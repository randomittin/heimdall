#!/usr/bin/env python3
"""
subagent-statusline.py — Heimdall SUBAGENT statusline (spec §9) for Claude Code.

INDEPENDENT of the main watchman (sentinels/hmd-statusline.py): no sigil, no gate,
no team wall. It renders ONE ghost/faint transcript row PER RUNNING subagent, so a
live subagent's identity + progress reads under the transcript without ever
competing with it.

INPUT  (stdin): one JSON object — {"columns": <int>, "tasks": [ {task}, ... ]}.
  each task: {id, name, description, status, startTime, tokenCount, model,
              contextWindowSize}.
OUTPUT (stdout): one JSON line PER RUNNING task —
  {"id":"<task id>","content":"<ansi row>"}
  the row: `╰── hmd:<name> <description-truncated> · <elapsed> ↓<tokens> <pct>%`
    • <pct>     = round(tokenCount / contextWindowSize × 100); OMITTED if either
                  field is absent/invalid.
    • <elapsed> = now − startTime, humanized (4m10s, 1h04m); OMITTED if startTime
                  is absent/unparseable.
    • <tokens>  = tokenCount humanized (708k, 1.2M); the `↓tokens` segment (and pct)
                  is OMITTED when tokenCount is absent.
    • <description> is truncated with `…` so the visible row fits `columns`.
    • faint/dim fg, terminal-safe (truecolor → 256 → plain no-color via hmd_termcaps).

Emits rows ONLY for status == "running". Any non-running task's id is OMITTED
entirely (never an empty content). Null-safe throughout: missing columns → 80,
missing token fields → drop pct, empty/malformed input → print nothing, exit 0,
NEVER write stderr.

Ships via hooks/subagent-statusline.sh (mirrors hooks/statusline.sh).
"""
import sys, os, json, time, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))

# Reuse the main watchman's tier machinery: truecolor bytes are built once, then
# CAPS.emit() downgrades to the detected terminal in a single pass (256/16/mono).
_tcspec = importlib.util.spec_from_file_location("hmd_termcaps", os.path.join(HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec); _tcspec.loader.exec_module(TC)

CAPS = TC.detect(sys.argv)
USE_COLOR = CAPS.use_color()

# ghost/faint palette: a dim slate fg + the SGR faint-intensity attribute, so the row
# recedes under the transcript. `_c` gates the color (empty codes → clean plain text);
# the color SGR is a 24-bit `38;2;` sequence so CAPS.emit downgrades it to the tier.
def _c(s): return s if USE_COLOR else ""
FAINT = _c("\033[2m") + _c("\033[38;2;90;100;114m")   # dim intensity + slate gray
X = _c("\033[0m")


def _num(v):
    """A finite, non-bool number or None. JSON bools are ints in python — reject them
    so a `true` tokenCount can never masquerade as 1."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    return None


def parse_start(v):
    """startTime → epoch seconds (float), or None. Accepts an epoch number (auto-
    detecting ms when the magnitude is > 1e12) or an ISO-8601 string. Never raises."""
    n = _num(v)
    if n is not None:
        f = float(n)
        if f > 1e12:            # milliseconds since epoch → seconds
            f /= 1000.0
        return f
    if isinstance(v, str) and v.strip():
        try:
            from datetime import datetime
            return datetime.fromisoformat(v.strip().replace("Z", "+00:00")).timestamp()
        except Exception:
            return None
    return None


def human_elapsed(secs):
    """Humanize an elapsed duration: `<s>s` under a minute, `<m>m<ss>s` under an hour,
    else `<h>h<mm>m` — sub-units zero-padded to 2 so columns never jitter."""
    s = int(secs)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def human_tokens(n):
    """Humanize a token count: `<n>` under 1k, `<n>k` under 1M, else `<n.n>M` (a lone
    `.0` trimmed → `2M`). None/0/absent → None (the ↓tokens segment is then dropped)."""
    v = _num(n)
    if not v or v <= 0:
        return None
    v = int(v)
    if v < 1000:
        return str(v)
    if v < 1_000_000:
        return "%dk" % round(v / 1000.0)
    m = "%.1f" % (v / 1_000_000.0)
    if m.endswith(".0"):
        m = m[:-2]
    return m + "M"


def _clip_desc(desc, budget):
    """Truncate `desc` to `budget` VISIBLE cells, appending `…` when clipped. budget<=0
    → empty. Drops whole characters (width-aware) so a wide glyph is never sliced."""
    if budget <= 0:
        return ""
    if CAPS.width(desc) <= budget:
        return desc
    out = []
    w = 0
    for ch in desc:
        cw = CAPS.width(ch)
        if w + cw > budget - 1:      # reserve one cell for the ellipsis
            break
        out.append(ch)
        w += cw
    return "".join(out) + "…"


def build_row(task, columns, now):
    """The faint transcript row for ONE running task, downgraded to the terminal tier.
    Returns the emitted (color-safe) string. The description is truncated so the
    VISIBLE row fits `columns`."""
    name = str(task.get("name") or "agent")
    desc = str(task.get("description") or "")

    # metric cluster: `· <elapsed> ↓<tokens> <pct>%` — each segment independently
    # omitted when its source field is absent/invalid.
    metrics = []
    start = parse_start(task.get("startTime"))
    if start is not None:
        metrics.append(human_elapsed(max(0.0, now - start)))
    tok = human_tokens(task.get("tokenCount"))
    if tok is not None:
        metrics.append("↓" + tok)
    tc = _num(task.get("tokenCount"))
    cw = _num(task.get("contextWindowSize"))
    if tc is not None and cw is not None and cw > 0:
        metrics.append("%d%%" % round(tc / cw * 100.0))
    tail = ("· " + " ".join(metrics)) if metrics else ""

    head = "hmd:" + name
    # visible width of the fixed frame ("╰── head [tail]"), so the description gets
    # exactly the leftover budget (plus one separating space it will occupy).
    fixed = "╰── " + head + ((" " + tail) if tail else "")
    budget = columns - CAPS.width(fixed) - 1   # −1 for the space before the description
    clipped = _clip_desc(desc, budget) if desc else ""

    pieces = ["╰──", head]
    if clipped:
        pieces.append(clipped)
    if tail:
        pieces.append(tail)
    plain = " ".join(pieces)
    return CAPS.emit(FAINT + plain + X)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(data, dict):
        return
    tasks = data.get("tasks")
    if not isinstance(tasks, list):
        return

    cols = _num(data.get("columns"))
    columns = int(cols) if (cols is not None and cols > 0) else 80

    now = None
    env_now = os.environ.get("HMD_NOW")
    if env_now:
        try:
            now = float(env_now)
        except Exception:
            now = None
    if now is None:
        now = time.time()

    out = []
    for t in tasks:
        if not isinstance(t, dict):
            continue
        if t.get("status") != "running":
            continue                     # non-running → OMIT the id entirely
        tid = t.get("id")
        if tid is None:
            continue
        try:
            content = build_row(t, columns, now)
        except Exception:
            continue                     # one bad task never breaks the others
        out.append(json.dumps({"id": tid, "content": content}))

    if out:
        sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # the statusline must NEVER error, NEVER write stderr: any fault → silent exit 0.
        sys.exit(0)
