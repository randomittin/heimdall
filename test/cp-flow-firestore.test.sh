#!/usr/bin/env bash
# cp-flow-firestore.test.sh — THE REQUEST-FLOW-UNDER-FIRESTORE REGRESSION GATE.
#
# THE INCIDENT CLASS THIS GATES (production Cloud Run, same root cause twice+). The
# control plane ran with HEIMDALL_STATE_BACKEND=firestore. FirestoreBackend.path() RAISES
# BackendUnavailable BY DESIGN (a firestore-backed rel has no local file). A code path on
# a LIVE REQUEST HANDLER called a *_path()/*_dir() accessor (which routes to
# backend.path()) — and it SHIPPED because EVERY cp suite runs on the LOCAL backend, where
# LocalBackend.path() returns a real path, so the firestore-only break was invisible.
#   • Incident #1: the dispatch flow.
#   • Incident #2: cp_boot._owner_haids via cp_auth.keys_path() (gated by cp-tick-firestore).
#   • This sweep also found: cp_ingest.ingest_batch (POST /ingest) decorated its result
#     with instance_store_path(); cp_notify.deliver_inbox returned backend.path() in its
#     result — both raise under firestore on EVERY request. Fixed to a path-or-None helper.
# This gate drives the CORE REQUEST FLOW under firestore — the handlers a real client
# reaches — and asserts NONE raises BackendUnavailable, closing the class for good.
#
# THE FLOW EXERCISED (each is a real request-handler store access under firestore):
#   1. INGEST  — cp_ingest.ingest_batch (the POST /ingest handler body) over an instance
#                HAID: re-run build_event, STORE the partition, AUDIT, return.
#                (Incident-shaped: ingest_batch decorated its result with a *_path()
#                accessor, which raises under firestore.)
#   2. JOB     — cp_jobstore start_job -> client_disconnect -> complete_job: the §4
#                flight-fix flow, the fold of an append-only log, under firestore.
#   3. APPROVAL— cp_approval submit + approve of a gated action_id (keyed JSON record).
#   4. NOTIFY  — cp_notify.notify (-> deliver_inbox) job_complete to the instance inbox,
#                then poll it back. (Incident-shaped: deliver_inbox returned a *_path()
#                accessor in its result, which raises under firestore.)
#   5. DISPATCH— cp_server.dispatch of a non-gated allowlisted action under firestore.
#
# ASSERTIONS (each FALSIFIABLE):
#   (a) NO-RAISE — the whole flow completes with NO BackendUnavailable anywhere. The
#       driver catches EVERY exception and prints its type, so a path()-on-request-path
#       regression surfaces by name (BackendUnavailable) and (a) FAILS.
#   (b) RESOLVES — the flow actually did its work under firestore (read back through the
#       backend): the ingested events are stored, the job folds to complete, the approval
#       resolves to approved, the notification lands in the polled inbox, the dispatch
#       fires. A handler that silently no-op'd (or could not read its store) FAILS (b).
#
# Same firestore mode-selection as cp-tick-firestore / cp-durability: (0) caller emulator,
# (1) self-started gcloud emulator, else (2) the SAME faithful in-process FAKE
# google.cloud.firestore those gates use. ZERO real GCP / ZERO spend. NO SECRET on disk:
# the PKI seed lives only in memory, passed to children by env. The test PRINTS its mode.
#
# Exit 0 = (a) AND (b) hold. Nonzero = the gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_ingest cp_notify cp_jobstore cp_approval cp_auth cp_audit cp_server \
         cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (emulator data / fake JSON store + the fake package). Lives
# OUTSIDE the per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-flowfs-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"

# The single per-instance ephemeral home (the flow runs in one process / instance).
HOME_T="/tmp/flowfsT"
rm -rf "$HOME_T"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_T"
}
trap cleanup EXIT

# A dedicated root collection so this gate's store never collides with another gate's.
export HEIMDALL_FIRESTORE_ROOT="flow_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-flow-firestore-test"

# ── a TEST seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
MK_SEED="$EXT/mk_seed.py"
cat >"$MK_SEED" <<'PYEOF'
import base64
print(base64.b64encode(bytes((i * 7 + 3) % 256 for i in range(32))).decode())
PYEOF
SEED_B64="$("$PY" "$MK_SEED")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_PID=""
  MODE="emulator"
  echo "cp-flow-firestore: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8769"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" \
      >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  for _ in $(seq 1 40); do
    if grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then break; fi
    if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then break; fi
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"
    MODE="emulator"
  else
    echo "cp-flow-firestore: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-flow-firestore: to force REAL mode, start an emulator yourself and export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
  # cp-tick-firestore gates use (a sitecustomize.py on PYTHONPATH registers it into
  # sys.modules before any import), persisting to a JSON file so reads after a write see
  # the same store. SHIPPED backend code is real; only the external service is a double.
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses. PERSISTS the whole store to the JSON
# file named by HEIMDALL_FAKE_FS_STORE so reads after a write share one durable store.
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


class Client:
    def __init__(self, project=None):
        self.project = project

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

echo "cp-flow-firestore: MODE=$MODE  (external store: $EXT)"
echo

# Everything from here runs under the firestore backend (the deploy profile that broke).
export HEIMDALL_STATE_BACKEND="firestore"

# ── the driver: one process that drives the core request flow end-to-end under the
#    firestore backend and prints a single status line the bash gate parses. It uses the
#    SAME store APIs the route handlers call (it IS the handler body), so a path() on any
#    of those request paths surfaces here as a named exception. ──
DRIVER="$EXT/flow_driver.py"
cat >"$DRIVER" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])

import cp_approval
import cp_auth
import cp_ingest
import cp_jobstore
import cp_notify
import cp_server

home = os.environ["HEIMDALL_HOME"]


def fail(stage, exc):
    # Any exception in a request handler under firestore is the regression — name it so a
    # BackendUnavailable surfaces by type instead of a bare traceback.
    print("STATUS handler_raised stage=%s %s: %s" % (stage, type(exc).__name__, exc))
    sys.exit(0)


# A verified instance HAID (the store partition key the real route derives from auth) and
# the OWNER identity the approval/dispatch steps run AS (the lib takes an Identity object).
instance_haid = "haid:flow-instance"
owner = cp_auth.Identity("haid:cp-server", owner=True)

# 1. INGEST (the POST /ingest handler body) under firestore. Two on-schema events; the
#    handler re-runs build_event, stores the partition, audits, and (the incident shape)
#    decorated its result with a *_path() accessor. If that raises -> regression.
try:
    events = [
        {"event_type": "phase", "run_id": "r1", "phase": "build"},
        {"event_type": "outcome", "run_id": "r1", "outcome": "ok"},
    ]
    ingest_res = cp_ingest.ingest_batch(instance_haid, events, home=home)
except Exception as exc:  # noqa: BLE001
    fail("ingest", exc)
ingest_stored = ingest_res.get("stored", 0)

# 2. JOB (§4 flight-fix flow) under firestore: create -> running -> done (the client
#    disconnects mid-run; state is the fold of the durable append-only log). Read back
#    through the backend — the fold must reach the 'done' terminal state.
try:
    job_id = cp_jobstore.create_job("sync-queue", {"queue": "issue"},
                                    instance_haid=instance_haid, home=home)
    cp_jobstore.transition(job_id, cp_jobstore.STATE_RUNNING, home=home)
    # (client disconnect happens here — no call; the worker keeps folding the log.)
    cp_jobstore.transition(job_id, cp_jobstore.STATE_DONE, home=home)
    job_state = cp_jobstore.read_job(job_id, home=home)
except Exception as exc:  # noqa: BLE001
    fail("job", exc)
job_status = (job_state or {}).get("state") if isinstance(job_state, dict) else None

# 3. APPROVAL under firestore: submit a GATED action (run-suite) -> it enters 'pending'
#    (a keyed JSON record via put_record), then the OWNER approves it -> it dispatches and
#    the record folds to 'approved' (read back via get_record — both firestore-safe).
try:
    sub = cp_approval.submit(owner, "run-suite", {"suite": "unit"}, home=home)
    action_id = sub["action_id"]
    cp_approval.approve(owner, action_id, home=home)
    appr = cp_approval.get(action_id, home=home)
except Exception as exc:  # noqa: BLE001
    fail("approval", exc)
appr_status = (appr or {}).get("state") if isinstance(appr, dict) else None

# 4. NOTIFY (-> deliver_inbox) under firestore: a job_complete ping to the instance inbox
#    (the incident shape: deliver_inbox returned a *_path() accessor in its result), then
#    poll it back as DATA.
try:
    notify_res = cp_notify.job_complete(instance_haid, job_id, home=home)
    inbox = cp_notify.poll(instance_haid, home=home)
except Exception as exc:  # noqa: BLE001
    fail("notify", exc)
notify_ok = bool(notify_res.get("ok")) if isinstance(notify_res, dict) else False
inbox_n = len(inbox) if isinstance(inbox, list) else 0

# 5. DISPATCH under firestore: a non-gated allowlisted action through cp_server.dispatch
#    (the §1 incident flow). Owner identity; a 200 Response is a fired dispatch.
try:
    disp = cp_server.dispatch(owner, "sync-queue", {"queue": "issue"}, home=home)
except Exception as exc:  # noqa: BLE001
    fail("dispatch", exc)
disp_ok = getattr(disp, "status", None) == 200

print("STATUS flow_ok ingest_stored=%d job_status=%s appr_status=%s "
      "notify_ok=%s inbox_n=%d disp_ok=%s"
      % (ingest_stored, job_status, appr_status, notify_ok, inbox_n, bool(disp_ok)))
PYEOF

rm -rf "$HOME_T"
OUT="$(HEIMDALL_HOME="$HOME_T" "$PY" "$DRIVER" 2>"$EXT/driver.err")"
echo "driver: $OUT"
[ -s "$EXT/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$EXT/driver.err"; }
echo

# ── (a) NO-RAISE ──
echo "(a) NO-RAISE — the core request flow under firestore must NOT raise BackendUnavailable"
if grep -q "BackendUnavailable" <<<"$OUT"; then
  STAGE="$(printf '%s' "$OUT" | sed -n 's/.*stage=\([a-z_]*\).*/\1/p')"
  bad "a1 a request handler RAISED BackendUnavailable under firestore (stage=$STAGE) — it still calls path() on a request path (regression)"
elif grep -q "^STATUS flow_ok " <<<"$OUT"; then
  ok "a1 the whole request flow completed under firestore with NO BackendUnavailable"
elif grep -q "handler_raised" <<<"$OUT"; then
  STAGE="$(printf '%s' "$OUT" | sed -n 's/.*stage=\([a-z_]*\).*/\1/p')"
  bad "a1 a request handler raised under firestore (stage=$STAGE, out: $OUT)"
else
  bad "a1 the flow did not complete (out: $OUT)"
fi
echo

# ── (b) RESOLVES ──
echo "(b) RESOLVES — each handler actually did its work under firestore (read back)"
if grep -q "ingest_stored=2" <<<"$OUT"; then
  ok "b1 INGEST stored both on-schema events under firestore"
else
  bad "b1 INGEST did not store the events under firestore (out: $OUT)"
fi
if grep -q "job_status=done" <<<"$OUT"; then
  ok "b2 JOB folded create->running->done (terminal) under firestore — the §4 flight-fix log fold"
else
  bad "b2 JOB did not fold to the 'done' terminal state under firestore (out: $OUT)"
fi
if grep -q "appr_status=approved" <<<"$OUT"; then
  ok "b3 APPROVAL resolved to 'approved' under firestore"
else
  bad "b3 APPROVAL did not resolve to approved under firestore (out: $OUT)"
fi
if grep -qE "notify_ok=True" <<<"$OUT" && grep -qE "inbox_n=[1-9]" <<<"$OUT"; then
  ok "b4 NOTIFY delivered to the inbox and polled it back under firestore"
else
  bad "b4 NOTIFY did not deliver+poll under firestore (out: $OUT)"
fi
if grep -q "disp_ok=True" <<<"$OUT"; then
  ok "b5 DISPATCH fired a non-gated allowlisted action under firestore"
else
  bad "b5 DISPATCH did not fire under firestore (out: $OUT)"
fi

echo
echo "============================================================"
echo "cp-flow-firestore ($MODE): $PASS passed, $FAIL failed"
echo "  (a) no-raise: the core request flow under firestore does NOT throw BackendUnavailable"
echo "  (b) resolves: ingest/job/approval/notify/dispatch each complete under firestore"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
