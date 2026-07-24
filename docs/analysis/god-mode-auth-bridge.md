# God Mode — the browser→god auth bridge (design of what was built)

Companion to `docs/analysis/dashboard-login-design.md` ("God mode stays separate"). That
doc kept god mode on owner-PKI + IAP and deliberately left the WEB path unbuilt. This
document is the design of the built bridge: how a **browser** reaches the owner-only
cross-tenant `/god/*` aggregate over the web without weakening INV-GOD (G1–G4).

## The problem

`/god/roster` + `/god/logs` (cp_god) are the deliberate INVERSE of multi-tenant isolation:
one owner watches every team. On the wire they are gated by TWO things a browser cannot
produce:

1. **GCP IAM** — the gated Cloud Run service is `--no-allow-unauthenticated`.
2. **The §3 Ed25519 owner signature** — `_require_owner(verify_identity(request))` needs a
   request signed by the owner's HAID private seed.

A browser has neither. RJ wants the god wall on the web, reachable only by him.

## The bridge — Google IAP as an owner-equivalent identity, for `/god/*` only

A THIRD serving surface (the **god surface**, `HEIMDALL_GOD_SURFACE=1`) sits behind Google
IAP. IAP authenticates RJ's Google identity at the edge and forwards a signed
`X-Goog-IAP-JWT-Assertion` (ES256) on every request. The control plane **independently
verifies** that JWT in the app layer (`bin/lib/cp_iap.py`) and, iff it is valid AND its
`email` == the configured owner email, mints `Identity(owner=True)` — the SAME shape the
Ed25519 owner yields, so `_require_owner` passes it identically.

This is a NEW owner-auth path ALONGSIDE the Ed25519 owner, scoped to `/god/*` on the god
surface only.

### Verification is real (not "trust the edge")

`cp_iap.verify_iap_jwt` performs the full JOSE verification, each an independent fail-closed
DENY:

- ES256 **signature** against Google's published IAP JWK set (`gstatic` JWKS, kid-matched,
  raw 64-byte r‖s re-encoded to DER, ECDSA-P256/SHA-256).
- `alg == ES256` **before** signature (blocks `alg=none` and RS/HS confusion — a
  caller-declared algorithm is never honored).
- `iss == https://cloud.google.com/iap`.
- `aud ==` the configured backend-service audience (`HEIMDALL_GOD_IAP_AUDIENCE`). An unset
  audience is a config error the caller refuses — the aud check is never skipped.
- `exp` present and unexpired; `iat` present and not in the future (bounded leeway).
- `email` present; then `cp_iap.iap_identity` requires `email == owner_email` (case-insensitive).

A misconfigured or bypassed IAP layer therefore cannot grant owner — the app layer is the
floor, IAP is defense in depth.

## Why INV-GOD (G1–G4) is intact

| Invariant | How it still holds |
|---|---|
| **G1/G2** — `/god/*` 404s on the public surface for anon + team-secret bearers | `/god/*` is still NEVER in `cp_publicsurface.PUBLIC_ROUTES`. The IAP path is honored ONLY when `cp_iap.god_surface_enabled()` (a DISTINCT deploy behind IAP), never on the public surface. `cp_iap` changes nothing about the public boundary. |
| **G3** — a signed non-owner → 401 not_owner | The owner gate (`cp_approval._require_owner`) is unchanged. The IAP path mints `owner=True` ONLY after signature + owner-email verify; every other case → `AuthError` → 401. |
| **G4** — the aggregate enumerates partitions server-side, ignores a wire team_id | The IAP path supplies only an `Identity`, never a team_id. cp_god still enumerates from the durable stores. Proven end-to-end (a forged `?team_id` under an IAP owner is ignored). |

Additionally, the IAP owner grant is **scoped to `/god/*`**: the god surface serves ONLY
`/god/*` + health (every other route is a flat 404), and the IAP header is consulted for no
other route. A browser that reached `/dispatch` on the god surface never resolves it, and
even if it did, `/dispatch` falls to §3 Ed25519 (which a browser cannot produce) → 401. The
grant confers nothing beyond the two read-only god routes.

## Where it plugs in (the exact change surface)

- **New module `bin/lib/cp_iap.py`** — the IAP verifier + surface predicates
  (`god_surface_enabled`, `is_god_route`, `owner_email`, `iap_audience`, `verify_iap_jwt`,
  `iap_identity`). stdlib + the `cryptography` EC backend the CP already ships. Graceful
  degrade (no EC backend → every verify raises `crypto_unavailable`, fail closed).
- **`bin/lib/cp_server.py`** — three additive edits:
  1. `import cp_iap` (one-way dep, like `cp_publicsurface`).
  2. lift the `X-Goog-IAP-JWT-Assertion` header into `request['iap_assertion']` (inert for
     every other route/surface — the §3 chokepoint ignores it).
  3. a **god-surface branch** at the top of `_handle`: when `god_surface_enabled()`, serve
     only health + `/god/*`; for `/god/*`, authenticate via `cp_iap.iap_identity` (401 +
     audit `auth_fail` on failure) and dispatch the registered god route with the owner
     Identity. Guarded entirely behind `god_surface_enabled()` → **inert on the gated IAM
     service and the public service** (both leave the flag unset; `/god/*` there is
     byte-for-byte unchanged — 404 on public, Ed25519 owner + IAM on the gated service).

Config (operator env, never hardcoded): `HEIMDALL_GOD_SURFACE`, `HEIMDALL_GOD_OWNER_EMAIL`,
`HEIMDALL_GOD_IAP_AUDIENCE` (+ optional `HEIMDALL_GOD_IAP_JWKS_URL`). Deployment steps:
`docs/god-mode-iap-setup.md`.

## Falsifiable proof

- **Oracle** — `evals/oracles/rr-multitenant-isolation` gains attack row **G5-god-forged-iap**
  ("a forged/absent/wrong-email IAP JWT must NOT mint owner") + mutant
  `god-accepts-forged-iap` (drops the app-layer verify). `bin/falsify
  rr-multitenant-isolation --assert-score 1.0` stays **1.0** (15/15 mutants caught, golden
  denies all 17 attacks); the new mutant goes RED exactly at G5.
- **CP enforcement** — `test/cp-iap-god-bridge.test.sh` drives the REAL code: unit coverage
  of every failure mode (forged signature, alg=none/HS confusion, wrong issuer/audience,
  expired, future-iat, no-email, unknown-kid, malformed, missing header, wrong-email,
  unconfigured) + a real `cp_server` HTTPServer on the god surface over a socket (valid owner
  JWT → 200 cross-tenant aggregate; forged/absent/wrong-email → 401; non-god route → 404;
  health pre-auth; forged `?team_id` ignored). 28/28 pass.

## The static page

`heimdall-site/god/` (index.html + god.js + god.css) — a self-contained, standalone bundle
(no dependency on runheimdall.dev's stylesheets) that renders `/god/roster` (cross-tenant
presence wall) + `/god/logs` (enrollments / verdicts / runs / security). It holds NO secret
and NO token: the credential is the ambient IAP session cookie (same-origin `fetch` with
`credentials: 'include'`). It deploys to the **same IAP origin** as the god endpoint (see
`god/README.md`), NOT to runheimdall.dev.
