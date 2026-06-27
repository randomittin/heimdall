#!/usr/bin/env python3
# cp_presence.py — TEAM PRESENCE on the Heimdall control plane (server-synced).
#
# WHY THIS EXISTS. Heimdall devs want to see WHO ELSE is active on the SAME project and
# who is currently online — synced through the server, not just local files. A laptop
# can only see its own state; the answer "who is on this project right now" must come
# from a SHARED, DURABLE store every dev's hmd writes to. This module is that store: a
# dev's hmd POSTs a heartbeat (its identity + project + what it is doing), and any dev
# can GET the roster of devs ONLINE on a project. The roster is the fold of the latest
# heartbeat per dev, filtered to those whose heartbeat is within a TTL (online).
#
# THE STORE SHAPE (on the StateBackend seam — mirrors cp_ingest §5 / cp_notify §8 / the
# cp_approval keyed-record discipline EXACTLY, never re-derives persistence):
#
#   • ONE keyed JSON record per (project, haid): the rel is
#     "presence/<project_slug>/<haid_slug>.json", written with put_record (atomic
#     single-doc set — last-write-wins, exactly the presence semantics: a new heartbeat
#     OVERWRITES the dev's prior record with a fresher ts, never an append log that grows
#     unbounded). get_record reads one dev's record back; list_names enumerates a
#     project's dev records; the roster is the get_record fold over that enumeration.
#
#   • EXTERNAL-KEYED ⇒ SURVIVES SCALE-TO-ZERO. Under HEIMDALL_STATE_BACKEND=firestore the
#     record lives in Firestore (keyed to the project/database, NOT to the ephemeral
#     ${HEIMDALL_HOME}), so a dev on instance B reads a heartbeat dev A wrote to instance
#     A — the whole point of server-synced presence. On the local backend it is the
#     byte-identical keyed-JSON-to-HEIMDALL_HOME path. The cross-dev read is the
#     falsifiable property: break the external keying and the roster cross-read goes
#     empty (see test/cp-presence.test.sh).
#
#   • "ONLINE" = a heartbeat within PRESENCE_TTL_SECONDS (default 45s). The record stores
#     `ts` as epoch seconds; roster() drops any dev whose ts is older than the TTL — a
#     dev who closed their laptop falls off the roster on its own, no explicit logout.
#
# THE VERIFIED-HAID WRITE KEY (mirrors cp_ingest §5). The heartbeat route stores under
# the SERVER-VERIFIED identity.haid, NEVER a body field — a dev cannot write another
# dev's presence record. `project`/`handle`/`verdict`/`file` are DATA from the body; the
# partition KEY (haid) is the verified identity.
#
# NO-SECRET-BY-CONSTRUCTION (REUSE telemetry._scrub VERBATIM, like cp_notify §8). Every
# free-ish string field (handle/project/verdict/file) passes through telemetry._scrub:
# bounded to <=120 chars AND rejected (dropped to None) if it matches a gitleaks
# high-signal pattern or looks like an assigned credential. A secret cannot enter a
# presence record by construction.
#
# DATA ONLY, EXECUTES NOTHING. A presence record is rendered status; there is no
# action_type / cmd / handler field and no code path from this module into dispatch /
# cp_handlers. Presence is observed, never run — the §2 control/data-plane line holds.
#
# NOT AUDITED (deliberate). Heartbeats arrive every few seconds per dev; auditing each
# would flood the §9 audit log with no security value (presence is low-stakes, the write
# is already PKI-gated at the server seam). The store IS the record. cp_ingest/cp_notify
# audit because they are security-loaded data flows; presence is not.
#
# THE INTERFACE the server BINDS to (stable; cp_boot imports, never edits cp_server):
#   record_presence(haid, *, project, handle, verdict, file, home, ts, now) -> dict
#   roster(project, *, home, now, ttl) -> list[dict]  — the ONLINE devs for a project.
#   beat_route(identity, request, ...) / roster_route(identity, request, ...)
#   register(*, home=None)  — wire POST /presence + GET /roster into cp_server's seam.
#
# stdlib-only (json/os/time/sys) + cp_state (the persistence seam) + cp_auth (the
# verified Identity shape) + cp_server (register_route + Response) + telemetry (_scrub) —
# the SAME dependency shape every other CP store has, no third-party dep, self-hostable.

from __future__ import annotations

import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth     # the verified Identity shape the heartbeat route receives (§3).
import cp_publicsurface  # the PUBLIC-SURFACE boundary: public_surface_enabled() gates the
                         # unauthenticated /roster-public read, check_roster_read() rate-limits
                         # it. One-way dep (cp_publicsurface imports neither this nor cp_server).
import cp_server   # REUSE register_route + register_public_route + Response — the §10 seam.
import cp_state    # the pluggable persistence backend — presence writes/reads its keyed
                   # JSON record THROUGH a StateBackend (get_backend) so the same atomic
                   # put / tolerant get / sorted enumeration becomes Firestore-durable on
                   # Cloud Run WITHOUT changing this store (byte-identical on local).
import telemetry   # REUSE _scrub — no-secret-by-construction (bounded + secret-rejected).

# ── the online window (a heartbeat fresher than this is "online" — §presence) ──
#
# A dev's hmd beats roughly every 30s; 45s gives one missed beat of slack before the dev
# drops off the roster. Overridable via env so a deploy / a test can tune the window.
PRESENCE_TTL_ENV = "HEIMDALL_PRESENCE_TTL_SECONDS"
DEFAULT_TTL_SECONDS = 45.0

# A conservative slug bound for a project / HAID used as a path segment (mirrors
# cp_ingest._SLUG_MAX). Keeps the store human-greppable + filesystem-safe + bounded, and
# (critically for the Firestore flat encoding) produces only single "_" runs from a
# "haid:<id>" / a repo name, never the "__" rel separator FirestoreBackend reserves.
_SLUG_MAX = 80


def ttl_seconds():
    """The online-window TTL in seconds (HEIMDALL_PRESENCE_TTL_SECONDS, default 45).
    A malformed env value falls back to the default rather than crashing a read."""
    raw = os.environ.get(PRESENCE_TTL_ENV)
    if not raw:
        return DEFAULT_TTL_SECONDS
    try:
        val = float(raw)
    except (TypeError, ValueError):
        return DEFAULT_TTL_SECONDS
    return val if val > 0 else DEFAULT_TTL_SECONDS


# ── store layout (a keyed record per (project, verified-haid) — StateBackend rel) ──
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace):
# the presence root is "presence/", one project's dir is "presence/<project_slug>/", one
# dev's record is "presence/<project_slug>/<haid_slug>.json". The backend owns the home
# root + makedirs + the byte shape; this store NEVER opens a file directly and NEVER
# calls backend.path() on a serving path (FirestoreBackend.path() RAISES by design — the
# firestore-only incident class).

_PRESENCE_REL = "presence"

# The keyed-record suffix (one .json per dev, like cp_approval's per-action records).
_RECORD_SUFFIX = ".json"


def _backend(home=None):
    """The StateBackend for the presence store (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every CP accessor's `home=` arg always has —
    threaded straight through, no re-derivation of heimdall_home() here (the backend owns
    it). Mirrors cp_ingest._backend / cp_notify._backend / cp_auth._backend verbatim."""
    return cp_state.get_backend(home=home)


def _slug(value):
    """A filesystem-safe, bounded path slug for a project name / HAID. Keeps
    [A-Za-z0-9._-] and maps every other char (the HAID `:` / a repo `/`) to `_`, so the
    segment is filesystem-safe, path-traversal-proof, AND free of the "__" separator the
    Firestore flat encoding reserves (a single odd char becomes a single "_"). Returns
    'unknown' for an empty/None value (an unattributed record still stores, never escapes
    its segment). Mirrors cp_ingest._slug exactly."""
    raw = str(value or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _project_rel(project):
    """The store-relative dir of one project's presence records: presence/<slug>/."""
    return os.path.join(_PRESENCE_REL, _slug(project))


def _record_rel(project, haid):
    """The store-relative path of one dev's presence record under a project:
    presence/<project_slug>/<haid_slug>.json."""
    return os.path.join(_project_rel(project), _slug(haid) + _RECORD_SUFFIX)


# ── the presence record (the CLOSED, DATA-ONLY, secret-scrubbed schema) ────────


def _clean(value):
    """Scrub one free-ish presence string field (REUSE telemetry._scrub VERBATIM): bound
    to <=120 chars AND drop (None) if it matches a gitleaks pattern / looks like an
    assigned credential. A secret cannot enter a presence record by construction. A None
    field stays None (the field is optional)."""
    if value is None:
        return None
    return telemetry._scrub(str(value))


def build_record(haid, *, project, handle=None, verdict=None, file=None, ts=None):
    """Assemble ONE DATA-ONLY, secret-scrubbed presence record. Pure — no IO. `haid` is
    the VERIFIED identity (the partition key); project/handle/verdict/file are scrubbed
    DATA. `ts` is epoch seconds (defaults to now) — the freshness used by the TTL.

    The schema is CLOSED — only these keys exist:
      {haid, handle, project, verdict, file, ts}
    There is NO action_type/cmd/handler field: a presence record is rendered status, it
    cannot be made to run anything (the §2 control/data-plane line)."""
    return {
        "haid": haid,
        "handle": _clean(handle),
        "project": _clean(project),
        "verdict": _clean(verdict),
        "file": _clean(file),
        # epoch seconds — the freshness the TTL filters on. A bad ts coerces to now.
        "ts": float(ts) if isinstance(ts, (int, float)) else time.time(),
    }


def record_presence(haid, *, project, handle=None, verdict=None, file=None,
                    home=None, ts=None):
    """STORE one dev's heartbeat: build the scrubbed record and atomically upsert it under
    (project, haid) via put_record (last-write-wins — a fresher beat overwrites the dev's
    prior record). The partition KEY is `haid` (the server-verified identity at the route
    boundary), never a body field — a dev cannot write another dev's record.

    Returns {ok, haid, project} on a stored write, {ok: False, reason} on an IO failure
    (the store degrades, never crashes a heartbeat). DATA only — executes nothing.

    Routed THROUGH the StateBackend: put_record writes the SAME atomic tmp+os.replace,
    json.dump(sort_keys=True, indent=2) keyed record cp_approval / cp_auth write — so the
    bytes are byte-identical on the local backend and the SAME atomic put becomes
    Firestore-durable (survives scale-to-zero) when the firestore backend is selected.
    NEVER calls backend.path() — the write is the durable op."""
    if not haid:
        return {"ok": False, "reason": "no_haid"}
    record = build_record(haid, project=project, handle=handle, verdict=verdict,
                          file=file, ts=ts)
    if not _backend(home).put_record(_record_rel(project, haid), record):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "haid": haid, "project": record.get("project")}


def is_online(record, *, now=None, ttl=None):
    """True iff a presence record's heartbeat is within the online TTL (now - ts <= ttl).
    A record with no/garbled ts is OFFLINE (never falsely online). `now`/`ttl` are
    injectable for deterministic tests."""
    if not isinstance(record, dict):
        return False
    ts = record.get("ts")
    if not isinstance(ts, (int, float)):
        return False
    when = now if now is not None else time.time()
    window = ttl if ttl is not None else ttl_seconds()
    return (when - ts) <= window


def roster(project, *, home=None, now=None, ttl=None):
    """The ONLINE devs for a project: the fold of the latest heartbeat per dev, filtered
    to those within the TTL, sorted by haid for a stable view. Read-only; an absent
    project store yields [] (honest empty). Each returned record carries an added
    "online": True and "age_seconds" (now - ts, rounded) for the renderer.

    Routed THROUGH the StateBackend: list_names returns the SAME sorted enumeration of a
    project's dev-record basenames on EVERY backend (leaf .json names directly under
    presence/<project>/ — FirestoreBackend recovers them from the flat doc-id prefix),
    and get_record returns the SAME tolerant keyed read (None when absent/corrupt). A
    BACKEND-SAFE read end to end: NEVER backend.path() (FirestoreBackend refuses it) —
    list_names + get_record are served by every backend, so the cross-dev roster read
    never raises under firestore (the firestore-only read-path incident class)."""
    backend = _backend(home)
    when = now if now is not None else time.time()
    window = ttl if ttl is not None else ttl_seconds()
    out = []
    for name in backend.list_names(_project_rel(project), suffix=_RECORD_SUFFIX):
        rel = os.path.join(_project_rel(project), name)
        record = backend.get_record(rel)
        if not is_online(record, now=when, ttl=window):
            continue
        view = dict(record)
        view["online"] = True
        view["age_seconds"] = round(when - record["ts"], 1)
        out.append(view)
    out.sort(key=lambda r: str(r.get("haid") or ""))
    return out


# ── the route handlers (verified Identity in — the server already authed it, §3) ─


def _parse_body(request):
    """Extract the JSON body dict from a request. The wire body is a JSON object carrying
    the heartbeat's DATA fields {project, handle, verdict, file}. Tolerant — a malformed
    / empty / non-object body yields {} (the route validates the fields it needs), never
    a crash. Recognizes NOTHING executable (no action_type/cmd/handler key is honored)."""
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


def _query_project(request, payload):
    """Resolve the roster's target project, GFE-safe (mirrors cp_worker._job_id_from):
      1. the QUERY STRING — request["query"]["project"], i.e. GET /roster?project=<p>.
         The GFE-SAFE read shape: Google's GFE / Cloud Run ingress REJECTS a GET-with-a-
         body (HTTP 400, never reaches the container), so the project rides the query, not
         the body. The server signs+verifies the FULL path-with-query, so the query'd
         project is authenticated + tamper-evident. cp_server._request_dict hands the
         parsed query in; when it didn't (a direct/in-process call) we parse the path's
         own ?query as a fallback so the query shape resolves either way.
      2. the BODY — payload["project"]. Back-compat for a direct/local call."""
    if isinstance(request, dict):
        q = request.get("query")
        if isinstance(q, dict) and q.get("project"):
            return q.get("project")
        path = request.get("path")
        if isinstance(path, str) and "?" in path:
            from urllib.parse import urlsplit, parse_qs
            vals = parse_qs(urlsplit(path).query).get("project")
            if vals and vals[0]:
                return vals[0]
    if isinstance(payload, dict) and payload.get("project"):
        return payload.get("project")
    return None


def beat_route(identity, request, *, home=None):
    """POST /presence — RECORD a dev's heartbeat (§presence). The server ran the §3 auth
    chokepoint BEFORE this, so `identity` is a VERIFIED cp_auth.Identity — an unsigned /
    forged / unknown / revoked beat never reaches here (it is a 401 at the seam). The
    record is keyed by identity.haid (the VERIFIED HAID), NEVER a body field — a dev
    cannot write another dev's presence.

    Body (JSON): {project, handle?, verdict?, file?} — DATA, scrubbed on store. DATA
    ONLY — dispatches nothing, runs no handler. 200 with the stored summary on a write,
    422 when no project is supplied (a record with no project has no roster to join)."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    payload = _parse_body(request)
    project = payload.get("project")
    if not project:
        return cp_server.Response(
            422, {"recorded": False, "reason": "no_project"})
    result = record_presence(
        haid, project=project, handle=payload.get("handle"),
        verdict=payload.get("verdict"), file=payload.get("file"), home=home)
    if not result.get("ok"):
        return cp_server.Response(
            500, {"recorded": False, "reason": result.get("reason", "io_error")})
    return cp_server.Response(
        200, {"recorded": True, "haid": haid, "project": result.get("project")})


def roster_route(identity, request, *, home=None):
    """GET /roster?project=<p> — the ONLINE devs for a project, from ANY signed client
    (§presence). The project rides the QUERY STRING with an EMPTY body (the GFE-safe read
    shape; the signature covers the full path-with-query). Reads the durable per-dev
    records and folds the roster (replay-on-read), so a fresh client — or a fresh instance
    after scale-to-zero — sees the team another dev's heartbeats built. 422 when no
    project is supplied. DATA only — runs nothing."""
    payload = _parse_body(request)
    project = _query_project(request, payload)
    if not project:
        return cp_server.Response(
            422, {"reason": "no_project", "roster": []})
    return cp_server.Response(
        200, {"project": project, "roster": roster(project, home=home)})


# ── the UNAUTHENTICATED browser read (GET /roster-public — the static dashboard's read) ──
#
# WHY A SECOND ROSTER ROUTE. The signed GET /roster needs a PKI signature; a BROWSER cannot
# sign, so the static heimdall-site dashboard would 401. This route is the unauthenticated,
# rate-limited, READ-ONLY public read of the SAME TTL-filtered online roster — served PRE-AUTH
# (like the health probes) but ONLY on the public surface, projected so it leaks no identity.

# CORS for the unauthenticated browser read (GET/OPTIONS /roster-public). The roster is read-
# only public data, so Access-Control-Allow-Origin:* lets the static dashboard (a DIFFERENT
# origin) fetch it; the preflight additionally advertises the allowed method/headers.
_CORS_HEADERS = {"Access-Control-Allow-Origin": "*"}
_CORS_PREFLIGHT_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Max-Age": "86400",
}


def _public_view(record):
    """Project ONE online roster record to the PUBLIC, NO-SECRET browser view: handle / verdict
    / file / age_seconds ONLY. Drops haid (the identity), ts, and every other field — the public
    read renders status, never an identity or a key. The fields are already scrubbed at write
    time (build_record -> _clean -> telemetry._scrub), so no secret can reach here either."""
    return {
        "handle": record.get("handle"),
        "verdict": record.get("verdict"),
        "file": record.get("file"),
        "age_seconds": record.get("age_seconds"),
    }


def roster_public_route(request, *, home=None):
    """GET /roster-public?project=<id> — the UNAUTHENTICATED, rate-limited, READ-ONLY online
    roster for the static web dashboard (a browser cannot PKI-sign, so the signed GET /roster
    401s it). Served PRE-AUTH, but ONLY on the public surface (public_surface_enabled()); off it
    the route does not exist (404), so the gated IAM service is unchanged.

    Exposes ONLY handle/verdict/file/age_seconds per ONLINE dev (the SAME TTL-filtered fold
    roster() computes) — NEVER the haid, a pubkey, or any secret, and it is a READ (no presence
    write seam exists on the public surface). Every reply carries Access-Control-Allow-Origin:*
    so a different-origin static site can fetch it.

    400 when project is missing/empty; an unknown project is a 200 with an empty online list
    (honest empty, not an error); 429 when the per-IP read-flood cap trips. DATA only — runs
    nothing, never backend.path() (roster() is list_names + get_record, firestore-safe)."""
    if not cp_publicsurface.public_surface_enabled():
        # Off the public surface this unauthenticated read does not exist — 404 like any other
        # gated route, so the IAM-gated service stays byte-for-byte as before.
        return cp_server.Response(404, {"error": "no_such_route"}, headers=_CORS_HEADERS)
    refusal = cp_publicsurface.check_roster_read(request, home=home)
    if refusal is not None:
        status, body = refusal
        return cp_server.Response(status, body, headers=_CORS_HEADERS)
    project = _query_project(request, None)
    if not project:
        return cp_server.Response(
            400, {"error": "no_project", "online": []}, headers=_CORS_HEADERS)
    online = [_public_view(view) for view in roster(project, home=home)]
    return cp_server.Response(
        200, {"project": project, "online": online}, headers=_CORS_HEADERS)


def roster_public_preflight(request):
    """OPTIONS /roster-public — the CORS preflight for the browser read. Returns 204 + the CORS
    headers so a different-origin static site may then issue the GET. Served pre-auth on the
    public surface only; 404s on the gated service exactly as the GET does (no preflight for a
    route that does not exist there)."""
    if not cp_publicsurface.public_surface_enabled():
        return cp_server.Response(404, {"error": "no_such_route"})
    return cp_server.Response(204, None, headers=_CORS_PREFLIGHT_HEADERS)


def register(*, home=None):
    """Wire POST /presence (heartbeat) + GET /roster (online team) into cp_server's
    registration seam (§10), and the UNAUTHENTICATED GET/OPTIONS /roster-public browser read
    into the PRE-AUTH public seam (register_public_route — the static dashboard cannot sign),
    all WITHOUT editing cp_server. The handlers close over the runtime `home` so a self-host
    deployment / a test can pin its store root. Returns the registered (method, path) keys.
    Idempotent — re-registering replaces the routes. Mirrors cp_ingest.register /
    cp_enroll.register (pre-auth public routes) exactly."""
    keys = []
    keys.append(cp_server.register_route(
        "POST", "/presence",
        lambda identity, request: beat_route(identity, request, home=home)))
    keys.append(cp_server.register_route(
        "GET", "/roster",
        lambda identity, request: roster_route(identity, request, home=home)))
    # The UNAUTHENTICATED browser read + its CORS preflight (pre-auth; public-surface-only,
    # self-gated inside the handlers; per-IP rate-limited; READ-ONLY — no public write seam).
    keys.append(cp_server.register_public_route(
        "GET", "/roster-public",
        lambda request: roster_public_route(request, home=home)))
    keys.append(cp_server.register_public_route(
        "OPTIONS", "/roster-public",
        lambda request: roster_public_preflight(request)))
    return keys
