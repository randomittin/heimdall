#!/usr/bin/env python3
# cp_god.py — OWNER-ONLY CROSS-TENANT "GOD MODE" of the Heimdall control plane.
#
# WHY THIS EXISTS (and why it is gated the hardest). Every other read on the control
# plane is TEAM-SCOPED: a signed member sees ONLY its own team's partition, a browser
# with a team secret sees ONLY derive_team_id(secret). God mode is the deliberate
# INVERSE — a single owner watches EVERY team at once (a cross-tenant presence + activity
# aggregate). Because it reads across the multi-tenant isolation boundary, it is the most
# dangerous surface in the system and is gated by INV-GOD (evals/oracles/rr-multitenant-
# isolation/INVARIANTS.md), whose falsifiable oracle is authored BEFORE this handler and
# which this module MUST pass:
#
#   G1/G2  — /god/* is NEVER on the PUBLIC route allowlist (cp_publicsurface.PUBLIC_ROUTES).
#            On the internet-facing --allow-unauthenticated public service, cp_server's
#            routing-layer boundary 404s any route not in PUBLIC_ROUTES BEFORE auth, BEFORE
#            any handler — so an anonymous caller (G1) AND a team-secret bearer (G2) get a
#            FLAT 404, indistinguishable from a nonexistent route. This module registers
#            /god/roster + /god/logs as AUTHENTICATED routes (cp_server.register_route),
#            never register_public_route, and does NOT touch PUBLIC_ROUTES — so the god
#            aggregate can never resolve on the public surface. (The public-surface 404 is
#            enforced in cp_server; the guarantee HERE is: we never opt these routes into
#            the public seam.)
#   G3     — on the GATED control-plane service (IAM-authorized) each handler runs the §3
#            auth chokepoint (cp_server.authenticate, upstream) and THEN cp_approval.
#            _require_owner(identity): a validly SIGNED but NON-owner key is refused
#            (AuthError('not_owner') -> 401). Only the owner PKI + IAM passes.
#   G4     — even for the owner, the aggregate enumerates its partition set SERVER-SIDE
#            from the durable stores (the presence tree + the key registry + the §9 audit
#            log). It NEVER reads a caller-supplied body/query team_id — there is no wire
#            channel by which a forged partition selector can enter the enumerated set
#            (INV-1 holds inside /god/* too). `request` is accepted for signature symmetry
#            with every route handler and is DELIBERATELY not consulted for team scoping.
#
# READ-ONLY. God mode observes; it dispatches NOTHING, mints NOTHING, writes NOTHING. It
# resolves no action_type, holds no credential, and runs no handler — it folds durable
# state and returns it. The §2 control/data-plane line holds.
#
# DEPLOYED-SHAPE SAFE (the firestore-only read-path incident class). Every enumeration
# goes through the StateBackend's firestore-safe primitives — list_names / get_record /
# read_lines — and NEVER cp_state's path() (FirestoreBackend.path() RAISES by design).
# So the aggregate serves identically on the local backend and under
# HEIMDALL_STATE_BACKEND=firestore in the deployed container; a backend read error is
# tolerant ([] / skipped), never a crash.
#
# stdlib-only (json/os/sys) + the sibling cp_* substrate (cp_presence read fold, cp_auth
# registry, cp_audit §9 log, cp_approval owner gate, cp_server seam) — the SAME dependency
# shape every CP piece has, no third-party dep, self-hostable.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_approval  # REUSE _require_owner — the EXACT owner gate the §7 approval surface uses
                   # (identity.owner + a verified Identity, else AuthError('not_owner') -> 401).
                   # Single source of truth for owner authority (dashboard-login-design.md
                   # "God mode stays separate"): a login session (owner=False) fails it too (G3/L5).
import cp_audit    # the §9 activity log (dispatch / approval / override / job_state / auth_fail).
                   # read_records is a firestore-safe tolerant NDJSON scan — the cross-team
                   # activity source for /god/logs (the audit is a global log, so reading it IS
                   # the cross-tenant aggregate; owner-gated + server-enumerated, never a wire team_id).
import cp_auth     # the HAID->pubkey key registry (enroll/join membership) + default_team_id +
                   # the registry rel (_KEYS_REL). Read via the StateBackend record accessor.
import cp_presence  # the presence read fold (roster) + the member view (_team_view) + the presence
                    # store rel (_PRESENCE_REL). The god roster enumerates the presence tree
                    # SERVER-SIDE and folds each (project, team) partition through roster().
import cp_server   # REUSE register_route + Response — the §10 seam. God routes are AUTHENTICATED
                   # (register_route), NEVER register_public_route: they must not resolve on the
                   # public surface (G1/G2).
import cp_state    # the pluggable persistence backend — every enumeration uses the firestore-safe
                   # list_names / get_record primitives (never path()), so the aggregate serves
                   # identically on local + firestore (deployed-shape safe).


# ── the cross-team PRESENCE aggregate (GET /god/roster) ────────────────────────────────


def aggregate_roster(*, home=None):
    """The cross-tenant presence aggregate: EVERY (project, team_id) partition's ONLINE
    roster, folded SERVER-SIDE from the durable presence tree. Returns a list of
    {project, team_id, online:[member-view, ...]} — one entry per enumerated partition.

    THE SERVER-SIDE ENUMERATION (G4 / INV-1 inside the owner aggregate). The presence
    store is keyed presence/<project>/<team_id>/<haid>.json (cp_presence). We enumerate:
      1. list_names(presence/)            -> the project partitions,
      2. list_names(presence/<project>/)  -> that project's team partitions,
    and fold each with cp_presence.roster(project, team_id) — the SAME read authority the
    team-scoped /roster / /roster-team use, so retirement tombstones + the online TTL are
    honored identically. There is NO caller-supplied team_id anywhere in this path — the
    partition set comes ONLY from the store. A forged wire team_id can never enter the
    enumerated set (that is exactly the G4 gate; the `god-accepts-body-team-id` mutant is
    the falsifier — a handler that read req.body.team_id here would open G4).

    DEPLOYED-SHAPE SAFE: list_names + get_record (inside roster) are served by every
    backend, NEVER backend.path() — the firestore-only read-path incident class is avoided.
    Tolerant: an absent/garbled presence tree yields []."""
    backend = cp_state.get_backend(home=home)
    teams = []
    for project in backend.list_names(cp_presence._PRESENCE_REL):
        proj_rel = os.path.join(cp_presence._PRESENCE_REL, project)
        for team_id in backend.list_names(proj_rel):
            views = cp_presence.roster(project, team_id, home=home)
            online = [cp_presence._team_view(v) for v in views]
            teams.append({"project": project, "team_id": team_id, "online": online})
    return teams


# ── the cross-team ACTIVITY aggregate (GET /god/logs) ──────────────────────────────────


def _member_view(haid, entry):
    """Project ONE key-registry binding to a non-secret join view: {haid, project, owner,
    enrolled_at}. NO key material — the registry stores only the public key + non-secret
    metadata, and we surface neither the pubkey nor any secret (there is none at rest)."""
    return {
        "haid": haid,
        "project": entry.get("project"),
        "owner": bool(entry.get("owner")),
        "enrolled_at": entry.get("enrolled_at"),
    }


def _enrollments(backend):
    """The cross-team ENROLL/JOIN aggregate, enumerated SERVER-SIDE from the HAID->pubkey
    key registry (cp_auth) grouped by each binding's RESOLVED team_id (its team_id field,
    else default_team_id — the SAME resolution registered_team uses). Returns a sorted list
    of {team_id, members:[join-view], count}. A binding with no resolvable team groups under
    the '__no_team__' bucket (honest, never dropped). Firestore-safe (get_record on the
    registry rel, never path()); tolerant of an absent/garbled registry ([])."""
    reg = backend.get_record(cp_auth._KEYS_REL)
    if not isinstance(reg, dict) or not isinstance(reg.get("keys"), dict):
        return []
    default = cp_auth.default_team_id()
    by_team = {}
    for haid, entry in reg["keys"].items():
        if not isinstance(entry, dict):
            continue
        tid = entry.get("team_id") or default or "__no_team__"
        by_team.setdefault(tid, []).append(_member_view(haid, entry))
    return [
        {"team_id": tid,
         "members": sorted(members, key=lambda m: str(m.get("haid") or "")),
         "count": len(members)}
        for tid, members in sorted(by_team.items())
    ]


# The §9 audit events that constitute the god-logs activity scope. Gate VERDICTS are the
# approval/override rows (a gate PROVEN/BLOCKED per team); RUN outcomes are the dispatch /
# refusal / job-state rows (a job/fix run's fate); auth_fail is a cross-team security signal
# an owner watches. All are already secret-scrubbed at write time (§9 params_shape +
# telemetry._scrub), so surfacing them to the owner leaks no value.
_VERDICT_EVENTS = ("approval", "override")
_RUN_EVENTS = ("dispatch", "dispatch_refused", "job_state")
_SECURITY_EVENTS = ("auth_fail",)


def _log_row(record):
    """Project ONE §9 audit record to the god-logs view. The audit is already secret-free
    by construction (values are reduced to params_shape; detail is scrubbed) — we surface
    the closed set of non-secret fields, never a raw value."""
    return {
        "ts": record.get("ts"),
        "event": record.get("event"),
        "actor_haid": record.get("actor_haid"),
        "action_type": record.get("action_type"),
        "action_id": record.get("action_id"),
        "job_id": record.get("job_id"),
        "decision": record.get("decision"),
        "outcome": record.get("outcome"),
        "detail": record.get("detail"),
    }


def aggregate_logs(*, home=None):
    """The cross-tenant ACTIVITY aggregate (read-only from CP state). Its scope is ALL of:
      • enroll/join events — SERVER-ENUMERATED from the key registry (per-team membership);
      • gate verdicts      — the §9 approval/override rows (PROVEN/BLOCKED, per team);
      • job/fix run outcomes — the §9 dispatch/refusal/job_state rows (a run's fate);
      • security signals    — the §9 auth_fail rows (a cross-team auth-failure watch).
    Returns {enrollments, verdicts, runs, security}. The audit log is a GLOBAL §9 record,
    so reading it IS the cross-team aggregate — owner-gated at the route, server-enumerated
    here, and it NEVER consults a caller-supplied team_id (G4 / INV-1). DEPLOYED-SHAPE SAFE:
    read_records + get_record only (firestore-safe), never backend.path()."""
    backend = cp_state.get_backend(home=home)
    records = cp_audit.read_records(home=home)
    return {
        "enrollments": _enrollments(backend),
        "verdicts": [_log_row(r) for r in records if r.get("event") in _VERDICT_EVENTS],
        "runs": [_log_row(r) for r in records if r.get("event") in _RUN_EVENTS],
        "security": [_log_row(r) for r in records if r.get("event") in _SECURITY_EVENTS],
    }


# ── the route handlers (owner-gated; §3-verified identity in) ──────────────────────────


def roster_route(identity, request, *, home=None):
    """GET /god/roster — the OWNER-ONLY cross-tenant presence aggregate. The §3 auth
    chokepoint ran upstream (cp_server.authenticate), so `identity` is a VERIFIED
    Identity; here the OWNER gate (cp_approval._require_owner) refuses a validly signed
    NON-owner key with 401 not_owner (G3) — only the owner PKI + IAM passes. On the PUBLIC
    surface this route is a flat 404 (G1/G2 — it is never in PUBLIC_ROUTES; enforced in
    cp_server's routing boundary before this ever runs).

    `request` is accepted for the (identity, request) route signature but is DELIBERATELY
    NOT consulted for team scoping: the partition set is enumerated SERVER-SIDE from the
    presence tree (aggregate_roster), never a caller-supplied team_id (G4 / INV-1)."""
    try:
        cp_approval._require_owner(identity)
    except cp_auth.AuthError as err:
        return cp_server.Response(401, {"error": err.reason})
    return cp_server.Response(200, {"teams": aggregate_roster(home=home)})


def logs_route(identity, request, *, home=None):
    """GET /god/logs — the OWNER-ONLY cross-tenant activity aggregate (enroll/join + gate
    verdicts + job/fix run outcomes + auth-failure signals). Same G1-G4 discipline as
    /god/roster: 404 on the public surface, owner-gated on the gated service, and the
    partition set is enumerated SERVER-SIDE (the registry + the §9 audit log) — a
    caller-supplied body/query team_id is never honored. Read-only; runs nothing."""
    try:
        cp_approval._require_owner(identity)
    except cp_auth.AuthError as err:
        return cp_server.Response(401, {"error": err.reason})
    return cp_server.Response(200, aggregate_logs(home=home))


def register(*, home=None):
    """Wire GET /god/roster + GET /god/logs into cp_server's AUTHENTICATED registration
    seam (§10) — NEVER the pre-auth public seam and NEVER cp_publicsurface.PUBLIC_ROUTES,
    so on the public surface both routes are a flat 404 (G1/G2). The handlers close over
    the runtime `home` so a self-host deployment / a test can pin its store root. Returns
    the registered (method, path) keys. Idempotent — re-registering replaces the routes."""
    keys = []
    keys.append(cp_server.register_route(
        "GET", "/god/roster",
        lambda identity, request: roster_route(identity, request, home=home)))
    keys.append(cp_server.register_route(
        "GET", "/god/logs",
        lambda identity, request: logs_route(identity, request, home=home)))
    return keys
