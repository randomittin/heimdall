#!/usr/bin/env bash
# hmd-farewell.sh — the watchman sleeps. The session-END counterpart to the
# session-START wake (bin/heimdall print_banner / narrate_launch_wakeup).
#
# One CHEAP, SHAREABLE close: a resting watchman + a one-line RECEIPT built from
# REAL session stats (never fabricated) + a punchy "unproven → proven" tagline.
# Designed to feel like a satisfying, screenshot-worthy end to the run.
#
# Where it runs: the SessionEnd hook, in the FOREGROUND, AFTER the fast
# checkpoint + autocommit have landed — so "clean tree" on the receipt is a TRUE
# proof, not a promise. It stays cheap on purpose: the heavy reel/summary-card
# render is backgrounded by the hook and must never be re-introduced here.
#
# Stats are REAL or ABSENT — never invented:
#   - files edited this session  <- bin/edit-tracker paths   (session-scoped ledger)
#   - agents spawned this session <- bin/parallelism-tracker grade
#   - clean tree                  <- git status --porcelain empty (committed proof)
# Any stat that is zero/unavailable is DROPPED from the receipt; if none resolve,
# the tagline alone closes the session cleanly.
#
# Rendering (mirrors sentinels/hmd-banner.sh + the uninstall farewell):
#   TTY      -> the `sleep` watchman frame (colored) + receipt + tagline.
#   non-TTY  -> NO frame glyphs (garbage through a pipe); clean text receipt only.
# NO_COLOR / TERM=dumb -> plain text. HEIMDALL_NO_INTRO=1 -> art suppressed
# (recordings / CI) but the text receipt still prints. Never fatal.
#
#   bash hmd-farewell.sh              # print the farewell
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"

is_tty() { [ -t 1 ]; }
want_color() { is_tty && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; }

# ── palette (truecolor; degrades to nothing when color is unwanted) ──
if want_color; then
  CY=$'\033[38;2;34;211;238m'; GR=$'\033[38;2;34;197;94m'
  DIM=$'\033[38;2;120;134;152m'; B=$'\033[1m'; X=$'\033[0m'
else
  CY=""; GR=""; DIM=""; B=""; X=""
fi

# ── REAL session stats (cheap; each degrades to empty on any failure) ──
edits=""; agents=""; clean=""

ETRACKER="$PLUGIN_DIR/bin/edit-tracker"
if [ -x "$ETRACKER" ]; then
  _e="$("$ETRACKER" paths 2>/dev/null | grep -c . 2>/dev/null || true)"
  case "$_e" in ''|*[!0-9]*) _e=0 ;; esac
  [ "$_e" -gt 0 ] && edits="$_e"
fi

PTRACKER="$PLUGIN_DIR/bin/parallelism-tracker"
if [ -x "$PTRACKER" ]; then
  _grade="$("$PTRACKER" grade 2>/dev/null || true)"
  _a="$(printf '%s' "$_grade" | sed -nE 's/.*agents: ([0-9]+) calls.*/\1/p' | head -1)"
  case "${_a:-}" in ''|*[!0-9]*) _a="" ;; esac
  [ -n "$_a" ] && [ "$_a" -gt 0 ] && agents="$_a"
fi

# Clean tree = the session-end checkpoint/autocommit already landed everything.
# This is a TRUE proof of "committed", cheap (one porcelain call).
if git rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then clean="yes"; fi
fi

# ── build the receipt line from whatever REAL stats resolved ──
parts=()
[ -n "$edits" ]  && parts+=("${B}${edits}${X}${DIM} $([ "$edits" = 1 ] && echo file || echo files) edited${X}")
[ -n "$agents" ] && parts+=("${B}${agents}${X}${DIM} $([ "$agents" = 1 ] && echo agent || echo agents)${X}")
[ -n "$clean" ]  && parts+=("${GR}clean tree${X}")

receipt=""
if [ "${#parts[@]}" -gt 0 ]; then
  receipt="${parts[0]}"
  i=1
  while [ "$i" -lt "${#parts[@]}" ]; do
    receipt="${receipt}${DIM} · ${X}${parts[$i]}"
    i=$((i + 1))
  done
fi

# ── the resting watchman frame (TTY + not suppressed + renderer present) ──
FACE_BIN="$PLUGIN_DIR/bin/heimdall-face"
if is_tty && [ "${HEIMDALL_NO_INTRO:-0}" != "1" ] && [ -x "$FACE_BIN" ]; then
  face_flag="--no-color"; want_color && face_flag="--color"
  printf '\n'
  while IFS= read -r _fl; do
    printf '  %s\n' "$_fl"
  done < <("$FACE_BIN" --frame sleep "$face_flag" 2>/dev/null)
fi

# ── the close: title -> receipt (if any) -> tagline ──
printf '  %b\n' "${CY}${B}▸${X} ${DIM}the watchman sleeps.${X}"
[ -n "$receipt" ] && printf '  %b\n' "$receipt"
printf '  %b\n' "${CY}${B}HEIMDALL${X} ${DIM}· what shipped, shipped proven.${X}"
printf '\n'
