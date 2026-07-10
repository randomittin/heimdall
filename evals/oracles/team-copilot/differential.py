#!/usr/bin/env python3
# differential.py — the SINGLE source of diff-truth for the team-copilot differential oracle
# (the REDUM TEAM-LENS arm: the code∪work bridge).
#
# Neutral gate wiring. It imports BOTH the REAL implementation (bin/lib/redum.py's team lens,
# driven over a real on-disk ledger) and the INDEPENDENT reference fold (reference.fold),
# normalizes each to a common comparable partition, and DIFFS them. run.sh + gate.sh are thin
# wrappers over the subcommands here; bin/falsify orchestrates run.sh and never re-implements
# this diff (REPORT-CONTRACT).
#
# THE COMPARABLE PARTITION (INVARIANTS.md RT-PART):
#     {"candidates": sorted list of [surface, haid, human, class, adoptable] rows}
# PASS iff impl == reference on this partition, over every seed / fixture. A per-record property
# check ("each surfaced candidate is valid") passes a whole-aggregate bug — a cross-team row
# leaking in (RT-ISO), a dropped-teammate row (RT-DROP), a reaped surface misclassified as
# in-flight instead of adoptable (RT-CLASS), or a teammate's goal prose leaked into a candidate
# field (RT-LEAK). This whole-partition differential catches that class — hence gate_type
# `differential`.
#
# THE IMPL ARM IS THE REAL DISK PATH. For each seed the harness materializes the teammate
# work-states as REAL claim + checkpoint files under a temp planning dir (mine) — and any
# cross-team record under a SEPARATE planning dir the lens is never pointed at — then calls the
# shipped redum.factor_for_task(team_lens=True). So the impl arm exercises the actual TTL rule,
# the checkpoint-completed rule, and the store-boundary isolation, not a re-implementation.

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
_LIB = os.path.join(_PLUGIN_ROOT, "bin", "lib")

for _p in (_HERE, _LIB):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import reference               # the INDEPENDENT reference (no bin/lib import).
import redum                   # the IMPLEMENTATION under test (bin/lib/redum.py team lens).

# a fixed clock so the TTL math is hermetic across every seed.
_NOW = 1_800_000_000
_MY_HAID = "haid:oracle-self.box-0000"    # the reader; excluded from its own advice.


# ── materialize a stream onto a real ledger + fold it through the REAL lens ───


def _iso(epoch):
    import datetime
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)\
        .strftime("%Y-%m-%dT%H:%M:%SZ")


def _slug(haid):
    import re
    return re.sub(r"[/:]", "_", str(haid))


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)


def impl_partition_of(stream, task):
    """Drive the REAL redum team lens over a real on-disk ledger built from `stream`. mine-team
    records become claim/checkpoint files under the read planning dir; other-team records go to a
    SEPARATE planning dir the lens is never pointed at (RT-ISO by store boundary)."""
    root = tempfile.mkdtemp(prefix="team-copilot.")
    mine = os.path.join(root, "mine", ".planning")
    other = os.path.join(root, "other", ".planning")
    os.makedirs(os.path.join(mine, "ledger", "claims"), exist_ok=True)
    os.makedirs(os.path.join(mine, "ledger", "checkpoints"), exist_ok=True)
    os.makedirs(os.path.join(other, "ledger", "claims"), exist_ok=True)
    os.makedirs(os.path.join(other, "ledger", "checkpoints"), exist_ok=True)

    prev_env = os.environ.pop("HEIMDALL_PLANNING_DIR", None)
    try:
        for rec in stream:
            plan = mine if str(rec.get("team", "mine")) == "mine" else other
            haid = str(rec["haid"])
            surface = str(rec["surface"])
            active = bool(rec.get("claim_active"))
            has_ckpt = bool(rec.get("has_checkpoint"))
            # a claim exists whenever the record models a claim (active OR reaped/expired);
            # in-flight => fresh heartbeat, dropped => a heartbeat past its TTL window.
            if active or (has_ckpt and not active):
                hb = _NOW - 60 if active else _NOW - 7200
                _write_json(os.path.join(plan, "ledger", "claims", _slug(haid) + ".json"), {
                    "haid": haid, "human": rec.get("human"),
                    "claimed_surfaces": [surface], "task_ref": "t",
                    "claimed_at": _iso(hb), "ttl_minutes": 60, "heartbeat": _iso(hb),
                })
            if has_ckpt:
                _write_json(os.path.join(plan, "ledger", "checkpoints", _slug(haid) + ".json"), {
                    "schema": "team_checkpoint_v1", "haid": haid, "human": rec.get("human"),
                    "branch": rec.get("branch"), "head_sha": "abc1234",
                    "phase": rec.get("phase"), "progress_pct": rec.get("progress_pct", 0),
                    # the teammate's private goal is stored — the lens MUST NOT surface it.
                    "active_goal": rec.get("active_goal", "[private]"),
                    "claimed_surfaces": [surface], "task_ref": "t",
                    "updated_at": _iso(_NOW), "resumable": True,
                })
        res = redum.factor_for_task(task, {}, team_lens=True, my_haid=_MY_HAID,
                                    repo_root=os.path.join(root, "mine"), now=_NOW)
        rows = [[c["surface"], c["haid"], c["human"], c["class"], bool(c["adoptable"])]
                for c in res.get("team_candidates", [])]
        return _norm({"candidates": rows})
    finally:
        if prev_env is not None:
            os.environ["HEIMDALL_PLANNING_DIR"] = prev_env
        shutil.rmtree(root, ignore_errors=True)


# ── normalization to the comparable partition ─────────────────────────────────


def _norm(part):
    rows = [list(r) for r in part.get("candidates", [])]
    return {"candidates": sorted(rows, key=lambda r: json.dumps(r, sort_keys=True))}


def ref_partition_of(stream, task):
    return _norm(reference.fold(stream, task=task))


# ── the diff: first-divergence pinpoint over the comparable partition ─────────


def diff_partitions(ref_part, subj_part):
    rs, ss = ref_part.get("candidates", []), subj_part.get("candidates", [])
    if rs != ss:
        n = max(len(rs), len(ss))
        for i in range(n):
            a = rs[i] if i < len(rs) else None
            b = ss[i] if i < len(ss) else None
            if a != b:
                return False, {
                    "step": "team-candidate roster (index %d of %d/%d)" % (i, len(rs), len(ss)),
                    "expected": json.dumps(a, sort_keys=True),
                    "actual": json.dumps(b, sort_keys=True),
                }
    return True, None


# ── fixture grading (what run.sh drives) ──────────────────────────────────────


def _load_stream(fixture):
    if isinstance(fixture.get("stream"), list):
        return fixture["stream"]
    if "seed" in fixture:
        return reference.generate_stream(int(fixture["seed"]),
                                         n_records=int(fixture.get("records", 12)))
    return None


def grade_fixture(fixture):
    """Grade one fixture -> (status, first_divergence, metrics).

    kind == "differential" (the golden): fold the SAME stream/seeds through the REAL impl lens
        AND the reference, normalize both, diff. status=pass iff they agree.
    kind == "mutant": the fixture carries a `stream` + a `corrupted` partition (what a buggy lens
        would emit, breaking ONE invariant). Recompute the CORRECT partition from the stream via
        the INDEPENDENT reference and diff against `corrupted`. A genuine defect diverges ->
        status=fail -> the mutant is KILLED."""
    kind = fixture.get("kind")

    if kind == "differential":
        seeds = fixture.get("seeds")
        records = int(fixture.get("records", 12))
        if isinstance(seeds, list) and seeds:
            compared = 0
            for seed in seeds:
                stream = reference.generate_stream(int(seed), n_records=records)
                task = reference.task_for(stream)
                ref_part, subj_part = ref_partition_of(stream, task), impl_partition_of(stream, task)
                compared += len(ref_part["candidates"])
                ok, div = diff_partitions(ref_part, subj_part)
                if not ok:
                    div = dict(div, step="seed %s — %s" % (seed, div["step"]))
                    return "fail", div, {"seeds_swept": len(seeds), "rows_compared": compared,
                                         "arm": "impl-vs-reference-differential"}
            if compared == 0:
                return "error", {"step": "empty partition", "expected": "≥1 candidate",
                                 "actual": "zero"}, {"rows_compared": 0, "arm": "differential"}
            return "pass", None, {"seeds_swept": len(seeds), "rows_compared": compared,
                                  "arm": "impl-vs-reference-differential"}
        stream = _load_stream(fixture)
        if stream is None:
            return "error", {"step": "fixture", "expected": "a stream/seed(s)",
                             "actual": "neither stream, seed, nor seeds"}, {"arm": "differential"}
        task = reference.task_for(stream)
        ref_part, subj_part = ref_partition_of(stream, task), impl_partition_of(stream, task)
        compared = len(ref_part["candidates"])
        if compared == 0:
            return "error", {"step": "empty partition", "expected": "≥1 candidate",
                             "actual": "zero"}, {"rows_compared": 0, "arm": "differential"}
        ok, div = diff_partitions(ref_part, subj_part)
        return ("pass" if ok else "fail"), (None if ok else div), \
               {"rows_compared": compared, "arm": "impl-vs-reference-differential"}

    if kind == "mutant":
        stream = _load_stream(fixture)
        corrupted = fixture.get("corrupted")
        if stream is None or not isinstance(corrupted, dict):
            return "error", {"step": "fixture", "expected": "a stream and a corrupted partition",
                             "actual": "missing stream or corrupted"}, {"arm": "differential-mutant"}
        task = fixture.get("task") or reference.task_for(stream)
        ref_part = ref_partition_of(stream, task)
        subj_part = _norm(corrupted)
        compared = len(ref_part["candidates"])
        if compared == 0:
            return "error", {"step": "empty reference partition",
                             "expected": "≥1 candidate in the correct partition",
                             "actual": "zero"}, {"rows_compared": 0, "arm": "differential-mutant"}
        ok, div = diff_partitions(ref_part, subj_part)
        return ("pass" if ok else "fail"), (None if ok else div), \
               {"rows_compared": compared, "arm": "differential-mutant"}

    return "error", {"step": "fixture kind", "expected": "differential|mutant",
                     "actual": json.dumps(kind)}, {"arm": "unknown"}


def sweep_seeds(n_seeds, start=1, records=12):
    """The seeded impl-vs-reference differential sweep (the registry gate_command arm)."""
    compared = 0
    for seed in range(start, start + n_seeds):
        stream = reference.generate_stream(seed, n_records=records)
        task = reference.task_for(stream)
        ref_part, subj_part = ref_partition_of(stream, task), impl_partition_of(stream, task)
        compared += len(ref_part["candidates"])
        ok, div = diff_partitions(ref_part, subj_part)
        if not ok:
            div = dict(div, step="seed %d — %s" % (seed, div["step"]))
            return False, div, {"seeds_swept": seed - start + 1, "rows_compared": compared,
                                "arm": "seeded-differential"}
    return True, None, {"seeds_swept": n_seeds, "rows_compared": compared, "arm": "seeded-differential"}


# ── CLI ────────────────────────────────────────────────────────────────────────


def _build_parser():
    p = argparse.ArgumentParser(prog="differential.py",
                                description="team-copilot (redum team-lens) differential diff-truth")
    sub = p.add_subparsers(dest="command")
    s = sub.add_parser("sweep")
    s.add_argument("--seeds", type=int, default=200)
    s.add_argument("--start", type=int, default=1)
    s.add_argument("--records", type=int, default=12)
    g = sub.add_parser("grade")
    g.add_argument("--input", required=True)
    return p


def main(argv=None):
    args = _build_parser().parse_args(argv)
    if args.command == "sweep":
        ok, div, metrics = sweep_seeds(args.seeds, start=args.start, records=args.records)
        print(json.dumps({"status": "pass" if ok else "fail", "first_divergence": div,
                          "metrics": metrics}, sort_keys=True))
        return 0 if ok else 1
    if args.command == "grade":
        with open(args.input, "r", encoding="utf-8") as fh:
            fixture = json.load(fh)
        status, div, metrics = grade_fixture(fixture)
        print(json.dumps({"status": status, "first_divergence": div, "metrics": metrics},
                         sort_keys=True))
        return 0 if status == "pass" else (2 if status == "error" else 1)
    _build_parser().print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
