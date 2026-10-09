#!/usr/bin/env bash
# hmd-private-state.test.sh -- bin/lib/hmd_private_state.py: open_lockfile(), stat_file() and read()'s `forbidden` /
# `dir_forbidden` bits, added so bin/heimdall-inbox-wake can route every lock-open, stat and read of its repo state
# through the one hardened walk.
# Oracle: none of them follows a link at ANY level (root/.heimdall, .heimdall/ui, .heimdall/ui/wake, the file itself),
# creates, changes or chmods anything outside the vetted directory, or hangs on a planted FIFO; a lock file is made 0600 in
# 0700 directories and is the same inode for every opener (so flock excludes); read() stays strict by default (0600 only)
# and honours the looser bits a caller asks for. Own-file run only. Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/hmd_private_state.py"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$LIB" "$WORK" > "$WORK/driver.out" 2>&1 <<'PYDRIVER'
import fcntl, importlib.util, os, signal, stat, subprocess, sys, tempfile

lib, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("hmd_private_state", lib)
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)
os.umask(0o022)

REL = ".heimdall/ui/wake"
LEVELS = (".heimdall", ".heimdall/ui", ".heimdall/ui/wake")


class Hang(Exception):
    """Raised by the alarm when a call blocks (a planted FIFO)."""


def on_alarm(signum, frame):
    raise Hang("blocked on a planted FIFO")


signal.signal(signal.SIGALRM, on_alarm)
cases = []


def case(label):
    def register(fn):
        cases.append((label, fn))
        return fn
    return register


def put(path, data, mode):
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, mode)


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def tree():
    """A repo root holding .heimdall/ui/wake (0700) with a 0600 `mark` and `f` in it, and a victim directory OUTSIDE it
    with one 0644 file."""
    base = tempfile.mkdtemp(prefix="t.", dir=work)
    root = os.path.join(base, "repo")
    os.makedirs(os.path.join(root, REL), mode=0o700)
    put(os.path.join(root, REL, "mark"), b"x", 0o600)
    put(os.path.join(root, REL, "f"), b"hello", 0o600)
    victim = os.path.join(base, "victim")
    os.mkdir(victim, 0o755)
    put(os.path.join(victim, "foreign"), b"SENTINEL", 0o644)
    return root, victim


def linked(level):
    """tree() with `level` moved out into the victim directory and a symlink left where it was."""
    root, victim = tree()
    src, dst = os.path.join(root, level), os.path.join(victim, "moved")
    os.rename(src, dst)
    os.symlink(dst, src)
    return root, victim


def snap(path):
    rows = ["ROOT %o %d" % (os.lstat(path).st_mode, os.lstat(path).st_mtime_ns)]
    for dp, dns, fns in os.walk(path):
        for n in dns + fns:
            p = os.path.join(dp, n)
            st = os.lstat(p)
            body = open(p, "rb").read() if stat.S_ISREG(st.st_mode) else b""
            rows.append("%s %o %d %d %r" % (os.path.relpath(p, path), st.st_mode, st.st_size, st.st_mtime_ns, body))
    return sorted(rows)


def refused(fn, *args, **kw):
    try:
        fn(*args, **kw)
    except OSError:
        return True
    return False


# ---- open_lockfile ----------------------------------------------------------------------------------------------

@case("open_lockfile: creates <rel>/<name> 0600 inside 0700 directories it made, whatever the umask")
def _():
    for um in (0o022, 0o000):
        old = os.umask(um)
        try:
            base = tempfile.mkdtemp(prefix="c.", dir=work)
            root = os.path.join(base, "repo")
            os.mkdir(root, 0o755)
            fd = ps.open_lockfile(root, REL, "7.lock")
            try:
                dirs = [mode(os.path.join(root, d)) for d in LEVELS]
                same = os.path.samestat(os.fstat(fd), os.stat(os.path.join(root, REL, "7.lock")))
                if stat.S_IMODE(os.fstat(fd).st_mode) != 0o600 or dirs != [0o700] * 3 or not same:
                    return False
            finally:
                os.close(fd)
        finally:
            os.umask(old)
    return True


@case("open_lockfile: an existing looser lock file is tightened to 0600 and is the same inode")
def _():
    root, _victim = tree()
    p = os.path.join(root, REL, "9.lock")
    put(p, b"", 0o644)
    before = os.stat(p).st_ino
    fd = ps.open_lockfile(root, REL, "9.lock")
    try:
        return mode(p) == 0o600 and os.fstat(fd).st_ino == before
    finally:
        os.close(fd)


@case("open_lockfile: two openers share one lock -- flock on one excludes the other")
def _():
    root, _victim = tree()
    a = ps.open_lockfile(root, REL, "3.lock")
    b = ps.open_lockfile(root, REL, "3.lock")
    try:
        fcntl.flock(a, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            fcntl.flock(b, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        return False
    finally:
        os.close(a)
        os.close(b)


@case("open_lockfile: the root is opened by its real path (a link AT the root is the caller's own choice)")
def _():
    root, _victim = tree()
    alias = root + "-alias"
    os.symlink(root, alias)
    os.close(ps.open_lockfile(alias, REL, "5.lock"))
    return os.path.exists(os.path.join(root, REL, "5.lock"))


@case("open_lockfile: a dangling link at the name is refused and its target is not created")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "not-there"), os.path.join(root, REL, "1.lock"))
    before = snap(victim)
    return refused(ps.open_lockfile, root, REL, "1.lock") and not os.path.exists(os.path.join(victim, "not-there")) and snap(victim) == before


@case("open_lockfile: a link at the name to an existing foreign file is refused; the file keeps its bytes, mode and mtime")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "foreign"), os.path.join(root, REL, "1.lock"))
    before = snap(victim)
    return refused(ps.open_lockfile, root, REL, "1.lock") and snap(victim) == before


def _lock_level(level):
    @case("open_lockfile: a link at %s is refused; nothing behind it is created, chmod'ed or opened" % level)
    def _():
        root, victim = linked(level)
        before = snap(victim)
        return refused(ps.open_lockfile, root, REL, "1.lock") and snap(victim) == before


for _level in LEVELS:
    _lock_level(_level)


@case("open_lockfile: a directory at the name is refused")
def _():
    root, _victim = tree()
    os.mkdir(os.path.join(root, REL, "1.lock"))
    return refused(ps.open_lockfile, root, REL, "1.lock")


@case("open_lockfile: a FIFO at the name is refused at once (the open cannot hang a hook)")
def _():
    root, _victim = tree()
    os.mkfifo(os.path.join(root, REL, "1.lock"))
    signal.alarm(5)
    try:
        return refused(ps.open_lockfile, root, REL, "1.lock")
    finally:
        signal.alarm(0)


@case("open_lockfile: a name with a slash or a dot-dot is refused")
def _():
    root, _victim = tree()
    return all(refused(ps.open_lockfile, root, REL, bad) for bad in ("../x", "a/b", "..", ""))


# ---- stat_file --------------------------------------------------------------------------------------------------

@case("stat_file: the stat of a regular file of ours")
def _():
    root, _victim = tree()
    st = ps.stat_file(root, REL, "mark")
    return st is not None and stat.S_ISREG(st.st_mode) and st.st_mtime == os.stat(os.path.join(root, REL, "mark")).st_mtime


@case("stat_file: None for a missing file and for a directory at the name")
def _():
    root, _victim = tree()
    os.mkdir(os.path.join(root, REL, "adir"))
    return ps.stat_file(root, REL, "nope") is None and ps.stat_file(root, REL, "adir") is None


@case("stat_file: None for a link at the name, even to a fresh regular file of ours")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "foreign"), os.path.join(root, REL, "link"))
    return ps.stat_file(root, REL, "link") is None


def _stat_level(level):
    @case("stat_file: None when %s is a link" % level)
    def _():
        root, _victim = linked(level)
        return ps.stat_file(root, REL, "mark") is None


for _level in LEVELS:
    _stat_level(_level)


# ---- read: forbidden / dir_forbidden ----------------------------------------------------------------------------

def readable(fmode, dmode=None, **kw):
    root, _victim = tree()
    put(os.path.join(root, REL, "f"), b"hello", fmode)
    if dmode is not None:
        os.chmod(os.path.join(root, REL), dmode)
    return ps.read(root, REL, "f", **kw)


@case("read: strict by default -- a 0600 file is read, a 0644 one is not")
def _():
    return readable(0o600) == b"hello" and readable(0o644) is None


@case("read: forbidden=0o022 reads a 0644 file and still refuses a group- or world-writable one")
def _():
    return readable(0o644, forbidden=0o022) == b"hello" and readable(0o664, forbidden=0o022) is None and readable(0o666, forbidden=0o022) is None


@case("read: forbidden=0 reads any file of ours")
def _():
    return readable(0o666, forbidden=0) == b"hello"


@case("read: dir_forbidden=0o022 refuses a file held in a group- or world-writable directory; 0700 and 0755 are fine")
def _():
    return (readable(0o600, 0o777, dir_forbidden=0o022) is None and readable(0o600, 0o775, dir_forbidden=0o022) is None
            and readable(0o600, 0o700, dir_forbidden=0o022) == b"hello" and readable(0o600, 0o755, dir_forbidden=0o022) == b"hello")


@case("read: without dir_forbidden the directory's mode is not judged (the old behaviour)")
def _():
    return readable(0o600, 0o777) == b"hello"


@case("read: a file larger than limit is not read; one exactly at the limit is")
def _():
    root, _victim = tree()
    return ps.read(root, REL, "f", limit=4) is None and ps.read(root, REL, "f", limit=5) == b"hello"


@case("read_json: passes forbidden and dir_forbidden through")
def _():
    root, _victim = tree()
    put(os.path.join(root, REL, "j"), b'{"a": 1}', 0o644)
    return (ps.read_json(root, REL, "j") is None and ps.read_json(root, REL, "j", forbidden=0o022) == {"a": 1}
            and ps.read_json(root, REL, "j", forbidden=0o022, dir_forbidden=0o700) is None)


@case("read: a link at the name is not followed")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "foreign"), os.path.join(root, REL, "link"))
    return ps.read(root, REL, "link", forbidden=0) is None


def _read_level(level):
    @case("read: None when %s is a link" % level)
    def _():
        root, _victim = linked(level)
        return ps.read(root, REL, "f", forbidden=0) is None


for _level in LEVELS:
    _read_level(_level)


@case("read: a FIFO at the name returns None at once (the open cannot hang a hook)")
def _():
    root, _victim = tree()
    os.mkfifo(os.path.join(root, REL, "fifo"))
    signal.alarm(5)
    try:
        return ps.read(root, REL, "fifo", forbidden=0) is None
    finally:
        signal.alarm(0)


# ---- ensure_dir / append (+ rotation) / the CLI's read and ensure -----------------------------------------------------
# The relay client's event log (append + one-generation rotation), the status file, connect.json and the pair window all go
# through these: none of them may follow a link at any level, at the file name or at the rotation name.

def _ensure_level(level):
    @case("ensure_dir: refused when %s is a link, nothing created or chmod'ed behind it" % level)
    def _():
        root, victim = linked(level)
        before = snap(victim)
        return refused(ps.ensure_dir, root, REL) and snap(victim) == before


for _level in LEVELS:
    _ensure_level(_level)


@case("ensure_dir: makes a missing chain 0700 and is a no-op the second time")
def _():
    base = tempfile.mkdtemp(prefix="e.", dir=work)
    root = os.path.join(base, "repo")
    os.mkdir(root, 0o755)
    ps.ensure_dir(root, REL)
    ps.ensure_dir(root, REL)
    return [mode(os.path.join(root, d)) for d in LEVELS] == [0o700] * 3


@case("append: creates the file 0600 in 0700 directories, and a second append adds to the first")
def _():
    base = tempfile.mkdtemp(prefix="a.", dir=work)
    root = os.path.join(base, "repo")
    os.mkdir(root, 0o755)
    ps.append(root, REL, "log", b"one\n")
    ps.append(root, REL, "log", b"two\n")
    p = os.path.join(root, REL, "log")
    return open(p, "rb").read() == b"one\ntwo\n" and mode(p) == 0o600 and [mode(os.path.join(root, d)) for d in LEVELS] == [0o700] * 3


@case("append: an existing 0644 file is tightened to 0600 and kept")
def _():
    root, _victim = tree()
    p = os.path.join(root, REL, "log")
    put(p, b"old\n", 0o644)
    ps.append(root, REL, "log", b"new\n")
    return open(p, "rb").read() == b"old\nnew\n" and mode(p) == 0o600


@case("append: a link at the name is refused and the file it points at is untouched")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "foreign"), os.path.join(root, REL, "log"))
    before = snap(victim)
    return refused(ps.append, root, REL, "log", b"x\n") and snap(victim) == before


def _append_level(level):
    @case("append: refused when %s is a link, nothing written behind it" % level)
    def _():
        root, victim = linked(level)
        before = snap(victim)
        return refused(ps.append, root, REL, "f", b"x\n", rotate_at=1) and snap(victim) == before


for _level in LEVELS:
    _append_level(_level)


@case("append: rotates to <name>.1 once the file holds rotate_at bytes (clobbering the old .1) and starts a fresh file")
def _():
    root, _victim = tree()
    p = os.path.join(root, REL, "log")
    put(p, b"A" * 10, 0o600)
    put(p + ".1", b"stale-generation", 0o600)
    ps.append(root, REL, "log", b"fresh\n", rotate_at=10)
    ps.append(root, REL, "log", b"more\n", rotate_at=10)
    return (open(p + ".1", "rb").read() == b"A" * 10 and open(p, "rb").read() == b"fresh\nmore\n"
            and mode(p) == 0o600 and mode(p + ".1") == 0o600)


@case("append: below rotate_at nothing is rotated")
def _():
    root, _victim = tree()
    p = os.path.join(root, REL, "log")
    put(p, b"A" * 9, 0o600)
    ps.append(root, REL, "log", b"x", rotate_at=10)
    return open(p, "rb").read() == b"A" * 9 + b"x" and not os.path.exists(p + ".1")


@case("append: a link planted at <name>.1 is replaced by the rotation, never written through")
def _():
    root, victim = tree()
    p = os.path.join(root, REL, "log")
    put(p, b"A" * 10, 0o600)
    os.symlink(os.path.join(victim, "foreign"), p + ".1")
    ps.append(root, REL, "log", b"fresh\n", rotate_at=10)
    return (open(os.path.join(victim, "foreign"), "rb").read() == b"SENTINEL" and not os.path.islink(p + ".1")
            and open(p + ".1", "rb").read() == b"A" * 10 and open(p, "rb").read() == b"fresh\n")


@case("append: a FIFO at the name is refused at once (the open cannot hang the client)")
def _():
    root, _victim = tree()
    os.mkfifo(os.path.join(root, REL, "fifo"))
    signal.alarm(5)
    try:
        return refused(ps.append, root, REL, "fifo", b"x\n")
    finally:
        signal.alarm(0)


def cli(*args, stdin=b""):
    return subprocess.run([sys.executable, "-I", lib] + list(args), input=stdin, capture_output=True, timeout=30)


@case("cli read: prints a 0600 file and exits 0; a 0644 file needs --forbidden 022")
def _():
    root, _victim = tree()
    put(os.path.join(root, REL, "j"), b'{"a": 1}', 0o600)
    put(os.path.join(root, REL, "k"), b'{"b": 2}', 0o644)
    ok_read = cli("read", "--root", root, "--rel", REL, "--name", "j")
    strict = cli("read", "--root", root, "--rel", REL, "--name", "k")
    loose = cli("read", "--root", root, "--rel", REL, "--name", "k", "--forbidden", "022")
    return (ok_read.returncode == 0 and ok_read.stdout == b'{"a": 1}' and strict.returncode == 1 and strict.stdout == b""
            and loose.returncode == 0 and loose.stdout == b'{"b": 2}')


@case("cli read: a missing file, a link at the name and a link at any level print nothing and exit 1")
def _():
    root, victim = tree()
    os.symlink(os.path.join(victim, "foreign"), os.path.join(root, REL, "link"))
    runs = [cli("read", "--root", root, "--rel", REL, "--name", n, "--forbidden", "0") for n in ("absent", "link")]
    for level in LEVELS:
        lroot, _v = linked(level)
        runs.append(cli("read", "--root", lroot, "--rel", REL, "--name", "f", "--forbidden", "0"))
    return all(r.returncode == 1 and r.stdout == b"" for r in runs)


@case("cli read: --limit refuses a bigger file")
def _():
    root, _victim = tree()
    put(os.path.join(root, REL, "big"), b"x" * 100, 0o600)
    small = cli("read", "--root", root, "--rel", REL, "--name", "big", "--limit", "99")
    exact = cli("read", "--root", root, "--rel", REL, "--name", "big", "--limit", "100")
    return small.returncode == 1 and small.stdout == b"" and exact.returncode == 0 and len(exact.stdout) == 100


@case("cli ensure: creates the chain 0700 (exit 0); a link at any level exits 1 and creates nothing behind it")
def _():
    base = tempfile.mkdtemp(prefix="n.", dir=work)
    root = os.path.join(base, "repo")
    os.mkdir(root, 0o755)
    made = cli("ensure", "--root", root, "--rel", REL)
    good = made.returncode == 0 and [mode(os.path.join(root, d)) for d in LEVELS] == [0o700] * 3
    for level in LEVELS:
        lroot, lvictim = linked(level)
        before = snap(lvictim)
        r = cli("ensure", "--root", lroot, "--rel", REL)
        good = good and r.returncode == 1 and snap(lvictim) == before
    return good


failures = 0
for label, fn in cases:
    try:
        good = fn()
    except Exception as exc:
        print("FAIL %s  [%s: %s]" % (label, type(exc).__name__, exc))
        failures += 1
        continue
    print(("PASS " if good else "FAIL ") + label)
    failures += 0 if good else 1
sys.exit(1 if failures else 0)
PYDRIVER
DRC=$?

while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) printf '  %s\n' "$line" ;;
  esac
done < "$WORK/driver.out"
[ "$DRC" -eq 0 ] || [ "$FAIL" -gt 0 ] || bad "driver exited $DRC with no verdict line"

echo ""
echo "hmd-private-state.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
