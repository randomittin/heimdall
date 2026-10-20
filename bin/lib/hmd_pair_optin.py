#!/usr/bin/env python3
"""hmd_pair_optin.py -- the per-repo record of the choice to pair by code here (stdlib only).

WHY. Pairing by code sends the laptop's `gh auth token` to the relay (one GET /user there). It is ON for every repo: a session start opens the
repo's pair window and registers its code with no `hmd app connect` first (bin/heimdall-app, _pw_start). This record is how one repo says no, and
how it says yes again: `hmd app disconnect` and `hmd app connect --no-code` write it as off, `hmd app connect` writes it as on, and a session's
start or end never writes it. No record is the default, which is on -- in the operator's own home (below). (Until 2026-10-20 this was an opt-in:
no record meant no window, and the file is still called pair-optin.)

WHERE. $HEIMDALL_HOME/app/pair-optin/<sha256(realpath repo)[:16]>.json (HEIMDALL_HOME, else ~/.heimdall -- hmd_relay_approval.home(), the one
definition the relay-approval store uses too: an absolute path either way, since a relative one means whatever directory the process runs in, which for
a session start is the repository): {"v":1,"repo":"<realpath>","state":"on"|"off","connected_at":N | "off_at":N}, 0600, written and read through
bin/lib/hmd_private_state.py (no link followed; a file of this user's with no group or other permission bits, or it is not believed). A record from
before "state" existed has none and means on. Never inside the repo: a repository controls everything under it, and could plant a record there to
switch its user's choice, which is exactly what this refuses.

WHICH HOME IS BELIEVED. A no is only as good as the place it is read from, and a repository names that place: it sets the environment of the session it
is opened in (`.claude/settings.json` "env", `.envrc`), HEIMDALL_HOME and HOME included, and hmd's own interpreter cache (bin/lib/hmd-python.sh) makes an
empty directory of any path it can. A repo that named a directory with no record in it would find no record, no record is the default, and the default is
on -- the operator's `hmd app disconnect` forgotten, the token sent, nothing said. So:
  * the operator's OWN home is <pw_dir>/.heimdall, with pw_dir from the account database (pwd.getpwuid(os.getuid())) and never from $HOME. It is ALWAYS
    read, whatever HEIMDALL_HOME says, and an `off` in either store wins. SEAM (below) adds a store to read; it never replaces this one.
  * the default, on, belongs to the own home alone: HEIMDALL_HOME unset or naming that directory, judged by device and inode (not by how a path is
    spelled). Any other home holds a choice only if it holds a record: with none, the repo is OFF, never the default. So a repository can point
    HEIMDALL_HOME (or HOME) away to switch pairing off for its own sessions, never to switch it on and never to lose the operator's off. An operator who
    keeps HEIMDALL_HOME elsewhere on purpose is on for a repo once `hmd app connect` recorded it there.
  * a home is read at all only if it can be believed: an absolute path to a directory that exists and can be searched, reached through no link and no
    directory of another account's, that is not inside the repo asked about and not inside ANY git work tree (hmd_relay_approval.in_a_repo, the judge of
    the relay-approval store: by file identity, on the directory that was opened, never by how a path is spelled). Anything else is OFF. The store itself
    (app/pair-optin) may be missing -- nothing was ever recorded -- and the home that would hold it is judged all the same.
  * `set` and `off` record in HEIMDALL_HOME AND in the own home: an off that only reached a home an environment named is lost the day that environment
    changes, and an on has to replace the off the own home keeps or `hmd app connect` could never turn pairing back on. Each write is judged as above (a home
    that cannot be believed is refused and nothing is created in it). A write that fails makes the command exit 1 with one line on stderr naming the place;
    for an off the other write is still tried, for an on it is not (an on is not mirrored where the one it mirrors was refused).
  * a test must not read or write the real home, so SEAM (HMD_TEST_CANONICAL_HOME) names a directory that is read in addition to it, and that `set` and `off`
    write instead of it: honoured only for a directory that carries SEAM_MARKER -- a regular file of this user's with no group or other permission bits,
    which a repository cannot make outside its own tree -- and that is in no git work tree. An environment can name any directory, but not one that has such
    a file in it, and an off in the real home wins even then.

A CHOICE THAT CANNOT BE READ IS NOT GUESSED AT. A record that is there but cannot be believed (loose permissions, not ours, malformed, naming another
path, a state nobody knows) is off, and so is a machine with no place to keep the choice (no HEIMDALL_HOME and no HOME, or a relative one): no token goes
out against a "no" that could not be read. Only a repo with no record at all, in the operator's own home, gets the default.

CLI (exit 0 done / yes, 1 no or refused -- the reason on stderr for a refusal, 2 usage):
    python3 hmd_pair_optin.py set   --repo DIR   # on: what `hmd app connect` records
    python3 hmd_pair_optin.py off   --repo DIR   # off: what `hmd app disconnect` and `connect --no-code` record
    python3 hmd_pair_optin.py clear --repo DIR   # forget the choice: back to the default (on, in the operator's own home)
    python3 hmd_pair_optin.py state --repo DIR   # prints on, off or default (nothing recorded, in the operator's own home)
    python3 hmd_pair_optin.py check --repo DIR   # exit 0 unless the repo is off: the pair window may offer a code here
"""
import argparse
import hashlib
import json
import os
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

try:
    import pwd
except ImportError:  # no account database here: no directory can be told to be the operator's own home
    pwd = None

REL = "app/pair-optin"
VERSION = 1
ON, OFF, DEFAULT = "on", "off", "default"
NOTHING, UNBELIEVED = "nothing", "unbelieved"  # what ONE store says besides on and off: a home that can be believed holds no record for the repo / it cannot be believed
SEAM = "HMD_TEST_CANONICAL_HOME"
SEAM_MARKER = ".hmd-test-canonical-home"


def _sibling(name):
    spec = spec_from_file_location(name, os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Where HEIMDALL_HOME is, and whether a store is inside a repo or a git work tree, are questions of the relay-approval store too: asked of the same code, so the
# two cannot drift apart.
APPROVAL = _sibling("hmd_relay_approval")
PRIVATE = APPROVAL.PRIVATE
home = APPROVAL.home
in_a_repo = APPROVAL.in_a_repo


def _name(real):
    return "%s.json" % hashlib.sha256(real.encode("utf-8")).hexdigest()[:16]


def _seam_believed(path):
    """True when `path` may stand in for the account's own home in a test: an absolute path to a directory that carries SEAM_MARKER (a file of this user's, 0600) and is in no
    git work tree."""
    if not os.path.isabs(path):
        return False
    try:
        dirfd = PRIVATE.open_dir(path, "", False)
    except OSError:
        return False
    try:
        return PRIVATE.read(path, "", SEAM_MARKER) is not None and not in_a_repo(dirfd)
    finally:
        os.close(dirfd)


def real_home():
    """The operator's own heimdall home: <pw_dir>/.heimdall, with pw_dir from the account database (pwd.getpwuid(os.getuid())) and never from $HOME, which a session's
    environment sets as it sets HEIMDALL_HOME. None when the database has no entry, or none that is an absolute path."""
    try:
        pw_dir = pwd.getpwuid(os.getuid()).pw_dir
    except (AttributeError, KeyError, OSError):
        return None
    return os.path.join(pw_dir, ".heimdall") if os.path.isabs(pw_dir) else None


def _seam():
    """The directory SEAM names when it may stand in for the account's own home in a test (_seam_believed), else None."""
    path = os.environ.get(SEAM)
    return path if path and _seam_believed(path) else None


def canonical_homes():
    """The stores an off is looked for in besides HEIMDALL_HOME's, and the only homes the default belongs to: the real home, always, and the directory SEAM names when it is
    believed. The seam ADDS a store; it never replaces the real one, so an environment that names one cannot hide an off recorded in the real home."""
    return [place for place in (real_home(), _seam()) if place is not None]


def _same_place(a, b):
    """True when `a` and `b` are one directory, by device and inode -- never by how either path is spelled (APFS reads two letter cases as one place)."""
    try:
        x, y = os.stat(a), os.stat(b)
    except OSError:
        return False
    return (x.st_dev, x.st_ino) == (y.st_dev, y.st_ino)


def _deepest(base):
    """(descriptor, whole) of <base>/app/pair-optin when it exists, else of the deepest directory of the way to it that does -- `whole` says which. Every step is opened
    without following a link and must be a directory of ours. FileNotFoundError when `base` itself is missing, any other OSError for a link, a file, another account's
    directory or one that cannot be searched on the way. The caller closes the descriptor."""
    rel = REL
    while True:
        try:
            return PRIVATE.open_dir(base, rel, False), rel == REL
        except FileNotFoundError:
            if not rel:
                raise
            rel = rel.rpartition("/")[0]


def _look(base, repo):
    """What the store under the home `base` says about `repo`: ON or OFF for a record that says so (OFF too for one that cannot be believed), NOTHING when the home can be believed
    and holds no record for it, UNBELIEVED when the home cannot be (see the module docstring). Creates nothing."""
    try:
        found, whole = _deepest(base)
    except OSError:
        return UNBELIEVED
    if in_a_repo(found, repo):
        os.close(found)
        return UNBELIEVED
    if not whole:
        os.close(found)
        return NOTHING
    real = os.path.realpath(repo)
    name = _name(real)
    try:
        rec = APPROVAL._record(found, name)  # read through the descriptor that in_a_repo judged: the check and the read cannot disagree
        if rec is None:
            return OFF if name in os.listdir(found) else NOTHING
    except OSError:
        return OFF
    finally:
        os.close(found)
    # a record from before "state" existed is the `hmd app connect` one: on
    chosen = rec.get("state", ON)
    return chosen if rec.get("v") == VERSION and rec.get("repo") == real and chosen in (ON, OFF) else OFF


def state(repo):
    """"on" when `hmd app connect` recorded this repo, "off" when it was switched off (`hmd app disconnect`, `hmd app connect --no-code`), "default" when nothing was ever recorded
    and the home read is the operator's own -- and the default is on. Everything else that cannot be read, and any other home with no record, is "off" (see the module docstring)."""
    base = home()
    if base is None:
        return OFF
    mine = _look(base, repo)
    anchors = canonical_homes()
    if any(_look(anchor, repo) == OFF for anchor in anchors):
        return OFF  # an off in the operator's own home wins, whatever HEIMDALL_HOME names
    if any(_same_place(base, anchor) for anchor in anchors):
        return OFF if mine == UNBELIEVED else DEFAULT if mine == NOTHING else mine
    return mine if mine in (ON, OFF) else OFF  # not the operator's own home: a home with no record is no place to take the default from


def _write(repo, choice, base):
    if base is None:
        raise OSError("no absolute HEIMDALL_HOME or HOME to keep the choice under")
    probe = APPROVAL._deepest_dir(os.path.join(base, REL))  # the directory the store is in, or will be made in, judged before anything is created
    try:
        refused = in_a_repo(probe, repo)
    finally:
        os.close(probe)
    if refused:
        raise OSError("%r is inside a git work tree or the repository it was asked for -- a repository could plant what is read there, so no choice is kept in it" % base)
    real = os.path.realpath(repo)
    os.makedirs(base, mode=0o700, exist_ok=True)
    when = {"connected_at": int(time.time())} if choice == ON else {"off_at": int(time.time())}
    body = json.dumps(dict(when, v=VERSION, repo=real, state=choice), sort_keys=True, separators=(",", ":"))
    PRIVATE.write(base, REL, _name(real), body.encode("utf-8"))


def _own_home():
    """The home `set`, `off` and `clear` also reach: the directory SEAM names in a test (which must not write the real one), else the real home. None when there is none."""
    return _seam() or real_home()


def _record(repo, choice):
    """Record `choice` for `repo` in HEIMDALL_HOME and in the operator's own home (see the module docstring for why both). Every write is judged as _write judges it. OSError, one
    line, naming each place that refused or failed; an off is tried in both whatever the first said, an on is not mirrored where the HEIMDALL_HOME write it mirrors was refused."""
    base, own = home(), _own_home()
    places = [("HEIMDALL_HOME", base)]
    if own is not None and (base is None or not _same_place(base, own)):
        places.append(("the account's own home", own))
    failed = []
    for what, where in places:
        try:
            _write(repo, choice, where)
        except OSError as exc:
            failed.append("%s (%s)" % (what, exc))
            if choice == ON:
                break
    if failed:
        raise OSError("the %s could not be recorded in %s" % (choice, "; ".join(failed)))


def set_(repo):
    _record(repo, ON)


def off(repo):
    _record(repo, OFF)


def clear(repo):
    name = _name(os.path.realpath(repo))
    for base in (home(), _own_home()):
        if base is not None:
            PRIVATE.remove(base, REL, name)


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
