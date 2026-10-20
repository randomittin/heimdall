#!/usr/bin/env python3
"""hmd_pair_optin.py -- the per-repo record of the choice to pair by code here (stdlib only).

WHY. Pairing by code sends the laptop's `gh auth token` to the relay (one GET /user there). It is ON for every repo: a session start opens the
repo's pair window and registers its code with no `hmd app connect` first (bin/heimdall-app, _pw_start). This record is how one repo says no, and
how it says yes again: `hmd app disconnect` and `hmd app connect --no-code` write it as off, `hmd app connect` writes it as on, and a session's
start or end never writes it. No record is the default, which is on. (Until 2026-10-20 this was an opt-in: no record meant no window, and the file
is still called pair-optin.)

WHERE. $HEIMDALL_HOME/app/pair-optin/<sha256(realpath repo)[:16]>.json (HEIMDALL_HOME, else ~/.heimdall): {"v":1,"repo":"<realpath>",
"state":"on"|"off","connected_at":N | "off_at":N}, 0600, written and read through bin/lib/hmd_private_state.py (no link followed; a file of this
user's with no group or other permission bits, or it is not believed). A record from before "state" existed has none and means on. Never inside the
repo: a repository controls everything under it, and could plant a record there to switch its user's choice, which is exactly what this refuses.

A CHOICE THAT CANNOT BE READ IS NOT GUESSED AT. A record that is there but cannot be believed (loose permissions, not ours, malformed, naming another
path, a state nobody knows) is off, and so is a machine with no place to keep the choice (no HEIMDALL_HOME and no HOME): no token goes out against
a "no" that could not be read. Only a repo with no record at all gets the default.

CLI (exit 0 done / yes, 1 no or refused -- the reason on stderr for a refusal, 2 usage):
    python3 hmd_pair_optin.py set   --repo DIR   # on: what `hmd app connect` records
    python3 hmd_pair_optin.py off   --repo DIR   # off: what `hmd app disconnect` and `connect --no-code` record
    python3 hmd_pair_optin.py clear --repo DIR   # forget the choice: back to the default (on)
    python3 hmd_pair_optin.py state --repo DIR   # prints on, off or default (nothing recorded)
    python3 hmd_pair_optin.py check --repo DIR   # exit 0 unless the repo is off: the pair window may offer a code here
"""
import argparse
import hashlib
import json
import os
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

REL = "app/pair-optin"
VERSION = 1
ON, OFF, DEFAULT = "on", "off", "default"


def _sibling(name):
    spec = spec_from_file_location(name, os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PRIVATE = _sibling("hmd_private_state")


def home():
    """$HEIMDALL_HOME, else ~/.heimdall; None with neither it nor HOME (there is no /tmp fallback)."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    user_home = os.environ.get("HOME")
    return os.path.join(user_home, ".heimdall") if user_home else None


def _name(real):
    return "%s.json" % hashlib.sha256(real.encode("utf-8")).hexdigest()[:16]


def state(repo):
    """"on" when `hmd app connect` recorded this repo, "off" when it was switched off (`hmd app disconnect`, `hmd app connect --no-code`), "default"
    when nothing was ever recorded -- and the default is on. Anything that is there but cannot be believed, and a machine with nowhere to keep the
    choice, is "off" (see the module docstring)."""
    base = home()
    if base is None:
        return OFF
    real = os.path.realpath(repo)
    name = _name(real)
    rec = PRIVATE.read_json(base, REL, name)
    if rec is None:
        return OFF if name in PRIVATE.names(base, REL) else DEFAULT
    # a record from before "state" existed is the `hmd app connect` one: on
    chosen = rec.get("state", ON)
    return chosen if rec.get("v") == VERSION and rec.get("repo") == real and chosen in (ON, OFF) else OFF


def _write(repo, choice):
    base = home()
    if base is None:
        raise OSError("no HEIMDALL_HOME or HOME to keep the choice under")
    real = os.path.realpath(repo)
    os.makedirs(base, mode=0o700, exist_ok=True)
    when = {"connected_at": int(time.time())} if choice == ON else {"off_at": int(time.time())}
    body = json.dumps(dict(when, v=VERSION, repo=real, state=choice), sort_keys=True, separators=(",", ":"))
    PRIVATE.write(base, REL, _name(real), body.encode("utf-8"))


def set_(repo):
    _write(repo, ON)


def off(repo):
    _write(repo, OFF)


def clear(repo):
    base = home()
    if base is not None:
        PRIVATE.remove(base, REL, _name(os.path.realpath(repo)))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_pair_optin.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("set", "off", "clear", "state", "check"))
    ap.add_argument("--repo", required=True)
    args = ap.parse_args(argv)
    if args.action == "state":
        print(state(args.repo))
        return 0
    if args.action == "check":
        return 1 if state(args.repo) == OFF else 0
    try:
        {"set": set_, "off": off, "clear": clear}[args.action](args.repo)
    except OSError as exc:
        print("hmd_pair_optin: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
