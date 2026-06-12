#!/usr/bin/env bash
# PARITY-ROW: Subcmd (none) -> improved(new) `goal-set goal-clear goal-get`
#   + Config state `.goal.condition` (improved/new, rendered in statusline)
# ASSERT: baseline = absent (superx had no goal verbs). heimdall ADDS goal-set/
#   goal-get/goal-clear with an observable round-trip on `.goal` in state, in an
#   isolated state file. Presence + correct CRUD is the bar.
ROW="state:goal-subcommands"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; SF="$WS/heimdall-state.json"
export HEIMDALL_STATE_FILE="$SF"
"$BIN/heimdall-state" init >/dev/null 2>&1

"$BIN/heimdall-state" goal-set "all tests green" "fixture" >/dev/null 2>&1; SC=$?
assert_exit 0 "$SC" "goal-set exits 0"
GOT="$("$BIN/heimdall-state" goal-get 2>&1)"
assert_contains "$GOT" "all tests green" "goal-get returns the set condition"

"$BIN/heimdall-state" goal-clear >/dev/null 2>&1; CC=$?
assert_exit 0 "$CC" "goal-clear exits 0"
CLEARED="$("$BIN/heimdall-state" goal-get 2>&1)"
if grep -qiF "all tests green" <<<"$CLEARED"; then bad "goal-clear did not clear the condition"; else ok "goal-clear removes the condition"; fi

rm -rf "$WS"
finish
