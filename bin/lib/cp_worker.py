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

import os
import sys
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
            checkpoints=4):
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
    if state == jobstore.STATE_RUNNING:
        # a sibling worker is already on it; do not double-run.
        return folded

    action_type = folded.get("action_type")
    raw_params = folded.get("params") or {}

    # 1. queued -> running (durable + audited). Any client may now disconnect.
    jobstore.transition(job_id, jobstore.STATE_RUNNING, home=home)
    cp_audit.write("job_state", actor_haid=actor_haid, job_id=job_id,
                   action_type=action_type, outcome="ok", detail="running",
                   home=home)

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


def resume_orphans(*, actor_haid=None, home=None, base_env=None, checkpoints=4):
    """After a server RESTART, re-fold every job in the store and drive any job left
    `queued` (or interrupted before running) back to completion (§4 L94 replay-on-boot).
    A job that was `running` when the process died is re-folded from disk; this driver
    re-runs the queued ones so the flight fix survives a full process restart, not just
    a client disconnect. Returns the list of (job_id, final_state) it advanced.

    A `paused`/terminal job is left as-is (a human/owner controls those). This is the
    boot hook the server calls to make durable jobs self-healing across restarts."""
    advanced = []
    for jid in jobstore.list_job_ids(home):
        folded = jobstore.fold_state(jid, home)
        if folded is None:
            continue
        if folded.get("state") == jobstore.STATE_QUEUED:
            try:
                final = run_job(jid, actor_haid=actor_haid, home=home,
                                base_env=base_env, checkpoints=checkpoints)
                advanced.append((jid, final.get("state") if final else None))
            except (ActionRefused, IsolationRefused, jobstore.IllegalTransition):
                advanced.append((jid, jobstore.current_state(jid, home)))
    return advanced


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
    """Resolve the target job_id from the request path (/jobs/<id>/<verb>) or the body.
    Path-first so a REST shape works; body fallback for a direct call."""
    if isinstance(payload, dict) and payload.get("job_id"):
        return payload.get("job_id")
    path = request.get("path") if isinstance(request, dict) else None
    if isinstance(path, str) and path.startswith("/jobs/"):
        rest = path[len("/jobs/"):].strip("/").split("/")
        if rest and rest[0]:
            return rest[0]
    return None


def start_route(identity, request, *, home=None, base_env=None, run=None):
    """POST /jobs — START a server-hosted job. Validates action_type+params through the
    §1 allowlist, ENQUEUES a durable job (cp_jobstore.create_job), and returns the
    job_id IMMEDIATELY. THE FLIGHT FIX: the client may disconnect the moment it has the
    job_id — the worker runs the job server-side off the durable record.

    `run` is the worker entry the server schedules (default run_job); the server passes
    a thread-scheduling wrapper so start returns without blocking on the job. A bad
    action_type / smuggled command is refused HERE (422) before any job is created."""
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
    runner = run if run is not None else run_job
    runner(job_id, actor_haid=actor, home=home, base_env=base_env)
    return cp_server.Response(
        200, {"started": True, "job_id": job_id, "state": jobstore.STATE_QUEUED})


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
