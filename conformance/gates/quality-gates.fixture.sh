#!/usr/bin/env bash
# PARITY-ROW: Gate "Tests pass" + "Lint clean" + "No dirty state" (kept) via
#   `.quality_gates.{tests_passing,lint_clean,dirty}` and the
#   `heimdall-state check-quality-gates` contract (exit 0 pass / exit 2 block).
# ASSERT: superx-state check-quality-gates exited 0 when gates passed and 2 when
#   not (the push-blocking contract). heimdall-state must preserve EXACTLY this:
#   a freshly-initialized (failing) state -> exit 2 with "blocked" wording;
#   after mark-clean -> exit 0 with "pass" wording. Real state file, no model.
ROW="gate:quality-gates"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; SF="$WS/heimdall-state.json"
export HEIMDALL_STATE_FILE="$SF"
"$BIN/heimdall-state" init >/dev/null 2>&1

# Fresh state: tests not passing / lint not clean -> blocked (exit 2).
OUT="$("$BIN/heimdall-state" check-quality-gates 2>&1)"; CODE=$?
assert_exit 2 "$CODE" "failing gates -> exit 2 (push blocked)"
assert_grep 'blocked|not met|fail' "$OUT" "blocked message printed when gates fail"

# After mark-clean: all gates pass -> exit 0.
"$BIN/heimdall-state" mark-clean >/dev/null 2>&1
OUT="$("$BIN/heimdall-state" check-quality-gates 2>&1)"; CODE=$?
assert_exit 0 "$CODE" "passing gates -> exit 0"
assert_grep 'pass' "$OUT" "pass message printed when gates pass"

# mark-dirty flips tests back to failing -> blocked again.
"$BIN/heimdall-state" mark-dirty >/dev/null 2>&1
"$BIN/heimdall-state" check-quality-gates >/dev/null 2>&1; CODE=$?
assert_exit 2 "$CODE" "mark-dirty re-blocks the gate (exit 2)"

rm -rf "$WS"
finish
