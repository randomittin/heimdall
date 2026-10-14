#!/usr/bin/env bash
# test/pair-window-token-optin.test.sh -- the laptop's `gh auth token` reaches the relay only for a repo the operator connected, and once.
#
# Launch blocker (GTM review of 2.4.8): the SessionStart hook `pair-window-start` sent the gh token to the relay for every attended session
# while gh was signed in -- not only after `hmd app connect` -- and sent it again about every 5 minutes until a phone paired (the relay keeps
# a code registration 360 s and each registration carries the token). Now:
#   * opt-in: `hmd app connect` writes a per-repo record in HEIMDALL_HOME (bin/lib/hmd_pair_optin.py), `hmd app disconnect` and
#     `connect --no-code` remove it, a session's end does not. Without it the hook records the session and nothing else: no gh call, no
#     relay call, no window.
#   * once: a code is registered once per request (connect, add-device, a window that opens with no phone paired) and the token goes out with
#     that registration only -- no timer, no restarted client, no later session start sends it again. HMD_PAIR_WINDOW_RENEW=1 is the explicit
#     opt-in to the old schedule (what test/app-pair-confirm.test.sh still proves, with that variable set).
#
# Hermetic: a loopback relay (test/lib/fake_relay_code.py), a `gh` that logs each call and prints an obviously fake token, throwaway HOME /
# repo / TMPDIR / HEIMDALL_HOME. The cases are test/lib/pair_window_token_optin_cases.py; the static checks are below.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/pair_window_token_optin_cases.py"
APP="$REPO/bin/heimdall-app"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "pair-window-token-optin (the gh token: opt-in per repo, sent once, never on a timer)"

for f in "$CASES" "$APP" "$REPO/bin/lib/hmd_pair_optin.py" "$REPO/test/lib/app_pair_confirm_cases.py" "$REPO/test/lib/fake_relay_code.py" \
         "$REPO/test/lib/pair_code_harness.py" "$REPO/README.md" "$REPO/DATA.md" "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 jq sh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ── static checks ─────────────────────────────────────────────────────────────────────────────────────
if bash -n "$APP" 2>"$TMPROOT/syntax.err"; then
  ok "bin/heimdall-app parses"
else
  bad "bin/heimdall-app does not parse: $(head -3 "$TMPROOT/syntax.err")"
fi
gate="$(grep -n '_pair_optin check "\$repo"' "$APP" | head -1 | cut -d: -f1)"
probe="$(grep -n '_gh_token_into probe' "$APP" | head -1 | cut -d: -f1)"
launch="$(grep -n 'nohup "\$SELF" pair-window-loop' "$APP" | head -1 | cut -d: -f1)"
if [ -n "$gate" ] && [ -n "$probe" ] && [ -n "$launch" ] && [ "$gate" -lt "$probe" ] && [ "$probe" -lt "$launch" ]; then
  ok "_pw_start checks the opt-in before it asks gh anything and before it starts the supervisor"
else
  bad "the opt-in check is not ahead of the gh probe and the supervisor start in _pw_start (gate '$gate', probe '$probe', start '$launch')"
fi
if [ "$(grep -c '_pair_optin set "\$REPO"' "$APP")" -ge 1 ] && [ "$(grep -c '_pair_optin clear "\$REPO"' "$APP")" -ge 2 ]; then
  ok "connect makes the record, and both disconnect and connect --no-code remove it"
else
  bad "bin/heimdall-app does not write the record in connect or remove it in disconnect and --no-code"
fi
if grep -nE '(export|declare -x|env) +[A-Za-z_]*(GH|GITHUB)_?TOKEN|GH_TOKEN=|GITHUB_TOKEN=' "$APP" >"$TMPROOT/env.out"; then
  bad "bin/heimdall-app puts a token in an environment variable: $(head -3 "$TMPROOT/env.out")"
else
  ok "bin/heimdall-app never puts a GitHub token in an environment variable"
fi
help_text="$("$APP" --help 2>/dev/null)"
if printf '%s' "$help_text" | grep -q 'THE TOKEN GOES OUT ONCE' && printf '%s' "$help_text" | grep -q 'OPT-IN: for a repo that `hmd app connect` has not been run for' \
   && printf '%s' "$help_text" | grep -q 'HMD_PAIR_WINDOW_RENEW=1'; then
  ok "the usage text says the token goes out once, that the pair window is opt-in, and names HMD_PAIR_WINDOW_RENEW=1 as the way back"
else
  bad "the usage text does not document the one-registration rule, the opt-in or HMD_PAIR_WINDOW_RENEW=1"
fi
if grep -q 'not on a timer' "$REPO/README.md" && grep -q 'nothing is sent until you run hmd app connect for a repo' "$REPO/README.md" \
   && cmp -s "$REPO/README.md" "$REPO/packages/runheimdall/README.md"; then
  ok "the README says nothing is sent until connect was run for the repo and that the token is not sent on a timer (and the npm copy matches)"
else
  bad "the README sentence about the token is not the opt-in, not-on-a-timer one, or the npm README drifted from it"
fi
if grep -q 'HMD_PAIR_WINDOW_RENEW=1' "$REPO/DATA.md" && grep -q 'pair-optin' "$REPO/DATA.md" && ! grep -q 'does the same for every attended Claude Code' "$REPO/DATA.md"; then
  ok "DATA.md documents the opt-in record, the one registration and HMD_PAIR_WINDOW_RENEW=1, and no longer says the hook does this for every attended session"
else
  bad "DATA.md does not document the opt-in, the one registration or HMD_PAIR_WINDOW_RENEW=1, or still says the hook sends the token for every attended session"
fi
if jq -e '[.hooks[] | select(.id == "pair-window-start") | .description | contains("ONCE") and contains("opt-in")] == [true]' "$REPO/hooks/hooks.metadata.json" >/dev/null; then
  ok "the pair-window-start hook's description says opt-in and registered ONCE"
else
  bad "hooks.metadata.json's pair-window-start description does not say opt-in and ONCE"
fi

# ── the cases ─────────────────────────────────────────────────────────────────────────────────────────
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
