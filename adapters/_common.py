"""Helpers shared by adapters: task validation, run ids, timestamps and read-only git plumbing.

Nothing here writes to the caller's repository. Every git call runs with GIT_* scrubbed from the
environment (a hook or wrapper that exported GIT_DIR must not redirect it) and with prompts off.

The conformance suite (adapters/conformance) deliberately does NOT import this module: it keeps its
own copy of the little it needs, so a bug here cannot also live in the thing that checks it.
"""
from __future__ import annotations

import datetime
import os
import re
import secrets
import shutil
import subprocess
import tempfile

from . import AdapterError

TASK_KEYS = ("id", "prompt", "repo", "base_sha", "options")
_TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
_SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")

_GIT_TIMEOUT_S = 120


def _int_env(name, default):
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


def now_ts():
    """RFC 3339 UTC with millisecond precision, the `ts` format of every event."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def new_run_id(name):
    return "%s-%s" % (name, secrets.token_hex(6))


def _env(extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    if extra:
        env.update(extra)
    return env


def git(repo, *args, stdin=None):
    """Run `git -C repo args...`; returns the CompletedProcess (bytes). A missing git or a hang is `unavailable`."""
    kwargs = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, env=_env(), timeout=_GIT_TIMEOUT_S, **kwargs)
    except FileNotFoundError:
        raise AdapterError("unavailable", "git is not installed")
    except subprocess.TimeoutExpired:
        raise AdapterError("unavailable", "git %s did not finish within %ds" % (args[0], _GIT_TIMEOUT_S))


def first_line(raw):
    lines = (raw or b"").decode("utf-8", "replace").strip().splitlines()
    return lines[0][:300] if lines else "no output"


def resolve_commit(repo, rev):
    """The full sha of the commit `rev` names in `repo`, or None."""
    if not isinstance(rev, str) or not rev or rev.startswith("-") or "\0" in rev:
        return None
    done = git(repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}")
    sha = done.stdout.decode("ascii", "replace").strip()
    return sha if done.returncode == 0 and _SHA.match(sha) else None


def validate_task(task):
    """The task as the contract defines it, normalised (absolute repo, options defaulted), or AdapterError.

    bad_task: the task is malformed or `repo` is not a usable git repository. unknown_base: `base_sha`
    is well formed but names no commit in `repo`.
    """
    if not isinstance(task, dict):
        raise AdapterError("bad_task", "task must be an object with id, prompt, repo and base_sha")
    unknown = sorted(str(k) for k in set(task) - set(TASK_KEYS))
    if unknown:
        raise AdapterError("bad_task", "unknown task key(s): %s (allowed: %s)" % (", ".join(unknown), ", ".join(TASK_KEYS)))
    for key in ("id", "prompt", "repo", "base_sha"):
        if key not in task:
            raise AdapterError("bad_task", "task.%s is required" % key)
        if not isinstance(task[key], str):
            raise AdapterError("bad_task", "task.%s must be a string" % key)
    if not _TASK_ID.match(task["id"]):
        raise AdapterError("bad_task", "task.id must match %s" % _TASK_ID.pattern)
    options = task.get("options", {})
    if not isinstance(options, dict):
        raise AdapterError("bad_task", "task.options must be an object keyed by adapter name")
    repo = os.path.abspath(task["repo"]) if task["repo"] else ""
    if not repo or not os.path.isdir(repo):
        raise AdapterError("bad_task", "task.repo is not a directory: %r" % task["repo"])
    probe = git(repo, "rev-parse", "--git-dir")
    if probe.returncode != 0:
        raise AdapterError("bad_task", "task.repo is not a git repository: %s" % first_line(probe.stderr))
    if not _SHA.match(task["base_sha"]):
        raise AdapterError("bad_task", "task.base_sha must be a full lowercase hex commit id (40 or 64 chars), got %r" % task["base_sha"][:80])
    if resolve_commit(repo, task["base_sha"]) != task["base_sha"]:
        raise AdapterError("unknown_base", "no commit %s in %s" % (task["base_sha"], repo))
    return {"id": task["id"], "prompt": task["prompt"], "repo": repo, "base_sha": task["base_sha"], "options": options}


def toplevel(repo):
    """The working-tree root of the repository `repo` is inside."""
    done = git(repo, "rev-parse", "--show-toplevel")
    if done.returncode != 0:
        raise AdapterError("bad_task", "%s is not inside a git working tree: %s" % (repo, first_line(done.stderr)))
    return done.stdout.decode("utf-8", "surrogateescape").strip()


def export_tree(repo, sha, dest):
    """Write the tree of commit `sha` into the new directory `dest`, as the COMMITTED bytes.

    Not `git archive`: that honours export-ignore and export-subst, so a repository that marks its
    tests export-ignore would export a tree a patch to those tests can never apply to. Blobs are read
    raw (no smudge filter, no eol conversion, nothing executed from repo config) and written with
    their mode: regular, executable, symlink; a submodule becomes an empty directory.
    """
    listing = git(repo, "ls-tree", "-r", "-z", "-l", "--full-tree", sha)
    if listing.returncode != 0:
        raise AdapterError("unknown_base", "cannot list %s: %s" % (sha, first_line(listing.stderr)))
    entries, total = [], 0
    for record in listing.stdout.split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        mode, kind, obj, size = meta.split()
        entries.append((mode, kind, obj.decode("ascii"), path.decode("utf-8", "surrogateescape")))
        total += int(size) if size != b"-" else 0
    max_files, max_bytes = _int_env("HMD_ADAPTER_MAX_EXPORT_FILES", 20000), _int_env("HMD_ADAPTER_MAX_EXPORT_MB", 256) * 1024 * 1024
    if len(entries) > max_files or total > max_bytes:
        raise AdapterError("too_large", "the base tree has %d files / %d bytes (caps: %d files / %d MB, HMD_ADAPTER_MAX_EXPORT_FILES / HMD_ADAPTER_MAX_EXPORT_MB)"
                           % (len(entries), total, max_files, max_bytes // (1024 * 1024)))
    os.makedirs(dest)
    try:
        reader = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=_env())
    except FileNotFoundError:
        raise AdapterError("unavailable", "git is not installed")
    try:
        for mode, kind, obj, rel in entries:
            parts = rel.split("/")
            if any(p in ("", ".", "..") or p.lower() == ".git" for p in parts):
                raise AdapterError("bad_task", "the base tree holds an unsafe path: %r" % rel)
            target = os.path.join(dest, *parts)
            if kind == b"commit":
                os.makedirs(target, exist_ok=True)
                continue
            reader.stdin.write(obj.encode("ascii") + b"\n")
            reader.stdin.flush()
            header = reader.stdout.readline().split()
            if len(header) != 3 or header[1] != b"blob":
                raise AdapterError("bad_task", "cannot read blob %s for %s" % (obj, rel))
            blob = reader.stdout.read(int(header[2]))
            reader.stdout.read(1)  # the LF git writes after every object
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if mode == b"120000":
                os.symlink(blob.decode("utf-8", "surrogateescape"), target)
                continue
            with open(target, "wb") as fh:
                fh.write(blob)
            if mode == b"100755":
                os.chmod(target, 0o755)
    finally:
        reader.stdin.close()
        reader.stdout.close()
        reader.wait()


def apply_diff(tree, diff):
    """Apply the unified `diff` to the directory `tree`; returns {files, insertions, deletions}. bad_diff when it does not.

    `git apply` is all-or-nothing, refuses paths outside the tree, `.git` paths and writes through
    symlinks. It must see `tree` as a plain directory: inside a repository it would silently skip every
    path outside its own subdirectory, so the search for a repository is stopped at the tree's parent.
    """
    tree = os.path.realpath(tree)
    env = _env({"GIT_CEILING_DIRECTORIES": os.path.dirname(tree)})
    payload = diff.encode("utf-8")
    try:
        counts = subprocess.run(["git", "apply", "--numstat", "-"], cwd=tree, input=payload, capture_output=True, env=env, timeout=_GIT_TIMEOUT_S)
        done = subprocess.run(["git", "apply", "--whitespace=nowarn", "-"], cwd=tree, input=payload, capture_output=True, env=env, timeout=_GIT_TIMEOUT_S)
    except FileNotFoundError:
        raise AdapterError("unavailable", "git is not installed")
    except subprocess.TimeoutExpired:
        raise AdapterError("unavailable", "git apply did not finish within %ds" % _GIT_TIMEOUT_S)
    if counts.returncode != 0 or done.returncode != 0:
        raise AdapterError("bad_diff", "the diff does not apply: %s" % first_line(done.stderr if done.returncode != 0 else counts.stderr))
    files = insertions = deletions = 0
    for line in counts.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split("\t", 2)
        if len(fields) < 3:
            continue
        added, deleted = fields[0], fields[1]
        files += 1
        insertions += int(added) if added.isdigit() else 0
        deletions += int(deleted) if deleted.isdigit() else 0
    return {"files": files, "insertions": insertions, "deletions": deletions}


def materialize(repo, base_sha, diff, dest):
    """The tree of `base_sha` with `diff` applied, written to the new directory `dest`. Returns apply_diff's stats."""
    export_tree(repo, base_sha, dest)
    return apply_diff(dest, diff)


def check_applies(repo, base_sha, diff):
    """Prove `diff` applies to `base_sha` by actually applying it in a throwaway tree; returns apply_diff's stats."""
    work = tempfile.mkdtemp(prefix="runhmd-adapter-")
    try:
        return materialize(repo, base_sha, diff, os.path.join(work, "tree"))
    finally:
        shutil.rmtree(work, ignore_errors=True)
