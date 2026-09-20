#!/usr/bin/env python3
"""hmd_qr.py -- stdlib-only QR Code encoder + terminal renderer.

Implements ISO/IEC 18004 QR Code generation for byte-mode payloads: versions
1-10 (auto-selected by capacity), error-correction levels L/M/Q/H (default
L). Zero third-party dependencies -- pure Python 3 standard library, so
`hmd app connect` can print a scannable QR for a pairing URL without a pip
install.

Library:
    from hmd_qr import encode_qr, render_terminal
    qr = encode_qr("https://host.tailnet.ts.net/?token=abc123", ecc="L")
    print(render_terminal(qr.matrix))

CLI:
    python3 bin/lib/hmd_qr.py "<text>" [--ecc L|M|Q|H] [--matrix] [--ascii]
"""

import argparse
import sys
from collections import namedtuple

# =============================================================================
# GF(256) arithmetic (ISO/IEC 18004 Annex A: primitive polynomial
# x^8 + x^4 + x^3 + x^2 + 1, i.e. 0x11D) and Reed-Solomon codeword generation.
# =============================================================================

_GF_EXP = [0] * 512
_GF_LOG = [0] * 256


def _init_gf_tables():
    x = 1
    for i in range(255):
        _GF_EXP[i] = x
        _GF_LOG[x] = i
        x <<= 1
        if x & 0x100:          # overflowed 8 bits -- reduce by the primitive polynomial
            x ^= 0x11D          # ISO/IEC 18004 Annex A primitive polynomial
    for i in range(255, 512):   # mirror the table so multiply never needs `% 255`
        _GF_EXP[i] = _GF_EXP[i - 255]


_init_gf_tables()


def _gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return _GF_EXP[_GF_LOG[a] + _GF_LOG[b]]


def _poly_mul_gf(p, q):
    """Multiply two GF(256) polynomials (coefficient lists, highest degree first)."""
    result = [0] * (len(p) + len(q) - 1)
    for i, pi in enumerate(p):
        if pi == 0:
            continue
        for j, qj in enumerate(q):
            if qj:
                result[i + j] ^= _gf_mul(pi, qj)
    return result


def _rs_generator_poly(nsym):
    """RS generator polynomial of degree `nsym`: product of (x - a^i), i=0..nsym-1."""
    g = [1]
    for i in range(nsym):
        g = _poly_mul_gf(g, [1, _GF_EXP[i]])
    return g


def _rs_encode(data, nsym):
    """Systematic Reed-Solomon encode: return the `nsym` EC codewords for `data`
    (ISO/IEC 18004 6.5, Annex A -- synthetic division of data*x^nsym by the
    generator polynomial over GF(256))."""
    gen = _rs_generator_poly(nsym)
    res = list(data) + [0] * nsym
    for i in range(len(data)):
        coef = res[i]
        if coef:
            for j, gj in enumerate(gen):
                res[i + j] ^= _gf_mul(gj, coef)
    return res[len(data):]


# =============================================================================
# Spec tables (ISO/IEC 18004), versions 1-10 only -- this encoder does not
# support versions 11-40.
# =============================================================================

# Table 9 (error correction characteristics): per (version, level),
# (EC codewords per block, [(block_count, data_codewords_per_block), ...]).
# Two groups mean blocks of two different sizes (the longer group's extra
# data codeword(s) are what the interleaving step in 6.6 has to weave in).
_BLOCK_TABLE = {
    1: {"L": (7, [(1, 19)]), "M": (10, [(1, 16)]), "Q": (13, [(1, 13)]), "H": (17, [(1, 9)])},
    2: {"L": (10, [(1, 34)]), "M": (16, [(1, 28)]), "Q": (22, [(1, 22)]), "H": (28, [(1, 16)])},
    3: {"L": (15, [(1, 55)]), "M": (26, [(1, 44)]), "Q": (18, [(2, 17)]), "H": (22, [(2, 13)])},
    4: {"L": (20, [(1, 80)]), "M": (18, [(2, 32)]), "Q": (26, [(2, 24)]), "H": (16, [(4, 9)])},
    5: {"L": (26, [(1, 108)]), "M": (24, [(2, 43)]), "Q": (18, [(2, 15), (2, 16)]),
        "H": (22, [(2, 11), (2, 12)])},
    6: {"L": (18, [(2, 68)]), "M": (16, [(4, 27)]), "Q": (24, [(4, 19)]), "H": (28, [(4, 15)])},
    7: {"L": (20, [(2, 78)]), "M": (18, [(4, 31)]), "Q": (18, [(2, 14), (4, 15)]),
        "H": (26, [(4, 13), (1, 14)])},
    8: {"L": (24, [(2, 97)]), "M": (22, [(2, 38), (2, 39)]), "Q": (22, [(4, 18), (2, 19)]),
        "H": (26, [(4, 14), (2, 15)])},
    9: {"L": (30, [(2, 116)]), "M": (22, [(3, 36), (2, 37)]), "Q": (20, [(4, 16), (4, 17)]),
        "H": (24, [(4, 12), (4, 13)])},
    10: {"L": (18, [(2, 68), (2, 69)]), "M": (26, [(4, 43), (1, 44)]),
         "Q": (24, [(6, 19), (2, 20)]), "H": (28, [(6, 15), (2, 16)])},
}

# Table 3 (character count indicator length), byte mode row: 8 bits for
# versions 1-9, 16 bits for versions 10-26 (this encoder caps at version 10).
def _count_bits(version):
    return 8 if version <= 9 else 16


# Table 1, "remainder bits" column: zero-padding appended after the
# interleaved codeword bitstream so it exactly fills the non-function modules.
_REMAINDER_BITS = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}

# Annex E, Table E.1: alignment pattern center coordinates, versions 1-10.
_ALIGNMENT_COORDS = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
    7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
}

# Table 25: 2-bit error-correction-level indicator used inside format info.
_ECC_LEVEL_BITS = {"L": 0b01, "M": 0b00, "Q": 0b11, "H": 0b10}

_BYTE_MODE_INDICATOR = 0b0100   # Table 2: mode indicator for 8-bit byte mode
_PAD_CODEWORDS = (0xEC, 0x11)   # 6.4.10: alternating pad codewords after the terminator


# =============================================================================
# Capacity and version selection
# =============================================================================

def _data_codewords_total(version, level):
    _ecc_per_block, groups = _BLOCK_TABLE[version][level]
    return sum(count * size for count, size in groups)


def byte_capacity(version, level):
    """Max byte-mode payload length, in bytes, for (version, level)."""
    total_bits = _data_codewords_total(version, level) * 8
    overhead_bits = 4 + _count_bits(version)   # mode indicator + count indicator
    return max(0, (total_bits - overhead_bits) // 8)


def select_version(byte_len, level):
    """Smallest version (1-10) whose byte-mode capacity fits `byte_len` bytes."""
    for version in range(1, 11):
        if byte_len <= byte_capacity(version, level):
            return version
    max_cap = byte_capacity(10, level)
    raise ValueError(
        f"text too long for a QR code at ECC level {level}: {byte_len} bytes "
        f"exceeds the version-10 byte-mode capacity of {max_cap} bytes "
        f"(this encoder supports versions 1-10 only)"
    )


# =============================================================================
# Data encoding: mode + count + payload -> terminated, padded data codewords
# =============================================================================

def _bits_from_int(value, width):
    return [(value >> i) & 1 for i in range(width - 1, -1, -1)]   # MSB first


def _build_data_bits(payload, version):
    bits = list(_bits_from_int(_BYTE_MODE_INDICATOR, 4))
    bits += _bits_from_int(len(payload), _count_bits(version))
    for byte in payload:
        bits += _bits_from_int(byte, 8)
    return bits


def _terminate_and_pad(bits, total_data_codewords):
    capacity_bits = total_data_codewords * 8
    bits = bits + [0] * max(0, min(4, capacity_bits - len(bits)))   # 6.4.9: up to 4-bit terminator
    while len(bits) % 8:
        bits.append(0)                                              # pad to a byte boundary
    codewords = [
        int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)
    ]
    i = 0
    while len(codewords) < total_data_codewords:
        codewords.append(_PAD_CODEWORDS[i % 2])
        i += 1
    return codewords


# =============================================================================
# Block splitting, Reed-Solomon, and codeword interleaving (6.6)
# =============================================================================

def _split_into_blocks(codewords, groups):
    blocks = []
    idx = 0
    for count, size in groups:
        for _ in range(count):
            blocks.append(codewords[idx:idx + size])
            idx += size
    return blocks


def _interleave(blocks):
    """Column-major read across blocks of possibly-unequal length (6.6)."""
    out = []
    for i in range(max(len(b) for b in blocks)):
        for block in blocks:
            if i < len(block):
                out.append(block[i])
    return out


def _build_codeword_stream(payload, version, level):
    ecc_per_block, groups = _BLOCK_TABLE[version][level]
    total_data_codewords = _data_codewords_total(version, level)

    bits = _build_data_bits(payload, version)
    data_codewords = _terminate_and_pad(bits, total_data_codewords)
    data_blocks = _split_into_blocks(data_codewords, groups)
    ec_blocks = [_rs_encode(block, ecc_per_block) for block in data_blocks]

    stream = _interleave(data_blocks) + _interleave(ec_blocks)
    bitstream = []
    for codeword in stream:
        bitstream += _bits_from_int(codeword, 8)
    bitstream += [0] * _REMAINDER_BITS[version]
    return bitstream


# =============================================================================
# Matrix: function-pattern placement
# =============================================================================

class _Grid:
    """A QR module grid. `dark[r][c]` is the module color; `reserved[r][c]`
    marks a fixed function module (finder/timing/alignment/format/version/dark)
    that data placement must skip and masking must never touch."""

    __slots__ = ("size", "dark", "reserved")

    def __init__(self, size):
        self.size = size
        self.dark = [[False] * size for _ in range(size)]
        self.reserved = [[False] * size for _ in range(size)]

    def set(self, row, col, is_dark):
        self.dark[row][col] = bool(is_dark)
        self.reserved[row][col] = True

    def in_bounds(self, row, col):
        return 0 <= row < self.size and 0 <= col < self.size


def _finder_dark(r, c):
    """Dark/light for offset (r,c) within a 7x7 finder pattern (Figure 3)."""
    if r in (0, 6) or c in (0, 6):
        return True                       # outer ring
    if 2 <= r <= 4 and 2 <= c <= 4:
        return True                       # inner 3x3 core
    return False                          # ring between core and border: light


def _place_finder(grid, top, left):
    """One 7x7 finder pattern anchored at (top,left) plus its 1-module light
    separator (6.3.4). The -1..7 offset range clips at the matrix edge, which
    is exactly the L-shaped separator each corner needs."""
    for r in range(-1, 8):
        for c in range(-1, 8):
            row, col = top + r, left + c
            if not grid.in_bounds(row, col):
                continue
            if 0 <= r <= 6 and 0 <= c <= 6:
                grid.set(row, col, _finder_dark(r, c))
            else:
                grid.set(row, col, False)   # separator: always light


def _place_timing(grid):
    """Row 6 / column 6 alternate dark/light, starting dark (6.3.5), spanning
    the gap between the two nearest finder-pattern separators."""
    size = grid.size
    for i in range(8, size - 8):
        if not grid.reserved[6][i]:
            grid.set(6, i, i % 2 == 0)
        if not grid.reserved[i][6]:
            grid.set(i, 6, i % 2 == 0)


def _place_alignment(grid, version):
    """5x5 alignment patterns at every coordinate pair from Table E.1, except
    the 3 corners that coincide with a finder pattern. Deliberately placed
    AFTER timing so an alignment pattern that sits on row/col 6 (e.g. v7's
    (22,6)) overrides the timing line there, per the real symbol layout."""
    coords = _ALIGNMENT_COORDS[version]
    if not coords:
        return
    finder_corners = {(coords[0], coords[0]), (coords[0], coords[-1]), (coords[-1], coords[0])}
    for row_c in coords:
        for col_c in coords:
            if (row_c, col_c) in finder_corners:
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    dark = max(abs(dr), abs(dc)) != 1   # ring=light, core+border=dark
                    grid.set(row_c + dr, col_c + dc, dark)


def _place_dark_module(grid, version):
    grid.set(4 * version + 9, 8, True)   # 6.3.8: fixed dark module


# =============================================================================
# Format info (15 bits) and version info (18 bits): BCH generation + placement
# =============================================================================

_FORMAT_GENERATOR = 0b10100110111        # Annex C generator polynomial, degree 10 (0x537)
_FORMAT_XOR_MASK = 0b101010000010010     # Annex C: XOR mask (0x5412) applied after BCH
_VERSION_GENERATOR = 0b1111100100101     # Annex D generator polynomial, degree 12 (0x1F25)


def _bch_remainder(value, ecc_bits, generator):
    """Binary polynomial division remainder (GF(2) / XOR arithmetic) -- the
    shared technique behind QR format info (15,5) and version info (18,6)."""
    dividend = value << ecc_bits
    gen_len = generator.bit_length()
    while dividend.bit_length() > ecc_bits:
        dividend ^= generator << (dividend.bit_length() - gen_len)
    return dividend


def _format_info_bits(level, mask_id):
    data5 = (_ECC_LEVEL_BITS[level] << 3) | mask_id
    remainder = _bch_remainder(data5, 10, _FORMAT_GENERATOR)
    return ((data5 << 10) | remainder) ^ _FORMAT_XOR_MASK


def _version_info_bits(version):
    remainder = _bch_remainder(version, 12, _VERSION_GENERATOR)
    return (version << 12) | remainder


def _format_info_positions(size):
    """Both 15-bit format-info copies (Figure 25), as (row,col) per bit index
    0..14 with bit 0 the LSB of the masked 15-bit codeword."""
    copy1 = [None] * 15
    for i in range(6):
        copy1[i] = (i, 8)
    copy1[6] = (7, 8)
    copy1[7] = (8, 8)
    copy1[8] = (8, 7)
    for i in range(9, 15):
        copy1[i] = (8, 14 - i)

    copy2 = [None] * 15
    for i in range(8):
        copy2[i] = (8, size - 1 - i)
    for i in range(8, 15):
        copy2[i] = (size - 15 + i, 8)

    return (copy1, copy2)


def _reserve_format_info(grid):
    for copy in _format_info_positions(grid.size):
        for row, col in copy:
            grid.set(row, col, False)


def _place_format_bits(grid, bits15):
    for copy in _format_info_positions(grid.size):
        for i, (row, col) in enumerate(copy):
            grid.set(row, col, (bits15 >> i) & 1)


def _version_info_positions(size):
    """The 18-bit version-info field (Figure 26, version>=7 only): one 6x3
    block and its transpose, bit i at both (b,a) and (a,b)."""
    positions = [None] * 18
    for i in range(18):
        a = size - 11 + (i % 3)
        b = i // 3
        positions[i] = (a, b)
    return positions


def _reserve_version_info(grid, version):
    if version < 7:
        return
    for a, b in _version_info_positions(grid.size):
        grid.set(a, b, False)
        grid.set(b, a, False)


def _place_version_bits(grid, bits18):
    for i, (a, b) in enumerate(_version_info_positions(grid.size)):
        bit = (bits18 >> i) & 1
        grid.set(a, b, bit)
        grid.set(b, a, bit)


# =============================================================================
# Data placement: the zigzag module scan (6.7.3)
# =============================================================================

def _place_data(grid, bits):
    """Place `bits` into every non-function module, scanning two columns at a
    time from the bottom-right corner, alternating scan direction, skipping
    column 6 (the vertical timing line) without consuming a column-pair slot
    for it -- the classic off-by-one this algorithm is notorious for."""
    size = grid.size
    bit_idx = 0
    col = size - 1
    going_up = True
    while col >= 1:
        if col == 6:
            col = 5
        rows = range(size - 1, -1, -1) if going_up else range(size)
        for row in rows:
            for c in (col, col - 1):
                if not grid.reserved[row][c]:
                    bit = bits[bit_idx] if bit_idx < len(bits) else 0
                    grid.dark[row][c] = bool(bit)   # data module: NOT reserved, masking applies
                    bit_idx += 1
        going_up = not going_up
        col -= 2
    assert bit_idx == len(bits), (
        f"placed {bit_idx} bits but had {len(bits)} -- codeword/module-count mismatch"
    )


# =============================================================================
# Masking: 8 candidate masks, penalty scoring, best-mask selection (6.8)
# =============================================================================

# Table 10: mask pattern condition per (row, column).
_MASK_FUNCS = (
    lambda r, c: (r + c) % 2 == 0,
    lambda r, c: r % 2 == 0,
    lambda r, c: c % 3 == 0,
    lambda r, c: (r + c) % 3 == 0,
    lambda r, c: (r // 2 + c // 3) % 2 == 0,
    lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
    lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
)


def _masked_copy(grid, mask_id):
    """A new grid with data modules XORed per `mask_id`; function modules untouched."""
    fn = _MASK_FUNCS[mask_id]
    out = _Grid(grid.size)
    for r in range(grid.size):
        src_row, out_dark, out_reserved = grid.dark[r], out.dark[r], out.reserved[r]
        for c in range(grid.size):
            is_reserved = grid.reserved[r][c]
            out_reserved[c] = is_reserved
            out_dark[c] = (not src_row[c]) if (not is_reserved and fn(r, c)) else src_row[c]
    return out


def _penalty_rule1_line(line):
    """Rule 1 (N1=3): runs of >=5 same-color modules, penalty 3 + (run-5)."""
    penalty = 0
    run_color, run_len = line[0], 1
    for v in line[1:]:
        if v == run_color:
            run_len += 1
        else:
            if run_len >= 5:
                penalty += 3 + (run_len - 5)
            run_color, run_len = v, 1
    if run_len >= 5:
        penalty += 3 + (run_len - 5)
    return penalty


def _penalty_rule1(grid):
    size = grid.size
    penalty = sum(_penalty_rule1_line(row) for row in grid.dark)
    penalty += sum(
        _penalty_rule1_line([grid.dark[r][c] for r in range(size)]) for c in range(size)
    )
    return penalty


def _penalty_rule2(grid):
    """Rule 2 (N2=3): every 2x2 block of one color, overlapping windows."""
    penalty = 0
    size = grid.size
    for r in range(size - 1):
        row, next_row = grid.dark[r], grid.dark[r + 1]
        for c in range(size - 1):
            if row[c] == row[c + 1] == next_row[c] == next_row[c + 1]:
                penalty += 3
    return penalty


# Rule 3 target: 1:1:3:1:1 dark:light:dark:dark:dark:light:dark run adjacent
# to a 4-module light run (i.e. looks like a finder pattern cross-section).
_FINDER_LIKE_A = (True, False, True, True, True, False, True, False, False, False, False)
_FINDER_LIKE_B = tuple(reversed(_FINDER_LIKE_A))


def _penalty_rule3_line(line):
    penalty = 0
    for start in range(len(line) - 10):
        window = tuple(line[start:start + 11])
        if window == _FINDER_LIKE_A or window == _FINDER_LIKE_B:
            penalty += 40   # N3=40
    return penalty


def _penalty_rule3(grid):
    size = grid.size
    penalty = sum(_penalty_rule3_line(row) for row in grid.dark)
    penalty += sum(
        _penalty_rule3_line([grid.dark[r][c] for r in range(size)]) for c in range(size)
    )
    return penalty


def _penalty_rule4(grid):
    """Rule 4 (N4=10): 10 points per 5% the dark-module ratio strays from 50%."""
    total = grid.size * grid.size
    dark = sum(sum(row) for row in grid.dark)
    percent = 100.0 * dark / total
    return int(abs(percent - 50.0) / 5.0) * 10


def _penalty_score(grid):
    return (
        _penalty_rule1(grid) + _penalty_rule2(grid) + _penalty_rule3(grid) + _penalty_rule4(grid)
    )


def _select_mask(grid, level, version):
    """Try all 8 masks; lowest penalty wins, lowest mask id breaks ties.

    Scoring convention (matches the de facto reference algorithm this encoder
    was differentially validated against -- the format/version info fields
    and the fixed dark module are scored at their placeholder light value,
    never their real per-mask bits, since those bits aren't "decided" yet
    during the trial: `grid` already carries format/version info positions
    as light placeholders via `_reserve_format_info`/`_reserve_version_info`,
    so trial candidates inherit that for free and must NOT have real bits
    placed on them here. Only the winning mask gets the real format/version
    info written into the grid this function returns."""
    dark_r, dark_c = 4 * version + 9, 8   # 6.3.8: fixed dark module coordinate
    best_score = best_mask_id = best_grid = None
    for mask_id in range(8):
        candidate = _masked_copy(grid, mask_id)
        candidate.dark[dark_r][dark_c] = False   # placeholder for scoring only
        score = _penalty_score(candidate)
        candidate.dark[dark_r][dark_c] = True    # restore the real, always-dark value
        if best_score is None or score < best_score:
            best_score, best_mask_id, best_grid = score, mask_id, candidate

    _place_format_bits(best_grid, _format_info_bits(level, best_mask_id))
    if version >= 7:
        _place_version_bits(best_grid, _version_info_bits(version))
    return best_mask_id, best_grid


# =============================================================================
# Top-level encode
# =============================================================================

QRCode = namedtuple("QRCode", "version level mask size matrix")


def encode_qr(text, ecc="L"):
    """Encode `text` (byte mode) as a QR code. Returns a QRCode namedtuple
    with `matrix`: a size x size list of lists of bool (True = dark)."""
    if ecc not in _BLOCK_TABLE[1]:
        raise ValueError(f"unknown ECC level {ecc!r}; expected one of L, M, Q, H")
    if not text:
        raise ValueError("input text must not be empty")

    # surrogateescape round-trips raw, non-UTF-8-safe bytes that argv handed us
    # as lone surrogates back to their original bytes instead of raising.
    payload = text.encode("utf-8", "surrogateescape")
    version = select_version(len(payload), ecc)
    bits = _build_codeword_stream(payload, version, ecc)

    size = 17 + 4 * version   # 6.2: module count per side
    grid = _Grid(size)
    _place_finder(grid, 0, 0)
    _place_finder(grid, 0, size - 7)
    _place_finder(grid, size - 7, 0)
    _place_timing(grid)
    _place_alignment(grid, version)
    _place_dark_module(grid, version)
    _reserve_format_info(grid)
    _reserve_version_info(grid, version)

    capacity_modules = sum(row.count(False) for row in grid.reserved)
    assert capacity_modules == len(bits), (
        f"internal error: {capacity_modules} data modules but {len(bits)} data bits "
        f"for version {version} level {ecc}"
    )

    _place_data(grid, bits)
    mask_id, final_grid = _select_mask(grid, ecc, version)

    return QRCode(version=version, level=ecc, mask=mask_id, size=size, matrix=final_grid.dark)


# =============================================================================
# Rendering
# =============================================================================

def render_matrix_text(matrix):
    """Raw 0/1 grid, one row per line, no quiet zone -- for tests/tooling."""
    return "\n".join("".join("1" if cell else "0" for cell in row) for row in matrix)


def render_terminal(matrix, quiet_zone=4, ascii_mode=False):
    """Render with a `quiet_zone`-module light border. Default: half-block
    Unicode characters (2 module-rows per printed line). `ascii_mode`: a
    `##`/two-space fallback, one module-row per printed line, for terminals
    that can't render the block-element characters cleanly."""
    size = len(matrix)
    total = size + 2 * quiet_zone

    def get(r, c):
        rr, cc = r - quiet_zone, c - quiet_zone
        return matrix[rr][cc] if 0 <= rr < size and 0 <= cc < size else False

    if ascii_mode:
        return "\n".join(
            "".join("##" if get(r, c) else "  " for c in range(total)) for r in range(total)
        )

    padded_rows = total + (total % 2)   # one extra light row if odd, so pairs never run short
    lines = []
    for r in range(0, padded_rows, 2):
        chars = []
        for c in range(total):
            top_dark, bottom_dark = get(r, c), get(r + 1, c)
            if top_dark and bottom_dark:
                chars.append("█")   # full block
            elif top_dark:
                chars.append("▀")   # upper half block
            elif bottom_dark:
                chars.append("▄")   # lower half block
            else:
                chars.append(" ")
        lines.append("".join(chars))
    return "\n".join(lines)


# =============================================================================
# CLI
# =============================================================================

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="hmd_qr.py",
        description="Encode text as a QR code and render it for a terminal (stdlib only).",
    )
    parser.add_argument("text", nargs="?", default=None, help="text to encode")
    parser.add_argument("--ecc", choices=["L", "M", "Q", "H"], default="L",
                         help="error correction level (default L)")
    parser.add_argument("--matrix", action="store_true",
                         help="print the raw 0/1 module grid instead of a rendered QR")
    parser.add_argument("--ascii", action="store_true",
                         help="render with ##/space instead of half-block characters")
    args = parser.parse_args(argv)

    if not args.text:
        print("error: input text must not be empty", file=sys.stderr)
        return 1

    try:
        qr = encode_qr(args.text, ecc=args.ecc)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.matrix:
        print(render_matrix_text(qr.matrix))
    else:
        print(render_terminal(qr.matrix, ascii_mode=args.ascii))
    return 0


if __name__ == "__main__":
    sys.exit(main())
