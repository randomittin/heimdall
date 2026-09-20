#!/usr/bin/env bash
# heimdall-inbox-deliver.test.sh — acceptance for delivering queued companion
# (hmdapp) messages into a running Claude Code session: a Stop-hook long-poll
# with loop guard, a tmux pane, or a UserPromptSubmit fallback.
#
# Oracle: bin/heimdall-inbox-deliver. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-inbox-deliver"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$BIN" ]; then
  echo "FATAL: $BIN missing or not executable"
  exit 1
fi

# A fresh throwaway project dir with just the .heimdall/ui shape this tool needs.
make_project() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/.heimdall/ui"
  printf '%s' "$d"
}

inbox_of()     { printf '%s/.heimdall/ui/inbox.jsonl' "$1"; }
delivered_of() { printf '%s/.heimdall/ui/inbox-delivered.jsonl' "$1"; }
state_of()     { printf '%s/.heimdall/ui/inbox-state.json' "$1"; }

# seed_inbox DIR TEXT [TEXT...] — writes one JSONL line per TEXT.
seed_inbox() {
  local d="$1"; shift
  local f; f="$(inbox_of "$d")"
  : > "$f"
  local i=0 t
  for t in "$@"; do
    i=$((i + 1))
    printf '{"id":"seed-%d","ts":1,"text":"%s","source":"test"}\n' "$i" "$t" >> "$f"
  done
}

# stop_payload DIR STOP_HOOK_ACTIVE LAST_ASSISTANT_MSG
stop_payload() {
  printf '{"session_id":"s1","transcript_path":"","cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' \
    "$1" "$2" "$3"
}

echo "1. STOP + PENDING -> block JSON, inbox popped and archived:"
D="$(make_project)"
seed_inbox "$D" "hello from phone"
OUT="$(printf '%s' "$(stop_payload "$D" false "working on it")" | "$BIN" stop --repo "$D")"
RC=$?
echo "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && ok "prints decision:block" || bad "no decision:block in: $OUT"
echo "$OUT" | grep -q "hello from phone" && ok "reason carries the queued text" || bad "message text missing from: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
{ [ ! -f "$(inbox_of "$D")" ] || [ ! -s "$(inbox_of "$D")" ]; } && ok "inbox emptied (popped)" || bad "inbox still has pending lines"
grep -q "hello from phone" "$(delivered_of "$D")" 2>/dev/null && ok "archived to inbox-delivered.jsonl" || bad "not archived"
rm -rf "$D"

echo "2. STOP + stop_hook_active=true -> silent loop guard, nothing popped:"
D="$(make_project)"
seed_inbox "$D" "queued msg"
OUT="$(printf '%s' "$(stop_payload "$D" true "are you sure?")" | "$BIN" stop --repo "$D")"
RC=$?
[ -z "$OUT" ] && ok "no stdout" || bad "unexpected stdout: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
grep -q "queued msg" "$(inbox_of "$D")" 2>/dev/null && ok "loop guard left the message queued" || bad "message was popped despite stop_hook_active"
rm -rf "$D"

echo "3. STOP + question + empty inbox + message arrives 3s later -> delivered within the wait:"
D="$(make_project)"
: > "$(inbox_of "$D")"
(
  sleep 3
  printf '{"id":"late1","ts":1,"text":"answer from phone","source":"test"}\n' >> "$(inbox_of "$D")"
) &
BGPID=$!
START=$(date +%s)
OUT="$(printf '%s' "$(stop_payload "$D" false "Should I proceed with the deploy?")" | HMD_INBOX_WAIT_S=10 "$BIN" stop --repo "$D")"
RC=$?
END=$(date +%s)
ELAPSED=$((END - START))
wait "$BGPID" 2>/dev/null || true
echo "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && ok "delivers via decision:block once the answer lands" || bad "no delivery: $OUT"
echo "$OUT" | grep -q "answer from phone" && ok "reason carries the late-arriving text" || bad "late message missing from: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
[ "$ELAPSED" -le 8 ] && ok "delivered promptly (${ELAPSED}s), proving a 2s long-poll (not a fixed 10s sleep)" || bad "took ${ELAPSED}s -- too slow for a 2s poll"
rm -rf "$D"

echo "4. STOP + no question + empty inbox -> no output:"
D="$(make_project)"
: > "$(inbox_of "$D")"
OUT="$(printf '%s' "$(stop_payload "$D" false "Done implementing the feature.")" | "$BIN" stop --repo "$D")"
RC=$?
[ -z "$OUT" ] && ok "no stdout" || bad "unexpected stdout: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
rm -rf "$D"

echo "5. TMUX mode -> sends each pending message + Enter, then pops:"
D="$(make_project)"
seed_inbox "$D" "hi from phone" "second msg"
FAKEBIN="$(mktemp -d)"
RECORD="$(mktemp)"
cat > "$FAKEBIN/tmux" <<'FAKETMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_RECORD_FILE"
exit 0
FAKETMUX
chmod +x "$FAKEBIN/tmux"
OUT="$(PATH="$FAKEBIN:$PATH" TMUX_RECORD_FILE="$RECORD" HMD_TMUX_TARGET="sess:0.0" "$BIN" tmux --repo "$D")"
RC=$?
grep -q -- "-l hi from phone" "$RECORD" && ok "sent first message literally" || bad "first message not sent: $(cat "$RECORD")"
grep -q -- "-l second msg" "$RECORD" && ok "sent second message literally" || bad "second message not sent"
[ "$(grep -c "Enter" "$RECORD")" = "2" ] && ok "pressed Enter once per message" || bad "wrong Enter count: $(grep -c "Enter" "$RECORD")"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
{ [ ! -f "$(inbox_of "$D")" ] || [ ! -s "$(inbox_of "$D")" ]; } && ok "inbox popped after tmux delivery" || bad "inbox still has pending lines"
rm -rf "$D" "$FAKEBIN" "$RECORD"

echo "6. TMUX mode with no target configured -> no-op, exit 0, nothing popped:"
D="$(make_project)"
seed_inbox "$D" "should stay queued"
OUT="$(env -u HMD_TMUX_TARGET "$BIN" tmux --repo "$D")"
RC=$?
[ -z "$OUT" ] && ok "no stdout" || bad "unexpected stdout: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
grep -q "should stay queued" "$(inbox_of "$D")" 2>/dev/null && ok "message left queued (no target/tmux available)" || bad "message was popped with no tmux"
rm -rf "$D"

echo "7. PROMPT mode -> pops pending, returns hookSpecificOutput.additionalContext:"
D="$(make_project)"
seed_inbox "$D" "ping from app"
OUT="$(printf '{"session_id":"s1","cwd":"%s"}' "$D" | "$BIN" prompt --repo "$D")"
RC=$?
echo "$OUT" | grep -q '"hookEventName"[[:space:]]*:[[:space:]]*"UserPromptSubmit"' && ok "hookEventName is UserPromptSubmit" || bad "wrong/missing hookEventName: $OUT"
echo "$OUT" | grep -q "ping from app" && ok "additionalContext carries the queued text" || bad "message text missing from: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
{ [ ! -f "$(inbox_of "$D")" ] || [ ! -s "$(inbox_of "$D")" ]; } && ok "inbox popped" || bad "inbox still has pending lines"
rm -rf "$D"

echo "8. PROMPT mode with empty inbox -> no output:"
D="$(make_project)"
: > "$(inbox_of "$D")"
OUT="$(printf '{"session_id":"s1","cwd":"%s"}' "$D" | "$BIN" prompt --repo "$D")"
RC=$?
[ -z "$OUT" ] && ok "no stdout on empty inbox" || bad "unexpected stdout: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
rm -rf "$D"

echo "9. STATUS --json -> reports pending count and waiting flag, never pops:"
D="$(make_project)"
seed_inbox "$D" "a" "b"
OUT="$("$BIN" status --json --repo "$D")"
RC=$?
echo "$OUT" | grep -q '"pending"[[:space:]]*:[[:space:]]*2' && ok "pending count is 2" || bad "wrong pending count: $OUT"
echo "$OUT" | grep -q '"waiting"[[:space:]]*:[[:space:]]*false' && ok "waiting defaults false" || bad "wrong waiting default: $OUT"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC (want 0)"
[ "$(wc -l < "$(inbox_of "$D")" | tr -d ' ')" = "2" ] && ok "status is non-destructive (still 2 queued)" || bad "status mutated the inbox"
printf '{"waiting":true,"since":1}' > "$(state_of "$D")"
OUT="$("$BIN" status --json --repo "$D")"
echo "$OUT" | grep -q '"waiting"[[:space:]]*:[[:space:]]*true' && ok "waiting reflects inbox-state.json" || bad "waiting not reflected: $OUT"
rm -rf "$D"

echo "10. GARBAGE STDIN -> exit 0, no output, no crash:"
D="$(make_project)"
OUT="$(printf '%s' 'not json at all {{{' | "$BIN" stop --repo "$D" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "stop mode: exit 0 on garbage stdin" || bad "exit $RC (want 0)"
[ -z "$OUT" ] && ok "stop mode: no output on garbage stdin" || bad "unexpected output: $OUT"
OUT2="$(printf '%s' 'garbage' | "$BIN" prompt --repo "$D" 2>&1)"
RC2=$?
[ "$RC2" -eq 0 ] && ok "prompt mode: exit 0 on garbage stdin" || bad "exit $RC2 (want 0)"
rm -rf "$D"

echo ""
echo "heimdall-inbox-deliver.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
