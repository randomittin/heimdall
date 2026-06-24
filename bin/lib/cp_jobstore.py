#!/usr/bin/env python3
# cp_jobstore.py — piece (d) of the Heimdall control plane: PERSISTENT JOB STATE.
#
# DESIGN DOSSIER §4 + §2 (authoritative). THE FLIGHT FIX's durable half: a job's
# state lives in an append-only NDJSON log on disk, NOT in process memory. A client
# starts a job and disconnects; the job state survives that disconnect AND a full
# server process restart, because state is the FOLD of the on-disk event log — replay
# the log on boot and you have the live state back. Any client reconnects and reads
# the current folded state to status/pause/resume/cancel.
#
# THE STORE (§4 L94) — one job = one file = one writer:
#   ${HEIMDALL_HOME}/control-plane/jobs/{job_id}.ndjson
#   Each line is one transition/progress event; the CURRENT state is the fold of all
#   lines (last state wins, progress/result accrue). NDJSON (not SQLite, not in-mem)
#   so the store scans as plaintext for `bin/secret-scan` (gitleaks) — mirrors the
#   telemetry.py / cp_audit.py store discipline. Append + flush is the cheapest
#   durable write; a crash mid-job loses at most the un-flushed tail, never the state.
#
# THE STATE MACHINE (§4) — states {queued, running, paused, done, cancelled}; only
# LEGAL transitions are accepted, an illegal one is REFUSED (returns None / raises
# IllegalTransition for the caller to audit). The legal edges (dossier §4 diagram):
#   queued   -> running | cancelled
#   running  -> paused  | done | cancelled
#   paused   -> running | cancelled
#   done / cancelled are TERMINAL (no outgoing edge).
#
# NO-SECRET-BY-CONSTRUCTION (§2/§9) — `progress` is a bounded numeric/short-tag scalar
# and `result` is a structured handler result (already bounded, value-free by the
# handler contract). The store records the job's OWN data; it carries NO control-plane
# secret (the worker that writes here runs inside the §2 IsolatedContext and has no
# PKI key / audit / server secret to leak in the first place).
#
# THE INTERFACE cp_worker + the /jobs endpoints (piece d) BIND to (stable):
#   STATES / TERMINAL_STATES                 — the pinned state vocabulary.
#   LEGAL_TRANSITIONS                        — the legal edge map.
#   IllegalTransition                        — the refused-transition exception.
#   create_job(action_type, params, ...)     — enqueue a new job, returns job_id.
#   append_event(job_id, **fields)           — append one raw event line (low-level).
#   transition(job_id, new_state, ...)       — a state change, transition-validated.
#   set_progress(job_id, progress, ...)      — record a progress tick (no state change).
#   set_result(job_id, result, ...)          — record the job's final result.
#   fold_state(job_id) / read_job(job_id)    — the current folded state (replay-on-read).
#   list_jobs() / jobs_dir()                  — enumerate the store.
#
# stdlib-only (json/os/uuid/datetime) + issue_queue (REUSE heimdall_home) — mirrors
# telemetry.py / cp_audit.py exactly. No third-party dep, self-hostable.

from __future__ import annotations

import datetime
import json
import os
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # REUSE heimdall_home() — the store lands in the same runtime home.

# ── schema constants (the pinned job contract — §4) ───────────────────────────

SCHEMA_VERSION = "1.0.0"

# The job state vocabulary (§4). fold_state never reports a state outside this set.
STATE_QUEUED = "queued"
STATE_RUNNING = "running"
STATE_PAUSED = "paused"
STATE_DONE = "done"
STATE_CANCELLED = "cancelled"

STATES = (STATE_QUEUED, STATE_RUNNING, STATE_PAUSED, STATE_DONE, STATE_CANCELLED)

# Terminal states have NO outgoing transition — a job that is done/cancelled is final.
TERMINAL_STATES = (STATE_DONE, STATE_CANCELLED)

# The LEGAL transition edges (§4 diagram). A transition not named here is REFUSED.
# This is the state-machine wall: an illegal mutation (e.g. done -> running, or
# resume of a never-paused job) cannot corrupt the log — it is rejected + auditable.
LEGAL_TRANSITIONS = {
    STATE_QUEUED: (STATE_RUNNING, STATE_CANCELLED),
    STATE_RUNNING: (STATE_PAUSED, STATE_DONE, STATE_CANCELLED),
    STATE_PAUSED: (STATE_RUNNING, STATE_CANCELLED),
    STATE_DONE: (),
    STATE_CANCELLED: (),
}

# event kinds written to the log (the fold reads these). state events carry a `state`;
# progress events carry a `progress`; result events carry a `result`.
EV_STATE = "state"
EV_PROGRESS = "progress"
EV_RESULT = "result"


class IllegalTransition(Exception):
    """Raised when a state change is not a LEGAL_TRANSITIONS edge from the job's
    current folded state (e.g. resume a running job, or transition a terminal job).
    The §4 legal-transitions-only rule, enforced — the caller (worker / endpoint)
    maps this to a refusal + an audit row. An illegal transition NEVER lands in the
    log, so the fold can never reach an impossible state."""

    def __init__(self, job_id, frm, to):
        self.job_id = job_id
        self.frm = frm
        self.to = to
        super().__init__(
            "illegal transition %s: %s -> %s" % (job_id, frm, to))


# ── store location (REUSE issue_queue.heimdall_home — never re-derive) ─────────


def jobs_dir(home=None):
    """The job store dir: ${HEIMDALL_HOME}/control-plane/jobs/."""
    base = home if home else issue_queue.heimdall_home()
    return os.path.join(base, "control-plane", "jobs")


def job_path(job_id, home=None):
    """Absolute path to one job's append-only NDJSON log. One job = one file."""
    return os.path.join(jobs_dir(home), "%s.ndjson" % job_id)


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (§4 ts field)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def new_job_id():
    """A stable id for one server-hosted job: 'job-<uuid4hex>'."""
    return "job-" + uuid.uuid4().hex


# ── the low-level append (one durable line — the only writer) ──────────────────


def _append_line(job_id, record, home=None):
    """Append one JSON line to {job_id}.ndjson, creating the store dir if needed.
    Returns True on a durable write (flushed), False on any IO failure. This is the
    ONLY way the log grows — every public mutator funnels through here so the file
    stays append-only with a single writer per job (§4 L94)."""
    try:
        ldir = jobs_dir(home)
        os.makedirs(ldir, exist_ok=True)
        path = os.path.join(ldir, "%s.ndjson" % job_id)
        line = json.dumps(record, sort_keys=True, separators=(",", ":"))
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
            os.fsync(fh.fileno())  # durability: the state survives a hard crash/restart.
        return True
    except OSError:
        return False


def append_event(job_id, *, ev, state=None, progress=None, result=None,
                 action_type=None, params=None, instance_haid=None, detail=None,
                 home=None):
    """Append ONE raw event line to the job log (low-level; mutators wrap this).
    Returns the written record dict on success, or None on an IO failure. The line
    shape (§4 L94): {job_id, ts, ev, state?, progress?, result?, action_type?,
    params?, instance_haid?, detail?}. Only the keys relevant to `ev` are set."""
    record = {
        "schema_version": SCHEMA_VERSION,
        "job_id": job_id,
        "ts": _now_iso(),
        "ev": ev,
    }
    if state is not None:
        record["state"] = state
    if progress is not None:
        record["progress"] = progress
    if result is not None:
        record["result"] = result
    if action_type is not None:
        record["action_type"] = action_type
    if params is not None:
        record["params"] = params
    if instance_haid is not None:
        record["instance_haid"] = instance_haid
    if detail is not None:
        record["detail"] = detail
    if not _append_line(job_id, record, home):
        return None
    return record


# ── create: enqueue a new job (the first log line — state=queued) ──────────────


def create_job(action_type, params, *, instance_haid=None, job_id=None, home=None):
    """Enqueue a NEW job: write the genesis line (ev=state, state=queued) carrying the
    action_type + the originating instance_haid + the (already allowlist-validated)
    params. Returns the job_id. THE FLIGHT FIX starts here: the caller (the /jobs start
    endpoint) returns this job_id to the client immediately; the client may disconnect
    while the worker runs the job server-side off this durable record.

    `params` is recorded so a restart-replay can re-dispatch the job to the worker;
    the values are the action's OWN validated scalars (not secrets) — but the endpoint
    is responsible for having run cp_allowlist.validate first, so no command string or
    off-pattern value ever reaches the log."""
    jid = job_id or new_job_id()
    rec = append_event(
        jid, ev=EV_STATE, state=STATE_QUEUED, action_type=action_type,
        params=params, instance_haid=instance_haid, home=home,
    )
    if rec is None:
        return None
    return jid


# ── the fold: state = replay of the append-only log (restart-durable) ──────────


def _read_lines(job_id, home=None):
    """Stream the parsed event lines for a job in store order. Tolerant: a bad line is
    skipped, an absent log yields []. Read-only — this is the replay the fold runs on
    EVERY read, so a fresh process (post-restart) reconstructs live state from disk."""
    path = job_path(job_id, home)
    out = []
    if not os.path.isfile(path):
        return out
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        return out
    return out


def fold_state(job_id, home=None):
    """Fold the append-only log into the CURRENT job state — the §4 source of truth.
    Returns a dict {job_id, state, action_type, params, instance_haid, progress,
    result, events, ts} or None if the job has no log (never created).

    The fold rule: the LAST state event wins; progress is the last progress (or the
    progress carried on a state line); result is the last result; action_type/params/
    instance_haid come from the genesis line. Because this is a pure replay of the
    on-disk log, a brand-new process AFTER A RESTART reconstructs the exact live state
    — the flight fix's durability guarantee, made concrete."""
    lines = _read_lines(job_id, home)
    if not lines:
        return None
    state = None
    action_type = None
    params = None
    instance_haid = None
    progress = None
    result = None
    last_ts = None
    for rec in lines:
        last_ts = rec.get("ts", last_ts)
        if action_type is None and rec.get("action_type") is not None:
            action_type = rec.get("action_type")
        if params is None and rec.get("params") is not None:
            params = rec.get("params")
        if instance_haid is None and rec.get("instance_haid") is not None:
            instance_haid = rec.get("instance_haid")
        ev = rec.get("ev")
        if ev == EV_STATE and rec.get("state") in STATES:
            state = rec.get("state")
        if rec.get("progress") is not None:
            progress = rec.get("progress")
        if rec.get("result") is not None:
            result = rec.get("result")
    return {
        "job_id": job_id,
        "state": state,
        "action_type": action_type,
        "params": params,
        "instance_haid": instance_haid,
        "progress": progress,
        "result": result,
        "events": len(lines),
        "ts": last_ts,
    }


def read_job(job_id, home=None):
    """The current folded job view (alias of fold_state — the public read name the
    /jobs status endpoint calls). Returns None for an unknown job_id."""
    return fold_state(job_id, home)


def current_state(job_id, home=None):
    """Just the current state string for a job, or None if the job is unknown. The
    cheap accessor the worker polls for the cooperative pause/cancel flags (§4 L100)."""
    folded = fold_state(job_id, home)
    return folded.get("state") if folded else None


# ── transition: a state change, LEGAL-TRANSITIONS-validated (§4) ───────────────


def can_transition(frm, to):
    """True iff `frm -> to` is a LEGAL_TRANSITIONS edge. A terminal `frm` has no legal
    `to`. An unknown `frm` (job not yet created) permits only the genesis queued state
    via create_job, never via transition() — so can_transition(None, x) is False."""
    if frm not in LEGAL_TRANSITIONS:
        return False
    return to in LEGAL_TRANSITIONS[frm]


def transition(job_id, new_state, *, progress=None, detail=None, home=None):
    """Move a job to `new_state`, accepting ONLY a LEGAL_TRANSITIONS edge from the
    job's CURRENT folded state. Returns the new state string on success. Raises
    IllegalTransition for an illegal edge (terminal job, or a non-edge like
    queued->paused) — the change NEVER lands in the log, so the fold can never reach
    an impossible state. Raises IllegalTransition (frm=None) for an unknown job.

    A successful transition appends one ev=state line (optionally carrying a progress
    tick), making the new state durable immediately — survives a disconnect/restart."""
    if new_state not in STATES:
        raise IllegalTransition(job_id, None, new_state)
    frm = current_state(job_id, home)
    if not can_transition(frm, new_state):
        raise IllegalTransition(job_id, frm, new_state)
    rec = append_event(
        job_id, ev=EV_STATE, state=new_state, progress=progress, detail=detail,
        home=home,
    )
    if rec is None:
        raise IllegalTransition(job_id, frm, new_state)
    return new_state


def set_progress(job_id, progress, *, home=None):
    """Record a progress tick (no state change) — the worker streams progress to the
    LOG, not the client socket (§4 L98), so progress survives a disconnect. `progress`
    is a bounded scalar (an int 0..100 or a short tag). Returns True on a written tick.
    A progress tick on a terminal/absent job is a no-op write (the state is unchanged
    either way) — it carries no state, so it cannot corrupt the fold."""
    if progress is None:
        return False
    rec = append_event(job_id, ev=EV_PROGRESS, progress=progress, home=home)
    return rec is not None


def set_result(job_id, result, *, home=None):
    """Record the job's structured result (the handler's return value) as a durable
    log line. Returns True on a written line. Recorded separately from the terminal
    state transition so a reader sees the result the moment it lands; the worker
    typically calls set_result then transition(..., done)."""
    if result is None:
        return False
    rec = append_event(job_id, ev=EV_RESULT, result=result, home=home)
    return rec is not None


# ── enumerate the store (for status/CLI + restart replay) ──────────────────────


def list_job_ids(home=None):
    """The sorted list of job_ids present in the store (one .ndjson file each).
    Tolerant of an absent store ([]). The restart-replay driver iterates these to
    re-fold every job's live state on boot — and to find jobs that were `running`
    when the process died, for the worker to resume."""
    ldir = jobs_dir(home)
    out = []
    try:
        if not os.path.isdir(ldir):
            return out
        for name in sorted(os.listdir(ldir)):
            if name.endswith(".ndjson"):
                out.append(name[: -len(".ndjson")])
    except OSError:
        return out
    return out


def list_jobs(home=None):
    """The folded view of every job in the store (restart-durable enumeration). Each
    entry is a fold_state dict. The /jobs list + the boot replay both build on this."""
    out = []
    for jid in list_job_ids(home):
        folded = fold_state(jid, home)
        if folded is not None:
            out.append(folded)
    return out
