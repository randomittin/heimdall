#!/usr/bin/env python3
"""The hmd brand pack: build it from the helm master, or prove it still matches, with the standard library alone.

The master is flat-colour pixel art: a 10x10 helm glyph in two colours, every cell a whole number of pixels (hmdapp draws it
with scripts/gen-icons.py). Nothing here is redrawn by eye. The lattice, the palette and every cell are read back out of the
master's pixels, re-emitted as SVG rects, and rendered to PNG by plain integer scaling, so no pixel is ever blended.

  python3 gen-brand-pack.py build   [--src hmd-mark-1024.png]  write every derived file next to this script
  python3 gen-brand-pack.py verify  [--src hmd-mark-1024.png]  prove each file is valid, the right size, and the master's grid
  python3 gen-brand-pack.py iconset DIR.iconset                the ten PNGs `iconutil -c icns DIR.iconset` wants
  python3 gen-brand-pack.py compare A.png B.png                count the pixels that differ (alpha-aware)

hmdapp rebuilds from, and verifies against, its own master:  --src ../icon.png

Two canvases carry the one grid. The app-icon canvas (hmd-mark*, github-social) keeps the master's proportions: 128 lattice
units of 8 px, the helm 7 units a cell. A cell there is 7/8 of a pixel at 16 px, so columns of the helm drop out. The favicon
canvas (hmd-favicon*, the .ico frames, the iconset) is 16 cells, the helm with a 3-cell margin, which is a whole number of
pixels at 16, 32, 48, 64 and every power of two above.
"""
import argparse
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from functools import reduce
from math import ceil, gcd
from pathlib import Path

HERE = Path(__file__).resolve().parent
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
FAVICON_CELLS = 16
ICO_SIZES = (16, 32, 48)
MASTER = (1024, 56, 10, 10)  # canvas px, px per cell, cells across, cells down: what the targets below are tuned for

# name: (width, height, px per cell, opaque). Every cell is a whole number of pixels and the helm sits dead centre.
PNG_TARGETS = {
    "hmd-mark-1024.png": (1024, 1024, 56, True),
    "hmd-mark-512.png": (512, 512, 28, True),
    "hmd-mark-transparent-1024.png": (1024, 1024, 56, False),
    "github-social-1280x640.png": (1280, 640, 56, True),  # helm 560 px high on 640: a 40 px margin above and below
    "hmd-favicon-32.png": (32, 32, 2, True),
    "hmd-apple-touch-icon-180.png": (180, 180, 10, True),  # helm 100 px; iOS applies its own corner mask
}
ICONSET = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32, "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256, "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
FILES = [*PNG_TARGETS, "hmd-mark.svg", "hmd-mark-transparent.svg", "hmd-favicon.svg", "hmd-favicon.ico", "gen-brand-pack.py"]


class PngError(ValueError):
    """A PNG that is not valid, or not the 8-bit RGB/RGBA kind this pack uses."""


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode_png(width, rows, channels):
    """rows: raw scanlines of `channels` bytes a pixel (3 = RGB, 4 = RGBA). Filter 0 throughout, so the output is deterministic."""
    ihdr = struct.pack(">IIBBBBB", width, len(rows), 8, 6 if channels == 4 else 2, 0, 0, 0)
    raw = b"".join(b"\x00" + row for row in rows)
    return PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def unfilter(kind, line, prev, ch):
    if kind == 0:
        return line
    out = bytearray(line)
    if kind == 1:
        for i in range(ch, len(out)):
            out[i] = (out[i] + out[i - ch]) & 255
    elif kind == 2:
        for i in range(len(out)):
            out[i] = (out[i] + prev[i]) & 255
    elif kind == 3:
        for i in range(len(out)):
            left = out[i - ch] if i >= ch else 0
            out[i] = (out[i] + ((left + prev[i]) >> 1)) & 255
    elif kind == 4:
        for i in range(len(out)):
            a = out[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            out[i] = (out[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    else:
        raise PngError("unknown filter type %d" % kind)
    return out


def read_png(blob):
    """-> (width, height, channels, rows). Strict: the signature, every chunk's CRC, IHDR first, IEND last with nothing after
    it, and pixel data of exactly the size the header promises."""
    if blob[:8] != PNG_SIGNATURE:
        raise PngError("bad signature")
    pos, header, idat, ended = 8, None, [], False
    while pos < len(blob):
        if ended:
            raise PngError("bytes after IEND")
        if pos + 12 > len(blob):
            raise PngError("truncated chunk header")
        length, kind = struct.unpack(">I4s", blob[pos:pos + 8])
        body, crc = blob[pos + 8:pos + 8 + length], blob[pos + 8 + length:pos + 12 + length]
        name = kind.decode("latin-1")
        if len(body) != length or len(crc) != 4:
            raise PngError("truncated %s chunk" % name)
        if struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF) != crc:
            raise PngError("bad CRC in %s chunk" % name)
        pos += 12 + length
        if kind == b"IHDR":
            if header is not None or length != 13:
                raise PngError("bad IHDR")
            header = struct.unpack(">IIBBBBB", body)
        elif header is None:
            raise PngError("%s chunk before IHDR" % name)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            ended = True
    if header is None or not ended:
        raise PngError("missing IHDR or IEND")
    width, height, depth, color, compression, filtering, interlace = header
    if (depth, compression, filtering, interlace) != (8, 0, 0, 0) or color not in (2, 6):
        raise PngError("need 8-bit non-interlaced RGB or RGBA, got IHDR %r" % (header,))
    channels = 3 if color == 2 else 4
    stride = width * channels
    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as err:
        raise PngError("pixel data does not inflate: %s" % err)
    if len(raw) != height * (stride + 1):
        raise PngError("pixel data is %d bytes, the header promises %d" % (len(raw), height * (stride + 1)))
    rows, prev = [], bytes(stride)
    for y in range(height):
        start = y * (stride + 1)
        rows.append(bytes(unfilter(raw[start], raw[start + 1:start + 1 + stride], prev, channels)))
        prev = rows[-1]
    return width, height, channels, rows


class Glyph:
    """The helm: a grid of lit/unlit cells, its two colours, and the lattice it was read from."""

    def __init__(self, cells, bg, ink, unit, cell_px, canvas):
        self.cells, self.bg, self.ink = cells, bg, ink
        self.unit, self.cell_px, self.canvas = unit, cell_px, canvas

    @property
    def width(self):
        return len(self.cells[0])

    @property
    def height(self):
        return len(self.cells)


def render(glyph, width, height, cell, opaque, channels):
    """Centre the helm on a width x height canvas, every cell becoming cell x cell pixels: integer scaling, nothing resampled.
    opaque=False leaves the margin fully transparent but keeps the ink's RGB there, so a viewer that resamples the image
    does not fringe the edge with a darker colour."""
    gw, gh = glyph.width * cell, glyph.height * cell
    if gw > width or gh > height or (width - gw) % 2 or (height - gh) % 2:
        raise ValueError("a %dx%d helm cannot be centred on whole pixels of a %dx%d canvas" % (gw, gh, width, height))
    if not opaque and channels != 4:
        raise ValueError("a transparent render needs an alpha channel")
    tail = b"\xff" if channels == 4 else b""
    ink = glyph.ink + tail
    empty = glyph.bg + tail if opaque else glyph.ink + b"\x00"
    ox, oy = (width - gw) // 2, (height - gh) // 2
    blank = empty * width
    rows = [blank] * oy
    for cells in glyph.cells:
        line = empty * ox + b"".join((ink if lit else empty) * cell for lit in cells) + empty * (width - gw - ox)
        rows.extend([line] * cell)
    rows.extend([blank] * (height - gh - oy))
    return rows


def sample_grid(master):
    """Read the lattice, the two colours and every helm cell back out of the master's pixels, and prove the read lost nothing:
    rendering the grid again must give the master back byte for byte."""
    width, height, ch, rows = master
    if ch != 3 or width != height:
        raise ValueError("the master must be an opaque square RGB PNG, got %dx%d with %d channels" % (width, height, ch))
    distinct = set(rows)
    colours = {r[i:i + 3] for r in distinct for i in range(0, width * 3, 3)}
    if len(colours) != 2:
        raise ValueError("the master must be flat two-colour pixel art, found %d colours" % len(colours))
    bg = rows[0][:3]
    (ink,) = colours - {bg}
    # Every colour change, along both axes, falls on a multiple of the lattice unit; the gcd of all of them is that unit.
    edges = {0, width} | {y for y in range(1, height) if rows[y] != rows[y - 1]}
    edges |= {x for r in distinct for x in range(1, width) if r[x * 3:x * 3 + 3] != r[x * 3 - 3:x * 3]}
    unit = reduce(gcd, edges)
    n = width // unit
    lattice = [[rows[gy * unit][gx * unit * 3:gx * unit * 3 + 3] == ink for gx in range(n)] for gy in range(n)]
    lit = [(gx, gy) for gy in range(n) for gx in range(n) if lattice[gy][gx]]
    x0, x1 = min(x for x, _ in lit), max(x for x, _ in lit) + 1
    y0, y1 = min(y for _, y in lit), max(y for _, y in lit) + 1
    runs = []
    for line in lattice + [list(col) for col in zip(*lattice)]:
        run = 0
        for on in line + [False]:
            if on:
                run += 1
            elif run:
                runs.append(run)
                run = 0
    cell = reduce(gcd, runs + [x1 - x0, y1 - y0])
    cells = [[lattice[y0 + r * cell][x0 + c * cell] for c in range((x1 - x0) // cell)] for r in range((y1 - y0) // cell)]
    glyph = Glyph(cells, bg, ink, unit, cell * unit, width)
    if render(glyph, width, height, glyph.cell_px, True, 3) != rows:
        raise ValueError("the master is not one centred glyph drawn in whole-pixel cells")
    if (glyph.canvas, glyph.cell_px, glyph.width, glyph.height) != MASTER:
        raise ValueError("the pack is tuned for %r (canvas, px per cell, cols, rows); the master is %r"
                         % (MASTER, (glyph.canvas, glyph.cell_px, glyph.width, glyph.height)))
    return glyph


def hex_colour(rgb):
    return "#%02X%02X%02X" % tuple(rgb)


def merged_rects(cells):
    """Cover the lit cells with a few rects: horizontal runs, then identical runs stacked on each other. -> [(x, y, w, h)]."""
    rects, latest = [], {}
    for y, line in enumerate(cells):
        x = 0
        while x < len(line):
            if not line[x]:
                x += 1
                continue
            start = x
            while x < len(line) and line[x]:
                x += 1
            index = latest.get((start, x - start))
            if index is not None and rects[index][1] + rects[index][3] == y:
                rects[index][3] += 1
            else:
                latest[(start, x - start)] = len(rects)
                rects.append([start, y, x - start, 1])
    return [tuple(r) for r in rects]


def svg_document(glyph, view, cell, size, tile):
    """The helm as crisp SVG rects on a view x view grid, `cell` grid units to a helm cell, centred. tile=True puts the
    background colour behind it. `size` is only the intrinsic width and height; the viewBox is what scales."""
    if (view - glyph.width * cell) % 2:
        raise ValueError("a %d-unit helm cannot be centred on a %d-unit grid" % (glyph.width * cell, view))
    origin = (view - glyph.width * cell) // 2
    lines = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" shape-rendering="crispEdges">'
        % (view, view, size, size),
        "<title>hmd: Heimdall helm mark</title>",
    ]
    if tile:
        lines.append('<rect width="%d" height="%d" fill="%s"/>' % (view, view, hex_colour(glyph.bg)))
    lines.append('<g fill="%s">' % hex_colour(glyph.ink))
    for x, y, w, h in merged_rects(glyph.cells):
        lines.append('<rect x="%d" y="%d" width="%d" height="%d"/>' % (origin + x * cell, origin + y * cell, w * cell, h * cell))
    return "\n".join(lines + ["</g>", "</svg>", ""])


def mark_svg(glyph, tile):
    return svg_document(glyph, glyph.canvas // glyph.unit, glyph.cell_px // glyph.unit, 512, tile)


def favicon_svg(glyph):
    return svg_document(glyph, FAVICON_CELLS, 1, 256, True)


def favicon_png(glyph, size):
    return encode_png(size, render(glyph, size, size, size // FAVICON_CELLS, True, 4), 4)


def encode_ico(frames):
    """frames: [(size, PNG bytes)]. PNG-compressed frames, which every browser and Windows since Vista reads."""
    table, blobs, offset = b"", b"", 6 + 16 * len(frames)
    for size, png in frames:
        table += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset)
        blobs += png
        offset += len(png)
    return struct.pack("<HHH", 0, 1, len(frames)) + table + blobs


def read_ico(blob):
    """-> {size: image}. Strict: a sound directory, PNG frames of the size the directory claims, nothing after the last one."""
    if len(blob) < 6:
        raise ValueError("ICO is truncated")
    reserved, kind, count = struct.unpack("<HHH", blob[:6])
    if (reserved, kind) != (0, 1):
        raise ValueError("not an ICO (reserved %d, type %d)" % (reserved, kind))
    frames, end = {}, 6 + 16 * count
    for i in range(count):
        width, height, _, _, planes, bits, length, offset = struct.unpack("<BBBBHHII", blob[6 + 16 * i:22 + 16 * i])
        width, height = width or 256, height or 256
        data = blob[offset:offset + length]
        if (planes, bits) != (1, 32) or offset < 6 + 16 * count or len(data) != length:
            raise ValueError("ICO directory entry %d is unsound" % i)
        img = read_png(data)
        if img[:2] != (width, height):
            raise ValueError("ICO frame %d is %dx%d but its directory entry says %dx%d" % (i, img[0], img[1], width, height))
        frames[width] = img
        end = max(end, offset + length)
    if end != len(blob):
        raise ValueError("%d stray bytes after the last ICO frame" % (len(blob) - end))
    return frames


def raster_svg(text, size):
    """Rasterise the pack's SVG dialect (viewBox, g, rect, fill) the way a crispEdges renderer does: a pixel is painted when
    its centre lies inside the rect. Anything outside that dialect is an error, never silently skipped."""
    if "<!" in text:  # the stdlib parser expands entities, so refuse any declaration: the dialect has no DTD, entity or comment
        raise ValueError("DTDs, entities and comments are not part of the pack's SVG dialect")
    root = ET.fromstring(text)
    min_x, min_y, view_w, view_h = (float(v) for v in root.get("viewBox").split())
    sx, sy = size / view_w, size / view_h
    canvas = [bytearray(size * 4) for _ in range(size)]

    def span(start, length, origin, scale):
        lo, hi = ((v - origin) * scale - 0.5 for v in (start, start + length))
        return min(size, max(0, ceil(lo))), min(size, max(0, ceil(hi)))

    def paint(node, fill):
        for el in node:
            tag = el.tag.rsplit("}", 1)[-1]
            if tag == "title":
                continue
            colour = el.get("fill", fill)
            if tag == "g":
                paint(el, colour)
                continue
            if tag != "rect" or el.get("transform") or not colour:
                raise ValueError("unsupported SVG: <%s> with transform=%r fill=%r" % (tag, el.get("transform"), colour))
            x, y, w, h = (float(el.get(k, 0)) for k in ("x", "y", "width", "height"))
            xa, xb = span(x, w, min_x, sx)
            ya, yb = span(y, h, min_y, sy)
            rgba = bytes(int(colour[i:i + 2], 16) for i in (1, 3, 5)) + b"\xff"
            for py in range(ya, yb):
                canvas[py][xa * 4:xb * 4] = rgba * (xb - xa)

    paint(root, root.get("fill"))
    return size, size, 4, [bytes(r) for r in canvas]


def count_diff(a, b):
    """How many pixels differ between two images. A pixel matches when its alpha agrees and, where it shows, so does its colour."""
    (aw, ah, ach, arows), (bw, bh, bch, brows) = a, b
    if (aw, ah) != (bw, bh):
        raise ValueError("sizes differ: %dx%d against %dx%d" % (aw, ah, bw, bh))
    wrong = 0
    for ra, rb in zip(arows, brows):
        if ach == bch and ra == rb:
            continue
        for x in range(aw):
            pa, pb = ra[x * ach:(x + 1) * ach], rb[x * bch:(x + 1) * bch]
            alpha_a, alpha_b = (pa[3] if ach == 4 else 255), (pb[3] if bch == 4 else 255)
            if alpha_a != alpha_b or (alpha_a and pa[:3] != pb[:3]):
                wrong += 1
    return wrong


def mask_of(img):
    """The master as an ink mask: ink opaque, everything else transparent. Built from the master's pixels alone."""
    width, height, ch, rows = img
    bg, cache, out = rows[0][:ch], {}, []
    for row in rows:
        if row not in cache:
            cache[row] = b"".join((row[i:i + ch] + b"\xff") if row[i:i + ch] != bg else b"\x00" * 4 for i in range(0, width * ch, ch))
        out.append(cache[row])
    return width, height, 4, out


def half(img):
    """The master point-sampled at half size: pixel (i, j) is the master's (2i+1, 2j+1). A true nearest-neighbour downscale."""
    width, height, ch, rows = img
    return width // 2, height // 2, ch, [b"".join(r[(2 * i + 1) * ch:(2 * i + 2) * ch] for i in range(width // 2)) for r in rows[1::2]]


def card(img, width, height):
    """The master cut to width x height about its centre, any extra margin its background colour: what centring the helm
    on a wider card at the same scale has to give."""
    mw, mh, ch, rows = img
    pad = rows[0][:ch] * ((width - mw) // 2)
    top = (mh - height) // 2
    return width, height, ch, [pad + rows[top + y] + pad for y in range(height)]


def read_back(img, glyph, cell):
    """Decode a render of the helm at `cell` px a cell back into its grid. None unless the margin and every cell block are
    one flat colour and the ink is the ink."""
    width, height, ch, rows = img
    gw, gh = glyph.width * cell, glyph.height * cell
    ox, oy = (width - gw) // 2, (height - gh) // 2

    def at(x, y):
        return rows[y][x * ch:(x + 1) * ch]

    margin, ink = at(0, 0), glyph.ink + (b"\xff" if ch == 4 else b"")
    for y in range(height):
        for x in range(width):
            if not (ox <= x < ox + gw and oy <= y < oy + gh) and at(x, y) != margin:
                return None
    cells = []
    for r in range(glyph.height):
        line = []
        for c in range(glyph.width):
            block = {at(ox + c * cell + i, oy + r * cell + j) for i in range(cell) for j in range(cell)}
            if len(block) != 1 or not block <= {margin, ink}:
                return None
            line.append(block == {ink})
        cells.append(line)
    return cells


class Report:
    def __init__(self):
        self.failed = 0

    def check(self, ok, label, detail=""):
        print("  %s %s%s" % ("PASS" if ok else "FAIL", label, ": " + detail if detail else ""))
        self.failed += 0 if ok else 1


def self_test(report, master, glyph):
    """A check that cannot fail proves nothing, so feed the checkers a broken PNG, a wrong pixel and a broken SVG first."""
    blob = bytearray(encode_png(2, [b"\x00" * 6, b"\xff" * 6], 3))
    blob[len(blob) // 2] ^= 0xFF
    try:
        read_png(bytes(blob))
        caught = False
    except PngError:
        caught = True
    report.check(caught, "self-test: a PNG with one corrupted byte is rejected")
    wrong = list(master[3])
    line = bytearray(wrong[500])
    line[3 * 700] ^= 0xFF
    wrong[500] = bytes(line)
    report.check(count_diff(master, (master[0], master[1], 3, wrong)) == 1, "self-test: one wrong pixel is counted as exactly one")
    lines = mark_svg(glyph, True).split("\n")
    del lines[next(i for i, text in enumerate(lines) if text.startswith("<g ")) + 1]
    report.check(count_diff(raster_svg("\n".join(lines), master[0]), master) > 0, "self-test: an SVG missing one rect no longer matches")


def verify(src, out):
    report = Report()
    master = read_png(src.read_bytes())
    glyph = sample_grid(master)
    print("master %s: %dx%d, background %s, ink %s, lattice %d px, helm %dx%d cells of %d px"
          % (src, master[0], master[1], hex_colour(glyph.bg), hex_colour(glyph.ink), glyph.unit, glyph.width, glyph.height, glyph.cell_px))
    self_test(report, master, glyph)

    def load(name):
        path = out / name
        if not path.is_file():
            report.check(False, name, "missing")
            return None
        return path.read_bytes()

    def load_png(name, width, height, channels):
        blob = load(name)
        if blob is None:
            return None
        try:
            img = read_png(blob)
        except ValueError as err:
            report.check(False, name, str(err))
            return None
        ok = img[:3] == (width, height, channels)
        detail = ("valid PNG, %dx%d, %d channels, %d bytes" % (img[0], img[1], img[2], len(blob))) if ok else (
            "expected %dx%d with %d channels, found %dx%d with %d" % (width, height, channels, img[0], img[1], img[2]))
        report.check(ok, name, detail)
        return img if ok else None

    def same(label, a, b):
        if a is None or b is None:
            report.check(False, label, "an input was missing")
            return
        try:
            n = count_diff(a, b)
        except ValueError as err:
            report.check(False, label, str(err))
            return
        report.check(n == 0, label, "%d of %d pixels differ" % (n, a[0] * a[1]))

    def grid(label, img, cell):
        report.check(img is not None and read_back(img, glyph, cell) == glyph.cells, label,
                     "decodes to the master's %dx%d grid, margin and every %dx%d cell block flat" % (glyph.width, glyph.height, cell, cell))

    def raster(name, size):
        text = load(name)
        if text is None:
            return None
        try:
            return raster_svg(text.decode("utf-8"), size)
        except (ValueError, ET.ParseError, AttributeError) as err:
            report.check(False, name, "cannot rasterise: %s" % err)
            return None

    images = {name: load_png(name, w, h, 3 if opaque else 4) for name, (w, h, cell, opaque) in PNG_TARGETS.items()}
    same("hmd-mark-1024.png is pixel-identical to the master", images["hmd-mark-1024.png"], master)
    same("hmd-mark-512.png is the master point-sampled at half size", images["hmd-mark-512.png"], half(master))
    same("hmd-mark-transparent-1024.png is the master's ink mask", images["hmd-mark-transparent-1024.png"], mask_of(master))
    same("github-social-1280x640.png is the master centred on a 1280x640 card", images["github-social-1280x640.png"], card(master, 1280, 640))
    grid("hmd-favicon-32.png", images["hmd-favicon-32.png"], PNG_TARGETS["hmd-favicon-32.png"][2])
    grid("hmd-apple-touch-icon-180.png", images["hmd-apple-touch-icon-180.png"], PNG_TARGETS["hmd-apple-touch-icon-180.png"][2])

    frames = {}
    blob = load("hmd-favicon.ico")
    if blob is not None:
        try:
            frames = read_ico(blob)
            report.check(sorted(frames) == list(ICO_SIZES), "hmd-favicon.ico", "valid ICO, frames %s, %d bytes" % (sorted(frames), len(blob)))
        except ValueError as err:
            report.check(False, "hmd-favicon.ico", str(err))
    for size in ICO_SIZES:
        grid("hmd-favicon.ico %d px frame" % size, frames.get(size), size // FAVICON_CELLS)
    same("hmd-favicon-32.png equals the .ico's 32 px frame", images["hmd-favicon-32.png"], frames.get(32))

    same("hmd-mark.svg rasterised at 1024 is pixel-identical to the master", raster("hmd-mark.svg", 1024), master)
    same("hmd-mark.svg rasterised at 512 equals hmd-mark-512.png", raster("hmd-mark.svg", 512), images["hmd-mark-512.png"])
    same("hmd-mark-transparent.svg rasterised at 1024 is the master's ink mask", raster("hmd-mark-transparent.svg", 1024), mask_of(master))
    for size in ICO_SIZES:
        same("hmd-favicon.svg rasterised at %d equals the .ico frame" % size, raster("hmd-favicon.svg", size), frames.get(size))

    readme = load("README.md")
    if readme is not None:
        missing = [name for name in FILES if name not in readme.decode("utf-8")]
        report.check(not missing, "README.md names every file in the pack", "missing " + ", ".join(missing) if missing else "")
    print("\ngen-brand-pack verify: %s" % ("clean." if not report.failed else "%d failing check(s)." % report.failed))
    return 1 if report.failed else 0


def build(src, out):
    glyph = sample_grid(read_png(src.read_bytes()))
    print("master %s: %dx%d, background %s, ink %s, lattice %d px, helm %dx%d cells of %d px"
          % (src, glyph.canvas, glyph.canvas, hex_colour(glyph.bg), hex_colour(glyph.ink), glyph.unit, glyph.width, glyph.height, glyph.cell_px))
    files = {}
    for name, (w, h, cell, opaque) in PNG_TARGETS.items():
        channels = 3 if opaque else 4
        files[name] = encode_png(w, render(glyph, w, h, cell, opaque, channels), channels)
    files["hmd-favicon.ico"] = encode_ico([(size, favicon_png(glyph, size)) for size in ICO_SIZES])
    files["hmd-mark.svg"] = mark_svg(glyph, True)
    files["hmd-mark-transparent.svg"] = mark_svg(glyph, False)
    files["hmd-favicon.svg"] = favicon_svg(glyph)
    out.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (out / name).write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        print("  wrote %-32s %7d bytes" % (name, len(data)))
    return 0


def iconset(src, directory):
    if not directory.name.endswith(".iconset"):
        raise ValueError("iconutil only reads a directory named *.iconset, not %s" % directory.name)
    glyph = sample_grid(read_png(src.read_bytes()))
    directory.mkdir(parents=True, exist_ok=True)
    for name, size in ICONSET.items():
        (directory / name).write_bytes(favicon_png(glyph, size))
        print("  wrote %s (%d px)" % (directory / name, size))
    return 0


def compare(a_path, b_path):
    a, b = read_png(a_path.read_bytes()), read_png(b_path.read_bytes())
    print("%s: %dx%d, %d channels\n%s: %dx%d, %d channels" % (a_path, *a[:3], b_path, *b[:3]))
    wrong = count_diff(a, b)
    print("%d of %d pixels differ" % (wrong, a[0] * a[1]))
    return 1 if wrong else 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "verify", "iconset"):
        sub = commands.add_parser(name)
        sub.add_argument("--src", type=Path, default=HERE / "hmd-mark-1024.png", help="the master PNG")
        if name == "iconset":
            sub.add_argument("directory", type=Path)
        else:
            sub.add_argument("--out", type=Path, default=HERE, help="the pack directory")
    sub = commands.add_parser("compare")
    sub.add_argument("a", type=Path)
    sub.add_argument("b", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            return build(args.src, args.out)
        if args.command == "verify":
            return verify(args.src, args.out)
        if args.command == "iconset":
            return iconset(args.src, args.directory)
        return compare(args.a, args.b)
    except (OSError, ValueError) as err:
        sys.exit("gen-brand-pack: %s" % err)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
