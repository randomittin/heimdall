#!/usr/bin/env python3
"""hmd_pair_optin.py -- the per-repo record that pairing by code was asked for here (stdlib only).

WHY. Pairing by code sends the laptop's `gh auth token` to the relay (one GET /user there). The SessionStart pair window used to do that
for every attended session while gh was signed in, whether or not anyone had ever connected a phone to the repo. This record is the opt-in:
an explicit `hmd app connect` for the repo makes it, `hmd app disconnect` removes it -- never a session's start or end -- and the window
reads no token, asks gh nothing and calls no relay for a repo without it (bin/heimdall-app, _pw_start).

WHERE. $HEIMDALL_HOME/app/pair-optin/<sha256(realpath repo)[:16]>.json (HEIMDALL_HOME, else ~/.heimdall): {"v":1,"repo":"<realpath>",
"connected_at":N}, 0600, written and read through bin/lib/hmd_private_state.py (no link followed; a file of this user's with no group or
other permission bits, or it is no record at all). Never inside the repo: a repository controls everything under it and could plant a
record there to opt its user in, which is exactly what this exists to refuse.

CLI (exit 0 done / yes, 1 no or refused -- the reason on stderr for a refusal, 2 usage):
    python3 hmd_pair_optin.py set   --repo DIR
    python3 hmd_pair_optin.py clear --repo DIR
    python3 hmd_pair_optin.py check --repo DIR
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


def is_set(repo):
    """True when an explicit connect recorded this repo. Anything unreadable, foreign, loose or naming another path is no record."""
    base = home()
    if base is None:
        return False
    real = os.path.realpath(repo)
    try:
        rec = PRIVATE.read_json(base, REL, _name(real))
    except OSError:
        return False
    return isinstance(rec, dict) and rec.get("v") == VERSION and rec.get("repo") == real


def set_(repo):
    base = home()
    if base is None:
        raise OSError("no HEIMDALL_HOME or HOME to keep the opt-in under")
    real = os.path.realpath(repo)
    os.makedirs(base, mode=0o700, exist_ok=True)
    body = json.dumps({"v": VERSION, "repo": real, "connected_at": int(time.time())}, sort_keys=True, separators=(",", ":"))
    PRIVATE.write(base, REL, _name(real), body.encode("utf-8"))


def clear(repo):
    base = home()
    if base is not None:
        PRIVATE.remove(base, REL, _name(os.path.realpath(repo)))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_pair_optin.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("set", "clear", "check"))
    ap.add_argument("--repo", required=True)
    args = ap.parse_args(argv)
    if args.action == "check":
        return 0 if is_set(args.repo) else 1
    try:
        if args.action == "set":
            set_(args.repo)
        else:
            clear(args.repo)
    except OSError as exc:
        print("hmd_pair_optin: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
