#!/usr/bin/env python3
# cp_funnel.py — SERVER-SIDE launch-funnel stamps (DERIVED facts, never a new client payload).
#
# THE GOVERNING CONSTRAINT (why this module exists on the SERVER and nowhere else).
# IDENTITY.md:32-38 is a signed, dated boundary: the signed heartbeat is "the ONLY thing sent
# home; no analytics, no tracking, no third parties", and DATA.md:15 publicly commits that
# telemetry is "Not in this release. Written to a LOCAL spool only." So the launch funnel may
# NOT be answered by asking the client for more. The rule that decides everything:
#
#     A NEW payload sent FROM the client breaks the claim.
#     A fact DERIVED server-side from data the heartbeat ALREADY lawfully delivered does not.
#
# Every stamp here is in the second category. `enroll` already carries the team secret and mints
# `enrolled_at`; `verdict` is already named in the sanctioned heartbeat payload. This module adds
# ZERO client egress, ZERO new routes, and ZERO outbound calls — it only writes down, once, a
# fact the server already observed. bin/lib/funnel.py (the CLIENT recorder) is deliberately
# transport-free and stays that way; this is its server-side counterpart, not its transport.
#
# WHAT IT STAMPS (the three growth-loop facts the launch gate needs):
#   • TEAM-2+  — the K-factor NUMERATOR. cp_enroll already computes the team member count on the
#     exact transition (the per-team cap check); on the 1 -> 2 edge we stamp the cohort date
#     ONCE. WRITE-ONCE IS LOAD-BEARING: overwrite it on the 2 -> 3 enroll and the cohort date is
#     destroyed, which is the whole signal.
#   • ENROLL   — the DENOMINATOR. `enrolled_at` already lives on every registry binding, so
#     enrolled_by_day() reads it straight off the registry with no new write. But
#     cp_registry_hygiene EVICTS idle bindings (bounded registry growth forever), so that read
#     silently DECAYS toward zero over time. The APPEND-ONLY per-day spool below is what makes
#     the denominator survive eviction — it is never rewritten and never reaped.
#   • FIRST-VERDICT — the ACTIVATION event. The first non-empty verdict on a heartbeat. It is
#     stamped on its OWN durable doc, NOT on the presence record: a presence record is
#     last-write-wins (the next beat overwrites it), is tombstoned by a retire, and is the input
#     cp_registry_hygiene reaps. A stamp living there would evaporate. `funnel` is deliberately
#     NOT in cp_state_firestore._TTL_ELIGIBLE_ROOTS, so a funnel doc never carries `ttl_at` and
#     the Firestore TTL policy can never expire it.
#
# THE KEYS ARE ONE-WAY. A team is keyed by pmr.team_id_hash (the SAME projection the client-side
# corpus uses — never re-derived here), so a funnel count can never be joined back to a team
# identity in the clear; a HAID is keyed by the same domain-separated projection. The raw
# team_id / haid NEVER appears in a funnel key or record.
#
# NEVER FAILS ITS CALLER. A stamp is bookkeeping; an enroll or a heartbeat must NEVER break
# because of it. Every write path is wrapped and degrades to False, exactly as cp_presence
# degrades a store fault to {"ok": False} rather than crashing a beat.
#
# FIRESTORE-SAFE BY CONSTRUCTION. Every rel is a real "/"-separated path
# (funnel/<family>/<key>.json) — NEVER a literal "__" inside a segment. FirestoreBackend
# flattens "/" to "__" and recovers an immediate child by splitting on the FIRST "__", so a
# segment containing "__" reads back as a phantom SUBDIRECTORY and the doc goes invisible to its
# own enumeration (the firestore-only read-path incident class documented in cp_presence._slug).
#
# stdlib-only (os/sys/time) + cp_state (the persistence seam) + cp_auth (the registry read) +
# pmr_corpus (the one-way key projection) — the SAME dependency shape every other CP store has.

from __future__ import annotations

import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth   # the haid->pubkey registry — the enrolled_at read surface reads it, never writes.
import cp_state  # the pluggable persistence backend — every stamp is a put_record/append_line.

# The funnel store root. NOT a TTL-eligible Firestore root (cp_state_firestore._TTL_ELIGIBLE_ROOTS
# is nonce/ratelimit/team_daily), so a funnel doc is durable-forever: it outlives the presence
# record it was derived from and the registry binding that produced it.
_FUNNEL_REL = "funnel"

_TEAM_GREW_REL = os.path.join(_FUNNEL_REL, "team_grew")
_FIRST_VERDICT_REL = os.path.join(_FUNNEL_REL, "first_verdict")
_ENROLL_REL = os.path.join(_FUNNEL_REL, "enroll")
# INIT-PROXY — the first beat EVER from a HAID. `hmd init` is a LOCAL command the server can
# never see, so the funnel's top stage is answered by its lawful server-side PROXY: the first
# heartbeat that identity ever sent. The haid and its instant are both already in the sanctioned
# heartbeat payload, so this writes down a fact the beat ALREADY delivered — zero new egress.
_INIT_PROXY_REL = os.path.join(_FUNNEL_REL, "init_proxy")
# ACTIVE-DAY — the WAU input: one write-once mark per (haid, UTC day). Keyed "<day>-<haid_key>"
# inside ONE directory rather than a funnel/active/<day>/<haid> nest, because the day must stay a
# NAME part and not a path segment: FirestoreBackend.list_names recovers the FIRST segment after
# the "<rel_dir>__" prefix, so a deeper nest would read back as a phantom subdirectory. A "-"
# joiner is unambiguous — day is fixed-width YYYY-MM-DD and haid_key is pure sha256 hex (no "-"),
# so rsplit("-", 1) always recovers the pair, and no segment ever contains a literal "__".
_ACTIVE_REL = os.path.join(_FUNNEL_REL, "active")

_RECORD_SUFFIX = ".json"
_SPOOL_SUFFIX = ".ndjson"

# The WAU window: "active in the last 7 UTC days", inclusive of today.
_WAU_WINDOW_DAYS = 7
_DAY_SECONDS = 86400

# The member count BEFORE the enroll that constitutes the K-factor edge: a team that already has
# exactly ONE member and gains another is the 1 -> 2 transition. 0 -> 1 is a team being created
# (not virality); 2 -> 3 is growth of an already-viral team (the cohort date is already stamped).
_K_FACTOR_EDGE_MEMBERS_BEFORE = 1


def _backend(home=None):
    """The StateBackend for the funnel store (HEIMDALL_STATE_BACKEND, default local). `home`
    threads straight through exactly as every CP accessor's `home=` arg does — the backend owns
    the root. Mirrors cp_presence._backend / cp_auth._backend verbatim."""
    return cp_state.get_backend(home=home)


def _project(domain, value):
    """The ONE-WAY key projection for a funnel partition. REUSES the client corpus hasher
    (pmr_corpus._h) so there is exactly one hashing implementation in the tree — never
    re-derived here. Lazy import keeps the server's boot-time surface minimal (the same
    discipline cp_enroll uses for cp_anomaly)."""
    import pmr_corpus as pmr  # lazy — a pure, stdlib-only hasher; imported once, cached.
    return pmr._h(domain, str(value or ""), 16)  # noqa: SLF001 — intentional single-hasher reuse.


def team_key(team_id):
    """The one-way funnel key for a team. Projects the (already one-way) team_id once MORE
    through pmr.team_id_hash's PMR domain, so a funnel count can never be joined back to a
    team's presence/ops partition. The raw team_id never leaves this call."""
    import pmr_corpus as pmr  # lazy — see _project.
    return pmr.team_id_hash(str(team_id or ""))


def haid_key(haid):
    """The one-way funnel key for a HAID. Domain-separated from the team projection so the two
    keyspaces can never collide, and non-reversible so an activation count can never be joined
    back to an identity."""
    return _project("heimdall-funnel-haid", haid)


def day_key(ts=None):
    """The UTC day bucket ("YYYY-MM-DD") an epoch-seconds instant falls in. UTC (not local) so
    every Cloud Run instance in every region buckets the SAME beat into the SAME day."""
    when = ts if isinstance(ts, (int, float)) and not isinstance(ts, bool) else time.time()
    return time.strftime("%Y-%m-%d", time.gmtime(when))


def team_grew_rel(team_id):
    """The store rel of one team's K-factor stamp: funnel/team_grew/<team_key>.json."""
    return os.path.join(_TEAM_GREW_REL, team_key(team_id) + _RECORD_SUFFIX)


def first_verdict_rel(haid):
    """The store rel of one HAID's activation stamp: funnel/first_verdict/<haid_key>.json."""
    return os.path.join(_FIRST_VERDICT_REL, haid_key(haid) + _RECORD_SUFFIX)


def enroll_day_rel(day):
    """The store rel of one UTC day's append-only enroll spool: funnel/enroll/<day>.ndjson."""
    return os.path.join(_ENROLL_REL, str(day) + _SPOOL_SUFFIX)


def init_proxy_rel(haid):
    """The store rel of one HAID's init-proxy stamp: funnel/init_proxy/<haid_key>.json."""
    return os.path.join(_INIT_PROXY_REL, haid_key(haid) + _RECORD_SUFFIX)


def active_rel(haid, day):
    """The store rel of one (haid, UTC day) active mark: funnel/active/<day>-<haid_key>.json."""
    return os.path.join(_ACTIVE_REL, "%s-%s%s" % (day, haid_key(haid), _RECORD_SUFFIX))


def _stamp_once(rel, record, home=None):
    """WRITE-ONCE: persist `record` at `rel` ONLY IF nothing is stored there yet. Returns True
    on the committed first write, False when a stamp already exists (the cohort/activation date
    is preserved) or the store write fails. Never raises — a stamp must never break the enroll
    or heartbeat that triggered it."""
    try:
        backend = _backend(home)
        if backend.get_record(rel) is not None:
            return False
        return bool(backend.put_record(rel, record))
    except Exception:  # noqa: BLE001 — bookkeeping never fails a real flow.
        return False


def stamp_team_grew(team_id, *, members_before, when=None, home=None):
    """THE K-FACTOR NUMERATOR. On the 1 -> 2 member edge ONLY, stamp the team's cohort date
    {first_second_member_at} write-once under its one-way key. `members_before` is the member
    count cp_enroll ALREADY computed for the per-team cap check on this exact transition — no
    extra registry read. Any other edge (0 -> 1, 2 -> 3) is a no-op, and an existing stamp is
    NEVER overwritten. Returns True only on the committed first stamp."""
    if not team_id or members_before != _K_FACTOR_EDGE_MEMBERS_BEFORE:
        return False
    stamped = when if isinstance(when, (int, float)) and not isinstance(when, bool) else time.time()
    return _stamp_once(team_grew_rel(team_id),
                       {"first_second_member_at": int(stamped)}, home=home)


def record_enroll(*, when=None, home=None):
    """THE DENOMINATOR, EVICTION-PROOF. Append ONE line to the UTC-day enroll spool. Append-only
    by construction: nothing ever rewrites or reaps this spool, so the count survives
    cp_registry_hygiene evicting the binding that produced it (the registry-derived
    enrolled_by_day() view decays; this does not). The line carries ONLY the instant — no haid,
    no team, nothing joinable. Called on the NET-NEW registration path only, so a re-enroll of
    an existing identity never double-counts. Returns True on the committed append."""
    stamped = when if isinstance(when, (int, float)) and not isinstance(when, bool) else time.time()
    try:
        return bool(_backend(home).append_line(enroll_day_rel(day_key(stamped)),
                                               {"ts": int(stamped)}))
    except Exception:  # noqa: BLE001 — bookkeeping never fails an enroll.
        return False


def stamp_first_verdict(haid, *, verdict, when=None, home=None):
    """THE ACTIVATION EVENT. On the FIRST non-empty `verdict` ever seen from a HAID, stamp
    {first_verdict_at} write-once under the HAID's one-way key. A verdict-less / empty beat is a
    no-op, and a LATER verdict NEVER moves the activation instant. The stamp lands on its own
    durable funnel doc — never on the presence record, which is last-write-wins, tombstoned by a
    retire, and reaped by registry hygiene. Costs ONE tolerant get_record per verdict-bearing
    beat and ZERO writes after the first. Returns True only on the committed first stamp."""
    if not haid or verdict is None or not str(verdict).strip():
        return False
    stamped = when if isinstance(when, (int, float)) and not isinstance(when, bool) else time.time()
    return _stamp_once(first_verdict_rel(haid),
                       {"first_verdict_at": int(stamped)}, home=home)


def stamp_init_proxy(haid, *, when=None, home=None):
    """THE FUNNEL'S TOP STAGE. On the FIRST beat ever seen from a HAID, stamp {first_beat_at}
    write-once under the HAID's one-way key. This is the server-side PROXY for `hmd init`: init
    runs entirely on the dev's machine and is invisible here, but the first heartbeat that
    identity sends is a fact the sanctioned payload ALREADY delivers, so recording it adds ZERO
    client egress. Unlike first-verdict this does NOT require a verdict — a bare beat is enough,
    which is exactly what makes it the TOP of the funnel (arrived) rather than the activation
    (did something). Returns True only on the committed first stamp."""
    if not haid:
        return False
    stamped = when if isinstance(when, (int, float)) and not isinstance(when, bool) else time.time()
    return _stamp_once(init_proxy_rel(haid), {"first_beat_at": int(stamped)}, home=home)


def mark_active_day(haid, *, when=None, home=None):
    """THE WAU INPUT. Mark (haid, UTC day) active write-once. Returns True only on the day's
    FIRST beat from this HAID, so a dev beating 500 times in a day is counted ONCE — a per-beat
    counter would report traffic and call it users. Derived: haid + instant are already in the
    heartbeat. The mark carries only the instant; the day and identity live in the one-way key,
    so nothing joinable is stored in the record body."""
    if not haid:
        return False
    stamped = when if isinstance(when, (int, float)) and not isinstance(when, bool) else time.time()
    return _stamp_once(active_rel(haid, day_key(stamped)),
                       {"active_at": int(stamped)}, home=home)


def stamp_beat(haid, *, verdict=None, when=None, home=None):
    """THE ONE BEAT-PATH ENTRY POINT — every heartbeat-derived stamp, in one call, so the hot
    path has a single seam and cp_presence carries no funnel logic of its own.

    COST DISCIPLINE (why this is not three unconditional reads per beat). The active-day mark is
    checked on EVERY beat — it must be, since it is what makes a dev counted once per day. But
    init-proxy is checked ONLY when that mark was newly written, i.e. on the day's first beat.
    That is exact, not approximate: a HAID's first beat EVER is necessarily also its first beat
    of THAT day, so the init-proxy stamp can never be missed by this gate. Steady state is
    therefore ONE extra get_record per beat, not three, and the init-proxy read happens at most
    once per dev per day.

    Returns {init_proxy, active, first_verdict} — True for each stamp COMMITTED by this call.
    Never raises: every leg degrades to False, so a heartbeat can never fail on bookkeeping."""
    active = mark_active_day(haid, when=when, home=home)
    # Gated on `active`: the first beat of a day is the only beat that can be a first-ever beat.
    init_proxy = stamp_init_proxy(haid, when=when, home=home) if active else False
    first_verdict = stamp_first_verdict(haid, verdict=verdict, when=when, home=home)
    return {"init_proxy": init_proxy, "active": active, "first_verdict": first_verdict}


# ── read surfaces (read-only; write NOTHING) ──────────────────────────────────


def enroll_count(*, day=None, home=None):
    """The eviction-proof enroll count: the number of spooled enrolls for ONE UTC `day`, or
    across EVERY recorded day when `day` is None. Read-only + tolerant — an absent spool reads
    as 0, a garbled line is skipped (read_lines already drops it). Firestore-safe: list_names +
    read_lines only, never backend.path()."""
    backend = _backend(home)
    try:
        if day is not None:
            return len(backend.read_lines(enroll_day_rel(day)))
        total = 0
        for name in backend.list_names(_ENROLL_REL, suffix=_SPOOL_SUFFIX):
            total += len(backend.read_lines(os.path.join(_ENROLL_REL, name)))
        return total
    except Exception:  # noqa: BLE001 — a read surface degrades to a number, never a crash.
        return 0


def _count_records(rel_dir, *, home=None):
    """The number of stamps in one funnel family. list_names only (never backend.path()), so it
    reads identically on the local and Firestore backends. A missing family reads as 0."""
    try:
        return len(_backend(home).list_names(rel_dir, suffix=_RECORD_SUFFIX))
    except Exception:  # noqa: BLE001 — a read surface degrades to a number, never a crash.
        return 0


def init_proxy_count(*, home=None):
    """How many distinct HAIDs have EVER beaten (the funnel's top-of-stage count)."""
    return _count_records(_INIT_PROXY_REL, home=home)


def first_verdict_count(*, home=None):
    """How many distinct HAIDs have EVER produced a verdict (the activation count)."""
    return _count_records(_FIRST_VERDICT_REL, home=home)


def team_grew_count(*, home=None):
    """How many distinct teams have EVER reached 2+ members (the K-factor NUMERATOR)."""
    return _count_records(_TEAM_GREW_REL, home=home)


def active_count(*, days=_WAU_WINDOW_DAYS, now=None, home=None):
    """WAU: the number of DISTINCT HAIDs with at least one beat in the last `days` UTC days
    (inclusive of today). Counts distinct DEVS, never marks — a dev active on five days holds
    five marks and must still count as ONE user, or the metric reports traffic and calls it
    people. Read-only + tolerant: an absent family reads as 0, an unparseable name is skipped
    rather than guessed into the window."""
    when = now if isinstance(now, (int, float)) and not isinstance(now, bool) else time.time()
    window = {day_key(when - i * _DAY_SECONDS) for i in range(max(int(days), 1))}
    seen = set()
    try:
        names = _backend(home).list_names(_ACTIVE_REL, suffix=_RECORD_SUFFIX)
    except Exception:  # noqa: BLE001 — a read surface degrades to a number, never a crash.
        return 0
    for name in names:
        stem = name[: -len(_RECORD_SUFFIX)]
        day, sep, key = stem.rpartition("-")  # haid_key is pure hex — the LAST "-" is the joiner.
        if not sep or day not in window:
            continue
        seen.add(key)
    return len(seen)


def enrolled_by_day(*, home=None):
    """The REGISTRY-derived enroll denominator: {"YYYY-MM-DD": count} bucketed by each binding's
    existing `enrolled_at` stamp. No new write — this reads the key registry cp_enroll already
    maintains. It is the LIVE view (who is still enrolled), and it DECAYS as cp_registry_hygiene
    evicts idle bindings; enroll_count() is the durable historical counterpart. A binding with no
    enrolled_at (a legacy pre-stamp identity) is skipped rather than guessed into a bucket."""
    buckets = {}
    try:
        keys = cp_auth._load_keys(home).get("keys")  # noqa: SLF001 — the registry's own reader.
    except Exception:  # noqa: BLE001 — an unreadable registry reads as no data, never a crash.
        return buckets
    if not isinstance(keys, dict):
        return buckets
    for entry in keys.values():
        if not isinstance(entry, dict):
            continue
        enrolled = entry.get("enrolled_at")
        if not isinstance(enrolled, (int, float)) or isinstance(enrolled, bool):
            continue
        bucket = day_key(enrolled)
        buckets[bucket] = buckets.get(bucket, 0) + 1
    return buckets
