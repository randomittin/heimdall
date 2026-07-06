#!/usr/bin/env bash
#
# heimdall-statusline-terminals.test.sh — multi-terminal capability detection +
# graded render fallback for the watchman statusline.
#
# The statusline builds its line in 24-bit truecolor + full unicode, then
# sentinels/hmd_termcaps.py downgrades the finished bytes to the DETECTED tier:
#   color   : truecolor | 256 | 16 | mono
#   unicode : full | basic | ascii
#
# We drive both layers with FABRICATED terminal env profiles and assert the
# emitted bytes match the expected tier (grep for/against `38;2;` truecolor SGR,
# `38;5;` 256-color SGR, unicode half-blocks/emoji):
#
#   iTerm2  (COLORTERM=truecolor)                 -> truecolor: 38;2; + half-blocks
#   Apple_Terminal (no COLORTERM)                 -> 256: NO 38;2;, uses 38;5;
#   tmux    (TERM=screen-256color, $TMUX set)     -> passthrough-safe 256, NO 38;2;
#   dumb    (TERM=dumb)                            -> ASCII only, no ESC-color, no glyphs
#   Warp    (TERM_PROGRAM=WarpTerminal)            -> truecolor (Warp does 24-bit)
#   16      (TERM=xterm, no COLORTERM)             -> 16-color, NO 38;2;/38;5;
#
# Override env HEIMDALL_STATUSLINE_MODE forces a tier (Warp/mis-detection escape):
#   256 on iTerm    -> NO 38;2;
#   ascii           -> ASCII only
# FALSIFIER: force truecolor on the Apple_Terminal profile -> the "no 38;2; on
# Apple_Terminal" guard FAILS (38;2; reappears) — proving the guard is real.
#
# Hermetic: HOME is redirected so the presence heartbeat can't touch ~/.heimdall,
# and CP is pointed at an unreachable port so no render blocks/forks off-box.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
TC="$ROOT/sentinels/hmd_termcaps.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"; mkdir -p "$PROJ"
JSON='{"workspace":{"current_dir":"'"$PROJ"'"}}'

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has()     { grep -qF -- "$2" <<<"$1"; }
assert_has()     { if has "$1" "$3"; then ok "$2"; else bad "$2 (missing: $3)"; fi; }
assert_not_has() { if has "$1" "$3"; then bad "$2 (unexpected: $3)"; else ok "$2"; fi; }
assert_eq()      { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }
[ -f "$TC" ] || { echo "FATAL: termcaps module missing at $TC"; exit 2; }

# probe the detection module directly: env -> "color=<tier> unicode=<tier> ..."
probe() { env -i PATH="$PATH" HOME="$TMP" "$@" python3 "$TC"; }
# color tier only ("truecolor"/"256"/"16"/"mono")
ctier() { probe "$@" | sed -E 's/.*color=([a-z0-9]+).*/\1/'; }
utier() { probe "$@" | sed -E 's/.*unicode=([a-z]+).*/\1/'; }
# render the full HUD under a clean profile (only the vars we pass are set)
render() { env -i PATH="$PATH" HOME="$TMP" HEIMDALL_CP_URL="http://127.0.0.1:1" \
                  COLUMNS=170 LANG=en_US.UTF-8 "$@" python3 "$SL"; }

HALF_A='▀'; HALF_B='▄'; BAR='▓'; PIP='●'; TICK='✓'; BOLT='⚡'

echo "== detection matrix: env -> color tier =="
assert_eq "iTerm2 COLORTERM=truecolor -> truecolor" \
  "$(ctier COLORTERM=truecolor TERM=xterm-256color TERM_PROGRAM=iTerm.app)" "truecolor"
assert_eq "Apple_Terminal (no COLORTERM) -> 256" \
  "$(ctier TERM=xterm-256color TERM_PROGRAM=Apple_Terminal)" "256"
assert_eq "tmux screen-256color + \$TMUX -> 256 (passthrough-safe, not truecolor)" \
  "$(ctier COLORTERM=truecolor TERM=screen-256color TMUX=/tmp/tmux-1/default,9,0)" "256"
assert_eq "bare screen (no 256) -> 16" \
  "$(ctier TERM=screen TMUX=/tmp/tmux-1/default,9,0)" "16"
assert_eq "dumb -> mono" "$(ctier TERM=dumb)" "mono"
assert_eq "dumb -> ascii unicode" "$(utier TERM=dumb)" "ascii"
assert_eq "Warp COLORTERM=truecolor -> truecolor" \
  "$(ctier COLORTERM=truecolor TERM=xterm-256color TERM_PROGRAM=WarpTerminal)" "truecolor"
assert_eq "plain xterm (no COLORTERM) -> 16" \
  "$(ctier TERM=xterm)" "16"
assert_eq "no TERM at all -> mono" "$(ctier)" "mono"

echo "== override env HEIMDALL_STATUSLINE_MODE =="
assert_eq "mode=256 forces 256 on an iTerm profile" \
  "$(ctier HEIMDALL_STATUSLINE_MODE=256 COLORTERM=truecolor TERM_PROGRAM=iTerm.app)" "256"
assert_eq "mode=truecolor forces truecolor on Apple_Terminal (override)" \
  "$(ctier HEIMDALL_STATUSLINE_MODE=truecolor TERM=xterm-256color TERM_PROGRAM=Apple_Terminal)" "truecolor"
assert_eq "mode=16 forces 16 even on a truecolor terminal" \
  "$(ctier HEIMDALL_STATUSLINE_MODE=16 COLORTERM=truecolor)" "16"
assert_eq "mode=mono forces mono" "$(ctier HEIMDALL_STATUSLINE_MODE=mono COLORTERM=truecolor)" "mono"
assert_eq "mode=ascii -> mono color" "$(ctier HEIMDALL_STATUSLINE_MODE=ascii COLORTERM=truecolor)" "mono"
assert_eq "mode=ascii -> ascii unicode" "$(utier HEIMDALL_STATUSLINE_MODE=ascii COLORTERM=truecolor)" "ascii"
assert_eq "unknown mode falls back to auto (truecolor here)" \
  "$(ctier HEIMDALL_STATUSLINE_MODE=lolwut COLORTERM=truecolor)" "truecolor"

echo "== rendered bytes per profile =="
# iTerm2 truecolor: 24-bit SGR + half-block sigil present (the full-caps path)
ITERM="$(printf '%s' "$JSON" | render COLORTERM=truecolor TERM=xterm-256color TERM_PROGRAM=iTerm.app HMD_NOW=1)"
assert_has "$ITERM" "iTerm2 -> emits 24-bit truecolor SGR (38;2;)" "38;2;"
if has "$ITERM" "$HALF_A" || has "$ITERM" "$HALF_B"; then ok "iTerm2 -> half-block sigil rendered"
else bad "iTerm2 -> no half-block sigil (unicode=full expected)"; fi

# Apple Terminal.app: NEVER raw truecolor; 256-color palette instead
APPLE="$(printf '%s' "$JSON" | render TERM=xterm-256color TERM_PROGRAM=Apple_Terminal HMD_NOW=1)"
assert_not_has "$APPLE" "Apple_Terminal -> NO 24-bit truecolor SGR (38;2;)" "38;2;"
assert_has     "$APPLE" "Apple_Terminal -> uses 256-color SGR (38;5;)" "38;5;"

# tmux/screen: passthrough-safe, no truecolor leaking through screen-256color
TMUXOUT="$(printf '%s' "$JSON" | render COLORTERM=truecolor TERM=screen-256color TMUX=/tmp/tmux-1/default,9,0 HMD_NOW=1)"
assert_not_has "$TMUXOUT" "tmux -> NO truecolor SGR (would be swallowed without Tc+passthrough)" "38;2;"
assert_has     "$TMUXOUT" "tmux -> passthrough-safe 256-color SGR (38;5;)" "38;5;"

# dumb / CI: ASCII only — no ESC-color, no half-blocks, no emoji, still legible
DUMB="$(printf '%s' "$JSON" | render TERM=dumb HMD_NOW=1)"; DEC=$?
assert_eq "dumb -> exits 0" "$DEC" "0"
if [ -n "$DUMB" ]; then ok "dumb -> non-empty (never blank)"; else bad "dumb -> blank output"; fi
if printf '%s' "$DUMB" | grep -q $'\033'; then bad "dumb -> emitted an ESC byte (no color/escape allowed)"
else ok "dumb -> no ESC/ANSI bytes at all"; fi
assert_not_has "$DUMB" "dumb -> no truecolor SGR" "38;2;"
assert_not_has "$DUMB" "dumb -> no 256 SGR" "38;5;"
assert_not_has "$DUMB" "dumb -> no half-block ▀" "$HALF_A"
assert_not_has "$DUMB" "dumb -> no half-block ▄" "$HALF_B"
assert_not_has "$DUMB" "dumb -> no bar block ▓" "$BAR"
assert_not_has "$DUMB" "dumb -> no bullet ●" "$PIP"
assert_not_has "$DUMB" "dumb -> no emoji bolt ⚡" "$BOLT"
assert_has     "$DUMB" "dumb -> still branded (HEIMDALL wordmark)" "HEIMDALL"
assert_has     "$DUMB" "dumb -> branded ASCII sigil (hmd)" "hmd"

# Warp: its own renderer handles 24-bit; distinct from Terminal.app
WARP="$(printf '%s' "$JSON" | render COLORTERM=truecolor TERM=xterm-256color TERM_PROGRAM=WarpTerminal HMD_NOW=1)"
assert_has "$WARP" "Warp -> emits 24-bit truecolor SGR (38;2;)" "38;2;"

echo "== override renders =="
OV256="$(printf '%s' "$JSON" | render HEIMDALL_STATUSLINE_MODE=256 COLORTERM=truecolor TERM_PROGRAM=iTerm.app HMD_NOW=1)"
assert_not_has "$OV256" "mode=256 override -> NO 38;2; even on a truecolor terminal" "38;2;"
assert_has     "$OV256" "mode=256 override -> 38;5; used" "38;5;"

OVASCII="$(printf '%s' "$JSON" | render HEIMDALL_STATUSLINE_MODE=ascii COLORTERM=truecolor TERM_PROGRAM=iTerm.app HMD_NOW=1)"
if printf '%s' "$OVASCII" | grep -q $'\033'; then bad "mode=ascii -> emitted an ESC byte"
else ok "mode=ascii override -> no ESC/ANSI bytes"; fi
assert_not_has "$OVASCII" "mode=ascii override -> no half-block" "$HALF_A"

echo "== falsifier: forcing truecolor on Apple_Terminal breaks the guard =="
# The "no 38;2; on Apple_Terminal" assertion above MUST be falsifiable: force the
# truecolor tier on the very same profile and 38;2; MUST reappear.
APPLE_FORCED="$(printf '%s' "$JSON" | render HEIMDALL_STATUSLINE_MODE=truecolor TERM=xterm-256color TERM_PROGRAM=Apple_Terminal HMD_NOW=1)"
assert_has "$APPLE_FORCED" "falsifier -> forced truecolor re-introduces 38;2; on Apple_Terminal (guard is real)" "38;2;"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
