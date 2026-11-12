#!/usr/bin/env python3
"""skills_config.py -- the per-operator skills settings in $HEIMDALL_HOME/skills-config.json.

    skills_config.py get KEY
    skills_config.py set KEY VALUE
    skills_config.py init --marker-present | --marker-absent

    KEY            VALUES                     DEFAULT  ENVIRONMENT
    registry       on | off                   off      HMD_SKILLS_REGISTRY
    consent        ask | allowlist | auto     ask      HMD_SKILLS_CONSENT
    allowlist      skill ids                  none     -
    grandfathered  true | false               false    -

`registry` is the flag the resolver call sites branch on; `consent`, `allowlist` and `grandfathered` are what the
install gate reads. `get` prints the value (an allowlist: one id per line). Precedence is the environment, then the
file, then the default; an empty variable is an unset one.

NEVER FATAL ON A READ. A value that is not allowed, at whichever tier wins, is reported on stderr and replaced by the
built-in default for that key. The defaults are the restrictive ones, so a typo can never move consent toward install.
A file that cannot be used (unreadable, not JSON, not an object, nested past the parser) is reported once and read as
empty. `get` exits 0 through all of it and writes nothing: it never creates $HEIMDALL_HOME, which a teardown must not
resurrect.

NEVER FROM A REPOSITORY. The one file is $HEIMDALL_HOME/skills-config.json (HEIMDALL_HOME, else ~/.heimdall: the
launcher's own rule). There is no path argument, no project dir and no lookup from the cwd, so a cloned repository
cannot choose its operator's consent mode (INV-S11). Run it as `python3 -I`: isolated mode also keeps a stdlib module
planted in the repository off the import path, and this file imports nothing else.

WRITES. `set` validates, merges into what the file holds (keys it does not know survive) and writes a temp file beside
it, mode 0600 and fsynced, then renames it over the target: a crash never leaves half a file and a failed write leaves
the old one. It will not overwrite a file it cannot parse (exit 1): that one is the operator's to fix. The file is
sparse -- it holds what an operator or `init` decided -- so a default that changes later (the registry's default-on
cycle) reaches everyone who never chose, instead of being frozen into every file.

GRANDFATHER. `init` is the first-run rule, run once by the launcher with what it saw at start: the setup marker present
-> {consent auto, grandfathered true} (today's behaviour: the same installs in the same order), absent -> {consent ask,
grandfathered false}. A file that already exists, valid or not, is never touched, so the decision is made once and a
marker that appears later, or a hand edit, does not re-open it. `get` and `init` are the only calls on the launch path;
`set` and `init` create $HEIMDALL_HOME when they must, so a teardown does not call them.

EXIT. 0 ok (every `get`); 1 a write failed, or the file cannot be merged into; 2 usage, or a `set` value that is not
allowed. stdlib only.
"""
import contextlib
import json
import os
import re
import sys
import tempfile

FILE_NAME = "skills-config.json"
CHOICES = {"registry": ("on", "off"), "consent": ("ask", "allowlist", "auto")}
DEFAULTS = {"registry": "off", "consent": "ask", "allowlist": [], "grandfathered": False}
ENV_VARS = {"registry": "HMD_SKILLS_REGISTRY", "consent": "HMD_SKILLS_CONSENT"}
SKILL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@-]{0,127}")  # matched whole (fullmatch): one printable token, never a newline
USAGE = (
    "usage:\n"
    "  skills_config.py get KEY\n"
    "  skills_config.py set KEY VALUE\n"
    "  skills_config.py init --marker-present | --marker-absent\n"
    "keys: registry (on|off), consent (ask|allowlist|auto), allowlist (skill ids), grandfathered (true|false)\n"
)


def warn(message):
    sys.stderr.write("skills-config: %s\n" % message)


def shown(value):
    """A value as one short line for a message: the file is untrusted text, the message is not."""
    text = repr(value)
    return text if len(text) <= 60 else text[:57] + "..."


def config_path():
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    return os.path.join(home, FILE_NAME)


def default(key):
    value = DEFAULTS[key]
    return list(value) if isinstance(value, list) else value


def expected(key):
    if key in CHOICES:
        return "|".join(CHOICES[key])
    return "true|false" if key == "grandfathered" else "skill ids of letters, digits and . _ @ -"


def from_text(key, text):
    """What a person typed (a command-line argument, an environment variable) as the typed value for KEY."""
    text = text.strip()
    if key == "allowlist":
        return text.replace(",", " ").split()
    if key == "grandfathered":
        return {"true": True, "false": False}.get(text.lower(), text)
    return text.lower()


def canonical(key, value):
    """VALUE as the file stores it for KEY, or ValueError when it is not an allowed value."""
    if key in CHOICES and value in CHOICES[key]:
        return value
    if key == "grandfathered" and isinstance(value, bool):
        return value
    if key == "allowlist" and isinstance(value, list) and all(isinstance(i, str) and SKILL_ID.fullmatch(i) for i in value):
        return list(dict.fromkeys(value))
    raise ValueError("%s %s is not allowed: expected %s" % (key, shown(value), expected(key)))


def load():
    """The file as a dict ({} when there is none), or ValueError when it exists and cannot be used."""
    path = config_path()
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


def resolve(key):
    """The value of KEY from the environment, else the file, else the default. Never raises."""
    name = ENV_VARS.get(key)
    if name and os.environ.get(name):
        source, raw = "$" + name, from_text(key, os.environ[name])
    else:
        try:
            data = load()
        except ValueError as exc:
            warn("%s; reading the defaults" % exc)
            return default(key)
        if key not in data:
            return default(key)
        source, raw = config_path(), data[key]
    try:
        return canonical(key, raw)
    except ValueError as exc:
        warn("%s, read from %s; using the default %s" % (exc, source, shown(DEFAULTS[key])))
        return default(key)


def write(data):
    """Atomically: a temp file (mode 0600, mkstemp's) in the same directory, then a rename over the target."""
    path = config_path()
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".skills-config-", suffix=".tmp")
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


def known(key):
    if key in DEFAULTS:
        return True
    warn("unknown key %s: expected %s" % (shown(key), "|".join(DEFAULTS)))
    return False


def cmd_get(key):
    if not known(key):
        return 2
    value = resolve(key)
    if key == "allowlist":
        if value:
            print("\n".join(value))
    elif key == "grandfathered":
        print("true" if value else "false")
    else:
        print(value)
    return 0


def cmd_set(key, text):
    if not known(key):
        return 2
    try:
        value = canonical(key, from_text(key, text))
    except ValueError as exc:
        warn(str(exc))
        return 2
    try:
        data = load()
    except ValueError as exc:
        warn("%s; fix or remove it, nothing was written" % exc)
        return 1
    data[key] = value
    write(data)
    return 0


def cmd_init(marker_present):
    if os.path.lexists(config_path()):
        return 0
    write({"consent": "auto", "grandfathered": True} if marker_present else {"consent": "ask", "grandfathered": False})
    return 0


def main(argv):
    args = argv[1:]
    try:
        if len(args) == 2 and args[0] == "get":
            return cmd_get(args[1])
        if len(args) == 3 and args[0] == "set":
            return cmd_set(args[1], args[2])
        if len(args) == 2 and args[0] == "init" and args[1] in ("--marker-present", "--marker-absent"):
            return cmd_init(args[1] == "--marker-present")
    except Exception as exc:  # reported with a non-zero status, never a traceback
        warn("%s failed: %s: %s" % (args[0], type(exc).__name__, exc))
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
