#!/usr/bin/env bash
# test/app-session-revoke-race.test.sh -- a disconnect and a resume never interleave into a phone that comes back after it was revoked or
# forgotten: the disconnect marks every login `revoking` first (all of them, under the store lock), every resume start (a periodic look, a
# respawn, the SessionStart pair window, a --resume-only client) claims under that lock and skips what is marked or gone, and a client that got
# through anyway ends itself and revokes once its login is marked or gone. Hermetic: loopback relays, fake phones, a fake `gh`, throwaway HOME.
# Cases: test/lib/app_session_revoke_race_cases.py
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_revoke_race_cases.py"
echo "app-session-revoke-race (no client ever attaches to a phone that was marked revoking or forgotten)"
for f in "$CASES" "$REPO/bin/heimdall-app" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_session_login.py" \
         "$REPO/test/lib/app_session_resume_cases.py" "$REPO/test/lib/app_session_multi_cases.py" "$REPO/test/lib/app_pair_confirm_cases.py"; do
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
