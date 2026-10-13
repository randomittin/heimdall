#!/usr/bin/env bash
# test/app-session-multi-resume.test.sh -- every phone paired to a repo (the first, and each one added with `hmd app add-device`) comes back
# by itself after its client is gone: `hmd app connect` and the SessionStart pair window start one client per stored login, each resuming its
# own phone's relay session with its own seq blocks -- no re-pair, no (key, nonce) repeat, and the resume limit applies per phone.
# Hermetic: loopback relay (test/lib/fake_relay_code.py), a fake `gh`, throwaway HOME / repo. Cases: test/lib/app_session_multi_cases.py
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_multi_cases.py"
echo "app-session-multi-resume (every paired phone resumes on its own after a restart)"
for f in "$CASES" "$REPO/bin/heimdall-app" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_session_login.py" \
         "$REPO/test/lib/app_pair_confirm_cases.py" "$REPO/test/lib/pair_code_harness.py" "$REPO/test/lib/fake_relay_code.py"; do
  [ -e "$f" ] || { printf 'FATAL: required file missing: %s\n\n0 passed, 1 failed\n' "$f" >&2; exit 1; }
done
bash -n "$REPO/bin/heimdall-app" || { printf 'FATAL: bin/heimdall-app does not parse\n\n0 passed, 1 failed\n' >&2; exit 1; }
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
