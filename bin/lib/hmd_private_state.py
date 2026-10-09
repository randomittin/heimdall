#!/usr/bin/env python3
"""hmd_private_state.py -- small state files that only this user may read or change, written and read without ever
following a link (stdlib only).

WHY THIS EXISTS. Files hmd keeps under <repo>/.heimdall/ -- the session records the SessionStart hook writes, the
marker a paired phone leaves for the statusline, the pair window's state, the companion inbox and its archive, locks and
audit log -- live in a tree a repository controls: a cloned repo can carry `.heimdall` or `.heimdall/app` as a symlink,
or a ready-made session record. A plain open()/chmod()/rename() through such a path writes, or chmods, wherever the link
points, and a plain read trusts whatever a checkout planted. The pattern here is bin/lib/companion_attach.py's
(_open_attachments, after its security review), applied to a directory chosen by the caller:

  * the way down from the root is walked ONE COMPONENT AT A TIME, each opened with O_NOFOLLOW relative to the one
    before and fstat'ed to be a directory this process owns (open_dir): a link anywhere below the root, or a
    directory of another account's, is refused (OSError) before anything is created, chmod'ed or written through
    it. A directory this creates is 0700, and the directory that will hold the files is forced to 0700 with fchmod
    of the vetted descriptor -- never chmod of a path;
  * a file is written to a temp name created O_CREAT|O_EXCL|O_NOFOLLOW (0600 whatever the umask), fsync'ed, and
    renamed over the real name relative to that same descriptor, so no path string is resolved a second time
    between the check and the use and an existing link at the real name is replaced, not written through;
  * a file is read O_NOFOLLOW and trusted only if what was actually opened is a regular file this process owns with
    no group or other permission bits and at most `limit` bytes. A file a git checkout planted is 0644 and fails
    that test, which is the point: a repository cannot make this user's tools believe it.

Beyond write/read/remove: open_lockfile() hands a caller a flock-able descriptor of a file it owns under the same walk
and lock() holds an exclusive flock on one for a with block; open_append() hands back an append-only descriptor (0600,
vetted) and append() writes to it -- under a lock when given a lock name -- and fsyncs; truncate() empties a file in place
and rename() renames inside the vetted directory (a link at the target is replaced, never written through); open_read()
hands back a vetted read-only descriptor and stat_file() the stat of a marker file (its mtime, say) without following a
link; read() takes the mode bits a caller tolerates -- `forbidden` for the file, `dir_forbidden` for the directory holding
it -- for state another tool already keeps looser than 0600 (bin/heimdall-inbox-wake, bin/heimdall-inbox-deliver and
bin/lib/companion_ui_inbox.py use them for the inbox, its archive, their locks, markers and connect.json).

The root itself is opened by its real path (the caller named it; /var -> /private/var and the like are fine).

CLI (for the shell tools, so a state file never goes through a shell redirection):
    python3 hmd_private_state.py write  --root DIR --rel REL --name NAME     the file's bytes on stdin
    python3 hmd_private_state.py remove --root DIR --rel REL --name NAME
exit 0 done, 1 refused or failed (the reason on stderr), 2 usage.
"""
import contextlib
import fcntl
import json
import os
import stat
import sys

_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
READ_LIMIT = 4096


def _vet_dir(fd, name):
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
        raise OSError("%s is not a directory of ours" % name)


def _step(parent, name, make):
    """The descriptor of the directory `name` inside the open directory `parent`: opened WITHOUT following a link,
    then checked (fstat of what was actually opened) to be a directory this process owns. `make` creates it (0700)
    when it is missing. A link, a plain file, someone else's directory: OSError, and nothing was touched. Returns
    (descriptor, created)."""
    created = False
    try:
        fd = os.open(name, _DIR_FLAGS, dir_fd=parent)
    except FileNotFoundError:
        if not make:
            raise
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            created = True
        except FileExistsError:  # another writer made it a moment ago: opened, and vetted, just below
            created = False
        fd = os.open(name, _DIR_FLAGS, dir_fd=parent)
    try:
        _vet_dir(fd, name)
    except BaseException:
        os.close(fd)
        raise
    return fd, created


def _components(rel):
    parts = [p for p in (rel or "").split("/") if p]
    if any(p in (".", "..") for p in parts):
        raise OSError("not a plain relative path: %r" % (rel,))
    return parts


def open_dir(root, rel, make):
    """The descriptor of <root>/<rel>, which the caller closes. `make` creates what is missing and forces the
    directory that will hold the files -- the last component, and any component it created -- to 0700 (fchmod of the
    vetted descriptor; a directory that already existed higher up, `.heimdall` itself, keeps the mode it has); a
    reader passes False and creates and changes nothing."""
    fd = os.open(os.path.realpath(root), os.O_RDONLY | os.O_DIRECTORY)
    try:
        _vet_dir(fd, root)
        parts = _components(rel)
        for i, name in enumerate(parts):
            below, created = _step(fd, name, make)
            os.close(fd)
            fd = below
            if make and (created or i == len(parts) - 1):
                os.fchmod(fd, 0o700)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _plain_name(name):
    if not name or name in (".", "..") or "/" in name or "\x00" in name or len(name) > 200:
        raise OSError("not a plain file name: %r" % (name,))
    return name


def _drop(dirfd, name):
    with contextlib.suppress(OSError):
        os.unlink(name, dir_fd=dirfd)


def write_all(fd, data):
    """Write every byte of `data` to the descriptor: a short write is continued, never dropped."""
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def _stage(dirfd, name, data):
    """Write `data` to a fresh temp file beside `name` (0600, never an existing file, never through a link); the
    temp's name is returned."""
    tmp = "%s.tmp-%s" % (name, os.urandom(4).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dirfd)
    try:
        os.fchmod(fd, 0o600)
        write_all(fd, data)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        _drop(dirfd, tmp)
        raise
    os.close(fd)
    return tmp


def write(root, rel, name, data):
    """Write `data` (bytes) as <root>/<rel>/<name>, replacing whatever is there (a link included, which is replaced,
    never written through). OSError when anything on the way is a link, a plain file, or another account's."""
    _plain_name(name)
    dirfd = open_dir(root, rel, True)
    try:
        tmp = _stage(dirfd, name, data)
        try:
            os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        except OSError:
            _drop(dirfd, tmp)
            raise
    finally:
        os.close(dirfd)


def create_once(root, rel, name, data):
    """Write `data` as <root>/<rel>/<name> only if nothing is there (link(2): atomic, and it fails where the name is
    taken, a link included). FileExistsError when it was already there; the loser of a race reads the winner's."""
    _plain_name(name)
    dirfd = open_dir(root, rel, True)
    try:
        tmp = _stage(dirfd, name, data)
        try:
            os.link(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd, follow_symlinks=False)
        finally:
            _drop(dirfd, tmp)
    finally:
        os.close(dirfd)


def _open_vetted(root, rel, name, flags, what):
    """The descriptor of <root>/<rel>/<name> opened with `flags` (O_WRONLY, plus O_APPEND when asked): the file is made
    (0600) when it is missing, opened WITHOUT following a link inside the vetted directory, checked (fstat of what was
    actually opened) to be a regular file this process owns, and forced to 0600 with fchmod of that descriptor -- never
    chmod of a path. O_NONBLOCK: the open cannot hang a hook on a FIFO."""
    _plain_name(name)
    dirfd = open_dir(root, rel, True)
    try:
        fd = os.open(name, flags | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=dirfd)
    finally:
        os.close(dirfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise OSError("%s is not %s of ours" % (name, what))
        os.fchmod(fd, 0o600)
    except BaseException:
        os.close(fd)
        raise
    return fd


def open_lockfile(root, rel, name):
    """The descriptor of <root>/<rel>/<name>, which the caller flocks and closes. The file is made (0600) when it is
    missing, opened WITHOUT following a link inside the vetted directory, checked (fstat of what was actually opened) to
    be a regular file this process owns, and forced to 0600 with fchmod of that descriptor -- never chmod of a path.
    OSError, with nothing created, changed or locked, when anything on the way is a link, a plain file or another
    account's, or when the name is a directory, a link (a dangling one is not created through) or a FIFO (O_NONBLOCK:
    the open cannot hang the hook on one)."""
    return _open_vetted(root, rel, name, os.O_WRONLY, "a lock file")


@contextlib.contextmanager
def lock(root, rel, name):
    """An exclusive flock on <root>/<rel>/<name> (open_lockfile: the same refusals) held for the body of a with
    statement and dropped when it ends, an exception included. Two openers of one name share one inode, so the lock
    excludes."""
    fd = open_lockfile(root, rel, name)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # closing the descriptor drops the lock


def open_append(root, rel, name):
    """The descriptor of <root>/<rel>/<name> for appending, which the caller closes: made 0600 when missing, never
    reached through a link, a regular file of ours (open_lockfile's refusals). A caller that must not claim anything
    before its destination is known to be writable opens it first and writes with write_all()."""
    return _open_vetted(root, rel, name, os.O_WRONLY | os.O_APPEND, "a file")


def _append(root, rel, name, data):
    fd = open_append(root, rel, name)
    try:
        write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def append(root, rel, name, data, lock_name=None):
    """Append `data` (bytes) to <root>/<rel>/<name> and fsync it. With `lock_name` the write is made while holding the
    exclusive flock on <root>/<rel>/<lock_name> (see lock()): append with a lock. OSError, with nothing written, when
    anything on the way is a link, a plain file or another account's."""
    if lock_name is None:
        _append(root, rel, name, data)
        return
    with lock(root, rel, lock_name):
        _append(root, rel, name, data)


def truncate(root, rel, name):
    """Empty <root>/<rel>/<name> in place -- ftruncate of the vetted descriptor, so the file keeps its inode, which a
    lockless writer may hold open -- and force it to 0600. True when it was emptied, False when it is not there. OSError
    when anything on the way is a link, a plain file or another account's, or when the name is a link, a directory, a FIFO
    or not ours: nothing behind a link is truncated or chmod'ed."""
    _plain_name(name)
    dirfd = open_dir(root, rel, False)
    try:
        try:
            fd = os.open(name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dirfd)
        except FileNotFoundError:
            return False
    finally:
        os.close(dirfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise OSError("%s is not a file of ours" % name)
        os.ftruncate(fd, 0)
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)
    return True


def rename(root, rel, src, dst):
    """Rename <root>/<rel>/<src> to <root>/<rel>/<dst> inside the vetted directory, replacing what is at <dst>: a link
    there is replaced, never written through, and a link at <src> moves as a link. OSError when the way is not plain
    directories of ours or <src> is missing."""
    _plain_name(src)
    _plain_name(dst)
    dirfd = open_dir(root, rel, False)
    try:
        os.replace(src, dst, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    finally:
        os.close(dirfd)


def open_read(root, rel, name, forbidden=0o077, dir_forbidden=0):
    """A read-only descriptor of <root>/<rel>/<name>, which the caller closes, or None when it is missing or not to be
    trusted: reached through a link, not a regular file (a FIFO is refused without blocking), not ours, carrying any of the
    mode bits in `forbidden` (default 0o077: only a 0600 file), or held in a directory carrying any of the bits in
    `dir_forbidden`. Both mode checks are made on the descriptors actually opened. Creates nothing."""
    try:
        _plain_name(name)
        dirfd = open_dir(root, rel, False)
    except OSError:
        return None
    try:
        if os.fstat(dirfd).st_mode & dir_forbidden:
            return None
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dirfd)
    except OSError:
        return None
    finally:
        os.close(dirfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & forbidden:
            os.close(fd)
            return None
    except OSError:
        os.close(fd)
        return None
    return fd


def read(root, rel, name, limit=READ_LIMIT, forbidden=0o077, dir_forbidden=0):
    """The bytes of <root>/<rel>/<name>, or None when it is missing or not to be trusted: reached through a link, not
    a regular file (a FIFO is refused without blocking), not ours, carrying any of the mode bits in `forbidden`, larger
    than `limit`, or held in a directory carrying any of the bits in `dir_forbidden`. `forbidden` defaults to 0o077, so
    only a 0600 file passes; a caller that needs "nobody else can write it" passes 0o022, one that needs nothing beyond
    "ours" passes 0. `dir_forbidden` defaults to 0 (the directory's mode is not judged); 0o022 refuses a directory
    somebody else could swap the file in. Both mode checks are made on the descriptors actually opened. Creates
    nothing."""
    fd = open_read(root, rel, name, forbidden, dir_forbidden)
    if fd is None:
        return None
    try:
        size = os.fstat(fd).st_size
        if size > limit:
            return None
        return os.read(fd, min(limit, size))
    except OSError:
        return None
    finally:
        os.close(fd)


def read_json(root, rel, name, limit=READ_LIMIT, forbidden=0o077, dir_forbidden=0):
    """read(), parsed: the object, or None for anything that is not a JSON object."""
    raw = read(root, rel, name, limit, forbidden, dir_forbidden)
    if raw is None:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def stat_file(root, rel, name):
    """The os.stat_result of <root>/<rel>/<name>, taken from the vetted directory without following a link, when that
    is a regular file this process owns; None when it is missing, a link or anything else, not ours, or the way to it is
    not a plain directory of ours. Creates nothing. For a caller that needs a marker's mtime and none of its content."""
    try:
        _plain_name(name)
        dirfd = open_dir(root, rel, False)
    except OSError:
        return None
    try:
        st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except OSError:
        return None
    finally:
        os.close(dirfd)
    return st if stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() else None


def names(root, rel):
    """The names in <root>/<rel>, sorted: [] when it is missing or the way to it is not a plain directory of ours. The
    names are only names -- read() and read_json() vet each file before anything is believed. Creates nothing."""
    try:
        dirfd = open_dir(root, rel, False)
    except OSError:
        return []
    try:
        return sorted(os.listdir(dirfd))
    except OSError:
        return []
    finally:
        os.close(dirfd)


def remove(root, rel, name):
    """Unlink <root>/<rel>/<name> (a link goes as a link, never followed) through the vetted directory. True when it
    went; False when it was not there or the way to it is not a plain directory of ours."""
    try:
        _plain_name(name)
        dirfd = open_dir(root, rel, False)
    except OSError:
        return False
    try:
        os.unlink(name, dir_fd=dirfd)
    except OSError:
        return False
    finally:
        os.close(dirfd)
    return True


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(prog="hmd_private_state.py", description=__doc__.split("\n")[0])
    parser.add_argument("action", choices=("write", "remove"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--rel", default="")
    parser.add_argument("--name", required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == "write":
            write(args.root, args.rel, args.name, sys.stdin.buffer.read(1 << 20))
        else:
            remove(args.root, args.rel, args.name)
    except OSError as exc:
        print("hmd_private_state: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
