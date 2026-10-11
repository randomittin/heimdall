#!/usr/bin/env python3
"""hmd_ui_procs -- find and stop the hmd servers a session or a test run left behind.

Two long-lived programs outlive whatever started them: `sentinels/hmd-ui.py` (`hmd ui`) and
`bin/heimdall-relay-client`. A test suite whose cleanup trap never saw the pid, or an `hmd app
connect` that moved to another port, leaves a server running with ppid 1 -- and every such ui keeps
re-running hooks/identity/agents each poll interval (handoff 2026-10-11: 14 test servers up to two
days old, plus two superseded real ones).

Two sweeps, one identification rule, nothing else ever signalled:

  reap       ppid 1, --repo gone or under a temp dir, older than --min-age, and no live relay
             client points at it (--ui-port).  `heimdall-gc uis`, run-all.sh's end-of-sweep guard.
  supersede  ppid 1, this --repo, loopback-only (not --allow-host/--trust-proxy), no live relay
             client pointing at it, not on --keep-port.  `hmd app connect` / `hmd ui` at start.

POSITIVE identification only: the process is this user's, argv is `<python> <...>/sentinels/hmd-ui.py`
(or `.../heimdall-relay-client`) with a `--repo` value that can be read unambiguously (a path ps
may have split at a space is skipped, never guessed), and it is re-read right before every signal
because a pid can change hands the moment its owner exits. A process that cannot be read as that is
not ours to touch.

Output: one line per action (`reaped|would-reap|SURVIVED <ui|client> pid=N ...`), then
`hmd_ui_procs: reaped=N survivors=M`. Exit 1 when a target survived SIGKILL, 2 on a usage error.

Env (test seams): HMD_UI_PROCS_TMP_ROOTS (colon list; replaces the default temp roots),
HMD_UI_PROCS_SCRIPT_ROOT (only recognise servers whose script lives under this directory).
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time

UI_SCRIPT = "/sentinels/hmd-ui.py"
CLIENT_SCRIPT = "/heimdall-relay-client"


class Proc(object):
    def __init__(self, pid, ppid, age, command, tokens, script_at, kind):
        self.pid, self.ppid, self.age, self.command = pid, ppid, age, command
        self.tokens, self.script_at, self.kind = tokens, script_at, kind
        self.repo = None       # realpath of --repo, None when not readable
        self.ui_port = None    # a client's --ui-port
        self.port = None       # a ui's listening port (lsof), None when unknown
        self.published = False

    def opt(self, name):
        """The value after `name` (or `name=value`), None when absent or when the value may have
        been split at a space by ps (the next token is not another flag)."""
        t = self.tokens
        for i in range(self.script_at + 1, len(t)):
            if t[i] == name:
                if i + 1 >= len(t):
                    return None
                if i + 2 < len(t) and not t[i + 2].startswith("-"):
                    return None
                return t[i + 1]
            if t[i].startswith(name + "="):
                if i + 1 < len(t) and not t[i + 1].startswith("-"):
                    return None
                return t[i][len(name) + 1:]
        return None


def _etime_s(text):
    days, _, rest = text.rpartition("-")
    parts = [int(x) for x in rest.split(":")]
    secs = 0
    for x in parts:
        secs = secs * 60 + x
    return secs + (int(days) * 86400 if days else 0)


def _ps_rows():
    try:
        out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,uid=,etime=,command="],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return
    me = os.getuid()
    for line in out.splitlines():
        if UI_SCRIPT not in line and CLIENT_SCRIPT not in line:
            continue
        parts = line.split(None, 4)
        try:
            pid, ppid, uid, age = int(parts[0]), int(parts[1]), int(parts[2]), _etime_s(parts[3])
            command = parts[4]
        except (IndexError, ValueError):
            continue
        if uid == me:
            yield pid, ppid, age, command


def _lsof(pid, *flags):
    try:
        out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid)] + list(flags) + ["-Fn"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [line[1:] for line in out.splitlines() if line.startswith("n")]


def _command_of(pid):
    try:
        return subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(pid)],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _state_of(pid):
    try:
        return subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _identify(pid, ppid, age, command):
    tokens = command.split()
    root = os.environ.get("HMD_UI_PROCS_SCRIPT_ROOT")
    for kind, tail in (("ui", UI_SCRIPT), ("client", CLIENT_SCRIPT)):
        for i, tok in enumerate(tokens[:4]):
            if not tok.endswith(tail):
                continue
            if i == 0 or "python" not in os.path.basename(tokens[0]).lower() \
                    or any(not x.startswith("-") for x in tokens[1:i]):
                break
            if root and not tok.startswith(os.path.realpath(root) + os.sep):
                break
            p = Proc(pid, ppid, age, command, tokens, i, kind)
            repo = p.opt("--repo")
            if repo is None:
                return None
            if not os.path.isabs(repo):
                cwd = _lsof(pid, "-d", "cwd")
                if not cwd:
                    return None
                repo = os.path.join(cwd[0], repo)
            p.repo = os.path.realpath(repo)
            if kind == "ui":
                p.published = any(x in tokens[i + 1:] for x in ("--allow-host", "--trust-proxy")) \
                    or any(x.startswith("--allow-host=") for x in tokens[i + 1:])
            else:
                port = p.opt("--ui-port")
                p.ui_port = int(port) if port and port.isdigit() and int(port) > 0 else None
            return p
    return None


def survey():
    skip = {os.getpid(), os.getppid()}
    found = [_identify(*row) for row in _ps_rows() if row[0] not in skip]
    return [p for p in found if p is not None]


def _ui_port(p):
    if p.port is None:
        for name in _lsof(p.pid, "-iTCP", "-sTCP:LISTEN"):
            tail = name.rsplit(":", 1)[-1]
            if tail.isdigit():
                p.port = int(tail)
                break
    return p.port


def _temp_roots():
    env = os.environ.get("HMD_UI_PROCS_TMP_ROOTS")
    raw = env.split(":") if env else [tempfile.gettempdir(), os.environ.get("TMPDIR", ""), "/tmp", "/var/tmp"]
    return [os.path.realpath(r) for r in raw if r]


def _under(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def orphans(procs, min_age):
    """Leaked servers: orphaned, old enough, repo gone or under a temp dir, and (for a ui) not served
    by a relay client that is itself still wanted."""
    tmp = _temp_roots()

    def leaked(p):
        return p.ppid == 1 and p.age >= min_age and (not os.path.isdir(p.repo) or any(_under(p.repo, r) for r in tmp))

    dead_clients = [p for p in procs if p.kind == "client" and leaked(p)]
    served = {c.ui_port for c in procs if c.kind == "client" and c.ui_port and c not in dead_clients}
    dead_uis = [p for p in procs if p.kind == "ui" and leaked(p) and _ui_port(p) is not None and p.port not in served]
    return dead_clients + dead_uis


def superseded(procs, repo, keep_ports, keep_pids):
    """Same-repo leftovers: orphaned loopback uis of `repo` that no live relay client serves."""
    served = {c.ui_port for c in procs if c.kind == "client" and c.ui_port}
    return [p for p in procs if p.kind == "ui" and p.ppid == 1 and not p.published and p.repo == repo
            and p.pid not in keep_pids and _ui_port(p) is not None
            and p.port not in served and p.port not in keep_ports]


def _running(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return not _state_of(pid).startswith("Z")


def _wait_gone(pid, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not _running(pid):
            return True
        time.sleep(0.1)
    return not _running(pid)


def stop(p, timeout):
    """SIGTERM (after SIGCONT, so a stopped process can act on it), wait, then SIGKILL; the argv is
    re-read before each signal. 'terminated' | 'killed' | 'gone' | 'survived'."""
    if _command_of(p.pid) != p.command:
        return "gone"
    for sig in (signal.SIGCONT, signal.SIGTERM):
        try:
            os.kill(p.pid, sig)
        except OSError:
            return "gone"
    if _wait_gone(p.pid, timeout):
        return "terminated"
    if _command_of(p.pid) != p.command:
        return "gone"
    try:
        os.kill(p.pid, signal.SIGKILL)
    except OSError:
        return "gone"
    return "killed" if _wait_gone(p.pid, 3) else "survived"


def run(targets, dry_run, timeout):
    reaped = survivors = 0
    for p in targets:
        what = "%s pid=%d port=%s repo=%s age=%ds" % (p.kind, p.pid, p.port if p.port else "-", p.repo, p.age)
        if dry_run:
            print("would-reap " + what)
            continue
        outcome = stop(p, timeout)
        if outcome == "survived":
            survivors += 1
            print("SURVIVED " + what)
        else:
            reaped += 1
            print("reaped %s (%s)" % (what, outcome))
    print("hmd_ui_procs: reaped=%d survivors=%d" % (reaped, survivors))
    return 1 if survivors else 0


def main(argv):
    ap = argparse.ArgumentParser(prog="hmd_ui_procs", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("reap", "supersede"):
        s = sub.add_parser(name)
        s.add_argument("--dry-run", action="store_true")
        s.add_argument("--timeout", type=float, default=5.0, help="seconds to wait after SIGTERM before SIGKILL")
        if name == "reap":
            s.add_argument("--min-age", type=int, default=3600, help="ignore servers younger than this many seconds")
        else:
            s.add_argument("--repo", required=True)
            s.add_argument("--keep-port", type=int, action="append", default=[])
            s.add_argument("--keep-pid", type=int, action="append", default=[])
    args = ap.parse_args(argv)
    procs = survey()
    if args.cmd == "reap":
        targets = orphans(procs, args.min_age)
    else:
        targets = superseded(procs, os.path.realpath(args.repo), set(args.keep_port), set(args.keep_pid))
    return run(targets, args.dry_run, args.timeout)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
