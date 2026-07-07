#!/usr/bin/env python3
# cp_enroll.py — TOKEN-GATED SELF-ENROLL for the Heimdall control plane (PKI bootstrap).
#
# WHY THIS EXISTS (the zero-touch first-run gap). cp_auth (§3) binds an Ed25519 keypair to
# a HAID: every instance<->server message is SIGNED with the instance key, the server
# VERIFIES against the registered pubkey. But a dev's FIRST run has NO registered key — its
# presence beats (cp_presence) would 401 at the §3 chokepoint until SOMEONE registers its
# haid->pubkey. Today that is a manual `identity` CLI step per dev. This module closes the
# gap: a dev's first run POSTs its freshly-generated pubkey to /enroll and is auto-registered
# with ZERO manual steps, after which every signed call verifies against that key.
#
# THE TRUST BOUNDARY (why this is safe to expose unsigned). /enroll is the ONE route that
# CANNOT be PKI-signed — the caller has no registered key yet (that is the whole point). So
# it cannot ride the §3 chokepoint; cp_server serves it PRE-AUTH via the public-route seam
# (register_public_route), exactly as the health probes are served pre-auth. An unsigned
# endpoint with no gate would let anyone register any key, so /enroll carries its OWN gate:
# a shared TEAM BOOTSTRAP TOKEN. The CALLER presents the token (header X-Heimdall-Enroll-
# Token or a body field); the SERVER compares it against a server-side secret
# (HEIMDALL_ENROLL_TOKEN — the SAME env/Secret-Manager seam as the PKI key, cp_auth
# PKI_KEY_ENV). Token absent/wrong -> refused, NOTHING registered.
#
# FAIL-CLOSED, NEVER ALLOW-ALL. If the server-side verifier secret is UNSET we refuse EVERY
# enroll with a clear reason ("enroll_disabled") — we NEVER fall back to accepting all
# enrollments. This is strictly fail-closed in BOTH profiles (a superset of the cloud-profile
# requirement): a server with no configured enroll token simply does not accept enrollments.
# The cloud profile (cp_auth.cloud_profile(): K_SERVICE set or HEIMDALL_STATE_BACKEND=
# firestore) is surfaced in the refusal reason so an operator can see a deployed instance was
# refused for a missing secret rather than a bad token.
#
# THE VERIFIER SECRET IS SERVER-ONLY. HEIMDALL_ENROLL_TOKEN is read from the server
# environment ONLY. It is NEVER returned in any response, NEVER logged/echoed, NEVER shipped
# in the plugin or a client, and NEVER compared with a non-constant-time op (hmac.compare_digest
# guards against a timing oracle). The route's success body is ONLY {ok, haid}; an error body
# is ONLY {ok:false, reason:<code>} — no secret, never the server PKI key, ever.
#
# THE REGISTRY IS REUSED VERBATIM. The haid->pubkey binding is persisted through
# cp_auth.register_key (the SAME StateBackend-seam registry the `identity` CLI and the server
# identity write to) — Firestore-durable under HEIMDALL_STATE_BACKEND=firestore, byte-identical
# local otherwise, NEVER backend.path() on the serving path (the firestore-only incident class).
# Idempotency mirrors a key store: same haid + SAME pubkey -> ok (a re-run is harmless); same
# haid + DIFFERENT pubkey -> 409 conflict (a registered identity cannot be silently rebound, so
# a stolen token cannot hijack an already-enrolled dev); a NEW haid -> registered.
#
# DATA ONLY, EXECUTES NOTHING. Enrollment writes one registry record; there is no action_type/
# handler/dispatch path out of this module — the §2 control/data-plane line holds.
#
# THE INTERFACE the server BINDS to (stable; cp_boot imports, never edits cp_server):
#   enroll(haid, pubkey, *, provided_token, handle, home) -> dict   — the testable core.
#   enroll_route(request, *, home) -> cp_server.Response            — the pre-auth handler.
#   register(*, home=None)  — wire POST /enroll into cp_server's PUBLIC (pre-auth) seam.
#
# stdlib-only (base64/hmac/json/os) + cp_auth (the registry + cloud_profile) + cp_server
# (register_public_route + Response) — the SAME dependency shape every other CP piece has.

from __future__ import annotations

import base64
import binascii
import hmac
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth     # REUSE the haid->pubkey registry (register_key/registered_pubkey) +
                   # cloud_profile() — never hand-roll Ed25519 or the registry here.
import cp_server   # REUSE register_public_route + Response — the pre-auth registration seam.

# The server-side verifier secret env var. Injected by the deploy via the SAME --set-secrets
# Secret-Manager seam as the PKI key (cp_auth.PKI_KEY_ENV / HEIMDALL_CP_PKI_KEY). SERVER-ONLY:
# read here, NEVER returned/logged/echoed, NEVER shipped in a client.
ENROLL_TOKEN_ENV = "HEIMDALL_ENROLL_TOKEN"

# The header the CALLER may carry the bootstrap token in (the body field is the alternative).
# cp_server lifts this header into request["enroll_token"]; documented here as the wire name.
ENROLL_TOKEN_HEADER = "X-Heimdall-Enroll-Token"

# The body field the CALLER may carry the bootstrap token in (alternative to the header — the
# POST-with-a-body shape is GFE-safe, so the body path works over real Cloud Run HTTP).
ENROLL_TOKEN_BODY_FIELD = "enroll_token"

# OPEN-ENROLL MODE (zero-friction internal onboarding). When HEIMDALL_ENROLL_OPEN is truthy,
# /enroll is served TOKENLESS — the bootstrap-token gate is bypassed and the load-bearing abuse
# controls become (1) the HARD registry-size cap below, (2) the per-IP + deployment-wide rate
# limits in cp_publicsurface.check_enroll. This is deliberately bounded: an open enroll can only
# register owner=False keys (no escalation), cannot hijack an enrolled haid (the 409 conflict
# holds), and cannot grow the registry past the cap. UNSET (the default) -> EXACTLY the
# fail-closed token gate, no regression. A configured+presented token is still accepted in open
# mode (token mode is never broken), the gate is simply not REQUIRED.
ENROLL_OPEN_ENV = "HEIMDALL_ENROLL_OPEN"

# The truthy spellings that ENABLE open mode (mirrors cp_publicsurface._TRUTHY). Anything else
# (unset / "" / "0" / "false") leaves enroll token-gated — fail-safe toward the token gate.
_OPEN_TRUTHY = {"1", "true", "yes", "on"}

# THE HARD REGISTRY-SIZE CAP (the open-mode blast bound). A NET-NEW haid is refused once the
# registry already holds this many keys, so the total registry GROWTH is bounded regardless of
# request rate or how many IPs/tokens an attacker rotates through. A re-enroll of an EXISTING
# haid (idempotent or a conflict) NEVER hits the cap — only net-new keys count against it. The
# cap applies in BOTH modes (a strict backstop); the generous default leaves token mode
# unaffected in practice and it is env-tunable for a tighter open deployment.
ENROLL_MAX_KEYS_ENV = "HEIMDALL_ENROLL_MAX_KEYS"
_DEFAULT_MAX_KEYS = 1000

# ── TEAM SECRET (multi-tenant team presence — the bootstrap capability) ─────────
#
# A team_secret is a high-entropy bearer capability scoping a team (a repo's roster). It both
# AUTHORIZES the enroll AND SCOPES the team: the server derives team_id = cp_auth.derive_team_id
# (one-way), binds haid -> team_id, and DISCARDS the raw secret (never at rest, never logged,
# never echoed). The header path keeps the secret out of any body log.

# The header the CALLER may carry the team secret in (the body field is the alternative).
# cp_server lifts this header into request["team_secret"]; documented here as the wire name.
TEAM_SECRET_HEADER = "X-Heimdall-Team-Secret"

# The body field the CALLER may carry the team secret in (alternative to the header — the
# POST-with-a-body /enroll shape is GFE-safe, so the body path works over real Cloud Run HTTP).
TEAM_SECRET_BODY_FIELD = "team_secret"

# MINIMUM accepted team_secret length (chars). 256-bit CSPRNG secrets are 43 base64url chars;
# rejecting anything shorter than 32 stops a hand-typed weak secret colliding into another
# team. A shorter secret -> team_secret_weak (422).
TEAM_SECRET_MIN_LEN = 32

# The PER-TEAM member cap (RJ ruling 4): a NET-NEW haid is refused once a team already holds
# this many bindings -> team_full (429). Bounds how much one (possibly leaked) secret can bloat
# the registry. Env-tunable; a typo/non-positive falls back to the default (never a 0 hard gate).
TEAM_MAX_MEMBERS_ENV = "HEIMDALL_TEAM_MAX_MEMBERS"
_DEFAULT_TEAM_MAX_MEMBERS = 100

# An Ed25519 public key is exactly 32 raw bytes; a submitted pubkey must decode to this or it
# cannot be a valid verification key and we refuse to store garbage.
_ED25519_PUBKEY_BYTES = 32


def server_enroll_token():
    """The server-side bootstrap-token verifier secret (HEIMDALL_ENROLL_TOKEN), or None when
    unset. SERVER-ONLY — this value is NEVER returned in a response, logged, or echoed. An
    empty/whitespace value is treated as unset (fail-closed), so a blank secret never becomes
    an accidental allow-all."""
    raw = os.environ.get(ENROLL_TOKEN_ENV)
    if raw is None:
        return None
    raw = raw.strip()
    return raw or None


def enroll_open():
    """True iff HEIMDALL_ENROLL_OPEN is set truthy — /enroll runs TOKENLESS (the bootstrap-token
    gate is bypassed; the registry-size cap + the rate limits are the load-bearing controls).
    Unset / "" / "0" / "false" -> False (the fail-closed token gate, EXACTLY today's behavior).
    Read fresh from the env each call so a deploy can flip it without a code change."""
    raw = os.environ.get(ENROLL_OPEN_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _OPEN_TRUTHY


def enroll_max_keys():
    """The HARD registry-size cap (HEIMDALL_ENROLL_MAX_KEYS), or _DEFAULT_MAX_KEYS when unset /
    malformed / non-positive (a typo must never silently become a 0/negative hard-closed gate —
    an explicit kill switch is a deploy concern). Bounds total registry GROWTH so an open/leaked
    enroll surface cannot register keys without bound, regardless of rate."""
    raw = os.environ.get(ENROLL_MAX_KEYS_ENV)
    if raw is None:
        return _DEFAULT_MAX_KEYS
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return _DEFAULT_MAX_KEYS
    return val if val > 0 else _DEFAULT_MAX_KEYS


def _registry_key_count(home=None):
    """Count the haid->pubkey bindings currently in the registry — firestore-safe (it reads
    through cp_auth's tolerant StateBackend-seam registry reader, get_record-based, NEVER
    backend.path()). An absent/corrupt registry reads as 0 keys (the cap then never trips on a
    fresh deployment). cp_auth owns the registry schema; this only reads its key count."""
    reg = cp_auth._load_keys(home)
    keys = reg.get("keys") if isinstance(reg, dict) else None
    return len(keys) if isinstance(keys, dict) else 0


def team_max_members():
    """The PER-TEAM member cap (HEIMDALL_TEAM_MAX_MEMBERS), or _DEFAULT_TEAM_MAX_MEMBERS when
    unset / malformed / non-positive (a typo must never silently become a 0/negative hard gate).
    Bounds how many NET-NEW haids one (possibly leaked) team_secret can register into its team."""
    raw = os.environ.get(TEAM_MAX_MEMBERS_ENV)
    if raw is None:
        return _DEFAULT_TEAM_MAX_MEMBERS
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return _DEFAULT_TEAM_MAX_MEMBERS
    return val if val > 0 else _DEFAULT_TEAM_MAX_MEMBERS


def _resolve_team_id(team_secret):
    """Resolve the team_id this enroll binds to, from the presented team_secret OR the
    configured default team. Returns (team_id, reason):
      • a too-short secret -> (None, "team_secret_weak").
      • a valid secret     -> (derive_team_id(secret), None) — the raw secret is DISCARDED here.
      • no secret + a configured default team -> (default_team_id(), None) — back-compat: the
        single-tenant deploy enrolls every dev into one default team (§migration).
      • no secret + NO default team -> (None, "team_required") — FAIL-CLOSED (never an
        unpartitioned binding).
    Pure of the registry; the raw secret never leaves this function."""
    if team_secret:
        if len(str(team_secret)) < TEAM_SECRET_MIN_LEN:
            return (None, "team_secret_weak")
        return (cp_auth.derive_team_id(team_secret), None)
    default = cp_auth.default_team_id()
    if default:
        return (default, None)
    return (None, "team_required")


def _token_matches(provided):
    """Constant-time compare of a caller-presented token against the server secret. Returns
    False when EITHER the server secret is unset (fail-closed — checked by the caller before
    here, but defended again) OR the provided token is empty OR they differ. hmac.compare_digest
    guards against a timing side channel; both operands are encoded to bytes for it."""
    secret = server_enroll_token()
    if not secret or not provided:
        return False
    return hmac.compare_digest(
        str(provided).encode("utf-8"), secret.encode("utf-8"))


def _valid_pubkey(pubkey):
    """True iff `pubkey` is base64 that decodes to a 32-byte Ed25519 public key. Rejects
    undecodable / wrong-length blobs so the registry never stores a key that can never verify
    a signature. Pure — no IO."""
    if not pubkey or not isinstance(pubkey, str):
        return False
    try:
        raw = base64.b64decode(pubkey.encode("ascii"), validate=True)
    except (binascii.Error, ValueError):
        return False
    return len(raw) == _ED25519_PUBKEY_BYTES


def enroll(haid, pubkey, *, provided_token, team_secret=None, handle=None,
           project=None, home=None):
    """THE testable self-enroll core. Token-gate, validate, resolve the TEAM, and bind
    haid -> {pubkey, owner:false, team_id, project} in the cp_auth registry. Returns a dict —
    {"ok": True, "haid": haid, "team_id": <id>} on success, or {"ok": False, "reason": <code>}
    on a refusal. NO secret (bootstrap token OR team_secret) is ever in the returned dict.

    `team_secret` is the team bootstrap capability (header X-Heimdall-Team-Secret or body
    field): the server derives team_id = cp_auth.derive_team_id(secret) and DISCARDS the raw
    secret (never at rest, never echoed). An absent secret maps to the configured default team
    (back-compat); no secret + no default team -> fail closed (team_required).

    `handle` is accepted as optional client metadata (display name); the registry schema is
    owned by cp_auth, so handle is read and discarded, never echoed. `project` (the dev's
    normalized repo id) is persisted on the binding (additive).

    The gate order (each a hard stop, fail-closed first):
      1-2. TOKEN GATE — enforced UNLESS open mode (enroll_open()): enroll_disabled (no server
         secret) / bad_enroll_token (presented token absent or mismatched, constant-time).
      3. malformed        — haid or pubkey is missing.
      4. invalid_pubkey   — pubkey is not base64 of a 32-byte Ed25519 key.
      4.5. TEAM GATE — team_secret_weak (presented secret < TEAM_SECRET_MIN_LEN) / team_required
         (no secret AND no default team configured -> never an unpartitioned binding).
      5. haid_pubkey_conflict — haid already registered to a DIFFERENT pubkey (409): a stolen
         secret can NEVER move someone else's enrolled HAID into the attacker's team.
      6. SAME pubkey re-enroll — a key holder may move their OWN HAID between teams (they hold
         the private key, so it is not a hijack): the team_id is UPDATED. An unchanged
         team_id+project is idempotent (no rewrite). Never hits a cap.
      6.5. CAPS (net-new haid only): team_full (the team already holds team_max_members()
         bindings) then enroll_registry_full (the global registry-size ceiling).
      7. register the binding through cp_auth.register_key (StateBackend seam, no path())."""
    # 1-2. THE TOKEN GATE — enforced UNLESS open mode is on. Open UNSET reproduces EXACTLY the
    #      historical fail-closed behavior (no regression); open ON makes enroll tokenless.
    if not enroll_open():
        # 1. FAIL-CLOSED: no server secret -> refuse ALL enroll (never allow-all).
        if not server_enroll_token():
            reason = ("enroll_disabled_cloud_profile" if cp_auth.cloud_profile()
                      else "enroll_disabled")
            return {"ok": False, "reason": reason}
        # 2. THE GATE: the presented token must match the server secret (constant-time).
        if not _token_matches(provided_token):
            return {"ok": False, "reason": "bad_enroll_token"}

    # 3-4. Validate the identity material BEFORE touching the registry.
    if not haid or not isinstance(haid, str) or not pubkey:
        return {"ok": False, "reason": "malformed"}
    if not _valid_pubkey(pubkey):
        return {"ok": False, "reason": "invalid_pubkey"}

    # 4.5. THE TEAM GATE — resolve the team_id this binding belongs to (the raw secret is
    #      consumed + discarded inside _resolve_team_id). A weak secret / no-team-and-no-default
    #      is fail-closed; otherwise team_id is the partition handle stored on the binding.
    team_id, team_reason = _resolve_team_id(team_secret)
    if team_reason is not None:
        return {"ok": False, "reason": team_reason}

    # 5-6. Conflict / OWN-key team-switch against the EXISTING binding (firestore-safe read).
    existing = cp_auth.registered_pubkey(haid, home=home)
    if existing is not None:
        if existing != pubkey:
            # A DIFFERENT key for an already-registered haid — refuse (no rebind/hijack). A
            # leaked team_secret can never move someone else's HAID into the attacker's team.
            return {"ok": False, "reason": "haid_pubkey_conflict"}
        # SAME key: the holder of the private key may move their OWN HAID between teams. If the
        # team_id (and project) are unchanged this is an idempotent re-run (no rewrite); else we
        # re-stamp the binding's team_id/project. Never blocked by a cap (not a net-new haid).
        cur_entry = cp_auth._load_keys(home)["keys"].get(haid) or {}
        cur_team = cur_entry.get("team_id")
        cur_project = cur_entry.get("project")
        eff_project = project if project is not None else cur_project
        if cur_team == team_id and eff_project == cur_project:
            return {"ok": True, "haid": haid, "team_id": team_id}
        if not cp_auth.register_key(haid, pubkey, owner=False, team_id=team_id,
                                    project=eff_project, home=home):
            return {"ok": False, "reason": "registry_write_failed"}
        return {"ok": True, "haid": haid, "team_id": team_id}

    # 6.4. ANOMALY FREEZE (cost-governance §3) — a team persistently flagged as a write-flooder
    #      (>50× the median daily write volume for FREEZE_DAYS consecutive days) has its ENROLLMENT
    #      FROZEN: no NEW member may join it. This is a NET-NEW gate ONLY — the idempotent/conflict/
    #      own-key-switch paths already returned above, so EXISTING members keep working (at the
    #      coalesced max backoff). Reversible (cp_anomaly.unfreeze / clear_mark) + audited. Lazy
    #      import (cp_anomaly pulls cp_config/cp_notify; no cycle back to cp_enroll, but keep the
    #      load-time surface minimal). Fail-open by construction: is_frozen returns False on any
    #      store hiccup, so a legit team is never frozen out by a transient backend error.
    import cp_anomaly  # lazy — the abuse throttle; a frozen team refuses only NET-NEW enrolls.
    if cp_anomaly.is_frozen(team_id, home=home):
        return {"ok": False, "reason": "team_frozen"}

    # 6.5. CAPS — a NET-NEW haid only (idempotent/conflict/switch already returned above).
    #      PER-TEAM first (bounds how much one secret can bloat its team), then the GLOBAL
    #      registry ceiling (bounds total growth regardless of rate / key-IP rotation).
    if cp_auth.team_member_count(team_id, home=home) >= team_max_members():
        return {"ok": False, "reason": "team_full"}
    if _registry_key_count(home) >= enroll_max_keys():
        return {"ok": False, "reason": "enroll_registry_full"}

    # 7. Register the NEW binding. Enrolled devs are NOT owners (owner is the server identity,
    #    cp_auth.ensure_server_identity); a self-enroll — token OR open — never grants
    #    gate-override authority (owner=False is re-asserted here, unconditionally). Stamp
    #    enrolled_at (epoch) so the registry-hygiene job (cost-governance §3) can bound a
    #    NEVER-beating identity: an enrolled key that never produces a beat is still evicted once
    #    its enrolled_at ages past the idle window (bounded registry growth forever).
    import time as _time  # stdlib — the enroll timestamp for the hygiene idle window.
    if not cp_auth.register_key(haid, pubkey, owner=False, team_id=team_id,
                                project=project, enrolled_at=int(_time.time()), home=home):
        return {"ok": False, "reason": "registry_write_failed"}
    return {"ok": True, "haid": haid, "team_id": team_id}


# The reason-code -> HTTP status map. Token/auth refusals are 401, a key conflict is 409, a
# bad request body is 422, a missing server secret is 403 (the route exists but is disabled), a
# full registry is 429 (a load/capacity refusal — back off, the registry-growth ceiling is hit),
# a registry IO failure is 500. Success is 200. The body is content-free beyond {ok, haid} /
# {ok, reason} — no secret, ever.
_STATUS_BY_REASON = {
    "enroll_disabled": 403,
    "enroll_disabled_cloud_profile": 403,
    "bad_enroll_token": 401,
    "malformed": 422,
    "invalid_pubkey": 422,
    "haid_pubkey_conflict": 409,
    "team_secret_weak": 422,
    "team_required": 422,
    "team_frozen": 429,
    "team_full": 429,
    "enroll_registry_full": 429,
    "registry_write_failed": 500,
}


def _parse_body(request):
    """Extract the JSON body dict from a request. The wire body is a JSON object carrying
    {haid, pubkey, handle?, enroll_token?}. Tolerant — a malformed/empty/non-object body
    yields {} (the core then refuses as malformed), never a crash. Recognizes NOTHING
    executable (no action_type/handler key is honored — DATA only)."""
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


def _presented_token(request, payload):
    """Resolve the caller-presented bootstrap token: the header (lifted by cp_server into
    request["enroll_token"]) wins, else the body field. Returns None when neither is present.
    NEVER logged — only handed to the constant-time comparator."""
    if isinstance(request, dict):
        header_tok = request.get("enroll_token")
        if header_tok:
            return header_tok
    if isinstance(payload, dict):
        body_tok = payload.get(ENROLL_TOKEN_BODY_FIELD)
        if body_tok:
            return body_tok
    return None


def _presented_team_secret(request, payload):
    """Resolve the caller-presented TEAM secret: the header (lifted by cp_server into
    request["team_secret"]) wins, else the body field. Returns None when neither is present
    (the core then maps to the default team or fails closed). NEVER logged/echoed — it is
    hashed to team_id and discarded inside enroll()."""
    if isinstance(request, dict):
        header_sec = request.get("team_secret")
        if header_sec:
            return header_sec
    if isinstance(payload, dict):
        body_sec = payload.get(TEAM_SECRET_BODY_FIELD)
        if body_sec:
            return body_sec
    return None


def enroll_route(request, *, home=None):
    """POST /enroll — the PRE-AUTH self-enroll handler (served BEFORE the §3 chokepoint; the
    caller has no registered key to sign with yet). `request` is the cp_server request dict;
    the body is JSON {haid, pubkey, handle?, project?, enroll_token?, team_secret?} and the
    bootstrap token / team secret may instead ride the X-Heimdall-Enroll-Token /
    X-Heimdall-Team-Secret headers. Runs the gated enroll() core and maps its reason to an
    HTTP status. The body is ONLY {ok, haid, team_id} on success / {ok:false, reason} on
    refusal — never the server secret, the team secret, or the PKI key. DATA only — dispatches
    nothing."""
    payload = _parse_body(request)
    result = enroll(
        payload.get("haid"),
        payload.get("pubkey"),
        provided_token=_presented_token(request, payload),
        team_secret=_presented_team_secret(request, payload),
        handle=payload.get("handle"),
        project=payload.get("project"),
        home=home,
    )
    if result.get("ok"):
        return cp_server.Response(
            200, {"ok": True, "haid": result.get("haid"),
                  "team_id": result.get("team_id")})
    reason = result.get("reason", "refused")
    status = _STATUS_BY_REASON.get(reason, 400)
    return cp_server.Response(status, {"ok": False, "reason": reason})


def register(*, home=None):
    """Wire POST /enroll into cp_server's PUBLIC (pre-auth) registration seam — served BEFORE
    the §3 auth chokepoint because the enrolling dev has no key to sign with yet. The handler
    closes over the runtime `home` so a self-host deployment / a test pins its registry root.
    Returns the registered (method, path) keys. Idempotent — re-registering replaces the route.
    Mirrors cp_diag's pre-auth health registration; carries its OWN bootstrap-token gate."""
    keys = []
    keys.append(cp_server.register_public_route(
        "POST", "/enroll",
        lambda request: enroll_route(request, home=home)))
    return keys
