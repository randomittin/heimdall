#!/usr/bin/env bash
#
# restart-request-hook.test.sh -- bin/heimdall-restart-request, the Stop hook that ASKS the supervising launcher to restart claude on an
# updated binary or plugin (Task W2-hook of docs/superpowers/plans/2026-11-13-seamless-update-restart.md, section 2 step 2).
#
# The hook only ever asks, atomically and quietly, and cannot affect a turn. Every claim below is run against the real script, with a fake
# launcher (a python process that records the signals it gets, and owns one child that stands in for claude) and a fake `heimdall-update-pending`:
#   A. every no-op leaves no request file, sends no signal, prints nothing on stdout or stderr and exits 0: no launcher pid (or one that is not a
#      process id, or is gone), HMD_AUTO_RESTART=off, stop_hook_active, nothing pending (or an answer that is no JSON object), a claude that is not
#      the launcher's child, an unusable session id or payload, a restart directory that is relative or a link. A request already on disk survives
#      a failed attempt byte for byte.
#   B. the happy path writes req.json (0600, in a 0700 directory it creates, the shape bin/lib/hmd_restart_gate.py reads) and sends USR1 to the
#      launcher, exactly once; a later Stop replaces the file; the hook says nothing and leaves no temp file behind.
#   C. the hook entry of hooks/hooks.json: one entry, gated by `hmd_hook_enabled seamless-restart`, registered in hooks.metadata.json, handing the
#      script the claude pid and the payload, swallowing the script's noise and exit status.
#   D. the first statements fork nothing: under RLIMIT_NPROC=1 (every fork fails) both the script and the hook entry end cleanly when the session
#      is not supervised, or HMD_AUTO_RESTART=off.
#   E. the script never ends anything and never blocks a turn: its only signal is one USR1, to the launcher.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HMD_TEST_RESTART_REQUEST:-$REPO/bin/heimdall-restart-request}"
HOOKS_JSON="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
finish() { printf '\n  restart-request-hook: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

for tool in jq python3 perl ps mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not found"; exit 2; }
done
PY="$(python3 -c 'import sys; print(sys.executable)')" && [ -n "$PY" ] || { echo "FATAL: cannot resolve python3"; exit 2; }

TMP="$(mktemp -d)" || exit 2
LAUNCHERS=()
cleanup() {
  local p
  for p in "${LAUNCHERS[@]:-}"; do [ -n "$p" ] && kill -USR2 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'STRAY=1' USR1   # a USR1 that reaches THIS shell (a hook signalling a process group) must show up as a failure, not kill the run

unset HMD_LAUNCHER_PID HMD_AUTO_RESTART HMD_RESTART_DIR HMD_LAUNCHER_START_HMD HMD_UPDATE_PENDING_CMD HMD_RESTART_REQUEST_DEBUG CLAUDE_PLUGIN_ROOT
export HEIMDALL_HOME="$TMP/home"
mkdir -p "$TMP/cwd"

mode_of() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }

# the launcher: records USR1 and USR2 in order, exits on USR2 (the test's sentinel), and owns one child, the stand-in for claude
cat > "$TMP/fake-launcher.py" <<'PY'
import os
import signal
import subprocess
import sys

log, fifo, childfile = sys.argv[1:4]
child = subprocess.Popen(["sleep", "120"])


def seen(number, frame):
    with open(log, "a") as handle:
        handle.write(signal.Signals(number).name[3:] + "\n")
    if number == signal.SIGUSR2:
        child.kill()
        child.wait()
        os._exit(0)


signal.signal(signal.SIGUSR1, seen)
signal.signal(signal.SIGUSR2, seen)
with open(childfile, "w") as handle:
    handle.write(str(child.pid))
with open(fifo, "w") as handle:
    handle.write("ready\n")
while True:
    signal.pause()
PY

# heimdall-update-pending: logs its arguments, then exits FAKE_PENDING_EXIT (default 0) or prints FAKE_PENDING_OUT
cat > "$TMP/fake-pending" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_PENDING_LOG"
[ "${FAKE_PENDING_EXIT:-0}" = 0 ] || exit "$FAKE_PENDING_EXIT"
printf '%s\n' "$FAKE_PENDING_OUT"
EOF
chmod +x "$TMP/fake-pending"

PEND='{"claude":["2.1.319","2.1.322"],"hmd":["2.4.1","2.4.2"]}'
PAY='{"session_id":"sess-123","hook_event_name":"Stop","stop_hook_active":false}'
LN=0
N=0

launcher_start() {   # sets LP (the launcher pid), CP (its child, the claude stand-in) and LLOG (the signals it saw)
  LN=$((LN + 1)); LLOG="$TMP/launcher.$LN.log"; : > "$LLOG"
  rm -f "$TMP/ready"; mkfifo "$TMP/ready"; exec 7<>"$TMP/ready"
  "$PY" -I -S "$TMP/fake-launcher.py" "$LLOG" "$TMP/ready" "$TMP/child.pid" &
  LP=$!; LAUNCHERS+=("$LP")
  read -t 15 -u 7 -r _ || { bad "the fake launcher did not start"; exec 7<&-; finish; exit 1; }
  exec 7<&-
  CP="$(cat "$TMP/child.pid")"
}

launcher_stop() {    # SIGUSR2 ends the launcher; SIGS is every signal it saw, in order, on one line
  kill -USR2 "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
  SIGS="$(tr '\n' ' ' < "$LLOG" | sed 's/ $//')"
}

new_dir() { N=$((N + 1)); RD="$TMP/state/restart/$N"; }

run_hook() {   # run_hook PAYLOAD [VAR=value ...]: the real script as the hook entry runs it; RC, $TMP/out and $TMP/err
  local payload="$1"; shift
  : > "$TMP/pending.log"
  ( cd "$TMP/cwd" && env HMD_LAUNCHER_PID="$LP" HMD_RESTART_DIR="$RD" HMD_LAUNCHER_START_HMD=2.4.1 HMD_UPDATE_PENDING_CMD="$TMP/fake-pending" \
      FAKE_PENDING_LOG="$TMP/pending.log" FAKE_PENDING_OUT="$PEND" "$@" bash "$HOOK" --claude-pid "${PIDARG:-$CP}" <<<"$payload" >"$TMP/out" 2>"$TMP/err" )
  RC=$?
}

noop() {   # noop LABEL called|not-called PAYLOAD [VAR=value ...]: exit 0, silent, no request file, and update-pending asked (or not)
  local label="$1" want="$2" payload="$3" called=not-called; shift 3
  new_dir
  run_hook "$payload" "$@"
  [ -s "$TMP/pending.log" ] && called=called
  if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] && [ ! -e "$RD/req.json" ] && [ "$called" = "$want" ]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$(head -c 80 "$TMP/out") err=$(head -c 120 "$TMP/err") request=$([ -e "$RD/req.json" ] && echo written || echo none) update-pending=$called (wanted $want)"
  fi
}

# ---- A. every no-op -----------------------------------------------------------------------------------------------------------------------------
echo "A. no-ops"
launcher_start
noop "HMD_LAUNCHER_PID unset (not a supervised session): update-pending is never asked" not-called "$PAY" HMD_LAUNCHER_PID=
noop "HMD_AUTO_RESTART=off" not-called "$PAY" HMD_AUTO_RESTART=off
noop "HMD_AUTO_RESTART=OFF (the gate reads off in any case, so does the hook)" not-called "$PAY" HMD_AUTO_RESTART=OFF
noop "stop_hook_active true (a Stop that is itself a continuation)" not-called '{"session_id":"sess-123","stop_hook_active":true}'
noop "update-pending exits 1 (nothing is pending)" called "$PAY" FAKE_PENDING_EXIT=1
noop "update-pending exits 2 (it could not answer)" called "$PAY" FAKE_PENDING_EXIT=2
noop "update-pending prints something that is no JSON" called "$PAY" FAKE_PENDING_OUT=claude
noop "update-pending prints JSON that is no object" called "$PAY" 'FAKE_PENDING_OUT=["claude"]'
true & DEAD=$!; wait "$DEAD" 2>/dev/null
noop "the launcher process is gone (kill -0 fails)" not-called "$PAY" HMD_LAUNCHER_PID="$DEAD"
for v in abc 0 -5 '12 34' 4294967297; do
  noop "HMD_LAUNCHER_PID=$v is no process id" not-called "$PAY" HMD_LAUNCHER_PID="$v"
done
PIDARG=$$ noop "claude (the test shell) is not a child of the launcher: a stale launcher pid reused by another process is never signalled" not-called "$PAY"
PIDARG=2147483646 noop "claude pid names no process" not-called "$PAY"
PIDARG=abc noop "--claude-pid is no process id" not-called "$PAY"
for sid in '-rf' 'a b' 'x;y' 'a/../b' "$(printf 'a%.0s' $(seq 1 129))"; do
  noop "session_id '${sid:0:20}' is not a usable id (it ends up on a --resume command line)" not-called "{\"session_id\":\"$sid\",\"stop_hook_active\":false}"
done
noop "no session_id in the payload" not-called '{"stop_hook_active":false}'
noop "payload is not JSON" not-called 'not json at all'
noop "payload is a JSON array" not-called '[1,2]'
noop "payload is empty" not-called ''
noop "HMD_RESTART_DIR unset" not-called "$PAY" HMD_RESTART_DIR=
noop "HMD_RESTART_DIR relative (it would land in the project)" not-called "$PAY" HMD_RESTART_DIR=rel/dir

new_dir; mkdir -p "$TMP/linktarget" "$TMP/state/restart"; ln -s "$TMP/linktarget" "$RD"
run_hook "$PAY"
if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] && [ -z "$(ls -A "$TMP/linktarget")" ]; then
  ok "HMD_RESTART_DIR is a symlink: nothing is written through it"
else
  bad "HMD_RESTART_DIR is a symlink: nothing is written through it" "rc=$RC target now holds: $(ls -A "$TMP/linktarget" | head -3 | tr '\n' ' ')"
fi

new_dir; mkdir -p "$RD"; printf '{"old":true}\n' > "$RD/req.json"
run_hook "$PAY" FAKE_PENDING_EXIT=1
if [ "$RC" = 0 ] && [ "$(cat "$RD/req.json")" = '{"old":true}' ] && [ "$(ls -A "$RD")" = req.json ]; then
  ok "a failed attempt leaves the request already on disk byte for byte, and no temp file"
else
  bad "a failed attempt leaves the request already on disk byte for byte, and no temp file" "now: $(cat "$RD/req.json") / dir: $(ls -A "$RD" | tr '\n' ' ')"
fi

new_dir
run_hook "$PAY" FAKE_PENDING_EXIT=1 HMD_RESTART_REQUEST_DEBUG=1
if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && grep -q '^heimdall-restart-request: ' "$TMP/err"; then
  ok "HMD_RESTART_REQUEST_DEBUG=1 says why on stderr (stdout stays empty, exit stays 0)"
else
  bad "HMD_RESTART_REQUEST_DEBUG=1 says why on stderr" "rc=$RC out=$(head -c 60 "$TMP/out") err=$(head -c 100 "$TMP/err")"
fi

launcher_stop
[ "$SIGS" = USR2 ] && ok "no no-op sent the launcher a signal" || bad "no no-op sent the launcher a signal" "the launcher saw: $SIGS"
[ -z "${STRAY:-}" ] && ok "no no-op signalled the test's own process group" || bad "a no-op signalled the test's own process group"
[ -z "$(ls -A "$TMP/cwd")" ] && ok "nothing was created in the cwd (the project)" || bad "something was created in the cwd" "$(ls -A "$TMP/cwd" | head -3 | tr '\n' ' ')"

# ---- B. the happy path --------------------------------------------------------------------------------------------------------------------------
echo "B. a request"
launcher_start
new_dir
run_hook "$PAY"
launcher_stop
if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then ok "exit 0, nothing on stdout or stderr"; else bad "exit 0, nothing on stdout or stderr" "rc=$RC out=$(head -c 80 "$TMP/out") err=$(head -c 120 "$TMP/err")"; fi
if [ -f "$RD/req.json" ] && [ "$(mode_of "$RD/req.json")" = 600 ] && [ "$(mode_of "$RD")" = 700 ] && [ "$(mode_of "$(dirname "$RD")")" = 700 ] && [ "$(ls -A "$RD")" = req.json ]; then
  ok "req.json is 0600 in a 0700 directory the hook created, and no temp file is left"
else
  bad "req.json is 0600 in a 0700 directory the hook created, and no temp file is left" "dir=$(mode_of "$RD" 2>&1) parent=$(mode_of "$(dirname "$RD")" 2>&1) file=$(mode_of "$RD/req.json" 2>&1) holds: $(ls -A "$RD" 2>&1 | tr '\n' ' ')"
fi
if jq -e --arg sid sess-123 --argjson pid "$CP" --argjson pend "$PEND" --argjson now "$(date +%s)" \
     '(keys | sort) == ["claude_pid","pending","session_id","stop_ts"] and .session_id == $sid and .claude_pid == $pid and .pending == $pend and ((.stop_ts - $now) | fabs) < 60' \
     "$RD/req.json" >/dev/null 2>&1; then
  ok "req.json holds {session_id, claude_pid, stop_ts, pending}: the payload's session id, the claude pid, now, update-pending's own JSON"
else
  bad "req.json holds {session_id, claude_pid, stop_ts, pending}" "$(head -c 300 "$RD/req.json" 2>&1)"
fi
GATE_PID="$("$PY" -I -S -c 'import sys, time; sys.path.insert(0, sys.argv[1]); import hmd_restart_gate as gate; print(gate.load_request(sys.argv[2], time.time())["pid"])' "$REPO/bin/lib" "$RD/req.json" 2>&1)"
[ "$GATE_PID" = "$CP" ] && ok "the restart gate's own loader reads the file (the contract between the two halves)" || bad "the restart gate's own loader reads the file" "$GATE_PID"
[ "$(cat "$TMP/pending.log")" = "--launcher-start-hmd 2.4.1 --pid $CP --json" ] && ok "update-pending is asked with the launcher's start version and the claude pid, as JSON" || bad "update-pending is asked with the launcher's start version and the claude pid, as JSON" "$(cat "$TMP/pending.log")"
[ "$SIGS" = "USR1 USR2" ] && ok "the launcher got exactly one USR1" || bad "the launcher got exactly one USR1" "it saw: $SIGS"

launcher_start
PAY2='{"session_id":"sess-456","hook_event_name":"Stop"}'
run_hook "$PAY2"
launcher_stop
if [ "$RC" = 0 ] && [ "$SIGS" = "USR1 USR2" ] && [ "$(ls -A "$RD")" = req.json ] \
   && jq -e --arg sid sess-456 --argjson pid "$CP" '.session_id == $sid and .claude_pid == $pid' "$RD/req.json" >/dev/null 2>&1; then
  ok "a later Stop replaces the request (new session id, new claude pid) and asks again"
else
  bad "a later Stop replaces the request and asks again" "rc=$RC signals=$SIGS file=$(head -c 200 "$RD/req.json" 2>&1) dir=$(ls -A "$RD" | tr '\n' ' ')"
fi

# ---- C. the hook entry --------------------------------------------------------------------------------------------------------------------------
echo "C. the hook entry"
if jq -e '[.hooks.Stop[].hooks[].command] | map(select(contains("heimdall-restart-request"))) | length == 1' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json: exactly one Stop entry runs heimdall-restart-request"
else
  bad "hooks.json: exactly one Stop entry runs heimdall-restart-request"
fi
CMD="$(jq -r '[.hooks.Stop[].hooks[].command | select(contains("heimdall-restart-request"))][0] // empty' "$HOOKS_JSON")"
case "$CMD" in
  *'hmd_hook_enabled seamless-restart'*"perl -e 'alarm 5; exec @ARGV'"*) ok "the entry is gated by hmd_hook_enabled seamless-restart and bounded by a 5 s alarm" ;;
  *) bad "the entry is gated by hmd_hook_enabled seamless-restart and bounded by a 5 s alarm" "${CMD:0:200}" ;;
esac
if jq -e '.hooks[] | select(.id == "seamless-restart") | .event == "Stop" and .locked == false and .remote_toggle == false' "$META" >/dev/null 2>&1; then
  ok "hooks.metadata.json registers seamless-restart (Stop, advisory, not remotely toggled)"
else
  bad "hooks.metadata.json registers seamless-restart (Stop, advisory, not remotely toggled)"
fi
if "$REPO/bin/heimdall-hooks" check >/dev/null 2>"$TMP/err"; then ok "heimdall-hooks check: hooks.json and its metadata agree"; else bad "heimdall-hooks check: hooks.json and its metadata agree" "$(head -c 300 "$TMP/err")"; fi

PLUG="$TMP/plugin"; mkdir -p "$PLUG/bin/lib" "$PLUG/hooks" "$TMP/stub" "$TMP/h2"
cp "$REPO/bin/lib/hook-enabled.sh" "$PLUG/bin/lib/"; cp "$META" "$PLUG/hooks/"
cat > "$PLUG/bin/heimdall-restart-request" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_DIR/args"
ps -o ppid= -p "$PPID" | tr -d ' ' > "$STUB_DIR/grandparent"
cat > "$STUB_DIR/stdin"
echo "noise on stdout"; echo "noise on stderr" >&2; exit 3
EOF
chmod +x "$PLUG/bin/heimdall-restart-request"
run_entry() {   # run_entry [VAR=value ...]: the hook entry's own command, as `sh -c`, with the Stop payload on stdin
  rm -f "$TMP/stub/args" "$TMP/stub/grandparent" "$TMP/stub/stdin"
  ( cd "$TMP/cwd" && env CLAUDE_PLUGIN_ROOT="$PLUG" STUB_DIR="$TMP/stub" "$@" sh -c "$CMD" <<<"$PAY" >"$TMP/out" 2>"$TMP/err" )
  RC=$?
}
run_entry HMD_LAUNCHER_PID=4242
if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] && [ -s "$TMP/stub/grandparent" ] \
   && [ "$(cat "$TMP/stub/args")" = "--claude-pid $(cat "$TMP/stub/grandparent")" ] && [ "$(cat "$TMP/stub/stdin")" = "$PAY" ]; then
  ok "a supervised session: the script gets the Stop payload and the hook's parent (claude) as --claude-pid; its noise and exit status never reach the harness"
else
  bad "a supervised session: the script gets the payload and --claude-pid; exit 0 and silence" "rc=$RC args=$(cat "$TMP/stub/args" 2>&1) grandparent=$(cat "$TMP/stub/grandparent" 2>&1) out=$(head -c 60 "$TMP/out") err=$(head -c 60 "$TMP/err")"
fi
run_entry
[ "$RC" = 0 ] && [ ! -e "$TMP/stub/args" ] && [ ! -s "$TMP/out" ] && ok "no HMD_LAUNCHER_PID: the script is never started" || bad "no HMD_LAUNCHER_PID: the script is never started" "rc=$RC"
printf 'seamless-restart\n' > "$TMP/h2/hooks-disabled"
run_entry HMD_LAUNCHER_PID=4242 HEIMDALL_HOME="$TMP/h2"
[ "$RC" = 0 ] && [ ! -e "$TMP/stub/args" ] && [ ! -s "$TMP/out" ] && ok "heimdall-hooks disable seamless-restart turns the entry off (hmd_hook_enabled)" || bad "heimdall-hooks disable seamless-restart turns the entry off" "rc=$RC script ran: $([ -e "$TMP/stub/args" ] && echo yes || echo no)"
printf 'some-other-hook\n' > "$TMP/h2/hooks-disabled"
run_entry HMD_LAUNCHER_PID=4242 HEIMDALL_HOME="$TMP/h2"
[ -e "$TMP/stub/args" ] && ok "control: another hook disabled, this one still runs" || bad "control: another hook disabled, this one still runs"

# ---- D. nothing forks before the early exits ----------------------------------------------------------------------------------------------------
echo "D. zero child processes"
# under RLIMIT_NPROC=1 every fork fails (bash then retries for ~15 s, so the alarm turns a fork into a failure in 4 s). A control proves the limit bites.
if ( ulimit -S -u 1 2>/dev/null && exec "$PY" -I -S -c 'import os, sys
try:
    os.fork()
except OSError:
    sys.exit(0)
sys.exit(1)' ) 2>/dev/null; then
  nofork() {   # nofork LABEL [VAR=value ...] -- COMMAND...
    local label="$1"; shift
    local -a vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
    ( ulimit -S -u 1; exec env "${vars[@]}" perl -e 'alarm 4; exec @ARGV' "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"
    RC=$?
    if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then ok "$label"; else bad "$label" "rc=$RC (142 = it tried to fork) err=$(head -c 120 "$TMP/err")"; fi
  }
  nofork "the script, HMD_LAUNCHER_PID unset: no fork" CLAUDE_PLUGIN_ROOT= -- bash "$HOOK"
  nofork "the script, HMD_AUTO_RESTART=off: no fork" HMD_LAUNCHER_PID=4242 HMD_AUTO_RESTART=off -- bash "$HOOK"
  nofork "the hook entry, HMD_LAUNCHER_PID unset: no fork, the script is not started" CLAUDE_PLUGIN_ROOT="$PLUG" STUB_DIR="$TMP/stub" -- sh -c "$CMD"
else
  ok "SKIPPED: RLIMIT_NPROC is not enforced for this user (root?), so a fork cannot be made to fail here"
fi

# ---- E. it only asks ----------------------------------------------------------------------------------------------------------------------------
echo "E. it only asks"
if [ -x "$HOOK" ] && bash -n "$HOOK" 2>"$TMP/err"; then ok "the script is executable and parses"; else bad "the script is executable and parses" "$(head -c 200 "$TMP/err")"; fi
CODE="$(grep -vE '^[[:space:]]*#' "$HOOK" 2>/dev/null)"
if printf '%s\n' "$CODE" | grep -qE 'kill -(9|KILL|TERM|HUP|INT|QUIT)|pkill|killall|"decision"|"continue"'; then
  bad "the script never ends or blocks anything (no TERM/KILL, no decision, no continue:false)" "$(printf '%s\n' "$CODE" | grep -nE 'kill -(9|KILL|TERM|HUP|INT|QUIT)|pkill|killall|"decision"|"continue"' | head -3)"
else
  ok "the script never ends or blocks anything (no TERM/KILL, no decision, no continue:false)"
fi
[ "$(printf '%s\n' "$CODE" | grep -cE 'kill -USR1')" = 1 ] && ok "exactly one statement signals: kill -USR1 to the launcher" || bad "exactly one statement signals: kill -USR1 to the launcher"
if ( . "$HOOK"; is_pid 2&& is_pid 12345 && is_pid 2147483647 && ! is_pid 1 && ! is_pid 0 && ! is_pid -5 && ! is_pid 007 && ! is_pid 12a && ! is_pid '' && ! is_pid 2147483648 && ! is_pid 4294967297 ); then
  ok "is_pid: 2..2147483647 only, no zero, no pid 1 (an orphaned claude's parent), no leading zero, no value a 32-bit pid_t would wrap onto 1"
else
  bad "is_pid accepts a value it must refuse, or refuses one it must accept"
fi

finish
