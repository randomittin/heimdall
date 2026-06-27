#!/usr/bin/env bash
# PARITY-ROW: statusline:viral-statusline — net-new full-width watchman line
#   (sentinels/hmd-statusline.py). No superx baseline; new viral surface. Reads
#   Claude Code statusLine JSON on stdin, COLUMNS for the right-pin, gate verdict
#   from <cwd>/.heimdall/statusline.json, team wall from <cwd>/.heimdall/team/*.json.
# ASSERT: empty stdin -> exit 0, >=4 rows; --widget -> one segment line; deny
#   verdict colors the line ("bifröst closed"); a fresh teammate file -> the watch
#   wall names them; a stale (old ts) file -> teammate dropped.
# GUARANTEE: every output row's visible width is <= COLUMNS. line() subtracts
#   the 8-col square sigil anchor (+2 gutter) prefixed on every row, so the
#   right-pinned verdict block lands exactly at COLUMNS and never overflows.
ROW="statusline:viral-statusline"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

SL="$PLUGIN_ROOT/sentinels/hmd-statusline.py"
assert_file "$SL" "hmd-statusline.py present"

ANCHOR=10   # sigil gutter prepended to content rows: 8 square grid cols + 2-space pad
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
# 8-col square sigil anchor (+2 gutter) so the right block pins to COLUMNS, never over.
MW="$(printf '%s' "$OUT" | maxw)"
if [ "$MW" -le "$COLS" ]; then ok "max row width $MW <= COLUMNS($COLS)"
else bad "max row width $MW exceeds COLUMNS($COLS) by $(( MW - COLS )) — line() must subtract the sigil anchor"; fi

# ── 2b) RICHER EYE ANIMATION, never eyeless (P3 screenshot guard) ──────────────
# The eyes are the watchman's signature, so they animate — but every phase is a
# LIGHT color and the eyes stay VISIBLE in EVERY frame (a still can land on any
# frame; the eyeless-capture lesson holds). A deterministic 12-tick cycle:
#   phase 0      -> BLINK  (120;128;145) eyes nearly closed, dimmed but visible
#   phase 4,8    -> LOOK   (255;255;255) a bright glint passes across the eyes
#   else         -> GLINT  (240;248;255) the steady bright watch
# HMD_NOW pins the clock. The 4 eye colors are eye-EXCLUSIVE (no other element
# emits them), so a raw grep proves eye presence per frame.
BLINK_OUT="$(printf '{}'  | HMD_NOW=0  COLUMNS=$COLS python3 "$SL")"   # 0%12==0  -> blink
LOOK_OUT="$(printf '{}'   | HMD_NOW=4  COLUMNS=$COLS python3 "$SL")"   # 4%12==4  -> look
GLINT_OUT="$(printf '{}'  | HMD_NOW=1  COLUMNS=$COLS python3 "$SL")"   # 1%12==1  -> glint
assert_contains "$BLINK_OUT" "120;128;145" "blink frame -> dimmed-but-visible eyes (never dark)"
assert_contains "$LOOK_OUT"  "255;255;255" "look frame -> a bright glint passes across the eyes"
assert_contains "$GLINT_OUT" "240;248;255" "steady frame -> bright white watch-glint"
# never the old near-black blink (38;44;53) on ANY of these frames -> no eyeless still
for F in "$BLINK_OUT" "$LOOK_OUT" "$GLINT_OUT"; do
  if grep -qF '38;44;53' <<<"$F"; then bad "a frame emitted the old near-black eye (eyeless-still risk)"; fi
done
ok "no frame emits a fully-dark eye (no eyeless still)"

# ── 2c) EYES IN EVERY FRAME: sweep the whole 12-tick cycle; each frame MUST carry
# one of the eye-light colors (the never-eyeless guarantee across the full cycle). ──
EYELESS=0
for T in 0 1 2 3 4 5 6 7 8 9 10 11; do
  FR="$(printf '{}' | HMD_NOW=$T COLUMNS=$COLS python3 "$SL")"
  if grep -qE '120;128;145|255;255;255|240;248;255|150;160;175' <<<"$FR"; then :; else
    EYELESS=1; bad "frame t=$T has NO visible eye color (eyeless!)"
  fi
done
[ "$EYELESS" = 0 ] && ok "eyes visible in EVERY frame across the 12-tick cycle (never eyeless)"

# ── 2d) SCANNING verdict -> a faster look-pulse (LOOK on even ticks, SQUINT on odd),
# both LIGHT colors so the actively-scanning watchman never goes eyeless either. ──
printf '{"verdict":"scanning"}' > "$WS/.heimdall/statusline.json"
SCAN_EVEN="$(printf '%s' "$JSON" | HMD_NOW=2 COLUMNS=$COLS python3 "$SL")"   # even -> LOOK
SCAN_ODD="$(printf '%s'  "$JSON" | HMD_NOW=3 COLUMNS=$COLS python3 "$SL")"   # odd  -> SQUINT
assert_contains "$SCAN_EVEN" "255;255;255" "scanning even tick -> bright look-pulse eyes"
assert_contains "$SCAN_ODD"  "150;160;175" "scanning odd tick -> alert squint eyes (still visible)"
rm -f "$WS/.heimdall/statusline.json"

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
rm -f "$WS/.heimdall/team/nadia.json"

# ── 7) FILE-controlled identity: bin/heimdall-identity is the sigil SEED + the
# wall HANDLE (RJ's call). Setting an identity must reflect on BOTH the sigil
# anchor (seed) and the info row (handle); a different identity changes the sigil. ──
if [ -x "$BIN/heimdall-identity" ]; then
  # NB: the statusline resolves identity via bin/heimdall-identity, which keys off
  # git-toplevel($cwd)/.heimdall unless HEIMDALL_IDENTITY_DIR overrides. $WS is created
  # INSIDE this git repo, so the render MUST inherit the SAME store override (else it
  # reads the repo's real .heimdall, not the test identity). Pass it on the render too.
  HEIMDALL_IDENTITY_DIR="$WS/.heimdall" "$BIN/heimdall-identity" --set tester --seed tester >/dev/null 2>&1
  ID_OUT="$(printf '%s' "$JSON" | HEIMDALL_IDENTITY_DIR="$WS/.heimdall" COLUMNS=$COLS HMD_NOW=7 python3 "$SL")"
  ID_PLAIN="$(printf '%s' "$ID_OUT" | sed -E 's/\x1b\[[0-9;]*m//g')"
  assert_contains "$ID_PLAIN" "tester" "identity handle 'tester' shows on the info row"
  SIG_A="$(printf '%s' "$ID_OUT" | head -1)"
  HEIMDALL_IDENTITY_DIR="$WS/.heimdall" "$BIN/heimdall-identity" --set someoneelse --seed someoneelse >/dev/null 2>&1
  SIG_B="$(printf '%s' "$JSON" | HEIMDALL_IDENTITY_DIR="$WS/.heimdall" COLUMNS=$COLS HMD_NOW=7 python3 "$SL" | head -1)"
  if [ "$SIG_A" != "$SIG_B" ]; then ok "sigil seed is file-controlled (changes with identity)"
  else bad "sigil row identical across identities — seed not sourced from heimdall-identity"; fi
  rm -f "$WS/.heimdall/identity.json"
else
  note "heimdall-identity bin absent — skipping file-seed assertions"
fi

# ── 8) SERVER-SYNCED roster: a populated roster cache fills the wall with ONLINE
# teammates (other machines), marked with a green online pip; the local team/*.json
# file path stays the OFFLINE fallback when the cache is absent (sections 5/6).
# Isolated workspace + a FRESH cache mtime so roster_presence serves it without a
# background refetch that could clobber the seeded rows. ──
WIDE=200
WS8="$(mk_workspace)"; mkdir -p "$WS8/.heimdall"
JSON8='{"workspace":{"current_dir":"'"$WS8"'"}}'
python3 - "$WS8/.heimdall/.roster-cache.json" <<'PY'
import json,sys
json.dump([
  {"handle":"riku","haid":"haid:riku","verdict":"working","file":"sync.go","age_seconds":4},
  {"handle":"vera","haid":"haid:vera","verdict":"pass","file":"core.py","age_seconds":9},
], open(sys.argv[1],"w"))
PY
ROSTER="$(printf '%s' "$JSON8" | COLUMNS=$WIDE HMD_NOW=7 python3 "$SL")"
ROSTER_PLAIN="$(printf '%s' "$ROSTER" | sed -E 's/\x1b\[[0-9;]*m//g')"
assert_contains "$ROSTER_PLAIN" "riku" "server roster -> online teammate 'riku' on the wall"
assert_contains "$ROSTER_PLAIN" "vera" "server roster -> online teammate 'vera' on the wall"
# the green online pip (GR ●) marks who is actually online now (roster, not file).
if printf '%s' "$ROSTER" | grep -qF $'\033[38;2;34;197;94m●'; then ok "online status shown (green pip on roster members)"
else bad "no online pip on roster members"; fi
# roster row stays width-safe at the wide terminal (<= COLUMNS).
RMW="$(printf '%s' "$ROSTER" | maxw)"
if [ "$RMW" -le "$WIDE" ]; then ok "roster wall width $RMW <= COLUMNS($WIDE)"; else bad "roster wall width $RMW exceeds COLUMNS($WIDE)"; fi
rm -rf "$WS8"

# ── 9) IDLE dedup: solo + no gate verdict -> "watching" appears AT MOST ONCE.
# The bug stacked it TWICE (r1 glyph-word + r2 bifröst-else); the idle right block
# now shows a single calm "◦ watching" and r2 carries the ledger claim (or empty). ──
IDLE="$(printf '%s' "$JSON" | COLUMNS=$COLS HMD_NOW=7 python3 "$SL" | sed -E 's/\x1b\[[0-9;]*m//g')"
WCNT="$(printf '%s' "$IDLE" | grep -o 'watching' | grep -c '')"
if [ "$WCNT" -le 1 ]; then ok "idle render shows 'watching' at most once (got $WCNT)"
else bad "idle render shows 'watching' $WCNT times — dedup failed"; fi

# ── 10) SOLO TEASE: an empty wall (no roster + no team files) fills the dead row
# with a faint team invite — sells the wall, drives the team-growth loop. ──
assert_contains "$IDLE" "invite your team" "empty-wall solo render teases the team invite"
assert_grep 'watch' "$IDLE" "solo tease carries the '── watch ──' styling"

# ── 11) populated wall has NO tease: the real watch wall replaces the invite. ──
NOWP="$(python3 -c 'import time;print(int(time.time()))')"
printf '{"haid":"kai-1","name":"kai","agent":"coder","verdict":"working","file":"db.ts","ts":%s}' "$NOWP" > "$WS/.heimdall/team/kai.json"
POP="$(printf '%s' "$JSON" | COLUMNS=$COLS python3 "$SL" | sed -E 's/\x1b\[[0-9;]*m//g')"
if grep -qF 'invite your team' <<<"$POP"; then bad "populated wall still shows the solo tease"
else ok "populated wall has no tease (real wall renders)"; fi
rm -f "$WS/.heimdall/team/kai.json"

# ── 12) AUTO-BEAT: the render fires a throttled, detached heartbeat so THIS dev
# appears on teammates' walls (the roster read alone never announced us). It must
# never block the render (CP unreachable), and must throttle (~1 beat / 20s). ──
if [ -x "$BIN/heimdall-presence" ]; then
  WSB="$(mk_workspace)"; mkdir -p "$WSB/.heimdall"
  JSONB='{"workspace":{"current_dir":"'"$WSB"'"}}'
  T0="$(python3 -c 'import time;print(int(time.time()*1000))')"
  printf '%s' "$JSONB" | HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=$COLS python3 "$SL" >/dev/null 2>&1
  T1="$(python3 -c 'import time;print(int(time.time()*1000))')"
  if [ "$(( T1 - T0 ))" -lt 2000 ]; then ok "auto-beat render non-blocking on unreachable CP ($(( T1 - T0 ))ms)"
  else bad "render blocked on the heartbeat ($(( T1 - T0 ))ms)"; fi
  if [ -f "$WSB/.heimdall/.beat-stamp" ]; then ok "auto-beat dropped a heartbeat stamp"
  else bad "no .beat-stamp — render did not beat"; fi
  M1="$(stat -f %m "$WSB/.heimdall/.beat-stamp" 2>/dev/null || stat -c %Y "$WSB/.heimdall/.beat-stamp" 2>/dev/null)"
  printf '%s' "$JSONB" | HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=$COLS python3 "$SL" >/dev/null 2>&1
  M2="$(stat -f %m "$WSB/.heimdall/.beat-stamp" 2>/dev/null || stat -c %Y "$WSB/.heimdall/.beat-stamp" 2>/dev/null)"
  if [ "$M1" = "$M2" ]; then ok "auto-beat throttled (no re-beat within the 20s window)"
  else bad "auto-beat not throttled (stamp bumped on immediate re-render)"; fi
else
  note "heimdall-presence bin absent — skipping auto-beat assertions"
fi

rm -rf "$WS"
finish
