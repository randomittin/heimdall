#!/usr/bin/env python3
"""hmd_relay_approval.py -- the relays this machine's operator approved to receive the laptop's `gh auth token` (stdlib only).

WHY. Pairing by code sends `gh auth token` to a relay (bin/heimdall-app), and it is on for every repo: a session start opens the repo's pair window and
registers its code with no `hmd app connect` first. Which relay used to be whatever HMD_RELAY_URL said -- and a cloned repository sets the environment of the
session it is opened in (`.claude/settings.json` "env", `.envrc`), so a hostile one could name a server of its own and have the token sent there at the next
session start, with nothing done by the operator. So the environment is not trusted with the token. A relay the environment names gets it only when it is

    * the default relay (the one baked into bin/heimdall-app, handed in as --default), or
    * one the operator approved: `hmd app connect --relay URL` (pairing by code, not --no-code) records the relay it was told to use, in HEIMDALL_HOME.

A relay typed after --relay on a command line is the operator's own choice and needs no approval to be used for that one command; the environment never is.

WHERE. $HEIMDALL_HOME/app/relay-approved/<sha256(origin)[:16]>.json (HEIMDALL_HOME, else ~/.heimdall -- an absolute path either way: a relative one means whatever directory the process runs in, the repository for a session
start, so it is no store): {"v":1,"relay":"<origin>","approved_at":N}, 0600 in a
0700 directory, written and read through bin/lib/hmd_private_state.py (no link followed; a file of this user's with no group or other permission bits, or it
is not believed). Never inside the repo: a repository controls everything under it, and could plant an approval there for its own server -- so a store that
is inside the repo it is asked about (a HEIMDALL_HOME the environment points into the checkout) is not read at all. "Inside" is a question about the directory,
not about how its path is spelled: it is answered by file identity (the repo's device and inode against those of each ancestor of the store), because a
case-insensitive volume -- macOS's APFS default -- reads /Users/RJ/x and /Users/rj/x as one place and a comparison of path strings reads them as two.
That also means a repo that contains the store -- a dotfiles repository at $HOME -- gets the default relay only.

MATCHING IS EXACT. A relay is compared as `scheme://host[:port]`, lower-cased, the scheme's own port left out, an IPv6 address compressed: https://x.example is
https://X.EXAMPLE:443/ and nothing else -- not http://x.example, not https://x.example:8443, not a name that merely starts or ends like it. Anything that is
not a plain http(s) origin (a path, a query, a fragment, credentials, a space, a control or non-ASCII character, an empty or hyphen-edged label, a trailing
dot, a port with a leading zero or above 65535) has no form, is never approved and never matches: a URL two parsers could read two ways is not guessed at.
Anything that cannot be read -- a record that is loose, not ours, malformed or about another relay, a machine with no place to keep it -- is "not approved":
no token goes out on a doubt.

CLI (exit 0 done / yes, 1 no or refused -- the reason on stderr for a refusal, 2 usage):
    python3 hmd_relay_approval.py trusted --relay=URL --default=URL [--repo=DIR]   # yes: URL is the default relay or approved (a store inside DIR is not read)
    python3 hmd_relay_approval.py approve --relay=URL                              # what `hmd app connect --relay URL` records
    python3 hmd_relay_approval.py forget  --relay=URL                              # take the approval back (exit 0 whether or not there was one)
    python3 hmd_relay_approval.py list                                             # one approved relay per line
"""
import argparse
import hashlib
import ipaddress
import json
import os
import re
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

REL = "app/relay-approved"
VERSION = 1
DEFAULT_PORTS = {"http": 80, "https": 443}

# Spelled out, not re.IGNORECASE: with it [a-z] also matches U+212A KELVIN SIGN, which str.lower() turns into a plain k, so a lookalike URL would
# normalise to an approved one. Every character here is ASCII.
ORIGIN = re.compile(r"(?P<scheme>[Hh][Tt][Tt][Pp][Ss]?)://"
                    r"(?P<host>\[[0-9A-Fa-f:.]{2,45}\]|[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)"
                    r"(?::(?P<port>[1-9][0-9]{0,4}))?/?", re.ASCII)


def _sibling(name):
    spec = spec_from_file_location(name, os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PRIVATE = _sibling("hmd_private_state")


def home():
    """$HEIMDALL_HOME, else ~/.heimdall; None with neither it nor HOME (there is no /tmp fallback), and None for one that is not an absolute path: a relative
    path means whatever directory the process runs in, which for a session start is the repository."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit if os.path.isabs(explicit) else None
    user_home = os.environ.get("HOME")
    return os.path.join(user_home, ".heimdall") if user_home and os.path.isabs(user_home) else None


def normalize(url):
    """`scheme://host[:port]` -- lower-cased, the scheme's own port left out, an IPv6 address compressed -- or None for anything that is not a plain http(s)
    origin (see the module docstring: nothing here is guessed at)."""
    if not isinstance(url, str):
        return None
    found = ORIGIN.fullmatch(url)
    if found is None:
        return None
    scheme, host, port = found.group("scheme").lower(), found.group("host").lower(), found.group("port")
    if host.startswith("["):
        try:
            host = "[%s]" % ipaddress.IPv6Address(host[1:-1]).compressed
        except ValueError:
            return None
    elif any(not label or len(label) > 63 or label[0] == "-" or label[-1] == "-" for label in host.split(".")):
        return None
    if port is not None:
        if int(port) > 65535:
            return None
        if int(port) == DEFAULT_PORTS[scheme]:
            port = None
    return "%s://%s%s" % (scheme, host, ":%s" % port if port else "")


def _name(origin):
    return "%s.json" % hashlib.sha256(origin.encode("utf-8")).hexdigest()[:16]


def _inside(path, repo):
    """True when `path` is `repo` or below it -- by file identity, never by the spelling of a path: the (device, inode) of `repo` is compared with those of `path`
    and of each of its ancestors, so another letter case (a case-insensitive volume such as APFS reads /Users/RJ/x and /Users/rj/x as one place), a link, a `..`
    or a bind mount does not get a store that is in the repo past. `path` need not exist yet: only the ancestors that do are looked at. A `repo` that cannot be
    examined answers True -- no store is read on a doubt."""
    try:
        root = os.stat(repo)
    except OSError:
        return True
    here = os.path.realpath(path)
    while True:
        try:
            seen = os.stat(here)
        except OSError:
            seen = None
        if seen is not None and (seen.st_dev, seen.st_ino) == (root.st_dev, root.st_ino):
            return True
        parent = os.path.dirname(here)
        if parent == here:
            return False
        here = parent


def approved(origin, repo=None):
    """True when the operator approved `origin` (already normalised). A store inside `repo` is not read: the repository could have written it."""
    base = home()
    if base is None or origin is None or (repo and _inside(base, repo)):
        return False
    rec = PRIVATE.read_json(base, REL, _name(origin), dir_forbidden=0o077)
    return rec is not None and rec.get("v") == VERSION and rec.get("relay") == origin


def trusted(url, default, repo=None):
    """True when the laptop's gh token may go to `url`: it is the default relay, or the operator approved it. `repo` is the repository the question is
    asked in (None: no repository to guard against)."""
    origin = normalize(url)
    return origin is not None and (origin == normalize(default) or approved(origin, repo))


def approve(url):
    """Record `url` as approved and return its normalised form. ValueError for a URL that has none, OSError when nothing can be written."""
    origin = normalize(url)
    if origin is None:
        raise ValueError("only a plain http(s) scheme://host[:port] can be approved (no path, query, credentials or unusual characters)")
    base = home()
    if base is None:
        raise OSError("no absolute HEIMDALL_HOME or HOME to keep the approval under")
    os.makedirs(base, mode=0o700, exist_ok=True)
    body = json.dumps({"v": VERSION, "relay": origin, "approved_at": int(time.time())}, sort_keys=True, separators=(",", ":"))
    PRIVATE.write(base, REL, _name(origin), body.encode("utf-8"))
    return origin


def forget(url):
    """Take the approval of `url` back. True when there was one."""
    origin, base = normalize(url), home()
    return origin is not None and base is not None and PRIVATE.remove(base, REL, _name(origin))


def approved_origins():
    """The relays approved, believed ones only, sorted."""
    base = home()
    found = []
    for name in PRIVATE.names(base, REL) if base is not None else []:
        rec = PRIVATE.read_json(base, REL, name, dir_forbidden=0o077)
        origin = rec.get("relay") if rec is not None and rec.get("v") == VERSION else None
        if isinstance(origin, str) and normalize(origin) == origin and _name(origin) == name:
            found.append(origin)
    return found


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_relay_approval.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("trusted", "approve", "forget", "list"))
    ap.add_argument("--relay")
    ap.add_argument("--default", default="")
    ap.add_argument("--repo")
    args = ap.parse_args(argv)
    if args.action == "list":
        for origin in approved_origins():
            print(origin)
        return 0
    if args.relay is None:
        ap.error("%s needs --relay=URL" % args.action)
    if args.action == "trusted":
        return 0 if trusted(args.relay, args.default, args.repo) else 1
    try:
        {"approve": approve, "forget": forget}[args.action](args.relay)
    except (OSError, ValueError) as exc:
        print("hmd_relay_approval: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
