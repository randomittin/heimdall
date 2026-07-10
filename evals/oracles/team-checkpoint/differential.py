#!/usr/bin/env python3
# differential.py — the SINGLE source of diff-truth for the team-checkpoint differential oracle.
#
# Neutral gate wiring: authored by neither the impl author nor the reference author. It imports
# BOTH the implementation fold (bin/lib/checkpoint_share.fold_stream) and the INDEPENDENT
# reference fold (reference.fold), normalizes each to a common comparable partition, and DIFFS
# them. run.sh + gate.sh are thin wrappers over the subcommands here; bin/falsify orchestrates
# run.sh and never re-implements this diff (REPORT-CONTRACT).
#
# THE COMPARABLE PARTITION (INVARIANTS.md INV-G):
#     {
#       "served":            sorted list of roster rows (INV-G row order, keyed by HAID),
#       "excluded_security": int (INV-C security-exclusion count),
#     }
# PASS iff impl == reference on this partition, over every seed / fixture. A per-record property
# check passes a whole-aggregate bug (a dropped / duplicated / misattributed teammate); this
# whole-partition differential catches that class — which is why the gate is `differential`.

from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
_LIB = os.path.join(_PLUGIN_ROOT, "bin", "lib")

for _p in (_HERE, _LIB):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import reference               # the INDEPENDENT reference (no bin/lib import).
import checkpoint_share        # the IMPLEMENTATION under test (bin/lib/).


# ── normalization to the comparable partition ─────────────────────────────────


def _norm(part):
    """Reduce a fold output to the comparable partition (served + excluded_security). Both folds
    already emit sorted str/int/bool-leaf rows, so this only drops the impl's extra `dropped`
    counter and re-sorts defensively."""
    served = [list(r) for r in part.get("served", [])]
    return {
        "served": sorted(served, key=lambda r: (str(r[0]), json.dumps(r, sort_keys=True))),
        "excluded_security": int(part.get("excluded_security", 0)),
    }


def impl_partition_of(stream):
    return _norm(checkpoint_share.fold_stream(stream, repo_root=_PLUGIN_ROOT))


def ref_partition_of(stream):
    return _norm(reference.fold(stream))


def _coerce_partition(part):
    """Coerce a fixture-authored `corrupted` partition into the canonical comparable shape so it
    diffs byte-for-byte against a normalized reference partition."""
    served = [list(r) for r in part.get("served", [])]
    return {
        "served": sorted(served, key=lambda r: (str(r[0]), json.dumps(r, sort_keys=True))),
        "excluded_security": int(part.get("excluded_security", 0)),
    }


# ── the diff: first-divergence pinpoint over the comparable partition ─────────


def diff_partitions(ref_part, subj_part):
    """Diff the reference partition (truth) against the subject partition. Returns
    (ok, first_divergence): served bucket set first, then the security-exclusion count."""
    rs, ss = ref_part.get("served", []), subj_part.get("served", [])
    if rs != ss:
        n = max(len(rs), len(ss))
        for i in range(n):
            a = rs[i] if i < len(rs) else None
            b = ss[i] if i < len(ss) else None
            if a != b:
                return False, {
                    "step": "served roster set (index %d of %d/%d)" % (i, len(rs), len(ss)),
                    "expected": json.dumps(a, sort_keys=True),
                    "actual": json.dumps(b, sort_keys=True),
                }
    re_, se_ = int(ref_part.get("excluded_security", 0)), int(subj_part.get("excluded_security", 0))
    if re_ != se_:
        return False, {
            "step": "excluded_security count",
            "expected": str(re_),
            "actual": str(se_),
        }
    return True, None


# ── fixture grading (what run.sh drives) ──────────────────────────────────────


def _load_stream(fixture):
    if isinstance(fixture.get("stream"), list):
        return fixture["stream"]
    if "seed" in fixture:
        return reference.generate_stream(int(fixture["seed"]),
                                         n_records=int(fixture.get("records", 24)))
    return None


def grade_fixture(fixture):
    """Grade one fixture -> (status, first_divergence, metrics).

    kind == "differential" (the golden): fold the SAME stream/seeds through the IMPL and the
        REFERENCE, normalize both, diff. status=pass iff they agree — the impl-vs-reference
        correctness proof.
    kind == "mutant": the fixture carries a `stream` + a `corrupted` partition (what a buggy
        impl would emit, breaking ONE invariant). The gate recomputes the CORRECT partition from
        the stream via the INDEPENDENT reference and diffs it against `corrupted`. A genuine
        defect diverges -> status=fail -> the mutant is KILLED."""
    kind = fixture.get("kind")

    if kind == "differential":
        seeds = fixture.get("seeds")
        if isinstance(seeds, list) and seeds:
            compared = 0
            for seed in seeds:
                stream = reference.generate_stream(int(seed),
                                                   n_records=int(fixture.get("records", 24)))
                ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
                compared += len(ref_part["served"])
                ok, div = diff_partitions(ref_part, subj_part)
                if not ok:
                    div = dict(div, step="seed %s — %s" % (seed, div["step"]))
                    return "fail", div, {"seeds_swept": len(seeds), "rows_compared": compared,
                                         "arm": "impl-vs-reference-differential"}
            return "pass", None, {"seeds_swept": len(seeds), "rows_compared": compared,
                                  "arm": "impl-vs-reference-differential"}
        stream = _load_stream(fixture)
        if stream is None:
            return "error", {"step": "fixture", "expected": "a stream/seed(s)",
                             "actual": "neither stream, seed, nor seeds"}, {"arm": "differential"}
        ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
        compared = len(ref_part["served"]) + ref_part["excluded_security"]
        if compared == 0:
            return "error", {"step": "empty partition",
                             "expected": "at least one served or excluded record",
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
        ref_part = ref_partition_of(stream)
        subj_part = _coerce_partition(corrupted)
        compared = len(ref_part["served"]) + ref_part["excluded_security"]
        if compared == 0:
            return "error", {"step": "empty reference partition",
                             "expected": "at least one record in the correct partition",
                             "actual": "zero"}, {"rows_compared": 0, "arm": "differential-mutant"}
        ok, div = diff_partitions(ref_part, subj_part)
        return ("pass" if ok else "fail"), (None if ok else div), \
               {"rows_compared": compared, "arm": "differential-mutant"}

    return "error", {"step": "fixture kind", "expected": "differential|mutant",
                     "actual": json.dumps(kind)}, {"arm": "unknown"}


def sweep_seeds(n_seeds, start=1, records=24):
    """The seeded impl-vs-reference differential sweep (the registry gate_command arm)."""
    compared = 0
    for seed in range(start, start + n_seeds):
        stream = reference.generate_stream(seed, n_records=records)
        ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
        compared += len(ref_part["served"])
        ok, div = diff_partitions(ref_part, subj_part)
        if not ok:
            div = dict(div, step="seed %d — %s" % (seed, div["step"]))
            return False, div, {"seeds_swept": seed - start + 1, "rows_compared": compared,
                                "arm": "seeded-differential"}
    return True, None, {"seeds_swept": n_seeds, "rows_compared": compared, "arm": "seeded-differential"}


# ── CLI ────────────────────────────────────────────────────────────────────────


def _build_parser():
    p = argparse.ArgumentParser(prog="differential.py",
                                description="team-checkpoint differential diff-truth")
    sub = p.add_subparsers(dest="command")
    s = sub.add_parser("sweep")
    s.add_argument("--seeds", type=int, default=200)
    s.add_argument("--start", type=int, default=1)
    s.add_argument("--records", type=int, default=24)
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
