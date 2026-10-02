#!/usr/bin/env python3
"""companion_ui_publish.py -- native `chat`, `hmd-question` and `agents` panel
publishers for the phone companion (HANDOFF-TO-HEIMDALL-product-asks.md, A3).

Until now the only publishers of these three panels were two scripts wired into
the hmdapp repo's own .claude/settings.json, so a user of any other repo got an
empty Chat tab. This module is the native replacement. It runs IN-PROCESS in the
`hmd ui` poller (sentinels/hmd-ui.py, StateCache.refresh -- the same slot as
`publish_live_users`, P36), so it needs no hook wiring and is "off until `hmd ui`
first runs in the repo" by construction. It publishes through the exact
companion_ui_panels.write_panel path `hmd ui panel set` uses -- one contract,
one scrub, one atomic write.

Source of truth is the session transcript (~/.claude/projects/<slug>/<id>.jsonl):
the conversation is DERIVED from a bounded tail of it (never a full read -- a live
transcript is tens of MB), text blocks only, so a missed hook or a late-started
server never loses the conversation, and inbox-delivered phone messages (which are
injected as hook context, never typed as prompts) are in it too. The tail is not
re-read per tick: ChatTail keeps the parsed conversation and reads only the bytes
appended since the last tick (zero-lag stage 2 -- re-deriving the whole 1 MiB tail
was ~115 ms of every transcript append's trip to the phone), with a result that is
byte-identical to re-reading the tail window (see its docstring).

The consumer contract is the shipped app's, not ours (hmdapp src/chat/parse.ts,
src/contract/guards.ts, src/session/tabs/agents/parse.ts):
  chat          log-tail  {"lines": [...]} and NOTHING else -- guards.ts rejects any
                other `data` key, so the serve-side `truncated`/`dropped_lines`
                markers (companion_ui_panels.bound_log_tail) must never fire: the
                publisher pre-bounds with that same helper at the app's own limits
                (200 lines, 500 UTF-16 units each) and keeps the newest slice.
                Line: "<HH:MM> <you|hmd> <text>", newline -> " ⏎ ".
  hmd-question  markdown  {"text": ...}  (<= 500 units), present only while the
                last thing in the conversation is an hmd reply ending in `?`
                (bin/heimdall's INPUT convention) -- gone the moment anything
                (typed prompt or delivered phone answer) follows it.
  agents        table     agent|role|model|status|started|elapsed, status in
                running|pending|finished|unknown (projection of heimdall-agents).

Stdlib only.
"""
import json
import os
import re
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import companion_ui_panels as P  # noqa: E402
import hmd_session_resolve as SESSION  # noqa: E402

CHAT_ID, CHAT_TITLE = "chat", "Chat"
QUESTION_ID, QUESTION_TITLE = "hmd-question", "hmd asks"
AGENTS_ID, AGENTS_TITLE = "agents", "Agents"
REFRESH_S = 30                  # stale after max(30*3, 30) = 90s, same as the hmdapp publishers
APP_MAX_UNITS = 500             # hmdapp guards.ts MAX_STRING_CHARS -- JS string length = UTF-16 units
TAIL_BYTES_DEFAULT = 1 << 20    # env HMD_UI_CHAT_TAIL_BYTES; never a full-file read
FP_BYTES = 256                  # ChatTail: bytes before its resume offset re-read to prove the file is the one cached
SYNC_ATTEMPTS = 3               # ChatTail: reads retried when a write lands under them, before one plain read
MAX_TAILS = 4                   # transcripts whose parsed tail a publisher keeps (the newest MAX_CANDIDATES rarely differ)
MAX_CANDIDATES = 8              # newest transcripts examined per tick
TTL_MARGIN_S = 3600             # never publish what read_panels would reap within the hour (flap loop)
ENVELOPE_SLACK = 512            # bytes of the panel file that are not `data`
NEWLINE_MARK = " ⏎ "       # parse.ts NEWLINE_MARKER_RE / ' ?⏎ ?'

# Ported from hmdapp scripts/hmd-chat-panel.sh: harness-injected "prompts" that are
# not something the operator typed.
SKIP_PROMPT_PREFIXES = ("<task-notification", "<system-reminder", "[SYSTEM NOTIFICATION",
                        "<cross-session-message", "<command-name", "<local-command",
                        "[Request interrupted")
# bin/heimdall-inbox-deliver INBOX_PROVENANCE_MARKER, start of it: wraps every
# delivered phone message in both the Stop and the UserPromptSubmit path.
INBOX_MARKER = "[companion inbox -- message from the paired phone"
_FOLD_RE = re.compile(r"(\d+) messages? folded:\s*\n```[^\n]*\n(.*)\n```", re.S)
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


# ── small helpers ────────────────────────────────────────────────────────────
def utf16_len(s):
    return len(s.encode("utf-16-le")) // 2


def cut_utf16(s, max_units):
    """`s` cut to at most `max_units` UTF-16 units, the last being an ellipsis when
    it was cut. The app measures JS `.length`, so an astral char (emoji) costs 2."""
    if utf16_len(s) <= max_units:
        return s
    out, used = [], 0
    for ch in s:
        w = 2 if ord(ch) > 0xFFFF else 1
        if used + w > max_units - 1:
            break
        out.append(ch)
        used += w
    return "".join(out) + "…"


def _env_int(name, default):
    try:
        v = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if v > 0 else default


def _epoch(ts, fallback):
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return fallback
    return fallback


# ── locating the session transcript ──────────────────────────────────────────
# bin/lib/hmd_session_resolve.py is the ONE place that decides which session of THIS repo is read
# (an inherited session id only when it names one of the repo's own transcripts, else the newest
# interactive one) -- the rule the edits, parallelism, attention and session-code collectors share.
def project_slug(path):
    return SESSION.project_slug(path)


def projects_dir():
    return SESSION.projects_dir()


def slug_dirs(root):
    return list(SESSION.project_dirs(root))


def source_paths(root):
    """What the native publishers read, for `hmd ui --print-sources`: the TAIL of the
    newest interactive session transcript of this repo, text blocks only."""
    return ([os.path.join(d, "<session>.jsonl") for d in slug_dirs(root)]
            + [os.path.join(root, ".heimdall", ".agents-count-cache")])


def _default_read_tail(path, nbytes):
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", errors="replace")
    except (OSError, ValueError):
        return None


def _parse_line(ln):
    """One JSONL line -> its dict entry, else None. A tail read starts mid-line; the
    partial first line (like any torn or non-JSON line) simply fails to parse and is
    skipped."""
    ln = ln.strip()
    if not ln or ln[0] != "{":
        return None
    try:
        o = json.loads(ln)
    except ValueError:
        return None
    return o if isinstance(o, dict) else None


# ── deriving the conversation ────────────────────────────────────────────────
def _text_of_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        return "\n".join(b["text"] for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return None


def human_prompt(e):
    """The text of a real operator prompt, else None. Modern transcripts tag the
    origin (`{"kind": "human"}`); older ones are filtered by the script's prefix list."""
    if e.get("type") != "user" or e.get("isSidechain") or e.get("isMeta"):
        return None
    if e.get("isCompactSummary") or e.get("isVisibleInTranscriptOnly"):
        return None
    msg = e.get("message")
    text = _text_of_content(msg.get("content") if isinstance(msg, dict) else None)
    if text is None:
        return None
    origin = e.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return None
    stripped = text.strip()
    if not stripped or stripped.startswith(SKIP_PROMPT_PREFIXES):
        return None
    return text


def _split_folded(n, body):
    lines = body.split("\n")
    if all(ln.startswith("    ") or not ln.strip() for ln in lines):
        lines = [ln[4:] if ln.startswith("    ") else ln for ln in lines]
    text = "\n".join(lines)
    parts = [p.strip() for p in text.split("\n\n")]
    if n > 1 and len(parts) == n and all(parts):
        return parts
    return [text.strip()] if text.strip() else []


def phone_messages(e):
    """Texts of inbox-delivered phone messages in this entry. Two transcript shapes
    carry one delivery: the Stop path's isMeta `Stop hook feedback:` user entry and
    the UserPromptSubmit path's `hook_additional_context` attachment. (The Stop path
    also writes a `hook_blocking_error` attachment and a `stop_hook_summary` system
    entry -- deliberately not read, so a message is never counted twice.)"""
    blobs = []
    etype = e.get("type")
    if etype == "user" and e.get("isMeta") and not e.get("isSidechain"):
        msg = e.get("message")
        c = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(c, str) and c.startswith("Stop hook feedback:"):
            blobs.append(c)
    elif etype == "attachment":
        att = e.get("attachment")
        if isinstance(att, dict) and att.get("type") == "hook_additional_context":
            c = att.get("content")
            if isinstance(c, list):
                blobs.extend(x for x in c if isinstance(x, str))
            elif isinstance(c, str):
                blobs.append(c)
    out = []
    for blob in blobs:
        m = _FOLD_RE.search(blob) if INBOX_MARKER in blob else None
        if m:
            out.extend(_split_folded(int(m.group(1)), m.group(2)))
    return out


def _assistant_parts(e):
    msg = e.get("message")
    if not isinstance(msg, dict):
        return [], False, None, None
    content = msg.get("content")
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    if not isinstance(content, list):
        return [], False, msg.get("id"), msg.get("stop_reason")
    texts = [b["text"] for b in content
             if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
             and b["text"].strip()]
    has_tool = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
    return texts, has_tool, msg.get("id"), msg.get("stop_reason")


class _Part(object):
    """What one transcript entry adds to the conversation: an operator prompt, a delivered
    phone message or one assistant text block. `off` is the file offset of the entry's line
    (what the tail window cuts by); `ts` is None when the entry has no usable timestamp (the
    file's mtime stands in at format time). Consecutive parts of one assistant message are a
    single turn (see _merges). `key`/`line` memoize the formatted line on the FIRST part of
    a turn, valid for the (part count, timestamp) it was formatted for."""
    __slots__ = ("off", "role", "mid", "text", "final", "ts", "key", "line")

    def __init__(self, off, role, mid, text, final, ts):
        self.off, self.role, self.mid, self.text, self.final, self.ts = off, role, mid, text, final, ts
        self.key = None
        self.line = None


def entry_parts(e, off):
    """The conversation parts of one transcript entry, usually none or one: operator
    prompts, delivered phone messages (both role `you`, text exactly as delivered so the app
    can pair them with its outbox entry) and assistant text blocks. A turn is its run of
    parts (_merges) and is shown when any part is the FINAL main-chain text of the turn:
    mid-turn narration (a message that stops for a tool) and sub-agent turns are not the
    chat; tool calls and results are never read."""
    if e.get("type") == "assistant":
        if e.get("isSidechain") or e.get("isApiErrorMessage"):
            return ()
        texts, has_tool, mid, stop = _assistant_parts(e)
        if not texts:
            return ()
        final = (not has_tool) and stop != "tool_use"
        return (_Part(off, "hmd", mid, "\n".join(texts), final, _epoch(e.get("timestamp"), None)),)
    if e.get("isSidechain"):
        return ()
    phone = phone_messages(e)
    if phone:
        ts = _epoch(e.get("timestamp"), None)
        return tuple(_Part(off, "you", None, t, True, ts) for t in phone)
    prompt = human_prompt(e)
    if prompt is None:
        return ()
    return (_Part(off, "you", None, prompt, True, _epoch(e.get("timestamp"), None)),)


def _merges(prev, cur):
    """True when `cur` continues `prev`'s turn: one assistant message arrives as one transcript
    entry per content block, all sharing the message id."""
    return cur.role == "hmd" and prev.role == "hmd" and bool(cur.mid) and prev.mid == cur.mid


def clean_text(raw):
    s = str(raw or "").replace("\r\n", "\n").replace("\r", "\n").replace("\n", NEWLINE_MARK)
    return _CONTROL_CHARS_RE.sub("", s).strip()


def format_line(role, raw_text, ts):
    """`<HH:MM> <role> <text>`; None for an empty turn. A secret-shaped turn becomes
    `<role> [redacted]` (checked on the raw text, the flattened line AND the cut
    line, so a secret split by a newline or by the cut is still caught) -- the panel
    is still published, never dropped whole."""
    text = clean_text(raw_text)
    if not text:
        return None
    head = "%s %s " % (time.strftime("%H:%M", time.localtime(ts)), role)
    if P.secret_shaped(str(raw_text)) or P.secret_shaped(text):
        return head + "[redacted]"
    line = head + cut_utf16(text, APP_MAX_UNITS - utf16_len(head))
    return head + "[redacted]" if P.secret_shaped(line) else line


_MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_HTML_TAG_RE = re.compile(r"<[^>]+>")


def is_question(text):
    """bin/heimdall's INPUT convention: a turn that needs the operator ends in a
    literal `?` (trailing markdown emphasis/backticks ignored) -- the same rule
    bin/heimdall-inbox-deliver uses to decide whether to long-poll."""
    return str(text or "").strip().rstrip("*_`~ \t\r\n").endswith("?")


def _tail_units(s, units):
    out, used = [], 0
    for ch in reversed(s):
        w = 2 if ord(ch) > 0xFFFF else 1
        if used + w > units:
            break
        out.append(ch)
        used += w
    return "".join(reversed(out))


def keep_tail(text, max_units):
    """`text` cut to <= max_units UTF-16 units KEEPING THE END, on whole paragraphs
    where it can (a leading ellipsis paragraph marks the cut). The question and the
    option list sit at the end of a long reply; the old head-truncating publisher
    sent the preamble and dropped the question itself."""
    if utf16_len(text) <= max_units:
        return text
    paras = text.split("\n\n")
    kept, used = [], 3          # room for the "…\n\n" marker
    for p in reversed(paras):
        w = utf16_len(p) + (2 if kept else 0)
        if used + w > max_units:
            break
        kept.append(p)
        used += w
    if kept:
        return "…\n\n" + "\n\n".join(reversed(kept))
    tail = _tail_units(paras[-1], max_units - 1)
    m = re.search(r"\s", tail)
    if m and m.start() < len(tail) // 2:
        tail = tail[m.end():]
    return "…" + tail


def question_markdown(raw):
    """The `hmd-question` text: the reply with links reduced to their label and HTML
    tags dropped (the app's markdown subset has neither), control bytes removed,
    kept to the app's string cap from the END. None when secret-shaped -- a
    question is dropped for that turn rather than sent redacted-but-present."""
    t = str(raw or "").replace("\r\n", "\n").replace("\r", "\n")
    t = _HTML_TAG_RE.sub("", _MD_LINK_RE.sub(r"\1", t))
    t = _CONTROL_CHARS_RE.sub("", t).strip()
    t = keep_tail(t, APP_MAX_UNITS)
    return None if (not t or P.secret_shaped(str(raw)) or P.secret_shaped(t)) else t


# ── agents ───────────────────────────────────────────────────────────────────
AGENT_COLUMNS = ("agent", "role", "model", "status", "started", "elapsed")   # parse.ts looks columns up by name
IDLE_ROW = ("—", "idle", "", "", "", "")      # parse.ts drops role == 'idle'; its presence = "published, none running"
FINISHED_TTL_S = 600            # a finished agent stays listed this long (the hmdapp publisher's FINISHED_TTL)
FRESH_SPAWN_S = 30              # first seen this soon after its last write => its start time is known
AGENTS_PROBE_MIN_S = 10         # `heimdall-agents list` costs ~0.3s: never more often than this
COUNT_CACHE_MAX_AGE_S = 60      # the statusline refreshes its count every render; older => no statusline
AGENT_ROW_CAP = 100
AGENT_CELL_CAP = 80
# heimdall-agents state -> the app's closed status set. Excluded: stale, orphaned, mailbox, reaped
# (not live work -- `heimdall-agents orphans` is the operator's view of those).
_STATE_STATUS = {"working": "running", "live": "running", "hung": "unknown",
                 "done": "finished", "failed": "finished", "killed": "finished"}
_STATUS_RANK = {"running": 0, "unknown": 1, "finished": 2}


def agent_cell(value, cap=AGENT_CELL_CAP):
    """One table cell: single line, control bytes gone, `[redacted]` when secret-shaped
    (a row is never dropped for it), cut to `cap`."""
    s = _CONTROL_CHARS_RE.sub("", re.sub(r"[\r\n\t]+", " ", str(value or ""))).strip()
    return "[redacted]" if P.secret_shaped(s) else cut_utf16(s, cap)


def fmt_elapsed(seconds):
    """Minute granularity on purpose: a per-second figure would change the panel (and
    so the SSE digest and every relay frame) on every probe."""
    s = max(0, int(seconds))
    if s < 60:
        return "<1m"
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def agent_rows(agents, now, seen):
    """Table rows for `heimdall-agents list --json` output. `seen` ({id: {first,
    finished_at}}) is the publisher's memory: the list carries no start time (its
    `age_secs` is time since the agent's transcript last changed), so a start time is
    claimed ONLY for an agent first seen while still fresh -- never guessed."""
    keep = []
    for a in agents:
        if not isinstance(a, dict):
            continue
        status = _STATE_STATUS.get(a.get("state"))
        age = a.get("age_secs")
        age = age if isinstance(age, (int, float)) and not isinstance(age, bool) and age >= 0 else 0
        aid = str(a.get("id") or "")
        if status is None or not aid or (status == "finished" and age > FINISHED_TTL_S):
            continue
        rec = seen.get(aid)
        if rec is None:
            rec = seen[aid] = {"first": (now - age) if (status != "finished" and age <= FRESH_SPAWN_S) else None,
                               "finished_at": None}
        if status == "finished" and rec["finished_at"] is None:
            rec["finished_at"] = now - age
        first = rec["first"]
        end = rec["finished_at"] if status == "finished" else now
        name = a.get("name")
        label = a.get("description") or (name if name and name != "-" else None) or aid
        keep.append((_STATUS_RANK[status], aid, [
            agent_cell(label), agent_cell(a.get("agent_type"), 64), "", status,
            time.strftime("%H:%M:%S", time.localtime(first)) if first else "",
            fmt_elapsed(end - first) if first and end else ""]))
    if len(seen) > 500:
        live_ids = {t[1] for t in keep}
        for aid in [k for k in seen if k not in live_ids][:len(seen) - 500]:
            del seen[aid]
    keep.sort(key=lambda t: (t[0], t[1]))
    return [row for _rank, _aid, row in keep[:AGENT_ROW_CAP]]


def _serialized_size(lines):
    return len(json.dumps(lines, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def fit_lines(lines):
    """Newest slice that the app can render and write_panel will accept. Reuses the
    serve-side bound (bound_log_tail) at the app's limits, DISCARDING its
    truncated/dropped_lines verdict on purpose (the app rejects those keys), then
    shrinks by the exact serialized size so JSON escaping can never push the file
    past MAX_FILE_BYTES."""
    kept, _dropped = P.bound_log_tail(lines, max_lines=P.MAX_LIST_ITEMS, max_bytes=P.MAX_FILE_BYTES,
                                      max_line_chars=P.MAX_STRING_CHARS)
    while kept and _serialized_size(kept) > P.MAX_FILE_BYTES - ENVELOPE_SLACK:
        kept = kept[1:]
    return kept


# ── the incremental chat ─────────────────────────────────────────────────────
def _fingerprint(raw):
    """The last FP_BYTES of `raw`, trimmed forward to start on a UTF-8 character boundary so
    that a read beginning there decodes without a replacement character."""
    fp = raw[-FP_BYTES:]
    k = 0
    while k < len(fp) and fp[k] & 0xC0 == 0x80:
        k += 1
    return fp[k:]


class ChatTail(object):
    """The chat-relevant content of ONE transcript, kept level with the file by reading only
    what was appended since the last tick. `view()` is, byte for byte, what this publisher used
    to derive by re-reading, re-parsing and re-formatting the last `tail_bytes` of the file on
    every tick -- ~115 ms for 1200 turns, the largest single cost of a transcript append's trip
    to the phone. test/heimdall-ui-chat-incremental.test.sh holds it to that against a frozen
    copy of the old pipeline, under appends, torn lines, rotations and a sliding window.

    Why it can be exact. The old read covered the window [size - tail_bytes, size) of the file,
    which moves with every append; a line the window starts inside is a partial one that fails
    to parse, and a line it starts exactly at is whole. So the cache keeps the parts (entry_parts)
    of every entry together with the byte offset of its line, and drops those whose line starts
    before the window start: the same entries the old read would parse. Turns are runs of parts
    (_merges), so a turn the window cuts into is simply the run of its remaining parts. Offsets
    are exact byte offsets: every read goes through the injected `read_tail(path, nbytes)` (the
    server's deny-listed primitive), which returns decoded text, so each is checked to be a
    lossless decode (re-encoding gives back the requested byte count) and an unaligned window
    start is resolved by a second read (`_cold`). Anything that cannot be proven -- invalid
    UTF-8 in the window, a write landing between the stat and the read, a transcript replaced,
    truncated or rewritten under the cache -- rebuilds from the window, or, failing that, derives
    from one plain read exactly as before; it never serves a guess.

    A line without its newline is never consumed. When it already is a whole JSON entry it still
    counts (the old read parsed it), re-read each tick until the newline arrives.

    Formatting is lazy and memoized per turn: `view()` walks the turns newest first and
    formats only until the 200 lines the panel can hold are found, so a tick costs the turns
    that changed, not the window.

    One instance per transcript path; the publisher's poller thread is its only caller."""

    def __init__(self, read_tail, tail_bytes):
        self._read_tail = read_tail
        self._tail = tail_bytes
        self._reset()

    def _reset(self):
        self._ident = None       # (st_dev, st_ino) of the file the cache was built from; None: not resumable
        self._off = 0            # offset just past the last complete (newline-terminated) line consumed
        self._seen = 0           # file size at the last sync: _off plus the unterminated tail's length
        self._mtime_ns = 0
        self._fp = b""           # up to FP_BYTES bytes just before _off, to prove the file is the one cached
        self._wstart = 0         # start of the tail window at the last sync
        self._parts = []         # _Part of every entry inside the window, oldest first
        self._ep = None          # (offset, entrypoint) of the newest entry inside the window that named one
        self._extra = ((), None)    # parts / entrypoint of the unterminated last line when it is a whole entry
        self._q = None           # (first part, part count, markdown) of the last question formatted

    # keeping level with the file
    def sync(self, path):
        """Bring the cache level with `path`'s bytes as they are now. False -- cache untouched --
        when the file cannot be read (denied, gone); True once view() reflects it."""
        try:
            return self._sync(path)
        except BaseException:
            self._reset()        # never leave a half-applied update to be resumed from
            raise

    def _sync(self, path):
        for _ in range(SYNC_ATTEMPTS):
            try:
                st = os.stat(path)
            except OSError:
                return self._once(path)      # not a file this process can stat: whatever the reader makes of it
            done = self._resume(path, st) if self._resumable(st) else None
            if done is None:
                done = self._cold(path, st)
            if done is not None:
                return done
        return self._once(path)              # the file kept moving under every read: one plain read, no cache

    def _resumable(self, st):
        if self._ident != (st.st_dev, st.st_ino) or st.st_mtime_ns < self._mtime_ns:
            return False
        if st.st_size == self._seen:
            return st.st_mtime_ns == self._mtime_ns      # a moved mtime on an unmoved size is an edit in place
        return self._seen < st.st_size <= self._off + self._tail

    def _resume(self, path, st):
        """Read only the bytes after the last consumed line. None: the file is not what was cached."""
        if st.st_size == self._seen:
            return True
        need = st.st_size - self._off + len(self._fp)
        text = self._read_tail(path, need)
        if text is None:
            return False
        raw = text.encode("utf-8")
        if len(raw) != need or not raw.startswith(self._fp):
            return None          # lossy decode, a write between stat and read, or the file was replaced
        pos, tail = self._feed(raw[len(self._fp):].decode("utf-8"), self._off)
        if pos != self._off:
            self._fp = _fingerprint(raw[:len(self._fp) + pos - self._off])
        self._off, self._seen, self._mtime_ns = pos, st.st_size, st.st_mtime_ns
        self._load_tail(tail, pos)
        self._slide(st.st_size)
        return True

    def _cold(self, path, st):
        """Rebuild from a read of the tail window, as the old publisher did on every tick. None: the
        file moved while it was being read (the caller tries again)."""
        self._reset()
        size = st.st_size
        text = self._read_tail(path, self._tail)
        if text is None:
            return False
        if size > self._tail:
            head, nl, rest = text.partition("\n")    # the window opens mid-line: `head` is what is left of one
        else:
            head, nl, rest = None, "\n", text        # the window is the whole file, from a line boundary
        rest_raw = rest.encode("utf-8")
        rest_pos = size - len(rest_raw)              # where `rest` starts, IF it decoded without replacements
        # An unaligned window start decodes lossily (a replacement char per stray byte), so the byte length
        # of `head` is unknowable; `rest` starts on a line boundary, and is proven lossless by asking for
        # exactly its length again: a lossy `rest` would be asked for too many bytes and start earlier.
        exact = (rest_pos == 0) if head is None else (bool(nl) and self._read_tail(path, len(rest_raw)) == rest)
        try:
            after = os.stat(path)
        except OSError:
            return None
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (st.st_dev, st.st_ino, size, st.st_mtime_ns):
            return None
        if not exact:
            self._load_text(text)
            return True
        if head is not None:
            self._take(_parse_line(head), size - self._tail)
        pos, tail = self._feed(rest, rest_pos)
        self._ident = (st.st_dev, st.st_ino)
        self._off, self._seen, self._mtime_ns = pos, size, st.st_mtime_ns
        self._fp = _fingerprint(rest_raw[:pos - rest_pos])
        self._load_tail(tail, pos)
        self._slide(size)
        return True

    def _once(self, path):
        text = self._read_tail(path, self._tail)
        if text is None:
            return False
        self._load_text(text)
        return True

    def _load_text(self, text):
        """Derive from `text` alone, as the old publisher did: the text is the whole window, so
        nothing is cut and offsets are never compared. Not resumable (_ident stays None)."""
        self._reset()
        pos, tail = self._feed(text, 0)
        self._load_tail(tail, pos)

    def _feed(self, text, pos):
        """Consume the complete lines of `text`, which starts at file offset `pos`: returns the
        offset just past the last of them and the unterminated rest."""
        lines = text.split("\n")
        rest = lines.pop()
        for ln in lines:
            self._take(_parse_line(ln), pos)
            pos += len(ln.encode("utf-8")) + 1
        return pos, rest

    def _take(self, e, off):
        if e is None:
            return
        ep = e.get("entrypoint")
        if isinstance(ep, str) and ep:
            self._ep = (off, ep)
        self._parts.extend(entry_parts(e, off))

    def _load_tail(self, rest, pos):
        e = _parse_line(rest)
        if e is None:
            self._extra = ((), None)
            return
        ep = e.get("entrypoint")
        self._extra = (entry_parts(e, pos), (pos, ep) if isinstance(ep, str) and ep else None)

    def _slide(self, size):
        """Cut the cache to the window [size - tail_bytes, size): the entries a read of it would parse."""
        self._wstart = start = max(0, size - self._tail)
        k = 0
        while k < len(self._parts) and self._parts[k].off < start:
            k += 1
        if k:
            del self._parts[:k]
        if self._ep is not None and self._ep[0] < start:
            self._ep = None

    # what the window says
    def _window(self):
        """(parts, newest entrypoint) inside the window, the unterminated line included."""
        parts, ep = self._parts, self._ep
        extra_parts, extra_ep = self._extra
        if extra_parts and extra_parts[0].off >= self._wstart:
            parts = parts + list(extra_parts)
        if extra_ep is not None and extra_ep[0] >= self._wstart:
            ep = extra_ep
        return parts, ep

    def headless(self):
        """True for a `claude -p` / SDK session (entrypoint sdk-cli, sdk-py, sdk-ts ...): the
        judge/verifier sub-sessions that once replaced the whole chat panel. The interactive CLI
        says `cli`. A window with no entrypoint at all counts as interactive."""
        ep = self._window()[1]
        return ep is not None and ep[1].startswith("sdk")

    def view(self, fallback_ts):
        """(headless, lines, question) for the window. `lines` are the newest panel lines in the
        publisher's format, bounded as fit_lines does; `question` is the hmd-question markdown for
        the last shown turn, or None. `fallback_ts` (the file's mtime) times a turn whose entry
        has no usable timestamp."""
        parts = self._window()[0]
        lines, last = [], None
        i = len(parts)
        while i > 0 and len(lines) < P.MAX_LIST_ITEMS:
            j = i - 1
            while j > 0 and _merges(parts[j - 1], parts[j]):
                j -= 1
            turn = parts[j:i]
            i = j
            if not any(p.final for p in turn):
                continue
            if last is None:
                last = turn
            line = self._line(turn, fallback_ts)
            if line:
                lines.append(line)
        lines.reverse()
        question = None
        if last is not None and last[0].role == "hmd":
            text = "\n".join(p.text for p in last)
            if is_question(text):
                question = self._question(last[0], len(last), text)
        return self.headless(), fit_lines(lines), question

    @staticmethod
    def _line(turn, fallback_ts):
        first = turn[0]
        ts = first.ts if first.ts is not None else fallback_ts
        key = (len(turn), ts)
        if first.key != key:
            first.line = format_line(first.role, "\n".join(p.text for p in turn), ts)
            first.key = key
        return first.line

    def _question(self, first, count, text):
        if self._q is None or self._q[0] is not first or self._q[1] != count:
            self._q = (first, count, question_markdown(text))
        return self._q[2]


# ── the publisher ────────────────────────────────────────────────────────────
class CompanionPublisher(object):
    """One per `hmd ui` process. `tick()` is called from the poller; it is cheap when
    nothing changed (one listdir + a stat per candidate transcript) and rewrites a
    panel ONLY when its content changed, so `updated_at` keeps meaning "last real
    activity" (the app's status heuristics read it) and the SSE digest stays quiet.

    `read_tail(path, nbytes) -> text|None` is injectable so the server hands in its
    deny-listed `_read_tail`; `list_agents()` likewise (see the agents publisher)."""

    def __init__(self, root, read_tail=None, list_agents=None, tail_bytes=None):
        self.root = root
        self._read_tail = read_tail or _default_read_tail
        self._list_agents = list_agents
        self._tail_bytes = tail_bytes or _env_int("HMD_UI_CHAT_TAIL_BYTES", TAIL_BYTES_DEFAULT)
        self._derived = None        # {"stamp", "mtime", "lines", "question"} of the transcript last read
        self._tails = {}            # transcript path -> its ChatTail, least recently used first
        self._headless = set()      # transcripts known to be sdk/-p sessions
        self._written = {}          # panel id -> the content last written
        self._agent_seen = {}       # agent id -> {first, finished_at}, see agent_rows
        self._agent_rows = None     # rows from the last successful probe
        self._last_probe = 0.0
        self._last_nonidle = 0.0

    # transcript selection
    def _candidates(self):
        """(mtime_ns, size, path) of this repo's top-level transcripts: the session the shared
        rule picks (hmd_session_resolve.resolve) FIRST, the rest newest-first behind it as
        fallbacks for a pick that turns out unreadable or headless. ttl=0: re-scanned every tick,
        a transcript created a moment ago is seen at once."""
        out = SESSION.transcripts(self.root)
        chosen = SESSION.resolve(self.root, ttl=0)
        if chosen is not None:
            out.sort(key=lambda c: c[2] != chosen.path)   # stable: the pick first, the rest keep their order
        return out

    def _refresh_derived(self, now):
        for mtime_ns, size, path in self._candidates()[:MAX_CANDIDATES]:
            if path in self._headless:
                continue
            mtime = mtime_ns / 1e9
            if now - mtime > P.PANEL_TTL_SECONDS - TTL_MARGIN_S:
                return None
            stamp = (path, size, mtime_ns)
            if self._derived is not None and self._derived["stamp"] == stamp:
                return self._derived
            tail = self._tail_of(path)
            if not tail.sync(path):
                continue
            if tail.headless():
                self._headless.add(path)
                self._tails.pop(path, None)
                continue
            _, lines, question = tail.view(mtime)
            self._derived = {"stamp": stamp, "mtime": mtime, "lines": lines, "question": question}
            return self._derived
        return None

    def _tail_of(self, path):
        """The ChatTail of `path`, kept for the next tick (the MAX_TAILS most recently used are)."""
        tail = self._tails.pop(path, None) or ChatTail(self._read_tail, self._tail_bytes)
        self._tails[path] = tail
        while len(self._tails) > MAX_TAILS:
            del self._tails[next(iter(self._tails))]
        return tail

    # writing
    def _write(self, pid, title, ptype, data, updated_at):
        try:
            P.write_panel(self.root, pid, {"id": pid, "title": title, "type": ptype, "data": data,
                                           "refresh_s": REFRESH_S, "updated_at": updated_at})
        except (P.PanelError, OSError) as e:
            sys.stderr.write("hmd-ui: companion panel %s not published: %s\n" % (pid, e))
            return False
        return True

    def _exists(self, pid):
        return os.path.exists(P.panel_path(self.root, pid))

    def _publish_chat(self, derived, now):
        lines = derived["lines"]
        exists = self._exists(CHAT_ID)
        if not lines and not exists:
            return False
        if exists and self._written.get(CHAT_ID) == lines:
            return False
        if not self._write(CHAT_ID, CHAT_TITLE, "log-tail", {"lines": lines}, min(now, derived["mtime"])):
            return False
        self._written[CHAT_ID] = list(lines)
        return True

    def _publish_question(self, derived, now):
        text = derived["question"]
        exists = self._exists(QUESTION_ID)
        if text is None:
            self._written.pop(QUESTION_ID, None)
            if not exists:
                return False
            try:
                return P.remove_panel(self.root, QUESTION_ID)
            except OSError as e:
                sys.stderr.write("hmd-ui: companion panel %s not removed: %s\n" % (QUESTION_ID, e.__class__.__name__))
                return False
        if exists and self._written.get(QUESTION_ID) == text:
            return False
        if not self._write(QUESTION_ID, QUESTION_TITLE, "markdown", {"text": text}, min(now, derived["mtime"])):
            return False
        self._written[QUESTION_ID] = text
        return True

    def _agents_count(self, now):
        """The statusline's cached live-subagent count (.heimdall/.agents-count-cache, a
        plain one-line file it refreshes on every render), or None when absent, stale
        or garbled -- then the answer has to come from a probe."""
        p = os.path.join(self.root, ".heimdall", ".agents-count-cache")
        try:
            if now - os.stat(p).st_mtime > COUNT_CACHE_MAX_AGE_S:
                return None
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                v = f.readline().strip()
        except OSError:
            return None
        return int(v) if v.isdigit() else None

    def _agents_rows(self, now):
        if self._list_agents is None:
            return None
        count = self._agents_count(now)
        recent = self._last_nonidle > 0 and now - self._last_nonidle < FINISHED_TTL_S
        if (count is None or count > 0 or recent) and now - self._last_probe >= AGENTS_PROBE_MIN_S:
            self._last_probe = now
            agents = self._list_agents()
            if isinstance(agents, list):
                rows = agent_rows(agents, now, self._agent_seen)
                if rows:
                    self._last_nonidle = now
                self._agent_rows = rows or [list(IDLE_ROW)]
            # a failed probe keeps whatever was last published: no flap to "idle"
        elif self._agent_rows is None or (count == 0 and not recent):
            self._agent_rows = [list(IDLE_ROW)]
        return self._agent_rows

    def _publish_agents(self, now):
        rows = self._agents_rows(now)
        if rows is None:
            return False
        if self._exists(AGENTS_ID) and self._written.get(AGENTS_ID) == rows:
            return False
        if not self._write(AGENTS_ID, AGENTS_TITLE, "table", {"columns": list(AGENT_COLUMNS), "rows": rows}, now):
            return False
        self._written[AGENTS_ID] = [list(r) for r in rows]
        return True

    def tick(self, now=None):
        """One publish pass. True when any panel file was written or removed."""
        now = time.time() if now is None else now
        derived = self._refresh_derived(now)
        if derived is None:
            return False
        changed = self._publish_chat(derived, now)
        changed = self._publish_question(derived, now) or changed
        return self._publish_agents(now) or changed
