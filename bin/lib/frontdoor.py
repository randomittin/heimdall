#!/usr/bin/env python3
# frontdoor.py is the engine behind bin/heimdall-frontdoor.
#
# F1 (Onboarding) directory-aware front door: a STANDALONE classifier that orients
# to what the user has in a directory and returns a routing decision. The launch
# path (F1 Wave-2) calls this first (the "orient" step in the
# orient -> resume -> persona-check -> onboard-if-cold tree), but here it is a
# pure, testable unit with its own CLI.
#
# THE FOUR CONTEXTS (mutually exclusive, checked in PRIORITY order):
#
#   mid-task-resume   : a checkpoint / .planning state is present, so there is
#                       in-flight work to RESUME. This wins over every other
#                       signal: if there is saved progress, we resume it
#                       regardless of how much code surrounds it. Detected by a
#                       .planning dir with a CHECKPOINT.md / STATE.md (or other
#                       planning state), or heimdall-state.json with live progress.
#
#   existing-codebase : an ESTABLISHED project: real git history (commits exist)
#                       AND source present. We are joining work already underway,
#                       so orient to the codebase rather than scaffold.
#
#   fresh-project     : a project STARTED but not yet under version control: a
#                       manifest and/or source files exist, but there is no git
#                       history (no repo, or a repo with zero commits). The
#                       "files exist but work has not really begun" state.
#
#   empty-dir         : nothing meaningful: no source, no manifest, no git
#                       history, no checkpoint. A blank canvas, the first-run /
#                       new-project path.
#
# ROUTE (returned alongside the context) is the launch path's branch target:
#   mid-task-resume   -> resume
#   existing-codebase -> orient-existing
#   fresh-project     -> orient-fresh
#   empty-dir         -> onboard-new
#
# Detection is REAL filesystem + git inspection over the target dir: every signal
# is computed from disk. The git-history check shells out to git only to count
# commits; if git is absent the dir simply reads as having no history (degraded
# honestly, never crashes). All paths are relative to the target dir (no baked
# paths).

import json
import os
import subprocess

# Files that mark a recognized project regardless of language (a manifest means a
# project was deliberately started). Kept broad but concrete: each is a real,
# widely-used manifest.
MANIFEST_FILES = (
    "package.json",
    "pyproject.toml",
    "setup.py",
    "requirements.txt",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle",
    "Gemfile",
    "composer.json",
    "Makefile",
    "CMakeLists.txt",
)

# Source file extensions that count as "real source present". An entry-level
# signal, paired with the manifest check so a lone README never reads as a
# project.
SOURCE_EXTS = (
    ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".rb", ".java",
    ".c", ".h", ".cpp", ".hpp", ".cs", ".swift", ".kt", ".php", ".sh",
)

# Names that do NOT count toward "non-empty": VCS/tooling dirs and OS cruft. A
# dir that holds only these is still effectively empty for routing.
IGNORED_ENTRIES = (".git", ".DS_Store", ".hg", ".svn", "__pycache__")

CONTEXT_ROUTE = {
    "mid-task-resume": "resume",
    "existing-codebase": "orient-existing",
    "fresh-project": "orient-fresh",
    "empty-dir": "onboard-new",
}


def _entries(target):
    """Non-ignored direct entries of target (names only). [] if unreadable."""
    try:
        return [e for e in os.listdir(target) if e not in IGNORED_ENTRIES]
    except OSError:
        return []


def has_checkpoint(target):
    """True iff there is resumable saved state under target.

    A checkpoint is .planning/CHECKPOINT.md or .planning/STATE.md (the canonical
    save format), any other file under .planning/, or a heimdall-state.json at the
    root. This is the "mid-task-resume" signal.
    """
    planning = os.path.join(target, ".planning")
    for marker in ("CHECKPOINT.md", "STATE.md"):
        if os.path.isfile(os.path.join(planning, marker)):
            return True
    if os.path.isdir(planning):
        try:
            if any(
                os.path.isfile(os.path.join(planning, e))
                for e in os.listdir(planning)
            ):
                return True
        except OSError:
            pass
    if os.path.isfile(os.path.join(target, "heimdall-state.json")):
        return True
    return False


def has_manifest(target):
    """True iff a recognized project manifest sits at the root of target."""
    return any(
        os.path.isfile(os.path.join(target, m)) for m in MANIFEST_FILES
    )


def has_source(target):
    """True iff at least one source file exists at the top level of target.

    Top-level only by design: a deeply-nested source file inside an otherwise
    empty tree should not, on its own, flip an empty dir to a project. The
    manifest check handles the deliberate-project case; this handles the
    hand-written-code case.
    """
    try:
        for e in os.listdir(target):
            if e in IGNORED_ENTRIES:
                continue
            full = os.path.join(target, e)
            if os.path.isfile(full) and os.path.splitext(e)[1] in SOURCE_EXTS:
                return True
    except OSError:
        return False
    return False


def git_commit_count(target):
    """Number of commits reachable from HEAD in target's repo (0 if none/absent).

    Real git inspection. A non-repo, an empty repo (no commits yet), or a missing
    git binary all yield 0, i.e. "no history". Never raises; degrades honestly.
    """
    try:
        proc = subprocess.run(
            ["git", "rev-list", "--count", "HEAD"],
            cwd=target,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except (OSError, ValueError):
        return 0
    if proc.returncode != 0:
        return 0
    out = proc.stdout.strip()
    try:
        return int(out)
    except ValueError:
        return 0


def classify(target):
    """Classify target into one of the four contexts (priority-ordered).

    Returns a dict: { context, route, signals } where signals carries the raw
    detected facts so a caller (or a human reading the trace) can see WHY the
    route was chosen, never an opaque verdict.
    """
    target = os.path.abspath(target)
    signals = {
        "exists": os.path.isdir(target),
        "checkpoint": has_checkpoint(target),
        "manifest": has_manifest(target),
        "source": has_source(target),
        "git_commits": git_commit_count(target),
        "entries": len(_entries(target)),
    }

    # 1. Resume wins over everything: saved progress means in-flight work.
    if signals["checkpoint"]:
        context = "mid-task-resume"
    # 2. Established codebase: real history AND code present.
    elif signals["git_commits"] > 0 and (signals["source"] or signals["manifest"]):
        context = "existing-codebase"
    # 3. Started-but-uncommitted: a project's files exist, no history yet.
    elif signals["manifest"] or signals["source"]:
        context = "fresh-project"
    # 4. Nothing meaningful, so empty.
    else:
        context = "empty-dir"

    return {
        "context": context,
        "route": CONTEXT_ROUTE[context],
        "signals": signals,
    }


def _cli(argv):
    """CLI core. Usage: heimdall-frontdoor [--json] [DIR].

    Default DIR is the cwd. Prints "<context> -> <route>" for humans, or the full
    classification record with --json. Returns 0 always (a classification is not a
    failure); 2 only on a usage error.
    """
    as_json = False
    target = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help", "help"):
            _usage()
            return 0
        if arg == "--json":
            as_json = True
        elif arg.startswith("-"):
            print("frontdoor: unknown option: %s" % arg)
            return 2
        else:
            if target is not None:
                print("frontdoor: only one DIR may be given")
                return 2
            target = arg
        i += 1
    if target is None:
        target = os.getcwd()
    if not os.path.isdir(target):
        print("frontdoor: not a directory: %s" % target)
        return 2
    result = classify(target)
    if as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("%s -> %s" % (result["context"], result["route"]))
    return 0


def _usage():
    print(
        "usage: heimdall-frontdoor [--json] [DIR]\n"
        "  classify DIR (default: cwd) into one of:\n"
        "    mid-task-resume    (checkpoint/.planning present)  -> resume\n"
        "    existing-codebase  (git history + source)          -> orient-existing\n"
        "    fresh-project      (manifest/source, no history)   -> orient-fresh\n"
        "    empty-dir          (nothing meaningful)            -> onboard-new\n"
        "  --json   emit the full classification record (context, route, signals)"
    )


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
