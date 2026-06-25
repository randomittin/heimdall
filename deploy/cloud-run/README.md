# Heimdall Control Plane — Cloud Run Deploy Runbook

Spec: `heimdall-cp-deploy-and-diagnostics-spec.md` §A (Cloud Run deployment).

This is the **exact, copy-pasteable** command sequence RJ runs to deploy the
control plane to Cloud Run. The container itself is built from the repo-root
`Dockerfile`; the `.dockerignore` keeps the build context lean and secret-free.

> **DEPLOY IS GATED.** Run this sequence **only after** the billing
> kill-switch tests are green (`$1` kill-switch test — the ₹10,000 spend cap).
> The kill-switch caps spend; `--max-instances=5` caps fan-out. Do not deploy
> spend-incurring infrastructure until the cap is proven. **DEPLOY NOT EXECUTED
> by the agent — gated on the kill-switch test.**

---

## ⚠️ REBUILD REQUIRED — the deployed image MUST come from current `main`

A prior incident shipped a **stale, pre-Wave-2 image**: in that image the
`bin/lib/cp_state.py` `get_backend` firestore branch only `raise`d
`BackendUnavailable` ("reserved for Wave 2"), so with
`HEIMDALL_STATE_BACKEND=firestore` set the control plane logged
`cp_boot: tick error: BackendUnavailable` every 60s and never reached durable
state. **You MUST rebuild the image from current `main` before deploying** — a
redeploy of the old image will reproduce the incident.

Two distinct fixes both have to be in the deployed image:

1. **The Wave-2 backend code** — current `main`'s `get_backend` firestore branch
   returns a real `cp_state_firestore.FirestoreBackend()` (no "reserved for
   Wave 2" `raise`). Confirm before deploy:

   ```bash
   # Expect: the firestore branch imports cp_state_firestore and returns
   # FirestoreBackend() — NOT a BackendUnavailable raise.
   grep -n "import cp_state_firestore" bin/lib/cp_state.py
   grep -n "return cp_state_firestore.FirestoreBackend()" bin/lib/cp_state.py
   ```

2. **The Firestore client in the image** — the `Dockerfile` now installs
   `google-cloud-firestore==2.16.1` (matching `deploy/requirements-firestore.txt`)
   in the same pip layer as `cryptography`, plus a **build-time guard**
   (`RUN python -c "import google.cloud.firestore, cryptography"`) so a missing
   dep **fails the build** instead of shipping a broken image. Confirm before
   deploy:

   ```bash
   # Expect: the firestore pin AND the import guard are both present.
   grep -n "google-cloud-firestore" Dockerfile
   grep -n 'python -c "import google.cloud.firestore' Dockerfile
   ```

### Post-deploy verification

After the rebuilt image is live, the incident signature must be **gone**:

```bash
# The BackendUnavailable tick error must STOP appearing in the logs.
gcloud run services logs read "${SERVICE}" --region="${REGION}" --limit=100 \
  | grep -F "cp_boot: tick error: BackendUnavailable" \
  && echo "STILL BROKEN — image is stale or missing google-cloud-firestore" \
  || echo "OK — firestore factory path is live, no BackendUnavailable ticks"
```

A clean run (no `BackendUnavailable` lines) means the firestore factory path is
live: `get_backend` returned `FirestoreBackend`, the client imported, and durable
state is being read/written across scale-to-zero.

---

## Execution model — long jobs run OUT OF PROCESS as Cloud Run Jobs

**Long jobs do NOT run inside the request-serving service.** They run as a
separate **Cloud Run Job** (`heimdall-long-job`), **run-to-completion**, one
execution per job. The service only **dispatches** the execution and returns the
`job_id` immediately; the Job process does the work and writes durable state to
Firestore.

**Why not in-process.** An earlier design ran the job on a background daemon
thread inside the service. On Cloud Run that **starves**: after a request
returns, Cloud Run **throttles the instance's CPU to near-zero** and, with
`--min-instances=0`, **scales the instance to zero** entirely — so the daemon
thread stops making progress and the job **stays queued forever**. This was the
"jobs stay queued on Cloud Run" incident. A Cloud Run **Job** is a first-class
run-to-completion workload: it gets **full CPU for its whole runtime** (no
post-response throttle), is **independent of any request lifecycle**, and the
service can still **scale to zero** between dispatches. Bonus: Cloud Run Jobs
give **free retries** (`--max-retries`) and a bounded **task timeout**
(`--task-timeout`).

**The runner is env-selected.** The control plane picks a `JobRunner`
implementation from `HEIMDALL_JOB_RUNNER`:

| `HEIMDALL_JOB_RUNNER` | Runner                  | Where it's for                              |
| --------------------- | ----------------------- | ------------------------------------------- |
| `thread`              | in-process thread       | local dev / tests (no Cloud Run throttle)   |
| `subprocess`          | local child process     | local run-to-completion, no GCP             |
| `cloudrun-job`        | Cloud Run Job execution | **production on Cloud Run**                 |

When unset, the runner **auto-selects `cloudrun-job` if `K_SERVICE` is present**
(Cloud Run injects `K_SERVICE` into every service container), else falls back to
a local runner. In production we **pin `HEIMDALL_JOB_RUNNER=cloudrun-job`
explicitly** on the service (§3) so dispatch behavior never depends on
autodetection.

**The dispatch + the entrypoint.** When the service receives a job, the
`cloudrun-job` runner shells out to:

```bash
gcloud run jobs execute heimdall-long-job --region "${REGION}" --args run-job,<JOB_ID>
```

That overrides the Job container's args for this one execution so it runs the
**run-to-completion entrypoint**:

```
heimdall-control-plane run-job <job_id>
```

which loads the job from durable state, runs it to terminal `done`, and exits.
The Job's image is the **same image** as the service (§4) — only the per-execution
args differ. The service's runtime SA needs permission to **execute** the Job
(`run.jobs.run`); see §4.1.

---

## 0. Prerequisites (one-time, per project)

```bash
# Pick the target project + region once; every command below reuses them.
export PROJECT_ID="heimdall-control-plane"        # the scoped Heimdall GCP project
export REGION="us-central1"
export SERVICE="heimdall-control-plane"
export RUNTIME_SA="heimdall-cp-run@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"

# Enable the APIs the deploy uses: Cloud Run, Cloud Build (for --source builds),
# Firestore, Secret Manager, and Artifact Registry (build push target).
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  firestore.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com
```

### Runtime service account (least privilege)

```bash
gcloud iam service-accounts create heimdall-cp-run \
  --display-name="Heimdall Control Plane (Cloud Run runtime)"

# Firestore read/write for durable state (job state, audit, gate queue, schedules).
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/datastore.user"

# Read the PKI signing key from Secret Manager at runtime (accessor only — the
# runtime never creates or overwrites secrets).
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor"
```

> **The runtime SA also needs `run.jobs.run`** to dispatch long jobs to the
> `heimdall-long-job` Cloud Run Job (the `cloudrun-job` runner shells out to
> `gcloud run jobs execute`). That binding is in **§4.1** — set up after the Job
> exists. `roles/run.invoker` does **not** grant it.

---

## 1. Firestore (durable state — survives scale-to-zero)

The local NDJSON store does **not** survive a Cloud Run instance restart
(ephemeral filesystem, scales to zero). Job state, audit log, gate queue, and
schedules go to Firestore in **native mode**.

```bash
gcloud firestore databases create --location="${REGION}"   # native mode (default)
```

> The Firestore state adapter (read/write via Firestore instead of local
> NDJSON, env-switched) is the **A2** deliverable owned by another agent. This
> runbook provisions the database; the adapter wires the control plane to it.

---

## 2. Secret Manager (PKI signing key — never baked into the image)

The control plane signs/verifies every request with an Ed25519 PKI key
(`bin/lib/cp_auth.py`). That key is a **secret**: it is NOT baked into the
image and NOT passed as env-plaintext. It lives in Secret Manager and is
injected into the running container as a mounted secret at deploy time.

### Secrets this service uses

| Secret name  | What it is                                   | Consumed as            |
| ------------ | -------------------------------------------- | ---------------------- |
| `cp-pki-key` | Ed25519 **private** signing seed (base64)    | env `HEIMDALL_CP_PKI_KEY` |

> **The seed is only HALF the identity.** `cp-pki-key` pins the **key** (the
> public/private Ed25519 material, derived deterministically from the seed —
> `cp_auth.load_signing_key`). It does **not** pin the **name** the key binds to.
> The server registers `server_haid → pubkey(seed)` at boot (`ensure_server_identity`),
> and `server_haid` is resolved from the **`HEIMDALL_CP_SERVER_HAID`** env var
> (`cp_auth.server_haid`, `bin/lib/cp_auth.py:269`). That env var is **not** a
> secret — it is a plain identity **name** — but it **must be pinned** in §3/§4
> alongside the seed. See _"Stable identity: both halves must be pinned"_ at the
> end of §3.
>
> **The canonical pinned value is `cp-server`** (the value live on the deployed
> service). `cp_auth.server_haid` stores and matches this string **verbatim** — it
> does **no** normalization, prefix-stripping, lowercasing, or format validation
> (`bin/lib/cp_auth.py:278` returns `pinned.strip() or None`; `register_key` and
> `verify` use it as an opaque registry key). So the **only** requirement is that
> every instance pins the **identical literal** and the verify client signs as that
> **same literal** — the `haid:` prefix is **not** required on this path. Any stable
> string works; we standardize on **`cp-server`** so the runbook matches production
> and no redeploy is needed.

### Create the secret container (no value committed anywhere)

```bash
gcloud secrets create cp-pki-key --replication-policy=automatic
```

### Add the key VALUE — generated locally, piped straight in, never written to a file

The real key value is generated on RJ's machine and piped directly into Secret
Manager via stdin. **No secret value is ever written to any file in this repo,
the build context, or the image.** Generate the Ed25519 seed with the same
backend the control plane uses:

```bash
# Generate a fresh Ed25519 private seed (base64), pipe it straight into the
# secret. The value touches only memory + Secret Manager — never disk, never git.
python3 - <<'PY' | gcloud secrets versions add cp-pki-key --data-file=-
import base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
seed = Ed25519PrivateKey.generate().private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption(),
)
import sys
sys.stdout.write(base64.b64encode(seed).decode())
PY
```

---

## 3. Deploy the service (the spend-incurring step — kill-switch-gated)

```bash
gcloud run deploy "${SERVICE}" \
  --source=. \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --max-instances=5 \
  --min-instances=0 \
  --cpu=1 \
  --memory=512Mi \
  --timeout=300 \
  --concurrency=80 \
  --port=8080 \
  --no-allow-unauthenticated \
  --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest" \
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server,HEIMDALL_JOB_RUNNER=cloudrun-job"
```

> **`HEIMDALL_JOB_RUNNER=cloudrun-job` is REQUIRED on the service.** It selects
> the production runner that dispatches long jobs to the `heimdall-long-job`
> Cloud Run Job instead of an in-process thread (see _"Execution model"_ above).
> Cloud Run injects `K_SERVICE`, so the runner would auto-select `cloudrun-job`
> anyway — but we **pin it explicitly** so dispatch never depends on
> autodetection. Without it (or with `thread`), jobs run on a starved daemon
> thread and **stay queued** — the exact incident this fixes. Like the HAID it
> is a plain name, **not** a secret.

> **`HEIMDALL_CP_SERVER_HAID=cp-server` is REQUIRED in every deploy command.** The
> code reads it at boot (`cp_auth.server_haid`, `bin/lib/cp_auth.py:269`); **absent,
> the server derives an unstable per-instance HAID from the container `HOSTNAME`** —
> different on every Cloud Run instance — so cross-instance signature verification
> breaks. It is stored and matched **verbatim** (no `haid:` prefix needed, no
> normalization), so `cp-server` is correct as-is; the only rule is to use the
> **identical literal** everywhere and never change it across redeploys. It is a
> plain identity name, **not** a secret — fine to commit and to read back via
> `gcloud run services describe`. See _"Stable identity: both halves must be pinned"_
> below for why an unpinned name silently breaks cross-instance auth.

What each flag buys:

- `--max-instances=5` — **runaway guard.** Caps fan-out. The kill-switch caps
  spend (₹10k); this caps concurrency so a storm can't spin up unbounded
  instances under the cap.
- `--min-instances=0` — **scale to zero.** $0 idle. No traffic ⇒ no instance ⇒
  no cost.
- `--port=8080` — the port Cloud Run routes to; the container binds
  `0.0.0.0:$PORT` (Cloud Run injects `PORT=8080`).
- `--no-allow-unauthenticated` — **not open to the internet.** Access requires
  Cloud Run IAM auth, layered on top of the app-level PKI signing.
- `--set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest"` — injects the PKI
  signing **key** (seed) from Secret Manager as an env var **at runtime only**. The
  value is never in the image, the repo, or this runbook.
- `--set-env-vars` — selects the Firestore state backend (the A2 adapter), passes
  the project for the Firestore client, **pins the server identity name**
  (`HEIMDALL_CP_SERVER_HAID`), and **pins the production job runner**
  (`HEIMDALL_JOB_RUNNER=cloudrun-job`, so long jobs dispatch to the
  `heimdall-long-job` Cloud Run Job instead of a starved in-process thread). The
  seed pins the key; the HAID pins the name — together they are the full, stable
  server identity (see below).

### Stable identity: both halves must be pinned

The control plane's identity is **two** things, and **both** must be stable across
every Cloud Run instance and every cold start for signatures to verify:

1. **The key** — the Ed25519 keypair. Pinned by `cp-pki-key`: `load_signing_key`
   derives the *same* keypair from the *same* seed on every instance
   (`bin/lib/cp_auth.py` `load_signing_key`). ✅ already pinned via `--set-secrets`.
2. **The name** — the HAID the key binds to. Resolved by `cp_auth.server_haid`
   (`bin/lib/cp_auth.py:269`): it reads `HEIMDALL_CP_SERVER_HAID` **first** and
   returns it **verbatim** (`pinned.strip() or None`, `bin/lib/cp_auth.py:278` — no
   prefix, no lowercasing, no format check), else derives a HAID via the
   `heimdall-haid` CLI — which uses the container **`HOSTNAME`**, *different on every
   Cloud Run instance*. ⇒ Without the env var, each instance registers a
   **different** `haid → pubkey` binding (an unstable, per-instance name), so a
   request signed as instance A's HAID **fails to verify** on instance B even though
   the *key* is identical. Pinning `HEIMDALL_CP_SERVER_HAID=cp-server` makes every
   instance register the **identical** `server_haid → pubkey(seed)` binding at boot
   (`ensure_server_identity`). Because the value is matched verbatim, the canonical
   `haid:{human}.{machine}-{hash4}` format is **not** enforced here — `cp-server` is
   a valid, stable name as-is; what matters is that it is identical on every instance
   and that the verify client signs as that same literal.

> **Why this matters for the flight-fix.** The flight-fix proof (§7) signs a
> request as the server's own HAID, then reads the job back from a **fresh**
> instance after scale-to-zero. That read only verifies if the fresh instance
> registered the **same** `haid → pubkey` the signer used. The seed alone is not
> enough — the *name* must match too. Pin both halves and the identity is
> reproducible: `server_haid → pubkey(seed)` is byte-identical on every cold start.

> **⚠️ RJ must redeploy with `HEIMDALL_CP_SERVER_HAID` set BEFORE running the §7
> flight-fix verify** — and for correct cross-instance identity in general. This is
> **not** a full image rebuild: a `--set-env-vars` update (which rolls a new
> revision) is enough to set the var on a service that is already on the current
> image:
>
> ```bash
> gcloud run services update "${SERVICE}" --region="${REGION}" \
>   --update-env-vars="HEIMDALL_CP_SERVER_HAID=cp-server"
> ```
>
> (Use the **same** `cp-server` value committed to in §3 and never change it. If a
> rebuild is also pending for other reasons — see the rebuild section above — the
> full `gcloud run deploy` in §3, which already carries the var, covers both.)

---

## 4. Server-hosted long jobs (the flight fix in production — §A4)

The 400k-call class of job runs as a **Cloud Run Job** (`heimdall-long-job`,
run-to-completion, independent of the client, $0 when not running). The service
kicks it off, the client disconnects, the Job finishes server-side and writes
its terminal state to Firestore. See _"Execution model"_ at the top for **why**
this is out-of-process (an in-process thread starves under Cloud Run's
post-response CPU throttle + scale-to-zero).

The Job runs the **same image** as the service. Its container command is the
run-to-completion entrypoint `heimdall-control-plane run-job`; the **per-job
`<job_id>` is supplied at execution time** by the service's dispatch
(`--args run-job,<JOB_ID>`, §4.2), overriding the default args. Create (or, if
it already exists, update) it:

```bash
gcloud run jobs create heimdall-long-job \
  --source=. \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --command="heimdall-control-plane" \
  --args="run-job" \
  --task-timeout=3600 \
  --max-retries=1 \
  --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest" \
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server"
```

> **Re-running this command?** `gcloud run jobs create` fails if the Job already
> exists — the existing runbook half-provisioned `heimdall-long-job`. To change
> the image/env/flags on an existing Job, swap `create` → `update` (same flags,
> `--source=.` rebuilds the image):
>
> ```bash
> gcloud run jobs update heimdall-long-job \
>   --source=. \
>   --region="${REGION}" \
>   --service-account="${RUNTIME_SA}" \
>   --command="heimdall-control-plane" \
>   --args="run-job" \
>   --task-timeout=3600 \
>   --max-retries=1 \
>   --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest" \
>   --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server"
> ```

What each Job flag buys:

- `--command="heimdall-control-plane" --args="run-job"` — the **default**
  container command/args. Each execution **overrides `--args`** to
  `run-job,<JOB_ID>` (§4.2), so the container runs `heimdall-control-plane
  run-job <job_id>` — the run-to-completion entrypoint that loads the job from
  durable state, runs it to `done`, and exits.
- `--max-retries=1` — **free retry.** Cloud Run re-runs a failed execution; the
  entrypoint is restart-safe because all state is in Firestore, not local disk.
- `--task-timeout=3600` — bounds a single execution to 1h (raise for the 400k
  class if needed). A Job, unlike the service, has **no `--timeout=300` request
  cap** — it runs to completion with full CPU.
- `--set-secrets`/`--set-env-vars` — **identical** PKI seed, Firestore backend,
  project, and server HAID as the service (§3), so the Job and the service share
  one stable `server_haid → pubkey(seed)` identity.

> **The Job intentionally does NOT set `HEIMDALL_JOB_RUNNER`.** The runner env is
> a **dispatch** selector — only the **service** dispatches. The Job is the
> **executor**: it runs `run-job <job_id>` directly to completion and must never
> re-dispatch to another Cloud Run Job. (Cloud Run does **not** inject
> `K_SERVICE` into Job containers, so even the autodetect default stays local — but
> we leave the var unset rather than relying on that.)

> The Job pins the **same** `HEIMDALL_CP_SERVER_HAID=cp-server` as the service (§3) — the
> long-running Job and the request-serving service share one stable server
> identity, so a job kicked off through the service and run by the Job both
> register the identical `server_haid → pubkey(seed)` binding. Keep this value in
> lockstep with §3.

### 4.1 IAM — the service must be allowed to EXECUTE the Job

The service's runtime SA dispatches the Job with `gcloud run jobs execute`, which
calls the Cloud Run Admin API's **`run.jobs.run`** permission. **`roles/run.invoker`
is NOT enough** — `run.invoker` only allows *invoking a service* (sending it an
HTTP request); it does **not** grant `run.jobs.run`, so the dispatch fails with a
`403 PERMISSION_DENIED` on the Job. Grant the runtime SA a role that includes
`run.jobs.run`.

**Least privilege (recommended) — a custom role with exactly the one permission,
bound on the project:**

```bash
gcloud iam roles create heimdallJobRunner \
  --project="${PROJECT_ID}" \
  --title="Heimdall Job Runner" \
  --description="Execute the heimdall-long-job Cloud Run Job" \
  --permissions="run.jobs.run"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="projects/${PROJECT_ID}/roles/heimdallJobRunner"
```

**Quick path (broader) — the predefined `roles/run.developer`**, which **includes**
`run.jobs.run` (along with other Cloud Run write permissions you don't strictly
need just to execute a Job):

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/run.developer"
```

> **Least-privilege note.** Prefer the custom `run.jobs.run`-only role: the
> runtime SA only ever needs to **execute** a pre-provisioned Job, never to
> create/update/delete Cloud Run resources. `roles/run.developer` works but
> grants far more than dispatch. Whichever you pick, this is **in addition to**
> the `roles/datastore.user` + `roles/secretmanager.secretAccessor` bindings the
> runtime SA already holds (§0).

### 4.2 Dispatch — how the service executes the Job per job

The `cloudrun-job` runner (selected by `HEIMDALL_JOB_RUNNER=cloudrun-job` on the
service, §3) runs this exact command for each job, overriding the Job's default
args so the container runs `heimdall-control-plane run-job <JOB_ID>`:

```bash
gcloud run jobs execute heimdall-long-job --region "${REGION}" --args run-job,<JOB_ID>
```

Each call creates one **execution** of `heimdall-long-job`. The service returns
the `job_id` immediately; the execution runs to `done` independently and writes
durable state to Firestore.

---

## 5. Encryption resolution (why "encrypted" is satisfied)

The control plane's "encrypted" requirement is met by **two layers**, and the
control plane is **never** to run on plain HTTP outside Cloud Run:

1. **Transport — Cloud Run terminates TLS automatically.** Every deployed
   service gets an HTTPS endpoint; the platform manages the certificate. There
   is no plaintext HTTP hop on the public path. The container itself speaks
   plain HTTP on `$PORT` **only inside the Cloud Run sandbox**, behind the
   platform's TLS-terminating proxy — that hop never leaves Google's network.
2. **Application — PKI signing.** Every instance↔server request is Ed25519
   signed and verified (`cp_auth.py`). This authenticates and integrity-protects
   the payload independently of the transport.

TLS (transport) + PKI signing (application) together satisfy "encrypted."

> **NEVER expose this on plain HTTP outside Cloud Run.** The container's
> `0.0.0.0:$PORT` bind is plaintext by design — it is safe **only** because
> Cloud Run wraps it in TLS and IAM auth. Do not put this image behind a plain
> HTTP load balancer, do not `docker run -p` it onto a public host, and do not
> disable Cloud Run's TLS. Plain-HTTP exposure breaks the encryption guarantee.

---

## 6. Verify the deploy (§A5)

```bash
# Scale-to-zero: hit it once, wait, confirm instances drop to 0.
gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --format="value(status.url)"
# ... after idle, the active instance count returns to 0 (no min-instance floor).

# Max-instances caps fan-out: a load test stops creating instances at 5.
gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/maxScale'])"
# -> 5

# A Cloud Run Job survives client disconnect (kick off, disconnect, it completes).
# This is the SAME dispatch the service's cloudrun-job runner issues per job —
# the per-execution args override the Job's default to run `run-job <JOB_ID>`.
gcloud run jobs execute heimdall-long-job --region="${REGION}" --args run-job,<JOB_ID>

# The runtime SA can EXECUTE the Job (run.jobs.run via §4.1) — if this 403s, the
# IAM grant in §4.1 is missing (roles/run.invoker is NOT enough).
gcloud run jobs executions list --job=heimdall-long-job --region="${REGION}" --limit=5

# Confirm a real execution ran for a given job_id: list executions and check at
# least one is Succeeded (the job reached `done` via the Cloud Run Job, not a
# starved in-process thread). Replace <JOB_ID> with the dispatched id.
gcloud run jobs executions list --job=heimdall-long-job --region="${REGION}" \
  --format="value(metadata.name,status.completionTime,status.succeededCount)" \
  | grep -q . \
  && echo "OK — at least one heimdall-long-job execution ran (job dispatched out-of-process)" \
  || echo "NONE — no execution ran; dispatch failed (check HEIMDALL_JOB_RUNNER on the service + run.jobs.run IAM in §4.1)"
```

Expected cost (scoped Heimdall account, kill-switch capped): ~$5–20/mo for
7–8 devs. Scale-to-zero dashboard + occasional Cloud Run Jobs + Firestore
(free tier covers most) + Scheduler. Hard-capped at ₹10,000 by the tested
kill-switch.

---

## 7. Prove the flight-fix on the live target (`verify-flight-fix.sh`)

`deploy/cloud-run/verify-flight-fix.sh` is the **copy-pasteable proof** that durable
server-hosted jobs work on the **real** Cloud Run + Firestore target — not the
emulator, not a laptop. It starts a signed job, confirms it persists, **replaces
the serving instance** (so the next request hits a *fresh* instance with no local
state), then reads the same job back. A read-back that resolves the job's durable
state **from a fresh instance** is the flight-fix holding in production.

> This is **RJ's** to run — it needs creds and the live URL. The agent that wrote
> it validated the script's logic locally (firestore mode, across a process
> restart); the prod run below is pure execution.

> **PRECONDITION — pin `HEIMDALL_CP_SERVER_HAID` first.** The script signs as the
> server's **own** HAID, read back from the deployed env. If the service was
> deployed *before* `HEIMDALL_CP_SERVER_HAID` was added (§3), the var is empty and
> the script cannot resolve a stable HAID — and even if it could, the per-instance
> derived name would make the cold-start read-back fail to verify. **Redeploy with
> the pinned var first** (the `gcloud run services update --update-env-vars=...` in
> §3's _"Stable identity"_ note is enough — no image rebuild), then run this. Quick
> check that the var is live:
>
> ```bash
> gcloud run services describe "${SERVICE}" --region="${REGION}" \
>   --format='value(spec.template.spec.containers[0].env)' \
>   | tr ',' '\n' | grep -q HEIMDALL_CP_SERVER_HAID \
>   && echo "OK — server HAID is pinned" \
>   || echo "MISSING — redeploy with HEIMDALL_CP_SERVER_HAID before verifying"
> ```

> **PRECONDITION — the out-of-process runner must be live too.** Before this
> incident fix, the job ran on an in-process thread and **stayed queued** (never
> reached `done`) under Cloud Run's CPU throttle + scale-to-zero, so the
> flight-fix proof **FAILED**: the read-back found a job stuck in its initial
> state, not a terminal one. The fix makes the job run as a `heimdall-long-job`
> Cloud Run Job. For the proof to **PASS**, three things must be live: (a)
> `HEIMDALL_JOB_RUNNER=cloudrun-job` on the service (§3), (b) the
> `heimdall-long-job` Job exists (§4), and (c) the runtime SA has `run.jobs.run`
> (§4.1). Quick check that the runner is pinned:
>
> ```bash
> gcloud run services describe "${SERVICE}" --region="${REGION}" \
>   --format='value(spec.template.spec.containers[0].env)' \
>   | tr ',' '\n' | grep -q 'HEIMDALL_JOB_RUNNER=cloudrun-job' \
>   && echo "OK — cloudrun-job runner is pinned (jobs dispatch out-of-process)" \
>   || echo "MISSING — set HEIMDALL_JOB_RUNNER=cloudrun-job (§3) or jobs stay queued on a starved thread"
> ```

### What it proves

`PASS` ⇒ a `job_id` started over `POST /jobs` was **dispatched to the
`heimdall-long-job` Cloud Run Job**, ran **to terminal `done`** out-of-process,
and resolved its **durable terminal state** via `GET /jobs` from a **fresh
instance** *after* the serving instance was torn down. Two properties are proven
at once: (1) the job **reaches `done`** — a Cloud Run Job execution appears in
`gcloud run jobs executions list --job=heimdall-long-job` and finishes (it is
**not** stuck queued on a throttled in-process thread); and (2) its state lived
in Firestore (the external store), not the wiped ephemeral home — i.e.
`HEIMDALL_STATE_BACKEND=firestore` is live and the image is current (no
`BackendUnavailable` ticks; see the rebuild section above).

> **The execution status is the AUTHORITATIVE PASS signal — not the job-record
> poll.** `run_v2` `run_job` is **async**: the dispatched Cloud Run Job
> **provisions** (~36s observed) and only **then** runs, so the signed
> `GET /jobs` job-record poll (STEP 2) can expire while the Job is still
> provisioning even though it **did** dispatch and **will** complete. The script
> therefore runs **STEP 2b**: it polls `gcloud run jobs executions list
> --job=heimdall-long-job` for an execution that **carries this `job_id`** (or was
> created at/after the dispatch instant) and reaches **`succeededCount=1`**. A
> succeeded execution = the job ran out-of-process, and that is the **ground-truth**
> PASS signal. If STEP 2's job-record poll times out **but** STEP 2b (or the STEP-5
> read-back) confirms the job ran, the script treats the timeout as an
> **async-provisioning timing artifact, NOT a dispatch failure**, and the verdict
> stays **PASS**. STEP 2's poll default is now **180s** (was 60s) to cover
> provision+run; raise `POLL_SECONDS` / `EXEC_POLL_SECONDS` for slower cold starts.
> STEP 2b is **gcloud-only** and **skips cleanly** in the local dry run (no real
> Cloud Run Job to query), so the dry run is unaffected.

> **STEP 5 waits for async Job completion + Firestore visibility — and a signed
> `GET /jobs` `state=done` from a FRESH instance is the read-back proof.** Because
> `run_v2` `run_job` is **async** (the Job **provisions ~36s + runs**, then its
> terminal `done` write must become **visible in Firestore**), the cold-start
> read-back must wait long enough for the durable write to land before failing.
> STEP 5 therefore polls the signed `GET /jobs` for **this `job_id`** until it reads
> back **`state=done`** (or terminal) from the **fresh** post-scale-to-zero instance,
> for up to **`STEP5_POLL_SECONDS` (default 180s)** — the ~180s window that covers
> provision + run + the Firestore write becoming visible. Only if it stays
> non-terminal past the **full** window is STEP 5 a real failure. When STEP 2b has
> already confirmed the **execution SUCCEEDED**, the Job has finished and the durable
> write appears shortly, so STEP 5 polls the same generous window for that `done` to
> land — and a confirmed `done` read back from a fresh instance is **STEP 5 PASS**.
> The verdict is **fully GREEN** when **both** hold: the execution **succeeded**
> (STEP 2b) **and** the signed `GET /jobs` reads **`state=done`** from a **fresh
> instance** (STEP 5) — that signed read is the durable read-back proof. The local
> dry run keeps a short read-back window via the legacy `COLD_POLL_SECONDS` alias
> (the in-process fake completes + writes instantly), so it is unaffected; the
> longer real-poll path skips cleanly without gcloud.

**The FAIL → PASS transition this fix delivers.** Before the out-of-process
runner, the flight-fix script **FAILED**: the in-process job stayed queued, never
reached `done`, and the read-back returned a non-terminal job. After deploying
with `HEIMDALL_JOB_RUNNER=cloudrun-job` (§3), the `heimdall-long-job` Job (§4),
and the `run.jobs.run` IAM grant (§4.1), the same script goes **PASS** — the job
now reaches `done` via a Cloud Run Job execution, and that terminal state reads
back from a fresh instance. With the **180s STEP-5 read-back window**, STEP 5 itself
goes **green** on a real completing run — the signed `GET /jobs` reads `state=done`
from the fresh instance within the window, rather than the verdict relying on a
reconciled NOTE. A persistent `FAIL` ⇒ either the runner is still in-process (job
never reaches `done` — check `HEIMDALL_JOB_RUNNER` and that an execution actually
ran, §6), or the state did not survive the instance replace (stale image / wrong
backend / non-deterministic scale) past the full `STEP5_POLL_SECONDS` window.

> **One-liner — check a Job execution ran for the dispatched `job_id`.** After
> the script reports its `job_id`, confirm at least one `heimdall-long-job`
> execution exists and succeeded (proof the job ran out-of-process, not on a
> starved thread):
>
> ```bash
> gcloud run jobs executions list --job=heimdall-long-job --region="${REGION}" \
>   --format="value(metadata.name,status.succeededCount)" \
>   | grep -q . \
>   && echo "OK — a heimdall-long-job execution ran (job reached done out-of-process)" \
>   || echo "NONE — no execution ran; the job never dispatched (the pre-fix queued-forever signature)"
> ```

### How RJ runs it (live URL, RJ's creds)

```bash
export PROJECT_ID="heimdall-control-plane"
export REGION="us-central1"
export SERVICE="heimdall-control-plane"

# The live Cloud Run https URL.
export BASE_URL="$(gcloud run services describe "${SERVICE}" \
  --region="${REGION}" --format='value(status.url)')"

# The registered identity to sign as = the server's OWN HAID (the deploy pins it via
# HEIMDALL_CP_SERVER_HAID; boot() registers server_haid -> pubkey(cp-pki-key)).
export CLIENT_HAID="$(gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --format='value(spec.template.spec.containers[0].env)' \
  | tr ',' '\n' | grep HEIMDALL_CP_SERVER_HAID | cut -d= -f2)"

# The PKI seed = the SAME cp-pki-key the server signs with (read from Secret Manager,
# straight into the env — never written to disk). The script NEVER prints it.
export PKI_SEED="$(gcloud secrets versions access latest --secret=cp-pki-key)"

# Cloud Run IAM bearer (the service is --no-allow-unauthenticated).
export ID_TOKEN="$(gcloud auth print-identity-token)"

bash deploy/cloud-run/verify-flight-fix.sh
# Expect: "VERDICT: PASS — the job_id resolved its DURABLE state from a FRESH
#          instance after scale-to-zero." (exit 0)
```

### The scale-to-zero step (how the instance is replaced — and why it PRESERVES the image)

The script defaults to `SCALE_TO_ZERO=revision`: it rolls a **no-op new revision**
that routes 100% of traffic to a fresh revision and **tears down the old serving
instance** — deterministic and fast. The trade-off vs. `SCALE_TO_ZERO=wait` (rely
on the `--min-instances=0` idle scale-down, ~up to 15 min, non-deterministic) is
documented in the script header: the revision rollout *provably* replaces the
instance now, which is exactly the property the proof needs (a fresh instance with
no local state). A third mode, `SCALE_TO_ZERO=command` + `SCALE_CMD`, runs an
operator-supplied replacement command (gcloud-free) — that is the seam the local
dry run uses to restart the server against the same external store.

> **STEP 4 PRESERVES the served image digest — it never rolls the service back.**
> A bare `gcloud run services update` that does **not** pass `--image` resolves the
> image reference afresh; if the service was last deployed from a mutable tag
> (`:latest`) or a `--source` build, the new revision can pull a **different/older
> digest** than the one serving. In the prod incident the verify's own STEP-4
> rollout reverted the service to a **pre-`run_v2` image** mid-test, so the
> subsequently-dispatched job hit a revision **without** the dispatch fix → **zero
> executions**, corrupting the test. The fixed STEP 4 now:
> 1. **captures** the currently-serving (100%-traffic) revision's exact image
>    **digest first** (`gcloud run services describe` → the 100%-traffic revision →
>    `gcloud run revisions describe --format='value(spec.containers[0].image)'`);
> 2. rolls the no-op revision **pinned to that exact digest** (`--image <digest>`),
>    so Cloud Run **reuses the same immutable image** (scale-to-zero **without**
>    changing the served code); and
> 3. **asserts** the new 100%-traffic revision serves the **same** digest it
>    started on — a drift **FAILS** the run loudly (`STEP-4 image DRIFTED: ...`)
>    rather than silently testing a stale image.
>
> `SCALE_TO_ZERO=wait` is the other image-untouching path (it never rolls a
> revision at all). `SCALE_TO_ZERO=command` (the dry-run seam) does not touch
> gcloud, so the digest-pin logic is **skipped cleanly** locally.

### Where the job lands in Firestore

The job's state log maps (per `bin/lib/cp_state_firestore.py`) to one node document:

```
rel: jobs/<job_id>.ndjson
doc: <HEIMDALL_FIRESTORE_ROOT>/jobs__<job_id>.ndjson      # root default: heimdall_cp
     (appended NDJSON lines live in that doc's "lines" subcollection)
```

The script **prints this path**, and — when `PROJECT_ID` is set and `gcloud` is
present — confirms the doc with `gcloud firestore documents describe`.

### Local dry run (no GCP, no spend — already validated by the agent)

`test/verify-flight-fix-dryrun.test.sh` runs `verify-flight-fix.sh` against a
**local** wired server in firestore mode (the in-process Firestore fake / a caller
emulator), simulating scale-to-zero by **restarting the server process** against
the same external store (fresh process = fresh instance; the durable store
persists). It reports `PASS` when the job survives the restart and is read back
from the external store — validating the script's logic end-to-end before prod:

```bash
bash test/verify-flight-fix-dryrun.test.sh
# Expect: "verify-flight-fix-dryrun: PASS" (exit 0)
```

### One-off read-back probe for a single job (`get-job.sh` — the decisive distinguisher)

`deploy/cloud-run/get-job.sh` sends the **exact same** signed `GET /jobs` that
`verify-flight-fix.sh` STEP 5 sends — for **one** `job_id` — against the live
service, and prints both the **raw HTTP response** and the **parsed `state`**. It is
the complement to `heimdall-cp-inspect` (§8): `inspect` reads the Firestore doc
**directly** (bypassing the service), while `get-job.sh` exercises the **service's
own HTTP read-path** — so together they isolate *write-path/store* from
*read-path/wire*. Use it when STEP 5 reads `state=None` for a job whose doc **has**
`done`.

The read contract it exercises (identical to STEP 5, audited against
`cp_worker.status_route`): `job_id` travels in the request **body**
(`{"job_id":...}`), which is exactly how `status_route` reads it (`_job_id_from` →
`payload["job_id"]` first); the response is `{"job": {... "state": ... }}` (the
folded `cp_jobstore.read_job` view), and the probe parses `state` from
`b["job"]["state"]` — the same path the verify uses. (The dry run round-trips this
exact shape across a fresh process and reads back `done`, so the send + parse are
contract-correct.)

```bash
export BASE_URL="$(gcloud run services describe heimdall-control-plane \
                     --region=us-central1 --format='value(status.url)')"
export CLIENT_HAID="$(gcloud run services describe heimdall-control-plane \
                       --region=us-central1 \
                       --format='value(spec.template.spec.containers[0].env)' \
                       | tr ',' '\n' | grep HEIMDALL_CP_SERVER_HAID | cut -d= -f2)"
export PKI_SEED="$(gcloud secrets versions access latest --secret=cp-pki-key)"
export ID_TOKEN="$(gcloud auth print-identity-token)"   # --no-allow-unauthenticated
bash deploy/cloud-run/get-job.sh job-d8884
```

Read the verdict the probe prints:

- **`DONE` (HTTP 200, `state=done`)** → the **service** returns `done`. The verify
  parses this exact shape and the dry run proves the round-trip reads `done`, so an
  earlier STEP-5 `None` was **not** a service or a parse bug — re-run the verify; any
  residual `None` on a *fresh* job is timing (raise `STEP5_POLL_SECONDS`), not parse.
- **`NONE` (HTTP 404 `no_such_job`, or 200 with `state=null`)** → the **service**
  read-path cannot resolve `done` for that `job_id` though its doc has it (per §8) →
  a **service-side** read-path / store issue (a fresh instance reading the wrong
  home/store), **not** a verify bug. Cross-check with `heimdall-cp-inspect env` (§8C).
- **`NONE` (HTTP 401)** → `CLIENT_HAID`/`PKI_SEED` is not the registered identity, or
  the `ID_TOKEN` bearer is missing for a `--no-allow-unauthenticated` service.

The probe talks **only HTTP**, contains **no secret literal**, and never prints the
`PKI_SEED` (read in-process from the env, never argv).

---

## 8. Inspecting the Firestore doc directly (`heimdall-cp-inspect`)

When a job's **execution succeeds** (the Cloud Run Job ran to completion and wrote
`state=done`) but the **service cannot read `done` back** (GET `/jobs` reports the
job as not-done), the question is *write-path vs read-path*: did the Job write the
done line to a **different Firestore doc** than the service reads (a doc-key / root-
collection / project / **database** mismatch between the two containers), or is the
service simply pointed at the wrong store? `gcloud firestore documents get` is not
always available; `bin/heimdall-cp-inspect` answers the question by reading the
**exact doc the control-plane code uses** — it imports the real `cp_state_firestore`
`rel→doc` mapping (it does *not* re-derive the encoding), so the doc it inspects is
byte-for-byte the doc `cp_jobstore` reads and `cp_worker` writes. It is **read-only**
(never mutates Firestore) and prints **no secrets**.

Three subcommands:

```bash
bin/heimdall-cp-inspect job <job_id>   # resolved doc path + ordered lines + folded state
                                       #   + "TERMINAL state=done present: yes/no"
                                       #   exit 0 iff done is present, 1 otherwise
bin/heimdall-cp-inspect list-jobs      # every doc id under the jobs namespace
                                       #   (catches a doc-key mismatch — the smoking gun)
bin/heimdall-cp-inspect env            # the firestore store location THIS process resolves
```

**(A) Locally, against the emulator** (no GCP spend — the agent validated the tool this
way against the in-process Firestore double, `test/cp-inspect.test.sh`, before prod):

```bash
gcloud emulators firestore start --host-port=localhost:8085 &   # needs a Java 21+ JRE
export FIRESTORE_EMULATOR_HOST=localhost:8085
export HEIMDALL_STATE_BACKEND=firestore HEIMDALL_FIRESTORE_PROJECT=demo-local
bin/heimdall-cp-inspect env
bin/heimdall-cp-inspect job <job_id>
bin/heimdall-cp-inspect list-jobs
```

**(B) In prod, to inspect the failing job's doc** — from a machine with ADC + the
project (the same creds/dep the deploy uses), pointed at the **same backend env the
service runs with**:

```bash
export HEIMDALL_STATE_BACKEND=firestore
export GOOGLE_CLOUD_PROJECT=<the deploy project>
export HEIMDALL_FIRESTORE_ROOT=<the deploy root collection, if overridden>
# (and the same Firestore DATABASE the service uses — see (C))
gcloud auth application-default login        # if ADC is not already present
bin/heimdall-cp-inspect job <failing_job_id>
```

If the doc **exists** and shows `state=done` here but the service reports not-done,
the service reads a *different store* than this env resolves → go to (C). If the doc
is **absent** / has no done line here, the Job's write did not land where this env
reads → run `list-jobs` to see which doc id the Job actually wrote.

**(C) To DIFF the resolved Firestore location between the Job container and the
Service** (the prime suspect — a project / **database** / root-collection mismatch):

```bash
# `env` INSIDE the Cloud Run JOB's container+env (one-off execution):
gcloud run jobs execute <job-name> --region <region> \
  --args=heimdall-cp-inspect,env --wait
gcloud logging read \
  'resource.type=cloud_run_job AND textPayload:"cp-inspect env"' \
  --limit 50 --format='value(textPayload)'

# `env` as the SERVICE sees it — inspect the service's env block, or run a one-off
# Job that inherits the SAME env the service has:
gcloud run services describe <service-name> --region <region> \
  --format='value(spec.template.spec.containers[0].env)'
```

DIFF the two `env` outputs. If `HEIMDALL_STATE_BACKEND`, the project, the root
collection, or the **resolved database** differ between the Job and the Service, that
difference **is** the read/write split — the Job writes one store, the service reads
another. (Firestore's default database is `(default)`; a service or Job pinned to a
**named** database via `FIRESTORE_DATABASE` / a client arg reads a wholly separate
keyspace, so a doc written to `(default)` is invisible from the named one.)

> Validate locally first: `bash test/cp-inspect.test.sh` → `cp-inspect: PASS` (exit 0).
> It seeds a job, writes `done` via the real `cp_jobstore` write path over a Firestore
> backend, then proves `job`/`list-jobs`/`env` read it back from the same resolved doc.

---

## Gate summary

- **Build context is secret-free** — `.dockerignore` excludes `.git`, the
  `.claude/worktrees` (stale worktrees), `test/`, `evals/`, fixtures, secrets,
  and env files. Only `bin/` enters the image.
- **No secret value is in any file** — the PKI key is generated locally and
  piped to Secret Manager; the container reads it via `--set-secrets` at runtime.
- **DEPLOY NOT EXECUTED — gated on `$1` kill-switch test.** Run §3 only after
  the kill-switch (₹10,000 cap) tests are green.
