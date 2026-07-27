# God Mode — the `hmd god` CLI (the no-GCP-browser path)

`hmd god` is the OWNER-ONLY, terminal path to **god mode**: the cross-tenant read that lets
the fleet owner (RJ) watch EVERY team at once — the deliberate inverse of every other read,
which is scoped to a single team.

```
hmd god roster                         the cross-team PRESENCE wall (all teams online)
hmd god logs [--kind K] [--limit N]    the cross-team ACTIVITY aggregate
                                       --kind: enroll | verdicts | runs | security (default: all)
                                       --limit N: keep the newest N rows per section
hmd god roster --json                  raw JSON instead of the pretty wall
```

It reads the owner-only routes `GET /god/roster` + `GET /god/logs` on the **gated**
control-plane service (`heimdall-control-plane`, deployed `--no-allow-unauthenticated`).

## The CLI vs. the web god view — two SEPARATE origins

There are **two independent** owner paths to the same `/god/*` data. They do not share an
origin, a deploy, or an auth method:

| | `hmd god` CLI (this doc) | Web god view (`god.runheimdall.dev`) |
|---|---|---|
| Surface | the **gated** `heimdall-control-plane` service | a **separate** IAP-gated Cloud Run service (`heimdall-cp-god`) |
| Owner auth | Ed25519 HAID **signature** (app layer) + GCP **identity token** (IAM edge) | Google **IAP JWT** (`X-Goog-IAP-JWT-Assertion`), verified by `cp_iap` |
| Needs | `gcloud` + the enrolled HAID key. **No IAP LB.** | the full IAP load-balancer + OAuth brand deploy (`docs/god-mode-iap-setup.md`) |
| Who | RJ at a terminal | RJ in a browser signed in as the owner Google account |

**The web god view is NOT the public dashboard** (`runheimdall.dev`). `god.runheimdall.dev`
is RJ's own IAP-gated origin in his GCP project — set up per **`docs/god-mode-iap-setup.md`**.
The CLI is the path that needs **no** browser and **no** IAP infrastructure. Same data, two
walls; neither weakens the multi-tenant isolation (INV-GOD G1–G5).

## How the CLI satisfies BOTH gates

`/god/*` on the gated service is gated twice; `hmd god` satisfies each:

1. **GCP IAM at the Cloud Run edge** — the service is `--no-allow-unauthenticated`, so every
   request must carry a Google identity token. The CLI attaches
   `gcloud auth print-identity-token --audiences=<service-url>` as `Authorization: Bearer …`.
   This gets the request *past the edge*; the app layer ignores it.
2. **The app-layer owner gate** — `cp_god`'s `_require_owner` refuses any non-owner Identity
   with **401 `not_owner`**. The CLI signs the request with RJ's **enrolled Ed25519 HAID key**
   (the same `~/.heimdall/pki/<haid>.seed` that `heimdall-presence`/`heimdall-dashboard` use),
   over the canonical `GET`-path bytes. The CP verifies the signature against the registered
   pubkey and checks `owner:true` in its key registry.

A **signed non-owner is refused 401 `not_owner`** — the falsifier this path is built to honor.

## Resolution (flag > env > derive)

| What | Order |
|---|---|
| HAID | `--haid` › `$HMD_HAID` › `heimdall-identity current` › `heimdall-haid current` |
| Seed | `~/.heimdall/pki/<haid-slug>.seed` (slug = HAID with `/` and `:` → `_`). Absent ⇒ "not enrolled" error. |
| URL | `--url` › `$HEIMDALL_GOD_CP_URL` › `$HEIMDALL_CP_URL` › `gcloud run services describe heimdall-control-plane --region=$HEIMDALL_GOD_CP_REGION` (default region `us-central1`) |
| IAM token | `$HEIMDALL_GOD_ID_TOKEN` › `gcloud auth print-identity-token --audiences=<URL>` (`$HEIMDALL_GOD_SKIP_ID_TOKEN=1` to omit for a self-host gated service) |

---

## THE CRUX — making RJ an owner

**Is RJ's HAID already an owner? NO** (by construction). Every enrolled dev is bound
`owner=False` — `cp_enroll` re-asserts it unconditionally (`bin/lib/cp_enroll.py`, the
`register_key(..., owner=False, ...)` calls), because an enrolled teammate is never a
gate-override / god-mode identity. The only `owner:true` identities a deploy has are the
server's **own** self-identity (`ensure_server_identity`, `HEIMDALL_CP_SERVER_HAID=haid:cp-server`)
and the IAP owner-email bridge (web view only). RJ's HAID — enrolled via a normal presence
beat — is therefore `owner=False`, and `_require_owner` 401s it. There was no owner-grant
mechanism before this change.

> Note on the HAID value: the machine-id suffix churns per checkout. `haid:rj.rishabhs-macbook-air-46d5`
> in the original spec resolves locally today to e.g. `haid:rj.rishabhs-macbook-air-4d6d`. Always
> grant the **actually-enrolled** HAID — read it with `heimdall-haid current` (or note the
> `identity:` line the CLI prints in its 401 `not_owner` refusal).

### The mechanism (built here): `HEIMDALL_CP_OWNER_HAIDS` — GO-LIVE REQUIRED

The owner set is **deploy config**, never a wire input. At boot (`cp_boot.boot`, right after
the server identity is established) `cp_auth.promote_owners()` flips `owner=True` on each
listed HAID's **existing** binding — preserving pubkey / team_id / project / enrolled_at — and
re-applies on **every cold-start** (deterministic, self-healing: a later re-enroll that reset
`owner=False` is re-promoted next boot).

```bash
# 1. Rebuild + redeploy the gated image carrying the new promote_owners code (the go-live),
#    e.g. your existing deploy/cloud-run pipeline.
# 2. Declare RJ an owner (use his ACTUAL enrolled HAID):
gcloud run services update heimdall-control-plane --region=us-central1 \
  --update-env-vars="HEIMDALL_CP_OWNER_HAIDS=haid:rj.rishabhs-macbook-air-4d6d"
# 3. The next cold-start promotes him. Then:
hmd god roster
```

**Go-live IS required** for this path: `promote_owners` is new code, so the image must be
rebuilt + redeployed before the env var does anything. Multiple owners: comma/space-separate
them. Fail-safe: a HAID **not** in the list is never touched (a signed non-owner still 401s —
INV-GOD G3 is unchanged); a listed HAID with **no** enrolled binding is **skipped**, never
fabricated (RJ must have beaten at least once so his pubkey is registered — he has).

### The no-redeploy alternative (Firestore console edit) — discouraged

The registry is one Firestore doc: root collection `heimdall_cp` (env `HEIMDALL_FIRESTORE_ROOT`),
document id **`auth__keys.json`**, field `rec.keys.<HAID>.owner`. Setting that boolean to
`true` in the Firestore console grants owner **immediately, no redeploy**. Caveats: it is
manual (get the HAID map-key exactly right) and **not self-healing** — a re-enroll that
rewrites the binding resets `owner=False`. Prefer the env mechanism; it re-asserts every boot.

## Verify the falsifier

A **non-owner** running `hmd god` must be refused. Proven by `test/heimdall-god-cli.test.sh`:
a signed non-owner identity → **401 `not_owner`**, non-zero exit; a promoted owner → 200.
The same test proves `promote_owners` escalates ONLY the declared HAID and leaves a non-listed
teammate `owner=False` (still 401). The CP-level invariant enforcement stays green in
`test/cp-god-session-isolation.test.sh` (G1–G4) and the `rr-multitenant-isolation` oracle.
