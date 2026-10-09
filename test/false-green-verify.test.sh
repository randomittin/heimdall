#!/usr/bin/env bash
# test/false-green-verify.test.sh: the mechanical verification that turns a candidate into a Study A task
# (evals/benchmark/false-green/PREREG.md section 5 and Amendment 2), bin/lib/fg_verify.py.
#
# WHAT THIS PROVES, against local fake upstream repositories (no network, no PyPI):
#   [V] VERIFY   a candidate is accepted only when the upstream tests FAIL at the commit before the merge and PASS at
#                the merge commit; every other outcome is a rejection that says why and leaves nothing behind;
#                an accepted candidate becomes a complete task directory, and the setup recorded in it rebuilds a
#                workspace on which the ground truth gives the same verdict (a task is verified with the steps it is
#                run with).
#   [W] WALK     the candidates are walked in ascending sha256(issue URL) order, every one walked is recorded with its
#                verdict, the first N accepted become tasks and the next becomes the pilot, the walk resumes where it
#                stopped, and it stops (reporting) when the disk is low.
#
# Hermetic: HOME and TMPDIR point into a throwaway dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }
python3 -m pytest --version >/dev/null 2>&1 || { echo "pytest required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks required (the secret-scan section runs it)" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fg-verify-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" TMPDIR="$TMP/tmp"; mkdir -p "$HOME" "$TMPDIR"

report() {  # report <output file>: PASS/FAIL/END lines from a python section; a crash before END is a failure
  local verdict desc detail seen_end=0
  while IFS=$'\t' read -r verdict desc detail; do
    case "$verdict" in
      PASS) ok "$desc" ;;
      FAIL) bad "$desc  [$detail]" ;;
      END)  seen_end=1 ;;
      *)    bad "unexpected line from the python section: $verdict $desc" ;;
    esac
  done <"$1"
  [ "$seen_end" -eq 1 ] || bad "the python section did not run to its end: $(tail -5 "$1.err" 2>/dev/null | tr '\n' ' ')"
}

python3 - "$REPO" "$TMP" >"$TMP/v.out" 2>"$TMP/v.out.err" <<'PY'
import contextlib, io, json, os, subprocess, sys
repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_repo, fg_verify

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else str(detail).replace("\n", " ")[:500]))

remotes = os.path.join(tmp, "remotes")
work_root = os.path.join(tmp, "work")
os.makedirs(work_root)
fg_verify.GITHUB = "file://%s/" % remotes
fg_verify.CLONE_RETRY_S = 0                  # the retry pause is for real networks; its mechanics are tested in [R]
HERMETIC_ENV = (["{python} -m venv --system-site-packages --without-pip .venv"], None)       # no PyPI: pytest comes from the interpreter's own site-packages; no pip either: ensurepip is ~4 s of CPU per workspace and nothing here installs anything
fg_verify.env_steps = lambda tree: HERMETIC_ENV

def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), check=True, capture_output=True, text=True).stdout.strip()

def remote(name, commits):
    """A local upstream repository with one commit per dict of path -> text; returns the commit shas."""
    root = os.path.join(remotes, "acme", name)
    os.makedirs(root)
    git(root, "init", "-q", "-b", "main")
    for key, value in (("user.email", "t@example.invalid"), ("user.name", "t"), ("uploadpack.allowFilter", "true"), ("uploadpack.allowAnySHA1InWant", "true")):
        git(root, "config", key, value)
    shas = []
    for files in commits:
        for path, text in files.items():
            os.makedirs(os.path.dirname(os.path.join(root, path)) or root, exist_ok=True)
            open(os.path.join(root, path), "w").write(text)
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "commit %d" % len(shas))
        shas.append(git(root, "rev-parse", "HEAD"))
    return shas

PYTEST_INI = "[pytest]\npythonpath = .\n"
TEST = "from calc import add\n\ndef test_add():\n    assert add(1, 2) == 3\n"
BUGGY, FIXED = "def add(a, b):\n    return a - b\n", "def add(a, b):\n    return a + b\n"

def candidate(name, merge, tests=("tests/test_calc.py",), number=5):
    return {"issue": "https://github.com/acme/%s/issues/%d" % (name, number), "pr": "https://github.com/acme/%s/pull/%d" % (name, number + 1),
            "merge": merge, "license": "MIT", "kind": "bugfix", "tests": list(tests)}

issue_text = lambda cand: ("Add is broken", "add(1, 2) returns -1 instead of 3")

def verify(cand, tasks):
    with contextlib.redirect_stdout(io.StringIO()):
        return fg_verify.verify_one(cand, work_root, tasks, issue_text, sys.executable)

def leftovers():
    return sorted(os.listdir(work_root))

# ── [V] ─────────────────────────────────────────────────────────────────────
good = remote("good", [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": FIXED, "tests/test_calc.py": TEST}])
tasks = os.path.join(tmp, "tasks")
res = verify(candidate("good", good[1]), tasks)
t("tests that fail before the merge and pass at it: accepted", res["verdict"] == "accepted" and res["reason"] == "", res)
t("the evidence is the two runs: base exit 1 (fail), merge exit 0 (pass)", res["evidence"]["base"]["rc"] == 1 and res["evidence"]["merge"]["rc"] == 0, res.get("evidence"))
t("the evidence carries pytest's last line for each run", "failed" in res["evidence"]["base"]["tail"] and "passed" in res["evidence"]["merge"]["tail"], res.get("evidence"))
t("the work directory is gone afterwards", leftovers() == [], leftovers())

tid = "acme__good-5"
tdir = os.path.join(tasks, tid)
task = json.load(open(os.path.join(tdir, "task.json")))
t("the task directory holds task.json, repo.ref, ground_truth.sh and tests/", all(os.path.exists(os.path.join(tdir, n)) for n in ("task.json", "repo.ref", "ground_truth.sh", "tests/tests/test_calc.py")), os.listdir(tdir))
t("the result names the task and the directory it went to", res["task"] == tid, res)
t("task.json has what the harness validates", all(task.get(k) for k in ("id", "category", "source", "prompt")) and task["id"] == tid and task["category"] == "bugfix"
  and task["source"] == "https://github.com/acme/good/issues/5", task)
t("task.json records the base and merge commits, the kind and the pull request",
  task["base_sha"] == good[0] and task["merge_sha"] == good[1] and task["kind"] == "repo" and task["pr"].endswith("/pull/6") and task["profile"] is None, task)
t("the prompt is the issue", "Add is broken" in task["prompt"] and "add(1, 2) returns -1" in task["prompt"], task["prompt"])
t("repo.ref names the repository, both commits and the licence", good[0] in open(os.path.join(tdir, "repo.ref")).read() and good[1] in open(os.path.join(tdir, "repo.ref")).read() and "MIT" in open(os.path.join(tdir, "repo.ref")).read())
t("the upstream test file is stored as it was at the merge commit", open(os.path.join(tdir, "tests", "tests", "test_calc.py")).read() == TEST)
t("ground_truth.sh is executable and valid bash", os.access(os.path.join(tdir, "ground_truth.sh"), os.X_OK) and subprocess.run(["bash", "-n", os.path.join(tdir, "ground_truth.sh")]).returncode == 0)
t("the first setup step clones the base commit, and the environment steps follow", task["setup"][0].startswith("git init -q . && git remote add origin") and good[0] in task["setup"][0] and task["setup"][1:] == HERMETIC_ENV[0], task["setup"])

# a task is verified with the steps it is run with: rebuild a workspace from the recorded setup and judge it
root = os.path.join(tmp, "replay")
ws = os.path.join(root, "ws")
os.makedirs(ws)
env = fg_repo.clean_env(root)
failure = fg_repo.run_steps(task["setup"], ws, env, root, python=sys.executable)
t("the recorded setup rebuilds a workspace", failure is None, failure)
judged = subprocess.run(["bash", os.path.join(tdir, "ground_truth.sh"), ws], cwd=root, env=env, capture_output=True, text=True)
t("and on that workspace, untouched, the ground truth fails (the issue is unresolved): exit 1", judged.returncode == 1, (judged.returncode, judged.stdout[-300:]))
open(os.path.join(ws, "calc.py"), "w").write(FIXED)
judged = subprocess.run(["bash", os.path.join(tdir, "ground_truth.sh"), ws], cwd=root, env=env, capture_output=True, text=True)
t("and once the agent's change is made, it passes: exit 0", judged.returncode == 0, (judged.returncode, judged.stdout[-300:]))
t("the replayed workspace has no remote, so the agent cannot fetch the upstream fix", subprocess.run(["git", "-C", ws, "remote"], capture_output=True, text=True).stdout.strip() == "")

# rejections
already = remote("already", [{"calc.py": FIXED, "pytest.ini": PYTEST_INI, "tests/test_calc.py": TEST}, {"README": "docs only change"}])
res = verify(candidate("already", already[1]), tasks)
t("tests that already pass before the merge: rejected", res["verdict"] == "rejected" and "already pass at the base commit" in res["reason"], res)
t("and a rejection writes no task", not os.path.exists(os.path.join(tasks, "acme__already-5")))
t("and leaves nothing behind", leftovers() == [], leftovers())

broken = remote("broken", [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": BUGGY + "# the fix never landed\n", "tests/test_calc.py": TEST}])
res = verify(candidate("broken", broken[1]), tasks)
t("tests that still fail at the merge commit: rejected", res["verdict"] == "rejected" and "fail at the merge commit" in res["reason"], res)

res = verify(candidate("good", "f" * 40, number=7), tasks)
t("a merge commit the remote does not have: rejected as a clone failure", res["verdict"] == "rejected" and res["reason"].startswith("clone:"), res)

res = verify(candidate("good", good[1], tests=("tests/test_calc.py", "tests/test_gone.py"), number=8), tasks)
t("a test path that is not in the merge commit: rejected, naming it", res["verdict"] == "rejected" and "test file missing at the merge commit: tests/test_gone.py" in res["reason"], res)

orphan = remote("orphan", [{"calc.py": FIXED, "pytest.ini": PYTEST_INI, "tests/test_calc.py": TEST}])
res = verify(candidate("orphan", orphan[0]), tasks)
t("a merge commit with no parent: rejected", res["verdict"] == "rejected" and "no parent" in res["reason"], res)

big = remote("big", [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": FIXED, "tests/test_calc.py": TEST, "tests/data.bin": "x" * 500_000}])
res = verify(candidate("big", big[1], tests=("tests/test_calc.py", "tests/data.bin")), tasks)
t("upstream test files over 400 KB: rejected", res["verdict"] == "rejected" and "exceed 400 KB" in res["reason"], res)

fg_verify.env_steps = lambda tree: (["exit 7"], None)
res = verify(candidate("good", good[1], number=9), tasks)
t("an environment step that fails: rejected, naming the step", res["verdict"] == "rejected" and res["reason"].startswith("environment: step 1 (exit 7): exit 7"), res)
fg_verify.env_steps = fg_repo.env_steps
res = verify(candidate("good", good[1], number=10), tasks)
t("a tree with no installable python project: rejected with the reason env_steps gives", res["verdict"] == "rejected" and res["reason"] == "no installable python project at the root", res)
fg_verify.env_steps = lambda tree: HERMETIC_ENV

def no_issue(cand):
    raise RuntimeError("gh: HTTP 404")
with contextlib.redirect_stdout(io.StringIO()):
    res = fg_verify.verify_one(candidate("good", good[1], number=11), work_root, tasks, no_issue, sys.executable)
t("an issue whose text cannot be fetched: rejected, never accepted without its prompt", res["verdict"] == "rejected" and "could not fetch the issue text" in res["reason"], res)
t("and writes no task directory", not os.path.exists(os.path.join(tasks, "acme__good-11")))
t("every outcome above left the work root empty", leftovers() == [], leftovers())

# ── [W] ─────────────────────────────────────────────────────────────────────
walk = os.path.join(tmp, "walk")
os.makedirs(walk)
taskgen = __import__("fg_taskgen")
names = ["w%d" % i for i in range(5)]
by_rank = sorted(names, key=lambda n: taskgen.issue_rank("https://github.com/acme/%s/issues/5" % n))
cands = []
for name in names:
    if name == by_rank[1]:
        shas = remote(name, [{"calc.py": FIXED, "pytest.ini": PYTEST_INI, "tests/test_calc.py": TEST}, {"README": "x"}])        # rejected: passes at base
    else:
        shas = remote(name, [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": FIXED, "tests/test_calc.py": TEST}])  # accepted
    cands.append(candidate(name, shas[1]))
cand_file = os.path.join(walk, "candidates.txt")
open(cand_file, "w").write("# pool\n" + "".join(taskgen.format_candidate(c) + "\n" for c in cands))
order = [c["issue"] for c in taskgen.ordered(cands)]
record, tasks_dir, pilot_dir = os.path.join(walk, "selection.jsonl"), os.path.join(walk, "tasks"), os.path.join(walk, "pilot")
fg_repo.container_free_bytes = lambda: 50 * 10**9

def walk_once(want, spares):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return fg_verify.verify_all(cand_file, tasks_dir, pilot_dir, record, work_root, want, spares, issue_text, sys.executable)

rc = walk_once(want=2, spares=1)
rows = [json.loads(l) for l in open(record)]
t("the walk ends normally once it has the tasks and the pilot", rc == 0, rc)
t("every candidate walked is recorded, in sha256(issue URL) order, with its rank", [r["issue"] for r in rows] == order[:len(rows)] and [r["rank"] for r in rows] == list(range(1, len(rows) + 1)), [(r["rank"], r["issue"]) for r in rows])
t("each record carries the hash, the verdict and the reason", all(r["sha256"] == fg_verify.issue_rank(r["issue"]) and r["verdict"] in ("accepted", "rejected") for r in rows))
accepted = [r for r in rows if r["verdict"] == "accepted"]
t("the walk stopped after the 3rd accepted candidate (2 tasks and 1 pilot)", len(accepted) == 3 and rows[-1]["verdict"] == "accepted", [(r["rank"], r["verdict"]) for r in rows])
t("the first two accepted are tasks, the third is the pilot", [r["role"] for r in accepted] == ["task", "task", "pilot"], [r["role"] for r in accepted])
t("tasks went to tasks/ and the pilot to pilot/, and nowhere else", sorted(os.listdir(tasks_dir)) == sorted(r["task"] for r in accepted[:2]) and os.listdir(pilot_dir) == [accepted[2]["task"]])
t("a rejection is in the walk, recorded with its reason and no role", [r["verdict"] for r in rows].count("rejected") == 1 and all(r["reason"] and r["role"] is None for r in rows if r["verdict"] == "rejected"), [(r["rank"], r["verdict"]) for r in rows])

rc = walk_once(want=2, spares=1)
t("walking again with nothing left to do changes nothing", rc == 0 and [json.loads(l) for l in open(record)] == rows)

# resume: a record that already holds the first rank is not walked again
os.remove(os.path.join(walk, "selection.jsonl"))
shutil_rm = __import__("shutil").rmtree
shutil_rm(tasks_dir); shutil_rm(pilot_dir)
first = rows[0]
open(record, "w").write(json.dumps(first) + "\n")
walk_once(want=2, spares=1)
resumed = [json.loads(l) for l in open(record)]
t("a walk resumes after the candidates already recorded, and does not walk them again", [r["issue"] for r in resumed].count(first["issue"]) == 1 and resumed[0] == first, [r["rank"] for r in resumed])
t("and the resumed walk reaches the same verdicts for the rest", [(r["issue"], r["verdict"]) for r in resumed] == [(r["issue"], r["verdict"]) for r in rows])

# the disk probe reads diskutil's Container Free Space and fails closed when it cannot
sample = "   Container Total Space:     245.1 GB (245107195904 Bytes) (exactly 478724992 512-Byte-Units)\n   Container Free Space:      7.4 GB (7390576640 Bytes) (exactly 14434720 512-Byte-Units)\n"
t("the container free space is parsed from diskutil's own text", fg_repo.parse_container_free(sample) == 7390576640, fg_repo.parse_container_free(sample))
try:
    fg_repo.parse_container_free("no such line\n")
    t("text with no Container Free Space line is an error, not 'plenty of space'", False, "no exception")
except RuntimeError as exc:
    t("text with no Container Free Space line is an error, not 'plenty of space'", "Container Free Space" in str(exc), str(exc))

# the disk guard
shutil_rm(tasks_dir); shutil_rm(pilot_dir); os.remove(record)
fg_repo.container_free_bytes = lambda: 1 * 10**9
err = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    rc = fg_verify.verify_all(cand_file, tasks_dir, pilot_dir, record, work_root, 2, 1, issue_text, sys.executable)
t("with under 3 GB free the walk stops before cloning anything, exit 3, and says so", rc == 3 and "3 GB" in err.getvalue() and not os.path.exists(record), (rc, err.getvalue()))
t("and the work root is untouched", leftovers() == [], leftovers())

# ── [P] a parallel walk decides exactly what a sequential one does ──────────
import hashlib, threading, time
fg_repo.container_free_bytes = lambda: 50 * 10**9
fg_verify.env_steps = lambda tree: HERMETIC_ENV
pnames = ["p%d" % i for i in range(8)]
p_order = sorted(["https://github.com/acme/%s/issues/5" % n for n in pnames], key=taskgen.issue_rank)
p_by_rank = [u.split("/")[4] for u in p_order]
p_cands = []
for name in pnames:
    if name in (p_by_rank[1], p_by_rank[3]):
        shas = remote(name, [{"calc.py": FIXED, "pytest.ini": PYTEST_INI, "tests/test_calc.py": TEST}, {"README": "x"}])        # rejected: passes at base
    else:
        shas = remote(name, [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": FIXED, "tests/test_calc.py": TEST}])  # accepted
    p_cands.append(candidate(name, shas[1]))
p_file = os.path.join(tmp, "p_candidates.txt")
open(p_file, "w").write("# pool\n" + "".join(taskgen.format_candidate(c) + "\n" for c in p_cands))

def full_walk(tag, jobs, want=2, spares=1, free=None):
    root = os.path.join(tmp, tag)
    os.makedirs(root, exist_ok=True)
    paths = {k: os.path.join(root, k) for k in ("tasks", "pilot", "selection.jsonl")}
    if free:
        fg_repo.container_free_bytes = free
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        rc = fg_verify.verify_all(p_file, paths["tasks"], paths["pilot"], paths["selection.jsonl"], work_root, want, spares, issue_text, sys.executable, jobs)
    rows = [json.loads(l) for l in open(paths["selection.jsonl"])] if os.path.exists(paths["selection.jsonl"]) else []
    return rc, rows, paths

view = lambda rows: [(r["rank"], r["issue"], r["sha256"], r["task"], r["verdict"], fg_verify.reason_class(r["reason"]), r["role"]) for r in rows]
rc_s, rows_s, paths_s = full_walk("seq", 1)
t("the sequential reference walk ends normally with 5 rows (2 rejected, 2 tasks, 1 pilot)", rc_s == 0 and len(rows_s) == 5 and [r["role"] for r in rows_s if r["verdict"] == "accepted"] == ["task", "task", "pilot"], [(r["rank"], r["verdict"], r["role"]) for r in rows_s])

real_verify, finished = fg_verify.verify_one, []
def staggered(cand, work, tasks_dir, text, python):
    rank = p_order.index(cand["issue"]) + 1
    time.sleep(0.5 * (9 - rank))                 # the earlier the rank, the later it finishes
    done = real_verify(cand, work, tasks_dir, text, python)
    finished.append(rank)
    return done
fg_verify.verify_one = staggered
try:
    rc_p, rows_p, paths_p = full_walk("par", 4)
finally:
    fg_verify.verify_one = real_verify
t("under jobs=4 the candidates really did finish out of rank order", finished[0] != 1 and finished != sorted(finished), finished)
t("and the parallel record is the sequential record: same ranks, tasks, verdicts, reasons and roles", rc_p == 0 and view(rows_p) == view(rows_s), (view(rows_p), view(rows_s)))
t("a candidate verified past the stopping point is discarded, never recorded", len(rows_p) == 5 and max(r["rank"] for r in rows_p) == rows_s[-1]["rank"] and len(finished) > 5, (len(rows_p), finished))
t("the same task and pilot directories exist, and nothing else", sorted(os.listdir(paths_p["tasks"])) == sorted(os.listdir(paths_s["tasks"])) and os.listdir(paths_p["pilot"]) == os.listdir(paths_s["pilot"]))
t("the work root is empty afterwards: no clone, environment or staged output survives", leftovers() == [], leftovers())

# ── [H] a slow candidate at the head of the line does not idle the other workers ──
started_ranks, started_when_head_finished = [], []
def slow_head(cand, work, tasks_dir, text, python):
    rank = p_order.index(cand["issue"]) + 1
    started_ranks.append(rank)
    if rank == 1:
        time.sleep(4)
    done = real_verify(cand, work, tasks_dir, text, python)
    if rank == 1:
        started_when_head_finished.append(len(started_ranks))
    return done
fg_verify.verify_one = slow_head
try:
    rc_h, rows_h, _ = full_walk("head", 2)
finally:
    fg_verify.verify_one = real_verify
t("while the first candidate is still running, the free worker has moved on to later ranks (3 or more started)", started_when_head_finished and started_when_head_finished[0] >= 3, started_when_head_finished)
t("and the record is still decided in rank order, the sequential record", rc_h == 0 and view(rows_h) == view(rows_s), (rc_h, view(rows_h)))

# ── [L] low disk in the middle of a walk, then resume ───────────────────────
calls = [0]
def stingy():
    calls[0] += 1
    return 50 * 10**9 if calls[0] <= 2 else 1 * 10**9      # fine at the start and for candidate 1, then low
rc_l, rows_l, paths_l = full_walk("low", 1, free=stingy)
t("a walk that runs low on disk after the first candidate records that one and stops with exit 3", rc_l == 3 and [r["rank"] for r in rows_l] == [1], (rc_l, [r["rank"] for r in rows_l]))
rc_l2, rows_l2, _ = full_walk("low", 1, free=lambda: 50 * 10**9)
t("the same command, resumed with room, finishes with the sequential walk's record", rc_l2 == 0 and view(rows_l2) == view(rows_s), (rc_l2, view(rows_l2)))
open(paths_l["selection.jsonl"], "w").write(json.dumps(dict(rows_l2[0], issue="https://github.com/acme/other/issues/1")) + "\n")
try:
    full_walk("low", 1)
    t("a record that is not the first rows of the pool in rank order is an error, not a resume", False, "no exception")
except ValueError as exc:
    t("a record that is not the first rows of the pool in rank order is an error, not a resume", "disagree" in str(exc), str(exc))

# ── [M] the manifest, the summary and the reason classes ────────────────────
manifest = fg_verify.build_manifest(p_file, paths_s["selection.jsonl"], paths_s["tasks"])
t("the manifest is a pure function of the pool, the record and the task directories", manifest == fg_verify.build_manifest(p_file, paths_s["selection.jsonl"], paths_s["tasks"]))
t("it lists the tasks (not the pilot) in rank order, each with the rank hash of its issue and both commits",
  manifest["task_count"] == 2 and [x["rank"] for x in manifest["tasks"]] == sorted(r["rank"] for r in rows_s if r["role"] == "task")
  and all(x["sha256"] == taskgen.issue_rank(x["issue"]) and len(x["base_sha"]) == 40 and len(x["merge_sha"]) == 40 and x["category"] == "bugfix" for x in manifest["tasks"]), manifest)
t("it pins the pool by hash and says how many were walked and why the rest were rejected",
  manifest["candidates_sha256"] == hashlib.sha256(open(p_file, "rb").read()).hexdigest() and manifest["candidates"] == 8 and manifest["walked"] == 5
  and manifest["rejected"] == {"tests already pass at the base commit": 2}, manifest)
first_task = os.path.join(paths_s["tasks"], manifest["tasks"][0]["id"])
open(os.path.join(first_task, "ground_truth.sh"), "a").write("# edited after the manifest\n")
changed = fg_verify.build_manifest(p_file, paths_s["selection.jsonl"], paths_s["tasks"])
t("editing any file of a task changes that task's directory hash and no other",
  changed["tasks"][0]["dir_sha256"] != manifest["tasks"][0]["dir_sha256"] and changed["tasks"][1] == manifest["tasks"][1])
shutil_rm(os.path.join(paths_s["tasks"], manifest["tasks"][1]["id"]))
try:
    fg_verify.build_manifest(p_file, paths_s["selection.jsonl"], paths_s["tasks"])
    t("a task the record accepts but whose directory is gone is an error", False, "no exception")
except ValueError as exc:
    t("a task the record accepts but whose directory is gone is an error", manifest["tasks"][1]["id"] in str(exc), str(exc))
summary = fg_verify.summarize(rows_s)
t("the summary counts what the walk did", summary == {"walked": 5, "tasks": 2, "pilots": 1, "rejected": {"tests already pass at the base commit": 2}}, summary)
IMPORT_FAILS = "tests could not run at the base commit: an import fails (a test dependency is missing or incompatible)"
samples = {"could not fetch the issue text: gh: HTTP 404": "issue text unavailable", "clone: step 1 (git init): exit 128: fatal": "clone or fetch failed",
           "no installable python project at the root": "no installable python project", "environment: step 3 (uv pip): exit 1: boom": "environment build failed",
           "the upstream tests already pass at the base commit (1 passed)": "tests already pass at the base commit",
           "the upstream tests still fail at the merge commit (1 failed)": "tests still fail at the merge commit",
           "the upstream tests could not run at the base commit: pytest exit 5": "tests could not run at the base commit",
           "a committed file holds a secret-shaped literal (gitleaks: private-key)": "secret-shaped literal in a committed file", "something new": "other",
           "environment: step 3 (uv pip install -e .): the workspace grew past 600 MB": "workspace over the 600 MB bound",
           "the upstream tests could not run at the base commit: the workspace grew past 600 MB": "workspace over the 600 MB bound",
           "the upstream tests could not run at the base commit: size: ": "workspace over the 600 MB bound",
           "environment: step 2 (uv pip install): timed out after 300s": "step timed out",
           "the upstream tests could not run at the merge commit: timed out after 300s": "step timed out",
           "the upstream tests could not run at the base commit: timeout: ": "step timed out",
           "the upstream tests could not run at the base commit: pytest exit 4: E   ModuleNotFoundError: No module named 'requests'": IMPORT_FAILS,
           "the upstream tests could not run at the base commit: pytest exit 4: E   ImportError: cannot import name 'X' from 'y'": IMPORT_FAILS,
           "the upstream tests could not run at the merge commit: pytest exit 4: E   ModuleNotFoundError: No module named 'requests'": "tests could not run at the merge commit"}
t("every rejection reason has a stable class, and an unknown one is 'other'", all(fg_verify.reason_class(r) == c for r, c in samples.items()), [(r, fg_verify.reason_class(r)) for r, c in samples.items() if fg_verify.reason_class(r) != c])

# ── [S] a secret-shaped literal in a committed file rejects the candidate ───
pem = "-----BEGIN " + "RSA PRIVATE KEY-----\n" + "\n".join(["MIIEowIBAAKCAQEA" + "q" * 48] * 4) + "\n-----END " + "RSA PRIVATE KEY-----\n"
leaky = remote("leaky", [{"calc.py": BUGGY, "pytest.ini": PYTEST_INI}, {"calc.py": FIXED, "tests/test_calc.py": TEST + "KEY = '''" + pem + "'''\n"}])
res = verify(candidate("leaky", leaky[1], number=21), os.path.join(tmp, "leaky-tasks"))
t("an upstream test file holding a private key: rejected, naming the rule and not the secret", res["verdict"] == "rejected" and "secret-shaped literal" in res["reason"] and "private-key" in res["reason"] and "qqqq" not in res["reason"], res)
t("and no task directory is left for the commit gate to refuse", not os.path.exists(os.path.join(tmp, "leaky-tasks", "acme__leaky-21")) and leftovers() == [])
clean = verify(candidate("good", good[1], number=22), os.path.join(tmp, "clean-tasks"))
t("a clean candidate records that the scan ran", clean["verdict"] == "accepted" and clean["evidence"]["secret_scan"].startswith("clean"), clean)
status, detail = fg_verify.secret_scan(os.path.join(tmp, "clean-tasks"))
t("secret_scan reports a clean directory as clean", status == "clean", (status, detail))
real_which = fg_verify.shutil.which
fg_verify.shutil.which = lambda name: None
try:
    status, detail = fg_verify.secret_scan(os.path.join(tmp, "clean-tasks"))
finally:
    fg_verify.shutil.which = real_which
t("with no gitleaks the scan says it was skipped, and why (the task records that, never 'clean')", status == "skipped" and "not installed" in detail, (status, detail))

# ── [R] input checks and the retry ──────────────────────────────────────────
res = verify(candidate("good", good[1], tests=("../outside/test_x.py",), number=31), tasks)
t("a candidate test path that climbs out of the tree: rejected before anything is cloned", res["verdict"] == "rejected" and res["reason"].startswith("unsafe test path") and res["evidence"] == {}, res)
res = verify(candidate("good", good[1], tests=("tests/conftest.py", "tests/data.json"), number=32), tasks)
t("a candidate with no test module among its changed test files: rejected", res["verdict"] == "rejected" and "no test module" in res["reason"], res)
real_guard = fg_repo.run_guarded
try:
    fg_repo.run_guarded = lambda *a, **k: fg_repo.Result(-9, "", "size")
    killed_size = fg_verify._ground_truth(".", ".", {}, ".")
    fg_repo.run_guarded = lambda *a, **k: fg_repo.Result(-9, "", "timeout")
    killed_time = fg_verify._ground_truth(".", ".", {}, ".")
finally:
    fg_repo.run_guarded = real_guard
t("a ground-truth run killed for size says the workspace grew past the bound, and has no exit code", killed_size["rc"] is None and "grew past 600 MB" in killed_size["tail"], killed_size)
t("a ground-truth run killed for time says how long it was given, and has no exit code", killed_time["rc"] is None and "timed out after %ds" % fg_verify.GROUND_TRUTH_TIMEOUT_S in killed_time["tail"], killed_time)
attempts = []
def flaky():
    attempts.append(1)
    return "connection reset" if len(attempts) < 3 else None
t("a step that fails twice and then works is retried to success", fg_verify._retried(flaky) is None and len(attempts) == 3, attempts)
attempts.clear()
t("a step that keeps failing is given up after CLONE_ATTEMPTS, with its last reason", fg_verify._retried(lambda: attempts.append(1) or "gone") == "gone" and len(attempts) == fg_verify.CLONE_ATTEMPTS, attempts)

print("\n".join(out))
print("END")
PY
report "$TMP/v.out"

echo
echo "false-green-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
