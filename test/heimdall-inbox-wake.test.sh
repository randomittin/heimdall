#!/usr/bin/env bash
# heimdall-inbox-wake.test.sh -- bin/heimdall-inbox-wake: wake an IDLE Claude Code session when a
# phone message lands (hmdapp docs/HANDOFF-TO-HEIMDALL-phone-replies-reach-session.md, 4(b)).
# Oracle: `watch` exits 2 with a FIXED notice (the asyncRewake contract: exit 2 wakes the model) only
# for a pending record the paired phone wrote (an inbox only our tooling can have produced, a live
# companion), while the session is idle, nobody holds the Stop long-poll and nobody types; inside tmux it
# types a FIXED prompt into the session's own pane instead. Tests 15-20 are the security cases: forged
# or dropped inbox, no live companion, text in argv, a pane that is not this session's, exit 2 on bad
# arguments, unquoted interpolation in hooks.json. Exit 0 = every proof holds. Own-file run only.
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

# newproj -> a repo dir with a private .heimdall/ui, a live companion (connect.json), a fake "claude"
# process (alive, child of this shell), its status file and its SessionStart registration
newproj() {
  D="$(mktemp -d "$WORK/p.XXXXXX")"; mkdir -p "$D/.heimdall/ui/wake" "$D/.heimdall/app" "$D/sessions"
  chmod 700 "$D/.heimdall/ui" "$D/.heimdall/ui/wake"
  sleep 300 & CP=$!; TMPS="$TMPS $CP"
  printf '{"pid":%s,"status":"idle"}' "$CP" > "$D/sessions/$CP.json"
  printf '{"pid":%s,"tty":"/nonexistent-tty","tmux_pane":"","tmux_socket":""}' "$CP" > "$D/.heimdall/ui/wake/$CP.json"; chmod 600 "$D/.heimdall/ui/wake/$CP.json"
  printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"x","started_at":"t"}\n' "$CP" "$CP" > "$D/.heimdall/app/connect.json"
}
rec() { printf '{"id":"%s","ts":1,"text":"%s","source":"%s"}\n' "$1" "$2" "$3" >> "$D/.heimdall/ui/inbox.jsonl"; chmod 600 "$D/.heimdall/ui/inbox.jsonl"; }
# watch MAX_S -- runs the watcher; sets OUT (stderr), RC, EL (seconds)
watch() {
  local t0 t1; t0=$(date +%s)
  OUT="$(HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S="$1" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
  t1=$(date +%s); EL=$((t1 - t0))
}
quiet_wake() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }

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
quiet_wake && ok "rc 0, no wake for a record from another source or a garbage line" || bad "rc=$RC out=$OUT"

echo "4. watch: a busy session is left to its tool/Stop hooks; the wake comes once it is idle:"
newproj; rec b1 "hi" companion
printf '{"pid":%s,"status":"busy"}' "$CP" > "$D/sessions/$CP.json"
( sleep 3; printf '{"pid":%s,"status":"idle"}' "$CP" > "$D/sessions/$CP.json" ) & TMPS="$TMPS $!"
watch 12
[ "$RC" -eq 2 ] && [ "$EL" -ge 2 ] && ok "no wake while busy; woke ${EL}s in, after idle" || bad "rc=$RC after ${EL}s out=$OUT"

echo "5. watch: a live Stop long-poll (fresh inbox-waiting) is left to deliver; no wake:"
newproj; rec h1 "hi" companion
( for _ in $(seq 1 30); do : > "$D/.heimdall/ui/inbox-waiting"; sleep 0.1; done ) & TMPS="$TMPS $!"
watch 2
quiet_wake && ok "rc 0 while the hold is live" || bad "rc=$RC out=$OUT"

echo "6. ledger: one wake per record id -- the same id does not wake again, a new id does:"
newproj; rec l1 "hi" companion
watch 10; [ "$RC" -eq 2 ] && ok "first watcher woke for l1" || bad "rc=$RC"
watch 2;  quiet_wake && ok "second watcher: l1 already woken for, no wake loop" || bad "rc=$RC out=$OUT"
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
quiet_wake && ok "dead claude pid: rc 0, no wake" || bad "rc=$RC out=$OUT"
OUT="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli HMD_CLAUDE_SESSIONS_DIR="$D/sessions" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
quiet_wake && ok "headless session: rc 0, no wake" || bad "rc=$RC out=$OUT"
OUT="$(HMD_INBOX_WAKE=off HMD_CLAUDE_SESSIONS_DIR="$D/sessions" "$BIN" watch --repo "$D" --pid "$CP" 2>&1 >/dev/null)"; RC=$?
quiet_wake && ok "HMD_INBOX_WAKE=off: rc 0, no wake" || bad "rc=$RC out=$OUT"

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
  chmod 600 "$D/.heimdall/ui/wake/$CP.json"
}
# twatch PANE_PID MAX_S [TMUX_PANE [TMUX]] -- the watcher's own environment is the session's (claude's) tmux environment
twatch() { PATH="$FAKE:$PATH" TMUX_RECORD="$REC" PANE_PID="$1" TMUX_PANE="${3-%7}" TMUX="${4-/tmp/tmux-501/default,1,0}" watch "$2"; }

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
tmux_proj; rec t3 "hi" companion; touch -a "$QT"
twatch "$$" 2
grep -q "send-keys" "$REC" && bad "typed over a human: $(cat "$REC")" || ok "no keystroke while the terminal is being read"
quiet_wake && ok "no wake either" || bad "rc=$RC out=$OUT"

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
printf '{"pid":%s,"tty":"/nonexistent-tty","tmux_pane":"","tmux_socket":""}' "$$" > "$D/.heimdall/ui/wake/$$.json"; chmod 600 "$D/.heimdall/ui/wake/$$.json"
SC="$(jq -r '[.hooks.Stop[].hooks[] | select(.asyncRewake == true)] | .[0].command' "$HOOKS_JSON")"
OUT="$(CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S=10 bash -c "$SC" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "wired command exits 2" || bad "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "SECRET-PHONE-TEXT" && bad "phone text in the wake" || ok "wired wake carries no phone text"
HMD_DIR="$(mktemp -d "$WORK/h.XXXXXX")"; printf 'inbox-wake-arm-stop\n' > "$HMD_DIR/hooks-disabled"
rm -f "$D/.heimdall/ui/inbox-wake.json"
OUT="$(HEIMDALL_HOME="$HMD_DIR" CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PROJECT_DIR="$D" HMD_CLAUDE_SESSIONS_DIR="$D/sessions" HMD_INBOX_WAKE_MAX_S=10 bash -c "$SC" 2>&1 >/dev/null)"; RC=$?
quiet_wake && ok "disabled via heimdall-hooks: no watcher, no wake" || bad "disabled but rc=$RC out=$OUT"

echo "15. SECURITY (who may wake): a record only counts in an inbox this user owns, 0600, not a symlink, in a ui dir nobody else can write -- what a checkout or another account drops never wakes:"
newproj; rec a1 "hi" companion; chmod 644 "$D/.heimdall/ui/inbox.jsonl"
watch 2; quiet_wake && ok "a 0644 inbox.jsonl (all a git checkout can ship) never wakes" || bad "rc=$RC out=$OUT"
chmod 600 "$D/.heimdall/ui/inbox.jsonl"; chmod 777 "$D/.heimdall/ui"
watch 2; quiet_wake && ok "a world-writable .heimdall/ui never wakes" || bad "rc=$RC out=$OUT"
chmod 700 "$D/.heimdall/ui"; mv "$D/.heimdall/ui/inbox.jsonl" "$D/real-inbox"; ln -s "$D/real-inbox" "$D/.heimdall/ui/inbox.jsonl"
watch 2; quiet_wake && ok "a symlinked inbox.jsonl never wakes" || bad "rc=$RC out=$OUT"
rm "$D/.heimdall/ui/inbox.jsonl"; mv "$D/real-inbox" "$D/.heimdall/ui/inbox.jsonl"
watch 10; [ "$RC" -eq 2 ] && ok "the same record in a proper inbox wakes (the gate, not the data, was the difference)" || bad "rc=$RC out=$OUT"

echo "16. SECURITY (authenticated channel): a wake needs a LIVE companion -- no connect.json, dead pids or a shared-writable one means no wake:"
newproj; rec c1 "hi" companion; rm "$D/.heimdall/app/connect.json"
watch 2; quiet_wake && ok "no connect.json: no wake" || bad "rc=$RC out=$OUT"
( : ) & DEADP=$!; wait "$DEADP" 2>/dev/null
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s}\n' "$DEADP" "$DEADP" > "$D/.heimdall/app/connect.json"
watch 2; quiet_wake && ok "connect.json naming dead pids: no wake" || bad "rc=$RC out=$OUT"
printf '{"mode":"direct","pid_ui":%s}\n' "$CP" > "$D/.heimdall/app/connect.json"; chmod 666 "$D/.heimdall/app/connect.json"
watch 2; quiet_wake && ok "a world-writable connect.json: no wake" || bad "rc=$RC out=$OUT"
chmod 600 "$D/.heimdall/app/connect.json"
watch 10; [ "$RC" -eq 2 ] && ok "a live direct-mode companion wakes" || bad "rc=$RC out=$OUT"

echo "17. SECURITY (nothing from the inbox reaches argv): shell metacharacters and tmux key names in a message are never sent; only the three fixed tmux calls run:"
tmux_proj; rec v1 '; touch PWNED # -t %1 Enter $(touch PWNED2) `touch PWNED3`' companion
twatch "$$" 3
BADLINES="$(grep -v -x -F -e '-S /tmp/tmux-501/default list-panes -a -F #{pane_id} #{pane_pid}' -e '-S /tmp/tmux-501/default send-keys -t %7 -l phone message waiting' -e '-S /tmp/tmux-501/default send-keys -t %7 Enter' "$REC")"
[ -z "$BADLINES" ] && [ -s "$REC" ] && ok "every tmux argv is one of the three constant shapes (list-panes, send-keys -l <fixed>, send-keys Enter)" || bad "unexpected tmux argv: $BADLINES"
[ ! -e PWNED ] && [ ! -e PWNED2 ] && [ ! -e PWNED3 ] && ok "nothing was shell-interpreted" || bad "a message reached a shell"

echo "18. SECURITY (own pane only): the SessionStart record must agree with THIS session's own TMUX_PANE/TMUX; another pane, a blank environment or a droppable 0644 record is never typed into:"
tmux_proj; rec m1 "hi" companion
twatch "$$" 10 '%8'
grep -q "send-keys" "$REC" && bad "typed into %8 although the session runs in %7: $(cat "$REC")" || ok "record says %7, session environment says %8: no keystroke"
[ "$RC" -eq 2 ] && ok "falls back to the rewake exit" || bad "rc=$RC"
tmux_proj; rec m2 "hi" companion
twatch "$$" 10 "" ""
grep -q "send-keys" "$REC" && bad "typed with no tmux environment" || ok "no TMUX_PANE in the session environment: no keystroke"
[ "$RC" -eq 2 ] && ok "falls back to the rewake exit" || bad "rc=$RC"
tmux_proj; rec m3 "hi" companion; chmod 644 "$D/.heimdall/ui/wake/$CP.json"
twatch "$$" 10
grep -q "send-keys" "$REC" && bad "trusted a 0644 registration" || ok "a registration file that is not 0600 and ours is ignored"
[ "$RC" -eq 2 ] && ok "falls back to the rewake exit" || bad "rc=$RC"

echo "19. SECURITY (exit 2 means wake): bad arguments exit 0, never 2 -- argparse's own usage-error code would wake the model:"
newproj
"$BIN" watch --repo "$D" --pid notanumber >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "a non-numeric --pid exits 0" || bad "--pid garbage exited $RC"
"$BIN" frobnicate >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "an unknown mode exits 0" || bad "unknown mode exited $RC"
"$BIN" watch --repo -x --pid "$CP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "an option-shaped --repo exits 0" || bad "--repo -x exited $RC"

echo "20. SECURITY (hooks.json): the wake commands quote every interpolated value and never eval, backtick or feed the payload into a shell:"
for ID in inbox-wake-register inbox-wake-arm-start inbox-wake-arm-stop; do
  C="$(jq -r --arg id "$ID" '[.hooks[][]?.hooks[]? | select((.command // "") | contains("hmd_hook_enabled " + $id + " "))] | .[0].command // empty' "$HOOKS_JSON")"
  case "$C" in *'--repo "${CLAUDE_PROJECT_DIR:-.}" --pid "$PPID"'*) ok "$ID: --repo and --pid are double-quoted" ;; *) bad "$ID: unquoted --repo/--pid: $C" ;; esac
  printf '%s' "$C" | grep -q -E 'eval |`|INPUT=|jq |\| *(ba)?sh' && bad "$ID: evals or interpolates the payload" || ok "$ID: no eval, backtick, jq or payload variable"
  printf '%s' "$C" | grep -q '"$HOOK"' && ok "$ID: the binary path is quoted" || bad "$ID: unquoted binary path"
done

echo ""
echo "heimdall-inbox-wake.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
