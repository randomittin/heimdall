#!/usr/bin/env bash
# PARITY-ROW: statusline:viral-statusline — net-new full-width watchman line
#   (sentinels/hmd-statusline.py). No superx baseline; new viral surface. Reads
#   Claude Code statusLine JSON on stdin, COLUMNS for the right-pin, gate verdict
#   from <cwd>/.heimdall/statusline.json, team wall from <cwd>/.heimdall/team/*.json.
# ASSERT: empty stdin -> exit 0, >=4 rows; --widget -> one segment line; deny
#   verdict colors the line ("bifröst closed"); a fresh teammate file -> the watch
#   wall names them; a stale (old ts) file -> teammate dropped.
# GUARANTEE: every output row's visible width is <= COLUMNS. line() subtracts
#   the 9-col sigil anchor (+2 gutter) prefixed on every row, so the right-pinned
#   verdict block lands exactly at COLUMNS and never overflows.
ROW="statusline:viral-statusline"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

SL="$PLUGIN_ROOT/sentinels/hmd-statusline.py"
assert_file "$SL" "hmd-statusline.py present"

ANCHOR=11   # sigil gutter prepended to content rows: 9 grid cols + 2-space pad
COLS=120

# max visible width across all output rows (ANSI-stripped, true char count)
maxw() { python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
print(max((len(A.sub("",l)) for l in sys.stdin.read().splitlines()), default=0))'; }

WS="$(mk_workspace)"; mkdir -p "$WS/.heimdall/team"
JSON='{"workspace":{"current_dir":"'"$WS"'"}}'   # cwd carried in the CC stdin blob

# ── 1) empty stdin: never errors, full 4-row HUD ──
OUT="$(printf '{}' | COLUMNS=$COLS python3 "$SL")"; EC=$?
assert_exit 0 "$EC" "empty stdin exits 0"
NL="$(printf '%s\n' "$OUT" | grep -c '')"
if [ "$NL" -ge 4 ]; then ok "renders >=4 rows (got $NL)"; else bad "rendered $NL rows (want >=4)"; fi

# ── 2) width: EVERY row's visible width <= COLUMNS (sigil anchor included) ──
# Regression guard for the line() width-math bug: line() must subtract the
# 9-col sigil anchor (+2 gutter) so the right block pins to COLUMNS, never over.
MW="$(printf '%s' "$OUT" | maxw)"
if [ "$MW" -le "$COLS" ]; then ok "max row width $MW <= COLUMNS($COLS)"
else bad "max row width $MW exceeds COLUMNS($COLS) by $(( MW - COLS )) — line() must subtract the sigil anchor"; fi

# ── 2b) SQUINT, not blink: eyes visible in EVERY frame (P3 screenshot guard) ──
# A still can land on any animation frame. The old blink shut the eyes to a
# near-black (38;44;53) ~20% of frames -> an eyeless still. Squint dims to a
# muted white (150;160;175) and NEVER goes dark. HMD_NOW pins the clock:
# t%5==0 -> squint frame, else -> bright white glint (240;248;255). The eye
# color codes appear ONLY in the sigil rows, so a raw grep proves eye presence.
SQUINT_OUT="$(printf '{}' | HMD_NOW=5 COLUMNS=$COLS python3 "$SL")"   # 5%5==0 -> squint
BRIGHT_OUT="$(printf '{}' | HMD_NOW=7 COLUMNS=$COLS python3 "$SL")"   # 7%5!=0 -> bright
assert_contains "$SQUINT_OUT" "150;160;175" "squint frame -> dimmed-white eyes still visible"
assert_contains "$BRIGHT_OUT" "240;248;255" "non-squint frame -> bright white eye glint"
if grep -qF '38;44;53' <<<"$SQUINT_OUT"; then bad "squint emitted the old near-black eye (eyeless-still risk)"
else ok "squint never emits a fully-dark eye (no eyeless still)"; fi

# ── 3) --widget: one ccstatusline-coexistence segment line ──
WID="$(printf '{}' | COLUMNS=$COLS python3 "$SL" --widget)"; WEC=$?
assert_exit 0 "$WEC" "--widget exits 0"
WNL="$(printf '%s' "$WID" | grep -c '')"   # no trailing newline emitted -> 1 line
if [ -n "$WID" ] && [ "$WNL" -le 1 ]; then ok "--widget emits one segment line"
else bad "--widget emitted $WNL lines (want 1): '$WID'"; fi

# ── 4) deny verdict colors the line ──
printf '{"verdict":"deny","passed":2,"total":5}' > "$WS/.heimdall/statusline.json"
DEN="$(printf '%s' "$JSON" | COLUMNS=$COLS python3 "$SL" | sed -E 's/\x1b\[[0-9;]*m//g')"
assert_contains "$DEN" "bifröst closed" "deny verdict renders 'bifröst closed'"
rm -f "$WS/.heimdall/statusline.json"

# ── 5) team wall: a fresh teammate is named on the watch row ──
NOW="$(python3 -c 'import time;print(int(time.time()))')"
printf '{"haid":"nadia-1","name":"nadia","agent":"coder","verdict":"working","file":"auth.ts","ts":%s}' "$NOW" > "$WS/.heimdall/team/nadia.json"
FRESH="$(printf '%s' "$JSON" | COLUMNS=$COLS python3 "$SL" | sed -E 's/\x1b\[[0-9;]*m//g')"
assert_grep 'watch' "$FRESH" "fresh teammate -> watch wall header"
assert_contains "$FRESH" "nadia" "fresh teammate -> name on the wall"

# ── 6) stale teammate (old ts) is dropped (agent left) ──
printf '{"haid":"nadia-1","name":"nadia","agent":"coder","verdict":"working","file":"auth.ts","ts":1}' > "$WS/.heimdall/team/nadia.json"
STALE="$(printf '%s' "$JSON" | COLUMNS=$COLS python3 "$SL" | sed -E 's/\x1b\[[0-9;]*m//g')"
if grep -qF 'nadia' <<<"$STALE"; then bad "stale teammate still on the wall (TTL not enforced)"
else ok "stale teammate dropped from the wall"; fi

rm -rf "$WS"
finish
