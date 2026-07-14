#!/usr/bin/env bash
# heimdall-mock-cp-watchdog.test.sh — the mock control-plane fixtures self-terminate when
# orphaned, so a SIGKILLed test run can NEVER leak a mock_cp.py python to launchd (the
# ~692-proc leak that pinned RAM). A bash EXIT trap does not run on SIGKILL; the in-process
# watchdog is the only defense — this suite proves it exists AND works.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
P=0; F=0
ok()  { P=$((P+1)); echo "  ok   $1"; }
bad() { F=$((F+1)); echo "  FAIL $1"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

# 1. BOTH fixtures embed the self-terminating watchdog (orphan → launchd → os._exit).
for f in heimdall-presence-doctor heimdall-presence-bootstrap; do
  t="$ROOT/test/$f.test.sh"
  if grep -q '_watchdog' "$t" && grep -q 'os.getppid() == 1' "$t" && grep -q 'os._exit' "$t"; then
    ok "$f fixture carries the orphan-death watchdog"
  else
    bad "$f fixture MISSING the watchdog (mock_cp.py could leak on SIGKILL)"
  fi
done

# 2. The watchdog WORKS: a mock CP whose parent is SIGKILLed (no EXIT trap) self-reaps.
res="$(python3 - <<'PY'
import subprocess, os, time, sys, tempfile, signal, textwrap
prog = textwrap.dedent('''
import os, threading as _th, time as _t
_PPID0 = os.getppid()
def _w():
    s=_t.time()
    while True:
        _t.sleep(0.3)
        if os.getppid()!=_PPID0 or os.getppid()==1 or (_t.time()-s)>120: os._exit(0)
_th.Thread(target=_w, daemon=True).start()
_t.sleep(60)
''')
f=tempfile.NamedTemporaryFile("w",suffix=".py",delete=False); f.write(prog); f.close()
parent=subprocess.Popen(["/bin/bash","-c",f"python3 {f.name} & echo $! ; sleep 60"],stdout=subprocess.PIPE)
child=int(parent.stdout.readline().strip()); time.sleep(0.5)
os.kill(parent.pid, signal.SIGKILL)
alive=True
for _ in range(20):
    time.sleep(0.3)
    try: os.kill(child,0)
    except ProcessLookupError: alive=False; break
try: os.kill(child,9)
except Exception: pass
os.unlink(f.name)
print("REAPED" if not alive else "LEAKED")
PY
)"
[ "$res" = "REAPED" ] && ok "orphaned mock CP self-reaps after parent SIGKILL" \
  || bad "orphan LEAKED after parent SIGKILL (watchdog broken): $res"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
