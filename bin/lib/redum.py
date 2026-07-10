#!/usr/bin/env python3
# redum.py — F3 Redum, the redundancy SOLVER (the engine behind bin/heimdall-redum).
#
# S-6 / SI-2 MEASURE reuse (the reuse_pct + suspected_duplicates field). Redum is
# what FIXES low reuse. Two phases:
#
#   • PLAN-TIME FACTORING (factor_for_task) — BEFORE the agent builds, surface the
#     existing repo units the solution SHOULD reuse, so it reuses BY DESIGN, not
#     by luck. For the commander class: a task to add mandatory-option behavior
#     surfaces makeOptionMandatory / _checkForMissingMandatoryOptions / _optionEx
#     as the existing machinery to call — so the agent calls them instead of
#     reimplementing. For RN/card-data: a task to add a cards selector/MMKV key
#     surfaces the existing selectCards / cards.cache key.
#
#   • COMMIT-TIME GATE (gate_attestation) — AFTER the change, read SI-2's `reuse`
#     field (it is already computed — Redum does NOT re-measure). If the change
#     RE-ADDED a shape the repo already had (suspected_duplicates non-empty, or a
#     low reuse_pct on a change that should have reused), FLAG it — and name the
#     existing unit via the shared dedup matcher. The gate is a backstop for
#     residual redundancy that slipped past plan-time factoring.
#
# Redum reuses, does not rebuild:
#   • the reuse measurement → SI-2's reuse field (read, never recompute).
#   • the dedup matching     → bin/lib/dedup.py (the shared core F2 also fuses on).
#   • the AST surface        → bin/lib/treesitter_ast.py (via dedup + reuse).
#
# This is a LIBRARY (pure functions). The CLI is bin/heimdall-redum, which owns
# git extraction + the SI-2 attestation read.

from __future__ import annotations

import ast
import datetime
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import dedup  # noqa: E402 — sibling import after sys.path setup
import reuse_analyzer as reuse  # noqa: E402

# The TEAM read-model. Redum's team lens (below) does NOT rebuild "what are my teammates
# working on" — it REUSES the shared-checkpoints engine, the ONE read model the checkpoint
# store already folds. checkpoint_share owns the git-native ledger resolution
# (planning_dir/claims_dir/checkpoints_dir — HEIMDALL_PLANNING_DIR or <git-root>/.planning),
# the per-HAID slug, the scrubbed checkpoint reads, the completed-work test, and the
# surface-overlap engine. A DIFFERENT team's ledger lives in a DIFFERENT planning dir and is
# never read — team isolation is the store boundary, inherited verbatim (keystone stays 1.0).
# Guarded so the SOLO path (team lens off) never gains a new failure mode if the module is
# absent; the lens degrades to empty rather than raising.
try:
    import checkpoint_share as _cp  # noqa: E402 — the shared team read-model
except Exception:  # noqa: BLE001 — absence must never break the solo redum path
    _cp = None

# the gate policy floor below which a low-reuse change is flagged. Mirrors the
# SI-2 risk floor (attestation.REUSE_RISK_FLOOR = 0.30) so Redum's gate and SI-2's
# risk surface agree. A reader/CI may pass its own floor.
DEFAULT_REUSE_FLOOR = 0.30

# how Redum turns a task description into candidate shapes to factor: a set of
# concept→shape hints. Each hint is (regex over the task text, [shape-name hints]).
# These are not hardcoded answers — they map a task's INTENT to the repo symbols
# Redum then *looks up* in the actual repo index. If a hinted symbol doesn't exist
# in the repo, it is NOT surfaced (we only surface what genuinely exists to reuse).
_INTENT_HINTS = [
    # the commander class: mandatory-option machinery.
    (re.compile(r"\bmandatory\b|\brequired option\b|\boption.*requir", re.I),
     ["makeOptionMandatory", "_checkForMissingMandatoryOptions", "_optionEx",
      "mandatoryOption"]),
    (re.compile(r"\bmissing option|\bmissing mandatory", re.I),
     ["_checkForMissingMandatoryOptions"]),
    # RN / card-data domain.
    (re.compile(r"\bcard", re.I),
     ["selectCards", "cardsSlice", "loadCards", "selectCardById"]),
    (re.compile(r"\bselector\b|\bderive.*state|\bselect from", re.I),
     []),  # selectors are surfaced structurally below, not by a fixed name list
    (re.compile(r"\bMMKV\b|\bstorage key|\bcache key|\bpersist", re.I),
     []),  # MMKV keys surfaced structurally below
]


# ── PLAN-TIME FACTORING ───────────────────────────────────────────────────────


def factor_for_task(task, repo_files, want_kinds=None, max_per_concept=4,
                    team_lens=False, my_haid=None, repo_root=None, now=None):
    """PHASE 1. Given a task description + the current repo files, return the
    reuse candidates the agent SHOULD reuse — so it reuses by design.

    task: the natural-language task (what the agent is about to build).
    repo_files: dict {path: source} of the EXISTING repo (the pre-build surface).
    want_kinds: optional kind filter (e.g. only ["rn-selector","mmkv-key"]).
    max_per_concept: cap candidates surfaced per detected concept (anti-over-
                     factoring: factor what is genuinely shared, not everything).
    team_lens: when True (and my_haid given), ALSO fold in OTHER teammates' live
               work — their ACTIVE claims + SHARED checkpoints — as reuse/overlap
               candidates, so "don't reinvent existing CODE" extends to "don't
               reinvent OR redo what a teammate is BUILDING right now". OFF by
               default → the returned dict is byte-identical to the solo path (no
               team keys), so no solo/feature-off behavior changes.
    my_haid / repo_root / now: team-lens inputs (this HAID's id — excluded from its
               own reuse advice; the planning-dir root; an epoch/ISO clock for TTL).

    Returns (solo) {
      "task": task,
      "candidates": [ {name, kind, file, score, reason, concept}, ... ],
      "concepts": [detected concept tags],
      "advice": one-line human guidance,
    }
    With team_lens ON the dict ALSO carries:
      "team_candidates": [ {surface, haid, human, branch, source, class, phase,
                            progress_pct, adoptable, reason}, ... ],
      "team_advice": one-line team guidance.

    The candidates are REAL repo units (indexed via the shared dedup core). A
    concept hint only surfaces a symbol that ACTUALLY EXISTS in the repo — Redum
    never invents a target. This is the anti-luck mechanism: the planner/agent is
    handed the names to call. Team candidates are REAL teammate surfaces already
    public in the git ledger (claim globs + checkpoint surfaces) — read-only, never
    written, never blocking."""
    index = dedup.index_repo_units(repo_files)
    by_name = {}
    for u in index:
        by_name.setdefault(u.name, u)

    candidates = []
    concepts = []
    seen = set()

    def emit(unit, concept, score, reason):
        key = (unit.name, unit.kind, unit.file)
        if key in seen:
            return
        seen.add(key)
        if want_kinds and unit.kind not in want_kinds:
            return
        candidates.append({
            "name": unit.name,
            "kind": unit.kind,
            "file": unit.file,
            "score": round(score, 4),
            "reason": reason,
            "concept": concept,
        })

    # 1) named-intent hints: map task INTENT → existing repo symbols to reuse.
    for rx, names in _INTENT_HINTS:
        if not rx.search(task or ""):
            continue
        concept = rx.pattern.split("|")[0].strip("\\b").strip()
        concepts.append(concept)
        emitted = 0
        for nm in names:
            u = by_name.get(nm)
            if u is None:
                # the exact symbol isn't here, but a near-named one might be the
                # capability — surface it so the agent reuses it not reinvents.
                u = _near_repo_unit(nm, index)
            if u is not None and emitted < max_per_concept:
                emit(u, concept, 0.9, "task implies %r; reuse existing %s %r"
                     % (concept, u.kind, u.name))
                emitted += 1

    # 2) STRUCTURAL concepts (selectors / MMKV keys / slices): when the task talks
    # about selectors / storage keys / slices, surface the EXISTING RN reuse units
    # of that kind so a new one reuses rather than duplicates.
    kind_for_concept = {
        "selector": "rn-selector",
        "MMKV": "mmkv-key",
        "storage key": "mmkv-key",
        "cache key": "mmkv-key",
        "slice": "rn-slice",
    }
    tl = (task or "").lower()
    for phrase, kind in kind_for_concept.items():
        if phrase.lower() in tl:
            concepts.append(phrase)
            n = 0
            for u in index:
                if u.kind == kind and n < max_per_concept:
                    emit(u, phrase, 0.85,
                         "task touches %s; an existing %s already exists — reuse it"
                         % (phrase, kind))
                    n += 1

    candidates.sort(key=lambda c: (-c["score"], c["name"]))
    advice = _factor_advice(candidates)
    result = {
        "task": task,
        "candidates": candidates,
        "concepts": sorted(set(concepts)),
        "advice": advice,
    }
    # TEAM LENS (opt-in): fold OTHER teammates' in-flight work into the reuse
    # surfacing. OFF by default so the solo path is byte-identical (no new keys).
    if team_lens:
        lens = team_lens_candidates(task, my_haid, repo_root=repo_root, now=now)
        result["team_candidates"] = lens["team_candidates"]
        result["team_advice"] = lens["team_advice"]
    return result


def _near_repo_unit(name, index):
    """Find an existing repo unit whose name is near `name` (the capability under a
    slightly different identifier), or None."""
    best = None
    for u in index:
        if dedup.normalize(u.name) == dedup.normalize(name):
            return u
        if best is None and dedup.near(name, u.name):
            best = u
    return best


def _factor_advice(candidates):
    if not candidates:
        return ("no existing reuse candidates detected for this task — proceed, "
                "but the commit-time gate will still backstop residual redundancy")
    names = ", ".join(c["name"] for c in candidates[:5])
    return ("reuse existing machinery instead of reimplementing: %s" % names)


# ── TEAM READ-MODEL (the code∪work BRIDGE) ─────────────────────────────────────
#
# ONE read model — "what are my teammates working on" — powers BOTH:
#   • duplicate-effort PREVENTION: a surface under a teammate's ACTIVE claim is a
#     'teammate-in-flight' reuse candidate — coordinate/reuse, do NOT reinvent.
#   • dropped-work RECOVERY: a surface in a teammate's SHARED checkpoint whose claim
#     has DROPPED (TTL-reaped / no active claim) and is not complete is an
#     'adoptable-dropped' candidate — adopt/resume, do NOT redo. This ties the
#     reap→adopt path of the shared-checkpoints handoff into redum's surfacing.
#   • a COMPLETED checkpoint surface is 'completed' — reuse the finished work.
#
# The read is TEAM-ISOLATION-SAFE by construction: it resolves the ONE planning dir
# (HEIMDALL_PLANNING_DIR or <git-root>/.planning) via checkpoint_share and reads only
# that team's ledger. A different team's ledger is a different dir → never read
# (rr-multitenant-isolation keystone unaffected). It NEVER emits a teammate's free-form
# prose (active_goal/task_ref) — only already-public surfaces + scrubbed roster fields
# (haid/human/branch/phase/progress_pct) — so the team lens has ZERO new leak surface.


def _parse_iso_epoch(value):
    """Parse an ISO8601 UTC timestamp (…Z or +00:00) to epoch seconds, or None. Mirrors
    heimdall-claim's timestamp shape (date -u +%FT%TZ). Tolerant — a bad value → None."""
    if value is None:
        return None
    s = str(value).strip()
    if not s:
        return None
    iso = s.replace("Z", "+00:00")
    try:
        dt = datetime.datetime.fromisoformat(iso)
    except ValueError:
        try:
            dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def _now_epoch(now):
    """Resolve the comparison clock. now: None → wall-clock UTC now; int/float → epoch
    as-is; str → parsed from ISO. Injectable so TTL tests are hermetic."""
    if now is None:
        return datetime.datetime.now(datetime.timezone.utc).timestamp()
    if isinstance(now, (int, float)):
        return float(now)
    parsed = _parse_iso_epoch(now)
    return parsed if parsed is not None else \
        datetime.datetime.now(datetime.timezone.utc).timestamp()


def _claim_is_active(rec, now_epoch):
    """A claim is ACTIVE while now < heartbeat + ttl_minutes (heimdall-claim's rule). A
    claim with an unparseable heartbeat is treated as EXPIRED (fail-safe: we do not surface
    stale work as live)."""
    hb = _parse_iso_epoch(rec.get("heartbeat") or rec.get("claimed_at"))
    if hb is None:
        return False
    try:
        ttl_min = float(rec.get("ttl_minutes", 90))
    except (TypeError, ValueError):
        ttl_min = 90.0
    return now_epoch < (hb + ttl_min * 60.0)


def _read_active_claims(my_haid, repo_root=None, now=None):
    """Read OTHER HAIDs' ACTIVE claims from the team ledger, keyed by HAID. Read-only,
    tolerant (a bad file is skipped). Team-isolation-safe: reads ONLY the resolved
    .planning/ledger/claims dir — a different team's ledger is never touched."""
    out = {}
    if _cp is None:
        return out
    now_epoch = _now_epoch(now)
    try:
        d = _cp.claims_dir(repo_root)
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(d, n), "r", encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict):
            continue
        haid = rec.get("haid")
        if not haid or haid == my_haid:
            continue
        if _claim_is_active(rec, now_epoch):
            out[haid] = rec
    return out


def _task_tokens(task):
    """Distinctive alnum tokens (len ≥ 3) in the task text, lowercased — the vocabulary a
    teammate surface must intersect to be RELEVANT to this task."""
    return {t.lower() for t in re.findall(r"[A-Za-z0-9_]+", task or "") if len(t) >= 3}


def _surface_relevant(surface, tokens):
    """A teammate's claimed surface is RELEVANT to the task when the task names its symbol
    or a distinctive path segment. Matches on the '#symbol' part and on each path segment /
    file-stem (glob wildcards stripped). A too-short/globby segment (len < 3) never matches
    on its own, so a broad 'src/**' claim does not spam every task."""
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


def _cp_completed(rec):
    """Whether a checkpoint marks completed work — reuse checkpoint_share's rule when
    available, else a local mirror (progress 100 / a done-ish phase)."""
    if _cp is not None:
        return _cp._is_completed(rec)  # noqa: SLF001 — intentional reuse of the shared rule
    try:
        pct = int(rec.get("progress_pct", 0))
    except (TypeError, ValueError):
        pct = 0
    if pct >= 100:
        return True
    return bool(re.search(r"\b(done|complete|completed|merged|shipped|landed)\b",
                          str(rec.get("phase") or "").lower()))


def team_lens_candidates(task, my_haid, repo_root=None, now=None):
    """Build the TEAM read-model: OTHER teammates' in-flight surfaces, folded from ACTIVE
    claims (live work) ∪ SHARED checkpoints (redundant, handoff-ready), matched to the task
    as reuse/overlap candidates. The code∪work bridge (see section header).

    Returns {"team_candidates": [...sorted...], "team_advice": str}. Read-only, never blocks,
    never emits teammate prose. A missing read-model (no checkpoint_share / empty ledger) →
    empty candidates (graceful)."""
    tokens = _task_tokens(task)
    active = _read_active_claims(my_haid, repo_root=repo_root, now=now)
    checkpoints = {}
    if _cp is not None:
        try:
            checkpoints = _cp.all_checkpoints(repo_root) or {}
        except Exception:  # noqa: BLE001 — a bad store never breaks planning
            checkpoints = {}

    # the union of OTHER HAIDs that have live claims and/or shared checkpoints.
    haids = set(active) | {h for h in checkpoints if h and h != my_haid}
    out = []
    for haid in sorted(haids):
        if haid == my_haid:
            continue
        claim = active.get(haid)
        ckpt = checkpoints.get(haid)
        has_active = claim is not None
        completed = bool(ckpt) and _cp_completed(ckpt)

        human = None
        branch = None
        phase = None
        pct = None
        if ckpt:
            human = ckpt.get("human")
            branch = ckpt.get("branch")
            phase = ckpt.get("phase")
            pct = ckpt.get("progress_pct")
        if claim and not human:
            human = claim.get("human")

        # union of the surfaces this teammate is on: their live claim + their checkpoint.
        surfaces = set()
        if claim:
            surfaces |= {str(s) for s in (claim.get("claimed_surfaces") or [])}
        if ckpt:
            surfaces |= {str(s) for s in (ckpt.get("claimed_surfaces") or [])}

        for surface in sorted(surfaces):
            if not _surface_relevant(surface, tokens):
                continue
            in_claim = bool(claim) and surface in \
                {str(s) for s in (claim.get("claimed_surfaces") or [])}
            in_ckpt = bool(ckpt) and surface in \
                {str(s) for s in (ckpt.get("claimed_surfaces") or [])}

            if completed:
                cls = "completed"
                reason = ("%s already COMPLETED %s (checkpoint %s%%) — reuse the finished "
                          "work, do not rewrite" % (human or haid, surface, pct))
            elif has_active:
                cls = "teammate-in-flight"
                reason = ("%s is BUILDING %s right now (active claim%s) — coordinate/reuse, "
                          "do NOT reinvent" % (human or haid, surface,
                                               " + checkpoint" if in_ckpt else ""))
            elif in_ckpt:
                # a checkpoint surface with NO active claim = dropped/reaped work that
                # SURVIVED in the redundant store → adoptable (the recovery half).
                cls = "adoptable-dropped"
                reason = ("%s's claim on %s DROPPED but their checkpoint survives (phase=%s, "
                          "%s%%) — adopt/resume, do NOT redo" % (human or haid, surface,
                                                                 phase, pct))
            else:
                # an EXPIRED claim with no surviving checkpoint: the work is gone, nothing
                # to reuse or adopt — do not surface a ghost.
                continue

            # _cp is guaranteed non-None here: a None read-model yields no active claims and
            # no checkpoints, so `haids` is empty and this loop never runs.
            out.append({
                "surface": surface,
                "haid": haid,
                "human": human or _cp.haid_human(haid),
                "branch": branch,
                "source": ("claim+checkpoint" if in_claim and in_ckpt
                           else "claim" if in_claim else "checkpoint"),
                "class": cls,
                "phase": phase,
                "progress_pct": pct,
                "adoptable": cls == "adoptable-dropped",
                "reason": reason,
            })

    out.sort(key=lambda c: (_CLASS_ORDER.get(c["class"], 9), c["haid"], c["surface"]))
    return {"team_candidates": out, "team_advice": _team_advice(out)}


# in-flight (coordinate NOW) ranks above adoptable (recover) above completed (reuse done).
_CLASS_ORDER = {"teammate-in-flight": 0, "adoptable-dropped": 1, "completed": 2}


def _team_advice(team_candidates):
    if not team_candidates:
        return ("no teammate is working on this surface right now — no coordination needed "
                "(the team lens found no active claims or checkpoints to reuse/adopt)")
    inflight = [c for c in team_candidates if c["class"] == "teammate-in-flight"]
    adoptable = [c for c in team_candidates if c["class"] == "adoptable-dropped"]
    parts = []
    if inflight:
        who = ", ".join(sorted({"%s:%s" % (c["human"], c["surface"]) for c in inflight}))
        parts.append("a teammate is BUILDING this now — coordinate/reuse, do NOT reinvent: "
                     + who)
    if adoptable:
        who = ", ".join(sorted({"%s:%s" % (c["human"], c["surface"]) for c in adoptable}))
        parts.append("dropped teammate work SURVIVES — adopt/resume, do NOT redo: " + who)
    if not parts:
        who = ", ".join(sorted({c["surface"] for c in team_candidates}))
        parts.append("teammate already completed this — reuse the finished work: " + who)
    return " | ".join(parts)


# ── COMMIT-TIME GATE ──────────────────────────────────────────────────────────


def gate_attestation(attestation, repo_files=None, changed_files=None,
                     floor=DEFAULT_REUSE_FLOOR, policy="flag",
                     team_lens=False, my_haid=None, repo_root=None, now=None,
                     changed_surfaces=None):
    """PHASE 2. Read SI-2's `reuse` field from an attestation record and decide the
    residual-redundancy verdict. Redum does NOT re-measure reuse — it ACTS on the
    metric SI-2 already emitted.

    attestation: the SI-2 record dict (from heimdall-attest), or its `reuse` sub-
                 dict directly. Must carry reuse_pct + suspected_duplicates.
    repo_files / changed_files: optional {path: src} maps. When provided, the
                 shared dedup matcher NAMES the exact existing unit each residual
                 duplicate should have reused + WHERE it lives (so the flag is
                 actionable, not just "low reuse"). Without them the gate still
                 fires on SI-2's suspected_duplicates (the metric stands alone).
    floor: reuse_pct below which a change is flagged (default 0.30, = SI-2 floor).
    policy: "flag" (default; warn, exit non-blocking) or "block" (the gate fails).
    team_lens: when True (and my_haid given), ALSO emit an INFORMATIONAL team signal
               when the change touches a surface a teammate holds an ACTIVE claim on.
               This is WARN-ONLY — a teammate's parallel work is a P3 collision, NOT a
               same-thing-MADE redum duplicate — so it NEVER escalates the verdict and
               NEVER blocks (surfacing > blocking, per team-mode law). The LOCAL
               same-repo residual-duplicate gate below is UNCHANGED: it still hard-blocks
               (verdict "block" under policy=block). OFF by default → byte-identical to
               the solo path (no team_signals key).
    my_haid / repo_root / now: team-lens inputs (this HAID; the planning-dir root; the
               TTL clock). changed_surfaces: optional explicit list of surfaces the change
               touches; when omitted it is derived from changed_files' paths.

    Returns (solo) {
      "verdict": "ok" | "flag" | "block",
      "reuse_pct": float|None,
      "suspected_duplicates": [...],        # echoed from SI-2 (not recomputed)
      "residual": [ {new_unit, duplicates, existing, reason}, ... ],
      "flags": [ {level, code, detail}, ... ],
      "summary": one-line human verdict,
    }
    With team_lens ON the dict ALSO carries "team_signals": [ {level:"warn", code:
    "team-residual-duplicate", haid, human, surface, overlaps, detail}, ... ] and the same
    entries appear as WARN-level flags — never HIGH, so the verdict is untouched."""
    reuse_field = _reuse_field(attestation)
    pct = reuse_field.get("reuse_pct")
    suspected = reuse_field.get("suspected_duplicates") or []

    flags = []
    residual = []

    # Build the dedup index ONCE if we were handed the repo surface, so each
    # residual duplicate can name the precise existing unit + file to reuse.
    index = None
    if repo_files:
        index = dedup.index_repo_units(repo_files)

    # 1) suspected_duplicates from SI-2 are RESIDUAL redundancy: the change re-added
    #    a shape the repo already had. Name the existing unit for each.
    for d in suspected:
        dup_name = d.get("duplicates")
        new_unit = d.get("new_unit")
        existing = _name_existing(dup_name, index)
        residual.append({
            "new_unit": new_unit,
            "duplicates": dup_name,
            "existing": existing,
            "reason": "change re-implements pre-existing %r instead of reusing it"
                      % dup_name,
        })

    # 1b) RN/MMKV residual: even when SI-2's symbol-level suspected_duplicates is
    #     empty, a NEW RN reuse unit (selector / MMKV key / slice) that duplicates
    #     an EXISTING one is residual redundancy SI-2's function-level metric may
    #     not name. Catch it with the RN-aware dedup matcher.
    if index is not None and changed_files:
        residual.extend(_rn_residual(changed_files, repo_files, index, suspected))

    if residual:
        names = sorted({r["duplicates"] for r in residual if r.get("duplicates")})
        flags.append({
            "level": "high",
            "code": "residual-duplicate",
            "detail": "change duplicates existing repo unit(s): %s — reuse them "
                      "instead of reimplementing" % ", ".join(names),
        })

    # 2) low reuse_pct floor (a change that SHOULD have reused but scored low).
    if pct is not None and pct < floor:
        flags.append({
            "level": "high",
            "code": "low-reuse",
            "detail": "reuse_pct=%.2f below the %.2f floor — the change likely "
                      "reinvents existing repo code" % (pct, floor),
        })

    # verdict: any high flag → flag (or block under block policy); else ok. Computed over
    # the LOCAL flags ONLY — the team lens (below) NEVER contributes a high flag, so it can
    # never change this verdict. This is the WARN-vs-BLOCK boundary: local same-repo
    # duplication hard-blocks; a teammate's parallel work only warns.
    has_high = any(f["level"] == "high" for f in flags)
    if not has_high:
        verdict = "ok"
    else:
        verdict = "block" if policy == "block" else "flag"

    result = {
        "verdict": verdict,
        "reuse_pct": pct,
        "suspected_duplicates": suspected,
        "residual": residual,
        "flags": flags,
        "summary": _gate_summary(verdict, pct, residual, floor),
    }

    # TEAM LENS (opt-in, WARN-ONLY): a teammate's active claim overlapping this change is a
    # coordination signal, never a hard duplicate. Emitted AFTER the verdict is fixed so it
    # provably cannot block. OFF by default → no team_signals key (solo path byte-identical).
    if team_lens:
        signals = _team_gate_signals(my_haid, changed_files, changed_surfaces,
                                     repo_root=repo_root, now=now)
        result["team_signals"] = signals
        flags.extend(signals)  # visible in the flags list, but WARN so verdict is untouched
    return result


def _reuse_field(attestation):
    """Accept either a full SI-2 record (with a top-level `reuse` field) or the
    reuse sub-dict directly. Returns the reuse dict (never raises — an absent field
    yields an empty dict so the gate degrades to 'ok' rather than crashing)."""
    if not isinstance(attestation, dict):
        return {}
    if "reuse" in attestation and isinstance(attestation["reuse"], dict):
        return attestation["reuse"]
    # already the reuse sub-dict?
    if "reuse_pct" in attestation or "suspected_duplicates" in attestation:
        return attestation
    return {}


def _name_existing(dup_name, index):
    """Resolve a suspected-duplicate symbol name to the existing repo unit (file +
    kind + span) via the dedup index, or a minimal {name} when not found / no
    index. This turns SI-2's bare name into an actionable 'reuse THIS at file:line'."""
    if not dup_name:
        return None
    if index is None:
        return {"name": dup_name}
    cands = dedup.match_candidates(dup_name, index, max_results=1)
    if cands:
        u = cands[0]["unit"]
        return {"name": u["name"], "kind": u.get("kind"), "file": u.get("file"),
                "span": u.get("span")}
    return {"name": dup_name}


def _rn_residual(changed_files, repo_files, index, already_suspected):
    """Find RN/MMKV reuse units in the CHANGED files that duplicate an EXISTING
    repo unit (matched via the shared dedup core). Excludes any name already named
    in SI-2's suspected_duplicates (no double-reporting). Returns residual rows."""
    out = []
    suspected_names = {d.get("duplicates") for d in (already_suspected or [])}
    suspected_names |= {d.get("new_unit") for d in (already_suspected or [])}
    seen = set()
    for path, src in changed_files.items():
        if reuse.is_test_path(path):
            continue
        for ru in dedup.rn_units(src, path):
            cands = dedup.match_candidates(ru, index, max_results=1)
            if not cands:
                continue
            top = cands[0]
            existing_file = top["unit"].get("file")
            # a unit "duplicating" a unit in the SAME changed file at the same spot
            # is itself, not a duplicate — require the match to live elsewhere OR a
            # different definition site.
            if existing_file == path and top["match"].startswith("name"):
                # same file: only treat as residual if it's a second definition.
                if _single_definition(src, ru):
                    continue
            if ru.name in suspected_names:
                continue
            key = (ru.kind, ru.name, existing_file)
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "new_unit": ru.name,
                "duplicates": top["unit"]["name"],
                "existing": {"name": top["unit"]["name"], "kind": top["unit"].get("kind"),
                             "file": existing_file, "span": top["unit"].get("span")},
                "reason": "new %s %r duplicates existing %s (%s)"
                          % (ru.kind, ru.name, top["unit"].get("kind"), top["reason"]),
            })
    return out


def _single_definition(src, ru):
    """True if `ru`'s key/name appears only once as a definition in `src` (so a
    same-file match is the unit itself, not a duplicate within the file)."""
    key = ru.detail.get("key") or ru.name
    return src.count(key) <= 1


def _gate_summary(verdict, pct, residual, floor):
    pct_s = "n/a" if pct is None else "%.0f%%" % (pct * 100)
    if verdict == "ok":
        return "redum gate: OK (reuse=%s, no residual duplicates)" % pct_s
    n = len(residual)
    return ("redum gate: %s — reuse=%s, %d residual duplicate%s "
            "(floor=%.0f%%)" % (verdict.upper(), pct_s, n,
                                "" if n == 1 else "s", floor * 100))


def _change_surfaces(changed_files, changed_surfaces):
    """The surfaces this change touches. Explicit `changed_surfaces` wins; else derive them
    from the changed-file PATHS (a file-level surface is enough to detect a teammate overlap
    via the shared file-prefix overlap engine)."""
    if changed_surfaces:
        return [str(s) for s in changed_surfaces]
    if not changed_files:
        return []
    return sorted({str(p) for p in changed_files})


def _team_gate_signals(my_haid, changed_files, changed_surfaces, repo_root=None, now=None):
    """WARN-ONLY team residual signals: for each surface this change touches, if a DIFFERENT
    teammate holds an ACTIVE claim over an overlapping surface, emit a warn signal naming the
    teammate. Reuses checkpoint_share's surface-overlap engine (the SAME rule the claim ledger
    uses) — never a new collision rule. Read-only, team-isolation-safe, and by construction
    level 'warn' so it can never block a commit."""
    signals = []
    if _cp is None:
        return signals
    surfaces = _change_surfaces(changed_files, changed_surfaces)
    if not surfaces:
        return signals
    active = _read_active_claims(my_haid, repo_root=repo_root, now=now)
    seen = set()
    for haid, claim in sorted(active.items()):
        held = [str(s) for s in (claim.get("claimed_surfaces") or [])]
        for req in surfaces:
            for h in held:
                if not _cp._surfaces_overlap(req, h):  # noqa: SLF001 — intentional reuse
                    continue
                key = (haid, req, h)
                if key in seen:
                    continue
                seen.add(key)
                human = claim.get("human") or _cp.haid_human(haid)
                signals.append({
                    "level": "warn",
                    "code": "team-residual-duplicate",
                    "haid": haid,
                    "human": human,
                    "surface": req,
                    "overlaps": h,
                    "detail": ("%s holds an ACTIVE claim on %s overlapping this change's %s — "
                               "coordinate/reuse, do NOT reinvent (WARN only, not a block)"
                               % (human, h, req)),
                })
    return signals


# ── CROSS-PROJECT SYMBOL REUSE (ponytail rung-2: "already exists? reuse it") ────
#
# The mechanical embodiment of the lazy-ladder's rung 2. The team lens above asks
# "is a TEAMMATE building this?"; this asks the code-only question one rung earlier:
# "does this SAME symbol already exist SOMEWHERE ELSE in the project?" — and routes
# the author to the canonical definition instead of a parallel copy.
#
# It builds a PROJECT-WIDE SYMBOL INDEX (functions, classes/types, dataclasses/
# TypedDicts/structs, module-level constants — Python via the real ast; shell
# functions heuristically) keyed by name + signature/shape + defining module, then
# classifies each PROPOSED new symbol against it:
#
#   EXACT-DUP-ONLY BLOCK (exit-3, mirrors redum's hard local-dup gate):
#     • a new FUNCTION with the SAME name AND SAME signature as a project function
#       in a DIFFERENT module.
#     • a new TYPE with the SAME name AND identical field SHAPE as a project type
#       in a DIFFERENT module.
#     These are unambiguous re-declarations of one canonical symbol → hard block.
#
#   ADVISE / WARN (surface the canonical import, never block — false-positive risk
#   from shadowing / generics / legitimate parallel domains):
#     • a type whose FIELDS match an existing type but under a DIFFERENT name
#       (structural equivalence).
#     • a function sharing a name but with a DIFFERENT signature (likely the same
#       capability under drift), or a near-duplicate name.
#     • a re-defined module-level constant/object.
#
# It REUSES redum's existing analysis substrate rather than rebuilding it: the
# dedup name normalizer (dedup.normalize) and the SHARED ignore set (reuse.is_test_
# path) that already scopes reuse to production code. Test fixtures, vendored, and
# generated trees are neither indexed as canonical nor checked as proposals. An
# explicit opt-out marker on a symbol (a deliberate, justified local copy) is
# honored — that symbol is allowed unconditionally.
#
# This is the code∪code half of rung-2; the team lens above is the code∪work half.

# an author's explicit "this local copy is deliberate" marker (comment or decorator
# above/inside the symbol). Honors the ponytail carve-out: a justified copy is not a
# violation. Matches `redum: allow-duplicate`, `redum-allow-duplicate`,
# `redum: allow-local-copy`, `@redum_allow_duplicate`, etc.
_OPTOUT_RX = re.compile(
    r"redum[\s:_\-]*allow[\s_\-]*(?:duplicate|local[\s_\-]*copy)", re.I)

# vendored / generated trees: NOT the project's own canonical reuse surface.
_VENDOR_RX = re.compile(
    r"(^|/)(node_modules|bower_components|vendor|vendored|third[_-]?party|external|"
    r"\.venv|venv|site-packages|dist|build|out|target|generated|__generated__|\.gen)(/|$)")
_GENERATED_FILE_RX = re.compile(
    r"(\.generated\.[A-Za-z0-9]+$|_generated\.[A-Za-z0-9]+$|_pb2\.py$|\.pb\.go$|"
    r"\.g\.dart$|\.min\.js$|\.bundle\.js$)")

# symbol families the reuse decision groups by (a function never dedups a type).
_FN_FAMILY = frozenset({"function", "shell-function", "method"})
_TYPE_FAMILY = frozenset({"type", "class", "interface", "enum", "component"})
_CONST_FAMILY = frozenset({"const"})

# the new symbol-reuse hard block exits 3 (distinct from the SI-2 residual gate's
# exit-1), so a CI/hook can tell a cross-project re-declaration from a low-reuse flag.
SYMBOL_REUSE_BLOCK_EXIT = 3


def _is_ignored_symbol_path(path):
    """A path whose symbols are NOT the project's canonical reuse surface: test /
    spec / fixture files (via reuse.is_test_path — the SHARED ignore set redum
    already scopes reuse with), plus vendored and generated trees. Symbols here are
    neither indexed as canonical nor checked as proposals."""
    norm = str(path).replace("\\", "/")
    if reuse.is_test_path(norm):
        return True
    if _VENDOR_RX.search(norm):
        return True
    return bool(_GENERATED_FILE_RX.search(norm))


class SymbolRecord:
    """One declared symbol in the project index: name + shape + defining module.

      name      — the canonical identifier a caller would reuse.
      kind      — function | shell-function | method | type | const | (raw dedup kind).
      module    — the file the symbol is defined in.
      sig       — for a function: the ordered parameter list (or [] for a shell fn).
                  None when the language yields no signature (never exact-blocks).
      fields    — for a type: the declared field/attribute names. None otherwise.
      value     — for a const: the source repr of its value. None otherwise.
      optout    — True when the author marked this a deliberate local copy.
    """

    __slots__ = ("name", "kind", "module", "sig", "fields", "value",
                 "line", "end_line", "optout")

    def __init__(self, name, kind, module, sig=None, fields=None, value=None,
                 line=None, end_line=None, optout=False):
        self.name = name
        self.kind = kind
        self.module = module
        self.sig = sig
        self.fields = fields
        self.value = value
        self.line = line
        self.end_line = end_line
        self.optout = optout

    @property
    def family(self):
        if self.kind in _FN_FAMILY:
            return "function"
        if self.kind in _TYPE_FAMILY:
            return "type"
        if self.kind in _CONST_FAMILY:
            return "const"
        return "other"

    def shape(self):
        """A stable canonical shape string for exact-match comparison within a family:
        a function's parameter list, a type's sorted field set, a const's value repr."""
        fam = self.family
        if fam == "function":
            return "(" + ",".join(self.sig or []) + ")"
        if fam == "type":
            return "{" + ",".join(sorted(self.fields or [])) + "}"
        if fam == "const":
            return "=" + (self.value if self.value is not None else "?")
        return ""

    def to_dict(self):
        d = {"name": self.name, "kind": self.kind, "module": self.module,
             "family": self.family, "shape": self.shape()}
        if self.optout:
            d["optout"] = True
        return d


def _optout_near(lines, node_line, node_end):
    """True when the opt-out marker appears in/just-above a symbol's source span (its
    decorators, a leading comment, or its body)."""
    lo = max(0, (node_line or 1) - 3)
    hi = min(len(lines), (node_end or node_line or 1))
    window = "\n".join(lines[lo:hi])
    return bool(_OPTOUT_RX.search(window))


def _py_symbol_records(src, path):
    """Extract module-level Python symbols (real ast): functions (with signatures),
    classes/dataclasses/TypedDicts (with field shapes), module-level constants."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    lines = src.splitlines()
    out = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            a = node.args
            params = [p.arg for p in list(a.posonlyargs) + list(a.args)]
            params += [p.arg for p in a.kwonlyargs]
            if a.vararg:
                params.append("*" + a.vararg.arg)
            if a.kwarg:
                params.append("**" + a.kwarg.arg)
            out.append(SymbolRecord(
                node.name, "function", path, sig=params, line=node.lineno,
                end_line=getattr(node, "end_lineno", node.lineno),
                optout=_optout_near(lines, node.lineno,
                                    getattr(node, "end_lineno", node.lineno))))
        elif isinstance(node, ast.ClassDef):
            fields = []
            for stmt in node.body:
                if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
                    fields.append(stmt.target.id)
                elif isinstance(stmt, ast.Assign):
                    for t in stmt.targets:
                        if isinstance(t, ast.Name):
                            fields.append(t.id)
            out.append(SymbolRecord(
                node.name, "type", path, fields=fields, line=node.lineno,
                end_line=getattr(node, "end_lineno", node.lineno),
                optout=_optout_near(lines, node.lineno,
                                    getattr(node, "end_lineno", node.lineno))))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            value = None
            if getattr(node, "value", None) is not None:
                try:
                    value = ast.unparse(node.value)
                except Exception:  # noqa: BLE001 — unparse is best-effort metadata
                    value = None
            for t in targets:
                if isinstance(t, ast.Name):
                    out.append(SymbolRecord(
                        t.id, "const", path, value=value, line=node.lineno,
                        end_line=getattr(node, "end_lineno", node.lineno),
                        optout=_optout_near(lines, node.lineno,
                                            getattr(node, "end_lineno", node.lineno))))
    return out


_SH_FUNC_RX = re.compile(
    r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"
    r"|^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{")


def _sh_symbol_records(src, path):
    """Heuristic shell-function extraction: `name() {` and `function name {`. Shell
    carries no signature, so shell functions can exact-block only another shell
    function of the SAME name (sig=[] → shape "()")."""
    out = []
    lines = src.splitlines()
    for m in _SH_FUNC_RX.finditer(src):
        name = m.group(1) or m.group(2)
        ln = src.count("\n", 0, m.start()) + 1
        out.append(SymbolRecord(name, "shell-function", path, sig=[], line=ln,
                                optout=_optout_near(lines, ln, ln)))
    return out


def _symbol_records_for(path, src):
    """All indexable symbol records in one file, or [] when the path is ignored
    (test/fixture/vendored/generated). Python + shell natively; other languages fall
    back to the dedup name+kind units (no signature → advise-only, never exact-block)."""
    if _is_ignored_symbol_path(path):
        return []
    lang = reuse.detect_language(path)
    if lang == "py":
        return _py_symbol_records(src, path)
    if lang in ("sh", "sh_maybe"):
        return _sh_symbol_records(src, path)
    recs = []
    for u in dedup.index_repo_units({path: src}):
        if u.kind in _TYPE_FAMILY:
            kind = "type"
        elif u.kind in _CONST_FAMILY:
            kind = "const"
        elif u.kind in _FN_FAMILY:
            kind = "function"
        else:
            continue  # rn-slice / rn-selector / mmkv-key are the SI-2 gate's job.
        # no signature/fields available cross-language → advise-only shape.
        recs.append(SymbolRecord(u.name, kind, path))
    return recs


def build_symbol_index(repo_files):
    """Build the PROJECT-WIDE symbol index over {path: source}. Skips ignored paths
    (test/fixture/vendored/generated). Returns list[SymbolRecord]."""
    index = []
    for path, src in (repo_files or {}).items():
        index.extend(_symbol_records_for(path, src))
    return index


def _import_hint(sym):
    """A copy-pasteable pointer to the canonical symbol's import site."""
    mod = str(sym.module)
    lang = reuse.detect_language(mod)
    if lang == "py":
        dotted = re.sub(r"\.py$", "", mod).replace("/", ".").strip(".")
        return "from %s import %s" % (dotted, sym.name)
    if lang in ("sh", "sh_maybe"):
        return "source %s  # then call %s()" % (mod, sym.name)
    return "reuse %s from %s" % (sym.name, mod)


def _pick_canonical(cands, proposed):
    """Deterministically choose the canonical to route to: the smallest (module, name)
    among candidates in a DIFFERENT module than the proposal (a symbol never dedups
    against itself)."""
    xs = sorted((c for c in cands if c.module != proposed.module),
                key=lambda c: (str(c.module), str(c.name)))
    return xs[0] if xs else None


def _reason_for(proposed, canonical, klass):
    verb = {"exact-function": "re-declares the existing function",
            "exact-type": "re-declares the existing type",
            "structural-type": "has the same fields as the existing type",
            "same-name-function": "shares a name with the existing function",
            "same-name-type": "shares a name with the existing type",
            "const-redef": "re-defines the existing constant"}.get(klass, "duplicates")
    return ("proposed %s %r %s %r in %s — reuse the canonical, do not re-declare it"
            % (proposed.family, proposed.name, verb, canonical.name, canonical.module))


def _finding(proposed, canonical, level, klass):
    return {
        "proposed": proposed.name,
        "proposed_module": proposed.module,
        "kind": proposed.kind,
        "family": proposed.family,
        "level": level,          # "block" | "warn"
        "class": klass,
        "canonical": {"name": canonical.name, "module": canonical.module,
                      "kind": canonical.kind, "shape": canonical.shape()},
        "import_hint": _import_hint(canonical),
        "reason": _reason_for(proposed, canonical, klass),
    }


def _classify_symbol(proposed, by_norm, type_by_fields):
    """Classify ONE proposed symbol against the canonical index. Returns a finding
    dict (level block|warn) or None when the symbol is unique/allowed (→ ok).
    Precedence: opt-out > exact-block > structural/near/const advise > unique."""
    if proposed.optout:
        return None  # a deliberate, justified local copy — allowed unconditionally.
    nn = dedup.normalize(proposed.name)
    same_name = by_norm.get(nn, [])

    if proposed.family == "function":
        # EXACT: same normalized name + identical signature, different module. Both
        # sides must carry a real signature (cross-language name-only units never block).
        exact = _pick_canonical(
            [c for c in same_name if c.family == "function"
             and c.sig is not None and proposed.sig is not None
             and c.shape() == proposed.shape()], proposed)
        if exact is not None:
            return _finding(proposed, exact, "block", "exact-function")
        near = _pick_canonical([c for c in same_name if c.family == "function"], proposed)
        if near is not None:
            return _finding(proposed, near, "warn", "same-name-function")
        return None

    if proposed.family == "type":
        exact = _pick_canonical(
            [c for c in same_name if c.family == "type"
             and c.fields and proposed.fields and c.shape() == proposed.shape()], proposed)
        if exact is not None:
            return _finding(proposed, exact, "block", "exact-type")
        # structural: identical field SHAPE under a DIFFERENT name.
        if proposed.fields:
            struct = _pick_canonical(
                [c for c in type_by_fields.get(proposed.shape(), []) if c.family == "type"],
                proposed)
            if struct is not None:
                return _finding(proposed, struct, "warn", "structural-type")
        same_type = _pick_canonical([c for c in same_name if c.family == "type"], proposed)
        if same_type is not None:
            return _finding(proposed, same_type, "warn", "same-name-type")
        return None

    if proposed.family == "const":
        c = _pick_canonical([c for c in same_name if c.family == "const"], proposed)
        if c is not None:
            return _finding(proposed, c, "warn", "const-redef")
        return None

    return None


def detect_symbol_reuse(proposed_files, repo_files, index=None):
    """Classify each PROPOSED new symbol against the PROJECT-WIDE canonical index.

    proposed_files: {path: source} of the NEW code being added.
    repo_files:     {path: source} of the EXISTING project (the canonical surface).
    index:          an optional pre-built index (build_symbol_index) to reuse.

    Returns {
      "verdict": "block" | "advise" | "ok",
      "blocked": [finding, ...],   # exact function/type duplication — HARD (exit-3)
      "advised": [finding, ...],   # structural/near/const — WARN, surface canonical
      "ok":      [{name, module}], # unique or opt-out-allowed
      "findings":[...all block+warn...],
      "summary": one-line human verdict,
    }
    Advise-default, exact-dup-only-block. Opt-out-marked and ignored-path symbols
    are never flagged."""
    if index is None:
        index = build_symbol_index(repo_files)
    by_norm = {}
    type_by_fields = {}
    for u in index:
        by_norm.setdefault(dedup.normalize(u.name), []).append(u)
        if u.family == "type" and u.fields:
            type_by_fields.setdefault(u.shape(), []).append(u)

    findings = []
    ok_rows = []
    for path, src in (proposed_files or {}).items():
        for proposed in _symbol_records_for(path, src):
            f = _classify_symbol(proposed, by_norm, type_by_fields)
            if f is None:
                ok_rows.append({"name": proposed.name, "module": proposed.module})
            else:
                findings.append(f)

    blocked = [f for f in findings if f["level"] == "block"]
    advised = [f for f in findings if f["level"] == "warn"]
    verdict = "block" if blocked else ("advise" if advised else "ok")
    ok_rows.sort(key=lambda r: (r["module"], r["name"]))
    return {
        "verdict": verdict,
        "blocked": blocked,
        "advised": advised,
        "ok": ok_rows,
        "findings": findings,
        "summary": _symbol_reuse_summary(verdict, blocked, advised),
    }


def _symbol_reuse_summary(verdict, blocked, advised):
    if verdict == "block":
        names = ", ".join(sorted({b["proposed"] for b in blocked}))
        return ("redum symbol-reuse: BLOCK — %d exact duplicate symbol(s) already exist "
                "project-wide (%s); reuse the canonical, do not re-declare"
                % (len(blocked), names))
    if verdict == "advise":
        names = ", ".join(sorted({a["proposed"] for a in advised}))
        return ("redum symbol-reuse: ADVISE — %d symbol(s) resemble existing project code "
                "(%s); consider reusing the canonical" % (len(advised), names))
    return "redum symbol-reuse: OK — no cross-project symbol duplication detected"


def symbol_reuse_exit_code(result):
    """The gate exit code for a detect_symbol_reuse result: exit-3 on a hard block
    (exact function/type re-declaration), else 0 (advise is WARN-only, never blocks)."""
    return SYMBOL_REUSE_BLOCK_EXIT if result.get("verdict") == "block" else 0
