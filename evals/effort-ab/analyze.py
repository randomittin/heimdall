#!/usr/bin/env python3
"""Paired analysis and the PRE-REGISTERED verdict of the effort A/B (docs/analysis/2026-11-23-effort-ab.md).

GO for medium as the default effort only if ALL hold:
  Q1  passes(medium) >= passes(high)                       (pass rate equal or better, zero tolerance)
  Q2  no task that passes in BOTH high reps fails in BOTH medium reps
  T   mean output tokens drop >= 15% (pooled mean over all runs of the arm)
Otherwise NO-GO. Fewer counted runs than expected -> INCOMPLETE. The bootstrap CI and the sign test are
supplementary: they never change the verdict, they say how far to trust it.

usage: analyze.py [--results runs.jsonl] [--expected 40] [--json]
"""
import argparse
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run import fixture_sha  # noqa: E402  (one definition of the fixture hash)

HIGH, MED = "high", "medium"
MIN_DROP = 0.15


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def load(path):
    counted, attempts = {}, []
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("kind") != "run":
            continue
        attempts.append(row)
        if row.get("counted"):
            counted[(row["task"], row["arm"], row["rep"])] = row
    return counted, attempts


def arm_stats(rows):
    return {
        "n": len(rows), "passes": sum(1 for r in rows if r["pass"]),
        "pass_rate": mean([1.0 if r["pass"] else 0.0 for r in rows]),
        "mean_output": mean([r["output_tokens"] for r in rows]),
        "mean_input_fresh": mean([r["input_tokens"] for r in rows]),
        "mean_cache_read": mean([r["cache_read_tokens"] for r in rows]),
        "mean_cache_write": mean([r["cache_write_tokens"] for r in rows]),
        "mean_turns": mean([r["num_turns"] for r in rows]),
        "mean_wall_s": mean([r["wall_s"] for r in rows]),
        "mean_cost": mean([r["cost_usd"] for r in rows]),
        "mean_thinking_est": mean([r["thinking_est_tokens"] for r in rows]),
    }


def bootstrap_drop(per_task, draws=20000, seed=12345):
    """95% CI of 1 - sum(medium)/sum(high), resampling TASKS (the pairing unit)."""
    rng, drops = random.Random(seed), []
    for _ in range(draws):
        sample = [per_task[rng.randrange(len(per_task))] for _ in per_task]
        high = sum(t["high_out"] for t in sample)
        if high:
            drops.append(1 - sum(t["medium_out"] for t in sample) / high)
    drops.sort()
    return [drops[int(0.025 * len(drops))], drops[int(0.975 * len(drops)) - 1]] if drops else [None, None]


def sign_test(per_task):
    lower = sum(1 for t in per_task if t["medium_out"] < t["high_out"])
    higher = sum(1 for t in per_task if t["medium_out"] > t["high_out"])
    n = lower + higher
    tail = sum(math.comb(n, i) for i in range(0, min(lower, higher) + 1)) / 2 ** n if n else 1.0
    return {"medium_lower": lower, "medium_higher": higher, "p_two_sided": min(1.0, 2 * tail)}


def changed_fixtures(counted, tasks_dir):
    """Tasks whose fixture differed between runs, changed during a run, or differs from the dir now."""
    seen, bad = {}, set()
    for (task, _arm, _rep), row in counted.items():
        if row.get("fixture_sha"):
            seen.setdefault(task, set()).add(row["fixture_sha"])
            if row.get("fixture_stable") is False:
                bad.add(task)
    for task, shas in seen.items():
        current = tasks_dir / task
        if len(shas) > 1 or (current.is_dir() and fixture_sha(current) not in shas):
            bad.add(task)
    return sorted(bad)


def analyse(counted, attempts, expected, tasks_dir=HERE / "tasks"):
    tasks = sorted({k[0] for k in counted})
    by_arm = {a: [r for k, r in counted.items() if k[1] == a] for a in (HIGH, MED)}
    per_task = []
    for t in tasks:
        cell = {a: [counted[k] for k in sorted(counted) if k[0] == t and k[1] == a] for a in (HIGH, MED)}
        if not cell[HIGH] or not cell[MED]:
            continue
        entry = {"task": t, "difficulty": (cell[HIGH] + cell[MED])[0].get("difficulty")}
        for a in (HIGH, MED):
            entry[f"{a}_pass"] = sum(1 for r in cell[a] if r["pass"])
            entry[f"{a}_n"] = len(cell[a])
            entry[f"{a}_out"] = mean([r["output_tokens"] for r in cell[a]])
            entry[f"{a}_turns"] = mean([r["num_turns"] for r in cell[a]])
            entry[f"{a}_wall"] = mean([r["wall_s"] for r in cell[a]])
            entry[f"{a}_cost"] = mean([r["cost_usd"] for r in cell[a]])
        entry["delta_pct"] = 100 * (entry["medium_out"] / entry["high_out"] - 1) if entry["high_out"] else None
        per_task.append(entry)
    stats = {a: arm_stats(by_arm[a]) for a in (HIGH, MED)}
    regressed = [t["task"] for t in per_task
                 if t["high_pass"] == t["high_n"] > 0 and t["medium_pass"] == 0]
    drop = 1 - stats[MED]["mean_output"] / stats[HIGH]["mean_output"] if stats[HIGH]["mean_output"] else 0.0
    q1 = stats[MED]["passes"] >= stats[HIGH]["passes"]
    q2 = not regressed
    t_ok = drop >= MIN_DROP - 1e-9
    complete = len(counted) >= expected
    verdict = "INCOMPLETE" if not complete else ("GO" if (q1 and q2 and t_ok) else "NO-GO")
    return {
        "complete": complete, "expected_runs": expected, "counted_runs": len(counted), "arms": stats,
        "tasks": per_task,
        "decision": {"q1_pass_rate_not_lower": q1, "q2_no_task_regression": q2, "regressed_tasks": regressed,
                     "output_token_drop": drop, "t_drop_ge_15pct": t_ok, "verdict": verdict},
        "supplementary": {
            "bootstrap_ci95_drop": bootstrap_drop(per_task) if per_task else [None, None],
            "sign_test": sign_test(per_task),
            "fixtures_changed": changed_fixtures(counted, tasks_dir),
            "attempts_total": len(attempts), "infra_retries": sum(1 for a in attempts if a["infra_failure"]),
            "timeouts": sum(1 for a in attempts if a["timed_out"]),
            "spend_usd_all_attempts": sum(a["cost_usd"] for a in attempts),
            "hook_events_total": sum(a["hook_events"] for a in attempts),
            "models_seen": sorted({m for a in attempts for m in a["models"]}),
        },
    }


def render(res):
    d, s = res["decision"], res["supplementary"]
    out = ["| arm | n | passes | pass rate | mean output tok | mean fresh input | mean cache read | mean cache write "
           "| mean turns | mean wall s | mean cost $ | mean thinking est |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for a in (HIGH, MED):
        x = res["arms"][a]
        out.append(f"| {a} | {x['n']} | {x['passes']} | {x['pass_rate']:.0%} | {x['mean_output']:.0f} | "
                   f"{x['mean_input_fresh']:.0f} | {x['mean_cache_read']:.0f} | {x['mean_cache_write']:.0f} | "
                   f"{x['mean_turns']:.1f} | {x['mean_wall_s']:.0f} | {x['mean_cost']:.3f} | {x['mean_thinking_est']:.0f} |")
    out += ["", "| task | difficulty | pass high | pass medium | out high | out medium | delta % | turns high | turns medium "
            "| wall high s | wall medium s |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for t in res["tasks"]:
        out.append(f"| {t['task']} | {t['difficulty']} | {t['high_pass']}/{t['high_n']} | {t['medium_pass']}/{t['medium_n']} | "
                   f"{t['high_out']:.0f} | {t['medium_out']:.0f} | {t['delta_pct']:+.1f} | {t['high_turns']:.1f} | "
                   f"{t['medium_turns']:.1f} | {t['high_wall']:.0f} | {t['medium_wall']:.0f} |")
    ci = s["bootstrap_ci95_drop"]
    out += ["", f"- Q1 pass rate medium >= high: **{d['q1_pass_rate_not_lower']}** "
                f"({res['arms'][MED]['passes']} vs {res['arms'][HIGH]['passes']} passes)",
            f"- Q2 no task passing both high reps fails both medium reps: **{d['q2_no_task_regression']}** {d['regressed_tasks']}",
            f"- T mean output-token drop: **{d['output_token_drop']:.1%}** (needs >= 15%): **{d['t_drop_ge_15pct']}**",
            f"- VERDICT: **{d['verdict']}** (counted runs {res['counted_runs']}/{res['expected_runs']})",
            f"- supplementary (never changes the verdict): bootstrap 95% CI of the drop over tasks "
            f"[{ci[0]:.1%}, {ci[1]:.1%}]" if ci[0] is not None else "- bootstrap CI n/a",
            ("- FIXTURES CHANGED while the study ran: " + ", ".join(s["fixtures_changed"]) + " (their rows are NOT valid; re-run)"
             if s["fixtures_changed"] else "- fixtures stable: one content hash per task across all counted rows, equal to the tree now"),
            f"- sign test over tasks: medium lower in {s['sign_test']['medium_lower']}, higher in "
            f"{s['sign_test']['medium_higher']}, p={s['sign_test']['p_two_sided']:.3f}",
            f"- attempts {s['attempts_total']} (infra retries {s['infra_retries']}, timeouts {s['timeouts']}), "
            f"spend ${s['spend_usd_all_attempts']:.2f} list-price-equivalent (CLI cost field, all attempts), "
            f"hook events {s['hook_events_total']}, models {s['models_seen']}"]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=HERE / "results" / "runs.jsonl")
    ap.add_argument("--tasks-dir", type=Path, default=HERE / "tasks")
    ap.add_argument("--expected", type=int, default=40)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    counted, attempts = load(args.results)
    res = analyse(counted, attempts, args.expected, args.tasks_dir)
    print(json.dumps(res, indent=1) if args.json else render(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
