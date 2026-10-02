#!/usr/bin/env bash
# heimdall-inbox-wiring.test.sh — acceptance for wiring the already-landed
# bin/heimdall-inbox-deliver into hmd's CLI dispatch (`heimdall inbox ...`)
# and the advisory Stop / UserPromptSubmit hook registry (hooks/hooks.json +
# hooks/hooks.metadata.json). heimdall-inbox-deliver's own behavior (stop /
# prompt / tmux / status modes) is covered by heimdall-inbox-deliver.test.sh;
# this suite covers only the wiring: dispatch arm, hook commands, kill-switch,
# and the Stop-hook wait-time policy decided at wiring time.
#
# Oracle: bin/heimdall's `inbox)` dispatch arm, hooks/hooks.json's
# inbox-deliver-stop / inbox-deliver-prompt hook groups, and their
# hooks.metadata.json sidecar entries. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HEIMDALL="$REPO/bin/heimdall"
HOOKS_TOOL="$REPO/bin/heimdall-hooks"
HOOKS_JSON="$REPO/hooks/hooks.json"
HOOKS_META="$REPO/hooks/hooks.metadata.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$HEIMDALL" "$HOOKS_TOOL"; do
  if [ ! -x "$f" ]; then
    echo "FATAL: $f missing or not executable"
    exit 1
  fi
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

make_project() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/.heimdall/ui"
  printf '%s' "$d"
}

# The Stop hook ends its hold the moment the terminal it runs under is read (the
# operator typing). Found through the hook's ancestors, that terminal is whatever
# launched this suite -- an operator's shell, a claude session -- and a human
# typing there mid-run would cut a wait a test is timing. Off everywhere except
# test 12, which injects its own signal.
export HMD_INBOX_TTY=off

echo "1. bin/heimdall inbox status -- runs + exits 0 on a temp repo with empty inbox:"
D="$(make_project)"
: > "$D/.heimdall/ui/inbox.jsonl"
OUT="$("$HEIMDALL" inbox status --json --repo "$D" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0): $OUT"
echo "$OUT" | grep -q '"pending"[[:space:]]*:[[:space:]]*0' && ok "reports pending:0 on empty inbox" || bad "unexpected status output: $OUT"
rm -rf "$D"

echo "2. hooks/hooks.json carries both inbox-deliver hook commands with the kill-switch prefix:"
STOP_CMDS="$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$HOOKS_JSON")"
PROMPT_CMDS="$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command // empty' "$HOOKS_JSON")"
printf '%s' "$STOP_CMDS" | grep -q 'heimdall-inbox-deliver' && ok "Stop array invokes heimdall-inbox-deliver" || bad "no heimdall-inbox-deliver command in Stop array"
printf '%s' "$STOP_CMDS" | grep -q 'hmd_hook_enabled inbox-deliver-stop' && ok "Stop hook carries the kill-switch prefix (inbox-deliver-stop)" || bad "Stop hook missing kill-switch prefix"
printf '%s' "$STOP_CMDS" | grep -q ' stop --repo' && ok "Stop hook runs stop mode" || bad "Stop hook doesn't run stop mode"
printf '%s' "$PROMPT_CMDS" | grep -q 'heimdall-inbox-deliver' && ok "UserPromptSubmit array invokes heimdall-inbox-deliver" || bad "no heimdall-inbox-deliver command in UserPromptSubmit array"
printf '%s' "$PROMPT_CMDS" | grep -q 'hmd_hook_enabled inbox-deliver-prompt' && ok "UserPromptSubmit hook carries the kill-switch prefix (inbox-deliver-prompt)" || bad "UserPromptSubmit hook missing kill-switch prefix"
printf '%s' "$PROMPT_CMDS" | grep -q ' prompt --repo' && ok "UserPromptSubmit hook runs prompt mode" || bad "UserPromptSubmit hook doesn't run prompt mode"

TIMEOUT_STOP="$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command | contains("inbox-deliver-stop")) | .timeout // empty' "$HOOKS_JSON")"
TIMEOUT_PROMPT="$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | contains("inbox-deliver-prompt")) | .timeout // empty' "$HOOKS_JSON")"
[ "$TIMEOUT_STOP" = "330" ] && ok "Stop hook timeout is 330s (the 300s companion-connected HMD_INBOX_WAIT_S default + a 30s margin for the last 2s poll and process start)" || bad "Stop hook timeout wrong/missing: '$TIMEOUT_STOP'"
# The two numbers drift apart silently -- the script's default is a constant in
# bin/heimdall-inbox-deliver, the timeout a literal in hooks.json -- and a timeout
# below the wait makes Claude Code kill the hook just before a late phone message
# could be delivered. Tie them together instead of trusting two literals.
DEFAULT_WAIT="$(sed -n 's/^COMPANION_WAIT_S = \([0-9][0-9.]*\).*/\1/p' "$REPO/bin/heimdall-inbox-deliver")"
python3 -c 'import sys; wait, timeout = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if timeout - wait >= 20 else 1)' "${DEFAULT_WAIT:-x}" "${TIMEOUT_STOP:-0}" 2>/dev/null \
  && ok "Stop hook timeout ($TIMEOUT_STOP) clears the script's companion wait default ($DEFAULT_WAIT) by >= 20s" \
  || bad "Stop hook timeout '$TIMEOUT_STOP' does not clear bin/heimdall-inbox-deliver's COMPANION_WAIT_S '$DEFAULT_WAIT' by 20s -- Claude Code would kill a hold that is still delivering"
[ "$TIMEOUT_PROMPT" = "10" ] && ok "UserPromptSubmit hook timeout is 10s" || bad "UserPromptSubmit hook timeout wrong/missing: '$TIMEOUT_PROMPT'"

echo "3. hooks.metadata.json registers both ids, distinct, advisory (locked:false):"
ID_STOP_COUNT="$(jq -r '[.hooks[] | select(.id == "inbox-deliver-stop")] | length' "$HOOKS_META")"
ID_PROMPT_COUNT="$(jq -r '[.hooks[] | select(.id == "inbox-deliver-prompt")] | length' "$HOOKS_META")"
[ "$ID_STOP_COUNT" = "1" ] && ok "inbox-deliver-stop appears exactly once in metadata" || bad "inbox-deliver-stop count: $ID_STOP_COUNT"
[ "$ID_PROMPT_COUNT" = "1" ] && ok "inbox-deliver-prompt appears exactly once in metadata" || bad "inbox-deliver-prompt count: $ID_PROMPT_COUNT"
LOCK_STOP="$(jq -r '.hooks[] | select(.id == "inbox-deliver-stop") | .locked' "$HOOKS_META")"
LOCK_PROMPT="$(jq -r '.hooks[] | select(.id == "inbox-deliver-prompt") | .locked' "$HOOKS_META")"
[ "$LOCK_STOP" = "false" ] && ok "inbox-deliver-stop is advisory (locked:false)" || bad "inbox-deliver-stop locked=$LOCK_STOP (want false)"
[ "$LOCK_PROMPT" = "false" ] && ok "inbox-deliver-prompt is advisory (locked:false)" || bad "inbox-deliver-prompt locked=$LOCK_PROMPT (want false)"

echo "4. heimdall-hooks check passes clean against the committed registry:"
CHECK_OUT="$(mktemp)"
"$HOOKS_TOOL" check >"$CHECK_OUT" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "heimdall-hooks check exits 0" || bad "heimdall-hooks check exit $RC: $(cat "$CHECK_OUT")"
rm -f "$CHECK_OUT"

echo "5. heimdall-hooks list shows both ids:"
LIST_OUT="$("$HOOKS_TOOL" list 2>&1)"
echo "$LIST_OUT" | grep -q 'inbox-deliver-stop' && ok "list shows inbox-deliver-stop" || bad "list missing inbox-deliver-stop: $LIST_OUT"
echo "$LIST_OUT" | grep -q 'inbox-deliver-prompt' && ok "list shows inbox-deliver-prompt" || bad "list missing inbox-deliver-prompt: $LIST_OUT"

echo "6. heimdall-hooks disable <id> makes each inbox hook a no-op (exit 0, empty stdout):"
TMPHOME="$(mktemp -d)"
for ID in inbox-deliver-stop inbox-deliver-prompt; do
  CMD="$(jq -r --arg id "$ID" '(.hooks.Stop[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]?) | select(.command | contains($id)) | .command' "$HOOKS_JSON")"
  if [ -z "$CMD" ]; then
    bad "$ID: could not locate its command in hooks.json to test disable"
    continue
  fi
  : > "$TMPHOME/hooks-disabled"
  echo "$ID" >> "$TMPHOME/hooks-disabled"
  OUT="$(printf '{}' | HEIMDALL_HOME="$TMPHOME" CLAUDE_PLUGIN_ROOT="$REPO" bash -c "$CMD" 2>&1)"
  RC=$?
  [ "$RC" -eq 0 ] && ok "$ID: disabled hook exits 0" || bad "$ID: disabled hook exit $RC: $OUT"
  [ -z "$OUT" ] && ok "$ID: disabled hook prints nothing" || bad "$ID: disabled hook printed: $OUT"
done
rm -rf "$TMPHOME"

echo "7. STOP event, empty inbox, no .heimdall/ui/inbox.wait marker -> exit 0, empty stdout, < 2s (via the wired hook command):"
D="$(make_project)"
: > "$D/.heimdall/ui/inbox.jsonl"
CMD="$(jq -r '(.hooks.Stop[]?.hooks[]?) | select(.command | contains("inbox-deliver-stop")) | .command' "$HOOKS_JSON")"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Should I proceed?"}'
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" bash -c "$CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0): $OUT"
[ -z "$OUT" ] && ok "no stdout on empty inbox (question + empty + no marker -> HMD_INBOX_WAIT_S=0)" || bad "unexpected stdout: $OUT"
[ "$ELAPSED" -le 2 ] && ok "returned in ${ELAPSED}s (< 2s -- no 240s default long-poll without the opt-in marker)" || bad "took ${ELAPSED}s -- want < 2s"
rm -rf "$D"

echo "8. STOP event, empty inbox, WITH .heimdall/ui/inbox.wait marker + short HMD_INBOX_WAIT_S -> honors an operator-set wait:"
D="$(make_project)"
: > "$D/.heimdall/ui/inbox.jsonl"
: > "$D/.heimdall/ui/inbox.wait"
CMD="$(jq -r '(.hooks.Stop[]?.hooks[]?) | select(.command | contains("inbox-deliver-stop")) | .command' "$HOOKS_JSON")"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Should I proceed?"}'
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_INBOX_WAIT_S=2 bash -c "$CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0): $OUT"
[ -z "$OUT" ] && ok "no stdout (still empty after the short wait)" || bad "unexpected stdout: $OUT"
[ "$ELAPSED" -ge 2 ] && ok "honored the marker -- actually waited (${ELAPSED}s >= 2s)" || bad "returned in ${ELAPSED}s -- marker should have forced a wait"
rm -rf "$D"

# A2: a connected companion (.heimdall/app/connect.json naming live processes)
# is the implicit opt-in -- the wired hook must hold the idle session for a
# phone message even with no inbox.wait marker and no '?'. Pinned to an
# attended session: a headless claude -p / SDK caller would otherwise (rightly)
# switch the wait off.
export CLAUDE_CODE_ENTRYPOINT=cli
unset HMD_AGENT_TYPE HMD_JUDGMENT HMD_INBOX_GATED HMD_INBOX_WAIT_S
STOP_CMD="$(jq -r '(.hooks.Stop[]?.hooks[]?) | select(.command | contains("inbox-deliver-stop")) | .command' "$HOOKS_JSON")"

echo "9. A2: no inbox.wait marker + companion connected (live connect.json) + last message WITHOUT '?' -> the wired hook delivers a late phone message (idle delivery, no prompt):"
D="$(make_project)"
mkdir -p "$D/.heimdall/app"
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"x","started_at":"t"}\n' "$$" "$$" > "$D/.heimdall/app/connect.json"
: > "$D/.heimdall/ui/inbox.jsonl"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done implementing the feature."}'
# The message lands 3s in -- long enough that a slow hook start cannot beat it
# and make a hook that never waits look like one that did. HMD_INBOX_WAIT_S=20
# only bounds a broken run (the real default with a companion is 300).
( sleep 3; printf '{"id":"w1","ts":1,"text":"idle hello from phone","source":"test"}\n' >> "$D/.heimdall/ui/inbox.jsonl" ) &
BGPID=$!
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_INBOX_WAIT_S=20 bash -c "$STOP_CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
wait "$BGPID" 2>/dev/null || true
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0): $OUT"
printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && ok "decision:block delivered through the wired command" || bad "no delivery: $OUT"
printf '%s' "$OUT" | grep -q "idle hello from phone" && ok "reason carries the late-arriving text" || bad "text missing from: $OUT"
[ "$ELAPSED" -le 9 ] && ok "delivered in ${ELAPSED}s -- the hook was holding the idle session, not returning at once" || bad "took ${ELAPSED}s"
rm -rf "$D"

echo "10. A2: a STALE connect.json (dead pids) is not a connected companion -- the wired hook returns at once:"
D="$(make_project)"
mkdir -p "$D/.heimdall/app"
( : ) & DEADP=$!
wait "$DEADP" 2>/dev/null
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"x","started_at":"t"}\n' "$DEADP" "$DEADP" > "$D/.heimdall/app/connect.json"
: > "$D/.heimdall/ui/inbox.jsonl"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done implementing the feature."}'
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_INBOX_WAIT_S=6 bash -c "$STOP_CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "exit 0, no stdout" || bad "rc=$RC out: $OUT"
[ "$ELAPSED" -le 3 ] && ok "returned in ${ELAPSED}s -- a crash-left connect.json cannot pin every turn end (a wait would show >= 6s)" || bad "took ${ELAPSED}s"
rm -rf "$D"

echo "11. A2: no marker + nobody connected + question + an operator-exported HMD_INBOX_WAIT_S=4 -> the wiring's opt-in gate still wins (returns at once):"
D="$(make_project)"
: > "$D/.heimdall/ui/inbox.jsonl"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Should I proceed?"}'
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_INBOX_WAIT_S=4 bash -c "$STOP_CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "exit 0, no stdout" || bad "rc=$RC out: $OUT"
[ "$ELAPSED" -le 3 ] && ok "returned in ${ELAPSED}s (the exported 4s wait did not leak past the gate)" || bad "took ${ELAPSED}s -- the gate did not hold"
rm -rf "$D"

echo "12. typing release through the wired command: companion connected, empty inbox, the terminal is read 3s in -> the hook hands the turn back within a poll, long before its wait (HMD_INBOX_TTY survives the wrapper):"
D="$(make_project)"
mkdir -p "$D/.heimdall/app"
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"x","started_at":"t"}\n' "$$" "$$" > "$D/.heimdall/app/connect.json"
: > "$D/.heimdall/ui/inbox.jsonl"
TTYF="$(mktemp)"
python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() - 3600, os.stat(sys.argv[1]).st_mtime))' "$TTYF"
PAYLOAD='{"session_id":"s1","transcript_path":"","cwd":"'"$D"'","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done implementing the feature."}'
# HMD_INBOX_WAIT_S=20 only bounds a broken run: the real default with a companion
# is 300, and the point is that the keystroke cuts it short.
( sleep 3; python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time(), os.stat(sys.argv[1]).st_mtime))' "$TTYF" ) &
BGPID=$!
START=$(date +%s)
OUT="$(printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_INBOX_TTY="$TTYF" HMD_INBOX_PRESENCE_CMD="echo 0" HMD_INBOX_WAIT_S=20 bash -c "$STOP_CMD" 2>&1)"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
wait "$BGPID" 2>/dev/null || true
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "exit 0, no stdout" || bad "rc=$RC out: $OUT"
[ "$ELAPSED" -ge 2 ] && ok "held until the keystroke (${ELAPSED}s), not returned at once" || bad "returned in ${ELAPSED}s -- the companion hold never began"
[ "$ELAPSED" -le 9 ] && ok "released ${ELAPSED}s in, a poll after the keystroke -- not the 20s bound" || bad "took ${ELAPSED}s -- the keystroke did not end the hold"
rm -rf "$D" "$TTYF"

echo ""
echo "heimdall-inbox-wiring.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
