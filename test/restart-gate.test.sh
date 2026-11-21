#!/usr/bin/env bash
# test/restart-gate.test.sh -- the safe-point gate of the seamless restart (docs/superpowers/plans/2026-11-13-seamless-update-restart.md, Task W1-gate).
#
# bin/heimdall-restart-gate answers ONE question for the launcher that supervises claude: "is NOW a safe moment to end this session and relaunch it on the
# updated claude binary / hmd plugin?" It prints `SAFE` (exit 0) or `UNSAFE <reason-token>` (exit 1), evaluates G1-G8 in order, signals nothing and writes
# nothing. Failing to restart costs the old behaviour (a pin notice); restarting at the wrong moment costs the operator's run, so every signal it cannot
# read is UNSAFE (`signal-unreadable`), never SAFE.
#
# This suite pins:
#   * the SAFE fixture: every condition holds, including the processes a healthy idle claude always has (MCP servers, the statusline, caffeinate, ...)
#   * one UNSAFE case per reason token, each flipping exactly ONE input of the SAFE fixture, plus the boundaries of the clauses that carry a number
#   * the order: the FIRST failing condition names the verdict, and an unreadable signal never hides an earlier failing one
#   * fail closed: a missing sessions file, an unknown or absent status, a hung or crashing helper, garbage output, an unset or missing tty
#   * --now skips G6 only; --json; the default request path; a bad option is exit 2 and never a verdict
#   * the operator's switches in G6: a fresh $HEIMDALL_HOME/restart/now (`hmd restart now`) ends the wait for a typing user, a future defer-until (`hmd restart defer`) holds it
#   * the three numbers with a seam (STOP_BEFORE_IDLE_S 30, SESSION_MIN_AGE_S 60, RESTART_GAP_S 600): the default, the seam moving it, a typo being the default and never 0
#   * falsifiability: five one-line breaks of the gate (M1 skip G4, M2 skip G5, M3 ignore the keystroke window, M4 ignore a deferral, M5 ignore `now`) each flip a verdict pinned here
#   * the sessions-file canary: the schema check goes red on a record that lost a field; with HMD_RESTART_LIVE_CANARY=1 it also reads the LIVE files
# Every input is a seam under a temp dir (a fixed clock HMD_RESTART_NOW, a fake tty file, fake `ps` / agents / pending commands): no real session, tty
# or process is read or touched, and the gate is called directly, not through the bin/heimdall dispatcher. bash 3.2 compatible.
#
# Usage:  bash test/restart-gate.test.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO/bin/heimdall-restart-gate"
LIB="$REPO/bin/lib/hmd_restart_gate.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# nothing the operator exports changes a case
unset HMD_AUTO_RESTART HMD_SUPERVISED HMD_RESTART_DIR HMD_RESTART_SESSIONS_DIR HMD_RESTART_TTY HMD_RESTART_AGENTS_CMD HMD_RESTART_PENDING_CMD \
      HMD_RESTART_PS_CMD HMD_RESTART_QUIET_S HMD_RESTART_SETTLE_S HMD_RESTART_NOW HMD_RESTART_CMD_TIMEOUT_S HEIMDALL_CC_VERSIONS HMD_AGENT_TASKDIR \
      HMD_AGENT_CWD HEIMDALL_HOME HMD_RESTART_STOP_BEFORE_IDLE_S HMD_RESTART_SESSION_MIN_AGE_S HMD_RESTART_GAP_S

echo "restart-gate"
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
[ -f "$LIB" ] && [ -x "$GATE" ] || { bad "0. bin/heimdall-restart-gate (executable) and bin/lib/hmd_restart_gate.py must exist"; exit 1; }
if bash -n "$GATE" 2>/dev/null; then ok "0. bin/heimdall-restart-gate parses"; else bad "0. bin/heimdall-restart-gate does not parse"; fi
if python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$LIB" 2>/dev/null; then ok "0. bin/lib/hmd_restart_gate.py parses"; else bad "0. bin/lib/hmd_restart_gate.py does not parse"; fi
if grep -nE 'kill|SIGTERM' "$LIB" >/dev/null; then bad "0. the gate never touches a process: its source must not name a signal or kill"; else ok "0. the gate source names no signal and no kill"; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/restart-gate.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
FXD="$T/fx"       # the fixture, rebuilt from scratch before every case
NOW=1800000000    # the gate's clock (HMD_RESTART_NOW)
mkdir -p "$T/fakes"

# the three commands the gate runs, as fakes whose answers the fixture writes into $FXD
cat > "$T/fakes/pending.sh" <<EOF
#!/bin/sh
case "\$(cat "$FXD/pending.mode")" in
  ok) echo "claude 2.1.319 2.1.322"; echo "hmd 2.4.1 2.4.2" ;;
  claude) echo "claude 2.1.319 2.1.322" ;;
  hmd) echo "hmd 2.4.1 2.4.2" ;;
  none) exit 1 ;;
  crash) exit 3 ;;
esac
exit 0
EOF
cat > "$T/fakes/agents.sh" <<EOF
#!/bin/sh
echo "\${HMD_AGENT_CWD:-unset}" > "$FXD/agents.cwd"
n="\$(cat "$FXD/agents.count")"
[ "\$n" = hang ] && exec sleep 30
echo "\$n"
EOF
cat > "$T/fakes/ps.sh" <<EOF
#!/bin/sh
cat "$FXD/ps.table"
[ -f "$FXD/ps.self" ] && echo "\$PPID 424242 /bin/zsh -c source /h/.claude/shell-snapshots/snapshot-zsh-9.sh && eval 'ask-the-gate'"
exit "\$(cat "$FXD/ps.rc")"
EOF
chmod +x "$T/fakes/pending.sh" "$T/fakes/agents.sh" "$T/fakes/ps.sh"

# the SAFE fixture, and the one-input flips of it (FX_<KNOB>=value)
cat > "$T/fixture.py" <<'PY'
import json
import os
import shutil

E = os.environ
FX = E["FIXDIR"]
NOW = int(E["FIXNOW"])
LIVE = int(E["FIXLIVEPID"])
CPID = 424242


def knob(name, default):
    return E.get("FX_" + name, default)


shutil.rmtree(FX, ignore_errors=True)
os.makedirs(FX)


def put(rel, text="", mtime=None):
    path = os.path.join(FX, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


git = knob("GIT", "plain")
repo = os.path.join(FX, "repo")
cwd = os.path.join(repo, "sub", "dir") if git == "nested" else repo
os.makedirs(cwd)

# the session: idle for STATUS_AGE seconds, started STARTED_AGE seconds ago; the Stop hook ran STOP_GAP seconds before the idle began
status_at = NOW - int(knob("STATUS_AGE", "60"))
session = {"pid": int(knob("SESSION_PID", str(CPID))), "sessionId": "11111111-2222-3333-4444-555555555555", "cwd": cwd,
           "startedAt": (NOW - int(knob("STARTED_AGE", "3600"))) * 1000, "version": "2.1.319", "kind": "interactive",
           "status": knob("STATUS", "idle"), "updatedAt": status_at * 1000, "statusUpdatedAt": status_at * 1000}
if knob("DROP", ""):
    del session[knob("DROP", "")]
if knob("SESSION", "ok") != "missing":
    put("sessions/%d.json" % CPID, json.dumps(session))
if knob("REQ", "ok") != "missing":
    put("req.json", json.dumps({"session_id": session["sessionId"], "claude_pid": CPID, "stop_ts": status_at - float(knob("STOP_GAP", "1")),
                                "pending": {"claude": ["2.1.319", "2.1.322"], "hmd": ["2.4.1", "2.4.2"]}}))
if knob("TTY", "ok") != "missing":
    put("tty", mtime=NOW - int(knob("TTY_AGE", "600")))

# the hmd home: an opt-out file, the record of the last restart
os.makedirs(os.path.join(FX, "home", "restart"))
if knob("OPTOUT_FILE", "0") == "1":
    put("home/no-auto-restart")
if knob("DEFER", ""):  # the operator's `hmd restart defer`: seconds from NOW until the deferral ends (negative once it ended)
    put("home/restart/defer-until", "%d\n" % (NOW + int(knob("DEFER", ""))))
if knob("NOWREQ", ""):  # the operator's `hmd restart now`: how many seconds ago it was asked (negative: a time that has not come)
    put("home/restart/now", "%d\n" % (NOW - int(knob("NOWREQ", ""))))
if knob("MARKER_GARBAGE", ""):  # one of those two files, holding something that is not a number
    put("home/restart/" + knob("MARKER_GARBAGE", ""), "soon\n")
targets_now = {"claude": "2.1.322", "hmd": "2.4.2"}
targets_old = {"claude": "2.1.300", "hmd": "2.3.0"}
last = knob("LAST", "none")
if last == "recent":
    put("home/restart/last.json", json.dumps({"ts": NOW - 100, "targets": targets_old}))
elif last == "same":
    put("home/restart/last.json", json.dumps({"ts": NOW - 7200, "targets": targets_now}))
elif last == "partial":
    put("home/restart/last.json", json.dumps({"ts": NOW - 7200, "targets": {"claude": "2.1.322"}}))
elif last == "old":
    put("home/restart/last.json", json.dumps({"ts": NOW - 7200, "targets": targets_old}))
elif last == "garbage":
    put("home/restart/last.json", "{not json")

# the installed claude binaries, and the harness task files
if knob("VERSIONS", "ok") != "missing":
    put("versions/2.1.319", mtime=NOW - 86400)
    put("versions/2.1.322", mtime=NOW - int(knob("BINARY_AGE", "3600")))
put("tasks/b1.output", "x", mtime=NOW - int(knob("TASK_AGE", "3600")))

# a sweep lock: a live pid (the test shell), a dead one, in the repo or in the hmd home
sweep = knob("SWEEP", "none")
lock_dir = {"live": "repo/.heimdall/receipts", "dead": "repo/.heimdall/receipts", "home-live": "home/receipts"}.get(sweep)
if lock_dir:
    put(lock_dir + "/sweep.lock", "pid=%d\n" % (99999999 if sweep == "dead" else LIVE))

# git: a plain repository, one mid-operation, a linked worktree, a subdirectory of a repository, no repository at all
gitdir = os.path.join(repo, ".git")
if git in ("worktree", "worktree-clean"):
    gitdir = os.path.join(FX, "gitdirs", "wt")
    os.makedirs(gitdir)
    put("repo/.git", "gitdir: %s\n" % gitdir)
elif git != "none":
    os.makedirs(gitdir)
marker = {"rebase-merge": "rebase-merge", "rebase-apply": "rebase-apply", "nested": "rebase-merge", "worktree": "rebase-merge",
          "MERGE_HEAD": "MERGE_HEAD"}.get(git)
if marker == "MERGE_HEAD":
    with open(os.path.join(gitdir, "MERGE_HEAD"), "w") as f:
        f.write("0" * 40 + "\n")
elif marker:
    os.makedirs(os.path.join(gitdir, marker))

# the process table: what a healthy idle claude has (MCP servers, the statusline, a hook wrapper, caffeinate, a zombie), then the one process to flip
rows = ["1 0 /sbin/launchd",
        "100 1 bash /opt/heimdall/bin/heimdall",
        "424242 100 claude --agent heimdall --plugin-dir /opt/heimdall",
        "424500 100 sleep 999",
        "424300 424242 python3 ./bin/heimdall-ledger-mcp",
        "424301 424242 /usr/bin/python3 /opt/heimdall/bin/heimdall-inbox-wake watch --repo /r --pid 424242",
        "424302 424242 caffeinate -i -t 300",
        "424303 424242 bash /opt/heimdall/hooks/../bin/heimdall-statusline",
        "424304 424242 (bash)",
        "424305 424242 perl -e alarm 5; exec @ARGV bash /opt/heimdall/bin/heimdall-restart-request",
        "424306 424242 node /opt/x/node_modules/@modelcontextprotocol/server-foo/dist/index.js"]
ps = knob("PS", "base")
rows += {"installer": ["555 1 bash /var/tmp/heimdall-apply.AbC123/install.sh"],
         "unknown": ["424398 424242 sleep 999"],
         "job": ["424399 424242 /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'sleep 99' < /dev/null"],
         "bashjob": ["424397 424242 /bin/bash -c source /h/.claude/shell-snapshots/snapshot-bash-1.sh && eval 'bash bin/heimdall-foo'"]}.get(ps, [])
put("ps.table", "\n".join(rows) + "\n")
put("ps.rc", knob("PS_RC", "0"))
if ps == "self":
    put("ps.self")

put("agents.count", knob("AGENTS", "0") + "\n")
put("pending.mode", knob("PENDING", "ok") + "\n")
PY

BASE=(HMD_RESTART_NOW="$NOW" HMD_SUPERVISED=1 HEIMDALL_HOME="$FXD/home" HMD_RESTART_SESSIONS_DIR="$FXD/sessions" HMD_RESTART_TTY="$FXD/tty"
      HMD_RESTART_AGENTS_CMD="$T/fakes/agents.sh" HMD_RESTART_PENDING_CMD="$T/fakes/pending.sh" HMD_RESTART_PS_CMD="$T/fakes/ps.sh"
      HEIMDALL_CC_VERSIONS="$FXD/versions" HMD_AGENT_TASKDIR="$FXD/tasks" HMD_RESTART_CMD_TIMEOUT_S=3)

# verdict [FX_KNOB=value ...] [-- ENV=value ... [-- GATE-ARG ...]]: V = what the gate printed, RC = its exit status
verdict() {
  local knobs=() genv=() gargs=() reqarg=() part=0 a noreq=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then part=$((part + 1)); continue; fi
    case "$part" in
      0) knobs+=("$a") ;;
      1) genv+=("$a") ;;
      *) if [ "$a" = NOREQ ]; then noreq=1; else gargs+=("$a"); fi ;;
    esac
  done
  if ! env FIXDIR="$FXD" FIXNOW="$NOW" FIXLIVEPID="$$" ${knobs[@]+"${knobs[@]}"} python3 -I "$T/fixture.py"; then V="(fixture failed)"; RC=99; return; fi
  [ "$noreq" = 1 ] || reqarg=(--req "$FXD/req.json")
  V="$(env "${BASE[@]}" ${genv[@]+"${genv[@]}"} "${GUT:-$GATE}" ${reqarg[@]+"${reqarg[@]}"} ${gargs[@]+"${gargs[@]}"} 2>/dev/null)"
  RC=$?
}
# C <name> <expected output> [verdict args]: the output and the exit status (0 only for SAFE) must both match
C() {
  local name="$1" want="$2" wantrc=1
  shift 2
  verdict "$@"
  [ "$want" = SAFE ] && wantrc=0
  if [ "$V" = "$want" ] && [ "$RC" = "$wantrc" ]; then ok "$name"; else bad "$name" "want '$want' (exit $wantrc), got '$V' (exit $RC)"; fi
}

echo "-- the SAFE fixture"
C "SAFE: every condition holds (MCP servers, statusline, hook wrapper, caffeinate, zombie and a stale task file around)" SAFE
if [ "$(cat "$FXD/agents.cwd" 2>/dev/null)" = "$FXD/repo" ]; then ok "the agent count is asked about the SESSION's cwd (HMD_AGENT_CWD), not the launcher's"; else bad "HMD_AGENT_CWD is the session cwd" "got '$(cat "$FXD/agents.cwd" 2>/dev/null)'"; fi
C "SAFE: the default request file is \$HMD_RESTART_DIR/req.json" SAFE -- HMD_RESTART_DIR="$FXD" -- NOREQ

echo "-- G1 opt-out"
C "G1 opt-out: HMD_AUTO_RESTART=off (any case)" "UNSAFE opt-out" -- HMD_AUTO_RESTART=Off
C "G1 opt-out: the no-auto-restart file in the hmd home" "UNSAFE opt-out" FX_OPTOUT_FILE=1
C "G1 any other HMD_AUTO_RESTART value is not an opt-out" SAFE -- HMD_AUTO_RESTART=on

echo "-- G2 supervised launch"
C "G2 not-supervised: HMD_SUPERVISED is not 1" "UNSAFE not-supervised" -- HMD_SUPERVISED=0
C "G2 not-supervised: HMD_SUPERVISED unset" "UNSAFE not-supervised" -- HMD_SUPERVISED=

echo "-- G3 update pending and fully landed"
C "G3 no-update: the pending command exits 1" "UNSAFE no-update" FX_PENDING=none
C "G3 install-running: an installer process is alive" "UNSAFE install-running" FX_PS=installer
C "G3 binary-fresh: the newest claude binary was written 5 s ago" "UNSAFE binary-fresh" FX_BINARY_AGE=5
C "G3 binary-fresh boundary: written 30 s ago is landed" SAFE FX_BINARY_AGE=30
C "G3 an hmd-only update ignores the claude binary's age (nothing of claude is pending)" SAFE FX_PENDING=hmd FX_BINARY_AGE=5

echo "-- G4 turn ended"
C "G4 not-idle: status busy" "UNSAFE not-idle" FX_STATUS=busy
C "G4 not-idle: status waiting (a permission prompt)" "UNSAFE not-idle" FX_STATUS=waiting
C "G4 not-idle: status shell (a background Bash job)" "UNSAFE not-idle" FX_STATUS=shell
C "G4 settling: idle for 5 s, the default settle is 15 s" "UNSAFE settling" FX_STATUS_AGE=5
C "G4 settling boundary: idle for 15 s is settled" SAFE FX_STATUS_AGE=15 FX_TTY_AGE=600
C "G4 settling honours HMD_RESTART_SETTLE_S" "UNSAFE settling" FX_STATUS_AGE=20 -- HMD_RESTART_SETTLE_S=30
C "G4 not-idle: the idle began 100 s after the recorded Stop (a later turn the request does not know)" "UNSAFE not-idle" FX_STOP_GAP=100
C "G4 not-idle: the recorded Stop is 30 s newer than the idle (the request is ahead of the session)" "UNSAFE not-idle" FX_STOP_GAP=-30
C "G4 the idle may begin up to 30 s after the recorded Stop (25 s)" SAFE FX_STOP_GAP=25
C "G4 not-idle: 35 s after the recorded Stop is outside the default window" "UNSAFE not-idle" FX_STOP_GAP=35
C "G4 HMD_RESTART_STOP_BEFORE_IDLE_S narrows the window (25 s > 10 s)" "UNSAFE not-idle" FX_STOP_GAP=25 -- HMD_RESTART_STOP_BEFORE_IDLE_S=10
C "G4 HMD_RESTART_STOP_BEFORE_IDLE_S widens it (35 s <= 60 s)" SAFE FX_STOP_GAP=35 -- HMD_RESTART_STOP_BEFORE_IDLE_S=60
C "G4 a typo in HMD_RESTART_STOP_BEFORE_IDLE_S is the default, never 0" SAFE FX_STOP_GAP=25 -- HMD_RESTART_STOP_BEFORE_IDLE_S=abc

echo "-- G5 no live background work"
C "G5 agents-live: heimdall-agents count > 0" "UNSAFE agents-live" FX_AGENTS=2
C "G5 sweep-running: a live pid in <repo>/.heimdall/receipts/sweep.lock" "UNSAFE sweep-running" FX_SWEEP=live
C "G5 sweep-running: a live pid in \$HEIMDALL_HOME/receipts/sweep.lock" "UNSAFE sweep-running" FX_SWEEP=home-live
C "G5 a sweep lock of a dead pid is not a sweep" SAFE FX_SWEEP=dead
C "G5 task-live: a harness task .output written 10 s ago" "UNSAFE task-live" FX_TASK_AGE=10
C "G5 task boundary: a task .output written 60 s ago is finished" SAFE FX_TASK_AGE=60
C "G5 task-live: an unknown child of claude" "UNSAFE task-live" FX_PS=unknown
C "G5 task-live: a Bash-tool job (zsh -c source ...)" "UNSAFE task-live" FX_PS=job
C "G5 task-live: a Bash-tool job under bash whose command mentions bin/heimdall-" "UNSAFE task-live" FX_PS=bashjob
C "G5 the process that asks (the gate's own wrapper) is not a live task" SAFE FX_PS=self

echo "-- G6 user quiet"
C "G6 user-active: the tty was read 10 s ago" "UNSAFE user-active" FX_TTY_AGE=10
C "G6 user-active: 100 s is inside the default 300 s window" "UNSAFE user-active" FX_TTY_AGE=100
C "G6 HMD_RESTART_QUIET_S moves the window (100 s >= 60 s)" SAFE FX_TTY_AGE=100 -- HMD_RESTART_QUIET_S=60
C "G6 a typo in HMD_RESTART_QUIET_S is the default, never 0" "UNSAFE user-active" FX_TTY_AGE=100 -- HMD_RESTART_QUIET_S=abc
C "--now skips G6 only: a typing user does not stop it" SAFE FX_TTY_AGE=10 -- -- --now
C "--now skips G6 only: a busy session still does" "UNSAFE not-idle" FX_TTY_AGE=10 FX_STATUS=busy -- -- --now
C "G6 defer: the operator deferred for another 600 s (the tty alone would allow it)" "UNSAFE user-active" FX_DEFER=600
C "G6 defer: a deferral that ended 30 s ago no longer holds" SAFE FX_DEFER=-30
C "G6 now: 'hmd restart now' asked 20 s ago ends the wait for a typing user" SAFE FX_TTY_AGE=10 FX_NOWREQ=20
C "G6 now: ... and the wait for a deferral" SAFE FX_DEFER=600 FX_NOWREQ=20
C "G6 now: asked 200 s ago has lapsed (the typing user holds again)" "UNSAFE user-active" FX_TTY_AGE=10 FX_NOWREQ=200
C "G6 now: a time that has not come is not an ask (the typing user holds)" "UNSAFE user-active" FX_TTY_AGE=10 FX_NOWREQ=-60
C "G6 now skips G6 only: a busy session still holds" "UNSAFE not-idle" FX_STATUS=busy FX_NOWREQ=20

echo "-- G7 loop guards"
C "G7 loop-guard: the session is 30 s old" "UNSAFE loop-guard" FX_STARTED_AGE=30
C "G7 loop-guard: the previous restart was 100 s ago (a different target)" "UNSAFE loop-guard" FX_LAST=recent
C "G7 loop-guard: one restart per target version (2.1.322 and 2.4.2 were restarted to already)" "UNSAFE loop-guard" FX_LAST=same
C "G7 an old restart to other targets does not block" SAFE FX_LAST=old
C "G7 one new target (hmd 2.4.2) among old ones is enough to restart" SAFE FX_LAST=partial
C "G7 HMD_RESTART_SESSION_MIN_AGE_S lowers the session age (30 s >= 10 s)" SAFE FX_STARTED_AGE=30 -- HMD_RESTART_SESSION_MIN_AGE_S=10
C "G7 HMD_RESTART_SESSION_MIN_AGE_S raises it (an hour-old session is younger than 2 h)" "UNSAFE loop-guard" FX_STARTED_AGE=3600 -- HMD_RESTART_SESSION_MIN_AGE_S=7200
C "G7 HMD_RESTART_GAP_S lowers the spacing (the previous restart was 100 s ago, 50 s is enough)" SAFE FX_LAST=recent -- HMD_RESTART_GAP_S=50
C "G7 HMD_RESTART_GAP_S=0 allows a restart right after another one, for a new target" SAFE FX_LAST=recent -- HMD_RESTART_GAP_S=0
C "G7 a typo in HMD_RESTART_GAP_S is the default, never 0" "UNSAFE loop-guard" FX_LAST=recent -- HMD_RESTART_GAP_S=abc

echo "-- G8 git mid-operation"
C "G8 git-midop: .git/rebase-merge" "UNSAFE git-midop" FX_GIT=rebase-merge
C "G8 git-midop: .git/rebase-apply" "UNSAFE git-midop" FX_GIT=rebase-apply
C "G8 git-midop: .git/MERGE_HEAD" "UNSAFE git-midop" FX_GIT=MERGE_HEAD
C "G8 git-midop: the gitdir of a linked worktree (.git is a file)" "UNSAFE git-midop" FX_GIT=worktree
C "G8 git-midop: the session cwd is a subdirectory of the repository" "UNSAFE git-midop" FX_GIT=nested
C "G8 a clean linked worktree is SAFE" SAFE FX_GIT=worktree-clean
C "G8 no repository at all: nothing git can see" SAFE FX_GIT=none

echo "-- signal-unreadable: fail closed"
C "unreadable: no sessions file for the claude pid" "UNSAFE signal-unreadable" FX_SESSION=missing
C "unreadable: a status value the gate does not know" "UNSAFE signal-unreadable" FX_STATUS=frobnicating
C "unreadable: the record has no status (claude's first write has none)" "UNSAFE signal-unreadable" FX_DROP=status
C "unreadable: the record has no statusUpdatedAt" "UNSAFE signal-unreadable" FX_DROP=statusUpdatedAt
C "unreadable: the sessions file names another pid" "UNSAFE signal-unreadable" FX_SESSION_PID=7
C "unreadable: no request file" "UNSAFE signal-unreadable" FX_REQ=missing
C "unreadable: HMD_RESTART_TTY unset" "UNSAFE signal-unreadable" -- HMD_RESTART_TTY=
C "unreadable: the tty cannot be stat'ed (the keystroke time is unknown on this platform)" "UNSAFE signal-unreadable" FX_TTY=missing
C "unreadable: the agent count is not a number" "UNSAFE signal-unreadable" FX_AGENTS=garbage
C "unreadable: the agent count hangs (the helper is cut off after HMD_RESTART_CMD_TIMEOUT_S)" "UNSAFE signal-unreadable" FX_AGENTS=hang -- HMD_RESTART_CMD_TIMEOUT_S=1
C "unreadable: the pending command crashes" "UNSAFE signal-unreadable" FX_PENDING=crash
C "unreadable: the pending command exits 0 and names no target" "UNSAFE signal-unreadable" FX_PENDING=empty
C "unreadable: the pending command is not configured" "UNSAFE signal-unreadable" -- HMD_RESTART_PENDING_CMD=
C "unreadable: the process table cannot be read" "UNSAFE signal-unreadable" FX_PS_RC=1
C "unreadable: the record of the last restart is garbage" "UNSAFE signal-unreadable" FX_LAST=garbage
C "unreadable: claude is pending but the versions directory is missing" "UNSAFE signal-unreadable" FX_VERSIONS=missing
C "unreadable: the deferral file holds no number" "UNSAFE signal-unreadable" FX_MARKER_GARBAGE=defer-until
C "unreadable: the now file holds no number" "UNSAFE signal-unreadable" FX_MARKER_GARBAGE=now

echo "-- order: the first failing condition names the verdict"
C "order: opt-out beats a busy session" "UNSAFE opt-out" FX_STATUS=busy -- HMD_AUTO_RESTART=off
C "order: a busy session beats an unset tty (an unreadable signal never hides an earlier failure)" "UNSAFE not-idle" FX_STATUS=busy -- HMD_RESTART_TTY=
C "order: an unreadable sessions file beats a live agent that is checked later" "UNSAFE signal-unreadable" FX_SESSION=missing FX_AGENTS=2

echo "-- the command line"
verdict FX_STATUS=busy -- -- --json
if printf '%s' "$V" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if (d["verdict"], d["reason"], d["detail"]) == ("UNSAFE", "not-idle", None) else 1)'; then ok "--json: UNSAFE carries the reason token"; else bad "--json: UNSAFE carries the reason token" "got '$V'"; fi
verdict -- -- --json
if printf '%s' "$V" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if (d["verdict"], d["reason"]) == ("SAFE", None) and d["detail"] is None else 1)' && [ "$RC" = 0 ]; then ok "--json: SAFE"; else bad "--json: SAFE" "got '$V' (exit $RC)"; fi
verdict FX_SESSION=missing -- -- --json
if printf '%s' "$V" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if d["reason"] == "signal-unreadable" and isinstance(d["detail"], str) and d["detail"] else 1)'; then ok "--json: signal-unreadable says what could not be read"; else bad "--json: signal-unreadable says what could not be read" "got '$V'"; fi
verdict -- -- --bogus
if [ -z "$V" ] && [ "$RC" = 2 ]; then ok "a bad option is exit 2 with no verdict on stdout"; else bad "a bad option is exit 2 with no verdict on stdout" "got '$V' (exit $RC)"; fi

echo "-- falsifiability: one-line breaks of the gate must flip a pinned verdict"
MUT="$T/mut"
mkdir -p "$MUT/bin/lib"
cp "$GATE" "$MUT/bin/heimdall-restart-gate"
for f in hmd_sweep_guard.py hmd_kill_guard.py; do cp "$REPO/bin/lib/$f" "$MUT/bin/lib/$f"; done
mutant() {  # mutant <name> <sed expression> <expected output of the intact gate> [verdict args]
  local name="$1" expr="$2" want="$3"
  shift 3
  sed "$expr" "$LIB" > "$MUT/bin/lib/hmd_restart_gate.py"
  if cmp -s "$LIB" "$MUT/bin/lib/hmd_restart_gate.py"; then bad "$name: the one-line break did not apply to the gate"; return; fi
  GUT="$MUT/bin/heimdall-restart-gate"
  verdict "$@"
  GUT=""
  if [ "$V" != "$want" ]; then ok "$name: the broken gate answers '$V', not '$want'"; else bad "$name: the broken gate still answers '$want'"; fi
}
mutant "M1 skip G4 (end a busy session)" 's/if session\["status"\] != "idle":/if False:/' "UNSAFE not-idle" FX_STATUS=busy
mutant "M2 skip G5 (end a session with a live agent)" 's/if int(count) > 0:/if False:/' "UNSAFE agents-live" FX_AGENTS=2
mutant "M3 ignore the keystroke window" 's/if ctx.now - atime < ctx.quiet:/if False:/' "UNSAFE user-active" FX_TTY_AGE=10
mutant "M4 ignore a deferral" 's/if until is not None and ctx.now < until:/if False:/' "UNSAFE user-active" FX_DEFER=600
mutant "M5 ignore \`hmd restart now\`" 's/if asked is not None and 0 <= ctx.now - asked <= NOW_VALID_S:/if False:/' SAFE FX_TTY_AGE=10 FX_NOWREQ=20

echo "-- the sessions-file canary (schema drift of ~/.claude/sessions/<pid>.json)"
canary() {  # canary <file>: exit 0 when the record carries everything the gate reads
  python3 -I -S -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import hmd_restart_gate as g
data = json.load(open(sys.argv[2]))
g.parse_session(data, data.get("pid"))
' "$REPO/bin/lib" "$1" 2>/dev/null
}
verdict
if canary "$FXD/sessions/424242.json"; then ok "canary: a complete record passes"; else bad "canary: a complete record passes"; fi
for field in pid sessionId cwd startedAt status statusUpdatedAt; do
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); del d[sys.argv[2]]; json.dump(d, open(sys.argv[3], "w"))' "$FXD/sessions/424242.json" "$field" "$T/drift.json"
  if canary "$T/drift.json"; then bad "canary: a record that lost '$field' must fail"; else ok "canary: a record that lost '$field' fails"; fi
done
if [ "${HMD_RESTART_LIVE_CANARY:-}" = 1 ]; then
  live="$(python3 -I -S -c '
import glob, json, os, sys
sys.path.insert(0, sys.argv[1])
import hmd_restart_gate as g
checked = drift = 0
for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        data = json.load(open(path))
        os.kill(data["pid"], 0)
    except (OSError, ValueError, KeyError, TypeError):
        continue
    if data.get("kind") != "interactive":
        continue
    checked += 1
    try:
        g.parse_session(data, data["pid"])
    except g.Unreadable as exc:
        drift += 1
        print("drift in %s: %s" % (os.path.basename(path), exc))
print("checked=%d drift=%d" % (checked, drift))
' "$REPO/bin/lib")"
  case "$live" in
    *"checked=0 "*) ok "live canary: no interactive session file to read on this machine" ;;
    *"drift=0") ok "live canary: every live interactive session file has what the gate reads ($live)" ;;
    *) bad "live canary: the sessions file schema drifted" "$live" ;;
  esac
else
  ok "live canary: skipped (set HMD_RESTART_LIVE_CANARY=1 to read the live ~/.claude/sessions)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
