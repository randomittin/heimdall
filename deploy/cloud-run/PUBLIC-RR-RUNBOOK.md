# PUBLIC-RR-RUNBOOK — stand up the public, multi-tenant `rr` control plane (W4)

The human step-by-step that pairs with `deploy/cloud-run/deploy-public-rr.sh`. RJ runs this on
his own machine, with his own `gcloud` (authenticated as a **human owner**, never a service
account) and the **GitHub App he creates**. Project: `heimdall-cp-prod`.

**What "public RR" is.** Any developer installs a GitHub App on their own repo, runs
`claude setup-token`, and enrolls into the control plane with a shared enroll token. They then
`rr "<task>"` from their laptop: `rr` signs the task with their per-dev Ed25519 key and POSTs it
to the public, enqueue-only `/rr-task` route. The **gated** worker (holding the per-team creds)
drains the team queue and opens a PR **as the App**. Two W4 deploy decisions turn this on:

| env | value | effect |
|-----|-------|--------|
| `HEIMDALL_RR_TENANT_AUTHZ` | `1` | turns ON the multi-tenant authz gate + the `POST /rr-task` enqueue route |
| `HEIMDALL_TEAM_CRED_STORE` | `secretmanager` | each team's Claude cred (BYOC) lands in its own per-team Secret-Manager secret |
| `HEIMDALL_GATED_SERVICE_URL` | the gated service URL | **on the public service only** — where `POST /team/cred` forwards its privileged Secret-Manager write (step 3c) |

**Smallest honest MVP.** BYO-credential (each user pays their own Claude tokens via
`claude setup-token`) + your-repos-first (each user installs the App on **their** repo and enrolls
into **their** team). Every isolation guarantee is real on day one: a signed `/rr-task` can only
write a rate-limited, team-scoped, budget-capped row — never read a credential, never run code.
Metered billing, an automatic install-callback route, and multi-repo/multi-region are deferred
(see `docs/analysis/2026-07-03-public-rr-control-plane.md` §7).

---

## A. Create the "Heimdall Maintainer" GitHub App (github.com, once)

The maintainer opens PRs **as this App** — a distinct bot identity, never a human's personal
account, never `main`, never a merge. RJ holds the App's private key.

1. **New App:** https://github.com/settings/apps/new (personal) or
   `https://github.com/organizations/<ORG>/settings/apps/new` (org).
   Name it **`heimdall-maintainer`** (or your choice). Homepage URL: your repo URL.
   You may pre-fill from the manifest that `deploy/github-app/setup-bot.sh` (default/plan mode)
   prints.

2. **Repository permissions — grant EXACTLY these four, and NOTHING else:**

   | permission | level | why |
   |------------|-------|-----|
   | **Contents** | Read and write | push the `heimdall/*` fix branch (+ read repo code) |
   | **Issues** | Read and write | READ the issue queue (the connector's work source) + comment "resolved by #N" + close the resolved issue |
   | **Pull requests** | Read and write | open the PR + post the proof-receipt comment |
   | **Metadata** | Read-only | mandatory baseline for any App (auto-selected) |

   **DENY everything else.** In particular: **no Administration** (so the App cannot touch branch
   protection or repo settings), **no Workflows/Actions** (no CI mutation — supply-chain safety),
   **no Commit statuses / Checks** (the gate runs tests **locally**; it never reads CI status),
   **no Members**, **no Deployments**, **no Contents:admin**, **no merge** capability beyond what a
   human review gate allows. Subscribe to **no events** (the maintainer polls; it needs no webhooks).

3. **Public installability:** under "Where can this GitHub App be installed?", select
   **"Any account"** — this makes the App public so other developers can install it on their own
   repos. (Keep it **not listed on the Marketplace** unless you intend to publish.)

4. **Generate + download the private key:** App → **Generate a private key** → save the `.pem`
   somewhere only you can read (e.g. `~/.heimdall/heimdall-maintainer.pem`, mode `600`). This is
   the App-level secret — it is App-wide, not per-installation.

5. **Note the App ID:** App settings → **App ID** (a number). You pass it to the deploy script.

> Per-user **installations** happen later (§C) — each developer installs the App on **their** repo.
> W4 wires only the **App-level** id + key here; installation ids are captured per team at enroll
> time (`cp_ghinstall`), so there is no single global installation id to configure.

---

## B. Run `deploy-public-rr.sh`

Authenticate as a **human owner** first (the script refuses a `*.gserviceaccount.com` identity):

```bash
gcloud auth login                    # a HUMAN owner — NOT a service account
gcloud config set project heimdall-cp-prod
```

### B.1 — Dry run first (no creds, no side effects)

```bash
deploy/cloud-run/deploy-public-rr.sh --dry-run
```

Prints the entire W4 plan — APIs → App secrets → deploy (`go-live.sh` + `HEIMDALL_RR_TENANT_AUTHZ=1`,
`HEIMDALL_TEAM_CRED_STORE=secretmanager`) → per-team BYOC store → enroll token → verify — and runs
**nothing**. Read it end to end.

### B.2 — Real run

```bash
deploy/cloud-run/deploy-public-rr.sh \
  --gh-app-id <APP_ID> \
  --gh-app-key-file ~/.heimdall/heimdall-maintainer.pem \
  --project heimdall-cp-prod \
  --region  us-central1 \
  --endpoint https://<your-public-service-url>      # optional; used only in the onboarding print
```

The sequence (each step guarded + idempotent — safe to re-run):

1. **preflight** — gcloud present; active account is a **human owner** (loud refusal on a service
   account); project exists + billing enabled; enables `run`, `secretmanager`, `artifactregistry`,
   `iap`.
2. **gh-app** — App id → `heimdall-gh-app-id`; the private-key PEM is **streamed from the file to
   `gcloud` stdin** (never argv, never logged) → `heimdall-gh-app-private-key`; the runtime SA
   (`heimdall-cp-runtime@…`) is granted `secretAccessor` on each (per-secret IAM, least privilege).
3. **deploy** — reuses `go-live.sh` (gated rebuild → least-privilege public surface → live boundary
   verify; digest-pinned), then sets `HEIMDALL_RR_TENANT_AUTHZ=1` + `HEIMDALL_TEAM_CRED_STORE=secretmanager`
   on **both** services (**3b**), then wires the **cred write-forward** (**3c**, see below).
   - **3c — least-privilege cred write-forward (the `/team/cred` 503 fix).** `POST /team/cred` must
     **create + version** a per-team Secret Manager secret, which needs `secretmanager.admin`. The
     internet-facing **public** SA (`heimdall-cp-public-run@…`) is deliberately least-privilege and
     holds **no** secret-admin — a direct write there raises `PermissionDenied` → a **bare 503**. We
     do **not** grant the public SA secret-admin (that would let a public surface create arbitrary
     secrets). Instead the public surface **forwards** the signed `/team/cred` to the **gated**
     service (which runs as the admin-holding runtime SA and does the write). Step 3c makes the
     **narrow** grant — `roles/run.invoker` on the **gated service only** — and sets
     `HEIMDALL_GATED_SERVICE_URL` on the public service so the forward knows the target. The gated
     handler **re-verifies the same Ed25519 signature** and **re-derives `team_id` server-side**
     (INV-1); the cred only **transits** the public surface (never read back, never logged — INV-6).
4. **byoc** — confirms the store selector is live and grants the **gated runtime SA** the role to
   **create** per-team secrets at enroll time (project-scoped `secretmanager.admin`). The **public**
   SA is **deliberately NOT** granted this — the write executes on the gated SA via the 3c forward.
   Each user's Claude cred lands in its **own** per-team secret; the raw secret only ever lives in
   Secret Manager.
5. **enroll** — mints `cp-enroll-token` (python3 → stdin → `gcloud`; the value never leaves the pipe,
   so this is safe in CI). Skipped when `--enroll-open` (tokenless+bounded enroll).
6. **verify** — public reachability (`GET /healthz`, falling back to `GET /readyz` → `200 booted`);
   an **unsigned** `POST /rr-task` → `401/403` (the signed-enqueue chokepoint holds); an **unsigned**
   `POST /team/cred` → `401/403` (route served, chokepoint holds, **no 5xx handler crash** — the
   503-fix smoke); a gated route (`POST /dispatch`) → app `404 {no_such_route}` on the public surface
   (the boundary holds).

**Distribute the enroll token OUT-OF-BAND.** The script never prints it. Read it once, share it
privately with each onboarding user:

```bash
gcloud secrets versions access latest --secret=cp-enroll-token --project=heimdall-cp-prod
```

Also grab the public service URL to hand out:

```bash
gcloud run services describe heimdall-cp-public --region=us-central1 \
  --project=heimdall-cp-prod --format='value(status.url)'
```

---

## B.1 Hotfix the LIVE deployment — `/team/cred` 503 (IAM + env only, no full redeploy)

If the public surface is already live and `POST /team/cred` returns a **503 with an empty body**,
the least-privilege public SA is trying (and failing) to create a Secret Manager secret. Apply the
step-3c write-forward wiring with three **targeted** `gcloud` commands (no image rebuild needed for
the IAM + env; the *code* fix ships with the next deploy of the image that contains `cp_credforward`):

```bash
PROJECT=heimdall-cp-prod
REGION=us-central1

# 1. resolve the least-privilege public SA + the gated service URL
PUBLIC_SA=$(gcloud run services describe heimdall-cp-public --region="$REGION" --project="$PROJECT" \
  --format='value(spec.template.spec.serviceAccountName)')
GATED_URL=$(gcloud run services describe heimdall-control-plane --region="$REGION" --project="$PROJECT" \
  --format='value(status.url)')

# 2. NARROW grant: the public SA may INVOKE the gated service ONLY (roles/run.invoker on that
#    service resource) — NOT secretmanager.admin. This is the whole least-privilege point.
gcloud run services add-iam-policy-binding heimdall-control-plane --region="$REGION" --project="$PROJECT" \
  --member="serviceAccount:${PUBLIC_SA}" --role=roles/run.invoker

# 3. point the public surface's /team/cred forward at the gated service
gcloud run services update heimdall-cp-public --region="$REGION" --project="$PROJECT" \
  --update-env-vars="HEIMDALL_GATED_SERVICE_URL=${GATED_URL}"
```

**Verify** (unsigned → the §3 chokepoint, never a 5xx crash):

```bash
PUBLIC_URL=$(gcloud run services describe heimdall-cp-public --region="$REGION" --project="$PROJECT" --format='value(status.url)')
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$PUBLIC_URL/team/cred" -H 'Content-Type: application/json' -d '{}'
# expect 401/403 (route served, chokepoint holds). A 5xx means the code image predates cp_credforward
# — redeploy the public service on the new image (deploy-public-rr.sh / go-live.sh), then re-run steps 1–3.
```

The gated runtime SA (`heimdall-cp-runtime@…`) must already hold `secretmanager.admin` (step 4). The
public SA never gets it — the SM write executes on the gated SA via the forward.

---

## C. Per-user onboarding (each developer, once)

Give each user: the **public URL** and the **enroll token** (privately).

1. **Install the App on their repo (their-repos-first):** the user opens the App's public page →
   **Install** → their account/org → **"Only select repositories"** → their target repo. This
   bounds the installation to that one repo; the maintainer opens PRs there as the App.

2. **BYO Claude credential:** the user authenticates their own Claude access on their machine:

   ```bash
   claude setup-token
   ```

   Their cred is captured into their **own per-team** Secret-Manager secret at enroll — they pay
   their own tokens (BYOC MVP).

3. **Enroll + wire the control plane:**

   ```bash
   rr setup --mode control-plane --endpoint <public-url> --enroll-token <t>
   ```

   This writes `~/.heimdall/remote.json {mode: control-plane}`, mints the user's per-dev Ed25519 key,
   and enrolls their `haid` into their team. The enroll token is a **bootstrap** credential (used
   once to join) — never their signing key.

4. **Run a task:**

   ```bash
   rr "fix the flaky test in payments and open a PR"
   ```

   `rr` signs the task and POSTs it to `/rr-task`. The gated worker drains their team's queue and the
   App opens the PR on **their** repo. A human merges.

---

## Boundary recap (why this is safe)

- **Public surface holds no cred and cannot dispatch.** A signed `/rr-task` is **enqueue-only**: it
  writes a durable, team-scoped, rate-limited, budget-capped row and stops. Execution + the per-team
  creds live on the **gated** worker / Cloud Run Job (`run.jobs.run`-capable, IAM-walled).
- **Server-side team resolution.** The operative `team_id` is derived from the verified `haid`'s
  registry binding — never from a request field. A caller cannot target another team's repo
  (`cp_ghinstall.team_owns_repo`); a mismatch is a `403 + audit` before any job exists.
- **Enroll never escalates.** `enroll()` re-asserts `owner=False`; a leaked enroll/team secret can
  only "join + operate within that one team", bounded by per-team member + rate caps. Rotation =
  re-enroll under a new secret.

See `docs/specs/2026-07-03-rr-isolation-invariants.md` for the full invariant + attack table.
