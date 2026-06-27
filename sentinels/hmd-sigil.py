#!/usr/bin/env python3
"""
hmd-sigil.py — deterministic watchman sigil from a HAID/identity seed.
Every Heimdall identity (user or agent) gets a unique, reproducible pixel watchman.
Same seed -> same sigil, forever. Used three ways:
  - compact  : the always-on statusline face (your watchman)
  - glyph     : a single colored cell for the team wall (teammates)
  - large     : the share card / banner / README avatar

Render is ANSI half-blocks (each text cell = 2 vertical pixels via ▀/▄), so a
9x8 grid is 9 cols x 4 text-rows and stays width-stable in any monospace terminal.
A 2:1 monospace cell + half-block = each pixel is ~square (see .planning/ref).

Two ways a grid is born — a HYBRID that always yields a clean, legible face:
  - CURATED   : 4 hand-authored mockup identities (rj/nadia/arjun/priya) ship
                their exact grids + hue, so those seeds match the design 1:1.
  - GENERATED : every other seed (real HAIDs are arbitrary) is built on a fixed
                guardian-sprite TEMPLATE — domed helm / framed visor / armed torso
                / two legs. The fixed cells carve the SAME little sentinel for every
                seed; the hash only flips a few TEXTURE cells that EXTEND the build
                (crest, ear-guards, arms, hip flare, stance), mirrored about col 4.
                No free bit placement -> a recognizable creature, never a blob.

Both paths then get the universal watchman finish: a carved-dark visor band and
FULL-CELL white square eyes (cols 2 & 6 punched across rows 2+3 = one whole text
cell each), and OFF pixels render as a DIM FILLED block (#13151d) so the face has
a solid silhouette / bounding box instead of fraying into transparent space.

  python3 hmd-sigil.py --seed rj-a3f9 --size compact
  python3 hmd-sigil.py --seed nadia   --size large
  python3 hmd-sigil.py --seed arjun   --glyph        # single cell for the wall
"""
import hashlib, sys, argparse

# ── curated identities (canonical mockup) — 4 hand-authored 8x9 faces + fixed hue.
#    pixel values: 0=off, 1=body hue, 2=eye. these seeds match the design pixel-for-pixel.
CURATED_GRIDS = {
    'rj':    ["111010111", "011101110", "011101110", "002000200",
              "000111000", "111111111", "000010000", "110101011"],
    'nadia': ["110111011", "011111110", "110101011", "002000200",
              "000111000", "011101110", "110000011", "000010000"],
    'arjun': ["010111010", "111111111", "110010011", "002000200",
              "111010111", "010101010", "101000101", "001111100"],
    'priya': ["111000111", "010000010", "111101111", "002000200",
              "111101111", "010010010", "001101100", "101111101"],
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

# guardian-sprite TEMPLATE — half-grid (cols 0..4, col 4 = mirror axis), 8 rows.
# codes: '1' body (always lit)   '.' off (always dark)   '~' texture (hash decides).
# The fixed '1'/'.' cells carve a recognizable little SENTINEL/INVADER silhouette —
# domed helm, framed visor, an armed torso, two legs — so EVERY seed is the same
# creature, never a random blob. Each '~' only ever EXTENDS an adjacent solid run
# (a wider crest, ear-guard tips, arms out, a hip flare, a wider stance) so a texture
# bit varies the guardian's build/livery per seed WITHOUT ever leaving an isolated
# dot. 5 texture cells -> 32 silhouettes x 4 identity hues = 128 distinct sprites.
# eye columns (full cols 2 & 6) are force-punched after build; rows 2/3 here only
# reserve clear negative space — the punch writes the real eyes.
TEMPLATE = [
    "..~11",  # row0 crown    — domed helm cap; ~col2 = crest / wider crown (3 -> 5 wide)
    "~1111",  # row1 helm      — full helm dome; ~col0 = ear-guard tips (7 -> 9 wide)
    "1...1",  # row2 brow      — helm edges frame the eyes; eye col (2) clear -> punched
    ".....",  # row3 visor     — all dark; eyes punched at cols 2 & 6
    "~.111",  # row4 shoulders — chest plate; ~col0 = pauldrons / arms out (5 -> 7 wide)
    ".1.11",  # row5 torso     — body core with tucked arms (fixed solid, never dotty)
    "..~11",  # row6 hips      — lower torso; ~col2 = belt / hip flare (3 -> 5 wide)
    ".11~.",  # row7 legs      — two legs; ~col3 = wider planted stance (narrow -> wide)
]

EYE = (240, 248, 255)   # bright eye glint (aliceblue)
DIM = (19, 21, 29)       # OFF pixel — a DIM FILLED cell (#13151d) -> solid silhouette
OFF = None               # legacy transparent sentinel (kept for color()/glyph back-compat)

W, H = 9, 8

def _apply_watchman(g):
    """Universal finish on ANY grid (curated or generated): carve a full-dark
    visor band, then punch FULL-CELL white square eyes at cols 2 & 6.
    Eyes span grid rows 2+3 so they fill one whole text cell (render pairs
    rows (2,3) into text-row 1) -> a crisp white ▀+white-bg square, not a sliver."""
    for c in range(W):
        g[3][c] = 0                 # carve the visor dark so eyes pop
    for col in (2, W - 1 - 2):      # cols 2 and 6, mirrored
        g[2][col] = 2               # top half of the eye cell
        g[3][col] = 2               # bottom half of the eye cell
    return g

def grid_for(seed, eye_override=None):
    """9x8 vertically-symmetric watchman. Curated for the 4 mockup seeds,
    template-generated (clean, framed eyes) for everything else."""
    if seed in CURATED_GRIDS:
        g = [[int(ch) for ch in row] for row in CURATED_GRIDS[seed]]
        hue = CURATED_HUES[seed]
    else:
        h = hashlib.sha256(seed.encode()).digest()
        g = [[0] * W for _ in range(H)]
        half = W // 2  # cols 0..3 + center col 4, then mirror
        bit = 0
        for r in range(H):
            for c in range(half + 1):
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
                g[r][W - 1 - c] = v               # mirror about col 4
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
