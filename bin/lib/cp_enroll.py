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


def enroll(haid, pubkey, *, provided_token, handle=None, home=None):
    """THE testable self-enroll core. Token-gate, validate, and idempotently bind haid->pubkey
    in the cp_auth registry. Returns a dict — {"ok": True, "haid": haid} on success, or
    {"ok": False, "reason": <code>} on a refusal. NO secret is ever in the returned dict.

    `handle` is accepted as optional client metadata (the dev's display name) for API/forward
    compatibility; the registry binds haid->pubkey only (its schema is owned by cp_auth), so
    handle is not persisted here — it is read and discarded, never echoed.

    The gate order (each a hard stop, fail-closed first):
      1-2. TOKEN GATE — enforced UNLESS open mode (enroll_open()) is enabled:
         1. enroll_disabled  — the SERVER verifier secret is unset. We refuse EVERY enroll and
            NEVER allow-all. The reason names the cloud profile so a deployed instance refused
            for a missing secret is distinguishable from a bad token.
         2. bad_enroll_token — the presented token is absent or does not match (constant-time).
         In OPEN mode both are SKIPPED (tokenless onboarding); a configured+presented token is
         still accepted (token mode is not broken), the gate is just not required. The registry
         cap (6.5) + the rate limits (cp_publicsurface) are the load-bearing controls there.
      3. malformed        — haid or pubkey is missing.
      4. invalid_pubkey   — pubkey is not base64 of a 32-byte Ed25519 key.
      5. haid_pubkey_conflict — haid is already registered to a DIFFERENT pubkey (409): a
         registered identity is never silently rebound, so neither a leaked token NOR an open
         enroll can hijack an already-enrolled dev.
      6. (idempotent) same haid + SAME pubkey -> ok without a rewrite (never hits the cap).
      6.5. enroll_registry_full — a NET-NEW haid is refused once the registry already holds
         enroll_max_keys() bindings. Bounds total registry GROWTH regardless of rate; only
         net-new keys count (idempotent/conflict already returned above).
      7. register the NEW binding through cp_auth.register_key (StateBackend seam, no path())."""
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

    # 5-6. Idempotency / conflict against the EXISTING binding (firestore-safe registry read).
    existing = cp_auth.registered_pubkey(haid, home=home)
    if existing is not None:
        if existing == pubkey:
            # Same key re-enroll: a harmless re-run, already bound. No rewrite — and never
            # blocked by the registry cap (an existing identity's re-enroll is always allowed).
            return {"ok": True, "haid": haid}
        # A DIFFERENT key for an already-registered haid — refuse (no silent rebind/hijack).
        return {"ok": False, "reason": "haid_pubkey_conflict"}

    # 6.5. THE HARD REGISTRY-SIZE CAP. Only a NET-NEW haid reaches here (idempotent + conflict
    #      already returned), so the cap NEVER blocks an existing identity's re-enroll — it bounds
    #      total registry GROWTH so an open/leaked enroll surface cannot grow the registry past
    #      enroll_max_keys(), regardless of rate or key/IP rotation.
    if _registry_key_count(home) >= enroll_max_keys():
        return {"ok": False, "reason": "enroll_registry_full"}

    # 7. Register the NEW binding. Enrolled devs are NOT owners (owner is the server identity,
    #    cp_auth.ensure_server_identity); a self-enroll — token OR open — never grants
    #    gate-override authority (owner=False is re-asserted here, unconditionally).
    if not cp_auth.register_key(haid, pubkey, owner=False, home=home):
        return {"ok": False, "reason": "registry_write_failed"}
    return {"ok": True, "haid": haid}


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


def enroll_route(request, *, home=None):
    """POST /enroll — the PRE-AUTH self-enroll handler (served BEFORE the §3 chokepoint; the
    caller has no registered key to sign with yet). `request` is the cp_server request dict;
    the body is JSON {haid, pubkey, handle?, enroll_token?} and the token may instead ride the
    X-Heimdall-Enroll-Token header. Runs the token-gated enroll() core and maps its reason to
    an HTTP status. The body is ONLY {ok, haid} on success / {ok:false, reason} on refusal —
    never the server secret, never the PKI key. DATA only — dispatches nothing."""
    payload = _parse_body(request)
    result = enroll(
        payload.get("haid"),
        payload.get("pubkey"),
        provided_token=_presented_token(request, payload),
        handle=payload.get("handle"),
        home=home,
    )
    if result.get("ok"):
        return cp_server.Response(200, {"ok": True, "haid": result.get("haid")})
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
