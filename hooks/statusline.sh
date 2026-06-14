#!/usr/bin/env bash
# statusline.sh — heimdall HUD for Claude Code's status bar
# Outputs a SINGLE line: the dense symbolic instrument
#   <watchman-eyes> · <phase-glyph> · <gate-cluster> · <token-gauge> [· <agents>]
# rendered entirely by bin/heimdall-face --statusline. NO roadmap prose — the HUD is
# a glanceable instrument, not a sentence. All rendering is shell+python side; zero
# model involvement.
#
# Project + token-gauge resolution (so the instrument reacts to the LIVE session):
#   1. an explicit "$1" arg (the conformance harness drives an isolated project),
#   2. else the cwd Claude Code pipes in its statusLine stdin JSON (.cwd /
#      .workspace.current_dir), plus the context-window burn (.context_window
#      .used_percentage / .exceeds_200k_tokens) for the token gauge,
#   3. else ".". stdin is consumed ONLY when no arg was given, and tolerantly: any
#      parse/field miss falls through to safe defaults — the status bar must never
#      error, never block, never print prose.

FACE_BIN="$(dirname "$0")/../bin/heimdall-face"

# ── Color detection ──
# The statusLine surface is colored even though Claude Code captures (pipes) stdout,
# so default to color on; only drop to plain when there is clearly no terminal.
if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" || "${TERM:-}" == *256color* ]]; then
  COLOR_FLAG="--color"
elif [ -t 1 ] || [ -n "${TERM:-}" ]; then
  COLOR_FLAG="--color"
else
  COLOR_FLAG="--no-color"
fi

# ── Resolve project + token burn from the statusLine stdin blob ──
# Reads stdin only when no "$1" was given and stdin is not a tty (Claude Code pipes
# the blob). Echoes three space-separated tokens: PROJECT BURN EXCEEDS, where BURN is
# a percentage or "-" and EXCEEDS is 1/0. Tolerant of empty / non-JSON / missing
# fields — any miss yields "." "-" "0". Prefers python3, falls back to jq, else ".".
resolve_signals_from_stdin() {
  [ -t 0 ] && { echo ". - 0"; return; }
  local blob
  blob="$(cat 2>/dev/null)"
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
  read -r PROJECT BURN EXCEEDS <<<"$(resolve_signals_from_stdin)"
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="."

# ── Render the dense instrument (single line, never errors) ──
# heimdall-face resolves eyes/phase/gates/agents from PROJECT's own state files and
# draws the wcwidth-aligned instrument; we hand it the token burn the shell parsed
# from CC's stdin (python cannot re-read stdin we already consumed). Graceful if the
# bin is absent / non-executable / errors — the HUD must never break.
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

# ── Degraded floor: the bin is unavailable → emit the idle watchman eyes only,
# never blank, never an error. Plain-text fallback if even that is impossible. ──
if [ -x "$FACE_BIN" ] && command -v python3 >/dev/null 2>&1; then
  FALLBACK="$(python3 "$FACE_BIN" --eyes "$COLOR_FLAG" "$PROJECT" </dev/null 2>/dev/null | head -n1)"
  [ -n "$FALLBACK" ] && { printf '%s\n' "$FALLBACK"; exit 0; }
fi
printf '[ heimdall ]\n'
exit 0
