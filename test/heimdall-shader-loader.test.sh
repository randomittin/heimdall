#!/usr/bin/env bash
# heimdall-shader-loader.test.sh — acceptance harness for the shader-style spinner
# (bin/heimdall spin()/_spin_tier()). Sources bin/heimdall in HEIMDALL_LIB_ONLY
# mode to exercise the loader in isolation (no launch path, no real `claude`).
#
# Asserts:
#   1. frames emit          — truecolor tier writes braille glyphs + 38;2 color SGR
#   2. mono has no color     — mono tier writes braille glyphs but ZERO 38;2 bytes
#   3. no hang on non-TTY    — piped stdout → tier resolves 'none', spin returns
#                              promptly and emits only the ✔ result line (no \r)
#   4. tier precedence       — non-TTY + no override → 'none' even with COLORTERM
#   5. cursor restored        — an animated run ends with the show-cursor sequence
#
# Also runnable as a visual demo:  heimdall-shader-loader.test.sh --demo
#
# Exit 0 = all pass, 1 = a failed assertion, 2 = harness/load error.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HMD="$(cd "$HERE/.." && pwd)/bin/heimdall"
[ -f "$HMD" ] || { echo "FATAL: bin/heimdall not found at $HMD" >&2; exit 2; }

# ── visual demo mode ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--demo" ]; then
  # shellcheck disable=SC1090
  HEIMDALL_LIB_ONLY=1 source "$HMD" >/dev/null 2>&1 || { echo "load failed" >&2; exit 2; }
  for t in truecolor 256 16 mono; do
    printf '\n  tier: %s\n' "$t"
    ( sleep 1.4 ) & pid=$!
    HEIMDALL_SPIN_TIER="$t" spin "$pid" "shader sweep — $t"
  done
  echo
  exit 0
fi

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Portable watchdog — macOS ships no `timeout`/`gtimeout`. Runs <cmd...> in the
# background and SIGTERMs it after <secs>; returns the command's real rc, or 124
# if the watchdog had to fire (so a never-exiting regression reads as a FAIL, not
# a hung test). Redirections on the caller apply to the backgrounded command.
_timeout() { # <secs> <cmd...>
  local secs="$1"; shift
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) & local killer=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  if kill -0 "$killer" 2>/dev/null; then
    kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  else
    rc=124   # watchdog already fired → treat as timeout
  fi
  return $rc
}

# Run spin() headlessly in a forced tier, capturing stdout to a file. Bounded by
# the watchdog so a regression that never exits is caught as a FAIL, not a hang.
# stdout is a pipe/file here (non-TTY) — HEIMDALL_SPIN_TIER bypasses the TTY guard.
run_spin() { # <tier> <dur> <outfile>
  local tier="$1" dur="$2" out="$3"
  _timeout 8 bash -c '
    export HEIMDALL_LIB_ONLY=1
    source "$1" >/dev/null 2>&1 || exit 3
    ( sleep "$3" ) & p=$!
    HEIMDALL_SPIN_TIER="$2" spin "$p" "building"
  ' _ "$HMD" "$tier" "$dur" >"$out" 2>/dev/null
}

BRAILLE='⠋'   # first spin frame — must appear in any animated tier

# ── 1. frames emit (truecolor) ────────────────────────────────────────────────
TC="$(mktemp)"; run_spin truecolor 0.5 "$TC"; RC=$?
if [ $RC -ne 0 ]; then bad "truecolor run exited $RC (expected 0)"
elif ! grep -q "$BRAILLE" "$TC"; then bad "truecolor: no braille frames emitted"
elif ! grep -q '38;2' "$TC"; then bad "truecolor: no 38;2 truecolor SGR emitted"
else ok "frames emit — truecolor writes braille + 38;2 color sweep"; fi

# ── 2. mono has no color codes ────────────────────────────────────────────────
MO="$(mktemp)"; run_spin mono 0.5 "$MO"; RC=$?
if [ $RC -ne 0 ]; then bad "mono run exited $RC (expected 0)"
elif ! grep -q "$BRAILLE" "$MO"; then bad "mono: no braille frames emitted"
elif grep -q '38;2' "$MO"; then bad "mono: leaked 38;2 truecolor bytes (must be plain)"
elif grep -q '38;5' "$MO"; then bad "mono: leaked 38;5 256-color bytes (must be plain)"
else ok "mono is plain braille — zero 38;2 / 38;5 color bytes"; fi

# ── 3. no hang on non-TTY (no override → tier 'none') ─────────────────────────
NT="$(mktemp)"
START=$SECONDS
_timeout 8 bash -c '
  export HEIMDALL_LIB_ONLY=1
  source "$1" >/dev/null 2>&1 || exit 3
  ( sleep 0.3 ) & p=$!
  spin "$p" "building"
' _ "$HMD" >"$NT" 2>/dev/null
RC=$?
ELAPSED=$((SECONDS-START))
if [ $RC -eq 124 ]; then bad "non-TTY: spin HUNG (timeout)"
elif [ $RC -ne 0 ]; then bad "non-TTY run exited $RC (expected 0)"
elif [ $ELAPSED -ge 5 ]; then bad "non-TTY: spin took ${ELAPSED}s (expected prompt return)"
elif grep -q $'\r' "$NT"; then bad "non-TTY: emitted \\r frames into a pipe (garbage)"
elif grep -q '38;2' "$NT"; then bad "non-TTY: emitted ANSI color into a pipe (garbage)"
elif ! grep -q '✔ building' "$NT"; then bad "non-TTY: missing '✔ building' result line"
else ok "non-TTY: no hang, no \\r/ANSI garbage, clean ✔ result line"; fi

# ── 4. tier precedence: non-TTY + COLORTERM still resolves 'none' ─────────────
T4="$(COLORTERM=truecolor TERM=xterm-256color bash -c '
  export HEIMDALL_LIB_ONLY=1
  source "$1" >/dev/null 2>&1 || exit 3
  _spin_tier
' _ "$HMD" 2>/dev/null | cat)"   # piped → stdout is non-TTY
if [ "$T4" = "none" ]; then ok "tier precedence — non-TTY wins over COLORTERM (→ none)"
else bad "tier precedence: non-TTY gave '$T4' (expected 'none')"; fi

# ── 5. cursor restored after an animated run ──────────────────────────────────
if grep -q $'\033\[?25h' "$TC"; then ok "cursor restored (show-cursor sequence on stop)"
else bad "cursor NOT restored — missing \\033[?25h on stop"; fi

rm -f "$TC" "$MO" "$NT"

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
