#!/usr/bin/env bash
# test/heimdall-task-result.test.sh — falsifiable tests for the H-4 return-path
# codec: heimdall-task-result compacts a finding to a capsule (heimdall-capsule)
# plus a schema-valid task_result message (bin/protocol/message-schema.json)
# referencing it by id. No LLM summarization step -- a file write and an id.
#
# Hermetic: HEIMDALL_PLANNING_DIR -> mktemp -d, no network, no real .planning/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/heimdall-task-result"
CAPSULE="$ROOT/bin/heimdall-capsule"
VALIDATE="$ROOT/bin/heimdall-validate"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
expect_fail(){ local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc (expected nonzero)"; else ok "$desc"; fi; }

TMP_PLANNING="$(mktemp -d)"
trap 'rm -rf "$TMP_PLANNING"' EXIT
export HEIMDALL_PLANNING_DIR="$TMP_PLANNING"
"$ROOT/bin/heimdall-protocol" init >/dev/null 2>&1 || true

echo "== usage / basic shape =="
if bash -n "$BIN" 2>/dev/null; then ok "bash -n heimdall-task-result"; else bad "bash -n heimdall-task-result"; fi
if "$BIN" -h >/dev/null 2>&1; then ok "-h exits 0"; else bad "-h exits 0"; fi
if "$BIN" -h 2>/dev/null | grep -q "heimdall-task-result done"; then ok "-h mentions the done subcommand"; else bad "-h mentions the done subcommand"; fi

echo "== done: happy path emits a schema-valid task_result =="
MSG='{}'
if OUT="$("$BIN" done --task T1 --status pass --from coder --what "added retry logic" --where "src/net.ts" --commit abc123 2>/dev/null)"; then
  ok "done (happy path) exits 0"; MSG="$OUT"
else
  bad "done (happy path) exits 0"
fi
if printf '%s' "$MSG" | "$VALIDATE" >/dev/null 2>&1; then ok "emitted message validates against message-schema.json"; else bad "emitted message validates against message-schema.json"; fi
checkeq "type == task_result"        "$(printf '%s' "$MSG" | jq -r '.type // empty')"    "task_result"
checkeq "task == T1"                 "$(printf '%s' "$MSG" | jq -r '.task // empty')"    "T1"
checkeq "status == pass"             "$(printf '%s' "$MSG" | jq -r '.status // empty')"  "pass"
checkeq "commit == abc123"           "$(printf '%s' "$MSG" | jq -r '.commit // empty')"  "abc123"
checkeq "capsule references task id" "$(printf '%s' "$MSG" | jq -r '.capsule // empty')" "T1"
checkeq "stdout is exactly one compact JSON line" "$(printf '%s' "$MSG" | jq -c . 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "== round-trip: capsule the message references hydrates identical content =="
CAP_ID="$(printf '%s' "$MSG" | jq -r '.capsule // empty')"
HYD="$("$CAPSULE" show "${CAP_ID:-__none__}" 2>/dev/null || true)"
if printf '%s' "$HYD" | grep -q "added retry logic"; then ok "hydrated capsule has identical WHAT content"; else bad "hydrated capsule has identical WHAT content"; fi
if printf '%s' "$HYD" | grep -q "src/net.ts"; then ok "hydrated capsule has identical WHERE content"; else bad "hydrated capsule has identical WHERE content"; fi

echo "== criteria round-trip =="
MSG2='{}'
if OUT2="$("$BIN" done --task T2 --status partial --from coder --what "partial fix" --criteria 1,2,4 2>/dev/null)"; then
  ok "done with --criteria exits 0"; MSG2="$OUT2"
else
  bad "done with --criteria exits 0"
fi
checkeq "criteria round-trips as integer array" "$(printf '%s' "$MSG2" | jq -c '.criteria // empty')" "[1,2,4]"

echo "== rejects bad input (exit 2) =="
expect_fail "missing --task rejected" "$BIN" done --status pass --from coder --what x
expect_fail "missing --what rejected" "$BIN" done --task T3 --status pass --from coder
expect_fail "missing --from rejected" "$BIN" done --task T3 --status pass --what x
expect_fail "bad --status rejected"   "$BIN" done --task T3 --status banana --from coder --what x
expect_fail "bad --criteria rejected" "$BIN" done --task T3 --status pass --from coder --what x --criteria "1,a,3"
RC=0; "$BIN" done --task T3 --status banana --from coder --what x >/dev/null 2>&1 || RC=$?
checkeq "bad --status exits exactly 2" "$RC" "2"

echo "== capsule write failure propagates as exit 1 =="
OVERLONG="$(printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8')"
RC=0; "$BIN" done --task Toverlong --status pass --from coder --what "$OVERLONG" >/dev/null 2>&1 || RC=$?
checkeq "capsule write failure (>10 lines) propagates as exit 1" "$RC" "1"
if [ -f "$TMP_PLANNING/protocol/capsules/Toverlong.md" ]; then bad "failed capsule write leaves no partial file"; else ok "failed capsule write leaves no partial file"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
