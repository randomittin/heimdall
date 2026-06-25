#!/usr/bin/env python3
# cp_diag.py — the Cloud Run health probes for the Heimdall control plane.
#
# DEPLOY SPEC §A (Cloud Run). Cloud Run keeps an instance alive on a liveness probe
# and only routes traffic once a readiness probe says it is safe to serve. Those
# probes are issued by the platform, NOT by a signed Heimdall client — so they MUST
# be UNAUTHENTICATED (the §3 auth chokepoint would 401 an unsigned platform probe and
# the instance would never go ready). cp_server short-circuits these two paths BEFORE
# the chokepoint; this module owns what they answer.
#
# THE PRIVACY LINE (the same no-secret-by-construction discipline as the rest of the
# control plane): a health body carries ONLY status booleans + counts + the version
# string. NEVER a key, a token, a HAID, an audit row, a path, or any sensitive state.
# An unauthenticated endpoint that leaked any of those would be a hole; by construction
# the bodies here are built from a fixed, content-free key set.
#
#   • liveness()  -> a cheap 200 {status:"ok", version}. "Is the process alive?" — it
#     does no I/O, touches no store; if the interpreter can answer, it is alive.
#   • readiness(home) -> 200 {status:"ready", ...} ONLY when serving is safe: the §10
#     seam is wired (boot() ran -> routes registered) AND the state store is reachable
#     (the runtime home resolves + its audit dir is writable). Otherwise 503 not_ready.
#     Cloud Run holds traffic off an instance that 503s readiness — the instance is up
#     but not yet (or no longer) safe to receive requests.
#
# register(server, home) plugs both paths into the §10 seam so registered_routes()
# reflects them (status/CLI visibility) — idempotent, like every other piece. The
# ACTUAL serving bypasses the seam (it must run pre-auth); the seam entries make the
# surface introspectable and keep the assembly honest about what it exposes.
#
# stdlib-only (os) + the sibling cp_server/cp_audit/issue_queue substrate modules.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit
import cp_server
import issue_queue

# The fixed, UNAUTHENTICATED probe paths (Cloud Run liveness/readiness conventions).
LIVENESS_PATH = "/healthz"
READINESS_PATH = "/readyz"

# The control-plane version surfaced by the probes. The single source of truth lives in
# cp_server.SERVER_VERSION so the probe string and the server_version banner never drift.
# This is the ONLY identifying string a health body carries, non-sensitive by construction.
VERSION = cp_server.SERVER_VERSION

# The §10 seam wires a fixed set of capability routes (ingest/dashboard/schedules/
# jobs*/approvals*/notifications). A readiness check treats "the seam is wired" as the
# boot signal; we require at least this many NON-diag routes before declaring ready, so
# a server that imported cp_server but never ran boot() reads as not_ready.
_MIN_SEAM_ROUTES = 15


def liveness():
    """Liveness probe (§A): a cheap unauthenticated 200 carrying ONLY {status, version}.
    No store I/O, no seam read — if the interpreter can build this Response, the process
    is alive. Cloud Run restarts an instance whose liveness stops answering."""
    return cp_server.Response(200, {"status": "ok", "version": VERSION})


def _seam_booted():
    """True iff the §10 seam carries the full capability surface (boot() has run in this
    process). Diag's own routes are excluded from the count so registering them does not
    by itself flip the readiness signal."""
    diag_keys = {("GET", LIVENESS_PATH), ("GET", READINESS_PATH)}
    seam = [k for k in cp_server.registered_routes() if k not in diag_keys]
    return len(seam) >= _MIN_SEAM_ROUTES, len(cp_server.registered_routes())


def _stores_reachable(home=None):
    """True iff the durable state store is reachable: the runtime home resolves and the
    audit directory is present-or-creatable + writable. This is the cheapest honest
    proxy for "the control plane can persist" — if we cannot land an audit row we are
    not safe to serve. Any OSError -> not reachable (return False, never raise)."""
    try:
        base = home if home else issue_queue.heimdall_home()
        adir = cp_audit.audit_dir(home)
        os.makedirs(adir, exist_ok=True)
        return os.path.isdir(base) and os.access(adir, os.W_OK)
    except OSError:
        return False


def readiness(home=None):
    """Readiness probe (§A): 200 {status:"ready", ...} ONLY when serving is safe — the
    seam is wired (boot() ran) AND the state store is reachable. Otherwise 503 not_ready.
    The body is content-free: status + two booleans + the registered-route COUNT (a
    number, never the route strings) + version. Cloud Run withholds traffic from an
    instance that 503s here, so this is the gate between 'up' and 'serving'."""
    booted, route_count = _seam_booted()
    stores = _stores_reachable(home)
    ready = booted and stores
    body = {
        "status": "ready" if ready else "not_ready",
        "booted": booted,
        "routes_registered": route_count,
        "stores_reachable": stores,
        "version": VERSION,
    }
    return cp_server.Response(200 if ready else 503, body)


def is_health_path(method, path):
    """True iff (method, path) is one of the unauthenticated health probes. cp_server
    calls this in the request path to short-circuit BEFORE the §3 auth chokepoint —
    the platform probe is unsigned and must not be 401'd."""
    return (method or "").upper() == "GET" and path in (LIVENESS_PATH, READINESS_PATH)


def handle(method, path, *, home=None):
    """Answer a health probe, or return None if (method, path) is not one. cp_server
    routes the two probe paths here pre-auth; everything else stays on the authenticated
    path. Splitting dispatch out from is_health_path keeps the server's pre-auth branch
    a two-liner and keeps the path->Response mapping owned here."""
    if (method or "").upper() != "GET":
        return None
    if path == LIVENESS_PATH:
        return liveness()
    if path == READINESS_PATH:
        return readiness(home=home)
    return None


def register(server=cp_server, *, home=None):
    """Register the two health paths into the §10 seam so registered_routes() reflects
    them (status/CLI introspection) — idempotent, the seam replaces a key on re-register.
    The handlers wrap the home-aware probes so an introspective call routes correctly;
    the LIVE serving still bypasses the seam (it runs pre-auth in cp_server). Returns the
    registered route keys."""
    keys = [
        server.register_route("GET", LIVENESS_PATH, lambda identity, request: liveness()),
        server.register_route(
            "GET", READINESS_PATH,
            lambda identity, request: readiness(home=home)),
    ]
    return keys
