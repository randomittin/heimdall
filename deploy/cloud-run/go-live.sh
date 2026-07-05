#!/usr/bin/env bash
# go-live.sh — THE GUIDED OPERATOR for the two-service go-live (RUNBOOK steps 2–7).
#
# WHAT THIS IS. A sequencer RJ runs under his OWN already-authenticated gcloud
# shell. It chains the canonical steps of GO-LIVE-RUNBOOK.md (gated rebuild →
# secret existence → public least-privilege SA + no-dispatch proof → public deploy
# → consistency gate → live boundary verify), PRINTS the exact gcloud command for
# each step, RUNS it, and STOPS on the first failure. It does NOT replace the
# runbook — it executes the runbook's commands in order, with the runbook's gates.
#
# WHAT THIS IS NOT. It NEVER holds a credential and NEVER leaks a secret:
#   • No secret VALUE appears anywhere in this file — secrets are referenced ONLY
#     by their Secret-Manager NAME (e.g. cp-enroll-token:latest), never their bytes.
#   • A minted secret value goes STRAIGHT into `gcloud secrets versions add
#     <name> --data-file=-` over stdin, from a python3 process whose ONLY output is
#     that one pipe. The value never touches argv (ps-visible), stdout, a log line,
#     a file, or an env var this script reads or prints. (`set -x` is NEVER enabled.)
#   • Step 5 REUSES deploy-public-surface.sh (its P1–P5 preflights + digest pin) —
#     this script does not duplicate that logic. Step 6 REUSES check-public-surface.sh.
#
# MODES:
#   (default)        GUIDED — print each command, RUN it (mutating gcloud), stop on fail.
#   --plan | --check PLAN   — print the ENTIRE sequence and run ZERO mutating gcloud
#                            (no spend, creds-optional). For review.
#
# SPEND. Step 2 (gated rebuild + redeploy) and step 5 (public deploy) incur spend.
# Run guided mode ONLY after the billing kill-switch gate is green (README §3).

set -uo pipefail   # NEVER set -x — it would echo a piped secret value.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
DEPLOY_PUBLIC="${SELF_DIR}/deploy-public-surface.sh"
CHECK_PUBLIC="${SELF_DIR}/check-public-surface.sh"

# ── config (every value overridable from the env; defaults match the RUNBOOK §0) ─────
PROJECT_ID="${PROJECT_ID:-heimdall-cp-prod}"
REGION="${REGION:-us-central1}"
GATED_SERVICE="${GATED_SERVICE:-heimdall-control-plane}"
PUBLIC_SERVICE="${PUBLIC_SERVICE:-heimdall-cp-public}"
# GATED runtime SA — the identity the gated control-plane service RUNS AS. NOT a hardcoded
# truncated 'heimdall-cp-run' name never existed → the live iam.serviceAccounts.actAs
# PERMISSION_DENIED). resolve_gated_sa() (called from the banner below) AUTO-DETECTS it from the
# deployed gated service's serviceAccountName just before STEP 2; an explicit GATED_SA/RUNTIME_SA
# env OVERRIDES it for a FRESH project where the service does not exist yet; else it falls back to
# the default heimdall-cp-runtime@<project> (the REAL gated runtime SA name).
GATED_SA_OVERRIDE="${GATED_SA:-${RUNTIME_SA:-}}"
DEFAULT_GATED_SA="heimdall-cp-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA="${GATED_SA_OVERRIDE:-${DEFAULT_GATED_SA}}"
PUBLIC_SA_NAME="${PUBLIC_SA_NAME:-heimdall-cp-public-run}"
PUBLIC_SA="${PUBLIC_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
# Secret NAMES only — never values. (RUNBOOK §2.)
ENROLL_SECRET="${ENROLL_SECRET:-cp-enroll-token}"
# Enroll mode forwarded to deploy-public-surface.sh (STEP 5). 0=token-gated (the DEFAULT — the
# viral/public phase, cp-enroll-token REQUIRED); 1=OPEN (tokenless+bounded, zero-config internal
# onboarding — the enroll token is OPTIONAL). The deploy script owns the abuse-control caps (they
# apply in BOTH modes) + the token resolution; this only forwards the mode.
ENROLL_OPEN="${ENROLL_OPEN:-0}"
PUBLIC_PKI_SECRET="${PUBLIC_PKI_SECRET:-cp-pki-key-public}"   # DISTINCT throwaway (verdict (b))
GATED_PKI_SECRET="${GATED_PKI_SECRET:-cp-pki-key}"            # the REAL server seed — gated-only
PUBLIC_SERVER_HAID="${PUBLIC_SERVER_HAID:-cp-public-server}"

# ── mode ─────────────────────────────────────────────────────────────────────────────
MODE="guided"
case "${1:-}" in
  ""|guided|apply)            MODE="guided" ;;
  --plan|plan|--check|check)  MODE="plan" ;;
  -h|--help)
    printf 'usage: %s [--plan|--check]\n  (no arg) guided: print+run each step, stop on first failure\n  --plan   print the whole sequence, run ZERO mutating gcloud (no spend)\n' "$0"
    exit 0 ;;
  *)
    printf '\033[31mFATAL\033[0m unknown arg %q — use --plan/--check or no arg (guided)\n' "$1" >&2
    exit 2 ;;
esac

# ── output helpers ─────────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;35m━━ %s\033[0m\n' "$*"; }
say()   { printf '\033[36m%s\033[0m\n' "$*"; }
note()  { printf '      %s\n' "$*"; }
warn()  { printf '\033[33mWARN\033[0m  %s\n' "$*" >&2; }
die()   { printf '\033[31mFATAL\033[0m %s\n' "$*" >&2; exit 2; }

# show() prints a command; run() prints it then runs it ONLY in guided mode. Neither
# is ever used to print a secret value — they print gcloud invocations that reference
# secrets by NAME only. (Stop-on-fail is the caller's job via `|| die`.)
show()  { printf '\033[2m  $ %s\033[0m\n' "$*"; }
# run() PRINTS the command, then RUNS it ONLY in guided mode. In plan mode it is a no-op
# that returns 0 (so a trailing `|| die` never fires for a command we deliberately skipped).
run()   { show "$*"; [ "$MODE" = "guided" ] || return 0; "$@"; }

# retry() — re-run a command up to N times with linear backoff, tolerating the
# transient GCP IAM "does not exist"/400 propagation race a freshly-created SA
# triggers on the FIRST grant that references it. gcloud add-iam-policy-binding is
# idempotent, so a re-grant of an already-present binding is a no-op success. In
# plan mode the wrapped `run` returns 0 immediately → one pass, zero mutation.
retry() {
  local tries="$1"; shift
  local n=1 rc=0
  while :; do
    "$@" && return 0
    rc=$?
    [ "$n" -ge "$tries" ] && return "$rc"
    warn "  (attempt ${n}/${tries} failed rc=${rc}; retry in $((n*2))s — likely IAM propagation race)"
    sleep "$((n*2))"
    n=$((n+1))
  done
}

# resolve_gated_sa — set RUNTIME_SA (the gated service-account the STEP-2 redeploy runs under),
# in precedence order, mirroring deploy-public-rr.sh's resolve_runtime_sa:
#   1. an explicit GATED_SA/RUNTIME_SA override (used verbatim — the escape hatch for a FRESH
#      project where the gated service does not exist yet to auto-detect from).
#   2. the deployed gated service's ACTUAL serviceAccountName (spec.template.spec.serviceAccountName
#      from `gcloud run services describe`) — a redeploy keeps the identity it already runs as.
#   3. the default heimdall-cp-runtime@<project> (the REAL gated runtime SA name) if the service is
#      absent. The old truncated 'heimdall-cp-run' default never existed → actAs PERMISSION_DENIED.
# In plan mode this runs ZERO gcloud (creds-optional): it prints the auto-detect intent + the
# default it would fall back to. Sets the global RUNTIME_SA.
resolve_gated_sa() {
  if [ -n "${GATED_SA_OVERRIDE}" ]; then
    RUNTIME_SA="${GATED_SA_OVERRIDE}"
    note "gated runtime SA (explicit GATED_SA/RUNTIME_SA override): ${RUNTIME_SA}"
    return 0
  fi
  if [ "$MODE" != "guided" ]; then
    RUNTIME_SA="${DEFAULT_GATED_SA}"
    note "gated runtime SA: AUTO-DETECTED at guided run from ${GATED_SERVICE} (spec.template.spec.serviceAccountName); default ${RUNTIME_SA} if the service is absent"
    return 0
  fi
  local sa
  sa="$(gcloud run services describe "${GATED_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" \
          --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)"
  if [ -n "${sa}" ]; then
    RUNTIME_SA="${sa}"
    note "gated runtime SA (auto-detected from deployed ${GATED_SERVICE}): ${RUNTIME_SA}"
  else
    RUNTIME_SA="${DEFAULT_GATED_SA}"
    note "gated runtime SA (${GATED_SERVICE} not deployed yet — default): ${RUNTIME_SA}  (override with GATED_SA=<email>)"
  fi
}

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — install the Cloud SDK and authenticate."

say "==> heimdall go-live (${MODE} mode) — RUNBOOK steps 2–7"
note "project=${PROJECT_ID} region=${REGION}"
resolve_gated_sa
note "gated=${GATED_SERVICE} (SA ${RUNTIME_SA})   public=${PUBLIC_SERVICE} (SA ${PUBLIC_SA})"
if [ "$MODE" = "plan" ]; then
  warn "PLAN/CHECK mode — prints the full sequence and runs ZERO mutating gcloud (no spend, creds-optional)."
fi

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 2 — GATED REBUILD (README §3–§4): build the current-main image, redeploy the
# gated service onto its new digest. Detect-and-skip if the gated service ALREADY
# serves a current-main image. This MUST precede step 5 (the public service pins the
# gated service's live digest — a stale gated image = no boundary).
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 2 — gated rebuild + redeploy (README §3–§4) [precedes the public pin]"
note "The public service (step 5) pins THIS service's live digest. A stale gated image"
note "would pin a stale boundary, so the gated image must come from current main first."

# In-image current-main proof (README §3 rebuild guards): the firestore factory branch
# and the build-time import guard must be in the source about to be built.
note "current-main source guards (must be present before a rebuild is meaningful):"
GUARD_OK=1
grep -q "return cp_state_firestore.FirestoreBackend()" "${REPO_ROOT}/bin/lib/cp_state.py" 2>/dev/null \
  && note "  ok  cp_state.py firestore branch returns FirestoreBackend()" \
  || { warn "  cp_state.py firestore branch missing FirestoreBackend() return"; GUARD_OK=0; }
grep -q "google-cloud-firestore" "${REPO_ROOT}/Dockerfile" 2>/dev/null \
  && note "  ok  Dockerfile pins google-cloud-firestore" \
  || { warn "  Dockerfile missing google-cloud-firestore pin"; GUARD_OK=0; }
[ "$GUARD_OK" = 1 ] || die "STEP 2: current-main source guards absent — refusing to rebuild a stale image."

# deployed-shape preflight (WARN-ONLY — never blocks the go-live). Static scan of
# bin/lib/*.py for the workstation-assumption smells the 14-bug cloud-maintainer
# bring-up saga proved dangerous (slug-onto-CWD paths, unguarded local-state reads,
# captured-but-ignored subprocess stderr, reserved Cloud Run env names in override
# dicts). Needs no creds; a bounded experiment (promotion to blocking is `--strict`).
DSHAPE_CHECK="${REPO_ROOT}/bin/heimdall-deployed-shape-check"
if command -v python3 >/dev/null 2>&1 && [ -f "${DSHAPE_CHECK}" ]; then
  note "deployed-shape preflight (WARN-only — findings never block):"
  python3 "${DSHAPE_CHECK}" --root "${REPO_ROOT}" || true
else
  warn "deployed-shape preflight skipped (python3 or ${DSHAPE_CHECK} absent)"
fi

# Detect-and-skip: compare the gated service's live image to the current-main HEAD.
# We compare the deployed image's commit-tag (or just report) against HEAD; if the
# operator has already deployed current main, we skip the spend-incurring rebuild.
HEAD_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
note "current-main HEAD = ${HEAD_SHA}"
LIVE_IMAGE=""
if [ "$MODE" = "guided" ]; then
  show "gcloud run services describe ${GATED_SERVICE} --region=${REGION} --project=${PROJECT_ID} --format='value(status.traffic[0].revisionName)'"
  LIVE_REV="$(gcloud run services describe "${GATED_SERVICE}" --region="${REGION}" \
                --project="${PROJECT_ID}" --format='value(status.traffic[0].revisionName)' 2>/dev/null || true)"
  if [ -n "${LIVE_REV}" ]; then
    show "gcloud run revisions describe ${LIVE_REV} --region=${REGION} --project=${PROJECT_ID} --format='value(spec.containers[0].image)'"
    LIVE_IMAGE="$(gcloud run revisions describe "${LIVE_REV}" --region="${REGION}" \
                    --project="${PROJECT_ID}" --format='value(spec.containers[0].image)' 2>/dev/null || true)"
  fi
fi

REBUILD_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/heimdall/heimdall-control-plane:${HEAD_SHA}"

# ensure_ar_repo <full-image-tag> — idempotently ensure the Artifact Registry docker repo
# that <full-image-tag> targets EXISTS before a build pushes into it. The repo is the path
# segment after the project id (…/${PROJECT_ID}/<repo>/<image>:<tag>). guided: describe ->
# present, skip; absent -> create (docker format, ${REGION}). plan: PRINT describe+create and
# mutate NOTHING (run() no-ops). Without this the push fails: name unknown: Repository "<repo>"
# not found (the repo is not auto-created by `builds submit --tag`).
ensure_ar_repo() {
  local tag="$1" repo
  repo="${tag##*.pkg.dev/${PROJECT_ID}/}"   # -> <repo>/<image>:<tag>
  repo="${repo%%/*}"                          # -> <repo>
  [ -n "${repo}" ] && [ "${repo}" != "${tag}" ] \
    || die "STEP 2: could not derive the Artifact Registry repo from tag '${tag}'."
  note "ensure Artifact Registry repo '${repo}' exists (${REGION}, docker) before the push:"
  if [ "$MODE" = "guided" ] \
     && gcloud artifacts repositories describe "${repo}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    say "  AR repo ${repo} already exists — skipping create"
    return 0
  fi
  show "gcloud artifacts repositories describe ${repo} --location=${REGION} --project=${PROJECT_ID}"
  show "gcloud artifacts repositories create ${repo} --repository-format=docker --location=${REGION} --project=${PROJECT_ID}"
  [ "$MODE" = "guided" ] || return 0
  # IDEMPOTENT create: the describe above may have failed for a NON-absence reason
  # (e.g. an expired cred triggering a mid-command reauth), so we fall through to
  # create — but ALREADY_EXISTS then means the repo IS present, which is exactly the
  # goal. Treat ALREADY_EXISTS as success; only a real failure dies. (Was: any
  # describe miss -> create -> ALREADY_EXISTS -> FATAL on a reauth.)
  local _cre
  _cre="$(gcloud artifacts repositories create "${repo}" \
            --repository-format=docker --location="${REGION}" --project="${PROJECT_ID}" 2>&1)" \
    && { say "  AR repo ${repo} created"; return 0; }
  if printf '%s' "${_cre}" | grep -qiE 'ALREADY_EXISTS|already exists'; then
    say "  AR repo ${repo} already exists — proceeding (create was idempotent)"
    return 0
  fi
  printf '%s\n' "${_cre}" >&2
  die "STEP 2: could not create Artifact Registry repo '${repo}' (${REGION}) — the build push would fail with: name unknown: Repository \"${repo}\" not found."
}

if [ -n "${LIVE_IMAGE}" ] && printf '%s' "${LIVE_IMAGE}" | grep -qF ":${HEAD_SHA}"; then
  say "STEP 2 SKIP — gated service already serves a current-main (${HEAD_SHA}) image:"
  note "${LIVE_IMAGE}"
else
  [ -n "${LIVE_IMAGE}" ] && note "gated currently serves: ${LIVE_IMAGE} (not current-main ${HEAD_SHA}) — rebuilding"
  note "build the current-main image to Artifact Registry, then redeploy the gated service onto it:"
  ensure_ar_repo "${REBUILD_TAG}"   # the target AR repo must EXIST before the push (else: Repository not found)
  run gcloud builds submit "${REPO_ROOT}" --project="${PROJECT_ID}" --tag="${REBUILD_TAG}" \
    || die "STEP 2: gcloud builds submit failed — gated image not rebuilt."
  # Redeploy the gated service onto the freshly-built image (README §3 envelope), pinned
  # by the tag we just pushed; --no-allow-unauthenticated keeps the IAM wall.
  run gcloud run deploy "${GATED_SERVICE}" \
    --image="${REBUILD_TAG}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --service-account="${RUNTIME_SA}" \
    --max-instances=5 --min-instances=1 --no-cpu-throttling --cpu=1 --memory=512Mi \
    --timeout=300 --concurrency=80 --port=8080 \
    --no-allow-unauthenticated \
    --set-secrets="HEIMDALL_CP_PKI_KEY=${GATED_PKI_SECRET}:latest,HEIMDALL_GH_APP_ID=heimdall-gh-app-id:latest,HEIMDALL_GH_APP_PRIVATE_KEY=heimdall-gh-app-private-key:latest" \
    --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server,HEIMDALL_JOB_RUNNER=cloudrun-job,HEIMDALL_CP_JOB_NAME=heimdall-maintainer-job" \
    || die "STEP 2: gated redeploy failed — public step 5 would pin a stale digest, aborting."
  say "STEP 2 ok — gated service redeployed on current-main ${HEAD_SHA}"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 3 — SECRET EXISTENCE (RUNBOOK §2). describe the three secrets; for any MISSING,
# PRINT the exact mint command and run it ONLY on explicit operator confirm. The minted
# VALUE is piped STRAIGHT to --data-file=- over stdin; it never touches argv/stdout/file/env.
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 3 — Secret Manager existence (cp-enroll-token, ${PUBLIC_PKI_SECRET}, ${GATED_PKI_SECRET})"

# secret_present <name> -> 0 present, 1 absent (guided: real probe; plan: report only).
secret_present() {
  local name="$1"
  if [ "$MODE" != "guided" ]; then return 1; fi
  gcloud secrets describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1
}

# confirm <prompt> -> 0 if the operator types y/yes. In plan mode we NEVER prompt or mint.
confirm() {
  [ "$MODE" = "guided" ] || return 1
  local ans=""
  printf '\033[33m  %s\033[0m [y/N] ' "$1" >&2
  IFS= read -r ans || true
  case "${ans}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# mint_token <name> — generate a URL-safe token and pipe it STRAIGHT into Secret Manager.
# THE NO-LEAKAGE SEAM: python3 writes the value to its stdout, which is connected ONLY to
# the gcloud stdin pipe (--data-file=-). The value never appears as an argv word (so it is
# invisible to `ps`), is never echoed, never logged, never written to a file, and is never
# captured into a shell variable. We print the COMMAND (which names the secret, not its
# value) for the operator, then run the pipe.
mint_token() {
  local name="$1"
  show "python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(32))' | gcloud secrets versions add ${name} --data-file=-"
  if [ "$MODE" = "guided" ]; then
    python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(32))' \
      | gcloud secrets versions add "${name}" --project="${PROJECT_ID}" --data-file=- >/dev/null \
      || die "STEP 3: minting ${name} failed."
    say "STEP 3 ok — ${name} version added (value never left the stdin pipe)"
  fi
}

# mint_ed25519_seed <name> — generate a fresh Ed25519 seed (base64) and pipe it STRAIGHT
# into Secret Manager. Same no-leakage seam as mint_token: the seed bytes flow python3 ->
# stdin -> gcloud only. This is the RUNBOOK §2.3 snippet for the DISTINCT throwaway seed.
mint_ed25519_seed() {
  local name="$1"
  show "python3 - <<'PY' | gcloud secrets versions add ${name} --data-file=-   # ed25519 seed (RUNBOOK §2.3)"
  show "  (Ed25519PrivateKey.generate -> raw private bytes -> base64 -> sys.stdout.write)"
  show "PY"
  if [ "$MODE" = "guided" ]; then
    python3 - <<'PY' \
      | gcloud secrets versions add "${name}" --project="${PROJECT_ID}" --data-file=- >/dev/null \
      || die "STEP 3: minting ${name} (ed25519 seed) failed."
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
seed = Ed25519PrivateKey.generate().private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption())
sys.stdout.write(base64.b64encode(seed).decode())
PY
    say "STEP 3 ok — ${name} ed25519 seed version added (value never left the stdin pipe)"
  fi
}

# ensure_secret_container <name> — create the Secret Manager container (no value) if absent.
ensure_secret_container() {
  local name="$1"
  run gcloud secrets create "${name}" --project="${PROJECT_ID}" --replication-policy=automatic \
    || warn "  (create ${name} returned nonzero — likely already exists; the versions add below is what matters)"
}

# provision_secret <name> <human-desc> <minter-fn> — the existence-and-mint flow for ONE
# secret. plan mode: PRINT the mint command (via the minter's show()) and return — no
# probe, no prompt, no mutation. guided mode: probe; if present, report; if MISSING, prompt
# — a yes mints (create container + minter), a no SKIPS with a warning (NEVER mints on a
# decline). The minter ($3) is the only place a value is generated, and it pipes to stdin.
provision_secret() {
  local name="$1" desc="$2" minter="$3"
  note "${name} — ${desc}"
  if [ "$MODE" != "guided" ]; then
    note "  (plan) if absent, mint with (value piped to --data-file=- over stdin, never logged):"
    "${minter}" "${name}"            # plan mode: minter only PRINTS the command
    return 0
  fi
  if secret_present "${name}"; then
    say "  present — ${name}"
    return 0
  fi
  warn "  MISSING — ${name}"
  if confirm "mint ${name} now? (value generated + piped to stdin, never echoed/logged/argv'd)"; then
    ensure_secret_container "${name}"
    "${minter}" "${name}"
  else
    warn "  skipped minting ${name} — step 5 needs it; mint it (RUNBOOK §2) before continuing"
  fi
}

# ── 3a. enroll token (RUNBOOK §2.2) ──
# REQUIRED in TOKEN mode (ENROLL_OPEN=0, the DEFAULT — the viral/public phase): /enroll is
# fail-closed, so the public deploy (STEP 5) REFUSES an absent cp-enroll-token. Mint it below
# (a decline is then enforced as a hard stop). OPTIONAL only in OPEN mode (ENROLL_OPEN=1):
# /enroll is tokenless+bounded, so you may SKIP minting — open enroll still works without the
# token and deploy-public-surface.sh does NOT fail when it is absent. The abuse-control caps
# (per-IP / budget / registry) bound enroll in BOTH modes regardless.
if [ "${ENROLL_OPEN}" = "1" ]; then
  note "ENROLL_OPEN=1 (open mode) — cp-enroll-token is OPTIONAL; you may decline the mint below (tokenless enroll still works)."
else
  note "ENROLL_OPEN=${ENROLL_OPEN} (token mode, the default) — cp-enroll-token is REQUIRED; mint it below or the public deploy refuses."
fi
provision_secret "${ENROLL_SECRET}" \
  "bootstrap token verifier for /enroll — REQUIRED in token mode (default), OPTIONAL in open mode (public service)" mint_token

# TOKEN MODE (the default) — the enroll token is REQUIRED: STEP 5's deploy-public-surface.sh
# REFUSES an absent token (a dead enroll route). Enforce it HERE so a declined / still-missing
# mint fails EARLY (before STEP 5's spend), not after the gated rebuild. In OPEN mode
# (ENROLL_OPEN=1) a missing token is fine (tokenless enroll), so this gate is token-mode-only.
if [ "${ENROLL_OPEN}" != "1" ] && [ "$MODE" = "guided" ]; then
  secret_present "${ENROLL_SECRET}" \
    || die "STEP 3: token mode (ENROLL_OPEN=${ENROLL_OPEN}) REQUIRES ${ENROLL_SECRET}, but it is still absent (mint declined?). Mint it (RUNBOOK §2.2) before continuing — the public deploy refuses without it. Or set ENROLL_OPEN=1 for tokenless open enroll."
fi

# ── 3b. distinct throwaway public PKI seed (RUNBOOK §2.3, verdict (b)) ──
[ "${PUBLIC_PKI_SECRET}" != "${GATED_PKI_SECRET}" ] || die "STEP 3: PUBLIC_PKI_SECRET == ${GATED_PKI_SECRET} — refusing to reuse the real server seed on the internet-facing service."
provision_secret "${PUBLIC_PKI_SECRET}" \
  "DISTINCT throwaway boot seed for the public service (NEVER the real ${GATED_PKI_SECRET})" mint_ed25519_seed

# ── 3c. the REAL gated server seed (RUNBOOK §2.1) — existence check ONLY, NEVER minted here ──
note "${GATED_PKI_SECRET} — the REAL server identity seed (gated service only). Existence check only."
if secret_present "${GATED_PKI_SECRET}"; then
  say "  present — ${GATED_PKI_SECRET}"
else
  warn "  MISSING — ${GATED_PKI_SECRET}. The gated service (step 2) cannot boot without it."
  note "  Mint it via README §2 on RJ's machine (ed25519 seed, piped to --data-file=-); this script does NOT mint the real server seed."
  [ "$MODE" = "guided" ] && die "STEP 3: real server seed ${GATED_PKI_SECRET} absent — provision it (README §2) before go-live."
fi

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 4 — PUBLIC SA (RUNBOOK §3). Create heimdall-cp-public-run (idempotent), grant ONLY
# datastore.user + secretAccessor on cp-enroll-token + the throwaway public seed. Then
# PROVE no-dispatch: assert the SA holds NO run.jobs.run / run.developer / run.admin.
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 4 — public least-privilege SA + the no-dispatch proof (RUNBOOK §3)"
note "deploy-public-surface.sh (step 5) also creates+grants this SA idempotently; here we"
note "establish it early and PROVE it cannot dispatch before any public deploy."

# 4a — ENSURE the SA (idempotent: a re-run of go-live.sh must NOT die on an
# already-existing SA), WAIT for it to PROPAGATE (GCP IAM is eventually consistent —
# a freshly-created SA is invisible to grants for a few seconds), THEN grant
# datastore + the two secretAccessors with RETRY (the first grant races the SA's
# propagation → transient 400 "does not exist"; retry until it lands).

# ensure_public_sa() — describe-first; create only if absent; distinguish a REAL
# create failure from a benign "already exists" (a concurrent create raced us).
ensure_public_sa() {
  if [ "$MODE" != "guided" ]; then
    run gcloud iam service-accounts create "${PUBLIC_SA_NAME}" --project="${PROJECT_ID}" \
      --display-name="Heimdall CP PUBLIC surface (presence/enroll/health — least privilege)"
    return 0
  fi
  if gcloud iam service-accounts describe "${PUBLIC_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    say "  SA ${PUBLIC_SA} already exists — skipping create (idempotent re-run)"
    return 0
  fi
  local err
  show "gcloud iam service-accounts create ${PUBLIC_SA_NAME} --project=${PROJECT_ID} --display-name='Heimdall CP PUBLIC surface (...)'"
  if err="$(gcloud iam service-accounts create "${PUBLIC_SA_NAME}" --project="${PROJECT_ID}" \
              --display-name="Heimdall CP PUBLIC surface (presence/enroll/health — least privilege)" 2>&1)"; then
    say "  SA ${PUBLIC_SA} created"
  elif printf '%s' "${err}" | grep -qiE 'already[ _]?exists'; then
    say "  SA ${PUBLIC_SA} already exists (create raced) — continuing"
  else
    die "STEP 4: SA create failed (NOT an already-exists error): ${err}"
  fi
}

# wait_sa_propagate() — poll describe until the SA is visible, so the grants below
# don't race its propagation. Bounded: ≤10 polls × 6s ≈ 60s, then die.
wait_sa_propagate() {
  if [ "$MODE" != "guided" ]; then
    show "gcloud iam service-accounts describe ${PUBLIC_SA} --project=${PROJECT_ID}   # poll until visible (≤10×6s)"
    note "  (plan) at guided run this POLLS describe until the SA propagates before any grant (≤10 tries, 6s apart, ≤60s)"
    return 0
  fi
  local n=1 max=10
  while [ "$n" -le "$max" ]; do
    if gcloud iam service-accounts describe "${PUBLIC_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
      say "  SA ${PUBLIC_SA} visible — propagated after ${n} poll(s)"
      return 0
    fi
    note "  SA not yet visible (poll ${n}/${max}) — sleeping 6s for IAM propagation"
    sleep 6
    n=$((n+1))
  done
  die "STEP 4: SA ${PUBLIC_SA} never became visible after ${max} polls (~60s) — IAM propagation stalled."
}

ensure_public_sa
wait_sa_propagate
retry 5 run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/datastore.user" \
  || die "STEP 4: datastore.user grant failed after retries."
retry 5 run gcloud secrets add-iam-policy-binding "${ENROLL_SECRET}" --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/secretmanager.secretAccessor" \
  || die "STEP 4: secretAccessor on ${ENROLL_SECRET} grant failed after retries."
retry 5 run gcloud secrets add-iam-policy-binding "${PUBLIC_PKI_SECRET}" --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/secretmanager.secretAccessor" \
  || die "STEP 4: secretAccessor on ${PUBLIC_PKI_SECRET} grant failed after retries."
note "(NO run.jobs.run / heimdallJobRunner / run.developer granted — public SA cannot dispatch)"

# 4b — the no-dispatch ASSERTION. Query the SA's project roles; expand each role's
# permissions; ABORT if any grants run.jobs.run or is a dispatch/super role. This mirrors
# deploy-public-surface.sh PREFLIGHT P3 — run it here so the proof gates BEFORE step 5.
assert_no_dispatch() {
  show "gcloud projects get-iam-policy ${PROJECT_ID} --flatten='bindings[].members' --filter='bindings.members:serviceAccount:${PUBLIC_SA}' --format='value(bindings.role)'"
  if [ "$MODE" != "guided" ]; then
    note "  (plan) at guided run this ASSERTS the public SA holds NO run.jobs.run / run.developer / run.admin / owner / editor"
    return 0
  fi
  local roles r perms
  roles="$(gcloud projects get-iam-policy "${PROJECT_ID}" \
            --flatten='bindings[].members' \
            --filter="bindings.members:serviceAccount:${PUBLIC_SA}" \
            --format='value(bindings.role)' 2>/dev/null)" \
    || die "STEP 4: could not read the public SA's IAM — refusing to proceed BLIND to step 5 (the no-dispatch proof is mandatory)."
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      roles/run.developer|roles/run.admin|roles/owner|roles/editor)
        die "STEP 4: public SA ${PUBLIC_SA} holds dispatch-capable role '${r}'. ABORT — remove it before deploying the public surface." ;;
    esac
    if [[ "$r" == projects/* ]]; then
      perms="$(gcloud iam roles describe "${r##*/}" --project="${PROJECT_ID}" --format='value(includedPermissions)' 2>/dev/null)" \
        || die "STEP 4: could not expand role '${r}' to verify it lacks run.jobs.run — refusing to proceed blind."
    else
      perms="$(gcloud iam roles describe "$r" --format='value(includedPermissions)' 2>/dev/null)" \
        || die "STEP 4: could not expand role '${r}' to verify it lacks run.jobs.run — refusing to proceed blind."
    fi
    if printf '%s' "${perms}" | grep -q 'run\.jobs\.run'; then
      die "STEP 4: public SA ${PUBLIC_SA} holds role '${r}' whose permissions include run.jobs.run. ABORT — the internet-facing SA must PROVABLY lack dispatch."
    fi
  done <<< "${roles}"
  say "STEP 4 ok — public SA holds NO role granting run.jobs.run (no-dispatch PROVEN)"
}
assert_no_dispatch

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 5 — DEPLOY THE PUBLIC SERVICE (RUNBOOK §5). REUSE deploy-public-surface.sh: it
# runs P1–P5, pins the gated service's live digest, creates+grants the SA, and deploys
# heimdall-cp-public --allow-unauthenticated with HEIMDALL_PUBLIC_SURFACE=1. The
# throwaway seed is handed in by env (PUBLIC_PKI_SECRET), satisfying P4/P5.
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 5 — deploy the public surface (REUSE deploy-public-surface.sh; P1–P5 + digest pin)"
[ -x "${DEPLOY_PUBLIC}" ] || [ -f "${DEPLOY_PUBLIC}" ] || die "STEP 5: ${DEPLOY_PUBLIC} not found."
# Hand the distinct throwaway seed to the deploy via env (RUNBOOK §2.3 / §5). The VALUE is
# never passed — only the secret NAME. deploy-public-surface.sh resolves the gated digest.
DP_MODE="plan"; [ "$MODE" = "guided" ] && DP_MODE="apply"
# ENROLL_OPEN is forwarded so the public service deploys in the chosen mode (token-gated by
# DEFAULT). In token mode deploy-public-surface.sh REQUIRES cp-enroll-token (refuses if absent);
# in open mode it mounts the token only IF it exists and never fails when absent. EITHER way it
# always sets the abuse-control caps (per-IP/budget/registry) — they apply in BOTH modes.
note "enroll mode forwarded: HEIMDALL_ENROLL_OPEN=${ENROLL_OPEN} (0=token-gated [default], 1=tokenless; the abuse caps apply in BOTH modes)"
show "ENROLL_OPEN=${ENROLL_OPEN} PUBLIC_PKI_SECRET=${PUBLIC_PKI_SECRET} PUBLIC_SERVER_HAID=${PUBLIC_SERVER_HAID} bash ${DEPLOY_PUBLIC} ${DP_MODE}"
PROJECT_ID="${PROJECT_ID}" REGION="${REGION}" \
GATED_SERVICE="${GATED_SERVICE}" PUBLIC_SERVICE="${PUBLIC_SERVICE}" \
PUBLIC_SA_NAME="${PUBLIC_SA_NAME}" ENROLL_SECRET="${ENROLL_SECRET}" \
ENROLL_OPEN="${ENROLL_OPEN}" \
PUBLIC_PKI_SECRET="${PUBLIC_PKI_SECRET}" PUBLIC_SERVER_HAID="${PUBLIC_SERVER_HAID}" \
  bash "${DEPLOY_PUBLIC}" "${DP_MODE}" \
  || die "STEP 5: deploy-public-surface.sh ${DP_MODE} failed (P1–P5 / digest pin / deploy)."
say "STEP 5 ok — public-surface ${DP_MODE} complete"

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 6 — CONSISTENCY GATE (RUNBOOK §6.1). REQUIRED: check-public-surface.sh must PASS.
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 6 — consistency gate (REQUIRED — STOP if it fails)"
[ -f "${CHECK_PUBLIC}" ] || die "STEP 6: ${CHECK_PUBLIC} not found."
show "bash ${CHECK_PUBLIC}"
bash "${CHECK_PUBLIC}" || die "STEP 6: check-public-surface.sh FAILED — STOP. Do not distribute the enroll token."
say "STEP 6 ok — check-public-surface PASS"

# ════════════════════════════════════════════════════════════════════════════════════
# STEP 7 — LIVE VERIFY (RUNBOOK §7). Public /readyz -> 200 booted (alive; /healthz is
# GFE-404'd externally so we probe /readyz); public POST /dispatch -> APP 404
# {no_such_route} (boundary holds — body-checked so a GFE edge 404 can't false-green);
# public POST /presence -> 401 (allowlist reaches the app); gated unauthenticated curl
# (NO id token) -> 401/403 (the edge still demands IAM).
# Both must pass. In plan mode these are PRINTED, not executed (creds-optional).
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 7 — live boundary verify (RUNBOOK §7 — both must pass)"

if [ "$MODE" != "guided" ]; then
  note "(plan) at guided run this resolves the public+gated URLs and runs:"
  show "curl -s -w '\\n%{http_code}' \"\${PUBLIC_URL}/readyz\"   # expect 200 + booted:true (NOT /healthz — GFE 404s it)"
  show "curl -s -w '\\n%{http_code}' -X POST \"\${PUBLIC_URL}/dispatch\" -d '{}'   # expect app 404 {no_such_route} (boundary)"
  show "curl -s -o /dev/null -w '%{http_code}' -X POST \"\${PUBLIC_URL}/presence\" -d '{}'   # expect 401 (allowlist reaches app)"
  show "curl -s -o /dev/null -w '%{http_code}' -X POST \"\${GATED_URL}/dispatch\" -H 'Content-Type: application/json' -d '{}'   # expect 401/403 (NO bearer)"
  say "==> plan complete — nothing was deployed and no mutating gcloud ran."
  exit 0
fi

show "gcloud run services describe ${PUBLIC_SERVICE} --region=${REGION} --project=${PROJECT_ID} --format='value(status.url)'"
PUBLIC_URL="$(gcloud run services describe "${PUBLIC_SERVICE}" --region="${REGION}" \
                --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null)" \
  || die "STEP 7: could not resolve the public service URL."
[ -n "${PUBLIC_URL}" ] || die "STEP 7: public service has no URL — deploy may not be live."
note "public URL: ${PUBLIC_URL}"

# 7.0 — the public surface is ALIVE: GET /readyz -> 200 from OUR app (booted +
# backend_ready). NOTE: we probe /readyz, NOT /healthz — Google's Cloud Run edge
# 404s an external GET /healthz before it reaches the container (a GFE quirk: the
# request never gets an x-cloud-trace-context; /readyz is served by the SAME
# is_health_path handler and IS reachable). /readyz is also the stronger signal:
# it forces the backend init and fail-closes (503) on a broken store.
show "curl -s -w '\\n%{http_code}' ${PUBLIC_URL}/readyz"
PUB_READY_RAW="$(curl -s -w '\n%{http_code}' "${PUBLIC_URL}/readyz" 2>/dev/null || true)"
PUB_READY_CODE="$(printf '%s' "${PUB_READY_RAW}" | tail -n1)"
PUB_READY_BODY="$(printf '%s' "${PUB_READY_RAW}" | sed '$d')"
note "public GET /readyz -> ${PUB_READY_CODE}  ${PUB_READY_BODY}"
[ "${PUB_READY_CODE}" = "200" ] \
  || die "STEP 7.0: public GET /readyz returned ${PUB_READY_CODE}, expected 200 — the public surface is not ready. STOP."
printf '%s' "${PUB_READY_BODY}" | grep -q '"booted": *true' \
  || die "STEP 7.0: /readyz did not report booted:true — the container is not serving our app. STOP."
say "  ok — public GET /readyz -> 200 booted (public surface is alive + backend ready)"

# 7.1 — a gated route is 404 on the PUBLIC surface, FROM OUR APP (the boundary), not
# a GFE edge 404. We assert the JSON body {"error":"no_such_route"} so a GFE/edge
# 404 (HTML, never reached the container) can NEVER be a false-green for the boundary.
show "curl -s ${PUBLIC_URL}/dispatch -X POST -H 'Content-Type: application/json' -d '{}'   # expect app JSON 404"
PUB_DISPATCH_RAW="$(curl -s -w '\n%{http_code}' -X POST "${PUBLIC_URL}/dispatch" \
                  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
PUB_DISPATCH="$(printf '%s' "${PUB_DISPATCH_RAW}" | tail -n1)"
PUB_DISPATCH_BODY="$(printf '%s' "${PUB_DISPATCH_RAW}" | sed '$d')"
note "public POST /dispatch -> ${PUB_DISPATCH}  ${PUB_DISPATCH_BODY}"
[ "${PUB_DISPATCH}" = "404" ] \
  || die "STEP 7.1: public POST /dispatch returned ${PUB_DISPATCH}, expected 404 — the boundary LEAKED. STOP."
printf '%s' "${PUB_DISPATCH_BODY}" | grep -q 'no_such_route' \
  || die "STEP 7.1: /dispatch 404 was NOT the app boundary (no 'no_such_route' body — a GFE/edge 404). The boundary is UNVERIFIED. STOP."
say "  ok — public POST /dispatch -> app 404 {no_such_route} (boundary holds: gated route does not resolve)"

# 7.1b — a REAL public route is REACHABLE (reaches the app): POST /presence with no
# signature -> 401 (the §3 chokepoint), proving the surface serves the allowlist (not
# a service that 404s everything). 401 = reached the app; a 404 here would mean the
# allowlist itself isn't being served.
show "curl -s -o /dev/null -w '%{http_code}' -X POST ${PUBLIC_URL}/presence -d '{}'   # expect 401 (reached app, needs sig)"
PUB_PRESENCE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${PUBLIC_URL}/presence" \
                  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
note "public POST /presence -> ${PUB_PRESENCE}"
case "${PUB_PRESENCE}" in
  401|429) say "  ok — public POST /presence -> ${PUB_PRESENCE} (allowlisted route reaches the app)";;
  *) die "STEP 7.1b: public POST /presence returned ${PUB_PRESENCE}, expected 401 — the public allowlist is not being served. STOP.";;
esac

# 7.2 — the GATED service still DEMANDS the IAM token (Cloud Run edge). NO id token sent.
show "gcloud run services describe ${GATED_SERVICE} --region=${REGION} --project=${PROJECT_ID} --format='value(status.url)'"
GATED_URL="$(gcloud run services describe "${GATED_SERVICE}" --region="${REGION}" \
               --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null)" \
  || die "STEP 7: could not resolve the gated service URL."
[ -n "${GATED_URL}" ] || die "STEP 7: gated service has no URL."
note "gated URL: ${GATED_URL}"
show "curl -s -o /dev/null -w '%{http_code}' -X POST ${GATED_URL}/dispatch -H 'Content-Type: application/json' -d '{}'   # NO Authorization header"
GATED_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${GATED_URL}/dispatch" \
                  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
note "gated unauthenticated POST /dispatch -> ${GATED_NOAUTH}"
case "${GATED_NOAUTH}" in
  401|403) say "  ok — gated unauthenticated POST /dispatch -> ${GATED_NOAUTH} (Cloud Run edge demands IAM)";;
  *) die "STEP 7.2: gated unauthenticated POST /dispatch returned ${GATED_NOAUTH}, expected 401/403 — the IAM wall is NOT up. STOP.";;
esac

say ""
say "==> GO-LIVE STEPS 2–7 COMPLETE — all gates green."
note "Next (RUNBOOK §8): distribute the enroll token + public URL OUT-OF-BAND. This script"
note "does NOT read or print the enroll token value; hand it off per RUNBOOK §8."
