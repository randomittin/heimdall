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

  python3 hmd-sigil.py --seed rj-a3f9 --size compact
  python3 hmd-sigil.py --seed nadia   --size large
  python3 hmd-sigil.py --seed arjun   --glyph        # single cell for the wall
"""
import hashlib, sys, argparse

# cyberpunk body palette — each identity locks one hue. retune to runheimdall.dev.
BODY = [
    (34, 211, 238),   # cyan
    (34, 197, 94),    # green
    (167, 139, 250),  # violet  (matches the hmd:heimdall powerline tag)
    (245, 158, 11),   # amber
    (244, 114, 182),  # pink
    (56, 189, 248),   # sky
    (45, 212, 191),   # teal
    (251, 113, 133),  # rose
]
EYE = (240, 248, 255)   # bright eye glint
OFF = None              # transparent (terminal bg)

def grid_for(seed, eye_override=None):
    """9x8 vertically-symmetric watchman. Eyes forced for brand identity."""
    h = hashlib.sha256(seed.encode()).digest()
    W, H = 9, 8
    g = [[0] * W for _ in range(H)]
    half = W // 2  # 4 generated cols + 1 center, mirrored
    bit = 0
    for r in range(H):
        for c in range(half + 1):
            byte = h[(bit // 8) % len(h)]
            on = (byte >> (bit % 8)) & 1
            # density + a helm bias: top rows lean lit on the outer edge (a crown)
            lit = on
            if r == 0 and c <= 1:
                lit = (byte >> 2) & 1 or on
            g[r][c] = 1 if lit else 0
            g[r][W - 1 - c] = g[r][c]  # mirror
            bit += 1
    # carve the visor band dark so eyes read
    for c in range(W):
        g[3][c] = 0
    # forced eyes (value 2) — symmetric, this is what makes every sigil a *watchman*
    g[3][2] = 2; g[3][W - 1 - 2] = 2
    # body hue from hash; eye color can be overridden (team verdict colors the eyes)
    hue = BODY[h[0] % len(BODY)]
    eye = eye_override or EYE
    return g, hue, eye

def color(rgb, layer):  # layer: 'fg' or 'bg'
    if rgb is None:
        return '\033[39m' if layer == 'fg' else '\033[49m'
    code = 38 if layer == 'fg' else 48
    return f'\033[{code};2;{rgb[0]};{rgb[1]};{rgb[2]}m'

def cell_color(v, hue, eye):
    return {0: OFF, 1: hue, 2: eye}[v]

def render(seed, eye_override=None, pad='  '):
    g, hue, eye = grid_for(seed, eye_override)
    H = len(g)
    out = []
    for tr in range(0, H, 2):  # two pixel-rows per text-row
        line = pad
        for c in range(len(g[0])):
            top = cell_color(g[tr][c], hue, eye)
            bot = cell_color(g[tr + 1][c], hue, eye) if tr + 1 < H else OFF
            if top is None and bot is None:
                line += ' '
            elif bot is None:
                line += color(top, 'fg') + '▀' + '\033[0m'
            elif top is None:
                line += color(bot, 'fg') + '▄' + '\033[0m'
            else:
                line += color(top, 'fg') + color(bot, 'bg') + '▀' + '\033[0m'
        out.append(line)
    return out

def render_large(seed, eye_override=None, pad='  '):
    """2x horizontal scale for share/banner — each pixel becomes ██-ish width."""
    g, hue, eye = grid_for(seed, eye_override)
    H = len(g)
    out = []
    for tr in range(0, H, 2):
        line = pad
        for c in range(len(g[0])):
            top = cell_color(g[tr][c], hue, eye)
            bot = cell_color(g[tr + 1][c], hue, eye) if tr + 1 < H else OFF
            for _ in range(2):  # double width
                if top is None and bot is None:
                    line += ' '
                elif bot is None:
                    line += color(top, 'fg') + '▀' + '\033[0m'
                elif top is None:
                    line += color(bot, 'fg') + '▄' + '\033[0m'
                else:
                    line += color(top, 'fg') + color(bot, 'bg') + '▀' + '\033[0m'
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
    ap.add_argument('--debug', action='store_true')  # print #/. grid
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
