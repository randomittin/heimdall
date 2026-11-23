#!/usr/bin/env python3
"""Pre-registered A/B of coding-agent thinking effort: high (arm A) vs medium (arm B).

Design, decision rule and limits are fixed in docs/analysis/2026-11-23-effort-ab.md, written and
committed BEFORE the first measured run. Every run: a fresh temp git repo seeded from
tasks/<id>/seed, `claude -p` headless in a scrubbed environment, then the hidden tasks/<id>/accept.sh
decides pass/fail. One JSONL row per attempt; analysis is analyze.py.

Safety: the child never inherits this process's environment (no tokens, no proxy, no session
pointers); --safe-mode disables hooks, plugins, CLAUDE.md and MCP; --no-session-persistence writes no
transcript; the disk floor and the account's 5-hour usage window are checked between runs.
"""
import argparse
import gzip
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARMS = ("high", "medium")  # arm A, arm B
TOOLS = "Bash,Read,Edit,Write,Glob,Grep"
MAX_CONCURRENT = 3
SUFFIX = (
    "\n\nWork only inside the current directory (a fresh git repository); do not read or write "
    "outside it. Run the visible tests before you finish. When done, reply with one short sentence."
)
KEEP_ENV = ("HOME", "PATH", "TMPDIR", "LANG", "USER", "LOGNAME")


def child_env():
    """The ONLY environment a child ever sees: no tokens, no ANTHROPIC_*, no CLAUDE_* session state."""
    env = {k: os.environ[k] for k in KEEP_ENV if k in os.environ}
    env.setdefault("LANG", "en_US.UTF-8")
    env.update(
        TERM="dumb", NO_COLOR="1", PYTHONDONTWRITEBYTECODE="1", GIT_TERMINAL_PROMPT="0",
        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
        GIT_AUTHOR_NAME="effort-ab", GIT_AUTHOR_EMAIL="effort-ab@invalid",
        GIT_COMMITTER_NAME="effort-ab", GIT_COMMITTER_EMAIL="effort-ab@invalid",
    )
    return env


def claude_cmd(claude, model, effort, budget):
    return [
        claude, "-p", "--model", model, "--effort", effort, "--safe-mode", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--include-hook-events",
        "--permission-mode", "acceptEdits", "--permission-prompts", "none",
        "--max-budget-usd", str(budget), "--tools", TOOLS, "--allowedTools", TOOLS,
    ]


def build_schedule(task_ids, reps, seed):
    """Interleaved, counterbalanced: each (task, rep) is an adjacent A/B pair, arm order alternates by
    (task index + rep), task order is a seeded shuffle per rep. Deterministic."""
    ordered = sorted(task_ids)
    jobs = []
    for rep in range(1, reps + 1):
        shuffled = list(ordered)
        random.Random(f"{seed}:{rep}").shuffle(shuffled)
        for task in shuffled:
            first = (ordered.index(task) + rep) % 2
            for arm in (ARMS[first], ARMS[1 - first]):
                jobs.append({"task": task, "rep": rep, "arm": arm})
    return jobs


def git(cwd, *args):
    return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=cwd, env=child_env(),
                          capture_output=True, text=True, timeout=60)


def make_workdir(task_dir, tmp_root):
    work = Path(tempfile.mkdtemp(prefix=f"effort-ab.{task_dir.name}.", dir=tmp_root))
    shutil.copytree(task_dir / "seed", work, dirs_exist_ok=True)
    git(work, "init", "-q")
    (work / ".git" / "info" / "exclude").write_text("__pycache__/\n*.pyc\nnode_modules/\n")
    git(work, "add", "-A")
    git(work, "commit", "-q", "-m", "seed")
    return work


def run_accept(task_dir, work):
    env = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "LANG") if k in os.environ}
    env.update(ACCEPT_DIR=str(task_dir), PYTHONDONTWRITEBYTECODE="1", TERM="dumb")
    try:
        p = subprocess.run(["bash", str(task_dir / "accept.sh")], cwd=work, env=env,
                           capture_output=True, text=True, timeout=60)
        return p.returncode, (p.stdout + p.stderr)[-500:]
    except subprocess.TimeoutExpired:
        return 124, "accept.sh timed out"


def parse_stream(path):
    out = {"result": None, "init": None, "think": 0, "tools": {}, "hooks": 0, "rate": None}
    last = 0
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            kind, sub = ev.get("type") or "", ev.get("subtype") or ""
            if kind == "result":
                out["result"] = ev
            elif kind == "system" and sub == "init":
                out["init"] = ev
            elif kind == "system" and sub == "thinking_tokens":
                est = ev.get("estimated_tokens") or 0
                if est < last:  # estimate restarts with every assistant message
                    out["think"] += last
                last = est
            elif kind.startswith("hook") or sub.startswith("hook"):
                out["hooks"] += 1
            elif kind == "rate_limit_event":
                out["rate"] = ev.get("rate_limit_info")
            elif kind == "assistant":
                for block in (ev.get("message") or {}).get("content") or []:
                    if block.get("type") == "tool_use":
                        name = block.get("name")
                        out["tools"][name] = out["tools"].get(name, 0) + 1
    out["think"] += last
    return out


def five_hour_util(rate):
    try:
        return float(rate["unifiedWindows"]["five_hour"]["utilization"])
    except (TypeError, KeyError, ValueError):
        return None


def metrics(parsed):
    res = parsed["result"] or {}
    usage = res.get("usage") or {}
    models = res.get("modelUsage") or {}
    pick = lambda mk, uk: sum((m.get(mk) or 0) for m in models.values()) if models else (usage.get(uk) or 0)
    return {
        "output_tokens": pick("outputTokens", "output_tokens"),
        "usage_output_tokens": usage.get("output_tokens") or 0,
        "input_tokens": pick("inputTokens", "input_tokens"),
        "cache_read_tokens": pick("cacheReadInputTokens", "cache_read_input_tokens"),
        "cache_write_tokens": pick("cacheCreationInputTokens", "cache_creation_input_tokens"),
        "cost_usd": res.get("total_cost_usd") or 0.0,
        "num_turns": res.get("num_turns") or 0,
        "duration_ms": res.get("duration_ms") or 0,
        "duration_api_ms": res.get("duration_api_ms") or 0,
        "is_error": bool(res.get("is_error")),
        "subtype": res.get("subtype"),
        "terminal_reason": res.get("terminal_reason"),
        "stop_reason": res.get("stop_reason"),
        "permission_denials": len(res.get("permission_denials") or []),
        "models": sorted(models),
        "result_chars": len(res.get("result") or ""),
        "thinking_est_tokens": parsed["think"],
        "tool_calls": parsed["tools"],
        "hook_events": parsed["hooks"],
        "five_hour_util": five_hour_util(parsed["rate"]),
        "claude_version": (parsed["init"] or {}).get("claude_code_version"),
    }


def infra_reason(parsed, rc, timed_out):
    """An infra failure is not a model outcome: it is re-run. A timeout and the budget cap are outcomes."""
    if timed_out:
        return ""
    res = parsed["result"]
    if res is None:
        return f"no result event (exit {rc})"
    if res.get("is_error") and res.get("subtype") != "error_max_budget_usd":
        return f"{res.get('subtype')} api_error_status={res.get('api_error_status')}"
    return ""


def free_pct(path):
    usage = shutil.disk_usage(path)
    return 100.0 * usage.free / usage.total


def execute(job, args, state):
    task_dir = args.tasks_dir / job["task"]
    task = json.loads((task_dir / "task.json").read_text())
    prompt = task["prompt"] + SUFFIX
    key = (job["task"], job["arm"], job["rep"])
    for attempt in range(state["attempts"].get(key, 0) + 1, state["attempts"].get(key, 0) + 4):
        if state["stop"].is_set() or time.monotonic() > state["deadline"]:
            return
        if free_pct(args.tmp_root) < args.min_free_pct:
            state["stop"].set()
            state["why"] = f"free disk below {args.min_free_pct}%"
            return
        work = make_workdir(task_dir, args.tmp_root)
        tag = f"{job['task']}.{job['arm']}.r{job['rep']}.a{attempt}"
        raw = args.streams_dir / f"{tag}.jsonl"
        prompt_file = args.streams_dir / f"{tag}.prompt"
        prompt_file.write_text(prompt)
        cmd = claude_cmd(args.claude, args.model, job["arm"], args.budget_usd)
        t0, timed_out = time.monotonic(), False
        with open(prompt_file) as stdin, open(raw, "w") as stdout, open(f"{raw}.err", "w") as stderr:
            proc = subprocess.Popen(cmd, cwd=work, env=child_env(), stdin=stdin, stdout=stdout,
                                    stderr=stderr, start_new_session=True)
            state["procs"].add(proc.pid)
            try:
                proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)  # our own session/group only
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
        wall = time.monotonic() - t0
        parsed = parse_stream(raw)
        reason = infra_reason(parsed, proc.returncode, timed_out)
        rc, tail = run_accept(task_dir, work)
        git(work, "add", "-A")
        patch = git(work, "diff", "--cached", "HEAD").stdout
        stat = git(work, "diff", "--cached", "--numstat", "HEAD").stdout.split("\n")
        changed = [ln.split("\t") for ln in stat if ln.strip()]
        final = (not reason) or attempt >= state["attempts"].get(key, 0) + 3
        row = {
            "kind": "run", "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "task": job["task"],
            "difficulty": task.get("difficulty"), "rep": job["rep"], "arm": job["arm"],
            "effort": job["arm"], "model_requested": args.model, "attempt": attempt, "counted": final,
            "pass": rc == 0 and not reason, "accept_rc": rc, "accept_tail": tail,
            "timed_out": timed_out, "exit_code": proc.returncode, "wall_s": round(wall, 1),
            "infra_failure": bool(reason), "infra_reason": reason,
            "files_changed": len(changed),
            "diff_lines": sum(int(c[0]) + int(c[1]) for c in changed if c[0].isdigit() and c[1].isdigit()),
            **metrics(parsed),
        }
        (args.patches_dir / f"{tag}.patch").write_text(patch[:200000])
        with open(raw, "rb") as src, gzip.open(f"{raw}.gz", "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.remove(raw)
        prompt_file.unlink(missing_ok=True)
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        with state["lock"]:
            state["done"] += 1
            state["spend"] += row["cost_usd"]
            with open(args.results, "a") as fh:
                fh.write(json.dumps(row) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
            print(f"[{state['done']}/{state['total']}] {job['task']} r{job['rep']} {job['arm']:<6} "
                  f"attempt={attempt} pass={int(row['pass'])} out={row['output_tokens']} "
                  f"turns={row['num_turns']} wall={row['wall_s']}s cost=${row['cost_usd']:.3f}"
                  f"{' INFRA:' + reason if reason else ''}", flush=True)
            util = row["five_hour_util"]
            if util is not None and util >= args.stop_util:
                state["stop"].set()
                state["why"] = f"five-hour usage window at {util:.0%}"
            if state["spend"] >= args.max_total_usd:
                state["stop"].set()
                state["why"] = f"total spend cap ${args.max_total_usd} reached"
        if final:
            return


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tasks-dir", type=Path, default=HERE / "tasks")
    ap.add_argument("--results", type=Path, default=HERE / "results" / "runs.jsonl")
    ap.add_argument("--only", default="", help="comma-separated task ids")
    ap.add_argument("--arms", default=",".join(ARMS), help="subset of high,medium (smoke runs only)")
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--seed", default="20261123")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--concurrency", type=int, default=MAX_CONCURRENT)
    ap.add_argument("--timeout", type=int, default=900, help="seconds per run")
    ap.add_argument("--budget-usd", type=float, default=2.0, help="per-run cap passed to claude")
    ap.add_argument("--max-total-usd", type=float, default=60.0)
    ap.add_argument("--stop-util", type=float, default=0.90, help="stop when the 5-hour window reaches this")
    ap.add_argument("--min-free-pct", type=float, default=10.0)
    ap.add_argument("--claude", default=os.environ.get("EFFORT_AB_CLAUDE") or shutil.which("claude"))
    ap.add_argument("--tmp-root", type=Path, default=Path(tempfile.gettempdir()))
    ap.add_argument("--keep", action="store_true", help="keep each run's workdir")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    only = {t for t in args.only.split(",") if t}
    tasks = sorted(p.name for p in args.tasks_dir.iterdir() if (p / "task.json").is_file())
    tasks = [t for t in tasks if not only or t in only]
    arms = [a for a in args.arms.split(",") if a in ARMS]
    jobs = [j for j in build_schedule(tasks, args.reps, args.seed) if j["arm"] in arms]
    args.concurrency = max(1, min(args.concurrency, MAX_CONCURRENT))
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.streams_dir = args.results.parent / "streams"
    args.patches_dir = args.results.parent / "patches"
    if args.dry_run:
        json.dump({"claude": claude_cmd(args.claude or "claude", args.model, "<effort>", args.budget_usd),
                   "child_env_names": sorted(child_env()), "concurrency": args.concurrency,
                   "jobs": jobs}, sys.stdout, indent=1)
        print()
        return 0
    if not args.claude:
        print("error: claude binary not found (set --claude or EFFORT_AB_CLAUDE)", file=sys.stderr)
        return 2
    args.streams_dir.mkdir(parents=True, exist_ok=True)
    args.patches_dir.mkdir(parents=True, exist_ok=True)

    attempts, counted = {}, set()
    if args.results.exists():
        for line in args.results.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                key = (row["task"], row["arm"], row["rep"])
                attempts[key] = max(attempts.get(key, 0), row["attempt"])
                if row.get("counted"):
                    counted.add(key)
    todo = [j for j in jobs if (j["task"], j["arm"], j["rep"]) not in counted]
    state = {"lock": threading.Lock(), "stop": threading.Event(), "why": "", "done": 0, "spend": 0.0,
             "total": len(todo), "attempts": attempts}
    print(f"effort-ab: {len(todo)} runs to do ({len(jobs) - len(todo)} already counted), "
          f"concurrency {args.concurrency}, results {args.results}", flush=True)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for fut in [pool.submit(execute, j, args, state) for j in todo]:
            fut.result()
    print(f"effort-ab: finished {state['done']} attempts, spend ${state['spend']:.2f}"
          + (f", STOPPED: {state['why']}" if state["stop"].is_set() else ""), flush=True)
    return 3 if state["stop"].is_set() else 0


if __name__ == "__main__":
    sys.exit(main())
