# team-copilot — COVERAGE (the REDUM TEAM-LENS arm)

The unified team co-piloting differential gate. This file transcribes the coverage for the
**redum team-lens** contribution; other tracks (triage, ponytail-debloat) add rows to the same
domain.

## Gate

- **Type:** `differential` (seeded impl-vs-reference over the team-candidate roster partition).
- **Registry command:** `evals/oracles/team-copilot/gate.sh --differential --seeds 200`
  (`bin/oracle-select team-copilot`).
- **Golden:** `fixtures/golden/differential.json` — 15 seeds × 12 records, folded through the REAL
  redum lens AND the independent reference. GREEN = they agree on every seed (147 rows compared;
  the 200-seed registry sweep compares 2049 rows).
- **Falsifier:** `bin/falsify team-copilot --assert-score 1.0` — golden passes AND every mutant is
  KILLED.
- **Keystone:** `bin/falsify rr-multitenant-isolation --assert-score 1.0` on every wave that reads
  team records.

## Coverage matrix

| Behavior | Invariant | Mutant (must go RED) | Expected |
|---|---|---|---|
| Team lens surfaces a teammate's ACTIVE claimed surface as a reuse candidate | RT-CLASS | `inflight-misclass` | green |
| A reaped teammate (checkpoint survives, claim dropped) → adoptable-dropped (RECOVERY) | RT-CLASS | `stale-claim-not-reaped` | green |
| A DIFFERENT team's ledger NEVER surfaces (isolation) | RT-ISO | `cross-team-read` | green |
| No teammate goal prose leaks into a candidate field | RT-LEAK | `content-leak` | green |
| Every relevant teammate row present exactly once | RT-DROP | `dropped-teammate` | green |
| Expired claim + no checkpoint = ghost, skipped | RT-GHOST | (golden distribution) | green |
| Team residual signal at gate is WARN, never blocks (no exit-3) | WARN-boundary | `test/redum-team-lens.test.sh` F2 | green |
| LOCAL same-repo duplicate still hard-blocks (verdict=block) | (unchanged) | `test/redum-team-lens.test.sh` F3 | green |
| Solo path byte-identical (team lens OFF) | (regression) | `test/redum-team-lens.test.sh` F6 | green |

## Mutant → kill

| Mutant | Invariant | Defect | Killed by |
|---|---|---|---|
| `cross-team-read` | RT-ISO | another team's surface leaks into the roster | extra row diverges |
| `content-leak` | RT-LEAK | active_goal prose in the human field | row value diverges |
| `stale-claim-not-reaped` | RT-CLASS | reaped surface shown as in-flight not adoptable | class/adoptable diverge |
| `inflight-misclass` | RT-CLASS | live surface shown as adoptable-dropped | class/adoptable diverge |
| `dropped-teammate` | RT-DROP | a recoverable teammate row omitted | missing row diverges |

All 5 mutants KILLED, golden GREEN → falsifiability 1.0. Isolation keystone 1.0.
