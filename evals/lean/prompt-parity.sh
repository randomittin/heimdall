#!/usr/bin/env bash
# prompt-parity.sh -- lean-core plan T5.1: oracle gate (gate_type differential, independent) for agents/heimdall-lean.md.
# Same fixed task set (evals/lean/tasks.json) through agent `heimdall` and `heimdall-lean`; the WHOLE ordered trace of each task
# (spawned agents, gates invoked, files touched) must be equal.
#
#   bash evals/lean/prompt-parity.sh            CHECK (no model call): compare the traces in evals/lean/traces/{full,lean}/<task>.json and write
#                                               evals/lean/prompt-parity.receipt.json (what install.sh lean_reset_prompt reads). Verdicts:
#                                                 green       every trace is source "live" (with recorded_at + model), bound to the CURRENT prompt
#                                                             sha256, and every task's two traces are equal. The ONLY verdict install.sh --reset acts on.
#                                                 unverified  nothing differs but there is no live evidence (no traces yet, or any trace that is not
#                                                             source "live"). install.sh treats it like red: the lean prompt is skipped. Exit 2.
#                                                 red         a mismatch, a stale / malformed / half-missing trace. Exit 1.
#   bash evals/lean/prompt-parity.sh --record   LIVE, COSTS MODEL BUDGET, operator-run only: runs each task through
#                                                 claude -p --agent hmd:heimdall       (reference)
#                                                 claude -p --agent hmd:heimdall-lean  (candidate)
#                                               in a fresh scratch git repo (--plugin-dir = this repo, --permission-mode bypassPermissions, stream-json),
#                                               extracts spawn (Agent/Task subagent_type), gate (Bash running lint / verify-edits) and touch (Write/Edit
#                                               paths, relative to the scratch repo) events, and writes live traces with recorded_at, model and the
#                                               prompt sha256. Then run the CHECK above for the verdict. HMD_PARITY_TIMEOUT_S bounds one run (default 1800).
# HMD_PARITY_ROOT overrides the repo root (tests use a fixture copy). The test never runs --record.
set -u
root="${HMD_PARITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
mode=check
case "${1:-}" in
  "") ;;
  --record) mode=record ;;
  *) echo "usage: prompt-parity.sh [--record]" >&2; exit 64 ;;
esac
exec python3 -I - "$root" "$mode" <<'PY'
import datetime, hashlib, json, os, re, shutil, subprocess, sys, tempfile

root, mode = sys.argv[1], sys.argv[2]
lean_dir = os.path.join(root, "evals", "lean")
receipt_path = os.path.join(lean_dir, "prompt-parity.receipt.json")
PROFILES = {  # profile -> (prompt file, agent name passed to claude)
    "full": ("agents/heimdall.md", "hmd:heimdall"),
    "lean": ("agents/heimdall-lean.md", "hmd:heimdall-lean"),
}
GATES = [("lint", re.compile(r"(^|[\s/;&|])\S*lint\S*")), ("verify-edits --quick", re.compile(r"verify-edits"))]


def sha(rel):
    try:
        with open(os.path.join(root, rel), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError, RecursionError):
        return None


def task_ids():
    tasks = load(os.path.join(lean_dir, "tasks.json"))
    if not (isinstance(tasks, dict) and isinstance(tasks.get("tasks"), list)):
        return []
    ids = [t.get("id") for t in tasks["tasks"] if isinstance(t, dict)]
    if not ids or not all(isinstance(i, str) and i for i in ids) or len(set(ids)) != len(ids):
        return []
    return ids


def events_of_stream(lines, cwd):
    """Reduce claude stream-json output to (model, [events]): spawn / gate / touch, consecutive duplicates collapsed."""
    model, events = "", []

    def add(kind, name):
        if not events or events[-1] != {"kind": kind, "name": name}:
            events.append({"kind": kind, "name": name})

    for line in lines:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        if msg.get("type") == "system" and msg.get("subtype") == "init" and isinstance(msg.get("model"), str):
            model = msg["model"]
        if msg.get("type") != "assistant":
            continue
        for block in (msg.get("message") or {}).get("content") or []:
            if not (isinstance(block, dict) and block.get("type") == "tool_use"):
                continue
            tool, inp = block.get("name"), block.get("input") or {}
            if tool in ("Agent", "Task") and isinstance(inp.get("subagent_type"), str):
                add("spawn", inp["subagent_type"])
            elif tool == "Bash" and isinstance(inp.get("command"), str):
                for name, rx in GATES:
                    if rx.search(inp["command"]):
                        add("gate", name)
                        break
            elif tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
                p = inp.get("file_path") or inp.get("notebook_path")
                if isinstance(p, str) and p:
                    real = os.path.realpath(cwd)
                    p = os.path.relpath(p, real) if os.path.isabs(p) and p.startswith(real + os.sep) else p
                    add("touch", p)
    return model, events


def record():
    ids = task_ids()
    if not ids:
        print("prompt-parity --record: tasks.json has no valid task list", file=sys.stderr)
        return 1
    tasks = {t["id"]: t["prompt"] for t in load(os.path.join(lean_dir, "tasks.json"))["tasks"]}
    timeout = int(os.environ.get("HMD_PARITY_TIMEOUT_S", "1800"))
    print("prompt-parity --record: LIVE runs, %d task(s) x 2 agents, this spends model budget" % len(ids))
    for tid in ids:
        for prof, (prompt_rel, agent) in PROFILES.items():
            prompt_sha = sha(prompt_rel)
            if prompt_sha is None:
                print("missing " + prompt_rel, file=sys.stderr)
                return 1
            with tempfile.TemporaryDirectory(prefix="hmd-parity-") as cwd:
                subprocess.run(["git", "init", "-q", cwd], check=True)
                cmd = ["claude", "-p", "--agent", agent, "--plugin-dir", root, "--permission-mode", "bypassPermissions",
                       "--output-format", "stream-json", "--verbose", tasks[tid]]
                try:
                    done = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
                except (OSError, subprocess.TimeoutExpired) as e:
                    print("%s/%s: claude run failed: %s" % (prof, tid, e), file=sys.stderr)
                    return 1
                if done.returncode != 0:
                    print("%s/%s: claude exited %d" % (prof, tid, done.returncode), file=sys.stderr)
                    return 1
                model, events = events_of_stream(done.stdout.splitlines(), cwd)
            if not model or not events:
                print("%s/%s: no model or no events in the stream; not recording" % (prof, tid), file=sys.stderr)
                return 1
            out_dir = os.path.join(lean_dir, "traces", prof)
            os.makedirs(out_dir, exist_ok=True)
            trace = {"task": tid, "agent": agent, "source": "live", "model": model,
                     "recorded_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "prompt_sha256": prompt_sha, "events": events}
            dest = os.path.join(out_dir, tid + ".json")
            with open(dest + ".tmp", "w") as f:
                json.dump(trace, f, indent=2)
                f.write("\n")
            os.replace(dest + ".tmp", dest)
            print("recorded %s/%s (%d events, model %s)" % (prof, tid, len(events), model))
    print("now run: bash evals/lean/prompt-parity.sh")
    return 0


def norm(events):
    if not isinstance(events, list):
        return None
    out = []
    for e in events:
        if not (isinstance(e, dict) and e.get("kind") in ("spawn", "gate", "touch")
                and isinstance(e.get("name"), str) and e["name"]):
            return None
        out.append((e["kind"], e["name"]))
    return out


def live_shaped(d):
    return (d.get("source") == "live" and isinstance(d.get("model"), str) and d["model"]
            and isinstance(d.get("recorded_at"), str) and d["recorded_at"])


def check():
    problems, unverified = [], []
    lean_sha, full_sha = sha(PROFILES["lean"][0]), sha(PROFILES["full"][0])
    if lean_sha is None:
        problems.append("missing " + PROFILES["lean"][0])
    if full_sha is None:
        problems.append("missing " + PROFILES["full"][0])
    ids = task_ids()
    if not ids:
        problems.append("tasks.json: no valid task list")
    checked = missing = 0
    for tid in ids:
        traces = {}
        for prof, want in (("full", full_sha), ("lean", lean_sha)):
            d = load(os.path.join(lean_dir, "traces", prof, tid + ".json"))
            if not isinstance(d, dict):
                missing += 1
                problems.append("%s/%s: trace missing or unreadable" % (prof, tid))
                continue
            ev = norm(d.get("events"))
            if not ev:
                problems.append("%s/%s: malformed or empty events" % (prof, tid))
                continue
            if d.get("task") != tid:
                problems.append("%s/%s: trace names another task" % (prof, tid))
                continue
            if want is None or d.get("prompt_sha256") != want:
                problems.append("%s/%s: trace recorded against a different prompt (stale)" % (prof, tid))
                continue
            if not live_shaped(d):
                unverified.append("%s/%s: not a live trace (source %r)" % (prof, tid, d.get("source")))
            traces[prof] = ev
        if len(traces) == 2:
            checked += 1
            a, b = traces["full"], traces["lean"]
            if a != b:
                i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
                problems.append("%s: traces differ at event %d (full=%s lean=%s)" % (
                    tid, i, a[i] if i < len(a) else None, b[i] if i < len(b) else None))
    if ids and missing == 2 * len(ids) and len(problems) == missing:
        problems, unverified = [], ["no traces recorded: run prompt-parity.sh --record (live, spends budget)"]
    if problems:
        verdict = "red"
    elif unverified or not ids or checked != len(ids):
        verdict = "unverified"
    else:
        verdict = "green"
    receipt = {"verdict": verdict, "lean_prompt_sha256": lean_sha or "", "gate_type": "differential", "independent": True,
               "tasks": checked, "problems": problems, "unverified_reasons": unverified}
    tmp = receipt_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(receipt, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, receipt_path)
    for p in problems + unverified:
        print(("RED: " if p in problems else "UNVERIFIED: ") + p)
    print("prompt-parity: %s (%d task(s) compared)" % (verdict, checked))
    return {"green": 0, "red": 1}.get(verdict, 2)


sys.exit(record() if mode == "record" else check())
PY
