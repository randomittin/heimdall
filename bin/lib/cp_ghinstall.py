#!/usr/bin/env python3
# cp_ghinstall.py — the PER-TEAM GitHub App INSTALLATION map for public, multi-tenant
# Heimdall (design §2: "one App, many installations, mapped by team_id").
#
# WHY THIS EXISTS (the multi-tenant keystone). The single public "Heimdall Maintainer"
# GitHub App has ONE App-id + ONE private key (RJ holds it). Each USER installs that same
# App on THEIR OWN repo(s) → GitHub issues each user a DISTINCT installation_id. To open a
# PR on a user's repo the maintainer must mint a scoped installation token from
# bin/heimdall-gh-app-token — and it MUST use THAT user's installation_id, never another's.
# This module is the durable, team-partitioned map
#     team_id -> {installation_id, repos[]}
# and the ONE gate that turns a caller's team_id into a scoped PR token for THEIR repo only.
#
# THE ISOLATION INVARIANTS (enforced here, tested in test/heimdall-cp-ghinstall.test.sh):
#   * KEYED-BY-CALLER. Every record is stored/read at the store-relative key
#     "gh-install/<team_id>.json" through the StateBackend (cp_state). A read for team A
#     addresses EXACTLY the team-A partition — there is NO path that returns team B's
#     installation to team A. team_id is the caller's verified partition handle
#     (cp_auth.registered_team from the enroll binding), NEVER a request-body field.
#   * REPO<->TEAM AUTHZ (the IDOR-via-repo-slug defeat). mint_token_for_team refuses to mint
#     a token for a `repo` the caller-team's installation does not cover. Without this a
#     caller could name another tenant's repo slug and ride their own installation to it;
#     the gate makes that a hard fail-closed refusal BEFORE any token is minted.
#   * TOKEN DISCIPLINE. The minted installation token is returned to the caller for env-only
#     injection into that team's job. It is NEVER logged, NEVER an argv element (the
#     installation_id rides the child's ENV, exactly as bin/heimdall-gh-app-token requires),
#     and NEVER placed in an exception message. A mint failure carries only the child's
#     (key-free, token-free) stderr.
#   * FAIL-CLOSED. No installation, an off-slug repo, an uncovered repo, or a minter failure
#     → a raised GhInstallError, never a silently-issued or wrong-tenant token.
#
# NON-SECRET STATE (design §2). installation_id + repo slugs are NOT sensitive — the App
# PRIVATE KEY stays the single global secret (Secret Manager / the 0600 store, read by the
# minter from its own env). So this map rides the same StateBackend seam the key registry
# uses (Firestore-durable in cloud, byte-identical local NDJSON/JSON in dev), NOT Secret
# Manager. It mirrors how cp_auth stamps team_id/project on a binding.
#
# stdlib-only (os/subprocess) + the repo's own cp_state / cp_allowlist substrate — no new dep.

from __future__ import annotations

import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state       # the pluggable, team-partitioned persistence backend (Wave 1).
import cp_allowlist   # REUSE REPO_SLUG_RE (cp_allowlist.py:163) — the single source of the
                      # owner/name whitelist that excludes every shell metachar + whitespace.

# The store-relative dir every team's install record lives under, RELATIVE to
# ${HEIMDALL_HOME}/control-plane/ (the StateBackend rel namespace). One keyed JSON record
# per team: "gh-install/<team_id>.json". The backend owns the home root + the atomic
# tmp+os.replace / indent=2 byte shape (byte-identical local, Firestore-durable in cloud).
_INSTALL_DIR = "gh-install"

# The record schema version (mirrors the key registry's "1.0.0" stamp).
_SCHEMA_VERSION = "1.0.0"

# The repo-slug whitelist, reused verbatim from the allowlist spine so an owner/name slug is
# the ONLY shape a covered repo can take (no deep path, no shell metachar, no whitespace).
_REPO_SLUG_RX = re.compile(cp_allowlist.REPO_SLUG_RE)

# A conservative team_id whitelist for use as a store-path segment. team_id is normally the
# 32-hex derive_team_id() handle (cp_auth), but we validate defensively so a caller-supplied
# id can NEVER traverse the store namespace ("/" and ".." are excluded by construction — the
# first char must be alnum and the set carries no slash).
_TEAM_ID_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")

# The minter binary: bin/heimdall-gh-app-token (sibling of this lib dir's parent). A test /
# GHE seam mirrors the tool's own HEIMDALL_GH_API_BASE seam — HEIMDALL_GH_APP_TOKEN_BIN
# overrides the path so a hermetic test can point at a fake minter without real GitHub creds.
_MINTER_ENV = "HEIMDALL_GH_APP_TOKEN_BIN"


class GhInstallError(Exception):
    """Raised for every fail-closed refusal in this module. `reason` is a short machine
    code (bad_team_id | bad_installation_id | bad_repo | no_repos | no_installation |
    repo_not_covered | mint_failed | minter_missing | write_failed); `detail` is a short,
    SECRET-FREE and TOKEN-FREE note — a minted token is NEVER placed in an exception
    message."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


def _backend(home=None):
    """The StateBackend for the install map (HEIMDALL_STATE_BACKEND, default local). `home`
    pins the store root exactly as every cp_* accessor's `home=` arg does."""
    return cp_state.get_backend(home=home)


def _rel(team_id):
    """The store-relative record key for a team — "gh-install/<team_id>.json". team_id is
    validated as a safe path segment first (fail-closed on anything that could traverse)."""
    tid = _validate_team_id(team_id)
    return os.path.join(_INSTALL_DIR, "%s.json" % tid)


def _validate_team_id(team_id):
    """Return the team_id iff it is a safe, non-empty store-path segment; else raise. This
    is the partition-key guard: a team_id with a slash / "../" / bad shape can never address
    another team's record or escape the store namespace."""
    if not isinstance(team_id, str) or not _TEAM_ID_RX.fullmatch(team_id):
        raise GhInstallError("bad_team_id", "team_id must be a safe non-empty id")
    return team_id


def _coerce_installation_id(installation_id):
    """Validate installation_id is a positive INTEGER (design §2: an int GitHub issues per
    install). Accepts an int or an all-digits str (the paste path in `rr setup`); rejects
    bool, floats, negatives, zero, and any non-digit string — fail-closed. Returns the int."""
    if isinstance(installation_id, bool):
        # bool is an int subclass in Python; a True/False installation id is nonsense.
        raise GhInstallError("bad_installation_id", "installation_id must be an integer")
    if isinstance(installation_id, int):
        value = installation_id
    elif isinstance(installation_id, str) and installation_id.strip().isdigit():
        value = int(installation_id.strip())
    else:
        raise GhInstallError("bad_installation_id", "installation_id must be an integer")
    if value <= 0:
        raise GhInstallError("bad_installation_id", "installation_id must be positive")
    return value


def _validate_repos(repos):
    """Validate + normalize the covered repo(s) into a SORTED, de-duplicated list of
    owner/name slugs. Accepts a single slug str or an iterable of slug strs. EVERY entry must
    fullmatch REPO_SLUG_RE (the shell-metachar-free owner/name whitelist). An empty set is a
    fail-closed refusal — an installation with no covered repo can authorize nothing."""
    if isinstance(repos, str):
        items = [repos]
    else:
        try:
            items = list(repos)
        except TypeError:
            raise GhInstallError("bad_repo", "repos must be a slug or a list of slugs")
    clean = []
    for r in items:
        if not isinstance(r, str) or not _REPO_SLUG_RX.fullmatch(r):
            raise GhInstallError("bad_repo", "each repo must be an owner/name slug")
        clean.append(r)
    if not clean:
        raise GhInstallError("no_repos", "at least one covered repo is required")
    return sorted(set(clean))


def set_team_installation(team_id, installation_id, repos, *, home=None):
    """Record (upsert) a team's GitHub App installation_id + the repo(s) it covers, keyed by
    the caller's team_id via the StateBackend. `installation_id` is validated as a positive
    int; `repos` are validated owner/name slugs (>=1). Returns the stored record dict (no
    secret — installation_id + slugs are non-sensitive). Fail-closed (GhInstallError) on a
    bad team_id / installation_id / repo, or an IO write failure."""
    tid = _validate_team_id(team_id)
    inst = _coerce_installation_id(installation_id)
    covered = _validate_repos(repos)
    record = {
        "version": _SCHEMA_VERSION,
        "team_id": tid,
        "installation_id": inst,
        "repos": covered,
    }
    if not _backend(home).put_record(_rel(tid), record):
        raise GhInstallError("write_failed", "could not persist the install record")
    return record


def _load(team_id, home=None):
    """The team's install record dict, or None when absent/corrupt. Reads EXACTLY the
    caller-team partition ("gh-install/<team_id>.json") — no cross-team path exists."""
    rec = _backend(home).get_record(_rel(team_id))
    return rec if isinstance(rec, dict) else None


def get_installation(team_id, *, home=None):
    """The caller-team's installation_id (an int). FAIL-CLOSED: raises
    GhInstallError('no_installation') when the team has no install record — never returns a
    default, never another team's id. The record is addressed strictly by the caller's
    team_id, so team A can only ever read team A's installation."""
    rec = _load(team_id, home=home)
    if not rec:
        raise GhInstallError("no_installation", "team has no GitHub App installation bound")
    inst = rec.get("installation_id")
    try:
        return _coerce_installation_id(inst)
    except GhInstallError:
        # A record that somehow holds a non-int installation_id is unusable — fail closed
        # rather than hand a malformed value to the minter.
        raise GhInstallError("no_installation", "stored installation_id is invalid")


def known_team_ids(*, home=None):
    """The SORTED team_ids that have a bound GitHub App installation (the DISPATCHABLE teams
    — the drain iterates these to sweep each team's queue, INV-2/§4 drain wiring). Enumerates
    the install partition ("gh-install/<team_id>.json") via the StateBackend's list_names —
    the SAME firestore-safe record enumeration cp_presence uses (never backend.path()). A team
    with queued work but NO installation is intentionally absent (it can authorize nothing, so
    it is not dispatchable — a drain over it would only ever fail-closed). Tolerant: an absent
    store yields []."""
    out = []
    for name in _backend(home).list_names(_INSTALL_DIR, suffix=".json"):
        tid = name[:-len(".json")] if name.endswith(".json") else name
        if tid:
            out.append(tid)
    return sorted(set(out))


def covered_repos(team_id, *, home=None):
    """The SORTED owner/name slugs the caller-team's installation covers, or [] when the team
    has no install record. Read-only, tolerant — the authz predicate builds on this."""
    rec = _load(team_id, home=home)
    if not rec:
        return []
    repos = rec.get("repos")
    return list(repos) if isinstance(repos, list) else []


def team_covers_repo(team_id, repo, *, home=None):
    """THE repo<->team AUTHZ PREDICATE (bool). True iff the caller-team's OWN installation
    covers `repo`. False for: no install record, an off-slug repo, or a repo owned by another
    tenant's installation. This is the exact-match gate that defeats IDOR-via-repo-slug — a
    caller naming another team's repo gets False here (and a refusal in mint). Never raises
    for a normal denial; a bad repo shape is simply not covered (False)."""
    if not isinstance(repo, str) or not _REPO_SLUG_RX.fullmatch(repo):
        return False
    return repo in covered_repos(team_id, home=home)


def _minter_path():
    """The bin/heimdall-gh-app-token path — the HEIMDALL_GH_APP_TOKEN_BIN override (a test /
    GHE seam) if set, else the repo-relative sibling of this lib dir's parent (bin/)."""
    override = os.environ.get(_MINTER_ENV)
    if override:
        return override
    return os.path.join(os.path.dirname(_HERE), "heimdall-gh-app-token")


def mint_token_for_team(team_id, repo, *, home=None, timeout=45):
    """Mint a SHORT-LIVED, SCOPED GitHub App installation token for the caller-team's repo.

    The repo<->team authz RED-line: `repo` MUST be covered by the CALLER-team's OWN
    installation (team_covers_repo). If it is not — or the team has no installation — this
    REFUSES (GhInstallError) BEFORE any token is minted. This is what stops a caller from
    naming another tenant's repo slug and riding their own installation to it.

    On authz pass it runs bin/heimdall-gh-app-token with the App creds already in the ambient
    env (App-id + private key, from Secret Manager / the 0600 store — this module never reads
    them) and TWO overrides carried by the child's ENV (never argv, so no secret/id is
    ps-visible): HEIMDALL_GH_APP_INSTALLATION_ID = the TEAM'S installation id, and
    HEIMDALL_GH_APP_REPOSITORIES = the repo NAME (defense-in-depth, scoping the token to that
    one repo). Returns the token string ONLY as the return value — it is NEVER logged, NEVER
    an argv element, NEVER placed in an exception. A non-zero minter exit is a fail-closed
    GhInstallError carrying only the child's (token-free) stderr."""
    # 1) authz FIRST — refuse an uncovered/foreign repo before any token exists.
    if not isinstance(repo, str) or not _REPO_SLUG_RX.fullmatch(repo):
        raise GhInstallError("bad_repo", "repo must be an owner/name slug")
    if not team_covers_repo(team_id, repo, home=home):
        # No installation OR the repo is not in this team's installation -> hard refusal.
        # Distinguish the two only for the audit note (never leak another team's coverage).
        if not _load(team_id, home=home):
            raise GhInstallError(
                "no_installation", "team has no GitHub App installation bound")
        raise GhInstallError(
            "repo_not_covered",
            "repo is not covered by the caller-team's installation")

    installation_id = get_installation(team_id, home=home)

    minter = _minter_path()
    if not (os.path.isfile(minter) and os.access(minter, os.X_OK)):
        raise GhInstallError("minter_missing", "the token minter is not executable")

    # The child inherits the ambient env (App-id + private key live there) and gets the
    # per-team installation id + a repo-name scope override. Secrets/ids ride ENV, not argv.
    child_env = dict(os.environ)
    child_env["HEIMDALL_GH_APP_INSTALLATION_ID"] = str(installation_id)
    child_env["HEIMDALL_GH_APP_REPOSITORIES"] = repo.split("/", 1)[1]

    try:
        proc = subprocess.run(
            [minter],
            env=child_env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise GhInstallError("mint_failed", "could not run the token minter") from exc

    if proc.returncode != 0:
        # The minter guarantees its stderr is key-free AND token-free (it prints ONLY the
        # token to stdout). We surface a trimmed stderr for diagnosis and DISCARD stdout.
        # KEEP the FIRST meaningful line(s): the minter's _die diagnostics are FRONT-loaded
        # (the CAUSE is line 1 — "cannot read the private key", "GitHub returned 401", a
        # timeout, an OSError), so preserve up to 3 non-empty lines / 200 chars rather than the
        # LAST line alone (which trimmed a multi-line diagnostic down to uselessness). When
        # stderr is empty we still NAME the exit code so the failure is never mute.
        lines = [ln.strip() for ln in (proc.stderr or "").splitlines() if ln.strip()]
        note = (" | ".join(lines[:3])[:200] if lines
                else "minter exited %d with no stderr" % proc.returncode)
        raise GhInstallError("mint_failed", note)

    token = (proc.stdout or "").strip()
    if not token:
        raise GhInstallError("mint_failed", "the minter returned an empty token")
    # Return ONLY — the token is never logged / stored / placed in an exception.
    return token
