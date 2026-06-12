#!/usr/bin/env bash
# PARITY-ROW: Gate "Conflict reflection" (kept) — conflict-log reviewed before
#   push; bin/conflict-log CRUD on state `.conflict_log`. Also covers
#   Command `conflict-log <add/list/unresolved/mark-reflected/reflect-all>`
#   (improved: HEIMDALL_STATE_FILE w/ superx fallback).
# ASSERT: superx tracked skill conflicts in state and required reflection before
#   push. heimdall keeps conflict-log with the same verbs: add a conflict ->
#   it shows as unresolved -> reflect-all -> unresolved list empties. Real state
#   file, no model.
ROW="gate:conflict-reflection"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; SF="$WS/heimdall-state.json"
export HEIMDALL_STATE_FILE="$SF"
"$BIN/heimdall-state" init >/dev/null 2>&1

# add a conflict (4 args: skill-a skill-b conflict resolution).
"$BIN/conflict-log" add "caveman" "verbose-docs" "tone clash" "prefer caveman in autocommit" >/dev/null 2>&1; AC=$?
assert_exit 0 "$AC" "conflict-log add exits 0"

UNRES="$("$BIN/conflict-log" unresolved 2>&1)"
assert_grep 'caveman|tone clash' "$UNRES" "added conflict appears as unresolved"

"$BIN/conflict-log" reflect-all >/dev/null 2>&1; RA=$?
assert_exit 0 "$RA" "reflect-all exits 0"

UNRES2="$("$BIN/conflict-log" unresolved 2>&1)"
if grep -qiE 'caveman|tone clash' <<<"$UNRES2"; then bad "conflict still unresolved after reflect-all"; else ok "reflect-all clears the unresolved list (gate satisfiable)"; fi

rm -rf "$WS"
finish
