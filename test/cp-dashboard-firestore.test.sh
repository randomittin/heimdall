#!/usr/bin/env bash
# cp-dashboard-firestore.test.sh — THE DASHBOARD-READ-UNDER-FIRESTORE REGRESSION GATE.
#
# THE INCIDENT CLASS THIS GATES (production Cloud Run, the firestore-only path() class —
# THIRD instance). The control plane ran with HEIMDALL_STATE_BACKEND=firestore.
# FirestoreBackend.path() RAISES BackendUnavailable BY DESIGN. A code path on a LIVE READ
# handler called backend.path() — and it shipped because EVERY cp suite (and the existing
# cp-flow-firestore gate) ran the WRITE path but never the DASHBOARD READ path.
#   • cp_ingest.stored_instances() guarded its loop with os.path.isdir(backend.path(...)).
#     backend.path() raises under firestore the moment list_names yields a name.
#   • SECOND, subtler firestore-only defect in the SAME function: the observe store is the
#     ONLY NESTED store (observe/<slug>/events.ndjson). FirestoreBackend.list_names only
#     surfaced LEAF doc basenames, so list_names("observe") returned [] under firestore —
#     the dashboard silently showed ZERO instances even with ingested data (data loss in
#     the cross-dev view). Both are firestore-only and invisible to local-backend suites.
# This gate drives the cross-dev DASHBOARD READ path under firestore — the handler a real
# /dashboard request reaches — and asserts it neither raises NOR silently drops instances.
#
# THE FLOW EXERCISED (each is a real dashboard-read store access under firestore):
#   1. INGEST   — cp_ingest.ingest_batch over TWO instance HAIDs (the observe store now
#                 holds two nested partitions, the condition that triggered both defects).
#   2. ENUMERATE— cp_ingest.stored_instances: must return BOTH slugs (not [] , not raise).
#   3. READ     — cp_ingest.read_instance(slug): each partition's events read back.
#   4. AGGREGATE— cp_dashboard.cross_dev: the §5 cross-dev fleet aggregate, the body the
#                 /dashboard route returns. Must see has_data + both instances + the events.
#
# ASSERTIONS (each FALSIFIABLE):
#   (a) NO-RAISE — the whole dashboard read completes with NO BackendUnavailable anywhere.
#       The driver catches EVERY exception and prints its type, so a path()-on-read-path
#       regression surfaces by name (BackendUnavailable) and (a) FAILS.
#   (b) RESOLVES — the dashboard actually SAW the ingested fleet under firestore:
#       stored_instances returns BOTH slugs, read_instance returns each partition's events,
#       and cross_dev reports has_data=True with both instances and the full event count.
#       A handler that silently returned [] (the list_names-nesting defect) FAILS (b).
#
# Same firestore mode-selection as cp-flow-firestore / cp-tick-firestore / cp-durability:
# (0) caller emulator, (1) self-started gcloud emulator, else (2) the SAME faithful
# in-process FAKE google.cloud.firestore those gates use. ZERO real GCP / ZERO spend. NO
# SECRET on disk: the PKI seed lives only in memory, passed to children by env. PRINTS mode.
#
# Exit 0 = (a) AND (b) hold. Nonzero = the gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_ingest cp_dashboard cp_audit cp_state cp_state_firestore; do
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
EXT="$(mktemp -d -t "cp-dashfs-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"

# The single per-instance ephemeral home (the read runs in one process / instance).
HOME_T="/tmp/dashfsT"
rm -rf "$HOME_T"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_T"
}
trap cleanup EXIT

# A dedicated root collection so this gate's store never collides with another gate's.
export HEIMDALL_FIRESTORE_ROOT="dashboard_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-dashboard-firestore-test"

# ── a TEST seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
MK_SEED="$EXT/mk_seed.py"
cat >"$MK_SEED" <<'PYEOF'
import base64
print(base64.b64encode(bytes((i * 11 + 5) % 256 for i in range(32))).decode())
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
  echo "cp-dashboard-firestore: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8771"
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
    echo "cp-dashboard-firestore: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-dashboard-firestore: to force REAL mode, start an emulator yourself and export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
  # cp-tick-firestore / cp-flow-firestore gates use (a sitecustomize.py on PYTHONPATH
  # registers it into sys.modules before any import), persisting to a JSON file so reads
  # after a write see the same store. SHIPPED backend code is real; only the external
  # service is a double.
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

echo "cp-dashboard-firestore: MODE=$MODE  (external store: $EXT)"
echo

# Everything from here runs under the firestore backend (the deploy profile that broke).
export HEIMDALL_STATE_BACKEND="firestore"

# ── the driver: one process that drives the cross-dev dashboard READ path end-to-end
#    under the firestore backend and prints a single status line the bash gate parses. It
#    uses the SAME store APIs the /dashboard route handler calls, so a path() on any of
#    those read paths surfaces here as a named exception. ──
DRIVER="$EXT/dash_driver.py"
cat >"$DRIVER" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])

import cp_dashboard
import cp_ingest

home = os.environ["HEIMDALL_HOME"]


def fail(stage, exc):
    print("STATUS handler_raised stage=%s %s: %s" % (stage, type(exc).__name__, exc))
    sys.exit(0)


# Two verified instance HAIDs (the observe store gets TWO nested partitions — the exact
# condition that triggered both the path()-raise and the list_names-nesting defect).
inst_a = "haid:dash-instance-a"
inst_b = "haid:dash-instance-b"

# 1. INGEST both instances under firestore (the POST /ingest handler body). inst_a gets
#    two events, inst_b gets one — so the fleet event count is a known, falsifiable total.
try:
    cp_ingest.ingest_batch(inst_a, [
        {"event_type": "phase", "run_id": "r1", "phase": "build"},
        {"event_type": "outcome", "run_id": "r1", "outcome": "ok"},
    ], home=home)
    cp_ingest.ingest_batch(inst_b, [
        {"event_type": "phase", "run_id": "r2", "phase": "test"},
    ], home=home)
except Exception as exc:  # noqa: BLE001
    fail("ingest", exc)

# 2. ENUMERATE: stored_instances must return BOTH slugs (the dashboard group-by keys).
#    The defect made this raise BackendUnavailable OR silently return [].
try:
    slugs = cp_ingest.stored_instances(home=home)
except Exception as exc:  # noqa: BLE001
    fail("stored_instances", exc)
n_slugs = len(slugs) if isinstance(slugs, list) else -1

# 3. READ each partition back through the backend (the per-dev scan the dashboard runs).
try:
    total_events = 0
    for slug in slugs:
        total_events += len(cp_ingest.read_instance(slug, home=home))
except Exception as exc:  # noqa: BLE001
    fail("read_instance", exc)

# 4. AGGREGATE: cross_dev — the body the /dashboard route returns. Must see has_data +
#    both instances. (The dashboard_route just wraps this in a Response.)
try:
    view = cp_dashboard.cross_dev(home=home)
except Exception as exc:  # noqa: BLE001
    fail("cross_dev", exc)
has_data = bool(view.get("has_data")) if isinstance(view, dict) else False
view_instances = len(view.get("instances") or []) if isinstance(view, dict) else -1

print("STATUS dash_ok n_slugs=%d total_events=%d has_data=%s view_instances=%d"
      % (n_slugs, total_events, has_data, view_instances))
PYEOF

rm -rf "$HOME_T"
OUT="$(HEIMDALL_HOME="$HOME_T" "$PY" "$DRIVER" 2>"$EXT/driver.err")"
echo "driver: $OUT"
[ -s "$EXT/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$EXT/driver.err"; }
echo

# ── (a) NO-RAISE ──
echo "(a) NO-RAISE — the cross-dev dashboard read under firestore must NOT raise BackendUnavailable"
if printf '%s' "$OUT" | grep -q "BackendUnavailable"; then
  STAGE="$(printf '%s' "$OUT" | sed -n 's/.*stage=\([a-z_]*\).*/\1/p')"
  bad "a1 a read handler RAISED BackendUnavailable under firestore (stage=$STAGE) — it still calls path() on a read path (regression)"
elif printf '%s' "$OUT" | grep -q "^STATUS dash_ok "; then
  ok "a1 the whole dashboard read completed under firestore with NO BackendUnavailable"
elif printf '%s' "$OUT" | grep -q "handler_raised"; then
  STAGE="$(printf '%s' "$OUT" | sed -n 's/.*stage=\([a-z_]*\).*/\1/p')"
  bad "a1 a read handler raised under firestore (stage=$STAGE, out: $OUT)"
else
  bad "a1 the dashboard read did not complete (out: $OUT)"
fi
echo

# ── (b) RESOLVES ──
echo "(b) RESOLVES — the dashboard actually SAW the ingested fleet under firestore (read back)"
if printf '%s' "$OUT" | grep -q "n_slugs=2"; then
  ok "b1 stored_instances returned BOTH instance slugs under firestore (not [] — the list_names-nesting defect is fixed)"
else
  bad "b1 stored_instances did not return both slugs under firestore (out: $OUT) — instances silently dropped"
fi
if printf '%s' "$OUT" | grep -q "total_events=3"; then
  ok "b2 read_instance read back all 3 events across the two partitions under firestore"
else
  bad "b2 read_instance did not read back all events under firestore (out: $OUT)"
fi
if printf '%s' "$OUT" | grep -q "has_data=True" && printf '%s' "$OUT" | grep -q "view_instances=2"; then
  ok "b3 cross_dev reported has_data + both instances (the /dashboard body is correct under firestore)"
else
  bad "b3 cross_dev did not report the fleet under firestore (out: $OUT)"
fi

echo
echo "============================================================"
echo "cp-dashboard-firestore ($MODE): $PASS passed, $FAIL failed"
echo "  (a) no-raise: the cross-dev dashboard read under firestore does NOT throw BackendUnavailable"
echo "  (b) resolves: stored_instances/read_instance/cross_dev see the ingested fleet under firestore"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
