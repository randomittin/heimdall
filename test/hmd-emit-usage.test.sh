#!/usr/bin/env bash
# test/hmd-emit-usage.test.sh — hmd self-meters its OWN run from claude's OWN
# structured output (NOT from a transcript file).
#
# DETERMINISTIC, NO REAL MODEL SPEND. A FAKE `claude` on PATH prints a canned
# `--output-format json` / `--output-format stream-json` blob carrying KNOWN
# usage + cost + session_id (plus the assistant's result text). The test drives
# hmd's capture path with HEIMDALL_USAGE_OUT set and asserts:
#
#   (a) the emitted record matches the LOCKED RAW schema with the correct raw
#       values + cost + session_id + model + usage_available:true, emitted to
#       $HEIMDALL_USAGE_OUT (no derived fields — raw only).
#   (b) the user STILL SAW the assistant's result text (UX preserved) even on the
#       json (automated) capture path.
#   (c) the stream-json (interactive) capture path renders the streamed assistant
#       text to the user AND captures the SAME usage+cost+session_id from the
#       final `result` event.
#   (d) when claude emits NO usable structured output, the record is honest:
#       usage_available:false + zeros + a reason — NEVER a fabricated number.
#   (e) the captured task's exit code is propagated unchanged (fail-open metering
#       never alters the run's status), and a metering failure never aborts.
#   (f) NO transcript file is read in the capture path — there is no
#       <projects-root>/<slug>/<session_id>.jsonl read anywhere.
#
# The capture+emit logic is exercised as a UNIT: bin/heimdall is sourced with
# HEIMDALL_LIB_ONLY=1 (defines functions, skips the main bootstrap), then
# capture_and_emit_usage is called directly with a fake `claude` on PATH.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HMD="$ROOT/bin/heimdall"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
[ -f "$HMD" ] || { echo "FATAL: heimdall not found at $HMD" >&2; exit 2; }

WORK="$(mktemp -d -t "emit-usage-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── Source hmd in library-only mode so we get the functions, not the bootstrap ─
# HEIMDALL_LIB_ONLY=1 makes bin/heimdall define its functions then return before
# the main launch path. Sourcing must succeed (rc 0) and expose the capture fn.
set +e
# shellcheck disable=SC1090
HEIMDALL_LIB_ONLY=1 source "$HMD"
SRC_RC=$?
set -e
if [ "$SRC_RC" -eq 0 ] && declare -F capture_and_emit_usage >/dev/null 2>&1; then
  ok "(lib) hmd sources in HEIMDALL_LIB_ONLY mode and exposes capture_and_emit_usage"
else
  bad "(lib) hmd did not source cleanly / no capture_and_emit_usage (rc=$SRC_RC)"
  echo "  hmd-emit-usage tests: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# ── Build a FAKE `claude` that prints canned structured output ─────────────────
# It honors the output format hmd asks for:
#   --output-format json        -> ONE json blob (top-level .usage + .total_cost_usd + .session_id + .result)
#   --output-format stream-json -> NDJSON: assistant text events, then a final `result` event
# It also writes the result text to stdout so we can assert UX preservation.
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
RESULT_TEXT="DONE: built the dashboard with auth and tests."
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
# Fake claude: deterministic structured output, NO network, NO spend.
mode="json"
for a in "\$@"; do
  case "\$a" in
    stream-json) mode="stream-json" ;;
    json) mode="json" ;;
  esac
done
SID="fake-sess-1234-5678"
RES="$RESULT_TEXT"
if [ "\$mode" = "stream-json" ]; then
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\$SID\"}"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\$RES\"}]}}"
  printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"\$SID\",\"total_cost_usd\":0.0731,\"result\":\"\$RES\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":345,\"cache_creation_input_tokens\":6000,\"cache_read_input_tokens\":90000},\"modelUsage\":{\"claude-opus-4-8\":{}}}"
else
  printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"\$SID\",\"total_cost_usd\":0.0731,\"result\":\"\$RES\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":345,\"cache_creation_input_tokens\":6000,\"cache_read_input_tokens\":90000},\"modelUsage\":{\"claude-opus-4-8\":{}}}"
fi
exit 0
FAKE
chmod +x "$FAKEBIN/claude"

# Known expected values from the fake blob.
EXP_IN=1200; EXP_OUT=345; EXP_CC=6000; EXP_CR=90000
EXP_COST=0.0731; EXP_SID="fake-sess-1234-5678"; EXP_MODEL="claude-opus-4-8"

# ── (a)+(b) AUTOMATED path: --output-format json, HEIMDALL_USAGE_OUT set ───────
OUT_A="$WORK/usage-json.json"
STDOUT_A="$WORK/stdout-json.txt"
set +e
PATH="$FAKEBIN:$PATH" HEIMDALL_USAGE_OUT="$OUT_A" HEIMDALL_USAGE_FORMAT="json" \
  capture_and_emit_usage "$EXP_MODEL" --agent heimdall -p "build a dashboard" \
  > "$STDOUT_A" 2>/dev/null
RC_A=$?
set -e

if [ "$RC_A" -eq 0 ]; then
  ok "(e) automated capture propagates the fake task's exit code unchanged (rc=0)"
else
  bad "(e) automated capture did not propagate rc=0 (got $RC_A)"
fi

if [ -f "$OUT_A" ] && jq -e '.' "$OUT_A" >/dev/null 2>&1; then
  if jq -e --argjson i "$EXP_IN" --argjson o "$EXP_OUT" --argjson cc "$EXP_CC" \
        --argjson cr "$EXP_CR" --argjson cost "$EXP_COST" \
        --arg sid "$EXP_SID" --arg model "$EXP_MODEL" '
        .session_id == $sid
        and .input_tokens == $i and .output_tokens == $o
        and .cache_creation_tokens == $cc and .cache_read_tokens == $cr
        and .total_cost_usd == $cost
        and .model == $model
        and .usage_available == true
      ' "$OUT_A" >/dev/null 2>&1; then
    ok "(a) json path emits the LOCKED RAW record (in/out/cc/cr + cost + sid + model + usage_available)"
  else
    bad "(a) json path emitted record mismatch"; cat "$OUT_A"
  fi
  # RAW ONLY — no derived fields (no total_tokens, no turns) in the emitted record.
  if jq -e 'has("total_tokens") or has("turns")' "$OUT_A" >/dev/null 2>&1; then
    bad "(a2) emitted record carries derived fields (total_tokens/turns) — must be RAW only"; cat "$OUT_A"
  else
    ok "(a2) emitted record is RAW only (no total_tokens / turns derived fields)"
  fi
else
  bad "(a) json path did not emit a valid record at $OUT_A"
fi

# the user still saw the assistant's result text on the json path.
if grep -qF "$RESULT_TEXT" "$STDOUT_A"; then
  ok "(b) json path: the user STILL SAW the assistant result text (UX preserved)"
else
  bad "(b) json path: result text was not surfaced to the user"; cat "$STDOUT_A"
fi

# ── (c) INTERACTIVE path: --output-format stream-json, render + capture ────────
OUT_C="$WORK/usage-stream.json"
STDOUT_C="$WORK/stdout-stream.txt"
set +e
PATH="$FAKEBIN:$PATH" HEIMDALL_USAGE_OUT="$OUT_C" HEIMDALL_USAGE_FORMAT="stream-json" \
  capture_and_emit_usage "$EXP_MODEL" --agent heimdall -p "build a dashboard" \
  > "$STDOUT_C" 2>/dev/null
RC_C=$?
set -e

if [ "$RC_C" -eq 0 ] && [ -f "$OUT_C" ] && jq -e --argjson i "$EXP_IN" --argjson o "$EXP_OUT" \
      --argjson cc "$EXP_CC" --argjson cr "$EXP_CR" --argjson cost "$EXP_COST" \
      --arg sid "$EXP_SID" '
      .input_tokens == $i and .output_tokens == $o
      and .cache_creation_tokens == $cc and .cache_read_tokens == $cr
      and .total_cost_usd == $cost and .session_id == $sid
      and .usage_available == true
    ' "$OUT_C" >/dev/null 2>&1; then
  ok "(c) stream-json path captures the SAME usage+cost+sid from the final result event"
else
  bad "(c) stream-json path capture wrong (rc=$RC_C)"; [ -f "$OUT_C" ] && cat "$OUT_C"
fi

# the streamed assistant text reached the user (rendered, not raw JSON).
if grep -qF "$RESULT_TEXT" "$STDOUT_C"; then
  ok "(c2) stream-json path: streamed assistant text rendered to the user"
else
  bad "(c2) stream-json path: assistant text not rendered to user"; cat "$STDOUT_C"
fi

# ── (d) NO usable usage => honest usage_available:false + zeros + reason ───────
FAKEBIN2="$WORK/bin-empty"
mkdir -p "$FAKEBIN2"
cat > "$FAKEBIN2/claude" <<'FAKE2'
#!/usr/bin/env bash
# Fake claude that emits NO usable structured output (just plain noise).
printf '%s\n' "hello, this is not structured json output at all"
exit 0
FAKE2
chmod +x "$FAKEBIN2/claude"
OUT_D="$WORK/usage-none.json"
set +e
PATH="$FAKEBIN2:$PATH" HEIMDALL_USAGE_OUT="$OUT_D" HEIMDALL_USAGE_FORMAT="json" \
  capture_and_emit_usage "$EXP_MODEL" --agent heimdall -p "x" >/dev/null 2>&1
RC_D=$?
set -e
if [ "$RC_D" -eq 0 ] && [ -f "$OUT_D" ] && jq -e '
      .usage_available == false
      and .input_tokens == 0 and .output_tokens == 0
      and .cache_creation_tokens == 0 and .cache_read_tokens == 0
      and (.reason // "" | length > 0)
    ' "$OUT_D" >/dev/null 2>&1; then
  ok "(d) no usable usage => usage_available:false + zeros + a reason (NEVER fabricated)"
else
  bad "(d) unusable-usage record not honest (rc=$RC_D)"; [ -f "$OUT_D" ] && cat "$OUT_D"
fi

# ── (e2) a FAILING task (nonzero exit) => exit code propagated, record still emits ─
FAKEBIN3="$WORK/bin-fail"
mkdir -p "$FAKEBIN3"
cat > "$FAKEBIN3/claude" <<FAKE3
#!/usr/bin/env bash
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"error\",\"session_id\":\"err-sess-9\",\"total_cost_usd\":0.01,\"result\":\"boom\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}"
exit 7
FAKE3
chmod +x "$FAKEBIN3/claude"
OUT_E="$WORK/usage-fail.json"
set +e
PATH="$FAKEBIN3:$PATH" HEIMDALL_USAGE_OUT="$OUT_E" HEIMDALL_USAGE_FORMAT="json" \
  capture_and_emit_usage "$EXP_MODEL" --agent heimdall -p "x" >/dev/null 2>&1
RC_E=$?
set -e
if [ "$RC_E" -eq 7 ] && [ -f "$OUT_E" ] && jq -e '.session_id == "err-sess-9" and .input_tokens == 5' "$OUT_E" >/dev/null 2>&1; then
  ok "(e2) failing task (exit 7): exit code propagated AND usage still emitted (fail-open)"
else
  bad "(e2) failing task not handled (rc=$RC_E)"; [ -f "$OUT_E" ] && cat "$OUT_E"
fi

# ── (f) NO transcript read anywhere in the capture path ────────────────────────
# Static guarantee: the capture function body must not read a per-session
# transcript by the deterministic <projects-root>/<slug>/<session_id>.jsonl rule.
FNBODY="$(declare -f capture_and_emit_usage)"
if printf '%s' "$FNBODY" | grep -qE 'projects.?root|\.jsonl|HEIMDALL_PROJECTS_ROOT|claude/projects'; then
  bad "(f) capture path still references a transcript path (.jsonl / projects-root) — must be removed"
else
  ok "(f) capture path reads NO transcript file (no .jsonl / projects-root reference)"
fi

echo
echo "  hmd-emit-usage tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
