#!/usr/bin/env bash
# hmd-ui-orphans.test.sh -- proves bin/lib/hmd_ui_procs.py (the reaper behind `heimdall-gc uis`, the
# connect-time "superseded ui" sweep and run-all.sh's end-of-sweep guard) stops exactly the servers
# it can POSITIVELY name as leftovers, and nothing else.
#
# THE LEAK THIS PINS (handoff 2026-10-11, measured on the operator's box): 14 `sentinels/hmd-ui.py`
# servers, ppid 1, --repo under $TMPDIR/tmp.*/desk.*/repo, up to two days old, each re-running
# hooks/identity/agents every poll interval; and two superseded real servers (:8711, :8712) left
# behind when `hmd app connect` moved on to :8713/:8714.
#
# Every process here is a REAL process (a python stand-in whose script path ends in
# /sentinels/hmd-ui.py or /heimdall-relay-client, so argv is what ps shows for the real ones),
# started detached (`( cmd & )` -> ppid 1) or as a child of this shell (ppid != 1) as the case needs.
# Nothing outside this suite's own temp dir is ever matched: HMD_UI_PROCS_SCRIPT_ROOT confines the
# reaper to the stand-ins, HMD_UI_PROCS_TMP_ROOTS names what counts as a temp dir here.
#
# Usage:  bash test/hmd-ui-orphans.test.sh
# bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HELPER="$REPO/bin/lib/hmd_ui_procs.py"
GC="$REPO/bin/heimdall-gc"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

PY="$(command -v python3 || true)"
for tool in "$PY" lsof ps; do
  [ -n "$tool" ] && command -v "$tool" >/dev/null 2>&1 && continue
  printf 'FATAL: required tool missing: %s\n' "${tool:-python3}" >&2; printf '\n0 passed, 1 failed\n'; exit 1
done

T="$(mktemp -d "${TMPDIR:-/tmp}/hmd-ui-orphans.XXXXXX")"
T="$(cd "$T" && pwd -P)"
FAKE="$T/fake"; TMPR="$T/tmp"; REAL="$T/real"
mkdir -p "$FAKE/sentinels" "$FAKE/bin" "$TMPR" "$REAL" "$T/h"
export HMD_UI_PROCS_SCRIPT_ROOT="$FAKE" HMD_UI_PROCS_TMP_ROOTS="$TMPR"

cleanup() {
  pkill -f "$FAKE/" 2>/dev/null || true
  sleep 0.2
  pkill -9 -f "$FAKE/" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$FAKE/sentinels/hmd-ui.py" <<'PYEOF'
import signal, socket, sys, time
args = sys.argv
port = int(args[args.index("--port") + 1]) if "--port" in args else 0
if "--ignore-term" in args:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
time.sleep(600)
PYEOF
cat > "$FAKE/bin/heimdall-relay-client" <<'PYEOF'
import time
time.sleep(600)
PYEOF
cat > "$FAKE/other.py" <<'PYEOF'
import time
time.sleep(600)
PYEOF

free_port() { "$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != "Z" ]
}
wait_listen() { local i=0; while ! { : <>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; }
listener_pid() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p\([0-9][0-9]*\)$/\1/p' | head -1; }
# mk_repo DIR -> a real directory with a .git marker
mk_repo() { mkdir -p "$1/.git"; }

# ui_orphan REPO PORT [flags...] -> the pid, started detached (ppid 1)
ui_orphan() {
  local repo="$1" port="$2"; shift 2
  ( "$PY" "$FAKE/sentinels/hmd-ui.py" --repo "$repo" --port "$port" --no-open "$@" >/dev/null 2>&1 & )
  wait_listen "$port"; listener_pid "$port"
}
# ui_child REPO PORT -> the pid, started as a child of this shell (ppid != 1)
ui_child() {
  "$PY" "$FAKE/sentinels/hmd-ui.py" --repo "$1" --port "$2" --no-open >/dev/null 2>&1 &
  UI_CHILD_PID=$!; wait_listen "$2"
}
# client_proc REPO UIPORT detached|child -> sets CLIENT_PID
client_proc() {
  if [ "$3" = detached ]; then
    ( "$PY" "$FAKE/bin/heimdall-relay-client" --relay https://relay.example --repo "$1" --ui-port "$2" >/dev/null 2>&1 & )
    sleep 0.4
    CLIENT_PID="$(pgrep -f "$FAKE/bin/heimdall-relay-client.*--ui-port $2( |\$)" | head -1)"
  else
    "$PY" "$FAKE/bin/heimdall-relay-client" --relay https://relay.example --repo "$1" --ui-port "$2" >/dev/null 2>&1 &
    CLIENT_PID=$!; sleep 0.4
  fi
}
reap() { "$PY" -I "$HELPER" reap "$@" 2>&1; }
supersede() { "$PY" -I "$HELPER" supersede "$@" 2>&1; }

echo "hmd-ui-orphans (bin/lib/hmd_ui_procs.py reap / supersede, heimdall-gc uis)"

if [ ! -f "$HELPER" ]; then
  bad "bin/lib/hmd_ui_procs.py is missing"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi

echo "-- 1. reap: orphaned servers on a temp or deleted repo, nothing else --"
mk_repo "$TMPR/leak1"; P_LEAK="$(free_port)"; LEAK_PID="$(ui_orphan "$TMPR/leak1" "$P_LEAK")"
mk_repo "$TMPR/gone"; P_GONE="$(free_port)"; GONE_PID="$(ui_orphan "$TMPR/gone" "$P_GONE")"; rm -rf "$TMPR/gone"
mk_repo "$REAL/proj"; P_REAL="$(free_port)"; REAL_PID="$(ui_orphan "$REAL/proj" "$P_REAL")"
mk_repo "$TMPR/owned"; P_OWNED="$(free_port)"; ui_child "$TMPR/owned" "$P_OWNED"; OWNED_PID="$UI_CHILD_PID"
mk_repo "$TMPR/attached"; P_ATT="$(free_port)"; ATT_PID="$(ui_orphan "$TMPR/attached" "$P_ATT")"
client_proc "$TMPR/attached" "$P_ATT" child; ATT_CLIENT="$CLIENT_PID"
mk_repo "$TMPR/lookalike"
( "$PY" "$FAKE/other.py" --repo "$TMPR/lookalike" --port 1 >/dev/null 2>&1 & ); sleep 0.3
LOOK_PID="$(pgrep -f "$FAKE/other.py" | head -1)"

OUT="$(reap --min-age 0 --dry-run)"
if printf '%s' "$OUT" | grep -q "would-reap ui pid=$LEAK_PID" && alive "$LEAK_PID"; then ok "dry-run names the orphaned temp-repo ui and kills nothing"; else bad "dry-run: $OUT"; fi

OUT="$(reap --min-age 0 --timeout 3)"
if ! alive "$LEAK_PID" && printf '%s' "$OUT" | grep -q "reaped ui pid=$LEAK_PID"; then ok "an orphaned (ppid 1) ui on a repo under a temp dir is reaped"; else bad "temp-repo ui survived: $OUT"; fi
if ! alive "$GONE_PID"; then ok "an orphaned ui whose --repo dir no longer exists is reaped"; else bad "missing-repo ui survived: $OUT"; fi
if alive "$REAL_PID"; then ok "an orphaned ui on a REAL repo (exists, not a temp dir) is never touched"; else bad "real-repo ui was killed"; fi
if alive "$OWNED_PID"; then ok "a ui that still has a live parent (ppid != 1) is never touched"; else bad "owned ui was killed"; fi
if alive "$ATT_PID" && alive "$ATT_CLIENT"; then ok "a ui a live relay client points at (--ui-port) is never touched"; else bad "attached ui or its client was killed: $OUT"; fi
if alive "$LOOK_PID"; then ok "a python with --repo but not running sentinels/hmd-ui.py is never touched"; else bad "lookalike was killed"; fi
kill "$ATT_CLIENT" 2>/dev/null; wait "$ATT_CLIENT" 2>/dev/null
kill "$OWNED_PID" 2>/dev/null; wait "$OWNED_PID" 2>/dev/null

echo "-- 2. reap: relay clients, the age floor, a TERM-proof server --"
mk_repo "$TMPR/leak2"; P2="$(free_port)"; U2="$(ui_orphan "$TMPR/leak2" "$P2")"
client_proc "$TMPR/leak2" "$P2" detached; C2="$CLIENT_PID"
OUT="$(reap --min-age 0 --timeout 3)"
if ! alive "$C2" && ! alive "$U2"; then ok "an orphaned relay client on a temp repo goes, and so does the ui it pointed at"; else bad "client/ui pair survived: $OUT"; fi
mk_repo "$TMPR/young"; P3="$(free_port)"; U3="$(ui_orphan "$TMPR/young" "$P3")"
OUT="$(reap --min-age 3600)"
if alive "$U3"; then ok "a ui younger than --min-age is kept (a test suite's own server is not a leak yet)"; else bad "young ui killed: $OUT"; fi
mk_repo "$TMPR/stubborn"; P4="$(free_port)"; U4="$(ui_orphan "$TMPR/stubborn" "$P4" --ignore-term)"
OUT="$(reap --min-age 0 --timeout 1)"
if ! alive "$U4" && printf '%s' "$OUT" | grep -q "reaped ui pid=$U4.*killed"; then ok "a server that ignores SIGTERM is stopped with SIGKILL after --timeout and reported as killed"; else bad "stubborn ui: $OUT"; fi
if ! alive "$U3"; then ok "(the young ui went with the min-age 0 sweep)"; else bad "young ui outlived a min-age 0 sweep"; fi

echo "-- 3. supersede: a same-repo leftover on ANOTHER port, nothing else --"
mk_repo "$REAL/mine"; mk_repo "$REAL/other"
PA="$(free_port)"; UA="$(ui_orphan "$REAL/mine" "$PA")"
PB="$(free_port)"; UB="$(ui_orphan "$REAL/mine" "$PB")"
PC="$(free_port)"; UC="$(ui_orphan "$REAL/other" "$PC")"
PD="$(free_port)"; UD="$(ui_orphan "$REAL/mine" "$PD" --allow-host funnel.example.ts.net)"
PE="$(free_port)"; UE="$(ui_orphan "$REAL/mine" "$PE")"; client_proc "$REAL/mine" "$PE" child; CE="$CLIENT_PID"
PF="$(free_port)"; ui_child "$REAL/mine" "$PF"; UF="$UI_CHILD_PID"
OUT="$(supersede --repo "$REAL/mine" --keep-port "$PA" --timeout 3)"
if ! alive "$UB" && printf '%s' "$OUT" | grep -q "reaped ui pid=$UB"; then ok "supersede stops a detached ui of the SAME repo on another port"; else bad "same-repo leftover survived: $OUT"; fi
if alive "$UA"; then ok "the ui on --keep-port (the one connect's own port logic adopts or replaces) is left to that logic"; else bad "keep-port ui was killed"; fi
if alive "$UC"; then ok "another repo's ui is never touched"; else bad "other repo's ui was killed"; fi
if alive "$UD"; then ok "a published (--allow-host) ui is never touched"; else bad "published ui was killed"; fi
if alive "$UE" && alive "$CE"; then ok "a same-repo ui a live relay client serves is never touched"; else bad "served ui was killed: $OUT"; fi
if alive "$UF"; then ok "a same-repo ui with a live parent (ppid != 1) is never touched"; else bad "owned same-repo ui was killed"; fi
kill "$CE" "$UF" 2>/dev/null; wait "$CE" "$UF" 2>/dev/null

echo "-- 4. heimdall-gc uis --"
mk_repo "$TMPR/gcleak"; PG="$(free_port)"; UG="$(ui_orphan "$TMPR/gcleak" "$PG")"
GOUT="$(HEIMDALL_HOME="$T/h" HMD_GC_UI_MIN_AGE_S=3600 bash "$GC" uis --home "$T/h" 2>&1)"
if alive "$UG"; then ok "heimdall-gc uis keeps an orphan younger than HMD_GC_UI_MIN_AGE_S"; else bad "gc killed a young orphan: $GOUT"; fi
GOUT="$(HEIMDALL_HOME="$T/h" HMD_GC_UI_MIN_AGE_S=0 bash "$GC" uis --home "$T/h" --dry-run 2>&1)"
if alive "$UG" && printf '%s' "$GOUT" | grep -q "pid=$UG"; then ok "heimdall-gc uis --dry-run reports the leak and kills nothing"; else bad "gc dry-run: $GOUT"; fi
GOUT="$(HEIMDALL_HOME="$T/h" HMD_GC_UI_MIN_AGE_S=0 bash "$GC" uis --home "$T/h" 2>&1)"
if ! alive "$UG" && printf '%s' "$GOUT" | grep -q "reaped ui pid=$UG"; then ok "heimdall-gc uis reaps the leak and says so"; else bad "gc run: $GOUT"; fi

echo "-- 5. this suite leaves nothing running --"
kill "$UA" "$UC" "$UD" "$UE" "$REAL_PID" "$ATT_PID" "$LOOK_PID" 2>/dev/null
sleep 0.4
LEFT="$(pgrep -f "$FAKE/" 2>/dev/null | tr '\n' ' ')"
if [ -z "${LEFT// /}" ]; then ok "no process of this suite is left running"; else bad "still running: $LEFT"; fi

printf '\nhmd-ui-orphans: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
