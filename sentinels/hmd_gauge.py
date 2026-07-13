#!/usr/bin/env python3
"""
hmd_gauge.py — Spec v2 gauges for the Heimdall statusline.

Two renderers live here, both leaf-standalone (import only hmd_termcaps + stdlib):

1. render_gauge  — Row 2 "context gauge" (Spec v2 §2). ONE text row of EXACTLY
   `width` visible cells: a run of background-coloured space cells forming a
   horizontal bar with two fg labels spliced INSIDE it.

     • Blue shader: the FILLED region carries a per-cell 24-bit background ramp
       #1E2F73 → #4264FF → #5AD7E6 (deep indigo → brand blue → cyan), interpolated
       per filled cell. At used ≥70% the TIP cell(s) remap to gold #FFCB57; at
       ≥90% the tip remaps to red #FF6B6B — tip-only, the rest of the fill keeps
       its identity ramp (never an all-gold / all-red bar).
     • Track (unfilled): alternating #181B24 / #14161E cells.
     • Inside-left label (over the fill, white bold): `CTX <pct>% · ↓<tokens>`
       (tokens humanized 708000→708k, 1200000→1.2M).
     • Inside-right label (over the track end, faint): `$<cost>` (`$%.2f`). If the
       fill overruns into the right-label cells, that label's fg flips to dark ink
       #0B0C10 for contrast against the bright fill.
     • Width degrade: bar <32c drops `↓tokens`; <26c drops `$cost`.

2. render_micro_gauge — Row 4 "limit micro-gauge" (Spec v2 §2). A small labelled
   rate-limit bar: `<label> <bar> <pct>%` + optional `·<N>h` reset (faint). The
   bar is EXACTLY `width` cells (12c full / 8c mid). The fill ramps from its own
   `hue` (5h cyan #5AD7E6, 7d gold #FFCB57 — passed in) and follows the SAME tip
   rule as the main gauge: gold ≥70 → red ≥90. `micro_text(label, pct, reset_h)`
   is the plain-text (narrow-tier) form; `pct=None` yields the bare label only
   (never a fabricated `0%`).

Build-once / downgrade-once
---------------------------
Each colour is emitted as its OWN standalone `\\033[48;2;r;g;bm` / `\\033[38;2;…m`
escape (never combined into one multi-parameter SGR) so hmd_termcaps.Caps.emit()
— whose rewriter matches ONLY standalone true-colour SGRs — always downgrades
truecolor → 256 (`48;5;N`) → 16 (nearest bright) → mono (stripped). On a mono /
no-colour tier the main gauge degrades to a plain ASCII proportional bar
`[####----]` and the micro-gauge to its plain `micro_text` form.

Neither renderer ever raises for any input; both degrade defensively.
"""
import os
import contextlib
import importlib.util

_HERE = os.path.dirname(os.path.abspath(__file__))
# Reuse the SAME termcaps tier machinery hmd-statusline.py uses (truecolor ->
# 256 -> 16 -> mono). Imported by path so this module stays a leaf (no cycle).
_tcspec = importlib.util.spec_from_file_location(
    "hmd_termcaps", os.path.join(_HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec)
_tcspec.loader.exec_module(TC)

# ── blue-shader ramp anchors (24-bit RGB) ────────────────────────────────────
# The base ramp fills the WHOLE bar: #1E2F73 -> #4264FF -> #5AD7E6 (deep indigo ->
# brand blue -> cyan) by default, or dark->hue->bright derived from a supplied base
# hue (the user's OWN sigil accent) so the bar reads in that identity hue. The gold
# (>=70) / red (>=90) danger warning does NOT remap the whole ramp — it remaps ONLY
# the last TIP_CELLS filled cells (the tip), so e.g. 81% is MOSTLY BLUE with a small
# gold tip (never an all-gold bar).
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
FG_FAINT = (0x9A, 0xA4, 0xB2)   # right label / micro readout, faint gray (#9AA4B2)
FG_INK = (0x0B, 0x0C, 0x10)     # right label over fill — dark ink for contrast
FG_TRACK = (0x3A, 0x3F, 0x49)   # micro-gauge empty ░ cells — ghost gray (#3A3F49)

# thresholds
GOLD_AT = 70
RED_AT = 90
TIP_CELLS = 2          # danger remaps ONLY the last TIP_CELLS filled cells (the tip)

# main-gauge splice geometry / width-degrade gates
_LEFT_COL = 1          # left label begins at cell index 1
_RIGHT_PAD = 1         # right label ends `_RIGHT_PAD` cells before the edge
_DROP_TOKENS = 32      # bar width < this -> drop `↓tokens` from the left label
_DROP_COST = 26        # bar width < this -> drop the `$cost` right label

# micro-gauge glyphs
_FILL_GLYPH = "▓"
_TRACK_GLYPH = "░"

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


def ramp_anchors(base_hue):
    """The three ramp endpoints (dark, mid, bright). base_hue None → the literal
    #1E2F73 → #4264FF → #5AD7E6 blue shader. A given base_hue (an RGB triple)
    derives the ramp from THAT hue: a deep variant (toward black) → the hue → a
    bright variant (toward white). The gold/red danger tips stay hue-independent."""
    if base_hue is None:
        return DARK, BLUE, CYAN
    h = (int(base_hue[0]), int(base_hue[1]), int(base_hue[2]))
    dark = _lerp((0, 0, 0), h, 0.45)              # deep variant of the hue
    bright = _lerp(h, (255, 255, 255), 0.42)      # bright variant of the hue
    return dark, h, bright


def base_ramp_color(t, base_hue=None):
    """Fill colour at fraction t in [0,1] on the BASE ramp: a 3-stop dark->mid->bright
    gradient (default indigo->blue->cyan). NO danger remap — the whole bar carries
    this ramp; the gold/red tip warning is applied per-cell at the TIP only."""
    dark, mid, bright = ramp_anchors(base_hue)
    if t <= 0.5:
        return _lerp(dark, mid, t / 0.5)
    return _lerp(mid, bright, (t - 0.5) / 0.5)


def danger_color(pct):
    """The tip danger tint for a usage percentage: gold at >=70, red at >=90, else
    None (no danger — the bar stays its base ramp). Hue-independent (a signal)."""
    if pct >= RED_AT:
        return RED
    if pct >= GOLD_AT:
        return GOLD
    return None


def ramp_color(t, pct, base_hue=None):
    """Back-compat shim: the base ramp colour at t (the danger tint is applied at the
    tip only, in _build_cells). Retained so any external caller keeps working."""
    return base_ramp_color(t, base_hue)


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


def _splice_right(cells, start, text, fill):
    """Splice the right label with a PER-CELL fg: FG_INK (dark ink) for any cell
    that sits over the fill (j < fill), else FG_FAINT. This is the fill-overrun
    contrast flip from Spec v2 §2 — the bright shader would swallow a faint label,
    so the overlapped glyphs go dark-on-bright while the rest stay faint-on-track."""
    n = len(cells)
    for i, ch in enumerate(text):
        j = start + i
        if 0 <= j < n:
            cells[j][1] = ch
            cells[j][2] = FG_INK if j < fill else FG_FAINT
            cells[j][3] = False


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


def _build_cells(width, pct, base_hue=None):
    """A `width`-long cell array: [bg_rgb, char, fg_rgb_or_None, bold_bool].
    Filled cells carry the per-cell BASE ramp (dark->mid->bright, from base_hue).
    The danger warning REMAPS the last `TIP_CELLS` filled cells to gold (pct>=70) /
    red (pct>=90) — tip-only, so the bar stays its identity hue with a small danger
    tip, never an all-gold/all-red bar. Empty cells carry the alternating track."""
    fill = _fill_count(width, pct)
    denom = max(1, fill - 1)
    danger = danger_color(pct)
    cells = []
    for i in range(width):
        if i < fill:
            bg = base_ramp_color(i / denom, base_hue)   # per-cell interpolation
            if danger is not None and (fill - 1 - i) < TIP_CELLS:
                bg = danger                             # tip-only remap
        else:
            bg = _TRACK_BGS[i % 2]
        cells.append([bg, " ", None, False])
    return cells


def render_gauge(width, used_pct, tokens, cost_usd, caps, base_hue=None, labels=True):
    """Render the Row 2 context gauge as ONE row of EXACTLY `width` visible cells.

    width     : bar width (the statusline clamps 24–40c; this fn honours what it
                is given and always emits exactly that many visible cells).
    used_pct  : context-window used percentage — drives the FILL (None -> 0 fill)
                and the left `CTX <pct>%` label.
    tokens    : input token count (humanized in the left label as `↓<tokens>`).
    cost_usd  : session cost (right label, `$%.2f`; None omits it).
    caps      : hmd_termcaps.Caps — drives the tier downgrade at emit time.
    base_hue  : optional RGB triple for the fill ramp (the user's OWN sigil accent);
                None -> the default blue shader #1E2F73→#4264FF→#5AD7E6. Gold/red
                danger tips (>=70/>=90) stay hue-independent.
    labels    : when False the bar renders CLEAN (fill/track ramp only, no text).

    Returns a tier-appropriate string: truecolor bg ramp downgraded to 256/16, or a
    plain ASCII proportional bar on a mono tier. Never raises.
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

        cells = _build_cells(width, pct, base_hue)
        fill = _fill_count(width, pct)

        if labels:
            # ── inside-left label over the fill, white bold ──
            left = "CTX %d%%" % _pct_int(pct)
            if width >= _DROP_TOKENS:
                tok = humanize_tokens(tokens)
                if tok:
                    left += " %s %s%s" % (_MIDDOT, _ARROW, tok)
            left = left[:max(0, width - _LEFT_COL)]
            left_end = _LEFT_COL + len(left)
            _splice(cells, _LEFT_COL, left, FG_WHITE, True)

            # ── inside-right label over the track end, faint (fg flips over fill) ──
            if width >= _DROP_COST and cost_usd is not None:
                right = ""
                with contextlib.suppress(TypeError, ValueError):
                    right = "$%.2f" % float(cost_usd)
                if right:
                    start = width - len(right) - _RIGHT_PAD
                    # never overlap the left label; drop it if it would collide.
                    if start >= left_end:
                        _splice_right(cells, start, right, fill)

        row = _serialize(cells)
        # single tier-downgrade pass (truecolor+full = byte-identical no-op).
        return caps.emit(row)
    except Exception:
        # exit-safe: any unexpected state degrades to the ASCII bar.
        try:
            return _ascii_bar(int(width), 0.0 if used_pct is None else float(used_pct))
        except Exception:
            return ""


# ── Row 4 limit micro-gauge ───────────────────────────────────────────────────
def micro_text(label, pct=None, reset_h=None):
    """Plain-text (narrow-tier) form of a limit micro-gauge:

        micro_text("5h", 28, 3)     -> "5h 28% ·3h"
        micro_text("7d", 41)        -> "7d 41%"
        micro_text("5h")            -> "5h"          (pct=None -> label only)

    `pct=None` yields the bare label — never a fabricated `0%` (Spec v2 §2). A
    reset (hours) is appended as ` ·<N>h` when supplied."""
    label = str(label)
    if pct is None:
        return label
    s = "%s %d%%" % (label, _pct_int(pct))
    if reset_h is not None:
        with contextlib.suppress(TypeError, ValueError):
            s += " %s%dh" % (_MIDDOT, int(reset_h))
    return s


def render_micro_gauge(width, hue, pct, caps, label, reset_h=None):
    """Render a Row 4 rate-limit micro-gauge: `<label> <bar> <pct>%` + optional
    `·<N>h` reset, where the bar is EXACTLY `width` visible cells of `▓` (fill) /
    `░` (track).

    width    : bar cell count (12c full / 8c mid).
    hue      : fill RGB — 5h cyan #5AD7E6, 7d gold #FFCB57 (caller-supplied). The
               fill ramps dark(hue)->hue->bright(hue) and, per the SAME rule as the
               main gauge, remaps its tip to gold (>=70) / red (>=90).
    pct      : used percentage. None -> bare label only (never a fabricated `0%`).
    caps     : hmd_termcaps.Caps — tier downgrade at emit time.
    label    : leading tag (`5h` / `7d`).
    reset_h  : optional reset hours -> ` ·<N>h` faint suffix.

    On a mono / no-colour tier (or width<=0) returns the plain `micro_text` form.
    Never raises.
    """
    try:
        try:
            width = int(width)
        except (TypeError, ValueError):
            width = 0

        # pct absent -> bare label only (never a fabricated 0%).
        if pct is None:
            s = micro_text(label, None, reset_h)
            return caps.emit(s) if caps is not None else s

        p = float(pct)
        if p < 0.0:
            p = 0.0

        # mono / no-colour / degenerate width -> plain text.
        if caps is None or not caps.use_color() or width <= 0:
            return micro_text(label, pct, reset_h)

        fill = _fill_count(width, p)
        denom = max(1, fill - 1)
        danger = danger_color(p)

        out = [_fg(FG_FAINT), str(label), " "]
        prev_fg = FG_FAINT
        for i in range(width):
            if i < fill:
                col = base_ramp_color(i / denom, hue)
                if danger is not None and (fill - 1 - i) < TIP_CELLS:
                    col = danger
                glyph = _FILL_GLYPH
            else:
                col = FG_TRACK
                glyph = _TRACK_GLYPH
            if col != prev_fg:
                out.append(_fg(col))
                prev_fg = col
            out.append(glyph)

        tail = " %d%%" % _pct_int(p)
        if reset_h is not None:
            with contextlib.suppress(TypeError, ValueError):
                tail += " %s%dh" % (_MIDDOT, int(reset_h))
        if prev_fg != FG_FAINT:
            out.append(_fg(FG_FAINT))
        out.append(tail)
        out.append("\033[0m")
        return caps.emit("".join(out))
    except Exception:
        with contextlib.suppress(Exception):
            return micro_text(label, pct, reset_h)
        return ""


if __name__ == "__main__":
    import sys
    caps = TC.detect(sys.argv)
    w = 40
    for a in sys.argv[1:]:
        if a.isdigit():
            w = int(a)
    print(render_gauge(w, 71, 708000, 4.12, caps))
    print(render_gauge(w, 81, 708000, 4.12, caps))
    print(render_gauge(w, 93, 708000, 4.12, caps))
    print(render_micro_gauge(12, CYAN, 28, caps, "5h", reset_h=3), "  ",
          render_micro_gauge(12, GOLD, 41, caps, "7d"))
    print(micro_text("5h", 28, 3), "|", micro_text("7d", 41), "|", micro_text("5h"))
