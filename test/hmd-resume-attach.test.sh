#!/usr/bin/env bash
# test/hmd-resume-attach.test.sh -- `hmd --resume` re-attaches a conversation that is running in the background.
#
# THE BUG. `hmd --resume` runs `claude --continue`, and Claude Code refuses a conversation that lives in a background
# session: it prints "Your most recent conversation is running in the background (session <id>) ..." and exits, so the
# operator got a notice instead of their session (operator report 2026-11-13: "hmd should be able to resume the background
# running tasks as well").
#
# WHAT IS GRADED. A fake `claude` is first on PATH: it logs its argv, answers `agents --json` from a fixture file and
# records `attach` and the launch, so nothing real is attached to or started.
#   1. bin/heimdall-bg-sessions   which sessions count (a live process, kind background, this directory), their order (last
#                                 transcript write, never the start time), cleaned titles, the --match selector, exit 1 none
#                                 and exit 3 cannot-list (claude failing, hanging, missing, printing junk), the `list` table.
#   2. _heimdall_resume_attach_bg library mode, so no banner: one session attaches; several pick on a terminal (Down+Enter,
#                                 Esc resumes normally) or take the most recent with a note; a selector; none -> it returns
#                                 and the caller goes on with --continue; claude unable to list -> one line telling how to
#                                 attach by hand, then today's behaviour.
#   3. the real launcher          `--resume` attaches without starting claude and exits with attach's status; no session ->
#                                 `claude --continue` as before; `--resume --foreground` never asks for the list; `-r ID`
#                                 selects; `hmd agents` lists with the attach hint.
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
. "$REPO/test/lib/net-default-guard.sh"

HEIMDALL="$REPO/bin/heimdall"
BG="$REPO/bin/heimdall-bg-sessions"
SELECT_LIB="$REPO/bin/lib/select.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for f in "$HEIMDALL" "$BG" "$SELECT_LIB"; do
  [ -f "$f" ] || { echo "FATAL: $f missing"; exit 1; }
done
PY3="$(command -v python3)" || { echo "FATAL: python3 not found"; exit 1; }

# ── sandbox ───────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-hmd-resume-attach-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/plugin"          # a COPY of the launcher: PLUGIN_DIR resolves to this dir
STUBS="$TMP/stubs"
HOME_DIR="$TMP/home"
WORK="$TMP/work"
OTHER="$TMP/other"
CFG="$TMP/claude-config"    # CLAUDE_CONFIG_DIR: where the fake transcripts live
CLAUDE_LOG="$TMP/claude.log"
AGENTS_JSON="$TMP/agents.json"
STDIN_FILE="$TMP/stdin"
OUT="$TMP/out"
ERR="$TMP/err"
mkdir -p "$FAKE/bin/lib" "$FAKE/.claude-plugin" "$STUBS" "$HOME_DIR/.heimdall" "$WORK" "$OTHER" "$CFG/projects/-proj" "$TMP/nopath"
cp "$HEIMDALL" "$FAKE/bin/heimdall"
cp "$BG" "$FAKE/bin/heimdall-bg-sessions"
cp "$SELECT_LIB" "$FAKE/bin/lib/select.sh"
chmod +x "$FAKE/bin/heimdall" "$FAKE/bin/heimdall-bg-sessions"
touch "$HOME_DIR/.heimdall/setup-done"       # first_run_setup becomes a no-op: no installs, no network
# A PATH with python3 and no claude. The REAL interpreter is linked: python3 on PATH is often a version-manager shim (a bash
# script) that cannot run without the rest of the PATH.
ln -s "$("$PY3" -I -c 'import sys; print(sys.executable)')" "$TMP/nopath/python3"

# The fake `claude`: one `ARGV: [a] [b] ...` line per call. `agents` answers the fixture (or sleeps, or fails); `attach` exits
# FAKE_ATTACH_RC; the launcher's own launch (it carries `--agent heimdall`) exits STUB_CLAUDE_RC.
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "${CLAUDE_LOG:-/dev/null}"
case "$1" in
  agents)
    [ -z "${FAKE_AGENTS_SLEEP:-}" ] || exec sleep "$FAKE_AGENTS_SLEEP"
    [ -z "${FAKE_AGENTS_RC:-}" ] || exit "$FAKE_AGENTS_RC"
    cat "${FAKE_AGENTS_JSON:-/dev/null}"; exit 0 ;;
  attach) exit "${FAKE_ATTACH_RC:-0}" ;;
esac
case " $* " in *" --agent heimdall "*) exit "${STUB_CLAUDE_RC:-0}" ;; esac
exit 0
EOF
chmod +x "$STUBS/claude"

# ENVV CMD... -- CMD in a clean environment (the only variables the code under test may see).
ENVV() {
  env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HOME_DIR/.heimdall" CLAUDE_CONFIG_DIR="$CFG" TERM=dumb \
    ANTHROPIC_API_KEY="sk-ant-resume-attach-probe" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_REUSE_METRIC=1 \
    HEIMDALL_DEFAULT_CP_URL="$HEIMDALL_DEFAULT_CP_URL" CLAUDE_LOG="$CLAUDE_LOG" FAKE_AGENTS_JSON="$AGENTS_JSON" \
    FAKE_AGENTS_RC="${FAKE_AGENTS_RC:-}" FAKE_AGENTS_SLEEP="${FAKE_AGENTS_SLEEP:-}" FAKE_ATTACH_RC="${FAKE_ATTACH_RC:-0}" \
    HMD_BG_SESSIONS_TIMEOUT_S="${HMD_BG_SESSIONS_TIMEOUT_S:-8}" HMD_SELECT_FORCE_TTY="${HMD_SELECT_FORCE_TTY:-0}" "$@"
}

STDIN_SRC=/dev/null
# run CMD [ARGS...] -- in $WORK, bounded by an alarm. Sets RC; stdout/stderr land in $OUT/$ERR; $CLAUDE_LOG holds the fake's calls.
run() {
  : > "$CLAUDE_LOG"; : > "$OUT"; : > "$ERR"
  ( cd "$WORK" && ENVV perl -e 'alarm shift; exec @ARGV' 60 "$@" <"$STDIN_SRC" >"$OUT" 2>"$ERR" )
  RC=$?
}
# bg ARGS... -- bin/heimdall-bg-sessions itself.
bg() { run "$BG" "$@"; }
# fn [SELECTOR] -- _heimdall_resume_attach_bg in library mode (no banner); prints CONTINUE when it returns to its caller.
fn() {
  run env HEIMDALL_LIB_ONLY=1 bash -c 'sel="${1:-}"; set --; source "$0" || exit 90; _heimdall_resume_attach_bg "$sel"; echo CONTINUE' \
    "$FAKE/bin/heimdall" "${1:-}"
}

snip() { head -c 300 "$1" 2>/dev/null | tr '\n' '|'; }
detail() { printf '[rc=%s out=%s err=%s claude=%s]' "${RC:-?}" "$(snip "$OUT")" "$(snip "$ERR")" "$(snip "$CLAUDE_LOG")"; }
check()     { if "${@:2}"; then ok "$1"; else bad "$1  $(detail)"; fi; }
check_not() { if "${@:2}"; then bad "$1  $(detail)"; else ok "$1"; fi; }

attached_ids() { sed -n 's/^ARGV: \[attach\] \[\([^]]*\)\]$/\1/p' "$CLAUDE_LOG" | tr '\n' ' ' | sed 's/ $//'; }
launched()     { grep -q '^ARGV: \[--continue\] \[--agent\] \[heimdall\]' "$CLAUDE_LOG"; }
agents_calls() { grep -c '^ARGV: \[agents\]' "$CLAUDE_LOG"; }
out_has()      { grep -qF -- "$1" "$OUT"; }
err_has()      { grep -qF -- "$1" "$ERR"; }
has_escape()   { LC_ALL=C grep -q "$(printf '\033')" "$1"; }
bad_fields()   { awk -F'\t' 'NF != 4' "$1" | wc -l | tr -d ' '; }

# ── fixtures ──────────────────────────────────────────────────────────────────
NOW_MS=$(( $(date +%s) * 1000 ))
SID_A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; SID_B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb; SID_C=cccccccc-cccc-4ccc-8ccc-cccccccccccc
SID_D=dddddddd-dddd-4ddd-8ddd-dddddddddddd; SID_E=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee; SID_F=ffffffff-ffff-4fff-8fff-ffffffffffff
SID_G=99999999-9999-4999-8999-999999999999; SID_H=88888888-8888-4888-8888-888888888888; SID_I=77777777-7777-4777-8777-777777777777

# rec ID SESSION_ID KIND CWD AGO_SECONDS NAME_JSON [PID] [STATUS] [STATE] -- one `claude agents --json` entry (NAME_JSON is a
# JSON string literal, quotes included, so a case can plant escapes).
rec() {
  local id="$1" sid="$2" kind="$3" cwd="$4" ago="$5" name="$6" pid="${7:-}" status="${8:-}" state="${9:-}" out
  out="\"cwd\":\"$cwd\",\"kind\":\"$kind\",\"startedAt\":$(( NOW_MS - ago * 1000 )),\"name\":$name"
  [ -z "$id" ] || out="\"id\":\"$id\",$out"
  [ -z "$sid" ] || out="$out,\"sessionId\":\"$sid\""
  [ -z "$pid" ] || out="$out,\"pid\":$pid"
  [ -z "$status" ] || out="$out,\"status\":\"$status\""
  [ -z "$state" ] || out="$out,\"state\":\"$state\""
  printf '{%s}' "$out"
}
# agents REC... -- the JSON array the fake `claude agents --json` prints.
agents() { local IFS=,; printf '[%s]' "$*" > "$AGENTS_JSON"; }

# Transcripts: A was written to LAST (Feb), B before (Jan). C and H never ran a turn: no transcript.
: > "$CFG/projects/-proj/$SID_A.jsonl"; touch -t 202602010000 "$CFG/projects/-proj/$SID_A.jsonl"
: > "$CFG/projects/-proj/$SID_B.jsonl"; touch -t 202601010000 "$CFG/projects/-proj/$SID_B.jsonl"

REC_A() { rec aaaa1111 "$SID_A" background "$WORK" 7200 '"alpha"' 111 busy working; }                 # oldest start, newest write
REC_B() { rec bbbb2222 "$SID_B" background "$WORK" 600 '"bravo"' 222 idle done; }                      # started later than A
REC_C() { rec cccc3333 "$SID_C" background "$WORK" 60 '"cccc3333"' 333 idle blocked; }                 # newest start, never prompted
REC_H() { rec hhhh8888 "$SID_H" background "$WORK" 100 '"evil\u001b[31m\tred\nline"' 888 busy working; }  # hostile title
REC_I() { rec "" "$SID_I" interactive "$WORK" 100 '"an-interactive-one"' 444 busy; }                   # not background
REC_D() { rec dddd4444 "$SID_D" background "$OTHER" 100 '"elsewhere"' 555 busy working; }              # another directory
REC_E() { rec eeee5555 "$SID_E" background "$WORK" 5000 '"exited-one"' "" "" blocked; }                # process exited
REC_F() { rec ffff6666 "$SID_F" background "$TMP/no-such-dir" 100 '"ghost"' 666 busy working; }        # cwd is gone
REC_G() { rec -rf "$SID_G" background "$WORK" 100 '"hostile-id"' 777 busy working; }                   # an id that is an option
FULL()  { agents "$(REC_A)" "$(REC_B)" "$(REC_C)" "$(REC_H)" "$(REC_I)" "$(REC_D)" "$(REC_E)" "$(REC_F)" "$(REC_G)"; }
ONE()   { agents "$(REC_A)" "$(REC_D)" "$(REC_E)" "$(REC_I)"; }

# ══════════════════════════════════════════════════════════════════════════════
echo "1. bin/heimdall-bg-sessions"
# ══════════════════════════════════════════════════════════════════════════════
FULL
bg rows --dir "$WORK"
IDS="$(cut -f1 "$OUT" | tr '\n' ' ')"
check "rows: exits 0" [ "$RC" -eq 0 ]
check "rows: only the running background sessions of this directory, most recently WRITTEN first (A, B), then the never-prompted by start (C, H)" \
  [ "$IDS" = "aaaa1111 bbbb2222 cccc3333 hhhh8888 " ]
check "rows: the label carries state, process, age and title" grep -Eq 'aaaa1111  working +busy +2h  alpha' "$OUT"
check "rows: a session with the id for a name is (untitled)" grep -Eq '^cccc3333	.*	\(untitled\)	' "$OUT"
check "rows: a title with escapes, a tab and a newline is one clean line" grep -q 'evil \[31m red line' "$OUT"
check_not "rows: no escape byte reaches the output" has_escape "$OUT"
check "rows: every line is exactly 4 tab-separated fields" [ "$(bad_fields "$OUT")" = 0 ]

bg rows --match bbbb;  check "match: an id prefix" [ "$(cut -f1 "$OUT")" = bbbb2222 ]
bg rows --match BRAVO; check "match: a name, case-insensitively" [ "$(cut -f1 "$OUT")" = bbbb2222 ]
bg rows --match "$SID_B"; check "match: a session id" [ "$(cut -f1 "$OUT")" = bbbb2222 ]
bg rows --match dddd;  check "match: a running session of ANOTHER directory (an id is global)" [ "$(cut -f1 "$OUT")" = dddd4444 ]
bg rows --match zzzz;  check "match: nothing matches -> exit 1" [ "$RC" -eq 1 ]
bg rows --match eeee;  check "match: a session whose process exited is not running -> exit 1" [ "$RC" -eq 1 ]

agents "$(REC_D)" "$(REC_E)" "$(REC_I)"
bg rows --dir "$WORK"; check "rows: none running here -> exit 1, nothing printed" [ "$RC" -eq 1 -a ! -s "$OUT" ]
FAKE_AGENTS_RC=1 bg rows --dir "$WORK"; check "rows: claude exits non-zero -> exit 3" [ "$RC" -eq 3 ]
printf 'this is not json' > "$AGENTS_JSON"
bg rows --dir "$WORK"; check "rows: claude prints junk -> exit 3" [ "$RC" -eq 3 ]
printf '{}' > "$AGENTS_JSON"
bg rows --dir "$WORK"; check "rows: claude prints JSON that is not an array -> exit 3" [ "$RC" -eq 3 ]
FULL
( cd "$WORK" && env -i PATH="$TMP/nopath" HOME="$HOME_DIR" "$BG" rows --dir "$WORK" </dev/null >"$OUT" 2>"$ERR" ); RC=$?
check "rows: no claude on PATH -> exit 3" [ "$RC" -eq 3 ]
FAKE_AGENTS_SLEEP=3 HMD_BG_SESSIONS_TIMEOUT_S=0.5 bg rows --dir "$WORK"
check "rows: claude that does not answer in time -> exit 3, said" [ "$RC" -eq 3 ]
check "rows: ...and the reason names the wait" err_has "did not answer"

FULL
bg list --dir "$WORK"
check "list: exits 0 and shows the running and the exited sessions of this directory" [ "$RC" -eq 0 ]
check "list: a running one" grep -Eq '^  aaaa1111  working' "$OUT"
check "list: an exited one is marked" grep -Eq 'eeee5555 .*exited' "$OUT"
check_not "list: another directory's session and an interactive one are not listed" grep -Eq 'dddd4444|an-interactive-one' "$OUT"
check "list: names the command that re-attaches the most recent running one" grep -qF 'Re-attach: hmd --resume aaaa1111   (or: claude attach aaaa1111)' "$OUT"
agents
bg list --dir "$WORK"; check "list: nothing here is said so, exit 0" [ "$RC" -eq 0 ]
check "list: ...in words" out_has "No background sessions in"
FAKE_AGENTS_RC=1 bg list --dir "$WORK"
check "list: claude cannot list -> exit 3 and the reason on stderr" [ "$RC" -eq 3 ]
check "list: ...naming what is needed" err_has "claude agents --json"

# ══════════════════════════════════════════════════════════════════════════════
echo "2. _heimdall_resume_attach_bg (library mode)"
# ══════════════════════════════════════════════════════════════════════════════
ONE; fn
check "one running session: claude attach is called with ITS id, once" [ "$(attached_ids)" = aaaa1111 ]
check "one running session: the function never returns to the --continue path" [ "$RC" -eq 0 ]
check_not "one running session: ...so CONTINUE is never printed" out_has CONTINUE
check "one running session: ONE line says which session is re-attached" grep -Eq 're-attaching to background session aaaa1111 \(alpha\)' "$OUT"
ONE; FAKE_ATTACH_RC=7 fn
check "attach's own exit status is the launcher's" [ "$RC" -eq 7 ]

agents "$(REC_D)" "$(REC_E)" "$(REC_I)"; fn
check "none running here: nothing is attached" [ -z "$(attached_ids)" ]
check "none running here: it returns, silently, to the --continue path" [ "$(cat "$OUT")" = CONTINUE ]

FULL; fn
check "several, no terminal: the most recently active is attached (not the newest start)" [ "$(attached_ids)" = aaaa1111 ]
check "several, no terminal: one note says so" out_has "4 background sessions and no terminal to pick on: re-attaching to background session aaaa1111"

printf '\033[B\n' > "$STDIN_FILE"; STDIN_SRC="$STDIN_FILE"
FULL; HMD_SELECT_FORCE_TTY=1 fn
check "several, a terminal: Down+Enter attaches the second" [ "$(attached_ids)" = bbbb2222 ]
check "several, a terminal: the menu lists the sessions" grep -q 'bbbb2222' "$ERR"
printf '\n' > "$STDIN_FILE"
FULL; HMD_SELECT_FORCE_TTY=1 fn
check "several, a terminal: Enter alone attaches the most recent" [ "$(attached_ids)" = aaaa1111 ]
printf '\033' > "$STDIN_FILE"
FULL; HMD_SELECT_FORCE_TTY=1 fn
check "several, a terminal: Esc attaches nothing" [ -z "$(attached_ids)" ]
check "several, a terminal: Esc returns to the --continue path, said" out_has "not attaching"
check "several, a terminal: ...and CONTINUE is printed" out_has CONTINUE
STDIN_SRC=/dev/null

FULL; fn bbbb
check "selector: an id prefix attaches that session although another is more recent" [ "$(attached_ids)" = bbbb2222 ]
FULL; fn nomatch
check "selector that matches nothing: nothing is attached" [ -z "$(attached_ids)" ]
check "selector that matches nothing: said, with the way to list them, and the --continue path goes on" grep -q 'no running background session matches "nomatch".*hmd agents' "$OUT"
check "selector that matches nothing: CONTINUE is printed" out_has CONTINUE

FULL; FAKE_AGENTS_RC=1 fn
check "claude cannot list: nothing is attached" [ -z "$(attached_ids)" ]
check "claude cannot list: one line says how to attach by hand" grep -q 'could not list background sessions.*claude attach <id>' "$ERR"
check "claude cannot list: today's --continue path goes on" out_has CONTINUE

# ══════════════════════════════════════════════════════════════════════════════
echo "3. the real launcher"
# ══════════════════════════════════════════════════════════════════════════════
ONE; FAKE_ATTACH_RC=7 run "$FAKE/bin/heimdall" --resume
check "--resume with a running background session: it is attached" [ "$(attached_ids)" = aaaa1111 ]
check_not "--resume with a running background session: claude --continue is NOT started" launched
check "--resume with a running background session: exits with attach's status" [ "$RC" -eq 7 ]
check "--resume with a running background session: one line says so" grep -Eq 're-attaching to background session aaaa1111' "$OUT"

agents
run "$FAKE/bin/heimdall" --resume
check "--resume with none running: claude --continue starts as before" launched
check "--resume with none running: nothing is attached" [ -z "$(attached_ids)" ]
check "--resume with none running: the list was asked for once" [ "$(agents_calls)" = 1 ]

ONE; run "$FAKE/bin/heimdall" --resume --foreground
check "--resume --foreground: claude --continue starts" launched
check "--resume --foreground: nothing is attached" [ -z "$(attached_ids)" ]
check "--resume --foreground: claude is never asked for the list" [ "$(agents_calls)" = 0 ]

FULL; run "$FAKE/bin/heimdall" -r bbbb
check "-r ID: that session is attached" [ "$(attached_ids)" = bbbb2222 ]
check_not "-r ID: claude --continue is NOT started" launched

FULL; run "$FAKE/bin/heimdall" agents
check "hmd agents: exits 0 (it is a command, not an unknown word)" [ "$RC" -eq 0 ]
check "hmd agents: lists this directory's sessions with the attach hint" grep -qF 'Re-attach: hmd --resume aaaa1111' "$OUT"
check "hmd agents: lists an exited session too" grep -Eq 'eeee5555 .*exited' "$OUT"
FAKE_AGENTS_RC=1 run "$FAKE/bin/heimdall" agents
check "hmd agents: claude cannot list -> exit 3" [ "$RC" -eq 3 ]

# ══════════════════════════════════════════════════════════════════════════════
echo "4. syntax"
# ══════════════════════════════════════════════════════════════════════════════
bash -n "$HEIMDALL" 2>/dev/null && ok "bin/heimdall passes bash -n" || bad "bin/heimdall has a syntax error"
"$PY3" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$BG" 2>/dev/null \
  && ok "bin/heimdall-bg-sessions parses" || bad "bin/heimdall-bg-sessions has a syntax error"

echo ""
echo "hmd-resume-attach: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
