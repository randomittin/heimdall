#!/usr/bin/env bash
# cp-durability.test.sh — THE DURABILITY GATE (Wave 2, the capstone proof).
#
# THE POINT OF THE WHOLE REFACTOR. The §4 flight-fix durability claim ("job state
# survives a client disconnect AND a process restart, because state is the fold of an
# on-disk log") is TRUE on a laptop but FALSE on Cloud Run: the home filesystem is
# EPHEMERAL — wiped on scale-to-zero, not shared across instances. cp_state put a
# StateBackend seam behind the 6 stores; FirestoreBackend persists the same operations
# in an EXTERNAL store (Firestore), keyed to the Firestore project, NOT to the home.
#
# THIS TEST SIMULATES Cloud Run scale-to-zero across two instances with SEPARATE
# ephemeral homes and asserts the FALSIFIABLE CONTRAST, both halves:
#
#   • LOCAL backend  (HEIMDALL_STATE_BACKEND=local):     instance B does NOT see the
#       job — its state was in the WIPED instance-A home → state LOST. If local somehow
#       finds it, the simulation is wrong and the test FAILS.
#   • FIRESTORE backend (HEIMDALL_STATE_BACKEND=firestore): instance B DOES see the
#       job + its full folded state — persisted in the external store, untouched by the
#       home wipe → state SURVIVED. If firestore does NOT survive, the test FAILS.
#
# Both halves must hold or the gate exits nonzero. This is the proof the durability gap
# is closed: the SAME jobstore API, the SAME scale-to-zero, opposite outcomes — and the
# only difference is the backend.
#
# ZERO REAL GCP / ZERO SPEND. Two modes, selected automatically:
#   (1) EMULATOR — if BOTH `gcloud beta emulators firestore` AND the python client lib
#       (google.cloud.firestore) are available, start the emulator, point
#       FIRESTORE_EMULATOR_HOST at it, run the SHIPPED FirestoreBackend against it, reap
#       it in a trap. The emulator process lives OUTSIDE any per-instance home.
#   (2) FAKE — else, a faithful in-process fake `google.cloud.firestore` package (on
#       PYTHONPATH) that implements EXACTLY the client surface FirestoreBackend calls,
#       PERSISTS to a JSON file that lives OUTSIDE any per-instance HEIMDALL_HOME (so the
#       home wipe cannot touch it), and is shared across the two FirestoreBackend
#       instances. SHIPPED backend code is real; only the external service is a double —
#       the same precedent as the billing kill-switch test faking the billing client.
# The test PRINTS which mode it used.
#
# Exit 0 = both contrast halves hold. Nonzero = the durability gate failed (prints which).
#
# REAL-EMULATOR VALIDATION (recorded so the evidence is durable). The gate was run against
# the REAL google.cloud.firestore client (pinned google-cloud-firestore==2.16.1, matching
# deploy/requirements-firestore.txt) talking to a LIVE local Firestore emulator — exercising
# real transaction / @firestore.transactional / order_by(seq).stream() / subcollection /
# doc-id semantics, not the in-process fake. It reported MODE=emulator, 9/9 PASS, both halves
# (local LOST, firestore SURVIVED); the SHIPPED FirestoreBackend needed NO code change for the
# real client. Falsifiability was re-confirmed against the real client (keying the Firestore
# root to HEIMDALL_HOME flips the firestore half RED). To reproduce locally (ZERO real GCP):
#
#   gcloud components install cloud-firestore-emulator     # needs a Java 21+ JRE on PATH
#   pip install google-cloud-firestore==2.16.1 --break-system-packages
#   gcloud emulators firestore start --host-port=localhost:8085 &   # reap it when done
#   export FIRESTORE_EMULATOR_HOST=localhost:8085
#   bash test/cp-durability.test.sh                        # prints "MODE=emulator"
#
# IMPORTANT: the emulator's JVM requires a Java 21+ JRE. With an older JRE the self-started
# emulator (mode 1 below) fails to boot; that failure is now PRINTED (not a silent fake), and
# a caller-set FIRESTORE_EMULATOR_HOST (mode 0) forces real mode regardless of the self-start.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB

[ -f "$LIB/cp_jobstore.py" ]         || { echo "FATAL: $LIB/cp_jobstore.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state.py" ]            || { echo "FATAL: $LIB/cp_state.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (Firestore emulator data / fake JSON store + the fake package).
# CRITICAL: this lives OUTSIDE both per-instance homes (/tmp/durA, /tmp/durB) so the
# scale-to-zero home wipe cannot touch the "external" store — that is what makes the
# Firestore half a real durability test and not an accident of shared disk.
EXT="$(mktemp -d -t "cp-dur-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"

# The two per-instance ephemeral homes (distinct disks, as the task pins them).
HOME_A="/tmp/durA"
HOME_B="/tmp/durB"
rm -rf "$HOME_A" "$HOME_B"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_A" "$HOME_B"
}
trap cleanup EXIT

# Shared root collection so both FirestoreBackend instances address the same store.
export HEIMDALL_FIRESTORE_ROOT="durability_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-durability-test"

# ── decide the mode: emulator (real client + emulator) vs faithful in-process fake ──
#
# Mode precedence (most explicit wins):
#   (0) EXTERNAL EMULATOR — FIRESTORE_EMULATOR_HOST already set by the caller AND the real
#       client lib installed → FORCE real "emulator" mode against that pre-started emulator.
#       The test does NOT start or own the emulator here; the caller is (the documented
#       flow: `gcloud emulators firestore start --host-port=localhost:8085 & ;
#       export FIRESTORE_EMULATOR_HOST=localhost:8085 ; bash test/cp-durability.test.sh`).
#       This guarantees a set host + installed client can NEVER silently degrade to the
#       fake — the gap an internal-emulator boot failure (e.g. a too-old JRE) used to hide.
#       No EMU_PID is captured (we did not start it) so cleanup leaves it to the caller.
#   (1) SELF-STARTED EMULATOR — else, if gcloud's emulator + the client are both present,
#       start the emulator ourselves, point the client at it, reap it in the trap. If our
#       emulator fails to boot/advertise (e.g. the Java 21+ JRE it needs is absent) we
#       PRINT why and fall through — the degrade is now VISIBLE, not silent.
#   (2) FAKE — else, the faithful in-process double.
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  # Honor the caller's emulator verbatim. We did NOT start it → keep EMU_PID empty so the
  # trap does not kill a process we do not own.
  EMU_PID=""
  MODE="emulator"
  echo "cp-durability: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  # EMULATOR MODE — start the emulator, capture its host, point the client at it.
  EMU_HOST="localhost:8765"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" \
      >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  # wait for the emulator to advertise its host (it prints it on startup).
  for _ in $(seq 1 40); do
    if grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then break; fi
    if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then break; fi
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"
    MODE="emulator"
  else
    # The self-started emulator never advertised (commonly: the emulator needs a Java 21+
    # JRE and the one on PATH is older). Make the degrade VISIBLE, not a silent fake.
    echo "cp-durability: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    echo "cp-durability: emulator log tail:" >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-durability: to force REAL mode, start an emulator yourself and export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE on PATH)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — inject a faithful in-process google.cloud.firestore via a sitecustomize.py
  # on PYTHONPATH. sitecustomize runs at INTERPRETER STARTUP and registers the fake module
  # into sys.modules BEFORE any import, so the SHIPPED FirestoreBackend's
  # `from google.cloud import firestore` + `firestore.Client()` resolve to THIS even when a
  # real (namespace-package) google is installed — the backend code under test runs
  # unchanged; only the external service is a double. The fake PERSISTS to $EXT/fake_fs.json
  # (a file OUTSIDE both homes), so two backend instances + a home wipe see the same store.
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses. NOT a general Firestore — exactly
# the surface the shipped backend calls:
#   firestore.Client(project=...) / firestore.Client()
#   db.collection(name) -> CollectionRef
#   db.transaction()    -> _Transaction
#   collection.document(id) -> DocRef
#   collection.stream() / collection.order_by(field).stream() -> [snapshot...]
#   docref.collection(name) -> CollectionRef (subcollection)
#   docref.get() / docref.get(transaction=txn) -> _Snapshot(.exists,.id,.to_dict())
#   docref.set(data) / docref.set(data, merge=True)
#   @firestore.transactional ; txn.set(ref, data) ; txn.get(ref)/ref.get(transaction=txn)
#
# PERSISTENCE: the entire store is a nested dict serialized to the JSON file named by
# HEIMDALL_FAKE_FS_STORE. Every mutation loads-mutates-saves that file, so two Client()
# instances in two processes (or one process after a "home wipe") share one durable
# store that lives OUTSIDE any per-instance home. That externalness is the whole point.
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
    tmp = _store_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


# The store layout in the JSON file:
#   { "collections": { "<coll-path>": { "<doc-id>": {"fields": {...},
#                                                     "subcollections": {<sub>: true}}}}}
# A collection path is a "/"-joined chain (root coll, then doc-id, then subcoll, ...).
# We key collections by their full path so subcollections are addressable.


class Client:
    def __init__(self, project=None):
        self.project = project

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path  # full "/"-joined collection path.

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
        # a subcollection's full path is "<coll>/<doc-id>/<subcoll>".
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
    # The fake store is file-serialized with atomic os.replace, so a "transaction" here
    # is just the sequence of set()s the decorated function issues — each set is durable
    # immediately. That preserves the monotonic-seq + ordered-line semantics the backend
    # relies on (read seq, write seq+1) for a single-process gate. set() is the only
    # mutation; get() reads through to the file.
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    # The real decorator wraps a fn(transaction, ...) and runs it within a txn; our fake
    # txn applies writes immediately, so we just call through.
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
  # sitecustomize.py — runs at interpreter startup; registers the fake impl as the
  # canonical google.cloud.firestore in sys.modules so the shipped import resolves to it.
  cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys

import _fake_firestore_impl as _impl

# Make `google` / `google.cloud` importable (real namespace packages when google libs are
# installed; synthesized empty packages otherwise), then bind our fake as their firestore.
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

echo "cp-durability: MODE=$MODE  (external store: $EXT)"
echo

# ── the driver: create+advance a job under instance A, then read under instance B ──
# A single python process per step, each pinned to ONE home + ONE backend, talking
# through the REAL cp_jobstore API (no mock of the thing under test).

# instance A: create a job and advance it (queued -> running -> set_result -> done).
mk_create_advance() {
cat <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
jid = J.create_job("run-task-X", {"task_id": "durability-job"},
                   instance_haid="haid:instanceA", home=home)
J.transition(jid, "running", home=home)
J.set_result(jid, {"status": "prepared", "n": 7}, home=home)
J.transition(jid, "done", home=home)
print(jid)
PYEOF
}

# instance B: read the job's folded state by id (the reconnecting-instance read).
mk_read() {
cat <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
jid = sys.argv[1]
folded = J.read_job(jid, home)
if not folded:
    print("MISSING")
else:
    res = folded.get("result") or {}
    print("FOUND|%s|%s" % (folded.get("state"), res.get("status") if isinstance(res, dict) else res))
PYEOF
}

CREATE_ADV="$EXT/create_advance.py"; mk_create_advance >"$CREATE_ADV"
READ_JOB="$EXT/read_job.py";        mk_read           >"$READ_JOB"

# ============================================================================
# HALF 1 — LOCAL backend: state LOST on scale-to-zero (expected).
# ============================================================================
echo "HALF 1 — LOCAL backend (state must be LOST on home wipe)"
export HEIMDALL_STATE_BACKEND="local"

# instance A on home A: create + advance the job; its state log lives under /tmp/durA.
rm -rf "$HOME_A"
JID_LOCAL="$(HEIMDALL_HOME="$HOME_A" "$PY" "$CREATE_ADV" 2>"$EXT/a_local.err" | tr -d '[:space:]')"
if [ -n "$JID_LOCAL" ]; then
  ok "1a instance A created+advanced job ($JID_LOCAL) under home A (local)"
else
  bad "1a instance A failed to create the job (local)"; cat "$EXT/a_local.err" >&2
fi
# sanity: instance A on its OWN home DOES see done (the store works before the wipe).
A_SELF="$(HEIMDALL_HOME="$HOME_A" "$PY" "$READ_JOB" "$JID_LOCAL" 2>/dev/null)"
[ "${A_SELF%%|*}" = "FOUND" ] && [ "$(echo "$A_SELF" | cut -d'|' -f2)" = "done" ] \
  && ok "1b instance A reads its own job=done before the wipe (store works)" \
  || bad "1b instance A could not read its own job before the wipe (got '$A_SELF')"

# SCALE-TO-ZERO: instance A's ephemeral disk vanishes.
rm -rf "$HOME_A"
ok "1c SCALE-TO-ZERO: instance A home ($HOME_A) wiped"

# instance B: a FRESH instance on a DIFFERENT ephemeral home reads the job.
rm -rf "$HOME_B"
B_LOCAL="$(HEIMDALL_HOME="$HOME_B" "$PY" "$READ_JOB" "$JID_LOCAL" 2>/dev/null)"
if [ "$B_LOCAL" = "MISSING" ]; then
  ok "1d instance B does NOT see the job (state was in the wiped home A) — LOST"
  echo "  → local: state LOST on scale-to-zero (expected)"
else
  bad "1d LOCAL SHOULD HAVE LOST THE STATE but instance B found it ('$B_LOCAL') — the scale-to-zero simulation is WRONG (homes not isolated)"
fi

echo

# ============================================================================
# HALF 2 — FIRESTORE backend: state SURVIVES scale-to-zero (durability proven).
# ============================================================================
echo "HALF 2 — FIRESTORE backend (state must SURVIVE the home wipe)"
export HEIMDALL_STATE_BACKEND="firestore"

# instance A on home A: create + advance the job. With the firestore backend the state
# is written to the EXTERNAL store, NOT under /tmp/durA.
rm -rf "$HOME_A"
JID_FS="$(HEIMDALL_HOME="$HOME_A" "$PY" "$CREATE_ADV" 2>"$EXT/a_fs.err" | tr -d '[:space:]')"
if [ -n "$JID_FS" ]; then
  ok "2a instance A created+advanced job ($JID_FS) under home A (firestore)"
else
  bad "2a instance A failed to create the job (firestore)"; cat "$EXT/a_fs.err" >&2
fi

# Prove the state is NOT on the per-instance disk: home A holds no job log for it.
if [ ! -e "$HOME_A/control-plane/jobs/$JID_FS.ndjson" ]; then
  ok "2b the firestore-backed job has NO local file under home A (state is external)"
else
  bad "2b firestore-backed job wrote a local file under home A — state is NOT external (durability broken)"
fi

# SCALE-TO-ZERO: instance A's ephemeral disk vanishes (same wipe as the local half).
rm -rf "$HOME_A"
ok "2c SCALE-TO-ZERO: instance A home ($HOME_A) wiped"

# instance B: a FRESH instance on a DIFFERENT ephemeral home reads the job from the
# external store, untouched by the home wipe.
rm -rf "$HOME_B"
B_FS="$(HEIMDALL_HOME="$HOME_B" "$PY" "$READ_JOB" "$JID_FS" 2>"$EXT/b_fs.err")"
B_FS_FOUND="${B_FS%%|*}"
B_FS_STATE="$(echo "$B_FS" | cut -d'|' -f2)"
B_FS_STATUS="$(echo "$B_FS" | cut -d'|' -f3)"
if [ "$B_FS_FOUND" = "FOUND" ] && [ "$B_FS_STATE" = "done" ]; then
  ok "2d instance B SEES the job=done from the external store (home was wiped) — SURVIVED"
else
  bad "2d instance B did NOT resolve the firestore-backed job after the wipe (got '$B_FS') — durability FAILED"
  cat "$EXT/b_fs.err" >&2
fi
[ "$B_FS_STATUS" = "prepared" ] \
  && ok "2e instance B reads the full folded RESULT (status=prepared) — the fold survived too" \
  || bad "2e instance B lost the job result after the wipe (got status '$B_FS_STATUS')"
[ "$B_FS_FOUND" = "FOUND" ] && [ "$B_FS_STATE" = "done" ] \
  && echo "  → firestore: state SURVIVED scale-to-zero (durability proven)"

echo
# ── verdict ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo "cp-durability ($MODE): $PASS passed, $FAIL failed"
echo "  local:     state LOST on scale-to-zero (expected)"
echo "  firestore: state SURVIVED scale-to-zero (durability proven)"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
