#!/usr/bin/env python3
# differential.py — the SINGLE source of diff-truth for the symbol-reuse differential oracle.
#
# Neutral gate wiring: authored by neither the impl author nor the reference author. It imports
# BOTH the implementation detector (bin/lib/redum.detect_symbol_reuse) and the INDEPENDENT
# reference fold (reference.fold), normalizes each to a common comparable partition, and DIFFS
# them. run.sh + gate.sh are thin wrappers over the subcommands here; bin/falsify orchestrates
# run.sh and never re-implements this diff (REPORT-CONTRACT).
#
# THE IMPL ARM. The stream is a set of ABSTRACT symbol declarations. This wiring SYNTHESIZES
# real source files from them (a function record -> a `def` with those params; a type record ->
# a `class` with those field attrs; a const record -> a module-level assignment) and feeds them
# to redum's detector — so the REAL production code path is exercised, not a mock. The reference
# classifies the same abstract records directly (it never sees source, imports nothing from
# bin/lib), so the two arms share no code.
#
# THE COMPARABLE PARTITION (INVARIANTS.md SR-G):
#     {
#       "blocked": sorted [ [proposed_tag, class, canonical_tag], ... ],
#       "advised": sorted [ [proposed_tag, class, canonical_tag], ... ],
#       "ok":      sorted [ proposed_tag, ... ],
#     }
# PASS iff impl == reference on this partition, over every seed / fixture. A per-symbol property
# check passes a whole-aggregate bug (a missed cross-file dup, a false-flagged unique); this
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
import redum                   # the IMPLEMENTATION under test (bin/lib/).


# ── synthesis: abstract symbol records -> real source files ───────────────────


def _fn_source(sym):
    params = ", ".join(sym.get("params") or [])
    marker = "# redum: allow-duplicate\n" if sym.get("optout") else ""
    return "%sdef %s(%s):\n    return None\n" % (marker, sym["name"], params)


def _type_source(sym):
    fields = sym.get("fields") or []
    body = "".join("    %s = None\n" % f for f in fields) or "    pass\n"
    marker = "# redum: allow-duplicate\n" if sym.get("optout") else ""
    return "%sclass %s:\n%s" % (marker, sym["name"], body)


def _const_source(sym):
    marker = "# redum: allow-duplicate\n" if sym.get("optout") else ""
    return "%s%s = %s\n" % (marker, sym["name"], sym.get("value", "0"))


def _source_for(sym):
    fam = reference.family(sym["kind"])
    if fam == "type":
        return _type_source(sym)
    if fam == "const":
        return _const_source(sym)
    return _fn_source(sym)


def synthesize(stream):
    """Build (proposed_files, repo_files) real-source maps from the abstract stream. One symbol
    per file (each record carries its own module path), so no accidental in-file collisions."""
    repo_files = {}
    for c in (stream.get("canonical") or []):
        repo_files[c["module"]] = _source_for(c)
    proposed_files = {}
    for p in (stream.get("proposed") or []):
        proposed_files[p["module"]] = _source_for(p)
    return proposed_files, repo_files


# ── normalization to the comparable partition ─────────────────────────────────


def _tag(name, module):
    return "%s@%s" % (name, module)


def impl_partition_of(stream):
    """Run redum's detector over synthesized source and reduce to the comparable partition."""
    proposed_files, repo_files = synthesize(stream)
    res = redum.detect_symbol_reuse(proposed_files, repo_files)
    blocked = [[_tag(f["proposed"], f["proposed_module"]), f["class"],
                _tag(f["canonical"]["name"], f["canonical"]["module"])]
               for f in res["blocked"]]
    advised = [[_tag(f["proposed"], f["proposed_module"]), f["class"],
                _tag(f["canonical"]["name"], f["canonical"]["module"])]
               for f in res["advised"]]
    ok = [_tag(r["name"], r["module"]) for r in res["ok"]]
    return _norm({"blocked": blocked, "advised": advised, "ok": ok})


def ref_partition_of(stream):
    return _norm(reference.fold(stream))


def _norm(part):
    """Sort each bucket into the canonical comparable shape (defensive re-sort)."""
    return {
        "blocked": sorted([list(r) for r in part.get("blocked", [])]),
        "advised": sorted([list(r) for r in part.get("advised", [])]),
        "ok": sorted([str(r) for r in part.get("ok", [])]),
    }


def _coerce_partition(part):
    """Coerce a fixture-authored `corrupted` partition into the canonical comparable shape so it
    diffs byte-for-byte against a normalized reference partition."""
    return _norm(part)


# ── the diff: first-divergence pinpoint over the comparable partition ─────────


def diff_partitions(ref_part, subj_part):
    """Diff the reference partition (truth) against the subject partition. Returns
    (ok, first_divergence): blocked bucket first (the hard gate), then advised, then ok."""
    for bucket in ("blocked", "advised", "ok"):
        rs, ss = ref_part.get(bucket, []), subj_part.get(bucket, [])
        if rs != ss:
            n = max(len(rs), len(ss))
            for i in range(n):
                a = rs[i] if i < len(rs) else None
                b = ss[i] if i < len(ss) else None
                if a != b:
                    return False, {
                        "step": "%s partition (index %d of %d/%d)" % (bucket, i, len(rs), len(ss)),
                        "expected": json.dumps(a, sort_keys=True),
                        "actual": json.dumps(b, sort_keys=True),
                    }
    return True, None


# ── fixture grading (what run.sh drives) ──────────────────────────────────────


def _load_stream(fixture):
    if isinstance(fixture.get("stream"), dict):
        return fixture["stream"]
    if "seed" in fixture:
        return reference.generate_stream(int(fixture["seed"]),
                                         records=int(fixture.get("records", 24)))
    return None


def _rows_compared(part):
    return len(part["blocked"]) + len(part["advised"]) + len(part["ok"])


def grade_fixture(fixture):
    """Grade one fixture -> (status, first_divergence, metrics).

    kind == "differential" (the golden): fold the SAME stream/seeds through the IMPL (synthesize
        + redum) and the REFERENCE, normalize both, diff. status=pass iff they agree.
    kind == "mutant": the fixture carries a `stream` + a `corrupted` partition (what a buggy impl
        would emit, breaking ONE invariant). The gate recomputes the CORRECT partition from the
        stream via the INDEPENDENT reference and diffs it against `corrupted`. A genuine defect
        diverges -> status=fail -> the mutant is KILLED."""
    kind = fixture.get("kind")

    if kind == "differential":
        seeds = fixture.get("seeds")
        records = int(fixture.get("records", 24))
        if isinstance(seeds, list) and seeds:
            compared = 0
            for seed in seeds:
                stream = reference.generate_stream(int(seed), records=records)
                ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
                compared += _rows_compared(ref_part)
                ok, div = diff_partitions(ref_part, subj_part)
                if not ok:
                    div = dict(div, step="seed %s — %s" % (seed, div["step"]))
                    return "fail", div, {"seeds_swept": len(seeds), "rows_compared": compared,
                                         "arm": "impl-vs-reference-differential"}
            return "pass", None, {"seeds_swept": len(seeds), "rows_compared": compared,
                                  "arm": "impl-vs-reference-differential"}
        stream = _load_stream(fixture)
        if not isinstance(stream, dict):
            return "error", {"step": "fixture", "expected": "a stream/seed(s)",
                             "actual": "neither stream, seed, nor seeds"}, {"arm": "differential"}
        ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
        compared = _rows_compared(ref_part)
        if compared == 0:
            return "error", {"step": "empty partition",
                             "expected": "at least one classified symbol",
                             "actual": "zero"}, {"rows_compared": 0, "arm": "differential"}
        ok, div = diff_partitions(ref_part, subj_part)
        return ("pass" if ok else "fail"), (None if ok else div), \
               {"rows_compared": compared, "arm": "impl-vs-reference-differential"}

    if kind == "mutant":
        stream = _load_stream(fixture)
        corrupted = fixture.get("corrupted")
        if not isinstance(stream, dict) or not isinstance(corrupted, dict):
            return "error", {"step": "fixture", "expected": "a stream and a corrupted partition",
                             "actual": "missing stream or corrupted"}, {"arm": "differential-mutant"}
        ref_part = ref_partition_of(stream)
        subj_part = _coerce_partition(corrupted)
        compared = _rows_compared(ref_part)
        if compared == 0:
            return "error", {"step": "empty reference partition",
                             "expected": "at least one classified symbol in the correct partition",
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
        stream = reference.generate_stream(seed, records=records)
        ref_part, subj_part = ref_partition_of(stream), impl_partition_of(stream)
        compared += _rows_compared(ref_part)
        ok, div = diff_partitions(ref_part, subj_part)
        if not ok:
            div = dict(div, step="seed %d — %s" % (seed, div["step"]))
            return False, div, {"seeds_swept": seed - start + 1, "rows_compared": compared,
                                "arm": "seeded-differential"}
    return True, None, {"seeds_swept": n_seeds, "rows_compared": compared, "arm": "seeded-differential"}


# ── CLI ────────────────────────────────────────────────────────────────────────


def _build_parser():
    p = argparse.ArgumentParser(prog="differential.py",
                                description="symbol-reuse differential diff-truth")
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
