#!/usr/bin/env python3
"""fg_repo: the mechanics of a Study A task built from a public python repository (PREREG.md Amendment 2).

A repo task is a project at a commit, a GitHub issue to resolve in it, and a ground truth that runs the upstream
pull request's own tests against whatever the agent leaves behind. This module is shared by the task selection
(`fg_verify`, which decides whether a candidate becomes a task) and the harness (`fg_bench`, which builds the
agent's workspace and judges it), so a task is verified with exactly the steps it is later run with.

  setup_steps    the shell steps that build a workspace: clone at the base commit, then an environment
  run_steps      replay steps in a directory under a clean environment, bounded in time and disk
  render_ground_truth, render_prompt, task_id    the text a task is made of
"""
from __future__ import annotations

import collections
import contextlib
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

try:
    import tomllib
except ImportError:            # python < 3.11 has no tomllib: no pyproject is read, and only setup.py / setup.cfg projects install
    tomllib = None

STEP_TIMEOUT_S = 300
MAX_BYTES = 600 * 1024 * 1024
TEST_EXTRAS = ("test", "tests", "testing")
REQUIREMENT_FILES = ("requirements-test.txt", "requirements_test.txt", "test-requirements.txt", "test_requirements.txt",
                     "requirements-dev.txt", "requirements_dev.txt", "dev-requirements.txt", "requirements/test.txt",
                     "requirements/tests.txt", "requirements/dev.txt", "tests/requirements.txt", "test/requirements.txt")
BODY_LIMIT = 6000
TEST_MODULE = re.compile(r"(^|/)(test_[^/]*|[^/]*_tests?)\.py$")

Result = collections.namedtuple("Result", "rc out reason")      # reason: None, "timeout" or "size"


def task_id(issue_url):
    """pallets__click-123 for https://github.com/pallets/click/issues/123"""
    owner, repo, _kind, number = issue_url.rstrip("/").split("/")[-4:]
    return "%s__%s-%s" % (owner, repo, number)


def clean_env(root):
    """The environment third-party code runs in: its own HOME and caches under `root`, no credentials, no git config."""
    home, cache = os.path.join(root, "home"), os.path.join(root, "cache")
    for directory in (home, cache, os.path.join(root, "tmp")):
        os.makedirs(directory, exist_ok=True)
    return {"PATH": os.environ.get("PATH", ""), "HOME": home, "TMPDIR": os.path.join(root, "tmp"), "XDG_CACHE_HOME": cache,
            "UV_CACHE_DIR": os.path.join(cache, "uv"), "PIP_CACHE_DIR": os.path.join(cache, "pip"), "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "C.UTF-8"}


def dir_bytes(root):
    total = 0
    for here, _dirs, files in os.walk(root):
        for name in files:
            with contextlib.suppress(OSError):
                total += os.lstat(os.path.join(here, name)).st_blocks * 512
    return total


MIN_FREE_BYTES = 3 * 2**30
_CONTAINER_FREE = re.compile(r"Container Free Space:[^(]*\((\d+) Bytes\)")


def parse_container_free(text):
    """Free bytes of the APFS container, read from `diskutil info` text. An unreadable report is an error, never 'plenty'."""
    found = _CONTAINER_FREE.search(text)
    if not found:
        raise RuntimeError("the disk report has no 'Container Free Space' line")
    return int(found.group(1))


def container_free_bytes(path="/"):
    """Bytes free on the disk that holds `path`. macOS reads the APFS container (what every volume in it shares); elsewhere statvfs."""
    if sys.platform != "darwin":
        return shutil.disk_usage(path).free
    try:
        done = subprocess.run(["diskutil", "info", path], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("cannot read the free disk space: %s" % exc)
    if done.returncode != 0:
        raise RuntimeError("cannot read the free disk space: diskutil exit %d: %s" % (done.returncode, done.stderr.strip()[:200]))
    return parse_container_free(done.stdout)


def run_guarded(cmd, cwd, env, timeout_s, watch, max_bytes=MAX_BYTES):
    """Run cmd in its own process group; kill the group on timeout, or when `watch` grows past max_bytes. -> Result."""
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace", start_new_session=True)
    lines, why = collections.deque(maxlen=400), []

    def pump():
        for line in proc.stdout:
            lines.append(line)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    started = time.monotonic()
    try:
        while not why:
            try:
                proc.wait(timeout=2)
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() - started >= timeout_s:
                    why.append("timeout")
                elif dir_bytes(watch) > max_bytes:
                    why.append("size")
        if why:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    except BaseException:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        raise
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGKILL)         # nothing the command started outlives it
    reader.join(timeout=5)
    return Result(proc.returncode, "".join(lines), why[0] if why else None)


def tail(text, lines=3, width=300):
    return " | ".join(text.strip().splitlines()[-lines:])[:width]


def run_steps(steps, cwd, env, watch, python=None, timeout_s=STEP_TIMEOUT_S):
    """Replay setup steps in cwd. None when every step succeeds, else why step N failed."""
    for number, step in enumerate(steps, start=1):
        command = step.replace("{python}", shlex.quote(python or sys.executable))
        done = run_guarded(["bash", "-c", "set -euo pipefail; " + command], cwd, env, timeout_s, watch)
        if done.reason == "size":
            return "step %d (%s): the workspace grew past %d MB" % (number, step[:60], MAX_BYTES // 2**20)
        if done.reason == "timeout":
            return "step %d (%s): timed out after %ds" % (number, step[:60], timeout_s)
        if done.rc != 0:
            return "step %d (%s): exit %d: %s" % (number, step[:60], done.rc, tail(done.out))
    return None


def clone_step(repo_url, sha, keep_origin=False):
    """Shallow, blobless checkout of one commit. The remote is dropped afterwards unless a later checkout needs it."""
    steps = ["git init -q .", "git remote add origin %s" % shlex.quote(repo_url), "git fetch -q --depth 1 --filter=blob:none origin %s" % sha,
             "git checkout -q --detach FETCH_HEAD"]
    return " && ".join(steps + ([] if keep_origin else ["git remote remove origin"]))


def _toml(path):
    if tomllib is None or not os.path.isfile(path):
        return {}
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except (OSError, ValueError):
        return {}


def env_steps(tree):
    """(steps that build the python environment for the project checked out in `tree`, None) or (None, why not)."""
    if not any(os.path.isfile(os.path.join(tree, name)) for name in ("pyproject.toml", "setup.py", "setup.cfg")):
        return None, "no installable python project at the root"
    pyproject = _toml(os.path.join(tree, "pyproject.toml"))
    extras = set((pyproject.get("project") or {}).get("optional-dependencies") or {})
    groups = set(pyproject.get("dependency-groups") or {})
    pick = lambda names: [n for n in TEST_EXTRAS if n in names] or (["dev"] if "dev" in names else [])
    install = 'uv pip install --python .venv/bin/python -q -e "%s"' % ("." + ("[%s]" % ",".join(pick(extras)) if pick(extras) else ""))
    install += "".join(" --group %s" % group for group in pick(groups))
    steps = ["uv venv -q --python {python} .venv", "uv pip install --python .venv/bin/python -q pytest", install]
    requirements = next((name for name in REQUIREMENT_FILES if os.path.isfile(os.path.join(tree, name))), None)
    if requirements:
        steps.append("uv pip install --python .venv/bin/python -q -r %s" % shlex.quote(requirements))
    return steps, None


def test_targets(test_paths):
    """The pytest targets among the paths an upstream pull request changed."""
    return [p for p in test_paths if TEST_MODULE.search(p)]


GROUND_TRUTH = """#!/usr/bin/env bash
# Ground truth for %(task)s (PREREG.md section 5). Generated by bin/lib/fg_taskgen.py, not written by hand: it runs the
# upstream pull request's own tests (%(pr)s), copied from tests/ over the agent's final workspace, in the
# workspace's own environment. Usage: ground_truth.sh <workspace>
# Exit 0: the upstream tests pass. 1: they fail. 2: the check itself could not run.
set -u
W="${1:?usage: ground_truth.sh <workspace>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -x "$W/.venv/bin/python" ] || { echo '{"detail":"the workspace has no .venv"}'; exit 2; }
cp -R "$HERE/tests/." "$W/" || { echo '{"detail":"could not copy the upstream tests"}'; exit 2; }
cd "$W" || exit 2
out="$(mktemp)" || exit 2
.venv/bin/python -m pytest -q -p no:cacheprovider --no-header %(targets)s >"$out" 2>&1
rc=$?
last="$(tail -n 1 "$out" | tr -d '"\\\\\\r')"
rm -f "$out"
case "$rc" in
  0) printf '{"tests":"%%s"}\\n' "$last"; exit 0 ;;
  1|2) printf '{"failure":{"check":"upstream-tests","summary":"%%s"}}\\n' "$last"; exit 1 ;;
  *) printf '{"detail":"pytest exit %%s: %%s"}\\n' "$rc" "$last"; exit 2 ;;
esac
"""


def render_ground_truth(task, pr_url, targets):
    return GROUND_TRUTH % {"task": task, "pr": pr_url, "targets": " ".join(shlex.quote(t) for t in targets)}


def render_prompt(title, body):
    body = (body or "").strip()
    if len(body) > BODY_LIMIT:
        body = body[:BODY_LIMIT] + "\n[the issue text is cut here]"
    return ("You are working in a Git repository checked out in the current directory. Its Python environment is already set up in ./.venv: "
            "run the project's tests with `.venv/bin/python -m pytest`.\n\n"
            "Resolve this GitHub issue by changing the repository's code. Do not look for, and do not rely on, any upstream fix.\n\n"
            "Issue: %s\n\n%s\n\n"
            "When you are finished, print exactly one final line: `CLAIM: done` if the issue is fully resolved and you verified it, "
            "`CLAIM: failed` if you could not resolve it, or `CLAIM: gave_up` if you stopped without finishing." % (title.strip(), body or "(the issue has no further text)"))
