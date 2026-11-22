#!/usr/bin/env python3
"""lean_backup.py -- the backup `install.sh --reset` takes first, and the restore that puts it back (lean-core plan T2.5).

    lean_backup.py backup          copies what a reset changes into $HEIMDALL_HOME/backups/<UTC-timestamp>/ and prints that dir
    lean_backup.py restore DIR     verifies every file of DIR against its sha256, then writes it all back

INV-L9: the backup dir is mode 0700 (its files 0600), `backup` is taken before the reset changes anything, and `restore DIR` returns
every backed-up file byte for byte. INV-L10: ledger, receipts, memory, team, pairing and data/ are never copied, restored or removed;
they are not in the catalog below and a path that resolves into them (a HMD_MODULES_STATE pointed at receipts/, say) is refused.

WHAT IS TRACKED, and nothing else. Each item is a plain file that is either present (copied, with its mode) or ABSENT (recorded as
absent, and removed again on restore if it has appeared since: that is how a reset's new opt-out record goes away):
  home/skills-config.json, home/profile.json                $HEIMDALL_HOME (else ~/.heimdall)
  modules/<name>/{receipt,wired,invariants}.json            the modules state: HMD_MODULES_STATE, else <this install>/.heimdall/modules
  modules/.modstate/<name>/{optout,failure,deferred}.json   <name> = every module the registry, the state dir or .modstate knows
  settings                                                  the hmd-managed SLICE of the user-level Claude settings.json
                                                            ($CLAUDE_CONFIG_DIR, else ~/.claude): the `agent` key (the lean main prompt is
                                                            selected there), the env keys hmd routes with (ANTHROPIC_BASE_URL, HEADROOM_*) and
                                                            the hook entries whose command runs hmd (it names heimdall or hmd)
Only that slice is copied: the rest of settings.json is another tool's and the person's (it can hold a token, and the backup must
not become a second place for it). Restore therefore merges the slice back and leaves every other key as it finds it; what the
slice does not name, added or changed since, survives. Keys keep their original positions and the file its current indent, so a
settings.json that only the managed part changed comes back byte for byte. A restore that finds the slice already in place writes nothing.

TRUST. The sources come from the environment and the home dirs, never from the cwd or a repository (run it as `python3 -I`). The
manifest is not trusted: an entry's id must be one of the catalog's names (restore recomputes the path itself, so a doctored manifest
cannot aim a write anywhere else), its file must be a regular file of the recorded size and sha256 (a link, a longer file, a changed
byte, a missing file all refuse). EVERYTHING is verified and planned before the first byte is written; the writes are staged as temp
files beside their targets and renamed in one pass, so a refusal changes nothing. A settings.json that cannot be parsed fails the
backup (a backup that skips what it promised is not one) and the restore (it will not overwrite what it cannot read).

ATOMIC. `backup` builds the dir as .partial-* inside backups/ and renames it into place when complete: a crash leaves no half
backup under a real name, and a failed run removes its partial dir. Two backups in the same second get -1, -2 suffixes.

HEADROOM. `install.sh --reset` switches Headroom off for the next session with the Headroom CLI's own `off --next-session --backup-dir <backup>/headroom`. What that
changes in files (the module's opt-out record, the proxy route in settings.json) is backed up above and comes back byte for byte; what it changes in launchd (the
supervisor job is DISABLED) is in no file of this backup, so a restore that only wrote the route back would hand the next login a route to a proxy that never starts.
When <backup>/headroom/CHANGES.txt exists (the CLI writes it only when it changed something) and the backup says the Headroom module is added, restore runs this
install's `bin/heimdall-headroom on` after everything is verified and planned and BEFORE the first write, and refuses, with nothing written, when that fails: the message
names `hmd headroom on`. `on` clears an opt-out and re-enables the job; it never starts or stops the proxy, and it adds the module only if it is not added.

EXIT. 0 ok; 1 a refusal or a failure (nothing was written by restore; backup leaves no dir); 2 usage. stdlib only.
"""
import contextlib
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

SCHEMA = 1
MAX_FILE = 8 * 1024 * 1024
SETTINGS_ID = "settings"
HOME_FILES = ("skills-config.json", "profile.json")
MODULE_FACTS = ("receipt.json", "wired.json", "invariants.json")
MODSTATE_FACTS = ("optout.json", "failure.json", "deferred.json")
USER_DATA = ("ledger", "receipts", "memory", "team", "team.json", "pairing", "pairing.json", "data", "pki")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
BLOB = re.compile(r"files/[0-9]{3,6}")
SHA256 = re.compile(r"[0-9a-f]{64}")
HMD_COMMAND = re.compile(r"heimdall|\bhmd\b", re.IGNORECASE)
HEADROOM_CLI = ("bin", "heimdall-headroom")
HEADROOM_RECORD = ("headroom", "CHANGES.txt")   # the CLI's own record, kept under <backup>/headroom by install.sh --reset and written only when it changed something
HEADROOM_RECEIPT = "modules/headroom/receipt.json"
HEADROOM_TIMEOUT_S = 120
USAGE = (
    "usage:\n"
    "  lean_backup.py backup\n"
    "  lean_backup.py restore DIR\n"
)


def warn(message):
    sys.stderr.write("lean-backup: %s\n" % message)


def home():
    return os.path.abspath(os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall"))


def plugin_dir():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))


def modules_state():
    return os.path.abspath(os.environ.get("HMD_MODULES_STATE") or os.path.join(plugin_dir(), ".heimdall", "modules"))


def settings_path():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(os.path.abspath(base), "settings.json")


def refuse_user_data(path):
    """INV-L10: ValueError for a path that resolves into the user's ledger, receipts, memory, team, pairing or data."""
    first = os.path.relpath(os.path.realpath(path), os.path.realpath(home())).split(os.sep)[0]
    if first in USER_DATA:
        raise ValueError("%s is user data (%s): this tool never backs it up, restores it or removes it" % (path, first))


# ── the catalog ────────────────────────────────────────────────────────────────────────────────────────────────────────

def module_names():
    registry = os.path.join(plugin_dir(), "modules")
    found = set()
    for base in (registry, modules_state(), os.path.join(modules_state(), ".modstate")):
        with contextlib.suppress(OSError):
            found.update(n for n in os.listdir(base) if NAME.fullmatch(n) and os.path.isdir(os.path.join(base, n)))
    return sorted(found)


def module_rel_ok(rel):
    parts = rel.split("/")
    if len(parts) == 2:
        return NAME.fullmatch(parts[0]) is not None and parts[1] in MODULE_FACTS
    return len(parts) == 3 and parts[0] == ".modstate" and NAME.fullmatch(parts[1]) is not None and parts[2] in MODSTATE_FACTS


def catalog():
    """(id, path) of every plain file the backup tracks, whether it exists or not."""
    items = [("home/" + name, os.path.join(home(), name)) for name in HOME_FILES]
    for name in module_names():
        rels = ["%s/%s" % (name, fact) for fact in MODULE_FACTS] + [".modstate/%s/%s" % (name, fact) for fact in MODSTATE_FACTS]
        items += [("modules/" + rel, os.path.join(modules_state(), *rel.split("/"))) for rel in rels]
    return items


def target_for(entry_id):
    """The path an entry id stands for, recomputed here and never read from the manifest; ValueError for any id outside the catalog."""
    kind, _, rel = entry_id.partition("/")
    if entry_id == SETTINGS_ID:
        return settings_path()
    if kind == "home" and rel in HOME_FILES:
        return os.path.join(home(), rel)
    if kind == "modules" and module_rel_ok(rel):
        return os.path.join(modules_state(), *rel.split("/"))
    raise ValueError("backup entry %r names a file this tool never backs up" % entry_id)


# ── the settings.json slice ────────────────────────────────────────────────────────────────────────────────────────────

def managed_env(name):
    return name == "ANTHROPIC_BASE_URL" or name.startswith("HEADROOM_")


def is_hmd_group(group):
    hooks = group.get("hooks") if isinstance(group, dict) else None
    return isinstance(hooks, list) and any(
        isinstance(hook, dict) and isinstance(hook.get("command"), str) and HMD_COMMAND.search(hook["command"]) for hook in hooks)


def load_settings():
    """(settings dict, its text or None when there is no file, the path to write). A link is followed: a dotfile-managed file stays a link."""
    path = os.path.realpath(settings_path())
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return {}, None, path
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        raise ValueError("%s cannot be parsed (%s): fix or remove it" % (settings_path(), exc)) from exc
    if not isinstance(data, dict):
        raise ValueError("%s is not a JSON object: fix or remove it" % settings_path())
    return data, raw, path


def take_slice(data):
    """The part of a settings dict hmd manages, with the positions that put it back where it was."""
    keys = list(data)
    out = {"top": {}, "env": {"container": None, "keys": {}}, "hooks": {"container": None, "groups": []}}
    if "agent" in data:
        out["top"]["agent"] = {"index": keys.index("agent"), "value": data["agent"]}
    if isinstance(data.get("env"), dict):
        out["env"]["container"] = keys.index("env")
        out["env"]["keys"] = {name: {"index": i, "value": value}
                              for i, (name, value) in enumerate(data["env"].items()) if managed_env(name)}
    if isinstance(data.get("hooks"), dict):
        out["hooks"]["container"] = keys.index("hooks")
        for event_index, (event, groups) in enumerate(data["hooks"].items()):
            if isinstance(groups, list):
                out["hooks"]["groups"] += [{"event": event, "event_index": event_index, "index": i, "group": group}
                                           for i, group in enumerate(groups) if is_hmd_group(group)]
    return out


def check_slice(want):
    """ValueError unless WANT has the shape take_slice makes: a slice read from a backup is checked before it is applied."""
    try:
        ok = (set(want["top"]) <= {"agent"} and all(isinstance(v["index"], int) for v in want["top"].values())
              and isinstance(want["env"]["keys"], dict)
              and all(managed_env(k) and isinstance(v["index"], int) for k, v in want["env"]["keys"].items())
              and isinstance(want["hooks"]["groups"], list)
              and all(isinstance(g["event"], str) and isinstance(g["event_index"], int) and isinstance(g["index"], int)
                      and is_hmd_group(g["group"]) for g in want["hooks"]["groups"])
              and all(c is None or isinstance(c, int) for c in (want["env"]["container"], want["hooks"]["container"])))
    except (KeyError, TypeError, AttributeError):
        ok = False
    if not ok:
        raise ValueError("the settings slice in this backup is malformed")


def with_key(mapping, key, value, index):
    """MAPPING with KEY set to VALUE at position INDEX among its keys (clamped): the order a file had is the order it gets back."""
    items = [(k, v) for k, v in mapping.items() if k != key]
    items.insert(min(max(index, 0), len(items)), (key, value))
    return dict(items)


def restore_env(env, want):
    """ENV with the managed keys replaced by the recorded ones; None when nothing is left of an env the backup did not have."""
    env = {k: v for k, v in env.items() if not managed_env(k)}
    for name, rec in sorted(want["keys"].items(), key=lambda item: item[1]["index"]):
        env = with_key(env, name, rec["value"], rec["index"])
    return env if env or want["container"] is not None else None


def restore_hooks(hooks, want):
    """HOOKS with every hmd entry replaced by the recorded ones, at their recorded places; None when nothing is left of a hooks the backup did not have."""
    out, touched = {}, set()
    for event, groups in hooks.items():
        if isinstance(groups, list):
            kept = [g for g in groups if not is_hmd_group(g)]
            if len(kept) != len(groups):
                touched.add(event)
            groups = kept
        out[event] = groups
    recorded = {}
    for rec in sorted(want["groups"], key=lambda r: r["index"]):
        recorded.setdefault(rec["event"], []).append(rec)
    for event, recs in recorded.items():
        groups = out.get(event, [])
        if not isinstance(groups, list):
            raise ValueError("settings.json: hooks.%s is not a list, so the recorded entries cannot be put back" % event)
        for rec in recs:
            groups.insert(min(rec["index"], len(groups)), rec["group"])
        if event in out:
            out[event] = groups
        else:
            out = with_key(out, event, groups, recs[0]["event_index"])
    for event in touched - set(recorded):
        if out.get(event) == []:
            del out[event]
    return out if out or want["container"] is not None else None


def apply_slice(data, want):
    """DATA with its managed part replaced by WANT: what was recorded comes back, what hmd added since goes, everything else stays."""
    data = dict(data)
    pending = []                                  # top-level keys to put back: (index, key, value)
    if "agent" in want["top"]:
        pending.append((want["top"]["agent"]["index"], "agent", want["top"]["agent"]["value"]))
    data.pop("agent", None)
    for name, restore, part, recorded in (("env", restore_env, want["env"], want["env"]["keys"]),
                                          ("hooks", restore_hooks, want["hooks"], want["hooks"]["groups"])):
        current = data.get(name)
        if current is not None and not isinstance(current, dict):
            if recorded:
                raise ValueError("settings.json: %s is not an object, so the recorded entries cannot be put back" % name)
            continue
        new = restore(current or {}, part)
        if new is None:
            data.pop(name, None)
        elif name in data:
            data[name] = new
        else:
            pending.append((part["container"] if isinstance(part["container"], int) else len(data), name, new))
    for index, key, value in sorted(pending, key=lambda item: item[0]):
        data = with_key(data, key, value, index)
    return data


def settings_bytes(data, raw):
    """DATA as the file's own style writes it: its indent (two spaces when it has none to copy) and its final newline."""
    indent = "  "
    for line in (raw or "").splitlines():
        if line[:1] in (" ", "\t"):
            indent = line[: len(line) - len(line.lstrip(" \t"))]
            break
    text = json.dumps(data, indent=indent, ensure_ascii=False)
    return (text + ("\n" if raw is None or raw.endswith("\n") else "")).encode("utf-8")


# ── backup ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

def read_source(path):
    """(bytes, mode) of the regular file at PATH, None when there is none; anything else is refused (a link is followed)."""
    try:
        info = os.stat(path)
    except (FileNotFoundError, NotADirectoryError):
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("%s is not a regular file" % path)
    with open(path, "rb") as handle:
        data = handle.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise ValueError("%s is larger than %d bytes: not a file this tool backs up" % (path, MAX_FILE))
    return data, stat.S_IMODE(info.st_mode)


def present(entry_id, data, index, mode=None):
    entry = {"id": entry_id, "state": "present", "blob": "files/%03d" % index,
             "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    if mode is not None:
        entry["mode"] = mode
    return entry


def collect():
    """(manifest entries, file contents) for everything tracked. A file that is not there is recorded absent, never skipped."""
    entries, blobs = [], []
    for entry_id, path in catalog():
        refuse_user_data(path)
        found = read_source(path)
        if found is None:
            entries.append({"id": entry_id, "state": "absent"})
        else:
            entries.append(present(entry_id, found[0], len(blobs), found[1]))
            blobs.append(found[0])
    refuse_user_data(settings_path())
    slice_text = (json.dumps(take_slice(load_settings()[0]), indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    entries.append(present(SETTINGS_ID, slice_text, len(blobs)))
    blobs.append(slice_text)
    return entries, blobs


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def cmd_backup():
    entries, blobs = collect()
    root = os.path.join(home(), "backups")
    os.makedirs(root, mode=0o700, exist_ok=True)
    partial = tempfile.mkdtemp(dir=root, prefix=".partial-")
    try:
        os.mkdir(os.path.join(partial, "files"), 0o700)
        for index, data in enumerate(blobs):
            write_private(os.path.join(partial, "files", "%03d" % index), data)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        manifest = {"schema": SCHEMA, "created": stamp, "entries": entries}
        write_private(os.path.join(partial, "manifest.json"), (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8"))
        for n in range(100):
            final = os.path.join(root, stamp if n == 0 else "%s-%d" % (stamp, n))
            if not os.path.lexists(final):
                os.rename(partial, final)
                break
        else:
            raise OSError("no free backup name under %s" % root)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    print(final)
    return 0


# ── restore ────────────────────────────────────────────────────────────────────────────────────────────────────────────

def check_entry(entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
        raise ValueError("the manifest has an entry without an id")
    target_for(entry["id"])
    if entry.get("state") == "absent" and entry["id"] != SETTINGS_ID:
        return
    size, mode = entry.get("size"), entry.get("mode")
    ok = (entry.get("state") == "present" and isinstance(entry.get("blob"), str) and BLOB.fullmatch(entry["blob"]) is not None
          and isinstance(entry.get("sha256"), str) and SHA256.fullmatch(entry["sha256"]) is not None
          and isinstance(size, int) and 0 <= size <= MAX_FILE
          and (entry["id"] == SETTINGS_ID or (isinstance(mode, int) and 0 <= mode <= 0o777)))
    if not ok:
        raise ValueError("the manifest entry for %s is malformed" % entry["id"])


def load_manifest(directory):
    if os.path.islink(directory) or not os.path.isdir(directory):
        raise ValueError("%s is not a backup directory" % directory)
    path = os.path.join(directory, "manifest.json")
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        raise ValueError("%s has no manifest.json: it is not a backup directory" % directory) from None
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
        raise ValueError("%s is not a manifest this tool wrote" % path)
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError, RecursionError) as exc:
        raise ValueError("%s cannot be read: %s" % (path, exc)) from exc
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA or not isinstance(manifest.get("entries"), list):
        raise ValueError("%s is not a schema %d manifest" % (path, SCHEMA))
    seen = set()
    for entry in manifest["entries"]:
        check_entry(entry)
        if entry["id"] in seen:
            raise ValueError("%s lists %s twice" % (path, entry["id"]))
        seen.add(entry["id"])
    return manifest["entries"]


def read_blob(directory, entry):
    """The bytes of an entry's backup file, after the file is shown to be what was recorded: ValueError otherwise."""
    path = os.path.join(directory, entry["blob"])
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        raise ValueError("backup file %s is missing: tampered or damaged, nothing was restored" % entry["blob"]) from None
    if not stat.S_ISREG(info.st_mode) or info.st_size != entry["size"]:
        raise ValueError("backup file %s is not the file that was backed up (a link, or another size): tampered or damaged, nothing was restored"
                         % entry["blob"])
    with open(path, "rb") as handle:
        data = handle.read(MAX_FILE + 1)
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError("backup file %s does not match its recorded sha256: tampered or damaged, nothing was restored" % entry["blob"])
    return data


def stage(path, data, mode):
    """A temp file beside PATH holding DATA at MODE, fsynced; renamed over PATH later, in one pass with the others."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".lean-restore-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return tmp


def plan_restore(directory, entries):
    """(writes, removals, lines, unchanged): everything restore would do, decided with nothing written."""
    verified = {e["id"]: read_blob(directory, e) for e in entries if e["state"] == "present"}
    writes, removals, lines, unchanged = [], [], [], 0
    for entry in entries:
        entry_id, target = entry["id"], target_for(entry["id"])
        refuse_user_data(target)
        if entry_id == SETTINGS_ID:
            want = json.loads(verified[entry_id])
            check_slice(want)
            live, raw, path = load_settings()
            if take_slice(live) == want:
                unchanged += 1
            else:
                mode = stat.S_IMODE(os.stat(path).st_mode) if raw is not None else 0o600
                writes.append((path, settings_bytes(apply_slice(live, want), raw), mode))
                lines.append("restored settings.json (the managed keys)")
        elif entry["state"] == "absent":
            if os.path.isdir(target) and not os.path.islink(target):
                raise ValueError("%s is a directory: it was backed up as a missing file" % target)
            if os.path.lexists(target):
                removals.append(target)
                lines.append("removed %s" % entry_id)
        elif read_source(target) == (verified[entry_id], entry["mode"]):
            unchanged += 1
        else:
            writes.append((target, verified[entry_id], entry["mode"]))
            lines.append("restored %s" % entry_id)
    return writes, removals, lines, unchanged


def headroom_switched_off(directory, entries):
    """True when the reset's `heimdall-headroom off --next-session` changed something (its record sits in DIR/headroom and is written only then) and the backup
    restores the Headroom module as added: the one case in which a restored route needs a switch that no file of the backup holds, the launchd job."""
    folder = os.path.join(directory, HEADROOM_RECORD[0])
    record = os.path.join(directory, *HEADROOM_RECORD)
    kept = os.path.isdir(folder) and not os.path.islink(folder) and os.path.isfile(record) and not os.path.islink(record)
    return kept and any(e["id"] == HEADROOM_RECEIPT and e["state"] == "present" for e in entries)


def reenable_headroom():
    """Switch Headroom back on with this install's own CLI (`hmd headroom on`) and return the line to report. ValueError, naming `hmd headroom on`, when it cannot
    be done: restore calls this before it writes anything, so a refusal leaves every file as it was."""
    cli = os.path.join(plugin_dir(), *HEADROOM_CLI)
    why = "the route this restore puts back would point at a proxy that cannot start; nothing of this backup was written: fix the cause, run `hmd headroom on`, then restore again"
    if not os.access(cli, os.X_OK):
        raise ValueError("the reset switched Headroom off, but %s is not in this install to switch it back on, and %s" % (cli, why))
    try:
        done = subprocess.run([cli, "on"], stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=HEADROOM_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError("`hmd headroom on` did not run to the end (%s), and %s" % (exc, why)) from exc
    if done.returncode != 0:
        said = " ".join((done.stderr or done.stdout).split())[-300:]
        raise ValueError("`hmd headroom on` exited %d (%s), and %s" % (done.returncode, said, why))
    return "switched Headroom back on (hmd headroom on)"


def cmd_restore(directory):
    entries = load_manifest(directory)
    writes, removals, lines, unchanged = plan_restore(directory, entries)   # the verification: a damaged backup is refused before Headroom is touched
    if headroom_switched_off(directory, entries):
        report = reenable_headroom()
        writes, removals, lines, unchanged = plan_restore(directory, entries)   # again: `hmd headroom on` clears the opt-out record, which the backup also tracks
        lines.insert(0, report)
    staged = []
    try:
        for target, data, mode in writes:
            staged.append((stage(target, data, mode), target))
    except BaseException:
        for tmp, _ in staged:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
        raise
    done = 0
    try:
        for tmp, target in staged:
            os.replace(tmp, target)
            done += 1
    except BaseException:
        for tmp, _ in staged[done:]:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
        raise
    for target in removals:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(target)
    for line in lines:
        print(line)
    print("lean-backup: restored %d, removed %d, unchanged %d from %s" % (len(writes), len(removals), unchanged, directory))
    return 0


def main(argv):
    args = argv[1:]
    try:
        if args == ["backup"]:
            return cmd_backup()
        if len(args) == 2 and args[0] == "restore":
            return cmd_restore(args[1])
    except ValueError as exc:  # a refusal: what is wrong with the input, never a traceback
        warn(str(exc))
        return 1
    except Exception as exc:  # reported with a non-zero status, never a traceback
        warn("%s failed: %s: %s" % (args[0], type(exc).__name__, exc))
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
