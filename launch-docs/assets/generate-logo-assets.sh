#!/usr/bin/env bash
# generate-logo-assets.sh — rebuild the Heimdall helm brand pack and its macOS .icns.
#
# WHY THIS EXISTS.
#   The mark is a 10x10 pixel helm, light blue #4CC2FF on near-black #0B0E12 — the same
#   glyph as the hmd app icon. It is flat-colour pixel art, so every size of it has to be
#   a WHOLE NUMBER OF PIXELS per helm cell. A smoothing resize (`sips -z`, `magick -resize`)
#   blends the cells into a different, blurry logo, so this script never resamples a pack
#   image: gen-brand-pack.py reads the lattice, the palette and every cell straight out of
#   the master's pixels and re-emits each derived file by integer scaling. Nothing is
#   redrawn by eye and no pixel is ever blended.
#
# STEPS.
#   1. build    rewrite every derived file in this directory from hmd-mark-1024.png,
#               deterministically (the master itself comes back byte-identical)
#   2. verify   prove each file is a valid PNG/ICO/SVG, the size its name says, and the
#               master's grid; a nonzero exit stops this script before an icon is
#               compiled from a pack that did not check out
#   3. iconset  write the ten PNGs iconutil wants (16..1024 px, each a whole number of
#               pixels per helm cell) into a scratch directory
#   4. icns     iconutil compiles that iconset into hmd-mark.icns
#
# OUTPUTS (all written to this directory; README.md "Brand mark" says which file is for what):
#   hmd-mark-1024.png              master raster — the one input, rewritten byte-identically
#   hmd-mark-512.png               512 px raster (README header, org avatar)
#   hmd-mark-transparent-1024.png  the helm alone, RGBA
#   github-social-1280x640.png     repository social preview card
#   hmd-favicon-32.png             32 px favicon PNG
#   hmd-apple-touch-icon-180.png   iOS home-screen icon of a web page
#   hmd-favicon.ico                16/32/48 px favicon frames
#   hmd-mark.svg                   the helm on its dark tile
#   hmd-mark-transparent.svg       the helm alone
#   hmd-favicon.svg                16-cell favicon canvas
#   hmd-mark.icns                  macOS icon set, for CFBundleIconFile (bin/heimdall-dream-bundle)
#
# REQUIRES: python3 (standard library only) and macOS `iconutil` (built in) for the last
#   step. Darwin only: the .icns is a macOS icon artifact and iconutil exists nowhere else.
#
# EXIT: 0 ok · 2 usage / missing tool / not Darwin · 3 generation failure

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PACK="$HERE/gen-brand-pack.py"
MASTER="$HERE/hmd-mark-1024.png"
ICNS="$HERE/hmd-mark.icns"

die() { printf 'generate-logo-assets: %s\n' "$1" >&2; exit "${2:-2}"; }

[ "$(uname -s)" = "Darwin" ] || die "requires macOS (iconutil); this host is $(uname -s)"
command -v python3  >/dev/null 2>&1 || die "'python3' not found"
command -v iconutil >/dev/null 2>&1 || die "'iconutil' not found"
[ -f "$PACK" ]   || die "brand pack builder missing: $PACK"
[ -f "$MASTER" ] || die "master asset missing: $MASTER"

WORK="$(mktemp -d -t hmd-logo-assets.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "generate-logo-assets: master $MASTER"

# ---- 1. rewrite every derived file from the master ------------------------------
python3 "$PACK" build || die "pack build failed" 3

# ---- 2. prove the result before anything is compiled from it --------------------
python3 "$PACK" verify || die "pack verify failed — no icon is compiled from an unverified pack" 3

# ---- 3. the ten-size iconset, then 4. the .icns ----------------------------------
python3 "$PACK" iconset "$WORK/hmd.iconset" >/dev/null || die "iconset generation failed" 3
iconutil -c icns "$WORK/hmd.iconset" -o "$ICNS" || die "iconutil compile failed" 3

echo "generate-logo-assets: wrote $ICNS"
