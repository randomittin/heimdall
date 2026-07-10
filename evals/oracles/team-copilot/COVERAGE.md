# team-copilot — COVERAGE

What the `team-copilot` differential gate covers, and what is deliberately out of scope. This
domain is the UNIFIED team-copilot oracle; TRACK A (team-triaging) contributes the triage
claim-arbitration cases below. Sibling tracks (redum team-lens, ponytail debloat) may add cases to
this same domain — a registry merge keeps ALL entries.

| Case | In scope? | Mechanism | Expected |
|---|---|---|---|
| Triage claim-gating: cross-teammate pick (no-double-work) | yes | differential served-claim sequence; `double-pick-race` mutant | green / mutant killed |
| Triage presence×expertise routing (suggest-only, offline excluded) | yes (property, companion) | `issue_queue.route_suggestions` — asserted by `test/heimdall-triage-team.test.sh` (no auto-assign, no mutation) | green |
| Triage reap → checkpoint handoff (dropped teammate adoptable) | yes | `ttl-reap-re-pick` invariant; `stale-claim-not-reaped` mutant | green / mutant killed |
| Team isolation (a different team's claims never visible) | yes | `team-isolation` invariant; `cross-team-read` mutant + `rr-multitenant-isolation` keystone | green / mutant killed |
| Solo / feature-off behavior | yes (regression) | `HEIMDALL_TEAM` unset/off → no claim shell, byte-identical pick — asserted by the (1c) contrast in `test/heimdall-triage-team.test.sh` | green (no change) |
| Redum team-lens cases | out of scope here (sibling track adds to this domain) | — | — |
| Ponytail debloat-overlap cases | out of scope here (sibling track adds to this domain) | — | — |

## Falsifiability

`bin/falsify team-copilot --assert-score 1.0` — golden passes (impl == reference over the seeded
variable-latency sweep) AND every mutant is rejected (the gate goes RED on each injected defect).
`bin/falsify rr-multitenant-isolation --assert-score 1.0` — the isolation keystone stays 1.0
(this track reads only same-repo team records; a different team is a different ledger).

## Why differential, not property

The served-claim sequence is a whole-aggregate over an interleaved stream. A per-event property
("each grant is one-owner-valid") passes a whole-sequence race — two teammates each granted the
same issue at close, jittered times. The differential diffs the ENTIRE served sequence against an
independent recompute over a seeded, variable-latency interleave (NOT a fixed-yield arrival-ordered
sweep, which resolves in arrival order by construction and is non-falsifiable), so the race,
isolation, and TTL defects are all caught.
