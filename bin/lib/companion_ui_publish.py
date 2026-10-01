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
injected as hook context, never typed as prompts) are in it too.

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

CHAT_ID, CHAT_TITLE = "chat", "Chat"
QUESTION_ID, QUESTION_TITLE = "hmd-question", "hmd asks"
AGENTS_ID, AGENTS_TITLE = "agents", "Agents"
REFRESH_S = 30                  # stale after max(30*3, 30) = 90s, same as the hmdapp publishers
APP_MAX_UNITS = 500             # hmdapp guards.ts MAX_STRING_CHARS -- JS string length = UTF-16 units
TAIL_BYTES_DEFAULT = 1 << 20    # env HMD_UI_CHAT_TAIL_BYTES; never a full-file read
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
def project_slug(path):
    """Claude Code's project dir name: every non-alphanumeric char -> '-'
    (bin/heimdall-agents _slug_for_cwd is the same rule)."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def projects_dir():
    """Same chain bin/heimdall-agents uses, plus CLAUDE_CONFIG_DIR."""
    override = os.environ.get("HMD_AGENT_PROJECTS_DIR")
    if override:
        return override
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        return os.path.join(cfg, "projects")
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".claude", "projects")


def slug_dirs(root):
    base, seen, out = projects_dir(), set(), []
    for r in (root, os.path.realpath(root)):
        s = project_slug(r)
        if s not in seen:
            seen.add(s)
            out.append(os.path.join(base, s))
    return out


def _default_read_tail(path, nbytes):
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", errors="replace")
    except (OSError, ValueError):
        return None


def parse_entries(text):
    """JSONL text -> dict entries. A tail read starts mid-line; the partial first
    line (like any torn or non-JSON line) simply fails to parse and is skipped."""
    out = []
    for ln in text.split("\n"):
        ln = ln.strip()
        if not ln or ln[0] != "{":
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict):
            out.append(o)
    return out


def is_headless(entries):
    """True for a `claude -p` / SDK session (entrypoint sdk-cli, sdk-py, sdk-ts ...):
    the judge/verifier sub-sessions that once replaced the whole chat panel. The
    interactive CLI says `cli`. An entry-less window counts as interactive."""
    for e in reversed(entries):
        ep = e.get("entrypoint")
        if isinstance(ep, str) and ep:
            return ep.startswith("sdk")
    return False


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


def derive_turns(entries, fallback_ts):
    """Chronological conversation turns [{role, ts, text, mid}]: operator prompts,
    delivered phone messages (both role `you`, text exactly as delivered so the app
    can pair them with its outbox entry), and the FINAL main-chain assistant text of
    each turn. Mid-turn narration (a message that stops for a tool) and sub-agent
    turns are not the chat; tool calls and results are never read."""
    turns = []
    for e in entries:
        ts = _epoch(e.get("timestamp"), fallback_ts)
        if e.get("type") == "assistant":
            if e.get("isSidechain") or e.get("isApiErrorMessage"):
                continue
            texts, has_tool, mid, stop = _assistant_parts(e)
            if not texts:
                continue
            final = (not has_tool) and stop != "tool_use"
            last = turns[-1] if turns else None
            if last is not None and last["role"] == "hmd" and mid and last["mid"] == mid:
                last["text"] += "\n" + "\n".join(texts)
                last["final"] = last["final"] or final
            else:
                turns.append({"role": "hmd", "ts": ts, "text": "\n".join(texts), "mid": mid, "final": final})
            continue
        if e.get("isSidechain"):
            continue
        phone = phone_messages(e)
        if phone:
            turns.extend({"role": "you", "ts": ts, "text": t, "mid": None, "final": True} for t in phone)
            continue
        prompt = human_prompt(e)
        if prompt is not None:
            turns.append({"role": "you", "ts": ts, "text": prompt, "mid": None, "final": True})
    return [t for t in turns if t["final"]]


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
        self._derived = None        # {"stamp", "mtime", "lines"} of the transcript last read
        self._headless = set()      # transcripts known to be sdk/-p sessions
        self._written = {}          # panel id -> the content last written

    # transcript selection
    def _candidates(self):
        out = []
        for d in slug_dirs(self.root):
            try:
                names = os.listdir(d)
            except OSError:
                continue
            for n in names:
                if not n.endswith(".jsonl"):
                    continue
                p = os.path.join(d, n)
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                if os.path.isfile(p):
                    out.append((st.st_mtime_ns, st.st_size, p))
        out.sort(reverse=True)
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
            text = self._read_tail(path, self._tail_bytes)
            if text is None:
                continue
            entries = parse_entries(text)
            if is_headless(entries):
                self._headless.add(path)
                continue
            turns = derive_turns(entries, mtime)
            lines = [ln for ln in (format_line(t["role"], t["text"], t["ts"]) for t in turns) if ln]
            self._derived = {"stamp": stamp, "mtime": mtime, "lines": fit_lines(lines), "turns": turns}
            return self._derived
        return None

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

    def tick(self, now=None):
        """One publish pass. True when any panel file was written or removed."""
        now = time.time() if now is None else now
        derived = self._refresh_derived(now)
        if derived is None:
            return False
        return self._publish_chat(derived, now)
