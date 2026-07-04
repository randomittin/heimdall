#!/usr/bin/env python3
# cp_jobrunner.py — the PLUGGABLE EXECUTION LAYER behind the §4 flight fix.
#
# WHY THIS EXISTS (the durability bug it fixes). cp_jobstore (Wave 0) made job STATE
# durable on Cloud Run by routing every transition through a StateBackend (Firestore).
# But STATE durable is not EXECUTION durable. start_route (cp_worker) drives the job on
# an in-process threading.Thread(daemon=True) launched AFTER the HTTP response returns.
# That model is correct on a laptop. On Cloud Run it is NOT:
#
#   * CPU is THROTTLED to ~0 outside the lifetime of a request (the platform only bills
#     and schedules CPU while a request is in flight unless CPU-always-on is set), so the
#     daemon thread spawned to run after the response is STARVED — it may never get the
#     cycles to drive the job to done.
#   * With min-instances=0 the instance is SCALED TO ZERO shortly after the response, and
#     the whole process (the daemon thread with it) is KILLED. The job is left `queued`
#     in the durable store forever — state survived, execution did not.
#
# THE FIX — run the job OUT OF PROCESS, in a unit of work whose lifetime is NOT tied to
# the HTTP request that started it. On Cloud Run that unit is a Cloud Run JOB execution
# (a container that runs to completion, billed for its whole run, independent of the
# service instance). Locally the same contract is a DETACHED subprocess (start_new_session)
# that survives the request handler and even the serving process. This module is the seam
# that selects between them — mirroring cp_state.get_backend / StateBackend exactly:
#
#   StateBackend : where the bytes live   ::   JobRunner : where the EXECUTION runs.
#
# THE CONTRACT (JobRunner) — ONE method, dispatch():
#
#   dispatch(job_id, *, actor_haid=None, home=None, base_env=None) -> dict
#       Cause job `job_id` (already created + `queued` in the durable store) to RUN to
#       completion. Returns a small status dict {"dispatched": bool, "runner": <name>,
#       ...}; NEVER blocks on the job finishing (start_route must return the job_id
#       immediately — the flight fix), and NEVER raises into start_route (a dispatch
#       failure returns {"dispatched": False, "error": ...} and leaves the job `queued`,
#       so resume_orphans / a retry re-drives it). The job's OUTCOME lives in the durable
#       jobstore log, which is the contract — dispatch only kicks off the execution.
#
# THE THREE IMPLS (each a real runner, no stubs):
#
#   LocalThreadRunner   — the CURRENT behavior, factored out: a daemon thread that runs
#                         run_job in THIS process. The right default for local/dev/test
#                         (one process, one fsync discipline, instant). Wrong for Cloud Run
#                         (see above) — which is exactly why this module also provides:
#   SubprocessRunner    — spawn `heimdall-control-plane run-job <job_id>` as a DETACHED
#                         local subprocess (start_new_session=True). Run-to-completion OUT
#                         OF PROCESS: the child outlives the request handler and the serving
#                         process, proving the out-of-process model locally for $0. This is
#                         the local stand-in for a Cloud Run Job execution — SAME contract.
#   CloudRunJobRunner   — dispatch a real Cloud Run Job execution via the Cloud Run Jobs
#                         REST API (google.cloud.run_v2.JobsClient.run_job) with an
#                         arg-override so the container's command becomes `run-job <id>`.
#                         The container runs run-job to completion off the durable Firestore
#                         record, independent of the throttled/scaled-to-zero service
#                         instance. The deployed image (python:3.12-slim) has NO gcloud SDK,
#                         so dispatch goes straight to the API over the runtime SA's ADC —
#                         no external binary. run_v2 is imported LAZILY, ONLY when this
#                         runner is actually selected at runtime — never in tests, never on
#                         the thread/subprocess paths (so local/dev/test never need
#                         google-cloud-run installed). run_job returns an LRO; dispatch
#                         returns as soon as the execution is CREATED (it does NOT block on
#                         completion — the flight fix).
#
# THE FACTORY — get_job_runner() selects the impl from HEIMDALL_JOB_RUNNER, defaulting to
# `thread` for local/dev/test, and AUTO-selecting `cloudrun-job` when K_SERVICE is set
# (we are inside a Cloud Run container) UNLESS the operator overrode it explicitly. An
# unknown name raises ValueError (fail closed — never guess a runner), mirroring
# cp_state.get_backend's fail-closed posture.
#
# stdlib-only (os/sys/subprocess) for the thread/subprocess paths + the sibling cp_worker
# (REUSE _detach_run / run_job — the thread runner and the run-job entrypoint both call into
# the kept helpers). The ONLY third-party dep is google-cloud-run, imported LAZILY inside the
# cloudrun-job dispatch path so it is needed only on the prod Cloud Run runner — the
# self-hostable local/dev/test paths stay pure-stdlib.

from __future__ import annotations

import abc
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


# ── loud logging to stderr (the Cloud Run log sink) ────────────────────────────────
#
# WHY THIS EXISTS (the "deployed-but-silent" incident). On prod the Cloud Run Job stayed
# `queued` AND the service logs were SILENT — dispatch() caught the API exception and returned
# {dispatched:False} with NO trace, so no run could name WHY (wrong job name? 403? quota?
# ImportError?). The fix is observability first: every dispatch step prints to stderr, which
# Cloud Run captures into the service logs, so the next prod run's logs NAME the exact failure.
#
# We write straight to sys.stderr with a `cp_jobrunner:` prefix — the SAME mechanism cp_boot
# uses (cp_boot.py: `sys.stderr.write("cp_boot: ... ")`), so it lands in Cloud Run logs the
# same way, with no logging-config dependency. We NEVER log env/credentials: the RunJobRequest
# DOES carry a per-execution container env override (the storage-identity pin + the per-team cred
# on the multi-tenant path), but that env rides the request to the API over TLS/ADC only — the log
# lines format ONLY the resource name + the run-job override args + the exception, never the env.

def _log(msg):
    """Write one LOUD diagnostic line to stderr (Cloud Run captures stderr into the service
    logs). Prefixed `cp_jobrunner:` to match cp_boot's stderr convention. Best-effort: a
    logging failure must NEVER break dispatch (the contract), so a write error is swallowed
    and dispatch proceeds — the log is a diagnostic aid, not part of the execution path."""
    try:
        sys.stderr.write("cp_jobrunner: %s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; a logging failure must not break dispatch.
        return  # swallow the write error; dispatch continues regardless of the log.


# ── env vars that select / configure the runner (the one place they are named) ─────

# Selects the runner impl. {thread (default local/dev/test), subprocess, cloudrun-job}.
RUNNER_ENV = "HEIMDALL_JOB_RUNNER"
RUNNER_THREAD = "thread"
RUNNER_SUBPROCESS = "subprocess"
RUNNER_CLOUDRUN = "cloudrun-job"

# Cloud Run sets K_SERVICE on every instance/job — the platform's own marker that we are
# inside a Cloud Run container. AUTO -> cloudrun-job when present (unless overridden).
CLOUD_RUN_SIGNAL = "K_SERVICE"

# The Cloud Run Job name to execute (deploy/cloud-run names it heimdall-long-job). The
# project + region come from the standard Cloud Run / gcloud env so the operator sets them
# once in the deploy and the runner reads them — never hard-coded.
JOB_NAME_ENV = "HEIMDALL_CP_JOB_NAME"
JOB_NAME_DEFAULT = "heimdall-long-job"
PROJECT_ENV = "GOOGLE_CLOUD_PROJECT"
# Cloud Run exposes the region to the container; HEIMDALL_CP_JOB_REGION lets the operator
# pin it explicitly (the canonical Cloud Run var name varies by surface, so we accept both).
REGION_ENVS = ("HEIMDALL_CP_JOB_REGION", "CLOUD_RUN_REGION", "FUNCTION_REGION")
REGION_DEFAULT = "us-central1"

# ── STORAGE-IDENTITY ENV (the write/read doc-path fix) ─────────────────────────────
#
# THE INCIDENT this closes. A job's durable state is one Firestore doc whose path is
# (firestore-project, database, root-collection, encode_rel("jobs/<id>.ndjson")). The doc-id
# encoding is PURE (a function of the rel only). But THREE of the path's coordinates are read
# from PER-INSTANCE ENV by cp_state_firestore.FirestoreBackend:
#   • the backend selector   HEIMDALL_STATE_BACKEND      (firestore vs local)
#   • the firestore project  HEIMDALL_FIRESTORE_PROJECT  (else firestore.Client() falls back
#                            and GOOGLE_CLOUD_PROJECT     to GOOGLE_CLOUD_PROJECT / ADC metadata)
#   • the root collection    HEIMDALL_FIRESTORE_ROOT      (default "heimdall_cp")
#   • the database (optional) HEIMDALL_FIRESTORE_DATABASE (default "(default)")
# CloudRunJobRunner.dispatch overrides only the Job's ARGS, never its env, so the out-of-process
# Cloud Run Job container wrote to whatever identity was baked into `heimdall-long-job` at
# create-time while the dispatching SERVICE read from its own deploy-time identity. ANY drift
# between those two deploy steps => the Job writes `done` to a doc the service never reads =>
# run-job exits 0 (the Job DID reach done) yet GET /jobs polls forever and never sees it.
#
# THE FIX — make the doc identity travel WITH the dispatch: the Job execution INHERITS the
# storage-identity env the dispatching service itself resolved (propagated as a container ENV
# override), so the Job writes to the IDENTICAL (backend, project, root, db) the service reads —
# by construction, independent of how the two deploy steps' env happened to be set. The doc is
# then purely (root, rel) for the SAME job across both processes, which is the contract.
#
# Only vars actually PRESENT in the dispatching env propagate (an unset var is NOT injected as a
# blank that would clobber a value the Job legitimately baked). HEIMDALL_HOME is deliberately
# EXCLUDED: a Firestore doc path is keyed to the project/db/root, never to the home (the whole
# durability property), so the Job's own home is irrelevant and must not be forced.
STORAGE_IDENTITY_ENVS = (
    "HEIMDALL_STATE_BACKEND",
    "HEIMDALL_FIRESTORE_PROJECT",
    "HEIMDALL_FIRESTORE_ROOT",
    "HEIMDALL_FIRESTORE_DATABASE",
    "GOOGLE_CLOUD_PROJECT",
)


def _storage_identity_env():
    """The (name, value) pairs of the storage-identity env vars PRESENT in this (the dispatching
    service's) process environment — the coordinates that pin which Firestore doc a job's state
    lands in. Returned as a list of (name, value), in STORAGE_IDENTITY_ENVS order, for the vars
    actually set; an unset var is omitted (never injected blank). The Cloud Run Job execution
    inherits exactly these, so it writes to the SAME doc the service reads (the write/read fix)."""
    pairs = []
    for name in STORAGE_IDENTITY_ENVS:
        val = os.environ.get(name)
        if val is not None and val != "":
            pairs.append((name, val))
    return pairs


def _container_env_pairs(base_env=None):
    """The (name, value) env pairs to apply as a Cloud Run Job execution's PER-EXECUTION container
    env override. This is the MULTI-TENANT credential seam: the gated per-team drain assembles THAT
    team's job env — its Claude model cred + its freshly-minted GitHub App install token — as
    `base_env`, and this execution must run with it (never a fixed single-tenant secret, never
    another team's). We start from base_env (the per-team env the dispatcher already scrubbed of
    every OTHER tenant's / the operator's ambient cred), then OVERLAY the dispatching service's
    STORAGE-IDENTITY env so the write/read-doc invariant still holds by construction (the Job writes
    the SAME Firestore doc the service reads) regardless of base_env — the storage-identity keys
    WIN their final value. Values are coerced to str; a None value is dropped (never injected blank).
    An empty/None base_env reduces to exactly _storage_identity_env() — the single-tenant behavior is
    byte-unchanged. Built FRESH per call from the caller's base_env, so two teams dispatched through
    the same runner get two DISTINCT env sets — no cross-tenant leak."""
    merged = {}
    if base_env:
        for name, value in base_env.items():
            if value is None:
                continue
            merged[str(name)] = str(value)
    # storage-identity OVERRIDES (the write/read-doc fix) — applied last so it wins its own keys.
    for name, value in _storage_identity_env():
        merged[name] = value
    return list(merged.items())


class JobRunnerError(RuntimeError):
    """Raised by the factory for an unknown HEIMDALL_JOB_RUNNER (fail closed). A dispatch
    FAILURE is NOT raised — it is returned as {"dispatched": False, "error": ...} so
    start_route never crashes; this exception is only the selection-time fail-closed guard,
    mirroring cp_state.get_backend's ValueError on an unknown backend."""


# ── the contract every dispatch site binds to (the frozen interface) ───────────────


class JobRunner(abc.ABC):
    """Cause a durable, already-`queued` job to RUN to completion. The single seam between
    "the job exists in the store" (cp_jobstore) and "the job's execution actually runs"
    — the piece the flight fix needs to be durable on Cloud Run, not just the state.

    An impl maps dispatch() onto its own execution medium: a daemon thread (local), a
    detached subprocess (local out-of-process proof), or a Cloud Run Job execution (prod).
    dispatch() MUST return promptly (never block on the job finishing) and MUST NOT raise
    into the caller — a failure is reported in the returned dict, leaving the job `queued`
    for resume_orphans / a retry to re-drive."""

    #: the short stable name reported in the dispatch status dict (and the selector table).
    name = "abstract"

    @abc.abstractmethod
    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        """Kick off execution of `job_id`. Returns {"dispatched": bool, "runner": name,
        ...}. Non-blocking; never raises into start_route."""


# ── LocalThreadRunner: the CURRENT in-process daemon thread (local/dev/test) ───────


class LocalThreadRunner(JobRunner):
    """Run the job on a background daemon thread in THIS process — the behavior the control
    plane has shipped (cp_worker._detach_run). One process, one jobstore writer, one fsync
    discipline, instant: the right default on a laptop / in tests.

    WRONG for Cloud Run (the bug this module exists to fix): the thread is launched AFTER
    the HTTP response, so it is starved by CPU-throttling outside requests and killed by
    scale-to-zero — the job is left `queued` forever. Use subprocess / cloudrun-job there.

    Delegates to the kept cp_worker._detach_run so there is exactly ONE thread-launch site
    (the runner and any direct caller share it). dispatch returns once the thread is
    LAUNCHED — start_route then returns the job_id immediately (the flight fix)."""

    name = RUNNER_THREAD

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        import cp_worker  # local import: avoid an import cycle (cp_worker's start_route
                          # imports us at call time, not at module load).
        try:
            cp_worker._detach_run(
                cp_worker.run_job, job_id, actor_haid=actor_haid, home=home,
                base_env=base_env)
        except Exception as exc:  # noqa: BLE001 — never crash start_route; report + leave queued.
            return {"dispatched": False, "runner": self.name,
                    "error": type(exc).__name__, "detail": str(exc)}
        return {"dispatched": True, "runner": self.name, "mode": "in-process-thread"}


# ── SubprocessRunner: a DETACHED local subprocess (the out-of-process proof) ───────


class SubprocessRunner(JobRunner):
    """Run the job in a DETACHED local subprocess — `heimdall-control-plane run-job
    <job_id>`, spawned with start_new_session=True so it is NOT in the request handler's
    process group and survives the request, the response, and even the serving process
    being killed (a Cloud Run scale-to-zero, simulated locally). Run-to-completion OUT OF
    PROCESS against the SAME durable jobstore — the locally-testable proof of the Cloud Run
    Job model, exercising the EXACT same `run-job` entrypoint the Cloud Run Job container
    runs. Same contract as CloudRunJobRunner; zero GCP, zero spend.

    home is passed to the child as HEIMDALL_HOME (the child re-derives the store root from
    it) and via the explicit `--home` arg; base_env keys (when given) are layered onto the
    child env so the run-to-completion process sees the same configuration the in-thread
    run would have. The child's stdout/stderr go to a per-job log under the store
    (control-plane/jobs/<job_id>.ndjson.run.log) so a detached run is debuggable, or
    /dev/null when the log dir cannot be created.

    dispatch returns the moment Popen succeeds (the child is launched, detached) — it does
    NOT wait() (that would re-couple the job's lifetime to the request). A spawn failure
    returns {"dispatched": False, ...}; the job stays queued for a retry."""

    name = RUNNER_SUBPROCESS

    def __init__(self, *, cli_path=None):
        # The control-plane CLI whose `run-job` subcommand runs the job to completion. We
        # resolve it relative to this lib dir (bin/lib/.. -> bin/heimdall-control-plane),
        # the same bin/ layout every cp_* module assumes; an explicit path overrides (tests).
        self._cli = cli_path or os.path.normpath(
            os.path.join(_HERE, os.pardir, "heimdall-control-plane"))

    def _child_env(self, *, home, base_env):
        """Build the child process env: inherit this process's env, overlay any base_env
        keys, and pin HEIMDALL_HOME to the resolved home so the detached child addresses the
        SAME store. We deliberately keep the full env (not a scrubbed one) — the §2 isolation
        boundary is applied INSIDE run_job (make_context / IsolatedContext), exactly as it is
        for the in-thread run; the child re-enters that boundary when it runs the handler."""
        env = dict(os.environ)
        if base_env:
            for k, v in base_env.items():
                if v is not None:
                    env[str(k)] = str(v)
        if home:
            env["HEIMDALL_HOME"] = str(home)
        return env

    def _log_handle(self, job_id, home):
        """Open the per-job run log for the detached child's stdout/stderr, or fall back to
        /dev/null. Returns an open file object the caller closes after Popen (Popen dup's the
        fd into the child, so the parent can close its handle immediately). Best-effort: a
        failure to create the log never blocks the dispatch — the job runs either way.

        The on-disk run log is a LocalBackend convenience. A non-filesystem backend
        (FirestoreBackend, the prod store on Cloud Run) has NO local path: job_path() ->
        backend.path() raises cp_state.BackendUnavailable there. That is EXPECTED, not an
        error — so we fall back to /dev/null and the detached child still spawns and runs.
        We catch broadly (OSError + BackendUnavailable + any backend init error): the log is
        a debugging aid only, and per the contract a log failure must NEVER block dispatch."""
        try:
            import cp_jobstore
            log_path = cp_jobstore.job_path(job_id, home) + ".run.log"
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            return open(log_path, "ab")
        except Exception:  # noqa: BLE001 — best-effort log; a non-filesystem backend (Firestore)
            return open(os.devnull, "ab")  # has no local path -> /dev/null, dispatch proceeds.

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        cmd = [self._cli, "run-job", job_id]
        if home:
            cmd += ["--home", str(home)]
        if actor_haid:
            cmd += ["--actor", str(actor_haid)]
        env = self._child_env(home=home, base_env=base_env)
        log = self._log_handle(job_id, home)
        try:
            # start_new_session=True detaches the child into its OWN session/process group,
            # so it is NOT killed when the request handler / serving process dies — the whole
            # point: run-to-completion OUT OF PROCESS. stdin from /dev/null so a detached child
            # never blocks on a tty. We do NOT wait() — the job runs independently; its outcome
            # is the durable jobstore log.
            with open(os.devnull, "rb") as devnull_in:
                proc = subprocess.Popen(  # noqa: S603 — fixed argv (CLI + literal subcommand
                    cmd,                  # + our own job_id/home/actor), no shell, no wire input.
                    stdin=devnull_in,
                    stdout=log,
                    stderr=log,
                    env=env,
                    start_new_session=True,
                    close_fds=True,
                )
        except OSError as exc:
            log.close()
            return {"dispatched": False, "runner": self.name,
                    "error": "spawn_failed", "detail": str(exc)}
        log.close()  # the child inherited the dup'd fd; the parent's handle is no longer needed.
        return {"dispatched": True, "runner": self.name, "mode": "detached-subprocess",
                "pid": proc.pid}


# ── CloudRunJobRunner: a real Cloud Run Job execution (the prod runner) ────────────


class CloudRunJobRunner(JobRunner):
    """Dispatch a real Cloud Run Job execution to run the job OUT OF PROCESS, independent of
    the throttled / scaled-to-zero service instance. The Cloud Run Job (`heimdall-long-job`
    by default, HEIMDALL_CP_JOB_NAME) is a container whose entrypoint is this CLI; we run it
    with an arg-override so its command is `run-job <job_id>` — it runs the job to completion
    off the durable Firestore record, billed for its whole run, then exits. The service
    instance is free to die the moment start_route returns the job_id.

    WHY THE API, NOT gcloud. The deployed image is python:3.12-slim + bash + cryptography +
    google-cloud-firestore (Dockerfile) — it has NO gcloud SDK. Shelling `gcloud run jobs
    execute` in the container fails with `gcloud: not found`, so the dispatch returns False
    and the job is NEVER dispatched to a Cloud Run Job → it stays `queued` forever. The fix:
    dispatch over the Cloud Run Jobs REST API (google.cloud.run_v2.JobsClient.run_job) — no
    external binary. Auth is the runtime SA's Application Default Credentials (ADC), which
    already carries run.jobs.run; we pass NO explicit credentials (the client resolves ADC).

    The request shape (run_v2):
        RunJobRequest(
            name="projects/<project>/locations/<region>/jobs/<job-name>",
            overrides=RunJobRequest.Overrides(
                container_overrides=[
                    RunJobRequest.Overrides.ContainerOverride(
                        args=["run-job", <job_id>],
                        env=[EnvVar(<per-team cred / storage-identity var>, <value>), ...]),
                ],
            ),
        )

    The container override carries BOTH the `run-job` subcommand AND the job_id as the
    container's args, so the execution runs `run-job <job_id>` against the durable record. Its
    ENV override (see _container_env_pairs) carries TWO layers, per execution:
      • the PER-EXECUTION job env `base_env` — on the MULTI-TENANT gated path this is the draining
        team's Claude model cred + its freshly-minted GitHub App install token (already scrubbed of
        every other tenant's / the operator's ambient secret), so THIS execution runs with THIS
        team's cred, never a fixed single-tenant secret baked into the Job and never another team's;
      • OVERLAID with the dispatching service's STORAGE-IDENTITY env (HEIMDALL_STATE_BACKEND /
        HEIMDALL_FIRESTORE_PROJECT / HEIMDALL_FIRESTORE_ROOT / HEIMDALL_FIRESTORE_DATABASE /
        GOOGLE_CLOUD_PROJECT — see STORAGE_IDENTITY_ENVS), which WINS its own keys so the Job writes
        its durable `done` to the IDENTICAL Firestore doc the service later reads. Without the
        storage-identity layer, the Job used whatever identity was baked in at create-time and a
        drift from the service's deploy-time identity left `done` in a doc the service never polled
        (the incident); without the base_env layer, the gated Job would run with no team cred.
    The override is built FRESH per dispatch from THIS call's base_env, so two teams dispatched
    through the same runner get two DISTINCT env sets — no cross-tenant credential leak.
    run_job returns an LRO (long-running operation); we do NOT .result()-block on completion
    — dispatch returns as soon as the execution is CREATED (the flight fix). `build_request`
    constructs the RunJobRequest WITHOUT calling GCP, so tests assert the exact shape (the
    resource name + the override args + the env override) with zero GCP and zero spend; `dispatch`
    builds the same request and hands it to the client for real in prod.

    region/project/job-name are read from env (REGION_ENVS / GOOGLE_CLOUD_PROJECT /
    HEIMDALL_CP_JOB_NAME), set once by the deploy. run_v2 is imported LAZILY inside the client
    path so the thread/subprocess runners (local/dev/test) NEVER need google-cloud-run.

    On ANY failure (google-cloud-run not importable, missing project, API error) dispatch
    returns {"dispatched": False, "error": ...} and the job stays `queued` — resume_orphans /
    a retry re-drives it. start_route NEVER crashes on a dispatch failure."""

    name = RUNNER_CLOUDRUN

    def __init__(self, *, job_name=None, project=None, region=None):
        self._job_name = job_name or os.environ.get(JOB_NAME_ENV) or JOB_NAME_DEFAULT
        self._project = project or os.environ.get(PROJECT_ENV) or None
        self._region = region or self._region_from_env() or REGION_DEFAULT

    @staticmethod
    def _region_from_env():
        for key in REGION_ENVS:
            val = os.environ.get(key)
            if val:
                return val.strip()
        return None

    def job_resource_name(self):
        """The fully-qualified Cloud Run Job resource:
        projects/<project>/locations/<region>/jobs/<job-name>. The project is required —
        without GOOGLE_CLOUD_PROJECT (or an explicit project) there is no resource to run, so
        we raise here and dispatch turns it into {"dispatched": False, ...} (never a crash)."""
        if not self._project:
            raise JobRunnerError(
                "no project: set %s (or pass project=) to build the Cloud Run Job resource name"
                % PROJECT_ENV)
        return "projects/%s/locations/%s/jobs/%s" % (
            self._project, self._region, self._job_name)

    def build_request(self, job_id, base_env=None):
        """Construct the run_v2.RunJobRequest for the execution WITHOUT calling GCP — the exact
        request dispatch will hand to the client. run_v2 message construction is purely offline
        (no network), so tests assert the shape (resource name + the ["run-job", job_id]
        container override + the env override) with zero GCP and zero spend, and dispatch shares
        one source of truth for the request. run_v2 is imported HERE (lazily): only code on the
        cloudrun-job path ever needs google-cloud-run installed.

        `base_env` is the PER-EXECUTION job env the dispatcher assembled for THIS run — on the
        multi-tenant gated path it is the draining team's Claude model cred + its minted GitHub App
        install token (already scrubbed of every other tenant's / the operator's ambient secret).
        It is threaded into the container ENV override so THIS execution runs with THIS team's cred
        (never a fixed single-tenant secret baked into the Job, never another team's). base_env=None
        reduces to the storage-identity-only override (the single-tenant behavior is unchanged)."""
        from google.cloud import run_v2  # lazy: only the prod runner needs google-cloud-run.
        # PER-EXECUTION CONTAINER ENV OVERRIDE (_container_env_pairs): base_env (the per-team cred +
        # minted token — the MULTI-TENANT seam) OVERLAID with the STORAGE-IDENTITY env the dispatching
        # SERVICE resolved (the write/read doc-path fix — the Job's durable `done` lands in the SAME
        # Firestore doc the service reads, by construction). Built fresh per call from THIS dispatch's
        # base_env, so two teams get two DISTINCT env sets — no cross-tenant credential leak. The env
        # rides the RunJobRequest to the Cloud Run Jobs API over TLS/ADC; it is NEVER logged (dispatch
        # logs only the resource name + the run-job args), so no credential reaches the log sink.
        env_override = [
            run_v2.EnvVar(name=name, value=value)
            for name, value in _container_env_pairs(base_env)
        ]
        return run_v2.RunJobRequest(
            name=self.job_resource_name(),
            overrides=run_v2.RunJobRequest.Overrides(
                container_overrides=[
                    # The override replaces the container's args for THIS execution so its
                    # command becomes `run-job <job_id>` — BOTH the subcommand and the id — and
                    # pins the storage identity so the Job writes the doc the service reads.
                    run_v2.RunJobRequest.Overrides.ContainerOverride(
                        args=["run-job", job_id], env=env_override),
                ],
            ),
        )

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        # START: name the runner + the job_id + the resource name we will call. Resolving the
        # resource name can raise (no project) — log that loudly too and fail closed, never crash.
        # This first line means a queued job's dispatch ATTEMPT is traceable in the logs from the
        # very start, even if everything after it fails (the "deployed-but-silent" class — killed).
        try:
            resource_name = self.job_resource_name()
        except JobRunnerError as exc:
            _log("dispatch START runner=%s job_id=%s — NO RESOURCE: %s"
                 % (self.name, job_id, exc))
            _log("ERROR no_project: %s — returning dispatched:False, job stays queued" % exc)
            return {"dispatched": False, "runner": self.name,
                    "error": "no_project", "detail": str(exc),
                    "job_name": self._job_name}
        _log("dispatch START runner=%s job_id=%s resource=%s region=%s"
             % (self.name, job_id, resource_name, self._region))

        try:
            # Lazy import: google-cloud-run is needed ONLY here, only when this runner is the
            # SELECTED one at runtime — the thread/subprocess paths stay pure-stdlib.
            from google.cloud import run_v2
        except ImportError as exc:
            # LOUD: the dep is missing in the deployed image — name it so the next run sees it.
            _log("ERROR run_v2 unavailable: %s — google-cloud-run not importable; "
                 "returning dispatched:False, job %s stays queued" % (exc, job_id))
            return {"dispatched": False, "runner": self.name,
                    "error": "run_v2_unavailable", "detail": str(exc),
                    "job_name": self._job_name}

        try:
            # Thread base_env (the per-team cred + minted install token on the multi-tenant path)
            # into the request's container env override so THIS execution runs with THIS team's cred.
            request = self.build_request(job_id, base_env=base_env)
        except JobRunnerError as exc:
            _log("ERROR no_project: %s — cannot build RunJobRequest; returning "
                 "dispatched:False, job %s stays queued" % (exc, job_id))
            return {"dispatched": False, "runner": self.name,
                    "error": "no_project", "detail": str(exc),
                    "job_name": self._job_name}

        # CALL: name the exact run_v2 call + resource + override args BEFORE we make it, so a
        # call that then hangs/403s/quotas is still attributable in the logs to this line.
        _log("calling run_v2 JobsClient.run_job name=%s args=[run-job,%s]"
             % (resource_name, job_id))
        try:
            # ADC: no explicit credentials — the runtime SA's Application Default Credentials
            # (already carrying run.jobs.run) authenticate the call. run_job kicks off the
            # execution and returns an LRO; we do NOT .result()-block on it (the flight fix) —
            # dispatch returns as soon as the execution is CREATED.
            client = run_v2.JobsClient()
            client.run_job(request=request)
        except Exception as exc:  # noqa: BLE001 — never crash start_route; report + leave queued.
            # THE CARDINAL: never swallow silently. Log the FULL exception type + message at
            # error level (a PermissionDenied/NotFound/InvalidArgument from the API carries the
            # 403/404/quota reason in str(exc)) so the next prod run's logs name the exact cause.
            detail = "%s: %s" % (type(exc).__name__, exc)
            _log("ERROR run_job FAILED for job %s name=%s: %s — returning dispatched:False, "
                 "job stays queued (resume/retry re-drives)" % (job_id, resource_name, detail))
            return {"dispatched": False, "runner": self.name,
                    "error": "run_job_failed", "detail": detail,
                    "job_name": self._job_name}

        # SUCCESS: the LRO was accepted (the execution is CREATED) — a healthy dispatch is
        # visible in the logs too, not just failures, so a working prod run is confirmable.
        _log("dispatched: execution create accepted for job %s name=%s"
             % (job_id, resource_name))
        return {"dispatched": True, "runner": self.name, "mode": "cloud-run-job",
                "job_name": self._job_name, "region": self._region}


# ── the factory: select the runner impl from the environment ───────────────────────


def get_job_runner(*, runner=None, home=None):
    """Return the JobRunner selected by HEIMDALL_JOB_RUNNER, or the explicit `runner` name
    when passed. `home` is accepted for factory-signature parity with cp_state.get_backend
    (the runners read the store root from home at dispatch time, not at construction).

    SELECTION TABLE (the documented, fail-closed contract):

      HEIMDALL_JOB_RUNNER   K_SERVICE   ->  runner            why
      ───────────────────   ─────────   ─    ──────────────    ──────────────────────────────
      (unset)               unset       ->  thread            local/dev/test default: in-proc
      (unset)               set         ->  cloudrun-job      AUTO: inside Cloud Run, run OOP
      thread                any         ->  thread            explicit override wins over AUTO
      subprocess            any         ->  subprocess        detached OOP (local proof / OOP)
      cloudrun-job          any         ->  cloudrun-job      real Cloud Run Job execution
      <anything else>       any         ->  ValueError        fail closed — never guess

    The AUTO rule: when running inside a Cloud Run container (K_SERVICE set) and the operator
    has NOT pinned HEIMDALL_JOB_RUNNER, default to cloudrun-job — the in-process thread is
    starved/killed there (the bug), so out-of-process is the correct default. An explicit
    HEIMDALL_JOB_RUNNER ALWAYS wins (e.g. set it to `subprocess` to run within the same
    container in dev, or `thread` to opt back into the old behavior knowingly).

    An unknown name raises ValueError (fail closed — never silently pick a runner), the same
    posture cp_state.get_backend takes for an unknown backend."""
    explicit = runner if runner is not None else os.environ.get(RUNNER_ENV)
    if explicit:
        name = explicit.strip().lower()
    elif os.environ.get(CLOUD_RUN_SIGNAL):
        # AUTO: inside Cloud Run with no explicit override — the in-process thread is the
        # bug here, so run out of process via a Cloud Run Job execution.
        name = RUNNER_CLOUDRUN
    else:
        name = RUNNER_THREAD

    if name == RUNNER_THREAD:
        return LocalThreadRunner()
    if name == RUNNER_SUBPROCESS:
        return SubprocessRunner()
    if name == RUNNER_CLOUDRUN:
        return CloudRunJobRunner()
    raise ValueError(
        "unknown %s=%r (expected 'thread', 'subprocess', or 'cloudrun-job')"
        % (RUNNER_ENV, name)
    )
