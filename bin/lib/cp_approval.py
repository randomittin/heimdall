#!/usr/bin/env python3
# cp_approval.py — piece (e) of the Heimdall control plane: the GATE-APPROVAL QUEUE
# + OWNER OVERRIDE (fleet-level human authority).
#
# DESIGN DOSSIER §7 (authoritative) + §1 (requires_gate comes from the allowlist) +
# §10 (piece e). This module is the human-authority thesis made concrete: an
# irreversible/sensitive action (requires_gate:true in the §1 ActionSpec) does NOT
# dispatch — it enters a pending-approval queue surfaced to the OWNER, and ONLY the
# owner (cp_auth Identity.owner) can approve / reject / override it. Every decision is
# audited (§9). A non-owner cannot approve or override (AuthError). The override is the
# fleet-level human-authority lever: the owner can FORCE any gate to dispatch or block,
# but the override is itself a signed, audited act — authority is exercised, never hidden.
#
# WHAT BINDS TO THE SUBSTRATE (a) — this module IMPORTS, never edits:
#   cp_allowlist.validate(action_type, params) -> {handler, params, requires_gate, isolated}
#       The §1 dispatch gate. requires_gate=True ⇒ the action MUST queue before it runs.
#       A non-allowlisted action_type / a command-smuggle attempt RefusedDispatch — the
#       queue never enqueues an un-validated action.
#   cp_auth.Identity / AuthError
#       The owner identity basis. Only Identity.owner==True may decide a gate. A non-owner
#       attempt raises AuthError('not_owner') — the same fail-closed shape §3 uses.
#   cp_audit.write / record_dispatch
#       Every approval/rejection/override writes ONE row (event 'approval' or 'override',
#       decision approved|rejected|overridden). params recorded as SHAPE only (no values).
#   cp_server.dispatch(identity, action_type, params, approved=True) -> Response
#       The §1/§2/§9 dispatch core. On approve/override-approve the action runs THROUGH
#       this exact path (allowlist re-validated, isolated context, audited) with the
#       approved flag set — there is no privileged side-door. register_route plugs the
#       approval endpoints onto the server seam (§10) without editing cp_server.
#
# THE GATE-SURFACE VOCABULARY (reused, never re-invented): the team gate surface
# (bin/heimdall-gate-surface) speaks PROVEN / BLOCKED / PENDING. The fleet gate EXTENDS
# that vocabulary: a pending approval is PENDING; an approved/overridden(force-approve)
# action is PROVEN (it will run / has run); a rejected/overridden(force-block) action is
# BLOCKED. verdict_for_state() is the single mapping — the fleet gate surface and the
# team gate surface read the same three words.
#
# THE STATE MODEL (§7):
#   pending ──▶ approved   ──▶ (action dispatches)
#      │
#      ├──────▶ rejected   ──▶ (action refused + audited)
#      └──────▶ overridden ──(owner force)──▶ approve: dispatches | block: refused
#                                              (audit flags the override either way)
# One record per pending action at ${HEIMDALL_HOME}/control-plane/approvals/{action_id}.json.
# A terminal state (approved/rejected/overridden) is final — a second decision on a
# non-pending record is refused (stale_decision), so a gate is decided exactly once.
#
# stdlib-only (json/os/uuid/datetime) + the sibling cp_* substrate — minimal self-host deps.

from __future__ import annotations

import datetime
import json
import os
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist
import cp_audit
import cp_auth
import cp_server
import cp_state     # the pluggable persistence backend (Wave 0/1). The approval store's
                   # atomic per-action_id JSON write/read/enumerate runs THROUGH a
                   # StateBackend (get_backend) so the same tmp+os.replace put / json read /
                   # sorted listing becomes durable on Cloud Run (Wave 2 FirestoreBackend)
                   # WITHOUT changing this store. The local backend is byte-identical to the
                   # prior JSON-to-HEIMDALL_HOME path, and it owns heimdall_home() resolution
                   # (the approval store no longer needs issue_queue directly).


# ── the approval state model (§7) ──────────────────────────────────────────────

# The four states the dossier pins. PENDING is the only non-terminal state.
STATE_PENDING = "pending"
STATE_APPROVED = "approved"
STATE_REJECTED = "rejected"
STATE_OVERRIDDEN = "overridden"
APPROVAL_STATES = (STATE_PENDING, STATE_APPROVED, STATE_REJECTED, STATE_OVERRIDDEN)

# The two override directions (§7): force the gate to dispatch, or force it to block.
OVERRIDE_APPROVE = "approve"
OVERRIDE_BLOCK = "block"
OVERRIDE_FORCES = (OVERRIDE_APPROVE, OVERRIDE_BLOCK)

# The gate-surface verdict vocabulary the fleet gate REUSES (bin/heimdall-gate-surface:
# PROVEN ✓ / BLOCKED ⛔ / PENDING ·). The fleet approval states map onto these three
# words so the team gate surface and the fleet gate surface read the same verdict.
VERDICT_PENDING = "PENDING"
VERDICT_PROVEN = "PROVEN"
VERDICT_BLOCKED = "BLOCKED"

_STATE_VERDICT = {
    STATE_PENDING: VERDICT_PENDING,      # surfaced to the owner, not yet decided.
    STATE_APPROVED: VERDICT_PROVEN,      # owner approved -> the action will run / ran.
    STATE_REJECTED: VERDICT_BLOCKED,     # owner denied -> the action will not run.
    STATE_OVERRIDDEN: VERDICT_PROVEN,    # default: a force-APPROVE override (the common case).
}


def verdict_for_state(state, *, force=None):
    """Map an approval state to the gate-surface verdict (PROVEN/BLOCKED/PENDING) the
    fleet gate surface shares with the team gate surface. For an `overridden` record the
    `force` direction disambiguates: a force-block override is BLOCKED, a force-approve
    override is PROVEN. An unknown state maps to PENDING (fail-safe: never claim PROVEN
    for a state we do not recognize)."""
    if state == STATE_OVERRIDDEN and force == OVERRIDE_BLOCK:
        return VERDICT_BLOCKED
    return _STATE_VERDICT.get(state, VERDICT_PENDING)


# ── the auth gate (only the OWNER may decide a gate — §3/§7) ────────────────────


def _require_owner(identity):
    """Assert `identity` is a verified OWNER (cp_auth Identity.owner). Returns the
    actor HAID on success. Raises cp_auth.AuthError('not_owner') otherwise — the same
    fail-closed shape the §3 chokepoint uses, so a non-owner attempt to approve / reject
    / override a gate is refused exactly like an unauthenticated request. This is the
    fleet human-authority boundary: a gate is the OWNER's decision alone."""
    if not isinstance(identity, cp_auth.Identity):
        raise cp_auth.AuthError("not_owner", "an Identity is required to decide a gate")
    if not identity.owner:
        raise cp_auth.AuthError("not_owner", "only the owner may decide a gate")
    return identity.haid


# ── the approvals store (one record per pending action — §7) ───────────────────
#
# NDJSON-sibling layout: one JSON file per action_id under the runtime home's
# control-plane/approvals/ (mirrors cp_auth's keys.json + cp_audit's audit store
# atomic-write discipline). One writer per file ⇒ no contention on the queue.
#
# The store is addressed by paths RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the
# StateBackend rel namespace): the approvals dir is "approvals/", one action's record is
# "approvals/{action_id}.json". The backend owns the home root + makedirs + the atomic
# tmp+os.replace / indent=2 byte shape; approvals_dir/_record_path remain the public
# absolute-path accessors (now derived from the backend's path(), so they stay
# byte-identical to the prior layout).

# the rel sub-dir all approval records live under, within control-plane/.
_APPROVALS_REL = "approvals"


def _backend(home=None):
    """The StateBackend for the approval store (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every approval accessor's `home=` arg always
    has."""
    return cp_state.get_backend(home=home)


def _approval_rel(action_id):
    """The store-relative path of one action's approval record: approvals/{action_id}.json.
    action_id is server-minted (act-<uuid>), so it is filename-safe by construction; we
    still basename-guard it so a crafted id can never escape the approvals dir."""
    safe = os.path.basename(str(action_id))
    return os.path.join(_APPROVALS_REL, safe + ".json")


def approvals_dir(home=None):
    """The approvals store dir: ${HEIMDALL_HOME}/control-plane/approvals/ (the backend's
    absolute path for the approvals rel-dir — unchanged on the local backend)."""
    return _backend(home).path(_APPROVALS_REL)


def _record_path(action_id, home=None):
    """The on-disk path for one action's approval record. action_id is server-minted
    (act-<uuid>), so it is filename-safe by construction; we still basename-guard it so
    a crafted id can never escape the approvals dir."""
    return _backend(home).path(_approval_rel(action_id))


def _now_iso():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def _write_record(record, home=None):
    """Atomic write of one approval record (tmp + os.replace, indent=2), mirroring
    cp_auth's discipline. Returns True on success, False on an IO failure.

    Routed THROUGH the StateBackend (Wave 1): put_record writes the same atomic
    tmp+os.replace, json.dump(sort_keys=True, indent=2) keyed record the approval store
    has always written — so the .json file is byte-identical on the local backend, and
    the SAME atomic put becomes Cloud-Run-durable when the Wave-2 backend lands."""
    return _backend(home).put_record(_approval_rel(record["action_id"]), record)


def get(action_id, home=None):
    """Read one approval record, or None if no such pending/decided action exists.
    Read-only; tolerant of a missing/corrupt file (returns None).

    Routed THROUGH the StateBackend (Wave 1): get_record returns the same single keyed
    JSON record (or None when absent/corrupt) the approval store has always read."""
    return _backend(home).get_record(_approval_rel(action_id))


def list_pending(home=None):
    """Every action currently awaiting an owner decision (state == pending), oldest
    first by submit ts. This is the queue the owner sees (§7 / NOTIFY §8 fires on submit).
    Read-only; tolerant of an absent store ([]).

    Routed THROUGH the StateBackend (Wave 1): list_names returns the same sorted,
    suffix-filtered enumeration; we strip the .json suffix to recover the action_id and
    re-fold each record's state, exactly as before."""
    out = []
    for name in _backend(home).list_names(_APPROVALS_REL, suffix=".json"):
        rec = get(name[: -len(".json")], home)
        if rec and rec.get("state") == STATE_PENDING:
            out.append(rec)
    out.sort(key=lambda r: r.get("submitted_at") or "")
    return out


# ── submit: a gated action ENTERS the queue (no dispatch) — the falsifiable core ─


def submit(identity, action_type, params, *, home=None, base_env=None):
    """Submit an action to the control plane THROUGH the gate (§1/§7). The flow:

      1. cp_allowlist.validate(action_type, params) — the §1 gate. An unknown action
         OR a command-smuggle attempt raises cp_allowlist.RefusedDispatch (the caller
         maps it to 422); the queue NEVER enqueues an un-validated action.
      2. requires_gate==False  ⇒ a non-gated action dispatches IMMEDIATELY through
         cp_server.dispatch (the normal §1 path) — it does NOT enter the queue.
      3. requires_gate==True   ⇒ THE FALSIFIABLE CORE: the action does NOT dispatch.
         A `pending` record is written to the approvals store and surfaced to the
         owner. NOTHING runs until an owner-signed approve/override lands. A build that
         auto-dispatched a gated action here would RED the cp-approval test.

    Returns a dict:
      {action_id, action_type, state, dispatched, status, requires_gate, verdict, response?}
    For a gated action: state='pending', dispatched=False, verdict='PENDING'. For a
    non-gated action: state='approved' (it ran), dispatched=True, the dispatch Response.

    `identity` is the SUBMITTER (any authenticated instance may request an action); it
    is NOT the approver — only the owner can later approve (see approve/override)."""
    actor = identity.haid if isinstance(identity, cp_auth.Identity) else identity

    # 1. §1 allowlist gate — refusal propagates (the queue never holds an un-validated action).
    plan = cp_allowlist.validate(action_type, params)  # raises RefusedDispatch on refusal.

    action_id = "act-" + uuid.uuid4().hex

    # 2. a NON-gated action dispatches immediately — it never enters the queue.
    if not plan["requires_gate"]:
        resp = cp_server.dispatch(
            identity, action_type, params, home=home, approved=False, base_env=base_env)
        return {
            "action_id": resp.body.get("action_id", action_id),
            "action_type": action_type,
            "state": STATE_APPROVED if resp.status == 200 else STATE_REJECTED,
            "dispatched": resp.status == 200,
            "status": resp.status,
            "requires_gate": False,
            "verdict": verdict_for_state(
                STATE_APPROVED if resp.status == 200 else STATE_REJECTED),
            "response": resp.to_dict(),
        }

    # 3. THE FALSIFIABLE CORE — a gated action ENTERS pending, dispatches NOTHING.
    record = {
        "schema_version": "1.0.0",
        "action_id": action_id,
        "action_type": action_type,
        "state": STATE_PENDING,
        "submitter_haid": actor,
        "submitted_at": _now_iso(),
        # params SHAPE only on the record (no values) — same no-secret discipline the
        # audit uses; the validated params are re-derived from the allowlist on dispatch.
        "params_shape": cp_audit.params_shape(plan["params"]),
        "params": dict(plan["params"]),  # the validated, typed, bounded params to dispatch.
        "decided_by": None,
        "decided_at": None,
        "force": None,
    }
    _write_record(record, home)

    # audit: the action is now pending owner approval (decision None, outcome refused —
    # it did NOT run). This mirrors cp_server.dispatch's own gate-hold audit row.
    cp_audit.write(
        "approval", actor_haid=actor, action_type=action_type, action_id=action_id,
        decision=None, outcome="refused", params=plan["params"],
        detail="pending owner approval", home=home,
    )
    return {
        "action_id": action_id,
        "action_type": action_type,
        "state": STATE_PENDING,
        "dispatched": False,
        "status": 202,            # Accepted-but-not-executed: queued for the owner.
        "requires_gate": True,
        "verdict": VERDICT_PENDING,
    }


# ── the owner decision helpers (load + guard a pending record) ─────────────────


class ApprovalError(Exception):
    """Raised when an approval operation is not applicable: no such action
    (unknown_action_id), or a decision on an already-decided record (stale_decision),
    or a bad override force (bad_force). Distinct from cp_auth.AuthError (which is the
    NON-OWNER refusal) — this is a state/precondition error, not an authority refusal."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


def _load_pending(action_id, home):
    """Load a record that MUST be pending, or raise ApprovalError. A decision on a
    non-pending (already approved/rejected/overridden) record is refused — a gate is
    decided exactly once, no re-deciding a terminal state."""
    rec = get(action_id, home)
    if rec is None:
        raise ApprovalError("unknown_action_id", "no pending approval for this action")
    if rec.get("state") != STATE_PENDING:
        raise ApprovalError(
            "stale_decision", "action already %s" % rec.get("state"))
    return rec


def _finalize(rec, *, state, decider_haid, force, home):
    """Write the terminal state onto a record (the decision is final). Returns the
    updated record."""
    rec["state"] = state
    rec["decided_by"] = decider_haid
    rec["decided_at"] = _now_iso()
    rec["force"] = force
    _write_record(rec, home)
    return rec


def _dispatch_approved(rec, decider, *, home, base_env):
    """Run a now-approved action THROUGH cp_server.dispatch with approved=True — the
    SAME §1/§2/§9 path every action takes (allowlist re-validated, isolated context,
    audited). There is no privileged side-door: an approved gate runs the normal path
    with the approved flag set. Returns the dispatch Response."""
    return cp_server.dispatch(
        decider, rec["action_type"], rec["params"],
        home=home, approved=True, base_env=base_env,
    )


# ── APPROVE / REJECT (owner-only — §7) ─────────────────────────────────────────


def approve(identity, action_id, *, home=None, base_env=None):
    """OWNER approves a pending gated action -> it DISPATCHES (§7). Only the owner may
    call this (cp_auth.AuthError('not_owner') otherwise — no dispatch). The decision is
    audited (event 'approval', decision 'approved') BEFORE the dispatch, and the dispatch
    itself writes its own §9 dispatch row. Returns:
      {action_id, state:'approved', dispatched:bool, status, verdict, response}
    On a non-pending / unknown action raises ApprovalError (the gate is decided once)."""
    decider_haid = _require_owner(identity)           # non-owner -> AuthError, no dispatch.
    rec = _load_pending(action_id, home)               # unknown/stale -> ApprovalError.
    _finalize(rec, state=STATE_APPROVED, decider_haid=decider_haid, force=None, home=home)

    # audit the OWNER's approval decision (every decision is in the log — §9).
    cp_audit.write(
        "approval", actor_haid=decider_haid, action_type=rec["action_type"],
        action_id=action_id, decision="approved", outcome="ok",
        params=rec["params"], detail="owner approved", home=home,
    )
    resp = _dispatch_approved(rec, identity, home=home, base_env=base_env)
    # correlate the queue record to the dispatched action: cp_server.dispatch mints its
    # own action_id (it owns id-minting; we never edit it), so we record the dispatched
    # child id back onto the approval record so the §9 dispatch row is findable from the
    # queue record — the approve decision row + the dispatch row are now linkable.
    dispatched_id = resp.body.get("action_id")
    rec["dispatched_action_id"] = dispatched_id
    _write_record(rec, home)
    return {
        "action_id": action_id,
        "dispatched_action_id": dispatched_id,
        "state": STATE_APPROVED,
        "dispatched": resp.status == 200,
        "status": resp.status,
        "verdict": verdict_for_state(STATE_APPROVED),
        "response": resp.to_dict(),
    }


def reject(identity, action_id, *, reason="owner rejected", home=None):
    """OWNER denies a pending gated action -> it does NOT dispatch (§7). Owner-only
    (AuthError otherwise). The decision is audited (event 'approval', decision
    'rejected', outcome 'refused'). Nothing runs. Returns:
      {action_id, state:'rejected', dispatched:False, status:403, verdict:'BLOCKED'}"""
    decider_haid = _require_owner(identity)
    rec = _load_pending(action_id, home)
    _finalize(rec, state=STATE_REJECTED, decider_haid=decider_haid, force=None, home=home)

    cp_audit.write(
        "approval", actor_haid=decider_haid, action_type=rec["action_type"],
        action_id=action_id, decision="rejected", outcome="refused",
        params=rec["params"], detail=reason, home=home,
    )
    return {
        "action_id": action_id,
        "state": STATE_REJECTED,
        "dispatched": False,
        "status": 403,
        "verdict": verdict_for_state(STATE_REJECTED),
    }


# ── OVERRIDE (the human-authority thesis, owner-only — §7) ──────────────────────


def override(identity, action_id, *, force, reason="owner override", home=None,
             base_env=None):
    """OWNER OVERRIDES a gate (§7) — the fleet-level human-authority lever. The owner can
    FORCE a pending action to dispatch (force='approve') OR force it to block
    (force='block'). EITHER way the override is audited as an `override` row (decision
    'overridden') — authority is exercised, never hidden. Owner-only (AuthError for a
    non-owner — no force). The record's terminal state is 'overridden'; the `force`
    field records which direction (so verdict_for_state can disambiguate PROVEN/BLOCKED).

    Returns:
      force='approve' -> {state:'overridden', dispatched:bool, status, verdict:'PROVEN', response}
      force='block'   -> {state:'overridden', dispatched:False, status:403, verdict:'BLOCKED'}

    Raises ApprovalError('bad_force') for a force other than approve/block, or
    ('unknown_action_id'/'stale_decision') for a missing / already-decided record."""
    if force not in OVERRIDE_FORCES:
        raise ApprovalError("bad_force", "force must be 'approve' or 'block'")
    decider_haid = _require_owner(identity)            # non-owner -> AuthError, no force.
    rec = _load_pending(action_id, home)
    _finalize(rec, state=STATE_OVERRIDDEN, decider_haid=decider_haid, force=force, home=home)

    # audit the override (every override is a signed, audited act — §7/§9).
    cp_audit.write(
        "override", actor_haid=decider_haid, action_type=rec["action_type"],
        action_id=action_id, decision="overridden",
        outcome="ok" if force == OVERRIDE_APPROVE else "refused",
        params=rec["params"],
        detail="owner override force-%s: %s" % (force, reason), home=home,
    )

    if force == OVERRIDE_BLOCK:
        return {
            "action_id": action_id,
            "state": STATE_OVERRIDDEN,
            "dispatched": False,
            "status": 403,
            "verdict": verdict_for_state(STATE_OVERRIDDEN, force=OVERRIDE_BLOCK),
            "force": OVERRIDE_BLOCK,
        }

    # force-approve: dispatch through the normal §1 path with approved=True.
    resp = _dispatch_approved(rec, identity, home=home, base_env=base_env)
    dispatched_id = resp.body.get("action_id")
    rec["dispatched_action_id"] = dispatched_id
    _write_record(rec, home)
    return {
        "action_id": action_id,
        "dispatched_action_id": dispatched_id,
        "state": STATE_OVERRIDDEN,
        "dispatched": resp.status == 200,
        "status": resp.status,
        "verdict": verdict_for_state(STATE_OVERRIDDEN, force=OVERRIDE_APPROVE),
        "force": OVERRIDE_APPROVE,
        "response": resp.to_dict(),
    }


# ── server route handlers (the §10 register_route seam — b-f plug in here) ──────
#
# Each handler receives the verified Identity (the §3 chokepoint already authenticated
# the request) + the parsed request dict, and returns a cp_server.Response. The owner
# guard runs AGAIN here (defence in depth): even a route reachable only via the auth
# chokepoint re-checks Identity.owner, so a non-owner authenticated caller still cannot
# decide a gate. AuthError -> 403; ApprovalError -> 404 (unknown) / 409 (stale).


def _request_payload(request):
    """Parse the JSON body of an approval request into a dict (the action_id + any
    reason/force). Tolerant: a malformed/empty body yields {}."""
    body = request.get("body") if isinstance(request, dict) else None
    if isinstance(body, (bytes, bytearray)):
        try:
            body = body.decode("utf-8")
        except Exception:  # noqa: BLE001 — undecodable body -> empty payload.
            return {}
    if not body:
        return {}
    try:
        obj = json.loads(body)
    except (ValueError, TypeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def _decision_response(fn, identity, payload, *, home):
    """Run an owner-decision fn, mapping its outcome/exceptions to a cp_server.Response.
    AuthError (non-owner) -> 403; ApprovalError unknown -> 404, stale/bad_force -> 409."""
    action_id = payload.get("action_id")
    if not action_id:
        return cp_server.Response(422, {"refused": True, "reason": "missing_action_id"})
    try:
        result = fn(identity, action_id)
    except cp_auth.AuthError as err:
        # a non-owner authenticated caller cannot decide a gate — refused, audited.
        cp_audit.write(
            "auth_fail",
            actor_haid=identity.haid if isinstance(identity, cp_auth.Identity) else None,
            action_id=action_id, outcome="refused", detail=err.reason, home=home,
        )
        return cp_server.Response(403, {"refused": True, "reason": err.reason})
    except ApprovalError as err:
        status = 404 if err.reason == "unknown_action_id" else 409
        return cp_server.Response(status, {"refused": True, "reason": err.reason})
    status = result.get("status", 200)
    return cp_server.Response(status, result)


def route_approve(identity, request, *, home=None):
    """POST /approvals/approve — owner approves a pending action -> dispatch."""
    payload = _request_payload(request)
    return _decision_response(
        lambda ident, aid: approve(ident, aid, home=home), identity, payload, home=home)


def route_reject(identity, request, *, home=None):
    """POST /approvals/reject — owner rejects a pending action -> no dispatch."""
    payload = _request_payload(request)
    reason = str(payload.get("reason") or "owner rejected")[:120]
    return _decision_response(
        lambda ident, aid: reject(ident, aid, reason=reason, home=home),
        identity, payload, home=home)


def route_override(identity, request, *, home=None):
    """POST /approvals/override — owner forces a gate (force=approve|block), audited."""
    payload = _request_payload(request)
    force = payload.get("force")
    reason = str(payload.get("reason") or "owner override")[:120]
    return _decision_response(
        lambda ident, aid: override(ident, aid, force=force, reason=reason, home=home),
        identity, payload, home=home)


def route_pending(identity, request, *, home=None):
    """GET /approvals/pending — the queue of actions awaiting an owner decision. Any
    authenticated identity may READ the queue (only deciding is owner-gated)."""
    return cp_server.Response(200, {"pending": list_pending(home)})


def register(home=None):
    """Register the approval endpoints onto the cp_server route seam (§10). Pieces plug
    routes in WITHOUT editing cp_server. Returns the registered route keys. Called at
    wire time (the CLI / server bootstrap). `home` is closed over so the routes write to
    the same runtime home the server serves."""
    keys = []
    keys.append(cp_server.register_route(
        "POST", "/approvals/approve",
        lambda ident, req: route_approve(ident, req, home=home)))
    keys.append(cp_server.register_route(
        "POST", "/approvals/reject",
        lambda ident, req: route_reject(ident, req, home=home)))
    keys.append(cp_server.register_route(
        "POST", "/approvals/override",
        lambda ident, req: route_override(ident, req, home=home)))
    keys.append(cp_server.register_route(
        "GET", "/approvals/pending",
        lambda ident, req: route_pending(ident, req, home=home)))
    return keys


# Register on import so a process that imports cp_approval gets the routes wired (the
# server bootstrap imports the wave-2 pieces to plug their seams). Idempotent —
# re-registering a key replaces it (cp_server.register_route's documented behavior).
register()
