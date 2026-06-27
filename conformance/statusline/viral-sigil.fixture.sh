#!/usr/bin/env bash
# PARITY-ROW: statusline:viral-sigil — net-new deterministic watchman sigil
#   (sentinels/hmd-sigil.py). No superx baseline; this is a new viral surface,
#   asserted on its own contract: same seed -> same art, width-stable, always a
#   watchman (forced symmetric eyes), and a single-cell glyph for the team wall.
# ASSERT: determinism (same --seed --debug twice == byte-identical); EXACT SQUARE
#   width (compact = 8 grid cols, large = 16, every text-row equal width — an 8x8
#   px grid renders square on a 2:1 half-block cell); the prominent watchman eyes
#   (debug grid rows 2 AND 3 each = exactly two symmetric '@' at cols 2 & 5 = a
#   2-px-tall full-cell eye block on a carved-dark visor band, with a gap between);
#   glyph mode renders one visible cell; CURATED seed rj == the embedded mockup
#   grid + the universal full-cell eye punch; eyes render as a FULL white cell
#   (EYE 240;248;255 as both fg and bg on the eye text-row, not a half sliver);
#   solid silhouette (OFF renders the DIM #13151d block, never a blank space).
ROW="statusline:viral-sigil"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

SIG="$PLUGIN_ROOT/sentinels/hmd-sigil.py"
assert_file "$SIG" "hmd-sigil.py present"

SEED="rj-a3f9"
PAD=2   # render() prepends a 2-space pad; grid cell-width = visible - PAD

# Read a sigil render on stdin; emit "<distinct-row-widths> <first-cell-width>".
# Strip ANSI and count CHARACTERS (sed/awk count bytes and the half-block glyphs
# ▀▄ are multibyte, so use python for a true char count). cell = visible - PAD.
gridw() { python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
w=[len(A.sub("",l)) for l in sys.stdin.read().splitlines()]
print(len(set(w)), (w[0]-2) if w else -1)'; }

WS="$(mk_workspace)"

# ── 1) determinism: same seed -> byte-identical debug grid ──
python3 "$SIG" --seed "$SEED" --debug > "$WS/a.grid" 2>/dev/null
python3 "$SIG" --seed "$SEED" --debug > "$WS/b.grid" 2>/dev/null
if cmp -s "$WS/a.grid" "$WS/b.grid"; then ok "deterministic: same seed -> byte-identical sigil"
else bad "non-deterministic: two renders of seed $SEED differ"; fi

# ── 2) EXACT SQUARE: compact = 8 grid cols (visible - 2 pad), all rows equal.
# 8 cols × 4 text-rows = an 8×8 px grid (each text-row = 2 px-rows): a true square. ──
read -r CN CCELL < <(python3 "$SIG" --seed "$SEED" --size compact | gridw)
if [ "$CN" = 1 ]; then ok "compact: all text-rows equal width"
else bad "compact: ragged row widths ($CN distinct)"; fi
if [ "$CCELL" = 8 ]; then ok "compact: 8 grid cols = exact square (visible - ${PAD} pad)"
else bad "compact: grid width $CCELL (want 8)"; fi
# rows: 8 px-rows / 2 per text-row = 4 text-rows; 4 rows × (2px each) == 8 cols -> square.
CROWS="$(python3 "$SIG" --seed "$SEED" --size compact | grep -c '')"
if [ "$CROWS" = 4 ]; then ok "compact: 4 text-rows (8 px-rows) -> 8x8 square silhouette"
else bad "compact: $CROWS text-rows (want 4 for a square)"; fi

# ── 2b) large = 16 grid cols (2x horizontal scale of the 8-col square) ──
read -r LN LCELL < <(python3 "$SIG" --seed "$SEED" --size large | gridw)
if [ "$LN" = 1 ]; then ok "large: all text-rows equal width"
else bad "large: ragged row widths ($LN distinct)"; fi
if [ "$LCELL" = 16 ]; then ok "large: 16 grid cols (visible - ${PAD} pad)"
else bad "large: grid width $LCELL (want 16)"; fi

# ── 3) PROMINENT EYES: the eye block is 2 px tall — debug grid rows 2 AND 3 each
# carry exactly two symmetric '@' at cols 2 & 5 (a full-cell eye per side, with a
# defined gap between them). Checking BOTH band rows guards the 2-px-tall block. ──
for RI in 2 3; do
  LINE="$(python3 "$SIG" --seed "$SEED" --debug | sed -n "$((RI+1))p")"   # 0-indexed row $RI
  AT="$(printf '%s' "$LINE" | tr -cd '@' | wc -c | tr -d ' ')"
  if [ "$AT" = 2 ]; then ok "watchman eyes: row $RI has exactly two '@' ($LINE)"
  else bad "watchman eyes: row $RI has $AT '@' (want 2): $LINE"; fi
  REV="$(printf '%s' "$LINE" | rev)"
  if [ "$LINE" = "$REV" ]; then ok "watchman eyes: row $RI vertically symmetric (palindrome)"
  else bad "watchman eyes: row $RI asymmetric ($LINE != $REV)"; fi
done
# the two eyes sit at cols 2 & 5 with a gap (cols 3,4 dark) — a defined separation.
EYEROW3="$(python3 "$SIG" --seed "$SEED" --debug | sed -n '3p')"   # row index 2
if [ "$(printf '%s' "$EYEROW3" | cut -c3)" = '@' ] && [ "$(printf '%s' "$EYEROW3" | cut -c6)" = '@' ] \
   && [ "$(printf '%s' "$EYEROW3" | cut -c4)" = '·' ] && [ "$(printf '%s' "$EYEROW3" | cut -c5)" = '·' ]; then
  ok "watchman eyes: cols 2 & 5 lit with a dark gap between ($EYEROW3)"
else bad "watchman eyes: eyes not at cols 2 & 5 with a gap: $EYEROW3"; fi

# ── 3b) CURATED grid: seed rj == embedded mockup grid + full-cell eye punch ──
# The 4 mockup identities ship their exact hand-authored 8x8 grids. grid_for then
# applies the universal finish: the whole visor band (rows 2+3) is carved dark and
# cols 2 & 5 are lifted to a FULL eye cell across both band rows (so the half-block
# render emits a crisp white square, not a sliver). This is rj's 8x8 mockup grid
# with that finish -> deterministic, must match byte-for-byte.
EXPECT_RJ="$(cat <<'GRID'
··####··
·######·
··@··@··
··@··@··
·######·
·##··##·
··####··
·##··##·
GRID
)"
GOT_RJ="$(python3 "$SIG" --seed rj --debug)"
if [ "$GOT_RJ" = "$EXPECT_RJ" ]; then ok "curated rj: debug grid == embedded mockup + eye punch"
else bad "curated rj: debug grid drifted from curated:
$GOT_RJ"; fi

# ── 3c) FULL white eye cell: EYE 240;248;255 as BOTH fg and bg on the eye text-row ──
# render() pairs grid rows (2,3) into text-row index 1; the full-cell eyes at cols
# 2 & 5 mean the eye glint appears as foreground AND background -> solid white squares.
EYEROW="$(python3 "$SIG" --seed "$SEED" --size compact | sed -n '2p')"
if printf '%s' "$EYEROW" | grep -qF '38;2;240;248;255' \
   && printf '%s' "$EYEROW" | grep -qF '48;2;240;248;255'; then
  ok "eyes: full white cell (EYE fg+bg) on the eye text-row"
else bad "eyes: EYE 240;248;255 not present as both fg+bg on eye text-row"; fi

# ── 3d) solid silhouette: OFF renders the DIM #13151d (19;21;29) filled block ──
COMPACT="$(python3 "$SIG" --seed "$SEED" --size compact)"
if printf '%s' "$COMPACT" | grep -qF '19;21;29'; then
  ok "silhouette: OFF renders a DIM filled block (not transparent)"
else bad "silhouette: DIM 19;21;29 absent -> OFF still transparent"; fi

# ── 4) glyph mode: a single visible cell for the team wall ──
GW="$(python3 "$SIG" --seed "$SEED" --glyph | python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
print(len(A.sub("",sys.stdin.readline().rstrip("\n"))))')"
if [ "$GW" = 1 ]; then ok "glyph: single visible cell"
else bad "glyph: visible width $GW (want 1)"; fi

rm -rf "$WS"
finish
