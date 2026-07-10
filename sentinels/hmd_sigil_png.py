#!/usr/bin/env python3
"""
hmd_sigil_png.py — crisp PNG render of a detailed 16×16 sigil sprite.

BUILD option C: the ANSI terminal can only approximate RJ's high-res gallery with
half-blocks; the surfaces that CAN show an image (the share card, the presence wall)
deserve a true-fidelity render. This module upscales the SAME hand-authored 16×16
sprite the terminal draws into a clean pixel-art PNG that matches the reference
gallery (see .planning/ref/sigil-target-spec.md + .planning/ref/sprites/lisa-16x16.jpg).

SINGLE SOURCE OF TRUTH
----------------------
The value→color palette is imported from `hmd_sigil` (DETAILED_SPRITES, the value
map, hues, accents, bg). The terminal ('D' tier) and this PNG therefore agree
pixel-for-pixel on every hue/accent — a hue fix in hmd_sigil lands on BOTH surfaces
at once. The only value handled differently is 5 (outline): on the terminal the
2-px-per-cell `▀` pack forces an interior-5 de-speckle recolor (a near-black interior
mark would read as a scattered black dot); at full PNG resolution there is no
half-block artifact, so an interior 5 renders as the true drawn ink line (a crisp
muzzle/mouth mark) — cleaner, not a workaround.

THE RENDER (how it upscales + frames + vignettes)
-------------------------------------------------
  • UPSCALE — each of the 16×16 sprite pixels becomes a `scale`×`scale` block
    (default 24 → a 384×384 sprite area). Fills are flat solid color (full-res, so
    ZERO half-block speckle) and eyes stay crisp white squares.
  • CARD — the sprite sits on a rounded-corner card the size of the sprite plus a
    margin. The card corners are anti-aliased (supersampled coverage → alpha), so the
    card reads as a soft rounded rect on a transparent PNG (composites on any surface).
  • VIGNETTE — the card is a gentle RADIAL vignette tinted toward the sprite's family:
    the sprite's own `bg` hex is the base (lisa → green, howl → orange, cat → brown …),
    lit a touch at the center and darkened toward the edges. The sprite's transparent
    ('.') pixels show this card, so the creature sits ON the vignette.
  • SOFT SILHOUETTE — the outer silhouette edge (a filled pixel meeting the card) is
    anti-aliased by the same 2×2 supersample, so the outline reads soft-rounded rather
    than hard-blocked. INTERIOR pixel edges stay crisp (a fully-covered pixel snaps to
    its own cell color — no interior blur), so fills and eyes remain clean.

Deterministic: same (sprite, scale, pad) → byte-identical PNG (a flat pixel map +
zlib level-9; no timestamps, no RNG). PURE STDLIB — the PNG is written with
zlib+struct (color type 6, 8-bit RGBA); no PIL / no new dependency.

  python3 hmd_sigil_png.py --seed fox --out fox.png
  python3 hmd_sigil_png.py --seed lisa --emotion "" --scale 32 --out lisa.png
  python3 hmd_sigil_png.py --seed <HAID>        # HAID → deterministic family
"""
import os, sys, math, zlib, struct, argparse, importlib.util

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "hmd_sigil", os.path.join(_HERE, "hmd_sigil.py"))
S = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(S)

WHITE = S.WHITE
BLACK = S.BLACK
N = 16                      # every detailed sprite is a 16×16 grid


# ── PNG encode (stdlib only: zlib + struct) ─────────────────────────────────────
def _png_bytes(width, height, rgba):
    """8-bit RGBA (color type 6) PNG. `rgba` is a flat bytes/bytearray of
    width*height*4 (row-major, no per-scanline filter byte — we add the 0 filter
    byte here). Deterministic: no ancillary chunks, no time."""
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)                                  # filter: None
        raw += rgba[y * stride:(y + 1) * stride]
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


# ── geometry / color helpers ────────────────────────────────────────────────────
def _clamp01(x):
    return 0.0 if x < 0.0 else 1.0 if x > 1.0 else x

def _smooth(t):
    """smoothstep — a gentle, non-linear vignette ramp (no hard banding)."""
    t = _clamp01(t)
    return t * t * (3.0 - 2.0 * t)

def _in_round_rect(x, y, w, h, r):
    """True if point (x,y) is inside a [0,w]×[0,h] rect with corner radius r
    (standard rounded-rect signed distance test)."""
    qx = abs(x - w / 2.0) - (w / 2.0 - r)
    qy = abs(y - h / 2.0) - (h / 2.0 - r)
    dx = qx if qx > 0 else 0.0
    dy = qy if qy > 0 else 0.0
    return dx * dx + dy * dy <= r * r


# ── the render ──────────────────────────────────────────────────────────────────
def render_rgba(name_or_haid, emotion=None, scale=24, pad=None):
    """Return (width, height, bytearray rgba) for a sprite. `name_or_haid` may be a
    sprite NAME ('fox', 'fox-rage', 'lisa') — rendered directly with its own authored
    hue — or an arbitrary HAID, which maps through hmd_sigil's deterministic family
    hash (same character the terminal picks). `scale` px per sprite pixel; `pad` is the
    card margin around the sprite (default proportional to scale)."""
    name, grid, pal, bg, _n = S.detailed_grid_for(name_or_haid, emotion)
    scale = int(scale)
    if scale < 1:
        scale = 1
    if pad is None:
        pad = int(round(scale * 1.5))
    sprite_px = N * scale
    W = H = sprite_px + 2 * pad
    radius = min(pad * 1.4, (W - 1) / 2.0)

    # vignette poles from the sprite's own bg family — lit center, dark rim.
    center = S._mix(bg, WHITE, 0.12)
    edge = S._mix(bg, BLACK, 0.40)
    cx = (W - 1) / 2.0
    cy = (H - 1) / 2.0
    maxd = math.hypot(cx, cy)

    # precolor every '.'/filled cell so the inner loop is a dict-free lookup.
    cell_rgb = [[pal[grid[r][c]] if grid[r][c] != '.' else None
                 for c in range(N)] for r in range(N)]
    filled = [[grid[r][c] != '.' for c in range(N)] for r in range(N)]

    def vign(px, py):
        t = _smooth(math.hypot(px - cx, py - cy) / maxd)
        return S._mix(center, edge, t)

    def cell_at(px, py):
        """(filled?, color) for a point in canvas space; None color = card/vignette."""
        if not (pad <= px < pad + sprite_px and pad <= py < pad + sprite_px):
            return (False, None)
        c = int((px - pad) // scale)
        r = int((py - pad) // scale)
        if 0 <= r < N and 0 <= c < N and filled[r][c]:
            return (True, cell_rgb[r][c])
        return (False, None)

    SS = 2                                   # 2×2 supersample — edge/corner AA only
    offs = [(i + 0.5) / SS for i in range(SS)]
    rgba = bytearray(W * H * 4)
    for y in range(H):
        vy = y + 0.5
        base_row = y * W * 4
        for x in range(W):
            vx = x + 0.5
            vcol = vign(vx, vy)              # card color at this pixel (smooth → 1 sample)
            f_here, col_here = cell_at(vx, vy)
            center_inside = _in_round_rect(vx, vy, W, H, radius)

            # FAST PATH — deep interior of a filled cell OR deep card interior, away
            # from the rounded corner: no supersample needed (crisp block / flat card).
            near_edge = False
            if f_here:
                ox = (vx - pad) % scale
                oy = (vy - pad) % scale
                if ox < 1.0 or ox > scale - 1.0 or oy < 1.0 or oy > scale - 1.0:
                    near_edge = True
            else:
                near_edge = True             # card/'.' pixels: may touch a silhouette
            near_corner = not _in_round_rect(vx, vy, W, H, radius + 1.5) or \
                (_in_round_rect(vx, vy, W, H, radius) and not
                 _in_round_rect(vx, vy, W, H, radius - 1.5))

            if not near_edge and not near_corner:
                if f_here:
                    r8, g8, b8 = col_here; a8 = 255
                else:
                    r8, g8, b8 = vcol; a8 = 255 if center_inside else 0
                o = base_row + x * 4
                rgba[o] = r8; rgba[o + 1] = g8; rgba[o + 2] = b8; rgba[o + 3] = a8
                continue

            # AA PATH — supersample coverage for the silhouette + card corner.
            opaque = []                       # (r,g,b) of opaque subsamples
            filled_n = 0
            for dy in offs:
                sy = y + dy
                for dx in offs:
                    sx = x + dx
                    if not _in_round_rect(sx, sy, W, H, radius):
                        continue              # outside the card → transparent
                    fs, cs = cell_at(sx, sy)
                    if fs:
                        opaque.append(cs); filled_n += 1
                    else:
                        opaque.append(vcol)
            tot = SS * SS
            if not opaque:
                a8 = 0; r8 = g8 = b8 = 0
            else:
                a8 = int(round(255.0 * len(opaque) / tot))
                if filled_n == tot and f_here:
                    r8, g8, b8 = col_here      # fully-covered interior → crisp cell color
                else:
                    sr = sum(c[0] for c in opaque)
                    sg = sum(c[1] for c in opaque)
                    sb = sum(c[2] for c in opaque)
                    n = len(opaque)
                    r8 = int(round(sr / n)); g8 = int(round(sg / n)); b8 = int(round(sb / n))
            o = base_row + x * 4
            rgba[o] = r8; rgba[o + 1] = g8; rgba[o + 2] = b8; rgba[o + 3] = a8
    return W, H, rgba


def render_png(name_or_haid, emotion=None, scale=24, pad=None):
    """Crisp sigil PNG bytes for a sprite name or HAID. Deterministic."""
    w, h, rgba = render_rgba(name_or_haid, emotion, scale, pad)
    return _png_bytes(w, h, rgba)


def write_png(path, name_or_haid, emotion=None, scale=24, pad=None):
    """Render + write the PNG to `path` (creating parent dirs). Returns the path."""
    data = render_png(name_or_haid, emotion, scale, pad)
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return path


def _cli_main(argv=None):
    ap = argparse.ArgumentParser(description="crisp PNG render of a detailed sigil sprite")
    ap.add_argument("--seed", required=True,
                    help="a sprite name ('fox', 'fox-rage', 'lisa') or an arbitrary HAID")
    ap.add_argument("--emotion", default=None,
                    help="an emotion variant (rage/joy/…); falls back to the base family")
    ap.add_argument("--scale", type=int, default=24, help="px per sprite pixel (default 24)")
    ap.add_argument("--pad", type=int, default=None, help="card margin px (default ~1.5×scale)")
    ap.add_argument("--out", default=None,
                    help="output PNG path (default: stdout as raw PNG bytes)")
    a = ap.parse_args(argv)
    emotion = a.emotion or None
    if a.out:
        print(write_png(a.out, a.seed, emotion, a.scale, a.pad))
    else:
        data = render_png(a.seed, emotion, a.scale, a.pad)
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(_cli_main())
