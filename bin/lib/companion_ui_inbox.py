#!/usr/bin/env python3
"""companion_ui_inbox.py -- the inbox for `hmd ui`'s POST /api/send (companion app ->
running Claude Code session messages).

The companion app POSTs {"text": str} to /api/send (sentinels/hmd-ui.py); this module
is the ONE place the message contract, the size/secret validation and the on-disk
queue live -- the server's POST handler and the `hmd ui inbox` CLI both import it, so
neither can drift from the other. Mirrors bin/lib/companion_ui_panels.py's role for
job panels exactly (single-file contract, imported by both writer and reader).

Message file: one JSON object per line, appended to
<repo>/.heimdall/ui/inbox.jsonl:
    {"id": str (uuid4), "ts": float (epoch), "text": str, "source": "companion"}

Validation (append() -- nothing is ever written on a failure):
    - text is first run through _strip_control_chars() (control/escape bytes
      gone, \n and \t kept) -- the same byte class bin/heimdall-inbox-deliver's
      own sanitize() strips, so a phone message can never carry a raw ANSI/OSC
      escape into a terminal via `hmd ui inbox ls|peek` (_print_rows and
      _cmd_peek sanitize again on the read side, as defense in depth for a
      row written by an older version)
    - text must be a string, and non-empty after stripping whitespace
    - text must be <= MAX_TEXT_CHARS characters
    - text must not be secret_shaped() (bin/heimdall-activity's own family, ported
      the same way companion_ui_panels.py ports it -- see secret_shaped() below)
A rejected message is never partially written, and the raised error never carries
the offending text -- only the field/rule name (InboxError.code).

Delivery: `pop_all()` moves every pending line to
<repo>/.heimdall/ui/inbox-delivered.jsonl (append) and truncates inbox.jsonl to
empty, under the SAME lock append() takes -- a message can never be observed as
both pending and delivered, and a message appended mid-pop is never lost.

Receipts (A2): pop_all() stamps every archived message with `delivered_at` (epoch
seconds of that pop), so the archive is also the delivery receipt log. summary() is
the `inbox` slice /api/state serves -- {pending, consumer, oldest_age_s, delivered}
-- where `delivered` is the last 20 archive entries as {id, delivered_at} ONLY, never
text (the id is the uuid POST /api/send returned), and `consumer` is read from
.heimdall/ui/inbox-waiting, the marker bin/heimdall-inbox-deliver's stop long-poll
rewrites every poll while it waits (stale after 2x the poll interval), falling back
to a configured tmux target, then "none". Queued -> delivered is therefore the
message leaving `pending` and its id appearing in `delivered` with a timestamp.

Capacity (N3): a token holder could otherwise POST unbounded 2000-char messages
forever, forcing every /api/state 2s poll and every /api/send to re-parse an
ever-growing inbox.jsonl (O(N^2), unbounded disk). append() now refuses a new
message once MAX_PENDING are already pending -- InboxError("inbox-full"), which
the server's existing `except INBOX.InboxError as e: self._send_json(422,
{"error": e.code})` already maps to 422 with no server-side change needed.
inbox.jsonl itself can never near MAX_INBOX_BYTES this way (MAX_PENDING x
MAX_TEXT_CHARS stays well under it); inbox-delivered.jsonl has no such
structural ceiling (pop_all() is called far more times over a repo's life than
the file is ever read), so it is the one rotated: once it reaches
MAX_INBOX_BYTES, pop_all() moves it to inbox-delivered.jsonl.1 (clobbering any
previous .1 -- single-generation rotation, not a numbered series) before
appending the batch being delivered, so a delivery's own messages always land
in the fresh active file. list_pending()/pending_count() are backed by a
per-process cache keyed on inbox.jsonl's (mtime_ns, size) (_cached_records) --
the 2s /api/state poll and the post-append recount in POST /api/send skip the
reopen+reparse entirely when the file hasn't changed since this process's last
call; any append()/pop_all() from any process changes the file's size, so the
very next call always sees it (the cache can serve one call stale, never
longer).

Locking: one exclusive flock over a dedicated `<inbox>.jsonl.lock` file (never the
data file itself), held for the whole read-modify-write -- the exact convention
bin/lib/work_queue.py's _FlockCtx and bin/lib/cp_team_queue.py's _PartitionLock
already use.

Filesystem permissions: the .heimdall/ui directory is forced to 0700 and
inbox.jsonl / inbox-delivered.jsonl / the lock file to 0600 -- on every
directory-create and every file-open, not just the first, so a directory or
file that predates this fix (0755/0644) self-heals the next time it's touched.
Phone messages are private to the repo owner; no other local account should be
able to read them.

Stdlib only (json, os, re, sys, time, uuid, fcntl, argparse, subprocess) --
Decision 1's zero-toolchain posture, matching companion_ui_panels.py. This file is
deliberately self-contained (secret_shaped and resolve_root are ported, not
imported from companion_ui_panels.py) so bin/heimdall-ui can exec either script
standalone with zero intra-repo import coupling.
"""
import argparse
import fcntl
import json
import math
import os
import re
import subprocess
import sys
import time
import uuid

MAX_TEXT_CHARS = 2000
MAX_PENDING = 200                    # N3: append() refuses a new message at/above this many pending
MAX_INBOX_BYTES = 2 * 1024 * 1024    # N3: inbox-delivered.jsonl rotation threshold (2 MiB)
INBOX_REL = os.path.join(".heimdall", "ui", "inbox.jsonl")
DELIVERED_REL = os.path.join(".heimdall", "ui", "inbox-delivered.jsonl")
WAITING_REL = os.path.join(".heimdall", "ui", "inbox-waiting")      # the stop long-poll's heartbeat marker
TMUX_TARGET_REL = os.path.join(".heimdall", "ui", "tmux-target")
POLL_INTERVAL_S = 2.0                   # bin/heimdall-inbox-deliver's stop long-poll cadence
WAITING_STALE_S = 2 * POLL_INTERVAL_S   # an inbox-waiting older than this: its long-poll is gone
RECEIPTS_LIMIT = 20                     # inbox.delivered[] is the last this-many deliveries
RECEIPTS_TAIL_BYTES = 256 * 1024        # the newest archive lines hold them; never read the whole file
GIT_TIMEOUT_S = 3

# ── secret scrub: bin/heimdall-activity:167-179, ported the same way
# companion_ui_panels.py:63-74 ports it. Order and families are the activity
# record's own; a hit on ANY rejects the message. Kept as its own copy (not an
# import of companion_ui_panels) so this module stays a single standalone file.
_SECRET_RES = (
    re.compile(r"(token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
               r"credential|private[_-]?key)\s*[=:]\s*\S{16,}", re.IGNORECASE),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),                     # GitHub PAT
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),               # other GitHub tokens
    re.compile(r"AKIA[0-9A-Z]{16}"),                        # AWS access key id
    re.compile(r"sk_(live|test)_[A-Za-z0-9]{16,}"),         # Stripe secret
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),            # Slack token
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),       # PEM key
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT
)


def secret_shaped(v):
    """True when `v` matches the secret_shaped() pattern family above."""
    if not isinstance(v, str):
        return False
    return any(rx.search(v) for rx in _SECRET_RES)


# ── control-char / ANSI-OSC scrub (A8): the single write choke-point for a
# phone message strips every non-printable byte before it ever reaches
# inbox.jsonl or a terminal (`hmd ui inbox ls|peek`) -- same byte class
# bin/heimdall-inbox-deliver's own sanitize() strips, so the two halves of
# the pipe agree on one sanitized shape instead of disagreeing (the exact
# A8 finding). \r\n / \r collapse to \n first (never kept as a bare CR,
# which could otherwise hide or overwrite a terminal line); \n and \t
# survive untouched.
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _strip_control_chars(text):
    """Neutralize ANSI/OSC and other control-byte injection (e.g. an OSC 52
    clipboard write or a title-bar rewrite via `hmd ui inbox ls|peek`)."""
    t = text.replace("\r\n", "\n").replace("\r", "\n")
    return _CONTROL_CHARS_RE.sub("", t)


class InboxError(ValueError):
    """A message failed validation, or the queue is full. `code` is the short
    machine-readable reason (empty|too-long|secret-shaped|invalid-type|inbox-full)
    the HTTP layer maps onto a status code; the message names the rule, never
    echoes the offending text."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# ── paths ────────────────────────────────────────────────────────────────────
def _inbox_path(root):
    return os.path.join(root, INBOX_REL)


def _delivered_path(root):
    return os.path.join(root, DELIVERED_REL)


def _lock_path(root):
    return _inbox_path(root) + ".lock"


# ── filesystem permissions (A10): the .heimdall/ui directory and everything
# in it are forced to 0700/0600 on every touch, not just first creation, so
# a directory/file that predates this fix (0755/0644, from os.makedirs()'s
# and open()'s own defaults) self-heals the next time it's touched. Phone
# messages are private to the repo owner -- no other local account should be
# able to read them.
def _ensure_dir(path, mode=0o700):
    """Create `path` (and parents) if missing, then force its mode to `mode`
    regardless of umask or a wider pre-existing mode."""
    os.makedirs(path, exist_ok=True)
    os.chmod(path, mode)


def _open_append_0600(path):
    """Open `path` for text append, creating it at mode 0600 if missing, and
    forcing 0600 even when it already exists (O_CREAT's mode argument is
    only applied -- and only umask-limited -- on the create branch, so a
    file left over from before this fix would otherwise keep its old, wider
    mode forever)."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(path, 0o600)
    return os.fdopen(fd, "a", encoding="utf-8")


class _FlockCtx:
    """A minimal exclusive-flock context manager on a dedicated lock file --
    mirrors bin/lib/work_queue.py's _FlockCtx and bin/lib/cp_team_queue.py's
    _PartitionLock. Held for the whole read-modify-write so append() and
    pop_all() can never interleave. The lock file itself is kept at mode
    0600 (A10), same self-healing chmod-on-every-open as the data files --
    it lives in the same directory and is just as readable by any local
    user if left at a default 0644."""

    def __init__(self, lock_path):
        self.lock_path = lock_path
        self._fh = None

    def __enter__(self):
        _ensure_dir(os.path.dirname(self.lock_path))
        fd = os.open(self.lock_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.chmod(self.lock_path, 0o600)
        self._fh = os.fdopen(fd, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
        finally:
            self._fh.close()
        return False


# ── reading ──────────────────────────────────────────────────────────────────
def _read_all(path):
    """Every line in `path` as (records, raw_lines). A line that fails to parse
    as a JSON object is dropped from `records` (fail-open, matching
    companion_ui_panels.read_panels dropping an invalid panel) but its raw bytes
    stay in `raw_lines` so pop_all() never silently loses a byte of the file --
    an unparsable line is still delivered, just never returned as a record."""
    if not os.path.exists(path):
        return [], []
    records = []
    raw_lines = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            raw_lines.append(line if line.endswith("\n") else line + "\n")
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                records.append(obj)
    return records, raw_lines


_READ_CACHE = {}  # path -> ((mtime_ns, size), records) -- see _cached_records


def _cached_records(path):
    """The records _read_all(path) would return, skipping the reopen+reparse
    when `path`'s (mtime_ns, size) match the last read done by THIS process --
    the O(1)-ish path behind list_pending()/pending_count() (N3): /api/state's
    2s poll and the post-append recount in POST /api/send both call one of
    those on every hit, far more often than inbox.jsonl actually changes.
    Correctness: append()/pop_all() always change the file's size, so a change
    from ANY process is visible on this process's very next call -- the cache
    can serve at most one call stale, never indefinitely. Returns the cached
    list object itself (not a copy) -- internal use only; list_pending() and
    pending_count() are the copy-safe public API built on top of this."""
    try:
        st = os.stat(path)
    except OSError:
        _READ_CACHE.pop(path, None)
        return []
    key = (st.st_mtime_ns, st.st_size)
    cached = _READ_CACHE.get(path)
    if cached is not None and cached[0] == key:
        return cached[1]
    records, _ = _read_all(path)
    _READ_CACHE[path] = (key, records)
    return records


def list_pending(root):
    """Every valid pending message, oldest first (inbox.jsonl is append-only, so
    file order IS delivery order). Never mutates the file; a corrupt or
    non-object line is dropped, never raised. Returns fresh dict copies every
    call, even when served from the _cached_records cache, so a caller can
    never mutate a cached structure."""
    return [dict(r) for r in _cached_records(_inbox_path(root))]


def pending_count(root):
    """len(list_pending(root)) without the per-call dict copies -- the cheap
    count MAX_PENDING enforcement (append()) and an /api/state-style summary
    actually need; O(1)-ish via the same _cached_records cache."""
    return len(_cached_records(_inbox_path(root)))


def peek(root):
    """The single oldest pending message, or None if the inbox is empty.
    Non-destructive -- list_pending()'s head. pop_all() is the only thing that
    dequeues."""
    pending = list_pending(root)
    return pending[0] if pending else None


# ── writing ──────────────────────────────────────────────────────────────────
def append(root, text):
    """Validate `text` and atomically append one message to inbox.jsonl. Returns
    the new record {id, ts, text, source}. Raises InboxError -- nothing is ever
    written on a validation failure (including the queue already being at
    MAX_PENDING), and the exception never carries `text`."""
    if not isinstance(text, str):
        raise InboxError("invalid-type", "text must be a string")
    text = _strip_control_chars(text)
    if not text.strip():
        raise InboxError("empty", "text must be non-empty after stripping whitespace")
    if len(text) > MAX_TEXT_CHARS:
        raise InboxError("too-long", "text exceeds %d characters" % MAX_TEXT_CHARS)
    if secret_shaped(text):
        raise InboxError("secret-shaped",
                         "text looks like it carries a secret/credential (bin/heimdall-activity "
                         "secret_shaped family); refused, nothing written")
    record = {"id": str(uuid.uuid4()), "ts": time.time(), "text": text, "source": "companion"}
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    path = _inbox_path(root)
    _ensure_dir(os.path.dirname(path))
    with _FlockCtx(_lock_path(root)):
        # N3: reject before writing once MAX_PENDING is already reached -- checked
        # under the SAME lock the write itself takes, so two concurrent senders
        # (different threads or processes) can never both observe "under the cap"
        # and jointly push it over.
        if pending_count(root) >= MAX_PENDING:
            raise InboxError("inbox-full",
                             "pending queue is at the %d-message cap; drain it (delivery, or "
                             "`hmd ui inbox pop`) before sending more" % MAX_PENDING)
        with _open_append_0600(path) as f:
            f.write(line)
            f.flush()
            os.fsync(f.fileno())
    return record


def _rotate_if_oversized(path, max_bytes):
    """If `path` already exists at/above `max_bytes`, move it to `<path>.1`
    (clobbering any previous `.1` -- single-generation rotation, not a numbered
    log1/log2/... series) so the next writer starts a fresh file. Called with
    the caller's lock already held, so the rename can never race a concurrent
    writer of the same path. N3: inbox-delivered.jsonl has no structural size
    ceiling the way inbox.jsonl does (MAX_PENDING already bounds that one);
    pop_all() calls this before appending each new batch so the archive can't
    grow without bound over a repo's lifetime."""
    try:
        if os.path.getsize(path) < max_bytes:
            return
    except OSError:
        return
    os.replace(path, path + ".1")


def _stamp_delivered(raw_lines, delivered_at):
    """The archive form of a popped batch: every line that is a JSON object gains
    `delivered_at` (the receipt delivered_receipts() reads back); any other line
    is kept as it was, so a pop never silently loses a byte."""
    out = []
    for line in raw_lines:
        try:
            obj = json.loads(line)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            obj["delivered_at"] = delivered_at
            line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        out.append(line)
    return out


def pop_all(root):
    """Deliver every pending message: append the current inbox.jsonl content to
    inbox-delivered.jsonl -- each message stamped with the `delivered_at` epoch
    of this pop, its delivery receipt -- (rotating it to inbox-delivered.jsonl.1
    first if it's already at MAX_INBOX_BYTES -- see _rotate_if_oversized) and
    truncate inbox.jsonl to empty, under the SAME lock append() takes. Returns
    the list of delivered records, receipt included (oldest first); [] when
    nothing was pending (and nothing is touched on disk, including rotation, in
    that case)."""
    path = _inbox_path(root)
    delivered_path = _delivered_path(root)
    with _FlockCtx(_lock_path(root)):
        records, raw_lines = _read_all(path)
        if not raw_lines:
            return []
        delivered_at = round(time.time(), 3)
        _ensure_dir(os.path.dirname(delivered_path))
        _rotate_if_oversized(delivered_path, MAX_INBOX_BYTES)
        with _open_append_0600(delivered_path) as df:
            df.writelines(_stamp_delivered(raw_lines, delivered_at))
            df.flush()
            os.fsync(df.fileno())
        # Truncate in place, still inside the lock so nothing can land between
        # the read above and this truncate. open(..., "w") already truncates on
        # open; the explicit truncate(0) just says so out loud. chmod after, in
        # case inbox.jsonl predates this fix and still carries a wider mode
        # (A10) -- truncating alone never changes a file's permission bits.
        with open(path, "w", encoding="utf-8") as f:
            f.truncate(0)
        os.chmod(path, 0o600)
    return [dict(r, delivered_at=delivered_at) for r in records]


# ── receipts, consumer, summary: the /api/state `inbox` slice ─────────────────
def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


_RECEIPTS_CACHE = {}  # path -> ((mtime_ns, size), receipts) -- see delivered_receipts


def _read_receipts(path, size):
    """The last RECEIPTS_LIMIT stamped lines of the archive as {id, delivered_at},
    oldest first, reading only its tail. A line that is not a JSON object with a
    string `id` and a finite numeric `delivered_at` -- a pre-receipt archive line,
    a corrupt one -- is skipped, never raised and never given an invented time."""
    with open(path, "rb") as f:
        if size > RECEIPTS_TAIL_BYTES:
            f.seek(size - RECEIPTS_TAIL_BYTES)
            f.readline()  # the seek landed mid-line: drop that partial first line
        chunk = f.read()
    out = []
    for line in chunk.splitlines():
        try:
            obj = json.loads(line.decode("utf-8"))
        except ValueError:  # JSONDecodeError and UnicodeDecodeError both
            continue
        if isinstance(obj, dict) and isinstance(obj.get("id"), str) and _is_number(obj.get("delivered_at")):
            out.append({"id": obj["id"], "delivered_at": obj["delivered_at"]})
    return out[-RECEIPTS_LIMIT:]


def delivered_receipts(root):
    """The delivery receipts /api/state serves as inbox.delivered: the last
    RECEIPTS_LIMIT of inbox-delivered.jsonl as [{"id", "delivered_at"}], oldest
    first -- the uuid POST /api/send returned and the epoch pop_all stamped, and
    NEVER the message text. Cached on the archive's (mtime_ns, size), like
    _cached_records, so the every-request poll costs one stat while nothing is
    delivered. Returns fresh dict copies."""
    path = _delivered_path(root)
    try:
        st = os.stat(path)
    except OSError:
        _RECEIPTS_CACHE.pop(path, None)
        return []
    key = (st.st_mtime_ns, st.st_size)
    cached = _RECEIPTS_CACHE.get(path)
    if cached is None or cached[0] != key:
        try:
            cached = (key, _read_receipts(path, st.st_size))
        except OSError:
            return []
        _RECEIPTS_CACHE[path] = cached
    return [dict(r) for r in cached[1]]


def tmux_target(root):
    """The configured tmux target, or "" -- resolved in the same order (env, then
    .heimdall/ui/tmux-target) bin/heimdall-inbox-deliver's tmux mode uses. In the
    server process the env is the SERVER's, so the file is the durable switch."""
    target = os.environ.get("HMD_TMUX_TARGET", "").strip()
    if target:
        return target
    try:
        with open(os.path.join(root, TMUX_TARGET_REL), "r", encoding="utf-8") as f:
            return f.read(512).strip()
    except (OSError, ValueError):
        return ""


def consumer_state(root, now=None):
    """Who would take the next phone message: "waiting" (a `stop` long-poll is live:
    its inbox-waiting marker was refreshed within WAITING_STALE_S -- twice the poll
    interval, so a killed hook stops counting within seconds), else "tmux" (a tmux
    target is configured), else "none" (the next delivery needs a turn boundary). A
    marker stamped in the future by more than that is clock noise, not a listener."""
    now = time.time() if now is None else now
    try:
        age = now - os.stat(os.path.join(root, WAITING_REL)).st_mtime
    except OSError:
        age = None
    if age is not None and -WAITING_STALE_S <= age <= WAITING_STALE_S:
        return "waiting"
    return "tmux" if tmux_target(root) else "none"


def _oldest_age_s(records, now):
    for r in records:
        ts = r.get("ts")
        if _is_number(ts):
            return round(max(0.0, now - ts), 1)
    return None


def summary(root, now=None):
    """The whole `inbox` slice of /api/state in one call:
    {"pending": n, "consumer": "waiting"|"tmux"|"none", "oldest_age_s": float|None,
    "delivered": [{"id", "delivered_at"}, ...]}. `pending` is read before
    `delivered`, so a message seen as delivered really was; an unreadable source
    degrades its own field (nothing pending / no receipts), never the slice."""
    now = time.time() if now is None else now
    try:
        records = _cached_records(_inbox_path(root))
    except OSError:
        records = []
    return {"pending": len(records),
            "consumer": consumer_state(root, now),
            "oldest_age_s": _oldest_age_s(records, now),
            "delivered": delivered_receipts(root)}


# ── CLI: `hmd ui inbox ls|pop|peek` (exec'd by bin/heimdall-ui) ───────────────
def resolve_root(explicit=None):
    """--repo > HEIMDALL_WATCH_ROOT > git toplevel (bounded) > cwd. Ported from
    companion_ui_panels.resolve_root (same order), inlined so the CLI has no
    import beyond stdlib."""
    if explicit:
        return os.path.realpath(os.path.expanduser(explicit))
    env_root = os.environ.get("HEIMDALL_WATCH_ROOT")
    if env_root:
        return os.path.realpath(os.path.expanduser(env_root))
    try:
        p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           timeout=GIT_TIMEOUT_S, stdin=subprocess.DEVNULL)
        if p.returncode == 0 and p.stdout.strip():
            return os.path.realpath(p.stdout.strip())
    except (OSError, subprocess.SubprocessError, ValueError):
        return os.getcwd()
    return os.getcwd()


def _print_rows(rows, as_json):
    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    if not rows:
        print("no pending messages")
        return
    for r in rows:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r.get("ts", 0)))
        text = _strip_control_chars(str(r.get("text", "")))
        print("%s  %s  %s" % (r.get("id", "?"), ts, text))


def _cmd_ls(args):
    _print_rows(list_pending(resolve_root(args.repo)), args.json)
    return 0


def _cmd_pop(args):
    _print_rows(pop_all(resolve_root(args.repo)), args.json)
    return 0


def _cmd_peek(args):
    r = peek(resolve_root(args.repo))
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0
    if r is None:
        print("no pending messages")
        return 0
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r.get("ts", 0)))
    print("%s  %s  %s" % (r.get("id", "?"), ts, _strip_control_chars(str(r.get("text", "")))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd ui inbox",
                                 description="list/deliver/peek companion -> session messages "
                                             "(the POST /api/send queue)")
    ap.add_argument("--repo", help="repo root (default: HEIMDALL_WATCH_ROOT, git toplevel, or cwd)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("ls", help="list every pending (undelivered) message")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(fn=_cmd_ls)
    pop = sub.add_parser("pop", help="deliver (dequeue) every pending message")
    pop.add_argument("--json", action="store_true")
    pop.set_defaults(fn=_cmd_pop)
    pk = sub.add_parser("peek", help="show the oldest pending message without delivering it")
    pk.add_argument("--json", action="store_true")
    pk.set_defaults(fn=_cmd_peek)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except OSError as e:
        sys.stderr.write("hmd ui inbox: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
