#!/usr/bin/env bash
# test/heimdall-429-detect.test.sh -- hermetic tests for
# hooks/heimdall-429-detect.sh, the mechanical SubagentStop/Stop 429 detector
# that closes task brief brief-1788288873-84149's gap: an in-process
# Agent-tool spawn's 429 reaches the ORCHESTRATOR only as a task-notification,
# never a hook, so nothing ever called bin/heimdall-429-mark's reactive
# marker for that path (see docs/analysis/2026-08-29-fallback-did-not-fire-
# rootcause.md, .planning/skills/subagent-stop-delivery-scope.md). Every fix
# upstream of this (PHASE 1-4 in bin/heimdall-session-usage,
# bin/heimdall-fallback's PHASE-4 read) already existed and already worked;
# this hook is the missing WRITE side.
#
# THE SIGNAL UNDER TEST: Claude Code writes a structural, closed-enum record
# into a transcript JSONL on any failed model call --
#   {"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,...}
# -- reached via agent_transcript_path (SubagentStop) or transcript_path
# (Stop). SubagentStop/Stop's own TOP-LEVEL payload fields carry no
# stop-reason/error-type of any kind (confirmed against the official hooks
# reference and this repo's 2026-08-25 hook-delivery spike) -- only the
# transcript proves it.
#
# FALSIFIABLE CLAIMS TESTED (never a heuristic -- structural match only):
#  1. hooks.json is valid JSON; SubagentStop and Stop each carry exactly one
#     entry invoking heimdall-429-detect.sh (found by BEHAVIOUR, never index)
#     -- and their PRE-EXISTING owners (heimdall-metric-hook,
#     heimdall-metric-reminder.sh, heimdall-claim-check) are still present:
#     this hook must ADD, never replace.
#  2. hooks/heimdall-429-detect.sh is executable and parses (bash -n).
#  3. real 429 via agent_transcript_path -> marker written, reason exactly
#     reflects hook_event_name=SubagentStop.
#  4. real 429 via transcript_path fallback (Stop shape, no
#     agent_transcript_path key) -> marker written, reason exactly reflects
#     hook_event_name=Stop.
#  5. clean/normal completion (no isApiErrorMessage records at all) -> no
#     marker.
#  6. non-429 API error (server_error/529) -> no marker (never a heuristic
#     that "any API error" means rate-limited).
#  7. non-429 API error (oauth_org_not_allowed/403) -> no marker.
#  8. STALE 429 record (older than the recency window) -> no marker.
#  9. malformed/garbage stdin -> exit 0, no marker, no crash.
# 10. missing/nonexistent transcript path -> exit 0, no marker.
# 11. both transcript-path fields absent -> exit 0, no marker.
# 12. transcript path is a directory, not a file -> exit 0, no marker.
# 13. unreadable transcript file (chmod 000) -> exit 0, no marker.
# 14. jq unavailable on PATH -> exit 0, no marker (fails open).
# 15. multiple records (stale 429 + fresh 529 + ordinary tool error + fresh
#     429, in that order) -> still correctly marks on the one genuine fresh
#     429, undistracted by noise.
# 16. HMD_429_MARK_BIN override is honored -- proves the hook NEVER
#     reimplements the marker itself, it only ever shells out to
#     bin/heimdall-429-mark's own `mark --reason <slug>` contract.
# 17. HMD_429_DETECT_WINDOW_SECS override is honored (widens the window
#     enough to mark on an otherwise-stale record).
# 18. HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES override is honored (shrinking it
#     enough to miss a record the default tail size would have found, with a
#     same-fixture default-settings baseline proving it isn't just broken).
#
# TIER 3 (2026-09-06): parent-transcript PROSE scan, the one exception to
# "structural only" -- classified via the real bin/lib/quota_stop.py
# classifier, never a bash/jq substring match. Closes the gap where seven
# real subagent-death 429s left NO structural record anywhere and the only
# trace was PROSE in the orchestrator's own Stop-triggered transcript (180
# accumulated occurrences measured via a direct grep against a real session
# jsonl).
# 19. FRESH prose-only 429 -- the REAL verbatim hour-only string ("resets
#     2pm", no minutes), zero structural record anywhere -- writes a marker
#     via the Stop path, reason carries the -prose suffix.
# 20. FRESH prose-only 429 with a minutes-present reset clause also writes a
#     marker (no regression against the hour-only fix).
# 21. STALE prose-only 429 (older than the recency window) -> no marker --
#     the single most important case given 180 already-accumulated
#     historical occurrences: recency is enforced per CANDIDATE LINE, not
#     just once per hook invocation.
# 22. Prose anchor present, reset clause absent -> no marker (the
#     classifier's reset-clause requirement holds all the way through the
#     hook, not just at the classify() level).
# 23. 529/overload prose (no quota anchor at all) -> no marker.
# 24. SubagentStop path (agent_transcript_path present) never runs the Tier
#     3 prose scan, even given byte-identical fresh prose content -- a dying
#     subagent's own transcript cannot structurally contain a
#     task-notification about itself, so this stays Stop-only.
# 25. HMD_QUOTA_STOP_PY override is honored -- a fake classifier is actually
#     invoked (proven by a sentinel file), and the hook honors its "unknown"
#     verdict rather than silently falling back to the real classifier.
# 26. Tier 3 is strictly last-resort: a fresh STRUCTURAL 429 alongside an
#     unrelated fresh PROSE 429 in the same transcript marks via Tier 1
#     (reason has no -prose suffix) -- tier order is real, not incidental.
#
# Usage: bash test/heimdall-429-detect.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
HOOK_SRC="$REPO/hooks/heimdall-429-detect.sh"
MARK_SRC="$REPO/bin/heimdall-429-mark"
QUOTA_STOP_SRC="$REPO/bin/lib/quota_stop.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "heimdall-429-detect harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "  python3 is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi

# --- 1. hooks.json is valid JSON ---------------------------------------------
if jq . "$HOOKS" >/dev/null 2>&1; then
  ok "hooks.json is valid JSON"
else
  bad "hooks.json is not valid JSON -- nothing below is meaningful"
  echo "--------------------------------------------------------------------"
  echo "RESULT: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# --- wiring, found by BEHAVIOUR never array index ----------------------------
for EVENT in SubagentStop Stop; do
  N=$(jq -r --arg e "$EVENT" '
    [(.hooks[$e] // [])[]
     | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-429-detect.sh"))))]
    | length' "$HOOKS")
  if [ "$N" = "1" ]; then
    ok "$EVENT carries exactly one entry invoking heimdall-429-detect.sh"
  else
    bad "$EVENT: expected exactly 1 matching entry, found $N"
  fi
done

# collateral: this hook must ADD, never REPLACE, the pre-existing owners.
OWNS_METRIC=$(jq -r '
  [(.hooks.SubagentStop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-hook"))))]
  | length' "$HOOKS")
[ "$OWNS_METRIC" = "1" ] && ok "SubagentStop still carries its pre-existing heimdall-metric-hook entry" \
  || bad "SubagentStop's pre-existing heimdall-metric-hook entry was lost or duplicated ($OWNS_METRIC)"

OWNS_REMINDER=$(jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-reminder.sh"))))]
  | length' "$HOOKS")
[ "$OWNS_REMINDER" = "1" ] && ok "Stop still carries its pre-existing heimdall-metric-reminder.sh entry" \
  || bad "Stop's pre-existing heimdall-metric-reminder.sh entry was lost or duplicated ($OWNS_REMINDER)"

OWNS_CLAIM=$(jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-claim-check"))))]
  | length' "$HOOKS")
[ "$OWNS_CLAIM" = "1" ] && ok "Stop still carries its pre-existing heimdall-claim-check entry" \
  || bad "Stop's pre-existing heimdall-claim-check entry was lost or duplicated ($OWNS_CLAIM)"

if [ ! -x "$HOOK_SRC" ]; then
  bad "hooks/heimdall-429-detect.sh is not executable -- cannot prove end-to-end"
  echo "--------------------------------------------------------------------"
  echo "RESULT: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
bash -n "$HOOK_SRC" && ok "hooks/heimdall-429-detect.sh parses (bash -n)" || bad "hooks/heimdall-429-detect.sh has a syntax error"

# --- extract the exact command strings hooks.json actually runs -------------
SUBAGENTSTOP_CMD_FILE="$(mktemp "${TMPDIR:-/tmp}/hmd-429-detect-cmd-sas.XXXXXX")"
STOP_CMD_FILE="$(mktemp "${TMPDIR:-/tmp}/hmd-429-detect-cmd-stop.XXXXXX")"
jq -r '
  [(.hooks.SubagentStop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-429-detect.sh"))))]
  | .[0].hooks[0].command' "$HOOKS" > "$SUBAGENTSTOP_CMD_FILE"
jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-429-detect.sh"))))]
  | .[0].hooks[0].command' "$HOOKS" > "$STOP_CMD_FILE"

[ -s "$SUBAGENTSTOP_CMD_FILE" ] && ok "SubagentStop entry has a non-empty command" || bad "SubagentStop entry command is empty"
[ -s "$STOP_CMD_FILE" ] && ok "Stop entry has a non-empty command" || bad "Stop entry command is empty"

# --- sandbox: a fake plugin install (hooks/ + bin/) --------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-429-detect.XXXXXX")"
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

iso_ts_offset() {
  # $1 = signed seconds offset from now (e.g. -10 = 10s ago). Delegates to
  # python3 exactly like test/heimdall-429-mark.test.sh's own case 9/12
  # fixtures, sidestepping BSD `date -v` vs GNU `date -d` divergence -- the
  # same reason the detector itself computes age entirely inside jq.
  python3 -c "import time,sys; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()+float(sys.argv[1]))))" "$1"
}

run_hook() {
  # $1 = payload json (stdin). $2 = "Stop" to route through the Stop-array
  # wrapper instead of SubagentStop's (default). export inside this subshell
  # so the wrapper's own CLAUDE_PLUGIN_ROOT lookup sees it -- a `VAR=val \`
  # pipeline prefix would only scope to `printf`, never reach `bash
  # "$cmdfile"` (same caveat test/heimdall-metric-hook.test.sh documents for
  # its own run_hook()).
  local cmdfile="$SUBAGENTSTOP_CMD_FILE"
  [ "${2:-}" = "Stop" ] && cmdfile="$STOP_CMD_FILE"
  (
    cd "$SANDBOX" || exit 1
    unset HEIMDALL_HOME
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    export CLAUDE_PROJECT_DIR="$PROJECT"
    export HEIMDALL_429_MARKER_FILE="$MARKER"
    printf '%s' "$1" | bash "$cmdfile" > /dev/null 2> "$SANDBOX/stderr.log"
  )
}

marker_exists() { [ -f "$MARKER" ]; }
marker_reason() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('reason',''))" "$MARKER" 2>/dev/null || true; }
reset_marker() { rm -f "$MARKER"; }

# --- fixture transcripts ------------------------------------------------------
FRESH_429_TS=$(iso_ts_offset -10)
STALE_429_TS=$(iso_ts_offset -999999)
FRESH_529_TS=$(iso_ts_offset -10)
FRESH_403_TS=$(iso_ts_offset -10)

write_fresh_429() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file1.txt","is_error":false}]}}
{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"requestId":"req_test_fresh_429","timestamp":"$FRESH_429_TS"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF
}
write_stale_429() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"requestId":"req_test_stale_429","timestamp":"$STALE_429_TS"}
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
write_fresh_529() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"isApiErrorMessage":true,"error":"server_error","apiErrorStatus":529,"requestId":"req_test_529","timestamp":"$FRESH_529_TS"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF
}
write_fresh_403() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"isApiErrorMessage":true,"error":"oauth_org_not_allowed","apiErrorStatus":403,"requestId":"req_test_403","timestamp":"$FRESH_403_TS"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF
}
write_mixed() {
  cat > "$1" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"requestId":"req_test_old_429","timestamp":"$STALE_429_TS"}
{"isApiErrorMessage":true,"error":"server_error","apiErrorStatus":529,"requestId":"req_test_mixed_529","timestamp":"$FRESH_529_TS"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"Exit code 1","is_error":true}]}}
{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"requestId":"req_test_mixed_fresh_429","timestamp":"$FRESH_429_TS"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF
}

MALFORMED_TRANSCRIPT="$TRANSCRIPTS/malformed.jsonl"
printf 'not json at all {{{\nrandom garbage line\n' > "$MALFORMED_TRANSCRIPT"

FRESH_429_TRANSCRIPT="$TRANSCRIPTS/fresh-429.jsonl";  write_fresh_429 "$FRESH_429_TRANSCRIPT"
STALE_429_TRANSCRIPT="$TRANSCRIPTS/stale-429.jsonl";  write_stale_429 "$STALE_429_TRANSCRIPT"
CLEAN_TRANSCRIPT="$TRANSCRIPTS/clean.jsonl";           write_clean "$CLEAN_TRANSCRIPT"
FRESH_529_TRANSCRIPT="$TRANSCRIPTS/fresh-529.jsonl";  write_fresh_529 "$FRESH_529_TRANSCRIPT"
FRESH_403_TRANSCRIPT="$TRANSCRIPTS/fresh-403.jsonl";  write_fresh_403 "$FRESH_403_TRANSCRIPT"
MIXED_TRANSCRIPT="$TRANSCRIPTS/mixed.jsonl";           write_mixed "$MIXED_TRANSCRIPT"

# --- Tier 3 fixtures: PROSE-ONLY transcripts, zero structural records at all,
# shaped exactly like a real queue-operation task-notification (the same
# shape test/heimdall-agent-resume.test.sh's mk_notif2() already models for
# this repo's real parent-transcript records).
write_prose_transcript() {
  # $1 = output path, $2 = timestamp (ISO), $3 = summary text, $4 = task id
  local path="$1" ts="$2" summary="$3" id="$4" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>failed</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TRANSCRIPTS" "$id" "$summary")"
  jq -nc --arg c "$body" --arg s "test-session-fixture" --arg ts "$ts" \
    '{type:"queue-operation", operation:"enqueue", timestamp:$ts, sessionId:$s, content:$c}' > "$path"
}

PROSE_FRESH_TS=$(iso_ts_offset -10)
PROSE_STALE_TS=$(iso_ts_offset -999999)

# REAL verbatim production string (2026-09-06): hour-only reset, no ":MM" --
# the exact shape that was silently un-classifiable before the quota_stop.py
# RESET_RE fix landed.
FRESH_PROSE_429_SUMMARY="Agent terminated early due to an API error: You've hit your session limit · resets 2pm (Asia/Calcutta)"
FRESH_PROSE_MINUTES_SUMMARY="Agent terminated early due to an API error: You've hit your usage limit · resets 5:40pm (Asia/Calcutta)"
PROSE_NO_RESET_SUMMARY="Agent terminated early due to an API error: You've hit your session limit for this billing period."
PROSE_529_SUMMARY="Agent terminated early due to an API error: 529 Overloaded, please retry your request"

FRESH_PROSE_429_TRANSCRIPT="$TRANSCRIPTS/fresh-prose-429.jsonl"
write_prose_transcript "$FRESH_PROSE_429_TRANSCRIPT" "$PROSE_FRESH_TS" "$FRESH_PROSE_429_SUMMARY" "task-fresh-prose-429"

STALE_PROSE_429_TRANSCRIPT="$TRANSCRIPTS/stale-prose-429.jsonl"
write_prose_transcript "$STALE_PROSE_429_TRANSCRIPT" "$PROSE_STALE_TS" "$FRESH_PROSE_429_SUMMARY" "task-stale-prose-429"

FRESH_PROSE_MINUTES_TRANSCRIPT="$TRANSCRIPTS/fresh-prose-minutes.jsonl"
write_prose_transcript "$FRESH_PROSE_MINUTES_TRANSCRIPT" "$PROSE_FRESH_TS" "$FRESH_PROSE_MINUTES_SUMMARY" "task-fresh-prose-minutes"

PROSE_NO_RESET_TRANSCRIPT="$TRANSCRIPTS/prose-no-reset.jsonl"
write_prose_transcript "$PROSE_NO_RESET_TRANSCRIPT" "$PROSE_FRESH_TS" "$PROSE_NO_RESET_SUMMARY" "task-prose-no-reset"

PROSE_529_TRANSCRIPT="$TRANSCRIPTS/prose-529.jsonl"
write_prose_transcript "$PROSE_529_TRANSCRIPT" "$PROSE_FRESH_TS" "$PROSE_529_SUMMARY" "task-prose-529"

# A fresh STRUCTURAL 429 alongside an unrelated fresh PROSE 429 in the same
# file -- Tier 1 must win; Tier 3 must never even be consulted once Tier 1
# already found a match (tier order is real, not incidental).
write_structural_plus_prose() {
  local path="$1" prose_body
  write_fresh_429 "$path"
  prose_body="$(printf '<task-notification>\n<task-id>task-mixed-tier</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/task-mixed-tier.output</output-file>\n<status>failed</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$TRANSCRIPTS" "$FRESH_PROSE_429_SUMMARY")"
  jq -nc --arg c "$prose_body" --arg s "test-session-fixture" --arg ts "$PROSE_FRESH_TS" \
    '{type:"queue-operation", operation:"enqueue", timestamp:$ts, sessionId:$s, content:$c}' >> "$path"
}
STRUCTURAL_PLUS_PROSE_TRANSCRIPT="$TRANSCRIPTS/structural-plus-prose.jsonl"
write_structural_plus_prose "$STRUCTURAL_PLUS_PROSE_TRANSCRIPT"

# --- 3. real 429 via agent_transcript_path -> marker written -----------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp, last_assistant_message:"DONE"}')
run_hook "$PAYLOAD" SubagentStop
if marker_exists; then
  ok "real 429 via agent_transcript_path writes a marker"
  R=$(marker_reason)
  [ "$R" = "subagentstop-transcript-429" ] && ok "marker reason exactly reflects hook_event_name=SubagentStop (got: $R)" \
    || bad "marker reason mismatch for SubagentStop (got: $R)"
else
  bad "real 429 via agent_transcript_path did NOT write a marker"
fi

# --- 4. real 429 via transcript_path fallback (Stop shape) -------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp, last_assistant_message:"DONE"}')
run_hook "$PAYLOAD" Stop
if marker_exists; then
  ok "real 429 via transcript_path (Stop shape, no agent_transcript_path key) writes a marker"
  R=$(marker_reason)
  [ "$R" = "stop-transcript-429" ] && ok "marker reason exactly reflects hook_event_name=Stop (got: $R)" \
    || bad "marker reason mismatch for Stop (got: $R)"
else
  bad "real 429 via transcript_path fallback did NOT write a marker"
fi

# --- 5. clean completion -> no marker -----------------------------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$CLEAN_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp, last_assistant_message:"DONE"}')
run_hook "$PAYLOAD"
marker_exists && bad "clean transcript incorrectly wrote a marker" \
  || ok "clean transcript (no isApiErrorMessage records) writes no marker"

# --- 6. non-429 API error (server_error/529) -> no marker ---------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_529_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
marker_exists && bad "server_error/529 incorrectly wrote a marker (rate_limit-only rule violated)" \
  || ok "server_error/529 (fresh, real API error) writes no marker -- never a heuristic"

# --- 7. non-429 API error (oauth_org_not_allowed/403) -> no marker ------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_403_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
marker_exists && bad "oauth_org_not_allowed/403 incorrectly wrote a marker" \
  || ok "oauth_org_not_allowed/403 (fresh, real API error) writes no marker"

# --- 8. STALE 429 (outside recency window) -> no marker -----------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$STALE_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
marker_exists && bad "stale 429 (999999s old) incorrectly wrote a marker -- recency bound violated" \
  || ok "stale 429 outside the default recency window writes no marker"

# --- 9. malformed/garbage stdin -> exit 0, no marker, no crash ----------------
reset_marker
RC=0
run_hook 'not-json-at-all {{{' || RC=$?
[ "$RC" -eq 0 ] && ok "malformed stdin exits 0" || bad "malformed stdin exited $RC, expected 0"
marker_exists && bad "malformed stdin incorrectly wrote a marker" || ok "malformed stdin writes no marker"

# --- 10. missing/nonexistent transcript path -> exit 0, no marker ------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$TRANSCRIPTS/does-not-exist.jsonl" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
RC=0
run_hook "$PAYLOAD" || RC=$?
[ "$RC" -eq 0 ] && ok "nonexistent transcript path exits 0" || bad "nonexistent transcript path exited $RC, expected 0"
marker_exists && bad "nonexistent transcript path incorrectly wrote a marker" || ok "nonexistent transcript path writes no marker"

# --- 11. both transcript-path fields absent -> exit 0, no marker -------------
reset_marker
PAYLOAD=$(jq -cn '{hook_event_name:"SubagentStop", last_assistant_message:"DONE"}')
RC=0
run_hook "$PAYLOAD" || RC=$?
[ "$RC" -eq 0 ] && ok "payload with neither transcript-path field exits 0" || bad "no-transcript-field payload exited $RC, expected 0"
marker_exists && bad "no-transcript-field payload incorrectly wrote a marker" || ok "payload with neither transcript-path field writes no marker"

# --- 12. transcript path is a directory, not a file -> exit 0, no marker -----
reset_marker
PAYLOAD=$(jq -cn --arg tp "$TRANSCRIPTS" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
RC=0
run_hook "$PAYLOAD" || RC=$?
[ "$RC" -eq 0 ] && ok "transcript path that is a directory exits 0" || bad "directory transcript path exited $RC, expected 0"
marker_exists && bad "directory transcript path incorrectly wrote a marker" || ok "transcript path that is a directory writes no marker"

# --- 13. unreadable transcript file (chmod 000) -> exit 0, no marker --------
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP unreadable-file case: running as root, permission bits are not enforced"
else
  reset_marker
  UNREADABLE="$TRANSCRIPTS/unreadable.jsonl"
  write_fresh_429 "$UNREADABLE"
  chmod 000 "$UNREADABLE"
  PAYLOAD=$(jq -cn --arg tp "$UNREADABLE" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
  RC=0
  run_hook "$PAYLOAD" || RC=$?
  [ "$RC" -eq 0 ] && ok "unreadable transcript file exits 0" || bad "unreadable transcript file exited $RC, expected 0"
  marker_exists && bad "unreadable transcript file incorrectly wrote a marker" || ok "unreadable transcript file (chmod 000) writes no marker"
  chmod 644 "$UNREADABLE"
fi

# --- 14. jq unavailable on PATH -> exit 0, no marker (fails open) ------------
reset_marker
NOJQ_DIR="$SANDBOX/nojq-path"
mkdir -p "$NOJQ_DIR"
for tool in bash sh cat tail tr dirname readlink mktemp basename env; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$NOJQ_DIR/$tool" 2>/dev/null
done
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
RC=0
( cd "$SANDBOX" && unset HEIMDALL_HOME && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" PATH="$NOJQ_DIR"; printf '%s' "$PAYLOAD" | bash "$SUBAGENTSTOP_CMD_FILE" >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 0 ] && ok "jq unavailable on PATH exits 0" || bad "jq-unavailable case exited $RC, expected 0"
marker_exists && bad "jq-unavailable case incorrectly wrote a marker" || ok "jq unavailable on PATH writes no marker (fails open)"

# --- 15. multiple records, only one fresh 429 mixed with noise -> marks -----
reset_marker
PAYLOAD=$(jq -cn --arg tp "$MIXED_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
marker_exists && ok "mixed transcript (stale 429 + fresh 529 + ordinary tool error + fresh 429) correctly marks on the genuine fresh 429" \
  || bad "mixed transcript failed to mark despite a genuine fresh 429 present"

# --- 16. HMD_429_MARK_BIN override is honored --------------------------------
reset_marker
FAKE_MARK_BIN="$SANDBOX/fake-mark-bin.sh"
FAKE_MARK_SENTINEL="$SANDBOX/fake-mark-called.txt"
rm -f "$FAKE_MARK_SENTINEL"
cat > "$FAKE_MARK_BIN" <<FAKEEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$FAKE_MARK_SENTINEL"
exit 0
FAKEEOF
chmod +x "$FAKE_MARK_BIN"
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
( cd "$SANDBOX" && unset HEIMDALL_HOME && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_MARK_BIN="$FAKE_MARK_BIN"; printf '%s' "$PAYLOAD" | bash "$SUBAGENTSTOP_CMD_FILE" >/dev/null 2>&1 )
if [ -f "$FAKE_MARK_SENTINEL" ]; then
  ok "HMD_429_MARK_BIN override is honored -- the override binary was invoked, not the real one"
  ARGS=$(cat "$FAKE_MARK_SENTINEL")
  case "$ARGS" in
    "mark --reason subagentstop-transcript-429") ok "override invoked with the exact 'mark --reason <slug>' shape it always uses (got: $ARGS)" ;;
    *) bad "override invoked with unexpected args: $ARGS" ;;
  esac
else
  bad "HMD_429_MARK_BIN override was NOT invoked -- env var ignored"
fi
marker_exists && bad "HMD_429_MARK_BIN case: real marker file unexpectedly written (override should have replaced the real mark tool)" \
  || ok "HMD_429_MARK_BIN case: real marker file correctly untouched (fake binary intercepted the call)"

# --- 17. HMD_429_DETECT_WINDOW_SECS override is honored ----------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$STALE_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
( cd "$SANDBOX" && unset HEIMDALL_HOME && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_WINDOW_SECS=100000000; printf '%s' "$PAYLOAD" | bash "$SUBAGENTSTOP_CMD_FILE" >/dev/null 2>&1 )
marker_exists && ok "HMD_429_DETECT_WINDOW_SECS override widens the recency window -- an otherwise-stale 429 now marks" \
  || bad "HMD_429_DETECT_WINDOW_SECS override had no effect -- stale record still not marked"

# --- 18. HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES override is honored ------------
# Baseline: the SAME transcript marks under default tail-byte settings...
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
if marker_exists; then
  ok "baseline: fresh-429 transcript marks under default tail-byte window (sanity check for case 18)"
else
  bad "baseline for case 18 unexpectedly failed to mark -- cannot proceed with tail-byte override check"
fi
# ...but a tiny override that can't reach the record misses it.
reset_marker
( cd "$SANDBOX" && unset HEIMDALL_HOME && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES=5; printf '%s' "$PAYLOAD" | bash "$SUBAGENTSTOP_CMD_FILE" >/dev/null 2>&1 )
if marker_exists; then
  bad "HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES=5 still marked -- override had no effect on the bounded read"
else
  ok "HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES=5 correctly misses the record (override genuinely bounds the read)"
fi

# --- 19. FRESH prose-only 429 (real hour-only string, zero structural record) -
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_PROSE_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp, last_assistant_message:"done"}')
run_hook "$PAYLOAD" Stop
if marker_exists; then
  ok "FRESH prose-only 429 (real hour-only 'resets 2pm' string, zero structural record anywhere) writes a marker"
  R=$(marker_reason)
  [ "$R" = "stop-prose-transcript-429" ] && ok "marker reason exactly reflects the -prose tier (got: $R)" \
    || bad "marker reason mismatch for Tier 3 prose match (got: $R)"
else
  bad "FRESH prose-only 429 did NOT write a marker -- the Tier 3 gap is not actually closed"
fi

# --- 20. FRESH prose-only 429, minutes-present reset -> marker written -------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_PROSE_MINUTES_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD" Stop
marker_exists && ok "FRESH prose-only 429 (minutes-present reset clause) also writes a marker (no regression)" \
  || bad "FRESH prose-only 429 (minutes-present) failed to mark"

# --- 21. STALE prose-only 429 -> NO marker (180 accumulated records) --------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$STALE_PROSE_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD" Stop
marker_exists && bad "STALE prose-only 429 incorrectly wrote a marker -- with 180 accumulated historical occurrences this is the most dangerous possible failure" \
  || ok "STALE prose-only 429 (999999s old) writes no marker -- recency is enforced per candidate line, not just once per hook call"

# --- 22. prose anchor present, NO reset clause -> NO marker ------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$PROSE_NO_RESET_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD" Stop
marker_exists && bad "prose anchor-only (no reset clause) incorrectly wrote a marker" \
  || ok "prose anchor-only (no reset clause) writes no marker -- the classifier's reset-clause requirement holds through the hook"

# --- 23. 529/overload prose -> NO marker -------------------------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$PROSE_529_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD" Stop
marker_exists && bad "529/overload prose incorrectly wrote a marker" \
  || ok "529/overload prose (no quota anchor at all) writes no marker"

# --- 24. SubagentStop path never runs the Tier 3 prose scan ------------------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$FRESH_PROSE_429_TRANSCRIPT" '{hook_event_name:"SubagentStop", agent_transcript_path:$tp}')
run_hook "$PAYLOAD" SubagentStop
marker_exists && bad "SubagentStop path incorrectly ran the Tier 3 prose scan (should be Stop-only)" \
  || ok "SubagentStop path does not run the Tier 3 prose scan even given byte-identical fresh prose (agent_transcript_path present, correctly Stop-gated)"

# --- 25. HMD_QUOTA_STOP_PY override is honored -------------------------------
reset_marker
FAKE_QUOTA_STOP_PY="$SANDBOX/fake-quota-stop.py"
FAKE_QUOTA_STOP_SENTINEL="$SANDBOX/fake-quota-stop-called.txt"
rm -f "$FAKE_QUOTA_STOP_SENTINEL"
cat > "$FAKE_QUOTA_STOP_PY" <<FAKEPYEOF
import sys
open("$FAKE_QUOTA_STOP_SENTINEL", "w").write("called")
print('{"class": "unknown"}')
sys.exit(1)
FAKEPYEOF
PAYLOAD=$(jq -cn --arg tp "$FRESH_PROSE_429_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
( cd "$SANDBOX" && unset HEIMDALL_HOME && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" HEIMDALL_429_MARKER_FILE="$MARKER" HMD_QUOTA_STOP_PY="$FAKE_QUOTA_STOP_PY"; printf '%s' "$PAYLOAD" | bash "$STOP_CMD_FILE" >/dev/null 2>&1 )
if [ -f "$FAKE_QUOTA_STOP_SENTINEL" ]; then
  ok "HMD_QUOTA_STOP_PY override is honored -- the override classifier was actually invoked"
else
  bad "HMD_QUOTA_STOP_PY override was NOT invoked -- env var ignored"
fi
marker_exists && bad "HMD_QUOTA_STOP_PY override case: marker written despite the override reporting 'unknown' -- verdict ignored downstream" \
  || ok "HMD_QUOTA_STOP_PY override case: no marker written, matching the override's honest 'unknown' verdict"

# --- 26. Tier 3 is strictly last-resort (structural + unrelated prose) ------
reset_marker
PAYLOAD=$(jq -cn --arg tp "$STRUCTURAL_PLUS_PROSE_TRANSCRIPT" '{hook_event_name:"Stop", transcript_path:$tp}')
run_hook "$PAYLOAD" Stop
if marker_exists; then
  R=$(marker_reason)
  [ "$R" = "stop-transcript-429" ] && ok "structural 429 alongside an unrelated fresh prose 429 marks via Tier 1, never Tier 3 (got: $R)" \
    || bad "tier-order violated -- expected stop-transcript-429, got: $R"
else
  bad "structural+prose transcript failed to mark at all"
fi

# --- collateral: every other live hook event still present -------------------
for EVENT in UserPromptSubmit PreToolUse PostToolUse SessionStart SessionEnd; do
  N=$(jq -r --arg e "$EVENT" '(.hooks[$e] // []) | length' "$HOOKS")
  if [ "${N:-0}" -ge 1 ]; then
    ok "$EVENT still registered ($N entr$([ "$N" = 1 ] && echo y || echo ies))"
  else
    bad "$EVENT lost all entries"
  fi
done

echo "--------------------------------------------------------------------"
echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
