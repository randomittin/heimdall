#!/usr/bin/env python3
# cp_server.py — piece (a) of the Heimdall control plane: THE SERVER SKELETON.
#
# DESIGN DOSSIER §1/§2/§3/§9/§10 (authoritative). A stateless request router over
# python stdlib http (self-hostable, minimal deps). It wires the substrate together:
#
#   • THE AUTH CHOKEPOINT (§3) — every request passes through cp_auth.verify_identity
#     exactly once. Unsigned / bad-sig / unknown / revoked -> 401 + audit auth_fail.
#   • THE DISPATCH GATE (§1) — a dispatch passes through cp_allowlist.validate. An
#     unknown action_type or a command-smuggle attempt -> 422 + audit dispatch_refused,
#     runs NOTHING. A valid allowlisted dispatch -> the named handler runs in an
#     isolated context (§2). The server NEVER runs an arbitrary command.
#   • THE AUDIT (§9) — every dispatch, every refusal, every auth failure writes a row.
#   • THE REGISTRATION SEAM (§10) — pieces (b)-(f) plug ingest/schedule/job/approval/
#     notify route handlers in via register_route() WITHOUT editing this file. The
#     seam is how the wave-1 substrate stays disjoint from the wave-2 pieces.
#
# THE CONTROL/DATA-PLANE LINE (§2) — an `isolated` dispatch runs its handler against
# a cp_handlers.IsolatedContext (scrubbed env + per-job scratch + scoped token, no
# read of the PKI key / audit log). The server constructs the context; the worker
# (piece d) is the low-priv process that runs the handler inside it. The server
# NEVER opens a reverse channel into an instance to make it run something.
#
# TWO LAYERS, deliberately separated:
#   • dispatch(...) — a PURE, socket-free core: takes (identity, action_type, params)
#     and returns a structured Response (status + body + the audit it wrote). This is
#     the falsifiable-core surface the substrate test drives directly — no socket
#     needed to prove the allowlist refuses arbitrary commands.
#   • serve(...) — the stdlib http.server wrapper that authenticates a real request,
#     routes it (built-in /dispatch + the registered seam routes), and renders a
#     Response. b-f register their routes; the wrapper owns argv/socket only.
#
# THE INTERFACE pieces (b)-(f) BIND to (stable; they import, never edit):
#   register_route(method, path, fn)  — the registration seam (b-f plug routes in).
#   dispatch(identity, action_type, params, ...) -> Response  — the §1/§2/§9 core.
#   authenticate(request, ...) -> Identity                    — the §3 chokepoint wrap.
#   Response                          — the {status, body, audit_id} result shape.
#   make_context(...)                 — build a §2 IsolatedContext for a dispatch.
#
# stdlib-only (json/os/uuid/http.server) + the sibling cp_* substrate modules.

from __future__ import annotations

import json
import os
import sys
import tempfile
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist
import cp_audit
import cp_auth
import cp_handlers
import cp_publicsurface  # THE PUBLIC-SURFACE BOUNDARY (allowlist 404 + the enroll/presence
                         # abuse gates). One-way dependency: this module imports it; it never
                         # imports cp_server (the gates return (status, body) tuples we wrap).
import issue_queue  # REUSE heimdall_home() for the per-job scratch root.

# The control-plane version. The single source of truth for the server_version banner
# AND the version string the unauthenticated health probes (cp_diag) surface, so the
# two never drift. Non-sensitive by construction (it identifies the build, nothing else).
SERVER_VERSION = "1.0"

# Cloud Run injects the port to listen on via $PORT and expects the container to bind
# 0.0.0.0 (the spec, §A1). These are the fallbacks when neither an explicit value nor
# the env supplies one — 0.0.0.0:8080 is the Cloud Run convention.
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8080


# ── the Response shape (the structured result every entry returns — §1/§9) ─────


class Response:
    """A structured server result: an HTTP status, a JSON-able body, and the audit_id
    of the row this request wrote (or None). Socket-free so the dispatch core is
    testable without a server. status follows the dossier's mapping: 200 ok, 401
    auth fail, 422 refused dispatch, 500 handler error."""

    def __init__(self, status, body, *, audit_id=None, headers=None):
        self.status = status
        self.body = body
        self.audit_id = audit_id
        # Optional extra response headers (e.g. the CORS allow-origin the UNAUTHENTICATED public
        # browser read GET/OPTIONS /roster-public needs). A plain {name: value} dict; empty by
        # default so every existing Response is byte-identical on the wire.
        self.headers = dict(headers) if headers else {}

    def to_dict(self):
        return {"status": self.status, "body": self.body, "audit_id": self.audit_id}


# ── the registration seam (b-f plug routes in WITHOUT editing this file — §10) ─
#
# A route is keyed (METHOD, path) -> callable(identity, request) -> Response. The
# wave-1 substrate registers nothing here by default beyond the built-in /dispatch
# entry (which is handled directly in serve, not via the seam). Pieces (b)-(f)
# call register_route at import/wire time to add /ingest, /jobs, /approvals, etc.
# This is the disjointness mechanism: they extend the server without touching it.

_ROUTES = {}

# The PRE-AUTH (public) seam — routes served BEFORE the §3 auth chokepoint. The chokepoint
# 401s any unsigned request, but a few routes MUST answer unsigned: the health probes (cp_diag,
# special-cased pre-auth below) and ENROLLMENT (cp_enroll — a dev's FIRST run has NO registered
# key yet, so it cannot sign). A public route carries its OWN gate inside its handler (enroll's
# bootstrap token), so opting a path out of PKI is the explicit, introspectable act of
# registering it HERE. Public handlers take `fn(request) -> Response` — there is NO verified
# identity pre-auth. Kept disjoint from _ROUTES so a public handler is never invoked with the
# post-auth (identity, request) shape.
_PUBLIC_ROUTES = {}


def register_route(method, path, fn):
    """Register a route handler for (METHOD, path). `fn(identity, request) -> Response`
    receives the verified Identity (§3) and the parsed request dict. Pieces (b)-(f)
    call this to plug in their surfaces (ingest/schedule/jobs/approvals/notify)
    without editing cp_server. Returns the (method, path) key. Re-registering a key
    replaces it (a piece owns its own routes)."""
    key = ((method or "").upper(), path or "")
    if not key[0] or not key[1]:
        raise ValueError("register_route needs a method and a path")
    if not callable(fn):
        raise ValueError("route handler must be callable")
    _ROUTES[key] = fn
    return key


def register_public_route(method, path, fn):
    """Register a PRE-AUTH (public) route handler for (METHOD, path) — served BEFORE the §3
    auth chokepoint. `fn(request) -> Response` receives the parsed request dict ONLY (there is
    no verified identity pre-auth). Use this ONLY for a route that cannot be PKI-signed (the
    caller has no registered key yet — enrollment) AND that carries its OWN gate inside the
    handler (a bootstrap token). The key is recorded so registered_routes() reflects it (the
    surface stays honest). Returns the (method, path) key. Re-registering replaces it."""
    key = ((method or "").upper(), path or "")
    if not key[0] or not key[1]:
        raise ValueError("register_public_route needs a method and a path")
    if not callable(fn):
        raise ValueError("route handler must be callable")
    _PUBLIC_ROUTES[key] = fn
    return key


def registered_routes():
    """The sorted list of registered (method, path) route keys — for status/CLI. Includes
    both the authenticated seam routes and the pre-auth public routes."""
    return sorted(set(_ROUTES.keys()) | set(_PUBLIC_ROUTES.keys()))


def _route(method, path):
    return _ROUTES.get(((method or "").upper(), path or ""))


def _public_route(method, path):
    return _PUBLIC_ROUTES.get(((method or "").upper(), path or ""))


# ── the §2 isolated-context builder ────────────────────────────────────────────


def _scratch_base(home):
    """The directory the per-job scratch tree roots under. An EXPLICIT `home` (or a
    set HEIMDALL_HOME, which issue_queue.heimdall_home() honors) ALWAYS wins —
    byte-identical to the historical path, so the prod config (HEIMDALL_HOME=/app/state)
    is unchanged.

    THE HARDENING: when NEITHER is supplied, issue_queue.heimdall_home() falls back to
    <repo>/.heimdall — a path that on a Cloud Run Job is the READ-ONLY container rootfs.
    os.makedirs against it raises PermissionError, run_job re-raises, and the run-job
    entrypoint exits 1 with the job stuck `running`. The scratch is ephemeral per-
    execution anyway, so with no home/HEIMDALL_HOME we root it under a GUARANTEED-
    writable temp base (tempfile.gettempdir()/heimdall-scratch) instead. This only
    changes behavior when home is absent — the configured path never moves."""
    if home:
        return home
    if os.environ.get("HEIMDALL_HOME"):
        return issue_queue.heimdall_home()
    return os.path.join(tempfile.gettempdir(), "heimdall-scratch")


def make_context(action_id, *, home=None, base_env=None):
    """Build a §2 IsolatedContext for one isolated dispatch: a per-job scratch dir
    under the runtime home's control-plane/scratch/<action_id>/ + a fresh scoped
    token. The context's scrubbed env + path-deny enforce the control/data-plane
    line; the worker (piece d) is the low-priv process that runs inside it.

    When no home/HEIMDALL_HOME is supplied the scratch base defaults to a guaranteed-
    writable temp dir (_scratch_base) so a Cloud Run Job whose home is absent does not
    hit the read-only rootfs — the scratch is ephemeral per-execution regardless."""
    base = _scratch_base(home)
    scratch = os.path.join(base, "control-plane", "scratch", action_id)
    os.makedirs(scratch, exist_ok=True)
    token = "jobtok-" + uuid.uuid4().hex
    return cp_handlers.IsolatedContext(scratch, token, base_env=base_env)


# ── the §3 auth chokepoint wrapper (audits an auth failure) ────────────────────


def authenticate(request, *, home=None, enforce_revocation=True):
    """Run the §3 auth chokepoint over a request dict, auditing a failure. Returns the
    verified Identity on success; on failure writes an audit auth_fail row and re-
    raises cp_auth.AuthError (the caller maps it to a 401 Response). The ONE place a
    request's identity is decided — the OIDC verifier swaps in behind cp_auth."""
    try:
        return cp_auth.verify_identity(
            request, home=home, enforce_revocation=enforce_revocation)
    except cp_auth.AuthError as err:
        cp_audit.write(
            "auth_fail",
            actor_haid=request.get("haid") if isinstance(request, dict) else None,
            outcome="refused", detail=err.reason, home=home,
        )
        raise


# ── THE DISPATCH CORE (the falsifiable §1/§2/§9 surface — socket-free) ──────────


def dispatch(identity, action_type, params, *, home=None, approved=False,
             base_env=None):
    """THE dispatch core (§1/§2/§9). Given a verified `identity`, an `action_type`,
    and raw `params`, decide + run an allowlisted action. Returns a Response.

    The flow (each step a hard gate):
      1. cp_allowlist.validate(action_type, params) — an unknown action_type OR a
         command-smuggle attempt (extra/off-pattern param) raises RefusedDispatch ->
         422 + audit dispatch_refused, runs NOTHING. THIS is the falsifiable core.
      2. requires_gate (§7): a gated action (run-suite) NOT yet `approved` is held
         at 422 (pending owner approval) + audited — it does not execute. (The
         approval queue piece (e) flips `approved`; wave-1 honors the flag.)
      3. isolated (§2): an isolated action runs its handler against a fresh
         IsolatedContext (scrubbed env + scratch + scoped token, no control-plane
         read). The server NEVER runs an arbitrary command — only a registered,
         named handler resolved from cp_handlers.HANDLERS.
      4. audit (§9): a successful dispatch writes a `dispatch` row (params-shape, no
         values); a handler error writes an error-outcome dispatch row -> 500.

    A breached caller can reach ONLY the N allowlisted handlers against the isolated
    env — the blast-radius wall. Pure of sockets; the substrate test drives it
    directly to prove arbitrary commands are refused."""
    actor = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    action_id = "act-" + uuid.uuid4().hex

    # 1. THE ALLOWLIST GATE — unknown action_type / command-smuggle -> 422 + audit.
    try:
        plan = cp_allowlist.validate(action_type, params)
    except cp_allowlist.RefusedDispatch as ref:
        audit_id = cp_audit.record_refusal(
            actor, action_type, reason=ref.reason, params=params,
            action_id=action_id, home=home,
        )
        return Response(
            422,
            {"refused": True, "reason": ref.reason, "action_id": action_id},
            audit_id=audit_id,
        )

    # 2. THE GATE (§7) — a requires_gate action needs an owner approval to run.
    if plan["requires_gate"] and not approved:
        audit_id = cp_audit.write(
            "approval", actor_haid=actor, action_type=action_type,
            action_id=action_id, decision=None, outcome="refused",
            params=plan["params"], detail="pending owner approval", home=home,
        )
        return Response(
            422,
            {"refused": True, "reason": "requires_approval",
             "action_id": action_id, "action_type": action_type},
            audit_id=audit_id,
        )

    # 3. RESOLVE the named handler (never code-from-the-wire) + run it in the §2
    #    isolated context. A handler ref that is not registered is refused.
    try:
        handler = cp_handlers.resolve(plan["handler"])
    except KeyError as err:
        audit_id = cp_audit.record_refusal(
            actor, action_type, reason="unregistered_handler",
            params=plan["params"], action_id=action_id, home=home,
        )
        return Response(
            422,
            {"refused": True, "reason": "unregistered_handler",
             "action_id": action_id},
            audit_id=audit_id,
        )

    ctx = make_context(action_id, home=home, base_env=base_env) if plan["isolated"] \
        else cp_handlers.IsolatedContext(
            os.path.join(issue_queue.heimdall_home() if not home else home,
                         "control-plane", "scratch", action_id),
            "jobtok-" + uuid.uuid4().hex, base_env=base_env)

    try:
        result = handler(plan["params"], ctx)
    except Exception as exc:  # noqa: BLE001 — a handler fault is a 500, audited.
        audit_id = cp_audit.write(
            "dispatch", actor_haid=actor, action_type=action_type,
            action_id=action_id, params=plan["params"], outcome="error",
            detail=type(exc).__name__, home=home,
        )
        return Response(
            500,
            {"error": "handler_error", "action_id": action_id},
            audit_id=audit_id,
        )

    # 4. AUDIT the accepted dispatch (params-shape only, never values — §9).
    audit_id = cp_audit.record_dispatch(
        actor, action_type, action_id=action_id, params=plan["params"],
        outcome="ok", home=home,
    )
    return Response(
        200,
        {"dispatched": True, "action_id": action_id, "action_type": action_type,
         "result": result},
        audit_id=audit_id,
    )


# ── the stdlib http wrapper (self-hostable; routes the substrate + the seam) ───


def _build_handler_class(home, enforce_revocation):
    """Build the BaseHTTPRequestHandler subclass bound to a runtime home. Defined as
    a factory so the home + revocation policy are closed over (the handler class API
    is fixed by stdlib, no instance-config hook). Handles the built-in POST /dispatch
    and routes everything else through the registration seam (b-f's routes)."""
    from http.server import BaseHTTPRequestHandler

    # Lazy import (cp_diag imports cp_server at module top — importing it here, at
    # serve-time inside the factory, avoids the import cycle while keeping the health
    # short-circuit available to every request the handler serves).
    import cp_diag

    class _CPHandler(BaseHTTPRequestHandler):
        server_version = "HeimdallControlPlane/" + SERVER_VERSION

        def log_message(self, fmt, *args):
            """Silence the default stderr access log (the audit log is the record)."""
            return

        def _read_body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                return b""
            return self.rfile.read(length)

        def _send(self, response):
            # A 204 (or an explicit None body) carries NO JSON payload — the no-content reply a
            # CORS preflight (OPTIONS /roster-public) returns. Everything else serializes JSON.
            if response.status == 204 or response.body is None:
                payload = b""
            else:
                payload = json.dumps(response.body).encode("utf-8")
            self.send_response(response.status)
            if payload:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            # Extra headers (CORS for the public browser read) — emitted verbatim. Empty for
            # every existing Response, so the gated/health/dispatch wire is unchanged.
            for name, value in response.headers.items():
                self.send_header(name, value)
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        def _request_dict(self, method, body_bytes):
            """Assemble the request dict the auth chokepoint verifies: the HAID +
            signature travel in headers, the canonical signed message is METHOD\\n
            PATH\\nBODY (cp_auth.canonical_message). `path` is the FULL self.path —
            INCLUDING any ?query — because that is exactly what the client signed
            (cp_auth.canonical_message signs the full path-with-query). The signature
            therefore covers the query and is tamper-evident.

            For handler convenience the request also carries a parsed `query` dict (the
            ?key=value pairs of self.path) so a handler can read e.g. job_id from the
            query WITHOUT re-parsing the path. ROUTING is a SEPARATE concern: _handle
            routes on the query-STRIPPED path (so "/jobs?job_id=X" still matches the
            "/jobs" route) while signing/verification + this dict keep the FULL path."""
            from urllib.parse import urlsplit, parse_qs
            split = urlsplit(self.path)
            # parse_qs -> {key: [v, ...]}; flatten to {key: first-value} for the handler.
            flat_query = {k: v[0] for k, v in parse_qs(split.query).items() if v}
            return {
                "method": method,
                # the FULL path-with-query AS TRANSMITTED — what the client signed.
                "path": self.path,
                # the path WITHOUT the ?query — what the router matches a route on.
                "route_path": split.path,
                # the parsed ?key=value pairs (first value each) for handlers.
                "query": flat_query,
                "body": body_bytes,
                "haid": self.headers.get("X-Heimdall-HAID"),
                "signature": self.headers.get("X-Heimdall-Signature"),
                # The bootstrap token a PRE-AUTH enroll caller may carry in a header (the body
                # field is the alternative). A normal signed request never sets it; the §3
                # chokepoint ignores it (verify_identity reads only haid/signature/method/
                # path/body), so lifting it here is inert for every authenticated route.
                "enroll_token": self.headers.get("X-Heimdall-Enroll-Token"),
                # The TEAM secret a caller may carry in a header — the bearer capability that
                # scopes a team (cp_enroll derives team_id at enroll; cp_presence derives it for
                # the browser /roster-team read). Kept in a HEADER (not the URL query) so it is
                # never written to access logs / Referer / history (Risk 2). A normal signed
                # request never sets it; the §3 chokepoint ignores it, so lifting it is inert
                # for every authenticated route.
                "team_secret": self.headers.get("X-Heimdall-Team-Secret"),
                # The rate-limit IP source for the PUBLIC surface (cp_publicsurface.client_ip
                # owns the policy of choosing between them). x_forwarded_for is the raw header
                # — on Cloud Run the GFE appends the caller, FIRST hop is the original client;
                # peer_ip is the TCP socket's remote address (the self-host/direct case). Both
                # are inert on the gated surface (the gates only run when public-surface-on).
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "peer_ip": (self.client_address[0]
                            if getattr(self, "client_address", None) else None),
            }

        def _handle(self, method):
            body = self._read_body()
            request = self._request_dict(method, body)
            # The path the ROUTER matches on: the request path WITHOUT any ?query, so a
            # GFE-safe GET /jobs?job_id=<id> still resolves the "/jobs" route. The
            # SIGNATURE (authenticate, below) verifies over the FULL self.path-with-query
            # in `request["path"]` — the two concerns are split deliberately.
            route_path = request["route_path"]
            # ── PUBLIC-SURFACE BOUNDARY (§public-surface) ── On the --allow-unauthenticated
            # public service (HEIMDALL_PUBLIC_SURFACE=1) ONLY the public allowlist exists:
            # every gated route (dispatch/jobs/approval/owner/audit/scheduler/…) returns a
            # FLAT 404 — indistinguishable from nonexistent — enforced HERE at the routing
            # layer, BEFORE health/public/auth, so a gated route never resolves, parses, or
            # authenticates on the public surface. Default (flag unset) = no-op (the gated
            # IAM service is byte-for-byte unchanged).
            if (cp_publicsurface.public_surface_enabled()
                    and not cp_publicsurface.is_public_route(method, route_path)):
                self._send(Response(404, {"error": "no_such_route"}))
                return
            # UNAUTHENTICATED health probes (§A) — answered BEFORE the auth chokepoint.
            # Cloud Run's liveness/readiness probes are issued by the platform, unsigned;
            # routing them through §3 would 401 every probe and the instance would never
            # go ready. cp_diag's bodies are content-free by construction (status +
            # version only), so serving them pre-auth leaks nothing.
            if cp_diag.is_health_path(method, route_path):
                self._send(cp_diag.handle(method, route_path, home=home))
                return
            # PRE-AUTH public routes (enrollment, §pki-bootstrap) — answered BEFORE the §3
            # chokepoint because the caller has NO registered key to sign with yet. A public
            # route carries its OWN gate inside the handler (enroll's bootstrap token); routing
            # it through §3 would 401 a legitimate first-run enroll. Matched on the query-
            # stripped path, like every other route; the handler takes (request) only.
            public = _public_route(method, route_path)
            if public is not None:
                # PUBLIC-SURFACE abuse gate for pre-auth enroll (per-IP + per-token + the
                # deployment-wide enroll budget): a leaked bootstrap token cannot flood
                # /enroll or grow the key registry unbounded. Inert on the gated surface.
                if (cp_publicsurface.public_surface_enabled()
                        and (method, route_path) == ("POST", "/enroll")):
                    refusal = cp_publicsurface.check_enroll(request, home=home)
                    if refusal is not None:
                        self._send(Response(*refusal))
                        return
                self._send(public(request))
                return
            # PUBLIC-SURFACE presence flood shed (pre-auth, cheap): drop an over-limit IP's
            # beat BEFORE spending crypto on signature verify. Inert on the gated surface.
            if (cp_publicsurface.public_surface_enabled()
                    and (method, route_path) == ("POST", "/presence")):
                refusal = cp_publicsurface.check_presence_pre_auth(request, home=home)
                if refusal is not None:
                    self._send(Response(*refusal))
                    return
            # §3 auth chokepoint — every request, exactly once. Verifies over the FULL
            # path-with-query (request["path"]) — the bytes the client signed.
            try:
                identity = authenticate(
                    request, home=home, enforce_revocation=enforce_revocation)
            except cp_auth.AuthError as err:
                self._send(Response(401, {"error": err.reason}))
                return
            # PUBLIC-SURFACE post-auth presence gates (need the VERIFIED haid): per-haid
            # rate-limit + replay-nonce over the signed beat body. Inert on the gated surface.
            if (cp_publicsurface.public_surface_enabled()
                    and (method, route_path) == ("POST", "/presence")):
                refusal = cp_publicsurface.check_presence_post_auth(
                    identity, request, home=home)
                if refusal is not None:
                    self._send(Response(*refusal))
                    return
            # built-in §1 dispatch entry (matched on the query-stripped path).
            if method == "POST" and route_path == "/dispatch":
                try:
                    payload = json.loads(body or b"{}")
                except (ValueError, TypeError):
                    self._send(Response(422, {"refused": True,
                                              "reason": "malformed_body"}))
                    return
                resp = dispatch(
                    identity, payload.get("action_type"),
                    payload.get("params"), home=home,
                    approved=bool(payload.get("approved")),
                )
                self._send(resp)
                return
            # the registration seam — b-f's routes (matched on the query-stripped path,
            # so GET /jobs?job_id=<id> resolves the "/jobs" route; the handler reads the
            # query via request["query"]).
            route = _route(method, route_path)
            if route is not None:
                self._send(route(identity, request))
                return
            self._send(Response(404, {"error": "no_such_route"}))

        def do_POST(self):
            self._handle("POST")

        def do_GET(self):
            self._handle("GET")

        def do_OPTIONS(self):
            # CORS preflight (OPTIONS /roster-public). Routed exactly like GET/POST: the public
            # boundary + the pre-auth public route seam answer it. A pre-auth public OPTIONS
            # handler returns 204 + the CORS headers a browser checks before the real GET.
            self._handle("OPTIONS")

    return _CPHandler


def resolve_bind(*, host=None, port=None, env=None):
    """Resolve the (host, port) to bind, honoring the Cloud Run contract (§A1). An
    EXPLICIT value always wins; when one is not given it falls back to the environment
    ($PORT — Cloud Run injects it; $HOST for self-host override) and finally to the
    0.0.0.0:8080 Cloud Run default. `env` is the environment mapping (defaults to
    os.environ) — passed explicitly so a test can resolve without mutating the process.

    The precedence, per axis: explicit arg > env var > module default. This is the ONE
    place the listen address is decided, so the container, the CLI, and a direct call
    all agree on it. A non-integer $PORT falls through to the default rather than
    crashing the boot (a malformed PORT must not take the instance down)."""
    e = env if env is not None else os.environ
    eff_host = host if host else (e.get("HOST") or DEFAULT_HOST)
    if port is not None:
        eff_port = int(port)
    else:
        raw = e.get("PORT")
        try:
            eff_port = int(raw) if raw not in (None, "") else DEFAULT_PORT
        except (TypeError, ValueError):
            eff_port = DEFAULT_PORT
    return eff_host, eff_port


def serve(host=None, port=None, *, home=None, enforce_revocation=True):
    """Start the stdlib http.server control plane (§10). Blocks, serving until
    interrupted. Authenticates every request (§3), routes the built-in /dispatch
    (§1) + the registered seam routes (b-f), audits (§9). Self-hostable: one process
    + a gitignored ${HEIMDALL_HOME}/control-plane/ state tree, no external DB.

    Binds per the Cloud Run contract (§A1): `host`/`port` default to None and resolve
    through resolve_bind — an explicit value wins, else $HOST/$PORT, else 0.0.0.0:8080.
    Cloud Run injects $PORT and requires a 0.0.0.0 bind; passing no host/port makes the
    container Just Work, while the test harness (which passes an explicit port) is
    unaffected. The two unauthenticated health probes (/healthz, /readyz — cp_diag) are
    answered pre-auth so the platform liveness/readiness checks reach them unsigned."""
    from http.server import HTTPServer

    host, port = resolve_bind(host=host, port=port)

    # ASSEMBLE the control plane (§10): plug every capability piece's routes into the
    # seam, re-drive orphaned jobs (§4 replay-on-boot), and start the per-minute
    # scheduler tick clock (§6). Without this the running server exposes ONLY the
    # built-in /dispatch — boot() is what makes /ingest, /dashboard, /schedules,
    # /jobs/*, /approvals/* and /notifications reachable over the wire.
    import cp_boot

    cp_boot.boot(home=home)

    handler_cls = _build_handler_class(home, enforce_revocation)
    httpd = HTTPServer((host, port), handler_cls)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown()
    finally:
        httpd.server_close()
    return 0
