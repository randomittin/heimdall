#!/usr/bin/env bash
# PARITY-ROW: Command `authenticity-check <npm/github/plugin>` (kept) — publisher
#   trust score 0-100 (bin/authenticity-check, unchanged name).
# ASSERT: superx's authenticity-check produced a JSON trust score (0-100) for an
#   npm/github/plugin identifier. heimdall keeps the binary + the three type verbs.
#   The usage surface is offline-checkable (assert here). The actual scoring makes
#   live network calls to npm/GitHub registries — running it in conformance would
#   depend on an external service, so the live-score assertion is a documented SKIP
#   per P2's "no external service" rule (a future networked CI lane can enable it).
ROW="file:authenticity-check"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# Offline: usage names the three trust types and the 0-100 score contract.
USAGE="$("$BIN/authenticity-check" 2>&1 || true)"
assert_grep 'npm'    "$USAGE" "usage documents the npm trust type"
assert_grep 'github' "$USAGE" "usage documents the github trust type"
assert_grep 'plugin' "$USAGE" "usage documents the plugin trust type"
assert_grep '0-100|trust score' "$USAGE" "usage documents the 0-100 trust-score output"

# Live scoring depends on npm/GitHub registries (external network) — out of scope.
note "SKIP live trust-score assertion: authenticity-check <type> <id> queries npm/GitHub over the network; P2 forbids depending on external services. Wire into a networked CI lane later."
skip_live() { note "SKIPPED: authenticity-check npm <pkg> (network) — score 0-100 unverifiable offline"; }
skip_live

finish
