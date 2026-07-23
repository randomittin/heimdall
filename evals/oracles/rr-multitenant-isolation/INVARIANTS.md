# rr-multitenant-isolation — invariants (INV-GOD + INV-LOGIN authored here)

This oracle is the falsifiable gate the cross-tenant "god mode" monitoring aggregate
(`GET /god/roster`) must pass **before any handler code is written**. The god aggregate
reads presence across ALL teams — the direct inverse of multi-tenant isolation — so it is
gated the hardest and the gate is authored independent of (and prior to) the
implementation. This file states INV-GOD, the four attack rows that encode it, and which
mutant proves each gate load-bearing.

## INV-GOD

> No team secret and no public route can ever return another team's data; the god
> aggregate is reachable ONLY with owner PKI + IAM.

Formally, for any caller `C` and any team secret `S`:

1. A request to the **PUBLIC surface** with `S` returns **ONLY** partition
   `derive_team_id(S)`.
2. `/god/*` returns **404 on the PUBLIC surface** for **all** `S` (and all anonymous
   callers) — it is never on the public route allowlist.
3. `/god/*` on the **GATED control-plane service** returns data **IFF**
   `identity.owner` **AND** valid signature **AND** IAM-authorized.
4. Even for the owner, the aggregate enumerates its partition set **SERVER-SIDE** from the
   team registry — it never honors a caller-supplied `team_id` (INV-1 holds for `/god/*`
   too).

INV-GOD composes with the existing invariants (INV-1 server-derived `team_id`, INV-2 cred
partition, INV-2/3 queue partition, INV-6 enqueue-only public surface, INV-11 repo↔team
authz). The public-surface boundary of INV-GOD is the same `cp_publicsurface` allowlist
that INV-6 hardens; the god routes simply must never be added to it.

## The four attack rows (all expected DENY)

Added to `fixtures/golden/acceptance.json` and modeled in `fixtures/model.mjs`, in fixed
sequence order after the existing A*/enqueue rows:

| Row | Invariant | Attack | DENY means |
|---|---|---|---|
| `G1-god-on-public` | INV-GOD (2) | `GET /god/roster` on the PUBLIC surface | the route 404s — the aggregate never resolves on the public surface |
| `G2-team-secret-god` | INV-GOD (1,2) | a valid team secret `S` (a public-surface bearer only) pointed at `/god/*` | `S` hits the public router where `/god/*` 404s; it never reaches the aggregate |
| `G3-nonowner-god` | INV-GOD (3) | a validly SIGNED, IAM-authorized **non-owner** key against the gated `/god/roster` | `_require_owner` returns 401 not_owner — only the owner passes |
| `G4-god-cross-partition` | INV-1 (god aggregate) | the owner supplies a forged body/query `team_id` not in the registry | the aggregate ignores the wire `team_id` and enumerates partitions server-side |

## Mutant → gate → RED (each new gate is load-bearing)

Each mutant is `fixtures/model.mjs` with EXACTLY ONE INV-GOD gate dropped. Dropping it
flips its attack from DENY to ALLOW, and `run.sh` reports that attack as
`first_divergence`. `bin/falsify` catches it (KILLED); leaving it in place would prove the
gate is not load-bearing.

| Mutant | Gate dropped | Attack that then SUCCEEDS | Oracle goes RED at |
|---|---|---|---|
| `god-in-public-allowlist` | `/god/roster` added to the public route allowlist (`PUBLIC_ROUTES`) | G1 **and** G2 — the aggregate resolves on the public surface for an anonymous caller and for a team secret | `G1-god-on-public` (first in sequence; G2 also flips) |
| `drop-require-owner` | the gated `/god/*` owner gate (`_require_owner`) | G3 — a signed non-owner key reaches the aggregate | `G3-nonowner-god` |
| `god-accepts-body-team-id` | server-side partition enumeration inside the aggregate | G4 — the aggregate honors a forged caller-supplied `team_id` | `G4-god-cross-partition` |

`god-in-public-allowlist` opening two attacks (G1, G2) from one dropped gate mirrors the
existing `accept-request-team-id` mutant, whose single dropped gate opens both
`A1-spoof-team-id` and `enqueue-cross-partition`; the manifest pins the first attack in
the fixed sequence as `first_fail_case`. G2 therefore has no dedicated mutant — it is
proven load-bearing by the same gate as G1, exactly as `enqueue-cross-partition` is proven
by the `accept-request-team-id` gate.

## Falsifiability

- Golden (`fixtures/golden/candidate.mjs`, every gate STRONG) DENIES all 16 attacks →
  `bin/falsify rr-multitenant-isolation --assert-score 1.0` passes (14/14 mutants killed).
- Weakening the acceptance table (dropping any G* or L* row) makes that row's mutant
  SURVIVE → score < 1.0 → falsify exits nonzero. The gate is not green-by-construction.
- The real `GET /god/roster` handler is implemented later (a separate agent) and MUST
  pass this gate — this oracle is authored independent of that implementation.

---

# INV-LOGIN — dashboard team-login session (authored here)

This oracle is also the falsifiable gate the dashboard **team-login** flow must pass
**before any login route is written**. Option B (`docs/analysis/dashboard-login-design.md`)
mints a short-TTL SESSION after a local hmd signs a canonical assertion binding
`{github-user ↔ HAID ↔ device_code}` with the enrolled Ed25519 HAID key, riding the
EXISTING `verify_identity` chokepoint. The session is a team-READ capability scoped to the
caller's OWN teams — never a cross-team capability, never owner. As with INV-GOD, the gate
is authored independent of (and prior to) the implementation.

## INV-LOGIN

> A dashboard login session is a team-READ capability scoped to the caller's OWN teams
> (server-derived via `registered_team(haid)` and signed in at mint); it is short-TTL,
> minted only on a verified HAID signature, and is ALWAYS `Identity.owner=false`.

Formally, for a login session minted for HAID `H` enrolled in `registered_team(H)`:

1. A read scopes to the session's **server-derived** teams ONLY — a body/query `team_id`
   is never honored (mirrors the `/dashboard-data` read: "returns roster/observe for ONLY
   the session's server-computed team_ids. Never trusts a client team_id.").
2. The session's team list is fixed **server-side at mint** from `registered_team(H)` and
   signed into the token — a client-tampered team list is never trusted.
3. An **expired / TTL-lapsed** session is rejected (401) before any read.
4. A mint request whose **HAID signature fails** verification issues **NO** session
   (`verify_identity` / `cp_auth.verify` is the single chokepoint).
5. A login session is **ALWAYS `Identity.owner=false`**; only owner-PKI + IAP grants owner
   (`dashboard-login-design.md` "God mode stays separate"). Owner authority is never
   delegatable through a dashboard session.

INV-LOGIN composes with the existing invariants: its server-derived team scope is the same
`registered_team(haid)` binding INV-1 uses, and its owner-separation is the same owner gate
INV-GOD hardens (a login session must fail `requireOwner` exactly as a non-owner key does).

## The five attack rows (all expected DENY)

Added to `fixtures/golden/acceptance.json` and modeled in `fixtures/model.mjs`, in fixed
sequence order after the existing A*/enqueue/G* rows:

| Row | Invariant | Attack | DENY means |
|---|---|---|---|
| `L1-session-cross-team` | INV-LOGIN-1 | a valid session for team A used with a body `team_id=B` to read team B's roster | the read stays scoped to the session's server-derived teams; team B is invisible |
| `L2-tampered-session-teamids` | INV-LOGIN-2 | a mint whose client-tampered team list adds a team the HAID is not enrolled in | teams are server-derived at mint from `registered_team` and signed in; the tampered team never enters the session |
| `L3-expired-session` | INV-LOGIN-3 | an expired / TTL-lapsed session presented for a read | the short TTL is enforced — the lapsed session is rejected (401) before any read |
| `L4-bad-signature-mint` | INV-LOGIN-4 | a mint request whose HAID signature fails verification | `verify_identity` rejects it — no session is issued |
| `L5-session-is-owner` | INV-LOGIN-5 | a login session pointed at an owner/god route | the session is always `owner=false` and never passes the owner gate |

## Mutant → gate → RED (each new gate is load-bearing)

Each mutant is `fixtures/model.mjs` with EXACTLY ONE INV-LOGIN gate dropped. Dropping it
flips its attack from DENY to ALLOW, and `run.sh` reports that attack as `first_divergence`.
`bin/falsify` catches it (KILLED); dropping the row from the acceptance table makes the
mutant SURVIVE (score < 1.0) — proving the row is load-bearing.

| Mutant | Gate dropped | Attack that then SUCCEEDS | Oracle goes RED at |
|---|---|---|---|
| `session-honors-body-team` | session read scopes to the session's server-derived teams | L1 — a team-A session reads team B by naming `team_id=B` | `L1-session-cross-team` |
| `session-teams-from-client` | server-derived team list at mint (`registered_team`, signed in) | L2 — the mint injects a team the HAID is not enrolled in | `L2-tampered-session-teamids` |
| `skip-session-expiry` | the short-TTL session expiry check | L3 — an expired session keeps reading rosters | `L3-expired-session` |
| `mint-skips-sig-verify` | the HAID signature verification at mint (`verify_identity`) | L4 — a forged-signature mint is issued a session | `L4-bad-signature-mint` |
| `login-session-grants-owner` | the always-`owner=false` rule for login sessions | L5 — a login session passes the owner/god gate | `L5-session-is-owner` |

Unlike `accept-request-team-id` / `god-in-public-allowlist` (one dropped gate → two
attacks), each INV-LOGIN mutant flips EXACTLY one attack (verified: `grade.mjs` reports a
single `ALLOW` per mutant), so every L* row has its own dedicated mutant.
