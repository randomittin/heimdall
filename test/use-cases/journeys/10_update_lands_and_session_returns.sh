#!/usr/bin/env bash
# Journey 10 -- an update lands while a session is running, and the session comes back on it (README "Auto-update checks GitHub Releases for new signed versions",
# SIGNING.md "refuse + stay + loud message + autoupdate.log line", docs/seamless-restart.md).
#
#   A developer installed hmd (the real installer, as in journey 01) and works in an interactive `hmd` session in their repo. Updates reach a machine through the auto-updater
#   that every Claude Code session start runs (`heimdall-autoupdate check`; the journey runs `--force`, the same run without the 24 h throttle). Its "latest release" and its
#   installer come from a local snapshot with a newer tag, signed with a throwaway minisign key (no network). (`hmd update` is the manual door to the same updater, and not the
#   door here: on a fresh install the launcher's development-checkout guard answers first, because install.sh's chmod +x leaves bin/edit-tracker.c and bin/parallelism-tracker.c
#   looking modified; it prints "development checkout" and updates nothing.)
#     1. a TAMPERED update (the signed installer with one line added after signing) is refused: the session start is not blocked (exit 0), the refusal is loud and names the
#        release and the bad signature, it is in autoupdate.log, the tampered installer never ran, the installed hmd is still the old release, and the turn that ends next
#        asks for nothing: no restart request, no TERM
#     2. the genuine update lands in the background while the session runs: verified, applied by the real installer, the installed tree is the new release's commit, and the
#        running session is not touched (no restart by itself)
#     3. at the end of the next turn the session asks for a restart: the request names the session and the update (old hmd -> new hmd)
#     4. the operator keeps typing, so the request waits: the gate says SAFE twice and only then is claude ended, once, with a SIGTERM it exits on by itself (143, not a kill),
#        and not before the keyboard has been quiet for the whole quiet window
#     5. the same conversation comes back on the new hmd: the second claude is started with `--resume sid-J`, its launcher started on the new version, the restart count is 1,
#        one line says what was updated, `hmd restart status` names the new version and nothing waiting
#     6. the operator quits as usual: the launcher exits 0 and nothing is relaunched; the keychain was never asked
#
# What is real: the installer, the updater and its signature check, the launcher (including the bare-`hmd` wrap hop), the Stop hook of hooks/hooks.json, the gate and the
# supervisor. What is a double, at the boundary only: claude (the oracle of the restart suites, test/fixtures/fake-claude: it records its argv, signals and exits, writes
# claude's sessions file, and its `key` steps are the keystrokes: they touch the file the gate reads as the tty's atime), the process table the gate reads (this launcher's
# descendants only, without the double's own sleeps, so nothing else on the machine can sway a verdict), the harness's tasks directory (empty), and a dummy API key so the
# launcher does not stop to ask for a login. The gate is run through a recorder that passes its answer on unchanged. The quiet window, the settle time, the poll and the
# session-age floor are shortened through the gate's own env seams; the keyboard is never faked in time, the window really passes. No check depends on how long a step took,
# only on the order of events and on a lower bound the window gives.
#
# Engines reused: test/seamless-restart-e2e.test.sh (the pty driver, the descendants-only process table, the fake claude, the Stop hook taken from hooks.json),
# test/update-signed-apply.test.sh (throwaway minisign key, signed installer, tampered copy, the updater's local seams), test/hmd-update-pending.test.sh (install.sh's upgrade).
# Mutants (test/use-cases/mutants.list): the updater applies a release whose signature does not verify, the relaunch drops `--resume`.
# shellcheck disable=SC2016,SC2329  # the jq filters and the Stop-hook snippet are single-quoted on purpose (a literal $); log_has is only ever called through wait_for
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 10_update_lands_and_session_returns
uc_need_crypto
uc_need minisign
uc_tree
uc_fakebin
uc_sandbox session

SB="$UC_ROOT/session"                      # the session's own files: the double's log, script and fifo, the stop gates, the observers
REL="$UC_ROOT/release"                     # the release: the signed installer, its signature, the throwaway key, the local snapshot of the new tag
FAKE="$UC_TREE/test/fixtures/fake-claude/fake-claude.sh"
HMD="$UC_HOME/.local/bin/hmd"
HH="$UC_HOME/.heimdall"                    # the install clone; hmd's state lives in it too (no HEIMDALL_HOME is set), as for a real user
QUIET_S=8
PTY_PID=""
mkdir -p "$SB/fakes" "$SB/tasks" "$REL"
[ -f "$FAKE" ] || uc_fatal "the restart suites' fake claude is missing: $FAKE"
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ $UC_VERSION =~ $version_re ]] || uc_fatal "VERSION ($UC_VERSION) is not X.Y.Z"
NEW_VERSION="${UC_VERSION%.*}.$((10#${UC_VERSION##*.} + 1))"

nlog() { grep -c -- "$1" "$SB/claude.log" 2>/dev/null || true; }           # lines of the double's log matching a fixed text
log_has() { [ "$(nlog "$1")" -ge "$2" ]; }                                 # ... at least N of them

# wait_for LABEL SECS CMD... -- poll CMD (status 0 = reached) for at most SECS seconds. A miss is a failure, never a pass; the limit is a hang detector.
wait_for() {
  local label="$1" secs="$2" i=0 max; shift 2
  max=$((secs * 5))
  while [ "$i" -lt "$max" ]; do
    if "$@"; then return 0; fi
    if [ -n "$PTY_PID" ] && ! kill -0 "$PTY_PID" 2>/dev/null; then break; fi
    sleep 0.2
    i=$((i + 1))
  done
  uc_bad "$label: not reached within ${secs}s (or the launcher ended first)" "log: $(tail -c 400 "$SB/claude.log" 2>/dev/null | LC_ALL=C tr '\n' ' ') pty: $(tail -c 300 "$SB/hmd.pty" 2>/dev/null | LC_ALL=C tr '\r\n' '  ')"
  return 1
}

# end_session -- nothing of the session outlives the journey: the launcher's whole process group goes (the pty driver takes it down on TERM) if the operator did not already quit,
# and an installer the updater detached is waited for (it writes into the sandbox that is removed next)
end_session() {
  local i=0
  if [ -n "$PTY_PID" ]; then
    if kill -0 "$PTY_PID" 2>/dev/null; then kill -TERM "$PTY_PID" 2>/dev/null; fi
    wait "$PTY_PID" 2>/dev/null
    PTY_PID=""
  fi
  while [ "$i" -lt 300 ] && pgrep -f "$REL/install" >/dev/null 2>&1; do sleep 0.2; i=$((i + 1)); done
  return 0
}
trap 'end_session; hmd_private_tmp_rm' EXIT
bail() { uc_bad "$1" "${2:-}"; end_session; uc_finish; }
# stop_if_red -- a failed step makes the rest of the journey meaningless (and slow): say so and end it
stop_if_red() { if [ "$UC_FAIL" -gt 0 ]; then bail "stopping here: $1"; fi; }

# the claude on this machine's PATH: the restart suites' recording double for the launcher's own session, the harness's quiet stub for every other call (the installer's `plugins` calls)
cat > "$UC_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "${UC_CLAUDE_LOG:-/dev/null}"
case "${1:-}" in
  --version) echo "2.1.323 (Claude Code)"; exit 0 ;;
  plugin|plugins) exit 0 ;;
esac
case " $* " in *" --agent heimdall "*) exec bash "${FAKE_CLAUDE_SH:?}" "$@" ;; esac
exit 0
EOF
chmod +x "$UC_BIN/claude"

# ---------------------------------------------------------------------------------------------------------------------------------------------------- the machine
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
uc_rc "(setup) the real installer puts hmd v$UC_VERSION on the machine" 0
if [ -x "$HMD" ] && [ "$(jq -r .version "$HH/.claude-plugin/plugin.json" 2>/dev/null)" = "$UC_VERSION" ] && [ "$(git -C "$HH" rev-parse HEAD 2>/dev/null)" = "$UC_SHA" ]; then
  uc_ok "(setup) ~/.heimdall is the installed v$UC_VERSION commit and hmd is on the PATH"
else
  uc_bad "(setup) hmd v$UC_VERSION is not installed where the journey expects it"
fi
stop_if_red "there is no installed hmd to update"
: > "$HH/setup-done"                       # first-run setup is not this journey's business
: > "$HH/presence-off"                     # nor team presence: no beat-keeper may be left running after the journey
uc_run "$UC_HOME" "$UC_WORK" -- git init -q
uc_run "$UC_HOME" "$UC_WORK" -- git config user.email dev@example.com
uc_run "$UC_HOME" "$UC_WORK" -- git config user.name Dev

# ---------------------------------------------------------------------------------------------------------------------------------------------------- the release
# a local snapshot of the next version: the tree under test with the version bumped, tagged. The signed installer is the real install.sh, signed by a throwaway key.
REL_REPO="$REL/repo"
git -c core.hooksPath=/dev/null clone -q "$UC_TREE" "$REL_REPO" >/dev/null 2>&1 || uc_fatal "could not clone the snapshot for the new release"
jq --arg v "$NEW_VERSION" '.version = $v' "$REL_REPO/.claude-plugin/plugin.json" > "$REL/plugin.json.new" || uc_fatal "could not bump plugin.json"
cat "$REL/plugin.json.new" > "$REL_REPO/.claude-plugin/plugin.json"
printf '%s\n' "$NEW_VERSION" > "$REL_REPO/VERSION"
git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case -C "$REL_REPO" commit -q -a --no-verify -m "release v$NEW_VERSION" \
  || uc_fatal "could not commit the new release"
git -c tag.gpgsign=false -C "$REL_REPO" tag "v$NEW_VERSION" || uc_fatal "could not tag the new release"
REL_SHA="$(git -C "$REL_REPO" rev-parse HEAD)"
cp "$REL_REPO/install.sh" "$REL/install.sh"
minisign -G -W -f -p "$REL/signing.pub" -s "$REL/signing.key" >/dev/null 2>&1 || uc_fatal "minisign could not mint a throwaway key pair"
minisign -Sq -s "$REL/signing.key" -m "$REL/install.sh" -x "$REL/install.sh.minisig" -c "use-case journey 10" -t "use-case journey 10" >/dev/null 2>&1 || uc_fatal "minisign could not sign the installer"
# the tampered copy: a line of someone else's added after signing; if it ever ran it would leave the marker
TAMPER_MARK="$SB/tampered-installer-ran"
{ head -n 1 "$REL/install.sh"; printf ': > "%s"\n' "$TAMPER_MARK"; tail -n +2 "$REL/install.sh"; } > "$REL/install.tampered.sh"
if [ -n "$REL_SHA" ] && ! cmp -s "$REL/install.sh" "$REL/install.tampered.sh" && minisign -Vq -p "$REL/signing.pub" -m "$REL/install.sh" -x "$REL/install.sh.minisig" >/dev/null 2>&1; then
  uc_ok "(setup) release v$NEW_VERSION: a tagged snapshot, its installer signed with a throwaway key, and a tampered copy that no longer matches the signature"
else
  uc_bad "(setup) the release fixture is not what the journey needs"
fi

# autoupdate ARTIFACT -- the session-start update check (`check --force`: no throttle), with its network seams on the local release: the latest version, the installer and its
# signature, the trust root (a throwaway key), and the installer's own source
autoupdate() {
  uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_NO_AUTOUPDATE=0 HEIMDALL_LATEST_OVERRIDE="$NEW_VERSION" HEIMDALL_INSTALL_ARTIFACT="$1" HEIMDALL_INSTALL_SIG="$REL/install.sh.minisig" \
    HEIMDALL_SIGNING_PUBKEY="$REL/signing.pub" HEIMDALL_REPO="$REL_REPO" -- "$HH/bin/heimdall-autoupdate" --force
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------- the session
cat > "$SB/script" <<'EOF'
@0 set status=idle sessionId=sid-J version=2.1.322
@0 key
@0 set status=busy
@0 stop-hook
@0 set status=idle
@0 key
@0 set status=busy
@0 stop-hook
@0 set status=idle
@0 key
@0 sleep 1
@0 key
@1 set status=idle version=2.1.322
EOF
mkfifo "$SB/fifo"
: > "$SB/tty"
touch -t 202001010000 "$SB/tty"
: > "$SB/claude.log"
: > "$SB/gate.log"
cat > "$SB/fakes/gate.sh" <<'EOF'
#!/bin/sh
# the REAL gate, its answer recorded and passed on unchanged
out=$("$SC_PLUGIN/bin/heimdall-restart-gate" "$@")
rc=$?
printf '%s %s\n' "$(date +%s)" "$out" >> "$SC_GATELOG"
printf '%s\n' "$out"
exit "$rc"
EOF
cat > "$SB/fakes/ps.sh" <<'EOF'
#!/bin/sh
# the process table of ONE session: the launcher's descendants only, without what the fake claude keeps around as housekeeping: its `sleep`s and its forked subshells
# (a row whose command line is its parent's own)
ps -axww -o pid=,ppid=,command= | awk -v root="${HMD_LAUNCHER_PID:-0}" '
  { ppid[$1] = $2; row[$1] = $0; name = $3; sub(/.*\//, "", name); base[$1] = name; c = ""; for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i; cmd[$1] = c }
  END {
    mark[root] = 1
    do { grew = 0; for (p in ppid) if (!(p in mark) && (ppid[p] in mark)) { mark[p] = 1; grew = 1 } } while (grew)
    for (p in mark) {
      if (p == root || !(p in row)) continue
      if (base[p] == "sleep") continue
      if ((ppid[p] in cmd) && cmd[p] == cmd[ppid[p]]) continue
      print row[p]
    }
  }'
EOF
cat > "$SB/pty.py" <<'EOF'
import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time

timeout_s, out_path, rc_path, cmd = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))


def own_tty():
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True, preexec_fn=own_tty)
os.close(slave)


def kill_group():
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        return


def on_term(_signo, _frame):
    kill_group()
    sys.exit(143)


signal.signal(signal.SIGTERM, on_term)
deadline = time.time() + timeout_s
rc = None
with open(out_path, "wb") as out:
    while True:
        if time.time() > deadline:
            kill_group()
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
with open(rc_path, "w") as f:
    f.write(str(rc if rc >= 0 else 128 - rc) + "\n")
EOF
chmod +x "$SB/fakes/gate.sh" "$SB/fakes/ps.sh"

# the Stop hook claude runs at the end of every turn: the one hooks/hooks.json of the installed plugin names for the restart request. It is held until the journey says the turn
# may end (SC_DIR/go-stop-N), so the update can land between two turns of the running session. `$PPID` stays claude's: the gate and the hook share one `bash -c`.
STOP_CMD="$(jq -r '[.hooks.Stop[].hooks[].command | select(contains("heimdall-restart-request"))] | .[0] // empty' "$HH/hooks/hooks.json")"
[ -n "$STOP_CMD" ] || uc_fatal "the installed hooks/hooks.json has no Stop hook that runs heimdall-restart-request"
STOP_GATE='n=$(cat "$SC_DIR/stop.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$SC_DIR/stop.n"; while [ ! -e "$SC_DIR/go-stop-$n" ]; do sleep 0.2; done; '

uc_run "$UC_HOME" "$UC_WORK" -- env
SANDBOX_ENV=()
while IFS= read -r line; do
  case "$line" in [A-Za-z_]*=*) SANDBOX_ENV[${#SANDBOX_ENV[@]}]="$line" ;; esac
done < "$UC_OUT"
SESSION_ENV=(
  ANTHROPIC_API_KEY=sk-ant-use-case-journey-10 HEIMDALL_NO_INTRO=1
  HMD_FAKE_CLAUDE=1 FAKE_CLAUDE_SH="$FAKE" FAKE_CLAUDE_LOG="$SB/claude.log" FAKE_CLAUDE_SCRIPT="$SB/script" FAKE_CLAUDE_FIFO="$SB/fifo" FAKE_CLAUDE_TTY_FILE="$SB/tty"
  FAKE_CLAUDE_TERM=graceful FAKE_CLAUDE_STOP_HOOK="$STOP_GATE$STOP_CMD"
  HMD_RESTART_TTY="$SB/tty" HMD_RESTART_QUIET_S="$QUIET_S" HMD_RESTART_SETTLE_S=1 HMD_RESTART_SESSION_MIN_AGE_S=0 HMD_RESTART_POLL_S=1 HMD_RESTART_RECHECK_S=1
  HMD_RESTART_GATE_CMD="$SB/fakes/gate.sh" HMD_RESTART_PS_CMD="$SB/fakes/ps.sh" HMD_AGENT_TASKDIR="$SB/tasks"
  SC_DIR="$SB" SC_PLUGIN="$HH" SC_GATELOG="$SB/gate.log"
)
# the operator types `hmd` in their repo, in a terminal
( cd "$UC_WORK" && exec env -i "${SANDBOX_ENV[@]}" "${SESSION_ENV[@]}" "$UC_PY" -I "$SB/pty.py" 280 "$SB/hmd.pty" "$SB/hmd.rc" "$HMD" ) </dev/null >"$SB/pty.out" 2>"$SB/pty.err" &
PTY_PID=$!
wait_for "claude is started by the launcher" 90 log_has '"event":"start"' 1 || bail "the session did not start" "$(tail -c 600 "$SB/hmd.pty" 2>/dev/null | LC_ALL=C tr '\r' ' ')"
LPID="$(jq -r 'select(.event == "start") | .env.HMD_LAUNCHER_PID // empty' "$SB/claude.log" | head -n 1)"
RDIR="$(jq -r 'select(.event == "start") | .env.HMD_RESTART_DIR // empty' "$SB/claude.log" | head -n 1)"
if [ -n "$LPID" ] && [ -n "$RDIR" ] && [ "$(jq -r 'select(.event == "start") | .env.HMD_LAUNCHER_START_HMD // empty' "$SB/claude.log" | head -n 1)" = "$UC_VERSION" ]; then
  uc_ok "(setup) hmd started a supervised claude: its launcher (pid $LPID) started on v$UC_VERSION"
else
  bail "(setup) claude was not started by a supervising launcher on v$UC_VERSION" "$(head -c 500 "$SB/claude.log")"
fi
uc_run "$UC_HOME" "$UC_WORK" -- git config --get core.hooksPath
if [ "$(tr -d '\n' < "$UC_OUT")" = ".heimdall/hooks" ]; then uc_ok "(setup) bare hmd wrapped the repo before it launched claude: the gate hooks are wired"; else uc_bad "(setup) bare hmd did not wrap the repo" "$(head -c 200 "$UC_OUT")"; fi
REQ="$RDIR/req.json"

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 1. a tampered update
autoupdate "$REL/install.tampered.sh"
uc_rc "a session start with a tampered update on offer still finishes: the updater never blocks it" 0
uc_has "the refusal is loud: it names the release it refused" "$UC_ERR" "refusing auto-update to v$NEW_VERSION"
uc_has "...says why: the signature does not verify" "$UC_ERR" 'INVALID signature'
uc_has "...and that hmd stays on the verified version" "$UC_ERR" 'staying on the current, verified version'
uc_has "...and the refusal is in autoupdate.log" "$HH/autoupdate.log" "refuse $NEW_VERSION signature rc=6"
if [ ! -e "$TAMPER_MARK" ]; then uc_ok "the tampered installer never ran"; else uc_bad "the tampered installer ran"; fi
if [ "$(jq -r .version "$HH/.claude-plugin/plugin.json")" = "$UC_VERSION" ] && [ "$(git -C "$HH" rev-parse HEAD)" = "$UC_SHA" ]; then
  uc_ok "the installed hmd is still v$UC_VERSION, at the same commit"
else
  uc_bad "the installed tree moved although the update was refused"
fi
stop_if_red "an update that does not verify must be refused before anything else is asked of the journey"
: > "$SB/go-stop-1"
wait_for "the first turn ended" 60 log_has '"status":"idle"' 2 || bail "the first turn did not end"
if [ ! -e "$REQ" ] && [ "$(nlog '"signal":"TERM"')" = 0 ] && [ "$(nlog '"event":"start"')" = 1 ]; then
  uc_ok "the turn that ended after the refusal asked for no restart: no request, no TERM, one claude"
else
  uc_bad "a refused update still made the session ask for a restart or end" "req=$([ -e "$REQ" ] && echo yes || echo no) terms=$(nlog '"signal":"TERM"') starts=$(nlog '"event":"start"')"
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 2. the genuine update lands
autoupdate "$REL/install.sh"
uc_rc "the session start with the genuine update on offer finishes" 0
uc_has "the update is verified against the trust root" "$HH/autoupdate.log" "verified $NEW_VERSION signature ok"
uc_has "...and applied in the background, as v$UC_VERSION -> v$NEW_VERSION" "$HH/autoupdate.log" "applying v$UC_VERSION -> v$NEW_VERSION"
wait_for "the installer the updater detached finishes" 180 grep -Eq 'done in [0-9]+s' "$HH/autoupdate.log" || bail "the update did not land" "$(tail -c 500 "$HH/autoupdate.log" 2>/dev/null | LC_ALL=C tr '\n' ' ')"
if [ "$(jq -r .version "$HH/.claude-plugin/plugin.json")" = "$NEW_VERSION" ] && [ "$(git -C "$HH" rev-parse HEAD)" = "$REL_SHA" ]; then
  uc_ok "the installed tree is now the v$NEW_VERSION commit"
else
  uc_bad "the installed tree is not the new release" "$(jq -r .version "$HH/.claude-plugin/plugin.json") $(git -C "$HH" rev-parse HEAD) want $REL_SHA"
fi
if [ ! -e "$TAMPER_MARK" ] && [ "$(nlog '"signal":"TERM"')" = 0 ] && [ "$(nlog '"event":"start"')" = 1 ]; then
  uc_ok "the running session was not touched by the update: one claude, no TERM, and the update is on disk"
else
  uc_bad "the landing disturbed the running session" "terms=$(nlog '"signal":"TERM"') starts=$(nlog '"event":"start"')"
fi
stop_if_red "the update did not land cleanly, so there is nothing for the session to come back on"

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 3. the turn ends and asks
: > "$SB/go-stop-2"
wait_for "the second turn ended" 60 log_has '"status":"idle"' 3 || bail "the second turn did not end"
uc_jq "the end of the turn asked for a restart: the request names the session and the update, hmd v$UC_VERSION to v$NEW_VERSION" \
  ".session_id == \"sid-J\" and .pending.hmd == [\"$UC_VERSION\", \"$NEW_VERSION\"]" "$REQ"

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 4. the restart waits for the keyboard
wait_for "the operator's last keystroke" 30 log_has '"event":"key"' 4 || bail "the operator never typed"
wait_for "claude is ended" $((QUIET_S + 90)) log_has '"signal":"TERM"' 1 || bail "the session was never restarted"
LASTKEY_MS="$(jq -r 'select(.event == "key") | .ts' "$SB/claude.log" | sort -n | tail -n 1)"
TERM_MS="$(jq -r 'select(.event == "signal" and .signal == "TERM") | .ts' "$SB/claude.log" | head -n 1)"
if [ -n "$LASTKEY_MS" ] && [ -n "$TERM_MS" ] && [ $((TERM_MS - LASTKEY_MS)) -ge $((QUIET_S * 1000)) ]; then
  uc_ok "claude was ended only after the keyboard had been quiet for the whole ${QUIET_S} s window"
else
  uc_bad "claude was ended inside the quiet window" "last keystroke $LASTKEY_MS, TERM $TERM_MS (window ${QUIET_S}s)"
fi
if [ "$(nlog '"signal":"TERM"')" = 1 ] && [ "$(wc -l < "$SB/gate.log" | tr -d ' ')" -ge 2 ] && [ "$(tail -n 2 "$SB/gate.log" | awk '$2 == "SAFE"' | wc -l | tr -d ' ')" = 2 ]; then
  uc_ok "the gate said SAFE twice running before the one TERM"
else
  uc_bad "the TERM did not follow two SAFE answers of the gate" "TERMs=$(nlog '"signal":"TERM"') answers: $(awk '{ print $2 " " $3 }' "$SB/gate.log" | sort | uniq -c | LC_ALL=C tr '\n' '|')"
fi

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 5. the session comes back
wait_for "the session comes back" 90 log_has '"event":"start"' 2 || bail "claude was not started again"
wait_for "the resumed session is up" 30 log_has '"status":"idle"' 4 || bail "the resumed claude never reported its status"
jq -s '[.[] | select(.event == "start")]' "$SB/claude.log" > "$SB/starts.json"
jq -s '[.[] | select(.event == "exit")]' "$SB/claude.log" > "$SB/exits.json"
uc_jq "the first claude was ended by a SIGTERM it exited on by itself: exit 143, not a kill" 'length >= 1 and .[0].rc == 143' "$SB/exits.json"
uc_jq "the session started fresh the first time: no --resume, hmd's own agent" '.[0].argv as $a | ($a | index("--resume")) == null and ($a | index("--agent")) != null' "$SB/starts.json"
uc_jq "the same conversation comes back: the second claude is started with --resume sid-J" \
  'length == 2 and (.[1].argv as $a | ($a | index("--resume")) as $i | $i != null and $a[$i + 1] == "sid-J" and .[1].resume == "sid-J")' "$SB/starts.json"
uc_jq "...as hmd's own agent again" '.[1].argv | index("--agent") != null' "$SB/starts.json"
uc_jq "...on the new hmd: its launcher started on v$NEW_VERSION, the first one on v$UC_VERSION" \
  ".[0].env.HMD_LAUNCHER_START_HMD == \"$UC_VERSION\" and .[1].env.HMD_LAUNCHER_START_HMD == \"$NEW_VERSION\"" "$SB/starts.json"
uc_jq "...as the first restart of this launcher (HMD_RESTART_COUNT 1)" '.[1].env.HMD_RESTART_COUNT == "1"' "$SB/starts.json"
tr -d '\r' < "$SB/hmd.pty" > "$SB/hmd.txt"
uc_has "one line says what was updated" "$SB/hmd.txt" "^\\[heimdall\\] updated hmd $UC_VERSION->$NEW_VERSION - resumed"
if [ "$(grep -c '^\[heimdall\] updated ' "$SB/hmd.txt")" = 1 ]; then uc_ok "...and it was printed once"; else uc_bad "the update line was printed $(grep -c '^\[heimdall\] updated ' "$SB/hmd.txt") times"; fi
uc_run "$UC_HOME" "$UC_WORK" -- "$HMD" restart status
uc_rc "hmd restart status answers" 0
uc_has "...naming the version the last restart went to" "$UC_OUT" "^last restart: .* to hmd $NEW_VERSION"
uc_has "...and nothing waiting any more" "$UC_OUT" '^waiting: nothing$'

# ---------------------------------------------------------------------------------------------------------------------------------------------------- 6. the operator quits
( exec 8<>"$SB/fifo" && printf '/exit\n' >&8 ) 2>/dev/null
wait_for "the launcher ends after /exit" 60 test -s "$SB/hmd.rc" || bail "the launcher did not end after the operator quit"
if [ "$(tr -d '\n' < "$SB/hmd.rc")" = 0 ] && [ "$(nlog '"event":"start"')" = 2 ]; then
  uc_ok "quitting ends the launcher with status 0, and nothing is relaunched"
else
  uc_bad "the launcher's end is not a plain quit" "rc=$(cat "$SB/hmd.rc") starts=$(nlog '"event":"start"')"
fi
wait "$PTY_PID" 2>/dev/null
PTY_PID=""
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the journey asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
