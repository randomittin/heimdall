#!/usr/bin/env bash
# test-protocol.sh — falsifiable test suite for the Token-Frugal Protocol v2.
#
# Pure bash + jq. Drives every protocol mechanism end-to-end against an isolated
# fixture planning tree (HEIMDALL_PLANNING_DIR -> a mktemp dir), so it never
# touches the real .planning/. Exit 0 iff every assertion holds.
#
# Usage: bin/protocol/test-protocol.sh
set -euo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
PROTO_BIN_DIR="$(cd "$(dirname "$SELF")" && pwd)"
BIN_DIR="$(cd "$PROTO_BIN_DIR/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
check(){ # desc ; runs last-arg test command already evaluated to $?
  if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi
}
# expect_fail <desc> <cmd...> — asserts the command exits NONZERO (set -e safe).
expect_fail(){ local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc (expected nonzero)"; else ok "$desc"; fi; }
# pipe_fail <desc> <input> <cmd...> — pipes input, asserts NONZERO exit.
pipe_fail(){ local desc="$1" in="$2"; shift 2; if printf '%s' "$in" | "$@" >/dev/null 2>&1; then bad "$desc (expected nonzero)"; else ok "$desc"; fi; }

# Isolated planning tree for the whole run.
TMP_PLANNING="$(mktemp -d)"
trap 'rm -rf "$TMP_PLANNING"' EXIT
export HEIMDALL_PLANNING_DIR="$TMP_PLANNING"

RESOLVE="$BIN_DIR/heimdall-resolve"
BLACKBOARD="$BIN_DIR/heimdall-blackboard"
CAPSULE="$BIN_DIR/heimdall-capsule"
BRIEF="$BIN_DIR/heimdall-brief"
LEDGER="$BIN_DIR/heimdall-ledger"
VALIDATE="$BIN_DIR/heimdall-validate"
GATE="$BIN_DIR/heimdall-gate"
PROTO="$BIN_DIR/heimdall-protocol"

echo "== syntax (bash -n) =="
for b in "$RESOLVE" "$BLACKBOARD" "$CAPSULE" "$BRIEF" "$LEDGER" "$VALIDATE" "$GATE" "$PROTO" "$BIN_DIR/lib/protocol.sh"; do
  bash -n "$b"; check $? "bash -n $(basename "$b")"
done

echo "== init =="
"$PROTO" init >/dev/null; check $? "heimdall-protocol init"
[ -f "$TMP_PLANNING/protocol/symbols.json" ];    check $? "symbols.json created"
[ -f "$TMP_PLANNING/blackboard.json" ];          check $? "blackboard.json created"
[ -d "$TMP_PLANNING/protocol/capsules" ];        check $? "capsules/ created"
[ -f "$TMP_PLANNING/protocol/message-schema.json" ]; check $? "message-schema.json installed"

echo "== [2] symbol table — resolve forward & reverse =="
"$RESOLVE" set F12 "src/matching/engine.ts" >/dev/null;       check $? "resolve set F12"
"$RESOLVE" set C3 "balances sum to zero" >/dev/null;          check $? "resolve set C3"
[ "$("$RESOLVE" F12)" = "src/matching/engine.ts" ];           check $? "resolve F12 -> path"
[ "$("$RESOLVE" C3)" = "balances sum to zero" ];              check $? "resolve C3 -> invariant"
[ "$("$RESOLVE" --reverse "src/matching/engine.ts")" = "F12" ]; check $? "reverse path -> F12"
expect_fail "resolve unknown id exits nonzero" "$RESOLVE" NOPE

echo "== [5] blackboard — set/get by key =="
"$BLACKBOARD" set dev_port 5173 >/dev/null;                   check $? "blackboard set dev_port"
"$BLACKBOARD" set node_version "20.11.0" >/dev/null;          check $? "blackboard set node_version"
[ "$("$BLACKBOARD" get dev_port)" = "5173" ];                 check $? "blackboard get dev_port"
[ "$("$BLACKBOARD" get node_version)" = "20.11.0" ];          check $? "blackboard get node_version"
expect_fail "blackboard get missing key exits nonzero" "$BLACKBOARD" get missing_key

echo "== [3] context capsules — write & hydrate dependency set only =="
"$CAPSULE" write wave1 --what "added LOB engine" --where "F12" \
  --decision "serial-replay reference" --gotcha "seed must be fixed" >/dev/null
check $? "capsule write wave1"
"$CAPSULE" write wave2 --what "added book diff" --where "F13" \
  --decision "post-stream compare" --depends wave1 >/dev/null
check $? "capsule write wave2 (depends wave1)"
"$CAPSULE" write wave3 --what "unrelated docs" --where "README" >/dev/null
check $? "capsule write wave3 (independent)"
[ "$(wc -l < "$TMP_PLANNING/protocol/capsules/wave1.md" | tr -d ' ')" -le 10 ]
check $? "capsule wave1 <= 10 lines"
# Hydrate the dependency set of wave2: must include wave2 + wave1, NOT wave3.
HYD="$("$CAPSULE" hydrate wave2)"
printf '%s' "$HYD" | grep -q "added LOB engine"; check $? "hydrate wave2 includes wave1 (dependency)"
printf '%s' "$HYD" | grep -q "added book diff";  check $? "hydrate wave2 includes wave2 (self)"
! printf '%s' "$HYD" | grep -q "unrelated docs"; check $? "hydrate wave2 EXCLUDES wave3 (not a dependency)"

echo "== [1] typed messages — validate good, reject malformed =="
GOOD='{"type":"task_result","from":"coder","msg_id":"m1","task":"3.2","status":"pass","criteria":[1,2,4],"commit":"a2ef507"}'
printf '%s' "$GOOD" | "$VALIDATE" >/dev/null; check $? "validate accepts good task_result"
BAD='{"type":"task_result","from":"coder","msg_id":"m2","status":"banana"}'
pipe_fail "validate REJECTS task_result missing task + bad status enum" "$BAD" "$VALIDATE"
MALFORMED='{"type":"task_result","from":"coder"'  # truncated JSON
pipe_fail "validate REJECTS unparseable JSON" "$MALFORMED" "$VALIDATE"
UNKNOWN='{"type":"frobnicate","from":"x","msg_id":"m3"}'
pipe_fail "validate REJECTS unknown message type" "$UNKNOWN" "$VALIDATE"
# validate-on-receipt: malformed -> one retry -> escalate
if OUT="$(printf '%s\n%s\n' "$MALFORMED" "$GOOD" | "$VALIDATE" --on-receipt 2>&1)"; then
  printf '%s' "$OUT" | grep -q "retry"; check $? "on-receipt: malformed then valid retry -> accepted"
else
  bad "on-receipt: malformed then valid retry -> accepted (got nonzero)"
fi
if printf '%s\n%s\n' "$MALFORMED" "$MALFORMED" | "$VALIDATE" --on-receipt >/dev/null 2>&1; then
  bad "on-receipt: two malformed -> escalate (expected nonzero)"
else
  ok "on-receipt: two malformed -> escalate (nonzero)"
fi

echo "== [4] delta brief — refs only, NOT the plan =="
# Plant a plan file that must NOT leak into the brief.
echo "SECRET_FULL_PLAN_BODY do not leak this" > "$TMP_PLANNING/PLAN-alpha.md"
# The invariants ref is repo-relative and is now VALIDATED, not echoed. This
# fixture used to pass `INVARIANTS.md`, which has never existed at the repo
# root — a dangling ref that rode through silently for months and is exactly
# the defect the validation was added for. A spawn handed that ref believes it
# inherited the no-stub rules it was never actually given.
BR="$("$BRIEF" build --task 3.2 --spec "implement book diff" \
       --symbols F12,C3 --capsules wave2 --invariants "CLAUDE.md#code-quality--zero-tolerance")"
printf '%s' "$BR" | grep -q "verified: file + anchor"; check $? "brief VERIFIES the invariants ref (file + anchor), not just echoes it"
expect_fail "brief REFUSES an invariants ref whose file does not exist" \
  "$BRIEF" build --task 3.2 --spec "dangle" --invariants "INVARIANTS.md"
expect_fail "brief REFUSES an invariants ref whose anchor does not exist" \
  "$BRIEF" build --task 3.2 --spec "dangle" --invariants "CLAUDE.md#no-such-section"
printf '%s' "$BR" | grep -q "implement book diff"; check $? "brief includes task spec"
printf '%s' "$BR" | grep -q "F12"; check $? "brief includes symbol refs"
printf '%s' "$BR" | grep -q "wave2"; check $? "brief includes capsule refs"
printf '%s' "$BR" | grep -q "src/matching/engine.ts"; check $? "brief resolves referenced symbols (added LOB engine context)"
! printf '%s' "$BR" | grep -q "SECRET_FULL_PLAN_BODY"; check $? "brief EXCLUDES the full plan body"
# Brief must hydrate ONLY referenced capsules (wave2 deps), not wave3.
! printf '%s' "$BR" | grep -q "unrelated docs"; check $? "brief EXCLUDES non-referenced capsule wave3"

echo "== [6] token ledger — measured before/after =="
"$LEDGER" log --role orchestration --kind brief --tokens 12000 >/dev/null; check $? "ledger log line 1"
"$LEDGER" log --role coder --kind task_result --tokens 800 >/dev/null;    check $? "ledger log line 2"
[ "$(wc -l < "$TMP_PLANNING/protocol/ledger.jsonl" | tr -d ' ')" -eq 2 ]; check $? "ledger has 2 lines"
"$LEDGER" report >/dev/null; check $? "ledger report runs"
# baseline/delta: set a v1 baseline for orchestration, expect a measured delta.
"$LEDGER" baseline --role orchestration --tokens 41000 >/dev/null; check $? "ledger set v1 baseline"
DELTA="$("$LEDGER" delta --role orchestration)"
printf '%s' "$DELTA" | grep -q "41000"; check $? "ledger delta shows baseline 41000"
printf '%s' "$DELTA" | grep -q "12000"; check $? "ledger delta shows measured 12000"

echo "== [contract-consuming, LAST/THINNEST] gate-report adapter =="
# A minimal report.json in the H-1 contract shape.
RPT="$TMP_PLANNING/sample-report.json"
cat > "$RPT" <<JSON
{"gate_id":"exchange-lob","status":"pass","first_divergence":null,"metrics":{"trades_compared":3},"fix_hint":"none","haid":"haid:local","wave":null,"ts":"2026-06-11T00:00:00Z"}
JSON
MSG="$("$GATE" to-message --report "$RPT" --from sentinel-bloat --msg-id g1)"
printf '%s' "$MSG" | "$VALIDATE" >/dev/null; check $? "gate adapter emits a schema-valid gate_report message"
[ "$(printf '%s' "$MSG" | jq -r '.gate_id')" = "exchange-lob" ]; check $? "gate_report carries gate_id (ref, not inlined body)"
[ "$(printf '%s' "$MSG" | jq -r '.status')" = "pass" ];          check $? "gate_report carries status"
# The adapter references the report by path — it must NOT inline metrics body.
! printf '%s' "$MSG" | jq -e 'has("metrics")' >/dev/null 2>&1;   check $? "gate_report does NOT inline metrics (reference-only)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
