#!/usr/bin/env bash
# test/launcher-supervised.test.sh -- the launcher half of the seamless restart (docs/superpowers/plans/2026-11-13-seamless-update-restart.md, Task W3-launcher).
#
# bin/heimdall hands BOTH of its interactive claude launches (the default one and --resume) to bin/lib/hmd_supervise.sh, which runs claude as a child of the launcher
# and, after an update, can end it at a safe moment and re-exec the launcher. This suite pins what the LAUNCHER owes that library, running a COPY of the real
# bin/heimdall in a sandbox plugin dir (the harness of heimdall-unknown-command.test.sh) with a stub claude that records its argv and what the supervisor gave it:
#   * interactive: supervised, resume: supervised   a real tty on stdin and stdout: HMD_SUPERVISED=1, claude a DIRECT child of the launcher (HMD_LAUNCHER_PID is its
#     parent: the Stop hook checks that), a 0700 HMD_RESTART_DIR, HMD_LAUNCHER_START_HMD = the version in plugin.json, HMD_RESTART_TTY a tty path
#   * print-mode: unsupervised, non-tty: unsupervised, opt-out   -p, a pipe (even with HMD_SUPERVISED=1 inherited from an outer session) and HMD_AUTO_RESTART=off: plain
#     claude, no supervisor in its environment, no restart directory
#   * team-pane-noop, non-claude-noop   --team panes still TYPE a bare `claude ...` line; nothing but bin/heimdall (and the library) knows the supervisor
#   * lib-missing: bare claude   a tree without bin/lib/hmd_supervise.sh (a partial install, a sandbox copy of bin/heimdall alone) falls open on both launches: claude runs
#     bare with the argv the library's own plain path gives it, and its status is the launcher's, instead of "command not found"
#   * exit-status: claude's rc preserved   the launcher exits with claude's status on every path
#   * no code after supervised call   the call ends in `exit` inside the same compound command: a launcher rewritten IN PLACE while it runs never reads the new text
#   * a restart's re-entry   HMD_LAUNCHER_PID == the launcher's own pid (an exec keeps the pid) and HMD_RESUME_SESSION_ID set: `--resume <sid>`; the same variables
#     inherited by an hmd run INSIDE the session (another pid), or an id that is not a plain token, do nothing; `hmd --resume` swaps its `--continue` for it
#   * the exec gap: a USR1 that arrives before the supervisor's own trap is survived
#   * `hmd restart` (bin/heimdall-restart): on, off, defer, now, status; it writes only its own files and signals nothing
#   * a restart's relaunch is quiet: the supervisor's exec carries HMD_RELAUNCHED=1, which the re-entered launcher believes only beside its own pid in HMD_LAUNCHER_PID, a plain
#     session id and a count of 1 or more, reads once and removes (claude never sees it). It then prints nothing of its own (the banner, the loaded-state and model lines, the
#     nudge: the supervisor's one `updated` line is the whole notice) while every functional step runs; a normal launch, a stray marker and the bare-hmd wrap hop keep today's output
# Falsifiability: every case was seen RED against the launcher before the change (the supervised ones for lack of a supervisor, the gap and the in-place ones for lack of
# a trap and of an `exit`, the lib-missing ones for lack of the launcher's fallback); the unsupervised cases are the controls that must hold before AND after. Nothing
# outside the temp tree is read, written or signalled.
#
# budget: 60 -- ~35 s solo: about thirty launcher runs, most of them under a real pty (python3 pty), each a few hundred ms of launcher setup before the stub claude
# Usage:  bash test/launcher-supervised.test.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/test/lib/net-default-guard.sh"
HEIMDALL="$REPO/bin/heimdall"
RESTART="$REPO/bin/heimdall-restart"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# nothing the operator exports changes a case
unset HMD_RELAUNCHED HMD_AUTO_RESTART HMD_SUPERVISED HMD_LAUNCHER_PID HMD_RESTART_DIR HMD_RESTART_COUNT HMD_RESTARTED_FROM HMD_RESUME_SESSION_ID HMD_RESTART_FALLBACK \
      HMD_RESTART_TTY HMD_LAUNCHER_START_HMD HMD_SUPERVISE_CLEANUP_FN HMD_CLAUDE_BIN HEIMDALL_SELF ORIG_ARGV HEIMDALL_HOME

echo "launcher-supervised"
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
command -v perl >/dev/null 2>&1 || { bad "0. perl is required"; exit 1; }
[ -x "$HEIMDALL" ] || { bad "0. bin/heimdall must exist and be executable"; exit 1; }
if bash -n "$HEIMDALL" 2>/dev/null; then ok "0. bin/heimdall parses"; else bad "0. bin/heimdall does not parse"; fi
if [ -f "$RESTART" ] && bash -n "$RESTART" 2>/dev/null; then ok "0. bin/heimdall-restart parses"; else bad "0. bin/heimdall-restart is missing or does not parse"; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/launcher-supervised.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
FAKE="$T/plugin"      # the sandbox plugin dir: PLUGIN_DIR of the launcher copy resolves here
STUBS="$T/stubs"
HOME_DIR="$T/home"
WORK="$T/work"
LOG="$T/claude.log"
OUT="$T/out"
mkdir -p "$FAKE/bin/lib" "$FAKE/.claude-plugin" "$STUBS" "$HOME_DIR/.heimdall" "$WORK"
cp "$HEIMDALL" "$FAKE/bin/heimdall"
cp "$HEIMDALL" "$FAKE/bin/heimdall-rw"      # the copy a stub rewrites in place
for f in hmd_supervise.sh hmd_restart_gate.py hmd_update_pending.py hmd_sweep_guard.py hmd_kill_guard.py; do cp "$REPO/bin/lib/$f" "$FAKE/bin/lib/" 2>/dev/null; done
for f in heimdall-restart-gate heimdall-update-pending; do cp "$REPO/bin/$f" "$FAKE/bin/" 2>/dev/null; done
chmod +x "$FAKE/bin/"* 2>/dev/null
printf '{"name": "heimdall", "version": "2.4.2"}\n' > "$FAKE/.claude-plugin/plugin.json"
touch "$HOME_DIR/.heimdall/setup-done"      # first_run_setup is a no-op: no installs, no network

# the stub claude: ONE `ARGV: [a] [b]` line per call; the launcher's own launch (the call carrying --agent heimdall) adds a LAUNCH line with what the supervisor gave it
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
log="${CLAUDE_LOG:-/dev/null}"
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$log"
case " $* " in *" --agent heimdall "*) ;; *) exit 0 ;; esac
d=""
if [ -d "${HMD_RESTART_DIR:-/nonexistent}" ]; then d=$(ls -ld "$HMD_RESTART_DIR" | cut -c1-10); fi
pf=""; prev=""
for a in "$@"; do if [ "$prev" = "--append-system-prompt-file" ]; then pf="$a"; fi; prev="$a"; done
ckpt=no
if [ -n "$pf" ] && grep -q 'LAST CHECKPOINT' "$pf" 2>/dev/null; then ckpt=yes; fi
printf 'LAUNCH: ppid=%s supervised=%s launcher=%s dir=%s start_hmd=%s tty=%s marker=%s ckpt=%s\n' "$PPID" "${HMD_SUPERVISED:-}" "${HMD_LAUNCHER_PID:-}" "$d" "${HMD_LAUNCHER_START_HMD:-}" "${HMD_RESTART_TTY:-}" "${HMD_RELAUNCHED:-}" "$ckpt" >> "$log"
if [ -n "${STUB_APPEND_TO:-}" ]; then printf 'echo AFTER-CALL-RAN\n' >> "$STUB_APPEND_TO"; fi
if [ -n "${STUB_SIGNAL_PARENT:-}" ]; then sleep 0.2; kill -USR1 "$PPID"; fi
if [ -n "${STUB_REQUEST_RESTART:-}" ]; then
  case " $* " in
    *" --resume "*) ;;
    *)
      # the Stop hook's request (req.json, then USR1 to the launcher), then wait for the supervisor's TERM and go the way claude does: exit 143
      printf '{"session_id": "%s"}\n' "$STUB_REQUEST_RESTART" > "$HMD_RESTART_DIR/req.json"
      sleep 20 &
      trap 'kill $! 2>/dev/null; exit 143' TERM
      kill -USR1 "$PPID"
      wait $!
      exit 0
      ;;
  esac
fi
sleep "${STUB_SLEEP:-0}"
exit "${STUB_RC:-0}"
EOF
# the stub tmux of the --team case: every call logged
cat > "$STUBS/tmux" <<'EOF'
#!/bin/sh
printf 'tmux:' >> "${CLAUDE_LOG:-/dev/null}"
for a in "$@"; do printf ' [%s]' "$a" >> "${CLAUDE_LOG:-/dev/null}"; done
printf '\n' >> "${CLAUDE_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$STUBS/claude" "$STUBS/tmux"
# the restart cases: a PLANNED project (a checkpoint and a settings file, what a real session has and the launcher says it loaded; a goal and a state file for the --resume path),
# the stand-ins the supervisor asks (a gate that says SAFE, an update that is pending, a checkpoint writer) and a second plugin dir with a stand-in of bin/heimdall-wrap for the
# bare-hmd hop. launch() runs in $LAUNCH_DIR when that is set, else in $WORK.
WORK_PLANNED="$T/work-planned"
mkdir -p "$WORK_PLANNED/.planning"
printf '# checkpoint\nresume from the last session\n' > "$WORK_PLANNED/.planning/CHECKPOINT.md"
printf '{"parallelism": 4}\n' > "$WORK_PLANNED/.planning/settings.json"
printf 'current_phase: 2\n' > "$WORK_PLANNED/.planning/STATE.md"
printf '{"goal": {"condition": "the tests pass"}}\n' > "$WORK_PLANNED/heimdall-state.json"
git -C "$WORK_PLANNED" init -q 2>/dev/null
printf '#!/bin/sh\necho SAFE\n' > "$STUBS/gate"
printf '#!/bin/sh\necho "hmd 2.4.2 2.4.3"\n' > "$STUBS/pending"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/ckpt"
chmod +x "$STUBS/gate" "$STUBS/pending" "$STUBS/ckpt"
FAKEW="$T/plugin-wrap"
cp -R "$FAKE" "$FAKEW"
cat > "$FAKEW/bin/heimdall-wrap" <<'EOF'
#!/bin/sh
# the stand-in of bin/heimdall-wrap for the bare-hmd hop: records its argv, says one line unless --quiet, and ends as the real one does, back in the launcher with HEIMDALL_WRAP_LAUNCHED=1
{ printf 'wrap:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "${CLAUDE_LOG:-/dev/null}"
quiet=0
for a in "$@"; do if [ "$a" = "--quiet" ]; then quiet=1; fi; done
if [ "$quiet" = 0 ]; then printf '  WRAP-SAYS-WRAPPED\n'; fi
HEIMDALL_WRAP_LAUNCHED=1 exec "$(dirname "$0")/heimdall"
EOF
chmod +x "$FAKEW/bin/heimdall-wrap"

# the pty runner: the launcher gets a real tty on stdin, stdout and stderr; its output lands in a file; the exit status is the launcher's (128+N for a signal)
cat > "$T/pty-run.py" <<'EOF'
import os
import pty
import select
import signal
import subprocess
import sys
import time

timeout_s, out_path = float(sys.argv[1]), sys.argv[2]
master, slave = pty.openpty()
proc = subprocess.Popen(sys.argv[3:], stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
os.close(slave)
chunks, deadline, rc = [], time.time() + timeout_s, None
while True:
    if rc is None:
        rc = proc.poll()
    if select.select([master], [], [], 0.05)[0]:
        try:
            data = os.read(master, 65536)
        except OSError:
            data = b""
        if data:
            chunks.append(data)
        elif rc is not None:
            break
        else:
            time.sleep(0.05)
    elif rc is not None:
        break
    if time.time() > deadline:
        os.killpg(proc.pid, signal.SIGKILL)
        rc = proc.wait()
        chunks.append(b"\n[pty-run: timed out]\n")
        break
with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
sys.exit(128 - rc if rc < 0 else rc)
EOF

BASEENV=(PATH="$STUBS:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HOME_DIR/.heimdall" TERM=dumb ANTHROPIC_API_KEY=sk-ant-launcher-supervised-probe
         HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_REUSE_METRIC=1 HEIMDALL_DEFAULT_CP_URL="${HEIMDALL_DEFAULT_CP_URL:-}" CLAUDE_LOG="$LOG")

# launch tty|plain [VAR=value ...] -- command [args ...]: RC is the exit status, $OUT the output, $LOG what the stubs recorded. A hung launcher is cut off after 60 s.
launch() {
  local mode="$1" extra=()
  shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  shift
  : > "$LOG"
  : > "$OUT"
  rm -rf "$HOME_DIR/.heimdall/restart"
  if [ "$mode" = tty ]; then
    ( cd "${LAUNCH_DIR:-$WORK}" && env -i "${BASEENV[@]}" ${extra[@]+"${extra[@]}"} python3 -I "$T/pty-run.py" 60 "$OUT" "$@" )
  else
    ( cd "${LAUNCH_DIR:-$WORK}" && env -i "${BASEENV[@]}" ${extra[@]+"${extra[@]}"} perl -e 'alarm shift; exec @ARGV' 60 "$@" </dev/null >"$OUT" 2>&1 )
  fi
  RC=$?
}
# the launcher re-entered the way the supervisor's exec does it: the SAME pid, with HMD_LAUNCHER_PID naming it
REENTER='export HMD_LAUNCHER_PID=$$; exec "$0" "$@"'

launch_line() { grep -F 'LAUNCH:' "$LOG" | head -n 1; }
field() { launch_line | tr ' ' '\n' | sed -n "s/^$1=//p"; }
launch_argv() { grep -F '[--agent] [heimdall]' "$LOG" | head -n 1; }
snip() { head -c 300 "$1" 2>/dev/null | LC_ALL=C tr '\n' ' '; }
tail_snip() { tail -c 300 "$1" 2>/dev/null | LC_ALL=C tr '\n' ' '; }      # where a launcher that died ("command not found") says so: after its banner
restart_dir_exists() { [ -e "$HOME_DIR/.heimdall/restart" ]; }
plain_out() { perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$OUT"; }      # what the last run printed, without escape sequences and the pty's carriage returns
banners() { plain_out | grep -c 'autonomous orchestration' || true; }      # how many times the banner's box was printed
silent_out() { [ -z "$(plain_out | tr -d '[:space:]')" ]; }
nth_launch() { grep -F 'LAUNCH:' "$LOG" | sed -n "${1}p"; }
nth_field() { nth_launch "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# banner_ok LABEL [FRAGMENT ...]: the last run printed the whole banner, once, and every FRAGMENT (the sandbox has no heimdall-face, so the wordmark is the plain-text one)
banner_ok() {
  local label="$1" why="" frag txt
  shift
  txt="$(plain_out)"
  for frag in 'H E I M D A L L' 'Nothing ships unproven.' 'v2.4.2' 'autonomous orchestration' 'wave-based parallel execution' 'smart skill management' 'terser output' 'cwd:' "$@"; do
    printf '%s' "$txt" | grep -qF -- "$frag" || why="$why '$frag' is missing;"
  done
  [ "$(banners)" = 1 ] || why="$why the banner was printed $(banners) times;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why" "out=[$(snip "$OUT")]"; fi
}
# quiet_ok LABEL: the last run printed nothing at all, and claude never saw HMD_RELAUNCHED
quiet_ok() {
  local label="$1" why=""
  silent_out || why="$why the launcher printed [$(plain_out | tr '\n' ' ' | head -c 200)];"
  [ -z "$(field marker)" ] || why="$why claude saw HMD_RELAUNCHED=$(field marker);"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why"; fi
}

# supervised_ok LABEL: the last run launched claude as a DIRECT child of a supervising launcher, with what the Stop hook and the gate read
supervised_ok() {
  local label="$1" why="" lp pp
  lp="$(field launcher)"
  pp="$(field ppid)"
  [ -n "$(launch_line)" ] || why="$why claude never launched;"
  [ "$(field supervised)" = 1 ] || why="$why HMD_SUPERVISED is '$(field supervised)';"
  { [ -n "$lp" ] && [ "$lp" = "$pp" ]; } || why="$why claude (ppid '$pp') is not a direct child of HMD_LAUNCHER_PID '$lp';"
  [ "$(field dir)" = "drwx------" ] || why="$why HMD_RESTART_DIR is '$(field dir)', not a 0700 directory;"
  [ "$(field start_hmd)" = "2.4.2" ] || why="$why HMD_LAUNCHER_START_HMD is '$(field start_hmd)', not the plugin.json version;"
  case "$(field tty)" in /dev/*) ;; *) why="$why HMD_RESTART_TTY is '$(field tty)';" ;; esac
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why" "log=[$(snip "$LOG")] out=[$(snip "$OUT")]"; fi
}
# unsupervised_ok LABEL: claude was launched with nothing of the supervisor in its environment and no restart directory was made
unsupervised_ok() {
  local label="$1" why=""
  [ -n "$(launch_line)" ] || why="$why claude never launched;"
  [ -z "$(field launcher)" ] || why="$why HMD_LAUNCHER_PID reached claude;"
  [ -z "$(field dir)" ] || why="$why a restart directory exists;"
  ! restart_dir_exists || why="$why \$HEIMDALL_HOME/restart was created;"
  if [ -z "$why" ]; then ok "$label"; else bad "$label --$why" "log=[$(snip "$LOG")] out=[$(snip "$OUT")]"; fi
}

echo "-- structure"
# a CALL is a line that starts with the function's name: the one-line fail-open definition (it starts with `declare`) names it too and is not a call site
n="$(grep -cE '^[[:space:]]*hmd_supervised_claude([[:space:]]|$)' "$HEIMDALL")"
if [ "$n" = 2 ]; then ok "structure: bin/heimdall calls the supervised function exactly twice (the two call sites; its fail-open definition is not a call)"; else bad "structure: the supervised function is called $n times in bin/heimdall, want 2"; fi
if sed -n '/^# --team N/,/^# --help/p' "$HEIMDALL" | grep -q 'hmd_supervised_claude\|HMD_SUPERVISED'; then bad "structure: the --team path must not touch the supervisor"; else ok "structure: the --team path is untouched"; fi
if head -n 40 "$HEIMDALL" | grep -qF 'trap : USR1'; then ok "structure: trap : USR1 is among the first statements of bin/heimdall"; else bad "structure: no trap : USR1 near the top of bin/heimdall"; fi
if grep -q '_heimdall_launch_cleanup' "$HEIMDALL"; then ok "structure: the cleanup trap body is kept"; else bad "structure: _heimdall_launch_cleanup is gone"; fi

echo "-- the supervised launches"
launch tty -- "$FAKE/bin/heimdall"
supervised_ok "interactive: supervised (claude is a direct child of the launcher, 0700 restart dir, version and tty exported)"
banner_ok "interactive: a normal launch prints the whole banner, once (unchanged)"
case "$(launch_argv)" in *"[--resume]"*|*"[--continue]"*) bad "interactive: a plain launch must not resume anything" "$(launch_argv)" ;; *) ok "interactive: the argv is the launcher's own, no --resume and no --continue" ;; esac
launch tty -- "$FAKE/bin/heimdall" --resume
supervised_ok "resume: supervised (hmd --resume goes through the same call)"
case "$(launch_argv)" in *"[--continue]"*) ok "resume: a plain hmd --resume still continues the last conversation" ;; *) bad "resume: a plain hmd --resume must pass --continue" "$(launch_argv)" ;; esac

echo "-- the unsupervised launches"
launch tty -- "$FAKE/bin/heimdall" fix the login bug
unsupervised_ok "print-mode: unsupervised (a task is -p, even with a tty)"
case "$(launch_argv)" in *"[-p]"*) ;; *) bad "print-mode: the task launch is no longer -p" "$(launch_argv)" ;; esac
launch plain -- "$FAKE/bin/heimdall"
unsupervised_ok "non-tty: unsupervised (a pipe on stdin and stdout)"
launch plain HMD_SUPERVISED=1 -- "$FAKE/bin/heimdall"
unsupervised_ok "non-tty: unsupervised even when HMD_SUPERVISED=1 is inherited from an outer session"
launch tty HMD_AUTO_RESTART=OFF -- "$FAKE/bin/heimdall"
unsupervised_ok "opt-out: HMD_AUTO_RESTART=off (any case) launches claude plainly"

echo "-- the supervisor library missing"
# A tree without bin/lib/hmd_supervise.sh (a partial install, a sandbox copy of bin/heimdall alone) leaves the supervised function undefined, and both launches used to die
# with "command not found" before claude started. The launcher falls open to the bare `claude ...` it ran before the supervisor existed. The control is the library's own
# plain path (HMD_AUTO_RESTART=off is exactly `claude "$@"`): the same launch, so the same argv once what the two sandboxes do not share (their plugin dir, the preamble
# file's random name) is taken out.
NOLIB="$T/plugin-nolib"
mkdir -p "$NOLIB/bin" "$NOLIB/.claude-plugin"
cp "$HEIMDALL" "$NOLIB/bin/heimdall"
cp "$FAKE/.claude-plugin/plugin.json" "$NOLIB/.claude-plugin/plugin.json"
chmod +x "$NOLIB/bin/heimdall"
norm_argv() { launch_argv | sed -E -e "s|$1|<plugin>|g" -e 's/(\[--append-system-prompt-file\] )\[[^]]*\]/\1[<file>]/'; }
for site in interactive resume; do
  site_args=()
  if [ "$site" = resume ]; then site_args=(--resume); fi
  launch tty HMD_AUTO_RESTART=off -- "$FAKE/bin/heimdall" ${site_args[@]+"${site_args[@]}"}
  want="$(norm_argv "$FAKE")"
  launch tty STUB_RC=3 -- "$NOLIB/bin/heimdall" ${site_args[@]+"${site_args[@]}"}
  got="$(norm_argv "$NOLIB")"
  unsupervised_ok "lib missing, $site: claude launches bare (nothing of the supervisor in its environment, no restart directory)"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then ok "lib missing, $site: the argv is identical to the library's own plain launch"; else bad "lib missing, $site: the argv differs from the library's plain launch" "got [$got] want [$want] end-of-output=[$(tail_snip "$OUT")]"; fi
  if [ "$RC" = 3 ]; then ok "lib missing, $site: claude's status (3) is the launcher's"; else bad "lib missing, $site: claude's status was not preserved" "rc=$RC end-of-output=[$(tail_snip "$OUT")]"; fi
done

echo "-- panes and other tools"
launch plain -- "$FAKE/bin/heimdall" --team 2 do the thing
typed="$(grep -F 'tmux: [send-keys]' "$LOG" | grep -F 'claude --agent heimdall' | head -n 1)"
if [ -n "$typed" ] && [ -z "$(launch_line)" ] && ! restart_dir_exists && ! printf '%s' "$typed" | grep -q 'HMD_\|hmd_supervise'; then
  ok "team-pane-noop: the panes are typed a bare 'claude --agent heimdall ...' line, no supervisor, no launcher above them"
else
  bad "team-pane-noop: the team path changed" "typed=[$typed] launch=[$(launch_line)] out=[$(snip "$OUT")]"
fi
users="$(cd "$REPO" && grep -rlE 'hmd_supervised_claude|hmd_supervise\.sh' bin hooks 2>/dev/null | sort | tr '\n' ' ')"
if [ "$users" = "bin/heimdall bin/lib/hmd_supervise.sh " ] && grep -q 'exec "\$real"' "$REPO/bin/heimdall-wrap"; then
  ok "non-claude-noop: only bin/heimdall and the library know the supervisor; heimdall-wrap execs the other tools directly"
else
  bad "non-claude-noop: something else names the supervisor, or heimdall-wrap no longer execs other tools directly" "users=[$users]"
fi

echo "-- exit status"
launch tty STUB_RC=3 -- "$FAKE/bin/heimdall"; r1=$RC
launch plain STUB_RC=3 -- "$FAKE/bin/heimdall"; r2=$RC
launch tty STUB_RC=3 -- "$FAKE/bin/heimdall" --resume; r3=$RC
launch tty STUB_RC=3 HMD_AUTO_RESTART=off -- "$FAKE/bin/heimdall"; r4=$RC
launch tty STUB_RC=0 -- "$FAKE/bin/heimdall"; r5=$RC
if [ "$r1 $r2 $r3 $r4 $r5" = "3 3 3 3 0" ]; then ok "exit-status: claude's rc preserved (3 supervised, 3 plain, 3 resumed, 3 opted out, 0)"; else bad "exit-status: claude's rc not preserved" "got '$r1 $r2 $r3 $r4 $r5', want '3 3 3 3 0'"; fi

echo "-- no code after the supervised call"
launch tty STUB_APPEND_TO="$FAKE/bin/heimdall-rw" -- "$FAKE/bin/heimdall-rw"
if [ "$RC" = 0 ] && ! grep -q 'AFTER-CALL-RAN' "$OUT" && grep -q 'AFTER-CALL-RAN' "$FAKE/bin/heimdall-rw"; then
  ok "no code after supervised call: the launcher rewritten in place while claude ran never read the new text"
else
  bad "no code after supervised call: the launcher went on reading its own file" "rc=$RC out=[$(snip "$OUT")]"
fi

echo "-- a restart's re-entry"
launch tty HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
supervised_ok "re-entry: the launcher is supervised again (same pid, claude its direct child)"
case "$(launch_argv)" in *"[--resume] [sess-42]"*) ok "re-entry: the interactive launch resumes the session the restart left (--resume sess-42)" ;; *) bad "re-entry: no --resume sess-42" "$(launch_argv)" ;; esac
launch tty HMD_LAUNCHER_PID=424242 HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- "$FAKE/bin/heimdall"
case "$(launch_argv)" in *"[--resume]"*) bad "re-entry: an hmd run inside the session (another pid) must not resume its outer session" "$(launch_argv)" ;; *) ok "re-entry: the variables inherited by an hmd run inside the session (another pid) are ignored" ;; esac
for badid in 'sess;touch-x' '-rf' 'a b' ''; do
  launch tty HMD_RESUME_SESSION_ID="$badid" HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
  case "$(launch_argv)" in *"[--resume]"*) bad "re-entry: the id '$badid' is not a plain token and must not reach claude" "$(launch_argv)" ;; *) ok "re-entry: the id '$badid' is refused" ;; esac
done
launch tty HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall" --resume
case "$(launch_argv)" in
  *"[--resume] [sess-42]"*"[--agent]"*) if printf '%s' "$(launch_argv)" | grep -qF '[--continue]'; then bad "re-entry: hmd --resume keeps --continue beside --resume" "$(launch_argv)"; else ok "re-entry: hmd --resume swaps --continue for --resume sess-42"; fi ;;
  *) bad "re-entry: hmd --resume does not pass --resume sess-42" "$(launch_argv)" ;;
esac

echo "-- a restart's relaunch is quiet"
# The supervisor's exec carries HMD_RELAUNCHED=1. The re-entered launcher reads it ONCE (claude never sees it) and believes it only beside what the supervisor sets with it: its own
# pid in HMD_LAUNCHER_PID, a plain session id, a restart count of 1 or more. A relaunch replaces a running session, so the line the supervisor printed is the whole notice.
LAUNCH_DIR="$WORK_PLANNED"
launch tty STUB_REQUEST_RESTART=sess-restart-1 HMD_RESTART_GATE_CMD="$STUBS/gate" HMD_UPDATE_PENDING_CMD="$STUBS/pending" HMD_CHECKPOINT_CMD="$STUBS/ckpt" HMD_RESTART_RECHECK_S=0 -- "$FAKE/bin/heimdall"
nl="$(grep -c 'LAUNCH:' "$LOG")"
n_upd="$(plain_out | grep -c '^\[heimdall\] updated hmd 2.4.2->2.4.3 - resumed$' || true)"
after="$(plain_out | sed '1,/^\[heimdall\] updated /d' | tr -d '[:space:]')"
if [ "$RC" = 0 ] && [ "$nl" = 2 ] && [ "$n_upd" = 1 ] && [ "$(banners)" = 1 ] && [ -z "$after" ]; then
  ok "relaunch: a real restart through the supervisor's own exec prints its one 'updated' line and nothing else (one banner in the whole run, nothing after the line)"
else
  bad "relaunch: a real restart printed more than its one line" "rc=$RC launches=$nl updated-lines=$n_upd banners=$(banners) after=[$(printf '%s' "$after" | head -c 200)]"
fi
argv2="$(grep -F '[--agent] [heimdall]' "$LOG" | sed -n 2p)"
if [ "$(nth_field 1 ckpt)" = yes ] && [ "$(nth_field 2 ckpt)" = yes ] && [ "$(nth_field 2 supervised)" = 1 ] && [ -n "$(nth_field 1 launcher)" ] \
   && [ "$(nth_field 1 launcher)" = "$(nth_field 2 launcher)" ] && [ -z "$(nth_field 2 marker)" ] && printf '%s' "$argv2" | grep -qF '[--resume] [sess-restart-1]'; then
  ok "relaunch: every functional step survives it (the same launcher pid, supervised again, --resume <the session id>, the checkpoint still in the preamble, no marker in claude's environment)"
else
  bad "relaunch: a functional step was lost" "launch1=[$(nth_launch 1)] launch2=[$(nth_launch 2)] argv2=[$argv2]"
fi
launch tty HMD_RELAUNCHED=1 HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
supervised_ok "relaunch (default launch): still supervised, claude a direct child of the same pid"
case "$(launch_argv)" in *"[--resume] [sess-42]"*) ok "relaunch (default launch): --resume sess-42 is still passed" ;; *) bad "relaunch (default launch): --resume sess-42 is gone" "$(launch_argv)" ;; esac
quiet_ok "relaunch (default launch): the launcher prints nothing at all (no banner, no loaded-state or model line) and claude never sees the marker"
if [ "$(field ckpt)" = yes ]; then ok "relaunch (default launch): the checkpoint context is still loaded into the preamble"; else bad "relaunch (default launch): the checkpoint context was lost" "$(launch_line)"; fi
launch tty HMD_RELAUNCHED=1 HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall" --resume --foreground
supervised_ok "relaunch (--resume): still supervised"
case "$(launch_argv)" in *"[--resume] [sess-42]"*) ok "relaunch (--resume): --resume sess-42 is still passed" ;; *) bad "relaunch (--resume): --resume sess-42 is gone" "$(launch_argv)" ;; esac
quiet_ok "relaunch (--resume): nothing printed (no banner, no 'Resuming from', no 'state loaded', no 'Goal restored') and no marker in claude's environment"
launch tty -- "$FAKE/bin/heimdall"
banner_ok "control (default launch): the same project prints the banner, the loaded-state lines and the model line" 'Project settings loaded' 'Checkpoint loaded' 'Model: inherit'
launch tty -- "$FAKE/bin/heimdall" --resume --foreground
banner_ok "control (--resume): the same project prints the banner, the resume lines and the goal" 'Resuming from .planning/STATE.md' 'heimdall state loaded' 'Goal restored'
LAUNCH_DIR=""
launch tty HMD_RELAUNCHED=1 -- "$FAKE/bin/heimdall"
banner_ok "stray marker: HMD_RELAUNCHED=1 alone in a normal launch silences nothing"
if [ -z "$(field marker)" ]; then ok "stray marker: it is removed from the environment before claude starts"; else bad "stray marker: claude saw HMD_RELAUNCHED=$(field marker)"; fi
launch tty HMD_RELAUNCHED=1 HMD_LAUNCHER_PID=424242 HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- "$FAKE/bin/heimdall"
banner_ok "stray marker: beside another launcher's pid (an hmd run inside a session) silences nothing"
launch tty HMD_RELAUNCHED=yes HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
banner_ok "stray marker: a value other than 1 silences nothing"
launch tty HMD_RELAUNCHED=1 HMD_RESUME_SESSION_ID=sess-42 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
banner_ok "stray marker: without a restart count silences nothing"
launch tty HMD_RELAUNCHED=1 'HMD_RESUME_SESSION_ID=sess;touch-x' HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
banner_ok "stray marker: beside an id that is not a plain token silences nothing"
# the bare-hmd hop: a bare `hmd` is wrapped first (bin/heimdall-wrap prints its own lines, then re-enters the launcher), so the relaunch runs the wrap again: quietly, with the marker riding its exec
launch tty HMD_RELAUNCHED=1 HMD_RESUME_SESSION_ID=sess-42 HMD_RESTART_COUNT=1 -- bash -c "$REENTER" "$FAKEW/bin/heimdall"
if grep -qF 'wrap: [launch] [--quiet]' "$LOG" && silent_out && [ -z "$(field marker)" ] && launch_argv | grep -qF '[--resume] [sess-42]'; then
  ok "relaunch (bare hmd): the wrap hop runs with --quiet, the marker rides its exec and is gone before claude, nothing is printed, the session is resumed"
else
  bad "relaunch (bare hmd): the wrap hop or what follows it is not quiet" "log=[$(snip "$LOG")] out=[$(snip "$OUT")]"
fi
launch tty -- "$FAKEW/bin/heimdall"
if grep -qF 'wrap: [launch]' "$LOG" && ! grep -qF -- '--quiet' "$LOG" && plain_out | grep -qF 'WRAP-SAYS-WRAPPED' && [ "$(banners)" = 1 ]; then
  ok "control (bare hmd): a normal launch runs the wrap without --quiet, and the wrap says its line"
else
  bad "control (bare hmd): a normal launch changed" "log=[$(snip "$LOG")] out=[$(snip "$OUT")]"
fi
launch tty HMD_RELAUNCHED=1 -- "$FAKEW/bin/heimdall"
if ! grep -qF -- '--quiet' "$LOG" && plain_out | grep -qF 'WRAP-SAYS-WRAPPED' && [ "$(banners)" = 1 ]; then
  ok "stray marker (bare hmd): the wrap is not told to be quiet"
else
  bad "stray marker (bare hmd): a stray marker silenced the wrap hop" "log=[$(snip "$LOG")] out=[$(snip "$OUT")]"
fi
# the nudge ("N recommended skills not installed"): the launcher's own function, cut out of bin/heimdall, over stand-ins of its two python helpers; a relaunch shows nothing and writes no stamp
NUD="$T/nudge"
mkdir -p "$NUD/plugin/bin/lib" "$NUD/home"
printf 'print("ask")\n' > "$NUD/plugin/bin/lib/skills_config.py"
printf 'print("2 skill(s) suggested for this project (this command installs nothing):")\n' > "$NUD/plugin/bin/lib/skills_cli_install.py"
cat > "$NUD/harness.sh" <<'EOF'
set -euo pipefail
PLUGIN_DIR="$NUD_PLUGIN"; HEIMDALL_HOME_DIR="$NUD_HOME"
_heimdall_home_ensure() { mkdir -p "$HEIMDALL_HOME_DIR"; }
_hmd_sc_interactive() { return 0; }
eval "$NUD_FN"
hmd_skills_nudge
EOF
nudge_src="$(sed -n '/^hmd_skills_nudge() {/,/^}/p' "$HEIMDALL")"
run_nudge() { rm -f "$NUD/home/skills-nudge-stamp"; env -i PATH="$PATH" HOME="$NUD/home" NUD_PLUGIN="$NUD/plugin" NUD_HOME="$NUD/home" NUD_FN="$nudge_src" "$@" bash "$NUD/harness.sh" 2>&1; }
nudge_normal="$(run_nudge)"
stamp_normal=no; if [ -e "$NUD/home/skills-nudge-stamp" ]; then stamp_normal=yes; fi
nudge_quiet="$(run_nudge HMD_RELAUNCH_QUIET=1)"
stamp_quiet=no; if [ -e "$NUD/home/skills-nudge-stamp" ]; then stamp_quiet=yes; fi
if printf '%s' "$nudge_normal" | grep -q '2 recommended skills not installed' && [ "$stamp_normal" = yes ] && [ -z "$nudge_quiet" ] && [ "$stamp_quiet" = no ]; then
  ok "nudge: shown (and stamped) in a normal launch, silent and unstamped in a restart's relaunch"
else
  bad "nudge: the relaunch gate does not hold" "normal=[$nudge_normal] stamp=$stamp_normal quiet=[$nudge_quiet] stamp=$stamp_quiet"
fi

echo "-- the path a restart execs (HEIMDALL_SELF)"
# The launcher resolves it with _heimdall_self_path, tested here on the function itself (pulled out of bin/heimdall) against real files. A repository that holds an
# executable of the launcher's own name must never be what a restart execs, whatever $0 looked like when the launcher started: joining a bare name onto the working
# directory would run a file the repository (or the session) put there.
fn_src="$(sed -n '/^_heimdall_self_path() {/,/^}/p' "$HEIMDALL")"
S="$T/self"
REAL="$S/real/bin/heimdall"
mkdir -p "$S/real/bin" "$S/pathdir" "$S/repo" "$S/other"
printf '#!/bin/sh\nexit 0\n' > "$REAL"
printf '#!/bin/sh\necho PLANTED-RAN >> "%s/planted.log"\nexit 0\n' "$S" > "$S/repo/hmd"
printf '#!/bin/sh\nexit 0\n' > "$S/other/heimdall"
chmod +x "$REAL" "$S/repo/hmd" "$S/other/heimdall"
ln -s "$REAL" "$S/pathdir/hmd"
self_path() {   # self_path SOURCE WORKDIR ARGV0 RESOLVED: what a launcher started in WORKDIR as ARGV0 would re-exec
  ( cd "$2" && eval "$1" && _heimdall_self_path "$3" "$4" "$2" )
}
want_self() {   # want_self LABEL WANT WORKDIR ARGV0 RESOLVED
  local got
  got="$(self_path "$fn_src" "$3" "$4" "$5")"
  if [ "$got" = "$2" ]; then ok "self: $1"; else bad "self: $1" "got '$got', want '$2'"; fi
}
if [ -z "$fn_src" ]; then
  bad "self: bin/heimdall defines no _heimdall_self_path"
else
  got="$(self_path "$fn_src" "$S/repo" hmd "$REAL")"
  "$got" 2>/dev/null
  if [ "$got" = "$REAL" ] && [ ! -e "$S/planted.log" ]; then ok "self: launched by a bare name with an executable of that name in the repository, a restart execs the resolved launcher and never the repository's file"; else bad "self: a bare name must not reach the repository's file" "got '$got', planted file ran: $([ -e "$S/planted.log" ] && echo yes || echo no)"; fi
  want_self "./hmd naming a different file than the launcher (a planted one) is refused" "$REAL" "$S/repo" ./hmd "$REAL"
  want_self "a bare name with nothing of that name around is the resolved launcher" "$REAL" "$S/other" hmd "$REAL"
  want_self "an absolute path to the same file (the hmd link) is kept, so an update behind the link is found" "$S/pathdir/hmd" "$S/other" "$S/pathdir/hmd" "$REAL"
  want_self "an absolute path to another file is refused" "$REAL" "$S/other" "$S/other/heimdall" "$REAL"
  want_self "a relative path with a slash to the same file is made absolute" "$S/pathdir/hmd" "$S/pathdir" ./hmd "$REAL"
  want_self "no absolute path at all (resolved is a bare name) means nothing to exec, so no supervision" "" "$S/repo" hmd hmd
  broken="$(printf '%s\n' "$fn_src" | sed -e 's/\[ "\$argv0" -ef "\$resolved" \]/true/g' -e 's|^    \*/\*)|    *)|')"
  got="$(self_path "$broken" "$S/repo" hmd "$REAL")"
  if [ "$broken" != "$fn_src" ] && [ "$got" = "$S/repo/hmd" ]; then ok "self: without the same-file guard the repository's file WOULD be what a restart execs (the case above can fail)"; else bad "self: the one-line break of the guard did not change the verdict" "got '$got'"; fi
fi
if grep -q 'HEIMDALL_SELF="\$(_heimdall_self_path "\$0" "\$SELF" "\$WORK_DIR")"' "$HEIMDALL" && ! grep -q 'HEIMDALL_SELF="\$WORK_DIR' "$HEIMDALL"; then ok "self: the launcher takes HEIMDALL_SELF from that function and joins nothing onto WORK_DIR itself"; else bad "self: bin/heimdall computes HEIMDALL_SELF some other way"; fi

echo "-- the exec gap"
launch plain STUB_SIGNAL_PARENT=1 STUB_SLEEP=0.4 -- bash -c "$REENTER" "$FAKE/bin/heimdall"
if [ "$RC" = 0 ]; then ok "exec gap: a USR1 before the supervisor's own trap does not end the re-entered launcher"; else bad "exec gap: the launcher died of the USR1 (exit $RC)" "out=[$(snip "$OUT")]"; fi

echo "-- hmd restart"
RH="$T/rh"
mkdir -p "$RH"
hr() { env -i PATH="$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$RH" ${HR_ENV:-} "$RESTART" "$@" 2>&1; }
if [ ! -f "$RESTART" ]; then
  bad "restart: bin/heimdall-restart does not exist"
else
  out="$(hr off)"; rc=$?
  if [ "$rc" = 0 ] && [ -f "$RH/no-auto-restart" ] && printf '%s' "$(hr status)" | grep -q 'auto restart: off'; then ok "restart off: writes the no-auto-restart file and status says off"; else bad "restart off" "rc=$rc out=[$out]"; fi
  out="$(hr on)"; rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$RH/no-auto-restart" ] && printf '%s' "$(hr status)" | grep -q 'auto restart: on'; then ok "restart on: removes it and status says on"; else bad "restart on" "rc=$rc out=[$out]"; fi
  if printf '%s' "$(HR_ENV=HMD_AUTO_RESTART=off hr status)" | grep -q 'auto restart: off'; then ok "restart status: HMD_AUTO_RESTART=off in the environment reads as off"; else bad "restart status ignores HMD_AUTO_RESTART=off"; fi
  now="$(date +%s)"
  out="$(hr defer 30)"; rc=$?
  until="$(cat "$RH/restart/defer-until" 2>/dev/null)"
  if [ "$rc" = 0 ] && printf '%s' "$until" | grep -qE '^[0-9]{10}$' && [ "$until" -ge $((now + 1790)) ] && [ "$until" -le $((now + 1810)) ] && printf '%s' "$(hr status)" | grep -q 'deferred until'; then ok "restart defer 30: defer-until is 30 minutes ahead, status shows it"; else bad "restart defer 30" "rc=$rc until=[$until] out=[$out]"; fi
  out="$(hr defer)"; until="$(cat "$RH/restart/defer-until" 2>/dev/null)"
  if [ "$until" -ge $((now + 3590)) ] && [ "$until" -le $((now + 3620)) ]; then ok "restart defer: an hour by default"; else bad "restart defer without minutes" "until=[$until]"; fi
  out="$(hr defer 0)"; rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$RH/restart/defer-until" ] && printf '%s' "$(hr status)" | grep -q 'defer: none'; then ok "restart defer 0: clears the deferral"; else bad "restart defer 0" "rc=$rc out=[$out]"; fi
  hr defer 20 >/dev/null
  before="$(cat "$RH/restart/defer-until")"
  out="$(hr defer abc)"; rc1=$?
  out2="$(hr defer 99999)"; rc2=$?
  if [ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$(cat "$RH/restart/defer-until")" = "$before" ]; then ok "restart defer: a non-number or more than a week is a usage error (exit 2) and changes nothing"; else bad "restart defer validation" "rc=$rc1/$rc2"; fi
  out="$(hr now)"; rc=$?
  if [ "$rc" = 1 ] && [ ! -e "$RH/restart/now" ]; then ok "restart now: with no request waiting it says so (exit 1) and writes nothing"; else bad "restart now with nothing waiting" "rc=$rc out=[$out]"; fi
  mkdir -p "$RH/restart/$$"
  printf '{}\n' > "$RH/restart/$$/req.json"
  now="$(date +%s)"
  out="$(hr now)"; rc=$?
  asked="$(cat "$RH/restart/now" 2>/dev/null)"
  if [ "$rc" = 0 ] && printf '%s' "$asked" | grep -qE '^[0-9]{10}$' && [ "$asked" -ge $((now - 5)) ] && [ "$asked" -le $((now + 5)) ]; then ok "restart now: a waiting request makes it write now (the gate reads it within the launcher's poll)"; else bad "restart now with a request waiting" "rc=$rc asked=[$asked] out=[$out]"; fi
  out="$(hr status)"
  if printf '%s' "$out" | grep -q "launcher pid $$ has asked" && printf '%s' "$out" | grep -q 'effort' && printf '%s' "$out" | grep -q 'draft'; then ok "restart status: names the waiting request and what a resume does not bring back"; else bad "restart status text" "$out"; fi
  out="$(hr bogus)"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'status'; then ok "restart: an unknown verb is a usage error (exit 2) that lists the verbs"; else bad "restart unknown verb" "rc=$rc out=[$out]"; fi
  if grep -nE '(^|[^a-z-])(kill|pkill|killall)([^a-z-]|$)' "$RESTART" >/dev/null; then bad "restart: the verb must signal nothing"; else ok "restart: the script names no kill (it writes files and signals nothing)"; fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
