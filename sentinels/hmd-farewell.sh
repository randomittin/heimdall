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

# ── FIX 1: one-shot sigil-unlock reveal ──────────────────────────────────────
# When `hmd` crosses 5 runs it silently unlocks `hmd sigil set <hero>`. bin/heimdall
# arms $HMD_HOME/.unlock-pending on that crossing; here we reveal it ONCE, then drop
# a .unlock-shown marker so it never repeats. Text-only (paste-clean); never fatal.
HMD_HOME="${HEIMDALL_HOME:-$HOME/.heimdall}"
UNLOCK_PENDING="$HMD_HOME/.unlock-pending"
UNLOCK_SHOWN="$HMD_HOME/.unlock-shown"
unlock_line=""
if [ -f "$UNLOCK_PENDING" ] && [ ! -f "$UNLOCK_SHOWN" ]; then
  unlock_line="${GR}${B}🔓 sigil customization unlocked${X}${DIM} — ${X}${B}hmd sigil set <hero>${X}"
  mkdir -p "$HMD_HOME" 2>/dev/null || true
  : > "$UNLOCK_SHOWN" 2>/dev/null || true      # mark shown — one-shot, never repeats
  rm -f "$UNLOCK_PENDING" 2>/dev/null || true
fi

# ── FIX 3: share CTA — surface the REAL run-card artifact path ────────────────
# The SessionEnd hook backgrounds the reel/summary render into .planning/reels/ but
# never tells the dev where the shareable artifact landed. Point at the NEWEST reel
# artifact IF one is freshly written for THIS run (mtime within the freshness window),
# preferring a rendered visual over the text endframe. Never fabricated: if nothing
# fresh exists (the background render has not landed yet / is undetermined) we print
# NOTHING. Freshness window overridable for tests via HEIMDALL_FAREWELL_ARTIFACT_MAX_AGE.
share_line=""
REEL_DIR=".planning/reels"
if [ -d "$REEL_DIR" ]; then
  _now="$(date +%s 2>/dev/null || echo 0)"
  _maxage="${HEIMDALL_FAREWELL_ARTIFACT_MAX_AGE:-120}"
  case "$_maxage" in ''|*[!0-9]*) _maxage=120 ;; esac
  _best=""; _best_mt=0
  for _f in "$REEL_DIR"/*.gif "$REEL_DIR"/*.mp4 "$REEL_DIR"/*.png "$REEL_DIR"/*.txt; do
    [ -f "$_f" ] || continue
    _mt="$(stat -f %m "$_f" 2>/dev/null || stat -c %Y "$_f" 2>/dev/null || echo 0)"
    case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
    [ "$_mt" -gt "$_best_mt" ] && { _best_mt="$_mt"; _best="$_f"; }
  done
  if [ -n "$_best" ] && [ "$_now" -gt 0 ]; then
    _age=$(( _now - _best_mt ))
    if [ "$_age" -ge 0 ] && [ "$_age" -le "$_maxage" ]; then
      share_line="${DIM}your run card → ${X}${CY}${_best#./}${X}"
    fi
  fi
fi

# ── FIX 5: solo-run invite (growth beat) — mirrors the statusline solo tease ──
# When the run was SOLO (no teammates on the wall) the screenshot moment is the ideal
# recruit beat. Solo-detect via the SAME signals the statusline uses: the per-repo
# roster cache (online teammates) + the local team heartbeat files. Skip entirely when
# presence is opted-out (an invite would be a lie — no one can see the dev). Never fatal.
invite_line=""
_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$_top" ] || _top="$PWD"
HMD_REPO_DIR="$_top/.heimdall"
_optout=""
[ -f "$HMD_HOME/presence-off" ] && _optout=1          # global kill switch
if [ -z "$_optout" ] && [ -f "$HMD_REPO_DIR/presence.json" ]; then
  grep -qE '"enabled"[[:space:]]*:[[:space:]]*false' "$HMD_REPO_DIR/presence.json" 2>/dev/null && _optout=1
fi
if [ -z "$_optout" ]; then
  _has_team=""
  _roster="$HMD_REPO_DIR/.roster-cache.json"
  if [ -f "$_roster" ]; then
    if command -v jq >/dev/null 2>&1; then
      _n="$(jq 'if type=="array" then length else 0 end' "$_roster" 2>/dev/null || echo 0)"
      case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
      [ "$_n" -gt 0 ] && _has_team=1
    elif grep -qE '"(haid|handle)"' "$_roster" 2>/dev/null; then
      _has_team=1
    fi
  fi
  if [ -z "$_has_team" ] && [ -d "$HMD_REPO_DIR/team" ]; then
    for _tf in "$HMD_REPO_DIR/team"/*.json; do [ -f "$_tf" ] && { _has_team=1; break; }; done
  fi
  [ -z "$_has_team" ] && invite_line="${DIM}flying solo — invite your team · ${X}${B}hmd invite${X}"
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
[ -n "$receipt" ]     && printf '  %b\n' "$receipt"
[ -n "$unlock_line" ] && printf '  %b\n' "$unlock_line"
[ -n "$share_line" ]  && printf '  %b\n' "$share_line"
[ -n "$invite_line" ] && printf '  %b\n' "$invite_line"
printf '  %b\n' "${CY}${B}HEIMDALL${X} ${DIM}· what shipped, shipped proven.${X}"
printf '\n'
