#!/usr/bin/env bash
# fake-claude.sh: test double for the `claude` binary, the oracle half of the seamless-restart
# plan (docs/superpowers/plans/2026-11-13-seamless-update-restart.md, sections 2, 3, 8, task W1-oracle).
# Authored from the plan and the Wave 0 memo ONLY (docs/analysis/2026-11-13-seamless-restart-spike.md),
# never from the supervisor, gate or hook it will be used against.
#
# Measured facts of the real claude 2.1.323 this double copies (memo verdict lines in brackets):
#   - SIGTERM is a normal, graceful exit with status 143, SessionEnd runs, the sessions file is deleted [Q1]
#   - after exit the tty is cooked but NOT bit-identical to its pre-launch state: the launcher's own
#     `stty "$saved"` is what restores it, so this double leaves a deterministic difference (echoe toggled) [Q2]
#   - `--resume <id>` continues the same session id [Q3]
#   - ~/.claude/sessions/<pid>.json: first write has no status; then status in idle|busy|waiting|shell,
#     sessionId, version, statusUpdatedAt (epoch ms); `waitingFor` only while waiting [Q4]
#   - the Stop hook runs while status is still busy, idle follows it [Q4]
#   - the hook runners and the work of a turn are DIRECT children of claude [Q4]; a keystroke moves the
#     tty atime [Q5]; the supervisor starts claude with `<&0 &` so fd 0 is the tty [Q6]
#
# Refuses to run unless HMD_FAKE_CLAUDE=1. Signals only itself and the children it started.
#
# Modes
#   fake-claude.sh [--exit-now] [claude args...]   act as claude (-p/--print and --exit-now: log, exit 0)
#   fake-claude.sh --version                       print a version line, no log, exit 0
#   fake-claude.sh --extract script|env TRACE      print the `#script ` / `#env ` lines of an expected trace
#   fake-claude.sh --trace-diff TRACE LOG [OUT]    render LOG (+ the `[heimdall] ` lines of the launcher's
#                                                  stdout file OUT) as a trace; diff against TRACE; rc 0 same, 1 differ
# Environment (claude mode)
#   FAKE_CLAUDE_LOG          required: JSON lines appended, one per event (start|signal|exit|status|key|stop-hook|child)
#   FAKE_CLAUDE_SCRIPT       steps run in order, one per line; `@N ` prefix = only the N-th start (0-based) of the log
#                              set status=.. sessionId=.. version=.. waitingFor=..   rewrite the sessions file
#                              sleep SECONDS | key | child on|off | stop-hook | exit [RC]
#                            `key` bumps the atime of FAKE_CLAUDE_TTY_FILE; `child on` starts `sleep 3600` as a direct
#                            child (live work the status does not show); `stop-hook` pipes a Stop payload
#                            {session_id,...} into `bash -c "$FAKE_CLAUDE_STOP_HOOK"` with the inherited launcher env
#   FAKE_CLAUDE_TERM         graceful (default, exit 143) | ignore (log TERM, keep running) | slow (FAKE_CLAUDE_SLOW_S, default 3, then 143)
#   FAKE_CLAUDE_FIFO         a named pipe; a `/exit` line exits 0 (the user typed /exit)
#   FAKE_CLAUDE_VERSION      default 2.1.323; FAKE_CLAUDE_SESSION_ID default: the resumed id, else fake-sid-<start index>
#   FAKE_CLAUDE_SESSIONS_DIR default $HOME/.claude/sessions (tests run with a temp HOME)
# Trace lines (an expected trace is the contract, see test/fixtures/fake-claude/expected/):
#   START argv=<--agent/--resume/--continue/-p projection> resume=<sid|none> count=<HMD_RESTART_COUNT|0>
#   | STATUS x | SESSION x | VERSION x | KEY
#   | STOP_HOOK | CHILD on|off | SIGNAL TERM | EXIT rc=N | PRINT <launcher line> | TTY restored=yes|no
set -u

if [ "${HMD_FAKE_CLAUDE:-}" != 1 ]; then
  echo "fake-claude: refusing to run: HMD_FAKE_CLAUDE=1 is required (this is a test double)" >&2
  exit 64
fi

case "${1:-}" in
  --version) echo "${FAKE_CLAUDE_VERSION:-2.1.323} (Claude Code)"; exit 0 ;;
  --extract)
    case "${2:-}" in script|env) ;; *) echo "usage: fake-claude.sh --extract script|env TRACE" >&2; exit 64 ;; esac
    [ -r "${3:-}" ] || { echo "fake-claude: cannot read trace: ${3:-}" >&2; exit 66; }
    sed -n "s/^#$2 //p" "$3"
    exit 0 ;;
  --trace-diff)
    [ $# -ge 3 ] || { echo "usage: fake-claude.sh --trace-diff TRACE LOG [OUT]" >&2; exit 64; }
    exec python3 -I - "$2" "$3" "${4:-}" <<'PY'
import difflib
import json
import sys

exp_path, log_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
KEEP_VALUE = ("--agent", "--resume")
KEEP_FLAG = ("--continue", "-p", "--print")


def project(argv):
    kept, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a in KEEP_VALUE and i + 1 < len(argv):
            kept += [a, argv[i + 1]]
            i += 2
            continue
        if a in KEEP_FLAG or a.startswith("--resume=") or a.startswith("--agent="):
            kept.append(a)
        i += 1
    return " ".join(kept)


events = [json.loads(line) for line in open(log_path) if line.strip()]
prints = []
if out_path:
    for line in open(out_path, errors="replace"):
        line = line.replace("\r", "").rstrip("\n")
        if line.startswith("[heimdall] "):
            prints.append(line)

lines = []
for idx, e in enumerate(events):
    kind = e["event"]
    if kind == "start":
        count = e.get("env", {}).get("HMD_RESTART_COUNT", "0")
        lines.append("START argv=%s resume=%s count=%s" % (project(e["argv"]), e.get("resume") or "none", count))
    elif kind == "signal":
        lines.append("SIGNAL " + e["signal"])
    elif kind == "exit":
        lines.append("EXIT rc=%d" % e["rc"])
        if prints and any(x["event"] == "start" for x in events[idx + 1:]):
            lines.append("PRINT " + prints.pop(0))
    elif kind == "status":
        for key, word in (("status", "STATUS"), ("sessionId", "SESSION"), ("version", "VERSION")):
            if key in e:
                lines.append("%s %s" % (word, e[key]))
    elif kind == "key":
        lines.append("KEY")
    elif kind == "stop-hook":
        lines.append("STOP_HOOK")
    elif kind == "child":
        lines.append("CHILD " + e["state"])
lines += ["PRINT " + p for p in prints]

sttys = [e.get("stty", "") for e in events if e["event"] == "start"]
tty_known = len(sttys) >= 2 and all(sttys)
if tty_known:
    lines.append("TTY restored=" + ("yes" if all(s == sttys[0] for s in sttys[1:]) else "no"))

expected = []
for line in open(exp_path):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    if line.startswith("?tty "):
        if tty_known:
            expected.append(line[5:])
        continue
    expected.append(line)

diff = list(difflib.unified_diff(expected, lines, "expected", "actual", lineterm=""))
if diff:
    print("\n".join(diff))
    sys.exit(1)
PY
    ;;
esac

# ---------------------------------------------------------------- claude mode
LOG=${FAKE_CLAUDE_LOG:-}
[ -n "$LOG" ] || { echo "fake-claude: FAKE_CLAUDE_LOG is required" >&2; exit 64; }
: >>"$LOG" || { echo "fake-claude: cannot write FAKE_CLAUDE_LOG: $LOG" >&2; exit 74; }
TERM_MODE=${FAKE_CLAUDE_TERM:-graceful}
case "$TERM_MODE" in graceful|ignore|slow) ;; *) echo "fake-claude: bad FAKE_CLAUDE_TERM: $TERM_MODE" >&2; exit 64 ;; esac
if [ -n "${FAKE_CLAUDE_FIFO:-}" ] && [ ! -p "$FAKE_CLAUDE_FIFO" ]; then
  echo "fake-claude: FAKE_CLAUDE_FIFO is not a named pipe: $FAKE_CLAUDE_FIFO" >&2
  exit 64
fi

EXIT_NOW=0
if [ "${1:-}" = "--exit-now" ]; then EXIT_NOW=1; shift; fi
case " $* " in *" -p "*|*" --print "*) EXIT_NOW=1 ;; esac

now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t=${EPOCHREALTIME/[.,]/}; echo "${t%???}"
  else perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; fi
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  s=${s//[[:cntrl:]]/?}
  printf '"%s"' "$s"
}

log_event() { printf '{"ts":%s,"event":"%s","pid":%s%s}\n' "$(now_ms)" "$1" "$$" "${2:+,$2}" >>"$LOG"; }

N=$(grep -c '"event":"start"' "$LOG" 2>/dev/null)
[ -n "$N" ] || N=0
RESUME=none; prev=""; ARGJ=""
for a in "$@"; do
  case "$a" in --resume=*) RESUME=${a#--resume=} ;; esac
  [ "$prev" = "--resume" ] && RESUME=$a
  prev=$a
  ARGJ="$ARGJ${ARGJ:+,}$(json_str "$a")"
done
ENVJ="\"PATH0\":$(json_str "${PATH%%:*}")"
for name in $(compgen -e | grep '^HMD_' | sort); do ENVJ="$ENVJ,$(json_str "$name"):$(json_str "${!name}")"; done
TTY_NAME=none; STTY=""
if [ -t 0 ]; then TTY_NAME=$(tty 2>/dev/null || echo unknown); STTY=$(stty -g 2>/dev/null); fi

S_SID=${FAKE_CLAUDE_SESSION_ID:-}
[ -n "$S_SID" ] || { [ "$RESUME" != none ] && S_SID=$RESUME || S_SID="fake-sid-$N"; }
S_VER=${FAKE_CLAUDE_VERSION:-2.1.323}; S_STATUS=""; S_STATUS_TS=0; S_WAITING=""; STARTED_MS=$(now_ms)
SESS_FILE=""; CHILD=""; IDLE=""; READER=""; SLP=""

log_event start "\"n\":$N,\"argv\":[$ARGJ],\"resume\":$(json_str "$RESUME"),\"env\":{$ENVJ},\"tty\":$(json_str "$TTY_NAME"),\"stty\":$(json_str "$STTY")"

on_exit() {
  local rc=$?
  trap - EXIT TERM USR2
  [ -z "$SESS_FILE" ] || rm -f "$SESS_FILE" "$SESS_FILE".tmp.*
  local p; for p in "$CHILD" "$IDLE" "$READER" "$SLP"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done
  if [ -t 0 ]; then
    case "$(stty -a 2>/dev/null)" in *" -echoe"*) stty echoe 2>/dev/null ;; *) stty -echoe 2>/dev/null ;; esac
  fi
  log_event exit "\"rc\":$rc"
}
trap on_exit EXIT
if [ "$EXIT_NOW" = 1 ]; then
  case " $* " in *" -p "*|*" --print "*) echo "fake-claude -p ok" ;; esac
  exit 0
fi

nap() { sleep "$1" & SLP=$!; while kill -0 "$SLP" 2>/dev/null; do wait "$SLP"; done; SLP=""; }
on_term() {
  log_event signal '"signal":"TERM"'
  case "$TERM_MODE" in
    graceful) exit 143 ;;
    slow) nap "${FAKE_CLAUDE_SLOW_S:-3}"; exit 143 ;;
  esac
}
trap on_term TERM
trap 'exit 0' USR2

SESS_DIR=${FAKE_CLAUDE_SESSIONS_DIR:-${HOME:?fake-claude: HOME is unset}/.claude/sessions}
mkdir -p "$SESS_DIR" || exit 74
SESS_FILE="$SESS_DIR/$$.json"

write_session() {
  local body
  body=$(printf '{"pid":%s,"sessionId":%s,"cwd":%s,"startedAt":%s,"version":%s,"kind":"interactive","entrypoint":"cli"' \
    "$$" "$(json_str "$S_SID")" "$(json_str "$PWD")" "$STARTED_MS" "$(json_str "$S_VER")")
  if [ -n "$S_STATUS" ]; then
    body="$body,\"status\":$(json_str "$S_STATUS"),\"updatedAt\":$(now_ms),\"statusUpdatedAt\":$S_STATUS_TS"
    if [ -n "$S_WAITING" ]; then body="$body,\"waitingFor\":$(json_str "$S_WAITING")"; fi
  fi
  printf '%s}\n' "$body" >"$SESS_FILE.tmp.$$" && mv -f "$SESS_FILE.tmp.$$" "$SESS_FILE"
}

run_step() {
  local kv k v frag=""
  case "$1" in
    set)
      shift
      for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k" in
          status) [ "$v" = "$S_STATUS" ] || S_STATUS_TS=$(now_ms); S_STATUS=$v ;;
          sessionId) S_SID=$v ;;
          version) S_VER=$v ;;
          waitingFor) S_WAITING=${v//_/ } ;;
          *) echo "fake-claude: unknown set key: $k" >&2; return 65 ;;
        esac
        frag="$frag${frag:+,}$(json_str "$k"):$(json_str "$v")"
      done
      write_session; log_event status "$frag" ;;
    sleep) nap "${2:?fake-claude: sleep needs seconds}" ;;
    key)
      if [ -n "${FAKE_CLAUDE_TTY_FILE:-}" ]; then
        [ -e "$FAKE_CLAUDE_TTY_FILE" ] || : >"$FAKE_CLAUDE_TTY_FILE"
        touch -a "$FAKE_CLAUDE_TTY_FILE"
      fi
      log_event key "" ;;
    child)
      case "${2:-}" in
        on) sleep 3600 & CHILD=$!; log_event child "\"state\":\"on\",\"cpid\":$CHILD" ;;
        off) [ -z "$CHILD" ] || kill "$CHILD" 2>/dev/null; log_event child "\"state\":\"off\",\"cpid\":${CHILD:-0}"; CHILD="" ;;
        *) echo "fake-claude: child needs on|off" >&2; return 65 ;;
      esac ;;
    stop-hook)
      log_event stop-hook ""
      if [ -n "${FAKE_CLAUDE_STOP_HOOK:-}" ]; then
        printf '{"session_id":%s,"hook_event_name":"Stop","cwd":%s}\n' "$(json_str "$S_SID")" "$(json_str "$PWD")" \
          | bash -c "$FAKE_CLAUDE_STOP_HOOK"
      fi ;;
    exit) exit "${2:-0}" ;;
    *) echo "fake-claude: unknown step: $1" >&2; return 65 ;;
  esac
}

write_session
if [ -n "${FAKE_CLAUDE_FIFO:-}" ]; then
  main=$$
  ( while IFS= read -r l; do [ "$l" = "/exit" ] && kill -USR2 "$main" 2>/dev/null; done <>"$FAKE_CLAUDE_FIFO" ) &
  READER=$!
fi
if [ -n "${FAKE_CLAUDE_SCRIPT:-}" ]; then
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; "@$N "*) line=${line#"@$N "} ;; @*) continue ;; esac
    run_step $line || exit $?
  done <"$FAKE_CLAUDE_SCRIPT"
  set +f
fi
while :; do sleep 3600 & IDLE=$!; wait "$IDLE"; done
