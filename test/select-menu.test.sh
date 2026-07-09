#!/usr/bin/env bash
#
# select-menu.test.sh — arrow-key selection helper (bin/lib/select.sh).
#
# WHAT THIS GATES.
#   1. Arrow-key PARSING: scripted ESC sequences (printf '\033[B\n') drive the
#      selector to the right choice — down/up, j/k, wrap-around, Enter-confirm.
#   2. NON-TTY FALLBACK (anti-hang): piped/empty stdin never blocks — it returns
#      the caller's default within a hard timeout, proving no wait on a stream
#      that will not deliver keys (the curl|bash / CI hang class).
#   3. TERMINAL RESTORE: the Ctrl-C (SIGINT) path restores the saved stty state
#      and exits 130 — the terminal is never left in raw mode; AND the normal
#      completion path also restores stty.
#
# HOW IT DRIVES A TTY-ONLY WIDGET WITHOUT A REAL TTY. hmd_select forces the
# key-reading path when HMD_SELECT_FORCE_TTY=1, so a pipe can stand in for the
# terminal. It reports the result via the globals HMD_SELECT_INDEX /
# HMD_SELECT_VALUE / HMD_SELECT_ABORTED (never stdout capture — see select.sh),
# so we source the helper into THIS shell and read the globals after each call.
#
# EXIT: 0 = all assertions pass; nonzero = a failure (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SELECT_LIB="$REPO/bin/lib/select.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -f "$SELECT_LIB" ] || { echo "FATAL: $SELECT_LIB missing"; exit 2; }
# shellcheck disable=SC1090
. "$SELECT_LIB"

# drive KEYS DEFAULT OPT... — run the forced-TTY selector with KEYS on stdin.
# Sets HMD_SELECT_INDEX / _VALUE / _ABORTED in this shell (UI is silenced).
drive() {
  local keys="$1"; shift
  local def="$1"; shift
  HMD_SELECT_INDEX=""; HMD_SELECT_VALUE=""; HMD_SELECT_ABORTED=""
  HMD_SELECT_FORCE_TTY=1 hmd_select "$def" "" "$@" < <(printf '%b' "$keys") >/dev/null 2>&1
}

# ── 1. Arrow-key parsing ──────────────────────────────────────────────────────

# Down then Enter → second option (index 1).
drive '\033[B\n' 0 coder non-coder
{ [ "$HMD_SELECT_INDEX" = "1" ] && [ "$HMD_SELECT_VALUE" = "non-coder" ]; } \
  && ok "down + Enter selects option 2 (index 1 = non-coder)" \
  || bad "down + Enter → idx='$HMD_SELECT_INDEX' val='$HMD_SELECT_VALUE' (want 1/non-coder)"

# Plain Enter → default (index 0).
drive '\n' 0 coder non-coder
{ [ "$HMD_SELECT_INDEX" = "0" ] && [ "$HMD_SELECT_VALUE" = "coder" ]; } \
  && ok "Enter alone confirms the default (index 0 = coder)" \
  || bad "Enter alone → idx='$HMD_SELECT_INDEX' (want 0/coder)"

# 'j' (vim down) then Enter → index 1.
drive 'j\n' 0 coder non-coder
[ "$HMD_SELECT_INDEX" = "1" ] \
  && ok "'j' acts as down-arrow (index 1)" \
  || bad "'j' down → idx='$HMD_SELECT_INDEX' (want 1)"

# 'k' (vim up) from index 0 wraps to last (index 1 of 2).
drive 'k\n' 0 coder non-coder
[ "$HMD_SELECT_INDEX" = "1" ] \
  && ok "'k' up-wraps from first to last (index 1)" \
  || bad "'k' up-wrap → idx='$HMD_SELECT_INDEX' (want 1)"

# Two downs on a 2-item menu wrap back to the top (0 → 1 → 0).
drive '\033[B\033[B\n' 0 coder non-coder
[ "$HMD_SELECT_INDEX" = "0" ] \
  && ok "down x2 wraps around to index 0" \
  || bad "down x2 wrap → idx='$HMD_SELECT_INDEX' (want 0)"

# Down twice then up once on a 3-item menu → index 1.
drive '\033[B\033[B\033[A\n' 0 a b c
[ "$HMD_SELECT_INDEX" = "1" ] \
  && ok "3-item: down,down,up lands on index 1" \
  || bad "3-item nav → idx='$HMD_SELECT_INDEX' (want 1)"

# Bare ESC (no following bytes) aborts to the default and flags abort.
drive '\033' 2 a b c d
{ [ "$HMD_SELECT_INDEX" = "2" ] && [ "$HMD_SELECT_ABORTED" = "1" ]; } \
  && ok "bare ESC aborts to the default index and sets HMD_SELECT_ABORTED" \
  || bad "bare ESC → idx='$HMD_SELECT_INDEX' aborted='$HMD_SELECT_ABORTED' (want 2/1)"

# ── 2. Non-TTY fallback: no hang, picks the default ───────────────────────────
# Run in a SEPARATE process under a hard timeout so a hang would surface as a
# timeout kill (rc 124) rather than wedging the suite. stdin is /dev/null (a
# closed, non-TTY stream) and force-mode is OFF, so the selector must fall back
# to the default WITHOUT reading a single byte.
have_timeout=""
command -v timeout >/dev/null 2>&1 && have_timeout="timeout 5"
command -v gtimeout >/dev/null 2>&1 && have_timeout="gtimeout 5"

fb_out="$(
  $have_timeout bash -c '
    . "'"$SELECT_LIB"'"
    hmd_select 1 "pick one" alpha beta gamma </dev/null >/dev/null 2>&1
    printf "%s|%s|%s" "$HMD_SELECT_INDEX" "$HMD_SELECT_VALUE" "$HMD_SELECT_ABORTED"
  '
)"
fb_rc=$?
if [ "$fb_rc" = "124" ]; then
  bad "non-TTY fallback HUNG (timed out) — the anti-hang contract is broken"
elif [ "$fb_out" = "1|beta|1" ]; then
  ok "non-TTY /dev/null stdin returns the default (index 1 = beta), no hang"
else
  bad "non-TTY fallback → '$fb_out' rc=$fb_rc (want '1|beta|1')"
fi

# Piping content in still yields the default (never blocks on a non-TTY stream).
fb2_out="$(
  $have_timeout bash -c '
    . "'"$SELECT_LIB"'"
    printf "2\n" | { hmd_select 0 "" x y z >/dev/null 2>&1; printf "%s" "$HMD_SELECT_INDEX"; }
  '
)"
fb2_rc=$?
if [ "$fb2_rc" = "124" ]; then
  bad "non-TTY fallback with piped text HUNG (timed out)"
elif [ "$fb2_out" = "0" ]; then
  ok "non-TTY piped text does not block and picks the default (index 0)"
else
  bad "non-TTY piped text → '$fb2_out' rc=$fb2_rc (want '0')"
fi

# ── 3. Terminal restore ───────────────────────────────────────────────────────
# Ctrl-C path: the SIGINT/TERM handler must restore the SAVED stty state and exit
# 130. We shadow `stty` inside a subshell so we can capture exactly what restore
# passed it, and confirm the process aborts with 130.
int_log="$(mktemp)"
int_rc=0
(
  . "$SELECT_LIB"
  stty() { echo "stty:$*" >>"$int_log"; }
  _HMD_STTY_SAVED="COOKED-STATE-42"
  _hmd_select_on_int
) 2>/dev/null
int_rc=$?
if [ "$int_rc" = "130" ] && grep -q "stty:COOKED-STATE-42" "$int_log"; then
  ok "Ctrl-C handler restores saved stty state and exits 130"
else
  bad "Ctrl-C handler rc=$int_rc, restore log='$(cat "$int_log" 2>/dev/null)' (want 130 + stty:COOKED-STATE-42)"
fi
rm -f "$int_log"

# Normal completion path also restores stty (save on entry, restore on confirm).
norm_log="$(mktemp)"
(
  . "$SELECT_LIB"
  # Fake stty: `-g` prints the saved cookie; every call is logged. Real terminal
  # never touched — proves the save/restore bracket runs on the happy path too.
  stty() {
    if [ "$1" = "-g" ]; then echo "SAVED-COOKIE"; fi
    echo "stty:$*" >>"$norm_log"
  }
  HMD_SELECT_FORCE_TTY=1 hmd_select 0 "" one two < <(printf '\n') >/dev/null 2>&1
) 2>/dev/null
if grep -q "stty:SAVED-COOKIE" "$norm_log"; then
  ok "normal completion restores stty to the saved state (terminal never left raw)"
else
  bad "normal path did not restore saved stty — log='$(cat "$norm_log" 2>/dev/null)'"
fi
rm -f "$norm_log"

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "select-menu.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
