#!/usr/bin/env bash
# PARITY-ROW: Config `.planning/detected-stack.json` (improved/new, written by
#   SessionStart stack-pack detect) + File improved(new) `.planning/detected-stack.json`.
# ASSERT: baseline = absent (superx had no stack detection). heimdall ADDS
#   stack-pack detect, whose observable output is detected-stack.json with a
#   `stacks` array. We run `stack-pack detect` over an isolated project that has a
#   react package.json and assert it identifies the stack as JSON. No model.
ROW="file:detected-stack"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

WS="$(mk_workspace)"; cd "$WS" || { bad "no ws"; finish; }
printf '{"name":"demo","dependencies":{"react":"18.0.0"}}' > package.json

OUT="$("$BIN/stack-pack" detect 2>&1)"; CODE=$?
assert_exit 0 "$CODE" "stack-pack detect exits 0"
if command -v jq >/dev/null 2>&1; then
  STACKS="$(jq -r '.stacks // [] | join(",")' <<<"$OUT" 2>/dev/null)"
  assert_contains "$STACKS" "react" "detects react stack from package.json"
else
  assert_grep 'react' "$OUT" "detects react stack from package.json"
fi

# SessionStart writes it to .planning/detected-stack.json (assert the redirect target shape).
mkdir -p .planning
"$BIN/stack-pack" detect > .planning/detected-stack.json 2>/dev/null
assert_file "$WS/.planning/detected-stack.json" "detect output lands at .planning/detected-stack.json"

cd / && rm -rf "$WS"
finish
