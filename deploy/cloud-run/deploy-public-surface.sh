#!/usr/bin/env bash
# deploy-public-surface.sh — DEPLOY THE SECOND CLOUD RUN SERVICE: the PUBLIC
# presence/enroll surface (`heimdall-cp-public`), from the SAME immutable image as the
# gated control plane, but `--allow-unauthenticated` and locked to a LEAST-PRIVILEGE SA.
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
#     LEAST-PRIVILEGE SA (datastore + the secret(s) it needs, NO run.jobs.run / NO
#     dispatch IAM).
#
# DEFENSE IN DEPTH — the public boundary is enforced at BOTH layers, independently:
#   1. APP LAYER  — HEIMDALL_PUBLIC_SURFACE=1 makes the server serve ONLY the public
#      route set and HARD-REFUSE (404, as if nonexistent) every gated route
#      (dispatch/jobs/approval/owner/audit/scheduler/...). Implemented in the server by
#      the core-boundary work; this script only SETS the env var — and ONLY on the public
#      service (it REFUSES to target the gated service, see PREFLIGHT P1).
#   2. IAM/SA LAYER — the public service runs as a NEW least-privilege SA that has NO
#      `run.jobs.run` and NO Cloud Run dispatch role. The long-job dispatch path (the
#      `cloudrun-job` runner shelling `gcloud run jobs execute`) calls run.jobs.run;
#      without it, EVEN A SERVER BUG that exposed /dispatch on the public service CANNOT
#      kick off a Cloud Run Job — the execute call 403s. The public SA literally cannot
#      run a job. The PREFLIGHT below makes deploying under the dispatch-capable SA
#      IMPOSSIBLE (hard refusal), not merely discouraged.
# Either layer alone refuses dispatch; both together is the belt-and-braces boundary.
#
# WHY THE PUBLIC SERVICE STILL NEEDS A SECRET. POST /enroll is TOKEN-GATED, fail-closed —
# the service needs HEIMDALL_ENROLL_TOKEN (the `cp-enroll-token` secret) to verify the
# bootstrap token; absent, enroll refuses every request (cp_enroll.server_enroll_token()
# -> None -> enroll_disabled). It is granted at the SECRET RESOURCE level (per-secret IAM),
# NOT project-wide, so it cannot read any other secret the project holds.
#
# THE SERVER PKI SEED IS *NOT* SHIPPED TO THE PUBLIC SERVICE BY DEFAULT. The real server
# identity seed (`cp-pki-key`) stays SERVER-ONLY on the gated service. The public surface
# verifies dev signatures against the per-dev key registry (Firestore), and no public route
# mints a server-signed artifact — so the internet-facing service holds the MINIMUM. This
# default is the verdict to confirm against the PKI-need audit
# (.planning/ref/public-surface-pki-need.md). IF that audit concludes the public service
# needs a seed ONLY to boot, set PUBLIC_PKI_SECRET to a DISTINCT THROWAWAY secret (never
# the real cp-pki-key) and a DISTINCT PUBLIC_SERVER_HAID — the conditional path below wires
# exactly that and REFUSES to reuse the gated server identity. See the GO-LIVE-RUNBOOK.
#
# THIS SCRIPT IS IDEMPOTENT. The SA + IAM steps no-op if already present; the deploy
# rolls a new revision. It DEPLOYS (spend-incurring) only in `apply` mode; the default
# `plan` mode PRINTS the exact commands and exits 0 without touching the project, so it
# is safe to run for review. Run `apply` only after the §3 kill-switch gate.
#
# stdlib gcloud only; no secret VALUE ever touches this script, the repo, or the image.

set -euo pipefail

# ── THE CANONICAL PUBLIC ROUTE SET (single source of truth) ──────────────────────────
# This MUST stay byte-identical to the route set documented in README.md's split section,
# the GO-LIVE-RUNBOOK, and the {POST /enroll, POST /presence, GET /roster, GET /healthz,
# GET /readyz} contract the server's HEIMDALL_PUBLIC_SURFACE gate enforces.
# check-public-surface.sh asserts this exact line appears verbatim in the README.
PUBLIC_SURFACE_ROUTES="POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz"

# ── config (every value overridable from the env; defaults match README §0) ──────────
PROJECT_ID="${PROJECT_ID:-heimdall-control-plane}"
REGION="${REGION:-us-central1}"
GATED_SERVICE="${GATED_SERVICE:-heimdall-control-plane}"   # the existing IAM-gated service
PUBLIC_SERVICE="${PUBLIC_SERVICE:-heimdall-cp-public}"     # the service THIS script deploys
PUBLIC_SA_NAME="${PUBLIC_SA_NAME:-heimdall-cp-public-run}" # least-privilege runtime SA
PUBLIC_SA="${PUBLIC_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
# The gated service's dispatch-capable runtime SA (README §0). The public surface must
# NEVER run as this identity — PREFLIGHT P2 hard-refuses if PUBLIC_SA resolves to it.
GATED_SA="${GATED_SA:-heimdall-cp-run@${PROJECT_ID}.iam.gserviceaccount.com}"
ENROLL_SECRET="${ENROLL_SECRET:-cp-enroll-token}"          # enroll bootstrap-token verifier
# CONDITIONAL server-PKI seed for the public service. DEFAULT EMPTY = no PKI seed shipped
# (the real cp-pki-key stays SERVER-ONLY). Set ONLY if the PKI-need audit says the public
# service needs a boot seed — and then to a DISTINCT THROWAWAY secret, never `cp-pki-key`.
PUBLIC_PKI_SECRET="${PUBLIC_PKI_SECRET:-}"
GATED_PKI_SECRET="${GATED_PKI_SECRET:-cp-pki-key}"         # the real server identity seed
# The gated server identity NAME (README §3). When a throwaway public seed IS shipped, the
# public service MUST register a DISTINCT name so its boot identity can never clobber the
# gated `cp-server -> pubkey(real-seed)` binding in the shared registry.
SERVER_HAID="${HEIMDALL_CP_SERVER_HAID:-cp-server}"
PUBLIC_SERVER_HAID="${PUBLIC_SERVER_HAID:-cp-public-server}"
# The image to deploy. The public service runs the SAME immutable image as the gated
# service, PINNED BY DIGEST (image@sha256:...). NEVER a floating tag, never a from-source
# build (which would diverge from the gated image). Unset => apply resolves and pins the
# gated service's currently-serving digest. A tag => apply resolves it to its digest.
IMAGE="${IMAGE:-}"

MODE="${1:-plan}"   # plan (default, no-op print) | apply (deploy — spend-incurring)
DISPATCH_ROLE=""    # set by probe_dispatch_iam when a dispatch-capable role is found

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$*" >&2; }
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

# ── PREFLIGHT — the dangerous mistakes are made IMPOSSIBLE here, not just documented ──
# P1/P2 are pure string checks (always enforced, no creds). P3 probes live IAM: a found
# dispatch role is fatal in BOTH modes; an UNVERIFIABLE IAM (no creds/unreachable) is fatal
# in `apply` (we never deploy the public surface without the no-dispatch proof) and a
# warning in `plan` (review can run offline).

# Return: 0 = no dispatch role; 1 = HAS a dispatch role (sets DISPATCH_ROLE); 2 = could not check.
probe_dispatch_iam() {
  local roles r perms
  roles="$(gcloud projects get-iam-policy "${PROJECT_ID}" \
            --flatten='bindings[].members' \
            --filter="bindings.members:serviceAccount:${PUBLIC_SA}" \
            --format='value(bindings.role)' 2>/dev/null)" || return 2
  # A clean exit with empty output = the SA holds no project-level role (incl. a not-yet-
  # created SA) => no dispatch role. The command's exit status (gated above) is what
  # distinguishes "no roles" from "query failed".
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # Hard denylist — roles that carry dispatch or are project-wide super-roles.
    case "$r" in
      roles/run.developer|roles/run.admin|roles/owner|roles/editor)
        DISPATCH_ROLE="$r"; return 1;;
    esac
    # Expand any other role's permissions and look for the dispatch permission directly —
    # catches custom roles (e.g. heimdallJobRunner) and any predefined role granting it.
    if [[ "$r" == projects/* ]]; then
      perms="$(gcloud iam roles describe "${r##*/}" --project="${PROJECT_ID}" \
                --format='value(includedPermissions)' 2>/dev/null)" || return 2
    else
      perms="$(gcloud iam roles describe "$r" \
                --format='value(includedPermissions)' 2>/dev/null)" || return 2
    fi
    if printf '%s' "$perms" | grep -q 'run\.jobs\.run'; then
      DISPATCH_ROLE="$r"; return 1
    fi
  done <<< "$roles"
  return 0
}

preflight() {
  # P1 — this script deploys ONLY the public service. Targeting the gated service would,
  # via HEIMDALL_PUBLIC_SURFACE=1, make the gated service 404 its OWN dispatch/jobs/owner/
  # audit routes — a FUNCTIONAL break of the control plane. Refuse outright.
  if [ "${PUBLIC_SERVICE}" = "${GATED_SERVICE}" ]; then
    die "PREFLIGHT P1: PUBLIC_SERVICE (${PUBLIC_SERVICE}) == GATED_SERVICE (${GATED_SERVICE}).
       This script deploys the PUBLIC surface ONLY. Setting HEIMDALL_PUBLIC_SURFACE=1 on the
       gated control plane would 404 its own dispatch/jobs/approval/owner/audit routes — a
       functional break. Point PUBLIC_SERVICE at a DISTINCT service name."
  fi

  # P2 — the public surface must NEVER run as the gated, dispatch-capable runtime SA.
  # Pure string check, always enforced — the wrong-SA deploy cannot even reach IAM.
  if [ "${PUBLIC_SA}" = "${GATED_SA}" ]; then
    die "PREFLIGHT P2: PUBLIC_SA (${PUBLIC_SA}) == GATED_SA (${GATED_SA}).
       The public service must run as a DISTINCT least-privilege SA — never the dispatch-
       capable gated SA (it holds run.jobs.run). Set PUBLIC_SA_NAME to a distinct SA."
  fi

  # P3 — the public SA must PROVABLY lack any role granting run.jobs.run (layer-2). Probe
  # live IAM; a found dispatch role is fatal always, an unverifiable IAM is fatal on apply.
  # Capture the probe's status WITHOUT tripping `set -e` (a non-zero is a real verdict here).
  local rc=0; probe_dispatch_iam || rc=$?
  case "$rc" in
    0) say "    PREFLIGHT P3 ok: public SA holds NO role granting run.jobs.run (no-dispatch proven)";;
    1) die "PREFLIGHT P3: public SA ${PUBLIC_SA} holds dispatch-capable role '${DISPATCH_ROLE}'
       (it grants run.jobs.run). The internet-facing public surface must PROVABLY lack
       dispatch. Remove that binding, or choose a clean least-privilege SA, then re-run.";;
    2) if [ "$MODE" = "apply" ]; then
         die "PREFLIGHT P3: could not verify the public SA's IAM (gcloud auth/connectivity).
       Refusing to deploy the public surface BLIND — the no-dispatch proof is mandatory.
       Run 'gcloud auth login' / fix connectivity, or run 'plan' to review offline."
       else
         warn "PREFLIGHT P3 (plan): IAM not reachable — the no-dispatch probe will be ENFORCED at apply."
       fi;;
  esac

  # P4 — if a public PKI seed is shipped (conditional), it MUST be a distinct throwaway,
  # never the real server identity seed, and registered under a DISTINCT server HAID so it
  # cannot clobber the gated `cp-server -> pubkey(real-seed)` binding in the shared registry.
  if [ -n "${PUBLIC_PKI_SECRET}" ]; then
    if [ "${PUBLIC_PKI_SECRET}" = "${GATED_PKI_SECRET}" ]; then
      die "PREFLIGHT P4: PUBLIC_PKI_SECRET (${PUBLIC_PKI_SECRET}) == the gated server seed
       (${GATED_PKI_SECRET}). The internet-facing public service must NEVER hold the real
       server identity seed. Use a DISTINCT throwaway secret (see the GO-LIVE-RUNBOOK)."
    fi
    if [ "${PUBLIC_SERVER_HAID}" = "${SERVER_HAID}" ]; then
      die "PREFLIGHT P4: PUBLIC_SERVER_HAID (${PUBLIC_SERVER_HAID}) == the gated server HAID
       (${SERVER_HAID}). A throwaway-seeded public service must register a DISTINCT identity
       name, or its boot registration would CLOBBER the gated server's binding."
    fi
    say "    PREFLIGHT P4 ok: public PKI seed is a distinct throwaway (${PUBLIC_PKI_SECRET}) under HAID ${PUBLIC_SERVER_HAID}"
  else
    # P5 — a Cloud Run public service is fail-closed at boot without a seed
    # (cp_auth.load_signing_key raises pki_key_absent when K_SERVICE is set; audit
    # verdict (b) in .planning/ref/public-surface-pki-need.md). A seedless public
    # deploy would simply never go ready. Refuse it: PUBLIC_PKI_SECRET is REQUIRED,
    # and P4 above guarantees it is a DISTINCT throwaway (never the real cp-pki-key).
    die "PREFLIGHT P5: PUBLIC_PKI_SECRET is unset. A Cloud Run public service is
       fail-closed at boot without a server seed, so it would never become ready.
       Set PUBLIC_PKI_SECRET to a DISTINCT THROWAWAY secret (never ${GATED_PKI_SECRET});
       see GO-LIVE-RUNBOOK §2.3 for minting cp-pki-key-public."
  fi
}

preflight

# ── resolve the image to an IMMUTABLE DIGEST (never a floating tag, never from-source) ──
# The public service must run the byte-identical image the gated service serves, pinned by
# digest (the deploy-arc lesson). In `apply` this resolution is HARD — a non-digest is fatal.
# In `plan` (possibly offline) it only describes what apply will pin.
resolve_image_for_apply() {
  if [ -z "${IMAGE}" ]; then
    say "    image: resolving the gated service's live digest (no IMAGE override given)"
    local rev
    rev="$(gcloud run services describe "${GATED_SERVICE}" \
            --region="${REGION}" --project="${PROJECT_ID}" \
            --format='value(status.traffic[0].revisionName)' 2>/dev/null)" \
      || die "could not read ${GATED_SERVICE}'s serving revision — deploy the gated service first, or pass IMAGE=<repo>@sha256:<hash>."
    [ -n "${rev}" ] || die "${GATED_SERVICE} has no 100%-traffic revision — deploy it first, or pass IMAGE=<digest>."
    IMAGE="$(gcloud run revisions describe "${rev}" \
              --region="${REGION}" --project="${PROJECT_ID}" \
              --format='value(spec.containers[0].image)' 2>/dev/null)" \
      || die "could not read the image of ${GATED_SERVICE}'s revision ${rev}."
  fi
  case "${IMAGE}" in
    *@sha256:*) ;;  # already an immutable digest — good
    *)
      say "    image: ${IMAGE} is a TAG — resolving to an immutable digest (tags are never deployed)"
      local digest
      digest="$(gcloud artifacts docker images describe "${IMAGE}" \
                 --format='value(image_summary.fully_qualified_digest)' 2>/dev/null)" \
        || die "could not resolve tag ${IMAGE} to a digest. Pin IMAGE=<repo>@sha256:<hash>
       explicitly — the public service NEVER deploys a floating tag."
      [ -n "${digest}" ] || die "tag ${IMAGE} resolved to an empty digest — pin IMAGE=<digest> explicitly."
      IMAGE="${digest}"
      ;;
  esac
  case "${IMAGE}" in
    *@sha256:*) ;;
    *) die "image did not resolve to a digest (got '${IMAGE}') — refusing a non-pinned image.";;
  esac
  say "    image: PINNED to immutable digest ${IMAGE}"
}

if [ "$MODE" = "apply" ]; then
  resolve_image_for_apply
else
  if [ -n "${IMAGE}" ]; then
    case "${IMAGE}" in
      *@sha256:*) say "    image: PINNED digest ${IMAGE}";;
      *) say "    image: ${IMAGE} is a TAG — apply will RESOLVE it to a digest (never deploys the tag)";;
    esac
  else
    say "    image: apply will PIN ${GATED_SERVICE}'s live digest (its 100%-traffic revision)"
    IMAGE="<DIGEST-RESOLVED-AT-APPLY>"   # display-only token for the printed plan command
  fi
fi

# ── 1. the least-privilege runtime SA (create if absent) ─────────────────────────────
# Distinct from the gated service's runtime SA. This SA is granted ONLY what the public
# surface needs: Firestore (presence heartbeats + roster reads + enroll registry) and read
# access to the secret(s) it consumes. It is NEVER granted run.jobs.run / heimdallJobRunner
# / roles/run.developer — so it cannot dispatch a Cloud Run Job (PREFLIGHT P3 enforces it).
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
# SA can read ONLY the secret(s) it needs and no other secret in the project. The enroll
# token is always needed (token-gated enroll). The PKI seed is granted ONLY when a distinct
# throwaway public seed is configured (PREFLIGHT P4 guarantees it is not the real seed).
run gcloud secrets add-iam-policy-binding "${ENROLL_SECRET}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" \
  --role="roles/secretmanager.secretAccessor"
if [ -n "${PUBLIC_PKI_SECRET}" ]; then
  run gcloud secrets add-iam-policy-binding "${PUBLIC_PKI_SECRET}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${PUBLIC_SA}" \
    --role="roles/secretmanager.secretAccessor"
fi

# DELIBERATELY ABSENT: run.jobs.run / heimdallJobRunner / roles/run.developer.
# The public SA gets NO Cloud Run Job execution permission — the IAM half of the boundary.
say "    (NO run.jobs.run / heimdallJobRunner / run.developer granted — public SA cannot dispatch)"

# ── 2. assemble the per-service secrets + env (least exposure) ────────────────────────
# Enroll token always. PKI seed ONLY on the conditional throwaway path. HEIMDALL_PUBLIC_
# SURFACE=1 is set ONLY here (the public service); PREFLIGHT P1 guarantees this script can
# never target the gated service, so the flag never leaks onto it.
SECRETS="HEIMDALL_ENROLL_TOKEN=${ENROLL_SECRET}:latest"
ENVVARS="HEIMDALL_PUBLIC_SURFACE=1,HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID}"
if [ -n "${PUBLIC_PKI_SECRET}" ]; then
  # CONDITIONAL (PKI-need audit verdict) — distinct throwaway seed + distinct server HAID,
  # so the public boot identity can never clobber the gated server's registry binding.
  SECRETS="${SECRETS},HEIMDALL_CP_PKI_KEY=${PUBLIC_PKI_SECRET}:latest"
  ENVVARS="${ENVVARS},HEIMDALL_CP_SERVER_HAID=${PUBLIC_SERVER_HAID}"
  say "    secrets: enroll-token + DISTINCT throwaway PKI seed (${PUBLIC_PKI_SECRET}); server HAID=${PUBLIC_SERVER_HAID}"
else
  say "    secrets: enroll-token ONLY — no server PKI seed on the public service (least exposure)"
fi

# ── 3. deploy the PUBLIC service ─────────────────────────────────────────────────────
# Same resource envelope as the gated §3 (max-instances caps fan-out, scale-to-zero idle), but:
#   • --image <digest>          — the byte-identical immutable image (never a floating tag).
#   • --allow-unauthenticated   — reachable with NO Cloud Run IAM bearer (zero-config dev).
#   • --service-account public SA — the least-privilege identity (cannot dispatch).
#   • HEIMDALL_PUBLIC_SURFACE=1  — the APP-LAYER gate: serve public routes, 404 the rest.
#   • HEIMDALL_ENROLL_TOKEN      — from cp-enroll-token, so token-gated enroll can verify.
# NOTE: HEIMDALL_JOB_RUNNER is intentionally NOT set — the public surface 404s /dispatch
# and /jobs, so the runner is never reached; and even if it were, the missing run.jobs.run
# IAM blocks the execute. The two layers are independent.
run gcloud run deploy "${PUBLIC_SERVICE}" \
  --image "${IMAGE}" \
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
  --set-secrets="${SECRETS}" \
  --set-env-vars="${ENVVARS}"

if [ "$MODE" = "apply" ]; then
  PUBLIC_URL="$(gcloud run services describe "${PUBLIC_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
  say "==> heimdall-cp-public is live at: ${PUBLIC_URL}"
  say "    point heimdall-presence at it:  export HEIMDALL_CP_URL=\"${PUBLIC_URL}\""
  say "    operator tools keep pointing at the GATED ${GATED_SERVICE} URL."
else
  say "==> plan only — nothing deployed. Re-run with: $0 apply   (after the §3 kill-switch gate)"
fi
