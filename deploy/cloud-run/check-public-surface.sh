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
# Scan EVERY line that documents the canonical public set, not just the first. A
# `head -1` here made this check vacuous: a leak on the second or third canonical
# line was never examined, so the same defect passed or failed purely on its line
# number. The count is asserted below so an empty scan can never read as clean.
scan_public_lines() { # scan_public_lines <label> <file>
  local label="$1" file="$2" n=0 leaked=0 line r
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    n=$((n + 1))
    for r in "${GATED_ROUTES[@]}"; do
      if printf '%s' "${line}" | grep -qF "${r}"; then
        fail "gated route ${r} leaked into the ${label}'s documented PUBLIC set: ${line}"
        leaked=1
      fi
    done
  done <<EOF
$(grep -F "${CANON}" "${file}")
EOF
  if [ "${n}" -eq 0 ]; then
    fail "VACUOUS: 0 canonical public-set lines found in ${label} — the gated-route scan examined nothing"
    return 1
  fi
  [ "${leaked}" -eq 0 ] && pass "no gated route in any of the ${n} canonical public-set line(s) in ${label}"
  return 0
}
scan_public_lines "README" "${README}"

# The public deploy must NOT grant any job-dispatch role. A dispatch role named in a
# `#` comment is fine (the script EXPLAINS what it deliberately omits); what must never
# appear is an EXECUTABLE grant — a non-comment line carrying both an IAM grant verb
# (add-iam-policy-binding / create role) and a dispatch role. Strip comment lines first.
NONCOMMENT="$(grep -vE '^[[:space:]]*#' "${DEPLOY_SH}")"
NONCOMMENT_N="$(printf '%s\n' "${NONCOMMENT}" | grep -c '[^[:space:]]' || true)"
# ANTI-VACUOUS: zero executable lines means this assertion scanned an empty haystack.
# "No dispatch grant found" over nothing examined is not a finding, it is a blind spot.
if [ "${NONCOMMENT_N}" -eq 0 ]; then
  fail "VACUOUS: ${DEPLOY_SH} has 0 executable (non-comment) lines — the dispatch-role scan examined nothing"
else
  # Join backslash line-continuations FIRST. `gcloud ... --role \` + newline +
  # `roles/run.developer` is one logical command but two physical lines, and a
  # per-physical-line grep sees an IAM verb with no role and a role with no verb,
  # so it matches neither and the grant sails through.
  JOINED="$(printf '%s\n' "${NONCOMMENT}" | awk '
    { if (buf != "") { sub(/^[ \t]+/, ""); line = buf " " $0 } else { line = $0 }
      if (line ~ /\\$/) { sub(/\\$/, "", line); buf = line } else { buf = ""; print line } }
    END { if (buf != "") print buf }')"
  DISPATCH_RE='run\.jobs\.run|roles/run\.developer|heimdallJobRunner'
  # A grant line: an IAM verb AND a dispatch role on the same logical line. `--role`
  # (not `--role=`) so the space-separated form `--role roles/run.developer` counts.
  BAD="$(printf '%s\n' "${JOINED}" \
         | grep -E 'add-iam-policy-binding|roles create|--role' \
         | grep -E "${DISPATCH_RE}" || true)"
  # Second shape: the role BOUND TO A VARIABLE (`ROLE=roles/run.developer`) and later
  # passed as `--role="$ROLE"`. The grant line then carries no literal role, so the
  # correlation above matches neither line and the grant sails through. Deliberately
  # scoped to ASSIGNMENTS, not to any mention: this script legitimately PRINTS the
  # role names in operator-facing `say "... no run.jobs.run ..."` messages, and a
  # string in an echo cannot become a grant.
  ASSIGN_RE="(^|[[:space:]]|;)(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[\"']?(${DISPATCH_RE})"
  VARBOUND="$(printf '%s\n' "${JOINED}" | grep -E "${ASSIGN_RE}" || true)"
  if [ -n "${BAD}" ]; then
    fail "public deploy has an EXECUTABLE dispatch-role grant:"
    printf '%s\n' "${BAD}" >&2
  elif [ -n "${VARBOUND}" ]; then
    fail "public deploy BINDS a dispatch role to a variable — it can reach a grant indirectly via --role=\"\$VAR\":"
    printf '%s\n' "${VARBOUND}" >&2
  else
    pass "no dispatch-role grant or role-bound variable in any of the ${NONCOMMENT_N} executable line(s) of the public deploy (comments aside)"
  fi
fi

# The public deploy MUST set the app-layer gate and MUST be --allow-unauthenticated.
grep -qF 'HEIMDALL_PUBLIC_SURFACE=1' "${DEPLOY_SH}" \
  && pass "public deploy sets HEIMDALL_PUBLIC_SURFACE=1 (app-layer gate)" \
  || fail "public deploy is missing HEIMDALL_PUBLIC_SURFACE=1"
grep -qF -- '--allow-unauthenticated' "${DEPLOY_SH}" \
  && pass "public deploy is --allow-unauthenticated (zero-config reachable)" \
  || fail "public deploy is missing --allow-unauthenticated"

# ── 4. RUNBOOK doc-lint — the go-live runbook references the real scripts + route set ─
# The runbook drives the deploy; if it drifts from the real script names or the canonical
# public route set, an operator follows stale instructions. Assert the references are real.
RUNBOOK="${SELF_DIR}/GO-LIVE-RUNBOOK.md"
if [ -f "${RUNBOOK}" ]; then
  grep -qF 'deploy-public-surface.sh' "${RUNBOOK}" \
    && pass "runbook references deploy-public-surface.sh" \
    || fail "runbook does not reference deploy-public-surface.sh"
  grep -qF 'check-public-surface.sh' "${RUNBOOK}" \
    && pass "runbook references check-public-surface.sh (the required gate)" \
    || fail "runbook does not reference check-public-surface.sh"
  grep -qF "${CANON}" "${RUNBOOK}" \
    && pass "runbook carries the identical canonical public route set" \
    || fail "runbook is missing the canonical public route set '${CANON}'"
  # No gated route may appear in ANY of the runbook's documented public-set lines
  # (same head -1 vacuity as the README scan above — every line gets examined).
  scan_public_lines "runbook" "${RUNBOOK}"
else
  fail "missing ${RUNBOOK} (the go-live runbook the deploy sequence depends on)"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  printf '\033[32mcheck-public-surface: PASS\033[0m\n'; exit 0
else
  printf '\033[31mcheck-public-surface: FAIL\033[0m\n'; exit 1
fi
