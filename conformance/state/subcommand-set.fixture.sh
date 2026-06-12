#!/usr/bin/env bash
# PARITY-ROW: Subcmd `init get set add-conflict check-quality-gates mark-dirty
#   mark-clean add-agent add-tokens set-budget budget migrate status` (kept, all 13)
#   on bin/heimdall-state (renamed from bin/superx-state)
# ASSERT: superx-state exposed exactly these 13 subcommands. heimdall-state must
#   keep ALL 13 by the SAME names. We assert each is listed in usage and that a
#   representative round-trip (init -> set -> get) actually mutates and reads state
#   in an isolated state file (real CRUD, no model).
ROW="state:subcommand-set"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

USAGE="$("$BIN/heimdall-state" 2>&1 || true)"
for sub in init get set add-conflict check-quality-gates mark-dirty mark-clean \
           add-agent add-tokens set-budget budget migrate status; do
  assert_grep "(^|[[:space:]])${sub}([[:space:]]|$)" "$USAGE" "subcommand '$sub' present in usage"
done

# Real round-trip in an isolated state file.
WS="$(mk_workspace)"; SF="$WS/heimdall-state.json"
HEIMDALL_STATE_FILE="$SF" "$BIN/heimdall-state" init >/dev/null 2>&1
assert_file "$SF" "init creates the state file"
HEIMDALL_STATE_FILE="$SF" "$BIN/heimdall-state" set '.project.phase' '"implementing"' >/dev/null 2>&1
GOT="$(HEIMDALL_STATE_FILE="$SF" "$BIN/heimdall-state" get '.project.phase' 2>&1)"
assert_contains "$GOT" "implementing" "set then get round-trips the value"

rm -rf "$WS"
finish
