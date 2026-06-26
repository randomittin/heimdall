#!/usr/bin/env bash
# statusline.sh — heimdall HUD for Claude Code's status bar
# PRIMARY: the full-width watchman (sentinels/hmd-statusline.py) — 4 rows, sigil
#   anchor left, gate verdict pinned right, team watch wall on the bottom rows.
#   It reads Claude Code's statusLine stdin JSON itself; we pipe stdin straight
#   through and hand it COLUMNS so the right-pinned verdict aligns. Zero model.
# FALLBACK: the legacy single-line instrument (bin/heimdall-face --statusline),
#   used iff python3 is unavailable, the watchman script is missing, or it exits
#   nonzero/empty. The bar must NEVER error, NEVER block, NEVER print prose.
#
# Never-error contract: the watchman output is captured to a var FIRST; we emit
# the fallback only after confirming the primary produced nothing usable. Every
# branch ends in `exit 0`.

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHMAN="$HERE/../sentinels/hmd-statusline.py"
FACE_BIN="$HERE/../bin/heimdall-face"

# ── Width: the watchman right-pins the verdict against COLUMNS. tput needs a tty
# (CC pipes stdout) so it usually fails here → fall back to 120. ──
COLS="$(tput cols 2>/dev/null)"
case "$COLS" in ''|*[!0-9]*) COLS=120 ;; esac
export COLUMNS="$COLS"

# ── Color detection (legacy fallback honors it via --color/--no-color) ──
if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" || "${TERM:-}" == *256color* ]]; then
  COLOR_FLAG="--color"
elif [ -t 1 ] || [ -n "${TERM:-}" ]; then
  COLOR_FLAG="--color"
else
  COLOR_FLAG="--no-color"
fi

# ── Slurp CC's statusLine stdin blob ONCE so both the watchman and the fallback
# signal-resolver can read it (stdin is consumable only once). Empty when a tty. ──
BLOB=""
[ -t 0 ] || BLOB="$(cat 2>/dev/null)"

# ── PRIMARY: the full-width watchman ──
# Capture first; emit only on success (nonempty). Any failure falls through.
if command -v python3 >/dev/null 2>&1 && [ -f "$WATCHMAN" ]; then
  WM="$(printf '%s' "$BLOB" | python3 "$WATCHMAN" 2>/dev/null)"
  if [ -n "$WM" ]; then
    printf '%s\n' "$WM"
    exit 0
  fi
fi

# ── FALLBACK: legacy single-line instrument ──
# Re-resolve project + token burn from the blob we already slurped (python cannot
# re-read the stdin the watchman attempt consumed). Tolerant: any miss → safe
# defaults. Echoes "PROJECT BURN EXCEEDS".
resolve_signals() {
  local blob="$1"
  [ -n "$blob" ] || { echo ". - 0"; return; }
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$blob" | python3 -c '
import json, os, sys
try:
    b = json.load(sys.stdin)
except Exception:
    print(". - 0"); sys.exit(0)
if not isinstance(b, dict):
    print(". - 0"); sys.exit(0)
proj = "."
cands = [b.get("cwd"), b.get("project_dir")]
ws = b.get("workspace")
if isinstance(ws, dict):
    cands += [ws.get("current_dir"), ws.get("project_dir")]
for c in cands:
    if isinstance(c, str) and c and os.path.isdir(c):
        proj = c
        break
burn = "-"
exceeds = "1" if b.get("exceeds_200k_tokens") is True else "0"
cw = b.get("context_window")
if isinstance(cw, dict):
    used = cw.get("used_percentage")
    if isinstance(used, (int, float)):
        burn = repr(float(used))
    else:
        size = cw.get("context_window_size")
        inp = cw.get("total_input_tokens")
        if isinstance(size, (int, float)) and size > 0 and isinstance(inp, (int, float)):
            burn = repr(max(0.0, min(100.0, (float(inp) / float(size)) * 100.0)))
print(proj, burn, exceeds)
' 2>/dev/null && return
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$blob" | jq -r '
      ((.cwd // .workspace.current_dir // .project_dir // .workspace.project_dir // ".")) as $p
      | ((.context_window.used_percentage) // "-") as $burn
      | (if .exceeds_200k_tokens == true then "1" else "0" end) as $ex
      | "\($p) \($burn) \($ex)"
    ' 2>/dev/null && return
  fi
  echo ". - 0"
}

PROJECT="."
BURN="-"
EXCEEDS="0"
if [ -n "${1:-}" ]; then
  PROJECT="$1"
else
  read -r PROJECT BURN EXCEEDS <<<"$(resolve_signals "$BLOB")"
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="."

if [ -x "$FACE_BIN" ] && command -v python3 >/dev/null 2>&1; then
  ARGS=(--statusline "$COLOR_FLAG")
  case "$BURN" in
    ''|'-'|'null') : ;;
    *) ARGS+=(--burn "$BURN") ;;
  esac
  [ "$EXCEEDS" = "1" ] && ARGS+=(--exceeds)
  ARGS+=("$PROJECT")
  LINE="$(python3 "$FACE_BIN" "${ARGS[@]}" </dev/null 2>/dev/null | head -n1)"
  if [ -n "$LINE" ]; then
    printf '%s\n' "$LINE"
    exit 0
  fi
fi

# ── Degraded floor: even the legacy bin is unavailable → idle watchman eyes, then
# plain text. Never blank, never an error. ──
if [ -x "$FACE_BIN" ] && command -v python3 >/dev/null 2>&1; then
  EYES="$(python3 "$FACE_BIN" --eyes "$COLOR_FLAG" "$PROJECT" </dev/null 2>/dev/null | head -n1)"
  [ -n "$EYES" ] && { printf '%s\n' "$EYES"; exit 0; }
fi
printf '[ heimdall ]\n'
exit 0
