#!/usr/bin/env bash
# cp-inspect.test.sh — proves bin/heimdall-cp-inspect reads the EXACT Firestore doc the
# control plane uses, BEFORE RJ runs it on prod.
#
# WHAT IT PROVES (the incident the tool settles). A job's terminal state=done line, once
# written THROUGH the SHIPPED FirestoreBackend, is read back by heimdall-cp-inspect from
# the SAME resolved doc — so the tool's "TERMINAL state=done present" verdict is
# authoritative. The test seeds a job + writes a done line via cp_jobstore (the real
# write path) over a Firestore backend, then runs the three subcommands and asserts:
#   - env       reports HEIMDALL_STATE_BACKEND=firestore + the resolved root/project/db.
#   - job <id>  prints the resolved doc path + the done line + "state=done present: yes",
#               and exits 0; an ABSENT job prints "doc exists: NO" + verdict "no", exit 1.
#   - list-jobs lists the seeded job's doc id (jobs__<id>.ndjson) under the jobs prefix.
#
# THE BACKEND UNDER TEST. Like test/cp-durability.test.sh, this runs the SHIPPED
# FirestoreBackend against either (a) a caller-provided FIRESTORE_EMULATOR_HOST + the real
# google-cloud-firestore client, or (b) a faithful in-process double injected via a
# sitecustomize.py on PYTHONPATH (no Java/emulator/GCP needed). The double persists to a
# JSON file OUTSIDE any home, so the write (cp_jobstore) and the read (heimdall-cp-inspect,
# a separate process) share one durable store — exactly the cross-process read the incident
# is about. The double mirrors the durability test's google.cloud.firestore double.
#
# Exit 0 + "cp-inspect: PASS" on success; nonzero + "cp-inspect: FAIL ..." on any assertion.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSPECT="$REPO/bin/heimdall-cp-inspect"
export REPO_LIB_PARENT="$REPO/bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXT="$WORK/ext"          # the external store dir (the double's JSON store + its pylib).
HOME_DIR="$WORK/home"    # a HEIMDALL_HOME (the firestore backend ignores it for storage).
mkdir -p "$EXT" "$HOME_DIR"

ROOT_COLL="heimdall_cp_test"      # a non-default root so we also prove HEIMDALL_FIRESTORE_ROOT.
PROJECT_ID="demo-cp-inspect"

# A is the number of assertions that have PASSED so far. This suite is fail-fast — the
# first failing assertion calls fail() and exits — so on the failure path the count is
# exactly "A passed, 1 failed". Emitting it on BOTH paths is what lets test/run-all.sh
# parse this suite; without it an exit-0 run is indistinguishable from an empty one.
A=0
ok() { A=$((A + 1)); }
fail() {
  echo "cp-inspect: FAIL — $*" >&2
  printf 'cp-inspect: %d passed, 1 failed\n' "$A"
  exit 1
}

# ── decide the mode: caller emulator (real client) vs in-process double ──────────────
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && python3 -c 'import google.cloud.firestore' >/dev/null 2>&1; then
  MODE="emulator"
  echo "cp-inspect: using caller FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
  PYLIB=""
else
  MODE="double"
  PYLIB="$EXT/pylib"
  mkdir -p "$PYLIB"
  # The faithful in-process double of the slice of google.cloud.firestore the SHIPPED
  # FirestoreBackend uses (mirrors test/cp-durability.test.sh). Persists the whole store
  # to one JSON file so write+read in separate processes share it.
  cat >"$PYLIB/_fake_firestore_impl.py" <<'PYEOF'
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("the firestore double needs %s set to a path" % _STORE_ENV)
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


class Client:
    def __init__(self, project=None):
        self.project = project
        self._database = "(default)"

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
  cat >"$PYLIB/sitecustomize.py" <<'PYEOF'
import importlib
import sys
import types

import _fake_firestore_impl as _impl

for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001 — synthesize a bare package when google is absent.
            _pkg = types.ModuleType(_name)
            _pkg.__path__ = []
            sys.modules[_name] = _pkg

_fs = types.ModuleType("google.cloud.firestore")
_fs.Client = _impl.Client
_fs.transactional = _impl.transactional
sys.modules["google.cloud.firestore"] = _fs
try:
    setattr(sys.modules["google.cloud"], "firestore", _fs)
except Exception:  # noqa: BLE001 — best-effort attribute bind.
    sys.stderr.write("sitecustomize: could not bind firestore onto google.cloud\n")
PYEOF
fi

# ── the shared env every step runs under (the SHIPPED firestore backend + the store) ──
export HEIMDALL_HOME="$HOME_DIR"
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_FIRESTORE_ROOT="$ROOT_COLL"
export HEIMDALL_FIRESTORE_PROJECT="$PROJECT_ID"
export HEIMDALL_FAKE_FS_STORE="$EXT/fake_fs.json"
if [ "$MODE" = "double" ]; then
  export PYTHONPATH="$PYLIB${PYTHONPATH:+:$PYTHONPATH}"
fi

echo "cp-inspect: MODE=$MODE  root=$ROOT_COLL  project=$PROJECT_ID"

# ── seed a job + write a terminal done line via the REAL write path (cp_jobstore) ─────
JOB_ID="$(python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO_LIB_PARENT"], "lib"))
import cp_jobstore
jid = cp_jobstore.create_job("noop.demo", {"n": 1})
assert jid, "create_job returned None"
# queued -> running -> done (the real legal path); result then terminal transition.
cp_jobstore.transition(jid, cp_jobstore.STATE_RUNNING)
cp_jobstore.set_result(jid, {"ok": True})
cp_jobstore.transition(jid, cp_jobstore.STATE_DONE)
print(jid)
PYEOF
)"
[ -n "$JOB_ID" ] || fail "could not seed a job (write path failed)"
ok
echo "cp-inspect: seeded job $JOB_ID (queued->running->done over the firestore backend)"

# ── 1) env: reports the resolved firestore location ──────────────────────────────────
ENV_OUT="$("$INSPECT" env 2>&1)" || fail "env exited nonzero: $ENV_OUT"
ok
echo "$ENV_OUT" | grep -q "HEIMDALL_STATE_BACKEND .*= firestore" \
  || fail "env did not report HEIMDALL_STATE_BACKEND=firestore:
$ENV_OUT"
ok
echo "$ENV_OUT" | grep -q "HEIMDALL_FIRESTORE_ROOT .*= $ROOT_COLL" \
  || fail "env did not report the root collection $ROOT_COLL:
$ENV_OUT"
ok
echo "$ENV_OUT" | grep -q "resolved_project .*= $PROJECT_ID" \
  || fail "env did not resolve the project $PROJECT_ID:
$ENV_OUT"
ok
echo "cp-inspect: [1/4] env OK"

# ── 2) job <id>: doc path + done line + "state=done present: yes", exit 0 ─────────────
JOB_OUT="$("$INSPECT" job "$JOB_ID" 2>&1)"; JOB_RC=$?
[ "$JOB_RC" -eq 0 ] || fail "job exited $JOB_RC (expected 0 for a done job):
$JOB_OUT"
ok
echo "$JOB_OUT" | grep -q "doc path .*: $ROOT_COLL/jobs__$JOB_ID.ndjson" \
  || fail "job did not print the resolved doc path $ROOT_COLL/jobs__$JOB_ID.ndjson:
$JOB_OUT"
ok
echo "$JOB_OUT" | grep -q "doc exists .*: yes" \
  || fail "job did not report doc exists: yes:
$JOB_OUT"
ok
echo "$JOB_OUT" | grep -q '"state":"done"' \
  || fail "job did not print the done NDJSON line:
$JOB_OUT"
ok
echo "$JOB_OUT" | grep -q "TERMINAL state=done present: yes" \
  || fail "job did not report TERMINAL state=done present: yes:
$JOB_OUT"
ok
echo "cp-inspect: [2/4] job <id> (done) OK"

# ── 3) job <absent>: doc exists NO + verdict no, exit 1 ──────────────────────────────
ABSENT="job-deadbeefdeadbeefdeadbeefdeadbeef"
ABS_OUT="$("$INSPECT" job "$ABSENT" 2>&1)"; ABS_RC=$?
[ "$ABS_RC" -eq 1 ] || fail "absent job exited $ABS_RC (expected 1):
$ABS_OUT"
ok
echo "$ABS_OUT" | grep -q "doc exists .*: NO" \
  || fail "absent job did not report doc exists: NO:
$ABS_OUT"
ok
echo "$ABS_OUT" | grep -q "TERMINAL state=done present: no" \
  || fail "absent job did not report TERMINAL state=done present: no:
$ABS_OUT"
ok
echo "cp-inspect: [3/4] job <absent> OK"

# ── 4) list-jobs: the seeded job's doc id is under the jobs prefix ────────────────────
LIST_OUT="$("$INSPECT" list-jobs 2>&1)" || fail "list-jobs exited nonzero: $LIST_OUT"
ok
echo "$LIST_OUT" | grep -q "$JOB_ID" \
  || fail "list-jobs did not list the seeded job id $JOB_ID:
$LIST_OUT"
ok
echo "$LIST_OUT" | grep -q "jobs__$JOB_ID.ndjson" \
  || fail "list-jobs did not show the raw doc id jobs__$JOB_ID.ndjson:
$LIST_OUT"
ok
echo "cp-inspect: [4/4] list-jobs OK"

echo "cp-inspect: PASS"
printf 'cp-inspect: %d passed, 0 failed\n' "$A"
