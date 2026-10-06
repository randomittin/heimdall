#!/usr/bin/env bash
#
# headroom-failsafe.test.sh — acceptance for FAIL-SAFE routing through the local
# Headroom proxy (bin/lib/hmd-headroom-chain.sh).
#
# THE INCIDENT THIS PINS (2026-10-06). The proxy on 127.0.0.1:8787 exited on a signal
# and nothing brought it back for 16m27s. Every live Claude session and subagent had
# ANTHROPIC_BASE_URL pinned to it at launch, so every request died with ECONNREFUSED.
# Two code facts made it worse, and both are asserted here:
#   · a launch from inside such a session inherited the dead ANTHROPIC_BASE_URL — the
#     chain said "not routing" and the tool launched straight into the dead port anyway;
#   · the chain could block ~5s on a listener that accepts but never answers, and then
#     start a SECOND proxy on top of it.
#
# THE CONTRACT. Routing never points a session at a port that is not answering:
#   probe (<=1s)  ->  dead? try the existing start path  ->  still down? DIRECT, with a
#   one-line stderr warning, and the inherited ANTHROPIC_BASE_URL dropped iff it is OUR
#   loopback proxy URL (an operator's own URL is never touched).
#
# HERMETIC. Every proxy here is a stdlib http.server on an ephemeral 2xxxx port. The
# real proxy on :8787 is never contacted, signalled or restarted. `launchctl` is ALWAYS
# the recorder in this file (LAUNCHCTL=...), and HOME is a throwaway, so no case can
# reach the real launchd domain.
#
# Sections:
#   1  dead port -> the start path runs once, proxy detached into its OWN process group
#   2  start path fails -> declines, one stderr warning, bounded wait
#   3  inherited dead ANTHROPIC_BASE_URL is dropped (and said so, in ONE line)
#   4  an operator's own ANTHROPIC_BASE_URL is never dropped
#   5  hung listener -> declines inside ~1s, does NOT start a second proxy on top of it
#   6  healthy proxy -> reused untouched (no start, no warning)
#   7  hmd_headroom_port_state: dead / silent / answering, each inside its budget
#   8  a stranger that answers HTTP is refused, and no proxy is started over it
#   9  opted-in launchd supervision: the chain asks launchd, never spawns beside it
#  10  launchd is unreachable from a synthetic HOME unless launchctl is shimmed
#  11  hmd_headroom_drop_if_dead (the shim re-entry arm's cheap check)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHAIN="$ROOT/bin/lib/hmd-headroom-chain.sh"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
command -v curl    >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
command -v perl    >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/headroom-failsafe.XXXXXX")"
PIDS="$TMP/pids"; : > "$PIDS"
cleanup() {
  local p f
  while read -r p; do [ -n "$p" ] && kill "$p" >/dev/null 2>&1; done < "$PIDS"
  for f in "$TMP"/home-*/.heimdall/headroom/proxy.pid; do
    [ -s "$f" ] && kill "$(cat "$f")" >/dev/null 2>&1
  done
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

now()  { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
lt()   { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
lines(){ [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ── fixtures ────────────────────────────────────────────────────────────────────────
SERVER_PY="$TMP/fake_http_server.py"
cat > "$SERVER_PY" <<'PYEOF'
import os, sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
service = os.environ.get("FAKE_SERVICE", "headroom-proxy")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return None

    def do_GET(self):
        body = json.dumps(
            {
                "service": service,
                "checks": {"upstream": {"url": "https://api.anthropic.com"}},
                "config": {"pid": os.getpid()},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

BLACKHOLE_PY="$TMP/blackhole.py"
cat > "$BLACKHOLE_PY" <<'PYEOF'
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(120)
PYEOF

# A fake `headroom` CLI. Every launch appends one line to $FAKE_START_LOG (so "how many
# times was a proxy started, and from where" is a count, not a guess) including the
# process group it ran in. FAKE_HEADROOM_MODE=die models a proxy that exits at once.
FAKE_BIN="$TMP/fake-headroom"
cat > "$FAKE_BIN" <<EOSH
#!/usr/bin/env bash
case "\${1:-}" in
  proxy)
    port=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--port" ] && port="\$a"; prev="\$a"; done
    printf 'start port=%s pgid=%s\n' "\$port" "\$(ps -o pgid= -p \$\$ | tr -d ' ')" >> "\${FAKE_START_LOG:?}"
    [ "\${FAKE_HEADROOM_MODE:-}" = die ] && exit 3
    exec python3 "$SERVER_PY" "\$port" "\$@"
    ;;
  --version) echo "headroom, version FAKE" ;;
  *) exit 2 ;;
esac
EOSH
chmod +x "$FAKE_BIN"

# launchctl RECORDER, standing in for launchd. `bootstrap`/`kickstart` really start the
# fake proxy (as launchd would) and log it to $LC_SPAWN_LOG, so "launchd started it" and
# "the chain spawned it itself" are two different counters. `print` answers from a flag
# file; FAKE_LAUNCHCTL_MODE=fail makes every verb refuse.
LC_SHIM="$TMP/launchctl-recorder"
cat > "$LC_SHIM" <<EOSH
#!/usr/bin/env bash
echo "\$*" >> "\${LC_CALLS:?}"
[ "\${FAKE_LAUNCHCTL_MODE:-}" = fail ] && exit 1
spawn() {
  FAKE_START_LOG="\${LC_SPAWN_LOG:?}" nohup "$FAKE_BIN" proxy --host 127.0.0.1 --port "\${HEADROOM_PORT:?}" --lossless >/dev/null 2>&1 &
  echo \$! >> "$PIDS"
}
case "\$1" in
  print)     [ -f "\${LC_LOADED:?}" ]; exit \$? ;;
  bootstrap) : > "\${LC_LOADED:?}"; spawn ;;
  kickstart) spawn ;;
  bootout)   rm -f "\${LC_LOADED:?}" ;;
esac
exit 0
EOSH
chmod +x "$LC_SHIM"

MODSTATE="$TMP/modstate"; mkdir -p "$MODSTATE/headroom"; printf '{}\n' > "$MODSTATE/headroom/receipt.json"

# setup_env <tag> <port> — the per-case environment, run INSIDE each case's subshell.
setup_env() {
  export HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE"
  export HOME="$TMP/home-$1"; mkdir -p "$HOME"
  export HEIMDALL_HOME="$HOME/.heimdall" HEADROOM_PORT="$2"
  export FAKE_START_LOG="$TMP/start-$1.log" LC_CALLS="$TMP/lc-$1.calls" LC_SPAWN_LOG="$TMP/lcspawn-$1.log"
  export LC_LOADED="$TMP/lc-$1.loaded"
  export HMD_HEADROOM_READY_POLLS=8
  # ALWAYS the recorder + a throwaway LaunchAgents dir: no case can reach real launchd.
  export LAUNCHCTL="$LC_SHIM" HEIMDALL_LAUNCH_AGENTS_DIR="$TMP/la-$1"
  unset ANTHROPIC_BASE_URL HMD_HEADROOM_DISABLE HMD_MODULE_OPTOUT HEADROOM_LOSSLESS FAKE_HEADROOM_MODE FAKE_LAUNCHCTL_MODE
  : > "$FAKE_START_LOG"; : > "$LC_CALLS"; : > "$LC_SPAWN_LOG"
}

BASE=$((20000 + ($$ % 4000) * 2))
NEXT=0
# Sets $P. NOT a command substitution: a $(...) call would increment NEXT in a subshell and
# hand every case the same port, which makes the cases interfere with one another.
nextport() { NEXT=$((NEXT+1)); P=$((BASE + NEXT)); }

serve() { # serve <port> [extra args...] — a live fake proxy, tracked for cleanup
  local port="$1"; shift
  python3 "$SERVER_PY" "$port" "$@" >/dev/null 2>&1 &
  echo $! >> "$PIDS"
  local i=0
  while [ "$i" -lt 40 ]; do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/livez" && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
listening() { # listening <port> — poll (<=6s) until something LISTENs there; python start-up time varies
  local i=0
  while [ "$i" -lt 60 ]; do lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
blackhole() { # blackhole <port> — accepts into the backlog, never answers
  python3 "$BLACKHOLE_PY" "$1" >/dev/null 2>&1 &
  echo $! >> "$PIDS"
  listening "$1"
}

echo
echo "0 — the chain parses"
bash -n "$CHAIN" && ok "bin/lib/hmd-headroom-chain.sh parses (bash -n)" || bad "syntax error in the chain lib"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "1 — dead port -> the start path runs ONCE and the proxy is detached into its own process group"
nextport; OUT="$TMP/out1"; ERR="$TMP/err1"
(
  . "$CHAIN"; setup_env c1 "$P"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nbase=%s\ndown=%s\nwarned=%s\n' "$rc" "$HMD_HEADROOM_BASE_URL" "${HMD_HEADROOM_DOWN:-}" "${HMD_HEADROOM_WARNED:-}" > "$OUT"
)
grep -q '^rc=0$' "$OUT" && ok "1a chain returns 0 when it can bring the proxy up" || bad "1a chain did not route after a start" "$(cat "$OUT" "$ERR" 2>/dev/null)"
grep -q "^base=http://127.0.0.1:$P\$" "$OUT" && ok "1b base URL points at the proxy it started" || bad "1b wrong base URL" "$(cat "$OUT")"
[ "$(lines "$TMP/start-c1.log")" = 1 ] && ok "1c the start path ran exactly once" || bad "1c start count != 1" "$(cat "$TMP/start-c1.log")"
[ ! -s "$ERR" ] && ok "1d no warning on a successful start" || bad "1d unexpected stderr on success" "$(cat "$ERR")"
[ ! -s "$TMP/lc-c1.calls" ] && ok "1e launchctl untouched when supervision was never opted into" || bad "1e launchctl was called without opt-in" "$(cat "$TMP/lc-c1.calls")"
PG="$(sed -n 's/.*pgid=\([0-9]*\).*/\1/p' "$TMP/start-c1.log" | head -1)"
MYPG="$(ps -o pgid= -p $$ | tr -d ' ')"
PIDREC="$(cat "$TMP/home-c1/.heimdall/headroom/proxy.pid" 2>/dev/null)"
if [ -n "$PG" ] && [ "$PG" != "$MYPG" ] && [ "$PG" = "$PIDREC" ]; then
  ok "1f the proxy leads its OWN process group (a terminal's ^C/SIGHUP to the launching session cannot reach it)"
else
  bad "1f the proxy shares the launching session's process group" "proxy pgid=$PG launcher pgid=$MYPG proxy.pid=$PIDREC"
fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "2 — start path fails -> decline, ONE stderr warning, bounded wait, never a dead URL"
nextport; OUT="$TMP/out2"; ERR="$TMP/err2"
T0=$(now)
(
  . "$CHAIN"; setup_env c2 "$P"; export FAKE_HEADROOM_MODE=die
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nbase=%s\ndown=%s\nwarned=%s\nurl=%s\nwhy=%s\n' "$rc" "$HMD_HEADROOM_BASE_URL" "${HMD_HEADROOM_DOWN:-}" "${HMD_HEADROOM_WARNED:-}" "${ANTHROPIC_BASE_URL:-unset}" "$HMD_HEADROOM_WHY" > "$OUT"
)
EL=$(secs "$T0" "$(now)")
grep -q '^rc=1$' "$OUT" && ok "2a chain declines when the proxy never comes up" || bad "2a chain did not decline" "$(cat "$OUT")"
grep -q '^base=$' "$OUT" && ok "2b no base URL is offered" || bad "2b a base URL was offered for a dead proxy" "$(cat "$OUT")"
grep -q '^url=unset$' "$OUT" && ok "2c ANTHROPIC_BASE_URL stays unset (direct)" || bad "2c ANTHROPIC_BASE_URL was set" "$(cat "$OUT")"
[ "$(lines "$TMP/start-c2.log")" = 1 ] && ok "2d the restart was attempted exactly once" || bad "2d restart attempts != 1" "$(cat "$TMP/start-c2.log")"
grep -q '^down=1$' "$OUT" && grep -q '^warned=1$' "$OUT" && ok "2e HMD_HEADROOM_DOWN / HMD_HEADROOM_WARNED are set" || bad "2e down/warned flags not set" "$(cat "$OUT")"
if [ "$(lines "$ERR")" = 1 ] && grep -q "headroom not routing" "$ERR" && grep -q "running direct" "$ERR"; then
  ok "2f exactly ONE stderr line: 'headroom not routing ... running direct'"
else
  bad "2f expected a single 'headroom not routing ... running direct' stderr line" "$(cat "$ERR")"
fi
lt "$EL" 6 && ok "2g the wait is bounded (${EL}s with 8 readiness polls)" || bad "2g wait not bounded: ${EL}s"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "3 — an inherited ANTHROPIC_BASE_URL that is OUR dead proxy is dropped, in one line"
nextport; OUT="$TMP/out3"; ERR="$TMP/err3"
(
  . "$CHAIN"; setup_env c3 "$P"; export FAKE_HEADROOM_MODE=die
  export ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nurl=%s\n' "$rc" "${ANTHROPIC_BASE_URL:-unset}" > "$OUT"
)
grep -q '^url=unset$' "$OUT" && ok "3a the stale URL is unset: the tool launches DIRECT" || bad "3a a dead ANTHROPIC_BASE_URL survived the decline" "$(cat "$OUT")"
if [ "$(lines "$ERR")" = 1 ] && grep -q "dropped the inherited ANTHROPIC_BASE_URL" "$ERR"; then
  ok "3b one stderr line says the inherited URL was dropped"
else
  bad "3b expected one 'dropped the inherited ANTHROPIC_BASE_URL' line" "$(cat "$ERR")"
fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "4 — an operator's OWN ANTHROPIC_BASE_URL is never dropped"
nextport; OUT="$TMP/out4"; ERR="$TMP/err4"
(
  . "$CHAIN"; setup_env c4 "$P"; export FAKE_HEADROOM_MODE=die
  export ANTHROPIC_BASE_URL="https://example.invalid"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nurl=%s\n' "$rc" "${ANTHROPIC_BASE_URL:-unset}" > "$OUT"
)
grep -q '^url=https://example.invalid$' "$OUT" && ok "4a the operator's URL is untouched" || bad "4a the operator's ANTHROPIC_BASE_URL was clobbered" "$(cat "$OUT")"
! grep -q "dropped" "$ERR" && ok "4b nothing claims a drop that did not happen" || bad "4b warning claims a drop" "$(cat "$ERR")"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "5 — a hung listener (accepts, never answers) declines inside ~1s and is NOT built over"
nextport; OUT="$TMP/out5"; ERR="$TMP/err5"
blackhole "$P"
T0=$(now)
(
  . "$CHAIN"; setup_env c5 "$P"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\ndown=%s\nwhy=%s\n' "$rc" "${HMD_HEADROOM_DOWN:-}" "$HMD_HEADROOM_WHY" > "$OUT"
)
EL=$(secs "$T0" "$(now)")
grep -q '^rc=1$' "$OUT" && ok "5a chain declines" || bad "5a chain did not decline" "$(cat "$OUT")"
lt "$EL" 2.5 && ok "5b the launch is never held by a hung listener (${EL}s < 2.5s)" || bad "5b a hung listener blocked the launch for ${EL}s"
grep -q '^why=.*did not answer' "$OUT" && ok "5c the reason names the hung listener" || bad "5c reason does not say the listener is not answering" "$(cat "$OUT")"
[ "$(lines "$TMP/start-c5.log")" = 0 ] && ok "5d no second proxy was started on top of it" || bad "5d a proxy was started over a live listener" "$(cat "$TMP/start-c5.log")"
[ "$(lines "$ERR")" = 1 ] && grep -q "headroom not routing" "$ERR" && ok "5e one stderr warning" || bad "5e expected one stderr warning" "$(cat "$ERR")"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "6 — a healthy proxy is reused untouched (no start, no warning)"
nextport; OUT="$TMP/out6"; ERR="$TMP/err6"
serve "$P" --lossless
(
  . "$CHAIN"; setup_env c6 "$P"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nbase=%s\nwhy=%s\n' "$rc" "$HMD_HEADROOM_BASE_URL" "$HMD_HEADROOM_WHY" > "$OUT"
)
grep -q '^rc=0$' "$OUT" && grep -q "^base=http://127.0.0.1:$P\$" "$OUT" && ok "6a a live proxy is routed into" || bad "6a live proxy not reused" "$(cat "$OUT" "$ERR")"
[ "$(lines "$TMP/start-c6.log")" = 0 ] && [ ! -s "$ERR" ] && ok "6b nothing started, nothing warned" || bad "6b reuse started something or warned" "$(cat "$TMP/start-c6.log" "$ERR" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "7 — hmd_headroom_port_state: dead / silent / answering, each inside its budget"
nextport; PD=$P; nextport; PS=$P; nextport; PA=$P
blackhole "$PS"; serve "$PA" --lossless
(
  . "$CHAIN"
  t0=$(now); d="$(hmd_headroom_port_state "$PD")"; td=$(secs "$t0" "$(now)")
  t0=$(now); s="$(hmd_headroom_port_state "$PS")"; ts=$(secs "$t0" "$(now)")
  a="$(hmd_headroom_port_state "$PA")"
  printf 'd=%s td=%s s=%s ts=%s a=%s\n' "$d" "$td" "$s" "$ts" "$a"
) > "$TMP/out7" 2>&1
read -r line < "$TMP/out7"
d="$(printf '%s' "$line" | sed -n 's/.*d=\([a-z]*\) .*/\1/p')"; td="$(printf '%s' "$line" | sed -n 's/.*td=\([0-9.]*\) .*/\1/p')"
s="$(printf '%s' "$line" | sed -n 's/.* s=\([a-z]*\) .*/\1/p')"; ts="$(printf '%s' "$line" | sed -n 's/.*ts=\([0-9.]*\) .*/\1/p')"
a="$(printf '%s' "$line" | sed -n 's/.* a=\([a-z]*\)$/\1/p')"
[ "$d" = dead ] && lt "${td:-9}" 0.8 && ok "7a refused connection -> dead, instantly (${td}s)" || bad "7a dead port misread" "$line"
[ "$s" = silent ] && lt "${ts:-9}" 1.6 && ok "7b accepts-but-silent -> silent, within the 1s budget (${ts}s)" || bad "7b hung listener misread or slow" "$line"
[ "$a" = answering ] && ok "7c a live listener -> answering" || bad "7c live proxy misread" "$line"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "8 — a stranger that answers HTTP is refused, and no proxy is started over it"
nextport; OUT="$TMP/out8"; ERR="$TMP/err8"
FAKE_SERVICE=not-headroom serve "$P"
(
  . "$CHAIN"; setup_env c8 "$P"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nwhy=%s\n' "$rc" "$HMD_HEADROOM_WHY" > "$OUT"
)
grep -q '^rc=1$' "$OUT" && grep -q 'not a Headroom proxy' "$OUT" && ok "8a refused, reason says it is not a Headroom proxy" || bad "8a stranger not refused" "$(cat "$OUT")"
[ "$(lines "$TMP/start-c8.log")" = 0 ] && ok "8b nothing started over the stranger" || bad "8b started a proxy over a stranger" "$(cat "$TMP/start-c8.log")"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "9 — opted-in launchd supervision: the chain asks launchd and never spawns beside it"
LABEL9="dev.runheimdall.headroom.test"
UIDN="$(id -u)"

# 9a: plist present, agent not loaded -> bootstrap (which starts it), no direct spawn
nextport; OUT="$TMP/out9a"; ERR="$TMP/err9a"
(
  . "$CHAIN"; setup_env c9a "$P"; export HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL9"
  mkdir -p "$HEIMDALL_LAUNCH_AGENTS_DIR"; : > "$HEIMDALL_LAUNCH_AGENTS_DIR/$LABEL9.plist"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\nwhy=%s\nsupervised=%s\n' "$rc" "$HMD_HEADROOM_WHY" "$(hmd_headroom_supervised && echo yes || echo no)" > "$OUT"
)
grep -q '^rc=0$' "$OUT" && ok "9a chain routes once launchd has started the proxy" || bad "9a supervised start failed" "$(cat "$OUT" "$ERR" "$TMP/lc-c9a.calls" 2>/dev/null)"
grep -q "^bootstrap gui/$UIDN $TMP/la-c9a/$LABEL9.plist\$" "$TMP/lc-c9a.calls" && ok "9b not loaded -> launchctl bootstrap gui/<uid> <plist>" || bad "9b no bootstrap recorded" "$(cat "$TMP/lc-c9a.calls")"
[ "$(lines "$TMP/start-c9a.log")" = 0 ] && [ "$(lines "$TMP/lcspawn-c9a.log")" = 1 ] && ok "9c exactly one proxy, started by launchd — the chain did NOT also spawn one" || bad "9c double start or no start" "chain-spawns=$(lines "$TMP/start-c9a.log") launchd-spawns=$(lines "$TMP/lcspawn-c9a.log")"
grep -q '^why=.*launchd' "$OUT" && ok "9d the reason says launchd started it" || bad "9d reason does not mention launchd" "$(cat "$OUT")"
grep -q '^supervised=yes$' "$OUT" && ok "9e hmd_headroom_supervised follows the plist (the opt-in marker)" || bad "9e supervised not detected" "$(cat "$OUT")"

# 9f: already loaded -> kickstart only, never a second bootstrap
nextport; OUT="$TMP/out9f"; ERR="$TMP/err9f"
(
  . "$CHAIN"; setup_env c9f "$P"; export HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL9"
  mkdir -p "$HEIMDALL_LAUNCH_AGENTS_DIR"; : > "$HEIMDALL_LAUNCH_AGENTS_DIR/$LABEL9.plist"; : > "$LC_LOADED"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\n' "$rc" > "$OUT"
)
grep -q "^kickstart gui/$UIDN/$LABEL9\$" "$TMP/lc-c9f.calls" && ! grep -q '^bootstrap' "$TMP/lc-c9f.calls" && ok "9f loaded -> launchctl kickstart gui/<uid>/<label>, no re-bootstrap" || bad "9f wrong verb for a loaded agent" "$(cat "$TMP/lc-c9f.calls")"

# 9g: launchctl refuses -> fall back to the direct spawn, still fail-safe
nextport; OUT="$TMP/out9g"; ERR="$TMP/err9g"
(
  . "$CHAIN"; setup_env c9g "$P"; export HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL9" FAKE_LAUNCHCTL_MODE=fail
  mkdir -p "$HEIMDALL_LAUNCH_AGENTS_DIR"; : > "$HEIMDALL_LAUNCH_AGENTS_DIR/$LABEL9.plist"
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'rc=%s\n' "$rc" > "$OUT"
)
grep -q '^rc=0$' "$OUT" && [ "$(lines "$TMP/start-c9g.log")" = 1 ] && ok "9g launchctl failing -> the direct spawn still brings the proxy up (exactly once)" || bad "9g no fallback when launchd refuses" "$(cat "$OUT" "$ERR" "$TMP/start-c9g.log" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "10 — a synthetic HOME can never reach the REAL launchd, even with a plist present"
nextport; OUT="$TMP/out10"; ERR="$TMP/err10"
mkdir -p "$TMP/pathshim"
cat > "$TMP/pathshim/launchctl" <<EOSH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/real-launchctl.calls"
exit 0
EOSH
chmod +x "$TMP/pathshim/launchctl"; : > "$TMP/real-launchctl.calls"
(
  . "$CHAIN"; setup_env c10 "$P"; export HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL9"
  unset LAUNCHCTL                      # the plain `launchctl` on PATH — i.e. the REAL one on a real machine
  export PATH="$TMP/pathshim:$PATH"
  mkdir -p "$HEIMDALL_LAUNCH_AGENTS_DIR"; : > "$HEIMDALL_LAUNCH_AGENTS_DIR/$LABEL9.plist"
  hmd_headroom_kick; krc=$?
  hmd_headroom_chain "$TMP" 2>"$ERR"; rc=$?
  printf 'krc=%s\nrc=%s\n' "$krc" "$rc" > "$OUT"
)
grep -q '^krc=1$' "$OUT" && ok "10a hmd_headroom_kick refuses (rc 1) when HOME is not the real passwd home" || bad "10a kick did not refuse" "$(cat "$OUT")"
[ ! -s "$TMP/real-launchctl.calls" ] && ok "10b the real launchctl was never invoked" || bad "10b the real launchctl was invoked from a synthetic HOME" "$(cat "$TMP/real-launchctl.calls")"
grep -q '^rc=0$' "$OUT" && [ "$(lines "$TMP/start-c10.log")" = 1 ] && ok "10c the chain falls back to the direct spawn instead" || bad "10c no fallback" "$(cat "$OUT" "$ERR" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "11 — hmd_headroom_drop_if_dead: the shim re-entry arm's cheap, start-nothing check"
nextport; PD=$P; nextport; PL=$P
serve "$PL" --lossless
OUT="$TMP/out11"
(
  . "$CHAIN"; setup_env c11 "$PD"
  export ANTHROPIC_BASE_URL="http://127.0.0.1:$PD"
  hmd_headroom_drop_if_dead 2>"$TMP/err11a"; printf 'dead_url=%s\n' "${ANTHROPIC_BASE_URL:-unset}" > "$OUT"
  setup_env c11b "$PL"; export ANTHROPIC_BASE_URL="http://127.0.0.1:$PL"
  hmd_headroom_drop_if_dead 2>"$TMP/err11b"; printf 'live_url=%s\n' "${ANTHROPIC_BASE_URL:-unset}" >> "$OUT"
  setup_env c11c "$PD"; export ANTHROPIC_BASE_URL="https://example.invalid"
  hmd_headroom_drop_if_dead 2>"$TMP/err11c"; printf 'own_url=%s\n' "${ANTHROPIC_BASE_URL:-unset}" >> "$OUT"
)
grep -q '^dead_url=unset$' "$OUT" && [ "$(lines "$TMP/err11a")" = 1 ] && ok "11a dead proxy URL dropped, one stderr line" || bad "11a dead URL not dropped" "$(cat "$OUT" "$TMP/err11a")"
grep -q "^live_url=http://127.0.0.1:$PL\$" "$OUT" && [ ! -s "$TMP/err11b" ] && ok "11b live proxy URL left alone, silent" || bad "11b live URL disturbed" "$(cat "$OUT" "$TMP/err11b")"
grep -q '^own_url=https://example.invalid$' "$OUT" && [ ! -s "$TMP/err11c" ] && ok "11c operator URL left alone, silent" || bad "11c operator URL disturbed" "$(cat "$OUT" "$TMP/err11c")"
[ "$(lines "$TMP/start-c11.log")" = 0 ] && ok "11d it never starts anything" || bad "11d the cheap check started a proxy"

echo
echo "headroom-failsafe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
