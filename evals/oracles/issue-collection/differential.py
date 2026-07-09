#!/usr/bin/env python3
# differential.py — the SINGLE source of diff-truth for the issue-collection
# differential oracle (Wave 4). Neutral gate wiring: it is authored by neither the
# impl author (Waves 1-3) nor the reference author (Wave 2d). It imports BOTH the
# implementation aggregate (bin/lib/cp_issue_aggregate.py) and the INDEPENDENT
# reference aggregate (reference/aggregate_ref.py), NORMALIZES each to a common
# comparable partition, and DIFFS them. run.sh + gate.sh are thin wrappers over the
# subcommands here; falsify never re-implements this diff (REPORT-CONTRACT §5).
#
# THE COMPARABLE PARTITION (per reference/README §"Aggregate output wrapper shape").
# The impl and the reference legitimately use DIFFERENT envelopes (issue_aggregate_v1
# with a dimensions map vs issue_aggregate_ref_v1 with served/suppressed lists). We
# therefore NEVER byte-diff raw envelopes. Both sides are normalized to:
#     {
#       "served":     sorted list of [error_class, signature_hash, hmd_version,
#                                     os_class, command_or_phase, teams, rows]
#       "suppressed": sorted list of [error_class, signature_hash, hmd_version,
#                                     os_class, command_or_phase, teams]
#       "excluded_security": int
#     }
# — the SIGNATURE-bucket partition (INV-B key) split on the k-anon verdict, plus the
# INV-F security-exclusion count. served carries the distinct-team count AND the row
# count (so a distinct-vs-row miscount is visible); suppressed carries the key + the
# (sub-k) distinct-team count (INV-B mandates teams:n on the marker) but NEVER any
# metrics. PASS iff impl == reference on this partition, over every seed / fixture.
#
# WHY THIS KILLS REAL BUGS. Keeping teams in served kills a distinct-vs-row miscount
# (cross-tenant-merge). Keeping the served/suppressed split kills a k-anon-off leak.
# Keeping excluded_security + the security predicate kills a security-lane leak.
# Keeping signature_hash in the key kills a bucket-key collapse (wrong-bucket-key).
# A normalization that dropped any of these would false-green the matching mutant —
# bin/falsify --assert-score 1.0 proves it does not.

from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REF_DIR = os.path.join(_HERE, "reference")
# The impl lives in bin/lib, three levels up from evals/oracles/issue-collection/.
_PLUGIN_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
_LIB = os.path.join(_PLUGIN_ROOT, "bin", "lib")

for _p in (_REF_DIR, _LIB):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import aggregate_ref          # the INDEPENDENT reference (evals/.../reference/).
import cp_issue_aggregate     # the IMPLEMENTATION under test (bin/lib/).
import issue_corpus           # the shared k-anon floor + security taxonomy constant.

# The k-anon floor the gate pins on BOTH sides so the diff is apples-to-apples. Read
# from the impl lib's canonical constant; the reference hand-copies the same value
# from INVARIANTS.md, so a drift between them would itself surface as a divergence.
K_MIN = issue_corpus.ISSUE_K_ANONYMITY_MIN

# The 5 bucket-key dimensions in canonical order (INV-B). Both normalizers emit keys
# in exactly this order so the two partitions are directly comparable.
_KEY_FIELDS = ("error_class", "signature_hash", "hmd_version", "os_class",
               "command_or_phase")


# ── normalization: reference envelope -> comparable partition ──────────────────


def normalize_ref(agg):
    """Project the reference aggregate (aggregate_ref.aggregate output) to the common
    comparable partition. The reference already emits served/suppressed lists with the
    key fields inline; we lift them into the canonical [key..., teams(, rows)] rows."""
    served = []
    for e in agg.get("served", []):
        row = [str(e.get(k, "")) for k in _KEY_FIELDS]
        row.append(int(e.get("teams", 0)))
        row.append(int(e.get("rows", 0)))
        served.append(row)
    suppressed = []
    for e in agg.get("suppressed", []):
        row = [str(e.get(k, "")) for k in _KEY_FIELDS]
        row.append(int(e.get("teams", 0)))
        suppressed.append(row)
    return {
        "served": sorted(served),
        "suppressed": sorted(suppressed),
        "excluded_security": int(agg.get("excluded_security", 0)),
    }


def _split_impl_key(key):
    """Split the impl's '|'-joined signature-bucket key back into its 5 dimensions.
    The impl builds the key as error_class|signature_hash|hmd_version|os_class|
    command_or_phase (cp_issue_aggregate._signature_key). None of those coded tokens
    contains a '|' in a well-formed record, so a plain 4-separator split is exact; a
    malformed key (wrong field count) raises, surfacing a real bucketing bug rather
    than silently mis-aligning."""
    parts = key.split("|")
    if len(parts) != len(_KEY_FIELDS):
        raise ValueError("impl bucket key has %d parts, expected %d: %r"
                         % (len(parts), len(_KEY_FIELDS), key))
    return parts


def normalize_impl(agg):
    """Project the impl aggregate (cp_issue_aggregate.compute_issue_aggregates output)
    to the common comparable partition. The impl nests the signature buckets under
    dimensions.by_signature, keyed by the '|'-joined tuple, each value either a
    published cell {suppressed:false, teams, n, ...} or a suppression marker
    {suppressed:true, teams, ...}. We read ONLY by_signature (the INV-B partition the
    reference computes), split the key, and split on the suppressed verdict."""
    dims = agg.get("dimensions", {}) if isinstance(agg.get("dimensions"), dict) else {}
    by_sig = dims.get("by_signature", {}) if isinstance(dims.get("by_signature"), dict) else {}
    served = []
    suppressed = []
    for key, cell in by_sig.items():
        fields = _split_impl_key(key)
        if not isinstance(cell, dict):
            raise ValueError("impl by_signature cell is not a dict: %r" % (cell,))
        if cell.get("suppressed"):
            row = list(fields)
            row.append(int(cell.get("teams", 0)))
            suppressed.append(row)
        else:
            row = list(fields)
            row.append(int(cell.get("teams", 0)))
            row.append(int(cell.get("n", 0)))
            served.append(row)
    return {
        "served": sorted(served),
        "suppressed": sorted(suppressed),
        "excluded_security": int(agg.get("excluded_security", 0)),
    }


# ── the diff: first-divergence pinpoint over the comparable partition ──────────


def diff_partitions(ref_part, subj_part):
    """Diff the reference partition (truth) against the subject partition. Returns
    (ok, first_divergence) where first_divergence is None on a match, else a
    {step, expected, actual} dict pinpointing the FIRST divergence — served set,
    then suppressed set, then the security-exclusion count. Byte-comparable because
    both sides are canonicalized (sorted lists, str/int leaves)."""
    # 1) served bucket set (key + teams + rows).
    ref_served = ref_part.get("served", [])
    subj_served = subj_part.get("served", [])
    if ref_served != subj_served:
        idx, exp, act = _first_list_div(ref_served, subj_served)
        return False, {
            "step": "served bucket set (index %d of %d/%d)"
                    % (idx, len(ref_served), len(subj_served)),
            "expected": json.dumps(exp, sort_keys=True),
            "actual": json.dumps(act, sort_keys=True),
        }
    # 2) suppressed bucket set (key + teams; never metrics).
    ref_supp = ref_part.get("suppressed", [])
    subj_supp = subj_part.get("suppressed", [])
    if ref_supp != subj_supp:
        idx, exp, act = _first_list_div(ref_supp, subj_supp)
        return False, {
            "step": "suppressed bucket set (index %d of %d/%d)"
                    % (idx, len(ref_supp), len(subj_supp)),
            "expected": json.dumps(exp, sort_keys=True),
            "actual": json.dumps(act, sort_keys=True),
        }
    # 3) security-exclusion count (INV-F).
    ref_sec = int(ref_part.get("excluded_security", 0))
    subj_sec = int(subj_part.get("excluded_security", 0))
    if ref_sec != subj_sec:
        return False, {
            "step": "excluded_security count",
            "expected": str(ref_sec),
            "actual": str(subj_sec),
        }
    return True, None


def _first_list_div(ref_list, subj_list):
    """The first index at which two sorted lists differ, with the two values (or a
    sentinel when one side is shorter)."""
    n = max(len(ref_list), len(subj_list))
    for i in range(n):
        a = ref_list[i] if i < len(ref_list) else None
        b = subj_list[i] if i < len(subj_list) else None
        if a != b:
            return i, a, b
    return 0, None, None


# ── impl-vs-reference over a shared stream (the load-bearing differential) ─────


def impl_partition_of(stream, k_min=None):
    """Run the IMPL aggregate over a stream and normalize it. Pure — uses the impl's
    in-memory compute_issue_aggregates (never the store backend), so the gate needs
    no Cloud Run / no state seam."""
    km = K_MIN if k_min is None else k_min
    agg = cp_issue_aggregate.compute_issue_aggregates(stream, k_min=km, now=0)
    return normalize_impl(agg)


def ref_partition_of(stream, k_min=None):
    """Run the INDEPENDENT reference aggregate over a stream and normalize it."""
    km = K_MIN if k_min is None else k_min
    agg = aggregate_ref.aggregate(stream, k_min=km)
    return normalize_ref(agg)


def diff_stream(stream, k_min=None):
    """Feed the SAME stream to impl + reference, normalize both, diff. Returns
    (ok, first_divergence)."""
    ref_part = ref_partition_of(stream, k_min=k_min)
    subj_part = impl_partition_of(stream, k_min=k_min)
    return diff_partitions(ref_part, subj_part)


def sweep_seeds(n_seeds, start=1, k_min=None, records=400, signatures=12, teams=25):
    """The seeded differential sweep (the registry gate_command arm). For each seed
    the reference generator produces a deterministic issue stream; impl + reference
    both aggregate it; the partitions must be identical. Returns
    (ok, first_divergence, metrics)."""
    compared = 0
    for seed in range(start, start + n_seeds):
        stream = aggregate_ref.generate_stream(
            seed, n_records=records, n_signatures=signatures, n_teams=teams)
        ref_part = ref_partition_of(stream, k_min=k_min)
        subj_part = impl_partition_of(stream, k_min=k_min)
        compared += len(ref_part["served"]) + len(ref_part["suppressed"])
        ok, div = diff_partitions(ref_part, subj_part)
        if not ok:
            div = dict(div)
            div["step"] = "seed %d — %s" % (seed, div["step"])
            return False, div, {"seeds_swept": seed - start + 1,
                                 "buckets_compared": compared, "arm": "seeded-differential"}
    return True, None, {"seeds_swept": n_seeds, "buckets_compared": compared,
                        "arm": "seeded-differential"}


# ── fixture grading (what run.sh drives; falsify orchestrates run.sh) ──────────


def _load_stream(fixture):
    """Extract the issue-record stream from a fixture: an explicit `stream` list, or
    a `seed` (+ optional generator params) resolved through the reference generator."""
    if isinstance(fixture.get("stream"), list):
        return fixture["stream"]
    if "seed" in fixture:
        return aggregate_ref.generate_stream(
            int(fixture["seed"]),
            n_records=int(fixture.get("records", 400)),
            n_signatures=int(fixture.get("signatures", 12)),
            n_teams=int(fixture.get("teams", 25)),
        )
    return None


def grade_fixture(fixture):
    """Grade one fixture. Returns (status, first_divergence, metrics).

    kind == "differential" (the golden): run the IMPL and the REFERENCE over the SAME
        stream/seeds, normalize both, diff. status=pass iff they agree. This is the
        real impl-vs-reference correctness proof.

    kind == "mutant": the fixture carries a `stream` + a `corrupted` partition (the
        output a BUGGY impl would emit, breaking ONE invariant). The gate recomputes
        the CORRECT partition from the stream via the INDEPENDENT reference (the
        subject cannot lie about the truth side) and diffs it against `corrupted`.
        A genuine defect diverges -> status=fail -> the mutant is KILLED. A mutant that
        stayed pass = the normalization is blind to that defect class = false-green.
    """
    kind = fixture.get("kind")
    k_min = int(fixture["k_min"]) if "k_min" in fixture else None

    if kind == "differential":
        seeds = fixture.get("seeds")
        if isinstance(seeds, list) and seeds:
            compared = 0
            for seed in seeds:
                stream = aggregate_ref.generate_stream(
                    int(seed),
                    n_records=int(fixture.get("records", 400)),
                    n_signatures=int(fixture.get("signatures", 12)),
                    n_teams=int(fixture.get("teams", 25)),
                )
                ref_part = ref_partition_of(stream, k_min=k_min)
                subj_part = impl_partition_of(stream, k_min=k_min)
                compared += len(ref_part["served"]) + len(ref_part["suppressed"])
                ok, div = diff_partitions(ref_part, subj_part)
                if not ok:
                    div = dict(div)
                    div["step"] = "seed %s — %s" % (seed, div["step"])
                    return "fail", div, {"seeds_swept": len(seeds),
                                         "buckets_compared": compared,
                                         "arm": "impl-vs-reference-differential"}
            return "pass", None, {"seeds_swept": len(seeds), "buckets_compared": compared,
                                  "arm": "impl-vs-reference-differential"}
        stream = _load_stream(fixture)
        if stream is None:
            return "error", {"step": "fixture", "expected": "a stream/seed(s)",
                             "actual": "neither `stream`, `seed`, nor `seeds`"}, \
                   {"arm": "impl-vs-reference-differential"}
        ref_part = ref_partition_of(stream, k_min=k_min)
        subj_part = impl_partition_of(stream, k_min=k_min)
        compared = len(ref_part["served"]) + len(ref_part["suppressed"])
        if compared == 0:
            # A partition over an empty/degenerate stream proves nothing (mirror the
            # exchange-lob R-6 empty-stream guard): refuse to grade it.
            return "error", {"step": "empty partition",
                             "expected": "at least one served or suppressed bucket",
                             "actual": "zero buckets"}, \
                   {"buckets_compared": 0, "arm": "impl-vs-reference-differential"}
        ok, div = diff_partitions(ref_part, subj_part)
        metrics = {"seeds_swept": 1, "buckets_compared": compared,
                   "arm": "impl-vs-reference-differential"}
        return ("pass" if ok else "fail"), (None if ok else div), metrics

    if kind == "mutant":
        stream = _load_stream(fixture)
        corrupted = fixture.get("corrupted")
        if stream is None or not isinstance(corrupted, dict):
            return "error", {"step": "fixture",
                             "expected": "a `stream` and a `corrupted` partition",
                             "actual": "missing `stream` or `corrupted`"}, \
                   {"arm": "differential-mutant"}
        ref_part = ref_partition_of(stream, k_min=k_min)
        subj_part = _coerce_partition(corrupted)
        compared = len(ref_part["served"]) + len(ref_part["suppressed"])
        if compared == 0:
            return "error", {"step": "empty reference partition",
                             "expected": "at least one bucket in the correct partition",
                             "actual": "zero buckets"}, \
                   {"buckets_compared": 0, "arm": "differential-mutant"}
        ok, div = diff_partitions(ref_part, subj_part)
        metrics = {"buckets_compared": compared, "arm": "differential-mutant"}
        # A mutant is KILLED when the gate goes RED (status=fail). If it matches the
        # reference the injected defect was invisible to the gate -> pass -> SURVIVED.
        return ("pass" if ok else "fail"), (None if ok else div), metrics

    return "error", {"step": "fixture kind", "expected": "differential|mutant",
                     "actual": json.dumps(kind)}, {"arm": "unknown"}


def _coerce_partition(part):
    """Coerce a fixture-authored `corrupted` partition into the canonical comparable
    shape (sorted rows, str/int leaves) so it diffs byte-for-byte against a normalized
    reference partition. Served rows are [key..., teams, rows]; suppressed rows are
    [key..., teams]."""
    def _row(r):
        r = list(r)
        out = [str(x) for x in r[:len(_KEY_FIELDS)]]
        out.extend(int(x) for x in r[len(_KEY_FIELDS):])
        return out
    served = sorted(_row(r) for r in part.get("served", []))
    suppressed = sorted(_row(r) for r in part.get("suppressed", []))
    return {
        "served": served,
        "suppressed": suppressed,
        "excluded_security": int(part.get("excluded_security", 0)),
    }


# ── CLI ────────────────────────────────────────────────────────────────────────


def _build_parser():
    p = argparse.ArgumentParser(
        prog="differential.py",
        description="issue-collection differential diff-truth: normalize impl + "
                    "independent reference to a common partition and diff.")
    sub = p.add_subparsers(dest="command")

    s = sub.add_parser("sweep", help="seeded impl-vs-reference differential sweep")
    s.add_argument("--seeds", type=int, default=200)
    s.add_argument("--start", type=int, default=1)
    s.add_argument("--k-min", type=int, default=None)
    s.add_argument("--records", type=int, default=400)
    s.add_argument("--signatures", type=int, default=12)
    s.add_argument("--teams", type=int, default=25)

    g = sub.add_parser("grade", help="grade a fixture -> JSON {status, first_divergence, metrics}")
    g.add_argument("--input", required=True)

    n = sub.add_parser("normalize-impl", help="normalize the impl aggregate of a stream file")
    n.add_argument("--stream", required=True)
    r = sub.add_parser("normalize-ref", help="normalize the reference aggregate of a stream file")
    r.add_argument("--stream", required=True)
    return p


def _read_stream_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    if not text:
        return []
    if text[0] == "[":
        return list(json.loads(text))
    return [json.loads(ln) for ln in text.splitlines() if ln.strip()]


def main(argv=None):
    args = _build_parser().parse_args(argv)

    if args.command == "sweep":
        ok, div, metrics = sweep_seeds(
            args.seeds, start=args.start, k_min=args.k_min,
            records=args.records, signatures=args.signatures, teams=args.teams)
        print(json.dumps({"status": "pass" if ok else "fail",
                          "first_divergence": div, "metrics": metrics},
                         sort_keys=True))
        return 0 if ok else 1

    if args.command == "grade":
        with open(args.input, "r", encoding="utf-8") as fh:
            fixture = json.load(fh)
        status, div, metrics = grade_fixture(fixture)
        print(json.dumps({"status": status, "first_divergence": div,
                          "metrics": metrics}, sort_keys=True))
        return 0 if status == "pass" else (2 if status == "error" else 1)

    if args.command == "normalize-impl":
        print(json.dumps(impl_partition_of(_read_stream_file(args.stream)),
                         sort_keys=True, indent=2))
        return 0
    if args.command == "normalize-ref":
        print(json.dumps(ref_partition_of(_read_stream_file(args.stream)),
                         sort_keys=True, indent=2))
        return 0

    _build_parser().print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
