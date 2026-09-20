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
import os
import re
import subprocess
import sys
import time
import uuid

MAX_TEXT_CHARS = 2000
INBOX_REL = os.path.join(".heimdall", "ui", "inbox.jsonl")
DELIVERED_REL = os.path.join(".heimdall", "ui", "inbox-delivered.jsonl")
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
    """A message failed validation. `code` is the short machine-readable reason
    (empty|too-long|secret-shaped|invalid-type) the HTTP layer maps onto a status
    code; the message names the rule, never echoes the offending text."""

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


def list_pending(root):
    """Every valid pending message, oldest first (inbox.jsonl is append-only, so
    file order IS delivery order). Never mutates the file; a corrupt or
    non-object line is dropped, never raised."""
    records, _ = _read_all(_inbox_path(root))
    return records


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
    written on a validation failure, and the exception never carries `text`."""
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
        with _open_append_0600(path) as f:
            f.write(line)
            f.flush()
            os.fsync(f.fileno())
    return record


def pop_all(root):
    """Deliver every pending message: append the current inbox.jsonl content to
    inbox-delivered.jsonl and truncate inbox.jsonl to empty, under the SAME lock
    append() takes. Returns the list of delivered records (oldest first); []
    when nothing was pending (and nothing is touched on disk in that case)."""
    path = _inbox_path(root)
    delivered_path = _delivered_path(root)
    with _FlockCtx(_lock_path(root)):
        records, raw_lines = _read_all(path)
        if not raw_lines:
            return []
        _ensure_dir(os.path.dirname(delivered_path))
        with _open_append_0600(delivered_path) as df:
            df.writelines(raw_lines)
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
    return records


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
