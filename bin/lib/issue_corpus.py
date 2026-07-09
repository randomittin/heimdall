#!/usr/bin/env python3
# issue_corpus.py — the Anonymized Issue Collection LOCAL emit engine (issue_v1).
#
# WHAT THIS IS: an ADDITIVE SIBLING of the pre-merge corpus (pmr_corpus.py). A
# teammate's hmd session surfaces bugs/errors/friction (a failing gate, an
# exception, a retry-storm). This module projects such an event into a
# ZERO-CONTENT, consent-gated `issue_v1` metadata record and spools it LOCALLY.
# Nothing sends anywhere in this build (Wave 1) — the spool IS the outbox; the
# signed transport + server ingest + k-anon aggregate land in later waves.
#
# THE PRIVACY LINE IS ABSOLUTE — and it is REUSED, NOT REBUILT. Every privacy
# primitive is IMPORTED from pmr_corpus (the #4/#10 gates stay byte-for-byte
# green; we never edit that module):
#   * enabled()               — the ONE master consent switch (OFF => pure no-op)
#   * assert_zero_content()   — the cardinal guard: a path/source line/PII => BLOCK
#   * secret_scan_payload()   — telemetry secret vocab + gitleaks belt
#   * team_id_hash / repo_class_hash / _h  — domain-separated, non-reversible ids
#   * corpus_home / corpus_namespace       — the isolated runtime home + keyspace
#   * _alarm()                — a blocked emission is LOUD, never silent
#   * _tag / _int / _num / _now_iso / _tz_bucket / _read_json / _atomic_write_json
#
# RJ's approved decisions (see evals/oracles/issue-collection/INVARIANTS.md):
#   1. Signal fields: a HASHED error-signature + COARSE coded fields only — no raw
#      stack, no code, no paths, no PII. k-anon also applies to the SIGNATURE
#      BUCKET itself (a rare hash is suppressed until >= k distinct teams hit it).
#   2. Disposition: SHADOW-first — no auto-open GitHub issues in this build.
#   3. k-anon: k >= 10 for the non-sensitive class (ISSUE_K_ANONYMITY_MIN). The
#      security-sensitive lane is ALWAYS private, regardless of k.
#
# stdlib-only. Mirrors the shape of pmr_corpus.emit_pmr (project -> guard -> scan
# -> spool) but for the issue schema, and adds the emit-time security classifier
# that routes matching signals to a PRIVATE .planning/security-signals/ lane.

from __future__ import annotations

import json
import os
import re
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# REUSE the pre-merge corpus privacy machinery by IMPORT — never re-derive it.
# (pmr_corpus itself imports telemetry for the secret vocabulary.)
import pmr_corpus  # noqa: E402 — sibling import after sys.path setup

# ── schema + policy constants ─────────────────────────────────────────────────

SCHEMA_ISSUE = "issue_v1"

# The consent version travels with each record — reuse the corpus's single source
# of truth so an issue and a PMR collected in the same session agree on disclosure.
CONSENT_VERSION = pmr_corpus.CONSENT_VERSION

# k-ANON for issues (RJ decision 3). Issues are RARER than PMRs, so a 20-floor
# (pmr_corpus.K_ANONYMITY_MIN) would starve the seeker feed — we use 10. A bucket
# (including a rare error-signature) seen by fewer than this many DISTINCT teams is
# SUPPRESSED. The corpus's stricter K_ANONYMITY_MIN (20) remains the reference.
ISSUE_K_ANONYMITY_MIN = 10

# The security-sensitivity taxonomy (RJ Q-sec default; extend by decision, never
# silently). An error_class in this set routes the signal to the PRIVATE lane,
# excluded from every public aggregate + synth candidate — regardless of k.
_SECURITY_CLASSES = frozenset({
    "auth", "crypto", "secret", "injection", "deanon", "isolation", "incident",
})

# A coded severity is one of a small closed enum; anything else coerces to
# "unknown" so a free-text severity can never smuggle content.
_SEVERITY_ENUM = frozenset({
    "info", "low", "medium", "high", "critical", "warn", "error", "fatal",
})

# The CLOSED set of top-level keys a canonical issue_v1 carries after rebuild — a
# reader trusts ONLY these; an ingested record is reduced to exactly this shape so a
# smuggled off-schema key (content hidden under an unknown field) is never stored.
ISSUE_TOP_KEYS = frozenset({
    "schema", "consent_version", "ids", "when", "signal", "env", "security_sensitive",
})


# ── namespace + store layout (own partition, sibling of telemetry/pmr) ────────


def issue_dir(home=None):
    """<home>/telemetry/issues — the issue-only namespace root. Reuses the corpus
    runtime home (HEIMDALL_CORPUS_HOME / HEIMDALL_HOME / ~/.heimdall) so issues are
    never mixed with per-repo presence/ops state; a test pins an explicit --home."""
    base = home if home else pmr_corpus.corpus_home()
    return os.path.join(base, "telemetry", "issues")


def outbox_dir(home=None):
    """The local send-queue (outbox). In Wave 1 this IS the queue — nothing sends."""
    return os.path.join(issue_dir(home), "outbox")


def deletions_dir(home=None):
    return os.path.join(issue_dir(home), "deletions")


def security_signals_dir(home=None):
    """The PRIVATE lane — git-committed, human-triaged, NEVER sent. When `home` is
    pinned (tests / sandbox) it lands under <home>/security-signals so a run stays
    hermetic; otherwise the repo-local .planning/security-signals/ (committed)."""
    if home:
        return os.path.join(home, "security-signals")
    root = _repo_root()
    return os.path.join(root, ".planning", "security-signals")


def _repo_root():
    """The current git repo root, or cwd when not in a repo. Only ever used to
    locate the .planning/ private lane — never emitted."""
    root = pmr_corpus._git(os.getcwd(), ["rev-parse", "--show-toplevel"]).strip()
    return root or os.getcwd()


# ── signature normalization (a HASHED, non-reversible error signature) ─────────

# Collapse the volatile parts of an error string so "boom at 0x1f22" and "boom at
# 0x9a01" share a signature — the shape survives, the specifics (and any content)
# never leave: only the domain-separated hash of the normalized form is stored.
_RX_HEX = re.compile(r"0x[0-9a-fA-F]+")
_RX_NUM = re.compile(r"\d+")
_RX_WS = re.compile(r"\s+")


def _normalize_error(event):
    raw = (event.get("signature") or event.get("message") or event.get("error")
           or event.get("error_class") or "")
    s = str(raw).lower()
    s = _RX_HEX.sub("0xn", s)
    s = _RX_NUM.sub("n", s)
    s = _RX_WS.sub(" ", s).strip()
    return s


def signature_hash(event):
    """The non-reversible error signature: sha256(domain, normalized-error)[:16].
    Domain-separated (heimdall-issue-sig) so it can never be joined to a PMR or
    presence hash. The raw error text is NEVER stored — only this hash."""
    return pmr_corpus._h("heimdall-issue-sig", _normalize_error(event), 16)


# ── coding helpers (bounded coded tokens — never content) ─────────────────────


def _coded(value, default="unknown"):
    """A single coded token, bounded to the corpus _TAG_MAX. Content is PRESERVED
    (not sanitized) so a planted path/source line survives to assert_zero_content
    and is caught there — this normalizer never silently cleans a leak."""
    if value is None:
        return default
    t = pmr_corpus._tag(str(value))
    return t if t else default


def _severity(value):
    s = str(value or "unknown").strip().lower()
    if s in _SEVERITY_ENUM:
        return s
    return "unknown" if not value else _coded(s)


def _os_class(event):
    return _coded(event.get("os_class") or pmr_corpus._default_os_class())


# ── the RAW-CONTENT guard (INV-A — refuse content, never silently hash it) ────
#
# The signature is HASHED, but we must never SILENTLY hash away a raw stack/path —
# that would make the zero-content guard un-falsifiable (a planted path would just
# vanish into a hash). Mirroring pmr_corpus's "_tag preserves content so the guard
# catches it" discipline: the free-text error-input fields are scanned BEFORE
# projection. A path / source line / multi-word phrase / PII shape there => BLOCK +
# ALARM. Only clean, single-token coded error identities survive to be hashed.
#
# The structured id/coded fields are EXEMPT from this raw scan: `repo`/`team_id` are
# hashed and never stored raw (a '/' in a repo slug is fine); the coded fields
# (error_class/gate/phase/command/os_class/hmd_version/severity) are copied into the
# record and guarded there by assert_zero_content(rec). Everything else a caller
# might dump a stack into (message/error/stack/trace/detail/signature/novel keys) is
# scanned here.
_RAW_EXEMPT_KEYS = frozenset({
    "team_id", "repo", "ids", "os_class", "hmd_version", "gate", "phase",
    "command", "error_class", "severity", "ci", "incident", "marker",
})


def _scan_raw_content(event):
    """Scan the raw event's free-text fields for content. Returns (ok, violations)
    from assert_zero_content over the non-exempt keys. ok=False => the caller passed
    raw content (a stack/path/phrase) we refuse to handle — BLOCK, never hash."""
    payload = {k: v for k, v in (event or {}).items() if k not in _RAW_EXEMPT_KEYS}
    return pmr_corpus.assert_zero_content(payload)


# ── the security-sensitivity classifier (the genuinely-new piece) ─────────────


def classify_security_sensitive(event):
    """True iff the signal must go to the PRIVATE lane (INV-F). A signal is
    security-sensitive when ANY of:
      1. a SECRET SHAPE is found in the RAW event (a token in an error text) —
         reuse pmr_corpus.secret_scan_payload over the whole raw event;
      2. error_class is in the security taxonomy (_SECURITY_CLASSES);
      3. an explicit incident marker is set (`incident: true` / marker=="incident");
      4. a gate/phase/command names a security lane (auth/crypto/... in the coded
         field itself).
    A True result routes to security_signals_dir and is excluded from every public
    aggregate + synth candidate, at any team count."""
    event = event or {}
    # (1) a secret anywhere in the raw event.
    clean, _findings = pmr_corpus.secret_scan_payload(event)
    if not clean:
        return True
    # (2) coded error_class in the security taxonomy.
    ec = str(event.get("error_class") or "").strip().lower()
    if ec in _SECURITY_CLASSES:
        return True
    # (3) explicit incident marker.
    if event.get("incident") is True:
        return True
    if str(event.get("marker") or "").strip().lower() == "incident":
        return True
    # (4) a security lane named in a coded field.
    for key in ("gate", "phase", "command"):
        if str(event.get(key) or "").strip().lower() in _SECURITY_CLASSES:
            return True
    return False


# ── the projection: event -> issue_v1 (PURE, zero-content by construction) ─────


def project(event):
    """Build an issue_v1 from a raw event (PURE — no IO). Copies ONLY coded tokens,
    non-reversible hashes, bounded enums, booleans. The raw error text becomes a
    signature_hash; a path/source symbol/PII is NEVER copied. `security_sensitive`
    is stamped here so the emit router can split the private lane before any spool.

    event = {
      error_class, signature|message|error,   # -> signature_hash (raw discarded)
      gate, phase, command, severity,          # coded coarse fields
      os_class, ci, hmd_version,               # coarse env
      team_id, repo | ids:{team_id, repo},     # hashed, never in the clear
      incident|marker,                         # security routing signals
    }
    """
    event = event or {}
    ids = event.get("ids") if isinstance(event.get("ids"), dict) else {}
    team_id = event.get("team_id") or ids.get("team_id") or "solo"
    repo = event.get("repo") or ids.get("repo") or "unknown"

    return {
        "schema": SCHEMA_ISSUE,
        "consent_version": CONSENT_VERSION,
        "ids": {
            "issue_id": "iss-" + uuid.uuid4().hex,
            "team_id_hash": pmr_corpus.team_id_hash(team_id),
            "repo_class_hash": pmr_corpus.repo_class_hash(repo),
        },
        "when": {
            "ts": pmr_corpus._now_iso(),
            "tz_bucket": pmr_corpus._tz_bucket(),
        },
        "signal": {
            "error_class": _coded(event.get("error_class")),
            "signature_hash": signature_hash(event),
            "gate": _coded(event.get("gate")),
            "phase": _coded(event.get("phase")),
            "command": _coded(event.get("command")),
            "severity": _severity(event.get("severity")),
        },
        "env": {
            "os_class": _os_class(event),
            "ci": bool(event.get("ci", False)),
            "hmd_version": _coded(event.get("hmd_version")),
        },
        "security_sensitive": classify_security_sensitive(event),
    }


# ── the emit path: consent -> project -> route/guard/scan -> spool ────────────


def emit_issue(event, home=None):
    """Emit ONE issue_v1. The full gate (INV-A/D/F):
        1. OFF honored (INV-D) — consent disabled => pure no-op, ZERO write.
        2. project() — the zero-content-by-construction metadata projection.
        3. security-sensitive (INV-F) => write the PRIVATE lane, NOT the outbox;
           never reported as emitted (it is never sent).
        4. assert_zero_content() (INV-A) — a path/source leak => BLOCK + ALARM.
        5. secret_scan_payload() — a secret shape => BLOCK + ALARM (belt).
        6. write to the local outbox (the send-queue; nothing sends in Wave 1).
    Returns a status dict — NEVER raises into the caller (telemetry must never fail
    a run)."""
    try:
        if not pmr_corpus.enabled(home):
            return {"emitted": False, "reason": "disabled"}

        rec = project(event)

        if rec.get("security_sensitive"):
            # The private record is itself a zero-content coded/hashed projection;
            # re-guard + re-scan it fail-closed so even the private lane can never
            # persist a leaked secret/path.
            ok, violations = pmr_corpus.assert_zero_content(rec)
            if not ok:
                pmr_corpus._alarm("issue-zero-content-private",
                                  {"violations": violations}, home)
                return {"emitted": False, "reason": "zero-content-blocked",
                        "blocked": True, "private": True, "violations": violations}
            clean, findings = pmr_corpus.secret_scan_payload(rec)
            if not clean:
                pmr_corpus._alarm("issue-secret-scan-private",
                                  {"findings": findings}, home)
                return {"emitted": False, "reason": "secret-detected-blocked",
                        "blocked": True, "private": True, "findings": findings}
            path = _write_security_lane(rec, home)
            return {"emitted": False, "reason": "security-sensitive-private",
                    "private": True, "issue_id": rec["ids"]["issue_id"],
                    "lane_path": path}

        # INV-A: refuse raw content in the error-input fields — never silently hash
        # a planted path/stack/phrase away. This is what keeps the guard falsifiable.
        raw_ok, raw_violations = _scan_raw_content(event)
        if not raw_ok:
            pmr_corpus._alarm("issue-zero-content-raw",
                              {"violations": raw_violations}, home)
            return {"emitted": False, "reason": "zero-content-blocked",
                    "blocked": True, "source": "raw-event", "violations": raw_violations}

        ok, violations = pmr_corpus.assert_zero_content(rec)
        if not ok:
            pmr_corpus._alarm("issue-zero-content", {"violations": violations}, home)
            return {"emitted": False, "reason": "zero-content-blocked",
                    "blocked": True, "violations": violations}

        clean, findings = pmr_corpus.secret_scan_payload(rec)
        if not clean:
            pmr_corpus._alarm("issue-secret-scan", {"findings": findings}, home)
            return {"emitted": False, "reason": "secret-detected-blocked",
                    "blocked": True, "findings": findings}

        path = _write_outbox(rec, home)
        return {"emitted": True, "issue_id": rec["ids"]["issue_id"],
                "spool_path": path, "security_sensitive": False,
                "consent_version": rec["consent_version"]}
    except Exception as exc:  # noqa: BLE001 — telemetry NEVER fails the caller
        return {"emitted": False, "reason": "error", "detail": str(exc)[:120]}


def _write_outbox(rec, home=None):
    d = outbox_dir(home)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, rec["ids"]["issue_id"] + ".json")
    pmr_corpus._atomic_write_json(path, rec)
    return path


def _write_security_lane(rec, home=None):
    d = security_signals_dir(home)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, rec["ids"]["issue_id"] + ".json")
    pmr_corpus._atomic_write_json(path, rec)
    return path


def outbox_records(home=None):
    """Read every queued issue_v1 from the outbox (read-only, tolerant)."""
    return pmr_corpus._read_dir_records(outbox_dir(home))


def security_lane_records(home=None):
    return pmr_corpus._read_dir_records(security_signals_dir(home))


# ── the SERVER-SIDE closed-schema rebuild (INV-A boundary, mirrors rebuild_pmr) ─


def rebuild_issue(line):
    """Re-run the closed-schema, zero-content-guarded rebuild on ONE pushed/stored
    issue SERVER-SIDE (mirrors pmr_corpus.rebuild_pmr). Reads ONLY the pinned keys,
    bounds every free field via _tag, coerces ints/bools, DROPS every unknown wire
    key, then re-checks the whole record with assert_zero_content. A client cannot
    inject an off-schema / secret / content-bearing issue: the server rebuilds it
    from the pinned keys. Returns the clean record, or None when the line is not a
    dict / not an issue_v1 / fails the guard. `team_id_hash` is carried from the
    line but the ingest caller OVERWRITES it with the server-derived handle (INV-C)."""
    if not isinstance(line, dict):
        return None
    if line.get("schema") not in (None, SCHEMA_ISSUE):
        return None

    ids = line.get("ids") if isinstance(line.get("ids"), dict) else {}
    when = line.get("when") if isinstance(line.get("when"), dict) else {}
    signal = line.get("signal") if isinstance(line.get("signal"), dict) else {}
    env = line.get("env") if isinstance(line.get("env"), dict) else {}

    rec = {
        "schema": SCHEMA_ISSUE,
        "consent_version": _coded(line.get("consent_version") or CONSENT_VERSION),
        "ids": {
            "issue_id": pmr_corpus._tag(_first(ids, "issue_id") or line.get("issue_id")),
            "team_id_hash": pmr_corpus._tag(
                _first(ids, "team_id_hash") or line.get("team_id_hash")),
            "repo_class_hash": pmr_corpus._tag(
                _first(ids, "repo_class_hash") or line.get("repo_class_hash")),
        },
        "when": {
            "ts": pmr_corpus._tag(_first(when, "ts") if when else line.get("ts")),
            "tz_bucket": pmr_corpus._tag(
                _first(when, "tz_bucket") if when else line.get("tz_bucket")),
        },
        "signal": {
            "error_class": _coded(signal.get("error_class")),
            "signature_hash": pmr_corpus._tag(signal.get("signature_hash")),
            "gate": _coded(signal.get("gate")),
            "phase": _coded(signal.get("phase")),
            "command": _coded(signal.get("command")),
            "severity": _severity(signal.get("severity")),
        },
        "env": {
            "os_class": _coded(env.get("os_class")),
            "ci": bool(env.get("ci", False)),
            "hmd_version": _coded(env.get("hmd_version")),
        },
        "security_sensitive": bool(line.get("security_sensitive", False)),
    }
    ok, _violations = pmr_corpus.assert_zero_content(rec)
    if not ok:
        return None
    return rec


def _first(d, *keys):
    """The first present, non-None value among `keys` in dict `d` (else None)."""
    if not isinstance(d, dict):
        return None
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


# ── the k-anon SIGNATURE-BUCKET suppression primitive (INV-B) ─────────────────
#
# Defined ONCE here (the local lib) and IMPORTED by the Wave-2 aggregate — the
# single source of the k-anon rule so the emit-side and the aggregate can never
# disagree. Distinct-team count, never row count: 100 issues from one team is still
# a cohort of ONE and MUST suppress.


def bucket_distinct_teams(records):
    """The number of DISTINCT team_id_hash contributing to a bucket."""
    teams = set()
    for r in records or []:
        if not isinstance(r, dict):
            continue
        # accept both the flat rebuilt shape (team_id_hash) and the nested client
        # shape (ids.team_id_hash) so the aggregate can fold either.
        tih = r.get("team_id_hash")
        if not tih and isinstance(r.get("ids"), dict):
            tih = r["ids"].get("team_id_hash")
        if tih:
            teams.add(tih)
    return len(teams)


def meets_k_anon(records, k=None):
    """True iff a bucket clears the k-anon floor (>= k DISTINCT teams)."""
    k = ISSUE_K_ANONYMITY_MIN if k is None else k
    return bucket_distinct_teams(records) >= k


def suppress_if_rare(records, k=None):
    """The k-anon gate for a signature bucket (INV-B). A bucket seen by fewer than
    k DISTINCT teams (a rare error-signature that could re-identify) is SUPPRESSED:
    returns a marker carrying ONLY the team count — never the underlying records /
    metrics. A cleared bucket returns the records for aggregation."""
    k = ISSUE_K_ANONYMITY_MIN if k is None else k
    n = bucket_distinct_teams(records)
    if n >= k:
        return {"suppressed": False, "teams": n, "k": k, "records": list(records or [])}
    return {"suppressed": True, "reason": "k_anonymity", "teams": n, "k": k}


# ── controls: status / purge / flush --dry-run ────────────────────────────────


def corpus_send_enabled(home=None):
    """True iff the issue SEND is permitted — the SAME master consent that gates
    local emit (pmr_corpus.enabled). Telemetry OFF => no byte leaves; there is no
    separate issue opt-out. A scheduled flush/aggregate checks this and, with the
    store empty under OFF, cannot leak around the switch (INV-D)."""
    return pmr_corpus.enabled(home)


def status(home=None):
    """A read-only at-a-glance (writes nothing)."""
    return {
        "schema": "issue_status_v1",
        "consent_version": CONSENT_VERSION,
        "enabled": pmr_corpus.enabled(home),
        "send_enabled": corpus_send_enabled(home),
        "k_anonymity_min": ISSUE_K_ANONYMITY_MIN,
        "collected": [
            "issue_v1 metadata: coded error_class + HASHED error signature, coded "
            "gate/phase/command, coded severity, hmd_version, os_class",
        ],
        "never_collected": [
            "source code", "file paths", "raw error/stack text", "prompts",
            "secrets", "PII",
        ],
        "outbox": {
            "queued": len(outbox_records(home)),
            "bytes": _dir_size(outbox_dir(home)),
        },
        "security_lane": {
            "queued": len(security_lane_records(home)),
            "note": "PRIVATE — human-triaged, never sent, excluded from aggregate+synth",
        },
        "deletion_requests": len(pmr_corpus._read_dir_records(deletions_dir(home))),
        "home": issue_dir(home),
    }


def _dir_size(d):
    total = 0
    try:
        for n in os.listdir(d):
            fp = os.path.join(d, n)
            try:
                total += os.path.getsize(fp)
            except OSError:
                continue
    except OSError:
        return 0
    return total


def purge(team_id=None, home=None):
    """Local purge + queued deletion (mirrors pmr_corpus.purge, issue-scoped).
    Empties the send outbox AND records a deletion request keyed by team_id_hash
    (the CP-side deletion honors it in a later wave). The PRIVATE security lane is
    NOT purged here — it is human-managed local triage, not sent data."""
    tid = team_id
    if not tid:
        tid = pmr_corpus._current_team_id()
    tih = pmr_corpus.team_id_hash(tid or "solo")
    req = {
        "schema": "issue_delete_v1",
        "consent_version": CONSENT_VERSION,
        "team_id_hash": tih,
        "requested_at": pmr_corpus._now_iso(),
        "status": "queued",
    }
    os.makedirs(deletions_dir(home), exist_ok=True)
    req_path = os.path.join(
        deletions_dir(home),
        "%d-%s.json" % (int(pmr_corpus._now().timestamp()), tih),
    )
    pmr_corpus._atomic_write_json(req_path, req)
    removed = pmr_corpus._empty_dir(outbox_dir(home))
    return {"purged": True, "removed": removed, "team_id_hash": tih,
            "deletion_request": req_path}


def flush_dry_run(home=None):
    """Build the signed batch that a flush WOULD send — and send NOTHING (there is
    no transport in Wave 1). Re-guards + re-scans each queued record (the send belt)
    and reports which would ship vs be held. A record failing the belt is DROPPED
    from the batch (never sent), matching the fail-closed send discipline."""
    records = outbox_records(home)
    ship, held = [], []
    for rec in records:
        ok, violations = pmr_corpus.assert_zero_content(rec)
        clean, findings = pmr_corpus.secret_scan_payload(rec)
        if ok and clean and not rec.get("security_sensitive"):
            ship.append(rec.get("ids", {}).get("issue_id"))
        else:
            reason = ("zero-content" if not ok else
                      "secret" if not clean else "security-sensitive")
            held.append({"issue_id": rec.get("ids", {}).get("issue_id"),
                         "reason": reason})
    return {
        "dry_run": True,
        "sent": 0,
        "send_enabled": corpus_send_enabled(home),
        "batch": {
            "schema": "issue_batch_v1",
            "consent_version": CONSENT_VERSION,
            "count": len(ship),
            "issue_ids": ship,
        },
        "would_ship": len(ship),
        "held": held,
        "note": "Wave 1: no transport — this is a build+scan preview, nothing sent.",
    }


# ── CLI core (driven by bin/heimdall-issue-corpus + the hmd router) ───────────


def _read_event(arg):
    """A --event arg is inline JSON or @path; default reads stdin. Returns {} on any
    parse failure (emit then no-ops honestly)."""
    try:
        if arg is None:
            raw = sys.stdin.read()
        elif arg.startswith("@"):
            with open(arg[1:], "r", encoding="utf-8") as fh:
                raw = fh.read()
        else:
            raw = arg
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def _cli(argv):
    """CLI core. Subcommands:
        emit [--event @f|JSON]   project+classify+guard+scan+spool ONE issue_v1
        status                   read-only at-a-glance (JSON)
        purge [--team-id ID]     local outbox purge + queued deletion
        flush --dry-run          build+scan the signed batch, send NOTHING
    """
    import argparse

    p = argparse.ArgumentParser(prog="hmd issue", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--event")
    p.add_argument("--team-id", dest="team_id")
    p.add_argument("--home")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    home = args.home
    sub = args.subcommand

    if sub == "emit":
        res = emit_issue(_read_event(args.event), home)
        print(json.dumps(res, indent=2, sort_keys=True))
        return 0  # never gate the caller

    if sub == "status":
        print(json.dumps(status(home), indent=2, sort_keys=True))
        return 0

    if sub == "purge":
        print(json.dumps(purge(team_id=args.team_id, home=home), indent=2,
                         sort_keys=True))
        return 0

    if sub == "flush":
        if not args.dry_run:
            # Wave 1 ships no transport — a real flush would send; refuse until it
            # exists, so nothing silently no-ops as if sent.
            print(json.dumps({"error": "flush requires --dry-run (no transport in "
                              "this build)"}, sort_keys=True))
            return 2
        print(json.dumps(flush_dry_run(home), indent=2, sort_keys=True))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
