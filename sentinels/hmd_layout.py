#!/usr/bin/env python3
"""
hmd_layout.py — pure row-assembly / layout helpers for the Heimdall statusline.

This module holds ONLY layout/composition primitives. It fetches no data, spawns
no processes, and imports no statusline assembly code — so it never forms an import
cycle with hmd-statusline.py (which imports THIS, not the reverse). Its only
dependency is the leaf hmd_termcaps.display_width for ANSI-stripped, wide-glyph-aware
width measurement; if that can't be loaded the width helper degrades to a plain
ANSI-stripped len (never crash).

SIGIL-KEEP interpretation (load-bearing — RJ constraint, overrides the spec's `▟█▙`)
-----------------------------------------------------------------------------------
The user's OWN 58-hero sigil (hmd_sigil.sigil_render, the current 8×8/`▄` hero block)
STAYS as the LEFT ANCHOR of the statusline. It is NOT retired and NOT replaced by the
spec's compressed `▟█▙` brand glyph. The 3-row content (identity / full-bleed gauge /
gates) lays out in the columns to the RIGHT of the sigil.

Consequently the spec's "full-bleed gauge" is reinterpreted as full-bleed of the
REMAINING width right of the sigil: the gauge's effective width is
`cols - sigil_width - gutter` (see remaining_width / compose_with_sigil). The gauge
must be rendered to exactly that width by the caller so its per-cell background ramp
is neither truncated nor padded with uncolored cells when composed.

(The Row-1 team cluster teammates use the separate compressed 1-row micro mark — NOT
this full sigil. That is a caller concern; this module is glyph-agnostic.)

Every helper is ANSI-safe (escapes carry zero width and are never sliced), wide-glyph
safe (a double-width glyph is dropped whole, never halved), and total: bad/odd inputs
degrade to a sane exact-width result rather than raising.
"""
import os
import re
import importlib.util

# ANSI SGR sequences carry zero visible width; they are copied verbatim and never
# counted or sliced.
ANSI = re.compile(r"\033\[[0-9;]*m")
ELLIPSIS = "…"  # single-cell truncation marker

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_termcaps():
    """Load the sibling hmd_termcaps leaf module by file path, so hmd_layout works
    standalone regardless of sys.path and without an import cycle. Returns None if it
    cannot be loaded (the width helper then degrades to a plain ANSI-stripped len)."""
    try:
        spec = importlib.util.spec_from_file_location(
            "hmd_termcaps", os.path.join(_HERE, "hmd_termcaps.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


_TC = _load_termcaps()
# The unicode tier at which layout math is done. Content is BUILT in full unicode and
# downgraded later (CAPS.emit at write time), so measuring at FULL is the correct
# layout width. Falls back to the literal "full" if termcaps is unavailable.
FULL = getattr(_TC, "FULL", "full")


# ── width ────────────────────────────────────────────────────────────────────
def _plain_len(s):
    return len(ANSI.sub("", s))


def vis_width(s, unicode_tier=FULL):
    """Printable terminal-cell width of `s` after ANSI strip, wide-glyph aware.

    Delegates to hmd_termcaps.display_width (East-Asian-Wide / emoji-presentation
    codepoints count as 2 cells under the full unicode tier; combining marks / ZWSP /
    ZWJ / VS16 count as 0). Degrades to a plain ANSI-stripped character count if
    termcaps is unavailable. Non-str input is coerced to str; never raises."""
    if not isinstance(s, str):
        s = "" if s is None else str(s)
    if _TC is None:
        return _plain_len(s)
    try:
        return _TC.display_width(s, unicode_tier)
    except Exception:
        return _plain_len(s)


def _char_width(ch, unicode_tier):
    """Visible width of a single (already non-ANSI) character."""
    return vis_width(ch, unicode_tier)


# ── the exact-width primitive ──────────────────────────────────────────────────
def pad_or_truncate(s, width, unicode_tier=FULL, ellipsis=ELLIPSIS):
    """Return `s` adjusted to EXACTLY `width` visible cells.

    - width <= 0            → "" (empty).
    - vis(s) == width       → `s` unchanged.
    - vis(s) <  width       → pad with trailing spaces to `width`. Any dangling SGR is
                              reset BEFORE the pad so a background/foreground color can
                              never bleed into the trailing spaces.
    - vis(s) >  width       → truncate to `width`, appending `ellipsis` (1 cell) as the
                              last visible cell. ANSI escapes are copied verbatim (never
                              sliced); a wide glyph is dropped whole (never halved); any
                              SGR left open by the clip is reset so color never bleeds.

    This is the "each row exactly COLUMNS" primitive the full-bleed layout is built on.
    """
    if not isinstance(s, str):
        s = "" if s is None else str(s)
    if width is None:
        return s
    if width <= 0:
        return ""

    w = vis_width(s, unicode_tier)
    if w == width:
        return s

    has_ansi = bool(ANSI.search(s))

    if w < width:
        pad = " " * (width - w)
        # close any open SGR before the pad so color/bg never bleeds into the spaces
        if has_ansi:
            return s + "\033[0m" + pad
        return s + pad

    # w > width → truncate. Reserve one cell for the ellipsis.
    el_w = vis_width(ellipsis, unicode_tier) or 1
    budget = width - el_w
    if budget < 0:
        budget = 0

    out = []
    used = 0
    pos = 0
    n = len(s)
    while pos < n:
        mtch = ANSI.match(s, pos)
        if mtch:
            out.append(mtch.group(0))   # zero-width, copy verbatim
            pos = mtch.end()
            continue
        ch = s[pos]
        cw = _char_width(ch, unicode_tier)
        if used + cw > budget:
            break                       # dropping this (possibly wide) glyph whole
        out.append(ch)
        used += cw
        pos += 1

    body = "".join(out)
    result = body + ellipsis
    # the ellipsis + body may be < width when a dropped wide glyph left a 1-cell gap
    gap = width - (used + el_w)
    if gap > 0:
        result += " " * gap
    if has_ansi:
        result += "\033[0m"             # re-close any SGR the clip left dangling
    return result


# ── left / right composition ─────────────────────────────────────────────────
def left_right(left, right, width, unicode_tier=FULL):
    """Compose one row: `left` at the left, `right` right-aligned, filled with a space
    gap of `width - vis(left) - vis(right)` between them. Result is EXACTLY `width`.

    On overflow (left+right wider than width) the LEFT is truncated first (with an
    ellipsis) to make room for the full right segment. If `right` alone is wider than
    `width`, the left is dropped entirely and the right is truncated to `width`."""
    if width is None:
        return (left or "") + (right or "")
    if width <= 0:
        return ""
    left = "" if left is None else str(left)
    right = "" if right is None else str(right)

    lw = vis_width(left, unicode_tier)
    rw = vis_width(right, unicode_tier)

    if lw + rw <= width:
        return left + " " * (width - lw - rw) + right

    # overflow
    if rw >= width:
        # right cannot fully fit → drop left, truncate right to the whole width
        return pad_or_truncate(right, width, unicode_tier)

    budget_left = width - rw
    left_fit = pad_or_truncate(left, budget_left, unicode_tier)
    return left_fit + right


# ── sigil-anchored assembly (the key one) ───────────────────────────────────────
def _sigil_width(sigil_rows, unicode_tier=FULL):
    if not sigil_rows:
        return 0
    return max(vis_width(r, unicode_tier) for r in sigil_rows)


def _resolve_geometry(sigil_rows, cols, gutter, unicode_tier):
    """Clamp the sigil width + gutter to the terminal so the content width is always
    >= 0 and (sig_w + gutter + content_width) == cols exactly. Degrades on tiny
    terminals: gutter shrinks before content, and a sigil wider than `cols` is itself
    clipped to `cols` (content then 0)."""
    cols = max(0, int(cols))
    gutter = max(0, int(gutter))
    sig_w = min(_sigil_width(sigil_rows, unicode_tier), cols)
    gutter = min(gutter, max(0, cols - sig_w))
    content_width = cols - sig_w - gutter
    return sig_w, gutter, content_width


def remaining_width(sigil_rows, cols, gutter=2, unicode_tier=FULL):
    """The full-bleed content/gauge width right of the sigil: `cols - sigil_width -
    gutter` (SIGIL-KEEP interpretation of the spec's full-bleed). The caller renders
    the gauge to EXACTLY this width so its per-cell bg ramp is neither truncated nor
    padded with uncolored cells when composed via compose_with_sigil."""
    _sig_w, _gutter, content_width = _resolve_geometry(
        sigil_rows, cols, gutter, unicode_tier)
    return content_width


def compose_with_sigil(sigil_rows, content_rows, cols, gutter=2, unicode_tier=FULL):
    """Lay the content rows out to the RIGHT of the sigil (the left anchor).

    For each output row i (i in range(max(len(sigil_rows), len(content_rows)))):
        `<sigil_rows[i] padded to sig_w>` + `<gutter spaces>` + `<content_rows[i]
        pad_or_truncated to content_width>`
    - Rows i >= len(sigil_rows) get a BLANK sig_w-wide prefix (so content rows below
      the sigil height still align under the content column).
    - Rows i >= len(content_rows) get an empty (space-padded) content cell.
    - content_width == cols - sig_w - gutter (== remaining_width). A gauge already
      rendered to remaining_width passes through untouched (no re-pad / no truncate).
    Every returned row is EXACTLY `cols` visible cells. Empty inputs → []."""
    sigil_rows = list(sigil_rows or [])
    content_rows = list(content_rows or [])
    if not sigil_rows and not content_rows:
        return []

    sig_w, gutter, content_width = _resolve_geometry(
        sigil_rows, cols, gutter, unicode_tier)
    gut = " " * gutter

    n = max(len(sigil_rows), len(content_rows))
    out = []
    for i in range(n):
        sig = sigil_rows[i] if i < len(sigil_rows) else ""
        content = content_rows[i] if i < len(content_rows) else ""
        sig_cell = pad_or_truncate(sig, sig_w, unicode_tier)
        content_cell = pad_or_truncate(content, content_width, unicode_tier)
        out.append(sig_cell + gut + content_cell)
    return out


# ── width tiers ────────────────────────────────────────────────────────────────
def width_tier(cols):
    """Classify a column count into a layout tier so the assembler can drop segments:
        full   : cols >= 100   (all rows, all segments)
        mid    : 60 <= cols < 100
        narrow : 40 <= cols < 60
        tiny   : cols < 40     (single-line fallback)
    Boundaries: 100 → full, 60 → mid, 40 → narrow."""
    try:
        cols = int(cols)
    except (TypeError, ValueError):
        cols = 0
    if cols >= 100:
        return "full"
    if cols >= 60:
        return "mid"
    if cols >= 40:
        return "narrow"
    return "tiny"
