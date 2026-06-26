#!/usr/bin/env bash
# check-public-surface.sh — THE GUARD for the two-service split docs+script.
#
# Three assertions, all runnable with NO GCP creds and NO spend:
#   1. SYNTAX     — `bash -n` parses deploy-public-surface.sh clean (and shellcheck if present).
#   2. CONTRACT   — the canonical PUBLIC route set is byte-identical in the deploy script AND
#                   in README.md (a drift between code and docs FAILS here).
#   3. BOUNDARY   — no GATED route name leaks into the documented PUBLIC set, and the public
#                   deploy never grants a dispatch role (run.jobs.run / run.developer).
#
# Exit 0 iff all three pass. This is the test the task's acceptance criterion runs.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="${SELF_DIR}/deploy-public-surface.sh"
README="${SELF_DIR}/README.md"

# The contract, stated ONCE here. Both the deploy script and the README must carry this
# exact string. Gated routes must NOT appear in the public set.
CANON='POST /enroll, POST /presence, GET /roster, GET /healthz, GET /readyz'
GATED_ROUTES=(/dispatch /jobs /approvals /owner /audit /schedules /ingest /dashboard /notifications)

pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=1; }
FAILED=0

[ -f "${DEPLOY_SH}" ] || { fail "missing ${DEPLOY_SH}"; exit 1; }
[ -f "${README}" ]    || { fail "missing ${README}"; exit 1; }

# ── 1. SYNTAX ────────────────────────────────────────────────────────────────────────
if bash -n "${DEPLOY_SH}" 2>/dev/null; then
  pass "bash -n: deploy-public-surface.sh parses clean"
else
  fail "bash -n: deploy-public-surface.sh has a syntax error"
fi
bash -n "${SELF_DIR}/check-public-surface.sh" 2>/dev/null \
  && pass "bash -n: check-public-surface.sh parses clean" \
  || fail "bash -n: check-public-surface.sh has a syntax error"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${DEPLOY_SH}" "${SELF_DIR}/check-public-surface.sh" \
    && pass "shellcheck: clean (warning level)" \
    || fail "shellcheck: reported issues"
else
  pass "shellcheck: not installed — skipped (bash -n covers syntax)"
fi

# ── 2. CONTRACT — the canonical public set is identical in script + README ───────────
grep -qF "PUBLIC_SURFACE_ROUTES=\"${CANON}\"" "${DEPLOY_SH}" \
  && pass "deploy script declares the canonical public route set" \
  || fail "deploy script's PUBLIC_SURFACE_ROUTES != canonical '${CANON}'"

grep -qF "${CANON}" "${README}" \
  && pass "README documents the identical public route set" \
  || fail "README is missing the canonical public route set '${CANON}'"

# ── 3. BOUNDARY — no gated route in the public set; no dispatch role in the deploy ───
# Pull the documented public set line out of the README and assert no gated path is in it.
PUBLIC_LINE="$(grep -F "${CANON}" "${README}" | head -1)"
for r in "${GATED_ROUTES[@]}"; do
  if printf '%s' "${PUBLIC_LINE}" | grep -qF "${r}"; then
    fail "gated route ${r} leaked into the documented PUBLIC set"
  fi
done
[ "${FAILED}" -eq 0 ] && pass "no gated route appears in the documented public set"

# The public deploy must NOT grant any job-dispatch role. A dispatch role named in a
# `#` comment is fine (the script EXPLAINS what it deliberately omits); what must never
# appear is an EXECUTABLE grant — a non-comment line carrying both an IAM grant verb
# (add-iam-policy-binding / create role) and a dispatch role. Strip comment lines first.
NONCOMMENT="$(grep -vE '^[[:space:]]*#' "${DEPLOY_SH}")"
BAD="$(printf '%s\n' "${NONCOMMENT}" \
       | grep -E 'add-iam-policy-binding|roles create|--role=' \
       | grep -E 'run\.jobs\.run|roles/run\.developer|heimdallJobRunner' || true)"
if [ -n "${BAD}" ]; then
  fail "public deploy has an EXECUTABLE dispatch-role grant:"
  printf '%s\n' "${BAD}" >&2
else
  pass "public deploy grants no dispatch role in any executable line (comments aside)"
fi

# The public deploy MUST set the app-layer gate and MUST be --allow-unauthenticated.
grep -qF 'HEIMDALL_PUBLIC_SURFACE=1' "${DEPLOY_SH}" \
  && pass "public deploy sets HEIMDALL_PUBLIC_SURFACE=1 (app-layer gate)" \
  || fail "public deploy is missing HEIMDALL_PUBLIC_SURFACE=1"
grep -qF -- '--allow-unauthenticated' "${DEPLOY_SH}" \
  && pass "public deploy is --allow-unauthenticated (zero-config reachable)" \
  || fail "public deploy is missing --allow-unauthenticated"

echo
if [ "${FAILED}" -eq 0 ]; then
  printf '\033[32mcheck-public-surface: PASS\033[0m\n'; exit 0
else
  printf '\033[31mcheck-public-surface: FAIL\033[0m\n'; exit 1
fi
