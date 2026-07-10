# triage-coord — INVARIANTS (TEAM MODE, TRACK A: team-triaging)

The exact semantics the `triage-coord` differential gate asserts. The independent reference
(`reference.py`) reproduces these from this file alone — it imports nothing from `bin/lib/*`.

## The unit under test

The **served-claim sequence**: given an interleaved stream of multi-HAID pick/release events over
teams and issues, which picks are GRANTED (each teammate's claim on an issue), in order. A served
row is `[t, seq, team, issue, haid]`. This is a **sequence-producing aggregate** — a per-event
"each grant is valid" check passes a whole-sequence race, so the gate is `differential`
(impl fold vs independent reference over seeded interleavings), not `property`.

## Invariants

- **one-owner-per-issue-per-team.** At any instant at most ONE haid holds a given `(team, issue)`.
  A `pick` is GRANTED iff the pair is unclaimed or already held by the SAME haid; otherwise DENIED
  (no emit). Two teammates can never both be granted the same issue — the cross-teammate
  no-double-work guard. This EXTENDS the machine-local `in_flight` bucket (which only stops one
  runner double-picking) to two teammates on two machines, via the git-shared `heimdall-claim`.

- **ordering.** Events are arbitrated in `(t, seq)` order — the deterministic, seeded,
  variable-latency interleave. `seq` breaks ties at equal `t` so the arbitration is total and
  reproducible; the jittered `t` is the concurrency the double-pick race hides in.

- **ttl-reap → re-pick (handoff enabler).** Before each event, every claim whose `expiry <= t` is
  REAPED. A dropped teammate's claim (its TTL lapsed) is therefore freed, and a later pick of that
  same issue is GRANTED — the issue is adoptable, not wedged. `expiry = grant_t + ttl`.

- **team isolation.** Claims are partitioned by `(team, issue)`. A pick in one team NEVER observes
  or collides with another team's claim: the SAME issue id can be served concurrently in two
  teams. A different team is a different git repo == a different `.planning` ledger, so the
  boundary is structural. Keystone: `rr-multitenant-isolation` stays 1.0.

- **release.** A `release` frees `(team, issue)` iff the releasing haid holds it (a non-holder's
  release is a no-op).

- **suggest-only routing (companion property, not in the served-claim fold).** Presence×expertise
  routing SUGGESTS an owner (online roster × recently-touched files) and NEVER auto-assigns: an
  offline teammate is never suggested, and the suggestion mutates nothing (no claim, no in_flight).
  A human/maintainer confirms the pick.

## Comparable partition

`{ "served": sorted list of [t, seq, team, issue, haid] }`. PASS iff the impl fold
(`issue_claim.simulate_claim_stream`) equals the independent reference fold (`reference.fold`) on
this partition, over every seed.

## Mutant belt (each must turn the gate RED)

- **double-pick-race** — two teammates both granted one `(team, issue)` (violates
  one-owner-per-issue-per-team).
- **cross-team-read** — a pick in team-beta denied because team-alpha holds the same issue id
  (violates team-isolation).
- **stale-claim-not-reaped** — a TTL-expired claim never reaped, so a later pick is denied forever
  (violates ttl-reap → re-pick).
