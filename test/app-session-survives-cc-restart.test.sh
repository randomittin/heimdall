#!/usr/bin/env bash
# test/app-session-survives-cc-restart.test.sh -- a paired phone must never drop because Claude Code ends, restarts, resumes or sits idle (2.4.8).
# Pair a phone, end Claude Code (its process dies, the real SessionEnd hook runs), start it again (the real SessionStart hook, `claude --resume`):
# the phone stays paired with the SAME code and the SAME relay session and keeps receiving, strictly increasing seq -- also across five idle hours,
# a restart of the whole laptop with a three-day-old login and gh signed out. Only `hmd app disconnect`, a revoke from the phone or a login the
# relay refuses ends a session, and no idle shutdown is on by default.
# It is also where that rule meets the gh-token rule (the token goes out only after `hmd app connect` for the repo, once, and only when pairing needs
# it): a repo paired under 2.4.7 -- a stored login, no opt-in record -- is resumed by SessionStart with zero gh calls and zero token sends, the repo's
# code survives a restart and is the one a later connect offers, an opted-in repo with no phone paired sends the token once, and a repo never
# connected with no phone paired costs a session start nothing.
#
# Hermetic: an in-process loopback relay, a fake phone, a fake `gh`, throwaway HOME / HEIMDALL_HOME / repo, HMD_SESSION_LOGIN_STORE=file (never the
# real Keychain); only processes the test started are ever signalled.
#   test/lib/app_session_survives_cases.py   the cases; its header numbers the checks
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_session_survives_cases.py"
APP="$REPO/bin/heimdall-app"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-session-survives-cc-restart (a paired phone survives Claude Code ending, restarting, resuming and idling; only a disconnect, a revoke or a failed login ends it)"

for f in "$CASES" "$APP" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_session_login.py" "$REPO/bin/lib/hmd_session_code.py"; do
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

# the usage text tells the operator what they are promised, and no longer promises the old 24-hour resume or the 4-hour idle stop
help_text="$("$APP" --help 2>/dev/null)"
if printf '%s' "$help_text" | grep -q 'never let go of by a session ending' \
   && printf '%s' "$help_text" | grep -q 'no age limit unless the operator sets HMD_SESSION_RESUME_H' \
   && printf '%s' "$help_text" | grep -q 'unset or 0 = never, the default' \
   && ! printf '%s' "$help_text" | grep -q 'default 24; per phone' \
   && ! printf '%s' "$help_text" | grep -q 'hours (default 4, 0 = never)'; then
  ok "the usage text promises a paired phone survives a session end, documents the opt-in resume bound and idle stop, and drops the 24 h / 4 h defaults"
else
  bad "the usage text does not say a paired phone survives a session end, or still carries the 24-hour resume / four-hour idle default"
fi
if jq -e '[.hooks.SessionEnd[].hooks[].command | select(contains("pair-window --stop"))] | length == 1' "$REPO/hooks/hooks.json" >/dev/null \
   && jq -e '[.hooks[] | select(.id == "pair-window-stop") | .description | contains("NEVER stops or revokes a paired phone")] == [true]' \
        "$REPO/hooks/hooks.metadata.json" >/dev/null; then
  ok "the pair-window-stop hook is wired once, and its description says it never stops or revokes a paired phone"
else
  bad "the pair-window-stop hook is not wired exactly once, or its description does not say it never stops or revokes a paired phone"
fi

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
