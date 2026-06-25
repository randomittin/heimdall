#!/usr/bin/env python3
# cp_ingest.py — piece (b) of the Heimdall control plane: OBSERVE INGEST (§5).
#
# DESIGN DOSSIER §5/§10/§11 (authoritative). Instances PUSH their `hmd report`
# telemetry (a batch of NDJSON events) to the server; the server writes them to the
# observability store, partitioned by instance HAID. The dashboard (cp_dashboard.py)
# reads that store. THIS module is DATA INGEST ONLY — it NEVER executes anything.
#
# THE FOUR CARDINAL PROPERTIES this module pins (each falsifiable in the test):
#
#   1. PKI-VERIFIED (§3) — ingest is wired in behind cp_server's auth chokepoint:
#      register_route("POST", "/ingest", ...) receives the ALREADY-verified Identity
#      (the server ran cp_auth.verify_identity before the route runs). An unsigned /
#      forged / unknown push never reaches the handler — it is a 401 at the server
#      seam. The handler is reached ONLY by an authenticated instance, and it stores
#      under THAT instance's verified HAID (a client cannot write another dev's
#      partition — the store key is the verified identity, never a body field).
#
#   2. NO-SECRET-BY-CONSTRUCTION (§5/§7) — the server RE-RUNS telemetry.build_event
#      on EVERY pushed line server-side. A line that is off-schema (event_type not in
#      EVENT_TYPES) is DROPPED; every free-ish field passes through telemetry._scrub
#      (bounded + secret-rejected). A client CANNOT inject a secret-bearing or
#      off-schema line — the discipline is enforced at the BOUNDARY, not trusted from
#      the client. The store is gitleaks-clean by construction (scrub) AND by gate
#      (the wave-3 / piece-b secret-scan over the store).
#
#   3. DATA-ONLY, EXECUTES NOTHING (§2/§5) — ingest writes events; it has NO dispatch
#      path, calls NO handler, resolves NO action_type, runs NO subprocess. There is
#      no `action_type`/`cmd`/`exec`/`handler` field in the ingest wire schema and no
#      code path from this module into cp_handlers / cp_server.dispatch. A pushed
#      payload is rendered as STORED DATA, never as a thing to run. This preserves the
#      §2 control/data-plane line: instances push data in, they never push commands.
#
#   4. PARTITIONED + AUDITED (§5/§9) — the store lands at
#      ${HEIMDALL_HOME}/control-plane/observe/<instance_haid>/events.ndjson (NDJSON so
#      gitleaks scans it as plaintext). Every accepted batch writes one cp_audit
#      `ingest` row (params-shape only — counts, never values).
#
# THE INTERFACE the server + dashboard BIND to (stable):
#   register(*, home=None)                 — wire POST /ingest into cp_server's seam.
#   ingest_route(identity, request, ...)   — the route handler (verified Identity in).
#   ingest_batch(instance_haid, events, ...) -> dict — the pure boundary: re-run
#                                            build_event per line, store, audit.
#   observe_dir / instance_store_path      — the partitioned store layout.
#   stored_instances(home) / read_instance(haid, home) — the dashboard read path.
#
# stdlib-only (json/os/sys) + the sibling substrate (cp_server/cp_auth/cp_audit) and
# the reused telemetry layer — minimal self-host deps, never re-derives discipline.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit     # REUSE the §9 audit writer — one `ingest` row per accepted batch.
import cp_auth      # the Identity shape the verified route receives (§3).
import cp_server    # REUSE register_route + Response — the registration seam (§10).
import cp_state     # the pluggable persistence backend (Wave 0). The observe store
                   # writes/reads its per-instance NDJSON THROUGH a StateBackend
                   # (get_backend) so the same flush-only append / tolerant scan /
                   # sorted enumeration becomes durable on Cloud Run (Wave 2
                   # FirestoreBackend) WITHOUT changing this store. The local backend is
                   # byte-identical to the prior NDJSON-to-HEIMDALL_HOME path, and it
                   # owns heimdall_home() resolution + the control-plane/ root (so this
                   # store no longer needs issue_queue directly).
import telemetry    # REUSE build_event + _scrub — no-secret-by-construction (§5/§7).

# ── store layout (partitioned by the VERIFIED instance HAID — §5) ──────────────
#
# Mirrors telemetry.py's own store choice (an NDJSON events.ndjson) so the dashboard
# can read each partition with the EXACT same line-scan telemetry/report use. The
# partition KEY is the instance HAID the server VERIFIED — never a client-supplied
# field, so a push cannot land in another dev's partition.

# A conservative slug for a HAID used as a directory name. A HAID is a deterministic
# identity name (`haid:rj.mbp-7f3a`); we keep [A-Za-z0-9._-] and map everything else
# (the `:` and `/role`) to `_` so the partition dir is filesystem-safe + bounded.
_SLUG_MAX = 80


def _slug(haid):
    """A filesystem-safe, bounded directory slug for a HAID. Keeps the identity name
    readable (so the store is human-greppable) while refusing any path-traversal or
    odd char. Returns 'unknown' for an empty/None HAID (an unattributed batch still
    stores, but never escapes its partition)."""
    raw = str(haid or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


# ── store location + backend (the persistence SEAM — Wave 0/1) ─────────────────
#
# The observe store addresses its bytes by paths RELATIVE to
# ${HEIMDALL_HOME}/control-plane/ (the StateBackend rel namespace): the observe root is
# "observe/", one instance's partition is "observe/<slug>/", one instance's append-only
# log is "observe/<slug>/events.ndjson". The backend owns the home root + makedirs + the
# byte shape; observe_dir/instance_dir/instance_store_path remain the public absolute-
# path accessors (now derived from the backend's path(), so they stay byte-identical to
# the prior layout and the cp suites' on-disk reads keep working).

# the rel sub-dir all instance partitions live under, within control-plane/.
_OBSERVE_REL = "observe"

# the per-instance log file name (one append-only NDJSON per partition).
_EVENTS_FILE = "events.ndjson"


def _backend(home=None):
    """The StateBackend for the observe store (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every observe accessor's `home=` arg always
    has (the backend re-derives heimdall_home when home is None)."""
    return cp_state.get_backend(home=home)


def _instance_rel(instance_haid):
    """The store-relative dir of one instance's partition: observe/<slug>/."""
    return os.path.join(_OBSERVE_REL, _slug(instance_haid))


def _events_rel(instance_haid):
    """The store-relative path of one instance's log: observe/<slug>/events.ndjson."""
    return os.path.join(_instance_rel(instance_haid), _EVENTS_FILE)


def observe_dir(home=None):
    """The observe store root: ${HEIMDALL_HOME}/control-plane/observe/ (the backend's
    absolute path for the observe rel-dir — unchanged on the local backend)."""
    return _backend(home).path(_OBSERVE_REL)


def instance_dir(instance_haid, home=None):
    """One instance's partition dir under the observe store (slugged HAID)."""
    return _backend(home).path(_instance_rel(instance_haid))


def instance_store_path(instance_haid, home=None):
    """Absolute path to one instance's append-only observe NDJSON log."""
    return _backend(home).path(_events_rel(instance_haid))


def _instance_store_path_or_none(instance_haid, home=None):
    """The local on-disk path of an instance's observe log, or None when the selected
    backend has no local file for it. On the LOCAL backend this is the real path; on a
    non-filesystem backend (FirestoreBackend) path() RAISES BackendUnavailable by design
    (a firestore-backed rel is an external doc, not an on-disk tree) — and a REQUEST
    handler must NOT raise over a cosmetic path lookup (the firestore-only incident
    class). The events are already durably stored via append_line; this returns None on
    firestore so ingest_batch's result carries an honest 'no local file' instead of
    crashing the POST /ingest path."""
    try:
        return instance_store_path(instance_haid, home)
    except cp_state.BackendUnavailable:
        return None


# ── the no-secret boundary: re-run build_event server-side per pushed line (§5) ─


def _rebuild_event(line):
    """Re-run telemetry.build_event on ONE pushed event dict SERVER-SIDE. This is the
    no-secret-by-construction boundary: a client cannot inject an off-schema or
    secret-bearing line, because the server rebuilds the event from the pinned schema
    keys — every free-ish field passes through telemetry._scrub (bounded + secret-
    rejected) and an event_type not in EVENT_TYPES yields None (the line is DROPPED).

    Returns the clean, scrubbed event dict, or None when the line is dropped (not a
    dict, or an off-schema event_type). Pure — no IO, never executes anything."""
    if not isinstance(line, dict):
        return None
    # Pull ONLY the pinned schema keys; an unknown wire field is ignored entirely
    # (it never reaches the store). build_event re-validates + scrubs each.
    return telemetry.build_event(
        line.get("event_type"),
        run_id=line.get("run_id"),
        phase=line.get("phase"),
        step=line.get("step"),
        outcome=line.get("outcome"),
        gate=line.get("gate"),
        tokens=line.get("tokens"),
        duration_ms=line.get("duration_ms"),
        commit=line.get("commit"),
        error=line.get("error"),
        loc=line.get("loc"),
        extra=line.get("extra"),
    )


def _append_events(instance_haid, events, home=None):
    """Append already-rebuilt (clean) event dicts to the instance's observe NDJSON log
    (one compact JSON line each + flush — mirrors telemetry._append). Returns the
    count written, or 0 on any IO failure (the ingest degrades to a dropped batch
    rather than crashing the request — the handler surfaces that).

    Routed THROUGH the StateBackend (Wave 1): append_line writes the SAME compact
    json.dumps(sort_keys=True, separators=(",", ":")) line and the SAME flush-only
    discipline (fsync=False — the observe log flushes only, never fsync'd, exactly as
    before; only the §4 jobstore uses fsync=True). The backend owns the makedirs + the
    control-plane/ root, so the bytes written are byte-identical to the prior path. A
    failed line degrades the whole batch to 0 (the prior open-mid-write OSError did the
    same — a partial write was reported as a dropped batch, never a crash)."""
    if not events:
        return 0
    rel = _events_rel(instance_haid)
    backend = _backend(home)
    written = 0
    for ev in events:
        if not backend.append_line(rel, ev, fsync=False):
            return 0
        written += 1
    return written


# ── the pure ingest boundary (re-run build_event → store → audit — §5/§9) ──────


def ingest_batch(instance_haid, events, *, home=None):
    """THE ingest boundary (§5): take a pushed batch of telemetry event dicts under a
    VERIFIED instance HAID, RE-RUN telemetry.build_event on each (the no-secret /
    on-schema boundary), STORE the clean events in that instance's partition, and
    AUDIT the batch. DATA ONLY — never resolves an action_type, never runs a handler,
    never spawns a process.

    Returns a result dict:
      {"instance_haid", "received", "stored", "dropped", "audit_id", "path"}
    where `received` is the count pushed, `stored` the count that survived the
    rebuild + write, `dropped` = received − stored (off-schema / secret-bearing lines
    the boundary refused). Never raises into the caller — a bad batch degrades to
    dropped lines, not a crash."""
    received = len(events) if isinstance(events, (list, tuple)) else 0
    clean = []
    if isinstance(events, (list, tuple)):
        for line in events:
            ev = _rebuild_event(line)
            if ev is not None:
                clean.append(ev)
    stored = _append_events(instance_haid, clean, home=home)
    # AUDIT one ingest row — params-SHAPE only (counts), never the pushed values.
    audit_id = cp_audit.write(
        "ingest", actor_haid=instance_haid,
        params={"received": received, "stored": stored},
        outcome="ok" if stored else "refused",
        detail="observe batch ingested", home=home,
    )
    return {
        "instance_haid": instance_haid,
        "received": received,
        "stored": stored,
        "dropped": received - stored,
        "audit_id": audit_id,
        # Informational only — the POST /ingest route does NOT read this field. Resolved
        # firestore-safe: None when the backend has no local file (FirestoreBackend),
        # never a raise on the request path (the firestore-only incident class).
        "path": _instance_store_path_or_none(instance_haid, home),
    }


# ── the route handler (verified Identity in — the server already authed it, §3) ─


def _parse_events(request):
    """Extract the pushed event LIST from a request dict. The wire body is JSON:
    either a bare list of event dicts, or {"events": [...]}. Returns the list (or []
    for a malformed / empty body). Tolerant — a bad body yields no events, never a
    crash. Recognizes NOTHING executable: there is no action_type/cmd/handler key in
    this schema and none is honored even if a client sends one."""
    body = request.get("body") if isinstance(request, dict) else None
    if body is None:
        return []
    if isinstance(body, (bytes, bytearray)):
        try:
            body = body.decode("utf-8")
        except (UnicodeDecodeError, AttributeError):
            return []
    if isinstance(body, str):
        try:
            body = json.loads(body or "null")
        except (ValueError, TypeError):
            return []
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        evs = body.get("events")
        return evs if isinstance(evs, list) else []
    return []


def ingest_route(identity, request, *, home=None):
    """The POST /ingest route handler (§5). The server ran the §3 auth chokepoint
    BEFORE this runs, so `identity` is a VERIFIED cp_auth.Identity — an unsigned /
    forged / unknown / revoked push never reaches here (it is a 401 at the seam). The
    store partition key is identity.haid (the VERIFIED HAID), NEVER a body field — a
    client cannot write into another instance's partition.

    Re-runs build_event per line (no-secret boundary), stores, audits, returns a
    cp_server.Response. DATA ONLY — it dispatches nothing, runs no handler, never
    executes. Returns 200 with the batch summary on a write, 422 when no usable
    event survived (an all-dropped batch is refused, audited)."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    events = _parse_events(request)
    result = ingest_batch(haid, events, home=home)
    if result["stored"] <= 0:
        return cp_server.Response(
            422,
            {"ingested": False, "reason": "no_storable_events",
             "received": result["received"], "stored": 0,
             "dropped": result["dropped"]},
            audit_id=result["audit_id"],
        )
    return cp_server.Response(
        200,
        {"ingested": True, "instance_haid": haid,
         "received": result["received"], "stored": result["stored"],
         "dropped": result["dropped"]},
        audit_id=result["audit_id"],
    )


def register(*, home=None):
    """Wire POST /ingest into cp_server's registration seam (§10) WITHOUT editing
    cp_server. Returns the registered (method, path) key. The handler closes over the
    runtime `home` so a self-host deployment / a test can pin its store root. After
    this, an authenticated instance POSTing /ingest reaches ingest_route with its
    verified Identity. Idempotent — re-registering replaces the route."""
    return cp_server.register_route(
        "POST", "/ingest",
        lambda identity, request: ingest_route(identity, request, home=home),
    )


# ── the dashboard read path: stored instances + per-instance events (§5) ───────


def stored_instances(home=None):
    """The list of instance partition slugs present in the observe store (the devs
    who have pushed). Read-only; an absent store yields [] (honest empty). The
    dashboard groups its cross-dev aggregate over these.

    Routed THROUGH the StateBackend: list_names returns the SAME sorted enumeration of
    the immediate children of observe/ (the per-instance partition directories) on EVERY
    backend — on Firestore the nested partition is recovered as a synthetic subdirectory
    name (see FirestoreBackend.list_names). The partition guard is a BACKEND-SAFE
    existence check on the partition's events log (backend.exists of <slug>/events.ndjson)
    rather than os.path.isdir(backend.path(...)):

      • FIRESTORE-SAFE — FirestoreBackend.path() RAISES BackendUnavailable by design (a
        firestore-backed rel has no local file). The old os.path.isdir(backend.path(...))
        guard therefore raised on the live cross-dev DASHBOARD read whenever the observe
        store held a partition — the firestore-only read-path incident this fixes. exists()
        is served by every backend (LocalBackend.exists = os.path.exists; Firestore checks
        the node/prefix), so the dashboard read never raises.

      • LOCAL-EQUIVALENT — a real partition IS a directory holding events.ndjson, so
        "<slug>/events.ndjson exists" selects exactly the partitions the prior isdir guard
        kept (every slug stored_instances returns has an events log — the contract the
        cross-dev read and cp-observe's per-slug events.ndjson read both rely on). A stray
        non-partition entry under observe/ (no events log) is skipped, as before."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(_OBSERVE_REL):
        if backend.exists(_events_rel(name)):
            names.append(name)
    return names


def read_instance(instance_slug, home=None):
    """Stream one instance partition's stored events (the dashboard's per-dev scan).
    `instance_slug` is a directory slug from stored_instances (already partition-safe).
    Tolerant: a bad line is skipped, an absent partition yields []. Read-only — never
    writes, never executes.

    Routed THROUGH the StateBackend (Wave 1): read_lines returns the SAME tolerant,
    store-ordered scan (bad line skipped, absent -> []) the observe store has always
    done — the dashboard aggregate semantics are unchanged. _events_rel applies the
    same _slug, so the partition addressed is byte-identical to the prior path."""
    return _backend(home).read_lines(_events_rel(instance_slug))
