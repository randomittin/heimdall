#!/usr/bin/env python3
# issue_claim.py — TEAM MODE (TRACK A): promote a triage pick from the machine-local
# in_flight bucket (issue_queue.pick) to a HAID-ATTRIBUTED, git-shared claim, so two
# TEAMMATES never triage/fix the SAME issue.
#
# THE COORDINATION-LOGIC CHANGE (not rendering). issue_queue.pick()'s `in_flight` bucket
# is machine-local: it stops ONE runner double-picking, NOT two teammates on two machines.
# This layer wires each pick to a git-shared claim on a synthetic surface `issue:<slug>`
# via the EXISTING collision primitive `bin/heimdall-claim`. Two teammates share the
# .planning/ledger/claims/ dir through git (one file per HAID → conflict-free merge); a
# pick first `check`s that surface against every OTHER HAID's ACTIVE claim and skips the
# issue when a teammate already holds it. Cross-teammate no-double-work, reusing the exact
# overlap + TTL + reap engine — ZERO new collision logic here.
#
# WE CALL heimdall-claim, WE DO NOT REIMPLEMENT IT (parallel tracks also call it). The
# binary owns identity (heimdall-haid), the atomic locked write, the surfaces_overlap
# nesting engine, TTL liveness, and reap. This module is the thin issue-shaped adapter:
# it maps an issue id to a stable surface and shells the claim/check/release/reap verbs.
#
# THE SURFACE IS A LITERAL, BY DESIGN. issue_surface() slugs every non-safe char (`:`, `/`,
# `#`) to `_`, so a surface carries NO glob and NO directory separator. heimdall-claim's
# file-prefix overlap then collides EXACTLY on the same issue id and NEVER on a different
# one (two distinct literals with no `/` can neither nest nor prefix-match — see
# files_overlap in bin/heimdall-claim). So two teammates on DIFFERENT issues in the SAME
# repo never false-collide, while the SAME issue always does.
#
# OPT-IN, SOLO-BYTE-IDENTICAL. team_claim_enabled() is False unless HEIMDALL_TEAM is an
# on-ish value. issue_queue.pick() calls into here ONLY when enabled, so a solo run (the
# unset/off default) never shells a claim, never writes a claim file, and is byte-identical
# to today. Every verb also degrades to a safe no-op (clear/True) when the binary is
# absent or errors — a coordination fault must never wedge the triage loop.
#
# stdlib-only. House style mirrors issue_queue.py (env-resolved runtime home, no caching).

from __future__ import annotations

import os
import re
import subprocess

_HERE = os.path.dirname(os.path.abspath(__file__))
_BIN_DIR = os.path.dirname(_HERE)  # bin/  (this file is bin/lib/issue_claim.py)
CLAIM_BIN = os.path.join(_BIN_DIR, "heimdall-claim")

# The default TTL a triage claim carries (minutes) — matches heimdall-claim's own default.
DEFAULT_TTL_MINUTES = 90

_ON_ISH = frozenset({"on", "1", "true", "yes", "enabled"})


# ── feature gate (opt-in; unset/off == solo == byte-identical) ─────────────────


def team_claim_enabled():
    """True ONLY when HEIMDALL_TEAM is an on-ish value (on/1/true/yes/enabled). Default,
    unset, or an off-ish value => False => issue_queue.pick() never shells a claim and the
    solo path is byte-identical to today. Opt-in is deliberate: issue_queue is imported by
    ~10 modules, so claim-gating must be a no-op unless a team run explicitly asks for it."""
    return (os.environ.get("HEIMDALL_TEAM") or "").strip().lower() in _ON_ISH


def available():
    """True iff the heimdall-claim primitive is present + executable. A broken/absent
    install degrades every verb to a no-op rather than crashing the loop."""
    return os.path.isfile(CLAIM_BIN) and os.access(CLAIM_BIN, os.X_OK)


# ── runtime planning home (mirrors bin/heimdall-claim's own resolution) ────────


def _repo_root(start=None):
    cur = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isdir(os.path.join(cur, ".git")) or os.path.isfile(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start or os.getcwd())
        cur = parent


def planning_dir(repo=None):
    """${HEIMDALL_PLANNING_DIR:-<repo-root>/.planning} — the SAME dir heimdall-claim resolves
    its claims/ store under. Resolved every call (no caching) so a subprocess test that pins
    the env sees its own ledger. Passed to the binary via the env so the claim lands in the
    right team's git-shared ledger (a different team == a different repo == a different dir,
    which is the structural isolation boundary — a team never sees another team's claims)."""
    explicit = os.environ.get("HEIMDALL_PLANNING_DIR")
    if explicit:
        return explicit
    return os.path.join(_repo_root(repo), ".planning")


# ── the issue → surface mapping (a literal, collision-exact) ───────────────────

_SURFACE_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def issue_surface(issue_id):
    """The synthetic claim surface for an issue id. Every non-safe char (`:`, `/`, `#`, space)
    collapses to a single `_`, so the surface is a bare LITERAL with no glob and no `/`
    separator. Under heimdall-claim's file-prefix overlap that means: the SAME issue id maps to
    the SAME literal (collision), while any DIFFERENT id maps to a literal that can neither
    equal, nest under, nor prefix-match it (no collision). e.g.
        'github:owner/repo#12'  -> 'issue:github_owner_repo_12'
        'corpus:proposal-abc'   -> 'issue:corpus_proposal-abc'."""
    slug = _SURFACE_UNSAFE.sub("_", str(issue_id)).strip("_") or "unknown"
    return "issue:" + slug


# ── the heimdall-claim verbs (thin subprocess adapters) ────────────────────────


def _run(args, planning):
    env = dict(os.environ)
    env["HEIMDALL_PLANNING_DIR"] = planning
    try:
        return subprocess.run(
            [CLAIM_BIN, *args], env=env, capture_output=True, text=True, check=False
        )
    except (OSError, ValueError):
        return None


def check(issue_id, repo=None, planning=None):
    """Is `issue_id` free for THIS HAID to pick? Returns (clear, holder). clear is False ONLY
    when heimdall-claim reports a collision (exit 3) — a DIFFERENT HAID holds an ACTIVE claim on
    the issue surface. exit 0 => clear; a binary fault (None / exit 2) degrades to clear so a
    coordination hiccup never wedges the loop. `holder` carries heimdall-claim's stderr report
    (who holds it) on a collision, else None."""
    pl = planning or planning_dir(repo)
    r = _run(["check", issue_surface(issue_id)], pl)
    if r is None:
        return (True, None)
    if r.returncode == 3:
        return (False, (r.stderr or "").strip() or "held by another agent")
    return (True, None)


def claim(issue_id, task_ref, repo=None, planning=None, ttl=DEFAULT_TTL_MINUTES):
    """Claim `issue_id` for THIS HAID (git-shared, HAID-attributed). Returns True on a granted
    claim, False on a collision (exit 3 — a teammate won a race between our check and claim) or
    any fault. heimdall-claim's own collision gate makes this the atomic arbiter: even if two
    teammates both passed check(), only one claim() succeeds."""
    pl = planning or planning_dir(repo)
    r = _run(["claim", issue_surface(issue_id), "--task", str(task_ref), "--ttl", str(int(ttl))], pl)
    return bool(r is not None and r.returncode == 0)


def release(repo=None, planning=None):
    """Release THIS HAID's claim (drops its claims/{slug}.json). The triage loop holds one
    issue claim at a time (pick → work → resolve/release → pick), so this frees the issue
    surface. Returns True on a released claim."""
    pl = planning or planning_dir(repo)
    r = _run(["release"], pl)
    return bool(r is not None and r.returncode == 0)


def reap(repo=None, planning=None):
    """Reap every TTL-expired claim NOW (reuse heimdall-claim reap). A dropped teammate's
    issue claim ages out here, returning the issue to the pick set — the first half of the
    handoff path (the second half, adopting their checkpoint, lives in triage_handoff.py).
    Best-effort: a fault is swallowed (the pick proceeds on the un-reaped view)."""
    pl = planning or planning_dir(repo)
    _run(["reap"], pl)


def holder_of(issue_id, repo=None, planning=None):
    """The HAID currently holding an ACTIVE claim on `issue_id`, or None. Reads the git-shared
    claim files directly (read-only, tolerant) — the same store heimdall-claim writes — so the
    caller can attribute a skip to a named teammate. Never raises."""
    import json

    pl = planning or planning_dir(repo)
    surf = issue_surface(issue_id)
    claims = os.path.join(pl, "ledger", "claims")
    try:
        names = [n for n in os.listdir(claims) if n.endswith(".json")]
    except OSError:
        return None
    for n in sorted(names):
        try:
            with open(os.path.join(claims, n), "r", encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict):
            continue
        if surf in (rec.get("claimed_surfaces") or []):
            return rec.get("haid")
    return None


# ── the pure claim-arbitration model (the differential-oracle impl side) ───────
#
# The SAME one-owner-per-issue-per-team decision the live heimdall-claim gate enforces, in a
# PURE, deterministic fold — no IO, no subprocess. It is the canonical decision spec: the
# team-copilot differential oracle folds an interleaved multi-HAID pick stream through THIS
# model and through an INDEPENDENT reference recompute, and diffs the served-claim sequence.
# It also backs a local dry-run of "who would win these picks" without touching the ledger.
#
# The model keys claims by (team, issue): a pick in team B never sees team A's claim (the
# isolation invariant). TTL expiry frees a claim (the reap/handoff invariant). Offline actors
# never win (they never emit a pick event). This is a decision model over EVENTS, not a
# reimplementation of heimdall-claim's file-glob engine — for issue surfaces (literals) the
# overlap relation is exact-equality, so the model needs only equality, not glob nesting.


def simulate_claim_stream(events):
    """Fold an interleaved multi-HAID pick stream into the served-claim sequence.

    events: an iterable of dicts, each one of:
      {"t": int, "seq": int, "team": str, "haid": str, "action": "pick",
       "issue": str, "ttl": int}   — an attempt to claim `issue` at time t for `ttl` ticks.
      {"t": int, "seq": int, "team": str, "haid": str, "action": "release",
       "issue": str}               — the holder voluntarily drops the issue.

    Rules (the invariants, one place):
      * events are processed in (t, seq) order — the deterministic interleave;
      * before each event, claims whose expiry <= t are REAPED (TTL — enables handoff);
      * a `pick` is GRANTED iff the (team, issue) is unclaimed OR already held by the SAME
        haid → sets expiry = t + ttl and EMITS a served row; otherwise DENIED (no emit —
        the cross-teammate no-double-work guard);
      * claims are partitioned by (team, issue): a pick in one team can never observe or
        collide with another team's claim (team isolation);
      * a `release` frees the (team, issue) iff the releasing haid holds it.

    Returns {"served": sorted list of served rows}. A served row is
      [t, seq, team, issue, haid] — the granted claim, in emission order then sorted for a
    stable comparable partition (the differential unit)."""
    ordered = sorted(
        (e for e in (events or []) if isinstance(e, dict)),
        key=lambda e: (int(e.get("t", 0)), int(e.get("seq", 0))),
    )
    active = {}  # (team, issue) -> {"haid": h, "expiry": int}
    served = []
    for e in ordered:
        t = int(e.get("t", 0))
        # TTL reap: drop every claim whose window has closed at or before now.
        for key in [k for k, v in active.items() if v["expiry"] <= t]:
            del active[key]
        team = str(e.get("team", "default"))
        issue = str(e.get("issue", ""))
        haid = str(e.get("haid", ""))
        action = e.get("action", "pick")
        key = (team, issue)
        if action == "release":
            held = active.get(key)
            if held and held["haid"] == haid:
                del active[key]
            continue
        # action == "pick"
        held = active.get(key)
        if held is None or held["haid"] == haid:
            ttl = int(e.get("ttl", DEFAULT_TTL_MINUTES))
            active[key] = {"haid": haid, "expiry": t + max(1, ttl)}
            served.append([t, int(e.get("seq", 0)), team, issue, haid])
        # else: DENIED — a different teammate holds an active claim; no emit.
    served.sort(key=lambda r: (r[0], r[1], r[2], r[3], r[4]))
    return {"served": served}
