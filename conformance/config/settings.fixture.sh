#!/usr/bin/env bash
# PARITY-ROW: Config settings.json `agent` (renamed "superx" -> "heimdall") +
#   settings.json `env` CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (kept) +
#   settings.json `statusline.command` (kept) + Env
#   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (kept).
# ASSERT: superx settings.json bound agent="superx", set the agent-teams env, and
#   wired the statusline command. heimdall must bind agent="heimdall" (rename),
#   keep the agent-teams env = "1", and keep the statusline.command. Pure static
#   JSON-field checks (no model).
ROW="config:settings"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }
S="settings.json"

A="$(jq -r '.agent // empty' "$S")"
[ "$A" = "heimdall" ] && ok "settings.json agent renamed to heimdall" || bad "agent='$A' (expected heimdall)"
[ "$A" = "superx" ] && bad "agent still 'superx'" || ok "agent is not 'superx'"

T="$(jq -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS // empty' "$S")"
[ "$T" = "1" ] && ok "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS kept = 1" || bad "agent-teams env = '$T' (expected 1)"

assert_json_field "$S" '.statusline.command' "statusline.command kept"
assert_grep 'statusline\.sh' "$(jq -r '.statusline.command' "$S")" "statusline.command points at statusline.sh"

finish
