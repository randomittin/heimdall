#!/usr/bin/env python3
"""land_consolidate.py — Class-1 REDUNDANCY consolidation for heimdall-land.

Reuses Redum's similarity engine (bin/lib/dedup.py — the SAME core F3 Redum and
F2 Checker fuse onto) to find near/exact-name DUPLICATE function definitions in a
merged worktree, then collapses each duplicate cluster N->1 so only ONE survivor
reaches shared main.

The split mirrors the spec's Class 1 / Class 2 line:
  • DETECTION is Redum's — dedup.match_candidates decides WHAT is redundant
    (exact-normalized name, or a near-duplicate name: `to_slug` ~ `toSlug`).
  • The SOLVER (removal + reference rewrite) is here: it deletes the duplicate
    definitions and rewrites their call sites to the survivor, span-driven when
    tree-sitter gave a span, language-aware regex fallback otherwise (Python
    `def`, JS/TS `function` + `const NAME = (...) =>`).

Survivor policy (own-branch-first / reuse-existing, per spec):
  1. a unit ALREADY on current main  -> reuse existing (don't rebuild it).
  2. else a unit added by the landing branch -> own-branch survives.
  3. else lexical (file, name) -> deterministic tie-break.

This does NOT catch Class 2 (semantic incompatibility / dangling references) —
there is no duplicate to find there; the merged-result GATE catches that. This
file is REDUNDANCY only.

Usage:
  land_consolidate.py --repo DIR [--main-ref REF] [--branch-ref REF]
                      [--floor F] [--apply] [--json]

  --repo DIR     the merged worktree to consolidate (default: cwd).
  --main-ref     git ref for CURRENT shared main (to know what pre-exists ->
                 reuse-existing). Optional; absent -> own-branch/lexical policy.
  --branch-ref   git ref for the landing branch (to know what it ADDED ->
                 own-branch-first). Optional.
  --floor F      similarity floor in (0,1]; pairs scoring >= F are duplicates
                 (default 0.7 — Redum's near-name threshold).
  --apply        WRITE the consolidation to disk. Default is a dry plan (JSON
                 only, no file changes).
  --json         print the machine-readable plan/result JSON to stdout.

Exit: 0 always on a successful scan/apply (the verdict is in the JSON:
      `consolidations` empty == nothing redundant). 2 = usage/IO error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import dedup  # noqa: E402 — sibling import after sys.path setup
import reuse_analyzer as reuse  # noqa: E402


def _git(repo, *args):
    """Run a git command in `repo`; return stripped stdout ('' on failure)."""
    try:
        out = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True, text=True, check=False,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:  # noqa: BLE001
        return ""


def _tracked_sources(repo):
    """{relpath: source} for every tracked, language-detectable, non-test file."""
    listing = _git(repo, "ls-files")
    files = {}
    for rel in listing.splitlines():
        rel = rel.strip()
        if not rel or reuse.is_test_path(rel):
            continue
        if reuse.detect_language(rel) is None:
            continue
        ap = os.path.join(repo, rel)
        try:
            with open(ap, "r", encoding="utf-8", errors="replace") as fh:
                files[rel] = fh.read()
        except (OSError, UnicodeError):
            continue
    return files


def _names_at_ref(repo, ref):
    """Set of EXACT function/method names defined at a git `ref` (so we can tell
    which exact side of a duplicate PRE-EXISTS on shared main — normalized
    membership can't distinguish `total_amount` from `totalAmount`)."""
    if not ref:
        return set()
    listing = _git(repo, "ls-tree", "-r", "--name-only", ref)
    names = set()
    for rel in listing.splitlines():
        rel = rel.strip()
        if not rel or reuse.is_test_path(rel) or reuse.detect_language(rel) is None:
            continue
        src = _git(repo, "show", "%s:%s" % (ref, rel))
        if not src:
            continue
        for u in dedup.index_repo_units({rel: src}):
            if u.kind in ("function", "method", "unit"):
                names.add(u.name)
    return names


_FUNC_KINDS = ("function", "method", "unit")


def _cluster(units, floor):
    """Union-find clusters of DISTINCT function units that dedup deems duplicate
    (score >= floor). Two units cluster when their names match per Redum's
    similarity (exact-normalized or near-name) and they are distinct definitions."""
    funcs = [u for u in units if u.kind in _FUNC_KINDS]
    parent = list(range(len(funcs)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        parent[find(i)] = find(j)

    for i in range(len(funcs)):
        for j in range(i + 1, len(funcs)):
            a, b = funcs[i], funcs[j]
            if a.file == b.file and a.span and b.span and a.span == b.span:
                continue  # same definition
            res = dedup.match_candidates(a, [b])
            if res and res[0]["score"] >= floor:
                union(i, j)

    groups = {}
    for i, u in enumerate(funcs):
        groups.setdefault(find(i), []).append(u)
    return [g for g in groups.values() if len(g) >= 2]


def _pick_survivor(group, main_names, branch_added_names):
    """Own-branch-first / reuse-existing survivor selection."""
    def key(u):
        return (u.file, u.name)

    on_main = [u for u in group if u.name in main_names]
    if on_main:
        return sorted(on_main, key=key)[0]
    on_branch = [u for u in group if u.name in branch_added_names]
    if on_branch:
        return sorted(on_branch, key=key)[0]
    return sorted(group, key=key)[0]


# ── definition location (span-driven, language-aware regex fallback) ──────────

def _ident_re(name):
    return re.compile(r"\b" + re.escape(name) + r"\b")


def _py_def_span(lines, name):
    """1-based inclusive (start,end) of a top-or-nested Python `def name`."""
    pat = re.compile(r"^(\s*)def\s+" + re.escape(name) + r"\s*\(")
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if not m:
            continue
        indent = len(m.group(1))
        end = len(lines)
        for j in range(i + 1, len(lines)):
            s = lines[j]
            if s.strip() == "":
                continue
            cur = len(s) - len(s.lstrip())
            if cur <= indent:
                end = j
                break
        else:
            end = len(lines)
        return (i + 1, end)  # end exclusive index -> caller slices [start-1:end]
    return None


def _brace_end(text, open_idx):
    """Index just past the matching close brace for the `{` at open_idx."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _js_def_range(src, name):
    """Char range (start,end) of a JS/TS `function name` or `const name = ...`."""
    # function declaration
    m = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\(", src)
    if m:
        brace = src.find("{", m.end() - 1)
        if brace != -1:
            return (m.start(), _brace_end(src, brace))
    # const/let/var name = (...) => {...}  OR = function (...) {...}  OR = expr;
    m = re.search(r"\b(?:const|let|var)\s+" + re.escape(name) + r"\s*=", src)
    if m:
        brace = src.find("{", m.end())
        semi = src.find(";", m.end())
        # if a brace opens before the next semicolon, it's a block body.
        if brace != -1 and (semi == -1 or brace < semi):
            end = _brace_end(src, brace)
            if end < len(src) and src[end] == ";":
                end += 1
            return (m.start(), end)
        if semi != -1:
            return (m.start(), semi + 1)
    return None


def _remove_definition(repo, unit):
    """Delete `unit`'s definition from its file. Returns LOC removed (or 0)."""
    ap = os.path.join(repo, unit.file)
    try:
        with open(ap, "r", encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return 0

    if unit.lang == "py":
        lines = src.splitlines(keepends=True)
        # prefer the tree-sitter span when present, else locate by name.
        if unit.span:
            start, end = unit.span[0], unit.span[1]
        else:
            sp = _py_def_span([l.rstrip("\n") for l in lines], unit.name)
            if not sp:
                return 0
            start, end = sp
        removed = lines[start - 1:end]
        new = lines[:start - 1] + lines[end:]
        with open(ap, "w", encoding="utf-8") as fh:
            fh.write("".join(new))
        return len([l for l in removed if l.strip()])

    # JS/TS (and other brace languages): char-range removal.
    rng = _js_def_range(src, unit.name)
    if not rng:
        return 0
    s, e = rng
    chunk = src[s:e]
    new = src[:s] + src[e:]
    # collapse a leftover blank line pair.
    new = re.sub(r"\n[ \t]*\n[ \t]*\n", "\n\n", new)
    with open(ap, "w", encoding="utf-8") as fh:
        fh.write(new)
    return chunk.count("\n") + 1


def _rewrite_references(repo, files, dup_name, survivor_name):
    """Rewrite whole-word `dup_name` -> `survivor_name` across tracked files.
    Returns the list of files changed."""
    changed = []
    rx = _ident_re(dup_name)
    for rel in files:
        ap = os.path.join(repo, rel)
        try:
            with open(ap, "r", encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        new = rx.sub(survivor_name, src)
        if new != src:
            with open(ap, "w", encoding="utf-8") as fh:
                fh.write(new)
            changed.append(rel)
    return changed


def consolidate(repo, main_ref="", branch_ref="", floor=0.7, apply=False):
    files = _tracked_sources(repo)
    units = dedup.index_repo_units(files)
    clusters = _cluster(units, floor)

    main_names = _names_at_ref(repo, main_ref) if main_ref else set()
    branch_added = set()
    if branch_ref:
        branch_added = _names_at_ref(repo, branch_ref) - main_names

    plan = []
    for group in clusters:
        survivor = _pick_survivor(group, main_names, branch_added)
        removed = [u for u in group if not (u.file == survivor.file
                                            and u.name == survivor.name)]
        plan.append({
            "survivor": {"name": survivor.name, "file": survivor.file,
                         "kind": survivor.kind},
            "removed": [{"name": u.name, "file": u.file, "kind": u.kind}
                        for u in removed],
            "reason": "duplicate-cluster size %d -> survivor reused" % len(group),
        })

    loc_removed = 0
    files_changed = set()
    if apply and plan:
        for entry, group in zip(plan, clusters):
            survivor = _pick_survivor(group, main_names, branch_added)
            for u in group:
                if u.file == survivor.file and u.name == survivor.name:
                    continue
                loc_removed += _remove_definition(repo, u)
                files_changed.add(u.file)
                # re-read files (a removal may have changed one) before rewrite.
                cur = _tracked_sources(repo)
                for ch in _rewrite_references(repo, cur, u.name, survivor.name):
                    files_changed.add(ch)

    return {
        "schema": "land-consolidate.1",
        "repo": repo,
        "floor": floor,
        "applied": bool(apply),
        "consolidations": plan,
        "duplicate_clusters": len(plan),
        "loc_removed": loc_removed,
        "files_changed": sorted(files_changed),
    }


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    ap.add_argument("--repo", default=os.getcwd())
    ap.add_argument("--main-ref", default="")
    ap.add_argument("--branch-ref", default="")
    ap.add_argument("--floor", type=float, default=0.7)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    repo = os.path.abspath(args.repo)
    if not os.path.isdir(os.path.join(repo, ".git")) and not _git(repo, "rev-parse", "--git-dir"):
        print("error: not a git repo: %s" % repo, file=sys.stderr)
        return 2

    result = consolidate(repo, args.main_ref, args.branch_ref, args.floor, args.apply)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        n = result["duplicate_clusters"]
        if n == 0:
            print("redum: no redundant duplicate functions in merged state", file=sys.stderr)
        else:
            for c in result["consolidations"]:
                rem = ", ".join("%s@%s" % (r["name"], r["file"]) for r in c["removed"])
                print("redum: keep %s@%s; collapse [%s]" % (
                    c["survivor"]["name"], c["survivor"]["file"], rem), file=sys.stderr)
            if result["applied"]:
                print("redum: consolidated %d cluster(s), -%d LOC, %d file(s) rewritten" % (
                    n, result["loc_removed"], len(result["files_changed"])), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
