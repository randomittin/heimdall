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

# 1. BOTH fixtures embed the self-terminating watchdog. The guard keys on the TEST-SCRIPT
# pid (MOCK_GUARD_PID), not ppid==1: `URL="$(launch_mock)"` reparents the mock to launchd
# mid-run, so a ppid-based guard would kill a LIVE mock. Guard-pid liveness → os._exit(0)
# once the test script is gone (SIGKILLed run) → no mock_cp.py leak to launchd.
for f in heimdall-presence-doctor heimdall-presence-bootstrap; do
  t="$ROOT/test/$f.test.sh"
  if grep -q '_watchdog' "$t" && grep -q 'MOCK_GUARD_PID' "$t" && grep -q 'os._exit' "$t"; then
    ok "$f fixture carries the orphan-death watchdog"
  else
    bad "$f fixture MISSING the watchdog (mock_cp.py could leak on SIGKILL)"
  fi
done

# 2. The watchdog WORKS — modeling the SHIPPED guard: a mock keyed on MOCK_GUARD_PID
# (the test-script pid) self-reaps once that guard process is SIGKILLed (no EXIT trap runs).
res="$(python3 - <<'PY'
import subprocess, os, time, tempfile, signal, textwrap
prog = textwrap.dedent('''
import os, threading as _th, time as _t
_GUARD = int(os.environ.get("MOCK_GUARD_PID") or "0")
def _w():
    s=_t.time()
    while True:
        _t.sleep(0.3)
        dead=False
        try: os.kill(_GUARD, 0)
        except ProcessLookupError: dead=True
        except PermissionError: dead=False
        if dead or (_t.time()-s)>120: os._exit(0)
_th.Thread(target=_w, daemon=True).start()
_t.sleep(60)
''')
f=tempfile.NamedTemporaryFile("w",suffix=".py",delete=False); f.write(prog); f.close()
guard=subprocess.Popen(["/bin/sleep","60"])                       # stands in for the test script
mock=subprocess.Popen(["python3", f.name],
                      env={**os.environ, "MOCK_GUARD_PID": str(guard.pid)})
time.sleep(0.5)
os.kill(guard.pid, signal.SIGKILL); guard.wait()                  # SIGKILLed run: no EXIT trap
alive=True
for _ in range(20):
    time.sleep(0.3)
    if mock.poll() is not None: alive=False; break
try: mock.kill()
except Exception: pass
os.unlink(f.name)
print("REAPED" if not alive else "LEAKED")
PY
)"
[ "$res" = "REAPED" ] && ok "orphaned mock CP self-reaps after guard SIGKILL" \
  || bad "orphan LEAKED after guard SIGKILL (watchdog broken): $res"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
