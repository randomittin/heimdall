#!/usr/bin/env python3
# checker.py — F2 Checker, the duplicate-shape CHECKER (the engine behind
# bin/heimdall-check). It answers ONE question at three depths:
#
#   "Does this change re-add a code shape the repo (or another author) already
#    provides — and if so, WHICH existing unit should it have reused?"
#
# F2 is FUSED onto the SHARED dedup core (bin/lib/dedup.py) — it does NOT fork the
# matcher. F3 Redum's commit-time gate and F2's max-tier are the SAME machinery
# (index_repo_units + match_candidates); F2 adds only the cross-author filter the
# fusion interface at the bottom of dedup.py exposes (different_author_than=).
#
# THREE TIERS (depth of the check, cheapest → deepest):
#
#   none   — PASSTHROUGH. No analysis. Returns an OK verdict with tier="none" so a
#            pipeline can disable the check without removing the call. Exists so
#            `--tier none` is a real, honest no-op rather than a faked result.
#
#   basic  — CHEAP LOCAL checks over the CHANGED files ONLY (no pre-change repo
#            index, no git history). Catches the duplicates that are visible
#            without a repo crawl:
#              • the same named symbol defined twice across the changed set
#                (two files both declaring `selectCards`), and
#              • the same RN/MMKV reuse unit (slice name / selector / MMKV key
#                STRING) declared twice across the changed set.
#            This is the fast pre-commit smoke check — O(changed files), no index.
#
#   max    — DEEP cross-author dedup, FUSED onto dedup.py. Indexes the PRE-CHANGE
#            repo units per author (author = the unit's last-touch author via the
#            authors map the CLI supplies from `git log`/`blame`) and asks, for
#            each unit the change ADDS: does an existing unit by a DIFFERENT author
#            already provide this shape? A hit is a cross-author semantic duplicate
#            — the change reimplemented something a teammate already wrote. Uses the
#            identical matcher F3's residual-redundancy gate uses, with ast-grep
#            structural confirmation when available (demand-driven, graceful-
#            degrade). This is the same candidate machinery, not a second copy.
#
# It does NOT re-measure the S-6 reuse percentage — that is SI-2's attestation
# `reuse` field. F2 is the *matcher* that NAMES the existing unit to reuse; when a
# caller hands it the SI-2 reuse record it is echoed into the verdict for context,
# never recomputed.
#
# LIBRARY (pure functions over source text + an authors map). The CLI
# (bin/heimdall-check) owns the git extraction, exactly like bin/heimdall-redum.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import dedup  # noqa: E402 — sibling import after sys.path setup
import reuse_analyzer as reuse  # noqa: E402

# the three tiers, cheapest → deepest. Exposed so the CLI can validate --tier.
TIERS = ("none", "basic", "max")


# ── public entry: run the checker at a tier ──────────────────────────────────


def check(tier, changed_files, repo_files=None, authors=None, reuse_field=None):
    """Run the F2 Checker at `tier` over a change.

    tier:          "none" | "basic" | "max".
    changed_files: dict {path: source} of the ADDED/CHANGED side of the diff.
    repo_files:    dict {path: source} of the PRE-CHANGE repo (max tier only —
                   the surface every new unit is checked against).
    authors:       dict {path: author} mapping each PRE-CHANGE repo file to the
                   author who last touched it (max tier only — drives cross-author
                   dedup). Absent/empty → max degrades to author-agnostic dedup
                   (still real: it finds duplicates, just can't attribute authors).
    reuse_field:   optional SI-2 reuse sub-dict, echoed into the verdict for
                   context (reuse_pct + suspected_duplicates). NEVER recomputed.

    Returns {
      "tier": tier,
      "verdict": "ok" | "duplicate",
      "duplicates": [ {new_unit, kind, file, existing:{...}, author, reason}, ... ],
      "checked_units": int,           # how many changed units were examined
      "reuse_pct": float|None,        # echoed from SI-2 when supplied
      "summary": one-line human verdict,
    }
    """
    if tier not in TIERS:
        raise ValueError("unknown tier %r (expected one of %s)"
                         % (tier, ", ".join(TIERS)))

    pct = (reuse_field or {}).get("reuse_pct") if reuse_field else None

    if tier == "none":
        return _verdict("none", [], 0, pct)
    if tier == "basic":
        dups, checked = _basic(changed_files)
        return _verdict("basic", dups, checked, pct)
    dups, checked = _max(changed_files, repo_files or {}, authors or {})
    return _verdict("max", dups, checked, pct)


# ── basic tier: cheap LOCAL within-diff duplicate detection ──────────────────


def _basic(changed_files):
    """CHEAP LOCAL check: find shapes declared TWICE across the changed set, with
    NO pre-change repo index and NO git history. Two kinds of within-diff dup:

      • a named symbol (function/class/component) defined in two changed files, and
      • an RN/MMKV reuse unit (slice / selector / MMKV key string) declared twice.

    Returns (duplicates, units_checked). O(changed source files)."""
    # index the changed set itself (production source only) so a symbol/unit that
    # appears in two changed files is visible as a within-diff collision.
    prod = {p: s for p, s in changed_files.items() if not reuse.is_test_path(p)}

    # symbol-level: name → list of (file) it is defined in.
    sym_sites = {}
    rn_sites = {}     # (kind, dedup-key) → list of (name, file)
    checked = 0
    for path, src in prod.items():
        lang = reuse.detect_language(path)
        if lang is None:
            continue
        units, _mod, _used = reuse.extract_units(src, lang, path, "auto")
        for u in (units or []):
            if u.name.startswith("<module:"):
                continue
            checked += 1
            sym_sites.setdefault(u.name, []).append(path)
        for ru in dedup.rn_units(src, path):
            key = (ru.kind, ru.detail.get("key") or dedup.normalize(ru.name))
            rn_sites.setdefault(key, []).append((ru.name, path, ru))
            checked += 1

    dups = []
    for name, files in sym_sites.items():
        uniq = sorted(set(files))
        if len(uniq) > 1:
            dups.append({
                "new_unit": name,
                "kind": "symbol",
                "file": uniq[1],
                "existing": {"name": name, "file": uniq[0]},
                "author": None,
                "reason": "symbol %r defined in %d changed files (%s) — declare "
                          "it once and import it" % (name, len(uniq),
                                                     ", ".join(uniq)),
            })
    for (kind, _k), sites in rn_sites.items():
        files = sorted({f for _n, f, _ru in sites})
        if len(files) > 1:
            name = sites[0][0]
            ru = sites[0][2]
            label = ru.detail.get("key") or name
            dups.append({
                "new_unit": name,
                "kind": kind,
                "file": files[1],
                "existing": {"name": name, "file": files[0],
                             "detail": ru.detail},
                "author": None,
                "reason": "%s %r declared in %d changed files (%s) — one source "
                          "of truth" % (kind, label, len(files),
                                        ", ".join(files)),
            })

    dups.sort(key=lambda d: (d["kind"], d["new_unit"]))
    return dups, checked


# ── max tier: cross-author semantic dedup, FUSED onto the shared dedup core ──


def _max(changed_files, repo_files, authors):
    """DEEP cross-author dedup. Indexes the PRE-CHANGE repo per author (the SHARED
    dedup.index_repo_units machinery F3 uses), then asks for each unit the change
    ADDS: does an existing unit by a DIFFERENT author already provide this shape?

    This is the FUSION the dedup core's interface block documents: same
    index_repo_units + match_candidates, with different_author_than set so only
    cross-author duplicates surface. ast-grep structurally confirms a renamed body
    (demand-driven) when available; degrades to name/kind matching otherwise.

    `authors` maps each pre-change file → its last-touch author. When a file has no
    known author the unit is indexed under author None; when NO authors are known
    the check still runs author-agnostically (any existing duplicate is reported,
    just without attribution) — it never silently does nothing.

    Returns (duplicates, units_checked)."""
    # 1) index the PRE-CHANGE repo, stamping each unit with its file's author so a
    #    later match can require a DIFFERENT author. We index per-author group so
    #    the author tag is attached (index_repo_units stamps detail["author"]).
    index = []
    by_author = {}
    for path, src in repo_files.items():
        by_author.setdefault(authors.get(path), {})[path] = src
    for author, files in by_author.items():
        index.extend(dedup.index_repo_units(files, author=author))

    # 2) for each unit the change ADDS, ask the shared matcher whether an existing
    #    unit by a DIFFERENT author provides the shape. Author of the changed side
    #    is the change's own author; we treat the adding side as a single author so
    #    "different author" means "someone other than whoever wrote this change".
    #    The CLI supplies the change author under the sentinel key "" in `authors`.
    change_author = authors.get("", "__change__")

    dups = []
    checked = 0
    seen = set()
    for path, src in changed_files.items():
        if reuse.is_test_path(path):
            continue
        lang = reuse.detect_language(path)
        if lang is None:
            continue
        # build the change-side units (symbols + RN units) the SAME way the index
        # is built, so a symbol and an RN unit are both checked.
        added = dedup.index_repo_units({path: src}, author=change_author)
        for unit in added:
            checked += 1
            cands = dedup.match_candidates(
                unit, index,
                structural_src=src,
                max_results=1,
                different_author_than=change_author,
            )
            if not cands:
                continue
            top = cands[0]
            ex = top["unit"]
            # a unit "matching" its own definition site is not a cross-author dup.
            if ex.get("file") == path and ex.get("name") == unit.name:
                continue
            key = (unit.kind, unit.name, ex.get("file"))
            if key in seen:
                continue
            seen.add(key)
            ex_author = ex.get("detail", {}).get("author")
            dups.append({
                "new_unit": unit.name,
                "kind": unit.kind,
                "file": path,
                "existing": {"name": ex["name"], "kind": ex.get("kind"),
                             "file": ex.get("file"), "span": ex.get("span")},
                "author": ex_author,
                "reason": "new %s %r duplicates existing %s %r%s (%s)"
                          % (unit.kind, unit.name, ex.get("kind"), ex["name"],
                             " by %s" % ex_author if ex_author else "",
                             top["reason"]),
            })

    dups.sort(key=lambda d: (d["kind"], d["new_unit"]))
    return dups, checked


# ── verdict assembly ─────────────────────────────────────────────────────────


def _verdict(tier, dups, checked, pct):
    verdict = "duplicate" if dups else "ok"
    return {
        "tier": tier,
        "verdict": verdict,
        "duplicates": dups,
        "checked_units": checked,
        "reuse_pct": pct,
        "summary": _summary(tier, verdict, dups, checked),
    }


def _summary(tier, verdict, dups, checked):
    if tier == "none":
        return "checker[none]: OK (passthrough — no analysis)"
    if verdict == "ok":
        return ("checker[%s]: OK (%d unit%s checked, no duplicate shapes)"
                % (tier, checked, "" if checked == 1 else "s"))
    names = ", ".join(sorted({d["new_unit"] for d in dups}))
    return ("checker[%s]: DUPLICATE — %d duplicate shape%s (%s) across %d "
            "checked unit%s" % (tier, len(dups), "" if len(dups) == 1 else "s",
                                names, checked, "" if checked == 1 else "s"))
