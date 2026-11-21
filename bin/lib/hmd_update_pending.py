#!/usr/bin/env python3
"""hmd_update_pending -- is a newer claude, or a newer hmd, installed than the one this session started with?

The seamless-restart feature (docs/superpowers/plans/2026-11-13-seamless-update-restart.md, sections 2 and 3, Task W1-hmd-pending) asks this before it does
anything else: is there anything to restart FOR? The Stop hook asks it after every turn and the restart gate reads it as G3, so it stays cheap (one git call
and one command) and it only says "yes" about what it could read in full, because a wrong "yes" ends a running session.

  heimdall-update-pending --launcher-start-hmd X.Y.Z [--pid P] [--json]

  stdout   up to two lines, claude first:   claude <running> <newest>     hmd <at launcher start> <on disk now>
           --json: the same as ONE object, {"claude":[a,b],"hmd":[a,b]}; a half that is not pending is absent
  exit     0  at least one half is pending, and every input could be read
           1  nothing is pending, OR an input could not be read: no stdout either way (fail closed)
           2  a usage error (stderr)
  stderr   empty on exit 0 and 1, unless HMD_UPDATE_PENDING_DEBUG=1: then ONE line names why nothing was reported

The claude half is `heimdall-cc-selfheal pending [--pid P]`, by contract: it prints `claude <running> <newest>` and exits 0 when the session runs an older
claude than the newest installed, and prints nothing and exits 1 otherwise. HMD_UPDATE_CC_PENDING_CMD replaces that command (a test seam; --pid is appended).
Anything else it does (another exit status, a line that is not exactly `claude <version> <version>`, a hang past HMD_UPDATE_CMD_TIMEOUT_S, a command that
cannot start) is an unreadable input. The line is checked token by token, because the launcher prints it into a terminal.

The hmd half compares the version the launcher recorded at its start (--launcher-start-hmd) with the version on disk now, and is pending only when the one on
disk is strictly newer (a downgrade is not pending). The version on disk is .claude-plugin/plugin.json's `version`, read first, the way bin/heimdall's
banner_version() reads it: the manifest ships bundled with the release code, so it names the code that is on disk. `git describe --tags --abbrev=0 --match
'v[0-9]*'` is only the fallback, used when the manifest carries no version at all: a hint, never a second opinion that has to agree. It cannot be one, because
install.sh upgrades an installed clone with `git fetch origin <tag>` + `git checkout FETCH_HEAD`, which creates no local tag: after a real upgrade `git describe`
keeps naming the OLD tag for good while plugin.json names the new version (measured on install.sh's own sequence; test/hmd-update-pending.test.sh replays it).
bin/heimdall-autoupdate's installed_version() and bin/heimdall's heimdall_version() read describe first and are stale on such a tree, so the launcher must record
--launcher-start-hmd from plugin.json the way this helper reads it (banner_version()), or a launcher started on an upgraded tree would see an update that is
already installed. test/hmd-update-pending.test.sh holds this helper to banner_version's order and to the updater's describe flags and version pattern.

"Fully installed" means the update FINISHED, not that its files are on disk. Two markers say it has not:
  * bin/heimdall-autoupdate runs its verified installer inside ${TMPDIR:-/tmp}/heimdall-apply.<random> and removes that directory only after the installer has
    exited (`bash install.sh ...; rm -rf workdir`): it is the one completion marker that updater has. A directory of that name younger than an hour is a
    running installer; an older one is an installer that was killed, never cleaned up, and is ignored.
  * install.sh updates with `git fetch` + `git checkout FETCH_HEAD`, and git holds .git/index.lock for as long as it is writing the tree (measured: the lock
    exists, the manifest on disk is already the new version and HEAD is still the old commit while a file is being written). A lock that stays behind means a
    checkout that died half way, which is no tree to restart from either.
Either marker, or any half that cannot be read, makes the whole answer "nothing" (the plan's rule: failing to restart costs the old behaviour, a pin notice;
failing to be safe costs the operator's run). The hmd half vetoes the claude half and the other way round: a claude restart would re-exec the new launcher.

Environment: HMD_UPDATE_PLUGIN_DIR (the plugin tree whose version is read; default the tree this file is in), HMD_UPDATE_CC_PENDING_CMD (above),
HMD_UPDATE_CMD_TIMEOUT_S (default 5: how long git or the cc command may take; a child that outlives it is killed with its process group),
HMD_UPDATE_PENDING_DEBUG=1 (say why on stderr), TMPDIR (where the installer's workdir is looked for). Every GIT_* variable is dropped before git runs, so
a GIT_DIR inherited from a parent process (a git hook) cannot point the answer at another repository.
"""
import argparse
import contextlib
import json
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PLUGIN_DIR = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
CC_SELFHEAL = os.path.normpath(os.path.join(HERE, os.pardir, "heimdall-cc-selfheal"))
try:
    TIMEOUT_S = float(os.environ.get("HMD_UPDATE_CMD_TIMEOUT_S", "5"))
except ValueError:
    TIMEOUT_S = 5.0
if not 0 < TIMEOUT_S <= 600:
    TIMEOUT_S = 5.0

APPLY_DIR_PREFIX = "heimdall-apply."  # bin/heimdall-autoupdate apply_update: mktemp -d "${TMPDIR:-/tmp}/heimdall-apply.<random>"
APPLY_DIR_MAX_AGE_S = 3600
DESCRIBE = ("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*")  # installed_version's git call, flag for flag
SEMVER = re.compile(r"^\s*v?([0-9]+\.[0-9]+\.[0-9]+)")  # norm_semver's pattern
START_VERSION = re.compile(r"v?([0-9]+\.[0-9]+\.[0-9]+)")
TOKEN = r"[0-9][0-9A-Za-z.+_-]{0,63}"
CLAUDE_LINE = re.compile(r"claude (%s) (%s)" % (TOKEN, TOKEN))


class Unreadable(Exception):
    """An input could not be read, or the plugin tree is not settled: the answer is "nothing", never a guess."""


def norm_semver(text):
    """bin/heimdall-autoupdate's norm_semver: a leading v and any suffix dropped; None when it is no X.Y.Z."""
    match = SEMVER.match(text)
    return match.group(1) if match else None


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def run_cmd(argv, env):
    """(exit status, stdout) of argv; (None, "") when it cannot be started; Unreadable when it outlives TIMEOUT_S (its whole process group is killed)."""
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    except OSError:
        return None, ""
    try:
        out, _ = proc.communicate(timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        proc.stdout.close()
        raise Unreadable("%s did not answer within %gs" % (argv[0], TIMEOUT_S))
    return proc.returncode, out.decode("utf-8", "replace")


def git(plugin_dir, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    return run_cmd(["git", "-C", plugin_dir] + list(args), env)


def git_layout(plugin_dir):
    """(is a repository, where its index.lock would be) from one git call; (False, None) when git is absent or the directory is no repository."""
    status, out = git(plugin_dir, "rev-parse", "--git-dir", "--git-path", "index.lock")
    if status != 0:
        return False, None
    lines = out.splitlines()
    if len(lines) != 2:
        raise Unreadable("git answered %r to rev-parse" % out[:80])
    lock = lines[1]
    return True, lock if os.path.isabs(lock) else os.path.join(plugin_dir, lock)


def describe_version(plugin_dir):
    """The fallback source: the nearest vX.Y.Z tag (installed_version's git call, flag for flag), None when the repository has none. A hint, never a check on plugin.json: after install.sh's tag-less upgrade it still names the OLD release."""
    status, out = git(plugin_dir, *DESCRIBE)
    return norm_semver(out.strip()) if status == 0 else None


def manifest_version(plugin_dir):
    """The source that decides: .claude-plugin/plugin.json's version, None when the file or the field is absent (Unreadable when the file is not JSON)."""
    path = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise Unreadable("%s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise Unreadable("%s is not a JSON object" % path)
    version = data.get("version")
    return norm_semver(version) if isinstance(version, str) else None


def apply_in_flight():
    """True while bin/heimdall-autoupdate's verified installer runs: its heimdall-apply.* workdir exists from before the installer starts until after it exits."""
    root = os.environ.get("TMPDIR") or "/tmp"
    try:
        names = os.listdir(root)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as exc:
        raise Unreadable("cannot list %s: %s" % (root, exc.strerror))
    now = time.time()
    for name in names:
        if not name.startswith(APPLY_DIR_PREFIX):
            continue
        try:
            info = os.lstat(os.path.join(root, name))
        except FileNotFoundError:
            continue  # gone between the listing and the stat: the installer finished just now
        except OSError as exc:
            raise Unreadable("cannot stat %s: %s" % (os.path.join(root, name), exc.strerror))
        if stat.S_ISDIR(info.st_mode) and now - info.st_mtime < APPLY_DIR_MAX_AGE_S:
            return True
    return False


def resolve_hmd_version(plugin_dir):
    """The hmd version on disk now, or Unreadable: the update is still landing or no source can be read. plugin.json decides; git describe is only the fallback."""
    if apply_in_flight():
        raise Unreadable("the installer is still running (a %s* workdir is in %s)" % (APPLY_DIR_PREFIX, os.environ.get("TMPDIR") or "/tmp"))
    is_repo, lock = git_layout(plugin_dir)
    if lock and os.path.lexists(lock):
        raise Unreadable("git is rewriting the plugin tree (%s exists)" % lock)
    version = manifest_version(plugin_dir)
    if not version and is_repo:
        version = describe_version(plugin_dir)
    if not version:
        raise Unreadable("no version source: the plugin tree has neither a plugin.json version nor a vX.Y.Z tag")
    return version


def hmd_half(start, plugin_dir):
    """[at launcher start, on disk now] when the version on disk is strictly newer, else None."""
    now = resolve_hmd_version(plugin_dir)
    if version_tuple(now) > version_tuple(start):
        return [start, now]
    return None


def claude_half(pid):
    """[running, newest] from `heimdall-cc-selfheal pending`, None when it says nothing is pending."""
    try:
        argv = shlex.split(os.environ.get("HMD_UPDATE_CC_PENDING_CMD") or "")
    except ValueError as exc:
        raise Unreadable("HMD_UPDATE_CC_PENDING_CMD: %s" % exc)
    if not argv:
        argv = [CC_SELFHEAL, "pending"]
    if pid is not None:
        argv += ["--pid", pid]
    status, out = run_cmd(argv, None)
    if status is None:
        raise Unreadable("cannot start %s" % argv[0])
    text = out.strip()
    if status == 1 and not text:
        return None
    match = CLAUDE_LINE.fullmatch(text) if status == 0 else None
    if not match:
        raise Unreadable("%s answered %r (exit %s)" % (argv[0], text[:80], status))
    return [match.group(1), match.group(2)]


def pending(args):
    start = START_VERSION.fullmatch(args.launcher_start_hmd)
    if not start:
        raise Unreadable("--launcher-start-hmd %r is not X.Y.Z" % args.launcher_start_hmd[:40])
    if args.pid is not None and not (re.fullmatch(r"[0-9]+", args.pid) and int(args.pid) > 0):
        raise Unreadable("--pid %r is not a process id" % args.pid[:40])
    halves = {}
    hmd = hmd_half(start.group(1), os.environ.get("HMD_UPDATE_PLUGIN_DIR") or DEFAULT_PLUGIN_DIR)
    claude = claude_half(args.pid)
    if claude:
        halves["claude"] = claude
    if hmd:
        halves["hmd"] = hmd
    return halves


def main(argv):
    parser = argparse.ArgumentParser(
        prog="heimdall-update-pending", allow_abbrev=False,
        description="Report a newer claude and/or a newer hmd than this session started with. Exit 0 and print a line per pending half, "
                    "else exit 1 and print nothing (also when an input cannot be read).")
    parser.add_argument("--launcher-start-hmd", required=True, metavar="X.Y.Z", help="the hmd version the launcher recorded when it started")
    parser.add_argument("--pid", metavar="P", help="the claude process whose running version is compared (forwarded to heimdall-cc-selfheal)")
    parser.add_argument("--json", action="store_true", help="print one JSON object instead of lines")
    args = parser.parse_args(argv)
    try:
        halves = pending(args)
    except Unreadable as exc:
        if os.environ.get("HMD_UPDATE_PENDING_DEBUG") == "1":
            print("heimdall-update-pending: nothing reported, unreadable input: %s" % exc, file=sys.stderr)
        return 1
    if not halves:
        return 1
    if args.json:
        print(json.dumps(halves, sort_keys=True, separators=(",", ":")))
        return 0
    for name in ("claude", "hmd"):
        if name in halves:
            print("%s %s %s" % (name, halves[name][0], halves[name][1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
