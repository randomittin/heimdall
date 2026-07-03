# rr-multitenant-isolation — cross-tenant-denial oracle coverage

The differential-style cross-tenant DENIAL oracle the W0 isolation ledger
(`docs/specs/2026-07-03-rr-isolation-invariants.md` §3) specified. It proves the whole
multi-tenant isolation story as a SINGLE gate: two tenants (A, B) each set up their own
creds / installation / queue, and EVERY cross-tenant attack MUST be DENIED. The gate
goes RED the instant ANY isolation gate is dropped — the meta-proof the gates are
load-bearing, not decorative.

## Shape (spec 2A structured seam)

- `--input` = a CANDIDATE isolation module (ES module exporting `default evaluate(attackId)`
  returning `"DENY" | "ALLOW"`).
- `--truth` = the acceptance oracle (`fixtures/golden/acceptance.json`) — the fixed
  `{attackId -> "DENY"}` table, applied identically to golden and every mutant.
- `run.sh` is the single source of diff-truth: it zips candidate decisions against the
  all-DENY acceptance table and reports the FIRST attack that returned `ALLOW` (the
  cross-tenant attack that SUCCEEDED) as `first_divergence {file, step, expected:"DENY",
  actual:"ALLOW"}`.
- `bin/falsify rr-multitenant-isolation --assert-score 1.0` = golden passes (every attack
  denied) AND every gate-dropped mutant is caught.

The candidate model (`fixtures/model.mjs`) mirrors the SHIPPED enforcement:
`cp_ghinstall.team_covers_repo` (INV-11), `cp_auth.registered_team` (INV-1),
`cp_team_creds.env_for_team` (INV-2 cred), `cp_team_queue` `(team_id,repo)` key
(INV-2/3 queue), `cp_ghinstall.get_installation` server-side (A5), and the
`cp_publicsurface` enqueue-only boundary (INV-6). The golden wires every gate STRONG; a
mutant is that SAME codebase with exactly ONE gate removed.

## Mutants → attacks → RED (the load-bearing proof)

| Mutant | Invariant | Gate dropped | Cross-tenant attack that then SUCCEEDS | Oracle goes RED at |
|---|---|---|---|---|
| `drop-team-covers-repo` | INV-11 | repo↔team authz (`team_covers_repo`) | A1/A5 IDOR — team A dispatches team B's repo | `A1-idor-repo` (DENY→ALLOW) |
| `accept-request-team-id` | INV-1 | server-derived `team_id` (`registered_team`) | A1 spoof — team A sets `team_id=B`, operates as B | `A1-spoof-team-id` |
| `drop-cred-partition-key` | INV-2 (cred) | per-team cred key (`env_for_team`) | A2 — team A's job runs on B's / a global cred | `A2-cred-read` |
| `drop-queue-partition-key` | INV-2/3 (queue) | `(team_id,repo)` queue key | A3 — team A drains team B's task queue | `A3-queue-drain` |
| `resolve-install-from-param` | A5 | server-side installation resolution | A5 — team A wields B's `installation_id` | `A5-install-swap` |
| `public-surface-dispatch` | INV-6 | enqueue-only public boundary | A10 — popped public surface dispatches / reads a cred | `A10-public-dispatch` |

Every mutant drops exactly one gate and flips exactly its own attack to `ALLOW`; the
golden denies all seven attacks (the sequence also carries `enqueue-cross-partition`,
INV-1, guarded by the same server-derived-`team_id` gate as the spoof). Falsifiability
score = 6/6 = 1.0, conditioned on golden passing.

## Falsifiability (the acceptance table is load-bearing)

`test/heimdall-rr-isolation-oracle.test.sh` proves the gate is not green-by-construction:
weakening the acceptance oracle (dropping the `A1-idor-repo` attack case) makes
`drop-team-covers-repo` SURVIVE — the score drops below 1.0 and `bin/falsify` exits
nonzero. A gate that could not be made to survive would be tautological; this one can.
