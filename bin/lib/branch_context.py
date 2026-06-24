#!/usr/bin/env python3
# branch_context.py — the SI-3 git-backed branch-context reader (own-branch-first).
#
# SI-3 is the substrate team-mode P3 (the collision-resolver) and team-awareness
# QUERY. It answers: "for THIS target (file / symbol), which OTHER branches in the
# repo also touched it — framed relative to MY current branch?" — WITHOUT drowning
# the agent in sibling-branch noise.
#
# THE DESIGN AXIS — OWN-BRANCH-FIRST:
#   The current branch's context is PRIMARY: own_context() is the cheap default a
#   launch path can call and surfaces only what the current branch changed vs its
#   merge-base. Other-branch context is NOT dumped — it is surfaced ON DEMAND by a
#   query (query_target / cross_branch), and every result is framed own-branch-
#   first (the current branch is the `own` anchor; siblings are the
#   `other_branches` list hung off it). There is no "list everything every sibling
#   did" call — that is the noise the spec forbids.
#
# CHEAP + MECHANICAL — git plumbing, NOT an LLM:
#   • current branch       → `git rev-parse --abbrev-ref HEAD`
#   • the branch set        → `git for-each-ref refs/heads`
#   • per-branch merge-base → `git merge-base <branch> <other>`
#   • what a branch touched → `git diff --name-only <merge-base>..<branch>`
#   • per-symbol overlap    → tree-sitter symbols (treesitter_ast) on the two sides
#                             of the overlapping file, intersected. OPTIONAL: when
#                             tree-sitter is unavailable the file-level overlap
#                             still stands (graceful degrade, never a crash).
#   No diff is re-analyzed by an LLM; every signal is a git command or an AST query.
#
# CROSS-BRANCH READS SI-2's REUSE RECORD (per the spec):
#   "SI-2's attestation `reuse` record + SI-3's branch reader are what cross-branch
#   detection reads." When a branch carries a COMMITTED attestation record (a JSON
#   with the SI-2 `{contracts,reuse}` shape) reachable via `git show <branch>:<path>`,
#   query_target ENRICHES that branch's entry with the reuse/contract surface it
#   declares for the target. The attestation is OPTIONAL enrichment — its absence
#   never suppresses the git-mechanical overlap (the file/symbol signal stands alone).
#
# GRACEFUL WHEN SOLO (the mandatory Heimdall pattern):
#   One branch → own-branch context only: no siblings, an empty other_branches
#   list, NO crash. A detached HEAD, an unborn branch, or a non-repo degrade to an
#   honest empty/own-only result rather than raising.
#
# This is a LIBRARY (functions over a repo dir). The thin CLI is
# bin/heimdall-branch-context, which owns argument parsing + JSON I/O.

from __future__ import annotations

import json
import os
import subprocess
import sys

# tree-sitter is an OPTIONAL per-symbol enrichment. Import lazily/tolerantly so a
# host without it still gets file-level branch context (graceful degrade).
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

SCHEMA_VERSION = "si-3.1"

# Source extensions whose per-symbol overlap we attempt to resolve. A non-source
# file still participates at the FILE level — it just contributes no symbols.
_SRC_EXT = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".py", ".go", ".rs"}

# Conventional locations a branch may carry a committed SI-2 attestation record
# (the gitignored runtime store is unreadable cross-branch, so cross-branch
# enrichment only sees a record a branch chose to COMMIT). Probed in order.
_ATTEST_COMMITTED_PATHS = (
    ".heimdall/attestations/latest.json",
    ".planning/ledger/attestation.json",
    ".planning/attestation.json",
)


# ── git plumbing (every signal is one of these; none re-analyze a diff) ────────


def _git(repo, *args):
    """Run a git command in `repo`; return (stdout_text, returncode). Never raises
    — a failing git call yields ("", nonzero) so callers degrade gracefully."""
    try:
        p = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True,
        )
    except (OSError, ValueError):
        return "", 1
    return p.stdout.decode("utf-8", "replace"), p.returncode


def is_repo(repo):
    """True iff `repo` is inside a git work tree."""
    out, rc = _git(repo, "rev-parse", "--is-inside-work-tree")
    return rc == 0 and out.strip() == "true"


def current_branch(repo):
    """The current branch name, or None on a detached HEAD / unborn branch."""
    out, rc = _git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if rc != 0:
        return None
    name = out.strip()
    if not name or name == "HEAD":  # detached HEAD
        return None
    return name


def local_branches(repo):
    """Sorted list of local branch names (refs/heads/*). Empty on an unborn repo."""
    out, rc = _git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    if rc != 0:
        return []
    return sorted(b.strip() for b in out.splitlines() if b.strip())


def merge_base(repo, a, b):
    """The merge-base sha of refs `a` and `b`, or None if there is no common
    ancestor (unrelated histories) or either ref is missing."""
    out, rc = _git(repo, "merge-base", a, b)
    if rc != 0:
        return None
    sha = out.strip()
    return sha or None


def changed_files(repo, base, tip):
    """The sorted list of paths changed between `base` and `tip`
    (`git diff --name-only base..tip`). Empty when base is None or on error."""
    if base is None:
        return []
    rng = "%s..%s" % (base, tip)
    out, rc = _git(repo, "diff", "--name-only", rng)
    if rc != 0:
        return []
    return sorted(p.strip() for p in out.splitlines() if p.strip())


def _show(repo, ref, path):
    """The content of `path` at `ref` (`git show ref:path`), or None if absent."""
    out, rc = _git(repo, "show", "%s:%s" % (ref, path))
    if rc != 0:
        return None
    return out


# ── per-symbol overlap (OPTIONAL tree-sitter enrichment) ───────────────────────


def _ts():
    """Lazily import the tree-sitter substrate; None if unavailable (degrade)."""
    try:
        import treesitter_ast as ts  # noqa: E402
        return ts
    except Exception:  # noqa: BLE001
        return None


def _is_src(path):
    return os.path.splitext(path)[1].lower() in _SRC_EXT


def _lang_for(path):
    ext = os.path.splitext(path)[1].lower()
    return {
        ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript",
        ".cjs": "javascript", ".ts": "typescript", ".tsx": "tsx",
        ".py": "python", ".go": "go", ".rs": "rust",
    }.get(ext)


def symbols_at(repo, ref, path):
    """The set of top-level symbol names declared in `path` at `ref`, via
    tree-sitter. Returns a set() — empty when the file is absent, non-source,
    unparseable, or tree-sitter is unavailable (graceful, never raises)."""
    if not _is_src(path):
        return set()
    ts = _ts()
    if ts is None:
        return set()
    src = _show(repo, ref, path)
    if src is None:
        return set()
    lang = ts.normalize_lang(_lang_for(path))
    if lang is None:
        return set()
    try:
        res = ts.extract(src, lang)
    except Exception:  # noqa: BLE001
        return set()
    if not getattr(res, "available", False):
        return set()
    return {s.name for s in res.symbols}


def changed_symbols(repo, base, tip, path):
    """The symbol names a branch CHANGED in `path` between base and tip. The honest
    mechanical signal: names added or removed since the fork (the symmetric
    difference of the two sides) UNION the branch's declared surface on the tip
    side — the caller only asks this for files already known-changed, so the tip
    surface IS what the sibling 'also touched' there. Empty when per-symbol
    resolution is unavailable (the file-level overlap still stands)."""
    if base is None:
        return symbols_at(repo, tip, path)
    base_syms = symbols_at(repo, base, path)
    tip_syms = symbols_at(repo, tip, path)
    return (base_syms ^ tip_syms) | tip_syms


# ── committed SI-2 attestation enrichment (cross-branch reuse read) ────────────


def attestation_for(repo, ref):
    """The committed SI-2 attestation record reachable at `ref` (the first of the
    conventional committed paths that parses as the SI-2 shape), or None. This is
    the cross-branch read of SI-2's reuse/contract surface — OPTIONAL enrichment,
    never required for the git-mechanical overlap."""
    for path in _ATTEST_COMMITTED_PATHS:
        body = _show(repo, ref, path)
        if body is None:
            continue
        try:
            rec = json.loads(body)
        except (ValueError, TypeError):
            continue
        if isinstance(rec, dict) and ("reuse" in rec or "contracts" in rec):
            return {"path": path, "record": rec}
    return None


def _attest_target_surface(attest, file_path, symbol):
    """From a committed attestation, the reuse/contract surface relevant to the
    queried target: the contract symbols the record declares in `file_path` and,
    when a symbol is queried, whether the record's reuse names it. Returns a small
    dict or None when the attestation says nothing about the target."""
    if not attest:
        return None
    rec = attest["record"]
    contracts = (rec.get("contracts") or {})
    surface = contracts.get("surface") or []
    file_syms = sorted({
        s.get("name") for s in surface
        if s.get("path") == file_path and s.get("name")
    })
    reuse = (rec.get("reuse") or {})
    reused = set(reuse.get("reused_symbols") or [])
    out = {"attestation_path": attest["path"]}
    if file_syms:
        out["contract_symbols"] = file_syms
    if reuse.get("reuse_pct") is not None:
        out["reuse_pct"] = reuse.get("reuse_pct")
    if symbol is not None and symbol in reused:
        out["reuses_target"] = True
    # nothing relevant beyond the path → no enrichment for this target.
    if len(out) == 1:
        return None
    return out


# ── own-branch context (the PRIMARY, cheap default) ────────────────────────────


def own_context(repo):
    """The CURRENT branch's own context: what THIS branch changed relative to its
    merge-base against the other branches (own-branch-first; siblings NOT dumped).

    Returns:
      { schema, repo, current, merge_base, base_ref, changed_files, solo }

    `base_ref` is the sibling the merge-base was taken against (the nearest other
    branch), or None when solo. `solo` is True when there is no other branch to
    frame against. NEVER raises: a non-repo / detached HEAD yields an honest
    own-only result with solo=True and an empty changed_files."""
    repo = os.path.abspath(repo)
    cur = current_branch(repo)
    if not is_repo(repo) or cur is None:
        return {
            "schema": SCHEMA_VERSION, "repo": repo, "current": cur,
            "merge_base": None, "base_ref": None, "changed_files": [],
            "solo": True,
        }
    others = [b for b in local_branches(repo) if b != cur]
    if not others:
        # solo: frame own changes against the repo root (first commit) so a single
        # branch still reports what it has done, without a sibling.
        root, rc = _git(repo, "rev-list", "--max-parents=0", "HEAD")
        base = root.strip().splitlines()[0].strip() if rc == 0 and root.strip() else None
        files = changed_files(repo, base, "HEAD") if base else []
        return {
            "schema": SCHEMA_VERSION, "repo": repo, "current": cur,
            "merge_base": base, "base_ref": None,
            "changed_files": files, "solo": True,
        }
    # pick the nearest sibling (the one whose merge-base is the most recent commit)
    # as the framing base; own changes are everything since that fork point.
    best_base = None
    best_ref = None
    for o in others:
        mb = merge_base(repo, "HEAD", o)
        if mb is None:
            continue
        if best_base is None:
            best_base, best_ref = mb, o
            continue
        # prefer the merge-base that is a DESCENDANT of the current best (more
        # recent fork → tighter own-change set).
        _o, rc = _git(repo, "merge-base", "--is-ancestor", best_base, mb)
        if rc == 0:
            best_base, best_ref = mb, o
    files = changed_files(repo, best_base, "HEAD") if best_base else []
    return {
        "schema": SCHEMA_VERSION, "repo": repo, "current": cur,
        "merge_base": best_base, "base_ref": best_ref,
        "changed_files": files, "solo": False,
    }


# ── on-demand cross-branch query (other-branch context, framed own-first) ──────


def _split_target(target):
    """Split "path#symbol" → (path, symbol); a bare path → (path, None)."""
    if target is None:
        return None, None
    if "#" in target:
        path, sym = target.split("#", 1)
        return path.strip(), (sym.strip() or None)
    return target.strip(), None


def query_target(repo, target, with_symbols=True, with_attestation=True):
    """ON-DEMAND: for a queried `target` (a file path, or "path#symbol"), surface
    which OTHER branches also touched it — framed OWN-BRANCH-FIRST.

    `target` forms:
      "src/auth.ts"             → file-level query
      "src/auth.ts#handleLogin" → file + symbol query (per-symbol overlap)

    Returns:
      { schema, repo, current, target:{file,symbol},
        own:   { touched: bool, symbols:[...] },          # the current branch
        other_branches: [ { branch, merge_base, touched_file,
                            touched_symbol, symbols, overlap, attestation? } ],
        overlap_count, solo }

    The `own` block is ALWAYS first and anchors the frame. `other_branches` is the
    on-demand surface — ONLY branches that actually touched the target file appear
    (no full sibling dump). `overlap` is True when the sibling touched the SAME
    target the current branch did (the collision signal P3 reads). Solo (one
    branch) → empty other_branches, no crash."""
    repo = os.path.abspath(repo)
    file_path, symbol = _split_target(target)
    cur = current_branch(repo)

    result = {
        "schema": SCHEMA_VERSION,
        "repo": repo,
        "current": cur,
        "target": {"file": file_path, "symbol": symbol},
        "own": {"touched": False, "symbols": []},
        "other_branches": [],
        "overlap_count": 0,
        "solo": True,
    }
    if not is_repo(repo) or cur is None:
        return result

    # ── own-branch first: did the CURRENT branch touch the target? ────────────
    own_ctx = own_context(repo)
    own_base = own_ctx.get("merge_base")
    own_touched_file = file_path in own_ctx.get("changed_files", [])
    own_syms = []
    if own_touched_file and with_symbols:
        own_syms = sorted(changed_symbols(repo, own_base, "HEAD", file_path))
    # when a symbol is queried: own touches it if the symbol is in the resolved
    # set, OR the file was touched but symbols are unresolved (degrade → assume).
    own_touched_symbol = (
        symbol is None
        or symbol in own_syms
        or (own_touched_file and not own_syms)
    )
    result["own"] = {
        "touched": bool(own_touched_file and own_touched_symbol),
        "symbols": own_syms,
    }

    others = [b for b in local_branches(repo) if b != cur]
    result["solo"] = len(others) == 0
    if not others:
        return result

    # ── on-demand: only siblings that ACTUALLY touched the file appear ────────
    for o in others:
        mb = merge_base(repo, "HEAD", o)
        ofiles = changed_files(repo, mb, o)
        if file_path not in ofiles:
            continue  # this sibling didn't touch the file → not surfaced (no dump)
        osyms = sorted(changed_symbols(repo, mb, o, file_path)) if with_symbols else []
        touched_symbol = (symbol is None) or (symbol in osyms) or (not osyms)
        # overlap = the sibling touched the SAME target the current branch did.
        overlap = bool(result["own"]["touched"]) and own_touched_file and (
            (symbol is None) or (touched_symbol and own_touched_symbol)
        )
        entry = {
            "branch": o,
            "merge_base": mb,
            "touched_file": True,
            "touched_symbol": bool(touched_symbol),
            "symbols": osyms,
            "overlap": overlap,
        }
        if with_attestation:
            att = _attest_target_surface(
                attestation_for(repo, o), file_path, symbol
            )
            if att:
                entry["attestation"] = att
        result["other_branches"].append(entry)
        if overlap:
            result["overlap_count"] += 1

    result["other_branches"].sort(key=lambda e: e["branch"])
    return result


# ── the human one-line summaries (for the CLI's stderr) ────────────────────────


def own_summary(ctx):
    if ctx.get("solo"):
        n = len(ctx.get("changed_files", []))
        return ("branch-context [own]: %s (solo) — %d file(s) changed, no siblings"
                % (ctx.get("current") or "(detached)", n))
    return ("branch-context [own]: %s vs %s — %d file(s) changed"
            % (ctx.get("current") or "(detached)",
               ctx.get("base_ref") or "(root)",
               len(ctx.get("changed_files", []))))


def query_summary(res):
    tgt = res["target"]["file"] or "(none)"
    if res["target"]["symbol"]:
        tgt += "#" + res["target"]["symbol"]
    own = "touched" if res["own"]["touched"] else "untouched"
    if res.get("solo"):
        return ("branch-context [query]: %s — solo, own=%s, no siblings"
                % (tgt, own))
    n = len(res["other_branches"])
    olap = res["overlap_count"]
    sibs = ", ".join(e["branch"] for e in res["other_branches"]) or "none"
    flag = " CROSS-BRANCH OVERLAP" if olap else ""
    return ("branch-context [query]: %s — own=%s; %d other-branch(es) [%s]%s"
            % (tgt, own, n, sibs, flag))
