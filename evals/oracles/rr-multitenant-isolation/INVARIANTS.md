# rr-multitenant-isolation — invariants (INV-GOD authored here)

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

- Golden (`fixtures/golden/candidate.mjs`, every gate STRONG) DENIES all 11 attacks →
  `bin/falsify rr-multitenant-isolation --assert-score 1.0` passes (9/9 mutants killed).
- Weakening the acceptance table (dropping any G* row) makes that row's mutant SURVIVE →
  score < 1.0 → falsify exits nonzero. The gate is not green-by-construction.
- The real `GET /god/roster` handler is implemented later (a separate agent) and MUST
  pass this gate — this oracle is authored independent of that implementation.
