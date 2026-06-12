#!/usr/bin/env bash
# PARITY-ROW: Command `detect-skills` (kept) — scan installed skills to JSON.
# ASSERT: superx's detect-skills emitted a JSON array of installed skills/plugins.
#   heimdall keeps bin/detect-skills; it must exit 0 and emit a JSON array (valid
#   JSON parseable by jq, type == array). No model.
ROW="file:detect-skills"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

OUT="$("$BIN/detect-skills" 2>/dev/null)"; CODE=$?
assert_exit 0 "$CODE" "detect-skills exits 0"
if command -v jq >/dev/null 2>&1; then
  T="$(jq -r 'type' <<<"$OUT" 2>/dev/null || echo invalid)"
  [ "$T" = "array" ] && ok "detect-skills emits a JSON array (type=array)" || bad "output is not a JSON array (type=$T)"
else
  note "jq unavailable — shape-checking for leading '['"
  assert_grep '^\s*\[' "$OUT" "output begins with a JSON array bracket"
fi
finish
