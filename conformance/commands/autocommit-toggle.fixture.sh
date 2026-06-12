#!/usr/bin/env bash
# PARITY-ROW: Flag (none) -> improved(new) `--no-autocommit` / `--autocommit`
#   (autocommit toggle, bin/heimdall:861)
# ASSERT: baseline = absent. Heimdall ADDS a per-project autocommit toggle whose
#   observable effect is a marker file `.heimdall-no-autocommit` in the project:
#   `--no-autocommit` creates it (and prints how to re-enable), `--autocommit`
#   removes it. Both exit 0. We run inside an isolated scratch dir so nothing real
#   is touched; these branches return before any claude launch.
ROW="cmd:autocommit-toggle"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; cd "$WS" || { bad "no workspace"; finish; }

OUT="$("$BIN/heimdall" --no-autocommit 2>&1)"; CODE=$?
assert_exit 0 "$CODE" "--no-autocommit exits 0"
assert_file "$WS/.heimdall-no-autocommit" "--no-autocommit creates the opt-out marker"
assert_grep 'autocommit' "$OUT" "--no-autocommit explains how to re-enable"

OUT="$("$BIN/heimdall" --autocommit 2>&1)"; CODE=$?
assert_exit 0 "$CODE" "--autocommit exits 0"
if [ ! -f "$WS/.heimdall-no-autocommit" ]; then ok "--autocommit removes the opt-out marker"; else bad "--autocommit left the marker in place"; fi

cd / && rm -rf "$WS"
finish
