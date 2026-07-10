#!/usr/bin/env python3
"""
hmd_sigil.py — deterministic watchman sigil from a HAID/identity seed.
Every Heimdall identity (user or agent) gets a unique, reproducible pixel watchman.
Same seed -> same sigil, forever. Used three ways:
  - compact  : the always-on statusline face (your watchman)
  - glyph     : a single colored cell for the team wall (teammates)
  - large     : the share card / banner / README avatar

Render is ANSI half-blocks (each text cell = 2 vertical pixels via ▀). A 2:1
monospace cell + half-block makes each PIXEL ~square, so an N×N pixel grid renders
as an EXACT SQUARE silhouette. The base grid is 8×8 px -> 8 cols × 4 text-rows: a
true square, width-stable in any monospace terminal (see .planning/ref).

ONE SHARED RENDER CORE
----------------------
`sigil_render(haid, size, caps)` is the single implementation every surface
(statusline, banner, `hmd sigil`, TUI) renders through. It was previously the case
that the statusline downgraded colors (via hmd_termcaps.Caps.emit) while the CLI +
banner emitted RAW 24-bit truecolor SGR blind — on a 256-color / tmux / 16-color
terminal that raw SGR is quantized unpredictably or swallowed (bg dropped), which
collapses the silhouette/eyes = the "morphed sigil" bug. The fix is structural:
sigil_render applies the capability tier ITSELF, so no caller can render blind.

  color tier  : truecolor | 256 (fixed xterm-cube LUT) | 16 (fixed 4-shade) | mono
  unicode tier: full (▀ half-blocks) | basic/ascii (translated by hmd_termcaps)
  sizes       : 'S' 4×4px (4c×2r) · 'M' 8×8px (8c×4r) · 'L' 16×16px (16c×8r)

Deterministic everywhere: same (haid, size, tier) -> byte-identical bytes. The
sha256(HAID) seed picks the silhouette; the transparent/OFF composite is done
BEFORE any downsample (OFF -> DIM filled block) so box-filtering never fringes.

Two ways a grid is born — a HYBRID that always yields a clean, legible face:
  - CURATED   : 4 hand-authored mockup identities (rj/nadia/arjun/priya) ship
                their exact grids + hue, so those seeds match the design 1:1.
  - GENERATED : every other seed (real HAIDs are arbitrary) maps DETERMINISTICALLY
                onto the ported superx SPRITE CAST — a set of hand-authored animal
                characters (owl / fox / cat / rabbit / panda / bear / dog / monk),
                each with its own unmistakable ear-and-body silhouette + hue. The
                hash picks ONE animal (sha256(seed)[0] % 8); the same seed always
                gets the same character. Distinct HAIDs -> distinct recognizable
                animals, never the one muddy guardian blob for everyone.

Both paths then get the universal watchman finish: a full-dark carved VISOR BAND
(grid rows 2+3, edge to edge) holding two FULL-CELL white square EYES (cols 2 & 5,
each punched across rows 2+3 = one whole text cell), with a defined gap between
them and the helm above / shoulders below framing the dark band so the eyes POP.
OFF pixels render as a DIM FILLED block (#13151d) so the face has a solid
silhouette / bounding box instead of fraying into transparent space.

  python3 hmd_sigil.py --seed rj-a3f9 --size compact
  python3 hmd_sigil.py --seed nadia   --size large
  python3 hmd_sigil.py --seed arjun   --size M --tier 256   # tiered render
  python3 hmd_sigil.py --seed arjun   --glyph               # single wall cell
"""
import hashlib, sys, os, argparse, importlib.util
from collections import Counter

# ── shared capability module (single source of the tier LUTs) ──────────────────
# Loaded by absolute path so `hmd_sigil.py` behaves identically whether imported
# (statusline/banner) or run as a script from any cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_tcspec = importlib.util.spec_from_file_location(
    "hmd_termcaps", os.path.join(_HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec); _tcspec.loader.exec_module(TC)

# ── curated identities (canonical mockup) — 4 hand-authored 8x8 faces + fixed hue.
#    pixel values: 0=off, 1=body hue, 2=eye. these seeds match the design pixel-for-pixel.
#    Rows 2+3 carry the eye marker (cols 2 & 5); the universal watchman finish carves
#    the full visor band and re-punches those eyes, so the band is identical for every
#    identity (one strong, consistent brand signature) while the body silhouette varies.
CURATED_GRIDS = {
    'rj':    ["00111100", "01111110", "00200200", "00200200",
              "01111110", "01100110", "00111100", "01100110"],
    'nadia': ["01100110", "01111110", "00200200", "00200200",
              "11111111", "01111110", "01011010", "11000011"],
    'arjun': ["00011000", "00111100", "00200200", "00200200",
              "01111110", "00111100", "00100100", "01100110"],
    'priya': ["01111110", "11111111", "00200200", "00200200",
              "11100111", "01111110", "01100110", "11011011"],
}
CURATED_HUES = {
    'rj':    (45, 212, 191),    # teal
    'nadia': (245, 158, 11),    # amber
    'arjun': (167, 139, 250),   # violet
    'priya': (244, 114, 182),   # pink
}

# ── SUPERX SPRITE CAST (ported) — the generated path is a recognizable ANIMAL, not
#    a blob. The superx dashboard shipped a cast of full-body pixel characters (one
#    per agent role) that READ as characters because each had an unmistakable
#    SILHOUETTE. That cast is ported here to the statusline's 8x8 half-block grid:
#    the distinguishing cues that survive at 4-row terminal scale — EAR shape (top
#    text-row) + BODY silhouette (bottom two text-rows) — are hand-authored per
#    animal; the middle band (rows 2,3) is reserved for the universal watchman finish
#    (carved dark + full-cell eyes at cols 2 & 5), so every animal still reads as a
#    face. Values: 0=off (DIM silhouette block), 1=body hue, 2=eye. Every row is
#    vertically symmetric (mirror about the 3.5 axis) — the render/width invariant.
#    A HAID is mapped DETERMINISTICALLY onto one animal (sha256(seed)[0] % 8), so
#    each dev gets a STABLE, recognizable character forever — 8 animals × distinct
#    per-character hues, never the one muddy guardian for everyone.
ANIMALS = {
    # owl — architect: ear tufts at the outer corners, round tapered body, talons.
    'owl':    ["10000001", "11111111", "01111110", "01111110",
               "01111110", "01111110", "00111100", "01000010"],
    # fox — coder: pointed ears (wide at the base), a slim body, legs + shoes.
    'fox':    ["01000010", "11100111", "01111110", "01111110",
               "00111100", "00111100", "01100110", "11000011"],
    # cat — design: two-pronged pointed ears, slim body.
    'cat':    ["10100101", "01111110", "01111110", "01111110",
               "01111110", "00111100", "00111100", "01100110"],
    # rabbit — test-runner: tall thin centered ears merging into the crown.
    'rabbit': ["00100100", "00111100", "01111110", "01111110",
               "01111110", "01111110", "00111100", "01100110"],
    # panda — lint-quality: small round mid-ears, a wide belly.
    'panda':  ["01100110", "11111111", "01111110", "01111110",
               "11111111", "01111110", "01111110", "01100110"],
    # bear — reviewer: round ears at the extreme corners, a wide head + body.
    'bear':   ["11000011", "11111111", "01111110", "01111110",
               "01111110", "01111110", "01111110", "01100110"],
    # dog — docs-writer: floppy ears hang down the sides (cols 0,7 lit at row 4).
    'dog':    ["01111110", "11111111", "01111110", "01111110",
               "11111111", "01111110", "01111110", "01100110"],
    # monk — superx mascot: bald narrow crown (no ears), robe flares wide at the base.
    'monk':   ["00111100", "01111110", "01111110", "01111110",
               "01111110", "01111110", "11111111", "11111111"],
}
# fixed order → deterministic index from the HAID hash (bash-3.2 test parity too).
ANIMAL_ORDER = ['owl', 'fox', 'cat', 'rabbit', 'panda', 'bear', 'dog', 'monk']
# per-character hue — a well-separated categorical palette echoing the superx role
# colors, so two devs on different animals are also different COLORS (max distinction).
ANIMAL_HUES = {
    'owl':    (52, 152, 219),    # blue
    'fox':    (46, 204, 113),    # green
    'cat':    (224, 86, 160),    # magenta
    'rabbit': (241, 196, 15),    # yellow
    'panda':  (200, 205, 210),   # light slate (patches read against the dark band)
    'bear':   (231, 76, 60),     # red
    'dog':    (26, 188, 156),    # teal
    'monk':   (230, 126, 34),    # orange
}

EYE = (240, 248, 255)   # bright eye glint (aliceblue)
DIM = (19, 21, 29)       # OFF pixel — a DIM FILLED cell (#13151d) -> solid silhouette
OFF = None               # legacy transparent sentinel (kept for color()/glyph back-compat)

W, H = 8, 8
EYE_COLS = (2, W - 1 - 2)   # cols 2 & 5 — symmetric, with a defined gap between them

# pixel-grid resolution per size token. rendered N cols × N/2 text-rows (half-block),
# so each is an EXACT SQUARE: N px wide × N px tall.
SIZES = {'S': 4, 'M': 8, 'L': 16}


def _apply_watchman(g):
    """Universal finish on ANY grid (curated or generated): carve a FULL-DARK visor
    BAND across grid rows 2+3 (edge to edge), then punch FULL-CELL white square eyes
    at cols 2 & 5. Each eye spans both band rows so it fills one whole text cell
    (render pairs rows (2,3) into text-row 1) -> a crisp white ▀+white-bg square, not
    a sliver. The band is dark edge-to-edge so the two eyes are the only lit thing on
    it (helm above + shoulders below frame it vertically) -> the eyes POP."""
    for c in range(W):
        g[2][c] = 0                 # carve the whole visor band dark, both rows,
        g[3][c] = 0                 # so nothing competes with the eyes
    for col in EYE_COLS:            # cols 2 and 5, mirrored
        g[2][col] = 2               # top half of the eye cell
        g[3][col] = 2               # bottom half of the eye cell
    return g

def animal_for(seed):
    """The deterministic animal a HAID maps onto: sha256(seed)[0] % 8, indexed into
    the fixed ANIMAL_ORDER. Same seed -> same animal, forever, on every surface."""
    idx = hashlib.sha256(seed.encode()).digest()[0] % len(ANIMAL_ORDER)
    return ANIMAL_ORDER[idx]

def grid_for(seed, eye_override=None):
    """8x8 vertically-symmetric watchman. Curated for the 4 mockup seeds; every other
    HAID maps deterministically onto a ported superx ANIMAL sprite (recognizable
    character, never a blob). Both paths get the universal watchman finish."""
    if seed in CURATED_GRIDS:
        g = [[int(ch) for ch in row] for row in CURATED_GRIDS[seed]]
        hue = CURATED_HUES[seed]
    else:
        name = animal_for(seed)
        g = [[int(ch) for ch in row] for row in ANIMALS[name]]
        hue = ANIMAL_HUES[name]
    _apply_watchman(g)
    eye = eye_override or EYE
    return g, hue, eye

def color(rgb, layer):  # layer: 'fg' or 'bg'
    if rgb is None:
        return '\033[39m' if layer == 'fg' else '\033[49m'
    code = 38 if layer == 'fg' else 48
    return f'\033[{code};2;{rgb[0]};{rgb[1]};{rgb[2]}m'

def cell_color(v, hue, eye):
    # 0 -> DIM filled block (silhouette), 1 -> body hue, 2 -> eye glint
    return {0: DIM, 1: hue, 2: eye}[v]

def _cell(top, bot):
    """One text cell from a top/bot pixel pair. OFF (None) stays transparent;
    everything else is a filled half-block so the face has a solid bounding box.
    The sigil block is PURE `▀` (fg=top px, bg=bottom px) so every emitted cell has
    identical wcwidth 1 — the width-invariant the conformance goldens assert."""
    if top is None and bot is None:
        return ' '
    if bot is None:
        return color(top, 'fg') + '▀' + '\033[0m'
    if top is None:
        return color(bot, 'fg') + '▄' + '\033[0m'
    return color(top, 'fg') + color(bot, 'bg') + '▀' + '\033[0m'


# ── tier plumbing ──────────────────────────────────────────────────────────────
def tier_caps(color_tier=None, unicode_tier=None):
    """Build a hmd_termcaps.Caps for an EXPLICIT tier (goldens / calibration / the
    --tier CLI flag). Defaults to truecolor + full = the byte-for-byte native path
    (Caps.emit is a NO-OP there), so render()/render_large()/glyph() and every
    existing conformance golden stay byte-identical."""
    ct = color_tier or TC.TRUECOLOR
    ut = unicode_tier or TC.FULL
    return TC.Caps(ct, ut, False, "", ct)

# the native (no-downgrade) caps: shared, cheap, immutable — the default for the
# legacy truecolor surfaces (banner/share/statusline-full path).
_NATIVE = tier_caps()


def _majority(vals):
    """Box-filter majority pixel value over a downsample region. Deterministic:
    the most common value wins; ties break toward the HIGHER value (eye 2 > body 1 >
    off 0) so eyes/body survive shrink instead of being eroded by the dim border."""
    cnt = Counter(vals)
    return max(cnt.items(), key=lambda kv: (kv[1], kv[0]))[0]


def _size_grid(seed, size, eye_override=None):
    """The value grid (0/1/2) at the target size. M is the native 8×8; L is a
    nearest 2× upsample (crisp doubling, no new colors); S is an 8→4 box-filter
    majority downsample done on the COMPOSITED grid (OFF already = DIM filled), so
    shrinking never fringes the silhouette."""
    g, hue, eye = grid_for(seed, eye_override)
    N = SIZES[size]
    if N == W:                                             # M — native 8×8
        vg = g
    elif N == 2 * W:                                       # L — nearest 2× upsample
        vg = [[g[r // 2][c // 2] for c in range(N)] for r in range(N)]
    else:                                                  # S — 8→4 box-majority
        step = W // N
        vg = [[_majority([g[step * R + dr][step * C + dc]
                          for dr in range(step) for dc in range(step)])
               for C in range(N)] for R in range(N)]
    return vg, hue, eye


def sigil_render(haid, size='M', caps=None, eye_override=None, pad='', xscale=1):
    """THE shared watchman renderer — every surface goes through here.

    Builds the value grid at `size`, emits PURE `▀` half-block cells in 24-bit
    truecolor, then downgrades the whole block to `caps` in ONE pass (Caps.emit):
    truecolor = byte-identical NO-OP; 256 = nearest xterm-cube LUT; 16 = fixed
    4-shade; mono/ascii = ANSI stripped + glyphs translated. Because the tier is
    applied HERE, no caller (CLI, banner, TUI) can emit truecolor blind — the
    root cause of the morphed render. Returns a list of lines.

    xscale doubles each cell horizontally (the legacy `large` share form)."""
    caps = caps or _NATIVE
    vg, hue, eye = _size_grid(haid, size, eye_override)
    N = len(vg)
    lines = []
    for tr in range(0, N, 2):   # two pixel-rows per text-row (N is always even)
        line = pad
        for c in range(N):
            top = cell_color(vg[tr][c], hue, eye)
            bot = cell_color(vg[tr + 1][c], hue, eye) if tr + 1 < N else OFF
            line += _cell(top, bot) * xscale
        lines.append(line)
    return caps.emit("\n".join(lines)).split("\n")


def render(seed, eye_override=None, pad='  '):
    """Compact statusline/banner watchman (size M, native truecolor). Delegates to
    the shared core so the cell-emit + tier logic lives in exactly one place."""
    return sigil_render(seed, 'M', _NATIVE, eye_override, pad)

def render_large(seed, eye_override=None, pad='  '):
    """2x horizontal scale for share/banner — each pixel becomes ██-ish width."""
    return sigil_render(seed, 'M', _NATIVE, eye_override, pad, xscale=2)

def glyph(seed, eye_override=None):
    """single colored cell for the team wall: ◉ in the identity hue."""
    _, hue, _ = grid_for(seed)
    col = eye_override or hue
    return color(col, 'fg') + '◉' + '\033[0m'

def glyph_color(seed):
    """The DOMINANT sigil color (body hue) for a seed — the deterministic identity
    tint the statusline wall paints a teammate's glyph with (spec B §4: teammate
    glyphs tinted by glyph_color(), state shown by solid/dim/red-frame, NOT by
    recoloring). Same seed -> same hue, forever, on every surface."""
    _, hue, _ = grid_for(seed)
    return hue


def _sq(rgb, n, caps):
    """An n×n aspect-square block: n cols × n/2 half-block rows, each cell the same
    solid color (fg=bg). If the terminal's cell aspect is the assumed ~1:2, this
    renders as a VISUAL SQUARE — the 2-second eyeball check that the sigil isn't
    squished. n must be even."""
    line = "".join(_cell(rgb, rgb) for _ in range(n))
    return caps.emit("\n".join([line] * (n // 2))).split("\n")


def _checker(a, b, n, caps):
    """An n-wide × n/2-tall checkerboard alternating colors a/b per cell AND per
    half (top/bot swapped each cell) — a dense color-fidelity target: on a broken
    color tier the pattern smears or drops the bg. n even."""
    rows = []
    for r in range(n // 2):
        cells = []
        for c in range(n):
            top, bot = (a, b) if (r + c) % 2 == 0 else (b, a)
            cells.append(_cell(top, bot))
        rows.append("".join(cells))
    return caps.emit("\n".join(rows)).split("\n")


def calibration_card(haid, caps=None):
    """`hmd sigil --test` — a self-verification card the user reads in 2 seconds to
    confirm their terminal renders the watchman correctly (and to screenshot if not).
    Rendered through the DETECTED caps so it shows exactly what the statusline/banner
    will look like on THIS terminal. Contains: the resolved tier, the sigil at all 3
    sizes (S/M/L), an aspect-square (must look square, not tall/squished), and a
    2-color checkerboard (color fidelity). Returns a list of lines."""
    caps = caps or TC.detect()
    B = caps.emit("\033[1m"); X = caps.emit("\033[0m")
    D = caps.emit("\033[38;2;90;100;114m")
    out = []
    out.append(f"{B}Heimdall sigil calibration{X}  {D}seed={haid}{X}")
    out.append(f"{D}tier: color={caps.color} unicode={caps.unicode} "
               f"tmux={1 if caps.tmux else 0}{X}")
    out.append("")
    for size, label in (("S", "S 4x4"), ("M", "M 8x8"), ("L", "L 16x16")):
        out.append(f"{D}{label}{X}")
        out.extend("  " + ln for ln in sigil_render(haid, size, caps))
        out.append("")
    out.append(f"{D}aspect-square (must look SQUARE, not tall):{X}")
    out.extend("  " + ln for ln in _sq((45, 212, 191), 8, caps))
    out.append("")
    out.append(f"{D}checkerboard (color fidelity — no smear/dropout):{X}")
    out.extend("  " + ln for ln in _checker((45, 212, 191), (19, 21, 29), 8, caps))
    out.append("")
    out.append(f"{D}looks morphed? screenshot this + run: "
               f"HEIMDALL_STATUSLINE_MODE=256 hmd sigil --test{X}")
    return out


def _cli_main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', default=None)
    ap.add_argument('--test', action='store_true',
                    help="print the terminal calibration card (detected caps)")
    ap.add_argument('--size', default='compact',
                    help="compact|large (legacy) or S|M|L (tiered core)")
    ap.add_argument('--tier', default=None,
                    choices=['truecolor', '256', '16', 'mono', 'ascii'],
                    help="force a capability tier (default: truecolor)")
    ap.add_argument('--glyph', action='store_true')
    ap.add_argument('--debug', action='store_true')  # print ·/#/@ grid
    a = ap.parse_args(argv)
    if a.test:
        # calibration uses the DETECTED tier unless one is forced with --tier.
        cc = None
        if a.tier == 'ascii':   cc = tier_caps(TC.MONO, TC.ASCII)
        elif a.tier == 'mono':  cc = tier_caps(TC.MONO, TC.FULL)
        elif a.tier in ('256', '16', 'truecolor'): cc = tier_caps(a.tier, TC.FULL)
        print('\n'.join(calibration_card(a.seed or 'you', cc)))
        return 0
    if not a.seed:
        ap.error("--seed is required (or use --test for the calibration card)")
    if a.glyph:
        print(glyph(a.seed)); return 0
    if a.debug:
        g, _, _ = grid_for(a.seed)
        for row in g:
            print(''.join({0: '·', 1: '#', 2: '@'}[v] for v in row))
        return 0
    # tier resolution. An explicit --tier is honored verbatim (goldens/scripts).
    # With NO --tier: the NEW S/M/L tokens auto-DETECT the terminal (morph-safe by
    # default — never truecolor blind on a 256/tmux/16-color terminal), while the
    # LEGACY compact/large tokens stay native truecolor (the banner/share + the
    # viral-sigil conformance contract expect the 24-bit path).
    if a.tier == 'ascii':
        caps = tier_caps(TC.MONO, TC.ASCII)
    elif a.tier == 'mono':
        caps = tier_caps(TC.MONO, TC.FULL)
    elif a.tier in ('256', '16', 'truecolor'):
        caps = tier_caps(TC.TRUECOLOR if a.tier == 'truecolor' else a.tier, TC.FULL)
    elif a.size in ('S', 'M', 'L'):
        caps = TC.detect()                     # new tokens: detect the real terminal
    else:
        caps = _NATIVE                         # legacy compact/large: truecolor
    if a.size in ('S', 'M', 'L'):
        lines = sigil_render(a.seed, a.size, caps)   # tiered tokens: no pad
    elif a.size == 'large':
        lines = sigil_render(a.seed, 'M', caps, pad='  ', xscale=2)  # legacy 2-sp pad
    else:  # compact
        lines = sigil_render(a.seed, 'M', caps, pad='  ')            # legacy 2-sp pad
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(_cli_main())
