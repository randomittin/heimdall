#!/usr/bin/env bash
# test/session-login-no-keychain.test.sh -- the relay session login (bin/lib/hmd_session_login.py) never asks macOS for a keychain that is not
# there. 2026-10-19: under `env -i HOME=<throwaway>` (a test harness that drops the sweep's HMD_SESSION_LOGIN_STORE=file) a bound phone's
# login went to `security -i add-generic-password` with no keychain to put it in, and macOS opened a "Keychain Not Found ... Reset To
# Defaults" dialog -- while `security -i` waited for a human. The store now asks first (`security default-keychain`, which only reads),
# uses the Keychain only when one exists under this HOME, else the 0600 file (one notice on stderr), and kills any `security` call at a bound.
#
# Hermetic: a throwaway HOME / HEIMDALL_HOME / repo and a STUB `security` that is the only thing on PATH (the real binary is unreachable, so
# no Keychain is touched) and fails a case the moment an add / find / delete / `-i` reaches it with no keychain to serve it.
#   test/lib/session_login_no_keychain_cases.py   the cases; its header numbers the checks
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/session_login_no_keychain_cases.py"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "session-login-no-keychain (no keychain for this HOME: the file store, never a Keychain Not Found dialog; every security call bounded)"

for f in "$CASES" "$REPO/bin/lib/hmd_session_login.py" "$REPO/test/lib/app_session_resume_cases.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 git; do
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
