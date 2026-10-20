#!/usr/bin/env bash
# test/pair-window-token-optin.test.sh -- pairing by code is ON for every repo, the laptop's `gh auth token` goes out once per code, and a repo or
# a machine can say no. (The file's name is from when it proved the opposite -- an opt-in -- and is kept so its history stays one file.)
#
# Launch blocker (GTM review of 2.4.8): the SessionStart hook `pair-window-start` sent the gh token to the relay for every attended session
# while gh was signed in, and sent it again about every 5 minutes until a phone paired (the relay keeps a code registration 360 s and each
# registration carries the token). 2.4.8 made the window opt-in per repo and one registration per window. The operator's directive of
# 2026-10-20 -- "ensure that all repos connections are on by default" -- took the opt-in away and kept the rest:
#   * default on: a repo nobody ran `hmd app connect` for gets its window at the first session start. What is left of the record
#     (bin/lib/hmd_pair_optin.py, in HEIMDALL_HOME, never in the repo) is a way to say NO: `hmd app disconnect` and `connect --no-code` write
#     it as off, `hmd app connect` as on, a session's start or end writes nothing. A repo that is off, a machine with HMD_PAIR_WINDOW=0 and a laptop
#     with no gh sign-in start nothing: the hook records the session and nothing else (no relay call, no window) and exits 0 -- a gh that is not
#     signed in costs one `gh auth token` and one line on stderr naming `gh auth login`.
#   * once: a code is registered once per request (connect, add-device, a window that opens with no phone paired) and the token goes out with
#     that registration only -- no timer, no restarted client, no later session start sends it again. HMD_PAIR_WINDOW_RENEW=1 is the explicit
#     opt-in to the old schedule (what test/app-pair-confirm.test.sh still proves, with that variable set).
#
#   * which relay: a repository sets the environment of the session it is opened in (`.claude/settings.json` "env", `.envrc`), HMD_RELAY_URL
#     included, and an on-by-default window would have sent the token to whatever server it named. The environment is no longer trusted with the
#     token: a relay it names gets it only if it is the default or one the operator approved (`hmd app connect --relay URL` records it in
#     HEIMDALL_HOME, bin/lib/hmd_relay_approval.py, never in the repo). The same rule holds for `hmd app add-device`, `hmd app identity revoke`
#     and a `hmd app connect` that names no relay itself; a relay typed after --relay on the command line is the operator's own choice.
#
# Hermetic: a loopback relay (test/lib/fake_relay_code.py), a `gh` that logs each call and prints an obviously fake token (or says it is not
# logged in), throwaway HOME / repo / TMPDIR / HEIMDALL_HOME. The cases are test/lib/pair_window_token_optin_cases.py; the static checks are below.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/pair_window_token_optin_cases.py"
APP="$REPO/bin/heimdall-app"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "pair-window-token-optin (pairing by code: on by default for every repo, a repo or a machine can say no, the gh token sent once, never on a timer)"

for f in "$CASES" "$APP" "$REPO/bin/lib/hmd_pair_optin.py" "$REPO/bin/lib/hmd_relay_approval.py" "$REPO/test/lib/app_pair_confirm_cases.py" "$REPO/test/lib/fake_relay_code.py" \
         "$REPO/test/lib/pair_code_harness.py" "$REPO/README.md" "$REPO/packages/runheimdall/README.md" "$REPO/DATA.md" "$REPO/docs/INVENTORY.md" \
         "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json"; do
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
  ok "_pw_start reads the opt-in before it asks gh anything and before it starts the supervisor"
else
  bad "the opt-in read is not ahead of the gh probe and the supervisor start in _pw_start (gate '$gate', probe '$probe', start '$launch')"
fi
if [ "$(grep -c '_pair_optin set "\$REPO"' "$APP")" -ge 1 ] && [ "$(grep -c '_pair_optin off "\$REPO"' "$APP")" -ge 2 ] && ! grep -q '_pair_optin clear' "$APP"; then
  ok "connect records the repo as on, both disconnect and connect --no-code record it as off, and nothing in the app deletes the choice"
else
  bad "bin/heimdall-app does not record on in connect and off in disconnect and --no-code, or still deletes the record somewhere"
fi
if grep -nE '(export|declare -x|env) +[A-Za-z_]*(GH|GITHUB)_?TOKEN|GH_TOKEN=|GITHUB_TOKEN=' "$APP" >"$TMPROOT/env.out"; then
  bad "bin/heimdall-app puts a token in an environment variable: $(head -3 "$TMPROOT/env.out")"
else
  ok "bin/heimdall-app never puts a GitHub token in an environment variable"
fi
help_text="$("$APP" --help 2>/dev/null)"
if printf '%s' "$help_text" | grep -q 'THE TOKEN GOES OUT ONCE' && printf '%s' "$help_text" | grep -q 'ON BY DEFAULT, for every repo' \
   && printf '%s' "$help_text" | grep -q 'HMD_PAIR_WINDOW_RENEW=1' && printf '%s' "$help_text" | grep -q 'HMD_PAIR_WINDOW=0' \
   && printf '%s' "$help_text" | grep -q 'ONE line on stderr that names `gh auth login`' \
   && ! printf '%s' "$help_text" | grep -q 'OPT-IN: for a repo that `hmd app connect` has not been run for'; then
  ok "the usage text says the token goes out once, that the pair window is on by default for every repo, how a repo and a machine say no, what a signed-out gh prints, and names HMD_PAIR_WINDOW_RENEW=1 as the way back to the old schedule"
else
  bad "the usage text does not document the one-registration rule, the on-by-default window, HMD_PAIR_WINDOW=0, the gh hint or HMD_PAIR_WINDOW_RENEW=1 -- or still calls the window opt-in"
fi
if grep -q 'not on a timer' "$REPO/README.md" && grep -q 'The phone companion is on by default for pairing' "$REPO/README.md" && grep -q 'HMD_PAIR_WINDOW=0' "$REPO/README.md" \
   && ! grep -q 'nothing is sent until you run hmd app connect for a repo' "$REPO/README.md" \
   && cmp -s "$REPO/README.md" "$REPO/packages/runheimdall/README.md"; then
  ok "the README says pairing is on by default, how to turn it off, and that the token is not sent on a timer -- no longer that nothing is sent until connect (and the npm copy matches)"
else
  bad "the README sentence about the phone companion is not the on-by-default, off-switches, not-on-a-timer one, still says nothing is sent until connect, or the npm README drifted from it"
fi
if grep -q 'HMD_PAIR_WINDOW_RENEW=1' "$REPO/DATA.md" && grep -q 'pair-optin' "$REPO/DATA.md" && grep -q 'On by default, for every repo' "$REPO/DATA.md" && grep -q 'HMD_PAIR_WINDOW=0' "$REPO/DATA.md" \
   && ! grep -q 'does the same for every attended Claude Code' "$REPO/DATA.md" && ! grep -q 'Opt-in, per repo. Nothing here runs for a repo until' "$REPO/DATA.md"; then
  ok "DATA.md documents the on-by-default window, the record that says no, the one registration, HMD_PAIR_WINDOW=0 and HMD_PAIR_WINDOW_RENEW=1, and no longer calls pair-by-code opt-in"
else
  bad "DATA.md does not document the on-by-default window, the off switches or the one registration, or still calls pair-by-code opt-in"
fi
if jq -e '[.hooks[] | select(.id == "pair-window-start") | .description | contains("ONCE") and contains("on by default") and contains("HMD_PAIR_WINDOW=0") and (contains("opt-in") | not)] == [true]' "$REPO/hooks/hooks.metadata.json" >/dev/null; then
  ok "the pair-window-start hook's description says on by default, registered ONCE and HMD_PAIR_WINDOW=0, and no longer says opt-in"
else
  bad "hooks.metadata.json's pair-window-start description does not say on by default, ONCE and HMD_PAIR_WINDOW=0, or still says opt-in"
fi
if jq -e '[.hooks[] | select(.id == "pair-window-start") | .description | contains("gh auth login")] == [true]' "$REPO/hooks/hooks.metadata.json" >/dev/null \
   && grep -q 'on by default' "$REPO/docs/INVENTORY.md" && ! grep -q 'only for a repo `hmd app connect` was run for' "$REPO/docs/INVENTORY.md"; then
  ok "the hook's description and docs/INVENTORY.md both say the window is on by default and the hook's names gh auth login"
else
  bad "the hook description does not name gh auth login, or docs/INVENTORY.md still says the window is only for a repo connect was run for"
fi

relay_gate="$(grep -n '_relay_trusted "\$relay" "\$repo"' "$APP" | head -1 | cut -d: -f1)"
if [ -n "$relay_gate" ] && [ -n "$gate" ] && [ -n "$probe" ] && [ "$relay_gate" -lt "$gate" ] && [ "$relay_gate" -lt "$probe" ]; then
  ok "_pw_start asks whether the environment's relay may have the token before it reads the opt-in, asks gh anything or starts the supervisor"
else
  bad "the relay trust check is not ahead of the opt-in read and the gh probe in _pw_start (relay '$relay_gate', opt-in '$gate', probe '$probe')"
fi
if [ "$(grep -c '_relay_trusted "' "$APP")" -ge 4 ] && [ "$(grep -c '_relay_approve "' "$APP")" -ge 1 ]; then
  ok "the session start, connect, add-device and identity revoke each ask the trust check about a relay the environment named, and connect --relay records the approval"
else
  bad "bin/heimdall-app does not ask the trust check on all four token paths (found $(grep -c '_relay_trusted "' "$APP"), want 4) or never records an approval"
fi
calls="$(grep -c '_relay_trusted "' "$APP")"
asked_about_the_repo="$(grep -cE '_relay_trusted "\$(relay|RELAY_URL)" "\$(REPO|repo)"' "$APP")"
if [ "$calls" -ge 4 ] && [ "$calls" -eq "$asked_about_the_repo" ] && grep -q '_relay_approve "\$RELAY_URL" "\$REPO"' "$APP"; then
  ok "every trust check is asked about the resolved repo (\$REPO / \$repo, which resolve_repo_value made) -- never the working directory -- and the approval is recorded against it too"
else
  bad "a _relay_trusted call does not pass the resolved repo as its second argument ($calls calls, $asked_about_the_repo with \$REPO or \$repo), or _relay_approve is not handed the repo"
fi
if printf '%s' "$help_text" | grep -q 'WHICH RELAY GETS THE TOKEN' && printf '%s' "$help_text" | grep -q 'the environment is not trusted with the token' \
   && printf '%s' "$help_text" | grep -q 'app/relay-approved'; then
  ok "the usage text says which relay may have the token: the default, one named on the command line or approved with connect --relay -- never one only the environment names"
else
  bad "the usage text does not document which relay gets the token (WHICH RELAY GETS THE TOKEN, the environment not being trusted, app/relay-approved)"
fi
if grep -q 'Which relay gets the token' "$REPO/DATA.md" && grep -q 'app/relay-approved' "$REPO/DATA.md" && grep -q 'HMD_RELAY_URL' "$REPO/DATA.md"; then
  ok "DATA.md says which relay gets the token, where an approval lives (outside the repo) and that HMD_RELAY_URL alone is not one"
else
  bad "DATA.md does not document which relay gets the token and the approval store"
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
