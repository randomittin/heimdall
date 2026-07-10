#!/usr/bin/env python3
# reference.py — the INDEPENDENT reference fold for the triage-coord (team-triaging) differential
# oracle.
#
# INDEPENDENCE (differential integrity). This module imports NOTHING from bin/lib/* — every rule
# below is HAND-REPRODUCED from evals/oracles/triage-coord/INVARIANTS.md, so it shares no code
# path with the shipped claim-arbitration fold under test. The impl author and this reference
# author are disjoint; differential.py (the neutral gate wiring) imports BOTH and diffs them, so
# oracle independence holds by construction. An acceptance grep enforces that this file names /
# imports no implementation module from bin/lib.
#
# WHAT IT COMPUTES. The SAME served-claim sequence the impl fold produces, recomputed from first
# principles over an interleaved multi-HAID pick stream (INVARIANTS.md section 2/3):
#   * events processed in (t, seq) order — the deterministic seeded variable-latency interleave;
#   * before each event, every claim whose expiry <= t is REAPED (TTL — the handoff enabler);
#   * a `pick` is GRANTED iff (team, issue) is unclaimed OR held by the SAME haid → emit a served
#     row + set expiry; otherwise DENIED (the cross-teammate no-double-work guard);
#   * claims are partitioned by (team, issue): a pick in one team never sees another team's claim
#     (INV — team isolation);
#   * a `release` frees (team, issue) iff the releasing haid holds it.
# Returns {"served": sorted list of served rows [t, seq, team, issue, haid]} — the comparable
# partition. A per-event property check ("each grant is valid") passes a whole-sequence RACE (two
# teammates both granted the same issue); this whole-partition differential catches that class.

from __future__ import annotations

import hashlib

_DEFAULT_TTL = 90


def fold(stream):
    """Fold an interleaved pick/release stream into the reference served-claim partition (the
    truth half of the differential). Independent re-statement of the one-owner-per-issue-per-team
    + TTL-reap invariant."""
    ordered = sorted(
        (e for e in (stream or []) if isinstance(e, dict)),
        key=lambda e: (int(e.get("t", 0)), int(e.get("seq", 0))),
    )
    active = {}  # (team, issue) -> {"haid", "expiry"}
    served = []
    for e in ordered:
        t = int(e.get("t", 0))
        for key in [k for k, v in active.items() if v["expiry"] <= t]:   # TTL reap
            del active[key]
        team = str(e.get("team", "default"))
        issue = str(e.get("issue", ""))
        haid = str(e.get("haid", ""))
        key = (team, issue)
        if e.get("action", "pick") == "release":
            held = active.get(key)
            if held and held["haid"] == haid:
                del active[key]
            continue
        held = active.get(key)
        if held is None or held["haid"] == haid:                          # GRANT
            ttl = int(e.get("ttl", _DEFAULT_TTL))
            active[key] = {"haid": haid, "expiry": t + max(1, ttl)}
            served.append([t, int(e.get("seq", 0)), team, issue, haid])
        # else DENIED — a different teammate holds an active claim; no emit.
    served.sort(key=lambda r: (r[0], r[1], r[2], r[3], r[4]))
    return {"served": served}


# ── deterministic seeded stream generator (the seeded variable-latency arm) ───


def _seeded_int(seed, *parts):
    h = hashlib.sha256(("|".join([str(seed)] + [str(p) for p in parts])).encode()).hexdigest()
    return int(h[:8], 16)


def generate_stream(seed, n_records=30):
    """A deterministic, seeded, VARIABLE-LATENCY interleaved multi-HAID pick stream — NOT a
    fixed-yield arrival-ordered sweep. Two teams, two HAIDs each, three issues. Each event lands
    at a jittered time (base cadence + a seeded 0..2 tick jitter), so different seeds interleave
    the picks differently — the concurrency the double-pick race hides in. Same seed => byte-
    identical stream. Carries the SAME issues across BOTH teams (so the isolation invariant is
    exercised every seed) and TTLs short enough that reap→re-pick happens (the handoff invariant).
    Both folds MUST agree on every seed — a race/isolation/TTL defect is a mutant-only divergence."""
    teams = ["team-alpha", "team-beta"]
    haids = {
        "team-alpha": ["haid:a1.box", "haid:a2.box"],
        "team-beta": ["haid:b1.box", "haid:b2.box"],
    }
    issues = ["github:o/r#1", "github:o/r#2", "corpus:p-3"]
    stream = []
    for i in range(n_records):
        team = teams[_seeded_int(seed, "team", i) % len(teams)]
        haid = haids[team][_seeded_int(seed, "haid", i) % 2]
        issue = issues[_seeded_int(seed, "iss", i) % len(issues)]
        # base cadence 2 ticks/event + a 0..2 jitter → overlapping, variable-latency windows.
        t = i * 2 + (_seeded_int(seed, "jit", i) % 3)
        action = "release" if (_seeded_int(seed, "act", i) % 7 == 0) else "pick"
        ttl = 4 + (_seeded_int(seed, "ttl", i) % 3)
        stream.append(
            {"t": t, "seq": i, "team": team, "haid": haid, "issue": issue,
             "action": action, "ttl": ttl}
        )
    return stream
