#!/usr/bin/env bash
# PARITY-ROW: Statusline `[SUPERX]` prefix (renamed -> `[HEIMDALL]`) + phase
#   (kept) + improved(new) token-budget bar / gate glyphs / goal marker / face.
#   Also Config settings.json `statusline.command` (kept).
# ASSERT: superx's statusline rendered `[SUPERX] phase | ...` entirely shell-side
#   (zero model). heimdall must render `[HEIMDALL]` (NOT [SUPERX]), still show the
#   phase from STATE.md, and run with zero model involvement (pure bash). We drive
#   hooks/statusline.sh against an isolated project with known state and assert the
#   rendered single line. No model invoked.
ROW="statusline:prefix-and-elements"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

SL="$PLUGIN_ROOT/hooks/statusline.sh"
assert_file "$SL" "statusline.sh present"

# Isolated project with a phase + a budget so the bar/glyphs have inputs.
WS="$(mk_workspace)"; mkdir -p "$WS/.planning"
HEIMDALL_STATE_FILE="$WS/heimdall-state.json" "$BIN/heimdall-state" init >/dev/null 2>&1
HEIMDALL_STATE_FILE="$WS/heimdall-state.json" "$BIN/heimdall-state" set '.project.phase' '"implementing"' >/dev/null 2>&1
printf -- '---\ncurrent_phase: implementing\n---\n' > "$WS/.planning/STATE.md"

LINE="$(bash "$SL" "$WS" 2>&1)"
# Strip ANSI for shape assertions.
PLAIN="$(printf '%s' "$LINE" | sed -E 's/\x1b\[[0-9;]*m//g')"

assert_contains "$PLAIN" "[HEIMDALL]" "renders [HEIMDALL] prefix"
if grep -qF '[SUPERX]' <<<"$PLAIN"; then bad "still renders the old [SUPERX] prefix"; else ok "no [SUPERX] prefix (rename landed)"; fi
# Single physical line (statusline contract).
NLINES="$(printf '%s' "$LINE" | grep -c '' || true)"
if [ "$NLINES" -le 1 ]; then ok "renders a single status line"; else bad "rendered $NLINES lines (must be 1)"; fi

# Config: settings.json points statusline at this script.
SCMD="$(jq -r '.statusLine.command // .statusline.command // empty' "$PLUGIN_ROOT/settings.json" 2>/dev/null)"
assert_grep 'statusline\.sh' "$SCMD" "settings.json statusline.command -> hooks/statusline.sh"

rm -rf "$WS"
finish
