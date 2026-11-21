#!/usr/bin/env python3
r"""hmd_restart_gate -- is NOW a safe moment to end the supervised claude and relaunch it on the updated binary and plugin?

docs/superpowers/plans/2026-11-13-seamless-update-restart.md (section 3, Task W1-gate; measurements: docs/analysis/2026-11-13-seamless-restart-spike.md).
The launcher that supervises claude asks this, from its USR1 trap and a 5 s poll while a restart request waits, twice 3 s apart: both answers must be SAFE
before it ends the session. Failing to restart costs the old behaviour (a pin notice); restarting at the wrong moment costs the operator's run, so anything
this cannot read is UNSAFE, never SAFE. The gate runs no model, writes nothing and never signals a process.

  heimdall-restart-gate [--req FILE] [--now] [--json]
     stdout  SAFE | UNSAFE <reason-token>     exit 0 only for SAFE, 1 for UNSAFE; a bad option is exit 2 with a usage line on stderr and no verdict
     --req   the request the Stop hook wrote (default $HMD_RESTART_DIR/req.json): {session_id, claude_pid, stop_ts, pending}. claude_pid picks the
             sessions file; stop_ts is seconds since the epoch (a value from 1e11 up is read as milliseconds, as claude writes its own)
     --now   skip G6 only (`hmd restart now`), the quiet window. Every other condition still has to hold
     --json  {"verdict", "reason", "detail"} on stdout; detail says what could not be read when the reason is signal-unreadable

  Evaluated in this order; the first that does not hold names the verdict (so an unreadable signal never hides an earlier failure):
  G1 opt-out            HMD_AUTO_RESTART is off (any case), or $HEIMDALL_HOME/no-auto-restart exists
  G2 not-supervised     HMD_SUPERVISED is not 1 (the launcher exports it only for an interactive claude with a TTY on stdin and stdout)
  G3 no-update          the pending command (HMD_RESTART_PENDING_CMD, a command line) exits 0 and prints at least one line `claude <running> <newest>`
                        or `hmd <started> <installed>`; exit 1 is no-update, any other status or no target line is unreadable
     install-running    some process command line matches heimdall.*install\.sh
     binary-fresh       claude is pending and its newest versions/<v> binary was written less than 30 s ago
  G4 not-idle           ~/.claude/sessions/<claude_pid>.json: status is idle (measured values: idle | busy | waiting | shell; busy or shell for a whole
                        background Bash job or subagent), and the idle began within -2..+10 s of the request's Stop, i.e. no later turn is missing
     settling           ...and the status has been idle for HMD_RESTART_SETTLE_S (15) or more: idle flashes for 0.1 s between turns
  G5 agents-live        heimdall-agents count (asked about the SESSION's cwd) is 0; parked mailbox teammates are not counted by it
     sweep-running      no live pid in receipts/sweep.lock of the session's repository or of $HEIMDALL_HOME (the reader of hmd_sweep_guard.py)
     task-live          no harness task .output written in the last 60 s, and no child of claude that is not infrastructure: caffeinate, a zombie, a
                        hook runner or helper of hmd (a script under bin/heimdall-* or hooks/), an MCP server. A Bash-tool job is a shell -c child
  G6 user-active        the tty's atime (it moves on a keystroke, measured on macOS) is HMD_RESTART_QUIET_S (300, the prompt-cache lifetime) or more ago
  G7 loop-guard         the session is at least 60 s old; $HEIMDALL_HOME/restart/last.json, {"ts": <epoch s>, "targets": {"claude": v, "hmd": v}} (the
                        versions the previous restart went to), is at least 600 s old and does not already cover every pending target
  G8 git-midop          no rebase-merge, rebase-apply or MERGE_HEAD in the git directory of the session's cwd (a linked worktree's own, too)
  signal-unreadable     any input that is missing, malformed, of an unknown value, hung, or unavailable on this platform (a tty that cannot be stat'ed)

Seams (env): HMD_RESTART_NOW (epoch, the clock), HMD_RESTART_SESSIONS_DIR (~/.claude/sessions), HMD_RESTART_TTY (no default: the supervisor sets it),
HMD_RESTART_AGENTS_CMD (heimdall-agents count), HMD_RESTART_PENDING_CMD (no default: the supervisor sets it), HMD_RESTART_PS_CMD (ps -axww, rows of
`pid ppid command`), HMD_RESTART_QUIET_S, HMD_RESTART_SETTLE_S, HMD_RESTART_CMD_TIMEOUT_S (10, for each helper), HEIMDALL_CC_VERSIONS (cc-selfheal's own
seam for the claude versions directory), HMD_AGENT_TASKDIR (heimdall-agents' own seam for the harness tasks directory), HEIMDALL_HOME. A number that is
not one is the default, said on stderr, never 0.
"""
import errno
import glob
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.normpath(os.path.join(HERE, os.pardir))

DEFAULT_QUIET_S = 300.0  # claude's prompt-cache lifetime: a restart after it re-reads the context at no extra price (plan Q2)
DEFAULT_SETTLE_S = 15.0
DEFAULT_CMD_TIMEOUT_S = 10.0
SESSION_MIN_AGE_S = 60
RESTART_GAP_S = 600
BINARY_FRESH_S = 30
TASK_FRESH_S = 60
STOP_BEFORE_IDLE_S = 10  # the Stop hook is capped at 5 s and runs while status is still busy; idle follows it by 0.1-1 s (spike Q4)
STOP_AFTER_IDLE_S = 2
STOP_FUTURE_S = 5
MAX_FILE = 1 << 20

OPT_OUT = "opt-out"
NOT_SUPERVISED = "not-supervised"
NO_UPDATE = "no-update"
INSTALL_RUNNING = "install-running"
BINARY_FRESH_TOKEN = "binary-fresh"
NOT_IDLE = "not-idle"
SETTLING = "settling"
AGENTS_LIVE = "agents-live"
SWEEP_RUNNING = "sweep-running"
TASK_LIVE = "task-live"
USER_ACTIVE = "user-active"
LOOP_GUARD = "loop-guard"
GIT_MIDOP = "git-midop"
UNREADABLE = "signal-unreadable"

STATUSES = frozenset(("idle", "busy", "waiting", "shell"))
GIT_OPS = ("rebase-merge", "rebase-apply", "MERGE_HEAD")
TARGET_NAMES = ("claude", "hmd")
SAFE_ID = re.compile(r"^[0-9A-Za-z._-]{1,128}$")
INSTALLER = re.compile(r"heimdall.*install\.sh")
PS_ROW = re.compile(r"^\s*([0-9]+)\s+([0-9]+)\s+(\S.*?)\s*$")
GITDIR_FILE = re.compile(r"gitdir:[ \t]*(.+?)[ \t]*\r?\n?\Z")
SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "fish"))
# What claude and hmd keep as children of an idle session (measured on a live one): caffeinate, zombies, hook runners and helpers of hmd, MCP servers.
ALLOWED_CHILDREN = tuple(re.compile(p) for p in (
    r"^(?:\S*/)?caffeinate(?:\s|$)",
    r"^\(.*\)$|<defunct>",
    r"^(?:\S*/)?perl\s+-e\s+alarm\s",
    r"^(?:\S*/)?(?:bash|sh|python[0-9.]*|perl|node)\s+(?:-\S+\s+)*\S*(?:bin/heimdall-|/hooks/)\S*",
))
MCP_SERVER = re.compile(r"(?i)mcp|modelcontextprotocol")


class Unreadable(Exception):
    """An input the gate needs that it cannot read: the verdict is UNSAFE signal-unreadable."""


# -- reading values ------------------------------------------------------------------------------------------------------------------------------

def clock():
    raw = os.environ.get("HMD_RESTART_NOW", "").strip()
    if not raw:
        return time.time()
    try:
        value = float(raw)
    except ValueError:
        raise Unreadable("HMD_RESTART_NOW is not an epoch")
    if not value > 0 or value == float("inf"):
        raise Unreadable("HMD_RESTART_NOW is not an epoch")
    return value


def seconds(name, default):
    """A number of seconds from the environment; anything else is the default, said on stderr (the disk floor's convention), never a silent 0."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        value = -1.0
    if not value >= 0 or value == float("inf"):
        sys.stderr.write("heimdall-restart-gate: %s=%r is not a number of seconds; using %g\n" % (name, raw, default))
        return default
    return value


def is_pid(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value < (1 << 31)


def epoch_s(value, what):
    """A timestamp in seconds. claude writes milliseconds, so anything from 1e11 up (year 5138 in seconds) is read as milliseconds."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not value > 0 or value == float("inf"):
        raise Unreadable("%s is not a usable timestamp: %r" % (what, value))
    return value / 1000.0 if value >= 1e11 else float(value)


def read_json(path, what, optional=False):
    """The JSON object in a regular file of a sane size. Unreadable otherwise; None for a file that is not there when `optional`."""
    try:
        st = os.stat(path)
    except OSError as exc:
        if optional and exc.errno in (errno.ENOENT, errno.ENOTDIR):
            return None
        raise Unreadable("%s cannot be read (%s)" % (what, exc.strerror))
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE:
        raise Unreadable("%s is not a regular file of a sane size" % what)
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        raise Unreadable("%s is not valid JSON" % what)
    if not isinstance(data, dict):
        raise Unreadable("%s is not a JSON object" % what)
    return data


def parse_session(data, pid):
    """The fields of a ~/.claude/sessions/<pid>.json the gate reads, checked and normalised. Unreadable when one is missing or of another type or value."""
    if not is_pid(pid):
        raise Unreadable("there is no usable claude pid to look the session up by")
    if isinstance(data.get("pid"), bool) or data.get("pid") != pid:
        raise Unreadable("the session file names pid %r, not %d" % (data.get("pid"), pid))
    status = data.get("status")
    if not isinstance(status, str) or status not in STATUSES:
        raise Unreadable("the session file has no status, or one the gate does not know: %r" % (status,))
    cwd = data.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        raise Unreadable("the session file has no absolute cwd")
    session_id = data.get("sessionId")
    if not isinstance(session_id, str) or not SAFE_ID.match(session_id):
        raise Unreadable("the session file has no usable sessionId")
    return {"pid": pid, "session_id": session_id, "cwd": cwd, "status": status,
            "status_at": epoch_s(data.get("statusUpdatedAt"), "statusUpdatedAt"), "started_at": epoch_s(data.get("startedAt"), "startedAt")}


def load_request(path, now):
    if not path:
        raise Unreadable("there is no request file: pass --req or set HMD_RESTART_DIR")
    data = read_json(path, "the restart request")
    pid = data.get("claude_pid")
    if not is_pid(pid):
        raise Unreadable("the restart request has no usable claude_pid")
    stop = epoch_s(data.get("stop_ts"), "stop_ts")
    if stop > now + STOP_FUTURE_S:
        raise Unreadable("the Stop of the restart request is in the future")
    return {"pid": pid, "stop_at": stop}


def version_key(name):
    """`sort -V` order: runs of digits compare as numbers, the rest as text."""
    return [(0, int(p), "") if re.match(r"^[0-9]+$", p) else (1, 0, p) for p in re.split(r"([0-9]+)", name)]


def parse_targets(text):
    """name -> newest version, from the pending command's lines `claude <running> <newest>` and `hmd <started> <installed>`."""
    targets = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in TARGET_NAMES:
            targets[parts[0]] = parts[2]
    return targets


# -- reading the machine -------------------------------------------------------------------------------------------------------------------------

def gitdir_of(path, root):
    """The git directory a linked worktree's `.git` file names."""
    try:
        with open(path, "rb") as f:
            text = f.read(MAX_FILE).decode("utf-8", "replace")
    except OSError as exc:
        raise Unreadable("%s cannot be read (%s)" % (path, exc.strerror))
    m = GITDIR_FILE.match(text)
    if not m:
        raise Unreadable("%s is not a gitdir file" % path)
    return os.path.normpath(os.path.join(root, m.group(1)))


def find_git(start):
    """The nearest repository around `start`: (work tree root, git directory), or None when there is none."""
    cur = os.path.realpath(start)
    while True:
        dot = os.path.join(cur, ".git")
        try:
            st = os.lstat(dot)
        except OSError as exc:
            if exc.errno not in (errno.ENOENT, errno.ENOTDIR):
                raise Unreadable("%s cannot be inspected (%s)" % (dot, exc.strerror))
        else:
            if stat.S_ISDIR(st.st_mode):
                return cur, dot
            if stat.S_ISREG(st.st_mode) and st.st_size <= MAX_FILE:
                return cur, gitdir_of(dot, cur)
            raise Unreadable("%s is neither a directory nor a gitdir file" % dot)
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def mtime_of(path):
    try:
        return os.stat(path).st_mtime
    except OSError as exc:
        if exc.errno == errno.ENOENT:  # a link whose transcript is gone: no sign of activity
            return 0.0
        raise Unreadable("%s cannot be inspected (%s)" % (path, exc.strerror))


def task_dirs(session_id):
    """The harness tasks directories of a session: HMD_AGENT_TASKDIR (heimdall-agents' own seam) when set, else <tmp>/claude-<uid>/<project>/<session>/tasks."""
    fixed = os.environ.get("HMD_AGENT_TASKDIR")
    if fixed:
        return [fixed]
    roots = []
    for root in (os.environ.get("TMPDIR", ""), "/private/tmp", "/tmp"):
        real = os.path.realpath(root) if root else ""
        if real and real not in roots:
            roots.append(real)
    found = []
    for root in roots:
        found.extend(glob.glob(os.path.join(glob.escape(root), "claude-*", "*", session_id, "tasks")))
    return found


def is_infrastructure(command):
    """Is this child of claude something claude or hmd keeps around, as opposed to work in progress? Everything not listed counts as work: a Bash-tool job
    is `/bin/zsh -c source <snapshot> ...`, and no allowlist entry matches a shell -c."""
    if any(p.search(command) for p in ALLOWED_CHILDREN):
        return True
    return os.path.basename(command.split(None, 1)[0]) not in SHELLS and MCP_SERVER.search(command) is not None


def binary_is_fresh(now):
    """Was the newest installed claude binary written less than BINARY_FRESH_S ago (an update may still be landing)?"""
    vdir = os.environ.get("HEIMDALL_CC_VERSIONS") or os.path.join(os.path.expanduser("~"), ".local", "share", "claude", "versions")
    try:
        names = os.listdir(vdir)
    except OSError as exc:
        raise Unreadable("%s cannot be listed (%s)" % (vdir, exc.strerror))
    if not names:
        raise Unreadable("%s holds no claude binary" % vdir)
    newest = max(names, key=version_key)
    try:
        written = os.stat(os.path.join(vdir, newest)).st_mtime
    except OSError as exc:
        raise Unreadable("%s/%s cannot be inspected (%s)" % (vdir, newest, exc.strerror))
    return now - written < BINARY_FRESH_S


def sweep_is_running(ctx):
    """A live pid in receipts/sweep.lock: of the session's repository (<repo>/.heimdall/receipts) and of $HEIMDALL_HOME, the two places the runner keeps it."""
    dirs = []
    found = ctx.git()
    if found:
        dirs.append(os.path.join(found[0], ".heimdall", "receipts"))
    if os.environ.get("HEIMDALL_HOME"):
        dirs.append(os.path.join(os.environ["HEIMDALL_HOME"], "receipts"))
    if not dirs:
        return False
    sys.path.insert(0, HERE)
    import hmd_sweep_guard  # the one reader of sweep.lock: a pid that names a live process, whoever owns it
    return any(hmd_sweep_guard.running(d) for d in dirs)


def task_is_live(ctx):
    """A harness task output written within TASK_FRESH_S, or a child of claude that is neither infrastructure nor the gate's own caller."""
    for tdir in task_dirs(ctx.session()["session_id"]):
        try:
            names = os.listdir(tdir)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.ENOTDIR):
                continue
            raise Unreadable("%s cannot be listed (%s)" % (tdir, exc.strerror))
        for name in names:
            if name.endswith(".output") and ctx.now - mtime_of(os.path.join(tdir, name)) < TASK_FRESH_S:
                return True
    claude, own = ctx.req()["pid"], ctx.own()
    return any(ppid == claude and pid not in own and not is_infrastructure(command) for pid, (ppid, command) in ctx.table().items())


class Ctx(object):
    """One evaluation: the inputs are read on first use (each read can raise Unreadable) and G3 leaves the pending targets for G7."""

    def __init__(self, req_path, skip_quiet):
        self.req_path = req_path
        self.skip_quiet = skip_quiet
        self.now = clock()
        self.home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
        self.settle = seconds("HMD_RESTART_SETTLE_S", DEFAULT_SETTLE_S)
        self.quiet = seconds("HMD_RESTART_QUIET_S", DEFAULT_QUIET_S)
        self.timeout = seconds("HMD_RESTART_CMD_TIMEOUT_S", DEFAULT_CMD_TIMEOUT_S) or DEFAULT_CMD_TIMEOUT_S
        self.targets = {}
        self._req = self._session = self._table = self._own = self._git = None
        self._git_read = False

    def command(self, name, default, what):
        raw = os.environ.get(name, "").strip()
        if not raw:
            if default is None:
                raise Unreadable("%s is not set, so %s cannot be asked" % (name, what))
            return default
        try:
            argv = shlex.split(raw)
        except ValueError:
            raise Unreadable("%s is not a command line" % name)
        if not argv:
            raise Unreadable("%s is not a command line" % name)
        return argv

    def run(self, argv, env=None):
        """(exit status, stdout) of a read-only helper; Unreadable when it cannot be started or does not answer within the timeout."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            raise Unreadable("%s did not answer within %gs" % (argv[0], self.timeout))
        except OSError as exc:
            raise Unreadable("%s cannot be run (%s)" % (argv[0], exc.strerror))
        return p.returncode, p.stdout.decode("utf-8", "replace")

    def req(self):
        if self._req is None:
            self._req = load_request(self.req_path, self.now)
        return self._req

    def session(self):
        if self._session is None:
            pid = self.req()["pid"]
            sdir = os.environ.get("HMD_RESTART_SESSIONS_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "sessions")
            self._session = parse_session(read_json(os.path.join(sdir, "%d.json" % pid), "the session file of claude pid %d" % pid), pid)
        return self._session

    def table(self):
        """pid -> (ppid, command line) of every process, from `ps` or HMD_RESTART_PS_CMD."""
        if self._table is None:
            rc, out = self.run(self.command("HMD_RESTART_PS_CMD", ["ps", "-axww", "-o", "pid=,ppid=,command="], "the process table"))
            if rc != 0:
                raise Unreadable("the process table command exited %d" % rc)
            rows = {}
            for line in out.splitlines():
                m = PS_ROW.match(line)
                if m:
                    rows[int(m.group(1))] = (int(m.group(2)), m.group(3))
            if not rows:
                raise Unreadable("the process table is empty")
            self._table = rows
        return self._table

    def own(self):
        """The gate's own pid and its ancestors: asked from inside a session (hmd restart status), the shell that asks is not work the session is doing."""
        if self._own is None:
            table, pid, chain = self.table(), os.getpid(), set()
            while pid and pid not in chain and len(chain) < 64:
                chain.add(pid)
                pid = table.get(pid, (0, ""))[0]
            self._own = chain
        return self._own

    def git(self):
        """(work tree root, git directory) around the session's cwd, or None when it is in no repository."""
        if not self._git_read:
            cwd = self.session()["cwd"]
            if not os.path.isdir(cwd):
                raise Unreadable("the session cwd %s is not a directory" % cwd)
            self._git, self._git_read = find_git(cwd), True
        return self._git


# -- the conditions, each None when it holds, else the reason token ------------------------------------------------------------------------------

def g1_opt_out(ctx):
    if os.environ.get("HMD_AUTO_RESTART", "").strip().lower() == "off":
        return OPT_OUT
    marker = os.path.join(ctx.home, "no-auto-restart")
    try:
        os.lstat(marker)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENOTDIR):
            return None
        raise Unreadable("it cannot be told whether %s exists (%s)" % (marker, exc.strerror))
    return OPT_OUT


def g2_supervised(ctx):
    return None if os.environ.get("HMD_SUPERVISED") == "1" else NOT_SUPERVISED


def g3_landed(ctx):
    rc, out = ctx.run(ctx.command("HMD_RESTART_PENDING_CMD", None, "whether an update is pending"))
    if rc == 1:
        return NO_UPDATE
    if rc != 0:
        raise Unreadable("the pending-update command exited %d" % rc)
    ctx.targets = parse_targets(out)
    if not ctx.targets:
        raise Unreadable("the pending-update command exited 0 but named no target")
    if any(INSTALLER.search(command) for _, command in ctx.table().values()):
        return INSTALL_RUNNING
    if "claude" in ctx.targets and binary_is_fresh(ctx.now):
        return BINARY_FRESH_TOKEN
    return None


def g4_turn_ended(ctx):
    session = ctx.session()
    if session["status"] != "idle":
        return NOT_IDLE
    if ctx.now - session["status_at"] < ctx.settle:
        return SETTLING
    lag = session["status_at"] - ctx.req()["stop_at"]  # how long after the recorded Stop the idle began
    if lag > STOP_BEFORE_IDLE_S or lag < -STOP_AFTER_IDLE_S:
        return NOT_IDLE
    return None


def g5_background(ctx):
    env = dict(os.environ)
    env["HMD_AGENT_CWD"] = ctx.session()["cwd"]
    rc, out = ctx.run(ctx.command("HMD_RESTART_AGENTS_CMD", [os.path.join(BIN, "heimdall-agents"), "count"], "the live subagent count"), env)
    count = out.strip()
    if rc != 0 or not re.match(r"^[0-9]{1,6}$", count):
        raise Unreadable("the subagent count command printed %r (exit %d)" % (count[:40], rc))
    if int(count) > 0:
        return AGENTS_LIVE
    if sweep_is_running(ctx):
        return SWEEP_RUNNING
    if task_is_live(ctx):
        return TASK_LIVE
    return None


def g6_quiet(ctx):
    if ctx.skip_quiet:
        return None
    tty = os.environ.get("HMD_RESTART_TTY", "")
    if not tty:
        raise Unreadable("HMD_RESTART_TTY is not set, so the time of the last keystroke is unknown")
    try:
        atime = os.stat(tty).st_atime
    except OSError as exc:
        raise Unreadable("the tty %s cannot be inspected (%s)" % (tty, exc.strerror))
    if ctx.now - atime < ctx.quiet:
        return USER_ACTIVE
    return None


def g7_loops(ctx):
    if ctx.now - ctx.session()["started_at"] < SESSION_MIN_AGE_S:
        return LOOP_GUARD
    last = read_json(os.path.join(ctx.home, "restart", "last.json"), "the record of the last restart", optional=True)
    if last is None:
        return None
    restarted_at = epoch_s(last.get("ts"), "the ts of the last restart")
    done = last.get("targets")
    if not isinstance(done, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in done.items()):
        raise Unreadable("the record of the last restart has no targets map of name -> version")
    if ctx.now - restarted_at < RESTART_GAP_S:
        return LOOP_GUARD
    if set(ctx.targets.items()) <= set(done.items()):
        return LOOP_GUARD
    return None


def g8_git(ctx):
    found = ctx.git()
    if not found:
        return None
    for name in GIT_OPS:
        path = os.path.join(found[1], name)
        try:
            os.lstat(path)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.ENOTDIR):
                continue
            raise Unreadable("%s cannot be inspected (%s)" % (path, exc.strerror))
        return GIT_MIDOP
    return None


CONDITIONS = (g1_opt_out, g2_supervised, g3_landed, g4_turn_ended, g5_background, g6_quiet, g7_loops, g8_git)


def evaluate(ctx):
    """The reason token of the first condition that does not hold, None when all do."""
    for condition in CONDITIONS:
        why = condition(ctx)
        if why:
            return why
    return None


USAGE = "usage: heimdall-restart-gate [--req FILE] [--now] [--json]\n"


def parse_args(argv):
    req, skip_quiet, as_json, k = None, False, False, 0
    while k < len(argv):
        arg = argv[k]
        k += 1
        if arg == "--now":
            skip_quiet = True
        elif arg == "--json":
            as_json = True
        elif arg == "--req" and k < len(argv):
            req, k = argv[k], k + 1
        elif arg.startswith("--req=") and len(arg) > len("--req="):
            req = arg[len("--req="):]
        else:
            return None
    return req, skip_quiet, as_json


def main(argv):
    parsed = parse_args(argv)
    if parsed is None:
        sys.stderr.write(USAGE)
        return 2
    req, skip_quiet, as_json = parsed
    if not req and os.environ.get("HMD_RESTART_DIR"):
        req = os.path.join(os.environ["HMD_RESTART_DIR"], "req.json")
    why = detail = None
    try:
        why = evaluate(Ctx(req, skip_quiet))
    except Unreadable as exc:
        why, detail = UNREADABLE, str(exc)
    except Exception as exc:  # a defect in the gate is a signal it could not read: never a SAFE
        why, detail = UNREADABLE, "internal error (%s)" % type(exc).__name__
    if as_json:
        sys.stdout.write(json.dumps({"verdict": "UNSAFE" if why else "SAFE", "reason": why, "detail": detail}) + "\n")
    else:
        sys.stdout.write(("UNSAFE %s\n" % why) if why else "SAFE\n")
    return 1 if why else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
