#!/usr/bin/env bash
# test/heimdall-429-detect-trace.test.sh -- hermetic tests for the diagnostic
# tracing added to hooks/heimdall-429-detect.sh (trace_emit(), trap ... EXIT).
#
# WHY THIS FILE EXISTS, SEPARATELY FROM test/heimdall-429-detect.test.sh: that
# suite proves MARKING behaviour (does a real 429 produce a marker) and now
# deliberately runs with HMD_429_DETECT_TRACE=0 throughout (see its own header
# comment) so tracing never touches the real $HOME/.heimdall from its six
# `unset HEIMDALL_HOME` subshells. This file's only job is the opposite: prove
# TRACING itself -- the one-line-per-invocation record that is the sole way to
# answer, from OUTSIDE the hook process, "did Stop/SubagentStop ever actually
# fire for a real 429 death?" (see the hook's own "THE OPEN QUESTION" header).
# Every case below therefore sandboxes HEIMDALL_HOME to a throwaway directory
# it controls and inspects, rather than unsetting it.
#
# FALSIFIABLE CLAIMS TESTED:
#  1. hooks/heimdall-429-detect.sh is executable and parses (bash -n) -- a
#     minimal sanity floor; full hooks.json wiring is already proven by
#     test/heimdall-429-detect.test.sh and is not duplicated here.
#  2. Trace ON by default (env var simply unset) + a real fresh 429 via
#     agent_transcript_path (SubagentStop shape) -> the marker is STILL
#     written correctly AND a trace line lands with every field matching:
#     hook_event_name, had_agent_transcript_path=true, had_transcript_path=
#     false, tier1_examined=1, tier2/3_examined=0, outcome=marked, detail.
#  3. Trace explicitly OFF (HMD_429_DETECT_TRACE=0) + a real fresh 429 (Stop
#     shape) -> the marker is STILL written (tracing must never change
#     detection behaviour), but NO trace file is created at all.
#  4. Trace default (env var unset, not merely "not 0") + a clean/no-429
#     transcript (Stop shape) -> a trace line lands with outcome=no-match,
#     tier1_examined=1, tier2/3=0, and no marker. This is the concrete proof
#     that tracing is genuinely opt-OUT, not opt-in: nothing here asks for
#     tracing, yet a line still appears.
#  5. jq unavailable on PATH -> the hook still fails open (no marker) but ALSO
#     still emits a trace line (outcome=skipped-no-jq, had_agent_transcript_
#     path=null, had_transcript_path=null, all tier counters 0, empty
#     hook_event_name) -- proving trace_emit's own printf-only construction
#     does not depend on jq, which matters precisely because "jq missing" is
#     one of the outcomes this trace exists to distinguish.
#  6. Unwritable trace path (a real file occupies the directory component the
#     trace file would need) -> the hook still exits 0 and STILL marks
#     correctly; the trace write fails silently and never surfaces as a
#     detection regression.
#  7. Size-cap/rotation: a trace file pre-seeded past a small configured
#     HMD_429_DETECT_TRACE_MAX_BYTES is trimmed to bounded size rather than
#     growing without limit.
#  8. Multiple invocations append additional lines rather than overwriting the
#     file (proves >> semantics, not truncation).
#  9. HMD_429_DETECT_TRACE_FILE override is honored -- the custom path
#     receives the line and the default path is never created.
# 10. Tier 2 (sibling transcript) scanning increments tier2_examined and the
#     resulting marker's reason carries the -sibling suffix.
# 11. Tier 3 (prose) scanning increments tier3_examined and the resulting
#     marker's reason carries the -prose suffix (reusing the real verbatim
#     production reset-clause string this repo already fixed a classifier bug
#     for).
#
# Usage: bash test/heimdall-429-detect-trace.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOK_SRC="$REPO/hooks/heimdall-429-detect.sh"
MARK_SRC="$REPO/bin/heimdall-429-mark"
QUOTA_STOP_SRC="$REPO/bin/lib/quota_stop.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "heimdall-429-detect-trace harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "  python3 is required for this test" >&2
  exit 1
fi

# --- 1. hook is executable and parses ----------------------------------------
if [ ! -x "$HOOK_SRC" ]; then
  bad "hooks/heimdall-429-detect.sh is not executable -- cannot prove end-to-end"
  echo "--------------------------------------------------------------------"
  echo "RESULT: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
bash -n "$HOOK_SRC" && ok "hooks/heimdall-429-detect.sh parses (bash -n)" || bad "hooks/heimdall-429-detect.sh has a syntax error"

# --- sandbox: a fake plugin install (hooks/ + bin/), called DIRECTLY ---------
# This file calls the copied script directly (bash "$PLUGIN/hooks/....sh"),
# never through the hooks.json SubagentStop/Stop array wrappers -- that
# wiring (both arrays name exactly one entry invoking this script, pre-
# existing owners are undisturbed) is already proven exhaustively by
# test/heimdall-429-detect.test.sh. Duplicating it here would just be the
# same assertion twice for a file whose only job is tracing behaviour, which
# lives entirely inside the script regardless of which array invoked it. The
# script resolves its own PLUGIN_DIR from `$0` (readlink -f), not from
# CLAUDE_PLUGIN_ROOT -- see hooks/heimdall-429-detect.sh:175-181 -- so a
# direct invocation with the real on-disk path resolves MARK_BIN correctly
# with no extra wiring needed.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-429-detect-trace.XXXXXX")"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

PLUGIN="$SANDBOX/plugin"
PROJECT="$SANDBOX/project"
TRANSCRIPTS="$SANDBOX/transcripts"
mkdir -p "$PLUGIN/hooks" "$PLUGIN/bin/lib" "$PROJECT" "$TRANSCRIPTS"

cp "$HOOK_SRC" "$PLUGIN/hooks/heimdall-429-detect.sh"
cp "$MARK_SRC" "$PLUGIN/bin/heimdall-429-mark"
cp "$QUOTA_STOP_SRC" "$PLUGIN/bin/lib/quota_stop.py"
[ -f "$PLUGIN/bin/lib/quota_stop.py" ] || { echo "FATAL: quota_stop.py failed to stage into sandbox" >&2; exit 1; }
chmod +x "$PLUGIN/hooks/heimdall-429-detect.sh" "$PLUGIN/bin/heimdall-429-mark"

MARKER="$SANDBOX/429-marker.json"

# Sandboxed HEIMDALL_HOME -- the entire point of this file. Named
# "unused-heimdall-home" to match the naming convention already established
# at test/heimdall-429-mark.test.sh:56 for a HEIMDALL_HOME that must never
# resolve to the operator's real ~/.heimdall.
HEIMDALL_HOME_SANDBOX="$SANDBOX/unused-heimdall-home"
mkdir -p "$HEIMDALL_HOME_SANDBOX"
TRACE_FILE_DEFAULT="$HEIMDALL_HOME_SANDBOX/429-detect-trace.jsonl"

iso_ts_offset() {
  # $1 = signed seconds offset from now. Delegates to python3 exactly like
  # test/heimdall-429-detect.test.sh's own iso_ts_offset(), sidestepping BSD
  # `date -v` vs GNU `date -d` divergence.
  python3 -c "import time,sys; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()+float(sys.argv[1]))))" "$1"
}

run_hook() {
  # $1 = payload json (stdin). Exports a SANDBOXED HEIMDALL_HOME (never unset)
  # -- the opposite of test/heimdall-429-detect.test.sh's run_hook(), because
  # this file's entire purpose is verifying what lands under a controlled
  # home directory.
  (
    cd "$SANDBOX" || exit 1
    export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX"
    export CLAUDE_PROJECT_DIR="$PROJECT"
    export HEIMDALL_429_MARKER_FILE="$MARKER"
    printf '%s' "$1" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" > /dev/null 2> "$SANDBOX/stderr.log"
  )
}

marker_exists() { [ -f "$MARKER" ]; }
marker_reason() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('reason',''))" "$MARKER" 2>/dev/null || true; }
reset_marker() { rm -f "$MARKER"; }
reset_trace()  { rm -f "$TRACE_FILE_DEFAULT"; }

last_trace_line() { tail -n 1 "$1" 2>/dev/null || true; }

# field_is: $1 = trace file, $2 = jq boolean filter against the LAST line
# (e.g. '.outcome == "marked"'), $3 = description. jq's `==` is type-strict
# ("true" (string) == true (bool) is false, never an error), so this proves
# BOTH presence and exact JSON type/value in one shot -- exactly what a
# hand-rolled printf-built JSON line needs verified.
field_is() {
  local f="$1" expr="$2" desc="$3" line
  line="$(last_trace_line "$f")"
  if [ -z "$line" ]; then
    bad "$desc (no trace line found in $f)"
    return
  fi
  if printf '%s' "$line" | jq -e "$expr" >/dev/null 2>&1; then
    ok "$desc"
  else
    bad "$desc (line: $line)"
  fi
}

# --- fixtures (mirrors test/heimdall-429-detect.test.sh's own shapes) --------
FRESH_429_TS=$(iso_ts_offset -10)

write_fresh_429() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file1.txt","is_error":false}]}}
{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"requestId":"req_test_trace_fresh_429","timestamp":"$FRESH_429_TS"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF
}
write_clean() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"12 passing","is_error":false}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE. 12 passing."}]}}
EOF
}
write_prose_transcript() {
  # $1 = output path, $2 = timestamp (ISO), $3 = summary text, $4 = task id
  local path="$1" ts="$2" summary="$3" id="$4" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>failed</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TRANSCRIPTS" "$id" "$summary")"
  jq -nc --arg c "$body" --arg s "test-session-fixture" --arg ts "$ts" \
    '{type:"queue-operation", operation:"enqueue", timestamp:$ts, sessionId:$s, content:$c}' > "$path"
}

FRESH_429_TRANSCRIPT="$TRANSCRIPTS/fresh-429.jsonl"; write_fresh_429 "$FRESH_429_TRANSCRIPT"
CLEAN_TRANSCRIPT="$TRANSCRIPTS/clean.jsonl";         write_clean "$CLEAN_TRANSCRIPT"

# REAL verbatim production string (2026-09-06): hour-only reset, no ":MM" --
# same fixture test/heimdall-429-detect.test.sh:329 uses for its own Tier 3
# case 19.
FRESH_PROSE_429_SUMMARY="Agent terminated early due to an API error: You've hit your session limit · resets 2pm (Asia/Calcutta)"
PROSE_FRESH_TS=$(iso_ts_offset -10)
FRESH_PROSE_429_TRANSCRIPT="$TRANSCRIPTS/fresh-prose-429.jsonl"
write_prose_transcript "$FRESH_PROSE_429_TRANSCRIPT" "$PROSE_FRESH_TS" "$FRESH_PROSE_429_SUMMARY" "task-fresh-prose-429"

# --- 2. Trace ON by default + real fresh 429 (SubagentStop) -> marker AND ----
#        a fully-correct trace line
reset_marker; reset_trace
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp, last_assistant_message:"DONE"}')
run_hook "$PAYLOAD"
if marker_exists; then
  ok "trace ON by default: real 429 via agent_transcript_path still writes a marker"
else
  bad "trace ON by default: real 429 via agent_transcript_path did NOT write a marker -- tracing must never change detection"
fi
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  ok "trace file created at the default path with no opt-in env var set"
  field_is "$TRACE_FILE_DEFAULT" '.ts != null and (.ts | type == "string") and (.ts | length > 0)' "trace line: ts is a non-empty string"
  field_is "$TRACE_FILE_DEFAULT" '.hook_event_name == "subagentstop"' "trace line: hook_event_name == subagentstop"
  field_is "$TRACE_FILE_DEFAULT" '.had_agent_transcript_path == true' "trace line: had_agent_transcript_path == true (JSON boolean, not string)"
  field_is "$TRACE_FILE_DEFAULT" '.had_transcript_path == false' "trace line: had_transcript_path == false (JSON boolean, not string)"
  field_is "$TRACE_FILE_DEFAULT" '.tier1_examined == 1' "trace line: tier1_examined == 1 (JSON number)"
  field_is "$TRACE_FILE_DEFAULT" '.tier2_examined == 0' "trace line: tier2_examined == 0"
  field_is "$TRACE_FILE_DEFAULT" '.tier3_examined == 0' "trace line: tier3_examined == 0"
  field_is "$TRACE_FILE_DEFAULT" '.outcome == "marked"' "trace line: outcome == marked"
  field_is "$TRACE_FILE_DEFAULT" '.detail == "subagentstop-transcript-429"' "trace line: detail == subagentstop-transcript-429"
else
  bad "trace file was NOT created at $TRACE_FILE_DEFAULT with no opt-in env var set -- default-ON is broken"
fi

# --- 3. Trace explicitly OFF + real fresh 429 (Stop) -> marker written, ------
#        NO trace file at all
reset_marker; reset_trace
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp, last_assistant_message:"DONE"}')
( cd "$SANDBOX" && export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_TRACE=0; printf '%s' "$PAYLOAD" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" >/dev/null 2>&1 )
marker_exists && ok "trace explicitly OFF (HMD_429_DETECT_TRACE=0): real 429 still writes a marker" \
  || bad "trace explicitly OFF: real 429 failed to write a marker -- disabling tracing must never disable detection"
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  bad "trace explicitly OFF: a trace file was created anyway ($TRACE_FILE_DEFAULT exists)"
else
  ok "trace explicitly OFF: no trace file was created at all"
fi

# --- 4. Trace default (var genuinely unset) + clean/no-429 (Stop) -----------
#        -> a trace line with outcome=no-match, no marker. Concrete proof the
#        default is opt-OUT: nothing here requests tracing, yet a line lands.
reset_marker; reset_trace
PAYLOAD=$(jq -cn --arg tp "$CLEAN_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp, last_assistant_message:"DONE. 12 passing."}')
run_hook "$PAYLOAD"
marker_exists && bad "clean transcript incorrectly wrote a marker" || ok "clean transcript writes no marker"
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  ok "default (env var unset): trace line lands even for a no-match outcome"
  field_is "$TRACE_FILE_DEFAULT" '.outcome == "no-match"' "trace line: outcome == no-match"
  field_is "$TRACE_FILE_DEFAULT" '.hook_event_name == "stop"' "trace line: hook_event_name == stop"
  field_is "$TRACE_FILE_DEFAULT" '.tier1_examined == 1' "trace line: tier1_examined == 1 (scan was attempted)"
  field_is "$TRACE_FILE_DEFAULT" '.tier2_examined == 0' "trace line: tier2_examined == 0 (no sibling dir present)"
  field_is "$TRACE_FILE_DEFAULT" '.tier3_examined == 0' "trace line: tier3_examined == 0 (no prose candidates)"
else
  bad "default (env var unset): no trace line was written for a no-match outcome -- default-ON claim unproven"
fi

# --- 5. jq unavailable -> trace line STILL written (printf-only, no jq) -----
reset_marker; reset_trace
NOJQ_DIR="$SANDBOX/nojq-path"
mkdir -p "$NOJQ_DIR"
for tool in bash sh cat tail tr dirname readlink mktemp basename env; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$NOJQ_DIR/$tool" 2>/dev/null
done
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
RC=0
( cd "$SANDBOX" && export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" PATH="$NOJQ_DIR"; printf '%s' "$PAYLOAD" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 0 ] && ok "jq-unavailable case exits 0" || bad "jq-unavailable case exited $RC, expected 0"
marker_exists && bad "jq-unavailable case incorrectly wrote a marker" || ok "jq-unavailable case writes no marker (fails open)"
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  ok "jq unavailable: trace line still written (printf + redirection are PATH-independent bash builtins)"
  field_is "$TRACE_FILE_DEFAULT" '.outcome == "skipped-no-jq"' "trace line: outcome == skipped-no-jq"
  field_is "$TRACE_FILE_DEFAULT" '.hook_event_name == ""' "trace line: hook_event_name == \"\" (script exited before it could be read)"
  field_is "$TRACE_FILE_DEFAULT" '.had_agent_transcript_path == null' "trace line: had_agent_transcript_path == null (JSON null, never computed)"
  field_is "$TRACE_FILE_DEFAULT" '.had_transcript_path == null' "trace line: had_transcript_path == null"
  field_is "$TRACE_FILE_DEFAULT" '.tier1_examined == 0 and .tier2_examined == 0 and .tier3_examined == 0' "trace line: all tier counters 0"
else
  bad "jq unavailable: no trace line was written -- trace_emit must not depend on jq"
fi

# --- 6. Unwritable trace path -> hook still exits 0, STILL marks correctly --
reset_marker
BLOCKED_PARENT="$SANDBOX/blocked-trace-parent"
printf 'a plain file occupies this path, not a directory' > "$BLOCKED_PARENT"
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
RC=0
( cd "$SANDBOX" && export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_TRACE_FILE="$BLOCKED_PARENT/429-detect-trace.jsonl"; printf '%s' "$PAYLOAD" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 0 ] && ok "unwritable trace path: hook still exits 0" || bad "unwritable trace path: hook exited $RC, expected 0"
marker_exists && ok "unwritable trace path: marker STILL written correctly (mark and trace are independent code paths)" \
  || bad "unwritable trace path: marker was NOT written -- a trace failure must never suppress a real detection"
[ -f "$BLOCKED_PARENT" ] && [ ! -d "$BLOCKED_PARENT" ] && ok "unwritable trace path: blocked parent is still a plain file, untouched" \
  || bad "unwritable trace path: blocked parent was unexpectedly altered"

# --- 7. size-cap/rotation: bounded growth ------------------------------------
reset_marker; reset_trace
PADDING_LINE='{"ts":"padding","hook_event_name":"padding","had_agent_transcript_path":false,"had_transcript_path":false,"tier1_examined":0,"tier2_examined":0,"tier3_examined":0,"outcome":"padding-line-for-rotation-test-only","detail":"filler"}'
for _i in $(seq 1 40); do printf '%s\n' "$PADDING_LINE" >> "$TRACE_FILE_DEFAULT"; done
PRESEED_SIZE=$(wc -c < "$TRACE_FILE_DEFAULT" | tr -d ' ')
PAYLOAD=$(jq -cn --arg tp "$CLEAN_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
( cd "$SANDBOX" && export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_TRACE_MAX_BYTES=2000; printf '%s' "$PAYLOAD" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" >/dev/null 2>&1 )
FINAL_SIZE=$(wc -c < "$TRACE_FILE_DEFAULT" 2>/dev/null | tr -d ' ')
if [ "$PRESEED_SIZE" -gt 2000 ] && [ "${FINAL_SIZE:-999999}" -le 2000 ]; then
  ok "size-cap/rotation: pre-seeded file ($PRESEED_SIZE bytes) trimmed to bounded size ($FINAL_SIZE bytes <= 2000 cap)"
else
  bad "size-cap/rotation: expected bounded growth, got preseed=$PRESEED_SIZE final=${FINAL_SIZE:-<missing>} (cap=2000)"
fi

# --- 8. multiple invocations append, never overwrite -------------------------
reset_marker; reset_trace
PAYLOAD=$(jq -cn --arg tp "$CLEAN_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD"
run_hook "$PAYLOAD"
run_hook "$PAYLOAD"
LINE_COUNT=$(wc -l < "$TRACE_FILE_DEFAULT" 2>/dev/null | tr -d ' ')
if [ "${LINE_COUNT:-0}" -ge 3 ]; then
  ok "three invocations produced $LINE_COUNT trace lines (append, not overwrite)"
else
  bad "three invocations produced only ${LINE_COUNT:-0} trace lines -- expected >= 3 (overwrite instead of append?)"
fi

# --- 9. HMD_429_DETECT_TRACE_FILE override is honored ------------------------
reset_marker; reset_trace
CUSTOM_TRACE_FILE="$SANDBOX/custom-trace-dir/custom.jsonl"
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
( cd "$SANDBOX" && export HEIMDALL_HOME="$HEIMDALL_HOME_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_TRACE_FILE="$CUSTOM_TRACE_FILE"; printf '%s' "$PAYLOAD" | bash "$PLUGIN/hooks/heimdall-429-detect.sh" --repo "$PROJECT" >/dev/null 2>&1 )
if [ -f "$CUSTOM_TRACE_FILE" ]; then
  ok "HMD_429_DETECT_TRACE_FILE override: custom path received the trace line (and its parent dir was created)"
  field_is "$CUSTOM_TRACE_FILE" '.outcome == "marked"' "custom-path trace line: outcome == marked"
else
  bad "HMD_429_DETECT_TRACE_FILE override: custom path $CUSTOM_TRACE_FILE was never created"
fi
[ -f "$TRACE_FILE_DEFAULT" ] && bad "HMD_429_DETECT_TRACE_FILE override: default path was ALSO written -- override should redirect, not duplicate" \
  || ok "HMD_429_DETECT_TRACE_FILE override: default path correctly untouched"

# --- 10. Tier 2 sibling scan increments tier2_examined, marks via sibling ----
reset_marker; reset_trace
PARENT_FOR_SIBLING="$TRANSCRIPTS/parent-for-sibling.jsonl"
write_clean "$PARENT_FOR_SIBLING"
SIBLING_DIR="$TRANSCRIPTS/parent-for-sibling/subagents"
mkdir -p "$SIBLING_DIR"
write_fresh_429 "$SIBLING_DIR/agent-sibling-1.jsonl"
PAYLOAD=$(jq -cn --arg tp "$PARENT_FOR_SIBLING" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD"
if marker_exists; then
  ok "tier2 sibling scan: marker written via a sibling transcript, parent itself clean"
  R=$(marker_reason)
  [ "$R" = "stop-sibling-transcript-429" ] && ok "tier2 sibling scan: marker reason carries the -sibling suffix (got: $R)" \
    || bad "tier2 sibling scan: unexpected marker reason (got: $R)"
else
  bad "tier2 sibling scan: failed to mark despite a fresh 429 in the sibling subagents/ dir"
fi
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  field_is "$TRACE_FILE_DEFAULT" '.tier1_examined == 1' "tier2 sibling scan: tier1_examined == 1 (parent scanned first, found nothing)"
  field_is "$TRACE_FILE_DEFAULT" '.tier2_examined >= 1' "tier2 sibling scan: tier2_examined >= 1 (sibling file was examined)"
  field_is "$TRACE_FILE_DEFAULT" '.outcome == "marked"' "tier2 sibling scan: trace outcome == marked"
  field_is "$TRACE_FILE_DEFAULT" '.detail == "stop-sibling-transcript-429"' "tier2 sibling scan: trace detail == stop-sibling-transcript-429"
else
  bad "tier2 sibling scan: no trace line was written at all"
fi

# --- 11. Tier 3 prose scan increments tier3_examined, marks via prose -------
reset_marker; reset_trace
PAYLOAD=$(jq -cn --arg tp "$FRESH_PROSE_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD"
if marker_exists; then
  ok "tier3 prose scan: marker written via the real verbatim hour-only reset-clause string"
  R=$(marker_reason)
  [ "$R" = "stop-prose-transcript-429" ] && ok "tier3 prose scan: marker reason carries the -prose suffix (got: $R)" \
    || bad "tier3 prose scan: unexpected marker reason (got: $R)"
else
  bad "tier3 prose scan: failed to mark despite a fresh prose-only 429"
fi
if [ -f "$TRACE_FILE_DEFAULT" ]; then
  field_is "$TRACE_FILE_DEFAULT" '.tier1_examined == 1' "tier3 prose scan: tier1_examined == 1 (structural scan attempted first)"
  field_is "$TRACE_FILE_DEFAULT" '.tier2_examined == 0' "tier3 prose scan: tier2_examined == 0 (no sibling dir for this parent path)"
  field_is "$TRACE_FILE_DEFAULT" '.tier3_examined >= 1' "tier3 prose scan: tier3_examined >= 1 (prose candidate was examined)"
  field_is "$TRACE_FILE_DEFAULT" '.outcome == "marked"' "tier3 prose scan: trace outcome == marked"
  field_is "$TRACE_FILE_DEFAULT" '.detail == "stop-prose-transcript-429"' "tier3 prose scan: trace detail == stop-prose-transcript-429"
else
  bad "tier3 prose scan: no trace line was written at all"
fi

echo "--------------------------------------------------------------------"
echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
