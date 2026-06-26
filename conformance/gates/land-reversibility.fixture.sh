#!/usr/bin/env bash
# PARITY-ROW: Gate "land-to-shared-main" — the team git flow's reversible-vs-
#   irreversible DESTINATION line, made mechanically checkable.
# ASSERT (static, no merge executed): bin/heimdall-land exists and wires the
#   exact principle — (a) the OWN branch push is reversible/autonomous
#   (force-with-lease, ungated), (b) shared main is gated on the MERGED result
#   (not the branch in isolation), (c) BOTH conflict classes are handled — redum
#   consolidation (Class 1) AND the merged-result gate (Class 2), (d) the gate
#   command is CONFIGURABLE, (e) force-push to shared main / non-fast-forward
#   stays human-gated. This proves the wiring is present; the behavioral proof is
#   test/land-flow.test.sh (both classes, throwaway repos).
ROW="gate:land-reversibility"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }

LAND="bin/heimdall-land"
assert_file "$LAND" "heimdall-land present"
[ -x "$LAND" ] && ok "heimdall-land executable" || bad "heimdall-land not executable"

SRC="$(cat "$LAND")"

# (a) reversible OWN-branch push is autonomous (force-with-lease, no gate).
assert_grep 'force-with-lease' "$SRC" "own-branch push uses --force-with-lease (reversible, autonomous)"
# (b) gate the MERGED result, never the branch in isolation.
assert_grep 'merge .*--no-ff --no-commit' "$SRC" "merges branch onto CURRENT main locally (merge-result gate)"
assert_grep 'worktree add' "$SRC" "uses a throwaway worktree to gate the merged state"
# (c) BOTH classes: redum consolidation (Class 1) + the merged-result gate (Class 2).
assert_grep 'land_consolidate' "$SRC" "Class 1 — redum consolidation wired (REDUNDANCY)"
assert_grep 'GATE the MERGED|gating MERGED result' "$SRC" "Class 2 — merged-result gate wired (INCOMPATIBILITY)"
# (d) the gate command is configurable.
assert_grep 'HEIMDALL_GATE_CMD' "$SRC" "gate command configurable via HEIMDALL_GATE_CMD"
assert_grep 'resolve_gate_cmd' "$SRC" "gate command resolution (settings.json / heimdall set default)"
# (e) irreversible-to-shared-main escalations stay human-gated.
assert_grep 'non-fast-forward|is-ancestor' "$SRC" "non-fast-forward land STOPS (force-push to shared main is human-only)"
assert_grep 'emit_and_exit 3' "$SRC" "STOP path (exit 3) exists for the human gate"
# Decision is the GATES' verdict, never agent self-assessment.
assert_grep 'never self-assess|never the agent|gates-on-merged' "$SRC" "decision is the gates' verdict, not self-assessment"

# The behavioral falsifier exists and is runnable.
assert_file "test/land-flow.test.sh" "falsifiable both-class harness present"

finish
