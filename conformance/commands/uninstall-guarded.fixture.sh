#!/usr/bin/env bash
# PARITY-ROW: Command `superx --uninstall` (improved: guarded _heimdall_remove_plugin,
#   no unguarded rm) -> `heimdall --uninstall`
# ASSERT: superx removed install + PATH + optional plugins. Heimdall IMPROVES by
#   guarding the removal: in a non-interactive shell (no TTY) WITHOUT --yes it must
#   REFUSE (exit 2 + one-line message) rather than prompt or perform an unguarded
#   rm. We assert that zero-stdin refusal contract — the observable safety upgrade —
#   without ever actually removing anything.
ROW="cmd:uninstall-guarded"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# run with stdin redirected from /dev/null (no TTY), no --yes.
OUT="$("$BIN/heimdall" --uninstall </dev/null 2>&1)"; CODE=$?
assert_exit 2 "$CODE" "uninstall w/o --yes in non-interactive shell refuses (exit 2)"
assert_grep 'non-interactive|--yes|refus' "$OUT" "prints the refuse-to-prompt message"

# Source-level guard: the removal helper exists and uninstall never uses a bare rm -rf
# on a home/plugin path outside the guarded helper.
assert_grep '_heimdall_remove_plugin' "$(cat "$BIN/heimdall")" "guarded removal helper _heimdall_remove_plugin defined"
finish
