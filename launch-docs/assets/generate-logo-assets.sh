#!/usr/bin/env bash
# generate-logo-assets.sh — derive transparent/square/icns assets from hmd-logo-eye-h.png.
#
# WHY THIS EXISTS.
#   The source asset (hmd-logo-eye-h.png) is a monoline eye/H mark, near-black on an
#   OPAQUE WHITE background, 1536x1024, no alpha channel. That is unusable anywhere the
#   surrounding chrome isn't pure white — a dark README, a dark Settings pane, an app
#   icon slot — the white square would show as a visible box. This script derives the
#   assets that actually get placed, and does so from the checked-in source every time
#   rather than leaving the pipeline as unrepeatable shell history.
#
# METHOD (not naive color-keying).
#   A plain `-transparent white` chroma-key leaves jagged, ringed edges wherever the
#   source anti-aliased a stroke against white, because those edge pixels are near-white
#   but not exactly white and get left half-opaque with the WRONG color mixed in. Instead:
#   grayscale + negate the source to build a MASK (white bg -> alpha 0, black stroke ->
#   alpha 255, anti-aliased edge -> the correct intermediate alpha), then composite a
#   solid near-black brand fill through that mask as the alpha channel. This reproduces
#   the original stroke's anti-aliasing exactly, just against transparency instead of
#   white.
#
# OUTPUTS (all written to this directory):
#   hmd-logo-eye-h-transparent.png   full 1536x1024 canvas, background removed
#   hmd-logo-eye-h-square.png        1024x1024, content trimmed + centered + padded —
#                                     the .icns source and the square master for any
#                                     future square placement
#   hmd-logo-eye-h.icns              full multi-resolution icon set built from the square
#                                     master via iconutil, for CFBundleIconFile use
#   hmd-logo-eye-h-mark.png          content trimmed + a small uniform breathing-room
#                                     margin (NOT padded to square) — the wide mark as-is,
#                                     for a README header (light backgrounds) or anywhere
#                                     the source's own 3:2-ish aspect ratio should be kept
#                                     rather than boxed into a square
#   hmd-logo-eye-h-mark-dark-bg.png  same crop/margin as the mark above, but filled with
#                                     a light near-white tone instead of near-black — the
#                                     near-black mark is close to invisible against a dark
#                                     README theme (e.g. GitHub dark mode's near-black
#                                     page background), so this is the
#                                     prefers-color-scheme:dark counterpart, not a
#                                     separate design
#
# REQUIRES: macOS `sips` + `iconutil` (built in), ImageMagick `magick` (brew). Darwin only
#   — the outputs are macOS icon artifacts and this script's own alpha-compositing and
#   iconset assembly rely on tools that don't exist elsewhere.
#
# EXIT: 0 ok · 2 usage / missing tool / not Darwin · 3 generation failure

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/hmd-logo-eye-h.png"
BRAND_COLOR="#1a1f2b"     # near-black from the source line art — light backgrounds
BRAND_COLOR_DARK_BG="#e6e8ec" # soft near-white — for the dark-mode README mark only
ICON_CANVAS=1024          # square master / icns base resolution
TRIM_FUZZ="2%"            # tolerance for treating near-white as background when trimming
MARK_PAD_PCT=6            # breathing-room margin on the README-mark, as % of its own size

die() { printf 'generate-logo-assets: %s\n' "$1" >&2; exit "${2:-2}"; }

[ "$(uname -s)" = "Darwin" ] || die "requires macOS (sips/iconutil); this host is $(uname -s)"
command -v magick   >/dev/null 2>&1 || die "ImageMagick 'magick' not found (brew install imagemagick)"
command -v sips     >/dev/null 2>&1 || die "'sips' not found"
command -v iconutil >/dev/null 2>&1 || die "'iconutil' not found"
[ -f "$SRC" ] || die "source asset missing: $SRC" 2

WORK="$(mktemp -d -t hmd-logo-assets.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "generate-logo-assets: source $SRC"

# ---- 1. build the alpha mask from source luminance (white->0, black->255) --------
magick "$SRC" -colorspace Gray -negate "$WORK/mask.png" \
  || die "mask generation failed" 3

# ---- 2/3. composite a solid fill through the mask as the alpha channel -----------
# composite_fill <color> <outfile> — reused for the default (near-black, light-
# background) render and, later, the dark-mode README mark's near-white render.
# -strip drops ImageMagick's embedded date:create/date:modify/date:timestamp tEXt
# chunks — without it, re-running this script produces a byte-different PNG every
# time even though every pixel is identical, which is both noisy in git diffs and
# leaks local generation timestamps into a shipped asset.
SRC_W="$(magick identify -format '%w' "$SRC")"
SRC_H="$(magick identify -format '%h' "$SRC")"
composite_fill() {
  local color="$1" outfile="$2"
  magick -size "${SRC_W}x${SRC_H}" "xc:$color" "$WORK/solid-$$.png" \
    || die "solid fill generation failed ($color)" 3
  magick "$WORK/solid-$$.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite \
    -strip "$outfile" \
    || die "alpha composite failed ($color)" 3
  rm -f "$WORK/solid-$$.png"
}
composite_fill "$BRAND_COLOR" "$HERE/hmd-logo-eye-h-transparent.png"

# ---- 4. find the content bounding box from the ALPHA channel, not RGB ------------
# (RGB is a uniform brand-color fill everywhere; -trim on it would see one flat color
#  and do nothing. Trimming the extracted alpha channel finds the real content box.)
magick "$HERE/hmd-logo-eye-h-transparent.png" -alpha extract "$WORK/alpha-only.png" \
  || die "alpha extraction failed" 3
# NOTE: %@ is itself "the trim bounding box" — do NOT also pass a `-trim` verb before
# it. Doing so applies the trim first (repositioning the page to 0,0) and %@ then
# reports the residual (near-zero, wrong) box of the ALREADY-trimmed image. Measured
# regression caught before shipping: with `-trim -format '%@'` this returned
# `796x431+2+0` instead of the correct `798x431+367+293`, silently cropping out most of
# the actual artwork.
TRIM_GEOM="$(magick "$WORK/alpha-only.png" -fuzz "$TRIM_FUZZ" -format '%@' info: 2>/dev/null)" \
  || die "trim bbox detection failed" 3
[ -n "$TRIM_GEOM" ] || die "empty trim geometry — is the source blank?" 3
echo "generate-logo-assets: content bbox $TRIM_GEOM"

# ---- 5. crop the transparent full canvas to that content box ---------------------
magick "$HERE/hmd-logo-eye-h-transparent.png" -crop "$TRIM_GEOM" +repage "$WORK/content.png" \
  || die "content crop failed" 3

# ---- 6. pad the cropped content into a square, centered, transparent border ------
magick "$WORK/content.png" -background none -gravity center \
  -extent "${ICON_CANVAS}x${ICON_CANVAS}" -strip "$HERE/hmd-logo-eye-h-square.png" \
  || die "square canvas extend failed" 3

# ---- 6b. the README/header mark: same content crop, small uniform margin, native
#          aspect ratio kept (not boxed into a square) ----------------------------
CONTENT_W="$(magick identify -format '%w' "$WORK/content.png")"
CONTENT_H="$(magick identify -format '%h' "$WORK/content.png")"
PAD_X=$(( CONTENT_W * MARK_PAD_PCT / 100 ))
PAD_Y=$(( CONTENT_H * MARK_PAD_PCT / 100 ))
magick "$WORK/content.png" -background none -gravity center \
  -extent "$((CONTENT_W + 2*PAD_X))x$((CONTENT_H + 2*PAD_Y))" -strip \
  "$HERE/hmd-logo-eye-h-mark.png" \
  || die "mark canvas extend failed" 3

# ---- 7. build the .iconset at every size macOS expects, then compile the .icns ---
ICONSET="$WORK/hmd.iconset"
mkdir -p "$ICONSET"
build_size() { # build_size <px> <name>
  sips -z "$1" "$1" "$HERE/hmd-logo-eye-h-square.png" --out "$ICONSET/$2" >/dev/null \
    || die "sips resize to ${1}x${1} failed" 3
}
build_size 16   icon_16x16.png
build_size 32   icon_16x16@2x.png
build_size 32   icon_32x32.png
build_size 64   icon_32x32@2x.png
build_size 128  icon_128x128.png
build_size 256  icon_128x128@2x.png
build_size 256  icon_256x256.png
build_size 512  icon_256x256@2x.png
build_size 512  icon_512x512.png
cp "$HERE/hmd-logo-eye-h-square.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$HERE/hmd-logo-eye-h.icns" \
  || die "iconutil compile failed" 3

echo "generate-logo-assets: wrote"
echo "  $HERE/hmd-logo-eye-h-transparent.png"
echo "  $HERE/hmd-logo-eye-h-square.png"
echo "  $HERE/hmd-logo-eye-h.icns"
echo "  $HERE/hmd-logo-eye-h-mark.png"
