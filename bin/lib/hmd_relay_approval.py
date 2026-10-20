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
is not believed). Never inside a repo: a repository controls everything under it, and could plant an approval there for its own server -- so a store that
is inside the repo it is asked about (a HEIMDALL_HOME the environment points into the checkout), or inside ANY git work tree (a `.git` entry on the way up), is not read
at all, and none is made there. Any work tree, not only the repo the question names, because the repo a caller names is not always the one the store is in: a command
run from a subdirectory, a CLAUDE_PROJECT_DIR that is one. The question is asked of the directory that is actually read -- <HEIMDALL_HOME>/app/relay-approved, opened
without following a link -- not of HEIMDALL_HOME, and on the descriptor that was opened (in_a_repo), which the record is then read through: the check and the read cannot
disagree. "Inside" is a question about the directory, not about how its path is spelled: it is answered by file identity (the ancestors of the open directory are reached
through `..` from it and identified by device and inode; the repo's identity is compared with each, and each is asked for a `.git` entry -- a directory, the file a linked
work tree or a submodule has, a link, a dangling one too -- without following a link), because a case-insensitive volume -- macOS's APFS default -- reads /Users/RJ/x and
/Users/rj/x as one place and a comparison of path strings reads them as two. That also means a repo that contains the store -- a dotfiles repository at $HOME -- gets the
default relay only, and so does every repo on a machine whose HEIMDALL_HOME is inside a work tree (set HEIMDALL_HOME outside it).

MATCHING IS EXACT. A relay is compared as `scheme://host[:port]`, lower-cased, the scheme's own port left out, an IPv6 address compressed: https://x.example is
https://X.EXAMPLE:443/ and nothing else -- not http://x.example, not https://x.example:8443, not a name that merely starts or ends like it. Anything that is
not a plain http(s) origin (a path, a query, a fragment, credentials, a space, a control or non-ASCII character, an empty or hyphen-edged label, a trailing
dot, a port with a leading zero or above 65535) has no form, is never approved and never matches: a URL two parsers could read two ways is not guessed at.
Anything that cannot be read -- a record that is loose, not ours, malformed or about another relay, a machine with no place to keep it -- is "not approved":
no token goes out on a doubt.

CLI (exit 0 done / yes, 1 no or refused -- the reason on stderr for a refusal, 2 usage):
    python3 hmd_relay_approval.py trusted --relay=URL --default=URL [--repo=DIR]   # yes: URL is the default relay or approved (a store inside DIR or any git work tree is not read)
    python3 hmd_relay_approval.py approve --relay=URL [--repo=DIR]                 # what `hmd app connect --relay URL` records (no store is made inside DIR or a git work tree)
    python3 hmd_relay_approval.py forget  --relay=URL                              # take the approval back (exit 0 whether or not there was one)
    python3 hmd_relay_approval.py list                                             # one approved relay per line
"""
import argparse
import hashlib
import ipaddress
import json
import os
import re
import stat
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


def _has_dot_git(dirfd):
    """True when the open directory has a `.git` entry of any kind -- a directory, the file a linked work tree or a submodule has, a link (not followed: a dangling one
    counts too) -- and on any doubt. False only when the directory answers that there is none."""
    try:
        os.stat(".git", dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def in_a_repo(dirfd, repo=None):
    """True when the open directory `dirfd` is `repo` or below it, or is a git work tree or below one -- ANY git work tree, whichever repo the question names. It is
    judged on the directory that was opened, by file identity, never by the spelling of a path: each ancestor is reached through `..` from the descriptor and
    identified by its (device, inode), the repo's compared with each, and each is asked for a `.git` entry (_has_dot_git). So another letter case (a case-insensitive
    volume such as APFS reads /Users/RJ/x and /Users/rj/x as one place), a link on the way to the directory or a `..` does not get a store that is in a repo past it:
    the answer is about the directory the caller then reads, not about a path it is spelled by. Anything that cannot be examined -- a `repo` that cannot be stat'ed, a
    directory that cannot be searched -- answers True: no store is read on a doubt."""
    try:
        root = os.stat(repo) if repo else None
        here = os.dup(dirfd)
    except OSError:
        return True
    try:
        while True:
            seen = os.fstat(here)
            if (root is not None and (seen.st_dev, seen.st_ino) == (root.st_dev, root.st_ino)) or _has_dot_git(here):
                return True
            above = os.open("..", os.O_RDONLY | os.O_DIRECTORY, dir_fd=here)
            os.close(here)
            here = above
            parent = os.fstat(here)
            if (parent.st_dev, parent.st_ino) == (seen.st_dev, seen.st_ino):  # the root is its own parent: every ancestor has been looked at
                return False
    except OSError:
        return True
    finally:
        os.close(here)


def _deepest_dir(path):
    """A descriptor of `path`, or of the nearest of its ancestors that exists, every link on the way resolved: the directory a store that is not made yet will be made in."""
    here = os.path.realpath(path)
    while True:
        try:
            return os.open(here, os.O_RDONLY | os.O_DIRECTORY)
        except (FileNotFoundError, NotADirectoryError):
            above = os.path.dirname(here)
            if above == here:
                raise
            here = above


def _open_store(repo=None):
    """The descriptor of the store directory, <HEIMDALL_HOME>/app/relay-approved, which the caller closes -- or None: there is no store, the way to it is not plain
    directories of this user's (hmd_private_state.open_dir follows no link), or the directory that was OPENED is inside `repo` or inside any git work tree
    (in_a_repo). Nothing is read from a place a repository could have written, and the caller reads through the very descriptor that was judged."""
    base = home()
    if base is None:
        return None
    try:
        store = PRIVATE.open_dir(base, REL, False)
    except OSError:
        return None
    if in_a_repo(store, repo):
        os.close(store)
        return None
    return store


def _record(store, name):
    """The record `name` in the open store directory as a dict, or None for anything that is not to be believed. The refusals are those of hmd_private_state.read_json
    with dir_forbidden=0o077, made on the descriptor that in_a_repo judged: a directory with a group or other permission bit; a file that is a link (never followed),
    not a regular file (a FIFO does not block the open), not this user's, with a group or other permission bit or over READ_LIMIT bytes; anything that is not a JSON object."""
    try:
        if os.fstat(store).st_mode & 0o077:
            return None
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=store)
    except OSError:
        return None
    try:
        seen = os.fstat(fd)
        if not stat.S_ISREG(seen.st_mode) or seen.st_uid != os.geteuid() or seen.st_mode & 0o077 or seen.st_size > PRIVATE.READ_LIMIT:
            return None
        raw = os.read(fd, seen.st_size)
    except OSError:
        return None
    finally:
        os.close(fd)
    try:
        rec = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return rec if isinstance(rec, dict) else None


def approved(origin, repo=None):
    """True when the operator approved `origin` (already normalised): its record is in the store directory, and that directory is neither inside `repo` nor inside any git
    work tree -- the repository could have written a record there."""
    store = _open_store(repo) if origin is not None else None
    if store is None:
        return False
    try:
        rec = _record(store, _name(origin))
    finally:
        os.close(store)
    return rec is not None and rec.get("v") == VERSION and rec.get("relay") == origin


def trusted(url, default, repo=None):
    """True when the laptop's gh token may go to `url`: it is the default relay, or the operator approved it. `repo` is the repository the question is
    asked in (None: no repository to guard against)."""
    origin = normalize(url)
    return origin is not None and (origin == normalize(default) or approved(origin, repo))


def approve(url, repo=None):
    """Record `url` as approved and return its normalised form. ValueError for a URL that has none, OSError when nothing can be written -- or when the store would be
    where it is not read, inside `repo` or inside any git work tree: nothing is created there."""
    origin = normalize(url)
    if origin is None:
        raise ValueError("only a plain http(s) scheme://host[:port] can be approved (no path, query, credentials or unusual characters)")
    base = home()
    if base is None:
        raise OSError("no absolute HEIMDALL_HOME or HOME to keep the approval under")
    probe = _deepest_dir(os.path.join(base, REL))  # the directory the store is in, or will be made in, judged before anything is created
    try:
        refused = in_a_repo(probe, repo)
    finally:
        os.close(probe)
    if refused:
        raise OSError("%r is inside a git work tree or the repository it was asked for -- a repository could plant what is read there, so no approval is kept in it" % base)
    os.makedirs(base, mode=0o700, exist_ok=True)
    body = json.dumps({"v": VERSION, "relay": origin, "approved_at": int(time.time())}, sort_keys=True, separators=(",", ":"))
    PRIVATE.write(base, REL, _name(origin), body.encode("utf-8"))
    return origin


def forget(url):
    """Take the approval of `url` back. True when there was one. A store inside a git work tree is left as it is (_open_store)."""
    origin = normalize(url)
    store = _open_store() if origin is not None else None
    if store is None:
        return False
    try:
        os.unlink(_name(origin), dir_fd=store)  # a link goes as a link, never followed
    except OSError:
        return False
    finally:
        os.close(store)
    return True


def approved_origins():
    """The relays approved, believed ones only, sorted -- none from a store inside a git work tree (_open_store)."""
    store = _open_store()
    if store is None:
        return []
    found = []
    try:
        for name in sorted(os.listdir(store)):
            rec = _record(store, name)
            origin = rec.get("relay") if rec is not None and rec.get("v") == VERSION else None
            if isinstance(origin, str) and normalize(origin) == origin and _name(origin) == name:
                found.append(origin)
    except OSError:
        return []
    finally:
        os.close(store)
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
        if args.action == "approve":
            approve(args.relay, args.repo)
        else:
            forget(args.relay)
    except (OSError, ValueError) as exc:
        print("hmd_relay_approval: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
