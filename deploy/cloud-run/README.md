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
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=haid:heimdall.cp-prod-0001"
```

> **`HEIMDALL_CP_SERVER_HAID` pins the server's identity NAME — choose one value
> and keep it constant forever.** Here it is `haid:heimdall.cp-prod-0001` (a plain
> identity name, **not** a secret — fine to commit and to read back via
> `gcloud run services describe`). RJ picks this value **once** and **never changes
> it** across redeploys. See _"Stable identity: both halves must be pinned"_ below
> for why an unpinned name silently breaks cross-instance auth.

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
  the project for the Firestore client, and **pins the server identity name**
  (`HEIMDALL_CP_SERVER_HAID`). The seed pins the key; this pins the name — together
  they are the full, stable server identity (see below).

### Stable identity: both halves must be pinned

The control plane's identity is **two** things, and **both** must be stable across
every Cloud Run instance and every cold start for signatures to verify:

1. **The key** — the Ed25519 keypair. Pinned by `cp-pki-key`: `load_signing_key`
   derives the *same* keypair from the *same* seed on every instance
   (`bin/lib/cp_auth.py` `load_signing_key`). ✅ already pinned via `--set-secrets`.
2. **The name** — the HAID the key binds to. Resolved by `cp_auth.server_haid`
   (`bin/lib/cp_auth.py:269`): it reads `HEIMDALL_CP_SERVER_HAID` **first**, else
   derives a HAID via the `heimdall-haid` CLI — which uses the container
   **`HOSTNAME`**, *different on every Cloud Run instance*. ⇒ Without the env var,
   each instance registers a **different** `haid → pubkey` binding (an unstable,
   per-instance name), so a request signed as instance A's HAID **fails to verify**
   on instance B even though the *key* is identical. Pinning
   `HEIMDALL_CP_SERVER_HAID` makes every instance register the **identical**
   `server_haid → pubkey(seed)` binding at boot (`ensure_server_identity`).

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
>   --update-env-vars="HEIMDALL_CP_SERVER_HAID=haid:heimdall.cp-prod-0001"
> ```
>
> (Choose the **same** value you committed to in §3 and never change it. If a
> rebuild is also pending for other reasons — see the rebuild section above — the
> full `gcloud run deploy` in §3, which already carries the var, covers both.)

---

## 4. Server-hosted long jobs (the flight fix in production — §A4)

The 400k-call class of job runs as a **Cloud Run Job** (run-to-completion,
independent of the client, $0 when not running). Client kicks it off,
disconnects, the job finishes server-side.

```bash
gcloud run jobs create heimdall-long-job \
  --source=. \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --task-timeout=3600 \
  --max-retries=1 \
  --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest" \
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=haid:heimdall.cp-prod-0001"
```

> The Job pins the **same** `HEIMDALL_CP_SERVER_HAID` as the service (§3) — the
> long-running Job and the request-serving service share one stable server
> identity, so a job kicked off through the service and run by the Job both
> register the identical `server_haid → pubkey(seed)` binding. Keep this value in
> lockstep with §3.

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
gcloud run jobs execute heimdall-long-job --region="${REGION}"
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

### What it proves

`PASS` ⇒ a `job_id` started over `POST /jobs` resolved its **durable terminal
state** via `GET /jobs` from a **fresh instance** *after* the serving instance was
torn down. The only way that read succeeds is if the state lived in Firestore (the
external store), not the wiped ephemeral home — i.e. `HEIMDALL_STATE_BACKEND=firestore`
is live and the image is current (no `BackendUnavailable` ticks; see the rebuild
section above). `FAIL` ⇒ the state did **not** survive the instance replace
(stale image / wrong backend / non-deterministic scale).

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

### The scale-to-zero step (how the instance is replaced)

The script defaults to `SCALE_TO_ZERO=revision`: it rolls a **no-op new revision**
(`gcloud run services update --revision-suffix=flightfix-<stamp> --update-env-vars=...`),
which routes 100% of traffic to a new revision and **tears down the old serving
instance** — deterministic and fast. The trade-off vs. `SCALE_TO_ZERO=wait` (rely
on the `--min-instances=0` idle scale-down, ~up to 15 min, non-deterministic) is
documented in the script header: the revision rollout *provably* replaces the
instance now, which is exactly the property the proof needs (a fresh instance with
no local state). A third mode, `SCALE_TO_ZERO=command` + `SCALE_CMD`, runs an
operator-supplied replacement command (gcloud-free) — that is the seam the local
dry run uses to restart the server against the same external store.

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

---

## Gate summary

- **Build context is secret-free** — `.dockerignore` excludes `.git`, the
  `.claude/worktrees` (stale worktrees), `test/`, `evals/`, fixtures, secrets,
  and env files. Only `bin/` enters the image.
- **No secret value is in any file** — the PKI key is generated locally and
  piped to Secret Manager; the container reads it via `--set-secrets` at runtime.
- **DEPLOY NOT EXECUTED — gated on `$1` kill-switch test.** Run §3 only after
  the kill-switch (₹10,000 cap) tests are green.
