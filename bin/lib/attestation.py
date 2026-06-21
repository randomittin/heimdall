#!/usr/bin/env python3
# attestation.py — the SI-2 commit-time attestation record builder.
#
# SI-2 is the shared substrate emitted ONCE per commit/task that every downstream
# feature (F2 Checker, F3 Redum, F4 Collision, F5 Debloat, F6 Team-mode) READS so
# none of them re-analyze the diff. One emission, many readers.
#
# The record schema is:
#
#   { claims, contracts, evidence, reuse, risk }
#
#   • claims    — what the change asserts it does, DERIVED from the diff (files
#                 added/modified/renamed + the named units added/changed in each,
#                 with a one-line structured summary). Not the agent's prose.
#   • contracts — the interfaces/APIs the change touches or must honor: the
#                 EXPORTED / public symbols it adds or changes, with their kind +
#                 signature, resolved from tree-sitter symbols (heuristic fallback).
#   • evidence  — RUNNABLE proof: the acceptance/test/build commands that were run
#                 and their real exit codes ({cmd, exit, ok}). This is a record of
#                 commands the EMITTER executed, never the agent's self-assessment.
#   • reuse     — THE S-6 reuse record, produced by the unified reuse analyzer
#                 (bin/lib/reuse_analyzer.py) on the SAME tree-sitter substrate:
#                 { units_total, units_reusing, units_reinventing, reuse_pct,
#                   reused_symbols, suspected_duplicates, engine }.
#   • risk      — flagged risks for a reviewer, DERIVED from the other fields (low
#                 reuse, suspected duplicates, large surface, missing evidence,
#                 partial analysis). Each risk is {level, code, detail}.
#
# DEGRADE GRACEFULLY: if any sub-analysis fails, the record is emitted PARTIAL
# (the field carries an honest `partial`/`reason`) rather than crashing — a
# commit must never be blocked by an attestation failure. The top-level record
# carries `"partial": true` plus a `"partial_reasons"` list when any field could
# not be fully derived.
#
# This is a LIBRARY (pure function of a job dict). The thin CLI is
# bin/heimdall-attest, which does the git extraction + runs the evidence commands
# + writes the record to .heimdall/attestations/<id>.json (gitignored runtime).

from __future__ import annotations

import json
import os
import sys

# the reuse analyzer lives alongside this file.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import reuse_analyzer as reuse  # noqa: E402 — sibling import after sys.path setup

SCHEMA_VERSION = "si-2.1"

# Source-file extensions the symbol/contract extraction understands. Anything
# else still appears in `claims.files` but contributes no units/contracts.
_SRC_EXT = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".py", ".sh", ".bash"}


def _is_src(path):
    ext = os.path.splitext(path)[1].lower()
    return ext in _SRC_EXT or "." not in os.path.basename(path)


# ── claims: what the change asserts it does (derived from the diff) ────────────


def _extract_named_units(src, path, engine):
    """Return the list of named code units (functions/classes/components/shell
    funcs) the change introduces in `path`, via the engine-aware reuse extractor.
    Returns (names, engine_used) — names is [] for unsupported/unparseable."""
    lang = reuse.detect_language(path)
    if lang is None:
        return [], None
    try:
        units, _mod, used = reuse.extract_units(src, lang, path, engine)
    except Exception:  # noqa: BLE001 — never let one bad file abort the record
        return [], None
    if not units:
        return [], used
    return [u.name for u in units], used


def build_claims(changed_files, statuses, engine):
    """changed_files: {path: source} (the AFTER side). statuses: {path: 'A'|'M'|
    'R'|...} git status letters (optional; defaults to 'M'). Returns the claims
    block: per-file added/changed units + a structured one-line summary."""
    files = []
    total_units = 0
    engines = set()
    partial = False
    for path in sorted(changed_files):
        src = changed_files[path]
        status = (statuses or {}).get(path, "M")
        names, used = ([], None)
        if _is_src(path):
            names, used = _extract_named_units(src, path, engine)
            if used:
                engines.add(used)
        total_units += len(names)
        entry = {
            "path": path,
            "status": status,
            "lang": reuse.detect_language(path),
            "units": names,
        }
        if _is_src(path) and used is None:
            # a source file we could not parse for units — honest partial marker.
            entry["units_partial"] = True
            partial = True
        files.append(entry)

    n_added = sum(1 for f in files if f["status"].startswith("A"))
    n_mod = sum(1 for f in files if f["status"].startswith("M"))
    n_ren = sum(1 for f in files if f["status"].startswith("R"))
    summary = (
        "changes %d file(s) (%d added, %d modified, %d renamed) introducing/"
        "touching %d named unit(s)" % (len(files), n_added, n_mod, n_ren, total_units)
    )
    claims = {
        "summary": summary,
        "files": files,
        "file_count": len(files),
        "unit_count": total_units,
    }
    if partial:
        claims["partial"] = True
    return claims, partial


# ── contracts: exported/public symbols added or changed (tree-sitter) ──────────


def _exported_symbols(src, path, engine):
    """Return the public/exported contract symbols a source file declares:
    [{name, kind, lang, exported}]. Uses tree-sitter symbols when available
    (engine auto/treesitter), falling back to the heuristic unit extractor. A
    symbol is `exported` when its declaration is preceded by `export` (JS/TS), is
    top-level public (Python: not name-mangled with a leading underscore), or is a
    top-level shell function. Degrades to [] on any failure (caller marks
    partial)."""
    lang = reuse.detect_language(path)
    if lang is None:
        return None  # not a source language → no contracts (not an error)

    eng = reuse.resolve_engine(engine)
    # Prefer tree-sitter symbol kinds (richer + AST-accurate) when usable.
    if eng in ("auto", "treesitter"):
        ts = reuse._ts_module()  # noqa: SLF001 — intentional substrate access
        tslang = reuse._ts_lang_for(lang, path) if ts is not None else None
        if ts is not None and tslang is not None:
            try:
                res = ts.extract(src, tslang)
            except Exception:  # noqa: BLE001
                res = None
            if res is not None and res.available:
                return _contracts_from_ts(res.symbols, src, lang)

    # Heuristic fallback: derive contract symbols from the unit extractor.
    try:
        units, _mod, _used = reuse.extract_units(src, lang, path, "heuristic")
    except Exception:  # noqa: BLE001
        return None
    if units is None:
        return None
    out = []
    for u in units:
        out.append({
            "name": u.name,
            "kind": "unit",
            "lang": lang,
            "exported": _looks_exported(u.name, src, lang),
        })
    return out


def _contracts_from_ts(symbols, src, lang):
    out = []
    for s in symbols:
        out.append({
            "name": s.name,
            "kind": s.kind,
            "lang": lang,
            "span": list(s.span),
            "exported": _looks_exported(s.name, src, lang),
        })
    return out


def _looks_exported(name, src, lang):
    """Heuristic export check shared by both engines: a symbol is part of the
    PUBLIC contract when JS/TS marks it `export`, Python keeps it un-underscored
    at module level, or shell defines it as a named function. Conservative: when
    unsure, treat top-level names as public (a contract a reader should honor)."""
    if lang == "js":
        # an `export` keyword anywhere referencing this name (export function X,
        # export const X, export class X, export { X }).
        needle_fn = "export"
        return needle_fn in src and (
            ("export" in src and name in src)
        )
    if lang == "py":
        return not name.startswith("_")
    if lang in ("sh", "sh_maybe"):
        return not name.startswith("_")
    return True


def build_contracts(changed_files, statuses, engine):
    """Return the contracts block: the exported/public symbols the change adds or
    changes, grouped by file, plus a flat `surface` list of the public ones."""
    by_file = []
    surface = []
    partial = False
    for path in sorted(changed_files):
        if not _is_src(path):
            continue
        syms = _exported_symbols(changed_files[path], path, engine)
        if syms is None:
            by_file.append({"path": path, "symbols": [], "partial": True})
            partial = True
            continue
        by_file.append({"path": path, "symbols": syms})
        for s in syms:
            if s.get("exported"):
                surface.append({"path": path, "name": s["name"], "kind": s["kind"]})
    contracts = {
        "summary": "%d public symbol(s) across %d source file(s)"
        % (len(surface), len(by_file)),
        "surface": surface,
        "by_file": by_file,
    }
    if partial:
        contracts["partial"] = True
    return contracts, partial


# ── evidence: runnable proof (recorded command exits, never self-report) ──────


def build_evidence(evidence_results):
    """evidence_results: a list of {cmd, exit} dicts ALREADY RUN by the emitter
    (the emitter executes the commands and captures real exit codes; this builder
    only records them — it never claims success it did not observe). Returns the
    evidence block. An empty list yields an honest `none-run` evidence block (a
    risk, surfaced in build_risk)."""
    checks = []
    all_ok = True
    for r in evidence_results or []:
        cmd = r.get("cmd", "")
        code = r.get("exit")
        ok = (code == 0)
        if not ok:
            all_ok = False
        entry = {"cmd": cmd, "exit": code, "ok": ok}
        if "kind" in r:
            entry["kind"] = r["kind"]
        if "stdout_tail" in r:
            entry["stdout_tail"] = r["stdout_tail"]
        checks.append(entry)
    evidence = {
        "checks": checks,
        "ran": len(checks),
        "all_passed": bool(checks) and all_ok,
    }
    if not checks:
        evidence["reason"] = "no-evidence-commands-supplied"
    return evidence


# ── reuse: THE S-6 record from the unified analyzer (tree-sitter substrate) ────


def build_reuse(task, pre_files, changed_files, engine):
    """Produce the reuse field via the unified reuse analyzer. The same analyzer
    that powers `heimdall-reuse-metric` and the S-6 gate — reuse measured ONCE,
    AST-based. Degrades to a partial reuse block on any analyzer error rather than
    aborting the attestation."""
    try:
        pre_symbols = reuse.build_pre_symbols(pre_files, engine)
        record = reuse.analyze(task, changed_files, pre_symbols, engine)
        return record, False
    except Exception as exc:  # noqa: BLE001 — never block a commit on reuse failure
        return (
            {
                "task": task,
                "units_total": 0,
                "units_reusing": 0,
                "units_reinventing": 0,
                "reuse_pct": None,
                "reused_symbols": [],
                "suspected_duplicates": [],
                "engine": reuse.resolve_engine(engine),
                "partial": True,
                "reason": "reuse-analyzer-error: %s" % exc,
            },
            True,
        )


# ── risk: reviewer-facing flags derived from the other fields ─────────────────

# the reuse floor below which a change is flagged for review (mirrors the S-6
# halt threshold default; a reader/gate may apply its own).
REUSE_RISK_FLOOR = 0.30
# a "large surface" heuristic: many public symbols added/changed at once.
LARGE_SURFACE = 12


def build_risk(claims, contracts, evidence, reuse_record):
    """Derive reviewer-facing risk flags from the already-built fields. Each risk
    is {level, code, detail}. Levels: info | warn | high."""
    risks = []

    pct = reuse_record.get("reuse_pct")
    dups = reuse_record.get("suspected_duplicates") or []
    if pct is not None and pct < REUSE_RISK_FLOOR:
        risks.append({
            "level": "high",
            "code": "low-reuse",
            "detail": "reuse_pct=%.2f below the %.2f floor — the change may "
                      "reinvent existing repo code" % (pct, REUSE_RISK_FLOOR),
        })
    if dups:
        names = sorted({d.get("duplicates") for d in dups if d.get("duplicates")})
        risks.append({
            "level": "warn",
            "code": "suspected-duplicates",
            "detail": "duplicates pre-existing symbol(s): %s" % ", ".join(names),
        })

    surface = contracts.get("surface") or []
    if len(surface) >= LARGE_SURFACE:
        risks.append({
            "level": "warn",
            "code": "large-public-surface",
            "detail": "%d public symbols added/changed in one change "
                      "(>= %d)" % (len(surface), LARGE_SURFACE),
        })

    if not evidence.get("checks"):
        risks.append({
            "level": "warn",
            "code": "no-evidence",
            "detail": "no runnable acceptance/test/build command was recorded — "
                      "the change is unproven",
        })
    elif not evidence.get("all_passed"):
        failed = [c["cmd"] for c in evidence["checks"] if not c["ok"]]
        risks.append({
            "level": "high",
            "code": "evidence-failed",
            "detail": "evidence command(s) did not pass: %s" % "; ".join(failed),
        })

    if claims.get("partial") or contracts.get("partial") or reuse_record.get("partial"):
        risks.append({
            "level": "info",
            "code": "partial-analysis",
            "detail": "one or more fields were derived partially (a source file "
                      "could not be parsed or an analyzer degraded)",
        })

    # an overall rollup so a reader can branch on one field.
    level_rank = {"info": 0, "warn": 1, "high": 2}
    top = max((level_rank[r["level"]] for r in risks), default=-1)
    overall = {2: "high", 1: "warn", 0: "info", -1: "none"}[top]
    return {"overall": overall, "flags": risks}


# ── the public builder ────────────────────────────────────────────────────────


def build_record(job):
    """Build the full SI-2 attestation record from a job dict:

      { "task": str,
        "commit": str,                 # commit sha / branch / run-id this attests
        "engine": "auto"|"treesitter"|"heuristic",   # optional
        "pre_files":     {path: src},  # repo BEFORE the change (for reuse)
        "changed_files": {path: src},  # the AFTER side of the diff
        "statuses":      {path: 'A'|'M'|'R'},        # optional git status letters
        "evidence":      [{cmd, exit, ...}, ...] }   # commands the emitter ran

    Returns the record dict with the five fields + metadata. NEVER raises: a
    failure in any sub-analysis yields a partial field and a top-level
    `"partial": true`."""
    task = job.get("task", "")
    commit = job.get("commit", "")
    engine = reuse.resolve_engine(job.get("engine"))
    pre_files = job.get("pre_files", {}) or {}
    changed_files = job.get("changed_files", {}) or {}
    statuses = job.get("statuses", {}) or {}
    evidence_results = job.get("evidence", []) or []

    partial_reasons = []

    claims, c_partial = build_claims(changed_files, statuses, engine)
    if c_partial:
        partial_reasons.append("claims")

    contracts, k_partial = build_contracts(changed_files, statuses, engine)
    if k_partial:
        partial_reasons.append("contracts")

    evidence = build_evidence(evidence_results)

    reuse_record, r_partial = build_reuse(task, pre_files, changed_files, engine)
    if r_partial:
        partial_reasons.append("reuse")

    risk = build_risk(claims, contracts, evidence, reuse_record)

    record = {
        "schema": SCHEMA_VERSION,
        "task": task,
        "commit": commit,
        "engine": engine,
        "claims": claims,
        "contracts": contracts,
        "evidence": evidence,
        "reuse": reuse_record,
        "risk": risk,
    }
    if partial_reasons:
        record["partial"] = True
        record["partial_reasons"] = partial_reasons
    return record


def main(argv):
    """CLI: read a job JSON on stdin, write the record JSON to stdout. Used by
    bin/heimdall-attest. The human summary goes to stderr."""
    raw = sys.stdin.read()
    job = json.loads(raw)
    record = build_record(job)
    sys.stdout.write(json.dumps(record, indent=2) + "\n")
    sys.stderr.write(human_summary(record) + "\n")
    return 0


def human_summary(record):
    reuse_record = record.get("reuse", {})
    pct = reuse_record.get("reuse_pct")
    pct_s = "n/a" if pct is None else "%.0f%%" % (pct * 100)
    ev = record.get("evidence", {})
    risk = record.get("risk", {})
    return (
        "attest %s: %d file(s), %d public symbol(s); reuse=%s [%s]; "
        "evidence=%d run/%s; risk=%s%s"
        % (
            record.get("commit", "?")[:12] or "?",
            record.get("claims", {}).get("file_count", 0),
            len(record.get("contracts", {}).get("surface", [])),
            pct_s,
            reuse_record.get("engine", "?"),
            ev.get("ran", 0),
            "all-passed" if ev.get("all_passed") else "not-all-passed",
            risk.get("overall", "?"),
            " (PARTIAL)" if record.get("partial") else "",
        )
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
