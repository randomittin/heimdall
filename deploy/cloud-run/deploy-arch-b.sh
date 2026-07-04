#!/usr/bin/env bash
# deploy-arch-b.sh — ONE command that does ALL of Arch B (fully-cloud maintainer Job),
# INCLUDING the prerequisite the runbook §3.2 left manual: BUILD + PUSH the maintainer
# container image (git + gh + claude + the heimdall toolchain), resolve its digest, PIN
# that digest into heimdall-maintainer-job.yaml, THEN hand off to deploy-maintainer.sh
# --cloud for the secrets + `run jobs replace` + IAM (this script does NOT duplicate that
# secret logic — deploy-maintainer.sh owns every token: prompted silently, never echoed,
# stdin-piped to gcloud. No token is ever read, assigned, or printed in THIS script).
#
# RUN BY THE OPERATOR (RJ) on his own machine with his gcloud creds — NO local Docker: the
# image is built on Cloud Build (`gcloud builds submit`), never a local docker daemon. The
# agent never runs this. No token is ever handled here — the only secrets in Arch B are
# minted INSIDE deploy-maintainer.sh.
#
# Order (idempotent, re-runnable, secret-safe):
#   a. preflight        — gcloud present, authed, project set, files present (no docker needed)
#   b. AR repo ensure   — gcloud artifacts repositories create <repo>  (|| already exists)
#   c. build + push     — gcloud builds submit (Cloud Build; inline config -f Dockerfile.maintainer)
#                         -> AR. Cloud Build's worker runs the build + push; no local docker.
#   d. digest resolve   — gcloud artifacts docker images describe --format image_summary.digest
#      + PIN            — back up the yaml, then sed the image@sha256 line in place
#   e. deploy (reuse)   — deploy-maintainer.sh --cloud --repo <r> --project <p> --region <g>
#   f. verify           — gcloud run jobs describe heimdall-maintainer-job
#
# Usage:
#   deploy-arch-b.sh --repo <owner/repo> [--project heimdall-control-plane] \
#                    [--region us-central1] [--tag <t>] [--schedule "<cron>"] [--dry-run]
#   --schedule "<cron>" is passed through to deploy-maintainer.sh --cloud, which registers
#            the maintainer cron with the control plane (idempotent) so the per-minute tick
#            fires run-maintainer-cycle autonomously — the last manual step for a fully-cloud
#            unattended maintainer (see MAINTAINER-RUNBOOK.md §6).
#   --dry-run prints the FULL plan, executes nothing, needs NO creds/tokens/Docker.
set -euo pipefail

# ── defaults (project per operator; the existing infra references heimdall-control-plane —
#    see the mismatch guard in preflight) ─────────────────────────────────────
REPO=""
PROJECT="heimdall-control-plane"
REGION="us-central1"
TAG=""
SCHEDULE=""
DRY=0

AR_REPO="heimdall"            # the Artifact Registry docker repo (matches the yaml image path)
IMAGE_NAME="heimdall-maintainer"
JOB="heimdall-maintainer-job"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DOCKERFILE="$HERE/Dockerfile.maintainer"
DOCKERFILE_REL="${DOCKERFILE#$ROOT/}"   # path to the Dockerfile RELATIVE to the Cloud Build context (ROOT)
YAML="$HERE/heimdall-maintainer-job.yaml"
DEPLOY_MAINTAINER="$HERE/deploy-maintainer.sh"

usage() { sed -n '23,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --repo)    REPO="${2:?}";    shift 2 ;;
  --project) PROJECT="${2:?}"; shift 2 ;;
  --region)  REGION="${2:?}";  shift 2 ;;
  --tag)     TAG="${2:?}";     shift 2 ;;
  --schedule) SCHEDULE="${2:?}"; shift 2 ;;
  --dry-run) DRY=1;            shift ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# run: in --dry-run print the command (NO secret is ever an argv here), else execute it.
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }

# ── arg validation (fail-closed, before any side effect) ─────────────────────
[ -n "$REPO" ] || die "missing --repo <owner/repo>"
printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || die "--repo must be <owner>/<name> (got: $REPO)"

# derive a traceable default tag: UTC timestamp + short git sha (local; no creds needed).
if [ -z "$TAG" ]; then
  _sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  TAG="$(date -u +%Y%m%d-%H%M%S)-${_sha}"
fi

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/${IMAGE_NAME}"

echo
printf '\033[1m╔═ HEIMDALL ARCH-B (build → push → pin → deploy) ═════════╗\033[0m\n'
printf '\033[1m║\033[0m repo=%-24s dry=%s\n' "$REPO" "$DRY"
printf '\033[1m║\033[0m image=%s:%s\n' "$IMAGE" "$TAG"
printf '\033[1m║\033[0m project=%-20s region=%s\n' "$PROJECT" "$REGION"
printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

# ── a. preflight ─────────────────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }
say "a. preflight"
[ -f "$DOCKERFILE" ]        || die "Dockerfile not found: $DOCKERFILE"
[ -f "$YAML" ]             || die "job manifest not found: $YAML"
[ -x "$DEPLOY_MAINTAINER" ] || die "deploy-maintainer.sh not found/executable: $DEPLOY_MAINTAINER (Arch-B prerequisite — see MAINTAINER-RUNBOOK.md §3)"
if [ "$DRY" != 1 ]; then
  # gcloud ONLY — the image is built on Cloud Build (`gcloud builds submit`), so no local
  # docker daemon is required. RJ's machine needs the Cloud SDK + the Cloud Build API enabled.
  need gcloud "install the Google Cloud SDK (https://cloud.google.com/sdk)"
  gcloud auth print-access-token >/dev/null 2>&1 || die "run: gcloud auth login"
fi
# consistency guard: the yaml's serviceAccountName + GOOGLE_CLOUD_PROJECT reference a
# project; if --project differs, the image-pin (below) keeps the image path in sync but
# those two fields are OUT of this script's pin scope — warn the operator to align them.
_yaml_proj="$(grep -oE 'heimdall-cp-run@[A-Za-z0-9-]+\.iam' "$YAML" | head -1 | sed -E 's/^heimdall-cp-run@([A-Za-z0-9-]+)\.iam$/\1/')"
if [ -n "$_yaml_proj" ] && [ "$_yaml_proj" != "$PROJECT" ]; then
  warn "the manifest's serviceAccountName/GOOGLE_CLOUD_PROJECT reference '$_yaml_proj', but --project=$PROJECT."
  warn "this script pins the IMAGE path to $PROJECT; also update serviceAccountName + GOOGLE_CLOUD_PROJECT in $YAML to $PROJECT before a real deploy (RUNBOOK §3.2)."
fi

# ── b. ensure the Artifact Registry docker repo exists (idempotent) ──────────
say "b. ensure Artifact Registry repo '${AR_REPO}' in ${REGION} (create || already exists)"
if [ "$DRY" = 1 ]; then
  run "gcloud artifacts repositories describe ${AR_REPO} --location=${REGION} --project=${PROJECT}  # (|| create below)"
  run "gcloud artifacts repositories create ${AR_REPO} --repository-format=docker --location=${REGION} --project=${PROJECT}  # only if absent"
else
  if gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
    say "  Artifact Registry repo '${AR_REPO}' already exists"
  else
    run gcloud artifacts repositories create "${AR_REPO}" \
      --repository-format=docker --location="${REGION}" --project="${PROJECT}"
  fi
fi

# ── c. build + push the maintainer image VIA CLOUD BUILD (no local docker) ────
# `gcloud builds submit --tag` can only build a root-context `Dockerfile`; the maintainer
# needs a CUSTOM Dockerfile path (deploy/cloud-run/Dockerfile.maintainer). So we hand Cloud
# Build a minimal inline build config that runs the build on Cloud Build's OWN worker and
# pushes the result to Artifact Registry (the `images:` block). RJ needs NO local docker —
# only gcloud + the Cloud Build API. The context is the repo ROOT so `COPY bin/` resolves;
# .gcloudignore/.dockerignore keep the upload lean.
say "c. build + push ${IMAGE}:${TAG} via Cloud Build  (context=${ROOT}, -f ${DOCKERFILE_REL})"
if [ "$DRY" = 1 ]; then
  run "gcloud builds submit ${ROOT} --project=${PROJECT} --config=<inline cloudbuild.yaml: build -f ${DOCKERFILE_REL} -> ${IMAGE}:${TAG}, images: push to AR>  # Cloud Build worker builds+pushes; NO local docker"
else
  CLOUDBUILD_CFG="${TMPDIR:-/tmp}/heimdall-maint-cloudbuild.$$-${RANDOM}.yaml"
  # minimal config: build the maintainer Dockerfile on Cloud Build, then push to AR (images:).
  cat > "$CLOUDBUILD_CFG" <<YAML
steps:
  - name: gcr.io/cloud-builders/docker
    args: ["build", "-f", "${DOCKERFILE_REL}", "-t", "${IMAGE}:${TAG}", "."]
images:
  - "${IMAGE}:${TAG}"
YAML
  run gcloud builds submit "$ROOT" --project="$PROJECT" --config="$CLOUDBUILD_CFG"
  rm -f "$CLOUDBUILD_CFG"
fi

# ── d. resolve the pushed digest + PIN it into the yaml ──────────────────────
say "d. resolve digest + pin into $(basename "$YAML")"
if [ "$DRY" = 1 ]; then
  run "gcloud artifacts docker images describe ${IMAGE}:${TAG} --format='value(image_summary.digest)'"
  run "cp ${YAML} ${YAML}.bak   # backup before pin"
  run "sed -i -E 's#(- image: ).*${IMAGE_NAME}@sha256:.*#\\1${IMAGE}@sha256:<resolved-digest>#' ${YAML}"
  say "  (dry-run) manifest image line WOULD become: - image: ${IMAGE}@sha256:<resolved-digest>"
else
  DIGEST="$(gcloud artifacts docker images describe "${IMAGE}:${TAG}" \
    --format='value(image_summary.digest)')"
  case "$DIGEST" in
    sha256:*) : ;;
    *) die "digest resolve returned '$DIGEST' (expected sha256:...) — build/push may have failed" ;;
  esac
  cp "$YAML" "${YAML}.bak"
  say "  backed up manifest -> ${YAML}.bak"
  # Replace the WHOLE image value (project + repo + name + digest) so the manifest pull
  # target matches exactly what was pushed to --project. Robust to the REPLACE_WITH_DIGEST
  # sentinel AND to a prior real @sha256 (re-pin is safe / idempotent).
  sed -i.pin -E "s#(- image: ).*${IMAGE_NAME}@sha256:.*#\1${IMAGE}@${DIGEST}#" "$YAML"
  rm -f "${YAML}.pin"
  grep -qF "${IMAGE}@${DIGEST}" "$YAML" \
    || die "pin failed — ${IMAGE}@${DIGEST} not found in $YAML after sed (restore ${YAML}.bak)"
  say "  pinned: ${IMAGE}@${DIGEST}"
fi

# ── e. deploy (REUSE deploy-maintainer.sh --cloud: secrets + job replace + IAM) ──
say "e. deploy — deploy-maintainer.sh --cloud (mints secrets, job replace, IAM)"
DM_ARGS=(--cloud --repo "$REPO" --project "$PROJECT" --region "$REGION")
[ -n "$SCHEDULE" ] && DM_ARGS+=(--schedule "$SCHEDULE")
[ "$DRY" = 1 ] && DM_ARGS+=(--dry-run)
run "$DEPLOY_MAINTAINER" "${DM_ARGS[@]}"

# ── f. verify ────────────────────────────────────────────────────────────────
say "f. verify"
run gcloud run jobs describe "$JOB" --region="$REGION" --project="$PROJECT"

# ── job-name alignment reminder (dispatcher <-> this manifest) ────────────────
# cp_jobrunner.CloudRunJobRunner defaults to job name 'heimdall-long-job'
# (cp_jobrunner.JOB_NAME_DEFAULT), overridable ONLY via env HEIMDALL_CP_JOB_NAME
# (cp_jobrunner.JOB_NAME_ENV). This manifest deploys '${JOB}', so the CONTROL-PLANE
# SERVICE that fires the maintainer tick MUST run with HEIMDALL_CP_JOB_NAME=${JOB}, else
# the cycle dispatches to heimdall-long-job (no git/gh/claude) and fails at runtime.
warn "dispatcher alignment: set HEIMDALL_CP_JOB_NAME=${JOB} on the control-plane SERVICE that runs the maintainer tick (cp_jobrunner defaults to heimdall-long-job otherwise). See MAINTAINER-RUNBOOK.md §3."

echo
say "done (Arch B)."
[ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds used. Re-run without --dry-run to apply."
exit 0
