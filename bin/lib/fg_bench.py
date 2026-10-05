#!/usr/bin/env python3
"""fg_bench: `bin/benchmark {validate|run|summarize} --suite false-green` (RP4).

  validate   exit 1 unless the design freeze is intact (PREREG.lock.json), every task has its
             ground_truth.sh, and the committed case set is exactly what the generator re-derives
  run        Study B (default, local, $0): judge every enumerated candidate and the design set with
             the naive check, `hmd attack` and the ground truth; write raw rows, one per candidate.
             Study A (--agent NAME): real agents; --dry (the default) prints the plan and the cost
             bound; --live --confirm-spend runs them and spends real money
  summarize  the summary as a pure function of the raw rows (bin/lib/fg_summary.py)

Exit codes: 0 ok, 1 invalid freeze or a failed check, 2 usage or config, 3 consent required
(--live without --confirm-spend).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN = os.path.dirname(os.path.dirname(HERE))
# FG_SUITE_DIR is a test seam: it points the harness at a (modified) copy of the suite so the
# validation failures can be exercised. A copy is checked against its own lock, never the committed one.
SUITE = os.environ.get("FG_SUITE_DIR") or os.path.join(PLUGIN, "evals", "benchmark", "false-green")
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import fg_agent  # noqa: E402
import fg_lock  # noqa: E402
import fg_mutate  # noqa: E402
import fg_summary  # noqa: E402

CATEGORIES = ("bugfix", "feature", "refactor", "concurrency", "security")
ATTACK_BIN = os.path.join(PLUGIN, "bin", "heimdall-attack")
NAIVE_TIMEOUT_S, ATTACK_TIMEOUT_S, GROUND_TRUTH_TIMEOUT_S = 30, 120, 200
# PREREG.md section 8: a run is killed at $2.00 of spend or 30 minutes and recorded as an infrastructure
# exclusion. How the spend is read while the run is live: PREREG.md Amendment 1, bin/lib/fg_agent.py.
PER_RUN_CAP_USD, RUN_TIMEOUT_S = 2.00, 1800
ENGINE_FILES = ("evals/oracles/attack/run.sh", "evals/oracles/attack/grade.mjs", "evals/oracles/attack/engine/battery.mjs",
                "evals/oracles/attack/engine/harness.mjs", "evals/oracles/attack/reference/settlement.ref.mjs",
                "bin/lib/runhmd_attack.py", "bin/heimdall-attack")
# claude-code streams JSON events so the spend can be read while the run is live, and carries the agent's own
# cap as a second stop ({budget} is the per-run cap). Its permission mode and tool set have not been exercised
# against a real task yet. The other two templates have not been exercised in this tree either, so a live run
# with them needs an explicit --agent-cmd.
AGENT_TEMPLATES = {
    "claude-code": ["claude", "-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                    "--max-budget-usd", "{budget}"],
    "codex": ["codex", "exec", "{prompt}"],
    "gemini": ["gemini", "-p", "{prompt}"],
}
VERIFIED_AGENTS = ("claude-code",)


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _tail(text, lines=3, width=300):
    return " | ".join(text.strip().splitlines()[-lines:])[:width]


def _run(cmd, cwd, timeout, env=None):
    """(exit code, or None on timeout; stdout; stderr)."""
    try:
        done = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None, "", "timeout after %ss" % timeout
    except OSError as exc:
        return 127, "", str(exc)
    return done.returncode, done.stdout, done.stderr


# ── tasks and validation ─────────────────────────────────────────────────────────────────
def load_tasks(suite):
    root, tasks = os.path.join(suite, "tasks"), []
    for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        path = os.path.join(root, name)
        if os.path.isdir(path):
            spec = os.path.join(path, "task.json")
            tasks.append((path, _read_json(spec) if os.path.isfile(spec) else None))
    return tasks


def validate(suite=SUITE, repo=PLUGIN):
    problems = []
    for name in ("PREREG.md", fg_lock.LOCK_NAME, "cases.json"):
        if not os.path.isfile(os.path.join(suite, name)):
            problems.append("missing %s" % name)
    tasks = load_tasks(suite)
    if not tasks:
        problems.append("no tasks under tasks/")
    for path, task in tasks:
        label = os.path.basename(path)
        if task is None:
            problems.append("task %s has no task.json" % label)
            continue
        for key in ("id", "category", "source", "prompt"):
            if not task.get(key):
                problems.append("task %s: task.json lacks %s" % (label, key))
        if task.get("category") not in CATEGORIES:
            problems.append("task %s: category %r is not one of %s" % (label, task.get("category"), "|".join(CATEGORIES)))
        for needed in ("repo.ref", "ground_truth.sh"):
            if not os.path.isfile(os.path.join(path, needed)):
                problems.append("task %s lacks %s (a task without a human-written ground truth is not a task)" % (label, needed))
    if problems:
        return problems
    problems += fg_lock.verify(suite, repo)
    cases = _read_json(os.path.join(suite, "cases.json"))
    with open(os.path.join(suite, cases["base"]["path"]), "r", encoding="utf-8") as fh:
        problems += fg_mutate.drift(cases, cases["base"]["path"], fh.read())
    return problems


# ── the three judges ─────────────────────────────────────────────────────────────────────
def _env(scratch):
    return {"PATH": os.environ.get("PATH", ""), "HOME": scratch, "TMPDIR": scratch, "LANG": "C"}


def judge_naive(task_dir, candidate):
    with tempfile.TemporaryDirectory(prefix="fg-naive-") as scratch:
        rc, out, err = _run(["node", os.path.join(task_dir, "visible_tests.mjs"), candidate], scratch, NAIVE_TIMEOUT_S, _env(scratch))
    return {"result": {0: "green", 1: "red"}.get(rc, "error"), "exit": rc, "tail": _tail(out + err)}


def judge_attack(task_dir, candidate):
    with tempfile.TemporaryDirectory(prefix="fg-attack-") as scratch:
        target, home = os.path.join(scratch, "target"), os.path.join(scratch, "home")
        os.makedirs(target)
        os.makedirs(home)
        shutil.copy(candidate, os.path.join(target, "webhook.mjs"))
        shutil.copy(os.path.join(task_dir, "runhmd.attack.json"), target)
        rc, out, err = _run([sys.executable, ATTACK_BIN, target, "--json", "--yes", "--no-network"], scratch, ATTACK_TIMEOUT_S, _env(home))
    if rc in (0, 1):
        try:
            doc = json.loads(out)
            return {"result": doc["verdict"], "exit": rc, "attacks": doc["attacks"], "cost_usd": doc.get("cost_usd"), "error": None,
                    "findings": [{k: f.get(k) for k in ("id", "title", "severity", "category")} for f in doc["findings"]]}
        except (ValueError, KeyError) as exc:
            return {"result": "error", "exit": rc, "error": "unreadable verdict (%s): %s" % (exc, _tail(out))}
    return {"result": "error", "exit": rc, "error": _tail(err or out) or "no output"}


def judge_ground_truth(task_dir, candidate):
    scratch = os.path.dirname(candidate)
    rc, out, err = _run(["bash", os.path.join(task_dir, "ground_truth.sh"), candidate], scratch, GROUND_TRUTH_TIMEOUT_S, _env(scratch))
    try:
        detail = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
    except ValueError:
        detail = {}
    result = {0: "pass", 1: "fail"}.get(rc, "error")
    return {"result": result, "exit": rc, "failure": detail.get("failure"), "error": None if result != "error" else (detail.get("detail") or _tail(err or out))}


def judge_all(task_dir, candidate):
    judged, wall = {}, {}
    for name, judge in (("naive", judge_naive), ("runhmd", judge_attack), ("ground_truth", judge_ground_truth)):
        started = time.monotonic()
        judged[name] = judge(task_dir, candidate)
        wall[name] = round(time.monotonic() - started, 3)
    judged["wall_s"] = wall
    return judged


# ── Study B ──────────────────────────────────────────────────────────────────────────────
def _judge_source(task_dir, text):
    with tempfile.TemporaryDirectory(prefix="fg-candidate-") as scratch:
        path = os.path.join(scratch, "candidate.mjs")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return judge_all(task_dir, path)


def _study_b_jobs(suite, only):
    task_dir = os.path.join(suite, "tasks", "settlement-webhook")
    cases = _read_json(os.path.join(suite, "cases.json"))
    with open(os.path.join(suite, cases["base"]["path"]), "r", encoding="utf-8") as fh:
        sources = fg_mutate.candidate_sources(fh.read())
    design = _read_json(os.path.join(task_dir, "design_set.json"))["entries"]
    cand = [c for c in cases["cases"] if c["status"] == "included" and (not only or c["id"] in only)]
    return task_dir, cases, sources, cand, [d for d in design if not only or d["id"] in only]


def plan_study_b(suite, out, only):
    task_dir, cases, _sources, cand, des = _study_b_jobs(suite, only)
    broken = fg_lock.verify(suite, PLUGIN)
    sys.stdout.write("false-green Study B (judge calibration): DRY RUN, nothing executed, no model calls\n"
                     "  tasks:       %d (%s)\n  candidates:  %d to judge (%d enumerated, %d excluded at enumeration: %s)\n"
                     "  design set:  %d entries (calibrates the ground truth; reported separately)\n"
                     "  judges:      naive visible tests, hmd attack --no-network, ground truth\n"
                     "  cost:        $0.00 (no model, no network)\n  freeze:      %s\n  would write: %s/{design-set,judge-calibration}.jsonl, ENV.json\n"
                     % (len(load_tasks(suite)), os.path.basename(task_dir), len(cand), cases["counts"]["enumerated"],
                        cases["counts"]["enumerated"] - cases["counts"]["included"], cases["counts"]["excluded"], len(des),
                        "intact" if not broken else "BROKEN: " + "; ".join(broken), out))
    return 1 if broken else 0


def run_study_b(suite, out, jobs, only):
    problems = validate(suite, PLUGIN)
    if problems:
        sys.stderr.write("fg_bench: refusing to run, the freeze is not intact:\n" + "".join("  %s\n" % p for p in problems))
        return 1
    task_dir, _cases, sources, cand, des = _study_b_jobs(suite, only)
    work = []
    for d in des:
        with open(os.path.join(PLUGIN, d["path"]), "r", encoding="utf-8") as fh:
            work.append(("design", d["id"], {"role": d["role"], "expect_ground_truth": d["expect_ground_truth"]}, fh.read()))
    for c in cand:
        work.append(("candidates", c["id"], {k: c[k] for k in ("operator", "line", "col", "from", "to")}, sources[c["id"]]))

    def one(item):
        kind, cid, meta, text = item
        row = {"schema": "fg.case/1", "suite": "false-green", "set": kind, "case_id": cid, "candidate_sha256": fg_mutate.sha256_text(text), "ts": _now()}
        row.update(meta)
        row.update(_judge_source(task_dir, text))
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        rows = list(pool.map(one, work))
    os.makedirs(out, exist_ok=True)
    for kind, name in (("design", "design-set.jsonl"), ("candidates", "judge-calibration.jsonl")):
        _write_rows(os.path.join(out, name), [r for r in rows if r["set"] == kind])
    _write_env(out)
    sys.stdout.write("false-green Study B: judged %d candidates and %d design-set entries -> %s\n" % (len(cand), len(des), out))
    return 0


def _write_rows(path, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for row in sorted(rows, key=lambda r: r["case_id"]):
            fh.write(json.dumps(row, sort_keys=True) + "\n")
    os.replace(tmp, path)


def _write_env(out):
    def sh(*cmd):
        rc, text, _ = _run(list(cmd), PLUGIN, 30)
        return text.strip() if rc == 0 else None

    tiers = {t: sh(os.path.join(PLUGIN, "bin", "heimdall-model-resolve"), t) for t in ("opus", "sonnet", "haiku")}
    env = {"schema": "fg.env/1", "ts": _now(), "repo_commit": sh("git", "rev-parse", "HEAD"),
           "tree_dirty": bool(sh("git", "status", "--porcelain", "--", "evals/oracles/attack", "bin", "fixtures/attack",
                                 "evals/benchmark/false-green/tasks", "evals/benchmark/false-green/cases.json",
                                 "evals/benchmark/false-green/PREREG.md", "evals/benchmark/false-green/PREREG.lock.json")),
           "node": sh("node", "--version"), "python": platform.python_version(), "os": platform.platform(),
           "engine_sha256": {rel: _sha256_file(os.path.join(PLUGIN, rel)) for rel in ENGINE_FILES},
           "prereg_lock_sha256": _sha256_file(os.path.join(SUITE, fg_lock.LOCK_NAME)), "model_resolve_tiers": tiers}
    with open(os.path.join(out, "ENV.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(env, indent=2, sort_keys=True) + "\n")


# ── Study A ──────────────────────────────────────────────────────────────────────────────
def plan_study_a(suite, args):
    tasks = [t for _p, t in load_tasks(suite) if t]
    attackable = sum(1 for t in tasks if t.get("profile") == "settlement-webhook/1")
    anchors = sum(1 for t in tasks if str(t.get("source", "")).startswith("author-written"))
    arms = ["alone", "runhmd"] if args.arm == "both" else [args.arm]
    note = "" if args.agent in VERIFIED_AGENTS or args.agent_cmd else " (command template untested in this tree: a live run needs --agent-cmd)"
    sys.stdout.write("false-green Study A (agents): %s, no model calls made by this command\n"
                     "  tasks:      %d (%d attackable by hmd attack, %d author-written anchor); a headline needs %d sampled tasks and %d agents\n"
                     "  agent:      %s%s\n  arms:       %s (one agent run per task; every arm is scored on that run)\n"
                     "  runs:       %d\n  cost bound: $%.2f per run x %d = $%.2f at most; the runhmd arm adds $0.00 (offline engine)\n"
                     "  per-run cap: the agent is killed at $%.2f of spend or %d minutes and the run is an infrastructure exclusion (PREREG.md section 8, Amendment 1)\n"
                     "  would write: %s/%s\n"
                     % ("DRY RUN" if not args.live else "LIVE", len(tasks), attackable, anchors, fg_summary.MIN_TASKS, fg_summary.MIN_AGENTS,
                        args.agent, note, ",".join(arms), len(tasks), PER_RUN_CAP_USD, len(tasks), PER_RUN_CAP_USD * len(tasks),
                        PER_RUN_CAP_USD, RUN_TIMEOUT_S // 60, args.out, "{" + ",".join(a + ".jsonl" for a in arms) + "}"))
    return 0


def _claim_of(text):
    found = re.findall(r"^\s*CLAIM:\s*(done|failed|gave_up)\s*$", text, re.M)
    return found[-1] if found else "gave_up"


def _infra_error(run, meter, text, cap_usd, timeout_s):
    """Why a run is an infrastructure exclusion (PREREG.md sections 8 and 9), or None."""
    if run.killed == "cap":
        return "per-run cap: estimated spend $%.2f reached the $%.2f cap; agent killed" % (meter.spend_usd, cap_usd)
    if run.killed == "timeout":
        return "agent timed out after %ds; killed" % timeout_s
    if run.killed == "fault":
        return "spend could not be read (%s); agent killed" % run.fault
    if meter.stopped_at_budget or (meter.cost_usd is not None and meter.cost_usd >= cap_usd):
        return "per-run cap: the run's cost, $%.2f, is at or above the $%.2f cap" % (meter.cost_usd or cap_usd, cap_usd)
    if run.rc != 0 and not re.search(r"^\s*CLAIM:", text, re.M):
        return "agent exited %s: %s" % (run.rc, _tail(run.stderr or text))
    return None


def _agent_once(path, task, template, cap_usd, timeout_s):
    """One supervised agent run in a fresh workspace; returns the per-run record that becomes the result rows."""
    work = tempfile.mkdtemp(prefix="fg-agent-")
    try:
        for name in task["workspace_files"]:
            shutil.copy(os.path.join(path, name), work)
        meter = fg_agent.Meter()
        command = [part.replace("{prompt}", task["prompt"]).replace("{budget}", "%.2f" % cap_usd) for part in template]
        run = fg_agent.supervise(command, work, meter, cap_usd, timeout_s)
        text = meter.final_text if meter.final_text is not None else run.stdout
        infra = _infra_error(run, meter, text, cap_usd, timeout_s)
        record = {"agent_claim": _claim_of(text), "wall_s": round(run.elapsed_s, 2), "tokens": meter.tokens, "cost_usd": meter.cost_usd,
                  "cost_source": meter.cost_source, "price_basis": meter.price_basis, "model": meter.model, "infra_error": infra,
                  "capped": bool(infra) and infra.startswith("per-run cap")}
        deliverable = os.path.join(work, task["deliverable"])
        if os.path.isfile(deliverable):
            judged = judge_all(path, deliverable)
            record["judge_wall_s"] = judged.pop("wall_s")
            record.update(judged)
        else:
            record.update({"naive": {"result": "red", "exit": None, "tail": "no deliverable"}, "runhmd": {"result": "error", "error": "no deliverable"},
                           "ground_truth": {"result": "fail", "exit": None, "failure": {"summary": "no %s was produced" % task["deliverable"]}}})
        return record
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_study_a_live(suite, args):
    template = args.agent_cmd.split() if args.agent_cmd else AGENT_TEMPLATES[args.agent]
    arms = ["alone", "runhmd"] if args.arm == "both" else [args.arm]
    rows, spent, unmetered = {a: [] for a in arms}, 0.0, 0
    tasks = [(p, t) for p, t in load_tasks(suite) if t]
    cap = PER_RUN_CAP_USD * len(tasks)
    for path, task in tasks:
        if spent >= cap:
            sys.stderr.write("fg_bench: the total cap of $%.2f is reached; the study is INCOMPLETE\n" % cap)
            break
        rec = _agent_once(path, task, template, PER_RUN_CAP_USD, RUN_TIMEOUT_S)
        spent += rec["cost_usd"] or 0.0
        if rec["cost_source"] == "unmetered":
            unmetered += 1
            sys.stderr.write("fg_bench: WARNING: %s on %s reported no usage: the per-run cap could not be enforced for this run (only the %d-minute limit applied)\n"
                             % (args.agent, task["id"], RUN_TIMEOUT_S // 60))
        verdict = rec["runhmd"]["result"] if rec["runhmd"]["result"] in ("PROVEN", "DENIED") else None
        finding = (rec["runhmd"].get("findings") or [{}])[0].get("title")
        for arm in arms:
            run_id = "%s-%s-1" % (args.agent, task["id"])
            rows[arm].append({
                "schema": "fg.run/1", "case_id": "%s-%s" % (run_id, arm), "task_id": task["id"], "agent": args.agent, "arm": arm, "run_id": run_id,
                "model": rec["model"], "ts": _now(), "agent_claim": rec["agent_claim"], "ground_truth": rec["ground_truth"]["result"],
                "false_green": rec["agent_claim"] == "done" and rec["ground_truth"]["result"] == "fail",
                "verdict": verdict if arm == "runhmd" else None, "counterexample": finding if arm == "runhmd" and verdict == "DENIED" else None,
                "human_label": None, "wall_s": rec["wall_s"], "human_interventions": 0, "tokens": rec["tokens"], "cost_usd": rec["cost_usd"],
                "cost_source": rec["cost_source"], "price_basis": rec["price_basis"],
                "naive": rec["naive"]["result"], "attackable": task.get("profile") == "settlement-webhook/1", "infra_error": rec["infra_error"],
                "anchor": str(task.get("source", "")).startswith("author-written"), "over_cap": rec["capped"],
                "ground_truth_failure": rec["ground_truth"].get("failure"),
            })
    os.makedirs(args.out, exist_ok=True)
    for arm in arms:
        _write_rows(os.path.join(args.out, arm + ".jsonl"), rows[arm])
    _write_env(args.out)
    sys.stdout.write("false-green Study A: %d run(s) by %s, $%.2f spent%s -> %s\n"
                     % (len(rows[arms[0]]), args.agent, spent, ", %d unmetered (their cost is unknown, not zero)" % unmetered if unmetered else "", args.out))
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────────────────────
class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("benchmark: %s (see benchmark --help)\n" % message)
        sys.exit(2)


def _parser():
    p = _Parser(prog="benchmark", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command", required=True, parser_class=_Parser)
    for name in ("validate", "run", "summarize"):
        s = sub.add_parser(name)
        s.add_argument("--suite", default="false-green")
        if name == "run":
            s.add_argument("--agent")
            s.add_argument("--agent-cmd", dest="agent_cmd")
            s.add_argument("--arm", choices=("alone", "runhmd", "both"), default="both")
            s.add_argument("--dry", action="store_true")
            s.add_argument("--live", action="store_true")
            s.add_argument("--confirm-spend", dest="confirm_spend", action="store_true")
            s.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
            s.add_argument("--only", help="comma-separated case ids (tests)")
        if name in ("run", "summarize"):
            s.add_argument("--out", help="run: results directory; summarize: also write the summary here")
        if name == "summarize":
            s.add_argument("--in", dest="results")
            s.add_argument("--json", action="store_true")
    return p


def main(argv):
    args = _parser().parse_args(argv)
    if args.suite != "false-green":
        sys.stderr.write("benchmark: unknown suite %r (the only suite here is false-green)\n" % args.suite)
        return 2
    if args.command == "validate":
        problems = validate()
        for problem in problems:
            sys.stderr.write("benchmark validate: %s\n" % problem)
        if not problems:
            sys.stdout.write("benchmark validate: ok (freeze intact, case set reproduces, ground truth present)\n")
        return 1 if problems else 0
    if args.command == "summarize":
        try:
            summary = fg_summary.summarize(fg_summary.load_rows(args.results or os.path.join(SUITE, "results")))
        except (OSError, ValueError) as exc:
            sys.stderr.write("benchmark summarize: %s\n" % exc)
            return 2
        text = fg_summary.render(summary)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as fh:
                fh.write(text)
        sys.stdout.write(text if args.json else "%s\n%s\n" % (summary["headline"], summary["judge_calibration"]["headline"]))
        return 0
    only = set(args.only.split(",")) if args.only else None
    if args.agent is None:
        out = args.out or os.path.join(SUITE, "results")
        return plan_study_b(SUITE, out, only) if args.dry else run_study_b(SUITE, out, max(1, args.jobs), only)
    args.out = args.out or os.path.join(SUITE, "results")
    if args.agent not in AGENT_TEMPLATES and not args.agent_cmd:
        sys.stderr.write("benchmark run: unknown agent %r (known: %s; or pass --agent-cmd)\n" % (args.agent, ", ".join(sorted(AGENT_TEMPLATES))))
        return 2
    if not args.live:
        return plan_study_a(SUITE, args)
    if not args.confirm_spend:
        plan_study_a(SUITE, args)
        sys.stderr.write("benchmark run: --live spends real money; pass --confirm-spend to proceed (exit 3 = consent required)\n")
        return 3
    if args.agent not in VERIFIED_AGENTS and not args.agent_cmd:
        sys.stderr.write("benchmark run: the %s command template is untested in this tree; pass --agent-cmd to run it\n" % args.agent)
        return 2
    problems = validate()
    if problems:
        sys.stderr.write("benchmark run: refusing, the freeze is not intact:\n" + "".join("  %s\n" % p for p in problems))
        return 1
    return run_study_a_live(SUITE, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
