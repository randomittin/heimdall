#!/usr/bin/env python3
# cp_ghverify.py — SERVER-SIDE GitHub identity + repo-access verification for zero-touch
# auto-team-formation (design: docs/analysis/zero-touch-team-formation.md §3c, INV-AUTOTEAM).
#
# WHY THIS EXISTS (the trust inversion). Auto-team moves the membership proof from "holds the
# team secret" to "has GitHub access to the repo" — but ONLY if the server proves BOTH facts
# itself. The client claims {gh_user, repo}; the server trusts NEITHER and re-derives both from
# GitHub. This module is the two fail-closed strata that do that re-derivation. It is a Wave-1
# PRIMITIVE: cp_autoteam (Wave 2, the POST /team/auto handler) composes it; this module owns NO
# route and writes NO binding.
#
# THE TWO STRATA (both server-side, both fail-closed — INV-AUTOTEAM):
#
#   * STRATUM A — verify_gh_identity(gh_token, claimed_login) -> verified_login (AT2).
#     The client forwards a SINGLE-USE GitHub token; the CP calls GitHub GET /user with it and
#     reads the REAL login. The claimed_login must equal the real login or we REFUSE — the
#     server NEVER trusts a client's username claim (a forger cannot name a victim's login).
#     The token is TRANSIT-ONLY: used for the one GET /user call, never stored, never logged,
#     never placed in an exception message (reuse the cred-forward discipline,
#     cp_credforward.py:28). We drop our reference to it the instant the call returns.
#
#   * STRATUM B — check_repo_access(gh_user, repo_slug, is_public) -> level (AT1/AT4).
#     The CP mints the App INSTALLATION token for the repo's installation (cp_ghinstall — the
#     App private key is already the single global secret; no new secret), calls
#     GET /repos/{owner}/{repo}/collaborators/{gh_user}/permission, maps GitHub's answer to a
#     level (admin/write/read/none), then applies the THRESHOLD policy. The public/private flag
#     is SERVER-DETERMINED from the repo metadata (GET /repos/{owner}/{repo} .private via the
#     App token) — NEVER a client claim. Below the threshold OR no access => REFUSE.
#
#   * can_initiate(gh_user, repo_slug) -> bool (AT5). True iff gh_user holds admin/push on the
#     repo — only an admin/push holder may auto-INITIATE a new team. Raises (fail-closed) if the
#     permission cannot be determined, so an indeterminate check never initiates.
#
# THE THRESHOLD POLICY (RJ's default, CENTRALIZED — change it in ONE place: the _*_MIN_LEVEL
# constants below). PRIVATE repo -> >= read (any collaborator: team == collaborators). PUBLIC
# repo -> >= write/push (the committing team, NOT drive-by readers — otherwise the whole world
# could join a public repo's presence wall, AT4). INITIATE -> >= write/push (AT5).
#
# HERMETIC-TEST SEAM. GitHub HTTP lives behind ONE chokepoint, _http_get_json — tests replace
# that symbol (and use a fake gh-app-token minter via cp_ghinstall) to run with ZERO network and
# ZERO real GitHub creds. HEIMDALL_GH_API_BASE overrides the API root (mirrors
# bin/heimdall-gh-app-token's own seam) for a GHE / self-host / local-fake base.
#
# stdlib-only (json/os/re/urllib) + the repo's own cp_auth (AuthError), cp_ghinstall (install
# token minting), cp_allowlist (the owner/name slug whitelist) — no new dependency.

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from cp_auth import AuthError  # the SINGLE failure type (server maps -> 401/403 + audit row).
import cp_ghinstall            # the per-team App installation map + scoped install-token minter.
import cp_allowlist            # REUSE REPO_SLUG_RE — the one owner/name whitelist (no metachar).

# ── the GitHub REST seam ────────────────────────────────────────────────────────
#
# The API root. HEIMDALL_GH_API_BASE overrides it (GHE / self-host / a hermetic local fake),
# mirroring bin/heimdall-gh-app-token:154 so the whole system reads ONE env for the base.
_GH_API_BASE_ENV = "HEIMDALL_GH_API_BASE"
_DEFAULT_API_BASE = "https://api.github.com"

# Bounded network timeout (seconds) — a hung GitHub call fails loud, never hangs the handler.
_TIMEOUT = 15

# The owner/name slug whitelist, reused VERBATIM from the allowlist spine (the same shape
# cp_ghinstall keys installations by) — an owner/name slug is the ONLY thing a repo can be, so
# no shell metachar / deep path / whitespace can ride the URL.
_REPO_SLUG_RX = re.compile(cp_allowlist.REPO_SLUG_RE)

# A conservative GitHub-login whitelist (alnum + hyphen, <=39 chars — GitHub's own rule). This
# is defense-in-depth: the login is path-quoted before it hits a URL, and validated here so a
# malformed/injected login can never form a permission path in the first place.
_GH_LOGIN_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}")

# ── THE THRESHOLD POLICY — the ONE place to change the public-repo guard ─────────
#
# GitHub's permission ladder, ordered. GET .../collaborators/{user}/permission returns exactly
# one of these in its "permission" field (custom org roles are collapsed by GitHub to one of
# them); a non-collaborator is a 404 which we read as "none".
_LEVELS = {"none": 0, "read": 1, "write": 2, "admin": 3}

# RJ's default policy (design §5, the "recommended default" row AT4). Change THESE to swap the
# policy — every threshold decision in this module routes through them, so the guard is one edit,
# not a scatter of literals:
#   * PRIVATE repo -> a collaborator (>= read) suffices: team == the repo's collaborators.
#   * PUBLIC  repo -> a committer (>= write/push) is required: the world has read on a public
#     repo, so a read-only auto-join would put everyone on the presence wall (AT4). Only the
#     actual pushing team joins.
#   * INITIATE (create a NEW team for a repo) -> admin/push only (AT5): you may only stand up a
#     team for a repo you control.
_PRIVATE_MIN_LEVEL = "read"
_PUBLIC_MIN_LEVEL = "write"
_INITIATE_MIN_LEVEL = "write"


def required_level(is_public):
    """The MINIMUM permission level auto-JOIN requires for a repo, per the centralized policy:
    public repos require _PUBLIC_MIN_LEVEL (write/push), private repos _PRIVATE_MIN_LEVEL
    (read). Pure — the single function the threshold is read through, so the public-repo guard
    is swappable in one place (the _*_MIN_LEVEL constants)."""
    return _PUBLIC_MIN_LEVEL if is_public else _PRIVATE_MIN_LEVEL


def _meets(level, minimum):
    """True iff `level` is at or above `minimum` on the GitHub permission ladder. Fail-closed on
    an unknown level (reads as 0/none) or an unknown minimum (reads as unreachable) — a garbled
    value can never satisfy a threshold."""
    return _LEVELS.get(level, 0) >= _LEVELS.get(minimum, max(_LEVELS.values()) + 1)


# ── input guards ────────────────────────────────────────────────────────────────


def _valid_slug(repo_slug):
    """True iff repo_slug is a clean owner/name slug (the reused allowlist whitelist)."""
    return isinstance(repo_slug, str) and bool(_REPO_SLUG_RX.fullmatch(repo_slug))


def _require_login(gh_user):
    """Return the trimmed login iff it is a well-formed GitHub username; else raise
    AuthError('bad_input'). Guards the permission-path construction against an injected login."""
    login = gh_user.strip() if isinstance(gh_user, str) else ""
    if not login or not _GH_LOGIN_RX.fullmatch(login):
        raise AuthError("bad_input", "invalid GitHub login")
    return login


def _require_slug(repo_slug):
    """Return repo_slug iff it is a clean owner/name slug; else raise AuthError('bad_input')."""
    if not _valid_slug(repo_slug):
        raise AuthError("bad_input", "repo must be an owner/name slug")
    return repo_slug


# ── the ONE GitHub HTTP chokepoint (the hermetic-test seam) ──────────────────────


def _gh_api_base():
    """The GitHub API root: HEIMDALL_GH_API_BASE (stripped of a trailing slash) when set, else
    https://api.github.com. Read fresh so a deploy / test can point at a GHE or local base."""
    raw = os.environ.get(_GH_API_BASE_ENV)
    if raw and raw.strip():
        return raw.strip().rstrip("/")
    return _DEFAULT_API_BASE


def _http_get_json(url, token, *, timeout=_TIMEOUT):
    """THE single GitHub network chokepoint (tests replace this symbol to run hermetically).
    GET `url` with a bearer `token`, returning (status_code, parsed_json_dict). A GitHub HTTP
    error (401/403/404/...) is returned as (code, body) — a real answer the caller interprets
    (a 404 on a permission check means "not a collaborator"). A TRANSPORT failure (DNS, timeout,
    connection refused) raises AuthError('gh_unreachable') carrying ONLY the exception type name.

    The token rides the Authorization HEADER (never the URL, never a log line, never an error
    message) — transit-only, exactly as the forwarded cred is handled in cp_credforward."""
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", "Bearer %s" % token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "heimdall-cp-ghverify")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return exc.code, {}
    except Exception as exc:  # noqa: BLE001 — transport failure -> fail loud, token-free note.
        raise AuthError("gh_unreachable", type(exc).__name__) from exc


# ── STRATUM A — server-side caller<->gh_user identity (AT2) ──────────────────────


def verify_gh_identity(gh_token, claimed_login):
    """STRATUM A (AT2). Prove the caller controls `claimed_login` by spending a SINGLE-USE,
    client-forwarded GitHub `gh_token` on GitHub's OWN GET /user and reading the REAL login. The
    server trusts the client's username claim for NOTHING: the real login (case-insensitive) must
    equal claimed_login or we REFUSE. Returns the GitHub-canonical login on a match.

    Raises AuthError:
      * bad_input             — a missing/blank token or claimed_login.
      * gh_identity_unverified — GET /user did not return a 200 with a login (bad/expired token).
      * gh_identity_mismatch   — the real login != claimed_login (a forged identity claim, AT2).
      * gh_unreachable         — GitHub was not reachable (transport failure).

    TRANSIT-ONLY TOKEN: the token is used for exactly this one call, is NEVER stored, NEVER
    logged, and NEVER appears in any raised message (the mismatch/unverified notes name neither
    the token nor a login). We drop our local reference the instant GET /user returns."""
    if not isinstance(gh_token, str) or not gh_token.strip():
        raise AuthError("bad_input", "a GitHub token is required")
    if not isinstance(claimed_login, str) or not claimed_login.strip():
        raise AuthError("bad_input", "a claimed login is required")
    url = "%s/user" % _gh_api_base()
    try:
        status, data = _http_get_json(url, gh_token.strip())
    finally:
        # Transit-only: drop the reference immediately, whether the call succeeded or raised.
        gh_token = None
    if status != 200 or not isinstance(data, dict):
        raise AuthError("gh_identity_unverified", "GET /user did not return 200 (status %s)"
                        % status)
    real = data.get("login")
    if not isinstance(real, str) or not real.strip():
        raise AuthError("gh_identity_unverified", "GitHub returned no login for the token")
    if real.strip().lower() != claimed_login.strip().lower():
        # AT2: the token's true owner is not the claimed user -> refuse. The message names
        # NEITHER value (no username enumeration, no leaked claim).
        raise AuthError("gh_identity_mismatch",
                        "claimed login does not match the GitHub token owner")
    return real.strip()


# ── the repo's installation token (the "repo-scoped variant", server-side) ───────


def _team_for_repo(repo_slug, *, home=None):
    """The team_id whose App installation COVERS `repo_slug`, or None. Reverse of the
    cp_ghinstall map (team_id -> repos[]): the auto-team flow knows a repo and must find the
    installation that can speak for it. Firestore-safe (known_team_ids + covered_repos only)."""
    for tid in cp_ghinstall.known_team_ids(home=home):
        if repo_slug in cp_ghinstall.covered_repos(tid, home=home):
            return tid
    return None


def _mint_installation_token(repo_slug, *, home=None):
    """Mint the SHORT-LIVED App installation token scoped to `repo_slug` (the repo-scoped
    variant of cp_ghinstall.mint_token_for_team): find the installation covering the repo, then
    mint through the existing gate (which re-checks coverage + scopes the token to the repo name).
    Returns the token string ONLY — it is transit-only and never logged/stored here.

    Raises AuthError('no_installation') when no installation covers the repo or the mint fails —
    a repo with no App installation cannot be permission-checked, which is a fail-closed refusal."""
    _require_slug(repo_slug)
    team = _team_for_repo(repo_slug, home=home)
    if not team:
        raise AuthError("no_installation", "no GitHub App installation covers this repo")
    try:
        return cp_ghinstall.mint_token_for_team(team, repo_slug, home=home)
    except cp_ghinstall.GhInstallError as exc:
        # Surface only the machine reason code (token-free, key-free) — never a secret.
        raise AuthError("no_installation",
                        "could not mint an installation token (%s)" % exc.reason) from exc


def _repo_is_public(repo_slug, token):
    """SERVER-DETERMINED public/private flag: GET /repos/{owner}/{repo} with the App installation
    token and read `.private`. Returns True iff the repo is public. Raises
    AuthError('gh_unreachable') if the metadata cannot be read (fail-closed — an indeterminate
    visibility must not silently fall to the looser public policy). NEVER a client claim."""
    url = "%s/repos/%s" % (_gh_api_base(), repo_slug)
    status, data = _http_get_json(url, token)
    if status != 200 or not isinstance(data, dict) or "private" not in data:
        raise AuthError("gh_unreachable",
                        "could not read repo metadata (status %s)" % status)
    return not bool(data.get("private"))


def _repo_permission_level(gh_user, repo_slug, token):
    """Map GitHub's answer for {gh_user, repo_slug} to a level (admin|write|read|none) using the
    App installation `token`. GET .../collaborators/{gh_user}/permission: a 200 carries the
    "permission" field; a 404 means the user is NOT a collaborator at all -> "none". Any other
    non-200, or an unrecognized permission value, fails closed to "none" / gh_unreachable so an
    ambiguous answer never grants access."""
    url = "%s/repos/%s/collaborators/%s/permission" % (
        _gh_api_base(), repo_slug, urllib.parse.quote(gh_user))
    status, data = _http_get_json(url, token)
    if status == 404:
        return "none"  # not a collaborator on this repo -> no access.
    if status != 200 or not isinstance(data, dict):
        raise AuthError("gh_unreachable",
                        "permission check did not return 200 (status %s)" % status)
    perm = data.get("permission")
    if perm not in _LEVELS:
        # GitHub collapses custom roles to one of the four; anything else -> fail closed.
        return "none"
    return perm


def repo_permission_level(gh_user, repo_slug, *, home=None):
    """The GitHub permission level (admin|write|read|none) `gh_user` holds on `repo_slug`,
    server-authoritative (via the App installation token). Raises AuthError on a bad input, no
    installation, or an unreachable GitHub. This is the raw lookup; check_repo_access applies the
    threshold policy on top of it, and can_initiate reads it for the initiate gate."""
    _require_login(gh_user)
    _require_slug(repo_slug)
    token = _mint_installation_token(repo_slug, home=home)
    try:
        return _repo_permission_level(gh_user, repo_slug, token)
    finally:
        token = None  # transit-only.


# ── STRATUM B — server-side gh_user<->repo permission + threshold (AT1/AT4) ───────


def check_repo_access(gh_user, repo_slug, is_public=None, *, home=None):
    """STRATUM B (AT1/AT4). Decide whether `gh_user` may auto-JOIN the team for `repo_slug`,
    server-authoritatively: mint the repo's App installation token, read gh_user's permission
    level, and apply the centralized THRESHOLD policy (required_level). Returns the GRANTED level
    string (admin|write|read) on ALLOW; raises AuthError('repo_access_denied') on DENY —
    fail-closed, so cp_autoteam refuses the join and writes no binding.

      * PRIVATE repo -> a collaborator (>= read) is admitted (AT1: a non-collaborator is denied).
      * PUBLIC  repo -> a committer (>= write/push) is required (AT4: a read-only drive-by is
        denied — the world cannot join a public repo's presence wall).

    `is_public` is SERVER-DETERMINED: pass None (the auto-team caller ALWAYS does) and this reads
    it from the repo metadata via the App token — NEVER a client claim. An explicit bool is
    accepted only for a caller that already determined it server-side (or a test); it must never
    carry a value the client supplied.

    Raises AuthError: bad_input | no_installation | gh_unreachable | repo_access_denied."""
    login = _require_login(gh_user)
    _require_slug(repo_slug)
    token = _mint_installation_token(repo_slug, home=home)  # transit-only.
    try:
        public = _repo_is_public(repo_slug, token) if is_public is None else bool(is_public)
        level = _repo_permission_level(login, repo_slug, token)
    finally:
        token = None  # drop the transit token the instant the two reads are done.
    minimum = required_level(public)
    if not _meets(level, minimum):
        # DENY. The note names the repo + levels (non-secret) for the audit row — NEVER a token.
        raise AuthError(
            "repo_access_denied",
            "%s has '%s' on %s; a %s repo requires >= '%s'" % (
                login, level, repo_slug, "public" if public else "private", minimum))
    return level


# ── the INITIATE gate (AT5) ──────────────────────────────────────────────────────


def can_initiate(gh_user, repo_slug, *, home=None):
    """AT5. True iff `gh_user` may auto-INITIATE a NEW team for `repo_slug` — i.e. holds
    admin/push (>= _INITIATE_MIN_LEVEL). You may only stand up a team for a repo you control.
    A merely-read collaborator (or a non-collaborator) returns False.

    Fail-closed: this RAISES AuthError (bad_input | no_installation | gh_unreachable) when the
    permission cannot be determined — an indeterminate check must never green-light an initiate.
    A determinate below-threshold answer returns False (a normal 'not authorized'), so the caller
    distinguishes 'not allowed' (False) from 'could not verify' (AuthError)."""
    level = repo_permission_level(gh_user, repo_slug, home=home)
    return _meets(level, _INITIATE_MIN_LEVEL)
