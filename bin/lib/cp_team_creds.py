#!/usr/bin/env python3
# cp_team_creds.py — the PER-TEAM MODEL-CREDENTIAL STORE for public, multi-tenant
# Heimdall (BYO-credential MVP, design §1 / §5 of
# docs/analysis/2026-07-03-public-rr-control-plane.md).
#
# WHY THIS EXISTS. The public control plane cannot run every user's `claude` on one
# shared subscription (ToS + unbounded cost + privacy). The honest MVP is BYO-credential:
# each team supplies THEIR OWN Claude auth — a `claude setup-token` OAuth token
# (CLAUDE_CODE_OAUTH_TOKEN, headless against their own Max/Pro subscription) or an
# ANTHROPIC_API_KEY (metered on their own account). This module is the store for that
# secret, keyed by team_id, injected ONLY into that team's own job env.
#
# THE ISOLATION CONTRACT (security-critical — every function enforces it):
#   * team_id IS the partition key. Every function takes the CALLER's team_id as its
#     FIRST argument and reads/writes EXACTLY that one partition. There is NO function
#     that takes team A's id and returns team B's cred — cross-tenant reads are not
#     expressible by the API, and a malformed/traversal team_id is refused
#     (fail-closed) rather than allowed to escape its partition.
#   * team_id MUST be the caller's VERIFIED team_id. The ONLY legitimate source is the
#     caller's enrolled-binding team (cp_auth.registered_team / the verified enroll
#     handshake — cp_auth.py) — NEVER a raw request field the client can spoof. This
#     module does not derive team_id and does not accept a team_secret; it consumes the
#     already-verified, non-secret team_id handle the caller resolved from cp_auth.
#   * The secret is NEVER logged, printed, repr'd, or embedded in any exception. It
#     leaves this module ONLY as the in-memory value returned by get_team_cred() /
#     env_for_team() for injection into THAT team's job env — the one intended sink.
#   * FAIL-CLOSED. A team with no stored cred yields None / {} (never a fabricated or
#     another team's value); the caller then denies. A bad kind / bad secret / bad
#     team_id yields a False/None/{}, never a partial or cross-tenant result.
#
# WHERE THE BYTES LIVE (two backends behind one seam — mirrors cp_state's design):
#   * LOCAL / self-host (default): the cred record is written THROUGH the StateBackend
#     (cp_state.get_backend — the same durable seam the key registry uses), at
#     control-plane/team-creds/<team_id>/<kind>.json, and the on-disk file is hardened
#     to 0600 (dir 0700) so a co-tenant process cannot read another team's secret.
#   * CLOUD (K_SERVICE / HEIMDALL_STATE_BACKEND=firestore, or forced via
#     HEIMDALL_TEAM_CRED_STORE=secretmanager): the raw secret is written to Google
#     Secret Manager under a per-team secret id, and the StateBackend record holds only
#     a NON-secret REFERENCE (project + secret_id) — the raw secret never sits in
#     Firestore. This is design §1's "Stored per-user in Secret Manager, keyed by
#     team_id" posture; the durable index still rides the StateBackend seam.
#
# HOW IT FEEDS THE JOB. env_for_team(team_id) returns exactly the dict
# {CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_API_KEY: <the team's secret>}. Merged into the
# isolated job's env, it makes cp_handlers.select_maintainer_auth (which already prefers
# CLAUDE_CODE_OAUTH_TOKEN then ANTHROPIC_API_KEY from the job's source_env) work UNCHANGED
# — just per-team. The secret travels by ENV ONLY, never on argv (cp_handlers fixed-argv).
#
# stdlib-only core (os/re) + cp_state (the StateBackend seam) + cp_auth (cloud-profile
# detection only, single-sourced with the deploy) + an OPTIONAL google-cloud-secret-manager
# client imported LAZILY, so the default local path never needs the cloud dep.

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the pluggable persistence backend — the durable per-team storage seam.

# ── the two BYO credential kinds + their job env vars (design §1 preference order) ──
#
# oauth_token is PREFERRED (the user's own subscription, no metered spend); api_key is
# the metered fallback. The env var each maps to is EXACTLY what
# cp_handlers.select_maintainer_auth selects, so a per-team env merge is a no-op there.

KIND_OAUTH_TOKEN = "oauth_token"
KIND_API_KEY = "api_key"

# Preference order: OAuth subscription first, metered API key second (mirrors
# cp_handlers.AUTH_ENV_ORDER). get_team_cred / env_for_team resolve in THIS order.
KINDS = (KIND_OAUTH_TOKEN, KIND_API_KEY)

# The job env var each kind injects into (identical to cp_handlers.AUTH_ENV_OAUTH /
# AUTH_ENV_API_KEY — the credential lands under the name the loop already reads).
ENV_FOR_KIND = {
    KIND_OAUTH_TOKEN: "CLAUDE_CODE_OAUTH_TOKEN",
    KIND_API_KEY: "ANTHROPIC_API_KEY",
}

# The record schema version (stored in every cred record for forward-compat).
_VERSION = "1.0.0"

# The store sub-namespace under control-plane/ (the StateBackend rel root). A team's
# creds live at team-creds/<team_id>/<kind>.json — one partition dir per team.
_STORE_REL = "team-creds"

# A team_id MUST be a safe, single-segment partition handle: the 32-hex
# derive_team_id() shape, or any equally path-safe slug. This regex REFUSES path
# separators, "..", whitespace, and empties — so a malformed/hostile team_id can never
# traverse out of its own partition into another team's dir (the at-rest isolation gate).
_TEAM_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")

# Override to force the secret-store backend regardless of profile (operators/tests):
#   "local"         -> the StateBackend + 0600 path (never Secret Manager).
#   "secretmanager" -> the Google Secret Manager path (raw secret off the StateBackend).
# Absent -> the cloud profile decides (K_SERVICE or firestore backend => Secret Manager).
_STORE_ENV = "HEIMDALL_TEAM_CRED_STORE"

# The GCP project env vars consulted (in order) for the Secret Manager store.
_PROJECT_ENVS = (
    "GOOGLE_CLOUD_PROJECT",
    "HEIMDALL_FIRESTORE_PROJECT",
    "GCP_PROJECT",
    "GCLOUD_PROJECT",
)


# ── team_id / kind / secret validation (fail-closed input gates) ───────────────


def _valid_team_id(team_id):
    """Return the team_id iff it is a safe single-segment partition handle, else None.
    A None/empty/whitespace/traversal/multi-segment value is REFUSED — the caller then
    fails closed. This is the boundary that keeps a malformed team_id inside its own
    partition (no "../otherteam" escape)."""
    if not team_id or not isinstance(team_id, str):
        return None
    return team_id if _TEAM_ID_RE.match(team_id) else None


def _valid_kind(kind):
    """True iff `kind` is one of the two known credential kinds."""
    return kind in ENV_FOR_KIND


# ── the StateBackend seam + the per-team rel paths ─────────────────────────────


def _backend(home=None):
    """The StateBackend for the cred index (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every cp_* accessor's `home=` arg does."""
    return cp_state.get_backend(home=home)


def _cred_rel(team_id, kind):
    """The store-relative record path for one (team_id, kind): team-creds/<tid>/<kind>.json.
    team_id is already validated safe, so this cannot escape the store namespace."""
    return os.path.join(_STORE_REL, team_id, "%s.json" % kind)


# ── which secret store: local (StateBackend + 0600) vs Google Secret Manager ───


def _cloud_profile():
    """True iff we are in the Cloud Run / durable deploy profile (single-sourced with
    the deploy via cp_auth.cloud_profile — K_SERVICE or HEIMDALL_STATE_BACKEND=firestore).
    Falls back to the same two signals directly if cp_auth cannot be imported."""
    try:
        import cp_auth
        return bool(cp_auth.cloud_profile())
    except Exception:  # noqa: BLE001 — mirror the signal directly if cp_auth is absent.
        if os.environ.get("K_SERVICE"):
            return True
        backend = (os.environ.get("HEIMDALL_STATE_BACKEND") or "").strip().lower()
        return backend == "firestore"


def _use_secret_manager():
    """True iff the raw secret should live in Google Secret Manager (and the StateBackend
    hold only a reference). Forced by HEIMDALL_TEAM_CRED_STORE; else the cloud profile."""
    override = (os.environ.get(_STORE_ENV) or "").strip().lower()
    if override == "local":
        return False
    if override in ("secretmanager", "secret-manager", "sm"):
        return True
    return _cloud_profile()


def _harden(backend, rel):
    """Best-effort at-rest hardening of a LOCALLY-stored cred: chmod the file to 0600 and
    its team partition dir to 0700, so a co-tenant process on the same box cannot read
    another team's secret. Silently skipped when the backend exposes no filesystem path
    (a non-filesystem backend keeps the raw secret in Secret Manager, not here)."""
    try:
        fpath = backend.path(rel)
    except cp_state.BackendUnavailable:
        return
    try:
        os.chmod(fpath, 0o600)
        os.chmod(os.path.dirname(fpath), 0o700)   # the per-team partition dir.
    except OSError:
        return


# ── Google Secret Manager helpers (the cloud store — lazy, real, fail-closed) ──


def _sm_client():
    """Construct the Secret Manager client. Imported LAZILY (the default local path never
    loads the cloud dep). Raises a clear RuntimeError — never a silent degrade — when the
    Secret Manager store is selected but the client is unavailable."""
    try:
        from google.cloud import secretmanager
    except Exception as exc:  # noqa: BLE001 — the cloud dep is not installed / importable.
        raise RuntimeError(
            "the Secret Manager team-cred store is selected but the "
            "'google-cloud-secret-manager' client is unavailable") from exc
    return secretmanager.SecretManagerServiceClient()


def _sm_project():
    """The GCP project for the Secret Manager store (first present of _PROJECT_ENVS).
    Raises RuntimeError when none is set — fail closed, never guess a project."""
    for name in _PROJECT_ENVS:
        val = os.environ.get(name)
        if val and val.strip():
            return val.strip()
    raise RuntimeError(
        "no GCP project for the Secret Manager team-cred store "
        "(set GOOGLE_CLOUD_PROJECT)")


def _sm_secret_id(team_id, kind):
    """The per-team Secret Manager secret id: heimdall-tc-<team_id>-<kind>. team_id is a
    validated hex/slug and kind is a known constant, so the id is Secret-Manager-safe
    ([A-Za-z0-9_-], well under the 255-char limit)."""
    return "heimdall-tc-%s-%s" % (team_id, kind.replace("_", "-"))


def _sm_secret_exists(client, name):
    """True iff the Secret Manager secret `name` already exists."""
    try:
        client.get_secret(request={"name": name})
        return True
    except Exception:  # noqa: BLE001 — NotFound (or any lookup miss) reads as absent.
        return False


def _sm_create_secret(client, parent, secret_id):
    """Create the per-team secret container (automatic replication). Returns True on a
    fresh create; False when a concurrent writer already created it (AlreadyExists) — the
    add_secret_version that follows still lands a new version either way."""
    try:
        client.create_secret(request={
            "parent": parent,
            "secret_id": secret_id,
            "secret": {"replication": {"automatic": {}}},
        })
        return True
    except Exception:  # noqa: BLE001 — AlreadyExists (a race) is benign; the version lands.
        return False


def _sm_put_secret(project, secret_id, secret):
    """Write the raw secret as a new version of the per-team Secret Manager secret,
    creating the container on first write. Raises on a hard failure (the caller does not
    persist a reference to a secret that never landed). The secret is passed only as the
    version payload — never logged."""
    client = _sm_client()
    parent = "projects/%s" % project
    name = "%s/secrets/%s" % (parent, secret_id)
    if not _sm_secret_exists(client, name):
        _sm_create_secret(client, parent, secret_id)
    client.add_secret_version(request={
        "parent": name,
        "payload": {"data": secret.encode("utf-8")},
    })


def _sm_access_secret(project, secret_id):
    """Read back the latest version of a per-team Secret Manager secret as a str, or None
    when the reference is incomplete. Access failures propagate to the caller, which
    treats them as no-cred (fail closed)."""
    if not project or not secret_id:
        return None
    client = _sm_client()
    name = "projects/%s/secrets/%s/versions/latest" % (project, secret_id)
    resp = client.access_secret_version(request={"name": name})
    return resp.payload.data.decode("utf-8")


def _sm_delete_secret(project, secret_id):
    """Destroy a team's Secret Manager secret (all versions). Returns True on delete,
    False when the reference is incomplete."""
    if not project or not secret_id:
        return False
    client = _sm_client()
    client.delete_secret(request={
        "name": "projects/%s/secrets/%s" % (project, secret_id),
    })
    return True


# ── record read helpers (a tombstone / cred-less record reads as no-cred) ──────


def _has_record(rec):
    """True iff `rec` is a live (non-tombstone) cred record with either a local secret or
    a Secret Manager reference. A None / deleted / off-schema record reads as no-cred."""
    if not isinstance(rec, dict) or rec.get("deleted"):
        return False
    if rec.get("kind") not in ENV_FOR_KIND:
        return False
    if rec.get("backend") == "secretmanager":
        return bool(rec.get("secret_id"))
    return bool(rec.get("secret"))


def _secret_from_record(rec):
    """Materialize the raw secret from a cred record (local inline or Secret Manager
    reference), or None for a tombstone / off-schema / unreadable record. Any Secret
    Manager access error yields None — the caller fails closed (no cred => deny)."""
    if not _has_record(rec):
        return None
    if rec.get("backend") == "secretmanager":
        try:
            return _sm_access_secret(rec.get("project"), rec.get("secret_id"))
        except Exception:  # noqa: BLE001 — an unreadable reference is no-cred (fail closed).
            return None
    return rec.get("secret") or None


def _local_remove(backend, rel):
    """Hard-remove a locally-stored cred file via the backend's filesystem path. Returns
    True on removal (or an already-absent file — idempotent), False when the backend
    exposes no path (a non-filesystem backend tombstones instead)."""
    try:
        fpath = backend.path(rel)
    except cp_state.BackendUnavailable:
        return False
    try:
        os.remove(fpath)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        return False


# ── the public API (each keyed to the caller's ONE verified team_id) ───────────


def put_team_cred(team_id, kind, secret, *, home=None):
    """Store a team's BYO model credential, keyed by the caller's VERIFIED `team_id`.
    `kind` is 'oauth_token' or 'api_key'; `secret` is the raw token/key. Locally the
    secret is written through the StateBackend and hardened to 0600; in the cloud profile
    it is written to Google Secret Manager and the StateBackend holds only a non-secret
    reference. Returns True on a durable write, False on invalid input (bad team_id/kind/
    empty secret) or an IO failure. The secret is NEVER logged/echoed — it is consumed
    only into the storage medium.

    SECURITY: `team_id` MUST be the caller's own verified team (from cp_auth), never a
    client-supplied field. This writes EXACTLY one team's partition — it cannot touch
    another team's cred."""
    tid = _valid_team_id(team_id)
    if not tid or not _valid_kind(kind):
        return False
    if not secret or not isinstance(secret, str):
        return False
    backend = _backend(home)
    rel = _cred_rel(tid, kind)
    env_name = ENV_FOR_KIND[kind]
    if _use_secret_manager():
        project = _sm_project()
        secret_id = _sm_secret_id(tid, kind)
        _sm_put_secret(project, secret_id, secret)  # raw secret -> Secret Manager only.
        record = {
            "version": _VERSION, "kind": kind, "env_name": env_name,
            "backend": "secretmanager", "project": project, "secret_id": secret_id,
        }
        return bool(backend.put_record(rel, record))
    # local: the secret rides the StateBackend record; the file is hardened to 0600.
    record = {
        "version": _VERSION, "kind": kind, "env_name": env_name,
        "backend": "local", "secret": secret,
    }
    if not backend.put_record(rel, record):
        return False
    _harden(backend, rel)
    return True


def get_team_cred(team_id, *, home=None):
    """Return the caller-team's model credential, preferring oauth_token then api_key, as
    an in-memory value for injection into THAT team's job env ONLY. Returns
    {"kind", "env_name", "secret"} for the first present kind, or None when the team has
    no stored cred (FAIL CLOSED — the caller then denies). The returned secret is meant
    solely for the job-env sink; it is never logged by this module.

    SECURITY: reads EXACTLY the partition of the caller's verified `team_id`. There is no
    parameter by which team A could request team B's cred."""
    tid = _valid_team_id(team_id)
    if not tid:
        return None
    backend = _backend(home)
    for kind in KINDS:  # oauth_token first, then api_key (design §1 preference order).
        secret = _secret_from_record(backend.get_record(_cred_rel(tid, kind)))
        if secret:
            return {"kind": kind, "env_name": ENV_FOR_KIND[kind], "secret": secret}
    return None


def env_for_team(team_id, *, home=None):
    """The env dict to merge into the isolated job env for the caller's team:
    {CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_API_KEY: <the team's secret>} — so
    cp_handlers.select_maintainer_auth works UNCHANGED, just per-team. Returns {} when the
    team has no cred (FAIL CLOSED — the caller denies). The secret travels by env ONLY,
    never on argv. This is the ONE intended sink for the secret value."""
    cred = get_team_cred(team_id, home=home)
    if not cred:
        return {}
    return {cred["env_name"]: cred["secret"]}


def has_cred(team_id, *, home=None):
    """True iff the caller's team has at least one stored credential (oauth_token or
    api_key). Cheap presence check — does NOT materialize the secret. False for an
    unknown/absent team or an invalid team_id (fail closed)."""
    tid = _valid_team_id(team_id)
    if not tid:
        return False
    backend = _backend(home)
    for kind in KINDS:
        if _has_record(backend.get_record(_cred_rel(tid, kind))):
            return True
    return False


def delete_team_cred(team_id, *, home=None):
    """Delete the caller-team's stored credential(s). Locally the 0600 file is removed; in
    the cloud profile the Secret Manager secret is destroyed and the StateBackend reference
    is tombstoned (the StateBackend seam has no hard-delete, so the durable index carries a
    'deleted' marker while the actual secret material is gone from Secret Manager). Returns
    True iff a stored cred existed and was removed, False when there was nothing to delete.

    SECURITY: deletes EXACTLY the caller's verified `team_id` partition — never another
    team's."""
    tid = _valid_team_id(team_id)
    if not tid:
        return False
    backend = _backend(home)
    removed = False
    for kind in KINDS:
        rel = _cred_rel(tid, kind)
        rec = backend.get_record(rel)
        if not _has_record(rec):
            continue
        if rec.get("backend") == "secretmanager":
            sm_ok = False
            try:
                sm_ok = _sm_delete_secret(rec.get("project"), rec.get("secret_id"))
            except Exception:  # noqa: BLE001 — a delete miss still tombstones the reference.
                sm_ok = False
            # Tombstone the durable reference regardless (the StateBackend seam has no
            # hard-delete); the secret material is gone from Secret Manager when sm_ok.
            backend.put_record(rel, {
                "version": _VERSION, "kind": kind, "deleted": True, "purged": sm_ok,
            })
            removed = True
            continue
        if _local_remove(backend, rel):
            removed = True
        else:
            # No filesystem path to remove — tombstone the record so it reads as no-cred.
            backend.put_record(rel, {"version": _VERSION, "kind": kind, "deleted": True})
            removed = True
    return removed
