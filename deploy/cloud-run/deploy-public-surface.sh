#!/usr/bin/env bash
# deploy-public-surface.sh — DEPLOY THE SECOND CLOUD RUN SERVICE: the PUBLIC
# presence/enroll surface (`heimdall-cp-public`), from the SAME image as the gated
# control plane, but `--allow-unauthenticated` and locked to a LEAST-PRIVILEGE SA.
#
# THE SECURITY PROBLEM THIS SOLVES. The control plane (`heimdall-control-plane`) is
# deployed `--no-allow-unauthenticated` (README §3) — Cloud Run IAM 401s any request
# without a bearer token. That is correct for dispatch/jobs/approvals/owner/audit, but
# it means a NEW dev with no `gcloud` and no IAM grant cannot even reach POST /enroll to
# bootstrap their key. Zero-config presence is impossible behind the IAM wall.
#
# THE FIX — SPLIT THE SURFACE INTO TWO SERVICES from ONE image:
#   • heimdall-control-plane  (existing, UNCHANGED) — --no-allow-unauthenticated, FULL
#     gated surface, full-privilege runtime SA (datastore + secrets + run.jobs.run).
#   • heimdall-cp-public      (THIS script)          — --allow-unauthenticated, PUBLIC
#     surface ONLY {POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz},
#     LEAST-PRIVILEGE SA (datastore + the two secrets it needs, NO run.jobs.run / NO
#     dispatch IAM).
#
# DEFENSE IN DEPTH — the public boundary is enforced at BOTH layers, independently:
#   1. APP LAYER  — HEIMDALL_PUBLIC_SURFACE=1 makes the server serve ONLY the public
#      route set and HARD-REFUSE (404, as if nonexistent) every gated route
#      (dispatch/jobs/approval/owner/audit/scheduler/...). Implemented in the server by
#      the core-boundary work; this script only SETS the env var.
#   2. IAM/SA LAYER — the public service runs as `heimdall-cp-public-run`, a SA that
#      has NO `run.jobs.run` and NO Cloud Run dispatch role. The long-job dispatch path
#      (the `cloudrun-job` runner shelling `gcloud run jobs execute`) calls run.jobs.run;
#      without it, EVEN A SERVER BUG that exposed /dispatch on the public service CANNOT
#      kick off a Cloud Run Job — the execute call 403s. The public SA literally cannot
#      run a job.
# Either layer alone refuses dispatch; both together is the belt-and-braces boundary.
#
# WHY THE PUBLIC SERVICE STILL NEEDS SECRETS. Two of the five public routes are not
# free-for-all:
#   • POST /presence + GET /roster are PKI-SIGNED (verified against the key registry) —
#     the service needs HEIMDALL_CP_PKI_KEY to verify dev signatures and to register its
#     own stable server identity at boot (cp_auth.ensure_server_identity).
#   • POST /enroll is TOKEN-GATED, fail-closed — the service needs HEIMDALL_ENROLL_TOKEN
#     (the `cp-enroll-token` secret) to verify the bootstrap token; absent, enroll
#     refuses every request (cp_enroll.server_enroll_token() -> None -> enroll_disabled).
# So the public service is allowed to READ exactly those two secrets — granted at the
# SECRET RESOURCE level (per-secret IAM), NOT project-wide, so it cannot read any other
# secret the project holds.
#
# THE CLIENTS. The dev's `heimdall-presence` client points at THIS public service URL
# (HEIMDALL_CP_URL / BASE_URL = the heimdall-cp-public URL). RJ's operator tools
# (get-job.sh, verify-flight-fix.sh, heimdall-cp-inspect) keep pointing at the GATED
# heimdall-control-plane URL — they exercise dispatch/jobs, which the public surface 404s.
#
# THIS SCRIPT IS IDEMPOTENT. The SA + IAM steps no-op if already present; the deploy
# rolls a new revision. It DEPLOYS (spend-incurring) only in `apply` mode; the default
# `plan` mode PRINTS the exact commands and exits 0 without touching the project, so it
# is safe to run for review (and in the doc-consistency check). Run `apply` only after
# the §3 kill-switch gate, exactly like the gated deploy.
#
# stdlib gcloud only; no secret VALUE ever touches this script, the repo, or the image.

set -euo pipefail

# ── THE CANONICAL PUBLIC ROUTE SET (single source of truth) ──────────────────────────
# This MUST stay byte-identical to the route set documented in README.md's split section
# and to the {POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz}
# contract the server's HEIMDALL_PUBLIC_SURFACE gate enforces. check-public-surface.sh
# asserts this exact line appears verbatim in the README — a drift FAILS the check.
PUBLIC_SURFACE_ROUTES="POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz"

# ── config (every value overridable from the env; defaults match README §0) ──────────
PROJECT_ID="${PROJECT_ID:-heimdall-control-plane}"
REGION="${REGION:-us-central1}"
GATED_SERVICE="${GATED_SERVICE:-heimdall-control-plane}"   # the existing IAM-gated service
PUBLIC_SERVICE="${PUBLIC_SERVICE:-heimdall-cp-public}"     # the service THIS script deploys
PUBLIC_SA_NAME="${PUBLIC_SA_NAME:-heimdall-cp-public-run}" # least-privilege runtime SA
PUBLIC_SA="${PUBLIC_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
PKI_SECRET="${PKI_SECRET:-cp-pki-key}"                     # Ed25519 seed (README §2)
ENROLL_SECRET="${ENROLL_SECRET:-cp-enroll-token}"          # enroll bootstrap-token verifier
SERVER_HAID="${HEIMDALL_CP_SERVER_HAID:-cp-server}"        # the SAME pinned name as §3
# The image to deploy. Default: build from source (--source=.) like §3. Set IMAGE to an
# exact digest to pin the public service to the SAME immutable image the gated service
# serves (the recommended path — see "Pin the same image" in the README split section).
IMAGE="${IMAGE:-}"

MODE="${1:-plan}"   # plan (default, no-op print) | apply (deploy — spend-incurring)

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
run()  { say "+ $*"; [ "$MODE" = "apply" ] && "$@"; return 0; }
die()  { printf '\033[31mFATAL\033[0m %s\n' "$*" >&2; exit 2; }

case "$MODE" in
  plan|apply) ;;
  *) die "usage: $0 [plan|apply]  (plan = print only; apply = deploy — spend-incurring)";;
esac

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — install the Cloud SDK"

say "==> heimdall-cp-public deploy (${MODE} mode)"
say "    project=${PROJECT_ID} region=${REGION} public-service=${PUBLIC_SERVICE}"
say "    public SA=${PUBLIC_SA} (LEAST PRIVILEGE — no run.jobs.run, no dispatch IAM)"
say "    public surface = {${PUBLIC_SURFACE_ROUTES}}  (HEIMDALL_PUBLIC_SURFACE=1)"

# ── 1. the least-privilege runtime SA (create if absent) ─────────────────────────────
# Distinct from the gated service's heimdall-cp-run. This SA is granted ONLY what the
# public surface needs: Firestore (presence heartbeats + roster reads + enroll registry)
# and read access to the two secrets it consumes. It is NEVER granted run.jobs.run /
# heimdallJobRunner / roles/run.developer — so it cannot dispatch a Cloud Run Job.
if [ "$MODE" = "apply" ] && gcloud iam service-accounts describe "${PUBLIC_SA}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  say "    SA ${PUBLIC_SA} already exists — skipping create"
else
  run gcloud iam service-accounts create "${PUBLIC_SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Heimdall CP PUBLIC surface (presence/enroll/health — least privilege)"
fi

# Firestore read/write — presence is External-keyed on the StateBackend seam (durable
# across scale-to-zero), and enroll writes the bootstrapped pubkey to the key registry.
run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" \
  --role="roles/datastore.user"

# Secret access — granted at the SECRET RESOURCE level (NOT project-wide), so the public
# SA can read ONLY these two secrets and no other secret in the project.
run gcloud secrets add-iam-policy-binding "${PKI_SECRET}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" \
  --role="roles/secretmanager.secretAccessor"
run gcloud secrets add-iam-policy-binding "${ENROLL_SECRET}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" \
  --role="roles/secretmanager.secretAccessor"

# DELIBERATELY ABSENT: run.jobs.run / heimdallJobRunner / roles/run.developer.
# The public SA gets NO Cloud Run Job execution permission — the IAM half of the boundary.
say "    (NO run.jobs.run / heimdallJobRunner / run.developer granted — public SA cannot dispatch)"

# ── 2. resolve the image to deploy ───────────────────────────────────────────────────
# The public service runs the SAME image as the gated service. Two paths:
#   (a) IMAGE pinned to an exact digest (recommended) — byte-identical to the gated image.
#   (b) IMAGE unset — build from --source=. (must be the SAME commit as the gated deploy).
if [ -n "${IMAGE}" ]; then
  say "    image: PINNED digest ${IMAGE} (same immutable image as the gated service)"
  IMAGE_FLAG=(--image "${IMAGE}")
else
  say "    image: --source=. (Cloud Build — deploy from the SAME commit as the gated service)"
  IMAGE_FLAG=(--source=.)
fi

# ── 3. deploy the PUBLIC service ─────────────────────────────────────────────────────
# Same resource envelope as §3 (max-instances caps fan-out, scale-to-zero idle), but:
#   • --allow-unauthenticated   — reachable with NO Cloud Run IAM bearer (zero-config dev).
#   • --service-account public SA — the least-privilege identity (cannot dispatch).
#   • HEIMDALL_PUBLIC_SURFACE=1  — the APP-LAYER gate: serve public routes, 404 the rest.
#   • HEIMDALL_ENROLL_TOKEN      — from cp-enroll-token, so token-gated enroll can verify.
# NOTE: HEIMDALL_JOB_RUNNER is intentionally NOT set — the public surface 404s /dispatch
# and /jobs, so the runner is never reached; and even if it were, the missing run.jobs.run
# IAM blocks the execute. The two layers are independent.
run gcloud run deploy "${PUBLIC_SERVICE}" \
  "${IMAGE_FLAG[@]}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --service-account="${PUBLIC_SA}" \
  --max-instances=5 \
  --min-instances=0 \
  --cpu=1 \
  --memory=512Mi \
  --timeout=300 \
  --concurrency=80 \
  --port=8080 \
  --allow-unauthenticated \
  --set-secrets="HEIMDALL_CP_PKI_KEY=${PKI_SECRET}:latest,HEIMDALL_ENROLL_TOKEN=${ENROLL_SECRET}:latest" \
  --set-env-vars="HEIMDALL_PUBLIC_SURFACE=1,HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=${SERVER_HAID}"

if [ "$MODE" = "apply" ]; then
  PUBLIC_URL="$(gcloud run services describe "${PUBLIC_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
  say "==> heimdall-cp-public is live at: ${PUBLIC_URL}"
  say "    point heimdall-presence at it:  export HEIMDALL_CP_URL=\"${PUBLIC_URL}\""
  say "    operator tools keep pointing at the GATED ${GATED_SERVICE} URL."
else
  say "==> plan only — nothing deployed. Re-run with: $0 apply   (after the §3 kill-switch gate)"
fi
