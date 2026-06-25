#!/usr/bin/env bash
# cp-job-writeread.test.sh — THE WRITE/READ DOC-PATH GATE (the "done not cross-readable" fix).
#
# THE INCIDENT this gate exists to catch. A service-dispatched Cloud Run Job execution
# SUCCEEDED (run-job exited 0 — and run-job exits 0 ONLY when the job reaches `done`, so
# `done` WAS written). YET a fresh service instance polling signed GET /jobs for 180s NEVER
# read state=done. HEIMDALL_STATE_BACKEND=firestore on BOTH. The Job WROTE `done` to a
# Firestore doc the SERVICE does not READ.
#
# THE ROOT CAUSE. A job's durable state is ONE Firestore doc whose address is
#   (firestore-project, database, root-collection, encode_rel("jobs/<id>.ndjson"))
# The doc-id encoding is PURE (a function of the rel only — proven by cp-durability). But THREE
# of the doc's coordinates are read from PER-INSTANCE ENV by cp_state_firestore.FirestoreBackend:
#   HEIMDALL_STATE_BACKEND, HEIMDALL_FIRESTORE_PROJECT (/GOOGLE_CLOUD_PROJECT fallback),
#   HEIMDALL_FIRESTORE_ROOT, HEIMDALL_FIRESTORE_DATABASE.
# The Cloud Run Job execution dispatched by the service inherited only its ARGS override, never
# the service's env — so the Job wrote with whatever identity was baked into it at create-time
# while the service read with its own deploy-time identity. ANY drift => the Job's `done` lands
# in a doc the service never polls => run-job exits 0, GET /jobs never sees done.
#
# WHAT cp-durability already proves and what it does NOT. cp-durability exports ONE
# HEIMDALL_FIRESTORE_ROOT + ONE HEIMDALL_FIRESTORE_PROJECT at the top, shared by BOTH simulated
# instances — so its write and read ALWAYS agree by construction. It proves the home-wipe
# survives; it CANNOT catch a write/read doc mismatch caused by env DIVERGENCE between the
# job-instance and the service-instance. THIS gate guards exactly that gap.
#
# THE GATE (FALSIFIABLE, both halves):
#   • PART A — the REAL run-job entrypoint (the EXACT command the Cloud Run Job container runs)
#       drives a queued job to `done` in a JOB-INSTANCE process (its own env + ephemeral home);
#       a SEPARATE SERVICE-INSTANCE process (its own env + a DIFFERENT ephemeral home) reads the
#       job via the GET /jobs read path (cp_jobstore.read_job, the same fold status_route calls)
#       and MUST see state=done. Execution-success != done-persisted-and-readable — this asserts
#       the readable half the incident lost.
#   • PART B (the FALSIFIER + the fix) — the dispatch-shape proof: with the SERVICE's storage
#       identity in env, CloudRunJobRunner.build_request MUST emit a container ENV override that
#       pins that identity onto the Job execution (so the out-of-process Job inherits the SAME
#       (backend, project, root, db) the service reads). A build that drops the env override
#       (args-only — the pre-fix behavior) leaves the Job to its own baked env: the mismatch
#       returns. This half makes the doc identity travel WITH the dispatch, by construction.
#
# ZERO REAL GCP / ZERO SPEND. Same two modes as cp-durability, auto-selected + PRINTED:
#   (0/1) EMULATOR — a real google.cloud.firestore client against a Firestore emulator (caller-
#         provided FIRESTORE_EMULATOR_HOST, or self-started when gcloud's emulator + the client
#         lib are present; the emulator needs a Java 21+ JRE). This exercises the REAL client's
#         doc resolution — the only mode that can prove the real-client write/read doc identity.
#   (2)   FAKE — a faithful in-process google.cloud.firestore double (the cp-durability fake),
#         persisting to a JSON file OUTSIDE any home; SHIPPED backend code is real. The fake
#         cannot prove the REAL client's project/database resolution, so when it is used PART A
#         is FLAGGED as "fake (cannot prove real-client doc resolution)".
#
# Exit 0 = both parts hold. Nonzero = the write/read gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB

[ -f "$LIB/cp_jobstore.py" ]         || { echo "FATAL: $LIB/cp_jobstore.py missing" >&2; exit 2; }
[ -f "$LIB/cp_jobrunner.py" ]        || { echo "FATAL: $LIB/cp_jobrunner.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }
[ -x "$CLI" ]                        || { echo "FATAL: $CLI missing/not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
note() { printf "  \033[33mNOTE\033[0m %s\n" "$1"; }

# The external store (emulator data / fake JSON) + the per-instance ephemeral homes. CRITICAL:
# the external store lives OUTSIDE both homes so neither home wipe touches it, and the two homes
# are DISTINCT so the job-instance and service-instance never share a local disk (the whole
# point — they must agree via the EXTERNAL store's doc identity, not a shared filesystem).
EXT="$(mktemp -d -t "cp-wr-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_JOB="/tmp/cp_wr_job"
HOME_SVC="/tmp/cp_wr_svc"
rm -rf "$HOME_JOB" "$HOME_SVC"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_JOB" "$HOME_SVC"
}
trap cleanup EXIT

# The shared external-store identity. BOTH the job-instance and the service-instance use these
# (the CORRECT deploy: identical storage identity on the job and the service). The gate proves
# that WITH a shared identity `done` is cross-readable, and (Part B) that the dispatch carries
# that identity so it is shared BY CONSTRUCTION even across two deploy steps.
export HEIMDALL_FIRESTORE_ROOT="writeread_gate"
export HEIMDALL_FIRESTORE_PROJECT="writeread-gate"

# ── mode select (emulator real-client vs faithful in-process fake) — mirrors cp-durability ──
MODE=""

# (0) caller-provided emulator.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_PID=""
  MODE="emulator"
  echo "cp-job-writeread: using caller FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) self-started emulator.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8766"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" >"$EXT/emu.log" 2>&1 &
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
    echo "cp-job-writeread: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-job-writeread: to force REAL mode, start an emulator + export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

# (2) faithful in-process fake (the cp-durability double).
if [ -z "$MODE" ]; then
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore FirestoreBackend uses —
# the SAME double cp-durability ships. PERSISTS to HEIMDALL_FAKE_FS_STORE (a file OUTSIDE any
# home) so two backend instances in two processes share one external store. NOTE: the fake's
# Client ignores project/database, so it CANNOT prove the real client's project/db resolution —
# the harness flags Part A as "fake" in that mode.
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
    def __init__(self, project=None, database=None, **kwargs):
        self.project = project
        self.database = database

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

echo "cp-job-writeread: MODE=$MODE  (external store: $EXT)"
echo

# Firestore is the backend under test for the whole gate.
export HEIMDALL_STATE_BACKEND="firestore"

# ============================================================================
# PART A — run-job (job-instance) writes `done` to the EXACT doc the service reads.
# ============================================================================
echo "PART A — run-job (job-instance env+home) -> done -> fresh service-instance reads done"

# Seed a QUEUED job via the SERVICE-SIDE create path (the rel the service writes/reads). We use
# an allowlisted no-op action so run_job drives it straight to done with no external effect.
SEED_PY="$EXT/seed.py"
cat >"$SEED_PY" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
# the service-side create path: create_job writes the genesis queued line via the backend rel
# the read path later folds. action_type must be allowlisted (resolve to a real handler).
jid = J.create_job(os.environ["ACTION_TYPE"], {}, instance_haid="haid:service", home=home)
print(jid or "NONE")
PYEOF

# Discover an allowlisted action that resolves to a registered handler (so run_job reaches done,
# not an ActionRefused). We ask the substrate itself rather than hard-coding an action name.
PICK_PY="$EXT/pick_action.py"
cat >"$PICK_PY" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_allowlist, cp_handlers
# find an allowlisted action whose handler is registered and which validates with empty params.
for action in getattr(cp_allowlist, "ALLOWED_ACTIONS", {}) or {}:
    try:
        plan = cp_allowlist.validate(action, {})
    except Exception:
        continue
    try:
        cp_handlers.resolve(plan["handler"])
    except Exception:
        continue
    print(action)
    break
else:
    print("NONE")
PYEOF
ACTION_TYPE="$("$PY" "$PICK_PY" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$ACTION_TYPE" ] || [ "$ACTION_TYPE" = "NONE" ]; then
  bad "A0 could not find an allowlisted action with a registered handler validating empty params"
  ACTION_TYPE=""
else
  ok "A0 picked allowlisted action '$ACTION_TYPE' (validates + handler registered) for the seed job"
fi

# The READER: the GET /jobs read path (cp_jobstore.read_job == the fold status_route calls),
# run in a SEPARATE process with the SERVICE-INSTANCE env+home.
READ_PY="$EXT/read.py"
cat >"$READ_PY" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
folded = J.read_job(sys.argv[1], home)
print("MISSING" if not folded else "FOUND|%s" % folded.get("state"))
PYEOF

if [ -n "$ACTION_TYPE" ]; then
  # (1) SERVICE creates the queued job (service env + service home).
  JID="$(HEIMDALL_HOME="$HOME_SVC" ACTION_TYPE="$ACTION_TYPE" "$PY" "$SEED_PY" 2>"$EXT/seed.err" | tr -d '[:space:]')"
  if [ -n "$JID" ] && [ "$JID" != "NONE" ]; then
    ok "A1 service created queued job ($JID) via create_job (service home, firestore)"
  else
    bad "A1 service failed to create the seed job"; cat "$EXT/seed.err" >&2
  fi

  # (2) the JOB-INSTANCE drives it with the REAL run-job CLI — K_SERVICE set (we ARE a Cloud Run
  #     Job), HEIMDALL_JOB_RUNNER=subprocess would re-dispatch, so we run the run-job subcommand
  #     DIRECTLY (the exact command the Cloud Run Job container's entrypoint runs). A DIFFERENT
  #     ephemeral home than the seeding step proves the job-instance and service-instance share
  #     NO local disk — they can only agree via the external store's doc identity.
  if [ -n "${JID:-}" ] && [ "$JID" != "NONE" ]; then
    set +e
    K_SERVICE="cp-long-job" HEIMDALL_HOME="$HOME_JOB" \
      "$CLI" run-job "$JID" --home "$HOME_JOB" --actor "haid:job-instance" \
      >"$EXT/runjob.out" 2>"$EXT/runjob.err"
    RUNJOB_RC=$?
    set -e 2>/dev/null || true
    if [ "$RUNJOB_RC" -eq 0 ]; then
      ok "A2 run-job (job-instance home, K_SERVICE set) drove $JID to done — exit 0 (done reached)"
    else
      bad "A2 run-job exited $RUNJOB_RC (expected 0 == done). stderr:"; tail -5 "$EXT/runjob.err" >&2
    fi

    # (3) THE CARDINAL — a FRESH service-instance (service env + a home that is NOT the job's home)
    #     reads the job via the GET /jobs read path. It MUST see state=done. This is the half the
    #     incident lost: execution succeeded yet the service never read done.
    rm -rf "$HOME_SVC"   # the service instance that reads is fresh (scale-to-zero) — new home.
    READ_RES="$(HEIMDALL_HOME="$HOME_SVC" "$PY" "$READ_PY" "$JID" 2>"$EXT/read.err")"
    READ_FOUND="${READ_RES%%|*}"
    READ_STATE="$(echo "$READ_RES" | cut -d'|' -f2)"
    if [ "$MODE" = "emulator" ]; then
      if [ "$READ_FOUND" = "FOUND" ] && [ "$READ_STATE" = "done" ]; then
        ok "A3 (CARDINAL) fresh service-instance reads state=done from the SAME doc run-job wrote (real client)"
      else
        bad "A3 (CARDINAL) service-instance did NOT read done (got '$READ_RES') — run-job wrote a doc the service does not read"
        cat "$EXT/read.err" >&2
      fi
    else
      if [ "$READ_FOUND" = "FOUND" ] && [ "$READ_STATE" = "done" ]; then
        ok "A3 fresh service-instance reads state=done (fake — cannot prove real-client doc resolution)"
        note "A3 ran under the in-process FAKE: it cannot prove the REAL client's project/database doc resolution. Run with a Firestore emulator (Java 21+) to prove the real-client path."
      else
        bad "A3 service-instance did NOT read done under the fake (got '$READ_RES')"
        cat "$EXT/read.err" >&2
      fi
    fi
  fi
fi

echo

# ============================================================================
# PART B — the dispatch carries the storage identity so write/read agree BY CONSTRUCTION.
# ============================================================================
echo "PART B — CloudRunJobRunner.build_request pins the service's storage identity onto the Job"

# The fix that makes Part A hold even across two deploy steps: the dispatch propagates the
# SERVICE's storage-identity env into the Job execution as a container ENV override, so the Job
# inherits the SAME (backend, project, root, db) — the doc is shared by construction. We assert
# build_request emits that env override (the real run_v2 message classes, offline, zero GCP). If
# run_v2 is absent we SKIP this half loudly (the suite driver should install the pin).
BUILD_PY="$EXT/build_request.py"
cat >"$BUILD_PY" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
try:
    from google.cloud import run_v2  # noqa: F401 — presence probe; build_request needs it.
except ImportError as exc:
    print("SKIP B: google-cloud-run not importable (%s) — install google-cloud-run to exercise "
          "the real run_v2 RunJobRequest env override" % exc)
    sys.exit(0)

import cp_jobrunner

# the SERVICE's resolved storage identity (what the service would read with).
os.environ["GOOGLE_CLOUD_PROJECT"] = "writeread-gate"            # resource name needs a project.
os.environ["HEIMDALL_STATE_BACKEND"] = "firestore"
os.environ["HEIMDALL_FIRESTORE_PROJECT"] = "writeread-gate"
os.environ["HEIMDALL_FIRESTORE_ROOT"] = "writeread_gate"
os.environ.pop("HEIMDALL_FIRESTORE_DATABASE", None)
for _k in ("HEIMDALL_CP_JOB_REGION", "CLOUD_RUN_REGION", "FUNCTION_REGION"):
    os.environ.pop(_k, None)

JID = "job-writeread-build-TEST"
req = cp_jobrunner.CloudRunJobRunner().build_request(JID)
cos = list(req.overrides.container_overrides)
env_map = {e.name: e.value for e in list(cos[0].env)} if len(cos) == 1 else {}
args = list(cos[0].args) if len(cos) == 1 else []

# B1 — the env override pins the SERVICE's storage identity (so the Job writes the SAME doc).
b1 = (env_map.get("HEIMDALL_STATE_BACKEND") == "firestore"
      and env_map.get("HEIMDALL_FIRESTORE_PROJECT") == "writeread-gate"
      and env_map.get("HEIMDALL_FIRESTORE_ROOT") == "writeread_gate")
print("PASS B1: dispatch env override pins the service's firestore identity (backend/project/root) "
      "onto the Job — write doc == read doc by construction" if b1 else
      "FAIL B1: env override missing/mismatched storage identity: %r" % env_map)

# B2 (FALSIFIER) — the env override is NON-EMPTY. The pre-fix behavior (args-only) left the env
#      empty and the Job wrote to its own baked identity — the write/read mismatch. This catches it.
print("PASS B2 (falsifier): env override is NON-EMPTY — the Job is NOT left to its own baked identity"
      if env_map else
      "FAIL B2 (falsifier): env override is EMPTY — the Job writes its own env's doc, not the "
      "service's; the 'done not cross-readable' incident is back")

# B3 — the args override is intact alongside the env (run-job,<id> still exactly carried).
print("PASS B3: args override still ['run-job', '%s'] alongside the env override" % JID
      if args == ["run-job", JID] else
      "FAIL B3: args override is %r (expected ['run-job', '%s'])" % (args, JID))
PYEOF

while IFS= read -r line; do
  case "$line" in
    PASS*)  ok  "${line#PASS }" ;;
    FAIL*)  bad "${line#FAIL }" ;;
    SKIP*)  printf "  \033[33mSKIP\033[0m %s\n" "${line#SKIP }" ;;
  esac
done < <(env -u HEIMDALL_JOB_RUNNER -u K_SERVICE "$PY" "$BUILD_PY" 2>&1)

echo
# ── verdict ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo "cp-job-writeread ($MODE): $PASS passed, $FAIL failed"
echo "  A: run-job's `done` is cross-readable by a fresh service-instance (the doc is shared)"
echo "  B: the dispatch propagates the storage identity, so write doc == read doc by construction"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
