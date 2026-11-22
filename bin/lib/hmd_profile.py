#!/usr/bin/env python3
"""hmd_profile.py -- which install profile this machine runs, `lean` or `full`, kept in $HEIMDALL_HOME/profile.json.

    hmd_profile.py get
    hmd_profile.py set lean|full
    hmd_profile.py init --marker-present | --marker-absent

`full` is today's install: the whole tree, every prompt and skill byte as it is. `lean` is the sparse install of
docs/superpowers/plans/2026-11-12-3x-lean-core.md. This file only RECORDS and REPORTS the choice: it moves no file, edits no
settings and reads nothing about how a session reaches the model. A lean install keeps the `claude` wrapper (the hmd
launcher) and is routed through no proxy (INV-L12); any such route is a separate opt-in that no profile turns on.

`get` prints the recorded profile. No file, or a file with no profile in it, prints `full`: the default is the one that
changes nothing, so an install that predates this file, and one that has not been through `init` yet, stay as they were.

NEVER FATAL ON A READ. A value that is not `lean` or `full`, or a file that cannot be used (unreadable, not JSON, not an
object, nested past the parser), is reported on stderr and read as the default `full`. `get` exits 0 through all of it and
writes nothing: it never creates $HEIMDALL_HOME, which a teardown must not resurrect.

NEVER FROM A REPOSITORY. The one file is $HEIMDALL_HOME/profile.json (HEIMDALL_HOME, else ~/.heimdall: the launcher's own
rule). There is no path argument, no project dir and no lookup from the cwd, so a cloned repository cannot choose its
operator's profile. Run it as `python3 -I`: isolated mode also keeps a stdlib module planted in the repository off the
import path, and this file imports nothing else.

INIT is the first-run rule, run once by the installer with what it saw (INV-L2). The setup marker (or an install dir that
was already there) seen -> `full`; absent -> `lean`, UNLESS $HEIMDALL_HOME/skills-config.json says `grandfathered: true`,
the record the consent model left when it first met an existing install, which survives a removed marker. Lean needs
positive evidence of a fresh install: anything that is not plainly "not grandfathered" (the key of another type, a file that
cannot be read or is not an object) records `full`. skills-config.json is only read here. A profile.json that already
exists, valid or not, a dangling link included, is never touched, so the decision is made once and a marker that appears or
goes later, or a hand edit, does not re-open it.

SET records `lean` or `full` and is the one way a recorded profile changes (`hmd lean on|off`, `install.sh --reset`). It
validates (case and surrounding space are folded), merges into what the file holds (keys it does not know survive) and
writes a temp file beside it, mode 0600 and fsynced, then renames it over the target: a crash never leaves half a file and
a failed write leaves the old one. It will not overwrite a file it cannot parse (exit 1): that one is the operator's to fix.

EXIT. 0 ok (every `get`; `init`, also when it leaves an existing file alone); 1 a write failed, or the file cannot be merged
into; 2 usage, or a `set` value that is not allowed. stdlib only.
"""
import contextlib
import json
import os
import sys
import tempfile

FILE_NAME = "profile.json"
SKILLS_CONFIG = "skills-config.json"
CHOICES = ("lean", "full")
DEFAULT = "full"
USAGE = (
    "usage:\n"
    "  hmd_profile.py get\n"
    "  hmd_profile.py set lean|full\n"
    "  hmd_profile.py init --marker-present | --marker-absent\n"
)


def warn(message):
    sys.stderr.write("hmd-profile: %s\n" % message)


def shown(value):
    """A value as one short line for a message: the file is untrusted text, the message is not."""
    text = repr(value)
    return text if len(text) <= 60 else text[:57] + "..."


def home():
    return os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")


def profile_path():
    return os.path.join(home(), FILE_NAME)


def load():
    """profile.json as a dict ({} when there is none), or ValueError when it exists and cannot be used."""
    path = profile_path()
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, RecursionError) as exc:
        raise ValueError("%s cannot be used: %s" % (path, exc)) from exc
    if not isinstance(data, dict):
        raise ValueError("%s cannot be used: it is not a JSON object" % path)
    return data


def resolve():
    """The recorded profile, else the default. Never raises."""
    try:
        data = load()
    except ValueError as exc:
        warn("%s; reading the default %s" % (exc, DEFAULT))
        return DEFAULT
    value = data.get("profile", DEFAULT)
    if value in CHOICES:
        return value
    warn("profile %s is not allowed: expected %s, read from %s; using the default %s"
         % (shown(value), "|".join(CHOICES), profile_path(), DEFAULT))
    return DEFAULT


def write(data):
    """Atomically: a temp file (mode 0600, mkstemp's) in the same directory, then a rename over the target."""
    path = profile_path()
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".profile-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def grandfathered():
    """False only when skills-config.json plainly says this install is new: no file, or no key (the default is false), or false.

    True, a value of another type, a file that is not an object and a file that cannot be read all answer True: none is
    proof of a fresh install, and the profile errs toward `full`.
    """
    try:
        with open(os.path.join(home(), SKILLS_CONFIG), encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return False
    except (OSError, ValueError, RecursionError):
        return True
    return not isinstance(data, dict) or data.get("grandfathered", False) is not False


def cmd_get():
    print(resolve())
    return 0


def cmd_set(text):
    value = text.strip().lower()
    if value not in CHOICES:
        warn("profile %s is not allowed: expected %s" % (shown(text), "|".join(CHOICES)))
        return 2
    try:
        data = load()
    except ValueError as exc:
        warn("%s; fix or remove it, nothing was written" % exc)
        return 1
    data["profile"] = value
    write(data)
    return 0


def cmd_init(marker_present):
    if os.path.lexists(profile_path()):
        return 0
    write({"profile": "full" if marker_present or grandfathered() else "lean"})
    return 0


def main(argv):
    args = argv[1:]
    try:
        if args == ["get"]:
            return cmd_get()
        if len(args) == 2 and args[0] == "set":
            return cmd_set(args[1])
        if len(args) == 2 and args[0] == "init" and args[1] in ("--marker-present", "--marker-absent"):
            return cmd_init(args[1] == "--marker-present")
    except Exception as exc:  # reported with a non-zero status, never a traceback
        warn("%s failed: %s: %s" % (args[0], type(exc).__name__, exc))
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
