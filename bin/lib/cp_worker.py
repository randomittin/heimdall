#!/usr/bin/env python3
# cp_worker.py — piece (d) of the Heimdall control plane: THE ISOLATED JOB RUNNER.
#
# DESIGN DOSSIER §4 + §2 (authoritative). THE FLIGHT FIX's executing half: the worker
# is the server-side process that RUNS a job parented to the server, NOT to the client
# connection (§4 L97). A client starts a job and disconnects; this worker keeps running
# and drives the job to `done` against the durable cp_jobstore log — so a reconnecting
# client reads status=done with the result, even though the originating socket is long
# gone.
#
# THE TWO HARD INVARIANTS this module enforces (the whole point of piece d):
#
#   1. ONLY AN ALLOWLISTED ACTION RUNS (§1) — the worker NEVER runs an arbitrary
#      command. It runs a job ONLY by passing its action_type+params through
#      cp_allowlist.validate (which refuses an unknown action / a command-smuggle /
#      an off-pattern param) and then invoking the NAMED handler resolved from
#      cp_handlers.HANDLERS. There is no shell, no eval, no wire-supplied command path.
#      An unknown action_type => the job is REFUSED, marked cancelled, audited — it
#      never executes.
#
#   2. THE WORKER RUNS INSIDE THE §2 ISOLATION BOUNDARY — the handler runs against a
#      cp_handlers.IsolatedContext whose scrubbed env + path-deny REFUSE any read of
#      the PKI private key (control-plane/auth/keys.json), the audit log
#      (control-plane/audit/audit.ndjson), or server secrets. A breached/buggy job
#      that reaches for control-plane state raises IsolationViolation and FAILS — a
#      control-plane compromise must NOT equal a fleet compromise (§2 L64). The worker
#      is server-side only; it NEVER reaches into a dev laptop to execute (that is RCE,
#      refused by construction — there is simply no code path that does it).
#
# COOPERATIVE PAUSE / RESUME / CANCEL (§4 L100) — the worker polls the DURABLE job
# state between progress checkpoints. A `paused` state observed at a checkpoint parks
# the worker (it waits, re-reading the log, until the state leaves paused); `running`
# resumes it; `cancelled` (or an external cancel) makes the worker stop cleanly and
# NOT mark the job done. Because the flag lives in the cp_jobstore log (not memory),
# ANY client can pause/resume/cancel a job this worker is running, from any connection.
#
# EVERY DISPATCH + EVERY TRANSITION IS AUDITED (§9) — the worker records a `dispatch`
# audit row when it begins a job (params-SHAPE only, never values) and a `job_state`
# row for each state change, via cp_audit (the substrate writer). The store stays
# secret-free by the substrate's scrub discipline.
#
# THE INTERFACE the /jobs endpoints (this piece) BIND to (stable):
#   run_job(job_id, ...)                 — drive ONE job to completion, in-process.
#   request_pause / request_resume / request_cancel(job_id, ...) — the durable flags.
#   resume_orphans(...)                  — re-attach to jobs left `running` on restart.
#   IsolationRefused / ActionRefused     — the two refusal types (audited by caller).
#
# stdlib-only (os/time) + the sibling cp_* substrate (allowlist/handlers/audit/server)
# + cp_jobstore — minimal self-host deps. The worker is in-process here (a thread the
# server starts); the §2 isolation is the IsolatedContext boundary, the same seam a
# real low-priv subprocess would honor.

from __future__ import annotations

import datetime
import os
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist
import cp_audit
import cp_handlers
import cp_jobstore as jobstore
import cp_server  # REUSE make_context — the §2 IsolatedContext builder.


# ── the worker's two refusal types (the caller audits + surfaces them) ─────────


class ActionRefused(Exception):
    """Raised when a job names an action_type the allowlist refuses (unknown action,
    command-smuggle, off-pattern param). The worker marks the job cancelled + audits a
    dispatch_refused row; the job NEVER executes. THE arbitrary-command wall, at the
    runner level — even a job record that somehow carried a bad action_type cannot run
    a command, because validate() refuses it before any handler is reached."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


class IsolationRefused(Exception):
    """Raised when a running job tries to read a control-plane resource through its
    IsolatedContext (the PKI key / audit log / server secret) — the §2 boundary fired
    a cp_handlers.IsolationViolation. The worker fails the job (state stays non-done)
    and audits it. Proves the isolation is REAL, not aspirational (§2 L64)."""

    def __init__(self, detail=""):
        self.detail = detail
        super().__init__(detail or "isolated job reached for control-plane resource")


# ── cooperative pause/cancel tuning (the worker polls the DURABLE state) ───────

# How long the worker parks between re-reads while a job sits `paused`. Short enough
# to feel responsive to a resume from any client, long enough not to spin the disk.
_PAUSE_POLL_SECONDS = 0.05

# A hard ceiling on parked-while-paused time so a forgotten paused job cannot pin a
# worker forever. On timeout the worker returns control (the job stays paused on disk,
# resumable later by re-running the worker) rather than blocking indefinitely.
_PAUSE_MAX_SECONDS = 30.0


# ── running-orphan reclaim tuning (audit §3a — a dead-container job is reclaimed) ──
#
# A job left `running` when its job-container dies (Cloud Run Job execution killed, the
# in-process daemon starved) is NEVER advanced again on its own — no worker holds it. Left
# alone it sits `running` forever, invisible. resume_orphans reclaims it on a LEASE: a job
# whose running stint began more than _RUNNING_LEASE_SECONDS ago is presumed dead.
#
# The lease default is 2× the ~1h max task time = 2h — long enough that a legitimately long
# job (which also streams progress ticks) is never falsely reclaimed, short enough that a dead
# container is picked up on the next resume pass. Overridable via env for ops + tests.
_RUNNING_LEASE_ENV = "HEIMDALL_JOB_RUNNING_LEASE_SECONDS"
_RUNNING_LEASE_DEFAULT = 7200  # 2h = 2 × the 1h per-task ceiling.

# Bounded re-drive: an orphaned running job is RE-DRIVEN once (this instance takes over and
# runs its handler to completion); if it is STILL a running orphan on a later pass (the re-
# drive faulted / re-orphaned), it is FAILED TERMINAL (running -> cancelled with a note)
# rather than re-driven forever — the never-loop-a-deterministically-failing-job discipline.
_RECLAIM_MAX = 1
# The durable marker (a job-log detail) counted to bound re-drives across passes/instances.
_RECLAIM_MARKER = "running_orphan_reclaim"
# The note stamped when the bound is exhausted and the orphan is failed terminal.
_RECLAIM_FAILED_DETAIL = "running_orphan_lease_failed"


# ── QUEUED-orphan grace window (BUG #15 — the double-run guard) ────────────────────
#
# THE LIVE INCIDENT (2026-07-05 20:24, forensically proven). resume_orphans re-drove a
# QUEUED job via run_job IN-PROCESS regardless of HEIMDALL_JOB_RUNNER. On the gated service
# (a REMOTE runner) that meant: the dispatcher created a real Cloud Run Job execution for a
# freshly-queued job, and ~18s later a resume pass on the (OLDER-image) gated SERVICE stole
# that same still-queued job and ran it IN-PROCESS with STALE code (the 876-line traceback),
# while the correct new-image Cloud Run Job execution arrived to find the job already done —
# a DOUBLE-RUN off ONE dispatch.
#
# THE GRACE HALF OF THE FIX: a queued job younger than this window is presumed to have a
# dispatch still in flight (its Cloud Run Job container is booting), so the REMOTE resume path
# SKIPS it rather than re-dispatching — re-dispatching a booting job re-creates the very race.
# The default 5min comfortably exceeds Cloud Run Job cold-start; overridable for ops + tests.
_QUEUED_GRACE_ENV = "HEIMDALL_JOB_QUEUED_GRACE_SECONDS"
_QUEUED_GRACE_DEFAULT = 300  # 5 min — longer than a Cloud Run Job cold start.


def _stderr(msg):
    """One LOUD diagnostic line to stderr (Cloud Run captures it into the service logs).
    Best-effort: a logging failure is swallowed so it can NEVER break the caller. Mirrors
    cp_boot._stderr — the loud-log discipline (no silent skip / no silent swallow)."""
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; a write error must not break a resume.
        return


def _running_lease_seconds():
    """The running-orphan lease in seconds (HEIMDALL_JOB_RUNNING_LEASE_SECONDS, else the 2h
    default). A malformed / non-positive env value falls back to the default (never crashes
    a resume pass)."""
    raw = os.environ.get(_RUNNING_LEASE_ENV)
    try:
        val = int(raw) if raw else 0
    except (TypeError, ValueError):
        val = 0
    return val if val > 0 else _RUNNING_LEASE_DEFAULT


def _parse_iso(ts):
    """Parse an ISO-8601 timestamp string to an aware UTC datetime, or None if unparseable.
    A naive ts (no tzinfo) is treated as UTC (the store writes second-precision UTC)."""
    try:
        dt = datetime.datetime.fromisoformat(ts)
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def _running_since(job_id, home):
    """The ISO ts of the LATEST state=running event in a job's log (when the current running
    stint began) — the lease anchor. None if the job never entered running. Read via the
    jobstore's tolerant line scan (no store edit — the raw event rows carry the per-event ts)."""
    since = None
    for rec in jobstore._read_lines(job_id, home):
        if rec.get("ev") == jobstore.EV_STATE and rec.get("state") == jobstore.STATE_RUNNING:
            since = rec.get("ts", since)
    return since


def _reclaim_count(job_id, home):
    """How many reclaim attempts a job's log already records (the durable _RECLAIM_MARKER
    lines) — the bound that stops an orphan being re-driven forever across passes/instances."""
    n = 0
    for rec in jobstore._read_lines(job_id, home):
        if rec.get("detail") == _RECLAIM_MARKER:
            n += 1
    return n


def _mark_reclaim(job_id, home):
    """Durably record ONE reclaim attempt (a progress line carrying the _RECLAIM_MARKER
    detail) BEFORE re-driving, so the bound survives a crash mid-reclaim and is shared
    across instances (the count is folded from the log, not held in memory)."""
    jobstore.append_event(job_id, ev=jobstore.EV_PROGRESS, progress="reclaim",
                          detail=_RECLAIM_MARKER, home=home)


def _state_since(job_id, state, home):
    """The ISO ts of the LATEST EV_STATE event for `state` in a job's log (when the job most
    recently ENTERED that state), or None. Generalizes _running_since so the QUEUED-orphan grace
    can anchor on when the job was queued (i.e. when its dispatch was handed off)."""
    since = None
    for rec in jobstore._read_lines(job_id, home):
        if rec.get("ev") == jobstore.EV_STATE and rec.get("state") == state:
            since = rec.get("ts", since)
    return since


def _queued_grace_seconds():
    """The QUEUED-orphan grace window in seconds (HEIMDALL_JOB_QUEUED_GRACE_SECONDS, else the
    5min default). A malformed / non-positive value falls back to the default — never crashes a
    resume pass (mirrors _running_lease_seconds)."""
    raw = os.environ.get(_QUEUED_GRACE_ENV)
    try:
        val = int(raw) if raw else 0
    except (TypeError, ValueError):
        val = 0
    return val if val > 0 else _QUEUED_GRACE_DEFAULT


def _is_remote_runner(job_runner):
    """True if the configured job runner executes jobs OUT OF PROCESS on a separate medium that a
    fresh dispatch re-drives (cloudrun-job). BUG #15: for such a runner a queued orphan must be
    RE-DISPATCHED via the runner — NEVER run_job in-process here, or the (possibly stale-image)
    resume host runs the SAME job the real Cloud Run Job execution is running (the proven double-
    run). thread/subprocess run in THIS process, so their resume stays in-process (unchanged)."""
    import cp_jobrunner
    return getattr(job_runner, "name", None) == cp_jobrunner.RUNNER_CLOUDRUN


def _resolve_job_runner(home):
    """The JobRunner the deployment's HEIMDALL_JOB_RUNNER selects (cp_jobrunner.get_job_runner) —
    resolved ONCE per resume pass so a queued-orphan re-drive honors the SAME runner the live
    dispatch uses (incl. the K_SERVICE AUTO -> cloudrun-job rule inside Cloud Run). Construction is
    cheap (no GCP import until dispatch). A selection failure (an unknown runner name) falls back
    to None -> the in-process path, logged loudly rather than crashing the pass."""
    import cp_jobrunner
    try:
        return cp_jobrunner.get_job_runner(home=home)
    except Exception as exc:  # noqa: BLE001 — never crash a resume pass on runner selection.
        _stderr("cp_worker: resume runner-resolve failed %s -> in-process fallback"
                % type(exc).__name__)
        return None


# ── the durable pause/resume/cancel flags (ANY client, via the jobstore log) ───
#
# These are thin, transition-validated wrappers over cp_jobstore. They are the only
# way state changes — so a pause/resume/cancel from a RECONNECTED client lands in the
# same durable log the running worker polls. Each returns the new state, or raises
# jobstore.IllegalTransition for an illegal edge (the endpoint maps that to a refusal).


def request_pause(job_id, *, actor_haid=None, home=None):
    """Cooperatively pause a running job (§4 L100): running -> paused, durably. The
    worker observes this at its next checkpoint and parks. Audited as a job_state
    transition. Raises IllegalTransition if the job is not running (e.g. already
    paused / terminal) — pause is only legal from running."""
    new = jobstore.transition(job_id, jobstore.STATE_PAUSED, home=home)
    cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                   outcome="ok", detail="paused", home=home)
    return new


def request_resume(job_id, *, actor_haid=None, home=None):
    """Resume a paused job (§4 L100): paused -> running, durably. The parked worker
    sees the state leave paused and continues. Audited. Raises IllegalTransition if
    the job is not paused — resume is only legal from paused."""
    new = jobstore.transition(job_id, jobstore.STATE_RUNNING, home=home)
    cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                   outcome="ok", detail="resumed", home=home)
    return new


def request_cancel(job_id, *, actor_haid=None, home=None):
    """Cancel a job (§4 L100): {queued|running|paused} -> cancelled, durably. The
    worker observes this at its next checkpoint and stops WITHOUT marking the job done.
    Audited. Raises IllegalTransition if the job is already terminal — cancel is legal
    from queued/running/paused only."""
    new = jobstore.transition(job_id, jobstore.STATE_CANCELLED, home=home)
    cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                   outcome="ok", detail="cancelled", home=home)
    return new


# ── the cooperative checkpoint (poll the DURABLE state mid-run) ────────────────


def _checkpoint(job_id, home):
    """Read the job's CURRENT durable state and act on a pause/cancel flag set by ANY
    client (§4 L100). Returns:
      'continue'  — state is running, proceed.
      'cancelled' — a cancel landed; the worker must stop without finishing.
    Parks (re-reading the log) while the state is `paused`, returning only when it
    leaves paused (resume -> 'continue', cancel -> 'cancelled') or the park ceiling is
    hit (returns 'paused' so the worker yields without finishing). Because the flag is
    on disk, the running worker honors a pause/resume/cancel from a reconnected
    client it shares no memory with."""
    state = jobstore.current_state(job_id, home)
    if state == jobstore.STATE_CANCELLED:
        return "cancelled"
    if state == jobstore.STATE_RUNNING:
        return "continue"
    if state == jobstore.STATE_PAUSED:
        waited = 0.0
        while waited < _PAUSE_MAX_SECONDS:
            time.sleep(_PAUSE_POLL_SECONDS)
            waited += _PAUSE_POLL_SECONDS
            s = jobstore.current_state(job_id, home)
            if s == jobstore.STATE_RUNNING:
                return "continue"
            if s == jobstore.STATE_CANCELLED:
                return "cancelled"
        return "paused"  # park ceiling hit; yield, leaving the job paused on disk.
    # queued (not yet started) or unknown — let the caller proceed (it just
    # transitioned to running); only an explicit cancel short-circuits.
    if state == jobstore.STATE_CANCELLED:
        return "cancelled"
    return "continue"


# ── run_job: drive ONE job to completion, isolated + allowlisted (§1/§2/§4) ─────


def run_job(job_id, *, actor_haid=None, home=None, base_env=None,
            checkpoints=4, resume_running=False):
    """Run ONE server-hosted job to completion — the heart of THE FLIGHT FIX.

    The job is identified by its durable cp_jobstore record (created by the /jobs start
    endpoint, which returned the job_id to a client that may now be DISCONNECTED). This
    worker runs PARENTED TO THE SERVER, off that durable record — the client connection
    is irrelevant to it.

    The flow (each step a hard gate):
      1. Read the folded job state. A job not in {queued} (already running/terminal)
         is not re-run (idempotence). queued -> running (durable transition + audit).
      2. ALLOWLIST GATE (§1): cp_allowlist.validate(action_type, params). An unknown
         action / command-smuggle / off-pattern param raises RefusedDispatch -> the
         worker marks the job CANCELLED, audits dispatch_refused, raises ActionRefused.
         The job NEVER executes an arbitrary command — there is no path that does.
      3. ISOLATION (§2): build a cp_handlers.IsolatedContext (scrubbed env + per-job
         scratch + scoped token, NO control-plane read) via cp_server.make_context.
         Run the NAMED handler (resolved from cp_handlers.HANDLERS) inside it. A handler
         that reaches for the PKI key / audit log raises IsolationViolation -> the
         worker fails the job + raises IsolationRefused. The worker can read NONE of
         those itself — it only ever calls a registered, bounded handler in the context.
      4. COOPERATIVE CHECKPOINTS (§4 L100): between progress ticks the worker polls the
         DURABLE state. A pause parks it; a resume continues; a cancel stops it cleanly
         (state stays cancelled, the job is NOT marked done). Progress streams to the
         LOG (set_progress), never the client socket — so it survives a disconnect.
      5. On success: set_result(result) + running -> done (durable). A reconnecting
         client reads status=done with the result. dispatch audited (§9).

    Returns the final folded state dict. Raises ActionRefused / IsolationRefused /
    jobstore.IllegalTransition on the refusal paths above (already audited)."""
    folded = jobstore.read_job(job_id, home)
    if folded is None:
        raise jobstore.IllegalTransition(job_id, None, jobstore.STATE_RUNNING)
    state = folded.get("state")
    if state in jobstore.TERMINAL_STATES:
        return folded  # already finished/cancelled — idempotent no-op.
    if state == jobstore.STATE_RUNNING and not resume_running:
        # a sibling worker is already on it; do not double-run. (resume_orphans passes
        # resume_running=True to RECLAIM a job whose worker died — see §3a reclaim.)
        return folded

    action_type = folded.get("action_type")
    raw_params = folded.get("params") or {}

    # 1. queued -> running (durable + audited). Any client may now disconnect. When RECLAIMING
    #    an orphan that is ALREADY running (resume_running, its old worker gone), there is no
    #    queued->running edge to take — this instance simply takes over the existing running
    #    stint and drives it to done; the audit row records the takeover.
    if state == jobstore.STATE_QUEUED:
        jobstore.transition(job_id, jobstore.STATE_RUNNING, home=home)
        cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                       action_type=action_type, outcome="ok", detail="running",
                       home=home)
    else:
        cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                       action_type=action_type, outcome="ok",
                       detail="running-reclaimed", home=home)

    # 2. THE ALLOWLIST GATE — only an allowlisted action runs. No arbitrary command.
    try:
        plan = cp_allowlist.validate(action_type, raw_params)
    except cp_allowlist.RefusedDispatch as ref:
        # the job named an action the allowlist refuses: cancel + audit, never run it.
        _safe_cancel(job_id, home)
        cp_audit.record_refusal(actor_haid, action_type, reason=ref.reason,
                                params=raw_params, action_id=job_id, home=home)
        raise ActionRefused(ref.reason, ref.detail)

    # 3. ISOLATION (§2) + run the NAMED handler inside the IsolatedContext.
    try:
        handler = cp_handlers.resolve(plan["handler"])
    except KeyError as err:
        _safe_cancel(job_id, home)
        cp_audit.record_refusal(actor_haid, action_type,
                                reason="unregistered_handler", params=raw_params,
                                action_id=job_id, home=home)
        raise ActionRefused("unregistered_handler", str(err))

    ctx = cp_server.make_context(job_id, home=home, base_env=base_env)

    # 4. COOPERATIVE CHECKPOINTS — poll the durable state for pause/resume/cancel.
    n = max(1, int(checkpoints))
    for i in range(n):
        decision = _checkpoint(job_id, home)
        if decision == "cancelled":
            cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                           action_type=action_type, outcome="ok",
                           detail="cancelled-mid-run", home=home)
            return jobstore.read_job(job_id, home)
        if decision == "paused":
            # park ceiling hit while paused — yield, job remains paused on disk.
            return jobstore.read_job(job_id, home)
        jobstore.set_progress(job_id, int((i + 1) * 100 / n), home=home)

    # run the bounded, NAMED handler inside the §2 isolated context.
    try:
        result = handler(plan["params"], ctx)
    except cp_handlers.IsolationViolation as iv:
        # the §2 boundary fired: the job reached for a control-plane resource. Fail it.
        cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                       action_type=action_type, outcome="error",
                       detail="isolation_violation", home=home)
        raise IsolationRefused(str(iv))
    except Exception as exc:  # noqa: BLE001 — a handler fault fails the job, audited.
        cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                       action_type=action_type, outcome="error",
                       detail=type(exc).__name__, home=home)
        raise

    # re-check for a cancel that landed WHILE the handler ran (cooperative).
    if jobstore.current_state(job_id, home) == jobstore.STATE_CANCELLED:
        cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                       action_type=action_type, outcome="ok",
                       detail="cancelled-post-run", home=home)
        return jobstore.read_job(job_id, home)

    # 5. SUCCESS — record the result + running -> done (durable). Reconnect reads it.
    jobstore.set_result(job_id, result, home=home)
    jobstore.transition(job_id, jobstore.STATE_DONE, progress=100, home=home)
    cp_audit.record_dispatch(actor_haid, action_type, action_id=job_id,
                             job_id=job_id, params=plan["params"], outcome="ok",
                             home=home)
    cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                   action_type=action_type, outcome="ok", detail="done", home=home)
    return jobstore.read_job(job_id, home)


def _safe_cancel(job_id, home):
    """Best-effort durable cancel of a job on a refusal path. Swallows an
    IllegalTransition (e.g. the job was already cancelled) so the refusal handling
    continues to audit + raise the precise refusal — the cancel is a courtesy, the
    audit + raise are the contract."""
    try:
        jobstore.transition(job_id, jobstore.STATE_CANCELLED, home=home)
        return True
    except jobstore.IllegalTransition:
        return False


# ── isolation self-check: PROVE the worker cannot read control-plane state (§2) ─


def assert_isolated_cannot_read_control_plane(job_id, *, home=None, base_env=None):
    """PROVE the §2 isolation is real (the falsifiable security assertion). Build the
    SAME IsolatedContext a job runs inside and demonstrate it REFUSES a read of every
    control-plane resource (the PKI key registry, the audit log). Returns a dict of
    {resource: refused?} — each value MUST be True. Used by the cardinal isolation
    test; a build where the worker COULD read the key would make a value False (RED)."""
    ctx = cp_server.make_context(job_id, home=home, base_env=base_env)
    refused = {}
    for rel in (
        os.path.join("control-plane", "auth", "keys.json"),
        os.path.join("control-plane", "audit", "audit.ndjson"),
        os.path.join("..", "control-plane", "auth", "keys.json"),
        "keys.json",
        "audit.ndjson",
    ):
        try:
            ctx.resolve_path(rel)
            refused[rel] = False  # the context HANDED a control-plane path -> breach.
        except cp_handlers.IsolationViolation:
            refused[rel] = True   # refused -> the §2 boundary held.
    # and the scrubbed env must carry NONE of the server's secret-bearing vars.
    env = ctx.scrubbed_env()
    refused["env_scrubbed"] = all(
        k in cp_handlers.ISOLATED_ENV_ALLOW or k in ("HEIMDALL_HOME",
                                                     "HEIMDALL_JOB_TOKEN")
        for k in env.keys()
    )
    return refused


# ── restart replay: re-attach to jobs left mid-flight (the durability driver) ──


def resume_orphans(*, actor_haid=None, home=None, base_env=None, checkpoints=4,
                   runner=None, job_runner=None, grace_seconds=None, now=None):
    """Re-drive orphaned jobs — the replay driver (§4 L94), now ALSO the running-orphan
    reclaimer (audit §3a) and the runner-honoring queued re-drive (BUG #15). Returns the list
    of (job_id, final_state) it advanced (the stable return the boot hook + cp-jobs restart test
    bind to). See resume_orphans_pass for the counted variant the periodic tick logs."""
    return resume_orphans_pass(
        actor_haid=actor_haid, home=home, base_env=base_env,
        checkpoints=checkpoints, runner=runner, job_runner=job_runner,
        grace_seconds=grace_seconds, now=now)["advanced"]


def resume_orphans_pass(*, actor_haid=None, home=None, base_env=None, checkpoints=4,
                        runner=None, job_runner=None, grace_seconds=None, now=None):
    """ONE resume pass over the whole job store, returning
    {"advanced": [(job_id, final_state), ...], "requeued": int, "reclaimed": int}.

    Two orphan classes are re-driven — every decision LOGGED loudly (no silent skip, audit
    §5). The pass is idempotent, so the periodic tick (cp_boot) can run it on a cadence, not
    only at boot (audit §3a fix (a)):

      QUEUED orphan (a dispatch that never durably started work — the cloudrun-job kick
        failed, or a boot after enqueue): RE-DRIVEN honoring the configured runner (BUG #15).
        When the runner is REMOTE (cloudrun-job) the orphan is RE-DISPATCHED via that runner —
        never run_job in-process (a stale-image resume host must not run the SAME job the real
        Cloud Run Job execution runs), and a queued job younger than `grace` is SKIPPED (its
        dispatch is still booting). For an IN-PROCESS runner (thread/subprocess) it is re-driven
        in-process via `runner` (default run_job), unchanged. Counts toward `requeued`.

      RUNNING orphan (a job-container died mid-run — audit §3a fix (b)): a job whose running
        stint began more than the lease (_running_lease_seconds) ago is presumed dead. It is
        RECLAIMED with a bound (_RECLAIM_MAX): the first time this instance takes over and
        re-drives it (runner with resume_running=True); if it is STILL a running orphan on a
        later pass (the re-drive faulted / re-orphaned), it is FAILED TERMINAL (running ->
        cancelled, detail=_RECLAIM_FAILED_DETAIL) rather than re-driven forever. Counts
        toward `reclaimed`. A running job WITHIN its lease is left running (logged as skipped).

    A `paused`/terminal job is left as-is (owner-controlled) — logged as a skip. `runner` is
    an injectable worker entry (default run_job) for deterministic tests; `now` pins the
    lease clock (default utcnow)."""
    run = runner or run_job
    when = now if now is not None else datetime.datetime.now(datetime.timezone.utc)
    lease = _running_lease_seconds()
    grace = grace_seconds if grace_seconds is not None else _queued_grace_seconds()
    # BUG #15: resolve the deployment's runner ONCE; a REMOTE runner (cloudrun-job) re-DISPATCHES
    # queued orphans instead of running them in-process. An injected job_runner wins (tests).
    jr = job_runner if job_runner is not None else _resolve_job_runner(home)
    remote = _is_remote_runner(jr)
    advanced = []
    requeued = 0
    reclaimed = 0
    for jid in jobstore.list_job_ids(home):
        folded = jobstore.fold_state(jid, home)
        if folded is None:
            continue
        state = folded.get("state")

        if state == jobstore.STATE_QUEUED:
            if remote:
                # BUG #15 — the runner runs jobs OUT OF PROCESS (cloudrun-job): RE-DISPATCH via
                # the runner, NEVER run_job in-process. GRACE: a queued job younger than the window
                # has a dispatch still in flight (its Cloud Run Job container is booting); resuming
                # it now re-creates the proven double-run, so SKIP it this pass.
                age = None
                since = _state_since(jid, jobstore.STATE_QUEUED, home)
                if since is not None:
                    dt = _parse_iso(since)
                    if dt is not None:
                        age = (when - dt).total_seconds()
                if age is not None and age < grace:
                    _stderr("cp_worker: resume queued job=%s age=%.0f grace=%d "
                            "resumed-via=skipped-young (dispatch in flight — container booting)"
                            % (jid, age, grace))
                    continue
                dispatched = jr.dispatch(jid, actor_haid=actor_haid, home=home,
                                         base_env=base_env)
                ok = (bool(dispatched.get("dispatched"))
                      if isinstance(dispatched, dict) else bool(dispatched))
                fstate = jobstore.current_state(jid, home)
                advanced.append((jid, fstate))
                requeued += 1
                _stderr("cp_worker: resume queued job=%s age=%s resumed-via=%s dispatched=%s -> %s"
                        % (jid, ("%.0f" % age) if age is not None else "unknown",
                           getattr(jr, "name", "?"), ok, fstate))
                continue
            # IN-PROCESS runner modes (thread/subprocess): re-drive in THIS process — unchanged.
            try:
                final = run(jid, actor_haid=actor_haid, home=home,
                            base_env=base_env, checkpoints=checkpoints)
                fstate = final.get("state") if final else None
                advanced.append((jid, fstate))
                _stderr("cp_worker: resume queued job=%s resumed-via=in-process -> %s"
                        % (jid, fstate))
            except (ActionRefused, IsolationRefused, jobstore.IllegalTransition) as exc:
                fstate = jobstore.current_state(jid, home)
                advanced.append((jid, fstate))
                _stderr("cp_worker: resume queued job=%s resumed-via=in-process REFUSED %s -> %s"
                        % (jid, type(exc).__name__, fstate))
            requeued += 1
            continue

        if state == jobstore.STATE_RUNNING:
            age = None
            since = _running_since(jid, home)
            if since is not None:
                dt = _parse_iso(since)
                if dt is not None:
                    age = (when - dt).total_seconds()
            if age is None or age < lease:
                _stderr("cp_worker: resume skip running job=%s age=%s lease=%d "
                        "(within lease — a live worker may hold it)"
                        % (jid, ("%.0f" % age) if age is not None else "unknown", lease))
                continue
            rc = _reclaim_count(jid, home)
            if rc < _RECLAIM_MAX:
                # RE-DRIVE once: record the durable bound marker FIRST, then take over the
                # running stint and drive it to done (resume_running=True). A fault leaves it
                # running (audited by run_job) so the NEXT pass fails it terminal.
                _mark_reclaim(jid, home)
                try:
                    final = run(jid, actor_haid=actor_haid, home=home,
                                base_env=base_env, checkpoints=checkpoints,
                                resume_running=True)
                    fstate = final.get("state") if final else None
                except (ActionRefused, IsolationRefused, jobstore.IllegalTransition) as exc:
                    fstate = jobstore.current_state(jid, home)
                    _stderr("cp_worker: reclaim re-drive job=%s REFUSED %s"
                            % (jid, type(exc).__name__))
                except Exception as exc:  # noqa: BLE001 — handler fault audited in run_job;
                    # leave the job running so the next pass fails it terminal.
                    fstate = jobstore.current_state(jid, home)
                    _stderr("cp_worker: reclaim re-drive job=%s FAULT %s"
                            % (jid, type(exc).__name__))
                advanced.append((jid, fstate))
                reclaimed += 1
                _stderr("cp_worker: resume reclaim running job=%s attempt=%d age=%.0f "
                        "lease=%d -> %s" % (jid, rc + 1, age, lease, fstate))
            else:
                # BOUND EXHAUSTED — fail terminal (running -> cancelled, noted + audited).
                fstate = jobstore.STATE_CANCELLED
                try:
                    jobstore.transition(jid, jobstore.STATE_CANCELLED,
                                        detail=_RECLAIM_FAILED_DETAIL, home=home)
                except jobstore.IllegalTransition:
                    fstate = jobstore.current_state(jid, home)
                cp_audit.write("job_state", actor_haid=actor_haid, job_id=jid,
                               action_type=folded.get("action_type"), outcome="error",
                               detail=_RECLAIM_FAILED_DETAIL, home=home)
                advanced.append((jid, fstate))
                reclaimed += 1
                _stderr("cp_worker: resume FAIL running job=%s reclaim_exhausted "
                        "age=%.0f lease=%d -> %s" % (jid, age, lease, fstate))
            continue

        # paused / any other non-orphan state: owner-controlled — never silently skipped.
        _stderr("cp_worker: resume skip job=%s state=%s (owner-controlled)" % (jid, state))
    return {"advanced": advanced, "requeued": requeued, "reclaimed": reclaimed}


# ── the /jobs endpoint route handlers (register via cp_server.register_route) ──
#
# These are the reconnectable surface (§4 L96-99): start returns a job_id (the client
# may disconnect); status/pause/resume/cancel act on the durable job by id from ANY
# client. Each is a cp_server route handler: fn(identity, request) -> cp_server.Response.
# Registered by register_job_routes() so the server gains /jobs without editing
# cp_server (the §10 disjointness seam).


def _haid_of(identity):
    """The actor HAID from a verified cp_server Identity (or a bare string in tests)."""
    return getattr(identity, "haid", identity)


def _json_body(request):
    """Parse the request body dict (the server hands raw bytes/str). Returns {} on a
    malformed/absent body — the endpoint validates the fields it needs."""
    import json
    body = request.get("body") if isinstance(request, dict) else None
    if body is None:
        return {}
    try:
        if isinstance(body, (bytes, bytearray)):
            body = body.decode("utf-8")
        if isinstance(body, str):
            return json.loads(body or "{}")
        if isinstance(body, dict):
            return body
    except (ValueError, TypeError):
        return {}
    return {}


def _job_id_from(request, payload):
    """Resolve the target job_id, in this precedence order:
      1. the QUERY STRING — request["query"]["job_id"], i.e. GET /jobs?job_id=<id>.
         This is the GFE-SAFE read shape: Google's GFE / Cloud Run ingress REJECTS a
         GET-with-a-body (HTTP 400, never reaches the container), so a deployed signed
         read MUST carry job_id in the query, NOT the body. The server signs+verifies
         the full path-with-query, so the query'd job_id is authenticated + tamper-
         evident. The parsed query is handed in by cp_server._request_dict; when the
         server didn't parse it (a direct/in-process call), we parse the request path's
         own ?query as a fallback so the query shape resolves either way.
      2. the BODY — payload["job_id"]. Back-compat for a direct/local call (and the
         legacy body-based GET that local test HTTP servers still accept).
      3. the REST PATH — /jobs/<id>/<verb>. The path-shaped form.
    A GFE-safe GET /jobs?job_id=<id> with an EMPTY body resolves via (1)."""
    # 1. the query string (the GFE-safe shape) — server-parsed first, then path-parsed.
    if isinstance(request, dict):
        q = request.get("query")
        if isinstance(q, dict) and q.get("job_id"):
            return q.get("job_id")
    path = request.get("path") if isinstance(request, dict) else None
    if isinstance(path, str) and "?" in path:
        from urllib.parse import urlsplit, parse_qs
        vals = parse_qs(urlsplit(path).query).get("job_id")
        if vals and vals[0]:
            return vals[0]
    # 2. the body (back-compat for a direct/local call).
    if isinstance(payload, dict) and payload.get("job_id"):
        return payload.get("job_id")
    # 3. the REST path (/jobs/<id>/<verb>) — strip any ?query before splitting.
    if isinstance(path, str):
        bare = path.split("?", 1)[0]
        if bare.startswith("/jobs/"):
            rest = bare[len("/jobs/"):].strip("/").split("/")
            if rest and rest[0]:
                return rest[0]
    return None


def _detach_run(runner, job_id, *, actor_haid=None, home=None, base_env=None):
    """Drive ONE job off the durable record in a BACKGROUND daemon thread — THE FLIGHT
    FIX's detach (§4 L97). start_route returns the job_id to the (possibly disconnecting)
    client the instant this thread is launched; the thread runs the job to completion
    against the same fsync'd cp_jobstore log, so a reconnecting client reads status=done.

    A thread (NOT a forked subprocess) is deliberate: every transition the runner drives
    stays in THIS process's durable jobstore writes — one store, one fsync discipline, no
    cross-process log interleave. daemon=True so a hosting process can exit without the
    thread pinning it; the durable log is the source of truth, and resume_orphans re-drives
    anything left `running` after a restart.

    The runner's refusal paths (ActionRefused / IsolationRefused / IllegalTransition) and
    any handler fault are ALREADY durably recorded + audited by run_job before they
    propagate — so the thread target swallows them: there is no client socket left to
    surface them on, and re-raising would only spam an uncaught-thread-exception to stderr.
    The job's outcome lives in the log, which is the contract."""
    def _target():
        try:
            runner(job_id, actor_haid=actor_haid, home=home, base_env=base_env)
        except (ActionRefused, IsolationRefused, jobstore.IllegalTransition) as exc:
            # already audited + durably recorded by run_job; no socket to raise on. LOUD
            # (audit obs #5): a swallowed thread exit must still say WHY — TYPE ONLY (never
            # str(exc)/base_env, which could carry a token), the maintainer-runner discipline.
            _stderr("cp_worker: job=%s detached-run refusal %s (audited by run_job)"
                    % (job_id, type(exc).__name__))
            return
        except Exception as exc:  # noqa: BLE001 — a handler fault is audited in run_job; the
            # job state reflects it. Don't crash the daemon thread — but say WHY (type only), so
            # a fault that raced BEFORE run_job's own audit write is not fully invisible.
            _stderr("cp_worker: job=%s detached-run FAULT %s (state in the durable log)"
                    % (job_id, type(exc).__name__))
            return

    t = threading.Thread(
        target=_target, name="cp-job-%s" % job_id, daemon=True)
    t.start()
    return t


def start_route(identity, request, *, home=None, base_env=None, run=None):
    """POST /jobs — START a server-hosted job. Validates action_type+params through the
    §1 allowlist, ENQUEUES a durable job (cp_jobstore.create_job), and returns the
    job_id IMMEDIATELY. THE FLIGHT FIX: the client may disconnect the moment it has the
    job_id — the worker runs the job server-side off the durable record.

    `run` is an OPTIONAL test override of the worker entry that drives the job: when given,
    start_route keeps the legacy in-process detach (_detach_run) so a test can inject an
    alternate runner and observe its effect IN-PROCESS. When NOT given (the production path),
    start_route DISPATCHES via cp_jobrunner.get_job_runner(...).dispatch(...) — which selects
    HOW the job runs: an in-process daemon thread on a laptop, or a real Cloud Run Job
    execution OUT OF PROCESS on Cloud Run. This is THE FIX: the in-process thread is
    starved/killed by Cloud Run's CPU-throttle-outside-requests + scale-to-zero, leaving the
    job `queued` forever; the JobRunner runs it in a unit of work whose lifetime is
    independent of this request. Either way the handler returns the job_id WITHOUT blocking —
    the client may disconnect the instant it has the id. A bad action_type / smuggled command
    is refused HERE (422) before any job is created."""
    actor = _haid_of(identity)
    payload = _json_body(request)
    action_type = payload.get("action_type")
    params = payload.get("params")
    # §1 allowlist gate at the boundary — refuse an arbitrary command before enqueue.
    try:
        cp_allowlist.validate(action_type, params)
    except cp_allowlist.RefusedDispatch as ref:
        aid = cp_audit.record_refusal(actor, action_type, reason=ref.reason,
                                      params=params, home=home)
        return cp_server.Response(
            422, {"refused": True, "reason": ref.reason}, audit_id=aid)
    job_id = jobstore.create_job(action_type, params, instance_haid=actor, home=home)
    if job_id is None:
        return cp_server.Response(500, {"error": "job_store_unavailable"})
    cp_audit.write("job_state", actor_haid=actor, action_type=action_type,
                   job_id=job_id, outcome="ok", detail="queued", home=home)
    # THE DISPATCH (§4 L97 — out-of-process-capable): kick off the job's execution so this
    # HTTP handler returns the job_id IMMEDIATELY (the client may disconnect at once). The
    # JobRunner selects HOW it runs: in-process daemon thread (local/dev — the legacy path),
    # a detached subprocess (the local out-of-process proof), or a real Cloud Run Job
    # execution (prod) — the latter two surviving the throttle/scale-to-zero that kills the
    # in-thread model. dispatch never blocks on the job + never raises here; a dispatch
    # failure leaves the job `queued` for resume_orphans / a retry to re-drive.
    #
    # A `run` override is the legacy in-process test seam: it injects an alternate worker
    # entry whose effect must be observable IN THIS process, so it keeps the _detach_run path.
    if run is not None:
        _detach_run(run, job_id, actor_haid=actor, home=home, base_env=base_env)
        dispatched = {"dispatched": True, "runner": "thread-override"}
    else:
        import cp_jobrunner
        dispatched = cp_jobrunner.get_job_runner(home=home).dispatch(
            job_id, actor_haid=actor, home=home, base_env=base_env)
    return cp_server.Response(
        200, {"started": True, "job_id": job_id, "state": jobstore.STATE_QUEUED,
              "dispatch": dispatched})


def status_route(identity, request, *, home=None):
    """GET /jobs/<id> — STATUS by job_id, from ANY client (§4 L99). Reads the durable
    folded state (replay-on-read), so a fresh client — or a fresh process after a
    restart — reads the current state + result of a job started by a now-gone client.
    404 for an unknown job_id."""
    payload = _json_body(request)
    job_id = _job_id_from(request, payload)
    folded = jobstore.read_job(job_id, home) if job_id else None
    if folded is None:
        return cp_server.Response(404, {"error": "no_such_job", "job_id": job_id})
    return cp_server.Response(200, {"job": folded})


def _mutate_route(verb, fn, identity, request, *, home=None):
    """Shared body for the pause/resume/cancel routes (§4 L99): resolve the job_id,
    apply the durable transition fn, map an IllegalTransition to a 422 refusal. The
    transition lands in the same log the running worker polls — so a reconnected
    client steers a job this server is actively running."""
    actor = _haid_of(identity)
    payload = _json_body(request)
    job_id = _job_id_from(request, payload)
    if not job_id or jobstore.read_job(job_id, home) is None:
        return cp_server.Response(404, {"error": "no_such_job", "job_id": job_id})
    try:
        new_state = fn(job_id, actor_haid=actor, home=home)
    except jobstore.IllegalTransition as it:
        return cp_server.Response(
            422, {"refused": True, "reason": "illegal_transition",
                  "from": it.frm, "to": it.to, "job_id": job_id})
    return cp_server.Response(
        200, {verb: True, "job_id": job_id, "state": new_state})


def pause_route(identity, request, *, home=None):
    """POST /jobs/<id>/pause — cooperatively pause a running job (§4 L100)."""
    return _mutate_route("paused", request_pause, identity, request, home=home)


def resume_route(identity, request, *, home=None):
    """POST /jobs/<id>/resume — resume a paused job (§4 L100)."""
    return _mutate_route("resumed", request_resume, identity, request, home=home)


def cancel_route(identity, request, *, home=None):
    """POST /jobs/<id>/cancel — cancel a queued/running/paused job (§4 L100)."""
    return _mutate_route("cancelled", request_cancel, identity, request, home=home)


def register_job_routes(*, home=None, base_env=None, run=None):
    """Plug the /jobs surface into the server via cp_server.register_route (§10 seam) —
    WITHOUT editing cp_server. Binds the runtime home + the worker entry into each route
    so the stdlib handler (which gets only (identity, request)) carries the config.
    Registers POST /jobs (start) + status/pause/resume/cancel. Returns the registered
    route keys."""
    def _bind(fn, **extra):
        return lambda identity, request: fn(identity, request, home=home, **extra)

    keys = []
    keys.append(cp_server.register_route(
        "POST", "/jobs", _bind(start_route, base_env=base_env, run=run)))
    keys.append(cp_server.register_route("GET", "/jobs", _bind(status_route)))
    keys.append(cp_server.register_route("POST", "/jobs/pause", _bind(pause_route)))
    keys.append(cp_server.register_route("POST", "/jobs/resume", _bind(resume_route)))
    keys.append(cp_server.register_route("POST", "/jobs/cancel", _bind(cancel_route)))
    return keys
