#!/usr/bin/env python3
"""hmd_nofollow_write.py -- vet, write and append to files under a directory a repository controls, never following a
link (stdlib only).

WHY THIS EXISTS. bin/heimdall-checkpoint writes .planning/CHECKPOINT.md, RESUME-KEY.json, settings.json and the team
record under .planning/ledger by itself -- from the SessionEnd worker and the PreCompact hook -- and appends its session
notes to .heimdall/resume-notes.ndjson (`heimdall-checkpoint note`, which the PreCompact hook runs), in whatever
repository the session was started in, and a cloned repository controls every name below its root: `.planning`,
`.heimdall`, `.planning/ledger` or one of the files in them can be a symlink to anywhere the user can write (a dangling
one is created through), or a FIFO. A plain mkdir -p, redirection or mv follows such a link, so a hostile repo could send
an automatic write -- or a read it then copies into a new file -- to a path of its choosing. The JSON stores of
bin/lib/pmr_corpus.py go through it too: the issue security lane lives in the repository (.planning/security-signals).

This is the sibling of bin/lib/hmd_private_state.py (the same walk: one component at a time, each opened O_NOFOLLOW
relative to the one before, so no path string is resolved twice between the check and the use) with the policy .planning
needs, because .planning is not private state. It is shared and committed, so no directory is chmod'ed or created 0700,
the only mode set is the one the caller asks for (umask applied, never forced), and ownership is not judged: a repo
bind-mounted into a container that runs as root belongs to another account and its checkpoint must still be saved. And
a link, a FIFO, a directory or anything else that is not a regular file at a FILE's name is REFUSED, never replaced: a
link there may be the user's own setup, and replacing it would destroy it.

  check(root, paths)                 Refused naming the first path that is not plain: a link anywhere below `root`,
                                     a directory where a file is wanted or the other way round. A path that is missing
                                     is plain (the write will create it). Creates and changes nothing.
  write(root, rel, name, data, mode) <root>/<rel>/<name> := data, atomically: a temp file made beside it (O_EXCL, never
                                     through a link), fsync'ed, renamed over the name (rename never follows a link at
                                     the target). Missing directories are made (mkdir's usual mode). Refused, with
                                     nothing written, when the way down or the name is not plain.
  append(root, rel, name, data, mode) <root>/<rel>/<name> += data: opened O_APPEND|O_NOFOLLOW (never through a link) and
                                     O_NONBLOCK (a FIFO cannot hang it), and checked to be a regular file ON THE
                                     DESCRIPTOR that is written to; created with `mode` (umask applied) when it is
                                     missing. Missing directories are made. Refused, with nothing written, when the way
                                     down or the name is not plain.
  open_dir(root, rel, make)          the descriptor of <root>/<rel> walked without following a link.

A refusal is `Refused`, an OSError: a caller that catches OSError sees it, and `except Refused` tells it from a failure of
another kind (a full disk, a permission), which is a plain OSError.

`root` is the caller's own word (the project it was told to checkpoint, opened by its real path); everything below it
is the repository's.

CLI (for the shell tools, so a state file never goes through a shell redirection):
    python3 -I hmd_nofollow_write.py check ROOT PATH...                       PATH is relative to ROOT; a trailing "/"
                                                                              asks for a directory, anything else for a
                                                                              regular file
    python3 -I hmd_nofollow_write.py write --root DIR --rel REL --name NAME [--mode OCTAL]
                                                                              the file's bytes on stdin; --mode is the
                                                                              creation mode, umask applied (default 600)
    python3 -I hmd_nofollow_write.py append --root DIR --rel REL --name NAME [--mode OCTAL]
                                                                              the bytes to append on stdin; same --mode
exit 0 done / plain, 1 failed for another reason (an I/O error; the reason on stderr), 2 usage, 4 REFUSED (a link or an
entry that is not plain; nothing was written; the reason on stderr).
"""
import argparse
import contextlib
import errno
import os
import stat
import sys

REFUSED = 4  # the exit status of a refusal: not 0 (done), not 1 (failed), not 2 (usage)

_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Refused(OSError):
    """A path that is not plain -- a link, a FIFO, a directory where a file is wanted, a name that is not a name. Nothing was
    written or changed."""


def _parts(rel):
    parts = [p for p in (rel or "").split("/") if p]
    if any(p in (".", "..") for p in parts):
        raise Refused("not a plain relative path: %r" % (rel,))
    return parts


def _plain_name(name):
    if not name or name in (".", "..") or "/" in name or "\x00" in name or len(name) > 200:
        raise Refused("not a plain file name: %r" % (name,))
    return name


def _lstat(name, dirfd):
    """The stat of `name` inside the open directory `dirfd`, a link not followed; None when it is not there."""
    try:
        return os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _refusal(shown, mode, want):
    """The Refused for `shown`, which is not `want` ('a directory' or 'a regular file'); `mode` is its lstat mode."""
    if stat.S_ISLNK(mode):
        return Refused("%s is a symbolic link" % shown)
    return Refused("%s is not %s" % (shown, want))


def open_dir(root, rel, make=False):
    """The descriptor of <root>/<rel>, which the caller closes: every component below `root` opened WITHOUT following
    a link, relative to the one before, and a directory because the open itself says so (O_DIRECTORY). `make` creates a
    missing component (mkdir's usual mode, umask applied); a reader leaves it False and creates nothing. Refused -- a
    link, a plain file, a FIFO -- with nothing created or changed behind it; FileNotFoundError when a component is
    missing and `make` is not set."""
    fd = os.open(os.path.realpath(root), os.O_RDONLY | os.O_DIRECTORY)
    shown = ""
    try:
        for name in _parts(rel):
            shown = "%s/%s" % (shown, name) if shown else name
            try:
                below = os.open(name, _DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not make:
                    raise
                with contextlib.suppress(FileExistsError):  # another maker got there first: opened, and vetted, just below
                    os.mkdir(name, 0o777, dir_fd=fd)
                below = os.open(name, _DIR_FLAGS, dir_fd=fd)
            except OSError as exc:
                if exc.errno not in (errno.ELOOP, errno.ENOTDIR):
                    raise
                st = _lstat(name, fd)
                if st is None:
                    raise
                raise _refusal(shown, st.st_mode, "a directory")
            os.close(fd)
            fd = below
    except BaseException:
        os.close(fd)
        raise
    return fd


def check(root, paths):
    """Return when every path is plain; raise Refused naming the first one that is not. A path is relative to `root`;
    a trailing "/" asks for a directory, anything else for a regular file. Missing is plain."""
    os.close(os.open(os.path.realpath(root), os.O_RDONLY | os.O_DIRECTORY))
    for path in paths:
        parts = _parts(path)
        if not parts:
            raise Refused("not a plain relative path: %r" % (path,))
        want_dir = path.endswith("/")
        try:
            dirfd = open_dir(root, "/".join(parts[:-1]))
        except FileNotFoundError:
            continue  # a directory that is not there holds nothing, so there is nothing to refuse below it
        try:
            st = _lstat(parts[-1], dirfd)
        finally:
            os.close(dirfd)
        if st is not None and not (stat.S_ISDIR if want_dir else stat.S_ISREG)(st.st_mode):
            raise _refusal("/".join(parts), st.st_mode, "a directory" if want_dir else "a regular file")


def _drop(dirfd, name):
    with contextlib.suppress(OSError):
        os.unlink(name, dir_fd=dirfd)


def write(root, rel, name, data, mode=0o600):
    """Make <root>/<rel>/<name> hold `data` (bytes), atomically, never through a link. `mode` is the creation mode of the
    new file with the umask applied (0o666 gives the file its owner's usual 0644; no chmod follows). The name is
    refused, with nothing written, when it is there as anything but a regular file -- a link included, which is not
    replaced; a regular file that is there is replaced whole."""
    _plain_name(name)
    dirfd = open_dir(root, rel, True)
    try:
        st = _lstat(name, dirfd)
        if st is not None and not stat.S_ISREG(st.st_mode):
            raise _refusal("/".join(_parts(rel) + [name]), st.st_mode, "a regular file")
        tmp = "%s.tmp-%s" % (name, os.urandom(4).hex())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dirfd)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
        except BaseException:
            os.close(fd)
            _drop(dirfd, tmp)
            raise
        os.close(fd)
        try:
            os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        except OSError:
            _drop(dirfd, tmp)
            raise
    finally:
        os.close(dirfd)


def append(root, rel, name, data, mode=0o600):
    """Add `data` (bytes) to the end of <root>/<rel>/<name>, never through a link; the file is created (`mode`, umask applied)
    when it is not there. The name is refused, with nothing written, when it is there as anything but a regular file -- a
    link included, which is not followed or replaced. The open is O_NOFOLLOW (a link planted since the check fails it) and
    O_NONBLOCK (a FIFO planted since the check cannot hang it), and what it opened is checked to be a regular file before a
    byte is written."""
    _plain_name(name)
    shown = "/".join(_parts(rel) + [name])
    dirfd = open_dir(root, rel, True)
    try:
        st = _lstat(name, dirfd)
        if st is not None and not stat.S_ISREG(st.st_mode):
            raise _refusal(shown, st.st_mode, "a regular file")
        try:
            fd = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=dirfd)
        except OSError as exc:
            planted = _lstat(name, dirfd) if exc.errno in (errno.ELOOP, errno.ENXIO) else None
            if planted is None:
                raise
            raise _refusal(shown, planted.st_mode, "a regular file")
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise Refused("%s is not a regular file" % shown)
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="hmd_nofollow_write.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="action", required=True)
    chk = sub.add_parser("check", help="refuse unless every path is plain")
    chk.add_argument("root")
    chk.add_argument("paths", nargs="+", help="relative to ROOT; a trailing / asks for a directory, else a regular file")
    for action, what in (("write", "atomically replace ROOT/REL/NAME with"), ("append", "append to ROOT/REL/NAME")):
        wr = sub.add_parser(action, help="%s the bytes on stdin" % what)
        wr.add_argument("--root", required=True)
        wr.add_argument("--rel", default="")
        wr.add_argument("--name", required=True)
        wr.add_argument("--mode", default="600", help="octal creation mode, umask applied (default 600)")
    args = parser.parse_args(argv)
    try:
        if args.action == "check":
            check(args.root, args.paths)
        else:
            try:
                mode = int(args.mode, 8)
            except ValueError:
                parser.error("--mode is octal digits")
            (write if args.action == "write" else append)(args.root, args.rel, args.name, sys.stdin.buffer.read(), mode)
    except Refused as exc:
        print("hmd_nofollow_write: %s" % exc, file=sys.stderr)
        return REFUSED
    except OSError as exc:
        print("hmd_nofollow_write: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
