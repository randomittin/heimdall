#!/usr/bin/env python3
"""fg_summary: the false-green summary, a pure function of the raw rows (PREREG.md section 7).

summarize(rows) reads nothing but its argument: no clock, no environment, no file order. The rows are
sorted into a canonical order first, so any permutation of the same rows gives the same bytes.
Rates are {k, n, rate, ci95} with Wilson 95% intervals; a rate with no denominator is null, never 0/0.

  fg_summary.py [--in DIR] [--out FILE]     summarize results/*.jsonl, print JSON, optionally write it

Row schemas: fg.case/1 (Study B and the design set, one row per candidate) and fg.run/1 (Study A, the
RP4 result line, one row per run and arm). Anything else, or a malformed line, is an error: a summary
never skips a row it cannot read.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys

SCHEMA = "fg.summary/1"
Z = 1.96
MIN_N = 10                       # a denominator under this is "underpowered": no headline percentage
MIN_TASKS, MIN_AGENTS, MIN_RATED = 30, 2, 100
KNOWN_SCHEMAS = ("fg.case/1", "fg.run/1")


def r6(value):
    return None if value is None else round(value, 6)


def wilson(k, n):
    if n == 0:
        return None
    p, d = k / n, 1 + Z * Z / n
    centre = (p + Z * Z / (2 * n)) / d
    half = Z * math.sqrt(p * (1 - p) / n + Z * Z / (4 * n * n)) / d
    return [r6(max(0.0, centre - half)), r6(min(1.0, centre + half))]


def rate(k, n):
    return {"k": k, "n": n, "rate": r6(k / n) if n else None, "ci95": wilson(k, n)}


def mcnemar_p(b, c):
    """Exact two-sided McNemar p-value on the discordant pairs b and c."""
    n = b + c
    if n == 0:
        return 1.0
    return r6(min(1.0, 2 * sum(math.comb(n, i) for i in range(min(b, c) + 1)) / 2 ** n))


def pct(value):
    return "%.1f%%" % (100 * value)


def span(r):
    return "95%% CI %s to %s" % (pct(r["ci95"][0]), pct(r["ci95"][1]))


def _point(r):
    return None if r["n"] == 0 else r["rate"]


# ── Study A: the RP4 result lines ─────────────────────────────────────────────────────────
def _merge_runs(rows):
    merged = {}
    for row in rows:
        if row["schema"] != "fg.run/1":
            continue
        key = (row["agent"], row["task_id"], row.get("run_id") or "")
        run = merged.setdefault(key, {"agent": key[0], "task_id": key[1], "run_id": key[2], "claim": None, "ground_truth": None,
                                      "verdict": None, "labels": [], "interventions": 0, "infra_error": None, "anchor": False})
        run["claim"], run["ground_truth"] = row.get("agent_claim"), row.get("ground_truth")
        run["interventions"] = max(run["interventions"], row.get("human_interventions") or 0)
        run["infra_error"] = run["infra_error"] or row.get("infra_error")
        run["anchor"] = run["anchor"] or bool(row.get("anchor"))
        if row.get("arm") == "runhmd":
            run["verdict"] = row.get("verdict")
            if row.get("human_label"):
                run["labels"].append(row["human_label"])
    return [merged[key] for key in sorted(merged)]


def _exclusion(run):
    if run["infra_error"]:
        return "infrastructure: %s" % run["infra_error"]
    if run["ground_truth"] not in ("pass", "fail"):
        return "ground truth did not run (%s)" % run["ground_truth"]
    if run["interventions"] > 0:
        return "human interventions"
    return None


def _agent_block(runs):
    done = [r for r in runs if r["claim"] == "done"]
    false = [r for r in done if r["ground_truth"] == "fail"]
    return {"runs": len(runs), "done": len(done), "false_greens": len(false),
            "false_green_rate": rate(len(false), len(done)), "false_green_per_run": rate(len(false), len(runs))}


def _study_a(rows):
    runs = _merge_runs(rows)
    out = {"status": "no-data", "runs": 0, "excluded": [], "by_agent": {}, "pooled": None, "catch": None,
           "denial_precision": {"n_rated": 0, "rate": None, "reported": False}, "sampled_tasks": 0, "agents": 0,
           "headline_eligible": False}
    if not runs:
        return out
    included = [r for r in runs if _exclusion(r) is None]
    agents = sorted({r["agent"] for r in included})
    false = [r for r in included if r["claim"] == "done" and r["ground_truth"] == "fail"]
    denied = [r for r in false if r["verdict"] == "DENIED"]
    unattackable = [r for r in false if r["verdict"] not in ("PROVEN", "DENIED")]
    labels = [lab for r in included if r["verdict"] == "DENIED" for lab in r["labels"] if lab in ("true_positive", "false_positive")]
    sampled = {r["task_id"] for r in included if not r["anchor"]}
    out.update({
        "status": "measured", "runs": len(runs),
        "excluded": [{"agent": r["agent"], "task_id": r["task_id"], "run_id": r["run_id"], "reason": _exclusion(r)} for r in runs if _exclusion(r)],
        "by_agent": {a: _agent_block([r for r in included if r["agent"] == a]) for a in agents},
        "pooled": _agent_block(included),
        "catch": {"catch_rate": rate(len(denied), len(false)), "unattackable_false_greens": len(unattackable),
                  "catch_rate_attackable_only": rate(len(denied), len(false) - len(unattackable))},
        "denial_precision": {"n_rated": len(labels), "rate": r6(labels.count("true_positive") / len(labels)) if len(labels) >= MIN_RATED else None,
                             "reported": len(labels) >= MIN_RATED},
        "sampled_tasks": len(sampled), "agents": len(agents),
        "headline_eligible": len(sampled) >= MIN_TASKS and len(agents) >= MIN_AGENTS,
    })
    return out


def _headline_a(study):
    if study["status"] == "no-data":
        return "No headline number exists: Study A (real agents) has no data."
    if not study["headline_eligible"]:
        return ("No headline number exists: Study A has %d sampled task(s) and %d agent(s); a headline needs at least %d tasks and %d agents."
                % (study["sampled_tasks"], study["agents"], MIN_TASKS, MIN_AGENTS))
    pooled, catch = study["pooled"]["false_green_rate"], study["catch"]["catch_rate"]
    text = "Across %d runs by %d agents, a 'done' claim was false in %s of the %d done claims (%s)" % (
        study["pooled"]["runs"], study["agents"], pct(pooled["rate"]), pooled["n"], span(pooled))
    if catch["n"]:
        text += "; hmd attack denied %s of those false greens (%s), %d of them unattackable" % (
            pct(catch["rate"]), span(catch), study["catch"]["unattackable_false_greens"])
    return text + "."


# ── Study B: judge calibration on mechanical candidates ──────────────────────────────────
def _verdict(row, judge):
    return (row.get(judge) or {}).get("result")


def _exclusion_b(row):
    for judge in ("ground_truth", "runhmd", "naive"):
        if _verdict(row, judge) not in {"ground_truth": ("pass", "fail"), "runhmd": ("PROVEN", "DENIED"), "naive": ("green", "red")}[judge]:
            return "%s judge error" % judge.replace("_", " ")
    return None


def _calibration(design):
    if not design:
        return None
    problems = []
    for row in sorted(design, key=lambda r: r["case_id"]):
        if _verdict(row, "ground_truth") != row.get("expect_ground_truth"):
            problems.append({"case_id": row["case_id"], "expected": row.get("expect_ground_truth"), "got": _verdict(row, "ground_truth")})
    return {"entries": len(design), "calibrated": not problems, "problems": problems,
            "attack_on_design_set": {r["case_id"]: _verdict(r, "runhmd") for r in sorted(design, key=lambda r: r["case_id"])}}


def _brief(row, **extra):
    return dict({"case_id": row["case_id"], "operator": row.get("operator"), "line": row.get("line"), "from": row.get("from"), "to": row.get("to")}, **extra)


def _headline_b(study):
    if study["status"] == "no-data":
        return "No judge-calibration data."
    if study["status"] != "measured":
        return "Judge calibration is %s: no rate is reported." % study["status"]
    p, head = study["primary"], "Judge calibration, NOT an agent false-green rate: %d mechanical single-site mutants of one webhook judged (%d excluded). " % (
        study["candidates_judged"], len(study["excluded"]))
    head += "The naive visible tests passed %d of them; %d of those were truly defective" % (p["naive_green"], p["naive_green_defective"]["k"])
    if study["underpowered"]["catch_rate"]:
        return head + ". Only %d defective candidates passed the naive check, under %d: no catch percentage is stated." % (p["catch_rate"]["n"], MIN_N)
    return head + " (%s, %s); hmd attack denied %d of those %d (%s, %s) and denied %d of %d truly correct candidates (%s)." % (
        pct(p["naive_false_green_rate"]["rate"]), span(p["naive_false_green_rate"]), p["catch_rate"]["k"], p["catch_rate"]["n"],
        pct(p["catch_rate"]["rate"]), span(p["catch_rate"]), p["false_denial_rate"]["k"], p["false_denial_rate"]["n"],
        pct(p["false_denial_rate"]["rate"]) if p["false_denial_rate"]["n"] else "n/a")


def _study_b(rows):
    cases = [r for r in rows if r["schema"] == "fg.case/1"]
    design = [r for r in cases if r.get("set") == "design"]
    cands = [r for r in cases if r.get("set") == "candidates"]
    calibration = _calibration(design)
    study = {"status": "no-data", "candidates_judged": 0, "excluded": [], "calibration": calibration, "primary": None,
             "secondary": None, "paired": None, "by_operator": {}, "misses": [], "false_denials": [],
             "underpowered": {"catch_rate": None, "false_denial_rate": None},
             "flags": {"catch_lt_50pct": None, "false_denial_gt_10pct": None}}
    if not cands:
        study["headline"] = _headline_b(study)
        return study
    included = [r for r in cands if _exclusion_b(r) is None]
    study["excluded"] = [{"case_id": r["case_id"], "reason": _exclusion_b(r)} for r in cands if _exclusion_b(r)]
    study["candidates_judged"] = len(included)
    study["status"] = "no-design-set" if calibration is None else ("measured" if calibration["calibrated"] else "invalid-ground-truth")
    if study["status"] != "measured":
        study["headline"] = _headline_b(study)
        return study

    truth = lambda r: _verdict(r, "ground_truth")
    denied = lambda r: _verdict(r, "runhmd") == "DENIED"
    green = [r for r in included if _verdict(r, "naive") == "green"]
    defective = [r for r in green if truth(r) == "fail"]
    correct = [r for r in green if truth(r) == "pass"]
    all_bad = [r for r in included if truth(r) == "fail"]
    all_ok = [r for r in included if truth(r) == "pass"]
    study["primary"] = {
        "naive_green": len(green), "naive_green_defective": rate(len(defective), len(green)),
        "naive_false_green_rate": rate(len(defective), len(green)),
        "catch_rate": rate(sum(denied(r) for r in defective), len(defective)),
        "false_denial_rate": rate(sum(denied(r) for r in correct), len(correct)),
        "denial_precision": rate(sum(truth(r) == "fail" for r in green if denied(r)), sum(denied(r) for r in green)),
    }
    study["secondary"] = {
        "truth_fail": len(all_bad), "truth_pass": len(all_ok),
        "naive_catch_rate": rate(sum(_verdict(r, "naive") == "red" for r in all_bad), len(all_bad)),
        "attack_catch_rate": rate(sum(denied(r) for r in all_bad), len(all_bad)),
        "attack_false_denial_rate": rate(sum(denied(r) for r in all_ok), len(all_ok)),
        "attack_denial_precision": rate(sum(truth(r) == "fail" for r in included if denied(r)), sum(denied(r) for r in included)),
    }
    only_naive = sum(_verdict(r, "naive") == "red" and not denied(r) for r in all_bad)
    only_attack = sum(_verdict(r, "naive") == "green" and denied(r) for r in all_bad)
    study["paired"] = {"both_caught": sum(_verdict(r, "naive") == "red" and denied(r) for r in all_bad), "only_naive_caught": only_naive,
                       "only_attack_caught": only_attack, "neither_caught": sum(_verdict(r, "naive") == "green" and not denied(r) for r in all_bad),
                       "mcnemar_exact_p": mcnemar_p(only_naive, only_attack)}
    for op in sorted({r.get("operator") for r in included}):
        mine = [r for r in included if r.get("operator") == op]
        bad = [r for r in mine if truth(r) == "fail" and _verdict(r, "naive") == "green"]
        study["by_operator"][op] = {"judged": len(mine), "truth_fail": sum(truth(r) == "fail" for r in mine),
                                    "naive_green_defective": len(bad), "denied_of_those": sum(denied(r) for r in bad)}
    study["misses"] = [_brief(r, ground_truth=(r["ground_truth"].get("failure") or {}).get("summary")) for r in sorted(defective, key=lambda r: r["case_id"]) if not denied(r)]
    study["false_denials"] = [_brief(r, findings=[f.get("title") for f in r["runhmd"].get("findings") or []]) for r in sorted(all_ok, key=lambda r: r["case_id"]) if denied(r)]
    p = study["primary"]
    study["underpowered"] = {"catch_rate": p["catch_rate"]["n"] < MIN_N, "false_denial_rate": p["false_denial_rate"]["n"] < MIN_N}
    study["flags"] = {
        "catch_lt_50pct": None if _point(p["catch_rate"]) is None else _point(p["catch_rate"]) < 0.5,
        "false_denial_gt_10pct": None if _point(p["false_denial_rate"]) is None else _point(p["false_denial_rate"]) > 0.10,
    }
    study["headline"] = _headline_b(study)
    return study


def summarize(rows):
    """The whole summary, from the raw rows alone."""
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or row.get("schema") not in KNOWN_SCHEMAS:
            raise ValueError("row %d has an unknown schema: %r" % (index, row.get("schema") if isinstance(row, dict) else row))
    ordered = sorted(rows, key=lambda r: json.dumps(r, sort_keys=True))
    a, b = _study_a(ordered), _study_b(ordered)
    point = lambda r: None if r is None else _point(r)
    return {
        "schema": SCHEMA, "suite": "false-green",
        "headline": _headline_a(a),
        "false_green_rate_by_agent": {name: point(block["false_green_rate"]) for name, block in a["by_agent"].items()},
        "catch_rate": point(a["catch"]["catch_rate"]) if a["catch"] else None,
        "denial_precision": a["denial_precision"]["rate"],
        "kill_flags": {
            "false_green_lt_10pct": None if not a["pooled"] or point(a["pooled"]["false_green_rate"]) is None else point(a["pooled"]["false_green_rate"]) < 0.10,
            "catch_lt_50pct": None if not a["catch"] or point(a["catch"]["catch_rate"]) is None else point(a["catch"]["catch_rate"]) < 0.50,
        },
        "study_a": a,
        "judge_calibration": b,
    }


def load_rows(results_dir):
    rows = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.jsonl"))):
        with open(path, "r", encoding="utf-8") as fh:
            for number, line in enumerate(fh, start=1):
                if not line.strip():
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError as exc:
                    raise ValueError("%s line %d is not JSON: %s" % (path, number, exc))
    return rows


def render(summary):
    return json.dumps(summary, indent=2, sort_keys=True) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(prog="fg_summary", description=__doc__.split("\n\n")[0])
    parser.add_argument("--in", dest="results", required=True, help="directory holding the raw *.jsonl rows")
    parser.add_argument("--out", help="also write the summary here")
    args = parser.parse_args(argv)
    try:
        text = render(summarize(load_rows(args.results)))
    except (OSError, ValueError) as exc:
        sys.stderr.write("fg_summary: %s\n" % exc)
        return 2
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
