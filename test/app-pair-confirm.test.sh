#!/usr/bin/env bash
# test/app-pair-confirm.test.sh -- code-only pairing (hmdapp's docs/HANDOFF-TO-HEIMDALL-pair-confirm-in-session.md): typing the
# 5-character session code on a phone signed in to the same GitHub account pairs at once, with no 6-digit compare, also with
# `hmd app connect --bg` and with no terminal; --confirm restores the compare; one session code is derived for the statusline,
# `hmd ui`, `hmd app` and the pair window; every session keeps a window open; a pairing leaves a notice and a statusline note.
# The window's token back-off: it re-registers its code -- the gh token is in that request -- no more often than a floor and
# stops after HMD_PAIR_WINDOW_IDLE_H hours with no pairing and no activity in its session.
#
# Hermetic, like test/app-pair-code.test.sh: a loopback relay (test/lib/fake_relay_code.py), a `gh` script in the sandbox's PATH
# that prints an obviously fake token, throwaway HOME / repo / TMPDIR / HEIMDALL_HOME, free ports, nothing on the network.
#   test/lib/app_pair_confirm_cases.py  the spec's nine acceptance tests (the file's header says which check proves which),
#                                       one case for each finding of the security review of bin/lib/hmd_session_code.py, and
#                                       the back-off's: renewals counted over simulated time, the idle stop on an injected clock
# plus the static checks below. Acceptance 7's "hmd ui lists the device and revoke removes it" is NOT here: that is CP4, which
# this tree does not have (see the cases file's header).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_pair_confirm_cases.py"
APP="$REPO/bin/heimdall-app"
CLIENT="$REPO/bin/heimdall-relay-client"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-pair-confirm (code-only pairing: no compare by default, one session code, a window in every session)"

for f in "$CASES" "$APP" "$CLIENT" "$REPO/test/lib/fake_relay_code.py" "$REPO/test/lib/pair_code_harness.py" \
         "$REPO/test/lib/statusline_sandbox.py" "$REPO/bin/lib/hmd_session_code.py" "$REPO/bin/lib/hmd_private_state.py" \
         "$REPO/bin/lib/hmd_app_code.py" "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json"; do
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
if "$REPO/bin/heimdall-hooks" check --quiet --hooks "$REPO/hooks/hooks.json" --metadata "$REPO/hooks/hooks.metadata.json" 2>"$TMPROOT/hooks.err"; then
  ok "hooks.json and hooks.metadata.json agree (the two pair-window hooks are registered, with fingerprints)"
else
  bad "hooks drift: $(head -3 "$TMPROOT/hooks.err")"
fi
if jq -e '[.hooks.SessionStart[].hooks[].command | select(contains("pair-window --session"))] | length == 1' "$REPO/hooks/hooks.json" >/dev/null \
   && jq -e '[.hooks.SessionEnd[].hooks[].command | select(contains("pair-window --stop"))] | length == 1' "$REPO/hooks/hooks.json" >/dev/null; then
  ok "SessionStart opens the window and SessionEnd closes it, once each"
else
  bad "the pair-window hooks are not wired exactly once each"
fi
if jq -e '[.hooks.SessionStart[].hooks[].command | select(contains("pair-window --session"))][0] | contains(".transcript_path") and contains("--transcript")' \
     "$REPO/hooks/hooks.json" >/dev/null; then
  ok "the SessionStart hook hands the window its session's transcript (the activity the idle stop watches)"
else
  bad "the pair-window-start hook does not pass the session's transcript_path to the window"
fi
help_text="$("$APP" --help 2>/dev/null)"
missing_docs="$(for want in HMD_PAIR_WINDOW_IDLE_H HMD_PAIR_WINDOW_RENEW_MIN_S HMD_PAIR_WINDOW_RENEW_LEAD_S --transcript; do
  printf '%s' "$help_text" | grep -q -- "$want" || printf '%s ' "$want"
done)"
if [ -z "$missing_docs" ]; then
  ok "the usage text documents the window's renewal floor, margin and idle stop (and --transcript)"
else
  bad "the usage text does not mention: $missing_docs"
fi
if grep -nE '(export|declare -x|env) +[A-Za-z_]*(GH|GITHUB)_?TOKEN|GH_TOKEN=|GITHUB_TOKEN=' "$APP" >"$TMPROOT/env.out"; then
  bad "bin/heimdall-app puts a token in an environment variable: $(head -3 "$TMPROOT/env.out")"
else
  ok "bin/heimdall-app never puts a GitHub token in an environment variable (the window's included)"
fi
if grep -nE 'gh_token.*(log|emit|print)' "$CLIENT" >"$TMPROOT/leak.out"; then
  bad "a relay-client line names the token near log/emit/print: $(head -3 "$TMPROOT/leak.out")"
else
  ok "no relay-client line puts the token near a log, emit or print (the new events name a login, never a token)"
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
