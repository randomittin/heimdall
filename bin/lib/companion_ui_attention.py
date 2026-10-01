#!/usr/bin/env python3
"""companion_ui_attention.py -- the `attention` slice of /api/state (A1 in
docs/HANDOFF-TO-HEIMDALL-product-asks.md, hmdapp audit 2026-10-01).

One additive top-level key, inside the SSE digest (sentinels/hmd-ui.py registers it):

    "attention": {"state":   "working"|"needs_input"|"needs_approval"|"idle"|"ended",
                  "id":      "a-<10 hex>" | null,   # one attention episode; new on every transition
                  "since":   <epoch s> | null,      # the transition's own timestamp
                  "kind":    null|"question"|"permission"|"done"|"stopped"|"error",
                  "summary": null | <= 160-char single line (secret_shaped -> null, field only),
                  "options": null | [{"key","label"}]  (<= 8 entries, label <= 80 chars),
                  "turn":    parallelism.turns | null}

No evidence at all -> {"state":"idle","id":null,"since":null,"kind":null,"summary":null,
"options":null,"turn":null}, the handoff's own "absent file" shape.

SOURCE -- DERIVED, NOT HOOK-WRITTEN. The handoff proposes a hook script writing
<repo>/.heimdall/ui/attention.json. That half (hooks, the file, the relay `notify` frame) is
deliberately not built here. This module derives the same states from evidence hmd already has:
the NEWEST main-chain entries of the repo's Claude Code session transcript
(${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug>/<session>.jsonl, <slug> = every non-alphanumeric
char of the repo root -> '-', the naming bin/heimdall-agents uses) plus the already-collected
sweep_receipt / checkpoint / quality_gate / parallelism slices and, read-only, the one-integer
live-subagent cache bin/heimdall-statusline keeps at .heimdall/.agents-count-cache.

BOUNDED AND CHEAP. Only the tail is ever read: a 64 KiB window, widened to 512 KiB then 4 MiB
only if no complete decisive entry fits (a single huge tool_result at the end). The parsed
evidence is cached by (mtime_ns, size), so an unchanged transcript costs one os.stat per call;
the directory scan that picks the transcript is cached for DIR_SCAN_TTL_S. Time-driven
transitions (approval grace, `ended`) are re-derived from that cached evidence on every call.

DIGEST. id/since/kind/summary are anchored on a transcript entry, never on "last activity", so
tool calls inside one working run change nothing and /api/events stays quiet. `id` is
sha256(session | anchor entry uuid | state), deterministic across hmd-ui restarts. A working
run longer than the tail window keeps its first anchor in-process (_EPISODE) instead of sliding.

HOW EACH STATE IS REACHED (the newest decisive entry decides):
  working         a prompt / tool_result / tool_use / mid-message assistant entry.
  needs_input     a settled-or-not assistant end_turn whose text ends in `?` (the inbox's own rule,
                  bin/heimdall-inbox-deliver is_question), or a pending AskUserQuestion tool call.
  needs_approval  a tool call with no result for longer than that tool can still be RUNNING
                  (Bash: its own timeout + hook margin, default 180 s; fast tools 20 s; other
                  tools 120 s; Agent/Task never), skipped when the newest permission-mode is
                  bypassPermissions/dontAsk; a pending ExitPlanMode is immediate. This is a timing
                  heuristic standing in for the Notification(permission_prompt) hook.
  idle            an end_turn / user interrupt / API-error that is SETTLED (a system turn_duration
                  entry followed it, or SETTLE_S passed) and has no fresh live subagents.
                  kind "done" iff sweep_receipt.head_sha and checkpoint.head agree on a >=7-char
                  prefix AND quality_gate.clear_to_push is true; else "stopped".
  ended           no transcript write for ENDED_AFTER_S. SessionEnd leaves no mark on disk, so
                  staleness stands in for it (every state, including needs_*, ages out).
`kind: "error"` is never emitted (the handoff defines no trigger for it).

Session choice: bin/lib/hmd_session_resolve.py, the ONE rule every hmd-ui collector shares -- an
inherited CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID / SESSION_ID only when it names a transcript
under THIS repo's own project dir, else the newest top-level *.jsonl whose entrypoint is not
`sdk*` (hmd's own headless judge/dream sessions write transcripts into the same directory and
would otherwise flap the state).

Stdlib only. Self-contained: secret_shaped is ported (companion_ui_inbox.py:94-111), not imported.
"""
import calendar
import hashlib
import json
import os
import re
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import hmd_session_resolve as SESSION  # noqa: E402

STATES = ("working", "needs_input", "needs_approval", "idle", "ended")
KINDS = ("question", "permission", "done", "stopped", "error")
SUMMARY_MAX = 160
OPTIONS_MAX = 8
LABEL_MAX = 80

TAIL_WINDOWS = (64 * 1024, 512 * 1024, 4 * 1024 * 1024)

ENDED_AFTER_S = 6 * 3600
SETTLE_S = 30.0                # a terminal entry with no turn_duration after it counts as settled
AGENTS_CACHE_FRESH_S = 60.0
AGENTS_CACHE_REL = os.path.join(".heimdall", ".agents-count-cache")

FAST_GRACE_S = 20.0
SLOW_GRACE_S = 120.0
BASH_DEFAULT_TIMEOUT_S = 120.0
BASH_MAX_TIMEOUT_S = 600.0
BASH_HOOK_MARGIN_S = 60.0

NO_PROMPT_MODES = frozenset({"bypassPermissions", "dontAsk"})
NEVER_APPROVAL_TOOLS = frozenset({"Agent", "Task", "TaskOutput", "Workflow"})
FAST_TOOLS = frozenset({"Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS",
                        "TodoWrite", "Skill", "SendMessage", "TaskStop", "ToolSearch",
                        "BashOutput", "KillShell"})
# Tools that exist to block on the operator: no timer, the tool call itself is the signal.
BLOCKING_TOOLS = {"AskUserQuestion": ("needs_input", "question"),
                  "ExitPlanMode": ("needs_approval", "permission")}

_IN_PROGRESS = ("prompt", "tool_result", "tool_use", "progress")
_LOCAL_COMMAND_NOISE = ("<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
                        "<command-name>", "<command-message>")

# ── secret scrub: companion_ui_inbox.py:94-111 (itself bin/heimdall-activity's), ported ────────
_SECRET_RES = (
    re.compile(r"(token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
               r"credential|private[_-]?key)\s*[=:]\s*\S{16,}", re.IGNORECASE),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"sk_(live|test)_[A-Za-z0-9]{16,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
)


def secret_shaped(v):
    if not isinstance(v, str):
        return False
    return any(rx.search(v) for rx in _SECRET_RES)


_LOCK = threading.RLock()
_EVIDENCE = {}    # transcript path -> ((mtime_ns, size), evidence)
_EPISODE = {}     # transcript path -> {"state", "anchor"} of the last derivation


def empty():
    return {"state": "idle", "id": None, "since": None, "kind": None,
            "summary": None, "options": None, "turn": None}


# ── transcript discovery ──────────────────────────────────────────────────────────────────────
_TS_RE =re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?(?:Z|[+-]00:?00)?$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def _parse_ts(value):
    m = _TS_RE.match(value.strip()) if isinstance(value, str) else None
    if not m:
        return None
    try:
        whole = calendar.timegm(tuple(int(g) for g in m.groups()[:6]))
    except (ValueError, OverflowError):
        return None
    return whole + (float("0." + m.group(7)) if m.group(7) else 0.0)


# ── tail scan ─────────────────────────────────────────────────────────────────────────────────
def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b["text"] for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def _classify(e):
    """(kind, info) for a decisive main-chain entry, None for metadata/noise.
    kinds: prompt | tool_result | tool_use | progress | text_end | interrupt."""
    msg = e.get("message") if isinstance(e.get("message"), dict) else {}
    content = msg.get("content")
    t = e.get("type")
    if t == "assistant":
        uses = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"] \
            if isinstance(content, list) else []
        if uses:
            return "tool_use", uses
        stop = msg.get("stop_reason")
        if isinstance(stop, str) and stop and stop not in ("tool_use", "pause_turn"):
            return "text_end", _text_of(content)
        return "progress", None
    if t == "user":
        if e.get("isCompactSummary"):
            return None
        if isinstance(content, list):
            ids = [b.get("tool_use_id") for b in content
                   if isinstance(b, dict) and b.get("type") == "tool_result"]
            if ids:
                return "tool_result", ids
        text = _text_of(content).lstrip()
        if text.startswith(_LOCAL_COMMAND_NOISE):
            return None
        if text.startswith("[Request interrupted by user"):
            return "interrupt", None
        return "prompt", None
    return None


def _record(e, kind):
    uid = e.get("uuid")
    return {"kind": kind, "uuid": uid if isinstance(uid, str) and uid else None,
            "ts": _parse_ts(e.get("timestamp")), "error": bool(e.get("isApiErrorMessage"))}


def _scan(lines):
    """Evidence from raw JSONL lines, NEWEST first. `newest` is the decisive entry; `seg` the
    oldest decisive entry of its working run (exact when a prompt or an earlier turn's end was
    reached inside the window); `pending` the tool calls of that run with no result yet."""
    ev = {"newest": None, "seg": None, "exact": False, "pending": [], "mode": None, "turn_end": False}
    results = set()
    closed = False
    for raw in lines:
        if closed:
            if ev["mode"] is not None or not ev["pending"]:
                break
            if b'"permission-mode"' not in raw:
                continue
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        t = e.get("type")
        if t == "permission-mode":
            if ev["mode"] is None and isinstance(e.get("permissionMode"), str):
                ev["mode"] = e["permissionMode"]
            continue
        if closed:
            continue
        if t == "system":
            if e.get("subtype") == "turn_duration" and ev["newest"] is None:
                ev["turn_end"] = True
            continue
        if e.get("isSidechain"):
            continue
        c = _classify(e)
        if c is None:
            continue
        kind, info = c
        rec = _record(e, kind)
        if ev["newest"] is None:
            ev["newest"] = rec
            if kind in ("text_end", "interrupt"):
                rec["text"] = info if kind == "text_end" else ""
                closed = True
                continue
        if kind == "tool_result":
            results.update(i for i in info if isinstance(i, str))
            ev["seg"] = rec
        elif kind == "tool_use":
            for b in info:
                if b.get("id") not in results:
                    ev["pending"].append({"name": b.get("name"), "input": b.get("input"),
                                          "uuid": rec["uuid"], "ts": rec["ts"]})
            ev["seg"] = rec
        elif kind == "progress":
            ev["seg"] = rec
        elif kind == "prompt":
            ev["seg"], ev["exact"], closed = rec, True, True
        else:
            ev["exact"], closed = True, True
    return ev


def _lines_newest_first(data, start):
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]          # the window opens mid-record
    for raw in reversed(lines):
        raw = raw.strip()
        if raw[:1] == b"{":
            yield raw


def _gather(path, st):
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _EVIDENCE.get(path)
    if hit is not None and hit[0] == stamp:
        return hit[1]
    ev = None
    for window in TAIL_WINDOWS:
        start = max(0, st.st_size - window)
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(st.st_size - start)
        ev = _scan(_lines_newest_first(data, start))
        if ev["newest"] is not None or start == 0:
            break
    if len(_EVIDENCE) > 16:
        _EVIDENCE.clear()
    _EVIDENCE[path] = (stamp, ev)
    return ev


# ── question text: summary + options ──────────────────────────────────────────────────────────
def is_question(text):
    """bin/heimdall-inbox-deliver is_question: the text, minus trailing markdown emphasis, ends in `?`."""
    return (text or "").strip().rstrip("*_`~ \t\r\n").endswith("?")


_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
_OPTION_RES = (   # the hmdapp parser's own line shapes (src/chat/parse.ts matchOptionLine)
    (re.compile(r"^([A-Za-z])\)\s*(.+)$"), str.upper),
    (re.compile(r"^-\s*([A-Za-z]):\s*(.+)$"), str.upper),
    (re.compile(r"^\*{0,2}([A-Za-z])\*{0,2}:\s*(.+)$"), str.upper),
    (re.compile(r"^(\d+)\.\s*(.+)$"), str),
    (re.compile(r"^\*{0,2}([A-Za-z])\*{0,2}\s*[—-]\s*(.+)$"), str.upper),
)


def _paragraphs(text):
    return [p.strip() for p in re.split(r"\n\s*\n+", text.strip()) if p.strip()]


def _option_line(line):
    t = line.strip()
    for rx, norm in _OPTION_RES:
        m = rx.match(t)
        if m:
            return {"key": norm(m.group(1)), "label": m.group(2).strip()}
    return None


def _paragraph_options(par):
    lines = [ln.strip() for ln in par.split("\n") if ln.strip()]
    if len(lines) >= 2:
        found = [_option_line(ln) for ln in lines]
        if all(found):
            return found
    chunks = [c for c in re.split(r"\s*·\s*", par) if c]
    if len(chunks) >= 2:
        found = [_option_line(c) for c in chunks]
        if all(found):
            return found
    return None


def _strip_markers(line):
    """Strip leading markdown markers: list/heading/blockquote/bold/italic wrappers.
    Strips repeatedly until none remain (e.g. '> - **A4**' -> 'A4').
    Returns stripped line after whitespace trimming."""
    line = line.strip()
    while True:
        old = line
        # Strip blockquote marker
        line = re.sub(r'^>\s*', '', line)
        # Strip heading hashes (##+ or #)
        line = re.sub(r'^#+\s*', '', line)
        # Strip list markers: - * + • (require space after marker)
        line = re.sub(r'^[-*+•]\s+', '', line)
        # Strip numbered list markers: 1. 12) etc (1-99, require space after)
        line = re.sub(r'^\d{1,2}[.)]\s+', '', line)
        # Strip bold/italic wrappers at start and end
        line = re.sub(r'^(\*\*|__)', '', line)
        line = re.sub(r'(\*\*|__)$', '', line)
        # If nothing changed, we're done
        if line == old:
            break
        line = line.strip()
    return line


def _summarise(paragraph):
    line = " ".join(_CONTROL_RE.sub(" ", paragraph).split())
    if not line or secret_shaped(line):
        return None
    line = _strip_markers(line)
    if not line:
        return None
    if len(line) > SUMMARY_MAX:
        line = _SENTENCE_SPLIT.split(line)[-1]
        if len(line) > SUMMARY_MAX:
            line = "…" + line[-(SUMMARY_MAX - 1):]
    return line


def _question_paragraph(text):
    paras = _paragraphs(text)
    prose = [p for p in paras if _paragraph_options(p) is None]
    return (prose or paras or [""])[-1]


def _make_options(text):
    paras = _paragraphs(text)
    for i, par in enumerate(paras):
        found = _paragraph_options(par)
        if found:
            break
    else:
        return None
    if i == len(paras) - 1 and found[-1]["label"].endswith("?"):
        found[-1]["label"] = found[-1]["label"][:-1].strip()
    keys = [o["key"] for o in found]
    labels = [" ".join(_CONTROL_RE.sub(" ", o["label"]).split()) for o in found]
    if (len(found) > OPTIONS_MAX or len(set(keys)) != len(keys) or not all(labels)
            or any(secret_shaped(lb) for lb in labels)):
        return None
    return [{"key": k, "label": lb if len(lb) <= LABEL_MAX else lb[:LABEL_MAX - 1] + "…"}
            for k, lb in zip(keys, labels)]


def _ask_summary(inp):
    qs = inp.get("questions") if isinstance(inp, dict) else None
    first = qs[0] if isinstance(qs, list) and qs else None
    q = first.get("question") if isinstance(first, dict) else None
    return _summarise(q) if isinstance(q, str) else None


def _tool_label(name):
    return re.sub(r"[^A-Za-z0-9_.:-]", "", name if isinstance(name, str) else "")[:60] or "tool"


# ── derivation ────────────────────────────────────────────────────────────────────────────────
def _grace_s(name, inp):
    """Longest a call to `name` can still legitimately be RUNNING; None = never an approval."""
    if name in NEVER_APPROVAL_TOOLS:
        return None
    if name == "Bash":
        inp = inp if isinstance(inp, dict) else {}
        if inp.get("run_in_background") is True:
            return FAST_GRACE_S
        t = inp.get("timeout")
        t = t / 1000.0 if isinstance(t, (int, float)) and not isinstance(t, bool) and t > 0 \
            else BASH_DEFAULT_TIMEOUT_S
        return min(t, BASH_MAX_TIMEOUT_S) + BASH_HOOK_MARGIN_S
    return FAST_GRACE_S if name in FAST_TOOLS else SLOW_GRACE_S


def _waiting(ev, now):
    """(pending call, (state, kind)) for the oldest call that must be waiting on the operator."""
    best = None
    for p in ev["pending"]:
        name = p["name"] if isinstance(p["name"], str) else ""
        verdict = BLOCKING_TOOLS.get(name)
        if verdict is None:
            if ev["mode"] in NO_PROMPT_MODES:
                continue
            grace = _grace_s(name, p["input"])
            if grace is None or p["ts"] is None or now - p["ts"] < grace:
                continue
            verdict = ("needs_approval", "permission")
        if best is None or (p["ts"] or 0) < (best[0]["ts"] or 0):
            best = (p, verdict)
    return best


def _anchor(rec, fallback_ts):
    ts = rec["ts"] if rec["ts"] is not None else fallback_ts
    return (rec["uuid"] or "ts:%s" % ts, ts)


def _working_anchor(path, ev, mtime):
    prev = _EPISODE.get(path)
    if not ev["exact"] and prev is not None and prev["state"] == "working":
        return prev["anchor"]          # the run began before the tail window: keep its first anchor
    return _anchor(ev["seg"] or ev["newest"], mtime)


def _agents_live(root, now):
    p = os.path.join(root, AGENTS_CACHE_REL)
    try:
        if now - os.stat(p).st_mtime > AGENTS_CACHE_FRESH_S:
            return False
        with open(p, "rb") as f:
            return int(f.read(32).strip() or b"0") > 0
    except (OSError, ValueError):
        return False


def _is_done(receipt, checkpoint, gate):
    sha = receipt.get("head_sha") if isinstance(receipt, dict) else None
    head = checkpoint.get("head") if isinstance(checkpoint, dict) else None
    if not (isinstance(sha, str) and isinstance(head, str)):
        return False
    sha, head = sha.strip().lower(), (head.split() or [""])[0].lower()
    n = min(len(sha), len(head))
    if n < 7 or sha[:n] != head[:n]:
        return False
    return isinstance(gate, dict) and gate.get("clear_to_push") is True


def _derive(path, ev, st, now, root, gate_evidence):
    """(state, anchor, kind, summary, options), or None when the transcript has no decisive entry."""
    nw = ev["newest"]
    if now - st.st_mtime >= ENDED_AFTER_S:
        key = nw["uuid"] if nw and nw["uuid"] else os.path.splitext(os.path.basename(path))[0]
        return "ended", (key, st.st_mtime), None, None, None
    if nw is None:
        return None
    if nw["kind"] in _IN_PROGRESS:
        wait = _waiting(ev, now)
        if wait is None:
            return "working", _working_anchor(path, ev, st.st_mtime), None, None, None
        call, (state, kind) = wait
        summary = _ask_summary(call["input"]) if state == "needs_input" \
            else "permission requested: " + _tool_label(call["name"])
        return state, _anchor(call, st.st_mtime), kind, summary, None
    ts = nw["ts"] if nw["ts"] is not None else st.st_mtime
    text = nw.get("text") or ""
    if nw["kind"] == "text_end" and not nw["error"] and is_question(text):
        return ("needs_input", _anchor(nw, st.st_mtime), "question",
                _summarise(_question_paragraph(text)), _make_options(text))
    if not (ev["turn_end"] or now - ts >= SETTLE_S) or _agents_live(root, now):
        return "working", _working_anchor(path, ev, st.st_mtime), None, None, None
    return "idle", _anchor(nw, st.st_mtime), ("done" if _is_done(*gate_evidence) else "stopped"), None, None


def _episode_id(session, anchor_key, state):
    return "a-" + hashlib.sha256(("%s|%s|%s" % (session, anchor_key, state)).encode("utf-8")).hexdigest()[:10]


def collect(root, turn=None, sweep_receipt=None, checkpoint=None, quality_gate=None, now=None, denied=None):
    """The `attention` dict for `root`. `turn` is parallelism.turns; the three slices only decide
    idle's kind; `denied` is hmd-ui's path_is_denied. Never raises on a missing/unreadable file."""
    now = time.time() if now is None else float(now)
    out = empty()
    try:
        with _LOCK:
            session = SESSION.resolve(root, denied=denied)
            path = session.path if session is not None else None
            if path is None:
                return out
            st = os.stat(path)
            verdict = _derive(path, _gather(path, st), st, now, root, (sweep_receipt, checkpoint, quality_gate))
            if verdict is None:
                return out
            state, anchor, kind, summary, options = verdict
            if len(_EPISODE) > 16:
                _EPISODE.clear()
            _EPISODE[path] = {"state": state, "anchor": anchor}
    except (OSError, ValueError):
        return out
    out.update(state=state, id=_episode_id(os.path.splitext(os.path.basename(path))[0], anchor[0], state),
               since=round(anchor[1], 3), kind=kind, summary=summary, options=options,
               turn=turn if isinstance(turn, int) and not isinstance(turn, bool) and turn >= 0 else None)
    return out
