# rr-multitenant-isolation — cross-tenant-denial oracle coverage

The differential-style cross-tenant DENIAL oracle the W0 isolation ledger
(`docs/specs/2026-07-03-rr-isolation-invariants.md` §3) specified, extended with the
INV-GOD owner-only god-aggregate gates (see `INVARIANTS.md`). It proves the whole
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
(INV-2/3 queue), `cp_ghinstall.get_installation` server-side (A5), the
`cp_publicsurface` enqueue-only boundary (INV-6), and the INV-GOD god-aggregate gates
(public-surface route allowlist, gated `_require_owner`, server-side partition
enumeration). The golden wires every gate STRONG; a mutant is that SAME codebase with
exactly ONE gate removed.

## Mutants → attacks → RED (the load-bearing proof)

| Mutant | Invariant | Gate dropped | Cross-tenant attack that then SUCCEEDS | Oracle goes RED at |
|---|---|---|---|---|
| `drop-team-covers-repo` | INV-11 | repo↔team authz (`team_covers_repo`) | A1/A5 IDOR — team A dispatches team B's repo | `A1-idor-repo` (DENY→ALLOW) |
| `accept-request-team-id` | INV-1 | server-derived `team_id` (`registered_team`) | A1 spoof — team A sets `team_id=B`, operates as B | `A1-spoof-team-id` |
| `drop-cred-partition-key` | INV-2 (cred) | per-team cred key (`env_for_team`) | A2 — team A's job runs on B's / a global cred | `A2-cred-read` |
| `drop-queue-partition-key` | INV-2/3 (queue) | `(team_id,repo)` queue key | A3 — team A drains team B's task queue | `A3-queue-drain` |
| `resolve-install-from-param` | A5 | server-side installation resolution | A5 — team A wields B's `installation_id` | `A5-install-swap` |
| `public-surface-dispatch` | INV-6 | enqueue-only public boundary | A10 — popped public surface dispatches / reads a cred | `A10-public-dispatch` |
| `god-in-public-allowlist` | INV-GOD | public-surface route allowlist (`PUBLIC_ROUTES`) | G1/G2 — `/god/roster` resolves on the PUBLIC surface for an anonymous caller AND a team secret | `G1-god-on-public` (also flips G2) |
| `drop-require-owner` | INV-GOD | gated `/god/*` owner gate (`_require_owner`) | G3 — a signed non-owner key reaches the gated `/god/roster` | `G3-nonowner-god` |
| `god-accepts-body-team-id` | INV-1 (god aggregate) | server-side partition enumeration in the aggregate | G4 — the god handler honors a forged caller-supplied `team_id` | `G4-god-cross-partition` |
| `session-honors-body-team` | INV-LOGIN-1 | session read scopes to the session's server-derived teams | L1 — a team-A session reads team B's roster via a body `team_id=B` | `L1-session-cross-team` |
| `session-teams-from-client` | INV-LOGIN-2 | server-derived team list at mint (`registered_team`, signed in) | L2 — a mint injects a team the HAID is not enrolled in | `L2-tampered-session-teamids` |
| `skip-session-expiry` | INV-LOGIN-3 | the short-TTL session expiry check | L3 — an expired session keeps reading rosters | `L3-expired-session` |
| `mint-skips-sig-verify` | INV-LOGIN-4 | HAID signature verification at mint (`verify_identity`) | L4 — a forged-signature mint is issued a session | `L4-bad-signature-mint` |
| `login-session-grants-owner` | INV-LOGIN-5 | the always-`owner=false` rule for login sessions | L5 — a login session passes the owner/god gate | `L5-session-is-owner` |
| `autoteam-skips-collab-check` | INV-AUTOTEAM(B) | Stratum-B collaborator/permission check (`cp_ghverify`) | AT1 — a non-collaborator auto-joins the bound repo's team | `AT1-noncollaborator-autojoin` |
| `autoteam-trusts-claimed-ghuser` | INV-AUTOTEAM(A) | Stratum-A caller↔`gh_user` binding (`GET /user` re-derive) | AT2 — a forger names a real collaborator's login and is believed | `AT2-forged-gh-identity` |
| `autoteam-honors-wire-teamid` | INV-1 (auto-join) | server-side `repo → team_id` resolution (`cp_repoteam`) | AT3 — the auto-join honors a caller-supplied `team_id` | `AT3-autojoin-wire-team-id` |
| `autoteam-public-read-joins` | INV-AUTOTEAM(§5) | the PUBLIC-repo write/push threshold | AT4 — a read-only caller on a PUBLIC repo auto-joins | `AT4-public-read-only-autojoin` |
| `autoteam-any-caller-initiates` | INV-AUTOTEAM (initiate) | the admin/push requirement for auto-INITIATE | AT5 — a read-only non-initiator invents a team for an unbound repo | `AT5-unbound-repo-autojoin` |
| `autoteam-skips-haid-possession` | INV-AUTOTEAM (haid possession) | the HAID key-possession verification (`sig` must verify under the claimed haid's registered Ed25519 pubkey) | AT6 — a repo admin who KNOWS a victim's HAID binds it into her team without proving key possession | `AT6-haid-possession` |

Every mutant drops exactly one gate and flips its own attack(s) to `ALLOW`; the golden
denies all sixteen attacks. Two dropped gates open two attacks each from a single flag —
`accept-request-team-id` (A1-spoof + `enqueue-cross-partition`, INV-1) and
`god-in-public-allowlist` (G1 + G2, INV-GOD) — with the manifest pinning the first attack
in the fixed sequence as `first_fail_case`; every INV-LOGIN mutant (`L1`–`L5`) flips
exactly one attack. Falsifiability score = 14/14 = 1.0, conditioned on golden passing.

The five `L*` rows encode INV-LOGIN — the dashboard team-login session
(`docs/analysis/dashboard-login-design.md`, Option B: local hmd + HAID + gh device-flow;
see `INVARIANTS.md`). A login session is a team-READ capability scoped to the caller's OWN
teams (server-derived via `registered_team(haid)` and signed in at mint), short-TTL, minted
only on a verified HAID signature, and ALWAYS `Identity.owner=false`. The model gates:
`sessionReadTeams` (INV-LOGIN-1 server-scoped read), `sessionMintTeams` (INV-LOGIN-2
server-derived team list), `sessionIsLive` (INV-LOGIN-3 TTL), `mintVerifiesSignature`
(INV-LOGIN-4 sig-at-mint), `loginSessionPassesOwnerGate` (INV-LOGIN-5 never-owner).

## Falsifiability (the acceptance table is load-bearing)

`test/heimdall-rr-isolation-oracle.test.sh` proves the gate is not green-by-construction:
weakening the acceptance oracle (dropping the `A1-idor-repo` attack case) makes
`drop-team-covers-repo` SURVIVE — the score drops below 1.0 and `bin/falsify` exits
nonzero. A gate that could not be made to survive would be tautological; this one can.
Dropping any G* row makes the corresponding INV-GOD mutant survive the same way; dropping
any L* row makes its INV-LOGIN mutant survive (verified: each drop → score 13/14 = 0.9286,
`bin/falsify` exits nonzero).

## INV-AUTOTEAM — zero-touch team formation (the six AT rows)

The six `AT*` rows encode INV-AUTOTEAM — zero-touch team formation
(`docs/analysis/zero-touch-team-formation.md`; see `INVARIANTS.md`). Membership proof moves
from "holds the team secret" to "has GitHub access to the repo," enforced SERVER-SIDE: a
teammate auto-JOINS by proving GitHub repo access (Stratum A caller↔`gh_user` re-derive +
Stratum B `gh_user`↔repo permission), the operative `team_id` is server-resolved from the
`repo → team_id` binding (never a wire field), and a first-runner auto-INITIATES only with
admin/push, and the bound `haid` is proven by a key-possession `sig` that verifies under the
claimed HAID's registered Ed25519 key. The model gates are disjoint from every A*/G*/L*/C* gate:
`autoteamHasRepoAccess` (AT1 Stratum-B collaborator check), `autoteamVerifyCaller` (AT2
Stratum-A `GET /user` re-derive), `autoteamResolveTeam` (AT3 server-side `repo → team_id`
resolution — INV-1 for auto-join), `autoteamMeetsThreshold` (AT4 public write-threshold —
RJ's public-threshold policy as a single swappable gate), `autoteamCanInitiate` (AT5
admin/push required to initiate an unbound repo), and `autoteamVerifiesHaidPossession` (AT6
key-possession: the `sig` must verify under the claimed haid's registered pubkey — only the
key-holder binds their own haid; closes the residual `sig`-not-enforced vector §3c).

With the AT rows added the oracle grades **24 attacks against 22 mutants**: falsifiability
score = 22/22 = 1.0 (21 prior + 1 new AT6, all mutants killed, golden passing). Each new mutant
flips EXACTLY its own AT* row (verified: `grade.mjs` reports a single `ALLOW` per mutant),
no existing mutant flips any AT* row, and no AT* mutant flips an existing attack. Dropping
any AT* row makes its mutant SURVIVE (verified: each drop → score 21/22 = 0.9545,
`bin/falsify` exits nonzero) — the six auto-team gates are load-bearing, not
green-by-construction. The real `POST /team/auto` handler (`cp_autoteam` / `cp_ghverify` /
`cp_repoteam`) is implemented later by a separate agent and MUST pass this gate.
