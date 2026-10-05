#!/usr/bin/env python3
"""fg_verify: turns a Study A candidate into a task, or says why not (PREREG.md section 5).

  walk      verify candidates.txt in ascending sha256(issue URL) order; every candidate walked is recorded
  summary   the record's rejections counted by reason
  manifest  the accepted tasks in rank order, each with the hash of every file in its directory

A candidate becomes a task only if the upstream pull request's own tests FAIL at the commit before the merge
and PASS at the merge commit. Both runs are the task's own generated ground_truth.sh, in an environment built
by the very steps the harness replays for an agent (fg_repo.run_steps), so a task is verified with the steps
it is run with. Nothing is chosen by hand: the order is the sha256 of the issue URL, the first N accepted are
the tasks, and every rejection is on the record with its reason. A candidate whose committed files would hold a
secret-shaped literal is rejected too (the commit gate would refuse the task, and a task must be committed
before any run).

The mechanics this module adds to section 5 (a hermetic environment per run, the 400 KB bound on upstream test
files, the secret scan, a walk that can stop on low disk and resume) are not in the preregistration yet: they
need an amendment before the first Study A run.

Exit codes of walk: 0 the quota is met, 1 the candidates ran out first, 2 unusable input or an unreadable disk
probe, 3 stopped on low disk (resume with the same command).
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import functools
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import fg_repo  # noqa: E402
import fg_taskgen  # noqa: E402
from fg_repo import env_steps  # noqa: E402,F401  (a module-level name on purpose: the tests replace it)
from fg_taskgen import issue_rank, ordered, parse_candidates  # noqa: E402

GITHUB = "https://github.com/"
MAX_TEST_BYTES = 400 * 1024
CLONE_ATTEMPTS, CLONE_RETRY_S = 3, 3          # a dropped connection is not a verdict on a candidate
LOOKAHEAD = 3                                 # candidates in flight or waiting per worker
GROUND_TRUTH_TIMEOUT_S = fg_repo.STEP_TIMEOUT_S
GITLEAKS_CONFIG = os.path.join(PLUGIN, ".gitleaks.toml")
LEAKS_EXIT = 7                                # gitleaks --exit-code: distinct from its own errors (1)
SHA = re.compile(r"[0-9a-f]{40}")

# rejection reason -> a short stable label, for counting (first match wins)
IMPORT_FAILS = "tests could not run at the base commit: an import fails (a test dependency is missing or incompatible)"
REASON_CLASSES = (
    ("could not fetch the issue text", "issue text unavailable"),
    ("clone:", "clone or fetch failed"),
    ("the merge commit has no parent", "merge commit has no parent"),
    ("unsafe test path", "unsafe test path"),
    ("test file missing at the merge commit", "test file missing at the merge commit"),
    ("exceed 400 KB", "upstream test files over 400 KB"),
    ("no test module", "no test module among the changed files"),
    ("no installable python project", "no installable python project"),
    ("grew past 600 MB", "workspace over the 600 MB bound"),
    ("size: ", "workspace over the 600 MB bound"),            # the first rows of the walk were written before the message said it in words
    ("timed out after", "step timed out"),
    ("timeout: ", "step timed out"),
    ("environment:", "environment build failed"),
    ("already pass at the base commit", "tests already pass at the base commit"),
    (("could not run at the base commit", "ModuleNotFoundError"), IMPORT_FAILS),
    (("could not run at the base commit", "ImportError"), IMPORT_FAILS),
    ("could not run at the base commit", "tests could not run at the base commit"),
    ("still fail at the merge commit", "tests still fail at the merge commit"),
    ("could not run at the merge commit", "tests could not run at the merge commit"),
    ("secret-shaped literal", "secret-shaped literal in a committed file"),
)


def reason_class(reason):
    for markers, label in REASON_CLASSES:
        if all(marker in reason for marker in ((markers,) if isinstance(markers, str) else markers)):
            return label
    return "other"


def _now_s():
    return time.monotonic()


@functools.lru_cache(maxsize=None)
def toolchain():
    def first_line(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip().splitlines()[0]
        except (OSError, subprocess.TimeoutExpired, IndexError):
            return None
    return {"python": platform.python_version(), "uv": first_line("uv", "--version"), "git": first_line("git", "--version"),
            "gitleaks": first_line("gitleaks", "version")}


def fetch_issue_text(cand):
    """(title, body) of the candidate's issue, from the GitHub API through gh; RuntimeError when it cannot be had."""
    owner, repo, _kind, number = cand["issue"].rstrip("/").split("/")[-4:]
    doc = fg_taskgen._gh(["api", "repos/%s/%s/issues/%s" % (owner, repo, number)])
    return doc.get("title") or "", doc.get("body") or ""


def secret_scan(path):
    """("clean" | "found" | "skipped", detail): gitleaks over a directory, with the commit gate's own rules."""
    gitleaks = shutil.which("gitleaks")
    if not gitleaks:
        return "skipped", "gitleaks is not installed"
    with tempfile.TemporaryDirectory(prefix="fg-leaks-") as scratch:
        report = os.path.join(scratch, "report.json")
        cmd = [gitleaks, "dir", "--no-banner", "--redact", "--exit-code", str(LEAKS_EXIT), "--report-format", "json", "--report-path", report]
        if os.path.isfile(GITLEAKS_CONFIG):
            cmd += ["--config", GITLEAKS_CONFIG]
        done = subprocess.run(cmd + [path], capture_output=True, text=True, timeout=300)
        if done.returncode == 0:
            return "clean", toolchain()["gitleaks"] or "gitleaks"
        if done.returncode == LEAKS_EXIT:
            with open(report, "r", encoding="utf-8") as fh:
                return "found", ", ".join(sorted({str(f.get("RuleID")) for f in json.load(fh)}))
        raise RuntimeError("gitleaks exit %d: %s" % (done.returncode, done.stderr.strip()[:200]))


def _quoted(*parts):
    return " ".join(shlex.quote(part) for part in parts)


def _probe_step(url, merge):
    """Fetch the merge commit and its parent, no files: enough to learn the base commit and read the upstream tests."""
    return " && ".join([_quoted("git", "init", "-q", "."), _quoted("git", "remote", "add", "origin", url),
                        _quoted("git", "fetch", "-q", "--depth", "2", "--filter=blob:none", "origin", merge)])


def _retried(attempt):
    """attempt() -> None on success or why it failed; tried again after a pause when it failed."""
    failure = None
    for number in range(CLONE_ATTEMPTS):
        failure = attempt()
        if failure is None:
            return None
        if number + 1 < CLONE_ATTEMPTS:
            time.sleep(CLONE_RETRY_S)
    return failure


def _fresh_run(path, step, env, root, python):
    def attempt():
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path)
        return fg_repo.run_steps([step], path, env, root, python=python)
    return _retried(attempt)


def _write(path, text, mode=0o644):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, mode)


def _stage_tests(cand, probe, stage, env, root):
    """Copy the upstream test files as they were at the merge commit into stage/tests. None, or why not."""
    paths = cand["tests"]
    listing =fg_repo.run_guarded(["git", "-c", "core.quotePath=false", "ls-tree", "-r", "-l", "-z", cand["merge"], "--"] + paths,
                                  probe, env, fg_repo.STEP_TIMEOUT_S, root)
    if listing.rc != 0:
        return "clone: could not list the test files at the merge commit: %s" % fg_repo.tail(listing.out)
    sizes = {}
    for entry in listing.out.split("\0"):
        meta, _tab, path = entry.partition("\t")
        fields = meta.split()
        if path and len(fields) == 4 and fields[1] == "blob" and fields[3].isdigit():
            sizes[path] = int(fields[3])
    for path in paths:
        if path not in sizes:
            return "test file missing at the merge commit: %s" % path
    total = sum(sizes[p] for p in paths)
    if total > MAX_TEST_BYTES:
        return "the upstream test files exceed 400 KB at the merge commit (%d bytes)" % total
    for path in paths:
        dest = os.path.join(stage, "tests", path)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        done = fg_repo.run_guarded(["bash", "-c", 'git cat-file blob "$1" > "$2"', "_", "%s:%s" % (cand["merge"], path), dest],
                                   probe, env, fg_repo.STEP_TIMEOUT_S, root)
        if done.rc != 0:
            return "clone: could not read %s at the merge commit: %s" % (path, fg_repo.tail(done.out))
    return None


def _ground_truth(stage, ws, env, root):
    """Run the task's own ground_truth.sh over the workspace: {"rc": 0 pass | 1 fail | other could not run, "tail": pytest's last line}."""
    done = fg_repo.run_guarded(["bash", os.path.join(stage, "ground_truth.sh"), ws], root, env, GROUND_TRUTH_TIMEOUT_S, root)
    if done.reason:
        why = "the workspace grew past %d MB" % (fg_repo.MAX_BYTES // 2**20) if done.reason == "size" else "timed out after %ds" % GROUND_TRUTH_TIMEOUT_S
        return {"rc": None, "tail": (why + (" | " + fg_repo.tail(done.out) if done.out.strip() else ""))[:300]}
    last = done.out.strip().splitlines()[-1] if done.out.strip() else ""
    try:
        detail = json.loads(last)
    except ValueError:
        detail = {}
    summary = (detail.get("failure") or {}).get("summary") or detail.get("tests") or detail.get("detail") or fg_repo.tail(done.out)
    return {"rc": done.rc, "tail": str(summary)[:300]}


def _verify(cand, task, root, tasks_dir, issue_text, python, evidence):
    """The rejection reason, or None when the candidate is accepted (its directory is then in tasks_dir/task)."""
    try:
        title, body = issue_text(cand)
    except RuntimeError as exc:
        return "could not fetch the issue text: %s" % str(exc)[:200]
    owner, repo = cand["issue"].rstrip("/").split("/")[-4:-2]
    url = "%s%s/%s" % (GITHUB, owner, repo)
    if any(os.path.isabs(p) or ".." in p.split("/") for p in cand["tests"]):
        return "unsafe test path in the candidate: %s" % ", ".join(cand["tests"])[:200]
    targets = fg_repo.test_targets(cand["tests"])
    if not targets:
        return "no test module among the changed test files"
    env = fg_repo.clean_env(root)
    stage = os.path.join(root, "stage", task)
    os.makedirs(os.path.join(stage, "tests"))

    probe = os.path.join(root, "probe")
    failure = _fresh_run(probe, _probe_step(url, cand["merge"]), env, root, python)
    if failure:
        return "clone: %s" % failure
    parent = fg_repo.run_guarded(["git", "rev-parse", "--verify", "-q", "FETCH_HEAD^"], probe, env, 60, root)
    base = parent.out.strip()
    if parent.rc != 0 or not SHA.fullmatch(base):
        return "the merge commit has no parent"
    problem = _stage_tests(cand, probe, stage, env, root)
    if problem:
        return problem

    ws = os.path.join(root, "ws")
    failure = _fresh_run(ws, fg_repo.clone_step(url, base, keep_origin=True), env, root, python)
    if failure:
        return "clone: %s" % failure
    commands, why = env_steps(ws)
    if commands is None:
        return why
    failure = fg_repo.run_steps(commands, ws, env, root, python=python)
    if failure:
        return "environment: %s" % failure

    _write(os.path.join(stage, "ground_truth.sh"), fg_repo.render_ground_truth(task, cand["pr"], targets), 0o755)
    evidence["base"] = _ground_truth(stage, ws, env, root)
    if evidence["base"]["rc"] == 0:
        return "the upstream tests already pass at the base commit (%s)" % evidence["base"]["tail"]
    if evidence["base"]["rc"] != 1:
        return "the upstream tests could not run at the base commit: %s" % evidence["base"]["tail"]
    failure = _retried(lambda: fg_repo.run_steps(
        ["git fetch -q --depth 1 --filter=blob:none origin %s && git checkout -q -f --detach %s" % (cand["merge"], cand["merge"])], ws, env, root))
    if failure:
        return "clone: %s" % failure
    evidence["merge"] = _ground_truth(stage, ws, env, root)
    if evidence["merge"]["rc"] == 1:
        return "the upstream tests still fail at the merge commit (%s)" % evidence["merge"]["tail"]
    if evidence["merge"]["rc"] != 0:
        return "the upstream tests could not run at the merge commit: %s" % evidence["merge"]["tail"]

    evidence["toolchain"] = toolchain()
    doc = {"id": task, "category": cand["kind"], "source": cand["issue"], "kind": "repo", "profile": None, "pr": cand["pr"],
           "repo": "%s/%s" % (owner, repo), "license": cand["license"], "base_sha": base, "merge_sha": cand["merge"],
           "test_paths": cand["tests"], "ground_truth_timeout_s": GROUND_TRUTH_TIMEOUT_S,
           "setup": [fg_repo.clone_step(url, base)] + commands, "prompt": fg_repo.render_prompt(title, body), "verified": evidence}
    _write(os.path.join(stage, "repo.ref"), "repository: %s\nissue: %s\npull_request: %s\nbase_sha: %s\nmerge_sha: %s\nlicense: %s\n" % (
        url, cand["issue"], cand["pr"], base, cand["merge"], cand["license"]))
    _write(os.path.join(stage, "task.json"), json.dumps(doc, indent=2) + "\n")
    status, detail = secret_scan(stage)            # over everything about to be committed, the prompt (issue text) included
    if status == "found":
        return "a committed file holds a secret-shaped literal (gitleaks: %s)" % detail
    evidence["secret_scan"] = "%s: %s" % (status, detail)
    _write(os.path.join(stage, "task.json"), json.dumps(doc, indent=2) + "\n")      # doc["verified"] is evidence: it now says how the scan went
    os.makedirs(tasks_dir, exist_ok=True)
    dest = os.path.join(tasks_dir, task)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(stage, dest)
    return None


def verify_one(cand, work_root, tasks_dir, issue_text, python):
    """Verify one candidate in a scratch directory under work_root, which is gone afterwards.

    -> {"issue", "task", "verdict": "accepted" | "rejected", "reason": "" when accepted, "evidence": {...}, "wall_s"}.
    An accepted candidate is a complete task directory at tasks_dir/<task id>; a rejected one leaves nothing.
    """
    started = _now_s()
    task = fg_repo.task_id(cand["issue"])
    result = {"issue": cand["issue"], "task": task, "verdict": "rejected", "reason": "", "evidence": {}}
    os.makedirs(work_root, exist_ok=True)
    root = tempfile.mkdtemp(prefix="v-", dir=work_root)
    try:
        reason = _verify(cand, task, root, tasks_dir, issue_text, python, result["evidence"])
    finally:
        shutil.rmtree(root, ignore_errors=True)
    result.update({"verdict": "rejected" if reason else "accepted", "reason": reason or "", "wall_s": round(_now_s() - started, 1)})
    return result


def _started(cand, work_root, stage, issue_text, python):
    """verify_one, unless the disk is low when this candidate's turn comes: then None, and nothing is cloned."""
    if fg_repo.container_free_bytes() < fg_repo.MIN_FREE_BYTES:
        return None
    return verify_one(cand, work_root, stage, issue_text, python)


def read_record(path):
    rows = []
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            for number, line in enumerate(fh, start=1):
                if line.strip():
                    try:
                        rows.append(json.loads(line))
                    except ValueError as exc:
                        raise ValueError("%s line %d is not JSON: %s" % (path, number, exc))
    return rows


def _append(path, row):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def verify_all(cand_file, tasks_dir, pilot_dir, record, work_root, want, spares, issue_text, python, jobs=1):
    """Walk the candidates in ascending sha256(issue URL) order until `want` are accepted as tasks and `spares` more as pilots.

    Candidates are verified `jobs` at a time, with a few ranks of lookahead so that one slow candidate does not
    idle the other workers, but decided strictly in rank order: the record is the same whatever `jobs` is, and a
    candidate verified past the stopping point is discarded, never recorded. Rows already in `record` are not
    walked again. Returns 0 (quota met), 1 (candidates exhausted), 3 (stopped on low disk, resumable).
    """
    if fg_repo.container_free_bytes() < fg_repo.MIN_FREE_BYTES:
        sys.stderr.write("fg_verify: under 3 GB free on the disk: stopping before anything is cloned\n")
        return 3
    with open(cand_file, "r", encoding="utf-8") as fh:
        cands = ordered(parse_candidates(fh.read()))
    rows = read_record(record)
    if [r["issue"] for r in rows] != [c["issue"] for c in cands[:len(rows)]]:
        raise ValueError("%s does not hold the first %d candidates of %s in rank order: the record and the pool disagree" % (record, len(rows), cand_file))
    taken = {role: sum(1 for r in rows if r.get("role") == role) for role in ("task", "pilot")}
    quota = {"task": want, "pilot": spares}
    met = lambda: all(taken[role] >= quota[role] for role in quota)
    pending, cursor, low_disk, window = collections.deque(), len(rows), False, max(1, jobs) * LOOKAHEAD
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        try:
            while not met():
                while cursor < len(cands) and len(pending) < window:
                    stage = os.path.join(work_root, "out-%d" % (cursor + 1))
                    pending.append((cursor + 1, cands[cursor], stage, pool.submit(_started, cands[cursor], work_root, stage, issue_text, python)))
                    cursor += 1
                if not pending:
                    break
                rank, cand, stage, future = pending.popleft()
                result = future.result()
                if result is None:                 # the disk was low when this candidate's turn came: everything after it is left undecided too
                    sys.stderr.write("fg_verify: under 3 GB free on the disk: no further candidate is started; resume with the same command\n")
                    low_disk = True
                    shutil.rmtree(stage, ignore_errors=True)
                    break
                role = None
                if result["verdict"] == "accepted":
                    role = "task" if taken["task"] < quota["task"] else "pilot"
                    destination = os.path.join(tasks_dir if role == "task" else pilot_dir, result["task"])
                    os.makedirs(os.path.dirname(destination), exist_ok=True)
                    shutil.rmtree(destination, ignore_errors=True)
                    shutil.move(os.path.join(stage, result["task"]), destination)
                    taken[role] += 1
                shutil.rmtree(stage, ignore_errors=True)
                _append(record, {"rank": rank, "issue": cand["issue"], "sha256": issue_rank(cand["issue"]), "task": result["task"],
                                 "verdict": result["verdict"], "reason": result["reason"], "role": role, "evidence": result["evidence"],
                                 "wall_s": result["wall_s"]})
                sys.stdout.write("fg_verify: %d/%d %s: %s%s\n" % (rank, len(cands), result["task"], result["verdict"], " (%s)" % result["reason"][:160] if result["reason"] else ""))
                sys.stdout.flush()
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
            for _rank, _cand, stage, _future in pending:
                shutil.rmtree(stage, ignore_errors=True)
    if met():
        return 0
    return 3 if low_disk else 1


def summarize(rows):
    """Counts of what the walk did: how many walked, accepted (by role) and rejected (by reason class)."""
    rejected = collections.Counter(reason_class(r["reason"]) for r in rows if r["verdict"] == "rejected")
    return {"walked": len(rows), "tasks": sum(1 for r in rows if r.get("role") == "task"), "pilots": sum(1 for r in rows if r.get("role") == "pilot"),
            "rejected": dict(sorted(rejected.items(), key=lambda kv: (-kv[1], kv[0])))}


def _dir_sha256(path):
    """One hash over every file in a directory: its relative paths and the sha256 of each, in sorted order."""
    lines = []
    for here, _dirs, files in os.walk(path):
        for name in files:
            full = os.path.join(here, name)
            with open(full, "rb") as fh:
                lines.append("%s %s" % (hashlib.sha256(fh.read()).hexdigest(), os.path.relpath(full, path)))
    return hashlib.sha256("\n".join(sorted(lines, key=lambda l: l.split(" ", 1)[1])).encode("utf-8")).hexdigest()


def _file_sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def build_manifest(cand_file, record, tasks_dir):
    """The accepted task set as one document, a pure function of the pool, the record and the task directories."""
    rows = read_record(record)
    tasks = []
    for row in sorted((r for r in rows if r.get("role") == "task"), key=lambda r: r["rank"]):
        path = os.path.join(tasks_dir, row["task"])
        if not os.path.isfile(os.path.join(path, "task.json")):
            raise ValueError("the record accepts %s as a task but %s has no task.json" % (row["task"], path))
        with open(os.path.join(path, "task.json"), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        tasks.append({"rank": row["rank"], "id": row["task"], "issue": row["issue"], "sha256": row["sha256"], "category": doc["category"],
                      "license": doc["license"], "base_sha": doc["base_sha"], "merge_sha": doc["merge_sha"], "dir_sha256": _dir_sha256(path)})
    summary = summarize(rows)
    return {"schema": "fg.study-a-manifest/1",
            "selection": "the first accepted tasks in ascending sha256(issue URL) order of candidates.txt (PREREG.md section 5)",
            "candidates_sha256": _file_sha256(cand_file), "candidates": len(parse_candidates(open(cand_file, "r", encoding="utf-8").read())),
            "walked": summary["walked"], "rejected": summary["rejected"], "task_count": len(tasks), "tasks": tasks}


def _parser():
    parser = argparse.ArgumentParser(prog="fg_verify", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    w = sub.add_parser("walk")
    w.add_argument("--candidates", required=True)
    w.add_argument("--tasks", required=True, help="where the first --want accepted candidates become task directories")
    w.add_argument("--pilot", required=True, help="where the next --spares accepted candidates go")
    w.add_argument("--record", required=True, help="selection.jsonl: one row per candidate walked, appended as the walk goes")
    w.add_argument("--work", required=True, help="scratch directory, outside the repository; each candidate's clone and environment live here until it is decided")
    w.add_argument("--want", type=int, required=True)
    w.add_argument("--spares", type=int, default=0)
    w.add_argument("--jobs", type=int, default=1)
    w.add_argument("--python", default=sys.executable)
    s = sub.add_parser("summary")
    s.add_argument("--record", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("--candidates", required=True)
    m.add_argument("--record", required=True)
    m.add_argument("--tasks", required=True)
    m.add_argument("--out", required=True)
    return parser


def main(argv):
    args = _parser().parse_args(argv)
    try:
        if args.command == "walk":
            signal.signal(signal.SIGTERM, lambda _signo, _frame: sys.exit(143))
            return verify_all(args.candidates, args.tasks, args.pilot, args.record, args.work, args.want, args.spares, fetch_issue_text, args.python, args.jobs)
        if args.command == "summary":
            sys.stdout.write(json.dumps(summarize(read_record(args.record)), indent=2) + "\n")
            return 0
        manifest = build_manifest(args.candidates, args.record, args.tasks)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(manifest, indent=2) + "\n")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        sys.stderr.write("fg_verify: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
