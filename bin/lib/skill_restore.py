#!/usr/bin/env python3
"""skill_restore.py -- the state half of bin/skill-manager: pause skills for one launch, undo it after.

    skill_restore.py activate CONFIG SETTINGS PROJECT_DIR RESTORE_FILE STATE_DIR
    skill_restore.py restore  SETTINGS RESTORE_FILE STATE_DIR

`activate` flips ~/.claude/settings.json's enabledPlugins to what the project needs (the permanent
set plus whatever heimdall-skills.json detects) and records the undo in RESTORE_FILE. `restore`
applies that undo and deletes the file. The launcher (bin/heimdall) picks RESTORE_FILE once, from
its own pid, and hands the same path to both -- see bin/skill-manager for the CLI and why.

WHAT A RESTORE FILE HOLDS. Not a snapshot of enabledPlugins -- the list of flips THIS launch made:

    {"t": <activation time>, "changes": {"<plugin>": {"from": <bool>, "to": <bool>}, ...}}

`restore` puts a plugin back to `from` only while it still reads `to`. So it undoes this launch's
own pause and nothing else: a plugin installed mid-session is not dropped, and a plugin the user
switched back on is not switched off again. (Writing a whole snapshot back would do both.)

OVERLAPPING LAUNCHES. Launch B can start while A is running, and then B sees A's pause as the
"current" state. Recording that as B's `from` would make the last launch to leave re-pause what the
first one had un-paused. So `from` is the ORIGINAL value: the `from` of the oldest still-running
launch that flipped the same plugin, else the current value. Every restore in a chain then writes
the same original, and the final state is the original in whatever order the launches leave.

A DEAD LAUNCHER. A launcher that is killed (kill -9, power loss) never restores. Its file is
<STATE_DIR>/<pid>.json, so the next `activate` can tell it is stale (the pid is gone), applies its
undo first, and deletes it -- at most SWEEP_MAX files per activation, so a directory full of debris
cannot stall a launch. A file whose owner is alive is never touched; an unreadable one from a dead
owner is simply dropped.

CONCURRENCY. Every read-modify-write of settings.json runs under one advisory lock in STATE_DIR.
If the lock cannot be had within LOCK_WAIT_SECONDS the work proceeds unlocked: pausing skills is
housekeeping and must never hang a launch.

Settings are written in place (as they always were), which keeps a symlinked settings.json
symlinked. The restore file is written to a temp file and renamed, so a crash never leaves half of
one. stdlib only.
"""
import contextlib
import glob
import json
import os
import re
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # no flock on this platform: run unlocked rather than fail
    fcntl = None

SWEEP_MAX = 64
LOCK_WAIT_SECONDS = 10
OWNER_FILE = re.compile(r"^[0-9]+\.json$")
USAGE = (
    "usage:\n"
    "  skill_restore.py activate CONFIG SETTINGS PROJECT_DIR RESTORE_FILE STATE_DIR\n"
    "  skill_restore.py restore  SETTINGS RESTORE_FILE STATE_DIR\n"
)


def warn(message):
    sys.stderr.write("skill-manager: %s\n" % message)


def read_json(path):
    with open(path) as handle:
        return json.load(handle)


def write_settings(path, settings):
    text = json.dumps(settings, indent=2) + "\n"
    with open(path, "w") as handle:
        handle.write(text)


def write_restore_file(path, record):
    """Atomically: a temp file in the same private directory, then a rename."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".restore-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def load_restore_file(path):
    """(activation time, changes) from one of our restore files, or None if it is not one."""
    try:
        data = read_json(path)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("changes"), dict):
        return None
    changes = {}
    for name, change in data["changes"].items():
        if (isinstance(change, dict) and isinstance(change.get("from"), bool)
                and isinstance(change.get("to"), bool)):
            changes[name] = {"from": change["from"], "to": change["to"]}
    stamp = data.get("t")
    return (float(stamp) if isinstance(stamp, (int, float)) else 0.0), changes


@contextlib.contextmanager
def locked(state_dir):
    """Serialize settings.json read-modify-writes across concurrent launches (see CONCURRENCY)."""
    fd = None
    held = False
    if fcntl is not None:
        try:
            fd = os.open(os.path.join(state_dir, ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        except OSError:
            fd = None
    if fd is not None:
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
    try:
        yield
    finally:
        if fd is not None:
            if held:
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def owner_alive(pid):
    try:
        os.kill(pid, 0)
    except (OverflowError, ValueError, ProcessLookupError):
        return False  # not a pid this OS can have, or no such process
    except OSError:
        return True  # EPERM (it exists, it just is not ours to signal) or anything we cannot judge
    return True


def same_file(first, second):
    return os.path.realpath(first) == os.path.realpath(second)


def owner_files(state_dir):
    """Every <pid>.json in the state directory."""
    return [os.path.join(state_dir, name) for name in sorted(os.listdir(state_dir)) if OWNER_FILE.match(name)]


def stale_restore_files(state_dir, own_path):
    """Restore files whose owner pid is gone, oldest first, at most SWEEP_MAX of them."""
    found = []
    for path in owner_files(state_dir):
        if same_file(path, own_path):
            continue
        if owner_alive(int(os.path.splitext(os.path.basename(path))[0])):
            continue
        try:
            found.append((os.stat(path).st_mtime, path))
        except OSError:
            continue  # it vanished between the listing and the stat
    return [path for _mtime, path in sorted(found)[:SWEEP_MAX]]


def other_launches(state_dir, own_path):
    """(activation time, changes) of every other restore file still in play (its owner is running)."""
    loaded = [load_restore_file(path) for path in owner_files(state_dir) if not same_file(path, own_path)]
    return [entry for entry in loaded if entry is not None]


def revert(plugins, changes):
    """Put back what a launch changed, but only where nobody has changed it since.

    Returns True when a plugin actually moved.
    """
    moved = False
    for name, change in changes.items():
        current = plugins.get(name)
        if isinstance(current, bool) and current == change["to"]:
            plugins[name] = change["from"]
            moved = moved or change["from"] != change["to"]
    return moved


def original_value(name, launches, current):
    """The value `name` had before the oldest running launch that flipped it (else: right now)."""
    for _stamp, changes in launches:
        if name in changes:
            return changes[name]["from"]
    return current


def needed_plugins(config, project_dir):
    needed = set(config.get("permanent", []))
    for rule in config.get("detection", {}).values():
        for pattern in rule.get("files", []):
            # top level, one level deep (fast scan), then src/ (common convention)
            if (glob.glob(os.path.join(project_dir, pattern))
                    or glob.glob(os.path.join(project_dir, "*", pattern))
                    or glob.glob(os.path.join(project_dir, "src", "**", pattern), recursive=True)):
                needed.update(rule.get("plugins", []))
                break
    return needed


def activate(config_path, settings_path, project_dir, restore_file, state_dir):
    """Pause what the project does not need. Returns the summary line, or None if nothing was done."""
    config = read_json(config_path)
    needed = needed_plugins(config, project_dir)
    try:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        os.makedirs(os.path.dirname(restore_file) or ".", exist_ok=True)
    except OSError as exc:
        warn("cannot create the restore directory (%s): skills left as they are" % exc)
        return None

    with locked(state_dir):
        settings = read_json(settings_path)
        plugins = settings.get("enabledPlugins")
        if not isinstance(plugins, dict):
            return "OK|0|0||"

        # Recover launches that died first, so their pause is not mistaken for the original state.
        # Settings are written BEFORE the files are deleted: a crash in between must not lose the undo.
        stale = stale_restore_files(state_dir, restore_file)
        recovered = False
        for path in stale:
            parsed = load_restore_file(path)
            if parsed is not None:
                recovered = revert(plugins, parsed[1]) or recovered
        if recovered:
            write_settings(settings_path, settings)
        for path in stale:
            with contextlib.suppress(OSError):
                os.unlink(path)

        own = load_restore_file(restore_file)
        launches = other_launches(state_dir, restore_file) + ([own] if own else [])
        launches.sort(key=lambda entry: entry[0])
        changes = dict(own[1]) if own else {}
        stamp = own[0] if own else time.time()
        turned_on, turned_off = [], []
        for name in list(plugins):
            enabled = plugins[name]
            wanted = name in needed
            if not isinstance(enabled, bool) or enabled == wanted:
                continue
            changes[name] = {"from": original_value(name, launches, enabled), "to": wanted}
            plugins[name] = wanted
            (turned_on if wanted else turned_off).append(name)

        if turned_on or turned_off:
            # The undo is durable before the pause is applied; if it cannot be, nothing is paused.
            try:
                write_restore_file(restore_file, {"t": stamp, "changes": changes})
            except OSError as exc:
                warn("cannot write %s (%s): skills left as they are" % (restore_file, exc))
                return None
            write_settings(settings_path, settings)

    active = sum(1 for value in plugins.values() if value)
    paused = sum(1 for value in plugins.values() if not value)
    if turned_on or turned_off:
        return "CHANGED|%d|%d|%s|%s" % (active, paused, ",".join(turned_on), ",".join(turned_off))
    return "OK|%d|%d||" % (active, paused)


def restore(settings_path, restore_file, state_dir):
    """Undo one launch. Returns the process exit status."""
    with locked(state_dir):
        if not os.path.isfile(restore_file):
            return 0  # consumed meanwhile (a recovery sweep, or an earlier restore)
        parsed = load_restore_file(restore_file)
        if parsed is None:
            warn("%s is not a restore file; left in place" % restore_file)
            return 1
        settings = read_json(settings_path)
        plugins = settings.get("enabledPlugins")
        if isinstance(plugins, dict) and revert(plugins, parsed[1]):
            write_settings(settings_path, settings)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(restore_file)
    return 0


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "activate" and len(argv) == 7:
            summary = activate(*argv[2:])
            if summary:
                print(summary)
            return 0
        if mode == "restore" and len(argv) == 5:
            return restore(*argv[2:])
    except Exception as exc:  # reported with a non-zero status, never swallowed
        warn("%s failed: %s: %s" % (mode, type(exc).__name__, exc))
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
