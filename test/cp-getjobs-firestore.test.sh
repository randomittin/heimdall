#!/usr/bin/env bash
# cp-getjobs-firestore.test.sh — THE FIRESTORE-MODE GET /jobs READ-BACK GATE.
#
# THE INCIDENT THIS GATES (production Cloud Run). A run-job EXECUTION wrote a terminal
# state=done line to the job's Firestore doc — and bin/heimdall-cp-inspect, reading the
# REAL rel->doc mapping over the live store, confirmed the doc EXISTS with state=done,
# foldable via cp_jobstore.fold_state. YET a fresh service instance's signed GET /jobs
# for that same job_id reported the job as not-done. That is an inspector-reads-done /
# endpoint-reads-None split.
#
# THE COVERAGE GAP THIS CLOSES. cp-wired drives GET /jobs over real signed HTTP, but on
# the LOCAL backend — where it works. NO gate drove GET /jobs over real HTTP on the
# FIRESTORE backend (the deploy profile). So the read path the prod service runs
# (status_route -> cp_jobstore.read_job -> fold_state -> FirestoreBackend.read_lines) was
# never asserted over the wire under firestore. This gate is that assertion: it is the
# guard for "the inspector folds done but the HTTP endpoint returns None/queued".
#
# WHAT IT DOES (each step the EXACT prod read shape):
#   1. Select firestore mode (emulator if available, else the SAME faithful in-process
#      fake google.cloud.firestore the cp-durability / cp-flow-firestore gates use,
#      persisting to a JSON file so a SEPARATE serve subprocess and the signing client
#      share one durable store — the cross-process property a real Firestore has).
#   2. Register an OWNER signing identity (keys written THROUGH the firestore backend).
#   3. SEED a job to the terminal state=done DIRECTLY in firestore via cp_jobstore
#      (create -> running -> set_result -> done) — the durable doc the inspector reads.
#      Confirm a FRESH-process fold (env-only, no shared memory) reads state=done — the
#      inspector's read, reproduced.
#   4. BOOT the REAL `heimdall-control-plane serve` subprocess under firestore (it
#      inherits the firestore env + the fake on PYTHONPATH), so the read crosses a real
#      process + a real HTTP socket.
#   5. Send a SIGNED GET /jobs with the job_id in the BODY ({"job_id": ...}) — the EXACT
#      request shape deploy/cloud-run/verify-flight-fix.sh's STEP-2/STEP-5 use (and the
#      shape status_route._job_id_from reads). Assert HTTP 200 + job.state=done +
#      result.status surfaced.
#
# FALSIFIABLE: a status_route that read the job_id from a place the body does NOT carry,
# or that folded over a different/stale backend than fold_state, would return None/404
# here while the FRESH-process fold (step 3) returns done — RED. The two reading the SAME
# done is the whole proof.
#
# DISCIPLINE (mirrors cp-flow-firestore / cp-wired): isolated throwaway home + external
# store dir; the PKI seed lives ONLY in memory (passed to children by env, NEVER written
# to a tracked file, NEVER printed); the serve subprocess is REAPED on EXIT; ZERO real
# GCP / ZERO spend in fake mode. Exit 0 = the firestore-mode HTTP read-back holds.

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
  printf "cp-getjobs-firestore: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  echo "============================================================"
  exit 0
fi

# The external-store dir (emulator data / fake JSON store + the fake package). Lives
# OUTSIDE the per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-getjobsfs-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"
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
export HEIMDALL_FIRESTORE_ROOT="getjobs_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-getjobs-firestore-test"

# ── a TEST PKI seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
# A deterministic 32-byte Ed25519 seed: the deploy's HEIMDALL_CP_PKI_KEY shape, so the
# serve subprocess derives the SAME server identity the firestore cloud-profile requires,
# and the owner identity derives a usable signing key from it.
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*7+3)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "cp-getjobs-firestore: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8771"
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
    echo "cp-getjobs-firestore: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

# (2) FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
#     cp-flow-firestore gates use (a sitecustomize.py on PYTHONPATH registers it into
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
echo "FIRESTORE-MODE GET /jobs READ-BACK GATE (MODE=$MODE)"
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
#    inspector reads), and confirm a FRESH-process fold reads done (the inspector's read).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 seed a job -> state=done in firestore + confirm a FRESH-process fold reads done"
JOB_ID="$("$PY" - <<'PYEOF' 2>"$EXT/seed.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
jid = J.create_job("run-task-X", {"task_id": "getjobs-fs"},
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

# The inspector's read, reproduced: a brand-new process (NO shared memory with the seeder)
# folds the SAME firestore doc and reads done. This is the "inspector reads done" baseline
# the HTTP endpoint (#4) must MATCH.
FRESH_STATE="$("$PY" - <<PYEOF 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
print((J.fold_state("$JOB_ID") or {}).get("state"))
PYEOF
)"
[ "$FRESH_STATE" = "done" ] \
  && ok "#2 a FRESH-process fold_state reads state=done (the inspector's read, reproduced)" \
  || bad "#2 a fresh fold did NOT read done (got '$FRESH_STATE') — the seed/read path is broken"

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
# #4 SIGNED GET /jobs with the job_id in the BODY — the EXACT shape verify-flight-fix.sh
#    uses (STEP-2/STEP-5: GET /jobs, {"job_id": ...} in the body). Assert the endpoint
#    returns the SAME done the FRESH fold (#2) read — the guard for the inspector/endpoint
#    split. [CARDINAL]
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 a SIGNED GET /jobs (job_id in body) returns state=done over the wire [CARDINAL]"
export CP_PORT CP_HAID="$OWNER_HAID" CP_PRIV="$OWNER_PRIV"
"$PY" - >"$EXT/getjobs.out" 2>"$EXT/getjobs.err" <<PYEOF
import json, os, sys, urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K  # the SHIPPED Ed25519 signer — never re-implemented.
port = int(os.environ["CP_PORT"]); haid = os.environ["CP_HAID"]; priv = os.environ["CP_PRIV"]
# THE VERIFY'S EXACT REQUEST SHAPE: GET /jobs, the job_id in the JSON body.
body = json.dumps({"job_id": "$JOB_ID"}).encode()
method, path = "GET", "/jobs"
req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=body, method=method)
req.add_header("X-Heimdall-HAID", haid)
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message(method, path, body)))
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        raw = r.read(); b = json.loads(raw) if raw else {}; st = r.status
except urllib.error.HTTPError as e:
    raw = e.read(); b = json.loads(raw) if raw else {}; st = e.code
job = b.get("job") or {}
result = job.get("result")
print(json.dumps({
    "status": st,
    "state": job.get("state"),
    "result": (result.get("status") if isinstance(result, dict) else result),
}))
PYEOF
GJ_STATUS="$("$PY" -c "import json;print(json.load(open('$EXT/getjobs.out')).get('status'))" 2>/dev/null)"
GJ_STATE="$("$PY" -c "import json;print(json.load(open('$EXT/getjobs.out')).get('state'))" 2>/dev/null)"
GJ_RESULT="$("$PY" -c "import json;print(json.load(open('$EXT/getjobs.out')).get('result'))" 2>/dev/null)"

[ "$GJ_STATUS" = "200" ] \
  && ok "#4 GET /jobs (signed, job_id in body) -> HTTP 200 under firestore" \
  || { bad "#4 GET /jobs did not return 200 under firestore (status=$GJ_STATUS)"; cat "$EXT/getjobs.err" >&2; }
[ "$GJ_STATE" = "done" ] \
  && ok "#4 the endpoint returns job.state=done — it reads the SAME folded state the inspector does [CARDINAL]" \
  || bad "#4 the endpoint returned state='$GJ_STATE' (NOT done) while the fresh fold read done — the inspector/endpoint split REPRODUCED"
[ "$GJ_RESULT" = "prepared" ] \
  && ok "#4 the reconnecting client reads the job RESULT (status=prepared) over signed HTTP under firestore" \
  || bad "#4 the job result was not surfaced over the wire (got '$GJ_RESULT')"

# FALSIFIABLE: the endpoint state MUST equal the fresh-fold state. A divergence (one done,
# the other None/queued) is exactly the prod split this gate guards against.
[ "$GJ_STATE" = "$FRESH_STATE" ] && [ "$GJ_STATE" = "done" ] \
  && ok "#4 FALSIFIABLE: the HTTP endpoint and the inspector-style fold AGREE on done (no read-path split)" \
  || bad "#4 the HTTP endpoint and the fold DISAGREE (endpoint='$GJ_STATE', fold='$FRESH_STATE') — read-path split"

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
printf "cp-getjobs-firestore (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
