#!/usr/bin/env bash
#
# heimdall-sigil-png.test.sh — the CRISP PNG sprite renderer (sentinels/hmd_sigil_png.py).
#
# The terminal 'D' tier approximates RJ's gallery with half-blocks; the PNG is the
# true-fidelity render for image surfaces (share-card avatar, presence wall). This
# suite proves the guarantees that render lives or dies on:
#
#   1. VALID PNG      — signature + IHDR (8-bit RGBA / color type 6) + the expected
#                       upscaled dimensions (16*scale + 2*pad, square).
#   2. DETERMINISTIC  — same sprite → BYTE-IDENTICAL PNG (a flat pixel map, zlib -9,
#                       no timestamps/RNG). A different sprite → a different PNG.
#   3. ALL 132 RENDER — every hand-authored sprite renders to a valid PNG, no error.
#   4. PALETTE AGREES — the PNG uses the SAME hue→RGB as the terminal sigil
#                       (hmd_sigil._detailed_palette): both surfaces are one palette.
#   5. CRISP EYES / PORTRAIT — creatures carry the full-white eye (255,255,255);
#                       lisa (portrait) carries the DARK brown eye and NO white eye.
#   6. SYNTAX         — the module is py_compile clean; the bin is bash -n clean.
#
# Usage:  test/heimdall-sigil-png.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PNG_PY="$REPO/sentinels/hmd_sigil_png.py"
PNG_BIN="$REPO/bin/heimdall-sigil-png"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "sigil-png harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── SYNTAX ────────────────────────────────────────────────────────────────────
python3 -m py_compile "$PNG_PY" && ok "hmd_sigil_png.py is py_compile clean" \
                                 || bad "hmd_sigil_png.py py_compile FAILED"
bash -n "$PNG_BIN" && ok "heimdall-sigil-png is bash -n clean" \
                   || bad "heimdall-sigil-png has a syntax error"

# ── core assertions (import the module directly) ──────────────────────────────
echo "== PNG validity / determinism / palette / 132-render =="
TMP="$(mktemp "${TMPDIR:-/tmp}/hmd-sigil-png.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
HMD_PNG_DIR="$REPO/sentinels" python3 - > "$TMP" 2>&1 <<'PY'
import os, struct, zlib, importlib.util
here = os.environ["HMD_PNG_DIR"]
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
S = load("hmd_sigil")
P = load("hmd_sigil_png")
def emit(tag, cond, detail=""):
    print(("OK " if cond else "BAD ") + tag + (" — " + detail if detail else ""))

SIG = b"\x89PNG\r\n\x1a\n"
def ihdr(data):
    # 8-byte sig, then 4-byte len + b"IHDR" + 13-byte header
    assert data[:8] == SIG and data[12:16] == b"IHDR"
    w, h = struct.unpack(">II", data[16:24])
    return w, h, data[24], data[25]           # width, height, bit-depth, color-type

# 1) VALID PNG — signature, header, 8-bit RGBA, expected upscaled dims.
scale = 8; pad = round(scale * 1.5); exp = 16 * scale + 2 * pad
data = P.render_png("fox", scale=scale)
emit("valid: PNG signature present", data[:8] == SIG)
try:
    w, h, depth, ctype = ihdr(data)
    emit("valid: IHDR is 8-bit RGBA (depth=8, color-type=6)", depth == 8 and ctype == 6,
         "depth=%d ctype=%d" % (depth, ctype))
    emit("valid: dimensions = 16*scale + 2*pad, square", (w, h) == (exp, exp),
         "%dx%d (want %dx%d)" % (w, h, exp, exp))
    iend = struct.pack(">I", 0) + b"IEND" + struct.pack(">I", zlib.crc32(b"IEND") & 0xffffffff)
    emit("valid: ends with a well-formed IEND chunk", data[-12:] == iend)
except Exception as e:
    emit("valid: IHDR parse", False, repr(e))

# 2) DETERMINISTIC — same sprite → byte-identical; different sprite → different.
a = P.render_png("fox", scale=scale)
b = P.render_png("fox", scale=scale)
emit("deterministic: same sprite → byte-identical PNG", a == b, "%d vs %d bytes" % (len(a), len(b)))
c = P.render_png("cat", scale=scale)
emit("falsifier: a different sprite → a different PNG", a != c)
# a HAID maps through the SAME family hash the terminal uses.
fam = S.detailed_family_for("some-real-haid-9q2")
emit("haid: PNG(HAID) == PNG(its family sprite) (same mapping as the terminal)",
     P.render_png("some-real-haid-9q2", scale=scale) == P.render_png(fam, scale=scale),
     "family=%s" % fam)

# 3) ALL 132 — every hand-authored sprite renders to a valid, correctly-sized PNG.
names = list(S.DETAILED_SPRITES.keys())
emit("count: 132 hand-authored sprites present", len(names) == 132, "n=%d" % len(names))
bad132 = []
sc = 4; pd = round(sc * 1.5); ex = 16 * sc + 2 * pd
for n in names:
    try:
        d = P.render_png(n, scale=sc)
        w, h, depth, ctype = ihdr(d)
        if not (d[:8] == SIG and depth == 8 and ctype == 6 and (w, h) == (ex, ex)):
            bad132.append(n)
    except Exception as e:
        bad132.append("%s(%r)" % (n, e))
emit("render: all 132 sprites render to a valid PNG, no error", not bad132,
     "bad=%s" % bad132[:5])

# 4) PALETTE AGREES — the PNG's body color is EXACTLY the terminal palette hue.
def has_rgb(rgba, rgb):
    r, g, b = rgb
    for i in range(0, len(rgba), 4):
        if rgba[i] == r and rgba[i+1] == g and rgba[i+2] == b and rgba[i+3] == 255:
            return True
    return False
for name in ("fox", "cherry", "penguin", "lisa", "howl"):
    sp = S.DETAILED_SPRITES[name]
    hue = S._hex_rgb(sp["hue"])
    term = S._detailed_palette(sp)["1"]            # what the terminal draws value 1 as
    _w, _h, rgba = P.render_rgba(name, scale=6)
    emit("palette: %s PNG body == terminal hue %s" % (name, sp["hue"]),
         tuple(hue) == tuple(term) and has_rgb(rgba, hue))

# 5) CRISP EYES / PORTRAIT — creatures = white eyes; lisa = dark eyes, NO white.
_w, _h, pen = P.render_rgba("penguin", scale=6)
emit("eyes: creatures carry the crisp WHITE eye (255,255,255)", has_rgb(pen, (255, 255, 255)))
_w, _h, lisa = P.render_rgba("lisa", scale=6)
dark = S._hex_rgb(S.DETAILED_SPRITES["lisa"]["accent7"])   # #3a2b20 dark brown eye/hair
pink = S._hex_rgb(S.DETAILED_SPRITES["lisa"]["accent6"])   # #e88a6c pink hand/blush
emit("lisa: portrait carries the DARK brown eye (accent7), NOT a white eye",
     has_rgb(lisa, dark) and not has_rgb(lisa, (255, 255, 255)))
emit("lisa: portrait carries the pink hand/blush accent (accent6)", has_rgb(lisa, pink))
PY

while IFS= read -r ln; do
  case "$ln" in
    "OK "*)  ok  "${ln#OK }" ;;
    "BAD "*) bad "${ln#BAD }" ;;
    *)       [ -n "$ln" ] && printf '  ??   %s\n' "$ln" ;;
  esac
done < "$TMP"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------"
echo "sigil-png: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
