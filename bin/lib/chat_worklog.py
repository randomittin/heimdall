#!/usr/bin/env python3
# chat_worklog.py — chat-ops P2 reader for P1's CONTEXT worklog (§3).
#
# P1 (bin/heimdall-context-sync) pushes the rolling session state to the `hmd/context`
# ORPHAN branch: worklog.json (the STRUCTURED "what was being attempted") + context.md +
# cases/ + verdicts.ndjson. The chat `investigate` verb RESUMES from that worklog rather than
# rediscovering — it reads worklog.json FIRST and cites what it resumed from (§3's payoff:
# "continuing from RJ's session ending 14:02: auth refactor, gate red on oracle/contract").
#
# HOW IT READS — git PLUMBING only (`git show hmd/context:worklog.json`), never a checkout:
# main and the working tree are untouched. If the branch is ABSENT (no P1 sync yet), the
# read is honestly {available: False, reason: "branch_absent"} — the verb degrades to a plain
# investigate instead of faking a resume.
#
# stdlib-only (json/os/subprocess). No store, no network.

from __future__ import annotations

import json
import os
import subprocess

CONTEXT_BRANCH = "hmd/context"
WORKLOG_PATH = "worklog.json"


def read_worklog(repo=None, *, branch=CONTEXT_BRANCH, path=WORKLOG_PATH, timeout=15):
    """Read the P1 worklog from the context branch via `git show <branch>:<path>` (plumbing,
    no checkout). Returns:
      {available: True, worklog: {...}}                       on a good read, or
      {available: False, reason, detail?}                     otherwise, where reason is one
      of: not_a_repo | branch_absent | corrupt | git_error.

    Honest by construction — a missing branch is available:False, never a fabricated resume."""
    repo = repo or os.getcwd()
    if not _is_worktree(repo, timeout):
        return {"available": False, "reason": "not_a_repo"}
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "show", "%s:%s" % (branch, path)],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"available": False, "reason": "git_error", "detail": str(exc)[:200]}
    if proc.returncode != 0:
        return {"available": False, "reason": "branch_absent",
                "detail": (proc.stderr or "").strip()[:200]}
    try:
        data = json.loads(proc.stdout)
    except (ValueError, TypeError):
        return {"available": False, "reason": "corrupt"}
    if not isinstance(data, dict):
        return {"available": False, "reason": "corrupt"}
    return {"available": True, "worklog": data}


def _is_worktree(repo, timeout):
    """True iff `repo` is inside a git work tree (covers a plain repo, a worktree, or a
    submodule where `.git` is a file, not a dir)."""
    if not os.path.isdir(repo):
        return False
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0 and (proc.stdout or "").strip() == "true"


def resume_citation(result):
    """A one-line human citation of what a resume is continuing FROM, built from a
    read_worklog() result. On available:True cites the author + summary + last_state; on
    available:False states honestly that there is no synced context to resume from. Pure."""
    if not isinstance(result, dict) or not result.get("available"):
        reason = (result or {}).get("reason", "unknown") if isinstance(result, dict) else "unknown"
        return "No synced hmd/context worklog to resume from (%s) — investigating fresh." % reason
    wl = result.get("worklog") or {}
    by = (wl.get("by") or "someone").strip() or "someone"
    summary = (wl.get("summary") or wl.get("goal") or "prior work").strip() or "prior work"
    last_state = (wl.get("last_state") or "").strip()
    line = "Continuing from %s's session: %s" % (by, summary)
    if last_state:
        # Keep the citation compact — the first line of the last_state is the signal.
        first_line = last_state.splitlines()[0].strip()
        if first_line:
            line += " (last state: %s)" % first_line
    return line
