#!/usr/bin/env python3
"""
hmd_termcaps.py — terminal capability detection + graded render fallback for the
Heimdall watchman statusline. Teammates run every terminal; the line must stay
legible and on-brand on all of them:

  iTerm2 / VS Code / kitty / Alacritty : 24-bit truecolor + full unicode (native)
  Apple Terminal.app                   : 256-color MAX, NO 24-bit — raw truecolor
                                         renders garish, so downgrade to nearest-256
  tmux / screen                        : 24-bit SGR is swallowed unless the user
                                         sets `Tc`/`RGB` + `set -g allow-passthrough
                                         on`; rather than bet on that we render a
                                         passthrough-safe 256-color line
  dumb / CI / no-unicode               : ASCII only — no ESC-color, no half-blocks,
                                         no emoji, but still branded and readable

Design — build once, downgrade once
-----------------------------------
hmd-statusline.py builds its line in 24-bit truecolor + full unicode exactly as
before, then hands the finished bytes to Caps.emit(), which downgrades in a SINGLE
pass:
  • color  — rewrites 24-bit `38;2;r;g;b` / `48;2;r;g;b` SGR to the detected tier
             (nearest xterm-256 `38;5;n`, nearest ANSI-16 `3n`/`9n`, or stripped
             for mono).
  • unicode — translates half-blocks / emoji / box glyphs to basic or ASCII.
The truecolor+full path is a byte-for-byte NO-OP, so the existing conformance
(conformance/statusline/viral-statusline.fixture.sh) stays green, and every
fallback lives in one tested module.

Tiers
-----
  color   : truecolor | 256 | 16 | mono
  unicode : full | basic | ascii

Detection precedence (detect())
-------------------------------
  1. HEIMDALL_STATUSLINE_MODE override (truecolor|256|16|mono|ascii|auto) — the
     teammate escape hatch when auto-detect is wrong (Warp especially).
  2. NO_COLOR / --no-color / --plain / TERM=dumb  -> mono (dumb also -> ascii).
  3. tmux/screen ($TMUX set, or TERM=screen*/tmux*) -> cap at 256, NEVER truecolor.
     24-bit SGR does not survive tmux without `set -g allow-passthrough on` and a
     `Tc`/`RGB` terminal-overrides entry; passthrough-safe 256 always renders.
  4. COLORTERM=truecolor|24bit -> truecolor. An explicit advertisement is the
     strongest positive signal (iTerm2/VS Code/kitty/Alacritty/Warp all set it).
  5. TERM_PROGRAM=Apple_Terminal (and NOT already truecolor) -> 256. Terminal.app
     has no 24-bit path; this is the "never raw truecolor to Terminal.app" rule.
     (COLORTERM wins over this on purpose: a terminal that explicitly claims
     truecolor is honored; bare Terminal.app never sets COLORTERM.)
  6. TERM=*256color* -> 256.
  7. TERM set (not dumb) -> 16.
  8. otherwise -> mono.
"""
import os
import re
import sys

# ── color tiers ───────────────────────────────────────────────────────────────
TRUECOLOR = "truecolor"
C256 = "256"
C16 = "16"
MONO = "mono"
# ── unicode tiers ─────────────────────────────────────────────────────────────
FULL = "full"
BASIC = "basic"
ASCII = "ascii"

_MODES = {"truecolor", "256", "16", "mono", "ascii", "auto"}

_ANSI = re.compile(r"\033\[[0-9;]*m")
# only the 24-bit true-color SGR sequences are rewritten; 0m/1m/39m/49m pass through
_TC_SGR = re.compile(r"\033\[(38|48);2;(\d{1,3});(\d{1,3});(\d{1,3})m")

# ── glyph downgrade tables ────────────────────────────────────────────────────
# FULL = identity (no translation). BASIC keeps line-drawing + bullets but drops
# pixel half-blocks and emoji-presentation symbols. ASCII is pure 7-bit.
_BASIC_MAP = {
    "▀": "'", "▄": ".", "█": "#", "▓": "#", "░": ":", "▔": "'", "▁": ".",
    "▐": "|", "▌": "|", "▕": "|", "▏": "|",
    "⚡": "*", "⟳": "~", "↓": "v", "◉": "O",
}
_ASCII_MAP = {
    "▀": '"', "▄": ".", "█": "#", "▓": "#", "░": "-", "▔": '"', "▁": ".",
    "▐": "[", "▌": "]", "▕": "[", "▏": "]",
    "│": "|", "─": "-", "—": "-",
    "●": "o", "◦": ".", "◉": "@", "·": ".", "•": "o",
    "✓": "+", "✗": "x", "✕": "x", "⚡": "!", "⟳": "~", "↓": "v",
    "ö": "o", "ø": "o", "ō": "o",
}
_BASIC_TT = str.maketrans(_BASIC_MAP)
_ASCII_TT = str.maketrans(_ASCII_MAP)


# ── display width (double-width aware for right-pin math when unicode==full) ────
def _is_wide(cp):
    """East-Asian-Wide / emoji-presentation codepoints render as 2 cells. Our glyph
    set is width-1 except emoji-presentation symbols (⚡ U+26A1 and the 1F000+ block)."""
    return (
        cp == 0x26A1                       # ⚡ emoji lightning
        or 0x1100 <= cp <= 0x115F          # Hangul Jamo
        or 0x2E80 <= cp <= 0x303E          # CJK radicals / Kangxi / punctuation
        or 0x3041 <= cp <= 0x33FF          # Hiragana .. CJK compat
        or 0x3400 <= cp <= 0x4DBF          # CJK ext A
        or 0x4E00 <= cp <= 0x9FFF          # CJK unified
        or 0xA000 <= cp <= 0xA4CF          # Yi
        or 0xAC00 <= cp <= 0xD7A3          # Hangul syllables
        or 0xF900 <= cp <= 0xFAFF          # CJK compat ideographs
        or 0xFE30 <= cp <= 0xFE4F          # CJK compat forms
        or 0xFF00 <= cp <= 0xFF60          # fullwidth forms
        or 0xFFE0 <= cp <= 0xFFE6          # fullwidth signs
        or 0x1F000 <= cp <= 0x1FAFF        # emoji / symbols & pictographs
        or 0x20000 <= cp <= 0x3FFFD        # CJK ext B+
    )


def display_width(s, unicode_tier=FULL):
    """Visible terminal cell width of s after ANSI strip. Emoji count as 2 cells
    only under unicode==full (after downgrade every glyph is ASCII width-1)."""
    s = _ANSI.sub("", s)
    if unicode_tier != FULL:
        return len(s)
    w = 0
    for ch in s:
        cp = ord(ch)
        if cp == 0 or 0x0300 <= cp <= 0x036F or cp in (0x200B, 0x200D, 0xFE0F):
            continue                       # NUL / combining marks / ZWSP / ZWJ / VS16
        w += 2 if _is_wide(cp) else 1
    return w


# ── truecolor -> nearest xterm-256 ────────────────────────────────────────────
_CUBE = (0, 95, 135, 175, 215, 255)


def _cube_idx(v):
    best, bd = 0, 1_000_000
    for i, s in enumerate(_CUBE):
        d = abs(s - v)
        if d < bd:
            bd, best = d, i
    return best


def rgb_to_256(r, g, b):
    """Nearest xterm-256 index: compares the 6x6x6 color cube against the 24-step
    grayscale ramp and picks whichever is closer in RGB distance."""
    ri, gi, bi = _cube_idx(r), _cube_idx(g), _cube_idx(b)
    cube_i = 16 + 36 * ri + 6 * gi + bi
    cr, cg, cb = _CUBE[ri], _CUBE[gi], _CUBE[bi]
    dc = (cr - r) ** 2 + (cg - g) ** 2 + (cb - b) ** 2
    # grayscale ramp: index 232..255 -> value 8,18,..,238 (10-step)
    gray = (r + g + b) // 3
    gidx = min(23, max(0, round((gray - 8) / 10.0)))
    gray_i = 232 + gidx
    gv = 8 + 10 * gidx
    dg = (gv - r) ** 2 + (gv - g) ** 2 + (gv - b) ** 2
    return gray_i if dg < dc else cube_i


# ── truecolor -> nearest ANSI-16 ──────────────────────────────────────────────
def rgb_to_16(r, g, b, bg=False):
    """Nearest ANSI-16 SGR parameter. Maps to one of the 8 base colors, using the
    bright (90-97 / 100-107) variant for light colors."""
    lum = (r * 299 + g * 587 + b * 114) // 1000
    bright = 1 if (lum > 150 or max(r, g, b) > 200) else 0
    thr = 100
    idx = (1 if r >= thr else 0) + (2 if g >= thr else 0) + (4 if b >= thr else 0)
    if bg:
        base = 100 if bright else 40
    else:
        base = 90 if bright else 30
    return base + idx


class Caps:
    """Resolved terminal capability tier + the emit() downgrade pass."""

    __slots__ = ("color", "unicode", "tmux", "term_program", "mode")

    def __init__(self, color, unicode, tmux, term_program, mode):
        self.color = color
        self.unicode = unicode
        self.tmux = tmux
        self.term_program = term_program
        self.mode = mode

    def use_color(self):
        return self.color != MONO

    def width(self, s):
        return display_width(s, self.unicode)

    def _sgr_sub(self, m):
        kind = m.group(1)
        r, g, b = int(m.group(2)), int(m.group(3)), int(m.group(4))
        if self.color == C256:
            n = rgb_to_256(r, g, b)
            return "\033[%s;5;%dm" % (kind, n)
        if self.color == C16:
            return "\033[%dm" % rgb_to_16(r, g, b, bg=(kind == "48"))
        return ""  # mono (defensive; mono strips all ANSI below anyway)

    def emit(self, text):
        """Downgrade finished truecolor+full bytes to this tier. NO-OP for
        truecolor+full so the native path is byte-identical."""
        if self.color == TRUECOLOR and self.unicode == FULL:
            return text
        # 1) color
        if self.color == MONO:
            text = _ANSI.sub("", text)
        elif self.color in (C256, C16):
            text = _TC_SGR.sub(self._sgr_sub, text)
        # 2) unicode
        if self.unicode == BASIC:
            text = text.translate(_BASIC_TT)
        elif self.unicode == ASCII:
            text = text.translate(_ASCII_TT)
        return text


def _unicode_tier(env, term):
    if term == "dumb":
        return ASCII
    loc = (env.get("LC_ALL") or env.get("LC_CTYPE") or env.get("LANG") or "").lower()
    if "utf-8" in loc or "utf8" in loc:
        return FULL
    if loc:                       # a non-UTF-8 locale is set -> be conservative
        return BASIC
    return FULL                   # unset locale: modern terminals are UTF-8 by default


def detect(argv=None, env=None):
    """Resolve the terminal capability tier from env (+ argv for --no-color/--plain
    that hooks/statusline.sh passes through)."""
    env = os.environ if env is None else env
    argv = sys.argv if argv is None else argv

    def g(k):
        return env.get(k) or ""

    colorterm = g("COLORTERM").lower()
    term = g("TERM").lower()
    term_prog = g("TERM_PROGRAM")
    tmux = bool(g("TMUX")) or term.startswith(("screen", "tmux"))
    uni = _unicode_tier(env, term)

    mode = g("HEIMDALL_STATUSLINE_MODE").strip().lower() or "auto"
    if mode not in _MODES:
        mode = "auto"

    no_color = (env.get("NO_COLOR") is not None) or ("--no-color" in argv) or ("--plain" in argv)

    # ── forced modes (teammate override) ──
    if mode == "truecolor":
        return Caps(TRUECOLOR, uni, tmux, term_prog, mode)
    if mode == "256":
        return Caps(C256, uni, tmux, term_prog, mode)
    if mode == "16":
        return Caps(C16, uni, tmux, term_prog, mode)
    if mode == "mono":
        return Caps(MONO, uni, tmux, term_prog, mode)
    if mode == "ascii":
        return Caps(MONO, ASCII, tmux, term_prog, mode)

    # ── auto-detect ──
    if no_color or term == "dumb":
        return Caps(MONO, ASCII if term == "dumb" else uni, tmux, term_prog, mode)

    has_tc = colorterm in ("truecolor", "24bit")

    if tmux:
        # 24-bit is unsafe through tmux/screen; render passthrough-safe.
        if "256color" in term or has_tc:
            return Caps(C256, uni, tmux, term_prog, mode)
        return Caps(C16, uni, tmux, term_prog, mode)

    if has_tc:
        return Caps(TRUECOLOR, uni, tmux, term_prog, mode)
    if term_prog == "Apple_Terminal":
        return Caps(C256, uni, tmux, term_prog, mode)
    if "256color" in term:
        return Caps(C256, uni, tmux, term_prog, mode)
    if term:
        return Caps(C16, uni, tmux, term_prog, mode)
    return Caps(MONO, uni, tmux, term_prog, mode)


if __name__ == "__main__":
    c = detect()
    if "--json" in sys.argv:
        import json
        print(json.dumps({"color": c.color, "unicode": c.unicode,
                          "tmux": c.tmux, "mode": c.mode}))
    else:
        print("color=%s unicode=%s tmux=%d mode=%s"
              % (c.color, c.unicode, 1 if c.tmux else 0, c.mode))
