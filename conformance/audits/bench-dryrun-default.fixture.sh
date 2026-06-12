#!/usr/bin/env bash
# PARITY-ROW: standing audit (plan P2.3) — "bench defaults to dry-run (zero token spend)"
#   Maps to Token/efficiency-surface NET-NEW row "watchman/bench are zero-context"
#   and the Slash row `/hmd:...bench` (net-new command). The observable contract:
#   running bench with NO flag must NOT spend API tokens.
# ASSERT: `heimdall-bench` (and the underlying `benchmark`) with no flag prints a
#   dry-run banner stating zero API spend, lists the capture plan, exits 0, and
#   makes NO live model call. We assert the banner + "no API / zero" wording +
#   exit 0, and that no results artifact is written (a real --live run would
#   append evals/benchmark/results.jsonl). This is a pure mechanical surface check
#   (no model invoked), consistent with P2's no-model rule.
ROW="audit:bench-dryrun-default"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd plugin root"; finish; }

# Snapshot the results artifact mtime/size so we can prove dry-run does not write it.
RES="evals/benchmark/results.jsonl"
BEFORE=""; [ -f "$RES" ] && BEFORE="$(wc -c <"$RES" | tr -d ' ')"

# run: no flags. Capture output + exit code (do NOT let pipefail mask it).
OUT="$(./bin/heimdall-bench 2>&1)"; CODE=$?

assert_exit 0 "$CODE" "heimdall-bench with no flag exits 0"
assert_grep 'no mode given|--dry|dry' "$OUT" "dry-run banner present"
assert_grep 'zero api|no api|spends? zero|zero[[:space:]-]*spend' "$OUT" "states zero/no API spend"
assert_grep 'capture plan|would measure|nothing captured' "$OUT" "prints capture plan (what --live WOULD do)"

# The underlying harness must also default to dry (defense in depth).
OUT2="$(./bin/benchmark 2>&1)"; CODE2=$?
assert_exit 0 "$CODE2" "bin/benchmark with no flag exits 0"
assert_grep 'dry|no api|nothing captured' "$OUT2" "bin/benchmark defaults to dry"

# Artifact must be unchanged (dry-run captures nothing).
AFTER=""; [ -f "$RES" ] && AFTER="$(wc -c <"$RES" | tr -d ' ')"
if [ "$BEFORE" = "$AFTER" ]; then ok "dry-run wrote nothing to $RES (size unchanged: '${AFTER:-absent}')"
else bad "dry-run mutated $RES ($BEFORE -> $AFTER)"; fi

finish
