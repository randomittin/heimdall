#!/usr/bin/env bash
# prompt-parity.sh -- lean-core plan T5.1: oracle gate (gate_type differential, independent) for agents/heimdall-lean.md.
# Same fixed task set (evals/lean/tasks.json) through agent `heimdall` and `heimdall-lean`; the WHOLE ordered trace of each task
# (spawned agents, gates invoked, files touched) must be equal. REPLAY ONLY: no live model budget, so this reads the recorded traces in
# evals/lean/traces/{full,lean}/<task>.json and says so on stdout and in the receipt ("replayed": true, "live": false).
# A trace binds the sha256 of the prompt it was recorded against; a stale trace is red (a green receipt cannot vouch for an edited prompt).
# On green writes evals/lean/prompt-parity.receipt.json {"verdict":"green","lean_prompt_sha256":...} (what install.sh lean_reset_prompt reads);
# on red writes verdict "red". HMD_PARITY_ROOT overrides the repo root (tests use a fixture copy). Exit 0 green, 1 red.
set -u
root="${HMD_PARITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
echo "prompt-parity: REPLAY of recorded traces (no live model run)"
exec python3 -I - "$root" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
lean_dir = os.path.join(root, "evals", "lean")
receipt_path = os.path.join(lean_dir, "prompt-parity.receipt.json")
PROMPTS = {"full": "agents/heimdall.md", "lean": "agents/heimdall-lean.md"}
problems = []


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


lean_sha = sha(PROMPTS["lean"])
full_sha = sha(PROMPTS["full"])
if lean_sha is None:
    problems.append("missing " + PROMPTS["lean"])
if full_sha is None:
    problems.append("missing " + PROMPTS["full"])
tasks = load(os.path.join(lean_dir, "tasks.json"))
ids = []
if isinstance(tasks, dict) and isinstance(tasks.get("tasks"), list):
    ids = [t.get("id") for t in tasks["tasks"] if isinstance(t, dict)]
if not ids or not all(isinstance(i, str) and i for i in ids) or len(set(ids)) != len(ids):
    problems.append("tasks.json: no valid task list")
    ids = []
checked = 0
for tid in ids:
    traces = {}
    for prof, want in (("full", full_sha), ("lean", lean_sha)):
        d = load(os.path.join(lean_dir, "traces", prof, tid + ".json"))
        if not isinstance(d, dict):
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
        traces[prof] = ev
    if len(traces) == 2:
        checked += 1
        a, b = traces["full"], traces["lean"]
        if a != b:
            i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
            problems.append("%s: traces differ at event %d (full=%s lean=%s)" % (
                tid, i, a[i] if i < len(a) else None, b[i] if i < len(b) else None))
verdict = "green" if (not problems and ids and checked == len(ids)) else "red"
receipt = {"verdict": verdict, "lean_prompt_sha256": lean_sha or "", "gate_type": "differential",
           "independent": True, "replayed": True, "live": False, "tasks": checked, "problems": problems}
tmp = receipt_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(receipt, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, receipt_path)
for p in problems:
    print("RED: " + p)
print("prompt-parity: %s (%d task(s) compared, replayed, not live)" % (verdict, checked))
sys.exit(0 if verdict == "green" else 1)
PY
