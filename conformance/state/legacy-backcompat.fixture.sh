#!/usr/bin/env bash
# PARITY-ROW: File `superx-state.json` (renamed to heimdall-state.json; reads/
#   migrates superx-state.json; hooks check both) + Env SUPERX_STATE_FILE
#   (renamed to HEIMDALL_STATE_FILE, with SUPERX_STATE_FILE back-compat fallback)
#   + Command bin/superx-state -> bin/heimdall-state (+ migrate)
# ASSERT: superx wrote/read superx-state.json keyed off SUPERX_STATE_FILE.
#   heimdall must (1) prefer heimdall-state.json, (2) ADOPT a pre-existing legacy
#   superx-state.json when no heimdall file exists (so old projects keep working),
#   and (3) honor SUPERX_STATE_FILE as a back-compat env override. This meets the
#   rename baseline AND adds non-lossy migration — strictly >= superx.
ROW="state:legacy-backcompat"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# (1)+(2) adopt a legacy superx-state.json present in cwd, no env override.
WS="$(mk_workspace)"; cd "$WS" || { bad "no ws"; finish; }
printf '{"version":1,"project":{"phase":"building"}}' > superx-state.json
GOT="$("$BIN/heimdall-state" get '.project.phase' 2>&1)"
assert_contains "$GOT" "building" "adopts legacy superx-state.json when no heimdall-state.json exists"

# heimdall-state.json must WIN when both exist (heimdall is primary).
printf '{"version":1,"project":{"phase":"shipping"}}' > heimdall-state.json
GOT="$("$BIN/heimdall-state" get '.project.phase' 2>&1)"
assert_contains "$GOT" "shipping" "prefers heimdall-state.json over legacy when both present"

# (3) SUPERX_STATE_FILE back-compat env override is still honored.
ALT="$WS/alt-legacy.json"
printf '{"version":1,"project":{"phase":"legacy-env"}}' > "$ALT"
GOT="$(SUPERX_STATE_FILE="$ALT" "$BIN/heimdall-state" get '.project.phase' 2>&1)"
assert_contains "$GOT" "legacy-env" "honors SUPERX_STATE_FILE back-compat env override"

# HEIMDALL_STATE_FILE wins over SUPERX_STATE_FILE (new var is primary).
NEWF="$WS/new.json"
printf '{"version":1,"project":{"phase":"new-env"}}' > "$NEWF"
GOT="$(HEIMDALL_STATE_FILE="$NEWF" SUPERX_STATE_FILE="$ALT" "$BIN/heimdall-state" get '.project.phase' 2>&1)"
assert_contains "$GOT" "new-env" "HEIMDALL_STATE_FILE takes precedence over SUPERX_STATE_FILE"

cd / && rm -rf "$WS"
finish
