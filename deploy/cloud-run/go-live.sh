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
PROJECT_ID="${PROJECT_ID:-heimdall-control-plane}"
REGION="${REGION:-us-central1}"
GATED_SERVICE="${GATED_SERVICE:-heimdall-control-plane}"
PUBLIC_SERVICE="${PUBLIC_SERVICE:-heimdall-cp-public}"
RUNTIME_SA="${RUNTIME_SA:-heimdall-cp-run@${PROJECT_ID}.iam.gserviceaccount.com}"
PUBLIC_SA_NAME="${PUBLIC_SA_NAME:-heimdall-cp-public-run}"
PUBLIC_SA="${PUBLIC_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
# Secret NAMES only — never values. (RUNBOOK §2.)
ENROLL_SECRET="${ENROLL_SECRET:-cp-enroll-token}"
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

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — install the Cloud SDK and authenticate."

say "==> heimdall go-live (${MODE} mode) — RUNBOOK steps 2–7"
note "project=${PROJECT_ID} region=${REGION}"
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
if [ -n "${LIVE_IMAGE}" ] && printf '%s' "${LIVE_IMAGE}" | grep -qF ":${HEAD_SHA}"; then
  say "STEP 2 SKIP — gated service already serves a current-main (${HEAD_SHA}) image:"
  note "${LIVE_IMAGE}"
else
  [ -n "${LIVE_IMAGE}" ] && note "gated currently serves: ${LIVE_IMAGE} (not current-main ${HEAD_SHA}) — rebuilding"
  note "build the current-main image to Artifact Registry, then redeploy the gated service onto it:"
  run gcloud builds submit "${REPO_ROOT}" --project="${PROJECT_ID}" --tag="${REBUILD_TAG}" \
    || die "STEP 2: gcloud builds submit failed — gated image not rebuilt."
  # Redeploy the gated service onto the freshly-built image (README §3 envelope), pinned
  # by the tag we just pushed; --no-allow-unauthenticated keeps the IAM wall.
  run gcloud run deploy "${GATED_SERVICE}" \
    --image="${REBUILD_TAG}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --service-account="${RUNTIME_SA}" \
    --max-instances=5 --min-instances=0 --cpu=1 --memory=512Mi \
    --timeout=300 --concurrency=80 --port=8080 \
    --no-allow-unauthenticated \
    --set-secrets="HEIMDALL_CP_PKI_KEY=${GATED_PKI_SECRET}:latest" \
    --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server,HEIMDALL_JOB_RUNNER=cloudrun-job" \
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
provision_secret "${ENROLL_SECRET}" \
  "bootstrap token verifier for token-gated /enroll (public service)" mint_token

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

# 4a — create the SA (idempotent) + grant exactly datastore + the two secretAccessors.
if [ "$MODE" = "guided" ] && gcloud iam service-accounts describe "${PUBLIC_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  say "  SA ${PUBLIC_SA} already exists — skipping create"
else
  run gcloud iam service-accounts create "${PUBLIC_SA_NAME}" --project="${PROJECT_ID}" \
    --display-name="Heimdall CP PUBLIC surface (presence/enroll/health — least privilege)" \
    || { [ "$MODE" = "guided" ] && warn "  (create returned nonzero — likely exists; continuing)"; }
fi
run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/datastore.user" \
  || die "STEP 4: datastore.user grant failed."
run gcloud secrets add-iam-policy-binding "${ENROLL_SECRET}" --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/secretmanager.secretAccessor" \
  || die "STEP 4: secretAccessor on ${ENROLL_SECRET} grant failed."
run gcloud secrets add-iam-policy-binding "${PUBLIC_PKI_SECRET}" --project="${PROJECT_ID}" \
  --member="serviceAccount:${PUBLIC_SA}" --role="roles/secretmanager.secretAccessor" \
  || die "STEP 4: secretAccessor on ${PUBLIC_PKI_SECRET} grant failed."
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
show "PUBLIC_PKI_SECRET=${PUBLIC_PKI_SECRET} PUBLIC_SERVER_HAID=${PUBLIC_SERVER_HAID} bash ${DEPLOY_PUBLIC} ${DP_MODE}"
PROJECT_ID="${PROJECT_ID}" REGION="${REGION}" \
GATED_SERVICE="${GATED_SERVICE}" PUBLIC_SERVICE="${PUBLIC_SERVICE}" \
PUBLIC_SA_NAME="${PUBLIC_SA_NAME}" ENROLL_SECRET="${ENROLL_SECRET}" \
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
# STEP 7 — LIVE VERIFY (RUNBOOK §7). Public POST /dispatch -> 404 (boundary holds);
# gated unauthenticated curl (NO id token) -> 401/403 (the edge still demands IAM).
# Both must pass. In plan mode these are PRINTED, not executed (creds-optional).
# ════════════════════════════════════════════════════════════════════════════════════
step "STEP 7 — live boundary verify (RUNBOOK §7 — both must pass)"

if [ "$MODE" != "guided" ]; then
  note "(plan) at guided run this resolves the public+gated URLs and runs:"
  show "curl -s -o /dev/null -w '%{http_code}' -X POST \"\${PUBLIC_URL}/dispatch\" -H 'Content-Type: application/json' -d '{}'   # expect 404"
  show "curl -s -o /dev/null -w '%{http_code}' \"\${PUBLIC_URL}/healthz\"   # expect 200"
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

# 7.1 — a gated route is 404 on the PUBLIC surface (app-layer boundary).
show "curl -s -o /dev/null -w '%{http_code}' -X POST ${PUBLIC_URL}/dispatch -H 'Content-Type: application/json' -d '{}'"
PUB_DISPATCH="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${PUBLIC_URL}/dispatch" \
                  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
note "public POST /dispatch -> ${PUB_DISPATCH}"
[ "${PUB_DISPATCH}" = "404" ] \
  || die "STEP 7.1: public POST /dispatch returned ${PUB_DISPATCH}, expected 404 — the boundary LEAKED. STOP."
say "  ok — public POST /dispatch -> 404 (gated route does not resolve on the public surface)"

show "curl -s -o /dev/null -w '%{http_code}' ${PUBLIC_URL}/healthz"
PUB_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/healthz" 2>/dev/null || true)"
note "public GET /healthz -> ${PUB_HEALTH}"
[ "${PUB_HEALTH}" = "200" ] \
  || die "STEP 7.1: public GET /healthz returned ${PUB_HEALTH}, expected 200 — the public surface is not alive. STOP."
say "  ok — public GET /healthz -> 200 (public surface is alive)"

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
