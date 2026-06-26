#!/usr/bin/env bash
# PARITY-ROW: statusline:viral-sigil — net-new deterministic watchman sigil
#   (sentinels/hmd-sigil.py). No superx baseline; this is a new viral surface,
#   asserted on its own contract: same seed -> same art, width-stable, always a
#   watchman (forced symmetric eyes), and a single-cell glyph for the team wall.
# ASSERT: determinism (same --seed --debug twice == byte-identical); width
#   stability (compact = 9 grid cols, large = 18, every text-row equal width);
#   the watchman eyes (debug grid row index 3 = exactly two symmetric '@');
#   glyph mode renders one visible cell.
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

# ── 2) width stability: compact = 9 grid cols (visible - 2 pad), all rows equal ──
read -r CN CCELL < <(python3 "$SIG" --seed "$SEED" --size compact | gridw)
if [ "$CN" = 1 ]; then ok "compact: all text-rows equal width"
else bad "compact: ragged row widths ($CN distinct)"; fi
if [ "$CCELL" = 9 ]; then ok "compact: 9 grid cols (visible - ${PAD} pad)"
else bad "compact: grid width $CCELL (want 9)"; fi

# ── 2b) large = 18 grid cols (2x horizontal scale) ──
read -r LN LCELL < <(python3 "$SIG" --seed "$SEED" --size large | gridw)
if [ "$LN" = 1 ]; then ok "large: all text-rows equal width"
else bad "large: ragged row widths ($LN distinct)"; fi
if [ "$LCELL" = 18 ]; then ok "large: 18 grid cols (visible - ${PAD} pad)"
else bad "large: grid width $LCELL (want 18)"; fi

# ── 3) the watchman: debug grid row index 3 = exactly two symmetric eyes ──
ROW3="$(python3 "$SIG" --seed "$SEED" --debug | sed -n '4p')"   # 0-indexed row 3 = 4th line
AT="$(printf '%s' "$ROW3" | tr -cd '@' | wc -c | tr -d ' ')"
if [ "$AT" = 2 ]; then ok "watchman eyes: row 3 has exactly two '@' ($ROW3)"
else bad "watchman eyes: row 3 has $AT '@' (want 2): $ROW3"; fi
REV="$(printf '%s' "$ROW3" | rev)"
if [ "$ROW3" = "$REV" ]; then ok "watchman eyes: row 3 vertically symmetric (palindrome)"
else bad "watchman eyes: row 3 asymmetric ($ROW3 != $REV)"; fi

# ── 4) glyph mode: a single visible cell for the team wall ──
GW="$(python3 "$SIG" --seed "$SEED" --glyph | python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
print(len(A.sub("",sys.stdin.readline().rstrip("\n"))))')"
if [ "$GW" = 1 ]; then ok "glyph: single visible cell"
else bad "glyph: visible width $GW (want 1)"; fi

rm -rf "$WS"
finish
