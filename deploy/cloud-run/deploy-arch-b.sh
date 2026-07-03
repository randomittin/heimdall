#!/usr/bin/env bash
# deploy-arch-b.sh — ONE command that does ALL of Arch B (fully-cloud maintainer Job),
# INCLUDING the prerequisite the runbook §3.2 left manual: BUILD + PUSH the maintainer
# container image (git + gh + claude + the heimdall toolchain), resolve its digest, PIN
# that digest into heimdall-maintainer-job.yaml, THEN hand off to deploy-maintainer.sh
# --cloud for the secrets + `run jobs replace` + IAM (this script does NOT duplicate that
# secret logic — deploy-maintainer.sh owns every token: prompted silently, never echoed,
# stdin-piped to gcloud. No token is ever read, assigned, or printed in THIS script).
#
# RUN BY THE OPERATOR (RJ) on his own machine with his gcloud creds + Docker. The agent
# never runs this. No token is ever handled here — the only secrets in Arch B are minted
# INSIDE deploy-maintainer.sh.
#
# Order (idempotent, re-runnable, secret-safe):
#   a. preflight        — gcloud + docker present, authed, project set, files present
#   b. AR repo ensure   — gcloud artifacts repositories create <repo>  (|| already exists)
#   c. build + push     — docker build -f Dockerfile.maintainer  ->  tag  ->  docker push
#   d. digest resolve   — gcloud artifacts docker images describe --format image_summary.digest
#      + PIN            — back up the yaml, then sed the image@sha256 line in place
#   e. deploy (reuse)   — deploy-maintainer.sh --cloud --repo <r> --project <p> --region <g>
#   f. verify           — gcloud run jobs describe heimdall-maintainer-job
#
# Usage:
#   deploy-arch-b.sh --repo <owner/repo> [--project heimdall-cp-prod] \
#                    [--region us-central1] [--tag <t>] [--schedule "<cron>"] [--dry-run]
#   --schedule "<cron>" is passed through to deploy-maintainer.sh --cloud, which registers
#            the maintainer cron with the control plane (idempotent) so the per-minute tick
#            fires run-maintainer-cycle autonomously — the last manual step for a fully-cloud
#            unattended maintainer (see MAINTAINER-RUNBOOK.md §6).
#   --dry-run prints the FULL plan, executes nothing, needs NO creds/tokens/Docker.
set -euo pipefail

# ── defaults (project per operator; the existing infra references heimdall-cp-prod —
#    see the mismatch guard in preflight) ─────────────────────────────────────
REPO=""
PROJECT="heimdall-cp-prod"
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
  need gcloud "install the Google Cloud SDK (https://cloud.google.com/sdk)"
  need docker "install Docker (needed to build + push the maintainer image)"
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
# make the local docker client able to push to this AR host (idempotent).
run gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── c. build + push the maintainer image ─────────────────────────────────────
say "c. build + push ${IMAGE}:${TAG}  (context=${ROOT}, -f ${DOCKERFILE})"
run docker build -f "$DOCKERFILE" -t "${IMAGE}:${TAG}" "$ROOT"
run docker push "${IMAGE}:${TAG}"

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

echo
say "done (Arch B)."
[ "$DRY" = 1 ] && warn "dry-run: nothing executed, no creds used. Re-run without --dry-run to apply."
exit 0
