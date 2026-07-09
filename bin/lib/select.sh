#!/usr/bin/env bash
# select.sh — reusable arrow-key selection menu for Heimdall interactive prompts.
#
# ONE function, hmd_select, that every interactive prompt calls instead of the
# old "type a number/letter + Enter" reads. It renders an option list with the
# current choice highlighted, moves with ↑/↓ (and j/k), confirms with Enter, and
# aborts cleanly on Ctrl-C / ESC — ALWAYS restoring the terminal (stty) on any
# exit path via a trap, so a raw-mode terminal is never left wedged.
#
# WHY globals, not stdout capture: the caller reads the result from the globals
#   HMD_SELECT_INDEX  (0-based index of the chosen option)
#   HMD_SELECT_VALUE  (the chosen option string)
#   HMD_SELECT_ABORTED (1 if ESC/EOF fell back to the default, else 0)
# rather than `$(hmd_select …)`. Command substitution makes stdout a PIPE, which
# would make `[ -t 1 ]` FALSE and defeat the TTY detection below. Using globals
# keeps stdout/stderr bound to the real terminal so TTY detection is accurate and
# the menu renders where the user can see it.
#
# NON-TTY / PIPED FALLBACK (critical — a hang here breaks curl|bash installs):
# when stdin or stdout is not a TTY (CI, piped, `curl|bash`, `</dev/null`) the
# selector NEVER reads keys and NEVER blocks — it returns the caller's default
# index immediately. Callers that must honor --yes / assume-yes / non-TTY-refuse
# contracts do so BEFORE calling hmd_select (the selector is reached only on a
# real terminal), so this fallback simply preserves the pre-existing default.
#
# TESTABILITY: set HMD_SELECT_FORCE_TTY=1 to force the key-reading path even when
# stdin is a pipe, so a test can drive it with scripted escape sequences
# (printf '\033[B\n' | …). stty calls are guarded (|| true) so a non-tty pipe in
# force mode degrades cleanly instead of erroring.
#
# Portability: bash 3.2 (macOS system bash) and up. Sourced only by bash scripts
# (#!/usr/bin/env bash), matching the other bin/lib/*.sh helpers.

# Saved terminal settings for the restore trap (global on purpose so the INT/TERM
# trap handler can see it).
_HMD_STTY_SAVED=""

# Restore the terminal to cooked mode and show the cursor. Idempotent + silent.
_hmd_select_restore() {
  if [ -n "${_HMD_STTY_SAVED:-}" ]; then
    stty "$_HMD_STTY_SAVED" 2>/dev/null || true
    _HMD_STTY_SAVED=""
  fi
  # Show the cursor again (we hide it while the menu is live).
  printf '\033[?25h' >&2 2>/dev/null || true
}

# Ctrl-C / SIGTERM during a live menu: restore the terminal FIRST, then abort the
# whole process. Aborting a prompt with Ctrl-C is the standard, expected UX — the
# critical guarantee is that we never leave the terminal in raw mode.
_hmd_select_on_int() {
  _hmd_select_restore
  printf '\n' >&2 2>/dev/null || true
  exit 130
}

# Redraw the option block in place. Assumes the cursor sits on the first option
# line. Highlights the current choice with reverse video + a ► marker.
_hmd_select_draw() {
  local _i
  for (( _i = 0; _i < _hs_n; _i++ )); do
    printf '\r\033[2K' >&2                       # CR + clear the whole line
    if [ "$_i" -eq "$_hs_cur" ]; then
      printf '  \033[7m ► %s \033[0m\n' "${_hs_opts[$_i]}" >&2
    else
      printf '    %s\n' "${_hs_opts[$_i]}" >&2
    fi
  done
}

# hmd_select DEFAULT_INDEX PROMPT OPTION0 OPTION1 [OPTION2 …]
#
#   DEFAULT_INDEX  0-based index selected on entry AND returned on non-TTY /
#                  ESC / EOF fallback.
#   PROMPT         a one-line header shown above the options (may be empty).
#   OPTION*        the choosable option strings (>= 1 required).
#
# Sets HMD_SELECT_INDEX / HMD_SELECT_VALUE / HMD_SELECT_ABORTED. Returns 0.
hmd_select() {
  local _hs_default="$1"; shift
  local _hs_prompt="$1"; shift
  local -a _hs_opts=("$@")
  local _hs_n="${#_hs_opts[@]}"

  HMD_SELECT_ABORTED=0

  # Guard: need at least one option and a sane default.
  if [ "$_hs_n" -lt 1 ]; then
    HMD_SELECT_INDEX=0
    HMD_SELECT_VALUE=""
    return 0
  fi
  case "$_hs_default" in
    ''|*[!0-9]*) _hs_default=0 ;;
  esac
  [ "$_hs_default" -ge "$_hs_n" ] && _hs_default=0

  # ── NON-TTY / PIPED FALLBACK ─────────────────────────────────────────────
  # Not a real terminal (and not force-mode) → return the default WITHOUT ever
  # reading a byte. This is the anti-hang contract: no stdin read means no wait,
  # so CI / piped / curl|bash paths can never wedge here.
  if [ "${HMD_SELECT_FORCE_TTY:-0}" != "1" ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      HMD_SELECT_INDEX="$_hs_default"
      HMD_SELECT_VALUE="${_hs_opts[$_hs_default]}"
      HMD_SELECT_ABORTED=1
      return 0
    fi
  fi

  # ── INTERACTIVE ARROW-KEY PATH ───────────────────────────────────────────
  local _hs_cur="$_hs_default"

  # Save terminal state and enter cbreak (char-at-a-time, no echo). We use
  # -icanon (not `raw`) so ISIG stays ON — Ctrl-C still delivers SIGINT to our
  # trap, which restores the terminal. min 1 time 0 = block for exactly 1 char.
  _HMD_STTY_SAVED="$(stty -g 2>/dev/null || true)"
  trap '_hmd_select_on_int' INT TERM
  stty -echo -icanon min 1 time 0 2>/dev/null || true
  printf '\033[?25l' >&2 2>/dev/null || true     # hide cursor

  # Header + first draw.
  [ -n "$_hs_prompt" ] && printf '%s\n' "$_hs_prompt" >&2
  _hs_hint='  \033[2m↑/↓ move · Enter select · Ctrl-C cancel\033[0m'
  printf "$_hs_hint\n" >&2
  _hmd_select_draw

  local _hs_key _hs_rest
  while :; do
    # Keypress POLL: -s (silent) -n1 (one char), NO -p prompt → reads a single
    # key, never solicits a typed line. On EOF `read` returns non-zero with an
    # empty key, which we treat like Enter (confirm) so a drained pipe (tests)
    # can never spin forever.
    if ! IFS= read -rsn1 _hs_key; then
      break                                       # EOF → confirm current
    fi

    case "$_hs_key" in
      '')                                         # Enter (delimiter) → confirm
        break ;;
      $'\033')                                    # ESC — maybe an arrow sequence
        # An arrow key is ESC [ A/B/C/D. Grab up to 2 more bytes with a short
        # timeout; a lone ESC (no bytes follow) is an abort request.
        _hs_rest=""
        IFS= read -rsn2 -t 1 _hs_rest 2>/dev/null || _hs_rest=""
        case "$_hs_rest" in
          '[A'|'OA') _hs_cur=$(( _hs_cur - 1 )) ;;  # up
          '[B'|'OB') _hs_cur=$(( _hs_cur + 1 )) ;;  # down
          '')                                       # bare ESC → abort to default
            _hs_cur="$_hs_default"
            HMD_SELECT_ABORTED=1
            break ;;
          *) : ;;                                   # other CSI → ignore
        esac ;;
      k|K) _hs_cur=$(( _hs_cur - 1 )) ;;          # vim up
      j|J) _hs_cur=$(( _hs_cur + 1 )) ;;          # vim down
      *) : ;;                                     # ignore anything else
    esac

    # Wrap-around so the menu never gets stuck at an edge.
    [ "$_hs_cur" -lt 0 ] && _hs_cur=$(( _hs_n - 1 ))
    [ "$_hs_cur" -ge "$_hs_n" ] && _hs_cur=0

    # Move the cursor back up to the first option line and redraw.
    printf '\033[%dA' "$_hs_n" >&2
    _hmd_select_draw
  done

  _hmd_select_restore
  trap - INT TERM

  HMD_SELECT_INDEX="$_hs_cur"
  HMD_SELECT_VALUE="${_hs_opts[$_hs_cur]}"
  return 0
}

# hmd_confirm PROMPT [DEFAULT_YES]
#
# A yes/no confirm rendered as a two-item arrow menu (No / Yes) — the arrow-key
# replacement for a `read -p "… [y/N] "` prompt. DEFAULT_YES=1 highlights Yes on
# entry (a [Y/n] prompt); anything else defaults to No (the safe [y/N] default).
# Returns 0 if the user chose Yes, 1 otherwise (including the non-TTY fallback,
# which returns the safe default). Built on hmd_select — no duplicated key logic.
hmd_confirm() {
  local _hc_prompt="$1"
  local _hc_default_yes="${2:-0}"
  local _hc_def=0
  [ "$_hc_default_yes" = "1" ] && _hc_def=1
  hmd_select "$_hc_def" "$_hc_prompt" "No" "Yes"
  [ "${HMD_SELECT_INDEX:-0}" = "1" ]
}
