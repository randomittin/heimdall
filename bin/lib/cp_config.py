#!/usr/bin/env python3
# cp_config.py — SERVER-DRIVEN ADAPTIVE INTERVALS (cost-governance §2, the big lever).
#
# WHY THIS EXISTS (the $10k-budget self-heal). Heimdall never pays for inference (BYO
# everywhere); the $10k/mo buys ONLY orchestration — Firestore ops + Cloud Run request
# handling. The dominant knob on that spend is HOW OFTEN every client beats/refreshes
# (launch-cost-model.md §4: doubling the beat/refresh interval ~halves the whole burn
# table). This module is the lever: a single, cheap, PUBLIC `GET /config` route serves
# the CURRENT interval ladder, the daily cost job SETS the ladder tier from the measured
# spend-pace, and every client (statusline, watch TUI, VS Code ext, hooks) fetches it on
# start + every ~10min and OBEYS it. The system self-heals its own burn with barely-
# perceptible wall latency (a 60s beat still feels live on a wall whose TTL rose with it).
#
# THE LADDER (spend-pace -> intervals; the daily job SETS the tier, /config SERVES it):
#   • < 50% of budget-pace -> DEFAULTS   : beat 20s / refresh 15s / ttl 45s  (nominal).
#   • 50–75%               -> 30 / 30 / ttl 90s   (backoff_reason budget_50pct).
#   • 75–90%               -> 60 / 60 / ttl 135s  (backoff_reason budget_75pct).
#   • > 90%                -> 120 / 120 / ttl 270s (backoff_reason budget_90pct) + an OWNER
#     ALERT (the daily job raises it — this module only records that the tier wants one).
# The TTL RISES WITH THE LADDER (spec §2): a 60s beat still feels live on a 135s wall, so
# slowing the beat never makes a present dev look offline — the online-window grows in step.
#
# NON-SENSITIVE + UNSIGNED, BUT CLAMPED (spec §2 / §3-abuse). /config is TUNING DATA, not a
# secret — it is served UNSIGNED (a browser statusline can read it with zero PKI). That means
# a spoofed/broken config could try to DoS a client (beat 1s) or a wall (beat 99999s), so the
# CLIENT clamps every interval it reads to [CLAMP_MIN_S, CLAMP_MAX_S] = [15s, 300s]
# (clamp_interval below, mirrored in bin/heimdall-presence). The ladder's own tiers are ALL
# already inside that band by construction — the clamp is the belt to the ladder's braces, so
# a compromised /config can never push a client outside the safe band. THE FALSIFIER: feed the
# clamp a 5 or a 9999 and it must return 15 / 300; drop the clamp and the raw value passes ->
# the client-clamp test goes RED.
#
# PER-COHORT OVERRIDE (spec §2/§3). A misbehaving team/IP cohort (flagged by cp_anomaly's
# >50×-median write-flood rule) gets its OWN slower interval THROUGH THE SAME mechanism: a
# per-cohort record pins that team to the ladder MAX (tier 3, 120/120), so its beats are
# COALESCED to the slowest cadence while every other team stays on the global ladder. /config
# resolves the cohort override FIRST (keyed by the caller's OWN team_id — a query param, since
# /config is unsigned), else the global ladder. cp-team-isolation stays green: the intervals
# are non-sensitive tuning; a cohort key is the caller's own team_id and the response leaks no
# other team's state (an unknown/spoofed cohort simply reads the global ladder).
#
# DURABLE + FIRESTORE-SAFE (the StateBackend discipline, verbatim). The ladder + cohort records
# are keyed JSON records written THROUGH cp_state.get_backend (put_record/get_record only —
# NEVER backend.path()), so the tier the daily job sets on one instance is read by /config on
# every other instance (survives scale-to-zero), byte-identical local in dev/test. A read
# tolerates an absent/corrupt record by returning the DEFAULT (tier 0) — a server that has
# never run the cost job simply serves the nominal defaults, which is the honest fail-safe.
#
# DATA ONLY, EXECUTES NOTHING. A config record is rendered tuning; there is no action_type /
# cmd / handler field and no path from here into dispatch. The §2 control/data-plane line holds.
#
# stdlib-only (json/os/sys/hashlib/time) + cp_state (persistence seam) + cp_server (register +
# Response) — the SAME dependency shape every CP store has, no third-party dep, self-hostable.

from __future__ import annotations

import hashlib
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_server  # REUSE register_public_route + Response — the §10 seam (/config is pre-auth).
import cp_state   # the pluggable persistence backend — the ladder/cohort records are keyed JSON
                  # written THROUGH a StateBackend so the tier the daily job sets is Firestore-
                  # durable (read by /config on every instance), byte-identical on local.

# ── the client clamp band (the spoof/DoS bound — spec §2/§3) ──────────────────────────────
#
# Every interval a client OBEYS is clamped to [CLAMP_MIN_S, CLAMP_MAX_S]. 15s is fast enough to
# feel live yet slow enough to bound per-client write rate; 300s (5min) is the slowest a wall
# can lag and still be "present". A spoofed /config can request neither a 1s DoS nor a 99999s
# black-hole — the clamp is the belt the client wears regardless of what the (unsigned) config
# says. The ladder's own tiers (20..120) live entirely inside this band, so the clamp is inert
# on every honest value and load-bearing only against a broken/hostile one.
CLAMP_MIN_S = 15
CLAMP_MAX_S = 300


def clamp_interval(value, *, default=None):
    """Clamp one interval (seconds) to the safe client band [CLAMP_MIN_S, CLAMP_MAX_S].

    A non-numeric / missing value falls back to `default` (itself clamped) when one is given,
    else to CLAMP_MIN_S — a client must ALWAYS end up with a usable, in-band interval, never a
    crash and never an out-of-band value. THE FALSIFIER (client-clamp test): clamp_interval(5)
    == 15 and clamp_interval(9999) == 300; remove the min()/max() and the raw value passes ->
    the test goes RED. Accepts an int/float or a numeric string (a client reads it off JSON /
    an env var), rejects a bool (True/False is never a meaningful interval)."""
    v = _coerce_number(value)
    if v is None:
        v = _coerce_number(default)
    if v is None:
        return CLAMP_MIN_S
    if v < CLAMP_MIN_S:
        return CLAMP_MIN_S
    if v > CLAMP_MAX_S:
        return CLAMP_MAX_S
    return int(v)


def _coerce_number(value):
    """A real number from an int/float or a numeric string, else None. A bool is rejected
    (True/False is never a meaningful interval). No exception escapes."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


# ── the ladder (spend-pace tier -> intervals + ttl + backoff reason) ──────────────────────
#
# Each tier is a CLOSED record: the beat/refresh cadence, the online-window ttl that rises with
# it, a backoff_reason a client can render ("we slowed the wall because we're at 80% of budget"),
# and whether reaching this tier WANTS an owner alert (the daily job fires it; this module only
# records the intent). The thresholds are the spec's ladder; `min_pct` is the INCLUSIVE floor of
# the tier's spend-pace band. Tiers are ordered ascending so tier_for_pct picks the highest whose
# floor the pace clears. Every interval here is inside [CLAMP_MIN_S, CLAMP_MAX_S] by construction.
_LADDER = (
    {"tier": 0, "min_pct": 0.0,  "beat_interval_s": 20,  "refresh_interval_s": 15,
     "ttl_s": 45,  "backoff_reason": None,          "owner_alert": False},
    {"tier": 1, "min_pct": 50.0, "beat_interval_s": 30,  "refresh_interval_s": 30,
     "ttl_s": 90,  "backoff_reason": "budget_50pct", "owner_alert": False},
    {"tier": 2, "min_pct": 75.0, "beat_interval_s": 60,  "refresh_interval_s": 60,
     "ttl_s": 135, "backoff_reason": "budget_75pct", "owner_alert": False},
    {"tier": 3, "min_pct": 90.0, "beat_interval_s": 120, "refresh_interval_s": 120,
     "ttl_s": 270, "backoff_reason": "budget_90pct", "owner_alert": True},
)

# The tier a flagged/coalesced cohort is pinned to (the ladder MAX — the slowest cadence). The
# anomaly rule (cp_anomaly §3) COALESCES a >50×-median write-flooder to this tier via a per-cohort
# override, so its beats are accepted but slowed to the max, never dropped.
COALESCE_TIER = _LADDER[-1]["tier"]


def ladder_tiers():
    """The full ladder as a list of tier dicts (for a status/CLI view). Read-only copy."""
    return [dict(t) for t in _LADDER]


def tier_for_pct(spend_pct):
    """The ladder tier for a spend-pace percentage: the HIGHEST tier whose inclusive `min_pct`
    floor the pace clears. A non-numeric / negative pace resolves to tier 0 (the nominal
    defaults — the honest fail-safe when the cost job has not produced a real number). Returns a
    fresh dict copy of the matched tier."""
    pct = _coerce_number(spend_pct)
    if pct is None or pct < 0:
        pct = 0.0
    chosen = _LADDER[0]
    for tier in _LADDER:
        if pct >= tier["min_pct"]:
            chosen = tier
    return dict(chosen)


def tier_by_index(index):
    """The tier dict at ladder position `index` (0..len-1), clamped into range. Used to pin a
    cohort to a specific tier (e.g. COALESCE_TIER). Returns a fresh dict copy."""
    i = index if isinstance(index, int) else 0
    i = max(0, min(len(_LADDER) - 1, i))
    return dict(_LADDER[i])


# ── store layout (keyed JSON records on the StateBackend rel namespace) ───────────────────
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace):
#   • the GLOBAL ladder is ONE record at "config/ladder.json".
#   • a per-cohort override is ONE record at "config/cohort/<team-hash>.json".
# The backend owns the home root + makedirs + the byte shape; this module NEVER opens a file
# directly and NEVER calls backend.path() on a serving path (FirestoreBackend.path() RAISES).
_CONFIG_REL = "config"
_LADDER_REL = os.path.join(_CONFIG_REL, "ladder.json")
_COHORT_REL = os.path.join(_CONFIG_REL, "cohort")
_RECORD_SUFFIX = ".json"

# The hex width of a cohort (team_id) hash used as a path segment — parity with
# cp_ratelimit._KEY_HASH_HEX / cp_daily_budget._TEAM_HASH_HEX. The team_id is already a
# non-secret derived id, but hashing keeps the path uniform + bounded + filesystem-safe.
_COHORT_HASH_HEX = 32


def _backend(home=None):
    """The StateBackend for the config store (HEIMDALL_STATE_BACKEND, default local). `home`
    pins the store root exactly as every CP accessor's `home=` arg always has — threaded
    straight through, no re-derivation of heimdall_home() here (the backend owns it)."""
    return cp_state.get_backend(home=home)


def _cohort_hash(team_id):
    """sha256-hash a cohort's team_id to a hex prefix used as a path segment (parity with
    cp_daily_budget._team_hash). Keeps the path uniform + bounded + filesystem-safe for any id
    shape. An empty/None id hashes the empty string to a stable bucket."""
    raw = str(team_id or "").encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_COHORT_HASH_HEX]


def _cohort_rel(team_id):
    """The store-relative path of one cohort's override record: config/cohort/<team-hash>.json."""
    return os.path.join(_COHORT_REL, _cohort_hash(team_id) + _RECORD_SUFFIX)


def _tier_record(tier, *, spend_pct=None):
    """Build the durable ladder/cohort record from a tier dict: the closed schema
    {tier, beat_interval_s, refresh_interval_s, ttl_s, backoff_reason, spend_pct, updated}.
    `spend_pct` is the measured pace that selected the tier (None for a cohort pin, where the
    tier is chosen by policy not by a global pace). DATA only — no action/cmd field."""
    return {
        "tier": tier["tier"],
        "beat_interval_s": tier["beat_interval_s"],
        "refresh_interval_s": tier["refresh_interval_s"],
        "ttl_s": tier["ttl_s"],
        "backoff_reason": tier["backoff_reason"],
        "spend_pct": (round(float(spend_pct), 2)
                      if isinstance(spend_pct, (int, float)) else None),
        "updated": int(time.time()),
    }


def _default_record():
    """The DEFAULT (tier 0) ladder record — what /config serves when the cost job has never
    run (an absent/corrupt store). The honest fail-safe: a fresh server serves nominal defaults,
    never a crash and never a slowed wall it did not earn."""
    return _tier_record(_LADDER[0], spend_pct=None)


def _valid_record(record):
    """True iff a read-back record has the closed ladder shape (a tier int + both intervals as
    numbers). A partial/corrupt record is treated as absent (-> default), never trusted."""
    if not isinstance(record, dict):
        return False
    if not isinstance(record.get("tier"), int):
        return False
    return (isinstance(record.get("beat_interval_s"), (int, float))
            and isinstance(record.get("refresh_interval_s"), (int, float)))


# ── SET (the daily cost job writes the tier) ──────────────────────────────────────────────


def set_ladder(spend_pct, *, home=None):
    """SET the GLOBAL ladder tier from the measured spend-pace (the daily cost job calls this).
    Selects the tier via tier_for_pct(spend_pct), writes the durable record, and returns it.
    Returns the record even on an IO failure (with a best-effort stderr note) — the caller (the
    daily job) treats a failed write as a logged degrade, not a crash, and /config falls back to
    the default until the next successful set. The returned record carries `owner_alert` so the
    daily job knows whether reaching this tier should page the owner (spec §4 brake chain)."""
    tier = tier_for_pct(spend_pct)
    record = _tier_record(tier, spend_pct=spend_pct)
    record["owner_alert"] = bool(tier.get("owner_alert"))
    if not _backend(home).put_record(_LADDER_REL, record):
        _stderr("cp_config: ladder tier NOT persisted (tier=%d pct=%s) — /config serves the "
                "prior/default until the next set" % (tier["tier"], record.get("spend_pct")))
    return record


def get_ladder(*, home=None):
    """The CURRENT global ladder record (what /config serves for a caller with no cohort
    override). Reads the durable record; an absent/corrupt record yields the DEFAULT (tier 0)
    — a server that has never run the cost job serves nominal defaults. Read-only, tolerant,
    never raises (a backend error degrades to the default)."""
    try:
        record = _backend(home).get_record(_LADDER_REL)
    except Exception:  # noqa: BLE001 — a config read must never raise; serve the default.
        return _default_record()
    return record if _valid_record(record) else _default_record()


# ── per-cohort override (a flagged team/IP gets its own slower interval — §2/§3) ──────────


def set_cohort_override(team_id, *, tier_index=COALESCE_TIER, reason="coalesced", home=None):
    """Pin a cohort (team_id) to a specific ladder tier — the per-cohort override (spec §2/§3).
    cp_anomaly calls this to COALESCE a >50×-median write-flooder to the ladder MAX (tier 3), so
    its beats are slowed to the slowest cadence rather than dropped. `reason` overrides the
    tier's own backoff_reason so a client can render WHY it was slowed ("coalesced"). Returns the
    stored record, {ok: False, ...} on an IO failure. Reversible: clear_cohort_override removes
    it (the cohort returns to the global ladder)."""
    tier = tier_by_index(tier_index)
    record = _tier_record(tier, spend_pct=None)
    if reason:
        record["backoff_reason"] = reason
    record["cohort"] = True
    if not _backend(home).put_record(_cohort_rel(team_id), record):
        return {"ok": False, "reason": "io_error"}
    record["ok"] = True
    return record


def clear_cohort_override(team_id, *, home=None):
    """REMOVE a cohort's override so it returns to the global ladder (reversibility — spec §3:
    all throttles reversible). Writes a tombstone record {cleared: True} that get_cohort_override
    reads as absent. Returns True on a stored write, False on IO failure. (A tombstone rather than
    a delete keeps the firestore-safe put/get discipline — no delete verb on the serving path.)"""
    return bool(_backend(home).put_record(
        _cohort_rel(team_id), {"cleared": True, "updated": int(time.time())}))


def get_cohort_override(team_id, *, home=None):
    """The cohort's override record, or None when it has none (never set, or cleared). A cleared
    tombstone ({cleared: True}) reads as None (back on the global ladder). Read-only, tolerant —
    a backend error yields None (the caller then serves the global ladder). An empty team_id is
    None (no cohort to override)."""
    if not team_id:
        return None
    try:
        record = _backend(home).get_record(_cohort_rel(team_id))
    except Exception:  # noqa: BLE001 — a cohort read must never raise; fall back to the global.
        return None
    if not isinstance(record, dict) or record.get("cleared"):
        return None
    return record if _valid_record(record) else None


# ── the effective config a caller sees (cohort override FIRST, else the global ladder) ────


def effective_config(cohort=None, *, home=None):
    """The config record a caller receives from /config: the caller's OWN cohort override when
    one exists (a flagged team gets its slower interval), else the global ladder. `cohort` is the
    caller's team_id (its own — /config is unsigned, so the caller names its own cohort; an
    unknown/spoofed cohort simply reads the global ladder, leaking no other team's state, so
    cp-team-isolation stays green). Returns a fresh record dict; never raises."""
    if cohort:
        override = get_cohort_override(cohort, home=home)
        if override is not None:
            return override
    return get_ladder(home=home)


def config_payload(cohort=None, *, home=None):
    """The PUBLIC /config JSON body: the clamped-by-construction interval tuning a client obeys.
    Carries {beat_interval_s, refresh_interval_s, ttl_s, backoff_reason?, spend_pct?, tier}. The
    intervals are already inside the client clamp band by construction, but the CLIENT clamps
    again on read (clamp_interval) — the belt to this brace. `backoff_reason`/`spend_pct` are
    omitted when null (a nominal tier carries neither). DATA only — no secret, no action field."""
    record = effective_config(cohort, home=home)
    payload = {
        "beat_interval_s": record.get("beat_interval_s"),
        "refresh_interval_s": record.get("refresh_interval_s"),
        "ttl_s": record.get("ttl_s"),
        "tier": record.get("tier"),
    }
    if record.get("backoff_reason"):
        payload["backoff_reason"] = record.get("backoff_reason")
    if record.get("spend_pct") is not None:
        payload["spend_pct"] = record.get("spend_pct")
    return payload


# ── the PUBLIC route (GET /config — unsigned, cached, non-sensitive tuning) ────────────────
#
# /config is served PRE-AUTH (register_public_route) because a browser statusline / a raw hook
# cannot PKI-sign, and the data is non-sensitive global tuning. It carries a Cache-Control so a
# CDN / the client caches it (clients fetch it only on start + every ~10min — it must not add
# per-request load). The cohort is read from the ?cohort=<team_id> query (the caller's OWN
# team_id — a client that wants its cohort's override passes it; an absent/unknown cohort reads
# the global ladder). No body is read (GFE rejects a GET-with-a-body); the query is the input.

# How long a client / CDN may cache /config. Clients re-fetch every ~10min anyway; a 60s cache
# collapses a thundering-herd of statuslines into ~one origin hit/min without meaningfully
# delaying a ladder change (a tier shift propagates within a minute — well under the ~10min
# client re-fetch cadence). Env-tunable for a deploy that wants a different edge cache.
_CACHE_TTL_ENV = "HEIMDALL_CONFIG_CACHE_SECONDS"
_CACHE_TTL_DEFAULT = 60


def _cache_seconds():
    """The Cache-Control max-age for /config (HEIMDALL_CONFIG_CACHE_SECONDS, default 60). A
    malformed/non-positive value falls back to the default (a cache header must never be a
    negative/zero that defeats edge caching by accident)."""
    raw = os.environ.get(_CACHE_TTL_ENV)
    if raw is None:
        return _CACHE_TTL_DEFAULT
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return _CACHE_TTL_DEFAULT
    return val if val > 0 else _CACHE_TTL_DEFAULT


def _query_cohort(request):
    """The caller's OWN cohort (team_id) from the ?cohort=<team_id> query, or None. GFE-safe
    (the query, never a body — Google's GFE rejects a GET-with-a-body). Mirrors cp_presence.
    _query_project: prefer the parsed request["query"], fall back to parsing the path's own
    ?query for a direct/in-process call. An absent cohort -> None (the global ladder)."""
    if isinstance(request, dict):
        q = request.get("query")
        if isinstance(q, dict) and q.get("cohort"):
            return q.get("cohort")
        path = request.get("path")
        if isinstance(path, str) and "?" in path:
            from urllib.parse import urlsplit, parse_qs
            vals = parse_qs(urlsplit(path).query).get("cohort")
            if vals and vals[0]:
                return vals[0]
    return None


def config_route(request, *, home=None):
    """GET /config — the PUBLIC, unsigned, cached interval-tuning read (spec §2). Returns the
    effective ladder config for the caller's OWN cohort (?cohort=<team_id>) else the global
    ladder, with a Cache-Control header so clients/CDN cache it (clients fetch only on start +
    every ~10min). Never signed, never a secret, DATA only — the CLIENT clamps every interval it
    reads to [15s, 300s] regardless of what this serves. Never raises (the payload builders are
    tolerant)."""
    cohort = _query_cohort(request)
    payload = config_payload(cohort, home=home)
    headers = {"Cache-Control": "public, max-age=%d" % _cache_seconds()}
    return cp_server.Response(200, payload, headers=headers)


def register(*, home=None):
    """Wire GET /config into cp_server's PRE-AUTH public seam (register_public_route — a browser
    statusline / a raw hook cannot sign, and the data is non-sensitive tuning), WITHOUT editing
    cp_server. The handler closes over the runtime `home` so a self-host deploy / a test pins its
    store root. Returns the registered (method, path) key(s). Idempotent — re-registering
    replaces. NB: (GET, /config) must ALSO be in cp_publicsurface.PUBLIC_ROUTES so the public
    surface serves it instead of a flat 404 (the allowlist is the public boundary)."""
    return [cp_server.register_public_route(
        "GET", "/config", lambda request: config_route(request, home=home))]


def _stderr(msg):
    """One best-effort diagnostic line to stderr (Cloud Run captures it). A logging failure is
    swallowed so it can never break the caller (a set/serve must not crash on a log fault)."""
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; must not raise into the caller.
        return
