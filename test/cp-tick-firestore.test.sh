#!/usr/bin/env bash
# cp-tick-firestore.test.sh — THE SCHEDULER-TICK-UNDER-FIRESTORE REGRESSION GATE.
#
# THE INCIDENT THIS GATES (live production, why the bug shipped). The control plane ran
# on Cloud Run with HEIMDALL_STATE_BACKEND=firestore. /readyz reported the backend
# ready (its probe uses _db()/read_lines — firestore-safe), yet cp_boot's per-minute
# scheduler tick STILL threw "BackendUnavailable" every 60s in the SAME process. Root
# cause: cp_boot.run_tick -> _owner_haids() enumerated the owner identities by calling
# cp_auth.keys_path(home) + open()ing that file. keys_path() routes to backend.path(),
# and FirestoreBackend.path() RAISES BackendUnavailable BY DESIGN (a firestore-backed
# rel has no local file). The tick path diverged from the readyz probe path: readyz
# never calls path(); the tick did. It shipped because EVERY cp suite ran on the LOCAL
# backend, where LocalBackend.path() returns a real path — so the firestore path()
# refusal in the tick chain was never exercised. The fix: _owner_haids reads the owner
# registry through the firestore-safe StateBackend accessor (cp_auth.owner_haids ->
# _load_keys -> get_record), never path()/open().
#
# THIS GATE asserts, under HEIMDALL_STATE_BACKEND=firestore, each FALSIFIABLE:
#
#   (a) NO-RAISE — cp_boot.run_tick() over a registered owner with a DUE schedule
#       completes WITHOUT raising BackendUnavailable. If the tick chain calls path()
#       (the regression), run_tick raises and (a) FAILS. The driver catches every
#       exception and prints its type, so a BackendUnavailable surfaces explicitly.
#   (b) FIRES — the due schedule actually DISPATCHES under firestore: run_tick returns
#       a fired-dispatch outcome for the scheduled action AND a `dispatch` audit row for
#       it lands in the firestore-backed audit log (read back through the backend). A
#       tick that silently did nothing — or could not read the schedule/owner store —
#       would NOT produce the fired outcome or the audit row, and (b) FAILS.
#
# The same firestore mode-selection as cp-auth-durability / cp-durability: (0) a
# caller-provided emulator (real client), else (1) a self-started gcloud emulator (real
# client; needs a Java 21+ JRE), else (2) a faithful in-process FAKE google.cloud.firestore
# (the SAME fake those gates use). The test PRINTS which mode it used. ZERO real GCP / ZERO
# spend. NO SECRET on disk: the PKI test seed lives only in memory, passed to children by env.
#
# Exit 0 = (a) AND (b) hold. Nonzero = the gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_boot.py" ]            || { echo "FATAL: $LIB/cp_boot.py missing" >&2; exit 2; }
[ -f "$LIB/cp_scheduler.py" ]       || { echo "FATAL: $LIB/cp_scheduler.py missing" >&2; exit 2; }
[ -f "$LIB/cp_auth.py" ]            || { echo "FATAL: $LIB/cp_auth.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state.py" ]           || { echo "FATAL: $LIB/cp_state.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (Firestore emulator data / fake JSON store + the fake package).
# Lives OUTSIDE the per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-tickfs-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"

# The single per-instance ephemeral home (the tick runs in one process / instance).
HOME_T="/tmp/tickfsT"
rm -rf "$HOME_T"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_T"
}
trap cleanup EXIT

# A dedicated root collection so this gate's store never collides with another gate's.
export HEIMDALL_FIRESTORE_ROOT="tick_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-tick-firestore-test"

# ── a TEST seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
# A fixed 32-byte seed so the seeded server identity (the owner the tick fires AS) is
# deterministic. Exported to children via env only (the channel --set-secrets uses).
MK_SEED="$EXT/mk_seed.py"
cat >"$MK_SEED" <<'PYEOF'
import base64
print(base64.b64encode(bytes((i * 5 + 1) % 256 for i in range(32))).decode())
PYEOF
SEED_B64="$("$PY" "$MK_SEED")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"

# The fixed server HAID the seeded owner identity binds to (the tick's owner principal).
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_PID=""
  MODE="emulator"
  echo "cp-tick-firestore: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8767"
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
    echo "cp-tick-firestore: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-tick-firestore: to force REAL mode, start an emulator yourself and export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
  # cp-auth-durability gates use (a sitecustomize.py on PYTHONPATH registers it into
  # sys.modules before any import), persisting to a JSON file so reads after the tick see
  # the same store. SHIPPED backend code is real; only the external service is a double.
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses. PERSISTS the whole store to the JSON
# file named by HEIMDALL_FAKE_FS_STORE so reads after a write (across processes or after a
# tick) share one durable external store.
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

echo "cp-tick-firestore: MODE=$MODE  (external store: $EXT)"
echo

# Everything from here runs under the firestore backend (the deploy profile that broke).
export HEIMDALL_STATE_BACKEND="firestore"

# Confirm the audit read API the driver uses still exists (fail loud if it drifted).
AUDIT_READER="$("$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_audit
print("search" if hasattr(cp_audit, "search") else "")
PYEOF
)"
if [ -z "$AUDIT_READER" ]; then
  echo "cp-tick-firestore: cp_audit.search not found — adjust the driver's audit reader" >&2
  exit 2
fi

# ── the driver: one process that (1) registers an OWNER, (2) creates a DUE schedule,
#    (3) runs cp_boot.run_tick at the due minute, (4) reads back the audit log — all
#    under the firestore backend. It prints a single status line the bash gate parses. ──
DRIVER="$EXT/tick_driver.py"
cat >"$DRIVER" <<'PYEOF'
import datetime
import os
import sys

sys.path.insert(0, os.environ["LIB"])

import cp_auth
import cp_audit
import cp_boot
import cp_scheduler

home = os.environ["HEIMDALL_HOME"]

# 1. Register the seeded server identity AS AN OWNER under the firestore backend. This is
#    the owner principal cp_boot.run_tick enumerates (the exact registry read that called
#    path() in the incident). ensure_server_identity derives the seeded pubkey + registers
#    it owner:true through the StateBackend (get_record/put_record — firestore-safe).
res = cp_auth.ensure_server_identity(home=home)
if not (res.get("seeded") and res.get("registered")):
    print("STATUS owner_register_failed res=%r" % res)
    sys.exit(0)
owner_haid = res["haid"]

# 2. Create a DUE schedule under firestore: an allowlisted, NON-gated action
#    (sync-queue) on a cron that matches the chosen minute. The owner_haid is the same
#    seeded owner, so run_tick (which fires AS each owner) will pick it up.
now = datetime.datetime(2026, 1, 1, 0, 0, tzinfo=datetime.timezone.utc)  # a fixed minute
cron = "%d %d %d %d *" % (now.minute, now.hour, now.day, now.month)      # matches `now`
identity = cp_auth.Identity(owner_haid, owner=True)
try:
    entry = cp_scheduler.create_schedule(
        identity, "sync-queue", {"queue": "issue"}, cron, home=home,
    )
except Exception as exc:  # noqa: BLE001 — a create failure under firestore is itself a bug.
    print("STATUS create_failed %s: %s" % (type(exc).__name__, exc))
    sys.exit(0)

# Sanity: the schedule is DUE at `now` under firestore (read back through the backend).
due = cp_scheduler.due_schedules(now, home=home)
if not any(d["schedule_id"] == entry["schedule_id"] for d in due):
    print("STATUS not_due due=%r" % [d["schedule_id"] for d in due])
    sys.exit(0)

# 3. THE TICK — run_tick enumerates owners (the path() raise site in the incident) and
#    fires each owner's due schedules through cp_server.dispatch. We catch EVERY exception
#    so a BackendUnavailable (the regression) surfaces by name instead of a bare traceback.
try:
    fired = cp_boot.run_tick(home=home, now=now)
except Exception as exc:  # noqa: BLE001 — the regression raises here; name it.
    print("STATUS tick_raised %s: %s" % (type(exc).__name__, exc))
    sys.exit(0)

# (a) NO-RAISE held (we got here) AND (b) the due schedule fired: a fired outcome for our
#     action_type, and a `dispatch` audit row for it in the firestore-backed audit log.
fired_actions = [f.get("action_type") for f in fired]
fired_ok = any(f.get("action_type") == "sync-queue" for f in fired)

dispatch_rows = cp_audit.search(home=home, event="dispatch", action_type="sync-queue")
audited = len(dispatch_rows) > 0

print("STATUS tick_ok fired=%r fired_ok=%s audited=%s n_dispatch_rows=%d"
      % (fired_actions, fired_ok, audited, len(dispatch_rows)))
PYEOF

rm -rf "$HOME_T"
OUT="$(HEIMDALL_HOME="$HOME_T" "$PY" "$DRIVER" 2>"$EXT/driver.err")"
echo "driver: $OUT"
[ -s "$EXT/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$EXT/driver.err"; }
echo

# ── (a) NO-RAISE ──
echo "(a) NO-RAISE — cp_boot.run_tick under firestore must NOT raise BackendUnavailable"
if grep -q "BackendUnavailable" <<<"$OUT"; then
  bad "a1 run_tick RAISED BackendUnavailable under firestore — the tick chain still calls path() (regression)"
elif grep -q "^STATUS tick_ok " <<<"$OUT"; then
  ok "a1 run_tick completed under firestore with NO BackendUnavailable (the tick path is firestore-safe)"
else
  bad "a1 run_tick did not reach the tick (out: $OUT)"
fi
echo

# ── (b) FIRES ──
echo "(b) FIRES — the due schedule must dispatch under firestore (fired + audit row)"
if grep -q "fired_ok=True" <<<"$OUT"; then
  ok "b1 the due sync-queue schedule FIRED a dispatch under firestore (run_tick returned its outcome)"
else
  bad "b1 the due schedule did NOT fire under firestore (out: $OUT)"
fi
if grep -q "audited=True" <<<"$OUT"; then
  ok "b2 a 'dispatch' audit row for the fired action landed in the firestore-backed audit log"
else
  bad "b2 no firestore-backed 'dispatch' audit row for the fired action (out: $OUT)"
fi

echo
echo "============================================================"
echo "cp-tick-firestore ($MODE): $PASS passed, $FAIL failed"
echo "  (a) no-raise: run_tick under firestore does NOT throw BackendUnavailable"
echo "  (b) fires:    a due schedule dispatches + audits under firestore"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
