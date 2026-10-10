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
plus, only on a message received while hmd was waiting on a question, the stamp
    "answers": str (that question's attention id, "a-<10 hex>"), "sig": str (64 hex: the seal over the record)
-- see Answers, below.

Answers (the phone's reply to a question hmd is waiting on): append() asks
bin/lib/companion_ui_attention.py what is open right now -- the SAME derivation the phone's own `attention`
slice is read from -- and when that is a question (state needs_input, kind question) stamps the record with the
episode id as "answers", and SEALS it: "sig" is HMAC-SHA256 over exactly (id, ts, text, answers) under a per-machine
key at $HEIMDALL_HOME/app/inbox-answer.key (0600, in a 0700 directory, outside every repo; made here on first use).
The question's text is not stored: bin/heimdall-inbox-deliver derives it at delivery from the session's own
attention state. The stamp is set HERE, at receive time, from what hmd itself derives: never from a
field the sender supplied and never from the message text. And only on the E2E-paired channel: append() stamps
only when it runs INSIDE the relay client of this repo (connect.json's pid_client is this process), where a
command is a frame that opened under the paired device's session key -- the phone's sealed `send-message`. A
send through the direct bearer-token route (POST /api/send, served by `hmd ui`) is never stamped; it is not the
paired channel. bin/heimdall-inbox-deliver frames a record whose seal verifies as the operator's answer to that
question while it is still the open one, and as a late message once it is not; no question open -> no stamp -> an
ordinary chat message. Every field of a record is forgeable by whatever can write inbox.jsonl (a checked-in or
planted line, another process, a tool the model ran); only the seal is not, so a record without a valid one is an
ordinary message under the untrusted-data framing whatever else it claims. A text that opens with
SYSTEM_NOTICE_PREFIX is hmd's own notice (the relay client's pairing notice), not something typed on the phone,
and is never stamped. A failure to derive the question, or to read or make the key, costs the stamp, never the message.

ASK-ANSWER-V1 (capability, listed in `caps` of every state frame by bin/heimdall-relay-client while answers_supported()): a phone
that sees it knows hmd matches the answer it sends -- over the E2E-paired relay, as an ordinary `send-message` {text}, no new
param -- to the question hmd is waiting on, hands the session that answer AS the operator's answer to that question, and ENDS the
question's attention episode when the delivery is made: state.attention leaves needs_input (working, a new id, since = the
delivery) and its "hmd asks" row clears, and a second answer to the same question is delivered as late. Without the token (an
older hmd, or the direct bearer-token route, which is never stamped) a phone answer is an ordinary message, and the row clears
only once the session's next transcript entry does.

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

Receipts (A2, docs/HANDOFF-TO-HEIMDALL-phone-replies-reach-session.md 4(d)): pop_all(root, via=)
stamps every archived message with `delivered_at` (epoch seconds of that pop) and `via` (who dequeued it: stop |
prompt | tool | tmux, the modes of bin/heimdall-inbox-deliver, or cli for `hmd ui inbox pop`), so the archive is
also the delivery receipt log. summary() is the `inbox` slice /api/state serves --
{pending, consumer, oldest_age_s, expired, delivered} -- where `delivered` is the last 20 archive entries as
{id, delivered_at, via, read_at} ONLY, never text (the id is the uuid POST /api/send returned), and `consumer`
is read from .heimdall/ui/inbox-waiting, the marker bin/heimdall-inbox-deliver's stop long-poll rewrites every
poll while it waits (stale after 2x the poll interval), falling back to a configured tmux target, then to an
armed wake ("wake", below), then "none".
Queued -> delivered is therefore the message leaving `pending` and its id appearing in `delivered` with a
timestamp.
  WAKE. "wake" says bin/heimdall-inbox-wake has a watcher armed for a live session and a companion is connected,
  so a message that lands makes the idle session take a turn by itself (an asyncRewake hook, or a prompt typed
  into the session's own tmux pane) and the deliver hooks hand it over in that turn. It is read from what that
  hook leaves under .heimdall/ui/wake/: <claude pid>.json (the SessionStart registration: ours, 0600, naming that
  pid) and <claude pid>.lock (ours, 0600) under an exclusive flock for as long as that session's watcher lives --
  the kernel frees it on any death, so a killed session stops counting at once -- plus the live-companion rule the
  watcher itself applies (.heimdall/app/connect.json), since it never wakes without one. It is checked last and only
  ever stands in for "none", so a client that does not know the value (hmdapp's guard drops an unknown consumer and
  keeps the rest of the slice) loses the upgrade, never a state it understood.
  DELIVERED TO SESSION. `delivered_at` is the moment a delivery hook popped the message into the session's
  context -- "delivered to session". It is NOT "read" and NOT "acted on": nothing in it says the model has seen
  the text. `read_at` is that: the timestamp of the first main-chain assistant entry the session transcript
  holds at/after `delivered_at`, null while there is none (and for a cli pop, which delivered to no session, and
  for a delivery older than READ_LOOKBACK_S, which is no longer looked up). `via` is null for a line archived
  before it was recorded.
  NOT DELIVERED. `expired` lists the ids of messages still pending EXPIRE_AFTER_S after they were sent, so a
  laptop that has stopped taking turns is visible on the phone instead of reading as "queued" for ever.

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

Links: the repo tree is attacker-shaped -- a checkout can carry .heimdall, .heimdall/ui, .heimdall/app, .heimdall/ui/wake or any
file in them as a symlink. Every create, write, append, rename, truncate, lock, stat, list and read this module makes under the repo
-- and of the seal key under $HEIMDALL_HOME -- goes through bin/lib/hmd_private_state.py, which walks down from the root one
component at a time with O_NOFOLLOW and refuses a link or another account's directory anywhere on the way: nothing is created,
chmod'ed, truncated, locked, renamed or written through a link, and nothing a link leads to is believed. A refusal is an OSError
from append() and pop_all() (nothing was written or dequeued: a refused archive costs no queued message) and an empty answer from
every read (list_pending, peek, summary, receipts, consumer state). There is no fallback to plain open().

Stdlib only (json, os, re, sys, time, uuid, fcntl, argparse, subprocess) --
Decision 1's zero-toolchain posture, matching companion_ui_panels.py. This file is
deliberately self-contained (secret_shaped and resolve_root are ported, not
imported from companion_ui_panels.py) so bin/heimdall-ui can exec either script
standalone with zero intra-repo import coupling.
"""
import argparse
import bisect
import contextlib
import datetime
import fcntl
import hashlib
import hmac
import json
import math
import os
import re
import subprocess
import sys
import time
import uuid
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.abspath(__file__))

MAX_TEXT_CHARS = 2000
MAX_PENDING = 200                    # N3: append() refuses a new message at/above this many pending
MAX_INBOX_BYTES = 2 * 1024 * 1024    # N3: inbox-delivered.jsonl rotation threshold (2 MiB)
INBOX_REL = os.path.join(".heimdall", "ui", "inbox.jsonl")
DELIVERED_REL = os.path.join(".heimdall", "ui", "inbox-delivered.jsonl")
WAITING_REL = os.path.join(".heimdall", "ui", "inbox-waiting")      # the stop long-poll's heartbeat marker
TMUX_TARGET_REL = os.path.join(".heimdall", "ui", "tmux-target")
WAKE_DIR_REL = os.path.join(".heimdall", "ui", "wake")   # bin/heimdall-inbox-wake: <claude pid>.json (SessionStart registration), <claude pid>.lock (flock held while that session's watcher is armed)
WAKE_LOCK_RE = re.compile(r"^([0-9]{1,9})\.lock$")       # a pid is at most 9 digits; a longer name is not one
PRIVATE = 0o077       # mode bits a file the wake hook wrote must not carry (it writes them 0600)
NOT_SHARED = 0o022    # mode bits connect.json must not carry: nobody else may write it
CONNECT_REL = os.path.join(".heimdall", "app", "connect.json")      # `hmd app connect`: names the ui and relay-client pids
POLL_INTERVAL_S = 2.0                   # bin/heimdall-inbox-deliver's stop long-poll cadence
WAITING_STALE_S = 2 * POLL_INTERVAL_S   # an inbox-waiting older than this: its long-poll is gone
RECEIPTS_LIMIT = 20                     # inbox.delivered[] is the last this-many deliveries
RECEIPTS_TAIL_BYTES = 256 * 1024        # the newest archive lines hold them; never read the whole file
GIT_TIMEOUT_S = 3
VIA_VALUES = ("stop", "prompt", "tool", "tmux", "cli")   # who dequeued: bin/heimdall-inbox-deliver's modes, and `hmd ui inbox pop`
SYSTEM_NOTICE_PREFIX = "[hmd notice]"   # opens a text hmd itself queues (bin/heimdall-relay-client's pairing notice): never an answer
CAP_ASK_ANSWER = "ask-answer-v1"        # the capability token the relay client lists to the phone while answers_supported(): see ASK-ANSWER-V1
UI_DIR = os.path.join(".heimdall", "ui")      # the directories hmd_private_state walks, one component at a time, without following a link
APP_DIR = os.path.join(".heimdall", "app")
INBOX_NAME = "inbox.jsonl"
DELIVERED_NAME = "inbox-delivered.jsonl"
LOCK_NAME = "inbox.jsonl.lock"          # the flock file: never the data file itself
WAITING_NAME = "inbox-waiting"
TMUX_TARGET_NAME = "tmux-target"
CONNECT_NAME = "connect.json"
INBOX_READ_MAX = 16 * 1024 * 1024       # inbox.jsonl cannot near this (MAX_PENDING x MAX_TEXT_CHARS is under 2 MiB); a bigger file is not read
SEAL_KEY_DIR = "app"                    # under $HEIMDALL_HOME: the per-machine key an answer stamp is sealed with
SEAL_KEY_NAME = "inbox-answer.key"
SEAL_KEY_REL = os.path.join(SEAL_KEY_DIR, SEAL_KEY_NAME)
SEAL_KEY_BYTES = 32                     # a key shorter than this is no key
SEAL_KEY_MAX_BYTES = 4096               # never read more of the key file than this
SEAL_DOMAIN = b"hmd-inbox-answer-v1\n"  # prefixes what is sealed, so this seal is never valid as any other HMAC under the key
EXPIRE_AFTER_S = 2 * 3600.0             # pending this long -> listed in inbox.expired: nothing is taking turns to receive it
READ_LOOKBACK_S = 3600.0                # read_at is looked up only for a delivery this recent (the phone watches the last few minutes)
READ_TAIL_BYTES = 512 * 1024            # the tail of the session transcript searched for the assistant entry after a delivery

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


_STATE = []   # [the hmd_private_state module] once it loaded


def _state():
    """bin/lib/hmd_private_state.py, loaded by path beside this file (it is not a package): the ONLY way this module touches
    a file under a repo or under $HEIMDALL_HOME. Every walk down from the root refuses a link at any level and a directory of
    another account's, makes files 0600 in 0700 directories (on every touch, so a directory or file that predates this fix at
    0755/0644 self-heals -- phone messages are private to the repo owner) and opens nothing through a link. There is no
    fallback to plain open()/chmod()/rename(): a helper that cannot be loaded is an OSError here -- append() and pop_all() are
    refused, nothing written -- and an empty answer for a read."""
    if not _STATE:
        try:
            spec = spec_from_file_location("hmd_private_state", os.path.join(HERE, "hmd_private_state.py"))
            mod = module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as exc:
            raise OSError("hmd_private_state is not available: %s" % (exc,))
        _STATE.append(mod)
    return _STATE[0]


def link_safe():
    """True when this copy found its helper, so it reaches repo state only without following a link. A copy of this library
    vendored into a repo without its helper (or from before it) is not that: bin/heimdall-inbox-deliver takes a repo's copy
    only on this, and otherwise runs its own inline implementation, which is."""
    try:
        _state()
    except OSError:
        return False
    return True


# ── reading ──────────────────────────────────────────────────────────────────
def _read_all(root):
    """Every line in inbox.jsonl as (records, raw_lines), read through hmd_private_state: ([], []) when the file is
    missing, reached through a link, not ours, not a regular file or over INBOX_READ_MAX. A line that fails to parse
    as a JSON object is dropped from `records` (fail-open, matching
    companion_ui_panels.read_panels dropping an invalid panel) but its raw bytes
    stay in `raw_lines` so pop_all() never silently loses a byte of the file --
    an unparsable line is still delivered, just never returned as a record. Lines end at a newline and nowhere else
    (U+2028 and its kin sit raw inside a record's JSON string)."""
    try:
        raw = _state().read(root, UI_DIR, INBOX_NAME, INBOX_READ_MAX, forbidden=0)
    except OSError:
        raw = None
    if raw is None:
        return [], []
    records = []
    raw_lines = []
    for line in raw.decode("utf-8", "surrogateescape").split("\n"):
        if not line.strip():
            continue
        raw_lines.append(line + "\n")
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            records.append(obj)
    return records, raw_lines


_READ_CACHE = {}  # path -> ((mtime_ns, size), records) -- see _cached_records


def _cached_records(root):
    """The records _read_all(root) would return, skipping the reopen+reparse
    when inbox.jsonl's (mtime_ns, size) match the last read done by THIS process --
    the O(1)-ish path behind list_pending()/pending_count() (N3): /api/state's
    2s poll and the post-append recount in POST /api/send both call one of
    those on every hit, far more often than inbox.jsonl actually changes.
    Correctness: append()/pop_all() always change the file's size, so a change
    from ANY process is visible on this process's very next call -- the cache
    can serve at most one call stale, never indefinitely. The stat is taken through
    hmd_private_state (a link, a foreign file or a directory of another account's on the way is no file: []).
    Returns the cached
    list object itself (not a copy) -- internal use only; list_pending() and
    pending_count() are the copy-safe public API built on top of this."""
    path = _inbox_path(root)
    try:
        st = _state().stat_file(root, UI_DIR, INBOX_NAME)
    except OSError:
        st = None
    if st is None:
        _READ_CACHE.pop(path, None)
        return []
    key = (st.st_mtime_ns, st.st_size)
    cached = _READ_CACHE.get(path)
    if cached is not None and cached[0] == key:
        return cached[1]
    records, _ = _read_all(root)
    _READ_CACHE[path] = (key, records)
    return records


def list_pending(root):
    """Every valid pending message, oldest first (inbox.jsonl is append-only, so
    file order IS delivery order). Never mutates the file; a corrupt or
    non-object line is dropped, never raised. Returns fresh dict copies every
    call, even when served from the _cached_records cache, so a caller can
    never mutate a cached structure."""
    return [dict(r) for r in _cached_records(root)]


def pending_count(root):
    """len(list_pending(root)) without the per-call dict copies -- the cheap
    count MAX_PENDING enforcement (append()) and an /api/state-style summary
    actually need; O(1)-ish via the same _cached_records cache."""
    return len(_cached_records(root))


def peek(root):
    """The single oldest pending message, or None if the inbox is empty.
    Non-destructive -- list_pending()'s head. pop_all() is the only thing that
    dequeues."""
    pending = list_pending(root)
    return pending[0] if pending else None


# ── the open question (stamped on a message at receive time) ─────────────────
_MODULES = {}   # sibling module name -> module, or None once it failed to load


def _sibling(name):
    """A sibling bin/lib module loaded by path (None when it cannot load), once -- the way
    companion_attach.py loads this module."""
    if name not in _MODULES:
        try:
            spec = spec_from_file_location(name, os.path.join(HERE, name + ".py"))
            mod = module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            mod = None
        _MODULES[name] = mod
    return _MODULES[name]


def _in_paired_relay_client(root):
    """True only when THIS process is the relay client of `root`'s `hmd app connect --relay`
    (connect.json's pid_client): the one place a command arrives as a frame that opened under the paired
    device's session key. The `hmd ui` server that takes POST /api/send is another pid, so it never matches;
    a missing, unreadable or stale connect.json does not match either -- the cautious side, an ordinary message."""
    try:
        rec = _state().read_json(root, APP_DIR, CONNECT_NAME, 65536, forbidden=0)
    except OSError:
        return False
    pid = rec.get("pid_client") if rec is not None else None
    return isinstance(pid, int) and not isinstance(pid, bool) and pid == os.getpid()


def open_ask(root):
    """The question hmd is waiting on right now, as {"id", "summary"}, else None: the `attention` derivation of
    bin/lib/companion_ui_attention.py -- the one the phone's own attention slice is read from -- kept when it is a
    question. `summary` is None when attention withheld it. Any failure to derive is None: a send must never be
    lost to its stamp, and an unstamped message is simply an ordinary one."""
    attention = _sibling("companion_ui_attention")
    if attention is None:
        return None
    try:
        a = attention.collect(root)
    except Exception:
        return None
    if a.get("state") == "needs_input" and a.get("kind") == "question" and isinstance(a.get("id"), str):
        return {"id": a["id"], "summary": a.get("summary")}
    return None


def answers_supported():
    """True when hmd can really match a phone answer to the open question AND end that question's episode when the answer is
    delivered -- what listing CAP_ASK_ANSWER to the phone promises: the attention derivation loads, it can end an episode
    (close_episode, with the link-safe helper it writes the marker through) and this copy reaches repo state without following a
    link. The loads are memoised, so this reads no file and is cheap enough to ask for the caps of every state frame."""
    attention = _sibling("companion_ui_attention")
    return (attention is not None and callable(getattr(attention, "collect", None))
            and callable(getattr(attention, "close_episode", None))
            and getattr(attention, "PRIVATE", None) is not None and link_safe())


# ── writing ──────────────────────────────────────────────────────────────────
def _heimdall_home():
    """$HEIMDALL_HOME, else ~/.heimdall (bin/lib/companion_remote_switches.py's resolution); None with neither it
    nor HOME -- there is no /tmp fallback, a directory other users can write."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    home = os.environ.get("HOME")
    return os.path.join(home, ".heimdall") if home else None


def _read_seal_key(home):
    """The key under `home` when hmd_private_state accepts it -- a regular file this user owns that nobody else can read,
    reached through no link (neither the key file nor $HEIMDALL_HOME/app may be one), in a directory nobody else can write,
    judged on the open descriptors -- and it is long enough, else None."""
    try:
        key = _state().read(home, SEAL_KEY_DIR, SEAL_KEY_NAME, SEAL_KEY_MAX_BYTES, forbidden=PRIVATE, dir_forbidden=NOT_SHARED)
    except OSError:
        return None
    return key if key is not None and len(key) >= SEAL_KEY_BYTES else None


def _seal_key():
    """The per-machine key an answer stamp is sealed with: SEAL_KEY_REL under $HEIMDALL_HOME, 0600 in a 0700
    directory, outside every repo. Made here when absent -- written whole to a private temp file and linked into
    place (hmd_private_state.create_once), so a racing second maker gets EEXIST and reads the winner's key, never a
    half-written one. The way down from $HEIMDALL_HOME is walked link-free: a link at app, or at the key, makes no key
    and writes nothing through it. None when it can be neither read nor made: no key, no seal, no stamp -- and the
    message still goes through."""
    home = _heimdall_home()
    if home is None:
        return None
    key = _read_seal_key(home)
    if key is not None:
        return key
    try:
        os.makedirs(home, exist_ok=True)   # the root is the operator's own choice (a link AT it is fine); everything below it is walked link-free
        with contextlib.suppress(FileExistsError):   # EEXIST: another maker linked its key first, and that one is the key
            _state().create_once(home, SEAL_KEY_DIR, SEAL_KEY_NAME, os.urandom(SEAL_KEY_BYTES))
    except OSError:
        return None
    return _read_seal_key(home)


def _seal(key, rec_id, ts, text, answers):
    """The seal of an answer stamp: HMAC-SHA256 (hex) over exactly (id, ts, text, answers).
    bin/heimdall-inbox-deliver's stamp_sealed recomputes it; the two must stay byte for byte the same."""
    body = json.dumps([rec_id, ts, text, answers], ensure_ascii=True, separators=(",", ":")).encode("ascii")
    return hmac.new(key, SEAL_DOMAIN + body, hashlib.sha256).hexdigest()


def append(root, text):
    """Validate `text` and atomically append one message to inbox.jsonl. Returns
    the new record {id, ts, text, source}, plus {answers, sig} when hmd was waiting on a question
    as it arrived (see Answers in the module docstring). Raises InboxError -- nothing is ever
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
    typed_on_phone = not text.lstrip().startswith(SYSTEM_NOTICE_PREFIX)
    ask = open_ask(root) if typed_on_phone and _in_paired_relay_client(root) else None
    key = _seal_key() if ask is not None else None
    if key is not None:
        record["answers"] = ask["id"]
        record["sig"] = _seal(key, record["id"], record["ts"], text, ask["id"])
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    state = _state()
    with state.lock(root, UI_DIR, LOCK_NAME):
        # N3: reject before writing once MAX_PENDING is already reached -- checked
        # under the SAME lock the write itself takes, so two concurrent senders
        # (different threads or processes) can never both observe "under the cap"
        # and jointly push it over.
        if pending_count(root) >= MAX_PENDING:
            raise InboxError("inbox-full",
                             "pending queue is at the %d-message cap; drain it (delivery, or "
                             "`hmd ui inbox pop`) before sending more" % MAX_PENDING)
        state.append(root, UI_DIR, INBOX_NAME, line.encode("utf-8"))   # fsync'ed; a link on the way is an OSError, nothing written
    return record


def _rotate_if_oversized(root, max_bytes):
    """If inbox-delivered.jsonl already exists at/above `max_bytes`, move it to `inbox-delivered.jsonl.1`
    (clobbering any previous `.1` -- single-generation rotation, not a numbered
    log1/log2/... series -- a link at `.1` is replaced, never written through) so the next writer starts a fresh file.
    Called with
    the caller's lock already held, so the rename can never race a concurrent
    writer of the same path. N3: inbox-delivered.jsonl has no structural size
    ceiling the way inbox.jsonl does (MAX_PENDING already bounds that one);
    pop_all() calls this before appending each new batch so the archive can't
    grow without bound over a repo's lifetime. The size is taken, and the rename made, inside the vetted
    directory: a link at the archive is no archive and is not rotated."""
    state = _state()
    st = state.stat_file(root, UI_DIR, DELIVERED_NAME)
    if st is None or st.st_size < max_bytes:
        return
    state.rename(root, UI_DIR, DELIVERED_NAME, DELIVERED_NAME + ".1")


def _stamp_delivered(raw_lines, delivered_at, via=None):
    """The archive form of a popped batch: every line that is a JSON object gains
    `delivered_at` (the receipt delivered_receipts() reads back) and, for a known `via`
    (VIA_VALUES), who dequeued it; any other line is kept as it was, so a pop never
    silently loses a byte."""
    out = []
    for line in raw_lines:
        try:
            obj = json.loads(line)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            obj["delivered_at"] = delivered_at
            if via in VIA_VALUES:
                obj["via"] = via
            line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        out.append(line)
    return out


def pop_all(root, via=None):
    """Deliver every pending message: append the current inbox.jsonl content to
    inbox-delivered.jsonl -- each message stamped with the `delivered_at` epoch
    of this pop and the `via` that popped it (one of VIA_VALUES; anything else
    records none) -- its delivery receipt -- (rotating it to inbox-delivered.jsonl.1
    first if it's already at MAX_INBOX_BYTES -- see _rotate_if_oversized) and
    truncate inbox.jsonl to empty, under the SAME lock append() takes. Returns
    the list of delivered records, receipt included (oldest first); [] when
    nothing was pending (and nothing is touched on disk, including rotation, in
    that case)."""
    state = _state()
    with state.lock(root, UI_DIR, LOCK_NAME):
        records, raw_lines = _read_all(root)
        if not raw_lines:
            return []
        delivered_at = round(time.time(), 3)
        _rotate_if_oversized(root, MAX_INBOX_BYTES)
        batch = "".join(_stamp_delivered(raw_lines, delivered_at, via)).encode("utf-8", "surrogateescape")
        # The archive is written (and fsync'ed) BEFORE anything is dequeued: a refusal here -- a link at the archive, a
        # directory of another account's -- raises with every message still pending in inbox.jsonl.
        state.append(root, UI_DIR, DELIVERED_NAME, batch)
        # Truncate in place, still inside the lock so nothing can land between the read above and this truncate: ftruncate of
        # the vetted descriptor (the file keeps its inode), and 0600 forced after, in case inbox.jsonl predates this fix
        # and still carries a wider mode (A10) -- truncating alone never changes a file's permission bits.
        state.truncate(root, UI_DIR, INBOX_NAME)
    return [dict(r, delivered_at=delivered_at, **({"via": via} if via in VIA_VALUES else {})) for r in records]


# ── receipts, consumer, summary: the /api/state `inbox` slice ─────────────────
def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


_RECEIPTS_CACHE = {}  # path -> ((mtime_ns, size), receipts) -- see delivered_receipts


def _read_receipts(root):
    """The last RECEIPTS_LIMIT stamped lines of the archive as {id, delivered_at, via},
    oldest first, reading only its tail (through a descriptor hmd_private_state vetted: no link, ours, a regular file;
    [] when it is not one). A line that is not a JSON object with a
    string `id` and a finite numeric `delivered_at` -- a pre-receipt archive line,
    a corrupt one -- is skipped, never raised and never given an invented time; a
    `via` that is not one of VIA_VALUES (a line archived before it was recorded) is None."""
    fd = _state().open_read(root, UI_DIR, DELIVERED_NAME, forbidden=0)
    if fd is None:
        return []
    try:
        size = os.fstat(fd).st_size
        start = max(0, size - RECEIPTS_TAIL_BYTES)
        chunk = os.pread(fd, size - start, start)
    finally:
        os.close(fd)
    if start:
        chunk = chunk.partition(b"\n")[2]  # the cut landed mid-line: drop that partial first line
    out = []
    for line in chunk.splitlines():
        try:
            obj = json.loads(line.decode("utf-8"))
        except ValueError:  # JSONDecodeError and UnicodeDecodeError both
            continue
        if isinstance(obj, dict) and isinstance(obj.get("id"), str) and _is_number(obj.get("delivered_at")):
            via = obj.get("via")
            out.append({"id": obj["id"], "delivered_at": obj["delivered_at"],
                        "via": via if via in VIA_VALUES else None})
    return out[-RECEIPTS_LIMIT:]


_ASSISTANT_CACHE = {}   # transcript path -> ((mtime_ns, size), (assistant times, time the tail reaches back to))
_READ_AT = {}           # (repo root, receipt id) -> read_at, once a receipt has one: it never moves


def _parse_iso(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def _assistant_times(root):
    """(sorted epoch times of the main-chain assistant entries in the tail of this repo's session
    transcript, the time that tail reaches back to) -- ([], inf) when there is no transcript to read. The
    session is the one every hmd-ui collector reads (hmd_session_resolve); only READ_TAIL_BYTES of it are
    read, and an unchanged transcript costs one stat."""
    attention = _sibling("companion_ui_attention")
    session = attention.SESSION.resolve(root) if attention is not None else None
    if session is None:
        return [], math.inf
    try:
        st = os.stat(session.path)
    except OSError:
        return [], math.inf
    key = (st.st_mtime_ns, st.st_size)
    hit = _ASSISTANT_CACHE.get(session.path)
    if hit is not None and hit[0] == key:
        return hit[1]
    cut = st.st_size > READ_TAIL_BYTES
    try:
        with open(session.path, "rb") as f:
            if cut:
                f.seek(st.st_size - READ_TAIL_BYTES)
                f.readline()  # the seek landed mid-line: drop that partial first line
            chunk = f.read()
    except OSError:
        return [], math.inf
    times, first = [], None
    for line in chunk.splitlines():
        if b'"timestamp"' not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = _parse_iso(e.get("timestamp")) if isinstance(e, dict) else None
        if t is None:
            continue
        first = t if first is None else first
        if e.get("type") == "assistant" and not e.get("isSidechain"):
            times.append(t)
    times.sort()
    value = (times, (math.inf if first is None else first) if cut else 0.0)
    if len(_ASSISTANT_CACHE) > 16:
        _ASSISTANT_CACHE.clear()
    _ASSISTANT_CACHE[session.path] = (key, value)
    return value


def _read_times(root, receipts, now):
    """{receipt id: read_at} for the receipts of `receipts` that have one: the first main-chain assistant entry
    at/after `delivered_at`. Looked up only for a delivery within READ_LOOKBACK_S, never for a cli pop (it
    delivered to no session), and only when the transcript tail reaches back past the delivery -- a time that
    cannot be told is left out, never guessed. A resolved time is kept for the life of the process."""
    out, todo = {}, []
    for r in receipts:
        known = _READ_AT.get((root, r["id"]))
        if known is not None:
            out[r["id"]] = known
        elif r["via"] != "cli" and now - r["delivered_at"] <= READ_LOOKBACK_S:
            todo.append(r)
    if todo:
        times, reaches = _assistant_times(root)
        for r in todo:
            i = bisect.bisect_left(times, r["delivered_at"])
            if r["delivered_at"] >= reaches and i < len(times):
                if len(_READ_AT) > 512:
                    _READ_AT.clear()
                out[r["id"]] = _READ_AT[(root, r["id"])] = times[i]
    return out


def delivered_receipts(root, now=None):
    """The delivery receipts /api/state serves as inbox.delivered: the last
    RECEIPTS_LIMIT of inbox-delivered.jsonl as [{"id", "delivered_at", "via", "read_at"}], oldest
    first -- the uuid POST /api/send returned, the epoch pop_all stamped (DELIVERED TO SESSION: a
    hook popped it into the session's context, which is not the model having read it), who popped
    it, and the first assistant entry after that when the transcript has one (null otherwise) --
    and NEVER the message text. The archive part is cached on its (mtime_ns, size), like
    _cached_records, so the every-request poll costs one stat while nothing is delivered. Returns
    fresh dict copies."""
    path = _delivered_path(root)
    try:
        st = _state().stat_file(root, UI_DIR, DELIVERED_NAME)
    except OSError:
        st = None
    if st is None:
        _RECEIPTS_CACHE.pop(path, None)
        return []
    key = (st.st_mtime_ns, st.st_size)
    cached = _RECEIPTS_CACHE.get(path)
    if cached is None or cached[0] != key:
        try:
            cached = (key, _read_receipts(root))
        except OSError:
            return []
        _RECEIPTS_CACHE[path] = cached
    read = _read_times(root, cached[1], time.time() if now is None else now)
    return [dict(r, read_at=read.get(r["id"])) for r in cached[1]]


def tmux_target(root):
    """The configured tmux target, or "" -- resolved in the same order (env, then
    .heimdall/ui/tmux-target) bin/heimdall-inbox-deliver's tmux mode uses. In the
    server process the env is the SERVER's, so the file is the durable switch."""
    target = os.environ.get("HMD_TMUX_TARGET", "").strip()
    if target:
        return target
    try:
        raw = _state().read(root, UI_DIR, TMUX_TARGET_NAME, 4096, forbidden=0)   # a link on the way is no target: it would name a pane to type into
    except OSError:
        raw = None
    return raw.decode("utf-8", "replace").strip() if raw is not None else ""


def _own_live_pid(pid):
    """True for a pid that is alive AND signalable by this user: one recycled by somebody else's process is not ours."""
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _read_own_json(root, rel, name, forbidden):
    """The JSON object in <root>/<rel>/<name> when hmd_private_state accepts the file -- reached through no link, a regular
    file this user owns that carries none of the `forbidden` mode bits, judged on the open descriptors -- else None
    (missing, foreign, malformed, not an object)."""
    try:
        return _state().read_json(root, rel, name, 65536, forbidden)
    except (OSError, RecursionError):
        return None


def _lock_held(root, name):
    """True while some process holds a flock on <.heimdall/ui/wake>/<name> (a file hmd_private_state accepts: a regular
    file of ours, 0600, reached through no link). The probe asks for a shared
    lock without waiting: refused = an exclusive holder is alive; granted = nobody is, and closing the descriptor
    drops it at once. The grant lasts microseconds; a watcher that starts inside that window stands down once and
    the next Stop re-arms it."""
    try:
        fd = _state().open_read(root, WAKE_DIR_REL, name, forbidden=PRIVATE)
    except OSError:
        return False
    if fd is None:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except OSError:
        return False
    finally:
        os.close(fd)
    return False


def _companion_connected(root):
    """The wake hook's own test for "a phone can reach this session right now": connect.json (`hmd app connect`) is
    ours, nobody else can write it, and every process it names (pid_ui, pid_client) is alive and ours. A watcher
    never wakes without one, so this status never claims a wake without one either."""
    rec = _read_own_json(root, APP_DIR, CONNECT_NAME, NOT_SHARED)
    pids = [rec[k] for k in ("pid_ui", "pid_client") if k in rec] if rec else []
    return bool(pids) and all(_own_live_pid(p) for p in pids)


def wake_armed(root):
    """True when bin/heimdall-inbox-wake has a watcher armed for a live session of this user AND a companion is
    connected: the two things its `watch` needs before it wakes anything. The session shows up as
    .heimdall/ui/wake/<pid>.json (`register`, at SessionStart: names that pid), a <pid>.lock some process holds an
    exclusive flock on (the watcher, for as long as it lives: the kernel frees it on any death) and a pid that is
    still alive. Every file is judged by the rules the hook writes it under -- ours, 0600, a regular file, never a
    link -- so one dropped into a checkout cannot claim a wake. Anything unreadable is "not armed"."""
    try:
        names = _state().names(root, WAKE_DIR_REL)   # [] when .heimdall, .heimdall/ui or the wake directory is a link
    except OSError:
        return False
    for name in names:
        m = WAKE_LOCK_RE.match(name)
        if m is None:
            continue
        pid = int(m.group(1))
        reg = _read_own_json(root, WAKE_DIR_REL, "%d.json" % pid, PRIVATE)
        if (reg is not None and reg.get("pid") == pid and _own_live_pid(pid)
                and _lock_held(root, "%d.lock" % pid)):
            return _companion_connected(root)
    return False


def consumer_state(root, now=None):
    """Who would take the next phone message: "waiting" (a `stop` long-poll is live:
    its inbox-waiting marker was refreshed within WAITING_STALE_S -- twice the poll
    interval, so a killed hook stops counting within seconds), else "tmux" (a tmux
    target is configured), else "wake" (nothing is listening, but an idle session has
    a wake armed: see wake_armed -- the message makes it take a turn by itself), else
    "none" (the next delivery needs a turn boundary). "wake" is checked last so it only
    ever stands in for "none". A marker stamped in the future by more than that is
    clock noise, not a listener."""
    now = time.time() if now is None else now
    try:
        marker = _state().stat_file(root, UI_DIR, WAITING_NAME)   # a link at the marker, or on the way to it, is no listener
    except OSError:
        marker = None
    age = now - marker.st_mtime if marker is not None else None
    if age is not None and -WAITING_STALE_S <= age <= WAITING_STALE_S:
        return "waiting"
    if tmux_target(root):
        return "tmux"
    return "wake" if wake_armed(root) else "none"


def _oldest_age_s(records, now):
    for r in records:
        ts = r.get("ts")
        if _is_number(ts):
            return round(max(0.0, now - ts), 1)
    return None


def _expired_ids(records, now):
    """Ids of the pending messages sent EXPIRE_AFTER_S or more before `now`."""
    return [r["id"] for r in records
            if isinstance(r.get("id"), str) and _is_number(r.get("ts")) and now - r["ts"] >= EXPIRE_AFTER_S]


def summary(root, now=None):
    """The whole `inbox` slice of /api/state in one call:
    {"pending": n, "consumer": "waiting"|"tmux"|"wake"|"none", "oldest_age_s": float|None,
    "expired": [id, ...], "delivered": [{"id", "delivered_at", "via", "read_at"}, ...]}.
    `pending` is read before `delivered`, so a message seen as delivered really was; an
    unreadable source degrades its own field (nothing pending / no receipts), never the slice."""
    now = time.time() if now is None else now
    try:
        records = _cached_records(root)
    except OSError:
        records = []
    return {"pending": len(records),
            "consumer": consumer_state(root, now),
            "oldest_age_s": _oldest_age_s(records, now),
            "expired": _expired_ids(records, now),
            "delivered": delivered_receipts(root, now)}


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
    _print_rows(pop_all(resolve_root(args.repo), via="cli"), args.json)
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
