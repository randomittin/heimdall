#!/usr/bin/env bash
# test/lean-dispatch.test.sh -- `hmd lean ...` and `hmd reinstall --reset` (3.x lean-core plan docs/superpowers/plans/2026-11-12-3x-lean-core.md,
# task T4.2; .planning/lean-core/INVARIANTS.md INV-L8, INV-L10).
#
# THE DEFECT CLASS. A word the dispatcher does not name is read as a TASK PROMPT: `hmd lean on` would start a Claude run with "lean on" as the task.
# And the one reinstall this launcher already knows, the `--reinstall` flag, wipes ~/.heimdall, which is the plugin clone AND the home of the
# ledger, receipts, memory, team and pairing. The lean reset has to reach the installed install.sh and nothing else: an in-place reset that
# deletes user data is the one failure this feature may not have.
#
# THE CONTRACT UNDER TEST
#   A  hmd lean: reaches bin/heimdall-lean with the verb consumed and every argument verbatim; its exit status comes back unchanged; bare
#      `hmd lean` is the tool's own answer; a tool that is missing or not executable is exit 1 and a not-found message; none of it starts Claude
#   B  hmd reinstall --reset: execs the INSTALLED install.sh as `--reset` plus every other argument (--yes) in order, one --reset whatever
#      order the operator typed; an install.sh without --reset, or none at all, is not run: exit 1 and the pinned installer one-liner, which is
#      printed and never run
#   C  hmd reinstall without --reset: usage on stderr, exit 2, nothing runs; --help is the usage on stdout, exit 0
#   D  the wrapper never reaches the wipe: no rm call, no curl call, the data under HEIMDALL_HOME byte-identical, and the arm's own code has no rm
#      and never names the `--reinstall` flag block or the plugin remover
#   E  the controls that make D and A mean something: an unrouted command CAN start the launch path in this sandbox (the trace fills), and the old
#      `--reinstall` flag in the same sandbox DOES trip the rm trap and reach curl
#   F  hmd help (and --help) lists lean and reinstall --reset; bin/heimdall parses. (The runhmd subcommand list, packages/runhmd/subcommands.txt, is
#      held by section 4 of test/runhmd-parity.test.sh, which fails on a dispatched word it does not list; it is not repeated here.)
#
# HERMETIC. HOME, HEIMDALL_HOME and the project are throwaway; the launcher under test is a COPY of bin/heimdall inside a fake plugin dir (so its
# PLUGIN_DIR is the fake dir, as in test/heimdall-cli-routing.test.sh) holding a fixture bin/heimdall-lean and a fixture install.sh; `claude`, `curl`
# and `rm` are PATH fakes (rm is a TRAP: it records its argv and removes nothing). Nothing reads the operator's machine, nothing touches the network.
# LEAN_DISPATCH_LAUNCHER=<file> points the copy at another launcher (a mutant, for the break-it check).
# budget: about 10 s solo: roughly forty launches of bin/heimdall, each a bash start and no python. No network.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HMD="${LEAN_DISPATCH_LAUNCHER:-$REPO/bin/heimdall}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
# t NAME [DETAIL]: the verdict of the command just before it. DETAIL is single-quoted at the call and expanded only on a failure: a
# command substitution in an argument would run BEFORE this function and replace the status it is about to read.
t() {
  local status=$?
  if [ "$status" -eq 0 ]; then ok "$1"; else eval "bad \"\$1\" \"${2:-}\""; fi
}

echo "lean-dispatch"

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lean-dispatch.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PLUG="$TMP/plugin"; FAKEBIN="$TMP/fakebin"; HOME_DIR="$TMP/home"; HH="$HOME_DIR/.heimdall"; PROJ="$TMP/proj"
mkdir -p "$PLUG/bin" "$FAKEBIN" "$PROJ" "$HH"
cp "$HMD" "$PLUG/bin/heimdall"
LEAN_OUT="$TMP/lean.out"; INSTALL_OUT="$TMP/install.out"
RM_LOG="$TMP/rm.log"; CURL_LOG="$TMP/curl.log"; CLAUDE_LOG="$TMP/claude.log"; TRACE="$TMP/trace"
: >"$LEAN_OUT"; : >"$INSTALL_OUT"; : >"$RM_LOG"; : >"$CURL_LOG"; : >"$CLAUDE_LOG"; : >"$TRACE"

# The user data the launcher's home holds, and the setup marker (a word that fell through to the launcher would then skip first-run setup).
for d in ledger receipts memory team pairing data; do mkdir -p "$HH/$d"; printf 'canary %s\n' "$d" >"$HH/$d/keep.txt"; done
touch "$HH/setup-done"
canary_sum() { ( cd "$HH" && for d in ledger receipts memory team pairing data; do cat "$d/keep.txt" 2>/dev/null || echo "MISSING $d"; done | cksum ); }
CANARY="$(canary_sum)"

cat >"$FAKEBIN/claude" <<'SH'
#!/bin/sh
# fake claude: records its argv; the launcher's probes get plausible answers; anything else would be a Claude run
printf '%s\n' "$*" >>"$FAKE_CLAUDE_LOG"
case "$*" in
  "--version") echo "1.99.0 (Claude Code)" ;;
  "plugins list --json") echo "[]" ;;
esac
exit 0
SH
cat >"$FAKEBIN/curl" <<'SH'
#!/bin/sh
# fake curl: records its argv and fetches nothing
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
exit 0
SH
cat >"$FAKEBIN/rm" <<'SH'
#!/bin/sh
# fake rm, the TRAP: records its argv and removes nothing, so a wipe the launcher attempts is seen and not suffered
printf '%s\n' "$*" >>"$FAKE_RM_LOG"
exit 0
SH
cat >"$PLUG/bin/heimdall-lean" <<'SH'
#!/usr/bin/env bash
# fixture heimdall-lean: records the argv it was exec'd with, one [word] per argument
{ printf 'ARGS:'; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >>"$FAKE_LEAN_OUT"
echo "fixture heimdall-lean ran"
exit "${FAKE_LEAN_RC:-0}"
SH
cat >"$PLUG/install.sh" <<'SH'
#!/usr/bin/env bash
# fixture install.sh that knows --reset: records its own path and its argv
printf '%s\n' "$0" >"$FAKE_INSTALL_OUT.self"
{ printf 'ARGS:'; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >>"$FAKE_INSTALL_OUT"
case "${1:-}" in --reset) echo "fixture install.sh ran the reset" ;; esac
exit "${FAKE_INSTALL_RC:-0}"
SH
cat >"$TMP/install.legacy" <<'SH'
#!/usr/bin/env bash
# fixture install.sh from before the flag existed: it only marks that it ran
echo ran >"$FAKE_INSTALL_OUT.legacy"
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/curl" "$FAKEBIN/rm" "$PLUG/bin/heimdall-lean" "$PLUG/install.sh" "$TMP/install.legacy"
cp "$PLUG/install.sh" "$TMP/install.reset"          # the install.sh that supports --reset, kept to put back

# What the operator's environment could bend: none of it may reach the launcher.
unset HEIMDALL_REF HEIMDALL_REPO CLAUDE_PLUGIN_ROOT WORK_DIR HEIMDALL_WRAP_LAUNCHED HMD_LAUNCHER_PID HMD_RELAUNCHED HMD_RESUME_SESSION_ID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

RC=0; OUT=""; ERR=""
hmd() {  # hmd ARGS... -> RC, OUT, ERR: the launcher copy in the fake plugin dir, from a throwaway project, the fakes first on PATH.
  # ANTHROPIC_API_KEY passes the launcher's sign-in gate, so a word that is NOT routed reaches the launch point (and the trace).
  OUT="$(cd "$PROJ" && PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HH" ANTHROPIC_API_KEY=sk-test-not-a-key \
         FAKE_CLAUDE_LOG="$CLAUDE_LOG" FAKE_CURL_LOG="$CURL_LOG" FAKE_RM_LOG="$RM_LOG" FAKE_LEAN_OUT="$LEAN_OUT" FAKE_INSTALL_OUT="$INSTALL_OUT" \
         FAKE_LEAN_RC="${FAKE_LEAN_RC:-0}" FAKE_INSTALL_RC="${FAKE_INSTALL_RC:-0}" HEIMDALL_TRACE_ORDER="$TRACE" \
         HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 bash "$PLUG/bin/heimdall" "$@" 2>"$TMP/stderr" </dev/null)"; RC=$?
  ERR="$(cat "$TMP/stderr")"
}
# The per-call records (what the two tools were exec'd with) start empty at each call; the trap, curl, claude and trace logs accumulate
# across sections A to C and are read once, in D.
reset_calls() { : >"$LEAN_OUT"; : >"$INSTALL_OUT"; rm -f "$INSTALL_OUT.self" "$INSTALL_OUT.legacy"; }
has()    { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
errhas() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
lean_argv()    { cat "$LEAN_OUT" 2>/dev/null; }
install_argv() { cat "$INSTALL_OUT" 2>/dev/null; }
launched() {  # a launch trace line, or a `claude` call that is not one of the launcher's probes
  [ -s "$TRACE" ] && return 0
  grep -qvx -e 'plugins list --json' -e '--version' "$CLAUDE_LOG" 2>/dev/null
}
wiped() {  # an rm with a recursive flag, or one naming HEIMDALL_HOME or the plugin dir
  grep -Eq -- '(^| )-[a-zA-Z]*[rR]|--recursive' "$RM_LOG" 2>/dev/null && return 0
  grep -qF -e "$HH" -e "$PLUG" "$RM_LOG" 2>/dev/null
}
code_of() {  # the code lines, comments left out, of the `  NAME)` arm of the launcher's top-level dispatch case
  awk -v name="$1" '$0 == "  " name ")" { on = 1; next } on && /^    ;;[[:space:]]*$/ { exit } on' "$PLUG/bin/heimdall" | grep -v '^[[:space:]]*#'
}

# ── A. hmd lean ──────────────────────────────────────────────────────────────────────────────────────────────────
echo "A. hmd lean"
reset_calls; hmd lean status
[ "$RC" -eq 0 ] && [ "$(lean_argv)" = "ARGS:[status]" ] && has "fixture heimdall-lean ran"
t "A1 hmd lean status reaches bin/heimdall-lean with the verb consumed: argv is exactly [status], exit 0" 'rc=$RC argv=$(lean_argv) out=$(printf "%s" "$OUT" | head -c 120) err=$ERR'
reset_calls; hmd lean on --yes
[ "$(lean_argv)" = "ARGS:[on][--yes]" ]; t "A2 hmd lean on --yes: every argument forwarded, in order" 'rc=$RC argv=$(lean_argv) err=$ERR'
reset_calls; hmd lean off 'two words' '*' ''
[ "$(lean_argv)" = "ARGS:[off][two words][*][]" ]; t "A3 arguments arrive verbatim: a space, a glob, an empty string" 'rc=$RC argv=$(lean_argv) err=$ERR'
reset_calls; FAKE_LEAN_RC=7 hmd lean off
[ "$RC" -eq 7 ]; t "A4 the tool's exit status comes back unchanged (7)" 'rc=$RC argv=$(lean_argv)'
reset_calls; hmd lean
[ "$RC" -eq 0 ] && [ "$(lean_argv)" = "ARGS:" ]; t "A5 bare hmd lean reaches the tool with no arguments: its own usage answers, the launcher starts no task" 'rc=$RC argv=$(lean_argv) err=$ERR'
mv "$PLUG/bin/heimdall-lean" "$TMP/heimdall-lean.keep"
reset_calls; hmd lean status
[ "$RC" -eq 1 ] && errhas "heimdall-lean not found" && [ ! -s "$LEAN_OUT" ]; t "A6 bin/heimdall-lean missing: exit 1 and a not-found error" 'rc=$RC err=$ERR'
cp "$TMP/heimdall-lean.keep" "$PLUG/bin/heimdall-lean"; chmod -x "$PLUG/bin/heimdall-lean"
reset_calls; hmd lean status
[ "$RC" -eq 1 ] && errhas "heimdall-lean not found" && [ ! -s "$LEAN_OUT" ]; t "A7 bin/heimdall-lean not executable: exit 1 and a not-found error, the tool is not run" 'rc=$RC err=$ERR'
chmod +x "$PLUG/bin/heimdall-lean"

# ── B. hmd reinstall --reset ─────────────────────────────────────────────────────────────────────────────────────
echo "B. hmd reinstall --reset"
reset_calls; hmd reinstall --reset
[ "$RC" -eq 0 ] && [ "$(install_argv)" = "ARGS:[--reset]" ] && [ "$(cat "$INSTALL_OUT.self" 2>/dev/null)" = "$PLUG/install.sh" ] && has "fixture install.sh ran the reset"
t "B1 hmd reinstall --reset runs the INSTALLED install.sh (its own path) with exactly [--reset]" 'rc=$RC argv=$(install_argv) self=$(cat "$INSTALL_OUT.self" 2>/dev/null) err=$ERR'
reset_calls; hmd reinstall --reset --yes
[ "$(install_argv)" = "ARGS:[--reset][--yes]" ]; t "B2 --yes passes through, after --reset" 'rc=$RC argv=$(install_argv) err=$ERR'
reset_calls; hmd reinstall --yes --reset
[ "$(install_argv)" = "ARGS:[--reset][--yes]" ]; t "B3 --yes typed before --reset: install.sh still gets --reset first and --yes after" 'rc=$RC argv=$(install_argv) err=$ERR'
reset_calls; hmd reinstall --reset --reset -y 'two words'
[ "$(install_argv)" = "ARGS:[--reset][-y][two words]" ]; t "B4 a repeated --reset is one --reset; the other arguments stay verbatim and in order" 'rc=$RC argv=$(install_argv) err=$ERR'
reset_calls; FAKE_INSTALL_RC=5 hmd reinstall --reset
[ "$RC" -eq 5 ]; t "B5 install.sh's exit status comes back unchanged (exec, nothing in between)" 'rc=$RC argv=$(install_argv)'

cp "$TMP/install.legacy" "$PLUG/install.sh"; chmod +x "$PLUG/install.sh"
reset_calls; hmd reinstall --reset --yes
[ "$RC" -eq 1 ] && [ ! -e "$INSTALL_OUT.legacy" ] && errhas 'curl -fsSL https://runheimdall.dev/install | bash -s -- --reset --yes'
t "B6 an install.sh without --reset is NOT run: exit 1 and the pinned installer one-liner on stderr, with the same arguments" 'rc=$RC ran=$(ls "$INSTALL_OUT.legacy" 2>/dev/null) err=$ERR'
[ ! -s "$CURL_LOG" ]; t "B7 ...and that one-liner is printed, never run: the fake curl was not called" 'curl=$(cat "$CURL_LOG")'
rm -f "$PLUG/install.sh"
reset_calls; hmd reinstall --reset
[ "$RC" -eq 1 ] && errhas 'curl -fsSL https://runheimdall.dev/install | bash -s -- --reset'; t "B8 no install.sh at all: the same one-liner and exit 1" 'rc=$RC err=$ERR'
cp "$TMP/install.reset" "$PLUG/install.sh"; chmod +x "$PLUG/install.sh"

# ── C. hmd reinstall without --reset ─────────────────────────────────────────────────────────────────────────────
echo "C. hmd reinstall without --reset"
reset_calls; hmd reinstall
[ "$RC" -eq 2 ] && errhas "Usage: hmd reinstall --reset" && [ -z "$OUT" ] && [ ! -s "$INSTALL_OUT" ]
t "C1 bare hmd reinstall: usage on stderr, nothing on stdout, exit 2, install.sh not run" 'rc=$RC out=$OUT err=$ERR argv=$(install_argv)'
reset_calls; hmd reinstall --yes
[ "$RC" -eq 2 ] && [ ! -s "$INSTALL_OUT" ]; t "C2 hmd reinstall --yes (no --reset): exit 2, install.sh not run" 'rc=$RC argv=$(install_argv) err=$ERR'
reset_calls; hmd reinstall --bogus
[ "$RC" -eq 2 ] && [ ! -s "$INSTALL_OUT" ]; t "C3 hmd reinstall --bogus: exit 2, install.sh not run" 'rc=$RC argv=$(install_argv) err=$ERR'
reset_calls; hmd reinstall --help
[ "$RC" -eq 0 ] && has "Usage: hmd reinstall --reset" && [ ! -s "$INSTALL_OUT" ]; t "C4 hmd reinstall --help: the usage on stdout, exit 0, install.sh not run" 'rc=$RC out=$(printf "%s" "$OUT" | head -c 120) argv=$(install_argv)'

# ── D. nothing above reached the wipe or the launch path ─────────────────────────────────────────────────────────
echo "D. the wrapper never reaches the wipe"
! wiped; t "D1 no rm with a recursive flag, and none naming HEIMDALL_HOME or the plugin dir, in any run above" 'rm calls: $(tr "\n" ";" <"$RM_LOG")'
[ ! -s "$CURL_LOG" ]; t "D2 no run above called curl" 'curl calls: $(tr "\n" ";" <"$CURL_LOG")'
[ "$(canary_sum)" = "$CANARY" ]; t "D3 ledger, receipts, memory, team, pairing and data under HEIMDALL_HOME are byte-identical" 'before=$CANARY after=$(canary_sum)'
! launched; t "D4 no run above started a Claude run (empty launch trace, no claude call but the probes)" 'trace=$(tr "\n" ";" <"$TRACE") claude=$(tr "\n" ";" <"$CLAUDE_LOG")'
ARM="$(code_of reinstall)"
[ -n "$ARM" ] && ! printf '%s\n' "$ARM" | grep -Eq '(^|[^[:alnum:]_./-])rm([[:space:]]|$)' && ! printf '%s\n' "$ARM" | grep -qF -e '--reinstall' -e '_heimdall_remove_plugin'
t "D5 the reinstall arm's code has no rm and never names the --reinstall flag block or the plugin remover" 'arm: $(printf "%s" "$ARM" | head -c 200)'

# ── E. controls: the traps can fire ──────────────────────────────────────────────────────────────────────────────
echo "E. controls"
: >"$TRACE"; : >"$CLAUDE_LOG"; : >"$RM_LOG"; : >"$CURL_LOG"
hmd fix the login bug
launched; t "E1 an unrouted command reaches the launch point in this sandbox (the trace fills), so D4 is not vacuous" 'rc=$RC trace=$(tr "\n" ";" <"$TRACE") err=$ERR'
: >"$TRACE"; : >"$CLAUDE_LOG"; : >"$RM_LOG"; : >"$CURL_LOG"
hmd --reinstall --yes
grep -qF -- "-rf $HH" "$RM_LOG" && [ -s "$CURL_LOG" ]
t "E2 the old --reinstall flag, in the same sandbox, trips the rm trap (-rf on HEIMDALL_HOME) and reaches curl, so D1 and D2 are not vacuous" 'rc=$RC rm=$(tr "\n" ";" <"$RM_LOG") curl=$(tr "\n" ";" <"$CURL_LOG") err=$ERR'

# ── F. help, the runhmd list, syntax ─────────────────────────────────────────────────────────────────────────────
echo "F. help, syntax"
hmd help
[ "$RC" -eq 0 ] && has 'lean <status|on|off>' && has 'reinstall --reset'; t "F1 hmd help lists lean and reinstall --reset" 'rc=$RC out=$(printf "%s" "$OUT" | head -c 200)'
hmd --help
[ "$RC" -eq 0 ] && has 'lean <status|on|off>' && has 'reinstall --reset'; t "F2 hmd --help lists them too" 'rc=$RC'
bash -n "$PLUG/bin/heimdall" 2>/dev/null; t "F3 the launcher parses (bash -n)"

echo
echo "lean-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
