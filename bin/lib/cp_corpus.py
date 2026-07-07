#!/usr/bin/env python3
# cp_corpus.py — PRE-MERGE CORPUS INGEST on the control plane (spec §5.2).
#
# DESIGN: heimdall-premerge-corpus-spec.md §3/§5.2 (authoritative). Clients spool their
# zero-content PMR T0 records (pmr_corpus.build_pmr) and, opt-in, T1 deny-context hunks, then
# FLUSH them to the CP's signed POST /corpus. THIS module is that ingest route + the corpus
# store. It is the sibling of cp_ingest.py (POST /ingest) but with FOUR corpus-specific rules:
#
#   1. ITS OWN NAMESPACE (spec §3 L49) — the corpus lands in the ISOLATED heimdall_corpus/
#      namespace (cp_state.get_backend(namespace=pmr_corpus.corpus_namespace())), a DISJOINT
#      keyspace from control-plane presence/ops/team data. A corpus read can NEVER resolve a
#      presence/team rel and vice-versa — the store-isolation guarantee (falsifiable in
#      test/heimdall-corpus-ingest.test.sh). The corpus has its OWN retention policy.
#
#   2. SERVER-DERIVED team_id_hash (INV-1) — the partition KEY is cp_auth.registered_team(haid)
#      from the VERIFIED signed identity, NEVER a body field. A client's carried team_id_hash is
#      RE-STAMPED with the server-derived one, so a client can only ever write its OWN team's
#      corpus partition — a corpus ingest creates NO cross-tenant write path (the standing
#      multi-tenant isolation oracle stays 1.0). No team resolves -> 403 fail-closed.
#
#   3. NO-SECRET-BY-CONSTRUCTION + SECRET-SCAN AT THE BOUNDARY (spec §2) — every T0 PMR is
#      RE-RUN through pmr_corpus.rebuild_pmr server-side (the closed-schema, scrubbed rebuild: a
#      smuggled source line / off-schema key never lands). Every T1 hunk is SECRET-SCANNED
#      server-side (pmr_corpus.scan_for_secrets) BEFORE it is stored — a planted-secret hunk is
#      DROPPED + alarmed (a leaked secret in the corpus is the brand-killing incident). The
#      discipline is enforced at the BOUNDARY, never trusted from the client.
#
#   4. DATA-ONLY, EXECUTES NOTHING (spec §2 control/data line) — corpus ingest writes records; it
#      has NO dispatch path, resolves NO action_type, runs NO handler, spawns NO process, and
#      makes NO model call (BYO-inference: no LLM on prod). A PMR is stored DATA, never a thing
#      to run.
#
# THE INTERFACE the server + jobs BIND to (stable):
#   register(*, home=None)                       — wire POST /corpus into cp_server's seam.
#   corpus_route(identity, request, ...)         — the route handler (verified Identity in).
#   ingest_corpus(team_id_hash, pmrs, hunks, ..) — the pure boundary: rebuild/scan, store, audit.
#   list_teams(...) / read_team_pmrs / read_team_hunks / all_pmrs / all_hunks — the job read path.
#
# stdlib-only (json/os/sys) + cp_audit/cp_auth/cp_server (the substrate) + cp_state (the ISOLATED
# corpus backend) + pmr_corpus (the shared contract) — the SAME dependency shape cp_ingest has.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_audit     # REUSE the §9 audit writer — one corpus_ingest row per accepted batch.
import cp_auth      # the verified Identity + registered_team (server-derived team_id_hash, INV-1).
import cp_server    # REUSE register_route + Response — the §10 registration seam.
import cp_state     # the pluggable persistence backend — used with the CORPUS NAMESPACE so the
                    # corpus lands in a DISJOINT keyspace (heimdall_corpus/), never the shared
                    # control-plane store. Same put/get/list/append contract; firestore-durable.
import pmr_corpus   # the shared pmr_v1 contract: rebuild_pmr (no-secret/on-schema boundary),
                    # scan_for_secrets (the T1 secret belt), the namespace + partition names.

# ── store layout (partitioned by the SERVER-DERIVED team_id_hash, in the corpus namespace) ──
#
# Every rel is RELATIVE to the CORPUS namespace root (heimdall_corpus/ — NOT control-plane/).
# T0 metadata: t0/<team_hash>/pmr.ndjson (append-only per team). T1 hunks: t1/<team_hash>/
# hunks.ndjson. The partition KEY is the server-derived team_id_hash (INV-1), so a member can
# only ever append to its OWN team's corpus partition. NDJSON so a plaintext scan can inspect it.

_PMR_FILE = "pmr.ndjson"      # the per-team T0 append-only log.
_HUNK_FILE = "hunks.ndjson"   # the per-team T1 append-only log.

# A conservative slug bound for a team_id_hash used as a path segment (mirrors cp_ingest._SLUG_MAX).
# A team_id_hash is 32-hex already (single-"_"-free), but the slug guards any odd shape.
_SLUG_MAX = 80


def _backend(home=None):
    """The ISOLATED corpus StateBackend (HEIMDALL_STATE_BACKEND, default local) rooted at the
    CORPUS namespace (pmr_corpus.corpus_namespace()) — a DISJOINT keyspace from the control-plane
    store. `home` pins the store root exactly as every CP accessor's `home=` arg threads through.
    THIS is the store-isolation seam: the corpus backend can never resolve a control-plane rel."""
    return cp_state.get_backend(home=home, namespace=pmr_corpus.corpus_namespace())


def _slug(value):
    """A filesystem-/firestore-safe, bounded path slug for a team_id_hash (mirrors cp_ingest._slug):
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


def _t0_rel(team_hash):
    """The store-relative T0 log path for a team: t0/<team_hash>/pmr.ndjson."""
    return os.path.join(pmr_corpus.T0_PARTITION, _slug(team_hash), _PMR_FILE)


def _t1_rel(team_hash):
    """The store-relative T1 log path for a team: t1/<team_hash>/hunks.ndjson."""
    return os.path.join(pmr_corpus.T1_PARTITION, _slug(team_hash), _HUNK_FILE)


# ── the pure ingest boundary (rebuild/scan → store → audit — spec §5.2/§9) ──────


def ingest_corpus(team_id_hash, pmrs, hunks, *, home=None):
    """THE corpus ingest boundary (spec §5.2). Under the SERVER-DERIVED team_id_hash (INV-1):
      • RE-RUN pmr_corpus.rebuild_pmr on every T0 PMR (the no-secret / on-schema boundary), STAMP
        the server team_id_hash (overwriting any client-carried one), and append it to the team's
        t0 partition in the ISOLATED corpus namespace.
      • SECRET-SCAN every T1 hunk server-side (pmr_corpus.scan_for_secrets) BEFORE storing it — a
        hunk with ANY finding is DROPPED (never stored) and counted as blocked; a clean hunk gets
        the server team_id_hash stamped and is appended to the team's t1 partition.
      • AUDIT one corpus_ingest row (COUNTS only, never values).

    DATA ONLY — never resolves an action_type, runs a handler, spawns a process, or makes a model
    call. Returns a result dict:
      {team_id_hash, received_pmrs, stored_pmrs, received_hunks, stored_hunks,
       blocked_hunks, audit_id}
    Never raises into the caller — a bad batch degrades to dropped/blocked lines, not a crash."""
    backend = _backend(home)

    # ── T0: rebuild (scrub + on-schema) → stamp server team_id_hash → store ──
    received_pmrs = len(pmrs) if isinstance(pmrs, (list, tuple)) else 0
    stored_pmrs = 0
    t0_rel = _t0_rel(team_id_hash)
    if isinstance(pmrs, (list, tuple)):
        for line in pmrs:
            clean = pmr_corpus.rebuild_pmr(line)
            if clean is None:
                continue
            # INV-1 — the stored partition + the record's own team_id_hash are the SERVER-derived
            # handle, never the client's claimed one. A client cannot attribute to another team.
            clean["team_id_hash"] = team_id_hash
            if backend.append_line(t0_rel, clean, fsync=False):
                stored_pmrs += 1

    # ── T1: secret-scan (BELT) → stamp → store; a planted-secret hunk is DROPPED + alarmed ──
    received_hunks = len(hunks) if isinstance(hunks, (list, tuple)) else 0
    stored_hunks = 0
    blocked_hunks = 0
    t1_rel = _t1_rel(team_id_hash)
    if isinstance(hunks, (list, tuple)):
        for line in hunks:
            if not isinstance(line, dict):
                continue
            findings = pmr_corpus.scan_for_secrets(line)
            if findings:
                # THE BRAND-KILLING GUARD: a secret-bearing hunk NEVER lands in the corpus. It is
                # dropped and the batch's blocked count rises; the audit row records the block.
                blocked_hunks += 1
                continue
            record = dict(line)
            record["team_id_hash"] = team_id_hash   # INV-1 — server-derived attribution.
            if backend.append_line(t1_rel, record, fsync=False):
                stored_hunks += 1

    # AUDIT one corpus_ingest row — SHAPE only (counts), never a PMR value or a hunk byte.
    audit_id = cp_audit.write(
        "corpus_ingest", actor_haid=None,
        params={"received_pmrs": received_pmrs, "stored_pmrs": stored_pmrs,
                "received_hunks": received_hunks, "stored_hunks": stored_hunks,
                "blocked_hunks": blocked_hunks},
        outcome="ok" if (stored_pmrs or stored_hunks) else "refused",
        detail="corpus batch ingested" + (
            " (blocked %d secret-bearing hunk(s))" % blocked_hunks if blocked_hunks else ""),
        home=home,
    )
    return {
        "team_id_hash": team_id_hash,
        "received_pmrs": received_pmrs, "stored_pmrs": stored_pmrs,
        "received_hunks": received_hunks, "stored_hunks": stored_hunks,
        "blocked_hunks": blocked_hunks, "audit_id": audit_id,
    }


# ── the route handler (verified Identity in — the server already authed it, §3) ─


def _parse_batch(request):
    """Extract (pmrs, hunks) from a request. The wire body is JSON: {"pmrs": [...], "hunks": [...]}
    (either key optional), OR a bare list (treated as pmrs). Tolerant — a malformed/empty body
    yields ([], []). Recognizes NOTHING executable: there is no action_type/cmd/handler key in
    this schema and none is honored even if a client sends one."""
    body = request.get("body") if isinstance(request, dict) else None
    if body is None:
        return [], []
    if isinstance(body, (bytes, bytearray)):
        try:
            body = body.decode("utf-8")
        except (UnicodeDecodeError, AttributeError):
            return [], []
    if isinstance(body, str):
        try:
            body = json.loads(body or "null")
        except (ValueError, TypeError):
            return [], []
    if isinstance(body, list):
        return body, []
    if isinstance(body, dict):
        pmrs = body.get("pmrs")
        hunks = body.get("hunks")
        return (pmrs if isinstance(pmrs, list) else [],
                hunks if isinstance(hunks, list) else [])
    return [], []


def corpus_route(identity, request, *, home=None):
    """POST /corpus — INGEST a client's spooled PMR batch (spec §5.2). The server ran the §3 auth
    chokepoint BEFORE this, so `identity` is a VERIFIED cp_auth.Identity — an unsigned / forged /
    unknown / revoked push never reaches here (401 at the seam). The corpus partition is keyed by
    the SERVER-DERIVED team_id_hash (registered_team of the verified haid), NEVER a body field.

    Body (JSON): {pmrs:[pmr_v1...], hunks:[pmr_hunk_v1...]}. DATA ONLY — dispatches nothing, runs
    no handler, makes no model call. 200 with the batch summary on any store; 403 when no team
    resolves (fail-closed — a PMR must be team-attributable for k-anonymity); 422 when nothing
    stored (an all-dropped batch is refused, audited)."""
    haid = identity.haid if isinstance(identity, cp_auth.Identity) else identity
    # INV-1 — the team_id_hash is the caller's SERVER-DERIVED team partition, never the body. A
    # binding with no team resolves to the default team (registered_team); still None -> 403.
    team_id_hash = cp_auth.registered_team(haid, home=home)
    if not team_id_hash:
        return cp_server.Response(403, {"ingested": False, "reason": "no_team"})
    pmrs, hunks = _parse_batch(request)
    result = ingest_corpus(team_id_hash, pmrs, hunks, home=home)
    if result["stored_pmrs"] <= 0 and result["stored_hunks"] <= 0:
        return cp_server.Response(
            422,
            {"ingested": False, "reason": "no_storable_records",
             "received_pmrs": result["received_pmrs"],
             "received_hunks": result["received_hunks"],
             "blocked_hunks": result["blocked_hunks"]},
            audit_id=result["audit_id"],
        )
    return cp_server.Response(
        200,
        {"ingested": True, "team_id_hash": team_id_hash,
         "stored_pmrs": result["stored_pmrs"], "stored_hunks": result["stored_hunks"],
         "blocked_hunks": result["blocked_hunks"]},
        audit_id=result["audit_id"],
    )


def register(*, home=None):
    """Wire POST /corpus into cp_server's registration seam (§10) WITHOUT editing cp_server.
    Returns the registered (method, path) key. The handler closes over the runtime `home` so a
    self-host deployment / a test can pin its store root. After this, a signed instance POSTing
    /corpus reaches corpus_route with its verified Identity. Idempotent — re-registering replaces
    the route. The route is added to cp_publicsurface.PUBLIC_ROUTES so it is served (signed,
    gated) on the public surface too."""
    return cp_server.register_route(
        "POST", "/corpus",
        lambda identity, request: corpus_route(identity, request, home=home),
    )


# ── the corpus READ path (the aggregate + rule-synthesis jobs bind to these) ────


def list_teams(home=None):
    """The SORTED team_id_hash partition slugs present in the T0 corpus (the teams that have
    pushed metadata). Read-only; an absent corpus yields [] (honest empty). The aggregate job
    counts DISTINCT teams over this for the k-anonymity gate. Backend-safe: list_names +
    exists (never backend.path() — firestore-safe)."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(pmr_corpus.T0_PARTITION):
        if backend.exists(os.path.join(pmr_corpus.T0_PARTITION, name, _PMR_FILE)):
            names.append(name)
    return names


def list_hunk_teams(home=None):
    """The SORTED team_id_hash partition slugs present in the T1 (hunk) corpus — the opted-in
    teams whose deny-context the rule-synthesis job reads. Read-only; absent -> []."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(pmr_corpus.T1_PARTITION):
        if backend.exists(os.path.join(pmr_corpus.T1_PARTITION, name, _HUNK_FILE)):
            names.append(name)
    return names


def read_team_pmrs(team_hash, home=None):
    """Stream one team's stored T0 PMRs (the aggregate's per-team scan). Tolerant: a bad line is
    skipped, an absent partition yields []. Read-only — never writes, never executes."""
    return _backend(home).read_lines(_t0_rel(team_hash))


def read_team_hunks(team_hash, home=None):
    """Stream one team's stored T1 hunks (the rule-synthesis per-team scan). Tolerant; absent -> []."""
    return _backend(home).read_lines(_t1_rel(team_hash))


def all_pmrs(home=None):
    """Every stored T0 PMR across every team partition (the aggregate's corpus-wide fold). Each
    record carries its server-stamped team_id_hash, so a reader can bucket + count distinct teams
    for the k-anonymity gate. Read-only."""
    out = []
    for team in list_teams(home=home):
        out.extend(read_team_pmrs(team, home=home))
    return out


def all_hunks(home=None):
    """Every stored T1 hunk across every opted-in team partition (the rule-synthesis corpus-wide
    fold). Read-only."""
    out = []
    for team in list_hunk_teams(home=home):
        out.extend(read_team_hunks(team, home=home))
    return out
