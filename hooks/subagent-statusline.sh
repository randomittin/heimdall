#!/usr/bin/env bash
# subagent-statusline.sh — heimdall SUBAGENT statusline for Claude Code (spec §9).
# Renders ONE faint transcript row per RUNNING subagent from the {columns, tasks[]}
# JSON on stdin, emitting one {"id","content"} JSON line per running task. It is
# INDEPENDENT of the main watchman (hooks/statusline.sh) — no sigil, no gate, no wall.
#
# Never-error contract (mirrors hooks/statusline.sh): the python renderer's output is
# captured FIRST; we emit only what it produced. The renderer is itself null-safe —
# malformed/empty input prints nothing and exits 0 — so a quiet no-op is the floor.
# Every branch ends in `exit 0`. NEVER blocks, NEVER prints prose, NEVER errors.

HERE="$(cd "$(dirname "$0")" && pwd)"
RENDERER="$HERE/../sentinels/subagent-statusline.py"

# ── Color detection (mirrors hooks/statusline.sh): pass --color/--no-color so the
# renderer downgrades to clean plain text in CI/pipes with no truecolor. ──
if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" || "${TERM:-}" == *256color* ]]; then
  COLOR_FLAG="--color"
elif [ -t 1 ] || [ -n "${TERM:-}" ]; then
  COLOR_FLAG="--color"
else
  COLOR_FLAG="--no-color"
fi

# ── Slurp the stdin JSON blob ONCE (stdin is consumable only once). The renderer
# reads `columns` from the blob itself, so no COLUMNS export is needed here. ──
BLOB=""
[ -t 0 ] || BLOB="$(cat 2>/dev/null)"

if command -v python3 >/dev/null 2>&1 && [ -f "$RENDERER" ]; then
  OUT="$(printf '%s' "$BLOB" | python3 "$RENDERER" "$COLOR_FLAG" 2>/dev/null)"
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
fi
exit 0
