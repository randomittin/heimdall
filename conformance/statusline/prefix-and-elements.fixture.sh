#!/usr/bin/env bash
# PARITY-ROW: statusline:prefix-and-elements — brand identity + HUD element presence.
#
# HISTORY: originally asserted the single-line `[HEIMDALL]` prefix format (renamed
#   from `[SUPERX]`). The 4-row watchman HUD replaced the single-line renderer; the
#   `[HEIMDALL]` bracket prefix no longer exists. This fixture is REWRITTEN to assert
#   the elements that MUST be present in the current watchman HUD — the HEIMDALL brand
#   wordmark, the watchman eye bracket, >=4 rows, CC JSON integration (model + context
#   bar), and the settings.json wiring. NOT a rubber-stamp: each assert has a real
#   falsifier (break HEIMDALL in the renderer -> fixture fails; remove the eye bracket
#   -> fixture fails; pass wrong model -> fixture fails). viral-statusline tests layout/
#   behavior; this tests brand identity and CC JSON integration.
# ASSERT:
#   (1) HEIMDALL wordmark present (not [HEIMDALL] bracket -- old prefix format is gone)
#   (2) watchman eye bracket present (visual watchman identity, l1 row0)
#   (3) HUD renders >=4 rows (NOT a single line -- the watchman contract)
#   (4) CC JSON model display_name flows into l1 (model column)
#   (5) CC JSON used_percentage flows into l2 context bar (N% marker)
#   (6) settings.json statusLine.command wires to statusline.sh (integration path)
# No model invoked. No file modifications.
ROW="statusline:prefix-and-elements"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

SL="$PLUGIN_ROOT/sentinels/hmd-statusline.py"
assert_file "$SL" "hmd-statusline.py present"

# Drive with CC JSON: the watchman reads stdin (not a positional arg).
# model + context_window carry known values we can grep for in the rendered output.
WS="$(mk_workspace)"; mkdir -p "$WS/.planning"
JSON='{"workspace":{"current_dir":"'"$WS"'"},"model":{"display_name":"TestModel"},"context_window":{"used_percentage":37}}'

OUT="$(printf '%s' "$JSON" | COLUMNS=120 python3 "$SL" 2>&1)"
PLAIN="$(printf '%s' "$OUT" | sed -E 's/\x1b\[[0-9;]*m//g')"

# -- 1) HEIMDALL brand wordmark (teal bold, l1 row0; old [HEIMDALL] bracket is gone) --
assert_contains "$PLAIN" "HEIMDALL" "renders HEIMDALL brand wordmark"
if grep -qF '[SUPERX]' <<<"$PLAIN"; then bad "still renders the old [SUPERX] prefix"; else ok "no [SUPERX] prefix (rename landed)"; fi

# -- 2) Watchman eye bracket (visual identity of this HUD, l1 row0) --
assert_contains "$OUT" "▐ ● ● ▌" "renders watchman eye bracket"

# -- 3) 4-row HUD -- NOT a single line (the watchman contract is always >=4 rows) --
NLINES="$(printf '%s\n' "$OUT" | grep -c '')"
if [ "$NLINES" -ge 4 ]; then ok "renders >=4 rows (got $NLINES) -- watchman HUD is multi-row"
else bad "rendered $NLINES rows (want >=4 for the watchman HUD)"; fi

# -- 4) CC JSON model display_name flows into l1 --
# The watchman parses data["model"]["display_name"] and places it in the info row.
assert_contains "$PLAIN" "TestModel" "CC JSON model display_name flows into the info row"

# -- 5) CC JSON used_percentage flows into the l2 context bar --
# The watchman renders the percentage in the bar: `N%`. Round-trip: 37 -> "37%".
assert_contains "$PLAIN" "37%" "CC JSON context used_percentage flows into the context bar"

# -- 6) settings.json statusLine.command wires to statusline.sh (integration path) --
# The entry point is hooks/statusline.sh (the wrapper); settings.json must name it.
SCMD="$(jq -r '.statusLine.command // .statusline.command // empty' "$PLUGIN_ROOT/settings.json" 2>/dev/null)"
assert_grep 'statusline\.sh' "$SCMD" "settings.json statusLine.command -> hooks/statusline.sh"

rm -rf "$WS"
finish
