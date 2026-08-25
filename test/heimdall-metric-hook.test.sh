#!/usr/bin/env bash
#
# heimdall-metric-hook.test.sh — the SubagentStop wiring that makes
# heimdall-metric fire MECHANICALLY, not by prose instruction.
#
# WHY: measured in this repo, 130 parallelism-tracker records exist against
# only 5 heimdall-metric records over the same 83-day window
# (.planning/metrics.jsonl) — a 26x gap between a hook that performs the
# action and a prose instruction asking an orchestrator to. bin/heimdall-dream
# has never once fired: "task-outcome records seen: 5" sits under its own
# 20-per-(task_type,model) sample floor. This test proves the fix: a real
# SubagentStop hook entry exists, and its command genuinely appends a record
# to .planning/metrics.jsonl end-to-end — never asserted, always executed.
#
# It also proves the hook's honesty constraints hold, not just its happy path:
#   - subagent_type "fork" (live model unobservable) never fabricates a record.
#   - an agent whose frontmatter model is "inherit"/unknown never fabricates one.
#   - task_type is real ONLY for the honest single-purpose allowlist (reviewer,
#     lint-quality, ...) and null for everything else, including multi-purpose
#     agents like coder — never a slug of agent_type, never a guess.
#   - outcome is NEVER derived from last_assistant_message — no event in the
#     SubagentStop payload can verify whether acceptance criteria passed, so
#     every record's outcome is null regardless of DONE/BLOCKED/anything else
#     the agent's own final message claims.
#   - a genuinely unknown agent_type (no matching agents/*.md) never crashes,
#     never records.
# Silence/null in all these cases is the correct behavior being tested — the
# whole point is "never guess a value to fill a field."
#
# Guarantees proved:
#   1. hooks/hooks.json is valid JSON.
#   2. Exactly one SubagentStop entry exists and its command invokes
#      heimdall-metric-hook.
#   3. Feeding it a real SubagentStop payload (agent_type, effort.level,
#      last_assistant_message) appends exactly one correctly-shaped record.
#   4. hmd:-namespaced agent_type slugs correctly and strips the prefix only
#      for the agents/*.md lookup, not for the recorded task_type.
#   5. outcome is ALWAYS null, regardless of DONE/DONE_WITH_CONCERNS/
#      NEEDS_CONTEXT/BLOCKED in last_assistant_message — no SubagentStop field
#      can verify a real pass/fail, so none is ever fabricated from prose.
#   6. task_type is real ONLY for the honest single-purpose allowlist
#      (lint-quality, docs-writer, test-runner, reviewer, planner, design,
#      security-auditor) — null for every other agent_type, including
#      multi-purpose ones like coder. Message content never gates whether a
#      record is written at all: a known agent+model records regardless of
#      what (or whether) last_assistant_message says.
#   7. fork / inherit-model record NOTHING (model genuinely unknown, never
#      guessed); a genuinely unknown agent_type also records NOTHING.
#   8. effort.level flows through when present; is simply absent (not
#      fabricated) when the payload omits it.
#   9. The hook is fail-open: no jq, a missing heimdall-metric binary, or a
#      malformed payload all still exit 0.
#
# Usage:  bash test/heimdall-metric-hook.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
HOOK_SRC="$REPO/bin/heimdall-metric-hook"
METRIC_SRC="$REPO/bin/heimdall-metric"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "heimdall-metric-hook harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi

# --- 1. hooks.json is valid JSON --------------------------------------------
if jq . "$HOOKS" >/dev/null 2>&1; then
  ok "hooks.json is valid JSON"
else
  bad "hooks.json is not valid JSON — nothing below is meaningful"
  echo "--------------------------------------------------------------------"
  echo "  heimdall-metric-hook: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# --- 2. exactly one SubagentStop entry owns metric emission ------------------
# Identified by BEHAVIOUR (its command invokes heimdall-metric-hook), never by
# array index, so reordering hooks.json cannot silently retarget this test.
OWNERS=$(jq -r '
  [(.hooks.SubagentStop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-hook"))))]
  | length' "$HOOKS")

if [ "$OWNERS" = "1" ]; then
  ok "exactly one SubagentStop entry invokes heimdall-metric-hook"
else
  bad "expected exactly 1 SubagentStop entry invoking heimdall-metric-hook, found $OWNERS"
fi

NOMATCHER=$(jq -r '
  [(.hooks.SubagentStop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-hook"))))]
  | .[0] | has("matcher")' "$HOOKS")
if [ "$NOMATCHER" = "false" ]; then
  ok "SubagentStop entry has no matcher key, matching SessionStart/SessionEnd's bare shape"
else
  bad "SubagentStop entry unexpectedly carries a matcher key"
fi

if [ ! -x "$HOOK_SRC" ]; then
  bad "bin/heimdall-metric-hook is not executable — cannot prove end-to-end emission"
  echo "--------------------------------------------------------------------"
  echo "  heimdall-metric-hook: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
bash -n "$HOOK_SRC" && ok "bin/heimdall-metric-hook parses (bash -n)" || bad "bin/heimdall-metric-hook has a syntax error"

HOOK_CMD_FILE="$(mktemp "${TMPDIR:-/tmp}/hmd-metric-hook-cmd.XXXXXX")"
jq -r '
  [(.hooks.SubagentStop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-hook"))))]
  | .[0].hooks[0].command' "$HOOKS" > "$HOOK_CMD_FILE"

if [ -s "$HOOK_CMD_FILE" ]; then
  ok "SubagentStop entry has a non-empty command"
else
  bad "SubagentStop entry command is empty"
fi

# --- sandbox: a fake plugin install (bin/ + agents/) and a fake project ------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-metric-hook.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PLUGIN="$SANDBOX/plugin"
PROJECT="$SANDBOX/project"
mkdir -p "$PLUGIN/bin" "$PLUGIN/agents" "$PROJECT/.planning"

cp "$HOOK_SRC" "$PLUGIN/bin/heimdall-metric-hook"
cp "$METRIC_SRC" "$PLUGIN/bin/heimdall-metric"
chmod +x "$PLUGIN/bin/heimdall-metric-hook" "$PLUGIN/bin/heimdall-metric"
# Deliberately NOT copying bin/lib/dream_data.py: this keeps
# _relocated_metrics_path() import-failing (by design, caught by heimdall-metric
# itself) so the test writes to exactly one place — $PROJECT/.planning — and
# never touches the real machine's $HEIMDALL_HOME.

cat > "$PLUGIN/agents/coder.md" <<'EOF'
---
name: coder
model: sonnet
---
body
EOF
cat > "$PLUGIN/agents/reviewer.md" <<'EOF'
---
name: reviewer
model: opus
---
body
EOF
cat > "$PLUGIN/agents/heimdall.md" <<'EOF'
---
name: heimdall
model: inherit
---
body
EOF
cat > "$PLUGIN/agents/lint-quality.md" <<'EOF'
---
name: lint-quality
model: haiku
---
body
EOF

METRICS="$PROJECT/.planning/metrics.jsonl"

run_hook() {
  # $1 = payload json (stdin). NOTE: a `VAR=val \` prefix on a pipeline only
  # scopes to the pipeline's FIRST command (here, `printf`) — it would never
  # reach `bash "$HOOK_CMD_FILE"`. export inside this already-isolated
  # subshell instead, so the wrapper's own CLAUDE_PLUGIN_ROOT lookup sees it.
  (
    cd "$SANDBOX" || exit 1
    unset HEIMDALL_PLANNING_DIR HEIMDALL_HOME
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    printf '%s' "$1" | bash "$HOOK_CMD_FILE" > /dev/null 2> "$SANDBOX/stderr.log"
  )
}

lines_now() { [ -f "$METRICS" ] && wc -l < "$METRICS" | tr -d ' ' || echo 0; }

# NOTE: the hooks.json command reads --repo from ${CLAUDE_PROJECT_DIR:-.}; set
# it so the emitted record lands in $PROJECT rather than the sandbox cwd.
export CLAUDE_PROJECT_DIR="$PROJECT"

# --- 3/4/5. positive cases: real record, correctly shaped -------------------
BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"coder", effort:{level:"high"}, last_assistant_message:"DONE. `npm test` -> 12 passed (exit 0)."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  ok "agent_type=coder + DONE appends exactly one record"
  REC=$(tail -1 "$METRICS")
  [ "$(printf '%s' "$REC" | jq -r '.metric')" = "task" ]      && ok "record metric=task"      || bad "record metric field wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.task_type')" = "null" ]   && ok "record task_type=null (coder is multi-purpose — never guessed)" || bad "record task_type wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.model')" = "sonnet" ]     && ok "record model=sonnet (from agents/coder.md frontmatter)" || bad "record model wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.outcome')" = "null" ]     && ok "record outcome=null (never derived from last_assistant_message, even a DONE)" || bad "record outcome wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.effort')" = "high" ]      && ok "record effort=high (from effort.level)" || bad "record effort wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.source')" = "subagentstop" ] && ok "record source=subagentstop" || bad "record source wrong: $REC"
else
  bad "agent_type=coder + DONE: expected $((BEFORE+1)) lines, got $AFTER"
fi

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"hmd:reviewer", last_assistant_message:"BLOCKED. cannot proceed without repo write access."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  ok "agent_type=hmd:reviewer + BLOCKED appends exactly one record"
  REC=$(tail -1 "$METRICS")
  [ "$(printf '%s' "$REC" | jq -r '.task_type')" = "review" ]       && ok "record task_type=review (honest allowlist: reviewer's ENTIRE job is review; prefix stripped)" || bad "record task_type wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.model')" = "opus" ]             && ok "record model=opus (agents/reviewer.md, prefix stripped for lookup)" || bad "record model wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.outcome')" = "null" ]           && ok "record outcome=null (BLOCKED does not become a fabricated fail)" || bad "record outcome wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.effort')" = "default" ]         && ok "record effort defaults to 'default' when effort.level absent (not fabricated by this hook)" || bad "record effort wrong: $REC"
else
  bad "agent_type=hmd:reviewer + BLOCKED: expected $((BEFORE+1)) lines, got $AFTER"
fi

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"lint-quality", last_assistant_message:"lint clean, 0 warnings"}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  ok "agent_type=lint-quality appends exactly one record"
  REC=$(tail -1 "$METRICS")
  [ "$(printf '%s' "$REC" | jq -r '.task_type')" = "lint" ] && ok "record task_type=lint (honest allowlist: lint-quality's ENTIRE job is lint — proves the table, not a one-off)" || bad "record task_type wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.model')" = "haiku" ]    && ok "record model=haiku (agents/lint-quality.md frontmatter)" || bad "record model wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r '.outcome')" = "null" ]   && ok "record outcome=null" || bad "record outcome wrong: $REC"
else
  bad "agent_type=lint-quality: expected $((BEFORE+1)) lines, got $AFTER"
fi

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"coder", last_assistant_message:"DONE_WITH_CONCERNS. Works but file grew large."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ] && [ "$(tail -1 "$METRICS" | jq -r '.outcome')" = "null" ]; then
  ok "DONE_WITH_CONCERNS still records outcome=null (an agent's own claim is not a verified fact)"
else
  bad "DONE_WITH_CONCERNS fabricated a non-null outcome (before=$BEFORE after=$AFTER)"
fi

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"coder", last_assistant_message:"NEEDS_CONTEXT. Which env should this target?"}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ] && [ "$(tail -1 "$METRICS" | jq -r '.outcome')" = "null" ]; then
  ok "NEEDS_CONTEXT still records outcome=null (a hook cannot know if this blocked acceptance)"
else
  bad "NEEDS_CONTEXT fabricated a non-null outcome (before=$BEFORE after=$AFTER)"
fi

# --- 6. negative cases: never guess, so never record -------------------------
BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"fork", last_assistant_message:"DONE. all good."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
[ "$AFTER" -eq "$BEFORE" ] && ok "subagent_type=fork records NOTHING (live model unobservable, never guessed)" \
  || bad "fork case fabricated a record: before=$BEFORE after=$AFTER"

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"heimdall", last_assistant_message:"DONE. all good."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
[ "$AFTER" -eq "$BEFORE" ] && ok "agent with model:inherit records NOTHING (model genuinely unknown, never guessed)" \
  || bad "inherit-model case fabricated a record: before=$BEFORE after=$AFTER"

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"coder", last_assistant_message:"Ran the migration and updated three files, looks fine to me."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  ok "message with no Status Contract token STILL records (coverage fix — message content is never inspected)"
  REC=$(tail -1 "$METRICS")
  [ "$(printf '%s' "$REC" | jq -r '.task_type')" = "null" ] && [ "$(printf '%s' "$REC" | jq -r '.outcome')" = "null" ] \
    && ok "task_type/outcome both null — volume captured honestly, nothing guessed from the prose" \
    || bad "no-token record fabricated a field: $REC"
else
  bad "no-token case recorded nothing — coverage gap not fixed (before=$BEFORE after=$AFTER)"
fi

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"totally-unknown-agent-xyz", last_assistant_message:"DONE."}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
[ "$AFTER" -eq "$BEFORE" ] && ok "unknown agent_type (no agents/*.md match) records NOTHING and does not crash" \
  || bad "unknown-agent case fabricated a record: before=$BEFORE after=$AFTER"

BEFORE=$(lines_now)
PAYLOAD=$(jq -cn '{agent_type:"coder", last_assistant_message:""}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
[ "$AFTER" -eq $((BEFORE+1)) ] && ok "empty last_assistant_message STILL records (message content never gates emission)" \
  || bad "empty-message case recorded nothing — coverage gap not fixed (before=$BEFORE after=$AFTER)"

# --- 8. fail-open behaviour ---------------------------------------------------
BEFORE=$(lines_now)
run_hook "not-json-at-all {{{"
AFTER=$(lines_now)
[ "$AFTER" -eq "$BEFORE" ] && ok "malformed (non-JSON) payload records nothing and does not crash the hook" \
  || bad "malformed payload changed record count: before=$BEFORE after=$AFTER"

RC_EMPTY=0
( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN"; printf '%s' '' | bash "$HOOK_CMD_FILE" >/dev/null 2>&1 ) || RC_EMPTY=$?
[ "$RC_EMPTY" -eq 0 ] && ok "empty stdin exits 0 (fail-open)" || bad "empty stdin exited $RC_EMPTY, expected 0"

NOPLUGIN_SANDBOX="$SANDBOX/noplugin"
mkdir -p "$NOPLUGIN_SANDBOX"
RC_NOBIN=0
( cd "$NOPLUGIN_SANDBOX" && export CLAUDE_PLUGIN_ROOT="$NOPLUGIN_SANDBOX"; printf '%s' "$PAYLOAD" | bash "$HOOK_CMD_FILE" >/dev/null 2>&1 ) || RC_NOBIN=$?
[ "$RC_NOBIN" -eq 0 ] && ok "missing heimdall-metric-hook binary at CLAUDE_PLUGIN_ROOT exits 0 (fail-open)" || bad "missing-binary case exited $RC_NOBIN, expected 0"

# --- 9. outcome derived from agent_transcript_path — conservative, fail-only -
# Fixture transcripts are CONSTRUCTED here, never real operator transcripts:
# real ones are non-reproducible and could leak session content (same rule
# bin/heimdall-529-scan's own test suite follows). Shape grounded in
# docs/analysis/2026-08-25-hook-delivery-spike.md (Finding 2's confirmed
# "Exit code 137" tool_result) and docs/analysis/2026-08-25-transcript-529-
# detection.md (structural-field-over-prose methodology).
TRANSCRIPTS="$SANDBOX/transcripts"
mkdir -p "$TRANSCRIPTS"

KILLED_TRANSCRIPT="$TRANSCRIPTS/killed.jsonl"
cat > "$KILLED_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"sleep 240"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Exit code 137","is_error":true}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE"}]}}
EOF

CLEAN_TRANSCRIPT="$TRANSCRIPTS/clean.jsonl"
cat > "$CLEAN_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"file1.txt\nfile2.txt","is_error":false}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"Exit code 1","is_error":true}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"DONE. All good."}]}}
EOF

MALFORMED_TRANSCRIPT="$TRANSCRIPTS/malformed.jsonl"
printf 'not json at all {{{\nrandom garbage line\n' > "$MALFORMED_TRANSCRIPT"

# (a) FALSIFIABILITY PROOF: a killed-tool transcript must never yield
# outcome=pass — and since the marker is unambiguous, must yield the honest
# outcome=fail rather than leaving it to chance which side of "not pass" it's on.
BEFORE=$(lines_now)
PAYLOAD=$(jq -cn --arg tp "$KILLED_TRANSCRIPT" '{agent_type:"coder", last_assistant_message:"DONE", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  REC=$(tail -1 "$METRICS")
  OUT=$(printf '%s' "$REC" | jq -r '.outcome')
  [ "$OUT" != "pass" ] && ok "killed-tool transcript + last_assistant_message=DONE never yields outcome=pass (got: $OUT)" \
    || bad "FALSIFIED: killed-tool transcript fabricated outcome=pass despite a SIGKILL marker: $REC"
  [ "$OUT" = "fail" ] && ok "killed-tool transcript (is_error:true, 'Exit code 137') correctly recorded as outcome=fail" \
    || bad "killed-tool transcript did not record outcome=fail (got: $OUT): $REC"
else
  bad "killed-tool transcript case: expected $((BEFORE+1)) lines, got $AFTER"
fi

# (b) NO REGRESSION: a clean transcript — including an is_error:true tool
# result for an ORDINARY (non-signal) exit code — still records outcome=null,
# exactly as before this feature existed. Proves the detector keys on the
# 128-192 signal-exit range, not merely on is_error:true or the substring
# "Exit code".
BEFORE=$(lines_now)
PAYLOAD=$(jq -cn --arg tp "$CLEAN_TRANSCRIPT" '{agent_type:"coder", last_assistant_message:"DONE. All good.", agent_transcript_path:$tp}')
run_hook "$PAYLOAD"
AFTER=$(lines_now)
if [ "$AFTER" -eq $((BEFORE+1)) ]; then
  OUT=$(tail -1 "$METRICS" | jq -r '.outcome')
  [ "$OUT" = "null" ] && ok "clean transcript (incl. an ordinary 'Exit code 1' tool error) still records outcome=null — no regression, no over-triggering on ordinary tool failures" \
    || bad "clean transcript fabricated a non-null outcome: $OUT"
else
  bad "clean-transcript case: expected $((BEFORE+1)) lines, got $AFTER"
fi

# (c) FALSIFIABILITY PROOF: missing/malformed agent_transcript_path never
# fabricates an outcome and never breaks the hook (exit 0 throughout) — the
# record still lands (task_type/model/effort unaffected), only the outcome
# piece is silently skipped.
CASE_LABELS=("nonexistent-path" "empty-path" "malformed-content" "a-directory")
CASE_PATHS=("$TRANSCRIPTS/does-not-exist.jsonl" "" "$MALFORMED_TRANSCRIPT" "$TRANSCRIPTS")
i=0
while [ $i -lt ${#CASE_PATHS[@]} ]; do
  CASE_PATH="${CASE_PATHS[$i]}"
  CASE_LABEL="${CASE_LABELS[$i]}"
  BEFORE=$(lines_now)
  PAYLOAD=$(jq -cn --arg tp "$CASE_PATH" '{agent_type:"coder", last_assistant_message:"DONE", agent_transcript_path:$tp}')
  RC=0
  ( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN"; printf '%s' "$PAYLOAD" | bash "$HOOK_CMD_FILE" >/dev/null 2>"$SANDBOX/stderr.log" ) || RC=$?
  AFTER=$(lines_now)
  [ "$RC" -eq 0 ] && ok "agent_transcript_path case '$CASE_LABEL' exits 0" || bad "agent_transcript_path case '$CASE_LABEL' exited $RC, expected 0"
  if [ "$AFTER" -eq $((BEFORE+1)) ]; then
    OUT=$(tail -1 "$METRICS" | jq -r '.outcome')
    [ "$OUT" = "null" ] && ok "agent_transcript_path case '$CASE_LABEL' still records, outcome=null (never fabricated from absent/bad evidence)" \
      || bad "agent_transcript_path case '$CASE_LABEL' fabricated a non-null outcome: $OUT"
  else
    bad "agent_transcript_path case '$CASE_LABEL': expected $((BEFORE+1)) lines, got $AFTER"
  fi
  i=$((i+1))
done

# --- collateral check: every other live hook event still present -------------
for EVENT in UserPromptSubmit PreToolUse PostToolUse SessionStart SessionEnd; do
  N=$(jq -r --arg e "$EVENT" '(.hooks[$e] // []) | length' "$HOOKS")
  if [ "${N:-0}" -ge 1 ]; then
    ok "$EVENT still registered ($N entr$([ "$N" = 1 ] && echo y || echo ies))"
  else
    bad "$EVENT lost all entries"
  fi
done

echo "--------------------------------------------------------------------"
printf "heimdall-metric-hook: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
