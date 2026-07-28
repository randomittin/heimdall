#!/usr/bin/env python3
# cp_autoteam.py — the POST /team/auto handler: ZERO-TOUCH auto-initiate + auto-join
# (design: docs/analysis/zero-touch-team-formation.md §3; oracle: INV-AUTOTEAM rows AT1-AT5
# in evals/oracles/rr-multitenant-isolation). A Wave-2 COMPOSITION — it owns NO new isolation
# logic; it WIRES the two landed Wave-1 primitives (cp_repoteam + cp_ghverify) into one
# pre-auth route so a dev joins/creates a team by PROVING GitHub repo access, never by
# presenting a bearer secret.
#
# WHY THIS EXISTS (the dance this kills). Today growing a team means `hmd invite` pasting a
# high-entropy team_secret out-of-band, then `hmd join` on the other side (design §1). This
# route replaces that with a server-verified GitHub-access proof: a teammate's first run on a
# repo AUTO-JOINS the repo's team (if they hold repo access), and the first run on a NOT-YET-
# bound repo AUTO-INITIATES the team (if they hold admin/push). No secret ever transits or
# lands in git — the operative team_id is ALWAYS server-resolved from the repo binding (INV-1).
#
# THE TRUST MODEL (what authorizes a bind — the AT1-AT5 basis, all SERVER-SIDE):
#   * AT2 (identity FIRST) — verify_gh_identity(gh_proof, gh_user) re-derives the caller's TRUE
#     login from GitHub's own GET /user with the forwarded single-use token. A forged username
#     claim (the token's real owner != the claimed gh_user) is a 401 BEFORE anything downstream.
#     The VERIFIED login (not the claimed one) is what every downstream check uses.
#   * AT3 / INV-1 (server-derived team) — the team is resolved from get_team_for_repo(repo),
#     the SERVER-SIDE repo->team binding. A `team_id` in the request body is NEVER read; the
#     handler does not even look at it. So a caller cannot steer the bind at a partition they
#     were never granted.
#   * AT1 / AT4 (auto-join gate) — for a BOUND repo, check_repo_access(verified_login, repo)
#     applies the threshold policy server-side (private >= read, public >= write; the visibility
#     is read from GitHub, never a client claim). A non-collaborator (AT1) or a public read-only
#     drive-by (AT4) raises repo_access_denied -> 403, and NO binding is written.
#   * AT5 (auto-initiate gate) — for an UNBOUND repo, can_initiate(verified_login, repo) must be
#     True (admin/push only). A non-admin caller is a 403 and NO team is minted — auto-join never
#     invents a team, and auto-initiate is gated to a repo you control.
#
# THE HAID BINDING (enroll-then-autojoin order). The membership bind reuses cp_repoteam.
# bind_haid_to_team, which re-registers the HAID's EXISTING key-registry binding (swapping only
# team_id) and FAIL-CLOSES when the HAID has no registered pubkey. So the caller MUST have
# enrolled first (POST /enroll binds haid->pubkey) — this route carries no pubkey and therefore
# cannot enroll. An unenrolled HAID gets a clear 403 "enroll_required": enroll, then re-call
# /team/auto. The `sig` field is accepted (reserved for the design's key-possession hardening
# follow-up, §3c) but is DELIBERATELY not the authorization basis in this wave — Strata A+B are,
# exactly as the design states; wiring it needs a canonical assertion seam that lives in
# cp_session (out of this wave's file scope), so it is not enforced here.
#
# THE SURFACE. Served PRE-AUTH via register_public_route (like /enroll — the caller may have no
# signable envelope, and the GitHub strata ARE the auth). (POST, /team/auto) is in
# cp_publicsurface.PUBLIC_ROUTES and carries its OWN abuse gate there (per-IP + a deployment-wide
# budget — a /team/auto flood is a GitHub-API + write cost). NO bearer secret is returned or
# accepted: the response carries the NON-SECRET team_id (a guessable partition handle, harmless
# under INV-1) + the mode + the repo slug. Every AuthError refusal writes an audit row.
#
# DATA ONLY, EXECUTES NOTHING. This handler resolves NO action_type, runs NO dispatch handler,
# and makes NO model call — it composes two primitives and writes one membership binding. The
# §2 control/data-plane line holds.
#
# THE INTERFACE the server BINDS to (stable; cp_boot imports, never edits cp_server):
#   auto_team(repo, gh_user, gh_proof, haid, *, home) -> (status, body)  — the testable core.
#   auto_team_route(request, *, home) -> cp_server.Response              — the pre-auth handler.
#   register(*, home=None)  — wire POST /team/auto into cp_server's PUBLIC (pre-auth) seam.
#
# stdlib-only (json/os/sys) + the sibling cp_* substrate (cp_repoteam, cp_ghverify, cp_audit,
# cp_server) — the SAME dependency shape every other CP piece has, no third-party dep.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_repoteam   # the SERVER-SIDE repo->team registry (get/mint/bind) — the AT3/AT5 keystone.
import cp_ghverify   # the two GitHub strata (verify_gh_identity / check_repo_access / can_initiate).
import cp_audit      # every refusal + every accepted bind writes an audit row (§9).
import cp_server     # REUSE register_public_route + Response — the pre-auth registration seam.

from cp_auth import AuthError  # the single failure type the gh strata raise (mapped to a status).


# The reason-code -> HTTP status map. A forged/unverifiable GitHub identity is 401 (AT2 — the
# caller failed the who-are-you proof). A denied repo-access / initiate is 403 (AT1/AT4/AT5 —
# authenticated-enough but not authorized). A malformed request (bad slug / missing field / bad
# input) is 422. A repo with no App installation is 403 (fail-closed — an unverifiable permission
# is a denial, not a server error). An unreachable GitHub is 503 (a transient upstream fault —
# retry). An unenrolled HAID is 403 with a clear enroll_required (enroll first). A bind write that
# fails despite an enrolled key is 500. The body is content-free beyond {ok, reason} on a refusal
# / {ok, team_id, mode, project} on success — never a secret, never the forwarded token.
_STATUS_BY_REASON = {
    "bad_repo": 422,
    "missing_field": 422,
    "bad_input": 422,
    "gh_identity_mismatch": 401,
    "gh_identity_unverified": 401,
    "repo_access_denied": 403,
    "initiate_denied": 403,
    "no_installation": 403,
    "gh_unreachable": 503,
    "enroll_required": 403,
    "bind_failed": 500,
}


def _refuse(haid, slug, reason, detail="", *, home=None):
    """Audit + shape a fail-closed refusal. Writes ONE audit_fail-shaped row (actor=haid,
    outcome=refused, the machine reason + a secret-free detail) and returns (status, body).
    NEVER echoes the forwarded gh token / any secret — `detail` carries only the primitive's
    own secret-free note (cp_ghverify guarantees its AuthError messages name no token)."""
    cp_audit.write(
        "team_auto", actor_haid=haid, outcome="refused",
        detail=("%s: %s" % (reason, detail)) if detail else reason, home=home)
    status = _STATUS_BY_REASON.get(reason, 400)
    return (status, {"ok": False, "reason": reason})


def auto_team(repo, gh_user, gh_proof, haid, *, home=None):
    """THE testable auto-team core (auto-initiate | auto-join). Composes the two Wave-1
    primitives into one server-verified membership decision and returns a (status, body) tuple.

    Args (from the public body — a wire `team_id` is IGNORED, never read as a parameter):
      repo     — a repo_slug or a git remote URL (canonicalized server-side, AT3 key).
      gh_user  — the caller's CLAIMED GitHub login (trusted for NOTHING; re-derived at AT2).
      gh_proof — a single-use forwarded GitHub token (transit-only; spent once on GET /user).
      haid     — the caller's Heimdall id; MUST be enrolled (has a registered pubkey) already.

    Flow (each step a hard, fail-closed gate — the AT rows in the module header):
      0. repo_slug the repo; unresolvable -> 422 bad_repo. Require gh_user/gh_proof/haid -> else
         422 missing_field.
      1. AT2 — verify_gh_identity(gh_proof, gh_user) -> verified_login (a forge -> 401). Every
         downstream check uses verified_login, NEVER the claimed gh_user.
      2. AT3/INV-1 — team = get_team_for_repo(slug): the team is ALWAYS server-derived from the
         repo binding. A body team_id would be ignored (it is never read).
      3a. BOUND (AUTO-JOIN) — check_repo_access(verified_login, slug, is_public=None) applies the
          threshold (private>=read / public>=write, server-determined visibility). Deny (AT1/AT4)
          -> 403 repo_access_denied, no binding. On pass -> bind_haid_to_team(haid, team).
      3b. UNBOUND (AUTO-INITIATE) — can_initiate(verified_login, slug) must be True (admin/push,
          AT5) else 403 initiate_denied. On pass -> team = mint_team_for_repo(slug) (CAS-safe:
          two concurrent initiates converge on ONE team) -> bind_haid_to_team(haid, team).
      4. bind_haid_to_team fail-closes (False) when the HAID is not enrolled -> 403 enroll_required
         (enroll first, then re-call). Success -> 200 {ok, team_id, mode, project}.

    The returned team_id is the NON-SECRET partition handle (safe to return under INV-1). NO
    bearer secret is ever returned or accepted."""
    # 0. Canonicalize the repo (the AT3 key) + require the identity material.
    slug = cp_repoteam.repo_slug(repo)
    if not slug:
        return _refuse(haid, None, "bad_repo", "not a resolvable owner/name repo slug", home=home)
    if not (isinstance(gh_user, str) and gh_user.strip()
            and isinstance(gh_proof, str) and gh_proof.strip()
            and isinstance(haid, str) and haid.strip()):
        return _refuse(haid, slug, "missing_field",
                       "gh_user, gh_proof and haid are all required", home=home)

    # 1. AT2 — IDENTITY FIRST. Re-derive the caller's TRUE login server-side; a forged claim or an
    #    unverifiable token refuses BEFORE any repo/permission work. verified_login is authoritative.
    try:
        verified_login = cp_ghverify.verify_gh_identity(gh_proof, gh_user)
    except AuthError as err:
        return _refuse(haid, slug, err.reason, err.detail, home=home)

    # 2. AT3 / INV-1 — resolve the team SERVER-SIDE from the repo binding. Bound -> join; else -> initiate.
    team = cp_repoteam.get_team_for_repo(slug, home=home)

    if team:
        # 3a. AUTO-JOIN (AT1/AT4). The JOIN gate: server-authoritative repo access at the threshold.
        try:
            cp_ghverify.check_repo_access(verified_login, slug, is_public=None, home=home)
        except AuthError as err:
            return _refuse(haid, slug, err.reason, err.detail, home=home)
        mode = "joined"
    else:
        # 3b. AUTO-INITIATE (AT5). The INITIATE gate: admin/push only. can_initiate RAISES on an
        #     indeterminate check (fail-closed) and returns False on a determinate below-threshold
        #     answer (a normal deny). Only True stands up a new team.
        try:
            if not cp_ghverify.can_initiate(verified_login, slug, home=home):
                return _refuse(haid, slug, "initiate_denied",
                               "auto-initiate requires admin/push on the repo", home=home)
        except AuthError as err:
            return _refuse(haid, slug, err.reason, err.detail, home=home)
        # Mint a SERVER-DERIVED team for the repo (CAS-safe: a concurrent initiate converges on the
        # winner, never a double-mint). The team_id is derived on the server from a fresh secret
        # that is discarded — no secret transits or lands in git.
        team = cp_repoteam.mint_team_for_repo(slug, home=home)
        mode = "initiated"

    # 4. Bind the HAID's membership to the SERVER-DERIVED team. Fail-closes when the HAID is not
    #    enrolled (no registered pubkey) -> the caller must enroll first (enroll-then-autojoin).
    if not cp_repoteam.bind_haid_to_team(haid, team, home=home):
        return _refuse(haid, slug, "enroll_required",
                       "the HAID must enroll (POST /enroll) before auto-join", home=home)

    cp_audit.write("team_auto", actor_haid=haid, outcome="ok",
                   detail="%s %s" % (mode, slug), home=home)
    # team_id is the NON-SECRET partition handle (INV-1) — safe to return. project is the repo slug
    # (the presence system's normalized repo id) — a non-secret convenience for the client.
    return (200, {"ok": True, "team_id": team, "mode": mode, "project": slug})


def _parse_body(request):
    """Extract the JSON body dict from a request. The wire body is a JSON object carrying
    {repo, gh_user, gh_proof, haid, sig?}. Tolerant — a malformed/empty/non-object body yields
    {} (the core then refuses as bad_repo/missing_field), never a crash. Recognizes NOTHING
    executable (no action_type/handler key is honored — DATA only). A `team_id` field, if
    present, is IGNORED here and never read by the core (INV-1)."""
    body = request.get("body") if isinstance(request, dict) else None
    if body is None:
        return {}
    if isinstance(body, (bytes, bytearray)):
        try:
            body = body.decode("utf-8")
        except (UnicodeDecodeError, AttributeError):
            return {}
    if isinstance(body, str):
        try:
            body = json.loads(body or "null")
        except (ValueError, TypeError):
            return {}
    return body if isinstance(body, dict) else {}


def auto_team_route(request, *, home=None):
    """POST /team/auto — the PRE-AUTH auto-initiate/auto-join handler (served BEFORE the §3
    chokepoint; the GitHub strata are the auth). `request` is the cp_server request dict; the
    body is JSON {repo, gh_user, gh_proof, haid, sig?}. Runs the gated auto_team() core and maps
    its (status, body) tuple to a Response. The body is ONLY {ok, team_id, mode, project} on
    success / {ok:false, reason} on refusal — never the forwarded token, never a bearer secret.
    DATA only — dispatches nothing."""
    payload = _parse_body(request)
    status, body = auto_team(
        payload.get("repo"),
        payload.get("gh_user"),
        payload.get("gh_proof"),
        payload.get("haid"),
        home=home,
    )
    return cp_server.Response(status, body)


def register(*, home=None):
    """Wire POST /team/auto into cp_server's PUBLIC (pre-auth) registration seam — served BEFORE
    the §3 auth chokepoint because the GitHub strata (not a signed envelope) are the auth. The
    handler closes over the runtime `home` so a self-host deployment / a test pins its store root.
    Returns the registered (method, path) keys. Idempotent — re-registering replaces the route.
    Mirrors cp_enroll's pre-auth registration; the abuse gate lives in cp_publicsurface."""
    keys = []
    keys.append(cp_server.register_public_route(
        "POST", "/team/auto",
        lambda request: auto_team_route(request, home=home)))
    return keys
