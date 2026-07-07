#!/usr/bin/env python3
# cp_anomaly.py — WRITE-FLOOD ANOMALY THROTTLE (cost-governance §3).
#
# WHY THIS EXISTS. Once inference is BYO everywhere (Heimdall never pays for a model call), the
# ONLY abuse left is WRITE-FLOODING the orchestration surface: a team/IP hammering /presence beats
# to burn Firestore writes + Cloud Run requests on the $10k/mo budget. It is cheap to ABSORB and
# cheaper to THROTTLE. This module is the throttle the spec §3 describes:
#
#   • ANOMALY RULE: any (team_id | IP) producing > ANOMALY_MULTIPLE× (default 50×) the MEDIAN daily
#     write volume of its peer cohorts is flagged. Its beats are ACCEPTED but COALESCED — the team
#     cohort is pinned to the interval-ladder MAX (cp_config.set_cohort_override -> tier 3, 120/120)
#     so its next /config fetch slows it to the slowest cadence. NOT dropped (a flood is data we
#     keep; we just slow the source). The cohort is MARKED and every owner is NOTIFIED.
#   • PERSISTENCE -> FREEZE: a cohort flagged on FREEZE_DAYS (default 3) CONSECUTIVE UTC days has its
#     ENROLLMENT FROZEN — no NEW member may enroll into that team (cp_enroll consults is_frozen);
#     EXISTING members keep working at the coalesced max backoff. This bounds a persistently-hostile
#     cohort without cutting off legitimate members mid-work.
#   • REVERSIBLE + AUDITED: every mark / coalesce / freeze writes a cp_audit row (the operational
#     record), and clear_mark / unfreeze undo it (a false positive, or a cohort that reformed, is
#     released). Nothing here is permanent or silent.
#
# THE MEDIAN, HONESTLY (the false-positive guard). A raw ">50× the median" fires spuriously when the
# fleet is tiny (median ~0, so any activity is "infinite×"). Two guards: (a) a cohort must ALSO clear
# an ABSOLUTE floor (ANOMALY_MIN_WRITES, default 5000/day — far above a legit ~1k beats/dev-day) to
# be flagged, so a small honest fleet never trips; (b) the median is computed over the CURRENT UTC
# day's per-cohort counters, so it tracks the live fleet. THE FALSIFIER (spec §3, both directions):
# a cohort at >50×median AND over the floor IS flagged (coalesced); a cohort at, say, 10×median or
# under the floor is NOT — evaluate() returns anomalous=False and writes no override.
#
# THE COUNTER (fixed UTC-day window, on the StateBackend seam — the cp_daily_budget discipline
# verbatim). record_write increments ONE keyed JSON counter {"count": N} per (kind, day, cohort-
# hash). One get + one put per recorded write — O(1), never a growing log, never backend.path().
# FLAG-GATED (HEIMDALL_ANOMALY_TRACK): the beat-path increment is INERT unless a deploy turns it on,
# so the single-tenant / gated path is byte-for-byte unchanged and adds no per-beat write by default.
#
# NEVER STORE A RAW IP / SECRET (no-secret-by-construction). A cohort key (a team_id — already a
# non-secret hash — or an IP) is sha256-hashed to a hex path segment before it becomes a key, so no
# raw IP is ever written or logged. The team_id used to freeze enrollment is the non-secret derived
# id (never the team secret).
#
# stdlib-only (hashlib/os/sys/time) + cp_state (persistence) + cp_config (the coalesce override) +
# cp_audit (the operational record) + cp_notify (the owner alert) + cp_auth (owner_haids) — the SAME
# dependency shape every CP throttle has, no third-party dep, self-hostable.

from __future__ import annotations

import hashlib
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit   # the §9 operational record — every mark/coalesce/freeze/clear audits.
import cp_auth    # owner_haids — the notify targets when a cohort is flagged.
import cp_config  # set_cohort_override / clear_cohort_override — the §2 coalesce mechanism.
import cp_notify  # the §8 owner alert channel (DATA only, never a command).
import cp_state   # the pluggable persistence backend — the daily counter + the mark record.

# ── policy knobs (env-overridable; conservative defaults) ─────────────────────────────────

# The multiple of the peer MEDIAN daily write volume above which a cohort is anomalous. 50× is the
# spec's threshold: an order-of-magnitude-plus over the typical dev, not a busy-but-legit team.
_MULTIPLE_ENV = "HEIMDALL_ANOMALY_MULTIPLE"
_MULTIPLE_DEFAULT = 50.0

# The ABSOLUTE daily-write floor a cohort must ALSO clear to be flagged (the tiny-fleet guard). A
# legit dev beats ~1k/day (5 active hours at 20s + slack); 5000 is comfortably above one dev yet far
# below a flood, so a small honest fleet never trips the ">50×~0 median" false positive.
_MIN_WRITES_ENV = "HEIMDALL_ANOMALY_MIN_WRITES"
_MIN_WRITES_DEFAULT = 5000

# Consecutive flagged UTC days before a cohort's ENROLLMENT is FROZEN. 3 days = a persistent
# pattern, not a one-off spike (which the coalesce already handles that day).
_FREEZE_DAYS_ENV = "HEIMDALL_ANOMALY_FREEZE_DAYS"
_FREEZE_DAYS_DEFAULT = 3

# The beat-path tracking flag: when truthy, the presence beat path increments the per-team daily
# write counter (one extra put/beat). Unset -> INERT (no per-beat write; the gated/single-tenant
# path is byte-for-byte unchanged). A public multi-tenant deploy turns it on.
_TRACK_ENV = "HEIMDALL_ANOMALY_TRACK"
_TRUTHY = {"1", "true", "yes", "on"}

# The two cohort KINDS. A team is the durable, actionable cohort (coalesce override + enroll freeze
# apply to it); an IP is tracked/marked/notified (the per-IP rate cap already coalesces a raw flood).
KIND_TEAM = "team"
KIND_IP = "ip"

_DAY_SECONDS = 86400
_HASH_HEX = 32
_RECORD_SUFFIX = ".json"
_FIELD_COUNT = "count"

# store rels (RELATIVE to control-plane/, the StateBackend namespace).
_WRITES_REL = "anomaly/writes"   # anomaly/writes/<kind>/<day>/<cohort-hash>.json  {"count": N}
_MARKS_REL = "anomaly/marks"     # anomaly/marks/<kind>/<cohort-hash>.json         (the mark record)


def tracking_enabled(env=None):
    """True iff HEIMDALL_ANOMALY_TRACK is truthy — the beat path then increments the per-team daily
    write counter. Unset / "" / "0" / "false" -> False (INERT: no per-beat write, the gated path
    unchanged). Mirrors cp_maintainer_runner.tenant_authz_enabled."""
    e = env if env is not None else os.environ
    raw = e.get(_TRACK_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _TRUTHY


def _float_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        val = float(raw)
    except (TypeError, ValueError):
        return default
    return val if val > 0 else default


def _int_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return default
    return val if val > 0 else default


def anomaly_multiple():
    """The >N×-median threshold (HEIMDALL_ANOMALY_MULTIPLE, default 50)."""
    return _float_env(_MULTIPLE_ENV, _MULTIPLE_DEFAULT)


def min_writes():
    """The absolute daily-write floor a cohort must clear to be flagged (HEIMDALL_ANOMALY_MIN_WRITES,
    default 5000 — the tiny-fleet false-positive guard)."""
    return _int_env(_MIN_WRITES_ENV, _MIN_WRITES_DEFAULT)


def freeze_days():
    """Consecutive flagged days before enrollment freeze (HEIMDALL_ANOMALY_FREEZE_DAYS, default 3)."""
    return _int_env(_FREEZE_DAYS_ENV, _FREEZE_DAYS_DEFAULT)


def _backend(home=None):
    """The StateBackend (HEIMDALL_STATE_BACKEND, default local). `home` threads straight through."""
    return cp_state.get_backend(home=home)


def _now():
    return time.time()


def _utc_day(now):
    """The UTC calendar-day ordinal for `now`: floor(now / 86400) (parity with cp_daily_budget)."""
    if not isinstance(now, (int, float)):
        return 0
    return int(now // _DAY_SECONDS)


def _hash(cohort_key):
    """sha256-hash a cohort key (team_id / IP) to a hex path segment — no raw IP ever stored."""
    raw = str(cohort_key or "").encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_HASH_HEX]


def _kind_slug(kind):
    """A safe, bounded kind segment (team|ip). An unknown kind coerces to 'other' (still stored,
    never escapes its segment)."""
    k = str(kind or "").strip().lower()
    return k if k in (KIND_TEAM, KIND_IP) else "other"


def _writes_rel(kind, day, cohort_key):
    """The per-(kind, day, cohort) counter record rel: anomaly/writes/<kind>/<day>/<hash>.json."""
    return os.path.join(_WRITES_REL, _kind_slug(kind), str(int(day)),
                        _hash(cohort_key) + _RECORD_SUFFIX)


def _writes_day_dir(kind, day):
    """The dir enumerating all cohorts' counters for a (kind, day): anomaly/writes/<kind>/<day>/."""
    return os.path.join(_WRITES_REL, _kind_slug(kind), str(int(day)))


def _mark_rel(kind, cohort_key):
    """The per-cohort mark record rel: anomaly/marks/<kind>/<hash>.json."""
    return os.path.join(_MARKS_REL, _kind_slug(kind), _hash(cohort_key) + _RECORD_SUFFIX)


def _read_count(backend, rel):
    """One counter record's non-negative int count (0 for absent/corrupt). Tolerant."""
    record = backend.get_record(rel)
    if isinstance(record, dict):
        raw = record.get(_FIELD_COUNT)
        if isinstance(raw, int) and raw >= 0:
            return raw
    return 0


# ── the daily write counter (record + read) ───────────────────────────────────────────────


def record_write(kind, cohort_key, *, amount=1, now=None, home=None):
    """Increment the (kind, cohort) CURRENT-UTC-day write counter by `amount` (>=1) and return the
    new count. One get + one put (O(1)). Called on the beat path (per team) when tracking is
    enabled, or by a test to seed synthetic volume. FAIL-SAFE: a backend error returns the amount
    (a lost increment never crashes a beat — the counter is an abuse signal, not a security gate)."""
    when = now if now is not None else _now()
    day = _utc_day(when)
    inc = int(amount) if isinstance(amount, (int, float)) and amount > 0 else 1
    backend = _backend(home)
    rel = _writes_rel(kind, day, cohort_key)
    try:
        count = _read_count(backend, rel) + inc
        backend.put_record(rel, {_FIELD_COUNT: count})
        return count
    except Exception:  # noqa: BLE001 — a lost increment never crashes a beat.
        return inc


def daily_counts(kind, *, now=None, home=None):
    """The list of every cohort's write count for the CURRENT UTC day (for the median). Enumerates
    the (kind, day) dir; an absent dir yields [] (a fresh day). Read-only, tolerant."""
    when = now if now is not None else _now()
    day = _utc_day(when)
    backend = _backend(home)
    day_dir = _writes_day_dir(kind, day)
    counts = []
    for name in backend.list_names(day_dir, suffix=_RECORD_SUFFIX):
        counts.append(_read_count(backend, os.path.join(day_dir, name)))
    return counts


def median_daily_writes(kind, *, now=None, home=None):
    """The MEDIAN of the current UTC day's per-cohort write counts (the peer baseline). 0.0 when no
    cohort has written yet (a fresh day). Pure statistics over daily_counts."""
    counts = sorted(daily_counts(kind, now=now, home=home))
    n = len(counts)
    if n == 0:
        return 0.0
    mid = n // 2
    if n % 2 == 1:
        return float(counts[mid])
    return (counts[mid - 1] + counts[mid]) / 2.0


def is_anomalous(kind, cohort_key, *, now=None, home=None):
    """Decide whether a cohort's CURRENT-day write volume is anomalous: count > multiple×median AND
    count >= the absolute floor (the tiny-fleet guard). Returns (anomalous, count, median, threshold).
    THE FALSIFIER (both directions): over both bars -> True; under EITHER -> False."""
    when = now if now is not None else _now()
    day = _utc_day(when)
    backend = _backend(home)
    count = _read_count(backend, _writes_rel(kind, day, cohort_key))
    median = median_daily_writes(kind, now=when, home=home)
    threshold = anomaly_multiple() * median
    anomalous = (count >= min_writes()) and (median > 0) and (count > threshold)
    return anomalous, count, median, threshold


# ── the mark record (the durable cohort state — reversible + audited) ─────────────────────


def get_mark(kind, cohort_key, *, home=None):
    """The cohort's mark record, or None when unmarked/cleared. Read-only, tolerant."""
    if not cohort_key:
        return None
    try:
        record = _backend(home).get_record(_mark_rel(kind, cohort_key))
    except Exception:  # noqa: BLE001 — a mark read never raises; treat as unmarked.
        return None
    if not isinstance(record, dict) or record.get("cleared"):
        return None
    return record


def is_marked(kind, cohort_key, *, home=None):
    """True iff the cohort is currently marked (flagged as a write-flooder, not yet cleared)."""
    return get_mark(kind, cohort_key, home=home) is not None


def is_frozen(team_id, *, home=None):
    """True iff the TEAM cohort's enrollment is FROZEN (persistently flagged FREEZE_DAYS+). cp_enroll
    consults this to REFUSE a NEW member for a frozen team (existing members keep working at max
    backoff). Only the team kind freezes (the actionable cohort). An empty team_id / unmarked team /
    cleared mark -> False (fail-open: a legit team is never frozen by a store hiccup)."""
    mark = get_mark(KIND_TEAM, team_id, home=home)
    return bool(mark and mark.get("frozen"))


def _audit(action_type, cohort_key, detail, *, home=None):
    """Write one operational audit row for a mark/coalesce/freeze/clear (mapped to the closed
    'job_state' event, the generic operational bucket — parity with cp_notify's alert mapping; the
    true action rides `action_type`). The cohort_key is passed as a bounded, scrubbed detail (no raw
    IP — cp_audit scrubs the detail). Never a security event (dispatch/override/auth_fail stay
    exclusive to real security acts)."""
    cp_audit.write("job_state", action_type=action_type, actor_haid=None,
                   outcome="ok", detail=detail, home=home)


def _notify_owners(text, *, home=None):
    """Alert every registered owner (cp_notify.alert -> owner inbox, DATA only). One owner's notify
    fault never blocks the others. Returns the alerted count."""
    alerted = 0
    for haid in cp_auth.owner_haids(home):
        try:
            if cp_notify.alert(haid, text, home=home).get("ok"):
                alerted += 1
        except Exception:  # noqa: BLE001 — a notify fault never breaks the throttle.
            continue
    return alerted


def evaluate(kind, cohort_key, *, now=None, home=None, notify=True):
    """THE anomaly decision + action (spec §3). Checks whether the cohort is anomalous TODAY and,
    if so: COALESCES it (pins the TEAM cohort to the interval-ladder max via cp_config), MARKS it
    (updating the consecutive-flagged-days run), FREEZES its enrollment once the run reaches
    FREEZE_DAYS, AUDITS, and (once per new flag day) NOTIFIES owners. Idempotent within a day —
    re-evaluating the same day does not double-count the consecutive run. Returns a decision dict:
      {anomalous, count, median, threshold, marked, coalesced, frozen, consecutive_days,
       owners_alerted}.
    A NON-anomalous cohort is a no-op (no override written, no mark) — the falsifiable opposite: the
    throttle fires at the threshold and NOT below."""
    when = now if now is not None else _now()
    day = _utc_day(when)
    anomalous, count, median, threshold = is_anomalous(kind, cohort_key, now=when, home=home)

    decision = {"anomalous": anomalous, "count": count, "median": median,
                "threshold": threshold, "marked": False, "coalesced": False,
                "frozen": False, "consecutive_days": 0, "owners_alerted": 0}
    if not anomalous:
        return decision

    backend = _backend(home)
    mark = get_mark(kind, cohort_key, home=home) or {}
    last_day = mark.get("last_flag_day")
    consecutive = int(mark.get("consecutive_flag_days") or 0)
    already_today = (last_day == day)
    if not already_today:
        # Extend the run when yesterday was also flagged, else start a fresh run at 1.
        consecutive = consecutive + 1 if last_day == day - 1 else 1

    frozen = bool(mark.get("frozen")) or (consecutive >= freeze_days())
    new_mark = {
        "kind": _kind_slug(kind),
        "marked": True,
        "first_flag_day": mark.get("first_flag_day") if mark.get("first_flag_day") else day,
        "last_flag_day": day,
        "consecutive_flag_days": consecutive,
        "frozen": frozen,
        "frozen_day": mark.get("frozen_day") if mark.get("frozen_day") else (day if frozen else None),
        "reason": "write_flood",
        "count": count,
        "median": median,
        "ts": int(when),
    }
    try:
        backend.put_record(_mark_rel(kind, cohort_key), new_mark)
        decision["marked"] = True
    except Exception:  # noqa: BLE001 — a mark write fault never crashes the beat path.
        decision["marked"] = False
    decision["consecutive_days"] = consecutive
    decision["frozen"] = frozen

    # COALESCE the TEAM cohort to the ladder max (the actionable dimension). An IP flood is already
    # coalesced by the per-IP rate cap; we still mark/notify/audit it, but the durable interval
    # override is a team concept (cp_config cohorts are keyed by team_id).
    if _kind_slug(kind) == KIND_TEAM:
        override = cp_config.set_cohort_override(cohort_key, reason="coalesced", home=home)
        decision["coalesced"] = bool(override.get("ok") or override.get("tier") is not None)

    # AUDIT (always) + NOTIFY (once per new flag day, so a steady flood does not re-page daily).
    _audit("anomaly_flag", cohort_key,
           "write_flood kind=%s count=%d median=%.1f consec=%d frozen=%s"
           % (_kind_slug(kind), count, median, consecutive, frozen), home=home)
    if frozen and not mark.get("frozen"):
        _audit("anomaly_freeze", cohort_key,
               "enrollment frozen kind=%s consec=%d" % (_kind_slug(kind), consecutive), home=home)
    if notify and not already_today:
        decision["owners_alerted"] = _notify_owners(
            "abuse throttle: a %s cohort flooded writes (%d today vs %.0f median) — coalesced to "
            "the interval-ladder max%s (day %d of flags)."
            % (_kind_slug(kind), count, median,
               "; ENROLLMENT FROZEN" if frozen else "", consecutive),
            home=home)
    return decision


# ── the beat-path observer (flag-gated: record the write + SAMPLED evaluate) ──────────────
#
# The presence beat path calls observe_beat when tracking is enabled. Two costs, kept bounded:
#   • the INCREMENT is O(1) EVERY beat (one get+put on the team's day counter) — the price of
#     tracking, paid only when the flag is on;
#   • the EVALUATE (which enumerates the day's cohorts to compute the median) runs ONLY on a
#     SAMPLED cadence, and ONLY once a cohort has already cleared the min-writes floor (i.e. it is
#     already a flood CANDIDATE). So the expensive median scan runs ~once per EVAL_EVERY writes for
#     a genuine flooder and NEVER for a normal team — the hot path stays cheap.
_EVAL_EVERY_ENV = "HEIMDALL_ANOMALY_EVAL_EVERY"
_EVAL_EVERY_DEFAULT = 250


def _eval_every():
    """How many writes between sampled evaluations of a flood-candidate cohort
    (HEIMDALL_ANOMALY_EVAL_EVERY, default 250). Bounds the median-scan frequency on the beat path."""
    return _int_env(_EVAL_EVERY_ENV, _EVAL_EVERY_DEFAULT)


def observe_beat(team_id, *, now=None, home=None):
    """Record ONE beat's write against the team's UTC-day counter and, on a sampled cadence once the
    cohort clears the min-writes floor, evaluate+coalesce (spec §3). Returns the evaluate decision
    dict when it ran this beat, else None (the common case — a cheap increment only). Called from
    the beat route ONLY when tracking_enabled(); inert (never called) otherwise, so the default path
    adds no per-beat write. Never raises — an abuse counter must not crash a heartbeat."""
    try:
        count = record_write(KIND_TEAM, team_id, now=now, home=home)
        floor = min_writes()
        every = _eval_every()
        # Only a cohort already OVER the flood floor is a candidate; sample its evaluation so the
        # median scan is amortized. A normal team never clears the floor, so it is never evaluated.
        if count >= floor and (count % every == 0 or count == floor):
            return evaluate(KIND_TEAM, team_id, now=now, home=home)
        return None
    except Exception:  # noqa: BLE001 — the throttle must never crash a beat.
        return None


# ── reversibility (a false positive / a reformed cohort is released — spec §3 audited) ────


def clear_mark(kind, cohort_key, *, home=None):
    """RELEASE a cohort: clear its mark (write a {cleared: True} tombstone) AND, for a team, remove
    its interval-ladder coalesce override (back to the global ladder). Reversibility (spec §3 — all
    throttles reversible + audited). Returns True on a stored write. An operator / a decayed-signal
    job calls this when a cohort reformed or a flag was a false positive."""
    ok = bool(_backend(home).put_record(
        _mark_rel(kind, cohort_key), {"cleared": True, "ts": int(_now())}))
    if _kind_slug(kind) == KIND_TEAM:
        cp_config.clear_cohort_override(cohort_key, home=home)
    _audit("anomaly_clear", cohort_key, "released kind=%s" % _kind_slug(kind), home=home)
    return ok


def unfreeze(team_id, *, home=None):
    """UNFREEZE a team's enrollment WITHOUT clearing its mark/coalesce (a targeted release of just
    the enrollment freeze — e.g. an owner vouches for a team still under the coalesced backoff).
    Rewrites the mark with frozen=False. Returns True on a stored write, False when unmarked."""
    mark = get_mark(KIND_TEAM, team_id, home=home)
    if not mark:
        return False
    mark = dict(mark)
    mark["frozen"] = False
    mark["frozen_day"] = None
    mark["ts"] = int(_now())
    ok = bool(_backend(home).put_record(_mark_rel(KIND_TEAM, team_id), mark))
    _audit("anomaly_unfreeze", team_id, "enrollment unfrozen", home=home)
    return ok


def _stderr(msg):
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only.
        return
