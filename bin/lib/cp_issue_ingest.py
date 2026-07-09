#!/usr/bin/env python3
# cp_issue_ingest.py — ANONYMIZED ISSUE INGEST on the control plane (Wave 2, issue-collection).
#
# WHAT THIS IS: the SERVER-SIDE sibling of cp_corpus.py, for the issue_v1 stream. A teammate's
# hmd session spools zero-content `issue_v1` metadata (issue_corpus.emit_issue) and FLUSHES it to
# the CP's SIGNED POST /issues; THIS module is that ingest route + the issue store. It mirrors
# cp_corpus.py exactly, with the SAME four corpus-specific rules — and one extra fail-closed drop:
#
#   1. ITS OWN ISOLATED KEYSPACE (INV-G) — issues land under the ISOLATED
#      heimdall_corpus/ namespace (cp_state.get_backend(namespace=pmr_corpus.corpus_namespace()))
#      in a partition prefix (`issues/`) DISJOINT from the control-plane presence/ops/team store
#      AND from the corpus's own t0/t1 partitions. An issue read can NEVER resolve a presence/team
#      rel and vice-versa; team B can NEVER read team A's partition. The rr-multitenant-isolation
#      keystone stays 1.0.
#
#   2. SERVER-DERIVED team_id_hash (INV-C/INV-1) — the partition KEY is
#      cp_auth.registered_team(haid) from the VERIFIED signed identity, NEVER a body field. A
#      client's carried team_id_hash (nested at ids.team_id_hash) is RE-STAMPED with the
#      server-derived one, so a client can only ever write its OWN team's partition. No team
#      resolves -> 403 fail-closed.
#
#   3. ZERO-CONTENT-BY-CONSTRUCTION + SECRET-SCAN AT THE BOUNDARY (INV-A/T2) — every record is
#      RE-RUN through issue_corpus.rebuild_issue server-side (the closed-schema, zero-content
#      rebuild: a smuggled path / off-schema key / raw stack never lands) and then RE-SCANNED for
#      secret shapes (pmr_corpus.secret_scan_payload); a finding DROPS the record + alarms.
#
#   4. DATA-ONLY, EXECUTES NOTHING (control/data line) — issue ingest writes records; it resolves
#      NO action_type, runs NO handler, spawns NO process, and makes NO model call. An issue is
#      stored DATA, never a thing to run.
#
#   +  SECURITY-SENSITIVE DROP AT THE BOUNDARY (INV-F, fail-closed) — a security_sensitive:true
#      record should NEVER have been sent (the client routes it to the private .planning/ lane),
#      but if one arrives it is DROPPED at the boundary and counted, never stored in the public
#      issue partition.
#
# THE INTERFACE the server + jobs BIND to (stable):
#   register(*, home=None)                        — wire POST /issues into cp_server's seam.
#   issues_route(identity, request, ...)          — the route handler (verified Identity in).
#   ingest_issues(team_id_hash, issues, ...)      — the pure boundary: rebuild/scan/drop, store, audit.
#   list_teams(...) / read_team_issues / all_issues — the job read path (the aggregate binds here).
#
# stdlib-only (json/os/sys) + cp_audit/cp_auth/cp_server (the substrate) + cp_state (the ISOLATED
# corpus backend) + issue_corpus (rebuild_issue) + pmr_corpus (namespace + secret scan) — the SAME
# dependency shape cp_corpus has. Does NOT register itself (that is the wave-3 wire-boot task); it
# EXPOSES register() for the boot seam to call. Does NOT edit cp_corpus.py (byte-green).

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit      # REUSE the §9 audit writer — one issue_ingest row (COUNTS only) per batch.
import cp_auth       # the verified Identity + registered_team (server-derived team_id_hash, INV-C).
import cp_server     # REUSE register_route + Response — the §10 registration seam.
import cp_state      # the pluggable persistence backend — used with the CORPUS NAMESPACE so issues
                     # land in a DISJOINT keyspace (heimdall_corpus/issues/), never the shared
                     # control-plane store. Same put/get/list/append contract; firestore-durable.
import issue_corpus  # the shared issue_v1 contract: rebuild_issue (the closed-schema, zero-content
                     # boundary rebuild that DROPS unknown keys and re-guards content).
import pmr_corpus    # corpus_namespace() (the isolated keyspace) + secret_scan_payload (the belt).

# ── store layout (partitioned by the SERVER-DERIVED team_id_hash, in the corpus namespace) ──
#
# Every rel is RELATIVE to the CORPUS namespace root (heimdall_corpus/ — NOT control-plane/). The
# issue log is issues/<team_hash>/issues.ndjson (append-only per team). The `issues/` prefix is
# DISJOINT from the corpus's own t0/ + t1/ partitions and from every control-plane rel, so no read
# path crosses partitions. The partition KEY is the server-derived team_id_hash (INV-C), so a
# member can only ever append to its OWN team's issue partition. NDJSON so a plaintext scan works.

_ISSUE_PARTITION = "issues"   # the top-level issue keyspace prefix, disjoint from t0/t1/control-plane.
_ISSUE_FILE = "issues.ndjson"  # the per-team append-only log.

# A conservative slug bound for a team_id_hash used as a path segment (mirrors cp_corpus._SLUG_MAX).
# A team_id_hash is 32-hex already ('_'-free), but the slug guards any odd shape (firestore-safe).
_SLUG_MAX = 80


def _backend(home=None):
    """The ISOLATED issue StateBackend (HEIMDALL_STATE_BACKEND, default local) rooted at the CORPUS
    namespace (pmr_corpus.corpus_namespace()) — a DISJOINT keyspace from the control-plane store.
    `home` pins the store root exactly as every CP accessor's `home=` arg threads through. THIS is
    the store-isolation seam (INV-G): the issue backend can never resolve a control-plane rel."""
    return cp_state.get_backend(home=home, namespace=pmr_corpus.corpus_namespace())


def _slug(value):
    """A filesystem-/firestore-safe, bounded path slug for a team_id_hash (mirrors cp_corpus._slug):
    keep [A-Za-z0-9._-], map every other char to '_', 'unknown' for empty. A 32-hex team_id_hash
    passes through unchanged (no '__' run — firestore-flat-safe)."""
    raw = str(value or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _issue_rel(team_hash):
    """The store-relative issue log path for a team: issues/<team_hash>/issues.ndjson."""
    return os.path.join(_ISSUE_PARTITION, _slug(team_hash), _ISSUE_FILE)


# ── the pure ingest boundary (rebuild/scan/drop → store → audit) ────────────────


def ingest_issues(team_id_hash, issues, *, home=None):
    """THE issue ingest boundary. Under the SERVER-DERIVED team_id_hash (INV-C):
      • RE-RUN issue_corpus.rebuild_issue on every record (the closed-schema, zero-content
        boundary: a smuggled path / off-schema key / raw stack never lands). None => dropped.
      • DROP any security_sensitive:true record fail-closed (INV-F) — it should have gone to the
        private lane; it NEVER enters the public issue partition. Counted as blocked_security.
      • SECRET-SCAN the rebuilt record server-side (pmr_corpus.secret_scan_payload) as a belt — a
        finding DROPS the record (never stored) + alarms. Counted as blocked_secret.
      • STAMP the server-derived team_id_hash (overwriting any client-carried ids.team_id_hash,
        INV-C) and append to the team's issue partition in the ISOLATED corpus namespace.
      • AUDIT one issue_ingest row (COUNTS only, never values).

    DATA ONLY — never resolves an action_type, runs a handler, spawns a process, or makes a model
    call. Returns a result dict:
      {team_id_hash, received, stored, blocked_secret, blocked_security, audit_id}
    Never raises into the caller — a bad batch degrades to dropped lines, not a crash."""
    backend = _backend(home)

    received = len(issues) if isinstance(issues, (list, tuple)) else 0
    stored = 0
    blocked_secret = 0
    blocked_security = 0
    rel = _issue_rel(team_id_hash)

    if isinstance(issues, (list, tuple)):
        for line in issues:
            clean = issue_corpus.rebuild_issue(line)
            if clean is None:
                # off-schema / non-dict / failed the zero-content re-guard — dropped, never stored.
                continue

            # INV-F — a security-sensitive record NEVER lands in the public partition. It should
            # have been routed to the private .planning/ lane client-side; drop it fail-closed here.
            if clean.get("security_sensitive"):
                blocked_security += 1
                continue

            # THE SECRET BELT — the rebuilt record is zero-content by construction, but re-scan at
            # the boundary (never trust the client). ANY finding drops the record + alarms.
            ok, findings = pmr_corpus.secret_scan_payload(clean)
            if not ok:
                blocked_secret += 1
                pmr_corpus._alarm("issue-ingest-secret-scan",
                                  {"findings": findings, "team_id_hash": team_id_hash}, home)
                continue

            # INV-C — the stored partition + the record's own team_id_hash are the SERVER-derived
            # handle, never the client's claimed one. A client cannot attribute to another team.
            ids = clean.get("ids")
            if not isinstance(ids, dict):
                ids = {}
                clean["ids"] = ids
            ids["team_id_hash"] = team_id_hash

            if backend.append_line(rel, clean, fsync=False):
                stored += 1

    # AUDIT one issue_ingest row — SHAPE only (counts), never an issue value or a signature byte.
    audit_id = cp_audit.write(
        "issue_ingest", actor_haid=None,
        params={"received": received, "stored": stored,
                "blocked_secret": blocked_secret, "blocked_security": blocked_security},
        outcome="ok" if stored else "refused",
        detail="issue batch ingested" + (
            " (blocked %d secret-bearing)" % blocked_secret if blocked_secret else "") + (
            " (dropped %d security-sensitive)" % blocked_security if blocked_security else ""),
        home=home,
    )
    return {
        "team_id_hash": team_id_hash,
        "received": received, "stored": stored,
        "blocked_secret": blocked_secret, "blocked_security": blocked_security,
        "audit_id": audit_id,
    }


# ── the route handler (verified Identity in — the server already authed it, §3) ─


def _parse_batch(request):
    """Extract the issue list from a request. The wire body is JSON: {"issues": [...]} (the key
    optional), OR a bare list (treated as the issues). Tolerant — a malformed/empty body yields [].
    Recognizes NOTHING executable: there is no action_type/cmd/handler key in this schema and none
    is honored even if a client sends one."""
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
        issues = body.get("issues")
        return issues if isinstance(issues, list) else []
    return []


def issues_route(identity, request, *, home=None):
    """POST /issues — INGEST a client's spooled issue_v1 batch. The server ran the §3 auth
    chokepoint BEFORE this, so `identity` is a VERIFIED cp_auth.Identity — an unsigned / forged /
    unknown / revoked push never reaches here (401 at the seam, INV-E). The issue partition is
    keyed by the SERVER-DERIVED team_id_hash (registered_team of the verified haid), NEVER a body
    field (INV-C).

    Body (JSON): {issues:[issue_v1...]}. DATA ONLY — dispatches nothing, runs no handler, makes no
    model call. 200 with the batch summary on any store; 403 when no team resolves (fail-closed —
    an issue must be team-attributable for k-anonymity); 422 when nothing stored (an all-dropped
    batch is refused, audited)."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    # INV-C — the team_id_hash is the caller's SERVER-DERIVED team partition, never the body. A
    # binding with no team resolves to the default team (registered_team); still falsy -> 403.
    team_id_hash = cp_auth.registered_team(haid, home=home)
    if not team_id_hash:
        return cp_server.Response(403, {"ingested": False, "reason": "no_team"})
    issues = _parse_batch(request)
    result = ingest_issues(team_id_hash, issues, home=home)
    if result["stored"] <= 0:
        return cp_server.Response(
            422,
            {"ingested": False, "reason": "no_storable_records",
             "received": result["received"],
             "blocked_secret": result["blocked_secret"],
             "blocked_security": result["blocked_security"]},
            audit_id=result["audit_id"],
        )
    return cp_server.Response(
        200,
        {"ingested": True, "team_id_hash": team_id_hash,
         "stored": result["stored"],
         "blocked_secret": result["blocked_secret"],
         "blocked_security": result["blocked_security"]},
        audit_id=result["audit_id"],
    )


def register(*, home=None):
    """Wire POST /issues into cp_server's registration seam (§10) WITHOUT editing cp_server.
    Returns the registered (method, path) key. The handler closes over the runtime `home` so a
    self-host deployment / a test can pin its store root. After this, a signed instance POSTing
    /issues reaches issues_route with its verified Identity. Idempotent — re-registering replaces
    the route. The wave-3 wire-public-surface task adds POST /issues to cp_publicsurface.PUBLIC_
    ROUTES so it is served (signed, gated) on the public surface too, exactly like /corpus."""
    return cp_server.register_route(
        "POST", "/issues",
        lambda identity, request: issues_route(identity, request, home=home),
    )


# ── the issue READ path (the aggregate + synth jobs bind to these) ──────────────


def list_teams(home=None):
    """The team_id_hash partition slugs present in the issue store (the teams that have pushed).
    Read-only; an absent store yields [] (honest empty). The aggregate job counts DISTINCT teams
    over this for the k-anonymity gate. Backend-safe: list_names + exists (never backend.path() —
    firestore-safe)."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(_ISSUE_PARTITION):
        if backend.exists(os.path.join(_ISSUE_PARTITION, name, _ISSUE_FILE)):
            names.append(name)
    return names


def read_team_issues(team_hash, home=None):
    """Stream one team's stored issue_v1 records (the aggregate's per-team scan). Tolerant: a bad
    line is skipped, an absent partition yields []. Read-only — never writes, never executes."""
    return _backend(home).read_lines(_issue_rel(team_hash))


def all_issues(home=None):
    """Every stored issue_v1 across every team partition (the aggregate's corpus-wide fold). Each
    record carries its server-stamped team_id_hash, so a reader can bucket + count distinct teams
    for the k-anonymity gate. Read-only."""
    out = []
    for team in list_teams(home=home):
        out.extend(read_team_issues(team, home=home))
    return out
