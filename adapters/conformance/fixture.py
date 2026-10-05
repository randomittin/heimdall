"""The conformance suite's own fixture: a small git repository with a known change, built here.

Everything the suite expects comes from this file and from docs/ADAPTERS.md, never from an adapter:
the repository, the base and head commits, the canonical diff between them, and the tree a faithful
claim must reproduce. Nothing here imports the adapters' shared helper module; the little git plumbing
the suite needs is written again on purpose, so one bug cannot sit on both sides of the check.

The scenario: base commit B, then head commit H = B plus every kind of change a diff carries (a
modified file, an added file, a deleted file, an executable-bit flip). HEAD is H, so an adapter that
applies a diff to HEAD instead of to the task's base_sha is caught.
"""
from __future__ import annotations

import hashlib
import io
import os
import subprocess
import tarfile

_WHEN = "2026-01-01T00:00:00Z"
_BASE_FILES = {
    "NOTES.md": "alpha\nbeta\ngamma\n",
    "old.txt": "to be deleted\n",
    "run.sh": "#!/bin/sh\necho hi\n",
    "src/app.mjs": "export const answer = 41;\n",
}
_HEAD_FILES = {
    "NOTES.md": "alpha\nbeta\ngamma\ndelta\n",
    "src/app.mjs": "export const answer = 42;\n",
    "src/new.txt": "added\n",
}


class FixtureError(Exception):
    """The suite could not build or inspect its own fixture: infrastructure, not an adapter fault."""


def _env(extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    if extra:
        env.update(extra)
    return env


def run(cwd, *args, env=None, check=True, stdin=None):
    """`git -C cwd args...`; raises FixtureError on failure unless check is False."""
    kwargs = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
    try:
        done = subprocess.run(["git", "-C", cwd, *args], capture_output=True, env=_env(env), **kwargs)
    except OSError as exc:
        raise FixtureError("cannot run git: %s" % exc)
    if check and done.returncode != 0:
        raise FixtureError("git %s failed: %s" % (" ".join(args[:2]), done.stderr.decode("utf-8", "replace").strip()[:300]))
    return done


def export(repo, rev, dest):
    """The tree of `rev` written to the new directory `dest` (the fixture carries no attributes, so `git archive` is exact)."""
    done = run(repo, "archive", "--format=tar", rev)
    os.makedirs(dest)
    with tarfile.open(fileobj=io.BytesIO(done.stdout)) as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(dest, filter="data")
        else:
            tar.extractall(dest)


def apply_diff(tree, diff):
    """(applied, first error line): does `diff` apply cleanly to the plain directory `tree`.

    `tree` must look like a plain directory to git: the search for a repository stops at its parent.
    """
    tree = os.path.realpath(tree)
    done = subprocess.run(["git", "apply", "--whitespace=nowarn", "-"], cwd=tree, input=diff.encode("utf-8", "surrogateescape"),
                          capture_output=True, env=_env({"GIT_CEILING_DIRECTORIES": os.path.dirname(tree)}))
    lines = done.stderr.decode("utf-8", "replace").strip().splitlines()
    return done.returncode == 0, (lines[0] if lines else "")


def _snapshot(root):
    snap = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if os.path.islink(full):
                snap[rel] = ("link", os.readlink(full))
            else:
                with open(full, "rb") as fh:
                    snap[rel] = ("file", hashlib.sha256(fh.read()).hexdigest(), bool(os.stat(full).st_mode & 0o100))
    return snap


def tree_diff(left, right, limit=4):
    """Human-readable differences between two directory trees (paths, bytes, executable bit, links); [] when identical."""
    a, b = _snapshot(left), _snapshot(right)
    found = ["only in claim: %s" % p for p in sorted(set(a) - set(b))] + ["missing from claim: %s" % p for p in sorted(set(b) - set(a))]
    for path in sorted(set(a) & set(b)):
        if a[path] != b[path]:
            found.append("differs: %s%s" % (path, " (executable bit)" if a[path][:2] == b[path][:2] and a[path][0] == "file" else ""))
    return found[:limit] + (["... and %d more" % (len(found) - limit)] if len(found) > limit else [])


def fingerprint(repo):
    """Everything an adapter must leave alone: HEAD, refs, status, registered worktrees and every working-tree file."""
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            digest.update(os.path.relpath(full, repo).encode("utf-8", "surrogateescape") + b"\0")
            if os.path.islink(full):
                digest.update(os.readlink(full).encode("utf-8", "surrogateescape"))
            else:
                with open(full, "rb") as fh:
                    digest.update(fh.read())
                digest.update(b"\1" if os.stat(full).st_mode & 0o100 else b"\0")
    return {
        "HEAD": run(repo, "rev-parse", "HEAD").stdout,
        "refs": run(repo, "for-each-ref").stdout,
        "status": run(repo, "status", "--porcelain=v1", "-z", "--ignored").stdout,
        "worktrees": run(repo, "worktree", "list", "--porcelain").stdout,
        "files": digest.hexdigest(),
    }


class Fixture:
    """repo, base_sha, head_sha, diff (git's own B..H), patch_path (the same diff in a file), expected_dir (H's tree), workdir."""

    def __init__(self, workdir):
        self.workdir = workdir
        self.repo = os.path.join(workdir, "repo")
        self.plain_dir = os.path.join(workdir, "plain")
        self.patch_path = os.path.join(workdir, "change.patch")
        self.expected_dir = os.path.join(workdir, "expected")
        self.base_sha = self.head_sha = self.diff = None

    def _commit(self, message):
        who = {"GIT_AUTHOR_NAME": "conformance", "GIT_AUTHOR_EMAIL": "conformance@example.invalid", "GIT_AUTHOR_DATE": _WHEN,
               "GIT_COMMITTER_NAME": "conformance", "GIT_COMMITTER_EMAIL": "conformance@example.invalid", "GIT_COMMITTER_DATE": _WHEN}
        run(self.repo, "add", "-A")
        run(self.repo, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull, "commit", "-q", "--no-verify", "-m", message, env=who)
        return run(self.repo, "rev-parse", "HEAD").stdout.decode("ascii").strip()

    def _write(self, files):
        for rel, text in files.items():
            path = os.path.join(self.repo, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

    def build(self):
        os.makedirs(self.repo)
        os.makedirs(self.plain_dir)
        run(self.repo, "init", "-q")
        run(self.repo, "symbolic-ref", "HEAD", "refs/heads/main")
        self._write(_BASE_FILES)
        self.base_sha = self._commit("base")
        self._write(_HEAD_FILES)
        os.remove(os.path.join(self.repo, "old.txt"))
        os.chmod(os.path.join(self.repo, "run.sh"), 0o755)
        self.head_sha = self._commit("head")
        raw = run(self.repo, "diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
                  "--src-prefix=a/", "--dst-prefix=b/", self.base_sha, self.head_sha, "--").stdout
        self.diff = raw.decode("utf-8")
        with open(self.patch_path, "w", encoding="utf-8") as fh:
            fh.write(self.diff)
        export(self.repo, self.head_sha, self.expected_dir)
        return self
