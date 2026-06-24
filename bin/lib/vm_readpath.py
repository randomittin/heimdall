#!/usr/bin/env python3
# vm_readpath.py — Verified-Memory → SI-1 read-path seam (VM piece D).
#
# THE SEAM (dossier §2 / §6 piece D): SI-1's comprehension capsule is the agent's
# ORIENTATION read path — "what IS this project". Verified-memory is a CONSUMER of
# that read path: when the capsule is assembled, the agent's git-verified memory
# about THIS repo is surfaced alongside it, each memory claim shown WITH its
# git-verified status (live | stale). This module is the thin seam that turns the
# verified_memory READ API (piece B, which already RE-VERIFIES at read time) into a
# capsule-shaped readout the comprehend CLI can append.
#
# THE LOAD-BEARING CONTRACT (dossier §2, "read-time re-verification is the load-
# bearing novelty"): we never serve a stale entry AS live. We call
# verified_memory.list_entries (which re-runs verify() against git on every entry
# at read time), then PARTITION the fresh result:
#   • LIVE   — git-confirmed survivors, ranked by the read-time weight READOUT
#              (weight is recomputed from the git-check, never a stored decaying
#              number — a deliberately-wrong stored weight cannot leak through).
#   • STALE  — every non-live entry, surfaced MARKED stale (weight 0), so the agent
#              treats a stale memory as stale (the thesis: verify against ground
#              truth before acting). Never promoted, never ranked among the live.
# A stale entry appearing in the live set is the exact failure mode verified-memory
# exists to kill; this seam keeps the two sets disjoint by construction.
#
# GRACEFUL DEGRADE (dossier §7, telemetry/attestation discipline): no memory store,
# verified-memory absent, an import failure, or a git fault → an EMPTY-but-well-
# formed readout (available=False, no live/stale), never a crash. The comprehend
# CLI that consumes this behaves EXACTLY as today when no verified memory exists —
# solo / clean-install is unaffected, no regression.
#
# This is a LIBRARY with a thin argparse CLI (readout) used by bin/heimdall-comprehend.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# the read-time-re-verifying memory API (piece B). Imported defensively: if the
# verified-memory layer is absent (a slimmed install), the read path degrades to an
# empty readout rather than crashing the comprehend capsule.
try:
    import verified_memory as _vm  # piece B — READ API re-verifies at read time
    import vm_gitcheck as _vmg      # piece A — the status constants (LIVE/STALE)
    _VM_AVAILABLE = True
    _VM_IMPORT_ERROR = None
except Exception as _exc:  # noqa: BLE001 — absent VM layer must never crash orient
    _vm = None
    _vmg = None
    _VM_AVAILABLE = False
    _VM_IMPORT_ERROR = str(_exc)

# the status labels, resolved from the engine when present, else the pinned literals
# (so the readout shape is identical whether or not the VM layer imported).
LIVE = getattr(_vmg, "LIVE", "live")
STALE = getattr(_vmg, "STALE", "stale")
CONFLICTED = getattr(_vmg, "CONFLICTED", "conflicted")


def _entry_view(entry):
    """The capsule-facing projection of ONE re-verified entry — the fields the agent
    needs to treat the memory correctly: the claim, its git-verified status, the
    read-time weight readout, the commit it asserts, the refs it depends on, and the
    one-line git reason. Drops the audit-only / cache fields. Never the stored
    status — the value here is always the fresh read-time readout from list_entries."""
    return {
        "id": entry.get("id"),
        "claim": entry.get("claim"),
        "status": entry.get("status"),
        "weight": entry.get("weight"),
        "commit_ref": entry.get("commit_ref"),
        "refs": entry.get("refs") or [],
        "reason": entry.get("reason"),
        "verified_at": entry.get("verified_at"),
    }


def read_context(repo, *, home=None, cache_dir=None, timeout=None):
    """Surface this repo's git-verified memory for the SI-1 orientation read path.

    Calls verified_memory.list_entries — which RE-VERIFIES every entry against git
    AT READ TIME (the load-bearing novelty) — then PARTITIONS the fresh result into
    git-confirmed LIVE survivors (ranked by the read-time weight readout) and STALE
    entries (surfaced marked stale, never served as live). A stale entry is NEVER
    placed in the live set: the two are disjoint by construction.

    Returns a readout dict (always well-formed, even when empty):
      { available: bool,            # False → no VM layer / no store → behave as today
        repo, store,                # the repo verified against + the resolved store path
        live:  [entry_view, ...],   # git-confirmed, descending read-time weight
        stale: [entry_view, ...],   # marked stale (weight 0), git-decided, not live
        counts: {live, stale, total},
        reason }                    # why available is False (absent layer/store/fault)

    NEVER raises — an import failure, a missing store, or a git fault degrades to an
    empty-but-well-formed readout so the comprehend capsule is unaffected (no
    regression, no crash). Solo / clean-install (no store) → available=False, empty."""
    empty = {
        "available": False,
        "repo": repo,
        "store": None,
        "live": [],
        "stale": [],
        "counts": {"live": 0, "stale": 0, "total": 0},
        "reason": None,
    }

    if not _VM_AVAILABLE:
        empty["reason"] = "verified-memory layer not installed (%s)" % (
            _VM_IMPORT_ERROR or "import unavailable"
        )
        return empty

    # resolve the store path (REUSE verified_memory.entries_path — never re-derive).
    try:
        store = _vm.entries_path(home)
    except Exception as exc:  # noqa: BLE001 — home resolution must not crash orient
        empty["reason"] = "could not resolve memory store: %s" % exc
        return empty
    empty["store"] = store

    # ABSENT STORE → behave exactly as today: no verified memory to surface. This is
    # the solo / clean-install path — an empty readout, no crash, no regression.
    if not os.path.isfile(store):
        empty["reason"] = "no memory store at %s (nothing to verify)" % store
        return empty

    # READ-TIME RE-VERIFICATION: list_entries re-runs the git-check on every entry
    # and returns them with the FRESH read-time status + weight (sorted live-first).
    try:
        kwargs = {"home": home, "cache_dir": cache_dir, "include_stale": True}
        if timeout is not None:
            kwargs["timeout"] = timeout
        entries = _vm.list_entries(repo, **kwargs)
    except Exception as exc:  # noqa: BLE001 — a verify/git fault must not crash orient
        empty["store"] = store
        empty["reason"] = "memory read-verification failed: %s — surfacing nothing" % exc
        return empty

    # PARTITION the fresh, re-verified result. A stale (or any non-live) entry is
    # NEVER placed in `live`: live is git-confirmed survivors only. This is the
    # disjoint-by-construction guarantee — a stale entry cannot leak in as live.
    live, stale = [], []
    for e in entries:
        view = _entry_view(e)
        if e.get("status") == LIVE:
            live.append(view)
        else:
            stale.append(view)

    # live are already descending-weight from list_entries; keep that order. stale
    # all weigh 0 (git zeroed them) — order them by claim for a stable readout.
    stale.sort(key=lambda v: (v.get("claim") or ""))

    return {
        "available": True,
        "repo": repo,
        "store": store,
        "live": live,
        "stale": stale,
        "counts": {
            "live": len(live),
            "stale": len(stale),
            "total": len(live) + len(stale),
        },
        "reason": None,
    }


# ── render the readout as a clean capsule block (appended by the comprehend CLI) ──


def _fmt_refs(refs):
    """Compact one-line ref summary: path:symbol joined, for the readout line."""
    parts = []
    for r in refs or []:
        path = (r.get("path") or "").strip()
        sym = (r.get("symbol") or "").strip()
        parts.append("%s:%s" % (path, sym) if sym else path)
    return ", ".join(parts)


def render_block(readout):
    """Render the read-path readout as a clean, self-contained text block for the
    SI-1 capsule. Each memory claim is shown WITH its git-verified status so the
    agent treats a stale memory as stale (verify against ground truth before
    acting). When no verified memory is available the block is a single honest
    line — it does NOT disrupt the existing comprehend output, it is purely additive.

    Returns the block as a string (no trailing newline)."""
    head = "── verified memory (git-checked at read) ──"

    if not readout.get("available"):
        # absent layer / store → one honest line; comprehend output is otherwise
        # identical to today (the additive block is a no-op note, not a section).
        reason = readout.get("reason") or "no verified memory for this repo"
        return "%s\n  (none — %s)" % (head, reason)

    live = readout.get("live") or []
    stale = readout.get("stale") or []
    counts = readout.get("counts") or {}
    lines = [head]
    lines.append(
        "  %d live · %d stale (git-decided at read; stale never served as live)"
        % (counts.get("live", 0), counts.get("stale", 0))
    )

    if live:
        lines.append("  LIVE — git-confirmed, ranked by read-time weight:")
        for v in live:
            refs = _fmt_refs(v.get("refs"))
            ref_str = (" [%s]" % refs) if refs else ""
            lines.append(
                "    • (w=%.3f) %s%s @ %s"
                % (v.get("weight") or 0.0, v.get("claim") or "", ref_str,
                   (v.get("commit_ref") or "")[:12])
            )
    if stale:
        lines.append("  STALE — git says these no longer hold; do NOT act on them:")
        for v in stale:
            reason = v.get("reason") or "no longer matches git"
            lines.append(
                "    ✗ [stale, w=0] %s — %s"
                % (v.get("claim") or "", reason)
            )
    if not live and not stale:
        lines.append("  (store present but empty — nothing to surface)")

    return "\n".join(lines)


# ── thin CLI (readout) — driven by bin/heimdall-comprehend's `recall` block ───────


def _cli(argv):
    """CLI core. Subcommand:
      readout --repo DIR [--home DIR] [--cache-dir DIR] [--timeout SEC]
              [--json | --text]
    Surfaces this repo's git-verified memory for the SI-1 read path: LIVE entries
    ranked by the read-time weight readout, STALE entries marked (never served as
    live). --json emits the full readout dict; --text (default) emits the rendered
    capsule block. Absent store / VM layer → an empty readout (available=False) and
    the one-line 'none' block — exit 0, no crash (graceful-degrade)."""
    import argparse

    p = argparse.ArgumentParser(prog="vm_readpath", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--home")
    p.add_argument("--cache-dir", dest="cache_dir")
    p.add_argument("--timeout", type=float, default=None)
    fmt = p.add_mutually_exclusive_group()
    fmt.add_argument("--json", action="store_const", dest="fmt", const="json")
    fmt.add_argument("--text", action="store_const", dest="fmt", const="text")
    p.set_defaults(fmt="text")
    args = p.parse_args(argv)

    if args.subcommand != "readout":
        sys.stderr.write("vm_readpath: unknown subcommand: %s\n" % args.subcommand)
        return 2

    readout = read_context(
        args.repo, home=args.home, cache_dir=args.cache_dir, timeout=args.timeout,
    )
    if args.fmt == "json":
        sys.stdout.write(json.dumps(readout, indent=2, sort_keys=True) + "\n")
    else:
        sys.stdout.write(render_block(readout) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
