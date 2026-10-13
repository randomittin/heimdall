#!/usr/bin/env bash
# test/app-session-login-race.test.sh -- concurrent writers of the stored session login (a client's refresh and seq reservation, a respawned
# client's claim, a command-line revoke) never interleave: one exclusive store lock around every read-modify-write, no resurrection of a
# login a revoke removed, and a disconnect that was asked for marks the login `revoking` so that no resume claims it afterwards.
# Hermetic: loopback relay, fake phone, throwaway HOME / repo. Cases: test/lib/app_session_race_cases.py
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_race_cases.py"
echo "app-session-login-race (the stored login is written under one lock; a disconnect never ends resumed)"
for f in "$CASES" "$REPO/bin/heimdall-app" "$REPO/bin/lib/hmd_session_login.py" "$REPO/test/lib/app_session_resume_cases.py"; do
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
