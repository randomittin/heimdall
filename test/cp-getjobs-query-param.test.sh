#!/usr/bin/env bash
# cp-getjobs-query-param.test.sh — THE DEPLOYED-SHAPE GET /jobs READ-BACK GATE.
#
# THE INCIDENT THIS GATES (the 8th prod-only break). A signed GET /jobs read used to
# carry its job_id in the request BODY. Local test HTTP servers accept a GET-with-a-body,
# so every local gate (cp-wired, cp-getjobs-firestore) passed — but Google's GFE / Cloud
# Run ingress REJECTS a GET-with-a-body as MALFORMED (HTTP 400, Google's own error page,
# the request never reaches the container). So the verify's STEP-5 read-back never even hit
# the service in prod. The fix moves the job_id off the GET body onto a QUERY PARAM —
# GET /jobs?job_id=<id> with an EMPTY body — and signs the FULL path-with-query on BOTH
# the client and the server so the read stays authenticated + tamper-evident.
#
# THE COVERAGE GAP THIS CLOSES. NO gate asserted the GFE-SAFE shape: a signed
# GET /jobs?job_id=<id> with NO body, signed over the path-with-query, returning
# state=done over real signed HTTP on the firestore backend. cp-getjobs-firestore drives
# the BODY shape (the one GFE rejects); this gate drives the QUERY shape (the one GFE
# accepts) and proves it reads back done — the deployed read path, asserted.
#
# WHAT IT DOES (each step the EXACT GFE-safe prod read shape):
#   1. Select firestore mode (emulator if available, else the SAME faithful in-process
#      fake google.cloud.firestore the cp-durability / cp-getjobs-firestore gates use,
#      persisting to a JSON file so a SEPARATE serve subprocess and the signing client
#      share one durable store — the cross-process property a real Firestore has).
#   2. Register an OWNER signing identity (keys written THROUGH the firestore backend).
#   3. SEED a job to terminal state=done DIRECTLY in firestore via cp_jobstore.
#   4. BOOT the REAL `heimdall-control-plane serve` subprocess under firestore.
#   5. CARDINAL: a signed GET /jobs?job_id=<id> with an EMPTY body — signed over
#      canonical_message("GET","/jobs?job_id=<id>","") — returns HTTP 200 + job.state=done.
#      The signature VERIFIES (not 401), proving the client+server canonicalize the SAME
#      full path-with-query. NO body is sent (data=None) — the GFE-safe shape.
#   6. A body-based GET is NO LONGER RELIED UPON: the EMPTY-body query GET resolves the
#      job, so the read no longer depends on a GET body that GFE rejects.
#
# FALSIFIER (the heart of the auth-critical proof): sign the QUERY-LESS path ("/jobs")
# while SENDING the query path ("/jobs?job_id=<id>") -> the server verifies over the FULL
# path-with-query, so the canonical bytes DIFFER -> 401 bad_signature. The reverse mismatch
# (sign the full query path, send a query-less path) also 401s. Only when the client signs
# the EXACT path it transmits does the read verify. This proves the client and server MUST
# compute the IDENTICAL canonical message — change it on one side only and every signed
# request 401s.
#
# DISCIPLINE (mirrors cp-getjobs-firestore): isolated throwaway home + external store dir;
# the PKI seed lives ONLY in memory (passed to children by env, NEVER written to a tracked
# file, NEVER printed); the serve subprocess is REAPED on EXIT; ZERO real GCP / ZERO spend
# in fake mode. Exit 0 = the deployed-shape (query-param) HTTP read-back holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB REPO

for f in cp_server cp_boot cp_auth cp_jobstore cp_worker cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# crypto gate: this gate REQUIRES PKI (signed HTTP). Absent crypto -> SKIP cleanly.
if ! "$PY" -c "import sys,os; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the signed-HTTP gate needs PKI."
  echo "============================================================"
  printf "cp-getjobs-query-param: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  echo "============================================================"
  exit 0
fi

# The external-store dir (emulator data / fake JSON store + the fake package). Lives
# OUTSIDE the per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-getjobsqp-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"

SERVER_PID=""
EMU_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true
  rm -rf "$EXT"
}
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export WORK="$EXT"

# A dedicated root collection + project so this gate's store never collides with another.
export HEIMDALL_FIRESTORE_ROOT="getjobs_queryparam_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-getjobs-query-param-test"

# ── a TEST PKI seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
# A deterministic 32-byte Ed25519 seed: the deploy's HEIMDALL_CP_PKI_KEY shape, so the
# serve subprocess derives the SAME server identity the firestore cloud-profile requires.
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*7+3)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "cp-getjobs-query-param: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8772"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  for _ in $(seq 1 40); do
    grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null && break
    kill -0 "$EMU_PID" >/dev/null 2>&1 || break
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"
    MODE="emulator"
  else
    echo "cp-getjobs-query-param: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

# (2) FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
#     cp-getjobs-firestore gates use (a sitecustomize.py on PYTHONPATH registers it into
#     sys.modules before any import), persisting to a JSON file so a SEPARATE serve
#     subprocess and the signing client share one durable store. SHIPPED backend code is
#     real; only the external service is a double.
if [ -z "$MODE" ]; then
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses. PERSISTS the whole store to the JSON
# file named by HEIMDALL_FAKE_FS_STORE so a SEPARATE process (the serve subprocess) and
# the signing client share one durable store — the cross-process property a real
# Firestore has, which a memory-only fake would not.
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("fake firestore needs %s set to a path" % _STORE_ENV)
    return p


def _load():
    try:
        with open(_store_path(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(data):
    tmp = _store_path() + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None, database=None):
        self.project = project
        self._database = database

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path

    def document(self, doc_id):
        return DocRef(self._path, doc_id)

    def order_by(self, field):
        return _Query(self._path, order_field=field)

    def stream(self):
        return _Query(self._path).stream()


class _Query:
    def __init__(self, coll_path, order_field=None):
        self._coll_path = coll_path
        self._order_field = order_field

    def order_by(self, field):
        return _Query(self._coll_path, order_field=field)

    def stream(self):
        data = _load()
        coll = data.get("collections", {}).get(self._coll_path, {})
        items = []
        for doc_id, doc in coll.items():
            items.append(_Snapshot(self._coll_path, doc_id, doc.get("fields")))
        if self._order_field:
            items.sort(key=lambda s: (s.to_dict() or {}).get(self._order_field))
        else:
            items.sort(key=lambda s: s.id)
        return iter(items)


class DocRef:
    def __init__(self, coll_path, doc_id):
        self._coll_path = coll_path
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def collection(self, name):
        return CollectionRef("%s/%s/%s" % (self._coll_path, self._doc_id, name))

    def get(self, transaction=None):
        data = _load()
        doc = data.get("collections", {}).get(self._coll_path, {}).get(self._doc_id)
        fields = doc.get("fields") if doc else None
        return _Snapshot(self._coll_path, self._doc_id, fields)

    def set(self, fields, merge=False):
        data = _load()
        colls = data.setdefault("collections", {})
        coll = colls.setdefault(self._coll_path, {})
        doc = coll.setdefault(self._doc_id, {"fields": {}})
        if merge:
            cur = dict(doc.get("fields") or {})
            cur.update(fields)
            doc["fields"] = cur
        else:
            doc["fields"] = dict(fields)
        _save(data)


class _Snapshot:
    def __init__(self, coll_path, doc_id, fields):
        self._coll_path = coll_path
        self._doc_id = doc_id
        self._fields = fields

    @property
    def id(self):
        return self._doc_id

    @property
    def exists(self):
        return self._fields is not None

    def to_dict(self):
        return dict(self._fields) if self._fields is not None else None


class _Transaction:
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
  cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys

import _fake_firestore_impl as _impl

for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001 — synthesize a bare package when google is absent.
            import types
            _pkg = types.ModuleType(_name)
            _pkg.__path__ = []
            sys.modules[_name] = _pkg

sys.modules["google.cloud.firestore"] = _impl
setattr(sys.modules["google.cloud"], "firestore", _impl)
PYEOF
  export HEIMDALL_FAKE_FS_STORE="$EXT/fake_fs.json"
  : >"$EXT/fake_fs.json"
  export PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}"
fi

# Everything from here runs under the firestore backend (the deploy profile).
export HEIMDALL_STATE_BACKEND="firestore"

echo "============================================================"
echo "DEPLOYED-SHAPE GET /jobs?job_id= READ-BACK GATE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# #1 register an OWNER signing identity (keys written THROUGH the firestore backend).
# ──────────────────────────────────────────────────────────────────────────────
echo "#1 register a signing OWNER identity under firestore"
OWNER_HAID="haid:rj.owner"
"$CLI" identity --haid "$OWNER_HAID" --owner --home "$HEIMDALL_HOME" \
  >"$EXT/ident.json" 2>"$EXT/ident.err"
IDENT_OK="$("$PY" -c "import json;print(json.load(open('$EXT/ident.json')).get('ok'))" 2>/dev/null)"
[ "$IDENT_OK" = "True" ] \
  && ok "#1 owner identity registered via the REAL CLI auth path under firestore ($OWNER_HAID)" \
  || { bad "#1 CLI identity registration failed under firestore"; cat "$EXT/ident.err" >&2; }
OWNER_PRIV="$("$PY" -c "import json;print(json.load(open('$EXT/ident.json'))['private_key'])" 2>/dev/null)"

# ──────────────────────────────────────────────────────────────────────────────
# #2 SEED a job to terminal state=done DIRECTLY in firestore (the durable doc the
#    deployed read must resolve over the wire).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 seed a job -> state=done in firestore"
JOB_ID="$("$PY" - <<'PYEOF' 2>"$EXT/seed.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
jid = J.create_job("run-task-X", {"task_id": "getjobs-qp"},
                   instance_haid="haid:rj.owner", home=home)
J.transition(jid, J.STATE_RUNNING, home=home)
J.set_result(jid, {"status": "prepared"}, home=home)
J.transition(jid, J.STATE_DONE, progress=100, home=home)
folded = J.read_job(jid, home=home)
assert folded and folded.get("state") == "done", "seed did not fold to done: %r" % folded
print(jid)
PYEOF
)"
[ -n "$JOB_ID" ] && [ "$JOB_ID" != "None" ] \
  && ok "#2 a job was seeded to state=done in firestore ($JOB_ID)" \
  || { bad "#2 could not seed a done job in firestore"; cat "$EXT/seed.err" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# #3 BOOT the REAL `heimdall-control-plane serve` subprocess under firestore — so the
#    read crosses a real process boundary + a real HTTP socket (not an in-process call).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#3 boot the REAL serve subprocess under firestore"
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
HMD_CP_GUARD_PID=$$ "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/serve.out" 2>"$EXT/serve.err" &
SERVER_PID=$!
UP=""
for _ in $(seq 1 50); do
  if "$PY" -c "import socket,sys
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $CP_PORT)); s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then UP="1"; break; fi
  sleep 0.1
done
if [ -n "$UP" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
  ok "#3 the REAL wired server is live on 127.0.0.1:$CP_PORT under firestore (pid $SERVER_PID)"
else
  bad "#3 the firestore-mode wired server did not come up"
  cat "$EXT/serve.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #4 THE GFE-SAFE READ: a signed GET /jobs?job_id=<id> with an EMPTY body, signed over the
#    FULL path-with-query, returns HTTP 200 + state=done. The signature VERIFIES (not 401).
#    This is the DEPLOYED shape — the one Google's GFE accepts. [CARDINAL]
#
#    The probe ALSO drives the FALSIFIER: signing the query-LESS path while sending the
#    query path -> 401 (the canonical bytes differ; client+server MUST match).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 a signed GET /jobs?job_id= (EMPTY body, signed over path-with-query) -> state=done [CARDINAL]"
export CP_PORT CP_HAID="$OWNER_HAID" CP_PRIV="$OWNER_PRIV" JOB_ID
"$PY" - >"$EXT/probe.out" 2>"$EXT/probe.err" <<'PYEOF'
import json, os, sys, urllib.parse, urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K  # the SHIPPED Ed25519 signer — never re-implemented.

port = int(os.environ["CP_PORT"]); haid = os.environ["CP_HAID"]; priv = os.environ["CP_PRIV"]
job_id = os.environ["JOB_ID"]
query_path = "/jobs?" + urllib.parse.urlencode({"job_id": job_id})
base = "http://127.0.0.1:%d" % port


def call(send_path, sign_path, body):
    """Send `send_path` with `body`, signing canonical_message("GET", sign_path, body).
    Returns (status, parsed_body). data=None for an empty body -> a TRUE bodyless GET."""
    if isinstance(body, str):
        body = body.encode()
    data = body if body else None
    req = urllib.request.Request(base + send_path, data=data, method="GET")
    req.add_header("X-Heimdall-HAID", haid)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message("GET", sign_path, body)))
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return e.code, {}


out = {}

# (a) THE GFE-SAFE READ: send the query path with an EMPTY body, sign the SAME query path.
st, b = call(query_path, query_path, b"")
job = b.get("job") or {}
result = job.get("result")
out["safe_status"] = st
out["safe_state"] = job.get("state")
out["safe_result"] = (result.get("status") if isinstance(result, dict) else result)

# (b) FALSIFIER #1: send the query path but SIGN the query-LESS path ("/jobs"). The server
#     verifies over the FULL path-with-query, so the canonical bytes DIFFER -> 401.
st_m1, b_m1 = call(query_path, "/jobs", b"")
out["mismatch_queryless_sign_status"] = st_m1
out["mismatch_queryless_sign_error"] = b_m1.get("error")

# (c) FALSIFIER #2: send the query-LESS path but SIGN the full query path. Mirror mismatch:
#     the server verifies over "/jobs" (what it received) -> bytes differ -> 401 (or 404
#     no_such_job if the signature somehow matched, which it must NOT). Assert NOT 200-with-done.
st_m2, b_m2 = call("/jobs", query_path, b"")
out["mismatch_fullsign_status"] = st_m2
out["mismatch_fullsign_error"] = b_m2.get("error")
out["mismatch_fullsign_state"] = (b_m2.get("job") or {}).get("state")

sys.stdout.write(json.dumps(out))
PYEOF

field() { "$PY" -c "import json;print(json.load(open('$EXT/probe.out')).get('$1'))" 2>/dev/null; }

SAFE_STATUS="$(field safe_status)"
SAFE_STATE="$(field safe_state)"
SAFE_RESULT="$(field safe_result)"
M1_STATUS="$(field mismatch_queryless_sign_status)"
M1_ERROR="$(field mismatch_queryless_sign_error)"
M2_STATUS="$(field mismatch_fullsign_status)"
M2_STATE="$(field mismatch_fullsign_state)"

# (a) THE CARDINAL: the GFE-safe, EMPTY-body, query-param GET reads back done over the wire.
[ "$SAFE_STATUS" = "200" ] \
  && ok "#4 GET /jobs?job_id= (signed over path-with-query, EMPTY body) -> HTTP 200; the signature VERIFIES (not 401)" \
  || { bad "#4 the GFE-safe query GET did not return 200 (status=$SAFE_STATUS) — the signed path-with-query did not verify"; cat "$EXT/probe.err" >&2; }
[ "$SAFE_STATE" = "done" ] \
  && ok "#4 the endpoint returns job.state=done for the EMPTY-body query read — the deployed read path resolves the durable job [CARDINAL]" \
  || bad "#4 the endpoint returned state='$SAFE_STATE' (NOT done) for the query-param read"
[ "$SAFE_RESULT" = "prepared" ] \
  && ok "#4 the reconnecting client reads the job RESULT (status=prepared) over the EMPTY-body query GET" \
  || bad "#4 the job result was not surfaced over the query-param read (got '$SAFE_RESULT')"

# (b) NO BODY RELIED UPON: the read above sent an EMPTY body and still resolved the job —
#     so the read no longer depends on a GET body that GFE rejects (the 8th-break fix).
[ "$SAFE_STATE" = "done" ] && [ "$SAFE_STATUS" = "200" ] \
  && ok "#4 NO GET BODY RELIED UPON: an EMPTY-body GET /jobs?job_id= resolves the job — GFE-safe (no GET-with-a-body)" \
  || bad "#4 the EMPTY-body query GET failed to resolve the job — the read still depends on a GET body"

# (c) FALSIFIER #1: sign the query-LESS path while sending the query path -> 401 bad_signature.
[ "$M1_STATUS" = "401" ] \
  && ok "#4 FALSIFIER: signing the query-LESS path '/jobs' while SENDING '/jobs?job_id=' -> 401 ($M1_ERROR) — client+server MUST canonicalize the SAME path-with-query" \
  || bad "#4 FALSIFIER BROKEN: a query/sign mismatch returned $M1_STATUS, not 401 — the query is NOT covered by the signature (tamper-evidence lost)"

# (c2) FALSIFIER #2: sign the full query path while sending the query-LESS path -> NOT 200-with-done.
{ [ "$M2_STATUS" = "401" ] || [ "$M2_STATE" != "done" ]; } \
  && ok "#4 FALSIFIER: signing '/jobs?job_id=' while SENDING the query-LESS '/jobs' does NOT read done (status=$M2_STATUS, state=$M2_STATE) — the mirror mismatch is also refused" \
  || bad "#4 FALSIFIER BROKEN: a mirror mismatch (full-sign, query-less send) read state=done — the signature is not bound to the transmitted path"

# ──────────────────────────────────────────────────────────────────────────────
# FOOTER — reap the serve subprocess; the gate verdict.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "FOOTER — reap the serve subprocess + verdict"
if [ -n "$SERVER_PID" ]; then
  disown "$SERVER_PID" 2>/dev/null || true
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    bad "FOOTER the firestore-mode serve subprocess did not stop"
  else
    ok "FOOTER the serve subprocess was reaped (no orphan server)"
    SERVER_PID=""
  fi
fi

echo
echo "============================================================"
printf "cp-getjobs-query-param (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
