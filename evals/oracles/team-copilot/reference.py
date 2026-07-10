#!/usr/bin/env python3
# reference.py — the INDEPENDENT reference fold for the team-copilot differential oracle
# (the REDUM TEAM-LENS arm: the code∪work bridge).
#
# INDEPENDENCE (differential integrity). This module imports NOTHING from bin/lib/* — every
# rule below is HAND-REPRODUCED from evals/oracles/team-copilot/INVARIANTS.md, so it shares no
# code path with the implementation under test (bin/lib/redum.py's team lens). differential.py
# (the neutral gate wiring) imports BOTH this reference and the redum impl and diffs them, so
# oracle independence holds by construction. An acceptance grep enforces
# `! grep -q 'redum\|checkpoint_share' reference.py`.
#
# WHAT IT COMPUTES. The SAME team-candidate roster the redum team lens produces, recomputed
# from first principles over a stream of teammate work-states:
#     {"candidates": sorted list of [surface, haid, human, class, adoptable] rows}
# per the team read-model in INVARIANTS.md:
#   team != "mine"                          -> EXCLUDE  (RT-ISO: a different team's ledger is a
#                                              different planning dir, never read)
#   surface NOT relevant to the task        -> SKIP     (RT-REL)
#   checkpoint completed (pct>=100/done)    -> class "completed"        ("reuse finished work")
#   active claim (non-TTL-expired)          -> class "teammate-in-flight" ("don't reinvent")
#   checkpoint survives, claim DROPPED      -> class "adoptable-dropped"  ("don't redo, adopt")
#   expired claim, no surviving checkpoint  -> SKIP     (RT-GHOST: nothing to reuse)
# A candidate row carries ONLY scrubbed roster fields (surface/haid/human/class/adoptable) —
# NEVER a teammate's free-form active_goal/task_ref prose (RT-LEAK).

from __future__ import annotations

import hashlib
import json
import re

# ── the class order + labels (hand-copied from INVARIANTS.md) ─────────────────
_CLASS_ORDER = {"teammate-in-flight": 0, "adoptable-dropped": 1, "completed": 2}

_DONE_RX = re.compile(r"\b(done|complete|completed|merged|shipped|landed)\b")


# ── relevance (reproduces redum._task_tokens + _surface_relevant) ─────────────


def task_tokens(task):
    return {t.lower() for t in re.findall(r"[A-Za-z0-9_]+", task or "") if len(t) >= 3}


def surface_relevant(surface, tokens):
    s = str(surface)
    parts = set()
    file_part, _, sym = s.partition("#")
    if sym:
        parts.add(sym.lower())
    for seg in re.split(r"[/.]", file_part):
        seg = seg.replace("*", "").strip()
        if len(seg) >= 3:
            parts.add(seg.lower())
    return bool(parts & tokens)


def is_completed(pct, phase):
    try:
        n = int(pct)
    except (TypeError, ValueError):
        n = 0
    if n >= 100:
        return True
    return bool(_DONE_RX.search(str(phase or "").lower()))


def _haid_human(haid):
    m = re.match(r"^haid:([a-z0-9-]+)\.", str(haid))
    return m.group(1) if m else str(haid)


def classify(rec):
    """Return the class of ONE teammate work-state record, or None to skip. Reproduces the
    redum team-lens classification rules (INVARIANTS.md RT-CLASS)."""
    has_ckpt = bool(rec.get("has_checkpoint"))
    active = bool(rec.get("claim_active"))
    if has_ckpt and is_completed(rec.get("progress_pct", 0), rec.get("phase")):
        return "completed"
    if active:
        return "teammate-in-flight"
    if has_ckpt:
        return "adoptable-dropped"
    return None   # expired claim, no surviving checkpoint -> a ghost, nothing to reuse


def task_for(stream):
    """The canonical task text for a stream: names every surface's distinctive symbol so every
    surface is RELEVANT (the differential exercises CLASSIFICATION + ISOLATION, not the relevance
    filter — that is covered by the unit test). Deterministic for a given stream."""
    syms = []
    for rec in stream or []:
        surface = str(rec.get("surface", ""))
        sym = surface.partition("#")[2]
        if sym:
            syms.append(sym)
    return "coordinate on " + " ".join(sorted(set(syms)))


def fold(stream, task=None):
    """Fold a stream of teammate work-states into the reference team-candidate partition (the
    truth half of the differential). Returns {"candidates": sorted rows}. A row is
    [surface, haid, human, class, adoptable] — scrubbed roster fields ONLY (RT-LEAK)."""
    if task is None:
        task = task_for(stream)
    tokens = task_tokens(task)
    rows = []
    for rec in stream or []:
        if not isinstance(rec, dict):
            continue
        if str(rec.get("team", "mine")) != "mine":     # RT-ISO — cross-team never surfaces
            continue
        surface = str(rec.get("surface", ""))
        if not surface_relevant(surface, tokens):        # RT-REL
            continue
        cls = classify(rec)
        if cls is None:                                  # RT-GHOST
            continue
        haid = str(rec.get("haid", ""))
        human = str(rec.get("human") or _haid_human(haid))
        rows.append([surface, haid, human, cls, cls == "adoptable-dropped"])
    rows.sort(key=lambda r: (_CLASS_ORDER.get(r[3], 9), r[1], r[0]))
    return {"candidates": rows}


# ── deterministic seeded stream generator (the seeded-differential arm) ───────


def _seeded_int(seed, *parts):
    h = hashlib.sha256(("|".join([str(seed)] + [str(p) for p in parts])).encode()).hexdigest()
    return int(h[:8], 16)


def generate_stream(seed, n_records=12):
    """Produce a deterministic teammate work-state stream for `seed`: ONE record per teammate
    (unique HAID — mirrors the one-file-per-HAID ledger). The distribution is skewed so every
    seed exercises all three classes (in-flight / adoptable-dropped / completed) AND a cross-team
    slice that MUST be excluded (RT-ISO). Same seed => byte-identical stream. Carries NO secret
    and NO free-form prose in a surfaced field, so the impl team lens and this reference MUST
    agree on every seed (leaks/misclassifications are the mutant-only defects)."""
    stream = []
    for i in range(n_records):
        kind = _seeded_int(seed, "kind", i) % 5
        team = "other" if (_seeded_int(seed, "team", i) % 7 == 0) else "mine"
        # class distribution: kind 0 -> adoptable-dropped, kind 1 -> completed, else in-flight.
        if kind == 0:
            claim_active, has_ckpt, pct, phase = False, True, \
                _seeded_int(seed, "pct", i) % 99, "wave-2/build"
        elif kind == 1:
            claim_active, has_ckpt, pct, phase = False, True, 100, "wave-3/done"
        else:
            claim_active, has_ckpt, pct, phase = True, True, \
                _seeded_int(seed, "pct", i) % 99, "wave-1/build"
        stream.append({
            "haid": "haid:dev%02d.box" % i,
            "human": "dev%02d" % i,
            "branch": "feat/dev%02d" % i,
            "phase": phase,
            "progress_pct": pct,
            "surface": "mod%02d/file.ts#sym%02d" % (i, i),
            "claim_active": claim_active,
            "has_checkpoint": has_ckpt,
            # a teammate's private planning note — MUST NEVER appear in a surfaced candidate.
            "active_goal": "advance module %d toward green" % (_seeded_int(seed, "g", i) % 20),
            "team": team,
        })
    return stream
