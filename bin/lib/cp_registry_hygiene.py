#!/usr/bin/env python3
# cp_registry_hygiene.py — REGISTRY TTL-EVICTION (cost-governance §3, bounded growth forever).
#
# WHY THIS EXISTS. The §3 abuse surface once inference is BYO is write-flooding + unbounded
# REGISTRY GROWTH: every enroll writes ONE haid->pubkey binding that lives forever, so a fleet
# that churns (devs try Heimdall once and never return) accretes dead identities in the single
# keys.json registry record without bound. The enroll rate-limit + the hard registry-size cap
# (cp_enroll.enroll_max_keys) bound the GROWTH RATE and the CEILING, but nothing RECLAIMS a
# binding once its holder goes quiet. This module is the spec's "Registry hygiene job: monthly
# TTL-eviction of identities with zero beats in 60 days" — the reclaim that keeps the registry
# bounded FOREVER, not just capped.
#
# THE ACTIVITY SIGNAL (derived from presence — zero per-beat cost). "Zero beats in N days" is
# read from the PRESENCE store, the authoritative beat record: a dev's beat upserts ONE presence
# record carrying its last-beat `ts` (cp_presence.build_record). This job WALKS the presence tree
# (presence/<project>/<team>/<haid>.json) and folds it to haid -> latest beat ts. So the idle
# window is measured off data the beat path ALREADY writes — this job adds NO per-beat write, no
# registry write on the hot path, and no last-seen field hammering the single shared keys.json
# record (which would be a Firestore write-contention disaster). It reads the presence tree +
# the registry once, on a MONTHLY cadence, and rewrites the registry ONCE.
#
# THE DECISION (fail-safe: never evict on the ABSENCE of evidence).
#   • OWNER  — an owner:true binding (the server / a gate-override identity) is NEVER evicted.
#   • ACTIVE — a binding whose latest presence beat ts is within the idle window is KEPT.
#   • NEVER-BEAT — a binding with NO presence record falls back to its enrolled_at stamp
#     (cp_auth.register_key writes it on enroll): an enroll that never produced a beat is evicted
#     once its enrolled_at ages past the window (this is what makes growth bounded even for a
#     key that enrolled and vanished without a single beat).
#   • GRANDFATHERED — a binding with NEITHER a presence record NOR an enrolled_at stamp (a legacy
#     pre-hygiene binding) is KEPT: we have NO positive evidence of staleness, and evicting on the
#     absence of a signal could cut off a live-but-pre-stamp member. Kept, not guessed.
#
# REVERSIBLE + AUDITED + DRY-RUN-ABLE. Eviction removes the binding via cp_auth.remove_keys (which
# refuses to remove an owner even if named — belt-and-braces). Every run audits the eviction set
# (cp_audit — the operational record). `apply=False` computes the full plan and touches NOTHING
# (the monthly job runs dry first, then applies). A re-enroll fully restores an evicted identity.
#
# stdlib-only (os/sys/time) + cp_state (walk the presence tree) + cp_auth (the registry read +
# remove_keys) + cp_audit (the operational record) — the SAME dependency shape every CP job has,
# no third-party dep, self-hostable. Firestore-safe: every store op is list_names/get_record/
# put_record (through cp_auth), never backend.path() on a serving path.

from __future__ import annotations

import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit   # the §9 operational record — every eviction run is audited.
import cp_auth    # the haid->pubkey registry (read) + remove_keys (the eviction write).
import cp_state   # the pluggable persistence backend — walk the presence tree (list_names/get).

# The presence store root + record suffix (parity with cp_presence._PRESENCE_REL / _RECORD_SUFFIX
# — referenced by literal so this read-only walker never imports cp_presence's write path).
_PRESENCE_REL = "presence"
_RECORD_SUFFIX = ".json"

_DAY_SECONDS = 86400

# The idle window: a binding with zero beats for this many days (and no fresher enrolled_at) is
# evicted. Env-overridable; the spec default is 60 days. A malformed/non-positive value falls back
# to the default (a misconfigured window must not evict the whole registry).
_MAX_IDLE_DAYS_ENV = "HEIMDALL_REGISTRY_MAX_IDLE_DAYS"
_MAX_IDLE_DAYS_DEFAULT = 60


def max_idle_days():
    """The idle window in days (HEIMDALL_REGISTRY_MAX_IDLE_DAYS, default 60). A malformed / non-
    positive value falls back to the default — a bad window can never widen into an evict-all."""
    raw = os.environ.get(_MAX_IDLE_DAYS_ENV)
    if raw is None:
        return _MAX_IDLE_DAYS_DEFAULT
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return _MAX_IDLE_DAYS_DEFAULT
    return val if val > 0 else _MAX_IDLE_DAYS_DEFAULT


def _backend(home=None):
    """The StateBackend (HEIMDALL_STATE_BACKEND, default local). `home` threads straight through."""
    return cp_state.get_backend(home=home)


def _record_ts(record):
    """The beat `ts` (epoch seconds) of one presence record, or None when absent/garbled. A record
    with no numeric ts contributes no activity signal (never falsely marks a haid active)."""
    if not isinstance(record, dict):
        return None
    ts = record.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        return None
    return float(ts)


def presence_last_seen(*, home=None):
    """Walk the presence tree and fold it to {haid: latest beat ts}. The tree is
    presence/<project>/<team>/<haid>.json; each record carries its own `haid` + `ts` (the beat
    freshness), so the fold is keyed by the record's OWN haid (never the slugged path segment,
    which is lossy). Read-only + tolerant: an absent tree yields {}, a garbled record is skipped.
    Firestore-safe — list_names/get_record only, never backend.path()."""
    backend = _backend(home)
    last_seen = {}
    for project in backend.list_names(_PRESENCE_REL):
        proj_rel = os.path.join(_PRESENCE_REL, project)
        for team in backend.list_names(proj_rel):
            team_rel = os.path.join(proj_rel, team)
            for name in backend.list_names(team_rel, suffix=_RECORD_SUFFIX):
                record = backend.get_record(os.path.join(team_rel, name))
                ts = _record_ts(record)
                if ts is None:
                    continue
                haid = record.get("haid")
                if not haid:
                    continue
                if haid not in last_seen or ts > last_seen[haid]:
                    last_seen[haid] = ts
    return last_seen


def plan_eviction(*, now=None, max_idle=None, home=None):
    """Compute the eviction PLAN without touching the registry. Returns a dict:
      {now, cutoff, max_idle_days, scanned, evict:[haid...], keep_active:[...], keep_owner:[...],
       keep_grandfathered:[...]}.
    A binding is EVICT iff it is NOT an owner AND has a positive activity signal (latest presence
    ts, else enrolled_at) that is OLDER than the cutoff (now - max_idle_days). A binding with no
    signal at all is kept (grandfathered). Pure of side effects — the dry-run the monthly job
    prints before it applies."""
    when = now if now is not None else time.time()
    days = max_idle if isinstance(max_idle, int) and max_idle > 0 else max_idle_days()
    cutoff = when - days * _DAY_SECONDS

    keys = cp_auth._load_keys(home).get("keys")
    last_seen = presence_last_seen(home=home)
    evict, keep_active, keep_owner, keep_grandfathered = [], [], [], []
    if isinstance(keys, dict):
        for haid, entry in keys.items():
            if not isinstance(entry, dict):
                continue
            if entry.get("owner"):
                keep_owner.append(haid)
                continue
            signal = last_seen.get(haid)
            if signal is None:
                enrolled = entry.get("enrolled_at")
                signal = float(enrolled) if isinstance(enrolled, (int, float)) \
                    and not isinstance(enrolled, bool) else None
            if signal is None:
                keep_grandfathered.append(haid)  # no evidence of staleness — never evict on absence.
            elif signal < cutoff:
                evict.append(haid)
            else:
                keep_active.append(haid)
    return {
        "now": int(when),
        "cutoff": int(cutoff),
        "max_idle_days": days,
        "scanned": len(keys) if isinstance(keys, dict) else 0,
        "evict": sorted(evict),
        "keep_active": sorted(keep_active),
        "keep_owner": sorted(keep_owner),
        "keep_grandfathered": sorted(keep_grandfathered),
    }


def evict_stale(*, now=None, max_idle=None, home=None, apply=True):
    """RUN the registry-hygiene job (spec §3). Computes the eviction plan and, when `apply`, removes
    every stale non-owner binding (cp_auth.remove_keys — which itself refuses to drop an owner) and
    audits the run. Returns the plan dict extended with {applied, evicted:[haid...]}. `apply=False`
    is a pure dry-run (nothing is removed, evicted == []). Never raises — a hygiene fault degrades
    to a logged no-op, never a crash (the monthly job must not page on a store hiccup)."""
    plan = plan_eviction(now=now, max_idle=max_idle, home=home)
    plan["applied"] = False
    plan["evicted"] = []
    if not apply or not plan["evict"]:
        return plan
    try:
        removed = cp_auth.remove_keys(plan["evict"], home=home)
    except Exception as exc:  # noqa: BLE001 — a hygiene fault never crashes the monthly job.
        _stderr("cp_registry_hygiene: eviction write failed (%s) — registry unchanged"
                % type(exc).__name__)
        return plan
    plan["applied"] = True
    plan["evicted"] = removed
    if removed:
        cp_audit.write("job_state", action_type="registry_hygiene_evict", actor_haid=None,
                       outcome="ok",
                       detail="evicted %d idle identities (window=%dd, scanned=%d)"
                       % (len(removed), plan["max_idle_days"], plan["scanned"]),
                       home=home)
    return plan


def _stderr(msg):
    """One best-effort diagnostic line to stderr (Cloud Run captures it). Swallowed on failure so
    a log fault can never break the caller."""
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; must not raise into the caller.
        return
