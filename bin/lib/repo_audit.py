#!/usr/bin/env python3
# repo_audit.py — the Δ2 AUDIT-ON-INIT engine: a fast, fully-offline repo scan that
# produces A NUMBER WORTH POSTING on the very first `hmd init`.
#
#   "heimdall audited <repo>: X files, Y% gate-covered, Z reuse candidates"
#
# WHAT IT MEASURES (all from file NAMES + git's own file list — no parsing, no
# network, no model call, so it finishes in well under a second on a large repo):
#   * files             — tracked files in the repo (git ls-files; a non-git tree
#                         falls back to a bounded walk).
#   * gate_covered_pct  — the share of non-test source files that have a matching
#                         test file (same basename stem). This is the honest "how
#                         much of this code has a test the watchman can gate" number.
#   * reuse_candidates  — source-file basename stems that occur in 2+ distinct files
#                         (likely-duplicated concerns — the reuse signal Heimdall
#                         exists to catch), computed from names only.
#
# The record is PRINTED (the postable headline) and STORED to <repo>/.heimdall/
# audit.json so `hmd badge` / `hmd clip` can surface it offline. It is REPO-LOCAL
# (a badge is about THIS repo) — distinct from the ~/.heimdall telemetry corpus.
#
# NON-BLOCKING BY CONTRACT: every path returns cleanly; a scan failure yields a
# zeroed record, never an exception into `hmd init` (init must still exit 0).
#
# stdlib-only. Reuses bin/lib/pmr_corpus.py for the hashed repo class + timestamp.

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import pmr_corpus as pmr  # noqa: E402 — reuse repo_class_hash / repo_identity / time

SCHEMA_AUDIT = "audit_v1"

# Source-code extensions we count as "code" (a superset of the PMR lang set).
_CODE_EXT = {
    "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "sh", "bash", "go", "rb", "rs",
    "java", "c", "cc", "cpp", "h", "hpp", "cs", "php", "swift", "kt", "scala",
    "sql", "html", "css", "scss", "vue", "svelte", "lua", "r", "m", "mm",
}

# A test-file signal on a path (basename or dir segment).
_RX_TEST = re.compile(r"(^|[._/-])(tests?|spec|__tests__)([._/-]|$)", re.I)

# Upper bound on files walked when git is unavailable — keeps a pathological tree fast.
_WALK_CAP = 20000


def _git(repo, args):
    try:
        proc = subprocess.run(
            ["git", "-C", repo] + args,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", "replace")


def list_files(repo):
    """The repo's tracked files. git ls-files when inside a repo; otherwise a
    bounded, VCS/artifact-pruned walk so a plain directory still audits."""
    out = _git(repo, ["ls-files"])
    if out.strip():
        return [ln for ln in out.splitlines() if ln.strip()]
    # Non-git fallback: bounded walk, skipping the usual noise dirs.
    skip = {".git", "node_modules", ".venv", "venv", "__pycache__", "dist",
            "build", ".next", "target", ".heimdall", ".idea", ".gradle"}
    files = []
    for root, dirs, names in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in skip]
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), repo)
            files.append(rel)
            if len(files) >= _WALK_CAP:
                return files
    return files


def _ext(path):
    return os.path.splitext(path)[1].lstrip(".").lower()


def _stem(path):
    """The comparison stem of a file: basename minus extension, minus a leading or
    trailing test/spec marker, lowercased. So 'users.js' and 'users.test.js' share
    the stem 'users' (coverage match), and 'utils.py' in two dirs shares 'utils'
    (reuse)."""
    b = os.path.splitext(os.path.basename(path))[0]
    b = re.sub(r"\.(test|spec)$", "", b, flags=re.I)
    b = re.sub(r"[._-](test|spec)$", "", b, flags=re.I)
    b = re.sub(r"^(test|spec)[._-]", "", b, flags=re.I)
    return b.lower()


def audit(repo=None):
    """Compute the audit record for `repo` (default: cwd). PURE data — writes
    nothing. Never raises: a failure degrades to a zeroed-but-valid record."""
    repo = repo or os.getcwd()
    try:
        root = _git(repo, ["rev-parse", "--show-toplevel"]).strip() or repo
        files = list_files(root)
        code = [f for f in files if _ext(f) in _CODE_EXT]
        tests = [f for f in code if _RX_TEST.search(f)]
        test_set = set(tests)
        non_test = [f for f in code if f not in test_set]

        test_stems = {_stem(t) for t in tests}
        covered = sum(1 for f in non_test if _stem(f) in test_stems)
        gate_pct = int(round(100.0 * covered / len(non_test))) if non_test else 0

        stem_counts = Counter(_stem(f) for f in non_test)
        reuse = sum(1 for _, n in stem_counts.items() if n >= 2)

        try:
            rc_hash = pmr.repo_class_hash(pmr.repo_identity(root))
        except Exception:  # noqa: BLE001 — hashing must never fail the audit
            rc_hash = ""

        return {
            "schema": SCHEMA_AUDIT,
            "ts": pmr._now_iso(),  # noqa: SLF001
            "repo_class_hash": rc_hash,
            "files": len(files),
            "code_files": len(code),
            "test_files": len(tests),
            "gate_covered_pct": gate_pct,
            "reuse_candidates": reuse,
        }
    except Exception as exc:  # noqa: BLE001 — audit is non-blocking; return a safe record
        return {
            "schema": SCHEMA_AUDIT,
            "ts": pmr._now_iso(),  # noqa: SLF001
            "repo_class_hash": "",
            "files": 0, "code_files": 0, "test_files": 0,
            "gate_covered_pct": 0, "reuse_candidates": 0,
            "error": str(exc)[:120],
        }


def headline(rec, repo=None):
    """The postable one-liner. Uses the repo's DISPLAY name (basename) — this is a
    local print for the user, never a telemetry field."""
    repo = repo or os.getcwd()
    root = _git(repo, ["rev-parse", "--show-toplevel"]).strip() or repo
    name = os.path.basename(os.path.normpath(root)) or "repo"
    return ("heimdall audited %s: %d files, %d%% gate-covered, %d reuse candidates"
            % (name, rec.get("files", 0), rec.get("gate_covered_pct", 0),
               rec.get("reuse_candidates", 0)))


def store_path(repo=None):
    repo = repo or os.getcwd()
    root = _git(repo, ["rev-parse", "--show-toplevel"]).strip() or repo
    return os.path.join(root, ".heimdall", "audit.json")


def store(rec, path=None, repo=None):
    """Persist the audit record to <repo>/.heimdall/audit.json (atomic). Best-effort:
    a write failure returns None rather than raising (init must not break)."""
    path = path or store_path(repo)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp-%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, sort_keys=True, indent=2)
            fh.write("\n")
            fh.flush()
        os.replace(tmp, path)
        return path
    except OSError:
        return None


def load(repo=None, path=None):
    """Read a stored audit record, or None when absent/unreadable."""
    path = path or store_path(repo)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except (OSError, ValueError):
        return None


def _cli(argv):
    """CLI core. Subcommands:
        run  [--repo DIR] [--store PATH] [--json] [--quiet]
              scan, PRINT the headline, and STORE audit.json. Exit 0 always.
        show [--repo DIR] [--json]
              print the stored audit (headline or JSON); exit 0 even if absent.
    """
    import argparse

    p = argparse.ArgumentParser(prog="repo_audit", add_help=True)
    p.add_argument("subcommand", nargs="?", default="run")
    p.add_argument("--repo")
    p.add_argument("--store", dest="store_to")
    p.add_argument("--json", action="store_true")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)
    repo = args.repo or os.getcwd()

    if args.subcommand == "show":
        rec = load(repo)
        if rec is None:
            if args.json:
                print("{}")
            return 0
        print(json.dumps(rec, indent=2, sort_keys=True) if args.json
              else headline(rec, repo))
        return 0

    # default: run
    rec = audit(repo)
    store(rec, path=args.store_to, repo=repo)
    if args.json:
        print(json.dumps(rec, indent=2, sort_keys=True))
    elif not args.quiet:
        print(headline(rec, repo))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
