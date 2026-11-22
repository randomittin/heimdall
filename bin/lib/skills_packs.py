#!/usr/bin/env python3
"""skills_packs.py -- which copy of a skill hmd reads: the installed pack when it is exactly the build the lock pins, else the bundled copy.

    skills_packs.py resolve ID

`resolve ID` prints the directory of skill ID (one directory name under skills/) and exits 0: its INSTALLED PACK, $HEIMDALL_HOME/packs/ID, when that pack is exactly the
build the lock pins, else the BUNDLED copy, <plugin root>/skills/ID (docs/superpowers/plans/2026-11-12-3x-lean-core.md T2.1; spec section 5 Stage 2: the resolver prefers an
installed package whose hash matches the lockfile, and otherwise falls back silently). Nothing here fetches, installs or writes a pack: that is the installer's job. This is
the read side, written first so the fallback exists before anything is moved.

THE PACK is what bin/heimdall-pack-build builds (T2.2): a copy of skills/ID, plus hmd.skill.yaml, plus SHA256SUMS, which lists every other file as `<sha256>  <path>`, one line
each, in bytewise path order. The pack's content hash is the sha256 of SHA256SUMS. THE PIN is the machine lock, $HEIMDALL_HOME/skills.lock (HEIMDALL_HOME, else ~/.heimdall: the
launcher's own rule): the row of ID, installed (or adopted), whose content_hash is that hash, 64 lowercase hex digits (a shorter hash is no pin).

TO VERIFY, as the builder documents it: SHA256SUMS must hash to the pin (the files alone say nothing about which build they came from), and the listing recomputed from the
files on disk must equal SHA256SUMS byte for byte (SHA256SUMS alone says nothing about a file edited after the build). The recomputation walks the pack the way the builder
walks a source: .DS_Store files and empty directories carry nothing; a name outside [A-Za-z0-9._-] or starting with a dot, a link, a file that is not regular or cannot be read
means no listing can be made, so the pack does not match; a file added or missing changes the listing. Modes are no part of the hash and are not checked. SHA256SUMS is pinned
by the hash, so nothing in it is parsed: it is only compared.

INV-L5 (the lean-core ledger): a pack with a hash mismatch, or missing, means the bundled copy, SILENTLY, never an error. So every way a pack cannot be used (no HEIMDALL_HOME, no
packs/, no pack for the ID, a changed byte, a lock that is missing, a link, not JSON or of another schema, no row, a row that is not installed, a hash that is not the pack's, ...)
prints the bundled path, exits 0 and says nothing on stderr. The bundled path is named whether or not it is on disk (a lean tree may not hold it; the caller tests for the file as
it does today). The resolver only reads: it creates, changes and deletes nothing, so it can never delete a bundled copy or leave a pack other than it found it.

THE ROOTS. The bundled root is CLAUDE_PLUGIN_ROOT (as bin/stack-pack reads it), else the tree this file lives in; the home is as above. Both come back absolute. Nothing is read from
the working directory or a project, and no project lock: a cloned repository cannot choose what an operator's skills resolve to. Run it as `python3 -I -S`: isolated mode also keeps
a module planted in the working directory off the import path.

EXIT. 0 the path was printed (every pack state, every fallback); 1 an unexpected failure (one line on stderr, nothing on stdout: a bug, not a pack state); 2 usage (no command, no id,
an id that is not a directory name). Python 3 standard library plus bin/lib/skills_lock.py.

Python API: resolve(skill_id, plugin_root=None, heimdall_home=None) -> Resolved(path, source) with source "pack" or "bundled"; ValueError for an id that is not a directory name.
The roots default as above.
"""
import collections
import hashlib
import os
import re
import stat
import sys

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB_DIR)  # python3 -I keeps the script's directory off sys.path
import skills_lock  # noqa: E402

Resolved = collections.namedtuple("Resolved", "path source")
SKILLS_DIR = "skills"
PACKS_DIR = "packs"
LOCK_FILE = "skills.lock"
SUMS_FILE = "SHA256SUMS"
SKIPPED_FILES = frozenset([".DS_Store"])
NAME_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")  # what bin/heimdall-pack-build lets a name hold
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")  # a skill id is one directory name (fullmatch only)
ID_RULE = "one directory name of letters, digits, '.', '_' and '-', starting with a letter or digit, at most 64 characters"
MAX_SUMS_BYTES = 1 << 20
MAX_FILE_BYTES = 32 << 20
MAX_FILES = 4096
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
USAGE = "usage: skills_packs.py resolve ID\n"
HELP = (
    "\n"
    "Print the directory of skill ID (a directory under skills/): its installed pack's when that pack is exactly the build the\n"
    "lock pins, else the bundled copy's. A pack that is missing or does not match is not an error: the bundled path is printed,\n"
    "silently.\n"
    "\n"
    "exit status: 0 the path was printed, 1 an unexpected failure, 2 bad usage\n"
)


def default_home():
    return os.path.abspath(os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall"))


def default_root():
    return os.path.abspath(os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(LIB_DIR)))


def pinned_hash(home, skill_id):
    """The content hash the machine lock pins for SKILL_ID: 64 hex digits, or None (no lock, a lock that cannot be used, no row, a row not installed, no sha256 in it)."""
    try:
        doc = skills_lock.load(os.path.join(home, LOCK_FILE))
    except skills_lock.LockError:
        return None
    for row in doc["entries"]:
        if row["id"] == skill_id and row["state"] in skills_lock.PRESENT:
            digest = row["content_hash"]
            return digest if digest and skills_lock.SHA256_RE.fullmatch(digest) else None
    return None


def read_regular(path, limit):
    """The bytes of the regular file at PATH (a link is refused, never followed), or None: not a regular file, bigger than LIMIT, or unreadable."""
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):  # before os.fdopen, which raises for a directory
            return None
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(limit + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    return data if len(data) <= limit else None


def safe_name(name):
    """True for a name made only of [A-Za-z0-9._-] that does not start with a dot: the names the builder lets a pack hold."""
    return bool(name) and name[0] != "." and all(char in NAME_CHARS for char in name)


def file_digests(pack):
    """{path relative to PACK, '/' separated: sha256 hex} of every file of the pack but its top-level SHA256SUMS; None when the pack holds what a build never makes."""
    found = {}
    pending = [("", pack)]
    while pending:
        prefix, directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                name = entry.name
                if name in SKIPPED_FILES and entry.is_file(follow_symlinks=False):
                    continue
                if not safe_name(name) or entry.is_symlink():
                    return None
                if entry.is_dir(follow_symlinks=False):
                    pending.append((prefix + name + "/", entry.path))
                elif not entry.is_file(follow_symlinks=False):
                    return None
                elif prefix or name != SUMS_FILE:
                    data = read_regular(entry.path, MAX_FILE_BYTES)
                    if data is None or len(found) >= MAX_FILES:
                        return None
                    found[prefix + name] = hashlib.sha256(data).hexdigest()
    return found


def matches(pack, pin):
    """True when the directory PACK is exactly the build whose content hash is PIN: SHA256SUMS hashes to PIN, and the listing recomputed from the files equals it."""
    sums = read_regular(os.path.join(pack, SUMS_FILE), MAX_SUMS_BYTES)
    if sums is None or hashlib.sha256(sums).hexdigest() != pin:
        return False
    try:
        digests = file_digests(pack)
    except OSError:
        return False
    if digests is None:
        return False
    return "".join("%s  %s\n" % (digests[path], path) for path in sorted(digests)).encode("ascii") == sums


def resolve(skill_id, plugin_root=None, heimdall_home=None):
    """Resolved(path, source): the skill's installed pack when that pack is the build the lock pins, else its bundled directory."""
    if ID_RE.fullmatch(skill_id) is None:
        raise ValueError("%r is not a skill id: %s" % (skill_id, ID_RULE))
    home = os.path.abspath(heimdall_home) if heimdall_home else default_home()
    pin = pinned_hash(home, skill_id)
    pack = os.path.join(home, PACKS_DIR, skill_id)
    if pin is not None and matches(pack, pin):
        return Resolved(pack, "pack")
    root = os.path.abspath(plugin_root) if plugin_root else default_root()
    return Resolved(os.path.join(root, SKILLS_DIR, skill_id), "bundled")


def main(argv):
    if argv in (["-h"], ["--help"]):
        sys.stdout.write(USAGE + HELP)
        return 0
    if len(argv) != 2 or argv[0] != "resolve":
        sys.stderr.write(USAGE)
        return 2
    if ID_RE.fullmatch(argv[1]) is None:
        sys.stderr.write("skills-packs: %r is not a skill id: %s\n%s" % (argv[1], ID_RULE, USAGE))
        return 2
    try:
        sys.stdout.buffer.write(os.fsencode(resolve(argv[1]).path) + b"\n")
        sys.stdout.buffer.flush()
    except Exception as exc:  # reported with a non-zero status, never a traceback
        sys.stderr.write("skills-packs: resolve failed: %s: %s\n" % (type(exc).__name__, exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
