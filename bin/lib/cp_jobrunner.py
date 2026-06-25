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
#   CloudRunJobRunner   — dispatch a real Cloud Run Job execution
#                         (`gcloud run jobs execute <job> --region <r> --args run-job,<id>
#                         --wait=false`). The container runs run-job to completion off the
#                         durable Firestore record, independent of the throttled/scaled-to-
#                         zero service instance. gcloud is exec'd ONLY when this runner is
#                         actually selected at runtime — never in tests.
#
# THE FACTORY — get_job_runner() selects the impl from HEIMDALL_JOB_RUNNER, defaulting to
# `thread` for local/dev/test, and AUTO-selecting `cloudrun-job` when K_SERVICE is set
# (we are inside a Cloud Run container) UNLESS the operator overrode it explicitly. An
# unknown name raises ValueError (fail closed — never guess a runner), mirroring
# cp_state.get_backend's fail-closed posture.
#
# stdlib-only (os/sys/subprocess) + the sibling cp_worker (REUSE _detach_run / run_job —
# the thread runner and the run-job entrypoint both call into the kept helpers). No
# third-party dep, self-hostable; gcloud is the ONLY external tool, and only the cloud
# runner touches it.

from __future__ import annotations

import abc
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


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
    by default, HEIMDALL_CP_JOB_NAME) is a container whose entrypoint is this CLI; we execute
    it with an arg-override so its command is `run-job <job_id>` — it runs the job to
    completion off the durable Firestore record, billed for its whole run, then exits. The
    service instance is free to die the moment start_route returns the job_id.

    The command shape (gcloud):
        gcloud run jobs execute <job-name> \\
            --region <region> --project <project> \\
            --args run-job,<job_id> --wait=false --format json

    --wait=false so dispatch does NOT block on the execution finishing (the flight fix). The
    region/project/job-name are read from env (REGION_ENVS / GOOGLE_CLOUD_PROJECT /
    HEIMDALL_CP_JOB_NAME), set once by the deploy. gcloud is exec'd ONLY here, ONLY when this
    runner is selected at runtime — `build_command` constructs the argv WITHOUT running it, so
    tests can assert the exact command shape with zero GCP and zero spend, and `dispatch`
    runs it for real in prod.

    On ANY gcloud failure (non-zero exit, gcloud absent) dispatch returns
    {"dispatched": False, "error": ...} and the job stays `queued` — resume_orphans / a retry
    re-drives it. start_route NEVER crashes on a dispatch failure."""

    name = RUNNER_CLOUDRUN

    def __init__(self, *, job_name=None, project=None, region=None, gcloud="gcloud"):
        self._job_name = job_name or os.environ.get(JOB_NAME_ENV) or JOB_NAME_DEFAULT
        self._project = project or os.environ.get(PROJECT_ENV) or None
        self._region = region or self._region_from_env() or REGION_DEFAULT
        self._gcloud = gcloud

    @staticmethod
    def _region_from_env():
        for key in REGION_ENVS:
            val = os.environ.get(key)
            if val:
                return val.strip()
        return None

    def build_command(self, job_id):
        """Construct the gcloud argv for the execution WITHOUT running it — the exact command
        dispatch will exec. Separated so tests assert the shape (region/project/job-name/args)
        with zero GCP, and dispatch shares one source of truth for the command."""
        cmd = [
            self._gcloud, "run", "jobs", "execute", self._job_name,
            "--region", self._region,
        ]
        if self._project:
            cmd += ["--project", self._project]
        # --args overrides the container's command per-execution so it runs `run-job <id>`;
        # --wait=false returns immediately (the flight fix — never block start_route).
        cmd += ["--args", "run-job,%s" % job_id, "--wait=false", "--format", "json"]
        return cmd

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        cmd = self.build_command(job_id)
        try:
            # The ONLY place gcloud is exec'd, and only when this runner is the SELECTED
            # one at runtime. A short timeout: `execute --wait=false` returns as soon as the
            # execution is CREATED, not when it finishes. capture so a failure detail is
            # returned (never printed to a non-existent client socket).
            proc = subprocess.run(  # noqa: S603 — fixed gcloud argv built above, no shell.
                cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=120, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"dispatched": False, "runner": self.name,
                    "error": "gcloud_unavailable", "detail": str(exc),
                    "job_name": self._job_name}
        if proc.returncode != 0:
            return {"dispatched": False, "runner": self.name,
                    "error": "gcloud_execute_failed", "returncode": proc.returncode,
                    "detail": (proc.stderr or "").strip()[:500],
                    "job_name": self._job_name}
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
