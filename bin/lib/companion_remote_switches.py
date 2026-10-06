#!/usr/bin/env python3
"""companion_remote_switches.py -- CP2 of hmdapp's docs/HANDOFF-TO-HEIMDALL-cursor-parity.md: the laptop-side safeguards every
`expand` remote action (launch-session, pr-merge, anything tagged expand later) sits behind. The dispatcher that enforces
them is bin/lib/companion_ui_controls.py; this module is what it asks, and the command line a person uses to answer it.

    $HEIMDALL_HOME/remote-launch.json   {"enabled": bool, "since": "<iso>"}   the launch switch   (off unless a person flipped it)
    $HEIMDALL_HOME/remote-merge.json    {"enabled": bool, "since": "<iso>"}   the merge switch    (a separate decision)
    $HEIMDALL_HOME/app/launch-allowlist.json  (0600, in a 0700 directory)
        [{"id": "r-3fa9", "label": "heimdall", "path": "<abs, never sent to the phone>", "merge": false}]
        id = "r-" + the first 4 hex of sha256 of the REALPATH; the path is realpath'd when it is added and re-checked on
        every use (a symlink swapped in since => the entry is not usable); only a repo added with --merge can receive pr-merge.
        Laptop-wide like the two switches, so it sits directly under $HEIMDALL_HOME (~/.heimdall/app/ by default), never under
        a second .heimdall inside it (that name belongs to a repo's own <repo>/.heimdall/).

    hmd app remote-launch on|off|status [--repo DIR]     (bin/heimdall-app delegates here: python3 <this file> remote-launch ...)
    hmd app remote-merge  on|off|status [--repo DIR]
    hmd app launch-allow <repo-path> [--merge] | --remove <id> | --list
    status-line [--repo DIR]                            one line for `hmd app status`: both switches and the allowlist size

WHAT ONLY A PERSON CAN DO. `on` and `launch-allow <path>` refuse unless stdin is a terminal (an agent's shell, a script and
the phone have none); `on` also refuses under HMD_UI_CONTROLS=0 and where the repo's kill switch file exists. `off`,
`status`, `--list` and `--remove` only reduce or read, so they need no terminal. Nothing in bin/lib/companion_ui_controls.py,
bin/heimdall-relay-client or sentinels/hmd-ui.py imports a writer from here (test/heimdall-remote-switches.test.sh greps for it
and runs every allowed action against the switch files): no remote action can flip a switch or widen the allowlist.

FAIL CLOSED. A switch file, or the allowlist, that is missing, oversized, not JSON, mistyped, a symlink, a non-regular file,
owned by another user or writable by group or others reads as OFF / empty -- and `status` says why. An allowlist entry that is
malformed, whose id is not the hash of its path, or whose path no longer resolves to itself is ignored, never repaired.
There is no environment variable, flag or test hook that bypasses the terminal check.

Stdlib only. Self-contained except for two lazily loaded siblings used for helpers (companion_ui_controls: secret_shaped and
controls_enabled).
"""
import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))

SWITCHES = {"launch": "remote-launch.json", "merge": "remote-merge.json", "dashboards": "remote-dashboards.json"}
CLI_SWITCH = {"remote-launch": "launch", "remote-merge": "merge", "remote-dashboards": "dashboards"}
SWITCH_WORDS = {"launch": "remote launch", "merge": "remote merge", "dashboards": "remote dashboards"}
OPEN_SWITCHES = frozenset(("dashboards",))   # a switch that is the whole gate: its action acts on the session's own repo, no allowlist
SWITCH_MAX_BYTES = 4096
ALLOWLIST_REL = os.path.join("app", "launch-allowlist.json")
ALLOWLIST_LOCK_REL = os.path.join("app", "launch-allowlist.lock")
ALLOWLIST_MAX_BYTES = 65536
ALLOWLIST_MAX_ENTRIES = 32
LABEL_MAX = 32
KILL_SWITCH_ENV = "HMD_UI_CONTROLS"

REPO_ID_RE = re.compile(r"r-[0-9a-f]{4}")
SINCE_RE = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
ENTRY_KEYS = frozenset(("id", "label", "path", "merge"))

_MODULES = {}


def _sibling(name):
    """A sibling bin/lib module loaded by path (None when it cannot load), once."""
    if name not in _MODULES:
        try:
            spec = spec_from_file_location(name, os.path.join(HERE, name + ".py"))
            mod = module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            mod = None
        _MODULES[name] = mod
    return _MODULES[name]


def heimdall_home():
    """$HEIMDALL_HOME, else ~/.heimdall; None when neither HEIMDALL_HOME nor HOME is set (everything is then off -- there
    is no /tmp fallback, a directory other users can write)."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    home = os.environ.get("HOME")
    return os.path.join(home, ".heimdall") if home else None


def _read_trusted_json(path, cap):
    """(value, why): the JSON in `path` when it is a regular file this user owns and nobody else can write, read through the
    descriptor that was checked (no symlink followed, no check-then-open gap). (None, None) when it is simply absent;
    (None, <reason>) when it exists but cannot be trusted."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        return None, None
    except OSError:
        return None, "unreadable, or a symlink"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "not a regular file"
        if st.st_uid != os.geteuid():
            return None, "owned by another user"
        if st.st_mode & 0o022:
            return None, "writable by group or others"
        raw = os.read(fd, cap + 1)
    finally:
        os.close(fd)
    if len(raw) > cap:
        return None, "too large"
    try:
        return json.loads(raw.decode("utf-8")), None
    except (ValueError, UnicodeDecodeError):
        return None, "not valid JSON"


def _write_json_atomic(path, obj):
    """Temp file, fsync, rename: 0600, never a half-written switch. A symlink at `path` is replaced, never followed.
    The temp file is unique per call (mkstemp), so two threads setting one switch never share one."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=os.path.basename(path) + ".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(obj, sort_keys=True, separators=(",", ":")))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


# -- the two switches -------------------------------------------------------------------------------------------------
def switch_state(name, home=None):
    """{"enabled": bool, "since": str|None, "why": str|None} -- `why` is only set when the file exists and was refused."""
    home = home or heimdall_home()
    if name not in SWITCHES or not home:
        return {"enabled": False, "since": None, "why": None if name in SWITCHES else "unknown switch"}
    obj, why = _read_trusted_json(os.path.join(home, SWITCHES[name]), SWITCH_MAX_BYTES)
    if not isinstance(obj, dict):
        return {"enabled": False, "since": None, "why": why or ("not an object" if obj is not None else None)}
    since = obj.get("since")
    if obj.get("enabled") is True and isinstance(since, str) and SINCE_RE.fullmatch(since):
        return {"enabled": True, "since": since, "why": None}
    if obj.get("enabled") is False and isinstance(since, str) and SINCE_RE.fullmatch(since):
        return {"enabled": False, "since": since, "why": None}
    return {"enabled": False, "since": None, "why": "malformed"}


def switch_enabled(name, home=None):
    return switch_state(name, home)["enabled"]


def set_switch(name, enabled, home=None):
    """Write the switch file. ONLY the command line below calls this: it is the one writer, and it is never reachable from a
    remote action."""
    home = home or heimdall_home()
    if name not in SWITCHES or not home:
        raise OSError("no such switch, or no HEIMDALL_HOME / HOME to keep it in")
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    _write_json_atomic(os.path.join(home, SWITCHES[name]), {"enabled": bool(enabled), "since": since})


# -- the repo allowlist -----------------------------------------------------------------------------------------------------
def repo_id(realpath):
    return "r-" + hashlib.sha256(realpath.encode("utf-8")).hexdigest()[:4]


def clean_label(text, fallback):
    """A label the phone may be shown: printable, at most LABEL_MAX characters, not secret-shaped, not a path."""
    label = "".join(ch for ch in str(text) if ch.isprintable())[:LABEL_MAX].strip()
    controls = _sibling("companion_ui_controls")
    if not label or label.startswith("/") or controls is None or controls.secret_shaped(label):
        return fallback
    return label


def _valid_entry(item):
    if not isinstance(item, dict) or set(item) != ENTRY_KEYS:
        return None
    ident, label, path, merge = item["id"], item["label"], item["path"], item["merge"]
    if not (isinstance(ident, str) and REPO_ID_RE.fullmatch(ident) and isinstance(label, str) and 0 < len(label) <= LABEL_MAX
            and isinstance(path, str) and os.path.isabs(path) and os.path.normpath(path) == path and isinstance(merge, bool)):
        return None
    return dict(item) if repo_id(path) == ident else None


def read_entries(home=None):
    """The allowlist's valid entries (malformed ones, duplicate ids and everything past the cap are dropped); [] when the file
    is absent or cannot be trusted."""
    home = home or heimdall_home()
    if not home:
        return []
    obj, _why = _read_trusted_json(os.path.join(home, ALLOWLIST_REL), ALLOWLIST_MAX_BYTES)
    if not isinstance(obj, list):
        return []
    out, seen = [], set()
    for item in obj[:ALLOWLIST_MAX_ENTRIES]:
        entry = _valid_entry(item)
        if entry is not None and entry["id"] not in seen:
            seen.add(entry["id"])
            out.append(entry)
    return out


def usable(entry):
    """Does the entry's path still resolve to itself (no symlink swapped in, nothing renamed away) and is it a directory?"""
    return os.path.realpath(entry["path"]) == entry["path"] and os.path.isdir(entry["path"])


def find(wanted, home=None):
    """The usable allowlist entry whose ID is `wanted` -- an id, never a label or a path -- else None."""
    if not (isinstance(wanted, str) and REPO_ID_RE.fullmatch(wanted)):
        return None
    for entry in read_entries(home):
        if entry["id"] == wanted:
            return entry if usable(entry) else None
    return None


def label_of(wanted, home=None):
    """The label of the allowlist entry with this id (usable or not: a label is harmless), else None."""
    if not (isinstance(wanted, str) and REPO_ID_RE.fullmatch(wanted)):
        return None
    for entry in read_entries(home):
        if entry["id"] == wanted:
            return entry["label"]
    return None


def public_repos(home=None):
    """What the phone may be told about the allowlist: id and label of every usable entry. Never a path."""
    return [{"id": e["id"], "label": e["label"]} for e in read_entries(home) if usable(e)]


def authorize(switch, repo=None, root=None, home=None):
    """The allowlist entry (a copy, with hmd's own path) an expand action under `switch` may act on, else None: the switch is
    on, and the repo is on the allowlist -- named by `repo` (an id) or, for an action about the session's own repo, `root` --
    still resolves to the path it was added with and, for the merge switch, was added with --merge."""
    if switch not in SWITCHES or not switch_enabled(switch, home):
        return None
    if repo is not None:
        entry = find(repo, home)
    elif root is not None:
        real = os.path.realpath(root)
        entry = find(repo_id(real), home)
        if entry is not None and entry["path"] != real:
            entry = None
    else:
        return None
    if entry is None:
        return None
    if switch == "merge" and entry["merge"] is not True:
        return None
    return dict(entry)


def available(switch, root=None, home=None):
    """True when an expand action under `switch` has something to act on now: the switch is on and (launch) some allowlisted
    repo is usable, or (merge) `root` is allowlisted with --merge."""
    if not switch_enabled(switch, home):
        return False
    if switch in OPEN_SWITCHES:
        return True
    if switch == "merge":
        return authorize("merge", root=root, home=home) is not None
    return bool(public_repos(home))


def _git_toplevel(real):
    env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
    try:
        done = subprocess.run(["git", "-C", real, "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=10, text=True)
    except (OSError, subprocess.SubprocessError):
        return None
    out = done.stdout.strip()
    return os.path.realpath(out) if done.returncode == 0 and out else None


@contextlib.contextmanager
def _allowlist_lock(home):
    path = os.path.join(home, ALLOWLIST_LOCK_REL)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _write_allowlist(home, entries):
    _write_json_atomic(os.path.join(home, ALLOWLIST_REL), entries)


def add_repo(path, merge=False, home=None):
    """(entry, None) once the repo at `path` is on the allowlist, else (None, reason). The path is realpath'd here and must be the
    root of a git work tree; the id is derived from that real path; a re-add restates the entry (so `merge` falls back to
    False unless asked for again). ONLY the command line below calls this."""
    home = home or heimdall_home()
    if not home:
        return None, "no HEIMDALL_HOME or HOME to keep the allowlist in"
    try:
        real = os.path.realpath(os.path.expanduser(path))
    except (OSError, ValueError):
        return None, "that path cannot be resolved"
    if not os.path.isdir(real):
        return None, "not a directory"
    top = _git_toplevel(real)
    if top is None:
        return None, "not a git repository (or git is missing)"
    if top != real:
        return None, "not the root of its repository (the root is %s)" % top
    ident = repo_id(real)
    entry = {"id": ident, "label": clean_label(os.path.basename(real), ident), "path": real, "merge": bool(merge)}
    with _allowlist_lock(home):
        entries = read_entries(home)
        if any(e["id"] == ident and e["path"] != real for e in entries):
            return None, "its id collides with another allowlisted repo"
        entries = [e for e in entries if e["id"] != ident] + [entry]
        if len(entries) > ALLOWLIST_MAX_ENTRIES:
            return None, "the allowlist is full (%d repos)" % ALLOWLIST_MAX_ENTRIES
        _write_allowlist(home, entries)
    return entry, None


def remove_repo(wanted, home=None):
    """True when the allowlist had an entry with this id (an id, never a label) and it is gone now."""
    home = home or heimdall_home()
    if not home or not (isinstance(wanted, str) and REPO_ID_RE.fullmatch(wanted)):
        return False
    with _allowlist_lock(home):
        entries = read_entries(home)
        kept = [e for e in entries if e["id"] != wanted]
        if len(kept) == len(entries):
            return False
        _write_allowlist(home, kept)
    return True


# -- the command line -------------------------------------------------------------------------------------------------------
USAGE = ("usage: hmd app remote-launch on|off|status [--repo DIR]\n"
         "       hmd app remote-merge  on|off|status [--repo DIR]\n"
         "       hmd app remote-dashboards on|off|status [--repo DIR]\n"
         "       hmd app launch-allow <repo-path> [--merge] | --remove <id> | --list\n")


def _say(text):
    sys.stdout.write(text + "\n")


def _refuse(text):
    sys.stderr.write(text + "\n")
    return 1


def _require_tty(what):
    """Only a person at a terminal may widen what the phone can do: an agent's shell, a script and the phone have none."""
    if not sys.stdin.isatty():
        sys.stderr.write("%s: refused -- this needs an interactive terminal on the laptop (stdin is not a TTY). A person has "
                         "to run it; an agent, a script and the phone cannot.\n" % what)
        return False
    return True


def _repo_arg(rest):
    """(root, remaining) from an optional `--repo DIR`; root is None for a malformed one."""
    root, remaining, i = os.getcwd(), [], 0
    while i < len(rest):
        if rest[i] == "--repo" and i + 1 < len(rest):
            root = rest[i + 1]
            i += 2
        else:
            remaining.append(rest[i])
            i += 1
    return os.path.realpath(os.path.expanduser(root)), remaining


def _cmd_switch(switch, cmd, rest):
    root, args = _repo_arg(rest)
    if len(args) != 1 or args[0] not in ("on", "off", "status"):
        sys.stderr.write(USAGE)
        return 2
    sub, word = args[0], SWITCH_WORDS[switch]
    if sub == "status":
        return _print_status(switch, word)
    if sub == "off":
        try:
            set_switch(switch, False)
        except OSError as e:
            return _refuse("%s off: cannot write the switch (%s)" % (cmd, type(e).__name__))
        _say("%s: off" % word)
        return 0
    if not _require_tty("%s on" % cmd):
        return 1
    if os.environ.get(KILL_SWITCH_ENV) == "0":
        return _refuse("%s on: refused -- HMD_UI_CONTROLS=0 is set in this shell and switches every remote control off" % cmd)
    controls = _sibling("companion_ui_controls")
    if controls is None or not controls.controls_enabled(root):
        return _refuse("%s on: refused -- remote controls are off for this repo (hmd app controls on re-enables them)" % cmd)
    try:
        set_switch(switch, True)
    except OSError as e:
        return _refuse("%s on: cannot write the switch (%s)" % (cmd, type(e).__name__))
    if switch == "launch":
        _say("remote launch: on -- the paired phone can start new Claude Code sessions in the repos on the allowlist "
             "(hmd app launch-allow --list). Turn it off with: hmd app remote-launch off")
    elif switch == "dashboards":
        _say("remote dashboards: on -- the paired phone can describe a panel in words and hmd on this laptop builds a read-only "
             "data producer for it; nothing runs until you confirm it here (hmd dash pending). Turn it off with: hmd app "
             "remote-dashboards off")
        return 0
    else:
        _say("remote merge: on -- the paired phone can merge a pull request for a repo allowlisted with --merge, only while "
             "hmd's gates and the sweep receipt for that exact head are green. Turn it off with: hmd app remote-merge off")
    if not read_entries():
        _say("the allowlist is empty, so nothing can be reached yet: hmd app launch-allow <repo-path>%s"
             % (" --merge" if switch == "merge" else ""))
    return 0


def _print_status(switch, word):
    st = switch_state(switch)
    if st["enabled"]:
        _say("%s: on (since %s)" % (word, st["since"]))
    else:
        _say("%s: off%s" % (word, " (ignored: %s)" % st["why"] if st["why"] else ""))
    entries = read_entries()
    _say("allowlist: %d repo(s), %d with merge" % (len(entries), sum(1 for e in entries if e["merge"])))
    return 0


def _cmd_status_line():
    entries = read_entries()
    _say("remote: launch %s, merge %s, allowlist %d repo(s)" % (
        "on" if switch_enabled("launch") else "off", "on" if switch_enabled("merge") else "off", len(entries)))
    return 0


def _cmd_allow(rest):
    merge, remove, list_only, paths, i = False, None, False, [], 0
    while i < len(rest):
        arg = rest[i]
        if arg == "--merge":
            merge = True
        elif arg == "--list":
            list_only = True
        elif arg == "--remove" and i + 1 < len(rest):
            remove = rest[i + 1]
            i += 1
        elif arg.startswith("--"):
            sys.stderr.write(USAGE)
            return 2
        else:
            paths.append(arg)
        i += 1
    if sum((list_only, remove is not None, bool(paths))) != 1 or len(paths) > 1 or (merge and not paths):
        sys.stderr.write(USAGE)
        return 2
    if list_only:
        for e in read_entries():
            _say("%s  %-*s  merge:%s  %s%s" % (e["id"], LABEL_MAX, e["label"], "yes" if e["merge"] else "no", e["path"],
                                              "" if usable(e) else "  (STALE: the path no longer resolves to itself -- not offered)"))
        return 0
    if remove is not None:
        if remove_repo(remove):
            _say("removed %s from the launch allowlist" % remove)
            return 0
        return _refuse("launch-allow --remove: no allowlisted repo has the id %r (an id like r-3fa9, not a label)" % remove[:20])
    if not _require_tty("launch-allow"):
        return 1
    entry, why = add_repo(paths[0], merge)
    if entry is None:
        return _refuse("launch-allow: refused -- %s" % why)
    _say("allowed %s %s (merge: %s) -- the phone sees the id and the label, never the path" % (
        entry["id"], entry["label"], "yes" if entry["merge"] else "no"))
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd in CLI_SWITCH:
        return _cmd_switch(CLI_SWITCH[cmd], cmd, rest)
    if cmd == "launch-allow":
        return _cmd_allow(rest)
    if cmd == "status-line":
        return _cmd_status_line()
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
