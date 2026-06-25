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
#     seam is wired (boot() ran -> routes registered) AND the SELECTED state backend
#     (HEIMDALL_STATE_BACKEND) actually INITIALIZES — not just "the local audit dir is
#     writable", but "get_backend() returns a backend whose client can come up + serve a
#     trivial read". Otherwise 503 not_ready. Cloud Run holds traffic off an instance
#     that 503s readiness — the instance is up but not (yet) safe to receive requests.
#
# THE INCIDENT THIS GATES (why readiness probes the SELECTED backend's init, not just
# local disk). The control plane shipped to Cloud Run with HEIMDALL_STATE_BACKEND=
# firestore, but the Firestore backend could NOT initialize (a missing dep ->
# BackendUnavailable). Readiness only checked the local audit dir — which WAS writable —
# so /readyz returned 200, Cloud Run routed live traffic to a broken instance, and every
# 60s tick then errored. The fix: readiness now calls cp_state.get_backend() and forces a
# CHEAP, TIMEOUT-BOUNDED liveness op on the selected backend. If get_backend() or that op
# raises (BackendUnavailable / ImportError / missing ADC / wrong project) or hangs past a
# short timeout, /readyz is 503 {reason} — the broken-backend deploy is caught at the
# probe (traffic held) instead of silently serving and erroring forever.
#
# register(server, home) plugs both paths into the §10 seam so registered_routes()
# reflects them (status/CLI visibility) — idempotent, like every other piece. The
# ACTUAL serving bypasses the seam (it must run pre-auth); the seam entries make the
# surface introspectable and keep the assembly honest about what it exposes.
#
# stdlib-only (os/threading) + the sibling cp_server/cp_audit/cp_state/issue_queue
# substrate modules.

from __future__ import annotations

import os
import sys
import threading

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit
import cp_server
import cp_state
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

# The store-relative rel the backend liveness probe reads. It is a NON-EXISTENT path
# under a "health/" prefix so the probe never touches real store data and never mutates
# anything: a read-only liveness op. LocalBackend.read_lines on an absent file returns []
# cheaply (a stat, no IO); FirestoreBackend.read_lines forces the lazy
# google.cloud.firestore import + client build + a minimal ordered-query round-trip (an
# empty result for this rel) — exactly the init path that failed in the incident.
_BACKEND_PROBE_REL = "health/_readyz_probe.ndjson"

# How long the backend init+probe may take before readiness declares the backend
# unavailable. firestore.Client() construction can BLOCK on ADC / metadata-server lookups
# when credentials are absent (it does not fail fast), so the probe MUST be bounded or a
# misconfigured deploy would hang the readiness handler instead of 503-ing. 3s is long
# enough for a healthy Firestore round-trip yet short enough that Cloud Run's readiness
# probe (which retries) is not itself starved. A hard init failure (missing dep / no ADC)
# usually raises well inside this window; the timeout only catches the pathological hang.
_BACKEND_PROBE_TIMEOUT_S = 3.0

# Reason codes returned in a 503 body (content-free, never a message that could carry a
# path/cred). "backend_unavailable" — get_backend or the probe raised a known
# backend-init failure (BackendUnavailable / ImportError / credentials / any exception),
# OR the probe exceeded the timeout (a hung client build). "backend_init_failed" is a
# synonym kept for the timeout case so an operator can tell "raised" from "hung" apart
# without the body ever carrying the underlying exception text.
_REASON_BACKEND_UNAVAILABLE = "backend_unavailable"
_REASON_BACKEND_INIT_FAILED = "backend_init_failed"


def _selected_backend_name():
    """The SELECTED backend name (HEIMDALL_STATE_BACKEND, default 'local') — surfaced in
    the readiness body so an operator can see WHICH backend failed without the body ever
    carrying a cred/path. A bare lowercase token (e.g. 'firestore'), non-sensitive."""
    return (os.environ.get(cp_state.BACKEND_ENV) or cp_state.BACKEND_LOCAL).strip().lower()


def _run_backend_probe(home):
    """Construct the SELECTED backend and force a cheap, read-only liveness op that proves
    it can actually serve — get_backend() then read_lines() of a non-existent health rel.
    For LocalBackend this is a stat returning []; for FirestoreBackend it forces the lazy
    client build + a minimal round-trip (the init path that failed in the incident).

    Returns None on success, or a short reason code on failure. NEVER raises and NEVER
    returns the underlying exception text — the body must stay content-free. A swallowed
    backend (FirestoreBackend.read_lines catches Exception -> []) is handled by also
    forcing the init seam (_db()) when the backend exposes one, so a client that cannot
    build surfaces here instead of looking like an empty store."""
    try:
        backend = cp_state.get_backend(home=home)
    except Exception:  # noqa: BLE001 — BackendUnavailable/ValueError/ImportError -> 503.
        return _REASON_BACKEND_UNAVAILABLE
    try:
        # Force the backend's client to come up. FirestoreBackend.read_lines swallows
        # init failures (degrades to []), so a broken client would otherwise read as a
        # healthy empty store. If the backend exposes the init seam (_db), call it FIRST
        # so BackendUnavailable / ImportError / credentials errors propagate here; this is
        # the exact failure the incident hid. LocalBackend has no _db, so it goes straight
        # to the read-only probe below.
        db_init = getattr(backend, "_db", None)
        if callable(db_init):
            db_init()
        # The read-only liveness op (an absent rel -> [] on every backend). On Firestore
        # this is a minimal ordered-query round-trip that proves the client can talk to
        # the store, not just construct.
        backend.read_lines(_BACKEND_PROBE_REL)
        return None
    except Exception:  # noqa: BLE001 — any init/round-trip failure -> not ready (503).
        return _REASON_BACKEND_UNAVAILABLE


def _backend_ready(home=None):
    """Probe the SELECTED state backend's init under a hard timeout. Returns
    (ok: bool, reason: str|None, backend_name: str). ok=True only when get_backend() AND
    the cheap read-only op both succeed within _BACKEND_PROBE_TIMEOUT_S.

    THE FLAKE/TIMEOUT DISCIPLINE (the §2 deploy-spec choice, documented here). The probe
    runs in a DAEMON thread joined for a bounded time. firestore.Client() can BLOCK on
    ADC/metadata lookups when creds are missing — it does not fail fast — so without the
    timeout a misconfigured deploy would HANG /readyz instead of 503-ing. We fail CLOSED
    on the SELECTED backend's init: a hard init failure (missing dep / no ADC / wrong
    project) and a hung client build BOTH 503, because the incident is a PERMANENT failure
    and a silently-serving broken instance is worse than a deploy Cloud Run holds. We do
    NOT add a retry loop: a single bounded attempt already distinguishes "cannot init at
    all" (raises/hangs -> 503, the incident) from "healthy" (returns fast -> ready); a
    transient network blip on a backend that has ALREADY initialized in the process would
    be swallowed by the backend's own tolerant read (read_lines -> []), so it does not flap
    readiness. The timeout exists for the one case the backend can't swallow: a client that
    never finishes coming up."""
    name = _selected_backend_name()
    result = {"reason": _REASON_BACKEND_INIT_FAILED}  # default if the thread never lands.

    def _worker():
        result["reason"] = _run_backend_probe(home)

    t = threading.Thread(target=_worker, name="readyz-backend-probe", daemon=True)
    t.start()
    t.join(_BACKEND_PROBE_TIMEOUT_S)
    if t.is_alive():
        # The probe hung past the timeout (e.g. firestore.Client() blocked on ADC). The
        # daemon thread is abandoned (it dies with the process); readiness fails closed.
        return False, _REASON_BACKEND_INIT_FAILED, name
    reason = result["reason"]
    if reason is None:
        return True, None, name
    return False, reason, name


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
    """True iff the LOCAL durable state store is reachable: the runtime home resolves and
    the audit directory is present-or-creatable + writable. This is the cheapest honest
    proxy for "the control plane can persist to local disk".

    BACKEND-AWARE: cp_audit.audit_dir() resolves through the SELECTED backend's path(),
    and a non-filesystem backend (FirestoreBackend) REFUSES path() by design
    (BackendUnavailable) — there is no local audit dir to stat. That is NOT an
    unreachable-store signal: for a non-local backend, store reachability is governed by
    the SELECTED-BACKEND PROBE (_backend_ready), not by a local writable dir. So when
    path() is refused we return True here (this local-disk check does not apply) and let
    the backend probe be the authoritative gate. Any local IO failure (OSError) -> not
    reachable. Never raises."""
    try:
        base = home if home else issue_queue.heimdall_home()
        adir = cp_audit.audit_dir(home)
        os.makedirs(adir, exist_ok=True)
        return os.path.isdir(base) and os.access(adir, os.W_OK)
    except cp_state.BackendUnavailable:
        # Non-filesystem backend: no local audit dir to check. Reachability for this
        # backend is decided by _backend_ready (the init probe), not by local disk.
        return True
    except OSError:
        return False


def readiness(home=None):
    """Readiness probe (§A): 200 {status:"ready", ...} ONLY when serving is safe — the
    seam is wired (boot() ran) AND the SELECTED state backend actually initializes (a
    cheap, timeout-bounded liveness op on get_backend()). Otherwise 503 not_ready.

    The body is content-free: status + booleans + the registered-route COUNT (a number,
    never the route strings) + the selected backend NAME (a bare token like 'firestore',
    never a cred/path) + a short reason CODE when not ready + version. It NEVER carries a
    key, token, ADC path, or exception text. Cloud Run withholds traffic from an instance
    that 503s here, so this is the gate between 'up' and 'serving' — and, per the incident,
    the gate that catches a deploy whose configured backend cannot come up."""
    booted, route_count = _seam_booted()
    stores = _stores_reachable(home)
    backend_ok, reason, backend_name = _backend_ready(home)
    ready = booted and stores and backend_ok
    body = {
        "status": "ready" if ready else "not_ready",
        "booted": booted,
        "routes_registered": route_count,
        "stores_reachable": stores,
        "backend": backend_name,
        "backend_ready": backend_ok,
        "version": VERSION,
    }
    # A reason CODE only when not ready, and only when the backend probe is what failed
    # (booted/stores failures are already legible from their own booleans). Content-free.
    if not ready and not backend_ok and reason:
        body["reason"] = reason
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
