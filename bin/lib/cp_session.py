#!/usr/bin/env python3
# cp_session.py — DASHBOARD TEAM-LOGIN SESSIONS (Option B: local hmd + HAID + gh device-flow).
#
# WHY THIS EXISTS. The static runheimdall.dev dashboard must show a user EXACTLY the teams
# they are a proven member of — but a BROWSER cannot PKI-sign (the signed GET /roster 401s
# it), and pasting a raw team_secret into the page is XSS-exfiltratable. Option B
# (docs/analysis/dashboard-login-design.md) replaces the secret-paste with a self-hosted
# DEVICE FLOW that reuses the Ed25519 HAID key the machine already holds and the CP already
# verifies: the browser shows a code, the user runs `hmd dashboard login` locally, the local
# hmd signs a canonical assertion binding {gh_user ↔ HAID ↔ device_code} with the enrolled
# HAID key, the CP VERIFIES that signature, SERVER-DERIVES the caller's teams, mints a
# short-TTL CP-signed session token, and releases it to the polling browser. The browser then
# reads ONLY its own teams' rosters with that token — no secret ever enters the browser.
#
# THE SESSION IS A TEAM-READ CAPABILITY ONLY — never a dispatch, never owner, never
# cross-team. This module MUST pass INV-LOGIN (evals/oracles/rr-multitenant-isolation/
# INVARIANTS.md), whose falsifiable oracle is authored BEFORE these routes:
#
#   L1 — a read scopes to the session's SERVER-DERIVED teams (baked into the token at mint),
#        NEVER a body/query team_id. rosters_route reads payload["teams"] from the verified
#        TOKEN and never consults the request body/query for team scoping (the
#        `session-honors-body-team` mutant is the falsifier).
#   L2 — the team list is fixed SERVER-SIDE at mint from cp_auth.registered_team(haid) and
#        signed into the token. approve_route NEVER reads a `teams`/`team_id` from the body
#        (the `session-teams-from-client` mutant is the falsifier).
#   L3 — the token carries a short TTL (3600s); verify_token rejects a lapsed exp (-> 401 at
#        the read, before any roster is folded — the `skip-session-expiry` mutant falsifier).
#   L4 — the mint rides the §3 verify chokepoint: approve_route verifies the HAID signature
#        over the canonical assertion with cp_auth.verify (registered pubkey + revocation);
#        a bad/forged signature raises AuthError and NO session is minted or stored (the
#        `mint-skips-sig-verify` mutant falsifier).
#   L5 — a login session is ALWAYS owner=False. mint_token hard-codes owner=False and
#        verify_token refuses any token whose owner is not False; a session-derived Identity
#        therefore fails cp_approval._require_owner exactly like a non-owner key (the
#        `login-session-grants-owner` mutant falsifier). Owner authority stays rooted in
#        owner-PKI + IAP — it is never delegatable through a dashboard session.
#
# THE CP-SIGNED SESSION TOKEN. Minted + verified with the server's DETERMINISTIC Ed25519
# identity (cp_auth.load_signing_key from HEIMDALL_CP_PKI_KEY — the SAME key that already
# stabilizes the CP identity across Cloud Run instances). The token is
# base64url(canonical-json-payload) + "." + base64(sig); the payload embeds
# {haid, teams[], gh_user, exp, owner:false}. Tamper of any field breaks the CP signature;
# a lapsed exp is rejected. The seed lives in Secret Manager (never in the static site).
#
# DEPLOYED-SHAPE SAFE. The device-code store uses the StateBackend keyed-record primitives
# (put_record / get_record) only — never backend.path() (FirestoreBackend refuses it) — so
# the flow works identically on the local backend and under HEIMDALL_STATE_BACKEND=firestore
# in the deployed container. A missing/invalid CP signing seed FAILS LOUD (AuthError ->
# structured 500 at mint), never a silently-unsigned token.
#
# stdlib-only (base64/json/os/sys/time/uuid) + cp_auth (HAID verify + CP token crypto +
# registered_team) + cp_presence (the roster fold + member view) + cp_state (the store) +
# cp_server (the pre-auth public seam — a browser/CLI cannot ride the §3 chokepoint).

from __future__ import annotations

import base64
import json
import os
import re
import sys
import time
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth     # HAID signature verify (verify) + the CP token crypto (load_signing_key /
                   # sign / verify_raw) + registered_team (the SERVER-DERIVED team scope at mint).
import cp_presence  # the roster read fold + the member view (_team_view) + the presence store rel.
import cp_server   # REUSE register_public_route + Response — a browser (init/status/rosters) and a
                   # local hmd (approve) cannot PKI-sign the HTTP envelope, so these ride the pre-auth
                   # PUBLIC seam and carry their OWN gate (assertion signature / CP-signed token).
import cp_state    # the pluggable persistence backend for the device-code store (firestore-safe
                   # put_record / get_record only, never path()).

# ── policy constants (env-overridable) ─────────────────────────────────────────────────

# The session token TTL — 3600s (dashboard-login-design.md "Access TTL ~15–60 min"). A read
# past exp is rejected (L3). Short by design; refresh = re-run `hmd dashboard login`.
SESSION_TTL_SECONDS = 3600

# The device-code lifetime (how long a browser may poll before the code lapses) + the poll
# cadence the browser is told to use. The device code is not a capability (it only names a
# pending mint slot); the CAPABILITY is the CP-signed token released on approve.
DEVICE_CODE_TTL_SECONDS = 900
POLL_INTERVAL_SECONDS = 5

# The device-code store rel (under control-plane/): one keyed record per device_code.
_SESSION_REL = "dashboard-sessions"
_RECORD_SUFFIX = ".json"

# The canonical assertion domain tag the LOCAL hmd signs and the CP verifies (L4). The
# assertion binds {gh_user ↔ HAID ↔ device_code ↔ nonce}; the domain tag stops this signature
# aliasing any OTHER signed message in the system (the request canonical_message, an enroll,
# a beat). The `hmd dashboard login` CLI MUST build the byte-identical message (see
# assertion_message) or the mint 401s — this is the single source of truth for both sides.
_ASSERTION_DOMAIN = "heimdall-dashboard-login-v1"

# A device_code must be a bounded, filesystem-/firestore-safe token (we mint "dc-<hex>"); a
# client-presented value is validated against this so a crafted id can never escape the store
# dir or smuggle a path separator. Basename-guarded too (belt-and-suspenders).
_DEVICE_CODE_RX = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def _ttl_seconds():
    """The session TTL (HEIMDALL_DASHBOARD_SESSION_TTL_SECONDS, default 3600). A malformed /
    non-positive value falls back to the default so a misconfig never disables the TTL (L3)."""
    raw = os.environ.get("HEIMDALL_DASHBOARD_SESSION_TTL_SECONDS")
    if not raw:
        return SESSION_TTL_SECONDS
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return SESSION_TTL_SECONDS
    return val if val > 0 else SESSION_TTL_SECONDS


# ── the CP-signed session token (mint + verify) ────────────────────────────────────────


def _backend(home=None):
    """The StateBackend for the device-code store (HEIMDALL_STATE_BACKEND, default local).
    Firestore-safe keyed-record access only (put_record / get_record) — never path()."""
    return cp_state.get_backend(home=home)


def _cp_keypair():
    """The server's DETERMINISTIC Ed25519 (private_b64, public_b64) from the PKI seed
    (cp_auth.load_signing_key -> HEIMDALL_CP_PKI_KEY). RAISES cp_auth.AuthError when the seed
    is absent/invalid (fail-closed): the mint surfaces that as a structured 500 rather than a
    silently-unsigned token, and a verify surfaces it as an inability to verify (401)."""
    return cp_auth.load_signing_key()


def _canonical_payload(payload):
    """The canonical signed bytes of a token payload: compact, sorted-key JSON. Deterministic
    so mint and verify agree byte-for-byte (the CP signature covers exactly these bytes)."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _unb64url(txt):
    pad = "=" * (-len(txt) % 4)
    return base64.urlsafe_b64decode(txt + pad)


def mint_token(haid, teams, gh_user, *, ttl=None, now=None, exp=None):
    """Mint a CP-SIGNED session token for a verified HAID. Returns (token, payload).

    The payload is {haid, teams:[server-derived], gh_user, exp, owner:false}. `owner` is
    HARD-CODED False (L5 — a login session is never owner; owner authority is not delegatable
    through a dashboard session). `teams` is the SERVER-DERIVED team list the caller passes in
    (approve_route derives it from registered_team(haid) — it is NEVER a client field, L2).
    `exp` is now + ttl (default 3600s, L3). The token is base64url(payload) + "." + base64(sig),
    signed with the CP's deterministic key; any tamper breaks the signature. RAISES
    cp_auth.AuthError when the CP signing seed is unavailable (fail-closed — no unsigned token)."""
    now = time.time() if now is None else now
    ttl = _ttl_seconds() if ttl is None else ttl
    exp = int(now + ttl) if exp is None else int(exp)
    payload = {
        "haid": str(haid),
        "teams": sorted(str(t) for t in (teams or [])),
        "gh_user": str(gh_user),
        "exp": exp,
        "owner": False,   # L5 — ALWAYS false for a login session.
    }
    priv, _pub = _cp_keypair()
    msg = _canonical_payload(payload)
    sig = cp_auth.sign(priv, msg)
    return _b64url(msg) + "." + sig, payload


def verify_token(token, *, now=None):
    """Verify a CP-signed session token. Returns (payload, None) on a live, well-formed,
    owner=false token, or (None, reason) on any failure:
      malformed          — not a token / undecodable / non-canonical payload,
      bad_signature      — the CP signature does not verify (tampered),
      expired            — the short TTL has lapsed (L3),
      not_read_capability— owner is not False (defense-in-depth for L5),
      crypto_unavailable — the CP signing seed is unavailable (fail-closed).
    verify_raw over the EXACT signed bytes makes any field tamper a bad_signature; the
    canonical re-check pins the payload to its canonical form so no reordering is honored."""
    if not isinstance(token, str) or "." not in token:
        return None, "malformed"
    b64payload, _, sig = token.partition(".")
    if not b64payload or not sig:
        return None, "malformed"
    try:
        msg = _unb64url(b64payload)
        payload = json.loads(msg)
    except (ValueError, TypeError, base64.binascii.Error):
        return None, "malformed"
    if not isinstance(payload, dict) or _canonical_payload(payload) != msg:
        return None, "malformed"
    try:
        _priv, pub = _cp_keypair()
        ok = cp_auth.verify_raw(pub, msg, sig)
    except cp_auth.AuthError:
        return None, "crypto_unavailable"
    if not ok:
        return None, "bad_signature"
    if payload.get("owner") is not False:
        return None, "not_read_capability"   # L5 defense — a login token is never owner.
    if not isinstance(payload.get("teams"), list):
        return None, "malformed"
    now = time.time() if now is None else now
    exp = payload.get("exp")
    if not isinstance(exp, (int, float)) or isinstance(exp, bool) or exp <= now:
        return None, "expired"                # L3 — a lapsed session is rejected before any read.
    return payload, None


# ── the canonical HAID assertion the local hmd signs (L4) ──────────────────────────────


def assertion_message(haid, gh_user, device_code, nonce):
    """The canonical bytes the LOCAL hmd signs with the enrolled HAID key and the CP verifies
    at approve (L4). Domain-tagged so this signature can never alias any other signed message
    (the request envelope, an enroll, a beat). The `hmd dashboard login` CLI MUST produce the
    byte-identical message. Deterministic + unambiguous (newline-joined fixed fields)."""
    return ("\n".join([
        _ASSERTION_DOMAIN, str(haid), str(gh_user), str(device_code), str(nonce),
    ])).encode("utf-8")


# ── the device-code store (one keyed record per device_code) ───────────────────────────


def _valid_device_code(device_code):
    """True iff `device_code` is a bounded, path-safe token (no traversal, no separator)."""
    return (isinstance(device_code, str)
            and bool(_DEVICE_CODE_RX.match(device_code))
            and os.path.basename(device_code) == device_code)


def _session_rel(device_code):
    """The store-relative path of one device-code record: dashboard-sessions/<code>.json.
    Basename-guarded so a crafted code can never escape the store dir."""
    safe = os.path.basename(str(device_code))
    return os.path.join(_SESSION_REL, safe + _RECORD_SUFFIX)


def _store_session(device_code, record, *, home=None):
    return _backend(home).put_record(_session_rel(device_code), record)


def _load_session(device_code, *, home=None):
    if not _valid_device_code(device_code):
        return None
    return _backend(home).get_record(_session_rel(device_code))


# ── request-body / header helpers (no cp_publicsurface import — parse here) ─────────────


def _body_dict(request):
    """The JSON object body of a request, tolerant of bytes/str/empty/malformed (-> {})."""
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


def _query_value(request, key):
    """A query-string value (request['query'][key]), GFE-safe (a GET carries no body, so the
    device_code rides the ?query the CP signs/serves). Falls back to parsing the path's own
    ?query for a direct/in-process call. None when absent."""
    if isinstance(request, dict):
        q = request.get("query")
        if isinstance(q, dict) and q.get(key):
            return q.get(key)
        path = request.get("path")
        if isinstance(path, str) and "?" in path:
            from urllib.parse import urlsplit, parse_qs
            vals = parse_qs(urlsplit(path).query).get(key)
            if vals and vals[0]:
                return vals[0]
    return None


def _bearer_token(request):
    """The Bearer session token from the Authorization header (cp_server lifts it into
    request['authorization']). 'Bearer <token>' -> <token>; anything else -> None."""
    if not isinstance(request, dict):
        return None
    auth = request.get("authorization")
    if not isinstance(auth, str):
        return None
    auth = auth.strip()
    if auth.lower().startswith("bearer "):
        tok = auth[len("bearer "):].strip()
        return tok or None
    return None


# ── the route handlers (pre-auth public seam; each self-gated) ─────────────────────────


def init_route(request, *, home=None, now=None):
    """POST /dashboard/session/init — start a device flow. NO auth: the browser mints a
    pending device_code (a random slot id, NOT a capability) and is told the poll interval +
    expiry. Returns {device_code, interval, expires_in}. The browser shows the code + `hmd
    dashboard login`; the local hmd approves it; the browser polls /status for the token."""
    now = time.time() if now is None else now
    device_code = "dc-" + uuid.uuid4().hex
    record = {
        "status": "pending",
        "created_at": int(now),
        "expires_at": int(now + DEVICE_CODE_TTL_SECONDS),
    }
    if not _store_session(device_code, record, home=home):
        return cp_server.Response(500, {"error": "store_error"})
    return cp_server.Response(200, {
        "device_code": device_code,
        "interval": POLL_INTERVAL_SECONDS,
        "expires_in": DEVICE_CODE_TTL_SECONDS,
    })


def approve_route(request, *, home=None, now=None):
    """POST /dashboard/session/approve — the LOCAL hmd completes the device flow. Body:
    {haid, gh_user, device_code, nonce, sig}.

    Flow (each step a hard gate):
      1. L4 — VERIFY the HAID signature over assertion_message(haid, gh_user, device_code,
         nonce) with cp_auth.verify (the registered pubkey + revocation, the §3 chokepoint's
         verify). A bad/forged/unknown/revoked signature raises AuthError -> 401 and NO
         session is minted or stored (the device_code stays pending).
      2. L2 — teams = cp_auth.registered_team(haid) — SERVER-DERIVED from the verified enroll
         binding. A body `teams`/`team_id` is NEVER read: the tampered team never enters the
         session.
      3. L5/L3 — mint a CP-signed token embedding {haid, teams, gh_user, exp} with owner=false
         and a short TTL. Bind gh_user↔haid into the stored record and mark the device_code
         READY with the token. Returns {status:ready, exp}."""
    payload = _body_dict(request)
    haid = payload.get("haid")
    gh_user = payload.get("gh_user")
    device_code = payload.get("device_code")
    nonce = payload.get("nonce")
    sig = payload.get("sig")
    if not (haid and gh_user and device_code and nonce and sig):
        return cp_server.Response(400, {"error": "missing_field"})
    if not _valid_device_code(device_code):
        return cp_server.Response(400, {"error": "bad_device_code"})
    record = _load_session(device_code, home=home)
    if not isinstance(record, dict):
        return cp_server.Response(404, {"error": "unknown_device_code"})

    # 1. L4 — the HAID signature MUST verify or NO session is issued (verify_identity's verify).
    message = assertion_message(haid, gh_user, device_code, nonce)
    try:
        cp_auth.verify(str(haid), message, str(sig), home=home)
    except cp_auth.AuthError as err:
        # Bad signature -> DENY. Nothing is minted or stored; the device_code stays pending.
        return cp_server.Response(401, {"error": err.reason})

    # 2. L2 — the team scope is SERVER-DERIVED at mint; a body teams/team_id is IGNORED.
    team_id = cp_auth.registered_team(str(haid), home=home)
    teams = [team_id] if team_id else []

    # 3. L5/L3 — mint the CP-signed, owner=false, short-TTL token; a missing seed fails LOUD.
    try:
        token, tok = mint_token(str(haid), teams, str(gh_user), now=now)
    except cp_auth.AuthError as err:
        return cp_server.Response(500, {"error": "mint_unavailable", "detail": err.reason})

    ready = {
        "status": "ready",
        "token": token,
        "exp": tok["exp"],
        "haid": str(haid),      # bind gh_user ↔ haid into the record (non-secret).
        "gh_user": str(gh_user),
        "teams": teams,
    }
    if not _store_session(device_code, ready, home=home):
        return cp_server.Response(500, {"error": "store_error"})
    return cp_server.Response(200, {"status": "ready", "exp": tok["exp"]})


def status_route(request, *, home=None):
    """GET /dashboard/session/status?device_code=X — the browser polls until approved. Returns
    {status:pending} until the local hmd approves, then {status:ready, token, exp} ONCE. The
    token is released a single time (the record flips to 'consumed', dropping the token) so a
    replayed poll — or a device_code leaked to a log — cannot re-fetch the capability."""
    device_code = _query_value(request, "device_code")
    if not _valid_device_code(device_code):
        return cp_server.Response(400, {"status": "error", "error": "bad_device_code"})
    record = _load_session(device_code, home=home)
    if not isinstance(record, dict):
        return cp_server.Response(404, {"status": "unknown"})
    status = record.get("status")
    if status == "ready":
        # ONE-TIME release: drop the token from the record so it cannot be polled again.
        _store_session(device_code, {"status": "consumed", "exp": record.get("exp")},
                       home=home)
        return cp_server.Response(200, {
            "status": "ready", "token": record.get("token"), "exp": record.get("exp")})
    if status == "consumed":
        return cp_server.Response(200, {"status": "consumed"})
    return cp_server.Response(200, {"status": "pending"})


def rosters_route(request, *, home=None, now=None):
    """GET /dashboard/rosters, Authorization: Bearer <token> — the browser reads ONLY its
    OWN teams' rosters. The team list comes from the verified TOKEN (server-derived at mint),
    NEVER a body/query team_id (L1). An expired/tampered/absent token -> 401 (L3/bad-sig).

    Returns {teams:[{project, team_id, online:[member-view]}]} — one entry per (project,
    team) partition the token's teams appear in, folded through cp_presence.roster (the SAME
    read authority /roster-team uses). DEPLOYED-SHAPE SAFE: list_names + get_record only."""
    token = _bearer_token(request)
    if not token:
        return cp_server.Response(401, {"error": "missing_token"})
    payload, reason = verify_token(token, now=now)
    if payload is None:
        return cp_server.Response(401, {"error": reason})   # L3 expired / bad-sig / malformed.
    teams = payload.get("teams") or []      # L1 — from the TOKEN only, NEVER the request body/query.
    backend = _backend(home)
    projects = backend.list_names(cp_presence._PRESENCE_REL)
    out = []
    for team_id in teams:
        for project in projects:
            proj_rel = os.path.join(cp_presence._PRESENCE_REL, project)
            if team_id in backend.list_names(proj_rel):
                online = [cp_presence._team_view(v)
                          for v in cp_presence.roster(project, team_id, home=home)]
                out.append({"project": project, "team_id": team_id, "online": online})
    return cp_server.Response(200, {"teams": out})


def register(*, home=None):
    """Wire the four dashboard-login routes into cp_server's PRE-AUTH public seam (a browser
    and a local hmd cannot PKI-sign the HTTP envelope, so they cannot ride the §3 chokepoint;
    each route carries its OWN gate — the assertion signature at approve, the CP-signed token
    at rosters). NOTE: these are pre-auth PUBLIC routes and are served on the GATED control-
    plane service; to also serve them on the internet-facing --allow-unauthenticated public
    service, (POST,/dashboard/session/init), (POST,/dashboard/session/approve),
    (GET,/dashboard/session/status), (GET,/dashboard/rosters) must be added to
    cp_publicsurface.PUBLIC_ROUTES (owned by that module). The handlers close over the runtime
    `home`. Returns the registered (method, path) keys; idempotent (re-registering replaces)."""
    keys = []
    keys.append(cp_server.register_public_route(
        "POST", "/dashboard/session/init",
        lambda request: init_route(request, home=home)))
    keys.append(cp_server.register_public_route(
        "POST", "/dashboard/session/approve",
        lambda request: approve_route(request, home=home)))
    keys.append(cp_server.register_public_route(
        "GET", "/dashboard/session/status",
        lambda request: status_route(request, home=home)))
    keys.append(cp_server.register_public_route(
        "GET", "/dashboard/rosters",
        lambda request: rosters_route(request, home=home)))
    return keys
