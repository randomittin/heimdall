#!/usr/bin/env bash
# heimdall-inbox-wake.test.sh -- bin/heimdall-inbox-wake: wake an IDLE Claude Code session when a
# phone message lands (hmdapp docs/HANDOFF-TO-HEIMDALL-phone-replies-reach-session.md, 4(b)).
# Oracle: `watch` exits 2 with a FIXED notice (the asyncRewake contract: exit 2 wakes the model) only
# for a pending record the paired phone wrote, while the session is idle, nobody holds the Stop long-poll
# and nobody types; inside tmux it types a FIXED prompt into the session's own pane instead. Exit 0 = every
# proof holds. Own-file run only; the full gate is the orchestrator's one sweep.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-inbox-wake"
HOOKS_JSON="$REPO/hooks/hooks.json"
HOOKS_META="$REPO/hooks/hooks.metadata.json"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

export CLAUDE_CODE_ENTRYPOINT=cli
unset HMD_AGENT_TYPE HMD_JUDGMENT HMD_INBOX_WAKE HMD_INBOX_WAKE_TMUX_QUIET_S TMUX TMUX_PANE
export HMD_INBOX_WAKE_POLL_S=0.2

TMPS=""
cleanup() { for p in $TMPS; do kill "$p" 2>/dev/null; done; rm -rf "${WORK:-/nonexistent-wake-test}"; }
trap cleanup EXIT
WORK="$(mktemp -d)"

# newproj -> a repo dir with .heimdall/ui, a fake "claude" process (alive, child of this shell), its status file
newproj() {
  D="$(mktemp -d "$WORK/p.XXXXXX")"; mkdir -p "$D/.heimdall/ui/wake" "$D/sessions"
  sleep 300 & CP=$!; TMPS="$TMPS $CP"
  printf '{"pid":%s,"status":"idle"}' "$CP" > "$D/sessions/$CP.json"
  printf '{"pid":%s,"tty":"/nonexistent-tty","tmux_pane":"","tmux_socket":""}' "$CP" > "$D/.heimdall/ui/wake/$CP.json"
}
rec() { printf '{"id":"%s","ts":1,"text":"%s","source":"%s"}\n' "$1" "$2" "$3" >> "$D/.heimdall/ui/inbox.jsonl"; }
# watch MAX_S -- runs the watcher; sets OUT (stderr), RC, EL (seconds)
watch() {
  local t0 t1; t0=$(date +%s)
  OUT="$(HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S="$1" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
  t1=$(date +%s); EL=$((t1 - t0))
}

echo "1. register: records the session's own pane + socket at 0600; a malformed pane is not recorded:"
newproj
printf '{"session_id":"s1"}' | TMUX_PANE='%7' TMUX='/tmp/tmux-501/default,123,0' "$BIN" register --repo "$D" --pid "$CP"
F="$D/.heimdall/ui/wake/$CP.json"
[ "$(jq -r '.tmux_pane' "$F")" = '%7' ] && [ "$(jq -r '.tmux_socket' "$F")" = '/tmp/tmux-501/default' ] && ok "pane %7 and its socket recorded" || bad "registration: $(cat "$F")"
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$F")" = "0o600" ] && ok "registration file is 0600" || bad "mode not 0600"
printf '{}' | TMUX_PANE='%7; touch /tmp/wake-pwned' TMUX='/x/y,1,0' "$BIN" register --repo "$D" --pid "$CP"
[ "$(jq -r '.tmux_pane' "$F")" = "" ] && ok "a pane that is not %N is dropped (never reaches tmux)" || bad "bad pane kept: $(cat "$F")"
printf '{}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli TMUX_PANE='%9' "$BIN" register --repo "$D" --pid "$CP"
[ "$(jq -r '.tmux_pane' "$F")" = "" ] && ok "a headless session does not register (file untouched)" || bad "headless registered"

echo "2. watch: a pending phone record + idle session -> exit 2 with the FIXED notice; no phone text in it; the id is claimed:"
newproj; rec r1 "SECRET-PHONE-TEXT" companion
watch 10
[ "$RC" -eq 2 ] && ok "exit 2 (asyncRewake: wake the model)" || bad "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "waiting in the companion inbox" && ok "the notice says a phone message is waiting" || bad "notice: $OUT"
printf '%s' "$OUT" | grep -q "SECRET-PHONE-TEXT" && bad "the phone text leaked into the wake" || ok "no message text in the wake (the deliver hooks carry it)"
[ "$(jq -r '.woken | keys[0]' "$D/.heimdall/ui/inbox-wake.json")" = "r1" ] && ok "ledger claims r1" || bad "ledger: $(cat "$D/.heimdall/ui/inbox-wake.json" 2>&1)"
grep -q SECRET-PHONE-TEXT "$D/.heimdall/ui/inbox.jsonl" && ok "the wake popped nothing: the message is still queued for the deliver hooks" || bad "wake consumed the message"

echo "3. watch: only the paired phone's records wake (source companion); anything else is ignored:"
newproj; rec x1 "from a script" "script"; printf 'not json\n' >> "$D/.heimdall/ui/inbox.jsonl"
watch 2
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "rc 0, no wake for a record from another source or a garbage line" || bad "rc=$RC out=$OUT"

echo "4. watch: a busy session is left to its tool/Stop hooks; the wake comes once it is idle:"
newproj; rec b1 "hi" companion
printf '{"pid":%s,"status":"busy"}' "$CP" > "$D/sessions/$CP.json"
( sleep 2; printf '{"pid":%s,"status":"idle"}' "$CP" > "$D/sessions/$CP.json" ) & TMPS="$TMPS $!"
watch 12
[ "$RC" -eq 2 ] && [ "$EL" -ge 2 ] && ok "no wake while busy; woke ${EL}s in, after idle" || bad "rc=$RC after ${EL}s out=$OUT"

echo "5. watch: a live Stop long-poll (fresh inbox-waiting) is left to deliver; no wake:"
newproj; rec h1 "hi" companion
( for _ in $(seq 1 30); do : > "$D/.heimdall/ui/inbox-waiting"; sleep 0.1; done ) & TMPS="$TMPS $!"
watch 2
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "rc 0 while the hold is live" || bad "rc=$RC out=$OUT"

echo "6. ledger: one wake per record id -- the same id does not wake again, a new id does:"
newproj; rec l1 "hi" companion
watch 10; [ "$RC" -eq 2 ] && ok "first watcher woke for l1" || bad "rc=$RC"
watch 2;  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "second watcher: l1 already woken for, no wake loop" || bad "rc=$RC out=$OUT"
rec l2 "hi again" companion
watch 10; [ "$RC" -eq 2 ] && ok "a NEW record id wakes again" || bad "rc=$RC out=$OUT"

echo "7. one watcher per session: a second one exits at once while the first is armed:"
newproj
( HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S=5 "$BIN" watch --repo "$D" --pid "$CP" >/dev/null 2>&1 ) & W1=$!; TMPS="$TMPS $W1"
sleep 1
watch 5
[ "$RC" -eq 0 ] && [ "$EL" -le 1 ] && ok "second watcher returned in ${EL}s (instance lock held by the first)" || bad "rc=$RC after ${EL}s"
wait "$W1" 2>/dev/null

echo "8. watch stands down for a dead session, a headless session and HMD_INBOX_WAKE=off:"
newproj; rec d1 "hi" companion
sleep 0.1 & DEAD=$!; wait "$DEAD" 2>/dev/null
OUT="$(HMD_INBOX_WAKE_MAX_S=5 "$BIN" watch --repo "$D" --pid "$DEAD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "dead claude pid: rc 0, no wake" || bad "rc=$RC out=$OUT"
OUT="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli HMD_CLAUDE_SESSIONS_DIR="$D/sessions" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "headless session: rc 0, no wake" || bad "rc=$RC out=$OUT"
OUT="$(HMD_INBOX_WAKE=off HMD_CLAUDE_SESSIONS_DIR="$D/sessions" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "HMD_INBOX_WAKE=off: rc 0, no wake" || bad "rc=$RC out=$OUT"

# tmux: a fake binary on PATH records the arguments and answers list-panes with a pane whose pid is this shell
# (an ancestor of the fake claude, which is this shell's child).
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/tmux" <<'FAKETMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_RECORD"
case "$*" in *list-panes*) printf '%%7 %s\n%%8 1\n' "$PANE_PID" ;; esac
exit 0
FAKETMUX
chmod +x "$FAKE/tmux"
quiet_tty() { QT="$WORK/qtty.$$"; : > "$QT"; python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1], (t, t))' "$QT"; }
tmux_proj() {
  newproj; quiet_tty; REC="$WORK/rec.$CP"; : > "$REC"
  printf '{"pid":%s,"tty":"%s","tmux_pane":"%%7","tmux_socket":"/tmp/tmux-501/default"}' "$CP" "$QT" > "$D/.heimdall/ui/wake/$CP.json"
}
twatch() { PATH="$FAKE:$PATH" TMUX_RECORD="$REC" PANE_PID="$1" watch "$2"; }

echo "9. tmux: the session's own pane gets the FIXED prompt + Enter (a real user turn); nothing else, no exit 2:"
tmux_proj; rec t1 "SECRET-PHONE-TEXT" companion
twatch "$$" 3
grep -q -- "send-keys -t %7 -l phone message waiting" "$REC" && grep -q -- "send-keys -t %7 Enter" "$REC" && ok "typed 'phone message waiting' + Enter into -t %7" || bad "tmux calls: $(cat "$REC")"
grep -q "SECRET-PHONE-TEXT" "$REC" && bad "phone text reached tmux" || ok "no phone text sent to the pane"
grep -q -- "-S /tmp/tmux-501/default" "$REC" && ok "targets the recorded tmux socket" || bad "no -S socket: $(cat "$REC")"
[ "$RC" -eq 0 ] && ok "rc 0: the watcher keeps watching after a keystroke wake (ledger bounds repeats)" || bad "rc=$RC"

echo "10. tmux: a pane that is NOT an ancestor of the session is never typed into; falls back to the rewake exit:"
tmux_proj; rec t2 "hi" companion
twatch "99999" 10
grep -q "send-keys" "$REC" && bad "typed into a pane that is not the session's: $(cat "$REC")" || ok "no send-keys into a foreign pane"
[ "$RC" -eq 2 ] && ok "rewake (exit 2) used instead" || bad "rc=$RC out=$OUT"

echo "11. tmux: the terminal was read just now (somebody is typing) -> neither keystroke nor wake; their prompt carries the message:"
tmux_proj; rec t3 "hi" companion; : > "$QT"
twatch "$$" 2
grep -q "send-keys" "$REC" && bad "typed over a human: $(cat "$REC")" || ok "no keystroke while the terminal is being read"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "no wake either" || bad "rc=$RC out=$OUT"

echo "12. tmux: terminal read 10-30s ago (a draft may be pending) -> no keystroke, rewake instead:"
tmux_proj; rec t4 "hi" companion; python3 -c 'import os,sys,time; t=time.time()-15; os.utime(sys.argv[1], (t, t))' "$QT"
twatch "$$" 10
grep -q "send-keys" "$REC" && bad "typed within the quiet window" || ok "no keystroke inside the quiet window"
[ "$RC" -eq 2 ] && ok "rewake exit used" || bad "rc=$RC"

echo "13. hooks.json: SessionStart register + armed watcher, Stop re-arm; asyncRewake, exec (exit 2 survives the shell), kill switches, sidecar ids:"
for ID in inbox-wake-register inbox-wake-arm-start inbox-wake-arm-stop; do
  C="$(jq -r --arg id "$ID" '[.hooks[][]?.hooks[]? | select((.command // "") | contains("hmd_hook_enabled " + $id + " "))] | .[0].command // empty' "$HOOKS_JSON")"
  [ -n "$C" ] && ok "$ID: wired with the kill-switch prefix" || { bad "$ID: not wired"; continue; }
  [ "$(jq -r --arg id "$ID" '[.hooks[] | select(.id == $id)] | length' "$HOOKS_META")" = "1" ] && ok "$ID: one sidecar entry" || bad "$ID: sidecar count"
  [ "$(jq -r --arg id "$ID" '.hooks[] | select(.id == $id) | .locked' "$HOOKS_META")" = "false" ] && ok "$ID: advisory (the operator can switch it off)" || bad "$ID: locked"
done
for ID in inbox-wake-arm-start inbox-wake-arm-stop; do
  H="$(jq -c --arg id "$ID" '[.hooks[][]?.hooks[]? | select((.command // "") | contains("hmd_hook_enabled " + $id + " "))] | .[0]' "$HOOKS_JSON")"
  [ "$(printf '%s' "$H" | jq -r '.asyncRewake')" = "true" ] && ok "$ID: asyncRewake true" || bad "$ID: not asyncRewake"
  [ "$(printf '%s' "$H" | jq -r '.timeout')" = "28800" ] && ok "$ID: timeout 28800 (the watcher's 8h bound)" || bad "$ID: timeout"
  printf '%s' "$H" | jq -r '.command' | grep -q 'exec "$HOOK" watch --repo' && ok "$ID: exec's the watcher so its exit 2 is the hook's" || bad "$ID: no exec"
done
[ "$(jq -r '[.hooks.Stop[].hooks[] | select(.asyncRewake == true)] | length' "$HOOKS_JSON")" = "1" ] && ok "Stop carries exactly one asyncRewake hook" || bad "Stop asyncRewake count"
"$REPO/bin/heimdall-hooks" check >/dev/null 2>&1 && ok "heimdall-hooks check passes against the sidecar" || bad "heimdall-hooks check fails"

echo "14. the wired Stop command end to end: a phone record lands while the session is idle -> the hook command itself exits 2:"
newproj; rec e1 "SECRET-PHONE-TEXT" companion
printf '{"pid":%s,"status":"idle"}' "$$" > "$D/sessions/$$.json"
printf '{"pid":%s,"tty":"/nonexistent-tty","tmux_pane":"","tmux_socket":""}' "$$" > "$D/.heimdall/ui/wake/$$.json"
SC="$(jq -r '[.hooks.Stop[].hooks[] | select(.asyncRewake == true)] | .[0].command' "$HOOKS_JSON")"
OUT="$(CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S=10 bash -c "$SC" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "wired command exits 2" || bad "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "SECRET-PHONE-TEXT" && bad "phone text in the wake" || ok "wired wake carries no phone text"
HMD_DIR="$(mktemp -d "$WORK/h.XXXXXX")"; mkdir -p "$HMD_DIR"; printf 'inbox-wake-arm-stop\n' > "$HMD_DIR/hooks-disabled"
rm -f "$D/.heimdall/ui/inbox-wake.json"
OUT="$(HEIMDALL_HOME="$HMD_DIR" CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S=10 bash -c "$SC" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "disabled via heimdall-hooks: no watcher, no wake" || bad "disabled but rc=$RC out=$OUT"

echo ""
echo "heimdall-inbox-wake.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
