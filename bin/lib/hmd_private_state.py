#!/usr/bin/env python3
"""hmd_private_state.py -- small state files that only this user may read or change, written and read without ever
following a link (stdlib only).

WHY THIS EXISTS. Files hmd keeps under <repo>/.heimdall/ -- the session record the SessionStart hook writes, the
marker a paired phone leaves for the statusline, the pair window's state -- live in a tree a repository controls: a
cloned repo can carry `.heimdall` or `.heimdall/app` as a symlink, or a ready-made `session.json`. A plain
open()/chmod()/rename() through such a path writes, or chmods, wherever the link points, and a plain read trusts
whatever a checkout planted. The pattern here is bin/lib/companion_attach.py's (_open_attachments, after its
security review), applied to a directory chosen by the caller:

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

The root itself is opened by its real path (the caller named it; /var -> /private/var and the like are fine).

CLI (for the shell tools, so a state file never goes through a shell redirection):
    python3 hmd_private_state.py write  --root DIR --rel REL --name NAME     the file's bytes on stdin
    python3 hmd_private_state.py remove --root DIR --rel REL --name NAME
exit 0 done, 1 refused or failed (the reason on stderr), 2 usage.
"""
import contextlib
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


def _stage(dirfd, name, data):
    """Write `data` to a fresh temp file beside `name` (0600, never an existing file, never through a link); the
    temp's name is returned."""
    tmp = "%s.tmp-%s" % (name, os.urandom(4).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dirfd)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
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


def read(root, rel, name, limit=READ_LIMIT):
    """The bytes of <root>/<rel>/<name>, or None when it is missing or not to be trusted: reached through a link, not
    a regular file, not ours, readable or writable by group or other, or larger than `limit`. Creates nothing."""
    try:
        _plain_name(name)
        dirfd = open_dir(root, rel, False)
    except OSError:
        return None
    try:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
        except OSError:
            return None
        try:
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077
                    or st.st_size > limit):
                return None
            return os.read(fd, limit)
        except OSError:
            return None
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def read_json(root, rel, name, limit=READ_LIMIT):
    """read(), parsed: the object, or None for anything that is not a JSON object."""
    raw = read(root, rel, name, limit)
    if raw is None:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


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
