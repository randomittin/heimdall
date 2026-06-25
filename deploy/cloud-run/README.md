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
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID}"
```

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
  signing key from Secret Manager as an env var **at runtime only**. The value
  is never in the image, the repo, or this runbook.
- `--set-env-vars` — selects the Firestore state backend (the A2 adapter) and
  passes the project for the Firestore client.

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
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID}"
```

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

## Gate summary

- **Build context is secret-free** — `.dockerignore` excludes `.git`, the
  `.claude/worktrees` (stale worktrees), `test/`, `evals/`, fixtures, secrets,
  and env files. Only `bin/` enters the image.
- **No secret value is in any file** — the PKI key is generated locally and
  piped to Secret Manager; the container reads it via `--set-secrets` at runtime.
- **DEPLOY NOT EXECUTED — gated on `$1` kill-switch test.** Run §3 only after
  the kill-switch (₹10,000 cap) tests are green.
