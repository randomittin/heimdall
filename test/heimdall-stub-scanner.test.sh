#!/usr/bin/env bash
# heimdall-stub-scanner.test.sh — the CONTEXT-AWARE stub gate, proven both ways.
#
# The PreToolUse Write|Edit hook in hooks/hooks.json is Heimdall's no-stub gate:
# it must exit 2 (block) when an agent tries to write UNFINISHED CODE, and exit 0
# (allow) otherwise. The load-bearing distinction is CODE SHAPE, not the mere
# presence of a scary word. An earlier raw-word grep (XXX | \bstub\b | \bshim\b |
# placeholder | FIXME) false-blocked legitimate content — Roman numerals that
# contain "XXX" (MMMDCCCLXXXVIII), docs/tests that TALK ABOUT the no-stub policy,
# and intentionally-broken fixtures (which are gated by falsify, not by this hook).
#
# This harness drives the REAL hook command — extracted verbatim from hooks.json
# via jq — with crafted JSON stdin, and asserts BOTH directions:
#
#   STILL BLOCKED (must stay red) — actual unfinished CODE:
#     empty JS body, python pass-only body, throw new Error("not implemented"),
#     raise NotImplementedError, a code-comment "// TODO: implement", todo!().
#
#   NOW ALLOWED (the fix) — content that only TRIPS a raw word match:
#     "MMMDCCCLXXXVIII" (XXX in a Roman numeral), a *.md prose file that says
#     "stub"/"placeholder", a fixtures/ file with a deliberate empty body, a
#     *.json data file whose value is the string "placeholder", a comment that
#     merely contains the word "stub".
#
# It ALSO asserts the BLOCK RECEIPT (H-receipt): when the gate fires it does not
# just exit 2 — it emits a screenshot-ready JSON receipt on the `error` key that
# NAMES the matched stub-shape and the FILE PATH. Those assertions prove the
# message carries both the shape label and the FPATH, for multiple shapes.
#
# FALSIFIABILITY: the test drives whatever command is CURRENTLY in hooks.json.
# Revert the gate to the raw-word grep and the NOW-ALLOWED cases go RED — so this
# suite fails the instant the over-eager scanner returns. (That is exactly the
# RED baseline observed before the fix.) Strip the shape/path out of the receipt
# and the RECEIPT cases go RED.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
HOOKS="$PLUGIN/hooks/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
[ -f "$HOOKS" ] || { echo "FATAL: hooks.json not found at $HOOKS"; exit 1; }

# Extract the actual PreToolUse Write|Edit hook command — we test the SHIPPED gate.
CMD="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[0].command' "$HOOKS")"
[ -n "$CMD" ] || { echo "FATAL: could not extract Write|Edit hook command from hooks.json"; exit 1; }

pass=0
fail=0

# run_case <block|allow> <name> <file_path> <content>
# Feeds the hook the same JSON shape Claude Code would: {tool_name, tool_input{file_path, content}}.
run_case() {
  expect="$1"; name="$2"; fpath="$3"; content="$4"
  json="$(jq -n --arg fp "$fpath" --arg c "$content" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:$c}}')"
  printf '%s' "$json" | bash -c "$CMD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then got="block"; else got="allow"; fi
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf 'PASS [%-5s] %s\n' "$expect" "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL [want %-5s got %-5s rc=%s] %s\n' "$expect" "$got" "$rc" "$name"
  fi
}

# run_receipt <name> <file_path> <content> <want_shape>
# The gate is more than a boolean: when it BLOCKS it emits a receipt on the `error`
# key. This asserts the receipt is valid JSON, a hard block (rc 2), and that the
# error text names BOTH the matched stub-shape AND the exact file path (FPATH) —
# so "Heimdall blocked a <shape> @ <path>" is a postable moment, not a bare 401.
run_receipt() {
  name="$1"; fpath="$2"; content="$3"; want_shape="$4"
  json="$(jq -n --arg fp "$fpath" --arg c "$content" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:$c}}')"
  out="$(printf '%s' "$json" | bash -c "$CMD" 2>/dev/null)"
  rc=$?
  err="$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)"
  ok=1
  [ "$rc" -eq 2 ] || ok=0                       # hard block
  [ -n "$err" ] || ok=0                          # valid JSON with an .error key
  case "$err" in *"$want_shape"*) : ;; *) ok=0 ;; esac   # names the SHAPE
  case "$err" in *"$fpath"*) : ;; *) ok=0 ;; esac        # names the PATH (FPATH)
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    printf 'PASS [recpt] %-24s shape=%-22s @ %s\n' "$name" "$want_shape" "$fpath"
  else
    fail=$((fail + 1))
    printf 'FAIL [recpt rc=%s] %s\n  err=%s\n' "$rc" "$name" "$err"
  fi
}

echo "== STILL BLOCKED: real unfinished-code shapes =="
run_case block "js empty named fn body"       "src/foo.js"  'function foo(){}'
run_case block "js empty arrow body"          "src/foo.js"  'const f = () => {}'
run_case block "python pass-only body"        "src/f.py"    "$(printf 'def f():\n    pass\n')"
run_case block "throw not implemented (dq)"   "src/f.js"    'throw new Error("not implemented")'
run_case block "throw not implemented (sq)"   "src/f.js"    "throw new Error('not implemented')"
run_case block "raise NotImplementedError"    "src/f.py"    "$(printf 'def f():\n    raise NotImplementedError\n')"
run_case block "code-comment // TODO"         "src/f.js"    '// TODO: implement this'
run_case block "code-comment # TODO"          "src/f.py"    '# TODO: implement this'
run_case block "rust todo macro"              "src/f.rs"    'fn f() { todo!() }'
run_case block "rust unimplemented macro"     "src/f.rs"    'fn f() { unimplemented!() }'

echo
echo "== NOW ALLOWED: legitimate content the raw-word grep wrongly blocked =="
run_case allow "roman numeral (XXX inside)"   "src/roman.js"                              'const MMMDCCCLXXXVIII = 3888; // roman'
run_case allow "markdown prose re: no-stub"   "docs/policy.md"                            'Never write a stub or placeholder in production code.'
run_case allow "fixtures deliberate defect"   "evals/oracles/ponytail/fixtures/bad.js"    'function under(){}'
run_case allow "json data value placeholder"  "config/data.json"                          '{"label": "placeholder text"}'
run_case allow "word stub in a code comment"  "src/real.js"                               'const x = 1; // this is not a stub, it is real and complete'
run_case allow "txt talking about shim/XXX"   "notes.txt"                                 'The shim/stub/XXX/placeholder words are fine here.'
run_case allow "real complete function"       "src/real.js"                               'function add(a, b){ return a + b; }'

echo
echo "== RECEIPT: block message names the matched SHAPE + the FILE PATH =="
run_receipt "empty-body receipt"     "src/widget.js"  'function render(){}'                     "empty function body"
run_receipt "pass-only receipt"      "src/svc.py"     "$(printf 'def handle():\n    pass\n')"   "pass-only body"
run_receipt "not-impl throw receipt" "src/api.js"     'throw new Error("not implemented")'      "not-implemented throw"
run_receipt "code-comment receipt"   "src/util.js"    '// TODO: wire this up'                   "code-comment TODO/FIXME"

echo
echo "----"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
