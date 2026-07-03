# Heimdall Control Plane — Go-Live Runbook (two-service split)

This is the turnkey, copy-pasteable sequence to take the Heimdall control plane
live as **two Cloud Run services from one image**:

| Service | Posture | Surface | Runtime SA |
| --- | --- | --- | --- |
| `heimdall-control-plane` (**gated**) | `--no-allow-unauthenticated` | full surface (dispatch, jobs, approvals, owner, audit, scheduler, … **+** the public routes) | `heimdall-cp-run` — datastore + secrets + **`run.jobs.run`** |
| `heimdall-cp-public` (**public**) | `--allow-unauthenticated` | **public routes only** — `POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz`; every gated route 404s. Also serves **`GET /roster-public?project=<id>`** (+ `OPTIONS` preflight) — unauthenticated, rate-limited, CORS browser read for the web dashboard; projects handles/verdicts/files only, no secrets, no writes (presence WRITES stay signed). | `heimdall-cp-public-run` — datastore + (REQUIRED in token mode) enroll-token secret, **NO `run.jobs.run`** |

> **ENROLL IS TOKEN-GATED by default — the public/viral phase.** The public service
> deploys with `HEIMDALL_ENROLL_OPEN` **left unset** (the server's fail-closed token
> gate is the absent-env default): `/enroll` **requires** the `cp-enroll-token`
> bootstrap token, so presence is authenticated to "someone who was given the token".
> The token-gate is **defense-in-depth**, not the only control — a per-IP rate limit,
> a deployment-wide enroll budget, and a **hard registry-size cap** apply **on top of
> it in token mode too**, so a **leaked** token still cannot flood `/enroll` or bloat
> the registry, and enrolled keys are **presence-only** (`owner=False`). For
> **zero-config internal onboarding** there is an **open (tokenless) alternative**
> (`ENROLL_OPEN=1`) — the same caps bound it, the token is optional; its full security
> model, the **residual risk**, and how to **flip between modes** are in
> [**§ Enroll security model**](#enroll-security-model-the-honest-threat-model) below.

The deep rationale (why the split exists, the defense-in-depth boundary, the
execution model) lives in [`README.md`](./README.md) §5b. **This runbook is the
operational sequence** — run it top to bottom. Every step is a real command or a
hard gate; do not skip a gate.

> **GUIDED OPERATOR.** [`go-live.sh`](./go-live.sh) chains steps 2–7 below under
> your own authenticated `gcloud` shell — it prints each command, runs it, and
> stops on the first failure (it never holds a credential and never logs a secret
> value). Review the whole sequence with no spend via `bash go-live.sh --plan`;
> run it for real with `bash go-live.sh` (after the §3 kill-switch gate).

> **DEPLOY IS SPEND-GATED.** The two `gcloud run deploy` steps incur spend. Run
> them **only after** the billing kill-switch tests are green (the ₹10,000 cap),
> exactly as [`README.md`](./README.md) §3 requires. `--max-instances=5` caps
> fan-out under that cap.

---

## How this runbook makes the dangerous mistakes IMPOSSIBLE

The two-service split has three ways to go catastrophically wrong. Each is now a
**hard refusal in `deploy-public-surface.sh`**, not merely a documented warning:

1. **Public surface deployed under the dispatch-capable SA.** If the public,
   internet-facing service ran as `heimdall-cp-run` (which holds `run.jobs.run`),
   a server bug exposing `/dispatch` could launch Cloud Run Jobs from the open
   internet. → **PREFLIGHT P2** refuses if the public SA equals the gated SA
   (pure string check, always enforced); **PREFLIGHT P3** probes live IAM and
   refuses if the public SA holds **any** role granting `run.jobs.run`
   (`roles/run.developer`, `roles/run.admin`, `roles/owner`, `roles/editor`, or
   any custom role — e.g. `heimdallJobRunner` — whose `includedPermissions`
   contain it). **If IAM cannot be checked, the deploy refuses rather than
   proceeds blind.**
2. **The public-surface flag leaking onto the gated service.** If
   `HEIMDALL_PUBLIC_SURFACE=1` were set on `heimdall-control-plane`, the gated
   service would **404 its own** dispatch/jobs/approval/owner/audit routes — a
   **functional break** of the control plane (not a security hole, but a total
   outage of operator tooling). → **PREFLIGHT P1** refuses if the public service
   name equals the gated service name. The script sets the flag **only** on the
   service it deploys, and it can never be pointed at the gated service.
3. **The real server PKI seed shipped to the internet — or a seedless public boot.**
   Audit verdict (b): the public service needs a server seed **only to boot**, but
   no public route uses the server private key — so it gets a **DISTINCT throwaway
   seed** (`cp-pki-key-public`), never the real `cp-pki-key` (which stays
   server-only). → **PREFLIGHT P4** refuses reusing `cp-pki-key` (or the gated
   server HAID); **PREFLIGHT P5** refuses a public deploy with NO seed (it would
   fail-closed at boot and never go ready). Both the real-seed and the no-seed
   deploys are impossible.

You can confirm all refusals fire without spending anything:

```bash
cd deploy/cloud-run

# P1 — refuses to target the gated service
PUBLIC_SERVICE=heimdall-control-plane bash deploy-public-surface.sh plan; echo "exit=$?"  # -> FATAL P1, exit=2

# P2 — refuses the gated runtime SA
PUBLIC_SA_NAME=heimdall-cp-run bash deploy-public-surface.sh plan; echo "exit=$?"          # -> FATAL P2, exit=2

# P4 — refuses the real server seed on the public service
PUBLIC_PKI_SECRET=cp-pki-key bash deploy-public-surface.sh plan; echo "exit=$?"            # -> FATAL P4, exit=2

# P5 — refuses a seedless public deploy (a distinct throwaway seed is REQUIRED)
( unset PUBLIC_PKI_SECRET; bash deploy-public-surface.sh plan ); echo "exit=$?"            # -> FATAL P5, exit=2
```

---

## 0. Prerequisites (one-time, per project)

```bash
export PROJECT_ID="heimdall-control-plane"
export REGION="us-central1"
export GATED_SERVICE="heimdall-control-plane"
export PUBLIC_SERVICE="heimdall-cp-public"
export GATED_SA="heimdall-cp-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
export PUBLIC_SA="heimdall-cp-public-run@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"
gcloud auth list   # confirm you are authenticated — PREFLIGHT P3 requires reachable IAM

# APIs (idempotent): Cloud Run, Cloud Build, Firestore, Secret Manager, Artifact Registry.
gcloud services enable \
  run.googleapis.com cloudbuild.googleapis.com firestore.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com
```

The **gated** service, its `heimdall-cp-run` runtime SA, Firestore, the
`heimdall-long-job` Cloud Run Job, and the `run.jobs.run` IAM grant are all set
up by [`README.md`](./README.md) §0–§4. This runbook **assumes the gated service
already exists and serves an immutable image** (the public service pins that exact
digest in Step 5). If it is not yet deployed, run [`README.md`](./README.md)
§0–§4 first, then return here.

---

## 1. Firestore (durable state — shared by both services)

Both services read/write the same Firestore database (presence + roster + the
enroll key registry live there, durable across scale-to-zero). It is created once
in [`README.md`](./README.md) §1:

```bash
gcloud firestore databases create --location="${REGION}" 2>/dev/null \
  || echo "Firestore already exists — OK"
```

---

## 2. Secret Manager — per service, least exposure

The principle: **each service holds the minimum secret material it needs, granted
at the secret-resource level (never project-wide).**

### 2.1 The PKI signing seed `cp-pki-key` — GATED SERVICE ONLY

`cp-pki-key` is the Ed25519 **server identity** seed. It is created and consumed
exactly as [`README.md`](./README.md) §2 describes, and is read **only** by the
gated `heimdall-control-plane` runtime SA. **The public service does not get it.**

### 2.2 The enroll bootstrap token `cp-enroll-token` — REQUIRED by default (token mode)

> **REQUIRED in the default token mode (`HEIMDALL_ENROLL_OPEN` unset).** `/enroll` is
> fail-closed: without the secret, `cp_enroll.server_enroll_token()` returns `None` and
> enroll refuses every request — so `deploy-public-surface.sh` **refuses the deploy**
> when `cp-enroll-token` is absent in token mode (a dead enroll route). **Mint it before
> go-live** (the step below). It becomes **OPTIONAL only in the open (tokenless)
> alternative** (`ENROLL_OPEN=1`): there `/enroll` is tokenless+bounded, so you may skip
> this step — open enroll works without the token and the deploy does not fail when it is
> absent (see § Enroll security model → "Switch to open (tokenless) enroll"). The
> abuse-control caps (per-IP / budget / registry) apply in **both** modes regardless.

Mint it once (generated locally, piped straight to Secret Manager, never written to a
file — the same seam as the PKI key):

```bash
gcloud secrets create cp-enroll-token --replication-policy=automatic 2>/dev/null \
  || echo "cp-enroll-token already exists — OK"
python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(32))' \
  | gcloud secrets versions add cp-enroll-token --data-file=-
```

`deploy-public-surface.sh` grants the **public** SA `secretAccessor` on
`cp-enroll-token` **only** — a per-secret binding, so the public SA cannot read
`cp-pki-key` or any other project secret.

### 2.3 ✅ REQUIRED — a DISTINCT throwaway public PKI seed (audit verdict (b))

> **Resolved by `.planning/ref/public-surface-pki-need.md` — verdict (b).** The
> public service needs a server PKI seed **only to BOOT**: `cp_boot` calls
> `cp_auth.ensure_server_identity` unconditionally, and `load_signing_key` is
> **fail-closed in the cloud profile** (`K_SERVICE` set ⇒ no seed ⇒ boot raises
> `pki_key_absent`). So a Cloud Run public service **cannot start without a seed** —
> but **no public route uses the server private key** (presence/roster verify dev
> signatures against the per-dev registry; enroll gates on the bootstrap token; no
> public route mints a server-signed artifact).
>
> **Therefore: ship a DISTINCT THROWAWAY seed — NEVER the real `cp-pki-key`.** The
> public service gets its own boot identity under a **distinct HAID**; a compromise
> of the internet-facing service leaks only a throwaway identity + the rotatable
> enroll token, never the gated server identity. The real `cp-pki-key` stays
> server-only on the gated service (§2.1). `PREFLIGHT P4` + `P5` make a seedless or
> real-seed public deploy impossible (a seedless public service would fail-closed at
> boot; the real seed on the internet is the exact exposure we refuse).
>
> Provision the distinct throwaway seed and hand it to the deploy via env:
>
>   ```bash
>   gcloud secrets create cp-pki-key-public --replication-policy=automatic
>   python3 - <<'PY' | gcloud secrets versions add cp-pki-key-public --data-file=-
>   import base64
>   from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
>   from cryptography.hazmat.primitives import serialization
>   seed = Ed25519PrivateKey.generate().private_bytes(
>       encoding=serialization.Encoding.Raw,
>       format=serialization.PrivateFormat.Raw,
>       encryption_algorithm=serialization.NoEncryption())
>   import sys; sys.stdout.write(base64.b64encode(seed).decode())
>   PY
>   ```
>
>   Then in Step 5: `export PUBLIC_PKI_SECRET="cp-pki-key-public"` (REQUIRED — a
>   Cloud Run public deploy without it is refused by PREFLIGHT P5; and optionally
>   `PUBLIC_SERVER_HAID`, default `cp-public-server`). **PREFLIGHT P4 hard-refuses**
>   if `PUBLIC_PKI_SECRET` is `cp-pki-key` or if the public HAID equals the gated
>   `cp-server`; **PREFLIGHT P5 hard-refuses** a public deploy with NO
>   `PUBLIC_PKI_SECRET` (a seedless public service would fail-closed at boot) — both
>   the wrong-seed and the no-seed deploys are impossible.

---

## Enroll security model (the honest threat model)

**Token mode is the default** for the public/viral phase: the public service deploys with
**`HEIMDALL_ENROLL_OPEN` left unset**, so `/enroll` is **fail-closed and token-gated** —
only a holder of the `cp-enroll-token` value can enroll, and presence is authenticated to
"someone who was given the token". An **open (tokenless) alternative** (`ENROLL_OPEN=1`)
exists for zero-config internal onboarding. This section states **exactly** what each mode
does and does **not** protect, with no hand-waving.

### What bounds enroll (in BOTH modes)

Enroll is bounded by **five independent controls**, each set by `deploy-public-surface.sh`
(env-overridable). Controls **1–3 + 5 apply in BOTH modes**; control 4 (presence-only)
holds in both as well. In the default **token mode** the bootstrap-token gate sits **on
top** of these as a sixth control — so even a **leaked** token is still bounded by 1–3:

1. **Per-IP rate limit** — `HEIMDALL_ENROLL_IP_LIMIT` new enrolls per
   `HEIMDALL_ENROLL_IP_WINDOW` (default **5 / 60s**). A single client IP cannot hammer
   `/enroll`. (On Cloud Run the key is the first `X-Forwarded-For` hop — the original
   client, which the GFE makes hard to spoof.)
2. **Deployment-wide enroll budget** — `HEIMDALL_ENROLL_BUDGET_MAX` new enrolls per
   `HEIMDALL_ENROLL_BUDGET_WINDOW` (default **50 / 3600s**), one global counter across
   the fleet. Even rotating through many IPs (or a leaked token), total new enrollments
   per window are capped.
3. **Hard registry-size cap** — `HEIMDALL_ENROLL_MAX_KEYS` (default **1000**). Once the
   key registry reaches the cap, new enrollments are refused outright — the registry
   cannot grow without bound no matter how long an attacker (or a leaked token) churns.
4. **Enrolled keys are presence-only (`owner=False`).** An enrollee gets a plain presence
   identity. It is **not** an owner, cannot dispatch, cannot approve, cannot touch any
   gated route — the public-surface boundary (404s every gated route) and the
   least-privilege SA (no `run.jobs.run`) block everything except presence/roster.
   Enrolling buys **nothing** beyond "appear on the presence wall".
5. **Presence TTL makes spoofed presence ephemeral.** Presence is a TTL'd heartbeat; a
   spoofed-but-valid presence entry **decays on its own** the moment the griefer stops
   beating (and each beat is itself per-IP + per-haid rate-limited and replay-nonce
   checked). There is no durable artifact to clean up.

### Why token mode is the default (the viral/public phase)

In the default token mode `/enroll` is **fail-closed**: without `cp-enroll-token` the
deploy refuses (a dead enroll route), and with it, **only a holder of the token value can
enroll**. The presence wall is therefore an **authenticated attestation** — "someone who
was given the token is online" — not merely advisory. That is the right posture for a
public/viral surface where the URL is reachable by anyone on the internet. The
abuse-control caps (1–3) **still apply on top of the token gate**, so a **leaked** token is
defense-in-depth-bounded: it cannot flood `/enroll` past the per-IP/budget caps nor grow
the registry past the hard cap, and it can never enroll anything but a presence-only
(`owner=False`) identity.

### The residual risk of the OPEN (tokenless) alternative (stated plainly)

The open alternative (`ENROLL_OPEN=1`) is **not zero-risk**, and we do not pretend
otherwise. With a tokenless public enroll, **anyone who can reach the URL can register a
presence identity for a known project** — and a public repo's git-remote is guessable, so
the project key is not a secret. Therefore, in open mode:

> A griefer **can** post **ephemeral, spoofed presence** to a project's presence wall —
> appearing "online" as a fabricated dev. This is **bounded** by the per-IP/budget/
> registry caps (controls 1–3), **non-escalating** (control 4: presence-only,
> `owner=False`, no gated access, no dispatch), and **ephemeral** (control 5: it decays
> via presence TTL). It is **not zero** — the presence wall of an **open** deployment is
> **advisory, not authenticated attestation of who is online**.

That is the deliberate trade for zero-config internal onboarding. **For a public/viral
phase, stay in the default token mode** (the token gate closes exactly this gap). Use open
mode only on an internal deployment that can tolerate advisory presence.

### Switch to open (tokenless) enroll (the zero-config internal alternative)

If you want zero-config onboarding (no token to mint or distribute) and accept the residual
risk above, set `ENROLL_OPEN=1` and redeploy:

```bash
ENROLL_OPEN=1 bash deploy/cloud-run/deploy-public-surface.sh apply
# or via the guided operator:
ENROLL_OPEN=1 bash deploy/cloud-run/go-live.sh
```

This sets `HEIMDALL_ENROLL_OPEN=1` on the service; `cp-enroll-token` becomes **optional**
(mounted for defense-in-depth if it exists, never required). Tokenless enroll now works,
bounded by controls 1–5.

### Flip back to the default token mode

Set `ENROLL_OPEN=0` (or unset it — token mode is the default) and redeploy:

```bash
ENROLL_OPEN=0 bash deploy/cloud-run/deploy-public-surface.sh apply
# or via the guided operator:
ENROLL_OPEN=0 bash deploy/cloud-run/go-live.sh
```

In token mode `cp-enroll-token` is **REQUIRED** (mint it first — RUNBOOK §2.2 — or the
deploy refuses) and is mounted; tokenless enroll is refused; the abuse-control caps (1–3)
still apply on top of the token gate. **Distribute the token out-of-band** (RUNBOOK §8) —
password manager / secrets channel, never in chat or plaintext.

**The boundary and the SA are identical in both modes** — flipping the enroll mode never
relaxes the public-surface 404 boundary, the least-privilege SA, the digest pin, or the
P1–P5 preflights. Only the enroll gate changes.

---

## 3. Public runtime SA + the no-dispatch proof

`deploy-public-surface.sh` **creates** the least-privilege public SA and grants it
exactly `roles/datastore.user` + `secretAccessor` on `cp-enroll-token`. It never
grants `run.jobs.run`. Review the exact SA/IAM/deploy commands with **no spend**:

```bash
bash deploy/cloud-run/deploy-public-surface.sh plan
```

Read the plan output. It must show:

- `PREFLIGHT P1 … P4` lines (P3 prints `WARN … will be ENFORCED at apply` when run
  offline — that is expected; the probe runs for real at `apply`).
- `(NO run.jobs.run / heimdallJobRunner / run.developer granted — public SA cannot dispatch)`.
- `enroll mode = HEIMDALL_ENROLL_OPEN=0 …` and `enroll: TOKEN-GATED (default; HEIMDALL_ENROLL_OPEN
  left UNSET on the deploy) — cp-enroll-token REQUIRED; abuse caps (IP=…, budget=…, registry=…)
  STILL apply` (the caps apply in token mode too; set `ENROLL_OPEN=1` for the open alternative).
- `enroll-token: REQUIRED (token mode) …` — apply mounts `cp-enroll-token` (and the deploy
  refuses if it is absent); in open mode (`ENROLL_OPEN=1`) this reads `OPTIONAL`.

If the public SA already exists from a prior run, prove **now** (before deploy) that
it lacks dispatch — this is the same probe PREFLIGHT P3 enforces at apply:

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${PUBLIC_SA}" \
  --format='value(bindings.role)'
# Expect: roles/datastore.user only (NO roles/run.developer, run.admin, owner, editor,
#         or any custom role granting run.jobs.run). If a dispatch role appears, REMOVE
#         it before deploying — apply will refuse otherwise.
```

---

## 4. Deploy the GATED service (unchanged)

The gated `heimdall-control-plane` is deployed exactly per
[`README.md`](./README.md) §3 — `--no-allow-unauthenticated`, full surface,
`heimdall-cp-run` SA, `HEIMDALL_JOB_RUNNER=cloudrun-job`, `cp-pki-key`,
`HEIMDALL_CP_SERVER_HAID=cp-server`. **This runbook does not change it.** If it is
already live on a current-`main` image, skip to Step 5.

> **The gated service must NOT carry `HEIMDALL_PUBLIC_SURFACE`.** If it did, it
> would 404 its own dispatch/jobs/owner/audit routes. Confirm it is absent:
>
> ```bash
> gcloud run services describe "${GATED_SERVICE}" --region="${REGION}" \
>   --format='value(spec.template.spec.containers[0].env)' \
>   | tr ',' '\n' | grep -q 'HEIMDALL_PUBLIC_SURFACE' \
>   && echo "BROKEN — gated service has HEIMDALL_PUBLIC_SURFACE set; it will 404 its own gated routes. Remove it." \
>   || echo "OK — gated service has NO public-surface flag (serves the full gated surface)"
> ```

---

## 5. Deploy the PUBLIC service (digest-pinned, least-privilege SA, flag)

`deploy-public-surface.sh` pins the **byte-identical immutable image** the gated
service is serving (resolved to a `@sha256:` digest — never a floating tag, never a
from-source build that could diverge). With no `IMAGE` override it auto-resolves the
gated service's current 100%-traffic digest:

```bash
# (Optional) pin an explicit digest instead of auto-resolving the gated service's:
#   export IMAGE="<region>-docker.pkg.dev/${PROJECT_ID}/<repo>/<img>@sha256:<hash>"
# (REQUIRED, per Step 2.3 — verdict (b)) ship the DISTINCT throwaway public seed:
#   export PUBLIC_PKI_SECRET="cp-pki-key-public"

bash deploy/cloud-run/deploy-public-surface.sh apply
```

At `apply` the script:

1. runs **PREFLIGHT P1–P4** (the wrong-service / wrong-SA / real-seed deploys are
   refused; an unverifiable IAM is refused);
2. **resolves and pins the image to an immutable digest** (a non-digest is fatal);
3. creates the least-privilege SA and grants datastore (+ the enroll-token secret
   **only when it is mounted** — present, or required in token mode);
4. deploys `heimdall-cp-public` `--allow-unauthenticated` with
   `HEIMDALL_PUBLIC_SURFACE=1`, `cp-enroll-token` mounted (token mode is the default —
   `HEIMDALL_ENROLL_OPEN` is **left unset**), and the abuse-control caps — per-IP / budget /
   `HEIMDALL_ENROLL_MAX_KEYS` (set in **both** modes). See § Enroll security model for the
   model and the open-mode switch.

Capture the public URL:

```bash
export PUBLIC_URL="$(gcloud run services describe "${PUBLIC_SERVICE}" \
  --region="${REGION}" --format='value(status.url)')"
echo "${PUBLIC_URL}"
```

---

## 6. REQUIRED GATE — run before any token distribution (STOP if it fails)

### 6.1 The consistency guard (script ⇄ docs ⇄ route-set parity)

```bash
bash deploy/cloud-run/check-public-surface.sh
# Expect: "check-public-surface: PASS" (exit 0)
```

**STOP if this fails.** It asserts the canonical public route set
(`POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz`) is
byte-identical across the deploy script, [`README.md`](./README.md), and the
server's enforced contract; that **no gated route leaked into the public set**; and
that the public deploy grants **no dispatch role** and always sets
`HEIMDALL_PUBLIC_SURFACE=1` + `--allow-unauthenticated`.

### 6.2 The public SA provably lacks dispatch (live IAM, the layer-2 proof)

```bash
ROLES="$(gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${PUBLIC_SA}" \
  --format='value(bindings.role)')"
echo "${ROLES}"
echo "${ROLES}" | grep -Eq 'run\.developer|run\.admin|roles/owner|roles/editor' \
  && echo "STOP — public SA holds a dispatch-capable role" \
  || echo "OK — public SA holds no obvious dispatch role"
```

**STOP if a dispatch-capable role appears.** (PREFLIGHT P3 would have refused the
deploy; this re-verifies the live grant after the fact.)

### 6.3 Flag isolation (the flag is on PUBLIC, absent on GATED)

```bash
# PUBLIC must HAVE the flag:
gcloud run services describe "${PUBLIC_SERVICE}" --region="${REGION}" \
  --format='value(spec.template.spec.containers[0].env)' \
  | tr ',' '\n' | grep -q 'HEIMDALL_PUBLIC_SURFACE=1' \
  && echo "OK — public service has HEIMDALL_PUBLIC_SURFACE=1" \
  || echo "STOP — public service is MISSING the flag (it would serve the full gated surface!)"

# GATED must NOT have the flag (re-check from Step 4):
gcloud run services describe "${GATED_SERVICE}" --region="${REGION}" \
  --format='value(spec.template.spec.containers[0].env)' \
  | tr ',' '\n' | grep -q 'HEIMDALL_PUBLIC_SURFACE' \
  && echo "STOP — gated service has the flag; it will 404 its own gated routes" \
  || echo "OK — gated service has NO public-surface flag"
```

**STOP if either check fails.**

---

## 7. LIVE verification — the boundary holds end-to-end (both must pass)

Both of these must pass **before** distributing the enroll token.

### 7.1 A gated route is 404 on the PUBLIC surface (app-layer boundary)

A `POST /dispatch` to the public service must return **404** — the route does not
resolve/parse/authenticate on the public surface (indistinguishable from a
nonexistent route; not a 401/403 that would reveal it exists):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "${PUBLIC_URL}/dispatch" \
  -H 'Content-Type: application/json' -d '{}'
# Expect: 404   (anything else — especially 200/401/403 — means the boundary leaked: STOP)
```

Confirm the public surface itself is alive:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "${PUBLIC_URL}/healthz"   # Expect: 200
```

### 7.2 The GATED service still DEMANDS the IAM token (Cloud Run edge)

An **unauthenticated** request (no ID token) to the gated service must be rejected
at the Cloud Run edge — proof `--no-allow-unauthenticated` is intact:

```bash
export GATED_URL="$(gcloud run services describe "${GATED_SERVICE}" \
  --region="${REGION}" --format='value(status.url)')"

curl -s -o /dev/null -w '%{http_code}\n' -X POST "${GATED_URL}/dispatch" \
  -H 'Content-Type: application/json' -d '{}'
# Expect: 401 or 403 (Cloud Run IAM rejects the missing bearer at the edge).
#         A 200/404 means the gated service is NOT IAM-protected: STOP.

# Sanity: WITH a valid bearer it gets past the edge (reaches the app, which then
# applies its own PKI auth — a non-edge status such as 401-from-app / 400 / 200):
curl -s -o /dev/null -w '%{http_code}\n' -X POST "${GATED_URL}/dispatch" \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  -H 'Content-Type: application/json' -d '{}'
# Expect: NOT a Cloud Run edge 403 — the bearer cleared the edge.
```

> The gated edge returns `403` (IAM denies an unauthorized/missing identity); some
> configurations return `401`. Either confirms the IAM wall is up. The decisive
> signal is that the **unauthenticated** call is rejected and the **bearer** call
> is not rejected *at the edge*.

---

## 8. Distribute the enroll token (out-of-band)

Only after Steps 6–7 pass. Devs need two things to bootstrap:

1. **The public URL** — `${PUBLIC_URL}` (safe to share; it is the
   `--allow-unauthenticated` surface). A dev exports it and the presence client
   resolves it: `export HEIMDALL_CP_URL="${PUBLIC_URL}"`.
2. **The enroll token VALUE** — the `cp-enroll-token` secret. **Never** commit it,
   paste it into chat logs, or email it in plaintext. Distribute it out-of-band
   (a password manager / secrets-sharing channel). Read it for distribution with:

   ```bash
   gcloud secrets versions access latest --secret=cp-enroll-token   # hand off out-of-band; do not log
   ```

Operators keep pointing their tools at the **gated** service:

```bash
export BASE_URL="$(gcloud run services describe "${GATED_SERVICE}" \
  --region="${REGION}" --format='value(status.url)')"
```

A first-run dev hits `POST /enroll` (token-gated) on the public service, registers
their key, then beats `POST /presence` and reads `GET /roster`. Dispatch/jobs 404
on the public surface — those live on the gated service behind IAM.

---

## 9. Rollback / teardown

### 9.1 Roll the public service back a revision (fast, reversible)

```bash
gcloud run revisions list --service="${PUBLIC_SERVICE}" --region="${REGION}"
gcloud run services update-traffic "${PUBLIC_SERVICE}" --region="${REGION}" \
  --to-revisions="<PREVIOUS_REVISION>=100"
```

### 9.2 Disable the public surface immediately (kill switch)

Lock the public service behind IAM (the public surface stops being reachable
without a bearer; the gated service is untouched):

```bash
gcloud run services update "${PUBLIC_SERVICE}" --region="${REGION}" \
  --no-allow-unauthenticated
```

Devs lose zero-config enroll/presence until re-opened; nothing sensitive is
exposed because dispatch/jobs never lived on the public surface.

### 9.3 Full teardown of the public service (the gated service survives)

```bash
gcloud run services delete "${PUBLIC_SERVICE}" --region="${REGION}"

# Remove the least-privilege SA's grants, then the SA (datastore + the enroll secret):
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/datastore.user"
gcloud secrets remove-iam-policy-binding cp-enroll-token \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/secretmanager.secretAccessor"
gcloud iam service-accounts delete "${PUBLIC_SA}"
```

The gated `heimdall-control-plane`, its `heimdall-cp-run` SA, `cp-pki-key`, and the
`heimdall-long-job` Job are **not** touched by any teardown step here.

---

## Go-live checklist (every box before token distribution)

- [ ] Gated service live on a current-`main` immutable image (README §3–§4).
- [ ] Enroll mode chosen: **token** (default — `HEIMDALL_ENROLL_OPEN` unset, `cp-enroll-token` REQUIRED + mounted; the recommended public/viral posture) or the **open** alternative (`ENROLL_OPEN=1` — tokenless, `cp-enroll-token` OPTIONAL, see § Enroll security model; residual risk of open mode acknowledged — ephemeral spoofed presence, bounded + non-escalating). Abuse caps (per-IP / budget / registry) apply in **both** modes.
- [ ] `cp-enroll-token` secret created (REQUIRED in the default token mode); distinct throwaway `cp-pki-key-public` seed provisioned under a distinct HAID — never the real `cp-pki-key` (Step 2.3, verdict (b)).
- [ ] `deploy-public-surface.sh plan` reviewed — P1–P4 present, no dispatch role granted.
- [ ] `deploy-public-surface.sh apply` succeeded; image pinned to a `@sha256:` digest.
- [ ] **GATE:** `check-public-surface.sh` → PASS (Step 6.1).
- [ ] **GATE:** public SA provably lacks any dispatch role (Step 6.2).
- [ ] **GATE:** flag on PUBLIC, absent on GATED (Step 6.3).
- [ ] **LIVE:** `POST /dispatch` on public → **404** (Step 7.1).
- [ ] **LIVE:** unauthenticated `POST /dispatch` on gated → **401/403** at the edge (Step 7.2).
- [ ] Enroll token + public URL distributed out-of-band (Step 8).
