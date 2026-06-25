#!/usr/bin/env bash
# cp-diag.test.sh — the Cloud-Run server-runtime slice: liveness/readiness probes
# (cp_diag) + the $PORT/0.0.0.0 bind in cp_server.serve(). Health endpoints are
# UNAUTHENTICATED (Cloud Run probes do not sign) and content-free (status + version
# only, NEVER secrets or sensitive state). This proves:
#   • /healthz is a cheap unsigned 200 carrying only {status, version}.
#   • /readyz reports booted-ness (routes registered + stores reachable): 200 ready
#     after boot(), 503 when not safe to serve.
#   • the diag routes register into the §10 seam (idempotent, ON TOP of the 15).
#   • serve() reads host/port from env PORT (0.0.0.0:$PORT) when not given explicitly,
#     and an explicit port still wins (the existing harness passes one).
#   • no key material in any health body.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib"
PY="${PYTHON:-python3}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/home"
mkdir -p "$HEIMDALL_HOME"

echo "cp-diag — Cloud Run server-runtime slice"

# ── A. liveness is a cheap unsigned 200 with ONLY {status, version} ────────────
A="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_diag
r = cp_diag.liveness()
assert r.status == 200, r.status
body = r.body
assert set(body.keys()) <= {"status", "version"}, body
assert body["status"] == "ok", body
assert body["version"], body
print(json.dumps(body))
PYEOF
)"
[ -n "$A" ] && ok "A liveness() -> 200, body keys are only {status,version}: $A" \
            || bad "A liveness() did not return a clean 200 body"

# ── B. readiness is 200 ready after boot, LOCAL backend (default) inits cleanly ──
# Default backend is "local": get_backend() + the cheap read-only probe both succeed, so
# backend_ready is True and /readyz is 200. This is the happy path the incident broke for
# firestore but which must stay green for the shipped local-disk dev/test path.
B="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_boot, cp_diag
cp_boot.boot(home=os.environ["HEIMDALL_HOME"], start_tick=False, resume=False)
r = cp_diag.readiness(home=os.environ["HEIMDALL_HOME"])
assert r.status == 200, (r.status, r.body)
b = r.body
assert b["status"] == "ready", b
assert b["booted"] is True, b
assert b["stores_reachable"] is True, b
assert b["routes_registered"] >= 15, b
assert b["backend"] == "local", b           # default selected backend
assert b["backend_ready"] is True, b        # the SELECTED backend actually initialized
assert "reason" not in b, b                 # no reason code on a ready body
assert b["version"], b
# content-free: only status booleans + counts + the bare backend NAME + version. No key,
# token, path, or exception text — a fixed, secret-free key set.
assert set(b.keys()) == {
    "status","booted","routes_registered","stores_reachable",
    "backend","backend_ready","version"}, b
print(json.dumps(b))
PYEOF
)"
[ -n "$B" ] && ok "B readiness() after boot, LOCAL backend -> 200 ready (backend_ready true): $B" \
            || bad "B readiness() did not report ready after boot"

# ── C. readiness is 503 when NOT booted (no routes registered) ─────────────────
C="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
# fresh interpreter: cp_boot.boot is NOT called -> seam is empty -> not ready.
import cp_diag
r = cp_diag.readiness(home=os.environ["HEIMDALL_HOME"])
assert r.status == 503, (r.status, r.body)
assert r.body["status"] == "not_ready", r.body
assert r.body["booted"] is False, r.body
print(json.dumps(r.body))
PYEOF
)"
[ -n "$C" ] && ok "C readiness() before boot -> 503 not_ready: $C" \
            || bad "C readiness() did not 503 when unbooted"

# ── G. THE INCIDENT: SELECTED backend cannot initialize -> /readyz 503, traffic held ─
# Reproduces the production miss: HEIMDALL_STATE_BACKEND=firestore but the firestore
# client lib cannot import (missing dep -> BackendUnavailable from _build_client). Before
# this fix /readyz returned 200 (it only checked the local audit dir, which was writable)
# and Cloud Run routed live traffic to a broken instance. Now readiness probes the
# SELECTED backend's init and MUST 503 with a reason code + the backend name, and the body
# MUST carry NO secret/path/exception text. The missing-dep import is simulated with a
# meta_path blocker so the test is hermetic (does not depend on whether the lib is
# installed). HEIMDALL_CP_PKI_KEY is supplied so boot() succeeds in the firestore/cloud
# profile (exactly the incident: PKI key present, backend dep missing) and we isolate the
# BACKEND signal — i.e. it is the backend probe, not boot, that flips readiness to 503.
G="$(LIB="$LIB" HEIMDALL_STATE_BACKEND=firestore \
     HEIMDALL_CP_PKI_KEY="$("$PY" -c 'import base64;print(base64.b64encode(b"0"*32).decode())')" \
     "$PY" - <<'PYEOF'
import os, sys, json, importlib.abc
sys.path.insert(0, os.environ["LIB"])
# Simulate the missing google-cloud-firestore dep: block its lazy import so the
# FirestoreBackend client build raises BackendUnavailable, exactly as in the incident.
class _Block(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name == "google.cloud.firestore" or name.startswith("google.cloud.firestore."):
            raise ImportError("simulated missing google-cloud-firestore dep")
        return None
sys.meta_path.insert(0, _Block())
import cp_boot, cp_diag
# boot succeeds (PKI key present); the backend dep is what is missing.
cp_boot.boot(home=os.environ["HEIMDALL_HOME"], start_tick=False, resume=False)
r = cp_diag.readiness(home=os.environ["HEIMDALL_HOME"])
assert r.status == 503, (r.status, r.body)
b = r.body
assert b["status"] == "not_ready", b
assert b["booted"] is True, b               # boot DID run -> isolates the backend signal
assert b["backend"] == "firestore", b       # names WHICH backend failed (bare token)
assert b["backend_ready"] is False, b
assert b["reason"] == "backend_unavailable", b   # a known backend-init failure raised
# NO secret/path/exception text anywhere in the body (content-free reason code only).
blob = json.dumps(b)
import re
assert not re.search(r"google\\.cloud|/[A-Za-z]+/|ImportError|Traceback|BEGIN|private|secret|/home/|/Users/", blob), b
print(blob)
PYEOF
)"
[ -n "$G" ] && ok "G INCIDENT firestore dep missing -> 503 backend_unavailable, no leak: $G" \
            || bad "G readiness did not 503 when the SELECTED backend could not init"

# ── H. a HUNG backend client (no fail-fast) -> 503 within the timeout, never hangs ─
# firestore.Client() can BLOCK on ADC/metadata lookups when creds are absent — it does
# not fail fast — so the readiness probe is timeout-bounded. We inject a fake backend
# whose init seam (_db) and read both sleep far past the timeout, and assert readiness
# RETURNS a 503 {reason:backend_init_failed} within a small wall-clock budget rather than
# hanging the handler (which would wedge Cloud Run's probe). Hermetic: no firestore lib,
# no network — pure monkeypatch of get_backend. os._exit at the end so the abandoned
# daemon probe thread cannot block the test interpreter's teardown.
H="$(LIB="$LIB" HEIMDALL_STATE_BACKEND=firestore "$PY" - <<'PYEOF'
import os, sys, json, time
sys.path.insert(0, os.environ["LIB"])
import cp_state, cp_diag
class _Hung:
    # init seam + read both block far past the readiness timeout.
    def _db(self): time.sleep(60)
    def read_lines(self, rel): time.sleep(60); return []
    # path() refused like a real non-filesystem backend (so _stores_reachable is N/A).
    def path(self, rel): raise cp_state.BackendUnavailable("no local path (fake firestore)")
cp_state.get_backend = lambda home=None, backend=None: _Hung()
t0 = time.time()
r = cp_diag.readiness(home=os.environ["HEIMDALL_HOME"])
dt = time.time() - t0
assert r.status == 503, (r.status, r.body)
assert r.body["backend"] == "firestore", r.body
assert r.body["backend_ready"] is False, r.body
assert r.body["reason"] == "backend_init_failed", r.body   # the timeout/hang variant
# the handler must return bounded (timeout ~3s) — a hung probe must NOT hang readiness.
assert dt < 5.0, "readiness hung %.1fs (timeout not enforced)" % dt
out = "%s dt=%.2fs" % (json.dumps(r.body), dt)
sys.stdout.write(out + "\n"); sys.stdout.flush()
os._exit(0)  # abandon the stuck daemon probe thread without blocking interpreter exit.
PYEOF
)"
[ -n "$H" ] && ok "H hung backend client -> 503 backend_init_failed within timeout: $H" \
            || bad "H readiness hung or did not 503 on a backend that never inits"

# ── D. diag routes register into the seam (idempotent, ON TOP of the 15) ────────
D="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_server, cp_boot, cp_diag
cp_boot.boot(home=os.environ["HEIMDALL_HOME"], start_tick=False, resume=False)
routes = set(cp_server.registered_routes())
assert ("GET", cp_diag.LIVENESS_PATH) in routes, routes
assert ("GET", cp_diag.READINESS_PATH) in routes, routes
n1 = len(cp_server.registered_routes())
# idempotent: a re-register does not multiply the keys.
cp_diag.register(cp_server, home=os.environ["HEIMDALL_HOME"])
n2 = len(cp_server.registered_routes())
assert n1 == n2, (n1, n2)
assert n1 >= 17, n1   # 15 seam + healthz + readyz
print(n1)
PYEOF
)"
[ -n "$D" ] && ok "D diag routes in the seam, idempotent ($D total routes >= 17)" \
            || bad "D diag routes not registered idempotently into the seam"

# ── E. serve() binds 0.0.0.0:$PORT from env when no explicit host/port given ────
E="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys, inspect
sys.path.insert(0, os.environ["LIB"])
import cp_server
sig = inspect.signature(cp_server.serve)
# host/port default to a sentinel so an explicit value wins and env fills the gap.
src = inspect.getsource(cp_server.serve)
assert "PORT" in src, "serve() must read env PORT"
assert "0.0.0.0" in src, "serve() must be able to bind 0.0.0.0"
# resolve the effective bind with no args + env PORT set, WITHOUT opening a socket.
host, port = cp_server.resolve_bind(host=None, port=None, env={"PORT": "5599"})
assert host == "0.0.0.0", host
assert port == 5599, port
# explicit wins over env.
host2, port2 = cp_server.resolve_bind(host="127.0.0.1", port=8787, env={"PORT":"5599"})
assert host2 == "127.0.0.1" and port2 == 8787, (host2, port2)
# default port when neither given nor in env -> 8080 (Cloud Run default).
host3, port3 = cp_server.resolve_bind(host=None, port=None, env={})
assert host3 == "0.0.0.0" and port3 == 8080, (host3, port3)
print("%s:%d" % (host, port))
PYEOF
)"
[ -n "$E" ] && ok "E serve() resolves 0.0.0.0:\$PORT (env), explicit wins, default 8080: $E" \
            || bad "E serve() does not resolve the Cloud Run bind correctly"

# ── F. a LIVE server answers /healthz + /readyz UNSIGNED, no key material ───────
CLI="$ROOT/bin/heimdall-control-plane"
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
"$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$WORK/serve.out" 2>"$WORK/serve.err" &
SPID=$!
UP=""
for _ in $(seq 1 50); do
  if "$PY" -c "import socket,sys;s=socket.socket();s.settimeout(0.2)
try:
  s.connect(('127.0.0.1',$CP_PORT));s.close()
except OSError: sys.exit(1)" 2>/dev/null; then UP="1"; break; fi
  sleep 0.1
done
if [ -n "$UP" ]; then
  HZ="$("$PY" -c "import urllib.request,sys;print(urllib.request.urlopen('http://127.0.0.1:$CP_PORT/healthz',timeout=3).read().decode())")"
  RZ="$("$PY" -c "import urllib.request,sys;print(urllib.request.urlopen('http://127.0.0.1:$CP_PORT/readyz',timeout=3).read().decode())")"
  echo "$HZ" | grep -q '"status": "ok"' && ok "F /healthz UNSIGNED -> 200 status ok: $HZ" || bad "F /healthz body wrong: $HZ"
  echo "$RZ" | grep -q '"status": "ready"' && ok "F /readyz UNSIGNED -> 200 ready: $RZ" || bad "F /readyz body wrong: $RZ"
  # no key material in either body (b64 key blobs, PEM, 'private', 'secret', 'pubkey', 'signature', 'token').
  if echo "$HZ$RZ" | grep -Eiq 'private|secret|pubkey|signature|BEGIN|jobtok-|[A-Za-z0-9+/]{40,}='; then
    bad "F health bodies leaked secret-shaped material"
  else
    ok "F health bodies carry NO key material (status/version only)"
  fi
else
  bad "F live server did not come up"; cat "$WORK/serve.err" >&2
fi
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null

echo
echo "cp-diag: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
