#!/usr/bin/env python3
# redum.py — F3 Redum, the redundancy SOLVER (the engine behind bin/heimdall-redum).
#
# S-6 / SI-2 MEASURE reuse (the reuse_pct + suspected_duplicates field). Redum is
# what FIXES low reuse. Two phases:
#
#   • PLAN-TIME FACTORING (factor_for_task) — BEFORE the agent builds, surface the
#     existing repo units the solution SHOULD reuse, so it reuses BY DESIGN, not
#     by luck. For the commander class: a task to add mandatory-option behavior
#     surfaces makeOptionMandatory / _checkForMissingMandatoryOptions / _optionEx
#     as the existing machinery to call — so the agent calls them instead of
#     reimplementing. For RN/card-data: a task to add a cards selector/MMKV key
#     surfaces the existing selectCards / cards.cache key.
#
#   • COMMIT-TIME GATE (gate_attestation) — AFTER the change, read SI-2's `reuse`
#     field (it is already computed — Redum does NOT re-measure). If the change
#     RE-ADDED a shape the repo already had (suspected_duplicates non-empty, or a
#     low reuse_pct on a change that should have reused), FLAG it — and name the
#     existing unit via the shared dedup matcher. The gate is a backstop for
#     residual redundancy that slipped past plan-time factoring.
#
# Redum reuses, does not rebuild:
#   • the reuse measurement → SI-2's reuse field (read, never recompute).
#   • the dedup matching     → bin/lib/dedup.py (the shared core F2 also fuses on).
#   • the AST surface        → bin/lib/treesitter_ast.py (via dedup + reuse).
#
# This is a LIBRARY (pure functions). The CLI is bin/heimdall-redum, which owns
# git extraction + the SI-2 attestation read.

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import dedup  # noqa: E402 — sibling import after sys.path setup
import reuse_analyzer as reuse  # noqa: E402

# the gate policy floor below which a low-reuse change is flagged. Mirrors the
# SI-2 risk floor (attestation.REUSE_RISK_FLOOR = 0.30) so Redum's gate and SI-2's
# risk surface agree. A reader/CI may pass its own floor.
DEFAULT_REUSE_FLOOR = 0.30

# how Redum turns a task description into candidate shapes to factor: a set of
# concept→shape hints. Each hint is (regex over the task text, [shape-name hints]).
# These are not hardcoded answers — they map a task's INTENT to the repo symbols
# Redum then *looks up* in the actual repo index. If a hinted symbol doesn't exist
# in the repo, it is NOT surfaced (we only surface what genuinely exists to reuse).
_INTENT_HINTS = [
    # the commander class: mandatory-option machinery.
    (re.compile(r"\bmandatory\b|\brequired option\b|\boption.*requir", re.I),
     ["makeOptionMandatory", "_checkForMissingMandatoryOptions", "_optionEx",
      "mandatoryOption"]),
    (re.compile(r"\bmissing option|\bmissing mandatory", re.I),
     ["_checkForMissingMandatoryOptions"]),
    # RN / card-data domain.
    (re.compile(r"\bcard", re.I),
     ["selectCards", "cardsSlice", "loadCards", "selectCardById"]),
    (re.compile(r"\bselector\b|\bderive.*state|\bselect from", re.I),
     []),  # selectors are surfaced structurally below, not by a fixed name list
    (re.compile(r"\bMMKV\b|\bstorage key|\bcache key|\bpersist", re.I),
     []),  # MMKV keys surfaced structurally below
]


# ── PLAN-TIME FACTORING ───────────────────────────────────────────────────────


def factor_for_task(task, repo_files, want_kinds=None, max_per_concept=4):
    """PHASE 1. Given a task description + the current repo files, return the
    reuse candidates the agent SHOULD reuse — so it reuses by design.

    task: the natural-language task (what the agent is about to build).
    repo_files: dict {path: source} of the EXISTING repo (the pre-build surface).
    want_kinds: optional kind filter (e.g. only ["rn-selector","mmkv-key"]).
    max_per_concept: cap candidates surfaced per detected concept (anti-over-
                     factoring: factor what is genuinely shared, not everything).

    Returns {
      "task": task,
      "candidates": [ {name, kind, file, score, reason, concept}, ... ],
      "concepts": [detected concept tags],
      "advice": one-line human guidance,
    }

    The candidates are REAL repo units (indexed via the shared dedup core). A
    concept hint only surfaces a symbol that ACTUALLY EXISTS in the repo — Redum
    never invents a target. This is the anti-luck mechanism: the planner/agent is
    handed the names to call."""
    index = dedup.index_repo_units(repo_files)
    by_name = {}
    for u in index:
        by_name.setdefault(u.name, u)

    candidates = []
    concepts = []
    seen = set()

    def emit(unit, concept, score, reason):
        key = (unit.name, unit.kind, unit.file)
        if key in seen:
            return
        seen.add(key)
        if want_kinds and unit.kind not in want_kinds:
            return
        candidates.append({
            "name": unit.name,
            "kind": unit.kind,
            "file": unit.file,
            "score": round(score, 4),
            "reason": reason,
            "concept": concept,
        })

    # 1) named-intent hints: map task INTENT → existing repo symbols to reuse.
    for rx, names in _INTENT_HINTS:
        if not rx.search(task or ""):
            continue
        concept = rx.pattern.split("|")[0].strip("\\b").strip()
        concepts.append(concept)
        emitted = 0
        for nm in names:
            u = by_name.get(nm)
            if u is None:
                # the exact symbol isn't here, but a near-named one might be the
                # capability — surface it so the agent reuses it not reinvents.
                u = _near_repo_unit(nm, index)
            if u is not None and emitted < max_per_concept:
                emit(u, concept, 0.9, "task implies %r; reuse existing %s %r"
                     % (concept, u.kind, u.name))
                emitted += 1

    # 2) STRUCTURAL concepts (selectors / MMKV keys / slices): when the task talks
    # about selectors / storage keys / slices, surface the EXISTING RN reuse units
    # of that kind so a new one reuses rather than duplicates.
    kind_for_concept = {
        "selector": "rn-selector",
        "MMKV": "mmkv-key",
        "storage key": "mmkv-key",
        "cache key": "mmkv-key",
        "slice": "rn-slice",
    }
    tl = (task or "").lower()
    for phrase, kind in kind_for_concept.items():
        if phrase.lower() in tl:
            concepts.append(phrase)
            n = 0
            for u in index:
                if u.kind == kind and n < max_per_concept:
                    emit(u, phrase, 0.85,
                         "task touches %s; an existing %s already exists — reuse it"
                         % (phrase, kind))
                    n += 1

    candidates.sort(key=lambda c: (-c["score"], c["name"]))
    advice = _factor_advice(candidates)
    return {
        "task": task,
        "candidates": candidates,
        "concepts": sorted(set(concepts)),
        "advice": advice,
    }


def _near_repo_unit(name, index):
    """Find an existing repo unit whose name is near `name` (the capability under a
    slightly different identifier), or None."""
    best = None
    for u in index:
        if dedup.normalize(u.name) == dedup.normalize(name):
            return u
        if best is None and dedup.near(name, u.name):
            best = u
    return best


def _factor_advice(candidates):
    if not candidates:
        return ("no existing reuse candidates detected for this task — proceed, "
                "but the commit-time gate will still backstop residual redundancy")
    names = ", ".join(c["name"] for c in candidates[:5])
    return ("reuse existing machinery instead of reimplementing: %s" % names)


# ── COMMIT-TIME GATE ──────────────────────────────────────────────────────────


def gate_attestation(attestation, repo_files=None, changed_files=None,
                     floor=DEFAULT_REUSE_FLOOR, policy="flag"):
    """PHASE 2. Read SI-2's `reuse` field from an attestation record and decide the
    residual-redundancy verdict. Redum does NOT re-measure reuse — it ACTS on the
    metric SI-2 already emitted.

    attestation: the SI-2 record dict (from heimdall-attest), or its `reuse` sub-
                 dict directly. Must carry reuse_pct + suspected_duplicates.
    repo_files / changed_files: optional {path: src} maps. When provided, the
                 shared dedup matcher NAMES the exact existing unit each residual
                 duplicate should have reused + WHERE it lives (so the flag is
                 actionable, not just "low reuse"). Without them the gate still
                 fires on SI-2's suspected_duplicates (the metric stands alone).
    floor: reuse_pct below which a change is flagged (default 0.30, = SI-2 floor).
    policy: "flag" (default; warn, exit non-blocking) or "block" (the gate fails).

    Returns {
      "verdict": "ok" | "flag" | "block",
      "reuse_pct": float|None,
      "suspected_duplicates": [...],        # echoed from SI-2 (not recomputed)
      "residual": [ {new_unit, duplicates, existing, reason}, ... ],
      "flags": [ {level, code, detail}, ... ],
      "summary": one-line human verdict,
    }"""
    reuse_field = _reuse_field(attestation)
    pct = reuse_field.get("reuse_pct")
    suspected = reuse_field.get("suspected_duplicates") or []

    flags = []
    residual = []

    # Build the dedup index ONCE if we were handed the repo surface, so each
    # residual duplicate can name the precise existing unit + file to reuse.
    index = None
    if repo_files:
        index = dedup.index_repo_units(repo_files)

    # 1) suspected_duplicates from SI-2 are RESIDUAL redundancy: the change re-added
    #    a shape the repo already had. Name the existing unit for each.
    for d in suspected:
        dup_name = d.get("duplicates")
        new_unit = d.get("new_unit")
        existing = _name_existing(dup_name, index)
        residual.append({
            "new_unit": new_unit,
            "duplicates": dup_name,
            "existing": existing,
            "reason": "change re-implements pre-existing %r instead of reusing it"
                      % dup_name,
        })

    # 1b) RN/MMKV residual: even when SI-2's symbol-level suspected_duplicates is
    #     empty, a NEW RN reuse unit (selector / MMKV key / slice) that duplicates
    #     an EXISTING one is residual redundancy SI-2's function-level metric may
    #     not name. Catch it with the RN-aware dedup matcher.
    if index is not None and changed_files:
        residual.extend(_rn_residual(changed_files, repo_files, index, suspected))

    if residual:
        names = sorted({r["duplicates"] for r in residual if r.get("duplicates")})
        flags.append({
            "level": "high",
            "code": "residual-duplicate",
            "detail": "change duplicates existing repo unit(s): %s — reuse them "
                      "instead of reimplementing" % ", ".join(names),
        })

    # 2) low reuse_pct floor (a change that SHOULD have reused but scored low).
    if pct is not None and pct < floor:
        flags.append({
            "level": "high",
            "code": "low-reuse",
            "detail": "reuse_pct=%.2f below the %.2f floor — the change likely "
                      "reinvents existing repo code" % (pct, floor),
        })

    # verdict: any high flag → flag (or block under block policy); else ok.
    has_high = any(f["level"] == "high" for f in flags)
    if not has_high:
        verdict = "ok"
    else:
        verdict = "block" if policy == "block" else "flag"

    return {
        "verdict": verdict,
        "reuse_pct": pct,
        "suspected_duplicates": suspected,
        "residual": residual,
        "flags": flags,
        "summary": _gate_summary(verdict, pct, residual, floor),
    }


def _reuse_field(attestation):
    """Accept either a full SI-2 record (with a top-level `reuse` field) or the
    reuse sub-dict directly. Returns the reuse dict (never raises — an absent field
    yields an empty dict so the gate degrades to 'ok' rather than crashing)."""
    if not isinstance(attestation, dict):
        return {}
    if "reuse" in attestation and isinstance(attestation["reuse"], dict):
        return attestation["reuse"]
    # already the reuse sub-dict?
    if "reuse_pct" in attestation or "suspected_duplicates" in attestation:
        return attestation
    return {}


def _name_existing(dup_name, index):
    """Resolve a suspected-duplicate symbol name to the existing repo unit (file +
    kind + span) via the dedup index, or a minimal {name} when not found / no
    index. This turns SI-2's bare name into an actionable 'reuse THIS at file:line'."""
    if not dup_name:
        return None
    if index is None:
        return {"name": dup_name}
    cands = dedup.match_candidates(dup_name, index, max_results=1)
    if cands:
        u = cands[0]["unit"]
        return {"name": u["name"], "kind": u.get("kind"), "file": u.get("file"),
                "span": u.get("span")}
    return {"name": dup_name}


def _rn_residual(changed_files, repo_files, index, already_suspected):
    """Find RN/MMKV reuse units in the CHANGED files that duplicate an EXISTING
    repo unit (matched via the shared dedup core). Excludes any name already named
    in SI-2's suspected_duplicates (no double-reporting). Returns residual rows."""
    out = []
    suspected_names = {d.get("duplicates") for d in (already_suspected or [])}
    suspected_names |= {d.get("new_unit") for d in (already_suspected or [])}
    seen = set()
    for path, src in changed_files.items():
        if reuse.is_test_path(path):
            continue
        for ru in dedup.rn_units(src, path):
            cands = dedup.match_candidates(ru, index, max_results=1)
            if not cands:
                continue
            top = cands[0]
            existing_file = top["unit"].get("file")
            # a unit "duplicating" a unit in the SAME changed file at the same spot
            # is itself, not a duplicate — require the match to live elsewhere OR a
            # different definition site.
            if existing_file == path and top["match"].startswith("name"):
                # same file: only treat as residual if it's a second definition.
                if _single_definition(src, ru):
                    continue
            if ru.name in suspected_names:
                continue
            key = (ru.kind, ru.name, existing_file)
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "new_unit": ru.name,
                "duplicates": top["unit"]["name"],
                "existing": {"name": top["unit"]["name"], "kind": top["unit"].get("kind"),
                             "file": existing_file, "span": top["unit"].get("span")},
                "reason": "new %s %r duplicates existing %s (%s)"
                          % (ru.kind, ru.name, top["unit"].get("kind"), top["reason"]),
            })
    return out


def _single_definition(src, ru):
    """True if `ru`'s key/name appears only once as a definition in `src` (so a
    same-file match is the unit itself, not a duplicate within the file)."""
    key = ru.detail.get("key") or ru.name
    return src.count(key) <= 1


def _gate_summary(verdict, pct, residual, floor):
    pct_s = "n/a" if pct is None else "%.0f%%" % (pct * 100)
    if verdict == "ok":
        return "redum gate: OK (reuse=%s, no residual duplicates)" % pct_s
    n = len(residual)
    return ("redum gate: %s — reuse=%s, %d residual duplicate%s "
            "(floor=%.0f%%)" % (verdict.upper(), pct_s, n,
                                "" if n == 1 else "s", floor * 100))
