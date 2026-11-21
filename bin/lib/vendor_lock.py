#!/usr/bin/env python3
r"""vendor_lock.py -- the vendor lock: which tagged commit of a split-out repository heimdall mirrors, and the hash of the files mirrored from it.

    heimdall-vendor sync   NAME | --all  [--source SRC]                 [--lock FILE] [--root DIR]
    heimdall-vendor verify NAME | --all  [--upstream [--source SRC]]    [--lock FILE] [--root DIR]
    heimdall-vendor diff   NAME | --all  [--source SRC]                 [--lock FILE] [--root DIR]

Plan: docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md, section 3 and task T1.1. The skills and the statusline are developed in their own
repositories; heimdall keeps a copy of every moved file at the SAME path (the bundled fallback), so no hook, installer or test changes. This tool keeps that
copy honest (INV-S1: the same bytes at the same path as the pinned tag).

THE LOCK, vendor/vendor.lock.json (--lock), strict JSON, schema 1:

    {"schema": 1, "repos": [{"name": "hmd-skills", "repo": "git@github.com:randomittin/hmd-skills.git", "tag": "v1.0.0",
                             "commit": "<40 hex>", "tree_sha256": "<64 hex>", "paths": ["skills/stacks/SKILL.md", ...]}]}

`repo` is where the tag is fetched from (a URL or a local path), `commit` what the tag must resolve to, `paths` the mirrored files (one path names the same
file in both trees), `tree_sha256` the hash of those files. The tool only READS the lock: a pin changes by a person editing it in a commit (tag, commit and
tree_sha256 together; a refused `sync` and `diff` print the values to put there), never by this tool.

TREE_SHA256 is the sha256 of this text, one line per path, in byte order of the path:

    heimdall-vendor tree/1
    <sha256 of the file's bytes> <x if the owner exec bit is set, else -> <path>

so it covers every byte, the exec bit (hooks/statusline.sh must stay executable) and the set of paths, and nothing else (no mtime, owner or umask). By hand:

    { echo 'heimdall-vendor tree/1'; for p in $(printf '%s\n' PATH... | LC_ALL=C sort); do
        printf '%s %s %s\n' "$(shasum -a 256 < "$p" | cut -d' ' -f1)" "$([ -x "$p" ] && echo x || echo -)" "$p"; done; } | shasum -a 256

VERBS. `verify` is offline: it recomputes tree_sha256 over the files in --root (default: the tree this tool lives in) and fails on any difference, naming the
file when one cannot be read (missing, a link, not a regular file). `verify --upstream` also fetches the tag and requires it to resolve to the locked commit
and to hash to the locked tree_sha256 (a tag moved upstream). `sync` fetches the tag, REFUSES (writing nothing) unless commit and tree_sha256 are the lock's,
then writes each mirrored file atomically (a temp file in the same directory, then a rename; the exec bit from the tag; a file already equal is not touched,
so a second sync changes nothing). `diff` fetches the tag and shows what the mirror has that the tag does not: a unified diff per changed text file, and the
commit and tree_sha256 the tag has when they are not the lock's. A path dropped from the lock is not deleted from the mirror: remove it by hand.

SOURCE. Where the tag is fetched from: --source SRC (one NAME only: a URL or a path, such as a local clone before the repository is published), else the
lock's `repo`. The fetch goes into a fresh temporary bare repository (so nothing of the caller's repository is touched, whatever GIT_DIR a hook set), only
the file, https, ssh and git transports are allowed, nothing prompts, and it is cut after HMD_VENDOR_GIT_TIMEOUT_S seconds (default 120).

UNTRUSTED INPUT. The lock and the fetched tree are read like untrusted files: the lock is a regular file of at most 1 MiB, strict JSON (a duplicate key or NaN
is refused) with every field checked (a path is relative, made of [A-Za-z0-9._@+-] parts, never `.`, `..` or a `.git*` part, unique in the whole lock even
by case; a repo or tag cannot start with `-`); a mirrored file must be a regular file of at most 32 MiB reached through no link; a tag's file must be a plain
blob (a link or a submodule is refused).

EXIT STATUS. 0 ok, nothing differs; 1 a difference, a refusal, a failed fetch or write, or a lock that is missing, unreadable or invalid (one report line each,
never a traceback); 2 bad usage (a NAME the lock does not list, --source with --all, ...). Python 3 standard library only.
"""
import argparse
import difflib
import errno
import hashlib
import itertools
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

SCHEMA = 1
TOOL_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_LOCK = os.path.join("vendor", "vendor.lock.json")
TREE_HEADER = "heimdall-vendor tree/1\n"
MAX_LOCK_BYTES = 1 << 20
MAX_FILE_BYTES = 32 << 20
MAX_DIFF_LINES = 200
GIT_TIMEOUT_S = 120
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

TOP_FIELDS = ("schema", "repos")
ENTRY_FIELDS = ("name", "repo", "tag", "commit", "tree_sha256", "paths")
# Used with fullmatch, never match: `$` would let a trailing newline through.
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
REPO_RE = re.compile(r"[A-Za-z0-9@:/._~+-]{1,300}")
TAG_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+/-]{0,127}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PATH_PART_RE = re.compile(r"[A-Za-z0-9._@+-]+")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
# What git is told it must not inherit: the variables that make it work on another repository than the temporary one the tool makes.
GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
                 "GIT_NAMESPACE", "GIT_PREFIX", "GIT_QUARANTINE_PATH")


class LockError(Exception):
    """The lock is missing, unreadable or invalid (exit 1)."""


class Failure(Exception):
    """One repository cannot be read, fetched or written, or the tag is not what the lock pins (that repository fails, exit 1)."""


def ascii_text(value, cap):
    """Printable ASCII only (anything else becomes '?'), cut to `cap` characters: text from git or the command line, shown on one line."""
    return re.sub(r"[^ -~]", "?", value).strip()[:cap]


def digest(data):
    return hashlib.sha256(data).hexdigest()


# ---- the lock: strict JSON, every field checked ------------------------------------------------------------------

def repo_ok(value):
    return isinstance(value, str) and REPO_RE.fullmatch(value) is not None and not value.startswith("-") and "::" not in value


def tag_ok(value):
    return (isinstance(value, str) and TAG_RE.fullmatch(value) is not None and ".." not in value and "//" not in value
            and not value.endswith(("/", ".", ".lock")))


def path_problem(path):
    """Why `path` cannot be a mirrored file, or None. Nothing here can leave the tree, name a link's way out or reach into a .git directory."""
    if not isinstance(path, str) or not 1 <= len(path) <= 300:
        return "must be a string of 1-300 characters"
    for part in path.split("/"):
        if PATH_PART_RE.fullmatch(part) is None or part in (".", "..") or part.lower().startswith(".git"):
            return "has an unsafe component %r" % part
    return None


ENTRY_RULES = (
    ("name", "must match %s" % NAME_RE.pattern, lambda value: isinstance(value, str) and NAME_RE.fullmatch(value) is not None),
    ("repo", "must be a git URL or path of 1-300 characters from [A-Za-z0-9@:/._~+-], not starting with '-', without '::'", repo_ok),
    ("tag", "must be a tag name of 1-128 characters from [A-Za-z0-9._+/-], starting with a letter or digit, without '..'", tag_ok),
    ("commit", "must be 40 or 64 lowercase hex digits", lambda value: isinstance(value, str) and COMMIT_RE.fullmatch(value) is not None),
    ("tree_sha256", "must be 64 lowercase hex digits", lambda value: isinstance(value, str) and SHA256_RE.fullmatch(value) is not None),
)


def entry_problems(entry, label):
    if not isinstance(entry, dict):
        return ["%s: not an object" % label]
    found = ["%s: missing key %s" % (label, key) for key in ENTRY_FIELDS if key not in entry]
    found += ["%s: unexpected key %r" % (label, key) for key in entry if key not in ENTRY_FIELDS]
    found += ["%s.%s: %s" % (label, key, rule) for key, rule, check in ENTRY_RULES if key in entry and not check(entry[key])]
    if "paths" in entry:
        paths = entry["paths"]
        if not isinstance(paths, list) or not paths:
            found.append("%s.paths: must be a non-empty array" % label)
        else:
            for path in paths:
                reason = path_problem(path)
                if reason:
                    found.append("%s.paths: %r %s" % (label, path, reason))
    return found


def problems(doc):
    """Every reason `doc` is not a valid vendor lock/1; an empty list when it is one."""
    if not isinstance(doc, dict):
        return ["top level: not an object"]
    found = ["top level: missing key %s" % key for key in TOP_FIELDS if key not in doc]
    found += ["top level: unexpected key %r" % key for key in doc if key not in TOP_FIELDS]
    if "schema" in doc and not (type(doc["schema"]) is int and doc["schema"] == SCHEMA):
        found.append("schema: must be %d" % SCHEMA)
    repos = doc.get("repos")
    if "repos" in doc and not isinstance(repos, list):
        return found + ["repos: must be an array"]
    names, owners = set(), {}
    for index, entry in enumerate(repos or []):
        label = "repos[%d]" % index
        found += entry_problems(entry, label)
        if not isinstance(entry, dict):
            continue
        if isinstance(entry.get("name"), str):
            if entry["name"] in names:
                found.append("%s: duplicate name %r" % (label, entry["name"]))
            names.add(entry["name"])
        if isinstance(entry.get("paths"), list):
            for path in entry["paths"]:
                if not isinstance(path, str):
                    continue
                if path.lower() in owners:
                    found.append("%s.paths: duplicate path %r (also in repos[%d])" % (label, path, owners[path.lower()]))
                else:
                    owners[path.lower()] = index
    return found


def read_lock_bytes(path):
    """The bytes of the lock at `path`. A link, a non-regular file, a missing or a big one is a LockError."""
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise LockError("no lock at %s" % path)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise LockError("%s is a symbolic link: the lock is never read through a link" % path)
        raise LockError("cannot open %s: %s" % (path, exc.strerror))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):  # before os.fdopen, which raises IsADirectoryError for a directory
            raise LockError("%s is not a regular file" % path)
        with os.fdopen(fd, "rb", closefd=False) as handle:
            raw = handle.read(MAX_LOCK_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > MAX_LOCK_BYTES:
        raise LockError("%s is larger than %d bytes" % (path, MAX_LOCK_BYTES))
    return raw


def _no_duplicates(pairs):
    found = {}
    for key, value in pairs:
        if key in found:
            raise ValueError("duplicate key %r" % key)
        found[key] = value
    return found


def _no_constants(name):
    raise ValueError("%s is not allowed" % name)


def load(path):
    """The lock at `path`, checked. LockError when it is missing, unreadable or invalid."""
    raw = read_lock_bytes(path)
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicates, parse_constant=_no_constants)
    except (ValueError, RecursionError) as exc:
        raise LockError("%s is not valid JSON: %s" % (path, exc))
    reasons = problems(doc)
    if reasons:
        raise LockError("%s is not a valid vendor lock (schema %d): %s" % (path, SCHEMA, "; ".join(reasons[:5])))
    return doc


# ---- hashing and the mirror --------------------------------------------------------------------------------------

def tree_sha256(files):
    """The lock's tree_sha256 of `files`, {path: (executable, data)} (see TREE_SHA256 above)."""
    lines = [TREE_HEADER]
    for path in sorted(files):
        executable, data = files[path]
        lines.append("%s %s %s\n" % (digest(data), "x" if executable else "-", path))
    return digest("".join(lines).encode("ascii"))


def read_mirror(root, rel):
    """(executable, data) of the regular file root/rel, or the text of why it is not one. No link is followed, in the file or in a parent directory."""
    here = root
    for part in rel.split("/")[:-1]:
        here = os.path.join(here, part)
        try:
            info = os.lstat(here)
        except FileNotFoundError:
            return "missing"
        except OSError as exc:
            return "cannot read: %s" % exc.strerror
        if stat.S_ISLNK(info.st_mode):
            return "a parent directory is a link"
        if not stat.S_ISDIR(info.st_mode):
            return "a parent is not a directory"
    try:
        fd = os.open(os.path.join(root, rel), os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return "missing"
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return "a link, not a regular file"
        return "cannot read: %s" % exc.strerror
    try:
        info = os.fstat(fd)  # before os.fdopen, which raises IsADirectoryError for a directory instead of letting us say what it is
        if not stat.S_ISREG(info.st_mode):
            return "not a regular file"
        if info.st_size > MAX_FILE_BYTES:
            return "larger than %d bytes" % MAX_FILE_BYTES
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
    finally:
        os.close(fd)
    return (bool(info.st_mode & 0o100), data)


def read_mirror_files(root, paths):
    """({path: (executable, data)}, [(path, why)]): the mirror as it is, and each path that cannot be read as a regular file."""
    files, failures = {}, []
    for path in sorted(paths):
        got = read_mirror(root, path)
        if isinstance(got, str):
            failures.append((path, got))
        else:
            files[path] = got
    return files, failures


def write_mirror_file(root, rel, executable, data):
    """Atomically: a temp file in the file's directory, flushed to disk, then renamed over the file. Never through a link; the exec bit as given."""
    try:
        parent = root
        for part in rel.split("/")[:-1]:
            parent = os.path.join(parent, part)
            try:
                info = os.lstat(parent)
            except FileNotFoundError:
                os.mkdir(parent, 0o755)
                continue
            if not stat.S_ISDIR(info.st_mode):
                raise Failure("%s: %s is a link or not a directory" % (rel, os.path.relpath(parent, root)))
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".heimdall-vendor.", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o755 if executable else 0o644)
            os.replace(tmp, os.path.join(root, rel))
        except BaseException:
            if os.path.lexists(tmp):
                os.unlink(tmp)
            raise
    except OSError as exc:
        raise Failure("%s: cannot write: %s" % (rel, exc.strerror))


# ---- the pinned tag, read from git -------------------------------------------------------------------------------

def git_timeout():
    """Seconds a git call may take: HMD_VENDOR_GIT_TIMEOUT_S when it is a number above 0 and at most 3600, else the default."""
    try:
        wanted = float(os.environ.get("HMD_VENDOR_GIT_TIMEOUT_S", ""))
    except ValueError:
        return GIT_TIMEOUT_S
    return wanted if 0 < wanted <= 3600 else GIT_TIMEOUT_S


def git(git_dir, argv, what):
    """The stdout of `git [--git-dir D] ARGV`. Failure("<what>: <why>") when git is missing, too slow or exits non-zero."""
    env = {key: value for key, value in os.environ.items() if key not in GIT_REPO_VARS}
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_ALLOW_PROTOCOL"] = "file:https:ssh:git"
    command = ["git"] + (["--git-dir", git_dir] if git_dir else []) + argv
    timeout = git_timeout()
    try:
        done = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=timeout)
    except FileNotFoundError:
        raise Failure("%s: git is not installed" % what)
    except subprocess.TimeoutExpired:
        raise Failure("%s: git %s took more than %d s" % (what, argv[0], timeout))
    if done.returncode != 0:
        detail = " ".join(done.stderr.decode("utf-8", "replace").strip().splitlines()[-2:])
        raise Failure("%s: git %s failed: %s" % (what, argv[0], ascii_text(detail, 300) or "no message"))
    return done.stdout


def read_upstream(entry, source):
    """(commit, {path: (executable, data)}) of the entry's tag as `source` (default: the lock's repo) has it. Failure when the tag cannot be read as files."""
    tag, paths = entry["tag"], entry["paths"]
    source = entry["repo"] if source is None else source
    work = tempfile.mkdtemp(prefix="heimdall-vendor-")
    try:
        bare = os.path.join(work, "repo.git")
        git(None, ["init", "-q", "--bare", bare], "cannot create a temporary repository")
        ref = "refs/tags/%s" % tag
        git(bare, ["fetch", "-q", "--no-tags", "--", source, "+%s:%s" % (ref, ref)], "cannot fetch tag %s from %s" % (tag, ascii_text(source, 120)))
        commit = git(bare, ["rev-parse", "--verify", "-q", ref + "^{commit}"], "tag %s is not a commit" % tag).decode("ascii", "replace").strip()
        if COMMIT_RE.fullmatch(commit) is None:
            raise Failure("tag %s: git printed %r, not a commit id" % (tag, ascii_text(commit, 80)))
        listing = git(bare, ["ls-tree", "-r", "-l", "-z", commit, "--"] + paths, "cannot list tag %s" % tag)
        records = {}
        for record in listing.decode("utf-8", "replace").split("\0"):
            meta, _, path = record.partition("\t")
            if len(meta.split()) == 4:
                records[path] = meta.split()
        files = {}
        for path in sorted(paths):
            if path not in records:
                raise Failure("%s is not a file in tag %s" % (path, tag))
            mode, kind, oid, size = records[path]
            if kind != "blob" or mode not in ("100644", "100755"):
                raise Failure("%s is a link or a submodule in tag %s (mode %s), not a file" % (path, tag, mode))
            if not size.isdigit() or int(size) > MAX_FILE_BYTES:
                raise Failure("%s is larger than %d bytes in tag %s" % (path, MAX_FILE_BYTES, tag))
            files[path] = (mode == "100755", git(bare, ["cat-file", "blob", oid], "cannot read %s of tag %s" % (path, tag)))
        return commit, files
    finally:
        shutil.rmtree(work, ignore_errors=True)


def load_pinned(entry, source):
    """(files, reasons): the tag's files and, when the tag is not what the lock pins, one line for each way it is not."""
    commit, files = read_upstream(entry, source)
    reasons = []
    if commit != entry["commit"]:
        reasons.append("tag %s is commit %s, the lock pins %s: the tag moved, or the lock is stale" % (entry["tag"], commit, entry["commit"]))
    tree = tree_sha256(files)
    if tree != entry["tree_sha256"]:
        reasons.append("the files of tag %s hash to tree_sha256 %s, the lock has %s" % (entry["tag"], tree, entry["tree_sha256"]))
    return files, reasons


# ---- the three verbs ---------------------------------------------------------------------------------------------

def verify_entry(root, entry, args):
    name = entry["name"]
    files, failures = read_mirror_files(root, entry["paths"])
    for path, why in failures:
        print("FAIL %s %s: %s" % (name, path, why))
    if failures:
        return False
    tree = tree_sha256(files)
    if tree != entry["tree_sha256"]:
        print("FAIL %s: tree_sha256 differs: lock %s, mirror %s" % (name, entry["tree_sha256"], tree))
        print("     a mirrored file was edited, or the lock's paths or tree_sha256 were; `heimdall-vendor diff %s` names the files" % name)
        return False
    if args.upstream:
        _, reasons = load_pinned(entry, args.source)
        for reason in reasons:
            print("FAIL %s: %s" % (name, reason))
        if reasons:
            return False
    print("ok %s: %d files match the lock (tag %s, tree_sha256 %s%s)" % (name, len(files), entry["tag"], tree, ", tag checked upstream" if args.upstream else ""))
    return True


def sync_entry(root, entry, args):
    name, tag = entry["name"], entry["tag"]
    files, reasons = load_pinned(entry, args.source)
    if reasons:
        for reason in reasons:
            print("FAIL %s: refusing to sync: %s" % (name, reason))
        print("     nothing was written")
        return False
    written = 0
    for path in sorted(files):
        executable, data = files[path]
        if read_mirror(root, path) != (executable, data):
            write_mirror_file(root, path, executable, data)
            written += 1
    if written:
        print("synced %s: %d of %d files written from tag %s (commit %s)" % (name, written, len(files), tag, entry["commit"]))
    else:
        print("already in sync %s: %d files equal tag %s (commit %s)" % (name, len(files), tag, entry["commit"]))
    return True


def text_lines(data):
    """The lines of `data` when it is UTF-8 text without a NUL, else None."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return None if "\x00" in text else text.splitlines()


def print_text_diff(label, path, old, new):
    """The unified diff of the tag's file (old) against the mirror's (new), cut at MAX_DIFF_LINES, control characters made visible."""
    old_lines, new_lines = text_lines(old), text_lines(new)
    if old_lines is None or new_lines is None:
        print("    binary or non-UTF-8 content: no line diff")
        return
    shown = list(itertools.islice(difflib.unified_diff(old_lines, new_lines, "%s:%s" % (label, path), "mirror:%s" % path, lineterm=""), MAX_DIFF_LINES + 1))
    if not shown:
        print("    the lines are the same; only a line ending or the end of the file differs")
    for line in shown[:MAX_DIFF_LINES]:
        print(CONTROL_RE.sub(lambda match: "\\x%02x" % ord(match.group()), line))
    if len(shown) > MAX_DIFF_LINES:
        print("    ... diff cut at %d lines" % MAX_DIFF_LINES)


def diff_entry(root, entry, args):
    name, tag = entry["name"], entry["tag"]
    files, reasons = load_pinned(entry, args.source)
    for reason in reasons:
        print("FAIL %s: %s" % (name, reason))
    differing = 0
    for path in sorted(files):
        executable, data = files[path]
        mine = read_mirror(root, path)
        if isinstance(mine, str):
            differing += 1
            print("changed %s %s: %s in the mirror" % (name, path, mine))
            continue
        if mine == (executable, data):
            continue
        differing += 1
        if mine[1] != data:
            print("changed %s %s: sha256 %s (tag) -> %s (mirror)" % (name, path, digest(data), digest(mine[1])))
            print_text_diff("%s@%s" % (name, tag), path, data, mine[1])
        if mine[0] != executable:
            describe = lambda flag: "executable" if flag else "not executable"
            print("changed %s %s: mode %s (tag) -> %s (mirror)" % (name, path, describe(executable), describe(mine[0])))
    if differing or reasons:
        print("FAIL %s: %d of %d files differ from tag %s" % (name, differing, len(files), tag))
        return False
    print("no difference %s: %d files equal tag %s (commit %s)" % (name, len(files), tag, entry["commit"]))
    return True


HANDLERS = {"sync": sync_entry, "verify": verify_entry, "diff": diff_entry}


def build_parser():
    parser = argparse.ArgumentParser(prog="heimdall-vendor", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", metavar="{sync,verify,diff}")
    commands.required = True

    def command(name, summary, description):
        sub = commands.add_parser(name, help=summary, description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
        target = sub.add_mutually_exclusive_group(required=True)
        target.add_argument("name", nargs="?", metavar="NAME", help="a repository the lock lists")
        target.add_argument("--all", action="store_true", help="every repository the lock lists")
        sub.add_argument("--lock", metavar="FILE", help="the lock (default: vendor/vendor.lock.json under --root)")
        sub.add_argument("--root", metavar="DIR", help="the tree that holds the mirror (default: the tree this tool lives in)")
        return sub

    verify = command("verify", "recompute tree_sha256 of the mirror and compare it with the lock (offline)",
                     "Recompute tree_sha256, the hash of the mirrored files under --root, and fail on any difference from the lock.\n"
                     "With --upstream also fetch the tag and require its commit and tree_sha256 to be the lock's (a tag moved upstream).")
    verify.add_argument("--upstream", action="store_true", help="also check the tag at its source (needs git and the source)")
    verify.add_argument("--source", metavar="SRC", help="with --upstream and one NAME: fetch from this URL or path instead of the lock's repo")
    sync = command("sync", "write the pinned tag's files into the mirror, refusing a tag the lock does not pin",
                   "Fetch the tag, refuse (writing nothing) unless its commit and tree_sha256 are the lock's, then write each mirrored file atomically.")
    sync.add_argument("--source", metavar="SRC", help="with one NAME: fetch from this URL or path (a local clone) instead of the lock's repo")
    diff = command("diff", "show what the mirror has that the pinned tag does not",
                   "Fetch the tag and show, per mirrored file, a unified diff of the tag's file against the mirror's, and the commit and tree_sha256 the tag has\n"
                   "when they are not the lock's.")
    diff.add_argument("--source", metavar="SRC", help="with one NAME: fetch from this URL or path (a local clone) instead of the lock's repo")
    return parser


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")  # a diff line the terminal's encoding cannot show is escaped, never a UnicodeEncodeError
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.source is not None:
        if args.all:
            parser.error("--source names the clone of ONE repository: give a NAME, not --all")
        if args.command == "verify" and not args.upstream:
            parser.error("--source only applies with --upstream")
        if not args.source or args.source.startswith("-") or "::" in args.source or CONTROL_RE.search(args.source):
            parser.error("--source must be a git URL or a path, not empty, not starting with '-', without '::' or control characters")
    root = os.path.abspath(args.root) if args.root else TOOL_ROOT
    if not os.path.isdir(root):
        parser.error("--root %s is not a directory" % ascii_text(root, 200))
    lock_file = args.lock if args.lock else os.path.join(root, DEFAULT_LOCK)
    try:
        doc = load(lock_file)
    except LockError as exc:
        print("heimdall-vendor: %s" % exc, file=sys.stderr)
        return 1
    if args.all:
        entries = doc["repos"]
        if not entries:
            print("heimdall-vendor: %s lists no repositories: nothing to %s" % (lock_file, args.command), file=sys.stderr)
            return 1
    else:
        entries = [entry for entry in doc["repos"] if entry["name"] == args.name]
        if not entries:
            parser.error("%s is not in %s (it lists: %s)" % (ascii_text(args.name, 80), lock_file, ", ".join(e["name"] for e in doc["repos"]) or "nothing"))
    results = []
    for entry in entries:
        try:
            results.append(HANDLERS[args.command](root, entry, args))
        except Failure as exc:
            print("FAIL %s: %s" % (entry["name"], exc))
            results.append(False)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
