#!/usr/bin/env bash
# test/app-session-nonce.test.sh -- a resumed relay client never seals two frames under one key with one nonce: the stored session login
# hands out seq blocks durably BEFORE they are used, the client seals nothing outside a block it holds, and a resume starts above
# everything ever handed out. Hermetic: loopback relay, fake phone, throwaway HOME / repo. Cases: test/lib/app_session_nonce_cases.py
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_nonce_cases.py"
echo "app-session-nonce (no (key, nonce) pair repeats across a kill and a resume)"
for f in "$CASES" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_session_login.py" "$REPO/test/lib/app_session_resume_cases.py"; do
  [ -e "$f" ] || { printf 'FATAL: required file missing: %s\n\n0 passed, 1 failed\n' "$f" >&2; exit 1; }
done
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
python3 "$CASES" >"$TMPROOT/cases.out" 2>&1
rc=$?
grep -E '^  (ok|FAIL) ' "$TMPROOT/cases.out"
tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$TMPROOT/cases.out" | tail -1)"
if [ "$rc" -eq 0 ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
  echo "ok: cases: $tally"; echo; echo "1 passed, 0 failed"; exit 0
fi
echo "FAIL: cases failed (exit $rc, tally '${tally:-none}')"
grep -E 'Traceback|Error' -A3 "$TMPROOT/cases.out" | head -20
echo; echo "0 passed, 1 failed"; exit 1
