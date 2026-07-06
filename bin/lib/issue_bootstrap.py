#!/usr/bin/env python3
# issue_bootstrap.py — the DEPENDENCY-BOOTSTRAP seam for the issue-resolution loop
# (bin/lib/issue_loop.py). It answers ONE question: "before the SI-2 gate runs this
# repo's acceptance commands, are the repo's own test dependencies present in the
# ephemeral maintainer container?" — the "deployed-shape" gap bug #24 exposed.
#
# THE DEPLOYED-SHAPE GAP (bug #24, run-11). The live maintainer produced the CORRECT
# fix (sum_range -> range(start, stop+1)), but the gate ran the repo's `./run_tests.sh`
# with ok=False + an EMPTY output tail: the ephemeral container had git/gh/claude/pytest-
# the-image-ships, but NOT the *repo's own* deps (its requirements.txt / pyproject deps).
# A dev's `./run_tests.sh` assumes those deps are already installed; the ephemeral
# maintainer starts from a clean image, so it must BOOTSTRAP them first or the gate can
# never PROVE even a correct fix (-> GATE_FAILED, no PR).
#
# THE FIX (best-effort, tolerant, sandbox-safe). Before the gate runs the evidence
# commands, install the clone's declared dependencies INTO THE EPHEMERAL CONTAINER:
#   • requirements.txt present            -> pip install -r requirements.txt
#   • pyproject.toml / setup.py present   -> pip install -e .
#   • neither                             -> no install attempt (nothing to bootstrap)
# ALWAYS TOLERANT: a pip failure is RECORDED and RETURNED, never raised — the evidence
# run itself is the real check (a fix whose deps cannot install will simply fail the gate
# honestly, never a crash). SANDBOX-SAFE: pip installs into the ephemeral container's
# environment ONLY (the same throwaway clone/image the Job runs in); nothing persists.
# TIME-CAPPED: a runaway install is killed at HEIMDALL_BOOTSTRAP_TIMEOUT seconds.
#
# This module runs a pip subprocess (its ONE side effect); it discovers the manifest and
# shells out. It NEVER decides the gate verdict — that stays the SI-2 recorded real exit.

from __future__ import annotations

import os
import subprocess
import sys

# The pip invocation. Defaults to the running interpreter's pip (`python -m pip`) so the
# install lands in the SAME environment the evidence commands run under. Overridable via
# HEIMDALL_PIP_BIN (tests point it at a fake pip that records the call; an operator could
# point it at a venv's pip). When overridden the value is used verbatim as argv[0].
PIP_BIN_ENV = "HEIMDALL_PIP_BIN"

# The per-bootstrap wall-clock cap (seconds). A repo's dep install must not hang the Job;
# a bad override falls back to the bounded default.
BOOTSTRAP_TIMEOUT_ENV = "HEIMDALL_BOOTSTRAP_TIMEOUT"
BOOTSTRAP_TIMEOUT_DEFAULT = 300  # seconds; well under the maintainer dispatch cap.

# How much of pip's combined output we retain for diagnosis (never the whole log).
_OUTPUT_TAIL_MAX = 2000


def _pip_argv():
    """The pip argv prefix. HEIMDALL_PIP_BIN overrides (a fake pip in tests, a venv pip
    for an operator); otherwise `<this-interpreter> -m pip` so the install lands in the
    environment the evidence commands execute under."""
    override = os.environ.get(PIP_BIN_ENV)
    if override:
        return [override]
    return [sys.executable, "-m", "pip"]


def _timeout():
    """The bootstrap wall-clock cap (seconds); a bad/absent override -> bounded default."""
    try:
        return int(os.environ.get(BOOTSTRAP_TIMEOUT_ENV, BOOTSTRAP_TIMEOUT_DEFAULT))
    except (TypeError, ValueError):
        return BOOTSTRAP_TIMEOUT_DEFAULT


def detect_manifest(repo):
    """Detect the clone's dependency manifest and the pip install args it implies.

    Precedence: a requirements.txt (pinned deps) first, then a PEP-517 project
    (pyproject.toml / setup.py -> editable install). Returns (manifest_name,
    install_args) or (None, None) when the clone declares no installable deps."""
    if not repo or not os.path.isdir(repo):
        return (None, None)
    req = os.path.join(repo, "requirements.txt")
    if os.path.isfile(req):
        return ("requirements.txt", ["install", "-r", "requirements.txt"])
    for manifest in ("pyproject.toml", "setup.py"):
        if os.path.isfile(os.path.join(repo, manifest)):
            return (manifest, ["install", "-e", "."])
    return (None, None)


def bootstrap_dependencies(repo, runner=None):
    """Best-effort install of the clone's declared dependencies BEFORE the SI-2 gate runs
    the evidence commands (bug #24's deployed-shape fix).

    repo:    the workspace clone whose deps to bootstrap.
    runner:  callable(argv:list, repo:str) -> (returncode:int, output_tail:str) that runs
             the pip install. Defaults to _default_pip_runner (a real, time-capped pip
             subprocess in the clone). Tests inject a fake that records the call.

    ALWAYS returns a diagnostic dict (never raises): {
      attempted, manifest, installed, exit?, output_tail?, reason?, detail?
    }. A no-manifest clone -> attempted False, reason 'no-manifest' (no install fired). A
    pip failure -> attempted True, installed False, reason 'install-failed' (RECORDED, not
    raised — the evidence run is still the real check)."""
    result = {"attempted": False, "manifest": None, "installed": False}
    if not repo or not os.path.isdir(repo):
        result["reason"] = "no-repo"
        return result

    manifest, install_args = detect_manifest(repo)
    if manifest is None:
        result["reason"] = "no-manifest"
        return result

    result["manifest"] = manifest
    result["attempted"] = True
    argv = _pip_argv() + install_args + ["--disable-pip-version-check"]
    run = runner or _default_pip_runner
    try:
        rc, tail = run(argv, repo)
    except FileNotFoundError:
        # pip itself is not resolvable — record honestly, never crash the loop.
        result["reason"] = "pip-not-found"
        return result
    except subprocess.TimeoutExpired:
        result["reason"] = "install-timeout"
        return result
    except OSError as exc:
        result["reason"] = "install-error"
        result["detail"] = str(exc)[:200]
        return result

    result["exit"] = rc
    result["installed"] = rc == 0
    result["output_tail"] = (tail or "")[-_OUTPUT_TAIL_MAX:]
    if rc != 0:
        result["reason"] = "install-failed"
    return result


def _default_pip_runner(argv, repo):
    """Run pip in the clone, time-capped, capturing combined output. Returns (returncode,
    output_tail). Raises TimeoutExpired on the cap (bootstrap_dependencies records it)."""
    proc = subprocess.run(
        argv,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=_timeout(),
    )
    return proc.returncode, (proc.stdout or "")


# ── CLI (thin; the loop calls bootstrap_dependencies directly, this aids manual runs) ──


def _cli(argv):
    """CLI core: `issue_bootstrap <repo>` — bootstrap the repo's deps, print the JSON
    diagnostic. Exit 0 always (best-effort; the JSON carries the real outcome)."""
    import json

    repo = argv[0] if argv else os.getcwd()
    print(json.dumps(bootstrap_dependencies(os.path.abspath(repo)), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
