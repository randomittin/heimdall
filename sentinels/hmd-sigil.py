#!/usr/bin/env python3
"""
hmd-sigil.py — deterministic watchman sigil from a HAID/identity seed.
Every Heimdall identity (user or agent) gets a unique, reproducible pixel watchman.
Same seed -> same sigil, forever. Used three ways:
  - compact  : the always-on statusline face (your watchman)
  - glyph     : a single colored cell for the team wall (teammates)
  - large     : the share card / banner / README avatar

Render is ANSI half-blocks (each text cell = 2 vertical pixels via ▀/▄). A 2:1
monospace cell + half-block makes each PIXEL ~square, so an N×N pixel grid renders
as an EXACT SQUARE silhouette. The grid is 8×8 px -> 8 cols × 4 text-rows: a true
square, width-stable in any monospace terminal (see .planning/ref).

Two ways a grid is born — a HYBRID that always yields a clean, legible face:
  - CURATED   : 4 hand-authored mockup identities (rj/nadia/arjun/priya) ship
                their exact grids + hue, so those seeds match the design 1:1.
  - GENERATED : every other seed (real HAIDs are arbitrary) is built on a fixed
                guardian-sprite TEMPLATE — domed helm / framed visor / armed torso
                / two legs. The fixed cells carve the SAME little sentinel for every
                seed; the hash only flips a few TEXTURE cells that EXTEND the build
                (crest, pauldrons, arms, hip flare, stance), mirrored about the 3.5
                axis. No free bit placement -> a recognizable creature, never a blob.

Both paths then get the universal watchman finish: a full-dark carved VISOR BAND
(grid rows 2+3, edge to edge) holding two FULL-CELL white square EYES (cols 2 & 5,
each punched across rows 2+3 = one whole text cell), with a defined gap between
them and the helm above / shoulders below framing the dark band so the eyes POP.
OFF pixels render as a DIM FILLED block (#13151d) so the face has a solid
silhouette / bounding box instead of fraying into transparent space.

  python3 hmd-sigil.py --seed rj-a3f9 --size compact
  python3 hmd-sigil.py --seed nadia   --size large
  python3 hmd-sigil.py --seed arjun   --glyph        # single cell for the wall
"""
import hashlib, sys, argparse

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

# generated seeds draw their hue from the SAME 4-color identity palette — the
# terminal never shows an off-brand body color the mockup never uses.
GEN_HUES = [(45, 212, 191), (245, 158, 11), (167, 139, 250), (244, 114, 182)]

# guardian-sprite TEMPLATE — half-grid (cols 0..3; mirror about the 3.5 axis to cols
# 7..4 — even width, no center column), 8 rows.
# codes: '1' body (always lit)   '.' off (always dark)   '~' texture (hash decides).
# The fixed '1'/'.' cells carve a recognizable little SENTINEL/INVADER silhouette —
# domed helm, framed visor, an armed torso, two legs — so EVERY seed is the same
# creature, never a random blob. Each '~' only ever EXTENDS an adjacent solid run
# (a wider crest, broad pauldrons, arms out, a hip flare, a wider stance) so a texture
# bit varies the guardian's build/livery per seed WITHOUT ever leaving an isolated
# dot. 5 texture cells -> 32 silhouettes x 4 identity hues = 128 distinct sprites.
# rows 2/3 here only reserve the visor's negative space — the universal finish carves
# the full dark band and punches the real full-cell eyes at cols 2 & 5.
TEMPLATE = [
    ".~11",  # row0 crown    — domed helm cap; ~col1 = crest / wider crown
    ".111",  # row1 helm      — full helm dome (cols 1..6)
    "....",  # row2 visor top — all dark; eyes punched at cols 2 & 5
    "....",  # row3 visor bot — all dark; eyes punched at cols 2 & 5
    "~111",  # row4 shoulders — chest plate; ~col0 = pauldrons / arms out (6 -> 8 wide)
    ".~1.",  # row5 torso     — body core with an extending arm (~col1), never dotty
    "..~1",  # row6 hips      — lower torso; ~col2 = belt / hip flare (narrow -> wide)
    ".1~.",  # row7 legs      — two legs; ~col2 = wider planted stance (narrow -> wide)
]

EYE = (240, 248, 255)   # bright eye glint (aliceblue)
DIM = (19, 21, 29)       # OFF pixel — a DIM FILLED cell (#13151d) -> solid silhouette
OFF = None               # legacy transparent sentinel (kept for color()/glyph back-compat)

W, H = 8, 8
EYE_COLS = (2, W - 1 - 2)   # cols 2 & 5 — symmetric, with a defined gap between them

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

def grid_for(seed, eye_override=None):
    """8x8 vertically-symmetric watchman. Curated for the 4 mockup seeds,
    template-generated (clean, framed eyes) for everything else."""
    if seed in CURATED_GRIDS:
        g = [[int(ch) for ch in row] for row in CURATED_GRIDS[seed]]
        hue = CURATED_HUES[seed]
    else:
        h = hashlib.sha256(seed.encode()).digest()
        g = [[0] * W for _ in range(H)]
        half = W // 2  # cols 0..3, then mirror to 7..4 (even width, no center col)
        bit = 0
        for r in range(H):
            for c in range(half):
                code = TEMPLATE[r][c]
                if code == '1':
                    v = 1
                elif code == '~':
                    byte = h[(bit // 8) % len(h)]
                    v = (byte >> (bit % 8)) & 1   # texture bit, low density per template
                    bit += 1
                else:
                    v = 0
                g[r][c] = v
                g[r][W - 1 - c] = v               # mirror about the 3.5 axis
        hue = GEN_HUES[h[0] % len(GEN_HUES)]
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
    everything else is a filled half-block so the face has a solid bounding box."""
    if top is None and bot is None:
        return ' '
    if bot is None:
        return color(top, 'fg') + '▀' + '\033[0m'
    if top is None:
        return color(bot, 'fg') + '▄' + '\033[0m'
    return color(top, 'fg') + color(bot, 'bg') + '▀' + '\033[0m'

def render(seed, eye_override=None, pad='  '):
    g, hue, eye = grid_for(seed, eye_override)
    out = []
    for tr in range(0, H, 2):  # two pixel-rows per text-row
        line = pad
        for c in range(W):
            top = cell_color(g[tr][c], hue, eye)
            bot = cell_color(g[tr + 1][c], hue, eye) if tr + 1 < H else OFF
            line += _cell(top, bot)
        out.append(line)
    return out

def render_large(seed, eye_override=None, pad='  '):
    """2x horizontal scale for share/banner — each pixel becomes ██-ish width."""
    g, hue, eye = grid_for(seed, eye_override)
    out = []
    for tr in range(0, H, 2):
        line = pad
        for c in range(W):
            top = cell_color(g[tr][c], hue, eye)
            bot = cell_color(g[tr + 1][c], hue, eye) if tr + 1 < H else OFF
            line += _cell(top, bot) * 2  # double width
        out.append(line)
    return out

def glyph(seed, eye_override=None):
    """single colored cell for the team wall: ◉ in the identity hue."""
    _, hue, _ = grid_for(seed)
    col = eye_override or hue
    return color(col, 'fg') + '◉' + '\033[0m'

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', required=True)
    ap.add_argument('--size', choices=['compact', 'large'], default='compact')
    ap.add_argument('--glyph', action='store_true')
    ap.add_argument('--debug', action='store_true')  # print ·/#/@ grid
    a = ap.parse_args()
    if a.glyph:
        print(glyph(a.seed)); sys.exit(0)
    if a.debug:
        g, _, _ = grid_for(a.seed)
        for row in g:
            print(''.join({0: '·', 1: '#', 2: '@'}[v] for v in row))
        sys.exit(0)
    lines = render_large(a.seed) if a.size == 'large' else render(a.seed)
    print('\n'.join(lines))
