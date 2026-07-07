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

import contextlib
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
    """A filesystem-safe, bounded path slug for a project name / HAID. Keeps [A-Za-z0-9.-]
    and maps every RUN of other chars (the HAID `:` / a repo `/`, incl. a literal `_`) to a
    SINGLE `_`, so the segment is filesystem-safe, path-traversal-proof, AND — critically for
    the Firestore flat encoding — can NEVER contain the "__" separator FirestoreBackend
    reserves. Returns 'unknown' for an empty/None value (an unattributed record still stores,
    never escapes its segment).

    THE COLLAPSE IS LOAD-BEARING (firestore-only viral-gate bug). FirestoreBackend flattens a
    rel `presence/<p>/<t>/<h>.json` to ONE doc id, "/"→"__", and list_names(<p>/<t>, ".json")
    recovers the immediate child by splitting the remainder on the FIRST "__" — a leaf when
    there is no interior "__", a SUBDIRECTORY otherwise. If a HAID with adjacent odd chars
    (e.g. a "://" / "//" run) mapped each char to a lone "_" INDIVIDUALLY, the leaf basename
    would contain "__"; list_names then read that leaf as a subdirectory and DROPPED it under
    the ".json" suffix filter, so a valid beat's record was invisible to its own roster-team on
    Firestore (while os.listdir on the LOCAL backend returned it verbatim — the deployed-shape
    gap the hermetic BUG2 test missed). Collapsing every replacement run to a single "_" honors
    the no-"__" invariant the flat encoding depends on, so the WRITE doc id and the READ
    list_names prefix stay byte-identical AND unambiguous on Firestore. A record that already
    round-trips (single-"_" slug) is UNCHANGED — the collapse is identity on it. See
    test/cp-presence-firestore.test.sh. NB: cp_ingest._slug carries the same per-char mapping
    and the same latent firestore risk for a "__"-bearing instance slug; this fix is scoped to
    the presence viral-gate and does NOT touch cp_ingest."""
    raw = str(value or "").strip()
    if not raw:
        return "unknown"
    out = []
    prev_us = False
    for ch in raw[:_SLUG_MAX]:
        if ch.isalnum() or ch in ".-":
            out.append(ch)
            prev_us = False
        elif not prev_us:
            # Every other char — including a literal "_" — maps to a SINGLE "_", and a RUN of
            # such chars collapses to one "_" (prev_us), so no "__" can ever appear in a segment.
            out.append("_")
            prev_us = True
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _team_rel(project, team_id):
    """The store-relative dir of one (project, team) partition's presence records:
    presence/<project_slug>/<team_id_slug>/. team_id is 32-hex (a safe single-"_"-free path
    segment on both backends); _slug guards None -> "unknown". This 3-level partition is the
    load-bearing isolation key — a roster read addresses exactly ONE such dir, so team A never
    enumerates team B's records."""
    return os.path.join(_PRESENCE_REL, _slug(project), _slug(team_id))


def _record_rel(project, team_id, haid):
    """The store-relative path of one dev's presence record under a (project, team):
    presence/<project_slug>/<team_id_slug>/<haid_slug>.json. The record KEY stays the verified
    haid (a dev cannot overwrite a teammate's record); team_id is the partition."""
    return os.path.join(_team_rel(project, team_id), _slug(haid) + _RECORD_SUFFIX)


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


def record_presence(haid, *, project, team_id, handle=None, verdict=None, file=None,
                    home=None, ts=None):
    """STORE one dev's heartbeat: build the scrubbed record and atomically upsert it under
    (project, team_id, haid) via put_record (last-write-wins — a fresher beat overwrites the
    dev's prior record). The partition KEY is (project, team_id) and the record KEY is `haid`
    (the server-verified identity at the route boundary). `team_id` is resolved from the
    caller's REGISTRY BINDING (cp_auth.registered_team), NEVER a body field — so a member can
    only beat into THEIR team.

    Returns {ok, haid, project, team_id} on a stored write, {ok: False, reason} on an IO
    failure (the store degrades, never crashes a heartbeat). DATA only — executes nothing.

    Routed THROUGH the StateBackend: put_record writes the SAME atomic tmp+os.replace,
    json.dump(sort_keys=True, indent=2) keyed record cp_approval / cp_auth write — so the
    bytes are byte-identical on the local backend and the SAME atomic put becomes
    Firestore-durable (survives scale-to-zero) when the firestore backend is selected.
    NEVER calls backend.path() — the write is the durable op."""
    if not haid:
        return {"ok": False, "reason": "no_haid"}
    record = build_record(haid, project=project, handle=handle, verdict=verdict,
                          file=file, ts=ts)
    if not _backend(home).put_record(_record_rel(project, team_id, haid), record):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "haid": haid, "project": record.get("project"),
            "team_id": team_id}


def record_retire(haid, *, project, team_id, home=None, ts=None):
    """RETIRE one dev's presence: atomically OVERWRITE their (project, team_id, haid) record
    with a RETIREMENT TOMBSTONE {haid, project, retired: True, ts} via put_record (last-write-
    wins). This is the "prompt disappearance, not TTL-wait" path: the tombstone makes roster()
    DROP the dev on the very NEXT read — no 45s online-window wait — so a `hmd presence off`
    vanishes the dev from teammates' walls promptly. A later normal beat (record_presence,
    retired absent) overwrites the tombstone and the dev reappears (re-opt-in).

    The record KEY is the SERVER-VERIFIED haid (a dev can only retire ITSELF, never a
    teammate); team_id is the (project, team) partition, resolved from the caller's binding at
    the route, NEVER a body field. DATA only — a tombstone runs nothing. Returns
    {ok, haid, project, team_id, retired} on a stored write, {ok: False, reason} on IO
    failure. Routed THROUGH the StateBackend (put_record) — Firestore-durable on Cloud Run,
    byte-identical on local; NEVER backend.path()."""
    if not haid:
        return {"ok": False, "reason": "no_haid"}
    record = {
        "haid": haid,
        "project": _clean(project),
        "retired": True,
        # epoch seconds — a fresh tombstone; is_online() keeps it "recent" so the
        # retired guard (not the TTL) is what removes the dev on the next read.
        "ts": float(ts) if isinstance(ts, (int, float)) else time.time(),
    }
    if not _backend(home).put_record(_record_rel(project, team_id, haid), record):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "haid": haid, "project": record.get("project"),
            "team_id": team_id, "retired": True}


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


def roster(project, team_id, *, home=None, now=None, ttl=None):
    """The ONLINE devs for a (project, team): the fold of the latest heartbeat per dev,
    filtered to those within the TTL, sorted by haid for a stable view. Read-only; an absent
    partition yields [] (honest empty — a nonexistent team and an idle team are
    indistinguishable, no existence oracle). Each returned record carries an added
    "online": True and "age_seconds" (now - ts, rounded) for the renderer.

    `team_id` SCOPES the read to exactly ONE partition dir (presence/<project>/<team_id>/) —
    the isolation guarantee: a read for team A never enumerates team B's records. The caller
    resolves team_id from the signed member's binding OR the presented secret's hash; it is
    NEVER taken on trust from a request body.

    Routed THROUGH the StateBackend: list_names returns the SAME sorted enumeration of the
    partition's dev-record basenames on EVERY backend (leaf .json names directly under
    presence/<project>/<team_id>/ — FirestoreBackend recovers them from the flat doc-id
    prefix), and get_record returns the SAME tolerant keyed read (None when absent/corrupt). A
    BACKEND-SAFE read end to end: NEVER backend.path() (FirestoreBackend refuses it) —
    list_names + get_record are served by every backend, so the cross-dev roster read
    never raises under firestore (the firestore-only read-path incident class)."""
    backend = _backend(home)
    when = now if now is not None else time.time()
    window = ttl if ttl is not None else ttl_seconds()
    out = []
    team_dir = _team_rel(project, team_id)
    for name in backend.list_names(team_dir, suffix=_RECORD_SUFFIX):
        rel = os.path.join(team_dir, name)
        record = backend.get_record(rel)
        if not is_online(record, now=when, ttl=window):
            continue
        # RETIREMENT (opt-out) is honored HERE, at the READ AUTHORITY — the server
        # drops a retired dev from EVERY roster read (the signed /roster AND the
        # team-secret /roster-team), so opt-out is REAL (server-side), not cosmetic
        # client-hiding. A dev who ran `hmd presence off` posted a retire tombstone
        # ({retired: true}); it disappears them on the NEXT read, no 45s TTL wait. A
        # later normal beat overwrites the tombstone (retired absent) and they
        # reappear (re-opt-in). THE FALSIFIER: drop this guard and a retired dev
        # reappears on the roster -> test/heimdall-presence-optout.test.sh goes RED.
        if isinstance(record, dict) and record.get("retired"):
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


def _partition_team(haid, request, *, home=None):
    """The (project, team) PARTITION handle a signed beat / retire / self-roster writes or reads
    under. PREFER the PRESENTED team_secret — the SAME capability the browser /roster-team read
    hashes to its partition (cp_auth.derive_team_id) — so a member's signed beat lands in EXACTLY
    the partition its team.json secret reads back: the write<->read round-trip closes on ONE
    derived partition (the BUG2 "viral-loop gate" fix). WITHOUT this, the WRITE partition came from
    the ENROLL-TIME binding (cp_auth.registered_team) while the READ partition (/roster-team) comes
    from the PRESENTED secret — for a LEGACY binding (no team_id -> default/None) or a STALE binding
    (enrolled under an older secret) those DIFFER, so a valid beat lands in a black-hole partition
    the roster read never enumerates and the beater is invisible to its own team.

    The secret rides the X-Heimdall-Team-Secret HEADER (cp_server lifts it into
    request["team_secret"]); it is hashed ONE-WAY and never stored / echoed. FALL BACK to the
    enroll-time registry binding ONLY when NO secret is presented — back-compat: an older client
    that sends no secret still scopes to its bound team (and a legacy no-team_id binding still reads
    as the default team).

    ISOLATION is preserved (rr-multitenant-isolation / cp-team-isolation): the presented secret is a
    bearer team capability — holding it IS membership, the IDENTICAL trust the /roster-team read
    already grants — and the record stays keyed by the SERVER-VERIFIED haid, so a caller can only
    ever write ITS OWN presence, into a team whose secret it holds. A different secret hashes to a
    different partition, so a beat can never cross-write another team; team_id (the hash) presented
    AS a secret is inert (derive of it is a wrong partition)."""
    secret = request.get("team_secret") if isinstance(request, dict) else None
    if secret:
        tid = cp_auth.derive_team_id(secret)
        if tid:
            return tid
    return cp_auth.registered_team(haid, home=home)


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
    # team_id from the PRESENTED team secret (the X-Heimdall-Team-Secret header, hashed one-way)
    # when supplied — so the beat WRITES into EXACTLY the partition /roster-team READS from that
    # same secret (the BUG2 round-trip); else the VERIFIED identity's registry binding (NEVER a
    # body field). A binding with no team_id reads as the default team (§migration). See
    # _partition_team for the isolation argument (the secret is a bearer capability; the record
    # stays keyed by the verified haid, so a member can only write ITS OWN presence into a team
    # whose secret it holds).
    team_id = _partition_team(haid, request, home=home)
    result = record_presence(
        haid, project=project, team_id=team_id, handle=payload.get("handle"),
        verdict=payload.get("verdict"), file=payload.get("file"), home=home)
    if not result.get("ok"):
        # LOUD on a DROPPED write (the firestore-only silent-drop class). A backend write that
        # fails must NEVER look like a silent 200: it surfaces as a 500 to the client AND is
        # NAMED on the server log here, so an operator sees "beat NOT stored" instead of an empty
        # roster with no trace. Best-effort log (suppressed) never masks the honest 500.
        reason = result.get("reason", "io_error")
        with contextlib.suppress(Exception):
            sys.stderr.write(
                "cp_presence: beat NOT stored haid=%s project=%s team=%s reason=%s\n"
                % (haid, project, team_id, reason))
        return cp_server.Response(500, {"recorded": False, "reason": reason})
    # ABUSE THROTTLE (cost-governance §3) — count this beat against the team's daily write volume
    # and, on a sampled cadence, coalesce a >50×-median write-flooder to the interval-ladder max
    # (cp_anomaly). FLAG-GATED (HEIMDALL_ANOMALY_TRACK): inert on the gated/single-tenant path (no
    # per-beat write added). Best-effort — the throttle never fails an accepted beat (observe_beat
    # swallows its own faults), so a store hiccup in the counter cannot turn a good beat into a 500.
    import cp_anomaly  # lazy — the write-flood throttle; mirrors cp_boot's lazy tenant-runner import.
    if cp_anomaly.tracking_enabled():
        cp_anomaly.observe_beat(team_id, home=home)
    return cp_server.Response(
        200, {"recorded": True, "haid": haid, "project": result.get("project"),
              "team_id": team_id})


def roster_route(identity, request, *, home=None):
    """GET /roster?project=<p> — the ONLINE devs for the CALLER'S OWN team on a project
    (§presence). The project rides the QUERY STRING with an EMPTY body (the GFE-safe read
    shape; the signature covers the full path-with-query). team_id is resolved from the
    VERIFIED caller's registry binding (cp_auth.registered_team) — so a signed member sees
    ONLY their own team's roster. This REPLACES the prior behavior where any signed dev saw
    any project's full roster (the cross-team leak): team_id is the load-bearing scope, taken
    from the binding, never the request. Reads the durable per-dev records and folds the
    roster (replay-on-read). 422 when no project is supplied. DATA only — runs nothing."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    payload = _parse_body(request)
    project = _query_project(request, payload)
    if not project:
        return cp_server.Response(
            422, {"reason": "no_project", "roster": []})
    # Same partition resolution as the beat: PREFER the presented team secret (so the caller's own
    # `roster` read is scoped to the SAME partition its beats wrote), else the registry binding.
    team_id = _partition_team(haid, request, home=home)
    return cp_server.Response(
        200, {"project": project, "team_id": team_id,
              "roster": roster(project, team_id, home=home)})


def retire_route(identity, request, *, home=None):
    """POST /presence-retire — RETIRE the caller's presence (the opt-out prompt-disappearance
    path). The server ran the §3 auth chokepoint BEFORE this, so `identity` is a VERIFIED
    cp_auth.Identity; the tombstone is keyed by identity.haid (the VERIFIED HAID) — a dev can
    only retire ITSELF, never a teammate. team_id is resolved from the VERIFIED caller's
    registry binding (cp_auth.registered_team), NEVER a body field, so the retirement lands in
    the caller's OWN team partition.

    Body (JSON): {project} — the project to retire from (the client sends its repo's project).
    Writes a retirement tombstone so the dev drops from teammates' rosters on the next read
    (no TTL wait). 200 with the retire summary on a write, 422 when no project is supplied,
    500 on an IO failure. DATA ONLY — dispatches nothing, runs no handler."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    payload = _parse_body(request)
    project = payload.get("project")
    if not project:
        return cp_server.Response(
            422, {"retired": False, "reason": "no_project"})
    # Retire into the SAME partition the beat wrote: PREFER the presented team secret, else the
    # registry binding — so a `presence off` tombstones exactly where the dev is visible.
    team_id = _partition_team(haid, request, home=home)
    result = record_retire(haid, project=project, team_id=team_id, home=home)
    if not result.get("ok"):
        return cp_server.Response(
            500, {"retired": False, "reason": result.get("reason", "io_error")})
    return cp_server.Response(
        200, {"retired": True, "haid": haid, "project": result.get("project"),
              "team_id": team_id})


# ── the TEAM-PRIVATE browser read (GET /roster-team — the static dashboard's read) ──
#
# WHY THIS ROUTE. The signed GET /roster needs a PKI signature; a BROWSER cannot sign, so the
# static heimdall-site dashboard would 401. /roster-team is the unauthenticated-at-the-edge,
# rate-limited, READ-ONLY read whose APP-LAYER auth is the TEAM SECRET presented in the
# X-Heimdall-Team-Secret HEADER: the server hashes it to team_id (cp_auth.derive_team_id) and
# returns ONLY that partition's roster — the FULL member view INCLUDING haid (members are
# entitled to see each other's haid + activity per the requirement). No header -> 403 (NOT an
# empty 200). A presented team_id (the hash, not the pre-image) hashes again to a WRONG
# partition -> empty: team_id is INERT, never a capability. The secret rides a HEADER, never the
# URL query (a query leaks to access logs / Referer / history — Risk 2).
#
# THE OLD /roster-public IS GONE. It was fully public (handles/verdicts/files to anyone); under
# the private model the team read exposes haid + activity, which must NOT be public. /roster-team
# REPLACES it; /roster-public now returns 403 on the public surface (the old leak is closed).

# CORS for the browser read. Access-Control-Allow-Origin:* lets a different-origin static site
# SEND the request; it can only READ the response with the user's explicit secret (no cookies /
# ambient credential, so `*` is safe). The preflight advertises the custom secret header.
_CORS_HEADERS = {"Access-Control-Allow-Origin": "*"}
_CORS_PREFLIGHT_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "X-Heimdall-Team-Secret",
    "Access-Control-Max-Age": "86400",
}


def _team_view(record):
    """Project ONE online roster record to the MEMBER view: haid + handle + verdict + file +
    age_seconds. This INCLUDES haid (the deliberate difference from the old public view) — but
    only a PROVEN member (a caller who presented the team secret) ever receives it. The free
    fields are already scrubbed at write time (build_record -> _clean -> telemetry._scrub), so
    no secret can reach here; ts is dropped (age_seconds carries the freshness)."""
    return {
        "haid": record.get("haid"),
        "handle": record.get("handle"),
        "verdict": record.get("verdict"),
        "file": record.get("file"),
        "age_seconds": record.get("age_seconds"),
    }


def roster_team_route(request, *, home=None):
    """GET /roster-team?project=<id> — the TEAM-PRIVATE browser read. App-layer auth is the
    team secret in the X-Heimdall-Team-Secret HEADER (cp_server lifts it to
    request["team_secret"]); the server derives team_id and returns the FULL member view
    (incl. haid) for (project, team_id). Served PRE-AUTH, but ONLY on the public surface; off
    it the route does not exist (404), so the gated IAM service is unchanged.

    No secret header -> 403 (NOT an empty 200 — the read demands the capability). A presented
    team_id (the hash) -> a wrong partition -> empty (team_id is inert). A random/unknown secret
    -> a partition with no records -> {online: []} (no existence oracle: a nonexistent team and
    an idle team are indistinguishable). 400 when project is missing; 429 when the per-IP
    read-flood cap trips. DATA only — runs nothing, never backend.path()."""
    if not cp_publicsurface.public_surface_enabled():
        return cp_server.Response(404, {"error": "no_such_route"}, headers=_CORS_HEADERS)
    refusal = cp_publicsurface.check_roster_read(request, home=home)
    if refusal is not None:
        status, body = refusal
        return cp_server.Response(status, body, headers=_CORS_HEADERS)
    secret = request.get("team_secret") if isinstance(request, dict) else None
    if not secret:
        # No capability presented — 403 (never an empty 200 that would mask the missing auth).
        return cp_server.Response(
            403, {"error": "team_secret_required", "online": []}, headers=_CORS_HEADERS)
    project = _query_project(request, None)
    if not project:
        return cp_server.Response(
            400, {"error": "no_project", "online": []}, headers=_CORS_HEADERS)
    # Hash the presented secret to the partition handle (one-way; no secret-to-secret compare,
    # no stored secret). The raw secret is consumed here and never stored/echoed.
    team_id = cp_auth.derive_team_id(secret)
    online = [_team_view(view) for view in roster(project, team_id, home=home)]
    return cp_server.Response(
        200, {"project": project, "online": online}, headers=_CORS_HEADERS)


def roster_team_preflight(request):
    """OPTIONS /roster-team — the CORS preflight for the browser read. Returns 204 + the CORS
    headers (incl. Access-Control-Allow-Headers: X-Heimdall-Team-Secret) so a different-origin
    static site may then issue the GET with the secret header. Public-surface only; 404s on the
    gated service exactly as the GET does."""
    if not cp_publicsurface.public_surface_enabled():
        return cp_server.Response(404, {"error": "no_such_route"})
    return cp_server.Response(204, None, headers=_CORS_PREFLIGHT_HEADERS)


def roster_public_route(request, *, home=None):
    """GET /roster-public — RETIRED. The old fully-public roster leaked handles/verdicts/files
    to anyone; the private team model forbids that, so this read is GONE. On the public surface
    it returns 403 (the leak is closed; team.html moved to /roster-team); off the public surface
    it 404s like any other non-existent route. NEVER returns a roster."""
    if not cp_publicsurface.public_surface_enabled():
        return cp_server.Response(404, {"error": "no_such_route"}, headers=_CORS_HEADERS)
    return cp_server.Response(
        403, {"error": "roster_public_retired", "online": []}, headers=_CORS_HEADERS)


def register(*, home=None):
    """Wire POST /presence (heartbeat) + GET /roster (the caller's-own-team read) into
    cp_server's registration seam (§10), and the TEAM-PRIVATE GET/OPTIONS /roster-team browser
    read into the PRE-AUTH public seam (register_public_route — the static dashboard cannot
    sign), all WITHOUT editing cp_server. The retired GET /roster-public stays registered so it
    returns 403 (not a flat 404) on the public surface — the old leak is closed explicitly. The
    handlers close over the runtime `home` so a self-host deployment / a test can pin its store
    root. Returns the registered (method, path) keys. Idempotent — re-registering replaces the
    routes. Mirrors cp_ingest.register / cp_enroll.register (pre-auth public routes) exactly."""
    keys = []
    keys.append(cp_server.register_route(
        "POST", "/presence",
        lambda identity, request: beat_route(identity, request, home=home)))
    keys.append(cp_server.register_route(
        "GET", "/roster",
        lambda identity, request: roster_route(identity, request, home=home)))
    # POST /presence-retire — the opt-out prompt-disappearance path: a signed member retires
    # its OWN presence (a tombstone keyed by the verified haid), dropping off teammates' walls
    # on the next read. Authenticated seam (only a signed member can retire itself).
    keys.append(cp_server.register_route(
        "POST", "/presence-retire",
        lambda identity, request: retire_route(identity, request, home=home)))
    # The TEAM-PRIVATE browser read + its CORS preflight (pre-auth; public-surface-only,
    # self-gated inside the handlers; secret-header authorized; per-IP rate-limited; READ-ONLY).
    keys.append(cp_server.register_public_route(
        "GET", "/roster-team",
        lambda request: roster_team_route(request, home=home)))
    keys.append(cp_server.register_public_route(
        "OPTIONS", "/roster-team",
        lambda request: roster_team_preflight(request)))
    # The RETIRED public read — kept registered so it 403s (not 404s) on the public surface.
    keys.append(cp_server.register_public_route(
        "GET", "/roster-public",
        lambda request: roster_public_route(request, home=home)))
    return keys
