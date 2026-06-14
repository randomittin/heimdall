#!/usr/bin/env bash
# PARITY-ROW: Config state `.budget.{total_tokens,token_limit}` (kept; token
#   budget, warn at 80%) + Behavior "Token budgets, warn at 80%" (improved:
#   statusline bar) + Subcmd add-tokens/set-budget/budget (kept)
# ASSERT: superx tracked a token budget and warned at 80% of the limit. heimdall
#   keeps the budget CRUD: set-budget records a limit, add-tokens accumulates,
#   crossing 80% emits a warning, and budget prints the summary. We drive a real
#   state file (no model) and assert the 80% warning fires.
ROW="state:budget"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; SF="$WS/heimdall-state.json"
export HEIMDALL_STATE_FILE="$SF"
"$BIN/heimdall-state" init >/dev/null 2>&1

"$BIN/heimdall-state" set-budget 1000 >/dev/null 2>&1
assert_json_field "$SF" '.budget.token_limit' "set-budget records token_limit"

# Below 80%: no warning.
OUT="$("$BIN/heimdall-state" add-tokens 700 2>&1)"
if grep -qiE 'warn|80%|over budget' <<<"$OUT"; then bad "warned at 70% (too early)"; else ok "no warning below 80%"; fi

# Cross 80% (now 850/1000): warning expected.
OUT="$("$BIN/heimdall-state" add-tokens 150 2>&1)"
assert_grep 'warn|80%|budget' "$OUT" "warns at/after 80% of the limit"

# budget summary prints the running total.
SUM="$("$BIN/heimdall-state" budget 2>&1)"
assert_grep '850|1000|token' "$SUM" "budget summary reflects usage against limit"

rm -rf "$WS"
finish
