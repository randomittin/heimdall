#!/usr/bin/env python3
# cp_publicsurface.py — THE PUBLIC-SURFACE BOUNDARY of the Heimdall control plane.
#
# WHY THIS EXISTS (the trust story of the whole team-presence feature). The control plane
# image serves TWO Cloud Run services from ONE binary (deploy/cloud-run/deploy-public-
# surface.sh): the IAM-gated `heimdall-control-plane` (--no-allow-unauthenticated, the FULL
# dispatch/jobs/approval/owner/audit/scheduler surface) and the PUBLIC `heimdall-cp-public`
# (--allow-unauthenticated). The public service is reachable by ANYONE on the internet, so
# the GFE/IAM layer no longer rejects anonymous callers — the APP LAYER is the only boundary
# left. This module IS that boundary, in two parts:
#
#   1. THE ALLOWLIST — PUBLIC_ROUTES is the SINGLE SOURCE OF TRUTH for which (method, path)
#      pairs the public surface serves. When public_surface_enabled() (env HEIMDALL_PUBLIC_
#      SURFACE truthy), cp_server's router serves ONLY these and returns a FLAT 404 for EVERY
#      other route — at the ROUTING LAYER, BEFORE auth, BEFORE any handler, BEFORE any param
#      parse. A gated route (dispatch/jobs/owner/...) is therefore INDISTINGUISHABLE from a
#      nonexistent one on the public surface: no 401/403 that would reveal it exists, a flat
#      404. This set MUST stay byte-identical to deploy/cloud-run (check-public-surface.sh
#      asserts the parity); see PUBLIC_ROUTES below.
#
#   2. THE ABUSE GATES — on the unauthenticated surface a leaked bootstrap token or a raw
#      flood is the threat, so the public-surface serving path layers the shipped substrate
#      gates over the public routes (cp_ratelimit + cp_nonce), WITHOUT touching the handlers
#      (they are shared with the gated service and stay byte-for-byte unchanged):
#        • /enroll   — rate-limit per client-IP AND per-(enroll-token-hash) + a deployment-
#          wide enroll_budget ceiling on new enrollments/window. Over-limit -> 429.
#        • /presence — rate-limit per-IP (applied BEFORE signature verify, to shed blunt
#          floods cheaply) AND per-haid (after identity is known); plus a replay-nonce check
#          (after signature verify) over the {nonce, ts} the signed beat body carries.
#
# THE CONTRACT WITH cp_server (no import cycle). cp_server imports THIS module (for the
# boundary check + the gates); this module NEVER imports cp_server. The gate functions
# therefore return either None (allow — let the normal flow proceed) or a (status, body)
# tuple (refuse), and cp_server wraps the tuple in its Response. This keeps the dependency
# one-way (cp_server -> cp_publicsurface -> cp_ratelimit/cp_nonce -> cp_state) so importing
# either module never deadlocks.
#
# DEFAULT (flag unset) = a pure no-op. public_surface_enabled() is False, so cp_server never
# calls the boundary 404 nor the gates: the IAM-gated service is byte-for-byte as today.
#
# stdlib-only (json/os/sys) + cp_ratelimit + cp_nonce (the shipped abuse-gate substrate) —
# the SAME dependency shape every CP piece has, no third-party dep, self-hostable.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth       # derive_team_id / default_team_id / team_member_count — the team-scoped
                    # enroll re-key + the net-new-team detection for the team-create caps; AND
                    # registered_team — the server-side team_id for the signed /rr-task enqueue.
import cp_nonce      # the replay/freshness gate for the signed presence beat + /rr-task (accept()).
import cp_ratelimit  # the fixed-window abuse gate (RateLimiter.allow + enroll_budget_ok).
import cp_team_queue  # the ENQUEUE-ONLY sink for the public /rr-task route (INV-6). This module
                     # holds NO credential and NO dispatch capability — a signed /rr-task writes
                     # a bounded, scrubbed row to the CALLER'S OWN team partition and STOPS; the
                     # gated worker (cp_maintainer_runner) is the only side that dispatches.

# ── THE CANONICAL PUBLIC ROUTE SET (single source of truth) ─────────────────────────────
#
# The SIGNED + health route set below mirrors deploy/cloud-run/deploy-public-surface.sh's
# PUBLIC_SURFACE_ROUTES and README.md's split section (check-public-surface.sh asserts that
# canonical string). Each entry is (METHOD, query-stripped path). When public_surface_enabled(),
# these are the ONLY routes cp_server serves; everything else is a flat 404 at the routing layer.
#   POST /enroll    — token-gated PKI bootstrap (pre-auth; cp_enroll).
#   POST /presence  — the signed heartbeat (cp_presence; rate-limited + replay-checked here).
#   GET  /roster    — the online-team read (cp_presence; signed, a read so no nonce).
#   GET  /healthz   — the Cloud Run liveness probe (pre-auth; cp_diag).
#   GET  /readyz    — the Cloud Run readiness probe (pre-auth; cp_diag).
#
# PLUS the TEAM-PRIVATE browser-read seam (app-layer only — NOT a signed/IAM route, so it is
# additive to the gcloud display string above; the static heimdall-site dashboard fetches it):
#   GET     /roster-team — the ONLINE roster for (project, team), authorized by the
#       X-Heimdall-Team-Secret HEADER (hashed -> team_id server-side); per-IP rate-limited +
#       CORS, FULL member view incl. haid. No secret header -> 403. A browser cannot PKI-sign,
#       so the signed GET /roster 401s it; this is its read.
#   OPTIONS /roster-team — the CORS preflight (204 + CORS incl. Access-Control-Allow-Headers:
#       X-Heimdall-Team-Secret).
#   GET     /roster-public — RETIRED: the old fully-public roster leaked activity to anyone, so
#       it now 403s on the public surface (kept in the allowlist so it returns 403, not a flat
#       404 — the closed leak is explicit). team.html moved to /roster-team.
# PLUS the SIGNED ENQUEUE-ONLY write seam (INV-6, the public multi-tenant intake):
#   POST /rr-task — a SIGNED, team-scoped enqueue. It goes through the §3 auth chokepoint (a
#       signature is REQUIRED — it is NOT a pre-auth public route, so an unsigned/forged request
#       is a 401), the caller's team_id is derived SERVER-SIDE from the verified binding (INV-1),
#       and the handler writes ONE bounded, scrubbed DATA row to the CALLER'S OWN team queue and
#       STOPS. It holds NO credential and has NO dispatch capability — a compromised public
#       surface can enqueue (to its own partition, rate-/replay-capped) but never dispatch or read
#       a cred (INV-6, defeats A10). Execution happens on the gated worker, which holds the creds.
# All OTHER entries are READ-ONLY: there is deliberately no other unauthenticated write.
PUBLIC_ROUTES = frozenset({
    ("POST", "/enroll"),
    ("POST", "/presence"),
    ("POST", "/rr-task"),
    ("GET", "/roster"),
    ("GET", "/roster-team"),
    ("OPTIONS", "/roster-team"),
    ("GET", "/roster-public"),
    ("GET", "/healthz"),
    ("GET", "/readyz"),
})

# The env var that flips the surface from gated (full) to public (allowlist-only). Set to a
# truthy value by deploy-public-surface.sh (HEIMDALL_PUBLIC_SURFACE=1); unset on the gated
# service, so the gated surface is unchanged.
PUBLIC_SURFACE_ENV = "HEIMDALL_PUBLIC_SURFACE"

# The truthy spellings that ENABLE the public surface. Anything else (incl. unset / "" / "0"
# / "false") leaves the surface gated — fail-safe toward the FULL gated behavior is wrong on
# a public deploy, so the deploy sets an explicit "1"; this just tolerates common spellings.
_TRUTHY = {"1", "true", "yes", "on"}


# ── the rate-limit + replay policy (env-overridable; conservative defaults) ─────────────
#
# Each limit is `N units per WINDOW seconds`. The defaults are sized to the real cadence: a
# dev beats ~every 30s (2/min) and enrolls once ever, so the ceilings are generous for a
# legit dev while bounding a flood / a leaked-token churn. All overridable from the env so a
# deploy can tune without a code change.

def _int_env(name, default):
    """Read a positive integer from the env, falling back to `default` for unset / malformed
    / non-positive values (a misconfigured limit must never silently become a 0/negative hard
    gate; the explicit kill-switch is a deploy concern, not a typo)."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return default
    return val if val > 0 else default


# Open-enroll mode (HEIMDALL_ENROLL_OPEN truthy — cp_enroll.ENROLL_OPEN_ENV). When on, /enroll
# is TOKENLESS, so the per-(enroll-token) gate is moot (no token to key on) and the per-IP cap +
# the deployment-wide enroll_budget become the LOAD-BEARING limits. Read directly here (no
# cp_enroll import — this module stays handler-free) and used only to pick a TIGHTER per-IP
# default; both limits stay env-tunable. Mirrors public_surface_enabled()'s truthy parse.
_ENROLL_OPEN_ENV = "HEIMDALL_ENROLL_OPEN"


def _enroll_open():
    """True iff HEIMDALL_ENROLL_OPEN is set truthy — the per-IP enroll cap then defaults TIGHTER
    (the load-bearing flood control on a tokenless surface). Unset -> the standard token-mode
    default. Env-tunable either way (an explicit HEIMDALL_ENROLL_IP_LIMIT always wins)."""
    raw = os.environ.get(_ENROLL_OPEN_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _TRUTHY


# /enroll — per-IP and per-(enroll-token-hash) blunt gates + the deployment-wide new-enroll
# ceiling. Enroll is a once-ever act, so even a generous per-key cap stops a flood. In OPEN mode
# the per-IP default is tightened (5 vs 10) because it is the load-bearing limit once the token
# gate is off; the enroll_budget is the deployment-wide ceiling that bounds total new enrolls
# regardless of how many IPs an attacker rotates through. All overridable from the env.
def _enroll_ip_limit():      return _int_env("HEIMDALL_ENROLL_IP_LIMIT", 5 if _enroll_open() else 10)
def _enroll_ip_window():     return _int_env("HEIMDALL_ENROLL_IP_WINDOW", 60)
def _enroll_token_limit():   return _int_env("HEIMDALL_ENROLL_TOKEN_LIMIT", 30)
def _enroll_token_window():  return _int_env("HEIMDALL_ENROLL_TOKEN_WINDOW", 60)
def _enroll_budget_max():    return _int_env("HEIMDALL_ENROLL_BUDGET_MAX", 50)
def _enroll_budget_window(): return _int_env("HEIMDALL_ENROLL_BUDGET_WINDOW", 3600)
# /enroll PER-TEAM bucket (re-keyed on the derived team_id, not the deprecated bootstrap token):
# a single (possibly leaked) team_secret cannot hammer /enroll even rotating IPs. Same limits as
# the per-token bucket; team_id is already a hash, re-hashed by cp_ratelimit before it is a key.
def _enroll_team_limit():    return _int_env("HEIMDALL_ENROLL_TEAM_LIMIT", 30)
def _enroll_team_window():   return _int_env("HEIMDALL_ENROLL_TEAM_WINDOW", 60)
# TEAM-CREATE caps (Risk 5b — unbounded team creation on the open edge). A net-new team_id (no
# existing member/record) counts against BOTH a per-IP create bucket AND a deployment-wide
# distinct-team ceiling, so an attacker rotating fresh secrets cannot explode the store/registry.
def _team_create_ip_limit():     return _int_env("HEIMDALL_TEAM_CREATE_IP_LIMIT", 5)
def _team_create_ip_window():    return _int_env("HEIMDALL_TEAM_CREATE_IP_WINDOW", 3600)
def _team_create_budget_max():   return _int_env("HEIMDALL_TEAM_CREATE_BUDGET_MAX", 50)
def _team_create_budget_window():return _int_env("HEIMDALL_TEAM_CREATE_BUDGET_WINDOW", 3600)

# /presence — per-IP (pre-verify, blunt flood shed) and per-haid (post-verify) caps. A dev
# beats ~2/min; behind a corporate NAT many devs share one IP, so the per-IP cap is loose and
# the per-haid cap is the tight one.
def _presence_ip_limit():     return _int_env("HEIMDALL_PRESENCE_IP_LIMIT", 120)
def _presence_ip_window():    return _int_env("HEIMDALL_PRESENCE_IP_WINDOW", 60)
def _presence_haid_limit():   return _int_env("HEIMDALL_PRESENCE_HAID_LIMIT", 30)
def _presence_haid_window():  return _int_env("HEIMDALL_PRESENCE_HAID_WINDOW", 60)

# The replay-nonce freshness window for a signed beat (cp_nonce.accept). 300s gives generous
# clock-skew slack while bounding a captured beat's replay life to 5 minutes.
def _presence_nonce_window(): return _int_env("HEIMDALL_PRESENCE_NONCE_WINDOW", 300)

# /roster-public — the UNAUTHENTICATED browser read. A blunt per-IP cap sheds a scrape flood;
# 60/min is generous for a dashboard polling every few seconds while bounding abuse. The read
# is cheap and exposes only the already-public online roster, and there is NO identity on this
# surface to key on — so one loose per-IP gate is the whole policy. Env-tunable.
def _roster_read_limit():  return _int_env("HEIMDALL_ROSTER_IP_LIMIT", 60)
def _roster_read_window(): return _int_env("HEIMDALL_ROSTER_IP_WINDOW", 60)

# /rr-task — the SIGNED enqueue write (INV-6/7/8). Per-IP (pre-verify blunt flood shed) AND
# per-TEAM (post-verify, keyed on the caller's server-derived team_id) fixed-window caps bound a
# single tenant's enqueue rate (INV-7), plus a replay-nonce over the signed body (INV-8). All
# env-tunable; conservative defaults sized for a human/bot filing tasks, not a flood.
def _rr_task_ip_limit():     return _int_env("HEIMDALL_RR_TASK_IP_LIMIT", 60)
def _rr_task_ip_window():    return _int_env("HEIMDALL_RR_TASK_IP_WINDOW", 60)
def _rr_task_team_limit():   return _int_env("HEIMDALL_RR_TASK_TEAM_LIMIT", 30)
def _rr_task_team_window():  return _int_env("HEIMDALL_RR_TASK_TEAM_WINDOW", 60)
def _rr_task_nonce_window(): return _int_env("HEIMDALL_RR_TASK_NONCE_WINDOW", 300)


# ── the public-surface predicates (what cp_server's router consults) ────────────────────


def public_surface_enabled(env=None):
    """True iff HEIMDALL_PUBLIC_SURFACE is set truthy — this instance serves the PUBLIC
    allowlist surface (enroll/presence/roster/health) and 404s every gated route. `env` is
    the environment mapping (defaults to os.environ) so a test can probe without mutating the
    process. Unset / "" / "0" / "false" -> False (the gated full surface, unchanged)."""
    e = env if env is not None else os.environ
    raw = e.get(PUBLIC_SURFACE_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _TRUTHY


def is_public_route(method, path):
    """True iff (METHOD, path) is in the public allowlist. `path` MUST be the query-STRIPPED
    route path (cp_server matches on route_path, so GET /roster?project=<p> resolves the
    "/roster" route). The check is exact — a gated route is never public."""
    return ((method or "").upper(), path or "") in PUBLIC_ROUTES


# ── client-IP resolution (documented source) ────────────────────────────────────────────


def client_ip(request):
    """Resolve the calling client's IP for rate-limit keying. THE SOURCE, in order:
      1. The FIRST hop of the X-Forwarded-For header. On Cloud Run every request arrives via
         Google's front end, which appends the caller's address to X-Forwarded-For; the FIRST
         comma-separated entry is the ORIGINAL client (later hops are Google's proxies). This
         is the address an attacker cannot trivially spoof past the GFE on the managed
         platform, so it is the right rate-limit key for the public service.
      2. The PEER address (request["peer_ip"], the TCP socket's remote address) when no
         X-Forwarded-For is present — the self-host / direct-connect case.
      3. "unknown" when neither resolves (an unattributed request still counts against a
         shared bucket, never escapes the limiter).
    cp_server populates request["x_forwarded_for"] (the raw header) and request["peer_ip"]
    (self.client_address[0]); this function owns the policy of choosing between them."""
    if isinstance(request, dict):
        xff = request.get("x_forwarded_for")
        if isinstance(xff, str) and xff.strip():
            first = xff.split(",")[0].strip()
            if first:
                return first
        peer = request.get("peer_ip")
        if isinstance(peer, str) and peer.strip():
            return peer.strip()
    return "unknown"


# ── body / token extraction (no cp_enroll/cp_presence import — parse the raw body here) ──


def _body_dict(request):
    """The JSON object body of a request, tolerant of bytes/str/empty/malformed (-> {}). The
    body was already signature-verified for /presence (the gates that read it run AFTER the §3
    chokepoint), and is the same body cp_enroll/cp_presence parse — we only read fields here,
    we never dispatch anything."""
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


def _enroll_token(request, payload):
    """The caller-presented bootstrap token, for the per-token rate-limit key: the header
    (cp_server lifts it into request["enroll_token"]) wins, else the body's enroll_token field,
    else "" (a tokenless attempt — all such share one bucket, capping tokenless floods). The
    token is handed to cp_ratelimit, which sha256-HASHES it before it touches the store, so the
    raw token is never written or logged (no-secret-by-construction)."""
    if isinstance(request, dict):
        header_tok = request.get("enroll_token")
        if header_tok:
            return str(header_tok)
    if isinstance(payload, dict):
        body_tok = payload.get("enroll_token")
        if body_tok:
            return str(body_tok)
    return ""


def _team_secret(request, payload):
    """The caller-presented TEAM secret (for the per-team enroll bucket + the team-create caps):
    the header (cp_server lifts it into request["team_secret"]) wins, else the body's team_secret
    field, else None (no secret -> the configured default team, or nothing to scope). The raw
    secret is NEVER stored/logged here — it is hashed to team_id by cp_auth.derive_team_id and
    only that non-secret handle (re-hashed again by cp_ratelimit) ever touches the limiter."""
    if isinstance(request, dict):
        header_sec = request.get("team_secret")
        if header_sec:
            return str(header_sec)
    if isinstance(payload, dict):
        body_sec = payload.get("team_secret")
        if body_sec:
            return str(body_sec)
    return None


# ── the abuse gates (return None to allow, or (status, body) to refuse) ─────────────────
#
# Each gate returns None when the request may proceed, or a (status:int, body:dict) tuple
# cp_server wraps in a Response. They are invoked ONLY when public_surface_enabled() — the
# gated service never runs them, so its handlers stay byte-for-byte unchanged.


def _rate_limited_body(scope, retry_after):
    """The refusal body for a 429. Carries retry_after (seconds until the window refreshes) so
    a client can back off; names the scope for an operator. Never echoes the IP/token/haid."""
    return {"error": "rate_limited", "scope": scope, "retry_after": int(retry_after)}


def check_enroll(request, *, home=None, now=None):
    """PUBLIC-SURFACE abuse gate for POST /enroll (pre-auth). Three fixed-window checks, all
    must pass; the first to refuse returns a 429 (NOTHING is enrolled):
      1. per-client-IP        — a single IP cannot hammer /enroll.
      2. per-(enroll-token)   — a single (leaked) bootstrap token cannot hammer /enroll, even
         rotating IPs (the token is hashed in the store; the raw value never lands there).
      3. enroll_budget        — a DEPLOYMENT-WIDE ceiling on new enrollments/window, so a
         leaked token cannot grow the key registry unbounded no matter how many IPs/HAIDs it
         rotates through. (Applied at the routing layer, this caps total enroll throughput per
         window; the cp_enroll core still owns idempotency/conflict/fail-closed-token.)
    Returns None to let the pre-auth enroll handler run, or (429, body) to refuse."""
    limiter = cp_ratelimit.RateLimiter(home=home)
    ip = client_ip(request)
    ok, retry = limiter.allow(
        "enroll_ip", ip, now=now, limit=_enroll_ip_limit(), window=_enroll_ip_window())
    if not ok:
        return (429, _rate_limited_body("enroll_ip", retry))

    payload = _body_dict(request)
    token = _enroll_token(request, payload)
    ok, retry = limiter.allow(
        "enroll_token", token, now=now,
        limit=_enroll_token_limit(), window=_enroll_token_window())
    if not ok:
        return (429, _rate_limited_body("enroll_token", retry))

    if not limiter.enroll_budget_ok(
            now=now, max_new=_enroll_budget_max(), window=_enroll_budget_window()):
        # The deployment-wide ceiling. retry_after is one budget window (the conservative
        # back-off when the global budget is spent).
        return (429, _rate_limited_body("enroll_budget", _enroll_budget_window()))

    # 4-5. TEAM-SCOPED gates (multi-tenant). The team_secret rides a header (cp_server lifts it
    #      to request["team_secret"]) or the body; we derive the NON-SECRET team_id and key on
    #      it — the raw secret never touches the limiter (team_id is already a hash, re-hashed by
    #      cp_ratelimit before it is a key). No secret -> the configured default team (back-compat);
    #      no secret AND no default -> enroll() fails team_required downstream, so there is nothing
    #      to scope and we skip the team gates here.
    secret = _team_secret(request, payload)
    team_id = cp_auth.derive_team_id(secret) if secret else cp_auth.default_team_id()
    if team_id:
        # 4. PER-TEAM bucket — a single (leaked) team_secret cannot hammer /enroll even rotating
        #    IPs (§3: re-key the per-token bucket on team_id, the durable partition handle).
        ok, retry = limiter.allow(
            "enroll_team", team_id, now=now,
            limit=_enroll_team_limit(), window=_enroll_team_window())
        if not ok:
            return (429, _rate_limited_body("enroll_team", retry))
        # 5. TEAM-CREATE caps (Risk 5b) — a NET-NEW team_id (no members/records yet) counts
        #    against a per-IP create bucket AND a deployment-wide distinct-team ceiling, so an
        #    attacker rotating fresh secrets cannot explode the registry/store. An EXISTING team
        #    (>=1 member) is exempt — only team CREATION is capped (team_member_count is the
        #    firestore-safe net-new signal). team_create_budget is a single global counter,
        #    mirroring enroll_budget_ok.
        if cp_auth.team_member_count(team_id, home=home) == 0:
            ok, retry = limiter.allow(
                "team_create_ip", ip, now=now,
                limit=_team_create_ip_limit(), window=_team_create_ip_window())
            if not ok:
                return (429, _rate_limited_body("team_create_ip", retry))
            ok, retry = limiter.allow(
                "team_create_budget", "global", now=now,
                limit=_team_create_budget_max(), window=_team_create_budget_window())
            if not ok:
                return (429, _rate_limited_body("team_create_budget", retry))
    return None


def check_presence_pre_auth(request, *, home=None, now=None):
    """PUBLIC-SURFACE per-IP flood gate for POST /presence, applied BEFORE the §3 signature
    verify so a blunt flood is shed CHEAPLY (no crypto spent on a request from an over-limit
    IP). Returns None to proceed to auth, or (429, body) to refuse. The per-haid cap +
    replay-nonce run AFTER identity is known (check_presence_post_auth)."""
    limiter = cp_ratelimit.RateLimiter(home=home)
    ip = client_ip(request)
    ok, retry = limiter.allow(
        "presence_ip", ip, now=now,
        limit=_presence_ip_limit(), window=_presence_ip_window())
    if not ok:
        return (429, _rate_limited_body("presence_ip", retry))
    return None


def check_presence_post_auth(identity, request, *, home=None, now=None):
    """PUBLIC-SURFACE gates for POST /presence that need the VERIFIED identity (run AFTER the
    §3 chokepoint, so `identity.haid` is proven and the body is signature-covered):
      1. per-haid rate-limit — the tight cap (a dev beats ~2/min); over-limit -> 429.
      2. replay-nonce        — the signed beat body carries {nonce, ts}; cp_nonce.accept
         decides freshness (|ts-now| <= window) + first-use ((haid, nonce) unseen). A stale
         ts or a replayed nonce -> 401 (auth_fail-shaped: the beat is not a live, first-use
         signed message). The (nonce, ts) ride INSIDE the signed body, so they are
         unforgeable — only replayable, which is exactly what this catches.
    Returns None to let the beat handler run, or (429, body) / (401, body) to refuse."""
    haid = getattr(identity, "haid", None) or identity
    limiter = cp_ratelimit.RateLimiter(home=home)
    ok, retry = limiter.allow(
        "presence_haid", str(haid), now=now,
        limit=_presence_haid_limit(), window=_presence_haid_window())
    if not ok:
        return (429, _rate_limited_body("presence_haid", retry))

    payload = _body_dict(request)
    nonce = payload.get("nonce")
    ts = payload.get("ts")
    accepted, reason = cp_nonce.accept(
        "presence", str(haid), nonce, ts, now=now, window=_presence_nonce_window())
    if not accepted:
        # A stale/replayed beat is not a live first-use signed message — refuse 401 (the same
        # status the §3 chokepoint uses for a beat that fails the freshness/first-use proof).
        return (401, {"error": "replay_" + reason})
    return None


def check_roster_read(request, *, home=None, now=None):
    """PUBLIC-SURFACE per-IP flood gate for the UNAUTHENTICATED GET /roster-public read. The
    browser dashboard cannot sign, so there is no identity to key on — a single per-IP fixed-
    window cap (scope "roster_read") is the whole gate; the read is cheap and exposes only the
    already-public online roster. Returns None to let the read proceed, or (429, body) to refuse.
    Reuses cp_ratelimit exactly like the enroll/presence gates (FAIL-OPEN on a backend hiccup —
    an abuse gate must never lock out a legit dashboard)."""
    limiter = cp_ratelimit.RateLimiter(home=home)
    ip = client_ip(request)
    ok, retry = limiter.allow(
        "roster_read", ip, now=now,
        limit=_roster_read_limit(), window=_roster_read_window())
    if not ok:
        return (429, _rate_limited_body("roster_read", retry))
    return None


# ── the SIGNED ENQUEUE-ONLY /rr-task route (INV-6/7/8 — the public multi-tenant intake) ──────
#
# THE INTAKE/EXECUTION SPLIT (INV-6). /rr-task is the ONLY public write beyond enroll/presence.
# It is SIGNED (the §3 chokepoint verifies the Ed25519 signature BEFORE these run — an
# unsigned/forged request is a 401, INV-8), its team_id is derived SERVER-SIDE from the verified
# binding (INV-1), and the handler writes ONE bounded, scrubbed DATA row to the CALLER'S OWN team
# queue and STOPS. This module holds NO credential and calls NO dispatcher — the enqueue sink is
# cp_team_queue.enqueue, nothing else. A compromised public surface can therefore enqueue (to its
# own partition, rate-/replay-capped) but can NEVER dispatch a job or read a cred (INV-6, A10).


def _rr_task_body(request):
    """The task DATA a signed /rr-task carries, as a bounded {text, severity?, priority?} dict
    (INV-5). The text is taken from the first present of `task`/`text`/`prompt`/`body`; the
    optional severity/priority ride through to the queue's prioritizer. This is DATA, never a
    free-form allowlist param — cp_team_queue.enqueue scrubs (secret-redacts) + trims it before
    persistence, so no secret and no oversized payload can ever land in a queue row."""
    payload = _body_dict(request)
    text = None
    for key in ("task", "text", "prompt", "body"):
        if payload.get(key) is not None:
            text = payload.get(key)
            break
    task = {"text": text}
    if payload.get("severity") is not None:
        task["severity"] = payload.get("severity")
    if payload.get("priority") is not None:
        task["priority"] = payload.get("priority")
    return task


def check_rr_task_pre_auth(request, *, home=None, now=None):
    """PUBLIC-SURFACE per-IP flood gate for POST /rr-task, applied BEFORE the §3 signature verify
    so a blunt flood is shed CHEAPLY (no crypto spent on an over-limit IP). Returns None to
    proceed to auth, or (429, body) to refuse. The per-team cap + replay-nonce run AFTER identity
    is known (check_rr_task_post_auth)."""
    limiter = cp_ratelimit.RateLimiter(home=home)
    ip = client_ip(request)
    ok, retry = limiter.allow(
        "rr_task_ip", ip, now=now,
        limit=_rr_task_ip_limit(), window=_rr_task_ip_window())
    if not ok:
        return (429, _rate_limited_body("rr_task_ip", retry))
    return None


def check_rr_task_post_auth(identity, request, *, home=None, now=None):
    """PUBLIC-SURFACE gates for POST /rr-task that need the VERIFIED identity (run AFTER the §3
    chokepoint, so `identity.haid` is proven and the body is signature-covered):
      1. per-TEAM rate-limit (INV-7) — keyed on the caller's SERVER-DERIVED team_id
         (cp_auth.registered_team), so a single tenant cannot flood the intake even rotating
         members/IPs; over-limit -> 429.
      2. replay-nonce (INV-8) — the signed body carries {nonce, ts}; cp_nonce.accept decides
         freshness (|ts-now| <= window) + first-use ((haid, nonce) unseen). A stale ts or a
         replayed nonce -> 401 (the captured signed bytes cannot be resent).
    Returns None to let the enqueue run, or (429, body) / (401, body) to refuse."""
    haid = getattr(identity, "haid", None) or identity
    team_id = cp_auth.registered_team(str(haid), home=home)
    # Key the per-team bucket on the team_id when it resolves, else on the haid (a no-team caller
    # still counts against a bucket — the enqueue itself fail-closes on the missing team).
    team_key = team_id if team_id else ("haid:" + str(haid))
    limiter = cp_ratelimit.RateLimiter(home=home)
    ok, retry = limiter.allow(
        "rr_task_team", team_key, now=now,
        limit=_rr_task_team_limit(), window=_rr_task_team_window())
    if not ok:
        return (429, _rate_limited_body("rr_task_team", retry))

    payload = _body_dict(request)
    nonce = payload.get("nonce")
    ts = payload.get("ts")
    accepted, reason = cp_nonce.accept(
        "rr-task", str(haid), nonce, ts, now=now, window=_rr_task_nonce_window())
    if not accepted:
        return (401, {"error": "replay_" + reason})
    return None


def enqueue_rr_task(identity, request, *, home=None, now=None):
    """THE enqueue-only handler for a signed POST /rr-task (INV-6/INV-1/INV-3/INV-5). Returns a
    (status, body) tuple cp_server wraps in a Response — NEVER a dispatch, NEVER a cred read.

    Flow:
      1. team_id = cp_auth.registered_team(identity.haid) — the caller's SERVER-DERIVED partition
         (INV-1). A body `team_id` field is IGNORED (it is never read here). No team resolves ->
         403 fail-closed (INV-3) — nothing is enqueued.
      2. cp_team_queue.enqueue(team_id, task) — the task is bounded + secret-scrubbed DATA (INV-5,
         enforced inside enqueue). It lands in EXACTLY the caller's OWN partition; there is no
         parameter by which it could reach another team's queue.
    The `now` arg is accepted for signature symmetry with the gates (unused here — enqueue stamps
    its own created_at)."""
    haid = getattr(identity, "haid", None) or identity
    team_id = cp_auth.registered_team(str(haid), home=home)   # INV-1 — server-derived, never the body.
    if not team_id:
        return (403, {"error": "no_team"})                    # INV-3 fail-closed.
    result = cp_team_queue.enqueue(team_id, _rr_task_body(request), home=home)
    if not result.get("ok"):
        return (422, {"error": result.get("reason", "enqueue_failed"), "team_id": team_id})
    return (200, {"enqueued": True, "id": result.get("id"),
                  "added": result.get("added"), "team_id": team_id})
    return None
