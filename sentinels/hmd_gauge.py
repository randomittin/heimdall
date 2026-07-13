#!/usr/bin/env python3
"""
hmd_gauge.py — the Row2 full-bleed context gauge for the Heimdall statusline.

A single text row spanning EXACTLY `width` visible cells: a run of
background-colored space cells forming a horizontal bar, with two fg labels
spliced INSIDE the bar (col 2 and right-aligned). The filled region carries a
24-bit background RAMP dark->bright; the empty track is a dim alternating
stripe. Two label strings sit over the bar preserving each cell's background:

  left  (over the fill, white bold) : `CTX <pct>% · ↓<tokens>`
  right (over the track, faint)     : `7d <pct>% · $<cost> · <dur>`

Build-once / downgrade-once
---------------------------
Like hmd-statusline.py, the row is BUILT in 24-bit truecolor + full unicode and
then handed to `caps.emit()`, which rewrites every standalone `48;2`/`38;2` SGR
to the detected tier (256 / 16) or strips it (mono) in a single pass. Because
`caps.emit`'s rewriter matches ONLY standalone `\\033[(38|48);2;r;g;bm`
sequences, each colour is emitted as its own escape (never combined into one
multi-parameter SGR) so the tier downgrade always fires. On a mono / no-colour
tier the coloured cell path is skipped entirely in favour of a plain ASCII
proportional bar `[####----]` — never a stripped run of blank spaces.

ANSI budget
-----------
The ramp is QUANTIZED: a new ramp colour is chosen only every
`ceil(width/40)` cells, capping distinct ramp SGRs at ~40 per row regardless of
width. A background SGR is emitted only when the cell background actually
changes from the previous cell, and foreground SGRs only bracket the label
glyphs — so a full-width row stays well under the escape-byte budget.

Standalone, exit-safe: imports only hmd_termcaps (for the tier downgrade) and
the stdlib. No import into hmd-statusline.py — no cycle. `render_gauge` never
raises for any input; it degrades to the ASCII bar on any unexpected state.
"""
import os
import math
import contextlib
import importlib.util

_HERE = os.path.dirname(os.path.abspath(__file__))
# Reuse the SAME termcaps tier machinery hmd-statusline.py uses (truecolor ->
# 256 -> 16 -> mono). Imported by path so this module stays a leaf (no cycle).
_tcspec = importlib.util.spec_from_file_location(
    "hmd_termcaps", os.path.join(_HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec)
_tcspec.loader.exec_module(TC)

# ── ramp anchors (24-bit RGB) ────────────────────────────────────────────────
# normal fill:  #1E2F73 -> #4264FF -> #5AD7E6   (deep indigo -> brand blue -> cyan)
# pct >= 70:    #4264FF -> #FFCB57              (brand blue -> gold tip)
# pct >= 90:    #FFCB57 -> #FF6B6B              (gold -> red tip)
DARK = (0x1E, 0x2F, 0x73)   # #1E2F73
BLUE = (0x42, 0x64, 0xFF)   # #4264FF
CYAN = (0x5A, 0xD7, 0xE6)   # #5AD7E6
GOLD = (0xFF, 0xCB, 0x57)   # #FFCB57
RED = (0xFF, 0x6B, 0x6B)    # #FF6B6B
# empty-track alternating stripe cells (near-black, low contrast)
TRACK_A = (0x18, 0x1B, 0x24)  # #181B24
TRACK_B = (0x14, 0x16, 0x1E)  # #14161E
_TRACK_BGS = (TRACK_A, TRACK_B)

# label foregrounds
FG_WHITE = (0xFF, 0xFF, 0xFF)   # left label, bold
FG_FAINT = (0x9A, 0xA4, 0xB2)   # right label, faint gray (#9AA4B2)

# thresholds
GOLD_AT = 70
RED_AT = 90

# splice geometry / tier gates
_LEFT_COL = 2          # left label begins at cell index 2
_RIGHT_PAD = 2         # right label ends `_RIGHT_PAD` cells before the edge
_MIN_LABELS = 40       # width < this  -> bar only, no labels
_MIN_RIGHT = 60        # width < this  -> drop the right label

_MIDDOT = "·"     # ·  (downgrades to '.' on ascii tier)
_ARROW = "↓"      # ↓  (downgrades to 'v' on basic/ascii tier)


# ── numeric formatting ───────────────────────────────────────────────────────
def humanize_tokens(n):
    """1 234 -> '1.2k', 708 000 -> '708k', 1 200 000 -> '1.2M'. Small -> as-is."""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return ""
    if n < 0:
        n = 0
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        k = n / 1000.0
        return ("%.1fk" % k) if k < 10 else ("%dk" % round(k))
    m = n / 1_000_000.0
    return ("%.1fM" % m) if m < 10 else ("%dM" % round(m))


def humanize_duration(ms):
    """900 000 -> '15m00s', 3 840 000 -> '1h04m', 5 000 -> '5s'. None -> ''."""
    try:
        ms = int(ms)
    except (TypeError, ValueError):
        return ""
    if ms < 0:
        ms = 0
    total_s = ms // 1000
    h, rem = divmod(total_s, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return "%dh%02dm" % (h, m)
    if m > 0:
        return "%dm%02ds" % (m, s)
    return "%ds" % s


def _pct_int(p):
    """Clamp a percentage to a display integer in [0, 999]. None -> 0."""
    try:
        v = round(float(p))
    except (TypeError, ValueError):
        return 0
    return max(0, min(999, int(v)))


# ── ramp ─────────────────────────────────────────────────────────────────────
def _lerp(a, b, t):
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    return (round(a[0] + (b[0] - a[0]) * t),
            round(a[1] + (b[1] - a[1]) * t),
            round(a[2] + (b[2] - a[2]) * t))


def ramp_color(t, pct):
    """Fill colour at fraction t in [0,1]. The endpoints REMAP by pct: gold tip
    at >=70, red tip at >=90 — else the 3-stop indigo->blue->cyan gradient."""
    if pct >= RED_AT:
        return _lerp(GOLD, RED, t)
    if pct >= GOLD_AT:
        return _lerp(BLUE, GOLD, t)
    if t <= 0.5:
        return _lerp(DARK, BLUE, t / 0.5)
    return _lerp(BLUE, CYAN, (t - 0.5) / 0.5)


# ── SGR helpers (each colour a STANDALONE escape so caps.emit can rewrite it) ──
def _bg(rgb):
    return "\033[48;2;%d;%d;%dm" % rgb


def _fg(rgb):
    return "\033[38;2;%d;%d;%dm" % rgb


def _ascii_bar(width, pct):
    """Mono / no-colour proportional bar, EXACTLY `width` chars: `[####----]`."""
    if width <= 0:
        return ""
    if width < 3:
        return "#" * width
    inner = width - 2
    fill = max(0, min(inner, round(pct / 100.0 * inner)))
    return "[" + ("#" * fill) + ("-" * (inner - fill)) + "]"


def _fill_count(width, pct):
    """Filled cell count = round(pct/100 * width), clamped to [0, width]."""
    return max(0, min(width, round(pct / 100.0 * width)))


def _splice(cells, start, text, fg, bold):
    """Overwrite the glyphs of `cells[start:start+len(text)]` with `text`,
    setting fg/bold but PRESERVING each cell's existing background. Out-of-range
    glyphs are dropped (never grows the row)."""
    n = len(cells)
    for i, ch in enumerate(text):
        j = start + i
        if 0 <= j < n:
            cells[j][1] = ch
            cells[j][2] = fg
            cells[j][3] = bold


def _serialize(cells):
    """Cell array -> ANSI string. A background SGR fires only when the bg
    changes; fg/bold SGRs only bracket label glyphs. Trailing reset."""
    out = []
    cur_bg = cur_fg = cur_bold = None
    for bg, ch, fg, bold in cells:
        if bg != cur_bg:
            out.append(_bg(bg))
            cur_bg = bg
        if bold != cur_bold:
            out.append("\033[1m" if bold else "\033[22m")
            cur_bold = bold
        if fg != cur_fg:
            out.append(_fg(fg) if fg is not None else "\033[39m")
            cur_fg = fg
        out.append(ch)
    out.append("\033[0m")
    return "".join(out)


def _build_cells(width, pct):
    """A `width`-long cell array: [bg_rgb, char, fg_rgb_or_None, bold_bool].
    Filled cells carry the quantized ramp; the tip cell is forced to the ramp
    endpoint; empty cells carry the alternating track stripe."""
    fill = _fill_count(width, pct)
    step = max(1, math.ceil(width / 40.0))
    denom = max(1, fill - 1)
    cells = []
    for i in range(width):
        if i < fill:
            # quantize to `step`-cell blocks; force the tip to the endpoint.
            qi = fill - 1 if i == fill - 1 else (i // step) * step
            bg = ramp_color(qi / denom, pct)
        else:
            bg = _TRACK_BGS[i % 2]
        cells.append([bg, " ", None, False])
    return cells


def render_gauge(width, used_pct, tokens, five_hour_pct, seven_day_pct, cost_usd,
                 duration_ms, caps, ctx_pct=None):
    """Render the Row2 context gauge as ONE row of EXACTLY `width` visible cells.

    width         : total visible cell count of the row
    used_pct      : context-window used percentage — drives the FILL (None -> 0 fill)
                    and the left `CTX <pct>%` label
    tokens        : input token count (humanized in the left label)
    five_hour_pct : rate_limits.five_hour.used_percentage — the 5-hour SESSION limit,
                    shown in the right readout as `5h <n>%` (omitted if None)
    seven_day_pct : rate_limits.seven_day.used_percentage (omitted if None)
    cost_usd      : session cost (right label, `$%.2f`)
    duration_ms   : session duration (right label, `1h04m`/`12m30s`)
    caps          : hmd_termcaps.Caps — drives the tier downgrade at emit time
    ctx_pct       : context % echoed in the RIGHT readout as `ctx <n>%` (None omits it;
                    the caller passes it only at the widest tier where the readout
                    shows). The right readout reads `ctx <n>% · 5h <n>% · 7d <n>% ·
                    $<cost> · <dur>`, each part OMITTED when its source is absent
                    (never a fabricated `0%`).

    Returns a tier-appropriate string: truecolor bg ramp downgraded to 256/16,
    or a plain ASCII proportional bar on a mono tier. Never raises.
    """
    try:
        try:
            width = int(width)
        except (TypeError, ValueError):
            return ""
        if width <= 0:
            return ""

        pct = 0.0 if used_pct is None else float(used_pct)
        if pct < 0.0:
            pct = 0.0

        # ── mono / no-colour: a plain ASCII proportional bar, exact width ──
        if caps is None or not caps.use_color():
            return _ascii_bar(width, pct)

        cells = _build_cells(width, pct)

        # ── labels (skipped entirely on the narrowest tier) ──
        if width >= _MIN_LABELS:
            # left label over the fill, white bold
            left = "CTX %d%%" % _pct_int(pct)
            tok = humanize_tokens(tokens)
            if tok:
                left += " %s %s%s" % (_MIDDOT, _ARROW, tok)
            left = left[:max(0, width - _LEFT_COL)]
            left_end = _LEFT_COL + len(left)
            _splice(cells, _LEFT_COL, left, FG_WHITE, True)

            # right label over the track end, faint — dropped when too narrow. A dual
            # limits readout: context % AND the 5-hour session limit %, then 7d/cost/dur.
            if width >= _MIN_RIGHT:
                right_parts = []
                if ctx_pct is not None:
                    right_parts.append("ctx %d%%" % _pct_int(ctx_pct))
                if five_hour_pct is not None:
                    right_parts.append("5h %d%%" % _pct_int(five_hour_pct))
                if seven_day_pct is not None:
                    right_parts.append("7d %d%%" % _pct_int(seven_day_pct))
                if cost_usd is not None:
                    with contextlib.suppress(TypeError, ValueError):
                        right_parts.append("$%.2f" % float(cost_usd))
                dur = humanize_duration(duration_ms)
                if dur:
                    right_parts.append(dur)
                right = (" %s " % _MIDDOT).join(right_parts)
                if right:
                    start = width - len(right) - _RIGHT_PAD
                    # never overlap the left label; drop the right label if it
                    # would collide on a cramped bar.
                    if start >= left_end:
                        _splice(cells, start, right, FG_FAINT, False)

        row = _serialize(cells)
        # single tier-downgrade pass (truecolor+full = byte-identical no-op).
        return caps.emit(row)
    except Exception:
        # exit-safe: any unexpected state degrades to the ASCII bar.
        try:
            return _ascii_bar(int(width), 0.0 if used_pct is None else float(used_pct))
        except Exception:
            return ""


if __name__ == "__main__":
    import sys
    caps = TC.detect(sys.argv)
    w = 80
    for a in sys.argv[1:]:
        if a.isdigit():
            w = int(a)
    print(render_gauge(w, 42, 708000, 55, 12, 0.87, 3_840_000, caps, ctx_pct=42))
