#!/usr/bin/env bash
# PARITY-ROW: Hooks (renamed+improved):
#   - PostToolUse Write/Edit -> mark-dirty + auto-checkpoint at >=5 files
#     (superx: "superx: auto-checkpoint"  ->  heimdall: "heimdall: auto-checkpoint")
#   - SessionStart -> init state + announce (superx-state -> heimdall-state init,
#     superx fallback; + stack-pack detect; CHECKPOINT.md hint)
#   - SessionEnd -> commit if dirty (superx: "superx: session-end checkpoint" ->
#     "heimdall: session-end checkpoint"; + parallelism grade/verify/reel/summary)
# ASSERT: superx's lifecycle hooks used superx-named state calls + commit prefixes.
#   heimdall must rename them to heimdall-* while KEEPING the superx forms only as
#   back-compat fallbacks. STATIC check of hooks/hooks.json (executing them would
#   git-commit / mutate the repo) — we do NOT run or edit the hooks. Each event's
#   command string is inspected for the renamed call + the documented improvements.
ROW="hook:lifecycle-rename"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }
HJ="hooks/hooks.json"

POST="$(jq -r '.hooks.PostToolUse[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null)"
START="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null)"
END="$(jq -r '.hooks.SessionEnd[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null)"

# PostToolUse: heimdall-named mark-dirty + auto-checkpoint commit prefix.
assert_grep 'heimdall-state mark-dirty' "$POST" "PostToolUse calls heimdall-state mark-dirty"
assert_grep 'heimdall: auto-checkpoint' "$POST" "auto-checkpoint commit prefix is 'heimdall:'"
assert_grep '\.heimdall-no-autocommit' "$POST" "improved: respects .heimdall-no-autocommit opt-out"

# SessionStart: heimdall-state init + stack-pack detect + CHECKPOINT hint.
assert_grep 'heimdall-state init' "$START" "SessionStart inits heimdall-state"
assert_grep 'stack-pack' "$START" "improved: SessionStart runs stack-pack detect"
assert_grep 'CHECKPOINT\.md' "$START" "improved: SessionStart surfaces CHECKPOINT.md hint"

# SessionEnd: heimdall-named commit prefix + new end-of-run renderers.
assert_grep 'heimdall: session-end checkpoint' "$END" "SessionEnd commit prefix is 'heimdall:'"
assert_grep 'summary-card' "$END" "improved: SessionEnd emits summary-card"
assert_grep 'parallelism-tracker"? grade' "$END" "improved: SessionEnd grades parallelism"

# Back-compat retained but secondary: superx forms only as fallbacks, never the primary call.
if grep -qE 'superx-state (init|mark-dirty)\b' <<<"$POST$START"; then bad "a primary call still uses superx-state"; else ok "no primary superx-state call in lifecycle hooks (superx only as fallback)"; fi

finish
