#!/usr/bin/env bash
# cp-job-execution.test.sh — THE FAIL→PASS PROOF that job EXECUTION is durable, not just
# job STATE. DESIGN DOSSIER §4 (the flight fix) + the Cloud Run execution model.
#
# THE BUG (confirmed). start_route runs jobs on an in-process threading.Thread(daemon=True)
# launched AFTER the HTTP response. On Cloud Run, CPU is throttled to ~0 outside a request
# and min-instances=0 scales the instance to zero shortly after the response — so the daemon
# thread is starved/killed and the job is left `queued` in the durable store FOREVER. State
# (Firestore) survived; EXECUTION did not.
#
# THE FIX. cp_jobrunner.JobRunner runs the job in a unit of work whose lifetime is INDEPENDENT
# of the request that started it: a detached subprocess locally (SubprocessRunner), a real
# Cloud Run Job execution in prod (CloudRunJobRunner) — both running the SAME `run-job`
# entrypoint to completion out of process. start_route dispatches via get_job_runner().
#
# WHAT THIS GATE PROVES (each half falsifiable, run for $0, zero GCP):
#
#   A. EXISTING BEHAVIOR (default thread runner): the cp-jobs / cp-wired / cp-integration
#      suites stay green — the dispatch seam did not regress the laptop path. (Run separately
#      by the suite driver; here we re-confirm the default selection is `thread`.)
#
#   B. THE CARDINAL (durable execution OUT OF PROCESS, firestore backend): in SUBPROCESS mode
#      with HEIMDALL_STATE_BACKEND=firestore (an EXTERNAL store outside any HEIMDALL_HOME), a
#      dispatching process creates + dispatches a job, then DIES IMMEDIATELY (os._exit) —
#      SIMULATING Cloud Run starving/killing the service the instant it responds. The detached
#      `run-job` child runs to completion against the SAME external firestore store. A FRESH
#      process (no shared memory, a brand-new ephemeral home — a cold instance) then reads the
#      job back as `done` WITH its result. Execution survived the dispatcher's death.
#
#   C. THE FALSIFIER (bug→fix, side by side): the SAME create+dispatch+os._exit race, run
#      BOTH ways against the SAME firestore store:
#        * THREAD runner   -> the daemon thread dies with the process -> job stays `queued`
#                             (NOT done) -> this is the BUG, asserted RED.
#        * SUBPROCESS runner-> the detached child completes out of process -> job `done`
#                             -> this is the FIX, asserted GREEN.
#      Showing both halves makes the gate genuinely distinguish the broken model from the
#      fixed one — a build that "fixed" nothing (still in-thread) would make C's subprocess
#      half stay queued and FAIL here.
#
# The EXTERNAL "Firestore" is the SAME faithful in-process double the durability gate ships
# (cp-durability / cp-flow-firestore): a sitecustomize.py binds a fake google.cloud.firestore
# that PERSISTS to a JSON file OUTSIDE any HEIMDALL_HOME, so a fresh process reads the same
# state back — exactly the property that makes execution-out-of-process observable. The
# SHIPPED cp_state_firestore + cp_jobrunner code runs UNCHANGED; only the external service is
# a double. If a real client lib + a caller-set FIRESTORE_EMULATOR_HOST are present, the
# shipped backend talks to that real emulator instead (same precedence as cp-durability).
#
# Exit 0 == every half holds (the bug is RED with thread, the fix is GREEN with subprocess).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB

[ -f "$LIB/cp_jobrunner.py" ] || { echo "FATAL: $LIB/cp_jobrunner.py missing" >&2; exit 2; }
[ -f "$LIB/cp_jobstore.py" ]  || { echo "FATAL: $LIB/cp_jobstore.py missing" >&2; exit 2; }
[ -x "$CLI" ]                 || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── isolated scratch: an EXTERNAL firestore store dir (outside any server home) + fake pkg ──
EXT="$(mktemp -d -t "cp-jobexec.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$EXT"' EXIT

# Shared firestore root + project so every process (dispatcher, detached child, fresh reader)
# addresses the SAME external store — the durability seam.
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_FIRESTORE_ROOT="jobexec_gate"
export HEIMDALL_FIRESTORE_PROJECT="jobexec-gate"

# ── decide firestore mode: real emulator (if caller pre-set one + client present) else fake ─
MODE=""
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "cp-job-execution: using caller FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the faithful in-process google.cloud.firestore double, persisting to a JSON
  # file OUTSIDE any home (lifted verbatim from test/cp-durability.test.sh; the shipped backend
  # runs unchanged, only the external service is a double).
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
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

echo "============================================================"
echo "cp-job-execution — durable EXECUTION (out-of-process) FAIL→PASS proof"
echo "  external firestore store: $EXT  (outside every process home, MODE=$MODE)"
echo "============================================================"

# ── A. EXISTING BEHAVIOR — the default runner selection is `thread` (laptop path unchanged) ──
echo
echo "A. EXISTING BEHAVIOR — default runner is in-process thread (laptop path)"
DEFAULT_RUNNER="$(env -u HEIMDALL_JOB_RUNNER -u K_SERVICE "$PY" -c \
  "import sys,os;sys.path.insert(0,os.environ['LIB']);import cp_jobrunner as r;print(r.get_job_runner().name)")"
[ "$DEFAULT_RUNNER" = "thread" ] \
  && ok "default HEIMDALL_JOB_RUNNER selection is 'thread' (cp-jobs/cp-wired/cp-integration run on this)" \
  || bad "default runner is '$DEFAULT_RUNNER' (expected thread — laptop path would regress)"

AUTO_RUNNER="$(env -u HEIMDALL_JOB_RUNNER K_SERVICE=svc "$PY" -c \
  "import sys,os;sys.path.insert(0,os.environ['LIB']);import cp_jobrunner as r;print(r.get_job_runner().name)")"
[ "$AUTO_RUNNER" = "cloudrun-job" ] \
  && ok "AUTO selection under K_SERVICE is 'cloudrun-job' (out-of-process on Cloud Run)" \
  || bad "AUTO runner under K_SERVICE is '$AUTO_RUNNER' (expected cloudrun-job)"

# ── the shared dispatch-then-die driver: create a job, dispatch via the given runner, then
#    os._exit the dispatching process IMMEDIATELY (simulating Cloud Run killing the service the
#    instant it responds). Prints the job_id on stdout. The runner mode is argv[1]; the home
#    (a FRESH ephemeral home per call — a distinct "instance") is argv[2].
DISPATCH_PY="$EXT/dispatch_then_die.py"
cat >"$DISPATCH_PY" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])
runner_name, home = sys.argv[1], sys.argv[2]
os.environ["HEIMDALL_JOB_RUNNER"] = runner_name
# the external firestore store is selected via HEIMDALL_STATE_BACKEND=firestore (inherited).
import cp_jobrunner
import cp_jobstore as js

job_id = js.create_job("run-task-X", {"task_id": "oop-exec"},
                       instance_haid="haid:dispatcher", home=home)
sys.stdout.write(job_id + "\n")
sys.stdout.flush()
# DISPATCH, then DIE. With the thread runner the daemon thread has not run yet -> killed with
# the process. With the subprocess runner the detached child is its OWN session -> survives.
cp_jobrunner.get_job_runner(home=home).dispatch(
    job_id, actor_haid="haid:dispatcher", home=home)
os._exit(0)  # hard kill — no atexit, no thread join. THE Cloud-Run-kills-the-service moment.
PYEOF

# read a job's folded state from a FRESH process (a brand-new ephemeral home == a cold instance
# that shares NO memory with the dispatcher or the child — only the external firestore store).
READ_PY="$EXT/read_state.py"
cat >"$READ_PY" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as js

job_id, home = sys.argv[1], sys.argv[2]
folded = js.read_job(job_id, home)
sys.stdout.write((folded.get("state") if folded else "none") or "none")
PYEOF

# poll the external store from a FRESH process until the job reaches `done` or a timeout.
# Each poll is a brand-new process (cold instance) reading the durable store back.
poll_until_done() {
  local job_id="$1" home="$2" tries="${3:-60}" st=""
  for _ in $(seq 1 "$tries"); do
    st="$("$PY" "$READ_PY" "$job_id" "$home")"
    [ "$st" = "done" ] && { echo "$st"; return 0; }
    "$PY" -c "import time;time.sleep(0.1)"
  done
  echo "$st"
  return 1
}

# ── B. THE CARDINAL — SUBPROCESS mode: dispatcher dies, detached child finishes, fresh read = done ──
echo
echo "B. CARDINAL — durable execution out of process (subprocess runner, firestore backend)"
HOME_DISP="$EXT/home-dispatcher"   # the dispatching "instance" home (gets killed/wiped).
HOME_READ="$EXT/home-reader"       # a FRESH cold instance home — shares nothing but the store.

SUB_JID="$("$PY" "$DISPATCH_PY" subprocess "$HOME_DISP")"
if [ -n "$SUB_JID" ]; then
  ok "POST/dispatch returned a job_id immediately, then the dispatcher process DIED ($SUB_JID)"
else
  bad "subprocess dispatcher did not return a job_id"
fi
# the dispatcher is dead; WIPE its ephemeral home to prove nothing local carried the execution.
rm -rf "$HOME_DISP"
SUB_STATE="$(poll_until_done "$SUB_JID" "$HOME_READ" 80)"
if [ "$SUB_STATE" = "done" ]; then
  ok "the DETACHED child ran the job to 'done' OUT OF PROCESS — read back from a FRESH instance after the dispatcher died"
else
  bad "subprocess job did not reach done from a fresh process (state=$SUB_STATE) — execution did NOT survive"
fi
# and the result is present (the handler actually ran, not just a state flip).
SUB_RESULT="$("$PY" -c "import sys,os;sys.path.insert(0,os.environ['LIB']);import cp_jobstore as js;j=js.read_job(sys.argv[1], sys.argv[2]);print('yes' if (j and j.get('result')) else 'no')" "$SUB_JID" "$HOME_READ")"
[ "$SUB_RESULT" = "yes" ] \
  && ok "the job's result is present in the durable store (the handler actually executed)" \
  || bad "no result recorded for the subprocess job — the handler did not run"

# ── C. THE FALSIFIER — same race, BOTH ways, side by side: thread RED, subprocess GREEN ──
echo
echo "C. FALSIFIER — same dispatch-then-die race, thread vs subprocess (bug vs fix)"

# C1. THREAD runner: the daemon thread dies with the dispatching process -> job stays queued.
HOME_T="$EXT/home-thread"
THREAD_JID="$("$PY" "$DISPATCH_PY" thread "$HOME_T")"
rm -rf "$HOME_T"   # wipe the dispatcher home (its in-thread run, if any, is gone with it).
# Give a generous settle window; the in-thread run had NO chance (process already exited).
"$PY" -c "import time;time.sleep(1.0)"
THREAD_STATE="$("$PY" "$READ_PY" "$THREAD_JID" "$EXT/home-thread-reader")"
if [ "$THREAD_STATE" != "done" ]; then
  ok "BUG REPRODUCED: with the THREAD runner the job did NOT reach done after the dispatcher died (state=$THREAD_STATE) — the in-thread model loses execution on Cloud Run"
else
  bad "the thread runner reached done despite the dispatcher dying — the falsifier did not reproduce the bug (race not deterministic)"
fi

# C2. SUBPROCESS runner: the detached child completes out of process -> job done. THE FIX.
HOME_S="$EXT/home-sub2"
SUB2_JID="$("$PY" "$DISPATCH_PY" subprocess "$HOME_S")"
rm -rf "$HOME_S"
SUB2_STATE="$(poll_until_done "$SUB2_JID" "$EXT/home-sub2-reader" 80)"
if [ "$SUB2_STATE" = "done" ]; then
  ok "FIX CONFIRMED: with the SUBPROCESS runner the SAME race reaches done — execution survived the dispatcher's death (out of process)"
else
  bad "the subprocess runner did NOT reach done (state=$SUB2_STATE) — the fix is not working"
fi

# C3. The gate genuinely distinguishes the two models: thread != done AND subprocess == done.
if [ "$THREAD_STATE" != "done" ] && [ "$SUB2_STATE" = "done" ]; then
  ok "THE DISTINCTION HOLDS: thread=$THREAD_STATE (lost) vs subprocess=$SUB2_STATE (durable) — the gate separates the broken model from the fixed one"
else
  bad "the gate does NOT distinguish the models (thread=$THREAD_STATE subprocess=$SUB2_STATE)"
fi

# ── D. CloudRunJobRunner run_v2 request shape — the prod dispatch contract ───────────
echo
echo "D. CloudRunJobRunner run_v2 RunJobRequest shape (the prod dispatch contract)"

# The deployed image has NO gcloud SDK, so CloudRunJobRunner.dispatch goes straight to the
# Cloud Run Jobs REST API: it builds a run_v2.RunJobRequest (build_request) and hands it to
# JobsClient.run_job over the runtime SA's ADC. run_v2 MESSAGE CONSTRUCTION IS OFFLINE (no
# network, no GCP, no spend), so we assert the EXACT request shape build_request produces —
# the real run_v2 types, zero dispatch. We exercise the REAL google-cloud-run message
# classes (the suite driver installs the pinned google-cloud-run==0.10.19); if run_v2 is not
# importable we SKIP with a loud note rather than silently passing.
ARGV_PY="$EXT/assert_request.py"
cat >"$ARGV_PY" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_jobrunner

# run_v2 message construction is offline; if the dep is absent the prod path cannot be
# exercised faithfully — emit SKIP lines (the suite driver should install the pin).
try:
    from google.cloud import run_v2  # noqa: F401 — presence probe only.
except ImportError as exc:
    print("SKIP D: google-cloud-run not importable (%s) — install the pinned "
          "google-cloud-run==0.10.19 to exercise the real run_v2 RunJobRequest shape" % exc)
    sys.exit(0)

TEST_JOB_ID = "job-argv-regression-TEST"


def override_args(request):
    """Pull the container override args out of a RunJobRequest (the run-job,<id> carrier)."""
    cos = list(request.overrides.container_overrides)
    if len(cos) != 1:
        return None
    return list(cos[0].args)


# ── build 1: defaults only (default job name, default region), project set so the resource
#    name is buildable (the resource REQUIRES a project — no project => no execution). ──────
os.environ.pop("HEIMDALL_CP_JOB_NAME", None)
os.environ.pop("HEIMDALL_CP_JOB_REGION", None)
os.environ.pop("CLOUD_RUN_REGION", None)
os.environ.pop("FUNCTION_REGION", None)
os.environ["GOOGLE_CLOUD_PROJECT"] = "proj-default"

runner_def = cp_jobrunner.CloudRunJobRunner()
req_def = runner_def.build_request(TEST_JOB_ID)

# D1 — the request name is the fully-qualified resource:
#      projects/<project>/locations/<region>/jobs/<job-name>, defaults filled from env.
expect_name_def = "projects/proj-default/locations/us-central1/jobs/heimdall-long-job"
name_ok = (req_def.name == expect_name_def)
print("PASS D1: request name is '%s' (project/region/job-name from env+defaults)"
      % expect_name_def if name_ok else
      "FAIL D1: request name is %r (expected %r)" % (req_def.name, expect_name_def))

# D2 — the container override args are EXACTLY ['run-job', <job_id>] — the override carries
#      BOTH the subcommand AND the id, so the execution runs `run-job <job_id>`.
args_def = override_args(req_def)
args_ok = (args_def == ["run-job", TEST_JOB_ID])
print("PASS D2: container override args == ['run-job', '%s'] (subcommand + id, exactly two)"
      % TEST_JOB_ID if args_ok else
      "FAIL D2: container override args are %r (expected ['run-job', '%s'])"
      % (args_def, TEST_JOB_ID))

# D3 (FALSIFIER) — the args are NOT the bare [job_id]. A regression that drops 'run-job'
#      (args == [job_id]) means the container runs its DEFAULT command (serve), the run-job
#      subcommand is never received, and every prod dispatch silently fails. This catches it.
not_bare = (args_def != [TEST_JOB_ID])
print("PASS D3 (falsifier): args are NOT bare [job_id] — the 'run-job' subcommand is mandatory"
      if not_bare else
      "FAIL D3 (falsifier): args dropped 'run-job' and are bare %r — prod dispatch would no-op"
      % args_def)

# D4 (FALSIFIER) — the SECOND arg is EXACTLY the job_id passed in (not blank, not wrong).
#      A regression to a blank/empty/wrong id would dispatch the wrong execution; this pins it.
second_arg = args_def[1] if (args_def and len(args_def) == 2) else None
id_ok = (second_arg == TEST_JOB_ID and second_arg != "")
print("PASS D4 (falsifier): the id arg is EXACTLY '%s' (not blank, not wrong)" % TEST_JOB_ID
      if id_ok else
      "FAIL D4 (falsifier): the id arg is %r (expected exactly '%s')"
      % (second_arg, TEST_JOB_ID))

# D5 — no project => no resource name => build_request raises JobRunnerError (turned into
#      {dispatched: False} by dispatch, never a crash). Pinning the fail-closed behavior.
os.environ.pop("GOOGLE_CLOUD_PROJECT", None)
runner_noproj = cp_jobrunner.CloudRunJobRunner(project=None)
raised = False
try:
    runner_noproj.build_request(TEST_JOB_ID)
except cp_jobrunner.JobRunnerError:
    raised = True
print("PASS D5: build_request raises JobRunnerError when no project is set (fail closed)"
      if raised else
      "FAIL D5: build_request did NOT raise without a project — resource name is unbuildable")

# ── build 2: custom job name + region + project all propagate into the resource name ───────
os.environ["HEIMDALL_CP_JOB_NAME"] = "my-custom-job"
os.environ["HEIMDALL_CP_JOB_REGION"] = "europe-west1"
os.environ["GOOGLE_CLOUD_PROJECT"] = "my-gcp-project"

runner_cust = cp_jobrunner.CloudRunJobRunner()
req_cust = runner_cust.build_request(TEST_JOB_ID)

# D6 — custom project + region + job name all flow into the resource name.
expect_name_cust = "projects/my-gcp-project/locations/europe-west1/jobs/my-custom-job"
name_cust_ok = (req_cust.name == expect_name_cust)
print("PASS D6: custom project/region/job-name propagate -> '%s'" % expect_name_cust
      if name_cust_ok else
      "FAIL D6: request name is %r (expected %r)" % (req_cust.name, expect_name_cust))

# D7 — the args invariant holds under the custom env too (override is env-independent).
args_cust = override_args(req_cust)
args_cust_ok = (args_cust == ["run-job", TEST_JOB_ID])
print("PASS D7: override args still ['run-job', '%s'] under custom env" % TEST_JOB_ID
      if args_cust_ok else
      "FAIL D7: override args under custom env are %r (expected ['run-job', '%s'])"
      % (args_cust, TEST_JOB_ID))

# D8 — the invariant holds for a DIFFERENT job_id: the exact id is fused with 'run-job',
#      never split, never dropped. Regression guard across ids.
ALT_ID = "job-00000000000000000000000000000000"
req_alt = runner_cust.build_request(ALT_ID)
args_alt = override_args(req_alt)
alt_ok = (args_alt == ["run-job", ALT_ID])
print("PASS D8: invariant holds for alternate id — override args == ['run-job', '%s']" % ALT_ID
      if alt_ok else
      "FAIL D8: override args for alternate id are %r (expected ['run-job', '%s'])"
      % (args_alt, ALT_ID))
PYEOF

# Run the request-shape assertions and map PASS/FAIL/SKIP lines to the test's counters.
while IFS= read -r line; do
  case "$line" in
    PASS*)  ok  "${line#PASS }" ;;
    FAIL*)  bad "${line#FAIL }" ;;
    SKIP*)  printf "  \033[33mSKIP\033[0m %s\n" "${line#SKIP }" ;;
  esac
done < <("$PY" "$ARGV_PY" 2>&1)

# ── verdict ──
echo
echo "============================================================"
echo "cp-job-execution: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
