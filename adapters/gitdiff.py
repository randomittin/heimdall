"""gitdiff: the universal adapter. The change already exists as a diff, so there is no agent to run.

Cursor, an editor, a teammate, a CI job: anything that can produce a diff is a `gitdiff` source
(`hmd attack --diff <patch|base..head|->`). The claim is "done" with that diff; runhmd's job is to
attack whether it is. This adapter therefore never observes the change being made and says so by
emitting no `test` events: silence is "unknown", never "tests passed".

Sources (exactly one under `task.options.gitdiff`):
  patch       the unified diff itself, as text
  patch_file  a path to a file holding it
  head        a revision of the repo; the diff is `git diff base_sha..head`, head_sha is that commit

A bare patch is no commit, so its claim has `head_sha: null` rather than a sha that points at nothing.
Contract: docs/ADAPTERS.md. Errors beyond the contract's own: bad_diff (not a diff, does not apply,
not UTF-8), empty_diff (nothing to attack), unknown_head, too_large.
"""
from __future__ import annotations

import copy
import os
import secrets

from . import AdapterError
from . import _common as common

NAME = "gitdiff"
CONTRACT = "runhmd.adapter/1"
AGENT = "none"

_SOURCES = ("patch", "patch_file", "head")
_RUNS = {}


def _max_diff_bytes():
    try:
        value = int(os.environ.get("HMD_ADAPTER_MAX_DIFF_BYTES", ""))
    except ValueError:
        return 5 * 1024 * 1024
    return value if value > 0 else 5 * 1024 * 1024


def _decode(raw, what):
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise AdapterError("bad_diff", "%s is not valid UTF-8 text" % what)


def _source(options):
    opts = options.get(NAME)
    if not isinstance(opts, dict):
        raise AdapterError("bad_task", "gitdiff needs task.options.gitdiff holding exactly one of: %s" % ", ".join(_SOURCES))
    unknown = sorted(set(opts) - set(_SOURCES))
    if unknown:
        raise AdapterError("bad_task", "unknown gitdiff option(s): %s (allowed: %s)" % (", ".join(map(str, unknown)), ", ".join(_SOURCES)))
    given = [k for k in _SOURCES if k in opts]
    if len(given) != 1:
        raise AdapterError("bad_task", "gitdiff needs exactly one of %s, got %s" % (", ".join(_SOURCES), ", ".join(given) or "none"))
    if not isinstance(opts[given[0]], str):
        raise AdapterError("bad_task", "gitdiff option %s must be a string" % given[0])
    return given[0], opts[given[0]]


def _read_patch_file(path):
    cap = _max_diff_bytes()
    try:
        if os.path.getsize(path) > cap:
            raise AdapterError("too_large", "%s is %d bytes (cap %d, HMD_ADAPTER_MAX_DIFF_BYTES)" % (path, os.path.getsize(path), cap))
        with open(path, "rb") as fh:
            return _decode(fh.read(), path)
    except OSError as exc:
        raise AdapterError("bad_task", "cannot read the patch file %s: %s" % (path, exc.strerror or exc))


def _git_diff(repo, base_sha, head_sha):
    done = common.git(repo, "diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
                      "--src-prefix=a/", "--dst-prefix=b/", base_sha, head_sha, "--")
    if done.returncode != 0:
        raise AdapterError("bad_diff", "git diff failed: %s" % common.first_line(done.stderr))
    return _decode(done.stdout, "the diff between %s and %s" % (base_sha[:12], head_sha[:12]))


def start(task):
    task = common.validate_task(task)
    repo, base_sha = task["repo"], task["base_sha"]
    mode, value = _source(task["options"])
    head_sha = None
    if mode == "patch":
        diff = value
    elif mode == "patch_file":
        diff = _read_patch_file(value)
    else:
        head_sha = common.resolve_commit(repo, value)
        if head_sha is None:
            raise AdapterError("unknown_head", "no commit %r in %s" % (value, repo))
        diff = _git_diff(repo, base_sha, head_sha)
    cap = _max_diff_bytes()
    if len(diff.encode("utf-8")) > cap:
        raise AdapterError("too_large", "the diff is over %d bytes (HMD_ADAPTER_MAX_DIFF_BYTES)" % cap)
    if not diff.strip():
        raise AdapterError("empty_diff", "the diff is empty: there is nothing to attack")
    stats = common.check_applies(repo, base_sha, diff)

    stream = [
        {"ts": common.now_ts(), "kind": "status", "data": {"state": "started", "adapter": NAME, "source": mode}},
        {"ts": common.now_ts(), "kind": "tool", "data": dict(
            stats, name="git.apply", summary="the diff applies cleanly to %s: %d file(s), +%d -%d"
            % (base_sha[:12], stats["files"], stats["insertions"], stats["deletions"]))},
        {"ts": common.now_ts(), "kind": "status", "data": {"state": "done"}},
    ]
    run_id = common.new_run_id(NAME)
    _RUNS[run_id] = {"events": stream, "claim": {"claim": "done", "diff": diff, "head_sha": head_sha}}
    return run_id


def _run(run_id):
    if not isinstance(run_id, str) or run_id not in _RUNS:
        raise AdapterError("unknown_run", "no run %r" % (run_id,))
    return _RUNS[run_id]


def events(run_id):
    return iter(copy.deepcopy(_run(run_id)["events"]))


def claim(run_id):
    return dict(_run(run_id)["claim"])


def task_for_spec(repo, spec, *, read_stdin):
    """The task `hmd attack --diff SPEC` stands for, resolved against `repo` (a directory inside a git repo).

    SPEC is a patch file, `A..B`, `A...B` (base = merge-base of A and B) or `-` (the patch comes from
    `read_stdin()`, so this module never touches the process's own stdin). A patch applies on top of
    the repo's HEAD; a range names its own base. Every revision is resolved to a full sha here.
    """
    repo = os.path.abspath(repo)
    if not os.path.isdir(repo):
        raise AdapterError("bad_task", "not a directory: %s" % repo)
    probe = common.git(repo, "rev-parse", "--git-dir")
    if probe.returncode != 0:
        raise AdapterError("bad_task", "%s is not a git repository: %s" % (repo, common.first_line(probe.stderr)))
    if not isinstance(spec, str) or not spec:
        raise AdapterError("bad_task", "--diff needs a patch file, A..B, A...B or -")

    def head_of_repo():
        sha = common.resolve_commit(repo, "HEAD")
        if sha is None:
            raise AdapterError("bad_task", "%s has no commits to apply a patch on" % repo)
        return sha

    if spec == "-":
        base_sha, options = head_of_repo(), {"patch": read_stdin()}
    elif os.path.isfile(spec):
        base_sha, options = head_of_repo(), {"patch_file": os.path.abspath(spec)}
    elif ".." in spec:
        triple = "..." in spec
        left, _, right = spec.partition("..." if triple else "..")
        left_sha, right_sha = common.resolve_commit(repo, left), common.resolve_commit(repo, right)
        if not left or not right or left_sha is None or right_sha is None:
            raise AdapterError("bad_task", "cannot resolve the range %s in %s: both sides must name a commit" % (spec, repo))
        base_sha = left_sha
        if triple:
            merged = common.git(repo, "merge-base", left_sha, right_sha)
            base_sha = merged.stdout.decode("ascii", "replace").strip()
            if merged.returncode != 0 or not base_sha:
                raise AdapterError("bad_task", "%s and %s have no merge base" % (left, right))
        options = {"head": right_sha}
    else:
        raise AdapterError("bad_task", "--diff %s is not a patch file that exists, nor A..B, A...B or -" % spec)
    return {"id": "diff-" + secrets.token_hex(4), "prompt": "", "repo": repo, "base_sha": base_sha, "options": {NAME: options}}
