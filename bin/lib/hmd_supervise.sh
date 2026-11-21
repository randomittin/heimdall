#!/usr/bin/env bash
# hmd_supervise.sh -- run claude as a supervised child; when an update has landed, end it at a safe moment and re-exec the launcher on the new binary and
# plugin, resuming the same session.
#
# docs/superpowers/plans/2026-11-13-seamless-update-restart.md (sections 2, 3 and 5, Task W2-supervisor); measurements: docs/analysis/2026-11-13-seamless-restart-spike.md.
# Sourced by bin/heimdall, which calls ONE function in place of the bare `claude ...` line (both call sites: the interactive launch and --resume):
#
#     hmd_supervised_claude <claude args...>          status = the last child's status
#
# Nothing happens on `source`: this file only defines functions, and is read completely before the child starts, so an update that rewrites it (or
# bin/heimdall) while a session runs cannot change what the running launcher executes. The supervised path never returns into the launcher's script text
# after a restart: it ends in `exec`. (The caller keeps the tail of its own script in one compound command, `{ hmd_supervised_claude ...; exit $?; }`, so the
# non-restart path does not read the rewritten file either.)
#
# What it needs from the launcher
#   HMD_SUPERVISED=1          exported only for an interactive claude with a TTY on stdin and stdout. Anything else, and HMD_AUTO_RESTART=off (any case), is
#                             exactly `claude "$@"; return $?`: no background job, no trap, no file. So -p, a pipe, the shim and --team panes get no supervisor
#   HEIMDALL_SELF, ORIG_ARGV  the launcher's own path and a bash array of its argv as it was started: a restart re-execs the NEW launcher with them (not the
#                             old flags: the point of an hmd update is a new preamble, new routing, new hooks)
#   HMD_SUPERVISE_CLEANUP_FN  optional: the name of a function holding the launch cleanup (bin/heimdall's `cleanup`). It is run in a subshell before the exec;
#                             it ends in `exit`, which then only ends the subshell. The launcher's EXIT trap does not run on an exec
# What it gives claude (all exported before the child starts; claude is a DIRECT child of HMD_LAUNCHER_PID, as the Stop hook checks)
#   HMD_LAUNCHER_PID          this launcher's pid: the hook sends USR1 to it
#   HMD_RESTART_DIR           a 0700 directory ($HEIMDALL_HOME/restart/<pid>, the same one across the exec: the pid is kept) where the hook writes req.json
#   HMD_LAUNCHER_START_HMD    the hmd version in .claude-plugin/plugin.json when this launcher started (what `heimdall-update-pending` compares with)
#   HMD_RESTART_TTY           the tty whose atime is the last keystroke (the gate's quiet window); a value already set is kept
# Seams (env): HMD_CLAUDE_BIN (claude), HMD_RESTART_GATE_CMD, HMD_UPDATE_PENDING_CMD, HMD_CHECKPOINT_CMD, HMD_RESTART_PARKED_CMD (no default: one name per line
# of the parked agents a restart ends; bin/heimdall-agents has no names-only listing yet), HMD_RESTART_SESSIONS_DIR (~/.claude/sessions), HMD_UPDATE_PLUGIN_DIR,
# HEIMDALL_HOME (~/.heimdall); seconds, digits only (anything else is the default, never 0): HMD_RESTART_POLL_S (5, between two looks at a waiting request),
# HMD_RESTART_RECHECK_S (3, between the two gate answers), HMD_RESTART_TERM_WAIT_S (20), HMD_RESTART_REQ_TTL_S (7200), HMD_RESTART_RESUME_FAIL_S (5);
# HMD_RESTART_MAX (3 restarts per launcher lifetime, counted by HMD_RESTART_COUNT, which survives the exec).
#
# The sequence (section 2): the Stop hook writes req.json and sends USR1. The launcher wakes (a trapped signal ends its `wait`; while a request waits it also
# wakes every second), runs the gate on a poll of HMD_RESTART_POLL_S, and after two SAFE answers HMD_RESTART_RECHECK_S apart runs `heimdall-checkpoint write`,
# reads the session id NOW (the sessions file follows /clear; the request's id is only the fallback), writes restarting.json and sends ONE TERM to its own
# child. Never a KILL, never a signal to any other pid. Claude exits 143 by itself within seconds (memo Q1) and restores its own terminal. If the child is still
# there after HMD_RESTART_TERM_WAIT_S, restarting.json and the request are deleted and the session is left alone until a NEW Stop. When the child ends and
# restarting.json is there for THAT child, the launcher puts the tty back (`stty` of the state it found: claude leaves a sane cooked state, not the pre-launch
# bits, and no escape-sequence mode: memo Q2), runs the cleanup, records the restart in $HEIMDALL_HOME/restart/last.json (the gate's loop guard reads it),
# prints ONE line and execs the launcher with HMD_RESUME_SESSION_ID, HMD_RESTART_COUNT+1, HMD_RESTARTED_FROM and HEIMDALL_NO_INTRO=1. Any other exit (the
# user's /exit, a crash) is the plain exit with claude's status. In the re-entered launcher a resume that fails within HMD_RESTART_RESUME_FAIL_S falls back to
# `--continue`, then to a fresh launch (HMD_RESTART_FALLBACK=checkpoint in its environment), one printed line each.
#
# Known gap, for bin/heimdall: between the exec and the new launcher's `trap`, USR1 has its default action. The Stop hook only signals a launcher whose child is
# alive, and the child is gone by then, but `trap : USR1` near the top of bin/heimdall (when HMD_LAUNCHER_PID is set) closes it.

_hmd_sv_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# a number of seconds from the environment (the NAME is one of this file's own constants): digits only, else the default, so a typo is never a silent 0
_hmd_sv_secs() {
  local v
  eval "v=\${$1:-}"
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$v" ;;
  esac
}

_hmd_sv_safe_id() {
  case "$1" in ''|*[!0-9A-Za-z._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

_hmd_sv_safe_ver() {
  case "$1" in ''|*[!0-9A-Za-z._+-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# single-quote a word so python's shlex (the gate splits HMD_RESTART_PENDING_CMD) reads it back whole
_hmd_sv_q() {
  local s=$1 out="'"
  while :; do
    case "$s" in
      *\'*) out="$out${s%%\'*}'\\''"; s=${s#*\'} ;;
      *) out="$out$s'"; break ;;
    esac
  done
  printf '%s' "$out"
}

# the string value of a "KEY": "value" of a flat JSON file (claude's sessions file, plugin.json, the Stop hook's req.json); empty when absent
_hmd_sv_json_str() {
  local line re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$1"
  return 0
}

# best effort, one line in the launcher's own directory: never on the terminal
_hmd_sv_log() { printf '%s %s\n' "$(date +%s)" "$*" >> "$HMD_RESTART_DIR/supervisor.log" 2>/dev/null || true; }

# the pending text (`claude <running> <newest>` / `hmd <started> <installed>`) -> _HMD_SV_DESC "claude A->B, hmd A->B", _HMD_SV_FROM / _HMD_SV_TO as JSON
# members; 1 when no half is valid. A version is a short run of [0-9A-Za-z._+-], so nothing from that output reaches a file or the terminal as markup.
_hmd_sv_parse_pending() {
  local name a b rest desc="" from="" to=""
  while read -r name a b rest; do
    case "$name" in claude|hmd) ;; *) continue ;; esac
    if ! _hmd_sv_safe_ver "$a" || ! _hmd_sv_safe_ver "$b"; then continue; fi
    desc="$desc${desc:+, }$name $a->$b"
    from="$from${from:+, }\"$name\": \"$a\""
    to="$to${to:+, }\"$name\": \"$b\""
  done <<EOF
$1
EOF
  [ -n "$desc" ] || return 1
  _HMD_SV_DESC=$desc
  _HMD_SV_FROM=$from
  _HMD_SV_TO=$to
}

# the names of the parked agents a restart ends (they are in-process teammates of claude: they have no pid, a restart is what clears them), joined for the line
_hmd_sv_parked() {
  local names="" n out
  if [ -z "${HMD_RESTART_PARKED_CMD:-}" ] || [ ! -x "$HMD_RESTART_PARKED_CMD" ]; then return 0; fi
  out=$("$HMD_RESTART_PARKED_CMD" 2>/dev/null </dev/null) || return 0
  while IFS= read -r n; do
    case "$n" in ''|*[!0-9A-Za-z._@:\ -]*) continue ;; esac
    names="$names${names:+, }$n"
  done <<EOF
$out
EOF
  printf '%s' "$names"
}

_hmd_sv_line() {
  local line="[heimdall] updated $_HMD_SV_DESC - resumed"
  if [ -n "${_HMD_SV_PARKED:-}" ]; then line="$line (parked agents ended: $_HMD_SV_PARKED)"; fi
  printf '%s' "$line"
}

_hmd_sv_tty_restore() {
  if [ -n "$_HMD_SV_STTY" ]; then stty "$_HMD_SV_STTY" 2>/dev/null || true; fi
}

# everything the supervised path needs; 1 (so the caller launches claude bare) when any of it is missing: a supervisor that could not relaunch is only risk
_hmd_sv_setup() {
  local lib_dir bin_dir plugin_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  bin_dir=$(cd "$lib_dir/.." && pwd) || return 1
  _HMD_SV_HOME=${HEIMDALL_HOME:-${HOME:-}/.heimdall}
  plugin_dir=${HMD_UPDATE_PLUGIN_DIR:-$bin_dir/..}
  _HMD_SV_GATE=${HMD_RESTART_GATE_CMD:-$bin_dir/heimdall-restart-gate}
  _HMD_SV_PENDING=${HMD_UPDATE_PENDING_CMD:-$bin_dir/heimdall-update-pending}
  _HMD_SV_CKPT=${HMD_CHECKPOINT_CMD:-$bin_dir/heimdall-checkpoint}
  _HMD_SV_SESSIONS=${HMD_RESTART_SESSIONS_DIR:-${HOME:-}/.claude/sessions}
  if [ ! -x "$_HMD_SV_GATE" ] || [ ! -x "$_HMD_SV_PENDING" ]; then return 1; fi
  if [ -z "${HEIMDALL_SELF:-}" ] || [ ! -x "$HEIMDALL_SELF" ]; then return 1; fi
  _HMD_SV_START_HMD=$(_hmd_sv_json_str "$plugin_dir/.claude-plugin/plugin.json" version)
  _hmd_sv_safe_ver "$_HMD_SV_START_HMD" || return 1
  _HMD_SV_POLL=$(_hmd_sv_secs HMD_RESTART_POLL_S 5)
  _HMD_SV_RECHECK=$(_hmd_sv_secs HMD_RESTART_RECHECK_S 3)
  _HMD_SV_TERM_WAIT=$(_hmd_sv_secs HMD_RESTART_TERM_WAIT_S 20)
  _HMD_SV_TTL=$(_hmd_sv_secs HMD_RESTART_REQ_TTL_S 7200)
  _HMD_SV_FAIL_S=$(_hmd_sv_secs HMD_RESTART_RESUME_FAIL_S 5)
  _HMD_SV_MAX=$(_hmd_sv_secs HMD_RESTART_MAX 3)
  # a directory inherited from an OUTER launcher (hmd run inside an hmd session) is not ours
  if [ -n "${HMD_LAUNCHER_PID:-}" ] && [ "$HMD_LAUNCHER_PID" != "$$" ]; then HMD_RESTART_DIR=""; fi
  : "${HMD_RESTART_DIR:=$_HMD_SV_HOME/restart/$$}"
  ( umask 077; mkdir -p "$HMD_RESTART_DIR" ) 2>/dev/null || return 1
  rm -f "$HMD_RESTART_DIR/req.json" "$HMD_RESTART_DIR/restarting.json" 2>/dev/null || true
  _HMD_SV_STTY=""
  if [ -t 0 ]; then
    _HMD_SV_STTY=$(stty -g 2>/dev/null) || _HMD_SV_STTY=""
    if [ -z "${HMD_RESTART_TTY:-}" ]; then HMD_RESTART_TTY=$(tty 2>/dev/null) || HMD_RESTART_TTY=""; fi
  fi
  case "${HMD_RESTART_TTY:-}" in /*) ;; *) HMD_RESTART_TTY="" ;; esac
  export HMD_LAUNCHER_PID=$$ HMD_RESTART_DIR HMD_RESTART_TTY HMD_LAUNCHER_START_HMD="$_HMD_SV_START_HMD"
  _HMD_SV_POKED=0
  _HMD_SV_SINCE=-1
  _HMD_SV_LOOKED=-1000
  _HMD_SV_TERMED=""
  _HMD_SV_PARKED=""
  _HMD_SV_WHY=""
  _HMD_SV_RC=0
  _HMD_SV_STARTED=0
  return 0
}

# claude as a background child of this shell, its stdin still the terminal: bash gives an async child /dev/null otherwise, and measured (memo Q6) the child
# still reads the controlling tty, takes Ctrl-C and resizes either way; `<&0` keeps it the same as a foreground launch
_hmd_sv_start() {
  "$_HMD_SV_BIN" ${_HMD_SV_ARGS[@]+"${_HMD_SV_ARGS[@]}"} <&0 &
  _HMD_SV_PID=$!
  _HMD_SV_STARTED=$SECONDS
  _HMD_SV_PENDING_LINE="$(_hmd_sv_q "$_HMD_SV_PENDING") --launcher-start-hmd $(_hmd_sv_q "$_HMD_SV_START_HMD") --pid $_HMD_SV_PID"
}

# resume -> --continue -> nothing: the arguments of the next attempt after a resume that failed fast
_hmd_sv_retarget() {
  local mode=$1 a skip=0 n=0
  local -a out
  out=()
  for a in ${_HMD_SV_ARGS[@]+"${_HMD_SV_ARGS[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      --resume) skip=1 ;;
      --resume=*|--continue) ;;
      *) out[$n]=$a; n=$((n + 1)) ;;
    esac
  done
  if [ "$mode" = continue ]; then out[$n]=--continue; fi
  _HMD_SV_ARGS=(${out[@]+"${out[@]}"})
}

# one answer of the gate for the request: 0 only for SAFE; the reason token of an UNSAFE is left in _HMD_SV_WHY. Anything else (a gate that cannot run) is UNSAFE
_hmd_sv_gate() {
  local out rc=0
  out=$(HMD_RESTART_PENDING_CMD="$_HMD_SV_PENDING_LINE" "$_HMD_SV_GATE" --req "$HMD_RESTART_DIR/req.json" 2>/dev/null </dev/null) || rc=$?
  _HMD_SV_WHY=${out#UNSAFE }
  [ "$rc" -eq 0 ] && [ "$out" = SAFE ]
}

# the decision, once: two SAFE answers, then checkpoint, marker, ONE TERM, and the wait for the child to go. Every refusal returns with the session untouched.
_hmd_sv_decide() {
  local cnt=${HMD_RESTART_COUNT:-0} sid pend deadline marker_tmp
  case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
  if [ "$cnt" -ge "$_HMD_SV_MAX" ]; then
    rm -f "$HMD_RESTART_DIR/req.json" 2>/dev/null || true
    _hmd_sv_log "request dropped: $cnt restarts already, the cap is $_HMD_SV_MAX"
    return 0
  fi
  if [ ! -x "${HEIMDALL_SELF:-}" ]; then
    _hmd_sv_log "no restart: the launcher ${HEIMDALL_SELF:-} cannot be executed, so the session could not be brought back"
    return 0
  fi
  if ! _hmd_sv_gate; then
    # a request that cannot be satisfied until something else changes is dropped: the next Stop makes a new one
    case "$_HMD_SV_WHY" in no-update|opt-out|not-supervised) rm -f "$HMD_RESTART_DIR/req.json" 2>/dev/null || true ;; esac
    return 0
  fi
  sleep "$_HMD_SV_RECHECK" || true
  _hmd_sv_gate || return 0
  kill -0 "$_HMD_SV_PID" 2>/dev/null || return 0
  pend=$("$_HMD_SV_PENDING" --launcher-start-hmd "$_HMD_SV_START_HMD" --pid "$_HMD_SV_PID" 2>/dev/null </dev/null) || return 0
  _hmd_sv_parse_pending "$pend" || return 0
  # the id in effect NOW: /clear changes it after the last Stop, so the request's id is only the fallback
  sid=$(_hmd_sv_json_str "$_HMD_SV_SESSIONS/$_HMD_SV_PID.json" sessionId)
  if ! _hmd_sv_safe_id "$sid"; then sid=$(_hmd_sv_json_str "$HMD_RESTART_DIR/req.json" session_id); fi
  if ! _hmd_sv_safe_id "$sid"; then
    _hmd_sv_log "no restart: no usable session id in the sessions file or the request"
    return 0
  fi
  _HMD_SV_SID=$sid
  _HMD_SV_PARKED=$(_hmd_sv_parked)
  if ! "$_HMD_SV_CKPT" write "$PWD" >/dev/null 2>&1 </dev/null; then
    _hmd_sv_log "heimdall-checkpoint write failed: the resume does not need it, the fallback to a fresh launch would"
  fi
  marker_tmp="$HMD_RESTART_DIR/restarting.json.tmp.$$"
  if ! printf '{"claude_pid": %s, "session_id": "%s", "from": {%s}, "to": {%s}}\n' "$_HMD_SV_PID" "$sid" "$_HMD_SV_FROM" "$_HMD_SV_TO" > "$marker_tmp" 2>/dev/null \
     || ! mv -f "$marker_tmp" "$HMD_RESTART_DIR/restarting.json" 2>/dev/null; then
    rm -f "$marker_tmp" 2>/dev/null || true
    _hmd_sv_log "no restart: restarting.json could not be written"
    return 0
  fi
  _HMD_SV_TERMED=$_HMD_SV_PID
  _hmd_sv_log "restart: claude $_HMD_SV_PID, session $sid, $_HMD_SV_DESC"
  if ! kill -TERM "$_HMD_SV_PID" 2>/dev/null; then
    # gone already (the user's /exit won the race): a normal exit, not ours
    rm -f "$HMD_RESTART_DIR/restarting.json" 2>/dev/null || true
    return 0
  fi
  deadline=$((SECONDS + _HMD_SV_TERM_WAIT))
  while kill -0 "$_HMD_SV_PID" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      rm -f "$HMD_RESTART_DIR/restarting.json" "$HMD_RESTART_DIR/req.json" 2>/dev/null || true
      _hmd_sv_log "term-ignored: claude $_HMD_SV_PID still running ${_HMD_SV_TERM_WAIT}s after the TERM; the session is left alone until a new Stop"
      return 0
    fi
    sleep 0.2 2>/dev/null || sleep 1 || true
  done
  return 0
}

# one look at the request: at once for a new Stop (USR1), else at most every HMD_RESTART_POLL_S; a request nobody could satisfy expires
_hmd_sv_serve() {
  if [ ! -f "$HMD_RESTART_DIR/req.json" ]; then
    _HMD_SV_POKED=0
    _HMD_SV_SINCE=-1
    return 0
  fi
  if [ "$_HMD_SV_POKED" = 1 ] || [ "$_HMD_SV_SINCE" -lt 0 ]; then _HMD_SV_SINCE=$SECONDS; fi
  if [ "$_HMD_SV_POKED" = 1 ]; then _HMD_SV_LOOKED=-1000; fi
  _HMD_SV_POKED=0
  if [ $((SECONDS - _HMD_SV_SINCE)) -ge "$_HMD_SV_TTL" ]; then
    rm -f "$HMD_RESTART_DIR/req.json" 2>/dev/null || true
    _hmd_sv_log "request expired after ${_HMD_SV_TTL}s without a safe moment"
    return 0
  fi
  if [ $((SECONDS - _HMD_SV_LOOKED)) -lt "$_HMD_SV_POLL" ]; then return 0; fi
  _HMD_SV_LOOKED=$SECONDS
  _hmd_sv_decide
}

# block until the child is gone and leave its status in _HMD_SV_RC. `wait` ends early, above 128, when a trapped signal arrives; the child is then looked at
# with `kill -0`, the request served, and the wait resumed. While a request waits the block is a one-second `sleep` instead, so the poll runs and the child's
# end is still noticed within the second. (A USR1 that lands between the test for a request and the start of `wait` waits for the next Stop: bash has no
# way to close that window, and the request is not lost, only late.)
_hmd_sv_wait() {
  local r=0 first=""
  _HMD_SV_RC=0
  while :; do
    if ! kill -0 "$_HMD_SV_PID" 2>/dev/null; then break; fi
    if [ -f "$HMD_RESTART_DIR/req.json" ] || [ "$_HMD_SV_POKED" = 1 ]; then
      sleep 1 &
      wait $! 2>/dev/null || true
      if kill -0 "$_HMD_SV_PID" 2>/dev/null; then _hmd_sv_serve; continue; fi
      break
    fi
    r=0
    wait "$_HMD_SV_PID" 2>/dev/null || r=$?
    if kill -0 "$_HMD_SV_PID" 2>/dev/null; then _hmd_sv_serve; continue; fi
    if [ "$r" -le 128 ]; then
      _HMD_SV_RC=$r
      return 0
    fi
    first=$r
    break
  done
  # gone, and its status not yet read (or read as a status above 128, which a cut-short `wait` also returns): ask once more; a second `wait` on a child
  # already reported answers 127, and then the first answer was the real one
  r=0
  wait "$_HMD_SV_PID" 2>/dev/null || r=$?
  if [ "$r" -eq 127 ] && [ -n "$first" ]; then _HMD_SV_RC=$first; else _HMD_SV_RC=$r; fi
}

# the child ended on our TERM: bring the same session back on the new launcher. Returns only when the exec failed.
_hmd_sv_relaunch() {
  local n=${HMD_RESTART_COUNT:-0} last tmp
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  rm -f "$HMD_RESTART_DIR/req.json" "$HMD_RESTART_DIR/restarting.json" 2>/dev/null || true
  _hmd_sv_tty_restore
  if [ -n "${HMD_SUPERVISE_CLEANUP_FN:-}" ] && [ "$(type -t "$HMD_SUPERVISE_CLEANUP_FN" 2>/dev/null)" = function ]; then
    ( "$HMD_SUPERVISE_CLEANUP_FN" ) >/dev/null 2>&1 || true
  fi
  last="$_HMD_SV_HOME/restart"
  tmp="$last/last.json.tmp.$$"
  if ! { mkdir -p "$last" && printf '{"ts": %s, "targets": {%s}}\n' "$(date +%s)" "$_HMD_SV_TO" > "$tmp" && mv -f "$tmp" "$last/last.json"; } 2>/dev/null; then
    _hmd_sv_log "last.json could not be written: the gate's loop guard has nothing to read; the cap of $_HMD_SV_MAX restarts still holds"
  fi
  printf '%s\n' "$(_hmd_sv_line)"
  shopt -s execfail
  HMD_RESUME_SESSION_ID="$_HMD_SV_SID" HMD_RESTART_COUNT=$((n + 1)) HMD_RESTARTED_FROM="$_HMD_SV_DESC" HEIMDALL_NO_INTRO=1 \
    exec "$HEIMDALL_SELF" ${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}
  shopt -u execfail
  printf '[heimdall] could not relaunch %s: the session was ended\n' "$HEIMDALL_SELF" >&2
}

hmd_supervised_claude() {
  local rc=0 level=resume resume_attempt=0 count=${HMD_RESTART_COUNT:-0}
  _HMD_SV_BIN=${HMD_CLAUDE_BIN:-claude}
  if [ "$(_hmd_sv_lc "${HMD_AUTO_RESTART:-}")" = off ] || [ "${HMD_SUPERVISED:-}" != 1 ] || ! _hmd_sv_setup; then
    "$_HMD_SV_BIN" "$@" || rc=$?
    return "$rc"
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge 1 ] && [ -n "${HMD_RESUME_SESSION_ID:-}" ]; then resume_attempt=1; fi
  _HMD_SV_ARGS=("$@")
  trap '_HMD_SV_POKED=1' USR1
  trap ':' INT
  _hmd_sv_start
  while :; do
    _hmd_sv_wait
    rc=$_HMD_SV_RC
    # a restart is ours only when restarting.json is there AND the TERM went to THIS child; any other exit is the user's or a crash
    if [ -f "$HMD_RESTART_DIR/restarting.json" ] && [ "$_HMD_SV_TERMED" = "$_HMD_SV_PID" ]; then
      _hmd_sv_relaunch
      break
    fi
    if [ "$resume_attempt" = 1 ] && [ "$rc" -ne 0 ] && [ "$level" != fresh ] && [ $((SECONDS - _HMD_SV_STARTED)) -le "$_HMD_SV_FAIL_S" ]; then
      _hmd_sv_tty_restore
      if [ "$level" = resume ]; then
        level=continue
        _hmd_sv_retarget continue
        printf '[heimdall] resume failed (exit %s); continuing the last conversation\n' "$rc"
      else
        level=fresh
        _hmd_sv_retarget fresh
        export HMD_RESTART_FALLBACK=checkpoint
        printf '[heimdall] resume failed (exit %s); restarted from checkpoint\n' "$rc"
      fi
      _hmd_sv_start
      continue
    fi
    break
  done
  # USR1 stays trapped (to nothing): a Stop hook still running when claude exited may signal a launcher that is past the loop, and the default action would end it
  trap ':' USR1
  trap - INT
  rm -f "$HMD_RESTART_DIR/req.json" "$HMD_RESTART_DIR/restarting.json" "$HMD_RESTART_DIR/supervisor.log" 2>/dev/null || true
  rmdir "$HMD_RESTART_DIR" 2>/dev/null || true
  return "$rc"
}
