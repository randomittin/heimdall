#!/usr/bin/env bash
# test/supervise-restart.test.sh -- the supervised claude launcher library of the seamless restart
# (docs/superpowers/plans/2026-11-13-seamless-update-restart.md sections 2 and 5, Task W2-supervisor).
#
# bin/lib/hmd_supervise.sh gives bin/heimdall ONE function, hmd_supervised_claude, in place of the bare `claude ...` line: it runs claude as a background
# child, serves the restart request the Stop hook leaves (USR1 + req.json), asks the safe-point gate twice, ends the session with exactly ONE SIGTERM and
# re-execs the launcher with --resume <the session id in effect at TERM time>. Every refusal path leaves the session alone.
#
# This suite pins, against the oracle of W1 (test/fixtures/fake-claude: the fake claude, the expected traces and the mutant list, written from the plan
# alone, never from this library):
#   * golden: the restart-happy, restart-deferred and restart-loop-guard traces (START argv/resume/count, SIGNAL, EXIT, the ONE printed line, tty restore)
#   * term-ignored, user-exit (with a request pending), off, unsupervised, exit-status, the restart cap, inplace-rewrite, the resume-failure fallback
#   * term-slow (F8): a child that outlasts HMD_RESTART_TERM_WAIT_S after our TERM and then exits 143 is still resumed, once, on the same session id
#   * the printed line for each combination of halves, with and without parked agents; sourcing has no side effect
# The gate is the REAL gate, run from a temp copy with three constants lowered: G7's 60 s session age and 600 s spacing (the fake session is seconds old; the
# loop-guard trace asks for the spacing at 0 so ONLY the per-version cap can block a second restart) and G4's 10 s Stop-before-idle window, which the
# restart-deferred script's 10 s busy window sits exactly on (idle then begins 10.05 s after the Stop). ps / agents / pending / checkpoint are fakes, the
# Stop hook is a stand-in that writes req.json and sends USR1 as the plan says. Every scenario runs a launcher stand-in (set -euo pipefail, like
# bin/heimdall) under a real pty, because `stty -g` of that tty is what the library restores; all scenarios run in parallel, each in its own temp tree.
# bash 3.2 compatible. Nothing outside the temp tree is read or signalled: only the fake claude this suite's launchers started is ever signalled.
#
# budget: 80 -- ~60 s solo: the scenarios run in real time (the oracle's fake-claude scripts sleep; restart-deferred alone is ~50 s), all at once, each with its own
# fake claude and one gate run every 2 s; timings carry 2 s of margin, and a failure that only shows under machine load gets ONE solo re-run.
#
# Usage:  bash test/supervise-restart.test.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/hmd_supervise.sh"
FAKE="$REPO/test/fixtures/fake-claude/fake-claude.sh"
TRACES="$REPO/test/fixtures/fake-claude/expected"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# nothing the operator exports changes a case
unset HMD_AUTO_RESTART HMD_SUPERVISED HMD_RESTART_DIR HMD_LAUNCHER_PID HMD_RESTART_COUNT HMD_RESTARTED_FROM HMD_RESUME_SESSION_ID HMD_RESTART_FALLBACK \
      HMD_RESTART_GATE_CMD HMD_UPDATE_PENDING_CMD HMD_CHECKPOINT_CMD HMD_CLAUDE_BIN HMD_SUPERVISE_CLEANUP_FN HMD_RESTART_PARKED_CMD HMD_RESTART_POLL_S \
      HMD_RESTART_RECHECK_S HMD_RESTART_TERM_WAIT_S HMD_RESTART_REQ_TTL_S HMD_RESTART_MAX HMD_RESTART_RESUME_FAIL_S HMD_RESTART_SESSIONS_DIR HMD_RESTART_TTY \
      HMD_RESTART_AGENTS_CMD HMD_RESTART_PS_CMD HMD_RESTART_PENDING_CMD HMD_RESTART_QUIET_S HMD_RESTART_SETTLE_S HMD_RESTART_NOW HMD_UPDATE_PLUGIN_DIR \
      HMD_AGENT_TASKDIR HEIMDALL_HOME HEIMDALL_CC_VERSIONS HEIMDALL_SELF ORIG_ARGV HMD_FAKE_CLAUDE FAKE_CLAUDE_LOG FAKE_CLAUDE_SCRIPT FAKE_CLAUDE_TERM \
      FAKE_CLAUDE_FIFO FAKE_CLAUDE_TTY_FILE FAKE_CLAUDE_STOP_HOOK FAKE_CLAUDE_SESSIONS_DIR FAKE_CLAUDE_VERSION FAKE_CLAUDE_SESSION_ID FAKE_CLAUDE_SLOW_S

echo "supervise-restart"
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
command -v perl >/dev/null 2>&1 || { bad "0. perl is required"; exit 1; }
[ -f "$LIB" ] || { bad "0. bin/lib/hmd_supervise.sh must exist"; exit 1; }
for f in "$FAKE" "$TRACES/restart-happy.trace" "$TRACES/restart-deferred.trace" "$TRACES/restart-loop-guard.trace"; do
  [ -f "$f" ] || { bad "0. the oracle fixture $f must exist"; exit 1; }
done
if bash -n "$LIB" 2>/dev/null; then ok "0. bin/lib/hmd_supervise.sh parses"; else bad "0. bin/lib/hmd_supervise.sh does not parse"; fi
if grep -nE 'kill -(9|KILL)|kill -s (9|KILL)|pkill|killall' "$LIB" >/dev/null; then bad "0. the library must never SIGKILL, pkill or killall"; else ok "0. the library names no SIGKILL, pkill or killall"; fi
if grep -q 'hmd_supervised_claude()' "$LIB"; then ok "0. hmd_supervised_claude() is defined"; else bad "0. hmd_supervised_claude() is not defined"; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/supervise-restart.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
cleanup() {
  local f p
  for f in "$T"/*/claude.log; do
    [ -f "$f" ] || continue
    for p in $(sed -n 's/.*"event":"start","pid":\([0-9][0-9]*\).*/\1/p' "$f"); do
      case "$(ps -o command= -p "$p" 2>/dev/null)" in *fake-claude.sh*) kill -USR2 "$p" 2>/dev/null ;; esac
    done
  done
  rm -rf "$T"
}
trap cleanup EXIT

# ---- sourcing is free: functions only, no variable, no trap, no output
bash -c ':; compgen -v | sort' _ "$LIB" > "$T/vars.before" 2>/dev/null
bash -c ':; . "$1"; compgen -v | sort' _ "$LIB" > "$T/vars.after" 2>/dev/null
SRC_OUT="$(bash -c 'set -euo pipefail; . "$1"; trap -p' _ "$LIB" 2>&1)"
if cmp -s "$T/vars.before" "$T/vars.after" && [ -z "$SRC_OUT" ]; then ok "0. sourcing the library defines functions only (no variable, no trap, no output)"
else bad "0. sourcing the library has a side effect" "$SRC_OUT"; fi

# ---- the printed line: each combination of halves, parked agents, nothing that is not a version or a name
line_of() {   # line_of "<pending output>" ["<parked names>"]
  ( . "$LIB"; _hmd_sv_parse_pending "$1" || exit 1; _HMD_SV_PARKED="${2:-}"; _hmd_sv_line )
}
L="$(line_of "$(printf 'claude 2.1.322 2.1.323\nhmd 2.4.1 2.4.2')")"
[ "$L" = "[heimdall] updated claude 2.1.322->2.1.323, hmd 2.4.1->2.4.2 - resumed" ] && ok "line: both halves" || bad "line: both halves" "$L"
L="$(line_of "claude 2.1.322 2.1.323")"
[ "$L" = "[heimdall] updated claude 2.1.322->2.1.323 - resumed" ] && ok "line: claude only" || bad "line: claude only" "$L"
L="$(line_of "hmd 2.4.1 2.4.2")"
[ "$L" = "[heimdall] updated hmd 2.4.1->2.4.2 - resumed" ] && ok "line: hmd only" || bad "line: hmd only" "$L"
L="$(line_of "claude 2.1.322 2.1.323" "reviewer, seeker")"
[ "$L" = "[heimdall] updated claude 2.1.322->2.1.323 - resumed (parked agents ended: reviewer, seeker)" ] && ok "line: parked agents are listed" || bad "line: parked agents" "$L"
if line_of 'claude 2.1.322;rm 2.1.323' >/dev/null 2>&1; then bad "line: a version with shell markup must be refused"; else ok "line: markup in a version is refused, a pending text without a valid half names no restart"; fi

# ---- the stand-ins
mkdir -p "$T/bin" "$T/fakes" "$T/gate/bin/lib"
cat > "$T/bin/claude" <<'EOF'
#!/bin/sh
exec bash "$FAKE_CLAUDE_SH" "$@"
EOF
cat > "$T/fakes/pending.sh" <<'EOF'
#!/bin/sh
# heimdall-update-pending: `claude <running> <newest>` while the session file of --pid reports an older claude than NEWEST_CLAUDE, and `hmd <start> <installed>`
# while the launcher started on an hmd older than INSTALLED_HMD; exit 0 when a half is pending, 1 when none is, 2 when the session file cannot be read
start=""
pid=""
while [ $# -gt 0 ]; do
  case "$1" in --launcher-start-hmd) start="$2"; shift ;; --pid) pid="$2"; shift ;; esac
  shift
done
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p)" = "$1" ]; }
n=0
running=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$HMD_RESTART_SESSIONS_DIR/$pid.json" 2>/dev/null)
[ -n "$running" ] || exit 2
if older "$running" "$NEWEST_CLAUDE"; then echo "claude $running $NEWEST_CLAUDE"; n=1; fi
if [ -n "$start" ] && older "$start" "$INSTALLED_HMD"; then echo "hmd $start $INSTALLED_HMD"; n=1; fi
[ "$n" = 1 ]
EOF
cat > "$T/fakes/agents.sh" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$T/fakes/checkpoint.sh" <<'EOF'
#!/bin/sh
echo "$*" >> "$SC_DIR/checkpoint.log"
EOF
cat > "$T/fakes/stophook.sh" <<'EOF'
#!/bin/sh
# the Stop hook of the plan (bin/heimdall-restart-request, W2-hook): ask the launcher, atomically and quietly, and always exit 0
payload=$(cat)
[ -n "${HMD_LAUNCHER_PID:-}" ] && [ -n "${HMD_RESTART_DIR:-}" ] || exit 0
sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
p=$PPID
i=0
while [ $i -lt 5 ] && [ ! -f "$HMD_RESTART_SESSIONS_DIR/$p.json" ]; do
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [ -n "$p" ] || exit 0
  i=$((i + 1))
done
mkdir -p "$HMD_RESTART_DIR"
printf '{"session_id":"%s","claude_pid":%s,"stop_ts":%s,"pending":{}}\n' "$sid" "$p" "$(date +%s)" > "$HMD_RESTART_DIR/req.json.tmp.$$" \
  && mv -f "$HMD_RESTART_DIR/req.json.tmp.$$" "$HMD_RESTART_DIR/req.json"
kill -USR1 "$HMD_LAUNCHER_PID" 2>/dev/null
exit 0
EOF
cat > "$T/fakes/ps.sh" <<'EOF'
#!/bin/sh
# the process table of ONE scenario: the launcher's descendants only (nothing else on this machine can sway a verdict), without what the fake claude keeps
# around as housekeeping: its `sleep`s (idle loop, script steps) and its forked subshells (a row whose command line is its parent's own). The `sleep 3600`
# a `child on` step started is live work the status does not show, and stays: its pid is the last child event of the fake's log.
keep=$(grep '"event":"child"' "$FAKE_CLAUDE_LOG" 2>/dev/null | tail -n 1 | sed -n 's/.*"state":"on","cpid":\([0-9][0-9]*\).*/\1/p')
ps -axww -o pid=,ppid=,command= | awk -v root="${HMD_LAUNCHER_PID:-0}" -v keep="${keep:-0}" '
  { ppid[$1] = $2; row[$1] = $0; name = $3; sub(/.*\//, "", name); base[$1] = name; c = ""; for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i; cmd[$1] = c }
  END {
    mark[root] = 1
    do { grew = 0; for (p in ppid) if (!(p in mark) && (ppid[p] in mark)) { mark[p] = 1; grew = 1 } } while (grew)
    for (p in mark) {
      if (p == root || !(p in row)) continue
      if (base[p] == "sleep" && p != keep) continue
      if ((ppid[p] in cmd) && cmd[p] == cmd[ppid[p]]) continue
      print row[p]
    }
  }'
EOF
cat > "$T/gate.sh" <<'EOF'
#!/bin/sh
out=$("$SC_GATE" "$@")
rc=$?
printf '%s %s\n' "$(date +%s)" "$out" >> "$SC_DIR/gate.log"
printf '%s\n' "$out"
exit $rc
EOF
cat > "$T/fakes/parked.sh" <<'EOF'
#!/bin/sh
printf 'reviewer\nseeker one\n\n<script>alert(1)</script>\n'
EOF
chmod +x "$T/bin/claude" "$T/fakes/pending.sh" "$T/fakes/agents.sh" "$T/fakes/checkpoint.sh" "$T/fakes/stophook.sh" "$T/fakes/ps.sh" "$T/gate.sh" "$T/fakes/parked.sh"
P="$( . "$LIB"; HMD_RESTART_PARKED_CMD="$T/fakes/parked.sh"; _hmd_sv_parked )"
[ "$P" = "reviewer, seeker one" ] && ok "parked: the lister's names are joined, a line that is not a name is dropped" || bad "parked: names" "$P"

# the real gate, three constants lowered (see the header); the copy is checked, so a renamed constant cannot silently leave one unpatched
cp "$REPO/bin/heimdall-restart-gate" "$T/gate/bin/"
cp "$REPO"/bin/lib/*.py "$T/gate/bin/lib/"
sed -e 's/^SESSION_MIN_AGE_S = 60/SESSION_MIN_AGE_S = 0/' -e 's/^RESTART_GAP_S = 600/RESTART_GAP_S = 0/' -e 's/^STOP_BEFORE_IDLE_S = 10 /STOP_BEFORE_IDLE_S = 30 /' \
  "$REPO/bin/lib/hmd_restart_gate.py" > "$T/gate/bin/lib/hmd_restart_gate.py"
if [ "$(grep -c -e '^SESSION_MIN_AGE_S = 0' -e '^RESTART_GAP_S = 0' -e '^STOP_BEFORE_IDLE_S = 30' "$T/gate/bin/lib/hmd_restart_gate.py")" = 3 ]; then
  ok "0. the gate copy carries the three lowered constants"
else
  bad "0. the gate copy lost a constant to patch (SESSION_MIN_AGE_S, RESTART_GAP_S, STOP_BEFORE_IDLE_S): the oracle and the gate have moved"; exit 1
fi

# the pty runner: the launcher gets a real controlling tty (stdin, stdout, stderr), its output lands in a file
cat > "$T/pty-run.py" <<'EOF'
import fcntl
import os
import select
import struct
import subprocess
import sys
import termios
import time

timeout_s, out_path = float(sys.argv[1]), sys.argv[2]
argv = sys.argv[3:]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))


def own_tty():
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True, preexec_fn=own_tty)
os.close(slave)
deadline = time.time() + timeout_s
rc = None
with open(out_path, "wb") as out:
    while True:
        if time.time() > deadline:
            proc.kill()
            rc = 124
            break
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if chunk:
                out.write(chunk)
                out.flush()
                continue
        if proc.poll() is not None:
            break
    if rc is None:
        rc = proc.wait()
sys.exit(rc)
EOF

# the launcher stand-in: the call shape bin/heimdall (W3) gives the library, under the same flags; padded past a read buffer so an in-place rewrite matters
cat > "$T/launcher.v1.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ORIG_ARGV=("$@")
HEIMDALL_SELF="$SC_LAUNCHER"
. "$SC_LIB"
echo "v1 start count=${HMD_RESTART_COUNT:-0} resume=${HMD_RESUME_SESSION_ID:-none}" >> "$SC_DIR/launcher.log"
if [ "${HMD_RESTART_COUNT:-0}" -ge 1 ]; then ver="$SC_HMD_AFTER"; else ver="$SC_HMD_FIRST"; fi
printf '{"name":"heimdall","version":"%s"}\n' "$ver" > "$HMD_UPDATE_PLUGIN_DIR/.claude-plugin/plugin.json"
sc_cleanup() { echo "cleanup ran" >> "$SC_DIR/launcher.log"; exit 9; }
HMD_SUPERVISE_CLEANUP_FN=sc_cleanup
export HMD_SUPERVISED="${SC_SUPERVISED:-1}"
args=("$@")
if [ -n "${HMD_RESUME_SESSION_ID:-}" ]; then args=("${args[@]}" --resume "$HMD_RESUME_SESSION_ID"); fi
{
  rc=0
  hmd_supervised_claude "${args[@]}" || rc=$?
  trap -p USR1 > "$SC_DIR/usr1.trap"
  echo "launcher-exit rc=$rc t=$(date +%s)" >> "$SC_DIR/launcher.log"
  exit "$rc"
}
echo "v1 tail: never reached" >> "$SC_DIR/launcher.log"
EOF
awk 'BEGIN { for (i = 0; i < 600; i++) print "# padding line " i " ......................................................" }' >> "$T/launcher.v1.sh"
{
  sed -n 1p "$T/launcher.v1.sh"
  printf '# rewritten in place while the old launcher runs: %s\n' "$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "x" }')"
  sed -n '2,$p' "$T/launcher.v1.sh" | sed -e 's/v1 start/v2 start/' -e 's/v1 tail/v2 tail/' -e '/^# padding line [0-9]*[05] /d'
} > "$T/launcher.v2.sh"

prep() {
  local sd="$1"
  mkdir -p "$sd/cwd" "$sd/sessions" "$sd/versions" "$sd/tasks" "$sd/home" "$sd/plugin/.claude-plugin"
  : > "$sd/versions/2.1.323"
  touch -t 202001010000 "$sd/versions/2.1.323"
  : > "$sd/tty"
  touch -a -t 202001010000 "$sd/tty"
  mkfifo "$sd/fifo"
  cp "$T/launcher.v1.sh" "$sd/launcher.sh"
  cp "$T/gate.sh" "$sd/gate.sh"
  chmod +x "$sd/launcher.sh" "$sd/gate.sh"
}

scenario_env() {   # scenario_env SD: everything the launcher, the fake claude, the gate and the stand-ins read
  local sd="$1"
  export HMD_FAKE_CLAUDE=1 FAKE_CLAUDE_SH="$FAKE" FAKE_CLAUDE_TERM=graceful
  export FAKE_CLAUDE_LOG="$sd/claude.log" FAKE_CLAUDE_SCRIPT="$sd/script" FAKE_CLAUDE_FIFO="$sd/fifo" FAKE_CLAUDE_TTY_FILE="$sd/tty"
  export FAKE_CLAUDE_STOP_HOOK="sh $T/fakes/stophook.sh" FAKE_CLAUDE_SESSIONS_DIR="$sd/sessions" HMD_RESTART_SESSIONS_DIR="$sd/sessions"
  export HMD_CLAUDE_BIN="$T/bin/claude" HMD_RESTART_GATE_CMD="$sd/gate.sh" HMD_UPDATE_PENDING_CMD="$T/fakes/pending.sh" HMD_CHECKPOINT_CMD="$T/fakes/checkpoint.sh"
  export HMD_RESTART_AGENTS_CMD="$T/fakes/agents.sh" HMD_RESTART_PS_CMD="$T/fakes/ps.sh" HMD_RESTART_TTY="$sd/tty" HMD_AGENT_TASKDIR="$sd/tasks"
  export HEIMDALL_HOME="$sd/home" HEIMDALL_CC_VERSIONS="$sd/versions" HMD_UPDATE_PLUGIN_DIR="$sd/plugin" HMD_RESTART_DIR="$sd/rd"
  export HMD_RESTART_POLL_S=2 HMD_RESTART_RECHECK_S=1 HMD_RESTART_TERM_WAIT_S=10 HMD_RESTART_QUIET_S=3 HMD_RESTART_SETTLE_S=3
  export NEWEST_CLAUDE=2.1.323 INSTALLED_HMD=2.4.2 SC_DIR="$sd" SC_LIB="$LIB" SC_LAUNCHER="$sd/launcher.sh" SC_HMD_FIRST=2.4.1 SC_HMD_AFTER=2.4.2
  export SC_GATE="$T/gate/bin/heimdall-restart-gate"
}

# launch NAME SCRIPT [VAR=value ...]: one scenario in the background. SCRIPT is the file of fake-claude steps; the run leaves $T/NAME/{out,rc,claude.log,...}
launch() {
  local name="$1" script="$2" kv
  shift 2
  local sd="$T/$name"
  prep "$sd"
  cp "$script" "$sd/script"
  (
    scenario_env "$sd"
    for kv in "$@"; do export "$kv"; done
    cd "$sd/cwd" || exit 1
    rc=0
    python3 -I "$T/pty-run.py" 150 "$sd/out" bash "$sd/launcher.sh" --agent heimdall || rc=$?
    echo "$rc" > "$sd/rc"
  ) &
}

send_exit() {   # send_exit NAME SECONDS: the user types /exit SECONDS from now
  local fifo="$T/$1/fifo" after="$2"
  ( sleep "$after"; perl -e 'alarm 5; exec @ARGV' sh -c 'echo /exit > "$1"' sh "$fifo" ) &
}

probe() {   # probe NAME DELAY [term [keep]]: DELAY seconds from now (from the first TERM with `term`) note what is left on disk, then the user types /exit (not with `keep`: the child is ending on our TERM)
  local sd="$T/$1" delay="$2" mode="${3:-}" keep="${4:-}"
  (
    n=0
    if [ "$mode" = term ]; then
      while [ "$n" -lt 400 ] && ! grep -q '"signal":"TERM"' "$sd/claude.log" 2>/dev/null; do sleep 0.2; n=$((n + 1)); done
    fi
    sleep "$delay"
    fpid="$(sed -n 's/.*"event":"start","pid":\([0-9][0-9]*\).*/\1/p' "$sd/claude.log" | sed -n 1p)"
    {
      if kill -0 "$fpid" 2>/dev/null; then echo "alive=yes"; else echo "alive=no"; fi
      if [ -e "$sd/rd/restarting.json" ]; then echo "marker=left"; else echo "marker=gone"; fi
      if [ -e "$sd/rd/req.json" ]; then echo "req=left"; else echo "req=gone"; fi
    } > "$sd/mid"
    cp "$sd/rd/supervisor.log" "$sd/mid.log" 2>/dev/null
    if [ "$keep" != keep ]; then perl -e 'alarm 5; exec @ARGV' sh -c 'echo /exit > "$1"' sh "$sd/fifo"; fi
  ) &
}

term_ignored_ok() {   # the session was left alone: alive, no marker, no request, ONE start, ONE TERM and no KILL; the user's /exit ended the launcher with 0
  local d="$1"
  [ "$(tr '\n' ' ' < "$d/mid" 2>/dev/null)" = "alive=yes marker=gone req=gone " ] && grep -q 'term-ignored' "$d/mid.log" 2>/dev/null \
    && [ "$(cat "$d/rc" 2>/dev/null)" = 0 ] && [ "$(count_in '"event":"start"' "$d/claude.log")" = 1 ] \
    && [ "$(count_in '"signal":"TERM"' "$d/claude.log")" = 1 ] && [ "$(count_in '"signal":"KILL"' "$d/claude.log")" = 0 ]
}

term_slow_ok() {   # the TERM went out once and the child was slow to go: when the wait ran out it was alive and the marker and the request were gone; it then exited 143 and the session
                   # came back ONCE (TERM count 1, no KILL, two starts), the launcher's status being the last child's
  local d="$1"
  [ "$(tr '\n' ' ' < "$d/mid" 2>/dev/null)" = "alive=yes marker=gone req=gone " ] && grep -q 'term-ignored' "$d/mid.log" 2>/dev/null \
    && [ "$(cat "$d/rc" 2>/dev/null)" = 0 ] && [ "$(count_in '"event":"start"' "$d/claude.log")" = 2 ] \
    && [ "$(count_in '"signal":"TERM"' "$d/claude.log")" = 1 ] && [ "$(count_in '"signal":"KILL"' "$d/claude.log")" = 0 ]
}

trace_script() { HMD_FAKE_CLAUDE=1 bash "$FAKE" --extract script "$1" > "$2"; }
trace_diff() { HMD_FAKE_CLAUDE=1 bash "$FAKE" --trace-diff "$2" "$T/$1/claude.log" "$T/$1/out" > "$T/$1/diff" 2>&1; }
count_in() { local n; n="$(grep -c "$1" "$2" 2>/dev/null)" || true; echo "${n:-0}"; }

# the scripts: three from the oracle's traces, the rest written here
trace_script "$TRACES/restart-happy.trace" "$T/s.happy"
trace_script "$TRACES/restart-deferred.trace" "$T/s.deferred"
trace_script "$TRACES/restart-loop-guard.trace" "$T/s.loopguard"
grep '^@0 ' "$T/s.happy" > "$T/s.first"
cat > "$T/s.quit" <<'EOF'
@0 set status=idle sessionId=sid-1 version=2.1.322
EOF
cat > "$T/s.rc7" <<'EOF'
@0 set status=idle sessionId=sid-1 version=2.1.322
@0 sleep 1
@0 exit 7
EOF
{ cat "$T/s.first"; echo '@1 exit 1'; echo '@2 exit 1'; echo '@3 exit 0'; } > "$T/s.fallback"
{ cat "$T/s.first"; echo '@1 exit 0'; } > "$T/s.ti"
cat > "$T/fallback.trace" <<'EOF'
START argv=--agent heimdall resume=none count=0
STATUS idle
SESSION sid-1
VERSION 2.1.322
STATUS busy
STOP_HOOK
STATUS idle
SIGNAL TERM
EXIT rc=143
PRINT [heimdall] updated claude 2.1.322->2.1.323, hmd 2.4.1->2.4.2 - resumed
START argv=--agent heimdall --resume sid-1 resume=sid-1 count=1
EXIT rc=1
PRINT [heimdall] resume failed (exit 1); continuing the last conversation
START argv=--agent heimdall --continue resume=none count=1
EXIT rc=1
PRINT [heimdall] resume failed (exit 1); restarted from checkpoint
START argv=--agent heimdall resume=none count=1
EXIT rc=0
?tty TTY restored=yes
EOF

# ---- the library's own mutants, from the oracle's list (test/fixtures/fake-claude/mutants.list): a one-line sed of a temp copy each, run under the scenario that
# pins it; the other mutants of the list target the gate (M1-M3, M10) or bin/heimdall (M8), and M6 (SIGKILL) is held by the grep above and term-ignored
mkdir -p "$T/mut"
for m in M4 M5 M7 M9; do
  expr="$(awk -F'\t' -v n="$m-" 'index($3, n) == 1 && $1 == "bin/lib/hmd_supervise.sh" { print $2 }' "$REPO/test/fixtures/fake-claude/mutants.list")"
  sed -e "$expr" "$LIB" > "$T/mut/$m.sh"
  if [ -n "$expr" ] && ! cmp -s "$LIB" "$T/mut/$m.sh"; then ok "0. mutant $m changes the library"
  else bad "0. mutant $m matches nothing in the library: the oracle's list and the library have drifted"; fi
done

# ---- start every long scenario at once
launch happy "$T/s.happy" "$(HMD_FAKE_CLAUDE=1 bash "$FAKE" --extract env "$TRACES/restart-happy.trace" | sed -n 1p)"
launch deferred "$T/s.deferred" HMD_RESTART_QUIET_S=8 HMD_RESTART_SETTLE_S=2 SC_HMD_FIRST=2.4.2
launch loop-guard "$T/s.loopguard" SC_HMD_FIRST=2.4.2
launch term-ignored "$T/s.ti" FAKE_CLAUDE_TERM=ignore HMD_RESTART_TERM_WAIT_S=3
launch term-slow "$T/s.happy" FAKE_CLAUDE_TERM=slow FAKE_CLAUDE_SLOW_S=10 HMD_RESTART_TERM_WAIT_S=2
launch no-update "$T/s.first" NEWEST_CLAUDE=2.1.322 SC_HMD_FIRST=2.4.2
launch ttl "$T/s.first" HMD_RESTART_QUIET_S=1000000000 HMD_RESTART_SETTLE_S=1 HMD_RESTART_REQ_TTL_S=5
launch mut-M4 "$T/s.happy" SC_LIB="$T/mut/M4.sh"
launch mut-M5 "$T/s.deferred" SC_LIB="$T/mut/M5.sh" HMD_RESTART_QUIET_S=8 HMD_RESTART_SETTLE_S=2 SC_HMD_FIRST=2.4.2
launch mut-M7 "$T/s.ti" SC_LIB="$T/mut/M7.sh" FAKE_CLAUDE_TERM=ignore HMD_RESTART_TERM_WAIT_S=3
launch mut-M9 "$T/s.happy" SC_LIB="$T/mut/M9.sh"
launch user-exit "$T/s.first" HMD_RESTART_QUIET_S=1000000000
launch cap "$T/s.first" HMD_RESTART_COUNT=3
launch inplace "$T/s.happy"
launch fallback "$T/s.fallback"
launch exit-status "$T/s.rc7"
launch unsupervised "$T/s.rc7" SC_SUPERVISED=0
send_exit user-exit 8
send_exit cap 10
( sleep 1.5; cp "$T/launcher.v2.sh" "$T/inplace/launcher.sh" ) &
probe term-ignored 6 term
probe term-slow 5 term keep
probe no-update 6
probe ttl 11
probe mut-M7 6 term

(
  sd="$T/happy"
  sleep 1.5
  fpid="$(sed -n 's/.*"event":"start","pid":\([0-9][0-9]*\).*/\1/p' "$sd/claude.log" | sed -n 1p)"
  lpid="$(sed -n 's/.*"HMD_LAUNCHER_PID":"\([0-9][0-9]*\)".*/\1/p' "$sd/claude.log" | sed -n 1p)"
  if [ -n "$fpid" ] && [ -n "$lpid" ] && [ "$(ps -o ppid= -p "$fpid" 2>/dev/null | tr -d ' ')" = "$lpid" ]; then echo direct > "$sd/ppid"; else echo "not-direct fpid=$fpid lpid=$lpid" > "$sd/ppid"; fi
) &

# ---- off: byte-identical argv to a bare claude (quoting stress), no supervision at all
OFFD="$T/off"
prep "$OFFD"
cp "$T/s.quit" "$OFFD/script"
(
  scenario_env "$OFFD"
  export HMD_AUTO_RESTART=off
  cd "$OFFD/cwd" || exit 1
  rc=0
  bash "$OFFD/launcher.sh" -p 'hello world' "it's a \"test\"" '' 'x  y' --model sonnet > "$OFFD/out" 2>&1 || rc=$?
  echo "$rc" > "$OFFD/rc"
  FAKE_CLAUDE_LOG="$OFFD/bare.log" "$T/bin/claude" -p 'hello world' "it's a \"test\"" '' 'x  y' --model sonnet > /dev/null 2>&1
)
wait

argv_of() { sed -n 's/.*"event":"start".*"argv":\(\[[^]]*\]\).*/\1/p' "$1" | sed -n 1p; }

# ---- golden traces
for sc in happy deferred loop-guard; do
  if trace_diff "$sc" "$TRACES/restart-$sc.trace"; then ok "golden: restart-$sc trace matches"
  else bad "golden: restart-$sc trace differs" "$(sed -n '1,30p' "$T/$sc/diff")"; fi
done

# ---- happy, in detail
D="$T/happy"
[ "$(cat "$D/rc" 2>/dev/null)" = 0 ] && ok "happy: the launcher's status is the last child's (0)" || bad "happy: launcher status" "rc=$(cat "$D/rc" 2>/dev/null)"
[ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 1 ] && ok "happy: exactly ONE TERM" || bad "happy: the number of TERMs" "$(count_in '"signal":"TERM"' "$D/claude.log")"
if [ "$(tail -n 2 "$D/gate.log" | awk '$2 == "SAFE"' | wc -l | tr -d ' ')" = 2 ] \
   && tail -n 2 "$D/gate.log" | awk '{ t[NR] = $1 } END { exit !(t[2] - t[1] >= 1) }'; then
  ok "happy: the gate said SAFE twice, at least RECHECK seconds apart, right before the TERM"
else bad "happy: the last two gate evaluations" "$(tail -n 3 "$D/gate.log" 2>/dev/null | tr '\n' '|')"; fi
grep -q '^write' "$D/checkpoint.log" 2>/dev/null && ok "happy: heimdall-checkpoint write ran before the TERM" || bad "happy: no checkpoint write"
[ "$(count_in 'cleanup ran' "$D/launcher.log")" = 1 ] && ok "happy: the launch cleanup ran once and its exit did not end the launcher" || bad "happy: launch cleanup" "$(cat "$D/launcher.log" 2>/dev/null)"
if grep -q '"claude": "2.1.323"' "$D/home/restart/last.json" 2>/dev/null && grep -q '"hmd": "2.4.2"' "$D/home/restart/last.json" && grep -q '"ts": [0-9]' "$D/home/restart/last.json"; then
  ok "happy: last.json records ts and the versions restarted to"
else bad "happy: last.json" "$(cat "$D/home/restart/last.json" 2>/dev/null)"; fi
[ -e "$D/usr1.trap" ] && ! grep -q '_HMD_SV_POKED' "$D/usr1.trap" && [ ! -e "$D/rd" ] \
  && ok "happy: no live USR1 handler is left (a late Stop hook cannot end the launcher) and no request directory" || bad "happy: leftovers" "$(cat "$D/usr1.trap" 2>/dev/null) $(ls "$D/rd" 2>/dev/null)"
[ "$(count_in '"stty":"gfmt1' "$D/claude.log")" -ge 2 ] && ok "happy: the golden tty line was evaluated on a real pty" || bad "happy: no stty recorded, the tty line was never checked"
# the contract of the Stop hook (bin/heimdall-restart-request): claude is a DIRECT child of HMD_LAUNCHER_PID and sees HMD_LAUNCHER_PID, HMD_RESTART_DIR and
# HMD_LAUNCHER_START_HMD (the plugin.json version at launcher start: the first launcher saw 2.4.1, the relaunched one 2.4.2)
START1="$(grep '"event":"start"' "$D/claude.log" | sed -n 1p)"
START2="$(grep '"event":"start"' "$D/claude.log" | sed -n 2p)"
S1=no
S2=no
if echo "$START1" | grep -q '"HMD_LAUNCHER_PID":"[0-9][0-9]*"' && echo "$START1" | grep -q '"HMD_LAUNCHER_START_HMD":"2.4.1"'; then S1=ok; fi
if echo "$START2" | grep -q '"HMD_LAUNCHER_START_HMD":"2.4.2"'; then S2=ok; fi
if [ "$(cat "$D/ppid" 2>/dev/null)" = direct ] && [ "$S1" = ok ] && [ "$S2" = ok ] && echo "$START1" | grep -q '"HMD_RESTART_DIR":"[^"]*/rd"'; then
  ok "happy: claude is a direct child of HMD_LAUNCHER_PID and inherits HMD_LAUNCHER_PID, HMD_RESTART_DIR, HMD_LAUNCHER_START_HMD (2.4.1, then 2.4.2)"
else bad "happy: the hook contract" "ppid=$(cat "$D/ppid" 2>/dev/null) s1=$S1 s2=$S2 env=$(printf '%s' "$START1" | grep -o '"HMD_[A-Z_]*":"[^"]*"' | tr '\n' ' ')"; fi

# ---- deferred and loop-guard, in detail
D="$T/deferred"
if grep -q 'UNSAFE not-idle' "$D/gate.log" && grep -q 'UNSAFE task-live' "$D/gate.log" && grep -q 'UNSAFE user-active' "$D/gate.log" && [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 1 ]; then
  ok "deferred: the library waited out busy, live work and the keystroke window, then ended the session once"
else bad "deferred: verdicts seen" "$(awk '{ $1 = ""; print }' "$D/gate.log" | sort | uniq -c | tr '\n' '|')"; fi
D="$T/loop-guard"
if grep -q 'UNSAFE loop-guard' "$D/gate.log" && [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 1 ] && [ "$(cat "$D/rc")" = 0 ]; then
  ok "loop-guard: the gate's per-version cap held on the last.json the library wrote"
else bad "loop-guard: verdicts seen" "$(awk '{ $1 = ""; print }' "$D/gate.log" | sort | uniq -c | tr '\n' '|')"; fi

# ---- term-ignored
D="$T/term-ignored"
if term_ignored_ok "$D"; then ok "term-ignored: session kept, no relaunch"
else bad "term-ignored" "mid=[$(tr '\n' ' ' < "$D/mid" 2>/dev/null)] rc=$(cat "$D/rc" 2>/dev/null) starts=$(count_in '"event":"start"' "$D/claude.log") terms=$(count_in '"signal":"TERM"' "$D/claude.log")"; fi

# ---- term-slow (F8): the TERM is delivered, claude needs longer than HMD_RESTART_TERM_WAIT_S to shut down (a slow SessionEnd or MCP shutdown, a swapping machine) and then exits 143.
# The wait ran out by then (the probe saw it alive, the marker and the request gone), but the TERM was ours: the same session comes back once, exactly as in restart-happy
D="$T/term-slow"
if term_slow_ok "$D" && trace_diff term-slow "$TRACES/restart-happy.trace"; then ok "term-slow: a child that outlasts the wait and then exits 143 is resumed once on the same session id"
else bad "term-slow" "mid=[$(tr '\n' ' ' < "$D/mid" 2>/dev/null)] rc=$(cat "$D/rc" 2>/dev/null) starts=$(count_in '"event":"start"' "$D/claude.log") terms=$(count_in '"signal":"TERM"' "$D/claude.log") diff=[$(sed -n '1,12p' "$D/diff" 2>/dev/null | tr '\n' '|')]"; fi

# ---- a request nobody can satisfy is dropped: no update pending any more (the gate says no-update and the library stops looking), or past its lifetime
D="$T/no-update"
if [ "$(tr '\n' ' ' < "$D/mid" 2>/dev/null)" = "alive=yes marker=gone req=gone " ] && [ "$(wc -l < "$D/gate.log" | tr -d ' ')" = 1 ] && grep -q 'UNSAFE no-update' "$D/gate.log" \
   && [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 0 ] && [ "$(cat "$D/rc" 2>/dev/null)" = 0 ]; then
  ok "no-update: the request is dropped at the gate's no-update and never looked at again"
else bad "no-update" "mid=[$(tr '\n' ' ' < "$D/mid" 2>/dev/null)] gate=$(tr '\n' '|' < "$D/gate.log" 2>/dev/null) rc=$(cat "$D/rc" 2>/dev/null)"; fi
D="$T/ttl"
if [ "$(tr '\n' ' ' < "$D/mid" 2>/dev/null)" = "alive=yes marker=gone req=gone " ] && grep -q 'expired' "$D/mid.log" 2>/dev/null && grep -q 'UNSAFE user-active' "$D/gate.log" \
   && [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 0 ] && [ "$(cat "$D/rc" 2>/dev/null)" = 0 ]; then
  ok "ttl: a request that never found a safe moment expires, the session untouched"
else bad "ttl" "mid=[$(tr '\n' ' ' < "$D/mid" 2>/dev/null)] log=$(tr '\n' '|' < "$D/mid.log" 2>/dev/null) gate=$(awk '{ $1 = ""; print }' "$D/gate.log" 2>/dev/null | sort | uniq -c | tr '\n' '|') rc=$(cat "$D/rc" 2>/dev/null)"; fi

# ---- user-exit with a request pending
D="$T/user-exit"
exit_ms="$(sed -n 's/.*"ts":\([0-9]*\),"event":"exit".*/\1/p' "$D/claude.log" | sed -n 1p)"
back_s="$(sed -n 's/.*launcher-exit rc=0 t=\([0-9]*\).*/\1/p' "$D/launcher.log" | sed -n 1p)"
if [ "$(cat "$D/rc" 2>/dev/null)" = 0 ] && [ "$(count_in '"event":"start"' "$D/claude.log")" = 1 ] && [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 0 ] \
   && [ -n "$exit_ms" ] && [ -n "$back_s" ] && [ $((back_s - exit_ms / 1000)) -le 3 ]; then
  ok "user-exit: no relaunch"
else bad "user-exit" "rc=$(cat "$D/rc" 2>/dev/null) starts=$(count_in '"event":"start"' "$D/claude.log") terms=$(count_in '"signal":"TERM"' "$D/claude.log") exit_ms=$exit_ms back_s=$back_s"; fi

# ---- the cap, the status, the unsupervised paths
D="$T/cap"
if [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 0 ] && [ ! -s "$D/gate.log" ] && [ "$(cat "$D/rc")" = 0 ]; then ok "cap: HMD_RESTART_COUNT at the cap, the gate is never asked and the session is never ended"
else bad "cap" "terms=$(count_in '"signal":"TERM"' "$D/claude.log") gate=$(cat "$D/gate.log" 2>/dev/null | tr '\n' '|')"; fi
[ "$(cat "$T/exit-status/rc" 2>/dev/null)" = 7 ] && [ "$(count_in '"event":"start"' "$T/exit-status/claude.log")" = 1 ] && ok "exit-status: claude's rc preserved" || bad "exit-status" "rc=$(cat "$T/exit-status/rc" 2>/dev/null)"
D="$T/unsupervised"
if [ "$(cat "$D/rc" 2>/dev/null)" = 7 ]; then
  if [ ! -e "$D/rd" ] && [ ! -s "$D/usr1.trap" ]; then ok "unsupervised: HMD_SUPERVISED unset or not 1, bare claude: no request directory, no trap, status kept"; else bad "unsupervised: supervision state was created"; fi
else bad "unsupervised: status" "rc=$(cat "$D/rc" 2>/dev/null)"; fi
D="$T/off"
if [ -n "$(argv_of "$D/claude.log")" ] && [ "$(argv_of "$D/claude.log")" = "$(argv_of "$D/bare.log")" ] && [ "$(cat "$D/rc")" = 0 ] && [ ! -e "$D/rd" ] && [ ! -s "$D/usr1.trap" ]; then
  ok "off: byte-identical argv to bare claude"
else bad "off" "launcher argv=$(argv_of "$D/claude.log") bare argv=$(argv_of "$D/bare.log") rc=$(cat "$D/rc" 2>/dev/null)"; fi

# ---- inplace-rewrite: the launcher file is rewritten in place (same inode, other length) while the old launcher runs; the relaunch must run the new text cleanly
D="$T/inplace"
if trace_diff inplace "$TRACES/restart-happy.trace" && grep -q 'v1 start count=0' "$D/launcher.log" && grep -q 'v2 start count=1 resume=sid-1' "$D/launcher.log" \
   && ! grep -qiE 'command not found|syntax error|unexpected|unbound variable|No such file' "$D/out" && [ "$(cat "$D/rc")" = 0 ]; then
  ok "inplace-rewrite: relaunch clean"
else bad "inplace-rewrite" "$(sed -n '1,12p' "$D/diff") | log: $(tr '\n' '|' < "$D/launcher.log") | out: $(head -c 300 "$D/out")"; fi

# ---- resume-failure fallback: --resume fails fast, then --continue fails fast, then a fresh launch from the checkpoint
D="$T/fallback"
if trace_diff fallback "$T/fallback.trace" && grep -q '"HMD_RESTART_FALLBACK":"checkpoint"' "$D/claude.log" && [ "$(cat "$D/rc")" = 0 ]; then
  ok "fallback: --resume fails fast, --continue fails fast, a fresh launch follows"
else bad "fallback" "$(sed -n '1,30p' "$D/diff")"; fi

# ---- the mutants (see above) must each be caught, and for the reason they are meant to be caught
if ! trace_diff mut-M4 "$TRACES/restart-happy.trace" && grep -q '^+START argv=--agent heimdall resume=none count=1' "$T/mut-M4/diff"; then
  ok "mutant M4 (relaunch without --resume): the restart-happy trace goes RED"
else bad "mutant M4 survived or died of something else" "$(sed -n '1,12p' "$T/mut-M4/diff")"; fi
if ! trace_diff mut-M5 "$TRACES/restart-deferred.trace" && grep -q '^+START argv=--agent heimdall --resume sid-1 resume=sid-1 count=1' "$T/mut-M5/diff"; then
  ok "mutant M5 (the request's stale session id): the restart-deferred trace goes RED"
else bad "mutant M5 survived or died of something else" "$(sed -n '1,12p' "$T/mut-M5/diff")"; fi
if ! trace_diff mut-M9 "$TRACES/restart-happy.trace" && grep -q '^+TTY restored=no' "$T/mut-M9/diff"; then
  ok "mutant M9 (no terminal restore): the tty line goes RED"
else bad "mutant M9 survived or died of something else" "$(sed -n '1,12p' "$T/mut-M9/diff")"; fi
if ! term_ignored_ok "$T/mut-M7" && [ "$(count_in '"event":"start"' "$T/mut-M7/claude.log")" -ge 1 ]; then
  ok "mutant M7 (relaunch without the marker): term-ignored goes RED"
else bad "mutant M7 survived" "mid=[$(tr '\n' ' ' < "$T/mut-M7/mid" 2>/dev/null)] starts=$(count_in '"event":"start"' "$T/mut-M7/claude.log")"; fi

echo
echo "supervise-restart: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
