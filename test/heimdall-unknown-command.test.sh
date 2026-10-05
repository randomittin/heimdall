#!/usr/bin/env bash
# test/heimdall-unknown-command.test.sh -- a lone unknown word must exit 2, never launch Claude.
#
# THE BUG. bin/heimdall has no catch-all arm in its dispatch, so every word it does
# not recognise falls through to the task-prompt path -- which launches an
# autonomous Claude session (--dangerously-skip-permissions) with that word as the
# TASK. `hmd attack`, `hmd prove`, `hmd typo` each silently started an agent
# (an `hmd attack </dev/null` hung 120 s before being killed; golive-readiness
# audit 2026-10-04, finding 12). `hmd hooks` was the same bug for one real command
# and was fixed by adding its arm (dc5ef731); this suite pins the whole class.
#
# THE RULE UNDER TEST. After every dispatch arm and every flag block has had its
# chance, whatever argv is left is classified by SHAPE alone:
#   no arguments                          -> interactive session   (unchanged)
#   two or more arguments                 -> task prompt            (unchanged)
#   one argument containing whitespace    -> task prompt            (unchanged)
#   `--` first, then anything             -> task prompt, verbatim  (the explicit escape)
#   one EMPTY argument                    -> not a word: left alone (unchanged)
#   one non-empty argument, no whitespace -> a command attempt: exit 2, "unknown command"
# "Known" needs no list: a known command was already dispatched (and exited) above
# the guard, so only an UNKNOWN single word can reach it. The one list that does
# exist -- the "did you mean" candidates -- is read out of the dispatch text itself,
# and section 8 proves that with a mutated copy of the script (a hand-copied list
# would fail it).
#
# HARNESS. Every launch runs with a stub `claude` first on PATH that RECORDS its
# argv and exits 0 -- the real claude is never launched, so a regression is
# DETECTED (the stub's log) instead of starting a session. HOME, HEIMDALL_HOME and the
# working directory are throwaway dirs, stdin is /dev/null, every run is bounded.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
. "$REPO/test/lib/net-default-guard.sh"

HEIMDALL="$REPO/bin/heimdall"
HMD="$REPO/bin/hmd"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for f in "$HEIMDALL" "$HMD"; do
  [ -x "$f" ] || { echo "FATAL: $f missing or not executable"; exit 1; }
done

# ── sandbox ───────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-heimdall-unknown-cmd-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/plugin"          # a COPY of bin/heimdall: PLUGIN_DIR resolves to this dir
STUBS="$TMP/stubs"
HOME_DIR="$TMP/home"
WORK="$TMP/work"
CLAUDE_LOG="$TMP/claude.log"
STUB_LOG="$TMP/stub.log"
OUT="$TMP/out"
ERR="$TMP/err"
mkdir -p "$FAKE/bin" "$FAKE/.claude-plugin" "$STUBS" "$HOME_DIR/.heimdall" "$WORK"
cp "$HEIMDALL" "$FAKE/bin/heimdall"
chmod +x "$FAKE/bin/heimdall"
# A setup-done marker makes first_run_setup a no-op: no installs, no network.
touch "$HOME_DIR/.heimdall/setup-done"

# The stub `claude`: one `ARGV: [a] [b] ...` line per invocation. The launcher's OWN
# launch is the invocation that carries `--agent heimdall`; helper probes it makes
# (--version and friends) are recorded too but never match that marker.
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "${CLAUDE_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$STUBS/claude"

# make_stub NAME -- a routed helper in the fake plugin dir that records its argv.
make_stub() {
  cat > "$FAKE/bin/$1" <<EOF
#!/bin/sh
printf '%s ARGS: %s\n' "$1" "\$*" >> "\${HMD_STUB_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "$FAKE/bin/$1"
}
make_stub heimdall-team
make_stub heimdall-hooks
make_stub heimdall-weekly-log

# run ENTRY [ARGS...] -- run the launcher in the sandbox. Sets RC; stdout/stderr land
# in $OUT/$ERR; $CLAUDE_LOG holds every claude invocation. Bounded by a perl alarm so
# a regression that launches something long-lived cannot hang the suite.
run() {
  : > "$CLAUDE_LOG"; : > "$STUB_LOG"; : > "$OUT"; : > "$ERR"
  ( cd "$WORK" && env -i \
      PATH="$STUBS:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HOME_DIR/.heimdall" TERM=dumb \
      ANTHROPIC_API_KEY="sk-ant-unknown-command-probe" \
      HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_REUSE_METRIC=1 \
      HEIMDALL_DEFAULT_CP_URL="$HEIMDALL_DEFAULT_CP_URL" \
      CLAUDE_LOG="$CLAUDE_LOG" HMD_STUB_LOG="$STUB_LOG" \
      perl -e 'alarm 90; exec @ARGV' "$@" </dev/null >"$OUT" 2>"$ERR" )
  RC=$?
}

# The launcher's own launch line (first line of the invocation: the multi-line -p text
# only continues it). launch_has asks about THAT call, never about a helper probe.
launch_line()  { grep -F '[--agent] [heimdall]' "$CLAUDE_LOG" 2>/dev/null | head -n 1; }
launched()     { [ -n "$(launch_line)" ]; }
launch_has()   { local l; l="$(launch_line)"; case "$l" in *"$1"*) return 0 ;; esac; return 1; }
claude_has()   { grep -qF -- "$1" "$CLAUDE_LOG" 2>/dev/null; }
err_has()      { grep -qF -- "$1" "$ERR" 2>/dev/null; }
snip()         { head -c 240 "$1" 2>/dev/null | tr '\n' ' '; }

# expect_rejected LABEL -- the last run exited 2 with "unknown command" on stderr,
# nothing on stdout, and never launched claude.
expect_rejected() {
  local label="$1" why=""
  [ "$RC" -eq 2 ] || why="$why exit=$RC (want 2);"
  err_has "unknown command" || why="$why stderr lacks 'unknown command';"
  [ ! -s "$OUT" ] || why="$why stdout not empty;"
  ! launched || why="$why CLAUDE WAS LAUNCHED;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why stderr=[$(snip "$ERR")]"; fi
}

# expect_launched LABEL NEEDLE -- the last run launched claude (exit 0), the launch argv
# carries NEEDLE, and nothing called it an unknown command.
expect_launched() {
  local label="$1" needle="$2" why=""
  [ "$RC" -eq 0 ] || why="$why exit=$RC (want 0);"
  launched || why="$why claude never launched;"
  claude_has "$needle" || why="$why argv lacks [$needle];"
  ! err_has "unknown command" || why="$why stderr says unknown command;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why log=[$(snip "$CLAUDE_LOG")] stderr=[$(snip "$ERR")]"; fi
}

# expect_interactive LABEL -- launched, but with no -p prompt (the interactive session).
expect_interactive() {
  local label="$1" why=""
  [ "$RC" -eq 0 ] || why="$why exit=$RC (want 0);"
  launched || why="$why claude never launched;"
  ! launch_has '[-p]' || why="$why launched with a -p task prompt;"
  ! err_has "unknown command" || why="$why stderr says unknown command;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why log=[$(snip "$CLAUDE_LOG")] stderr=[$(snip "$ERR")]"; fi
}

# expect_suggests LABEL WORD -- the last run's stderr offers WORD as the nearest command.
expect_suggests() {
  if err_has "did you mean '$2'?"; then ok "$1"; else bad "$1 -- stderr=[$(snip "$ERR")]"; fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo "1. the acceptance line, through the real entry points"
# `hmd definitely-not-a-cmd; test $? -eq 2`
# ══════════════════════════════════════════════════════════════════════════════
run "$HMD" definitely-not-a-cmd
expect_rejected "hmd definitely-not-a-cmd exits 2 'unknown command', no launch"
run "$HEIMDALL" definitely-not-a-cmd
expect_rejected "heimdall definitely-not-a-cmd behaves identically"
err_has "'definitely-not-a-cmd'" \
  && ok "the message names the offending word" \
  || bad "the message does not quote the word -- stderr=[$(snip "$ERR")]"
for w in attack prove typo; do
  run "$HMD" "$w"
  expect_rejected "hmd $w (the three words the audit launched agents with) exits 2"
done

# ══════════════════════════════════════════════════════════════════════════════
echo "2. near-miss typos are told what they probably meant"
# ══════════════════════════════════════════════════════════════════════════════
run "$HMD" hook;        expect_rejected "hmd hook exits 2";            expect_suggests "hmd hook -> hooks" hooks
run "$HMD" statu;       expect_rejected "hmd statu exits 2";           expect_suggests "hmd statu -> status" status
run "$HMD" verison;     expect_rejected "hmd verison exits 2";         expect_suggests "hmd verison -> version" version
run "$HMD" --versoin;   expect_rejected "hmd --versoin exits 2";       expect_suggests "hmd --versoin -> --version" --version
run "$HMD" Status;      expect_rejected "hmd Status exits 2";          expect_suggests "hmd Status -> status (case only)" status
run "$HMD" updat;       expect_rejected "hmd updat exits 2";           expect_suggests "hmd updat -> update (a bare flag-ladder command)" update
for w in definitely-not-a-cmd attack prove; do
  run "$HMD" "$w"
  if err_has "did you mean"; then
    bad "hmd $w got a suggestion it should not have -- stderr=[$(snip "$ERR")]"
  else
    ok "hmd $w gets NO suggestion (nothing is close enough to guess)"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
echo "3. anything that reads as a task prompt still launches (stub claude records argv)"
# ══════════════════════════════════════════════════════════════════════════════
run "$FAKE/bin/heimdall" "fix the bug in x"
expect_launched "hmd \"fix the bug in x\" (one quoted sentence) launches with the sentence as the task" "fix the bug in x"
launch_has '[-p]' && ok "...as a -p task prompt" || bad "...but not as a -p prompt -- log=[$(snip "$CLAUDE_LOG")]"

run "$FAKE/bin/heimdall" fix the bug in x
expect_launched "hmd fix the bug in x (unquoted words) launches" "fix the bug in x"

run "$FAKE/bin/heimdall" hook list
expect_launched "hmd hook list (mistyped command + argument) launches: indistinguishable from a prompt" "hook list"

run "$FAKE/bin/heimdall" "status now"
expect_launched "hmd \"status now\" (command-looking word inside a sentence) launches" "status now"

run "$FAKE/bin/heimdall" "
multi
line"
expect_launched "a single argument containing a newline launches" "multi"

run "$FAKE/bin/heimdall" ""
if [ "$RC" -eq 0 ] && ! err_has "unknown command"; then
  ok "an EMPTY argument is not a word: not rejected (exit 0)"
else
  bad "hmd \"\" was rejected or failed -- exit=$RC stderr=[$(snip "$ERR")]"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "4. '--' is the explicit way to run a ONE-word task"
# ══════════════════════════════════════════════════════════════════════════════
run "$FAKE/bin/heimdall" -- refactor
expect_launched "hmd -- refactor launches with 'refactor' as the whole task" "/goal refactor"
run "$FAKE/bin/heimdall" -- fix the bug
expect_launched "hmd -- fix the bug launches" "/goal fix the bug"
run "$FAKE/bin/heimdall" -- --bogus
expect_launched "everything after -- is the prompt, even a flag-shaped word" "/goal --bogus"
run "$FAKE/bin/heimdall" --
expect_interactive "a bare -- with nothing after it opens the interactive session"

# ══════════════════════════════════════════════════════════════════════════════
echo "5. launcher flags are consumed BEFORE the word is classified"
# ══════════════════════════════════════════════════════════════════════════════
run "$FAKE/bin/heimdall" --auto "fix the bug in x"
expect_launched "hmd --auto \"fix the bug in x\" launches" "fix the bug in x"
launch_has '[--permission-mode] [auto]' && ok "...and --auto reached claude as --permission-mode auto" \
  || bad "...but --auto was not applied -- log=[$(snip "$CLAUDE_LOG")]"

run "$FAKE/bin/heimdall" --no-goal "fix the bug in x"
expect_launched "hmd --no-goal \"fix the bug in x\" launches" "fix the bug in x"
launch_has '/goal' && bad "--no-goal still wrapped the task in /goal" || ok "...without the /goal wrapper"

run "$FAKE/bin/heimdall" --auto typo
expect_rejected "hmd --auto typo exits 2: the flag is consumed, the lone word that is left is unknown"

run "$FAKE/bin/heimdall" --auto
expect_interactive "hmd --auto (no word at all) is still the interactive session"

run "$FAKE/bin/heimdall"
expect_interactive "bare hmd is still the interactive session"

run "$FAKE/bin/heimdall" --bogus-flag
expect_rejected "hmd --bogus-flag exits 2: a lone unknown flag is never a task"

# ══════════════════════════════════════════════════════════════════════════════
echo "6. help, version and the dispatch arms are untouched"
# ══════════════════════════════════════════════════════════════════════════════
for h in --help -h help; do
  run "$HMD" "$h"
  if [ "$RC" -eq 0 ] && grep -q '^Usage:' "$OUT" && ! err_has "unknown command" && ! launched; then
    ok "hmd $h prints usage, exits 0, launches nothing"
  else
    bad "hmd $h broke -- exit=$RC stdout=[$(snip "$OUT")] stderr=[$(snip "$ERR")]"
  fi
done
run "$HMD" --help
grep -qF 'heimdall -- <word>' "$OUT" \
  && ok "--help documents the '-- <word>' form" \
  || bad "--help does not mention 'heimdall -- <word>' -- stdout=[$(snip "$OUT")]"
grep -qF 'heimdall "build X"' "$OUT" \
  && ok "--help still documents the task-prompt form" \
  || bad "--help lost the 'heimdall \"build X\"' line"

run "$HMD" version
if [ "$RC" -eq 0 ] && grep -q '^Heimdall v' "$OUT"; then ok "hmd version still exits 0 with the version banner"
else bad "hmd version broke -- exit=$RC stdout=[$(snip "$OUT")]"; fi

run "$FAKE/bin/heimdall" team show --json
if [ "$RC" -eq 0 ] && grep -qF 'heimdall-team ARGS: show --json' "$STUB_LOG" && ! err_has "unknown command" && ! launched; then
  ok "hmd team show --json still routes to its helper (known command, never rejected)"
else
  bad "hmd team routing broke -- exit=$RC stub=[$(snip "$STUB_LOG")] stderr=[$(snip "$ERR")]"
fi
run "$FAKE/bin/heimdall" hooks --help
if [ "$RC" -eq 0 ] && grep -qF 'heimdall-hooks ARGS: --help' "$STUB_LOG" && ! launched; then
  ok "hmd hooks --help still routes to heimdall-hooks"
else
  bad "hmd hooks routing broke -- exit=$RC stub=[$(snip "$STUB_LOG")] stderr=[$(snip "$ERR")]"
fi
run "$FAKE/bin/heimdall" weekly-log
if [ "$RC" -eq 0 ] && grep -qF 'heimdall-weekly-log ARGS:' "$STUB_LOG" && ! launched; then
  ok "hmd weekly-log (bare) still routes to its helper"
else
  bad "hmd weekly-log routing broke -- exit=$RC stub=[$(snip "$STUB_LOG")] stderr=[$(snip "$ERR")]"
fi
run "$FAKE/bin/heimdall" --skills
if [ "$RC" -eq 0 ] && grep -q 'Installed skills' "$OUT" && ! err_has "unknown command" && ! launched; then
  ok "hmd --skills (a flag-ladder command, not a case arm) is not rejected"
else
  bad "hmd --skills broke -- exit=$RC stdout=[$(snip "$OUT")] stderr=[$(snip "$ERR")]"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "7. a rejection is cheap and leaves nothing behind"
# ══════════════════════════════════════════════════════════════════════════════
BEFORE="$(find "$WORK" -mindepth 1 | wc -l | tr -d ' ')"
run "$FAKE/bin/heimdall" definitely-not-a-cmd
AFTER="$(find "$WORK" -mindepth 1 | wc -l | tr -d ' ')"
[ "$BEFORE" = "$AFTER" ] \
  && ok "a rejected word writes nothing into the working directory (no CLAUDE.md, no git init)" \
  || bad "a rejected word touched the working directory ($BEFORE -> $AFTER entries)"
[ ! -s "$CLAUDE_LOG" ] \
  && ok "a rejected word makes no claude call of any kind (not even a probe)" \
  || bad "a rejected word still called claude -- log=[$(snip "$CLAUDE_LOG")]"

# ══════════════════════════════════════════════════════════════════════════════
echo "8. the known-command set IS the dispatch -- a hand-copied list would fail this"
# ══════════════════════════════════════════════════════════════════════════════
# (a) A NEW arm added to a copy of the script is suggested for a typo of it, with no
#     second place to register it.
MUT_ADD="$TMP/mut-add"; mkdir -p "$MUT_ADD/bin" "$MUT_ADD/.claude-plugin"
awk '/^  demo\)$/ { print "  zzz-mutant-arm)"; print "    echo ZZZ-MUTANT-ARM-RAN"; print "    exit 0"; print "    ;;" } { print }' \
  "$HEIMDALL" > "$MUT_ADD/bin/heimdall"
chmod +x "$MUT_ADD/bin/heimdall"
grep -q '^  zzz-mutant-arm)$' "$MUT_ADD/bin/heimdall" \
  && ok "(setup) the mutant copy carries the extra arm" \
  || bad "(setup) could not insert the mutant arm -- the 'demo)' anchor moved; fix this suite"
run "$MUT_ADD/bin/heimdall" zzz-mutant-arm
if [ "$RC" -eq 0 ] && grep -q 'ZZZ-MUTANT-ARM-RAN' "$OUT"; then ok "the new arm runs when named"
else bad "the new arm did not run -- exit=$RC stdout=[$(snip "$OUT")] stderr=[$(snip "$ERR")]"; fi
run "$MUT_ADD/bin/heimdall" zzz-mutant-arn
expect_rejected "a typo of the new arm is rejected"
expect_suggests "...and the new arm is suggested, though no list anywhere mentions it" zzz-mutant-arm

# (b) An arm that stops existing stops being suggested.
MUT_REN="$TMP/mut-ren"; mkdir -p "$MUT_REN/bin" "$MUT_REN/.claude-plugin"
sed 's/^  sigil-png)$/  sigil-pnx)/' "$HEIMDALL" > "$MUT_REN/bin/heimdall"
chmod +x "$MUT_REN/bin/heimdall"
run "$MUT_REN/bin/heimdall" sigil-pnh
expect_rejected "(rename) a typo near a renamed arm is rejected"
expect_suggests "...and the NEW name is what gets suggested" sigil-pnx
err_has "'sigil-png'" && bad "...but the old name is still suggested -- a stale list" || ok "...and the old name is gone"
run "$MUT_REN/bin/heimdall" sigil-png
expect_rejected "(rename) the old name is itself unknown now"

# (c) The extractor sees every kind of dispatch entry: case arms (single and
#     aliased), the odd names, and the flag-ladder commands that are not arms.
NAMES="$( ( cd "$WORK" && env -i PATH="$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HOME_DIR/.heimdall" \
            HEIMDALL_LIB_ONLY=1 bash -c 'f="$1"; set --; source "$f" || exit 90; _hmd_dispatch_names "$f"' _ "$HEIMDALL" ) 2>/dev/null )"
NCOUNT="$(printf '%s\n' "$NAMES" | grep -c .)"
[ "$NCOUNT" -ge 60 ] \
  && ok "the extractor finds the dispatch ($NCOUNT names, floor 60)" \
  || bad "the extractor found only $NCOUNT names (want >= 60): it is not reading the dispatch"
for n in hooks version --version -V help demo team presence beat roster wrap unwrap 529-scan caveman-audit \
         update --update --help -h --auto --resume --skills --team --uninstall; do
  printf '%s\n' "$NAMES" | grep -qx -- "$n" \
    && ok "extractor includes '$n'" \
    || bad "extractor misses '$n'"
done
printf '%s\n' "$NAMES" | grep -qxE "''|\*|" \
  && bad "extractor emitted an empty, '' or * entry" \
  || ok "extractor emits no empty, '' or * entry"

# ══════════════════════════════════════════════════════════════════════════════
echo "9. syntax"
# ══════════════════════════════════════════════════════════════════════════════
if bash -n "$HEIMDALL" 2>/dev/null; then ok "bin/heimdall passes bash -n"; else bad "bin/heimdall has a syntax error"; fi

echo ""
echo "heimdall-unknown-command: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
