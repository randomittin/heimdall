#!/usr/bin/env bash
# test/app-session-resume.test.sh -- a stopped laptop relay client must not unpair the phone: the client's relay session login is kept
# outside the repo (Keychain, else a 0600 file under $HEIMDALL_HOME), a TERMed or KILLed client revokes nothing, a new client resumes the
# same relay session for HMD_SESSION_RESUME_H hours, and only an explicit disconnect, a revoke from the phone or a failed login unpairs.
#
# Hermetic: an in-process loopback relay, a fake phone, a fake `security` for the Keychain case, throwaway HOME / repo.
#   test/lib/app_session_resume_cases.py   the cases; its header numbers the checks
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_resume_cases.py"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-session-resume (a stopped client does not unpair the phone; only a disconnect, a revoke or a failed login does)"

for f in "$CASES" "$REPO/bin/heimdall-app" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_session_login.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

python3 "$CASES" >"$TMPROOT/cases.out" 2>&1
rc=$?
grep -E '^  (ok|FAIL) ' "$TMPROOT/cases.out"
tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$TMPROOT/cases.out" | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
  ok "cases: $tally"
else
  bad "cases failed (exit $rc, tally '${tally:-none}')"
  grep -E 'Traceback|Error' -A3 "$TMPROOT/cases.out" | head -20
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
