#!/usr/bin/env python3
# collision.py — TEAM MODE P3 (F4), the same-target-CHANGED collision engine.
#
# THE DISTINCTION (F4 ≠ F3 Redum):
#   F3 Redum = "you both MADE your own X" — REDUNDANT CREATION (two branches each
#   re-implement a shape the repo already had). Already shipped (heimdall-redum).
#   F4 Collision = "you both TOUCHED X" — SAME-THING-CHANGED (two branches edit
#   the SAME existing function / file / symbol). THIS module. Redum dedupes new
#   work; collision surfaces a coordination conflict on shared work.
#
# WHAT IT DOES — a QUERY on SI-3, NOT a new git crawler:
#   The detection substrate is SI-3 (bin/lib/branch_context.py). This engine does
#   NOT re-walk branches; it CALLS branch_context.query_target for each target a
#   sibling also touched and reads the own-branch-first overlap it already
#   computes. SI-3 owns "which OTHER branch touched the same file/symbol, framed
#   relative to MY current branch". collision.py owns the LAYER ON TOP: for each
#   such overlap, CLASSIFY it and decide SURFACE-vs-resolve.
#
# OWN-BRANCH-FIRST (inherited from SI-3): every collision is framed relative to
#   the CURRENT branch — "your handleLogin vs feat-b's handleLogin". The current
#   branch is the `own` anchor; siblings hang off it. No "list everything every
#   sibling did" dump (that is the noise SI-3 forbids and this engine inherits).
#
# SURFACE OVER AUTO-MERGE (the "nothing ships unproven" ethos):
#   A collision is classified, NEVER silently merged:
#     • SAFE-TEXTUAL  → the two branches changed DISJOINT line regions of the file
#       (no overlapping hunk ranges) OR made the IDENTICAL change. A textual
#       three-way merge would apply cleanly with no conflict. resolution =
#       "safe-textual": the engine REPORTS it is auto-resolvable. It still does
#       NOT write a merged file — the human/merge-tool applies it; the engine's
#       job is the honest verdict, not the merge.
#     • FLAG-HUMAN    → the SAME function/symbol body DIVERGED on the two branches
#       (both edited the same symbol, and the resulting bodies differ). This is a
#       SEMANTIC collision. resolution = "flag-human": it MUST go to a human. The
#       engine NEVER classifies a divergent same-symbol body as safe / auto-merge
#       — doing so is the falsifiable failure the conformance test REDs on.
#   The rule, stated negatively (the invariant the test enforces): a same-symbol
#   body divergence is NEVER resolution == "safe-textual". Risk beats convenience.
#
# CHEAP + MECHANICAL — git plumbing + tree-sitter, NO LLM:
#   • which siblings touched the target → SI-3 (merge-base / diff --name-only)
#   • per-symbol same-target            → SI-3 changed_symbols (tree-sitter)
#   • disjoint-vs-overlapping regions   → `git diff -U0 base..tip` hunk ranges,
#                                          intersected between the two sides
#   • identical-change detection        → compare the two tips' blob of the file
#   No diff is interpreted by an LLM; every signal is a git command or an AST query.
#
# GRACEFUL WHEN SOLO (the mandatory Heimdall pattern):
#   One branch → no siblings → zero collisions, solo=True, NO crash. A detached
#   HEAD / non-repo degrades to an honest empty result rather than raising.
#
# SECRET-FREE BY CONSTRUCTION:
#   A collision RECORD carries ONLY branch names + target (file/symbol) names +
#   the classification. It NEVER carries code, diffs, hunk bodies, or blobs — so
#   the git-tracked store (.planning/ledger/collisions/) is gitleaks-clean by
#   construction. The classification reads the bodies in memory; it writes only
#   the verdict.
#
# This is a LIBRARY (functions over a repo dir). The thin CLI is
# bin/heimdall-collision, which owns argument parsing + JSON/record I/O.

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import branch_context as B  # SI-3 — the substrate P3 queries.

SCHEMA_VERSION = "p3-collision.1"

# Resolution verdicts. The negative invariant the conformance test enforces:
# RESOLVE_FLAG is the ONLY verdict a divergent same-symbol body may carry.
RESOLVE_SAFE = "safe-textual"   # disjoint regions OR identical change → auto-resolvable
RESOLVE_FLAG = "flag-human"     # same symbol body diverged → SEMANTIC, human decides
RESOLVE_NONE = "none"           # no real collision (sibling touched file but not own target)


# ── per-side hunk regions (git diff -U0 → changed line ranges) ─────────────────

# A unified-diff hunk header: @@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@
_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def _changed_line_ranges(repo, base, tip, path):
    """The set of (start, end) line ranges a branch CHANGED in `path` between
    base and tip, taken from `git diff -U0 base..tip -- path` hunk headers (the
    NEW-side ranges on the tip). -U0 → zero context, so the ranges are exactly
    the touched lines. Returns a list of (start, end) inclusive on the tip side;
    an empty list when nothing changed or the diff is unavailable. NEVER raises."""
    if base is None:
        return []
    rng = "%s..%s" % (base, tip)
    out, rc = B._git(repo, "diff", "-U0", rng, "--", path)
    if rc != 0:
        return []
    ranges = []
    for line in out.splitlines():
        m = _HUNK_RE.match(line)
        if not m:
            continue
        new_start = int(m.group(3))
        new_count = m.group(4)
        count = int(new_count) if new_count is not None else 1
        if count == 0:
            # a pure deletion (new_count 0) touches the position new_start.
            ranges.append((new_start, new_start))
        else:
            ranges.append((new_start, new_start + count - 1))
    return ranges


def _ranges_overlap(a_ranges, b_ranges):
    """True iff any range in a_ranges overlaps any range in b_ranges (inclusive)."""
    for a0, a1 in a_ranges:
        for b0, b1 in b_ranges:
            if a0 <= b1 and b0 <= a1:
                return True
    return False


def _file_blob(repo, ref, path):
    """The file's content at `ref` (None if absent). Used ONLY in memory to detect
    an identical change; never written to a record."""
    return B._show(repo, ref, path)


# ── the collision classifier (SURFACE > auto-merge) ────────────────────────────


def _classify(repo, own_base, sib_base, sibling, file_path, symbol,
              own_touched_symbol, sib_touched_symbol):
    """Classify ONE current-branch-vs-sibling overlap on a target into a
    resolution verdict + a human reason. SURFACE > auto-merge:

      • Identical change (both tips carry the same blob for the file) → SAFE: the
        merge is a no-op, nothing to decide.
      • A SYMBOL was queried and BOTH sides touched that same symbol → FLAG: the
        same function body diverged (we already know the blobs differ, else the
        identical-change branch caught it). A semantic collision is NEVER safe.
      • No symbol queried (file-level), regions DISJOINT → SAFE: a three-way
        textual merge applies cleanly.
      • No symbol queried, regions OVERLAP → FLAG: the two branches edited the
        same lines; let a human resolve.

    Returns (resolution, reason). The negative invariant: a same-symbol body
    divergence ALWAYS returns RESOLVE_FLAG (never RESOLVE_SAFE)."""
    sib_tip = sibling

    # ── identical change short-circuit: the two tips agree on the whole file ──
    own_blob = _file_blob(repo, "HEAD", file_path)
    sib_blob = _file_blob(repo, sib_tip, file_path)
    if own_blob is not None and own_blob == sib_blob:
        return (RESOLVE_SAFE,
                "identical change: both branches' %s are byte-identical — merge is a no-op"
                % file_path)

    # ── symbol-level: same function body diverged → SEMANTIC, FLAG for human ──
    # (we are here only because the blobs differ, so a shared touched symbol means
    #  the symbol body genuinely diverged.)
    if symbol is not None and own_touched_symbol and sib_touched_symbol:
        return (RESOLVE_FLAG,
                "same-symbol divergence: %s#%s changed on both the current branch "
                "and %s with differing bodies — a SEMANTIC collision; a human must "
                "decide (never auto-merged)" % (file_path, symbol, sibling))

    # ── file-level: disjoint line regions resolve, overlapping flag ───────────
    own_ranges = _changed_line_ranges(repo, own_base, "HEAD", file_path)
    sib_ranges = _changed_line_ranges(repo, sib_base, sib_tip, file_path)
    if own_ranges and sib_ranges and _ranges_overlap(own_ranges, sib_ranges):
        return (RESOLVE_FLAG,
                "overlapping line regions: the current branch and %s edited the "
                "same lines of %s — a textual conflict; a human must resolve"
                % (sibling, file_path))
    # disjoint (or one side has no resolvable range) → a clean textual merge.
    return (RESOLVE_SAFE,
            "disjoint regions: the current branch and %s changed non-overlapping "
            "parts of %s — a three-way textual merge applies cleanly"
            % (sibling, file_path))


# ── the public detector: query SI-3, classify each overlap ─────────────────────


def detect_target(repo, target, with_symbols=True):
    """Detect same-target-CHANGED collisions for a SINGLE `target` (a file path or
    "path#symbol"), framed OWN-BRANCH-FIRST. Calls SI-3 (query_target) and
    classifies every sibling overlap it surfaces.

    Returns:
      { schema, repo, current, target:{file,symbol},
        own:{ touched, symbols },                  # SI-3's own-branch anchor
        collisions: [ { sibling, merge_base, touched_symbol, resolution,
                        reason, requires_human } ],
        flagged, safe, solo }

    `collisions` contains ONLY siblings that REALLY collide (touched the SAME
    target the current branch did — SI-3's overlap=true). A sibling that touched
    the file but NOT the queried symbol is NOT a collision and is omitted.
    `flagged` counts FLAG-HUMAN verdicts, `safe` counts SAFE-TEXTUAL. Solo (one
    branch) → empty collisions, solo=True, no crash. Secret-free: only names +
    verdicts, never code."""
    repo = os.path.abspath(repo)
    q = B.query_target(repo, target, with_symbols=with_symbols, with_attestation=True)
    file_path = q["target"]["file"]
    symbol = q["target"]["symbol"]

    own_ctx = B.own_context(repo)
    own_base = own_ctx.get("merge_base")
    own_touched_symbol = bool(q["own"]["touched"])

    result = {
        "schema": SCHEMA_VERSION,
        "repo": repo,
        "current": q["current"],
        "target": {"file": file_path, "symbol": symbol},
        "own": q["own"],
        "collisions": [],
        "flagged": 0,
        "safe": 0,
        "solo": q["solo"],
    }
    if q["solo"] or not q["other_branches"]:
        return result

    for ob in q["other_branches"]:
        if not ob.get("overlap"):
            continue  # touched the file but not the SAME target → not a collision
        sibling = ob["branch"]
        sib_base = ob.get("merge_base")
        sib_touched_symbol = bool(ob.get("touched_symbol"))
        resolution, reason = _classify(
            repo, own_base, sib_base, sibling, file_path, symbol,
            own_touched_symbol, sib_touched_symbol,
        )
        result["collisions"].append({
            "sibling": sibling,
            "merge_base": sib_base,
            "touched_symbol": sib_touched_symbol,
            "resolution": resolution,
            "reason": reason,
            "requires_human": resolution == RESOLVE_FLAG,
        })
        if resolution == RESOLVE_FLAG:
            result["flagged"] += 1
        elif resolution == RESOLVE_SAFE:
            result["safe"] += 1

    result["collisions"].sort(key=lambda c: c["sibling"])
    return result


def scan(repo, with_symbols=True):
    """Detect EVERY same-target-CHANGED collision for the CURRENT branch: for each
    file the current branch changed (own_context.changed_files) that a sibling
    ALSO changed, resolve the colliding symbols (tree-sitter) and classify each.
    Framed own-branch-first; the result aggregates per-target detect_target runs.

    Returns:
      { schema, repo, current, base_ref, targets:[ <detect_target result>... ],
        total_collisions, flagged, safe, solo }

    Solo / no overlap → empty targets, solo flag honest, no crash. This is the
    cheap "what do I collide with right now?" the launch path can call. Only files
    the current branch ACTUALLY changed are considered — no sibling dump."""
    repo = os.path.abspath(repo)
    own = B.own_context(repo)
    cur = own.get("current")

    result = {
        "schema": SCHEMA_VERSION,
        "repo": repo,
        "current": cur,
        "base_ref": own.get("base_ref"),
        "targets": [],
        "total_collisions": 0,
        "flagged": 0,
        "safe": 0,
        "solo": bool(own.get("solo")),
    }
    if own.get("solo") or cur is None:
        return result

    own_base = own.get("merge_base")
    others = [b for b in B.local_branches(repo) if b != cur]
    if not others:
        result["solo"] = True
        return result

    for path in own.get("changed_files", []):
        # which siblings also changed this file? (cheap SI-3 file query first)
        sibling_changed = False
        sib_syms = set()
        for o in others:
            mb = B.merge_base(repo, "HEAD", o)
            ofiles = B.changed_files(repo, mb, o)
            if path in ofiles:
                sibling_changed = True
                if with_symbols:
                    sib_syms |= B.changed_symbols(repo, mb, o, path)
        if not sibling_changed:
            continue

        # resolve the current branch's changed symbols in this file; intersect
        # with the siblings' to find the SAME symbols both sides touched.
        own_syms = (B.changed_symbols(repo, own_base, "HEAD", path)
                    if with_symbols else set())
        shared_syms = sorted(own_syms & sib_syms)

        if shared_syms:
            # one symbol-level target per shared symbol (the precise collision).
            for sym in shared_syms:
                dt = detect_target(repo, "%s#%s" % (path, sym),
                                   with_symbols=with_symbols)
                if dt["collisions"]:
                    result["targets"].append(dt)
        else:
            # no shared symbol resolvable → file-level target.
            dt = detect_target(repo, path, with_symbols=with_symbols)
            if dt["collisions"]:
                result["targets"].append(dt)

    for dt in result["targets"]:
        result["total_collisions"] += len(dt["collisions"])
        result["flagged"] += dt["flagged"]
        result["safe"] += dt["safe"]
    return result


# ── the git-tracked, secret-free collision RECORD ──────────────────────────────


def record_for(scan_result):
    """Build the secret-free, git-tracked collision RECORD from a scan result.
    Carries ONLY branch names + target names + classifications — NEVER code,
    diffs, or blobs (so the store is gitleaks-clean by construction). One record
    per current-branch scan, keyed by the current branch.

    Shape:
      { schema, current, base_ref, recorded_at(caller-filled), solo,
        total_collisions, flagged, safe,
        collisions: [ { file, symbol, sibling, resolution, requires_human,
                        reason } ] }"""
    flat = []
    for dt in scan_result.get("targets", []):
        f = dt["target"]["file"]
        s = dt["target"]["symbol"]
        for c in dt["collisions"]:
            flat.append({
                "file": f,
                "symbol": s,
                "sibling": c["sibling"],
                "resolution": c["resolution"],
                "requires_human": c["requires_human"],
                "reason": c["reason"],
            })
    flat.sort(key=lambda c: (c["file"], c["symbol"] or "", c["sibling"]))
    return {
        "schema": SCHEMA_VERSION,
        "current": scan_result.get("current"),
        "base_ref": scan_result.get("base_ref"),
        "solo": bool(scan_result.get("solo")),
        "total_collisions": scan_result.get("total_collisions", 0),
        "flagged": scan_result.get("flagged", 0),
        "safe": scan_result.get("safe", 0),
        "collisions": flat,
    }


# ── human one-line summaries (for the CLI's stderr) ────────────────────────────


def scan_summary(res):
    cur = res.get("current") or "(detached)"
    if res.get("solo"):
        return "collision [scan]: %s — solo, no siblings, 0 collisions" % cur
    total = res.get("total_collisions", 0)
    if total == 0:
        return ("collision [scan]: %s vs %s — 0 same-target collisions"
                % (cur, res.get("base_ref") or "(siblings)"))
    return ("collision [scan]: %s — %d same-target collision(s): %d FLAG-for-human, "
            "%d safe-textual" % (cur, total, res.get("flagged", 0), res.get("safe", 0)))


def target_summary(res):
    tgt = res["target"]["file"] or "(none)"
    if res["target"]["symbol"]:
        tgt += "#" + res["target"]["symbol"]
    cur = res.get("current") or "(detached)"
    if res.get("solo"):
        return "collision [%s]: %s — solo, no siblings, 0 collisions" % (cur, tgt)
    n = len(res["collisions"])
    if n == 0:
        return "collision [%s]: %s — no same-target collision" % (cur, tgt)
    sibs = ", ".join(c["sibling"] for c in res["collisions"])
    flag = " ⚑ FLAG-for-human" if res.get("flagged") else ""
    return ("collision [%s]: %s — %d collision(s) with [%s]%s"
            % (cur, tgt, n, sibs, flag))
