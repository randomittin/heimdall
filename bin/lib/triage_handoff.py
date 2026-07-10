#!/usr/bin/env python3
# triage_handoff.py — TEAM MODE (TRACK A step 3): reap → checkpoint ADOPT for issues.
#
# THE HANDOFF GUARANTEE. When a teammate holding an issue claim DROPS (their session dies,
# their claim's TTL lapses), `heimdall-claim reap` ages the claim out and the issue returns to
# the pick set (issue_queue.pick reaps before every team pick). But a bare re-queue would make
# the next teammate RESTART triage from zero. This module closes the loop: it reads the dropped
# teammate's SHARED CHECKPOINT (.planning/ledger/checkpoints/{slug}.json — the just-merged
# redundancy backbone) and recovers their in-flight triage state (branch, phase, %, scrubbed
# goal), so the adopting teammate RESUMES rather than restarts. Reap frees the WORK; the
# checkpoint carries the CONTEXT — the two halves of the shared-checkpoints reap→adopt path,
# now wired for issues.
#
# READ-ONLY OVER SHARED STATE. This module IMPORTS checkpoint_share and issue_claim and NEVER
# edits them (checkpoint_share owns the scrub/consent/allowlist; issue_claim owns the surface +
# the heimdall-claim reap). It reads git-visible team records only — a different team is a
# different repo == a different .planning ledger, so a team never sees another team's
# checkpoints (the structural isolation boundary; rr-multitenant-isolation stays 1.0).
#
# THE ISSUE ↔ CHECKPOINT LINK is the task_ref. A triage claim carries task_ref
# "issue-triage:<issue-id>" (issue_queue.pick); a teammate's checkpoint published while working
# that issue carries the SAME task_ref (or names the issue in its active_goal / claims the
# issue surface). find_handoff matches on any of those, tolerant of checkpoint_share's scrub
# (which drops the colon-bearing `issue:` surface but keeps the prose task_ref).
#
# stdlib-only + the two sibling libs. House style mirrors issue_claim.py / checkpoint_share.py.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    import checkpoint_share as _cp  # READ-ONLY: all_checkpoints / read_checkpoint (never edited)
except Exception:  # pragma: no cover - broken install
    _cp = None
try:
    import issue_claim as _ic  # issue_surface + the heimdall-claim reap (TTL frees the claim)
except Exception:  # pragma: no cover
    _ic = None


_TRIAGE_TASK_PREFIX = "issue-triage:"


def reap(repo=None):
    """Reap TTL-expired claims (delegates to issue_claim.reap → heimdall-claim reap). A dropped
    teammate's issue claim ages out here, returning the issue to the pick set. Best-effort."""
    if _ic is not None:
        _ic.reap(repo=repo)


def _mentions_issue(rec, issue_id):
    """True when a checkpoint record references `issue_id`: via its triage task_ref, its
    active_goal text, or the issue's synthetic claim surface among claimed_surfaces."""
    if not isinstance(rec, dict):
        return False
    task = str(rec.get("task_ref") or "")
    if issue_id in task:
        return True
    if str(issue_id) in str(rec.get("active_goal") or ""):
        return True
    if _ic is not None and _ic.issue_surface(issue_id) in (rec.get("claimed_surfaces") or []):
        return True
    return False


def _resume_context(issue_id, haid, rec):
    """Project a checkpoint record to the resume context an adopting teammate needs. Every field
    is already scrubbed by checkpoint_share at publish time, so this carries no secret/path."""
    return {
        "issue_id": issue_id,
        "from_haid": haid,
        "human": rec.get("human"),
        "branch": rec.get("branch"),
        "head_sha": rec.get("head_sha"),
        "phase": rec.get("phase"),
        "progress_pct": rec.get("progress_pct"),
        "active_goal": rec.get("active_goal"),
        "resumable": bool(rec.get("resumable")),
    }


def find_handoff(issue_id, repo=None):
    """The resume context for adopting a dropped teammate's in-flight triage of `issue_id`, or
    None. Scans the git-shared checkpoints for a RESUMABLE record referencing the issue and
    returns the teammate's branch/phase/%/goal so the adopter RESUMES, not restarts. Read-only,
    tolerant — never raises."""
    if _cp is None:
        return None
    try:
        checkpoints = _cp.all_checkpoints(repo_root=repo)
    except Exception:  # pragma: no cover - defensive
        return None
    for haid in sorted(checkpoints):
        rec = checkpoints[haid]
        if not isinstance(rec, dict):
            continue
        if not rec.get("resumable"):
            continue
        if _mentions_issue(rec, issue_id):
            return _resume_context(issue_id, haid, rec)
    return None


def adoptable(repo=None, reap_first=True):
    """Every issue currently ADOPTABLE via a teammate's checkpoint. Reaps first (so a dropped
    teammate's claim is gone → its issue is genuinely free), then lists the resume contexts of
    resumable checkpoints that name a triage task. Returns a list of resume-context dicts,
    sorted by issue id. An issue STILL actively claimed is not adoptable — but reap has already
    freed any expired claim, and a live claim's holder is still working it (not dropped)."""
    if _cp is None:
        return []
    if reap_first:
        reap(repo=repo)
    try:
        checkpoints = _cp.all_checkpoints(repo_root=repo)
    except Exception:  # pragma: no cover
        return []
    out = []
    for haid in sorted(checkpoints):
        rec = checkpoints[haid]
        if not isinstance(rec, dict) or not rec.get("resumable"):
            continue
        issue_id = _issue_from_task(rec.get("task_ref"))
        if not issue_id:
            continue
        # If the ISSUE is still held by an ACTIVE claim, the holder is working it (not dropped)
        # — not adoptable. Post-reap, only live claims remain, so this excludes them cleanly.
        if _ic is not None and _ic.holder_of(issue_id, repo=repo):
            continue
        out.append(_resume_context(issue_id, haid, rec))
    out.sort(key=lambda c: str(c.get("issue_id") or ""))
    return out


def _issue_from_task(task_ref):
    """Extract the issue id embedded in a triage task_ref ('issue-triage:<id>'), or None."""
    task = str(task_ref or "")
    if task.startswith(_TRIAGE_TASK_PREFIX):
        return task[len(_TRIAGE_TASK_PREFIX):] or None
    return None


# ── CLI (driven by a thin bash wrapper / tests) ────────────────────────────────


def _cli(argv):
    import argparse

    p = argparse.ArgumentParser(prog="triage-handoff", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--id")
    p.add_argument("--repo")
    args = p.parse_args(argv)
    sub = args.subcommand

    if sub == "reap":
        reap(repo=args.repo)
        print(json.dumps({"reaped": True}, sort_keys=True))
        return 0

    if sub == "find":
        if not args.id:
            print("error: find needs --id <issue-id>")
            return 2
        ctx = find_handoff(args.id, repo=args.repo)
        print(json.dumps(ctx, indent=2, sort_keys=True))
        return 0

    if sub == "adoptable":
        print(json.dumps(adoptable(repo=args.repo), indent=2, sort_keys=True))
        return 0

    print("error: unknown subcommand: %s" % sub)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
