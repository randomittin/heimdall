#!/usr/bin/env bash
# PARITY-ROW: Gate "Pre-push: check-quality-gates" (improved: stacked with
#   secret/selfscan/oracle/corpus) + Hook "PreToolUse Bash -> quality-gates on
#   git push" (renamed+improved: heimdall-state check-quality-gates + secret/
#   selfscan/oracle/corpus + parallelism-tracker).
# ASSERT: superx's pre-push hook ran `superx-state check-quality-gates` (exit 2
#   blocks). heimdall must (a) still call `heimdall-state check-quality-gates`
#   on `git push`, and (b) STACK additional gates in the SAME hook: secret-scan,
#   heimdall-selfscan, falsify (oracle), corpus. This is a STATIC composition
#   check of hooks/hooks.json (we do NOT execute the hook or modify it) — it
#   proves the improved gate chain is wired, meeting+exceeding the superx baseline.
ROW="gate:prepush-composition"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }

HJ="hooks/hooks.json"
assert_file "$HJ" "hooks.json present"

# Pull the PreToolUse Bash command string(s) that gate on git push.
PUSH_CMD="$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null | grep -F 'git\s*push' || \
            jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null | grep -F 'check-quality-gates')"

# (a) superx baseline kept: quality-gate check on push.
assert_grep 'heimdall-state check-quality-gates' "$PUSH_CMD" "pre-push still runs heimdall-state check-quality-gates (renamed baseline)"
# It must NOT call the old superx-state binary by that name in the live command.
if grep -qE 'superx-state check-quality-gates' <<<"$PUSH_CMD"; then bad "pre-push still calls superx-state (not renamed)"; else ok "pre-push does not call superx-state (rename landed)"; fi

# (b) improved stacked gates wired into the same push path.
assert_grep 'secret-scan'        "$PUSH_CMD" "improved: secret-scan stacked into pre-push"
assert_grep 'heimdall-selfscan'  "$PUSH_CMD" "improved: heimdall-selfscan stacked into pre-push"
assert_grep 'falsify'            "$PUSH_CMD" "improved: oracle falsify gate stacked into pre-push"
assert_grep 'corpus'             "$PUSH_CMD" "improved: corpus regression gate stacked into pre-push"
# Each gate uses exit 2 to block (push-blocking contract preserved).
assert_grep 'exit 2' "$PUSH_CMD" "blocking contract preserved (exit 2 on gate failure)"

finish
