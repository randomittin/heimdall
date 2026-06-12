#!/usr/bin/env bash
# PARITY-ROW: Command `superx --help`/`-h` (kept) -> `heimdall --help`/`-h`/`help`
# ASSERT: superx printed usage text on --help/-h and exited 0. Heimdall must do
#   the same on all three forms (--help, -h, and the bare `help` subcommand),
#   exit 0, and print a usage block naming the real binary `heimdall` and its
#   flag surface.
ROW="cmd:help"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

for form in "--help" "-h" "help"; do
  OUT="$("$BIN/heimdall" $form 2>&1)"; CODE=$?
  assert_exit 0 "$CODE" "heimdall $form exits 0"
  assert_grep 'usage' "$OUT" "heimdall $form prints Usage"
  assert_contains "$OUT" "heimdall" "heimdall $form names the heimdall binary"
done
# Must NOT print the old superx name as the program name in usage.
OUT="$("$BIN/heimdall" --help 2>&1)"
if printf '%s' "$OUT" | grep -qE '^[[:space:]]*superx '; then bad "usage still shows superx as program name"; else ok "usage shows heimdall (not superx) as program name"; fi
finish
