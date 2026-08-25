#!/usr/bin/env bash
#
# heimdall-metric-reminder.test.sh — the Stop-hook nudge that closes the last
# gap in getting real, typed, outcome-bearing heimdall-metric records into
# .planning/metrics.jsonl: only the ORCHESTRATOR knows both task_type and
# first-try pass/fail, and prose alone was measured not to be enough (130
# hook-wired parallelism-tracker records vs 5 prose-instructed heimdall-metric
# records over the same 83-day window — see bin/heimdall-metric-hook's own
# header for the full account of the two hooks that tried and structurally
# could not: SubagentStop-based heimdall-metric-hook, and the git-hook-based
# heimdall-gate-run).
#
# WHY Stop AND NOT SubagentStop, VERIFIED (not assumed): both this session's
# own pinned CLI binary (resolved via $CLAUDE_CODE_EXECPATH) and the
# separately installed one carry, verbatim, in their embedded --help text:
#   Stop:         additionalContext "delivered to the model; the conversation
#                 continues" -> reaches the orchestrator's own context.
#   SubagentStop: additionalContext "delivered to the subagent; the subagent
#                 continues" -> dies with the subagent it fired for.
# This suite does not re-prove that CLI-internal fact (it is not something a
# bash harness can assert against a black-box binary) — it proves the hook
# built on top of it: exactly one Stop entry wired to a real, executable
# script, and that script's own observable behaviour is correct end-to-end.
#
# Guarantees proved:
#   1. hooks.json is valid JSON.
#   2. Exactly one Stop entry exists and its command invokes
#      heimdall-metric-reminder.sh; it carries no matcher key (bare shape,
#      matching SessionStart/SubagentStop/SessionEnd).
#   3. hooks/heimdall-metric-reminder.sh exists, is executable, and parses
#      (bash -n).
#   4. A session with a real --source orchestrator, typed, pass/fail record
#      already in .planning/metrics.jsonl gets ABSOLUTE SILENCE (no stdout).
#      A fail outcome silences it just as well as a pass — a fail is still a
#      real observation, not something to keep nagging about.
#   5. A session with NO such record — whether the ledger is entirely absent,
#      or present but holding only mechanical subagentstop/gate-* rows, or an
#      orchestrator row missing its outcome — gets exactly one reminder,
#      injected via hookSpecificOutput.additionalContext for the Stop event,
#      naming the real `heimdall-metric` command and explicitly warning never
#      to guess --type/--outcome.
#   6. That reminder fires AT MOST ONCE per session_id: a second Stop event
#      for the same session, still lacking a qualifying record, stays silent
#      — and a qualifying record appearing LATER does not retroactively
#      unsilence anything either.
#   7. Fail-open, unconditionally: a missing/non-executable heimdall-metric
#      binary, a missing session_id, an unreadable ledger, and a
#      malformed/empty payload all exit 0 with zero stdout, never a crash —
#      and an unreadable ledger is never silently treated as "zero records"
#      (that would be a guess, not a fact), so no marker gets written for
#      either of those two short-circuits (both are meant to be re-checked on
#      the next Stop event, not locked in for the rest of the session).
#   8. Fast: a representative invocation completes well inside a generous
#      bound, measured here, not assumed.
#
# Usage:  bash test/heimdall-metric-reminder.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
HOOK_SRC="$REPO/hooks/heimdall-metric-reminder.sh"
METRIC_SRC="$REPO/bin/heimdall-metric"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "heimdall-metric-reminder harness  repo=$REPO"
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
  echo "  heimdall-metric-reminder: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# --- 2. exactly one Stop entry owns the reminder ----------------------------
# Identified by BEHAVIOUR (its command invokes heimdall-metric-reminder.sh),
# never by array index, so reordering hooks.json cannot silently retarget
# this test.
OWNERS=$(jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-reminder"))))]
  | length' "$HOOKS")

if [ "$OWNERS" = "1" ]; then
  ok "exactly one Stop entry invokes heimdall-metric-reminder.sh"
else
  bad "expected exactly 1 Stop entry invoking heimdall-metric-reminder.sh, found $OWNERS"
fi

NOMATCHER=$(jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-reminder"))))]
  | .[0] | has("matcher")' "$HOOKS")
if [ "$NOMATCHER" = "false" ]; then
  ok "Stop entry has no matcher key, matching SessionStart/SubagentStop/SessionEnd's bare shape"
else
  bad "Stop entry unexpectedly carries a matcher key"
fi

if [ ! -x "$HOOK_SRC" ]; then
  bad "hooks/heimdall-metric-reminder.sh is not executable — cannot prove end-to-end behaviour"
  echo "--------------------------------------------------------------------"
  echo "  heimdall-metric-reminder: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
bash -n "$HOOK_SRC" && ok "hooks/heimdall-metric-reminder.sh parses (bash -n)" || bad "hooks/heimdall-metric-reminder.sh has a syntax error"

HOOK_CMD_FILE="$(mktemp "${TMPDIR:-/tmp}/hmd-metric-reminder-cmd.XXXXXX")"
jq -r '
  [(.hooks.Stop // [])[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-metric-reminder"))))]
  | .[0].hooks[0].command' "$HOOKS" > "$HOOK_CMD_FILE"

if [ -s "$HOOK_CMD_FILE" ]; then
  ok "Stop entry has a non-empty command"
else
  bad "Stop entry command is empty"
fi

# --- sandbox: a fake plugin install (hooks/ + bin/) and a fake project ------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-metric-reminder.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PLUGIN="$SANDBOX/plugin"
PROJECT="$SANDBOX/project"
mkdir -p "$PLUGIN/hooks" "$PLUGIN/bin" "$PROJECT/.planning"

cp "$HOOK_SRC" "$PLUGIN/hooks/heimdall-metric-reminder.sh"
cp "$METRIC_SRC" "$PLUGIN/bin/heimdall-metric"
chmod +x "$PLUGIN/hooks/heimdall-metric-reminder.sh" "$PLUGIN/bin/heimdall-metric"

METRICS="$PROJECT/.planning/metrics.jsonl"

run_hook() {
  # $1 = payload json (stdin). Runs the actual hooks.json command string
  # (extracted verbatim above), never the script directly, so this proves the
  # wiring in hooks.json too, not just the script in isolation.
  (
    cd "$SANDBOX" || exit 1
    unset HEIMDALL_PLANNING_DIR HEIMDALL_HOME
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    export CLAUDE_PROJECT_DIR="$PROJECT"
    printf '%s' "$1" | bash "$HOOK_CMD_FILE" 2>"$SANDBOX/stderr.log"
  )
}

append_record() { printf '%s\n' "$1" >> "$METRICS"; }

rec() {
  # rec <source> <task_type-or-empty> <outcome-or-empty> -> one metrics.jsonl line
  jq -cn --arg src "$1" --arg tt "$2" --arg oc "$3" '
    {metric:"task", schema:1, source:$src, model:"sonnet"}
    + (if $tt == "" then {task_type:null} else {task_type:$tt} end)
    + (if $oc == "" then {outcome:null} else {outcome:$oc} end)'
}

# --- 3. a real orchestrator-sourced record silences the reminder -----------
rm -f "$METRICS"
append_record "$(rec orchestrator code pass)"
OUT=$(run_hook "$(jq -cn --arg sid "session-with-record" '{session_id:$sid}')")
if [ -z "$OUT" ]; then
  ok "session with a qualifying orchestrator record emits nothing"
else
  bad "session with a qualifying orchestrator record emitted output: $OUT"
fi
[ ! -e "$PROJECT/.heimdall/stop-hook/reminded-session-with-record" ] \
  && ok "no marker written when a qualifying record already exists (nothing to remind about)" \
  || bad "a marker was written even though a qualifying record already existed"

# --- 3b. outcome=fail also counts as a real observation (not pass-only) -----
rm -f "$METRICS"
append_record "$(rec orchestrator lint fail)"
OUT=$(run_hook "$(jq -cn --arg sid "session-with-fail-record" '{session_id:$sid}')")
[ -z "$OUT" ] && ok "outcome=fail also silences the reminder (a fail is still a real observation)" \
  || bad "outcome=fail record did not silence the reminder: $OUT"

# --- 4. no qualifying record -> exactly one reminder ------------------------
rm -f "$METRICS"
OUT=$(run_hook "$(jq -cn --arg sid "session-no-ledger" '{session_id:$sid}')")
if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "missing ledger entirely (zero records, known for certain) emits valid JSON"
  EVT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')
  CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
  [ "$EVT" = "Stop" ] && ok "hookEventName is Stop" || bad "hookEventName wrong: $EVT"
  printf '%s' "$CTX" | grep -q "heimdall-metric" && ok "additionalContext names the real heimdall-metric command" \
    || bad "additionalContext does not name heimdall-metric: $CTX"
  printf '%s' "$CTX" | grep -qi "never guess" && ok "additionalContext explicitly warns never to guess a value" \
    || bad "additionalContext does not warn against guessing: $CTX"
else
  bad "missing ledger case emitted no valid JSON reminder: '$OUT'"
fi
[ -e "$PROJECT/.heimdall/stop-hook/reminded-session-no-ledger" ] \
  && ok "marker written after the reminder fires" \
  || bad "no marker written after the reminder fired — would nag every turn"

# --- 5. same session, called again -> silent (already reminded) ------------
OUT2=$(run_hook "$(jq -cn --arg sid "session-no-ledger" '{session_id:$sid}')")
[ -z "$OUT2" ] && ok "second Stop event for the same session stays silent (one nudge per session, ever)" \
  || bad "second Stop event for the same session re-emitted a reminder: $OUT2"

# --- 5b. even after a qualifying record later appears, stays silent --------
append_record "$(rec orchestrator code pass)"
OUT3=$(run_hook "$(jq -cn --arg sid "session-no-ledger" '{session_id:$sid}')")
[ -z "$OUT3" ] && ok "already-reminded session stays silent even after a qualifying record later appears" \
  || bad "already-reminded session re-emitted after a later record appeared: $OUT3"

# --- 6. mechanical-only rows (subagentstop / gate-*) do not count -----------
rm -f "$METRICS"
append_record "$(rec subagentstop code "")"
append_record "$(rec gate-pre-push "" pass)"
OUT=$(run_hook "$(jq -cn --arg sid "session-mechanical-only" '{session_id:$sid}')")
if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "mechanical-only rows (subagentstop w/ task_type, gate-* w/ outcome) still trigger the reminder"
else
  bad "mechanical-only rows wrongly silenced the reminder: '$OUT'"
fi

# --- 6b. orchestrator-sourced but no outcome logged yet -> still reminds ---
rm -f "$METRICS"
append_record "$(rec orchestrator code "")"
OUT=$(run_hook "$(jq -cn --arg sid "session-orchestrator-no-outcome" '{session_id:$sid}')")
if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "source=orchestrator with task_type but no outcome still triggers the reminder (not outcome-bearing yet)"
else
  bad "orchestrator record with no outcome wrongly silenced the reminder: '$OUT'"
fi

# --- 7. fail-open behaviour --------------------------------------------------
rm -f "$METRICS"
RC=0
( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT"; printf '%s' '' | bash "$HOOK_CMD_FILE" >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 0 ] && ok "empty stdin exits 0 (fail-open)" || bad "empty stdin exited $RC, expected 0"

RC=0
OUT=$( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT"; printf '%s' 'not-json-at-all {{{' | bash "$HOOK_CMD_FILE" 2>/dev/null ) || RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "malformed (non-JSON) payload exits 0 with no output" \
  || bad "malformed payload: rc=$RC output='$OUT'"

RC=0
OUT=$( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT"; printf '%s' "$(jq -cn '{no_session_id_here:true}')" | bash "$HOOK_CMD_FILE" 2>/dev/null ) || RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "payload missing session_id exits 0 with no output (never guesses a session identity)" \
  || bad "missing-session_id payload: rc=$RC output='$OUT'"

NOPLUGIN_SANDBOX="$SANDBOX/noplugin"
mkdir -p "$NOPLUGIN_SANDBOX"
RC=0
( set +o pipefail; cd "$NOPLUGIN_SANDBOX" && export CLAUDE_PLUGIN_ROOT="$NOPLUGIN_SANDBOX" CLAUDE_PROJECT_DIR="$PROJECT"; printf '%s' "$(jq -cn --arg sid "no-binary" '{session_id:$sid}')" | bash "$HOOK_CMD_FILE" >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 0 ] && ok "missing heimdall-metric binary at CLAUDE_PLUGIN_ROOT exits 0 (fail-open)" || bad "missing-binary case exited $RC, expected 0"
[ ! -e "$PROJECT/.heimdall/stop-hook/reminded-no-binary" ] \
  && ok "no marker written when heimdall-metric binary is missing (transient brokenness is not a one-time thing)" \
  || bad "a marker was written despite the missing binary short-circuit"

# unreadable ledger: MUST be silent, and MUST NOT be treated as "zero records".
rm -f "$METRICS"
append_record "$(rec orchestrator code pass)"
chmod 000 "$METRICS"
RC=0
OUT=$( cd "$SANDBOX" && export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT"; printf '%s' "$(jq -cn --arg sid "session-unreadable" '{session_id:$sid}')" | bash "$HOOK_CMD_FILE" 2>/dev/null ) || RC=$?
chmod 644 "$METRICS"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "unreadable ledger exits 0 with no output (unreadable is 'unknown', never treated as 'zero records')" \
  || bad "unreadable ledger case: rc=$RC output='$OUT'"
[ ! -e "$PROJECT/.heimdall/stop-hook/reminded-session-unreadable" ] \
  && ok "no marker written when the ledger is unreadable (would wrongly lock in a guess)" \
  || bad "a marker was written despite the ledger being unreadable"

# --- 8. latency: a representative invocation is fast ------------------------
rm -f "$METRICS"
START=$(date +%s%N 2>/dev/null || echo 0)
run_hook "$(jq -cn --arg sid "session-latency" '{session_id:$sid}')" >/dev/null
END=$(date +%s%N 2>/dev/null || echo 0)
if [ "$START" != "0" ] && [ "$END" != "0" ]; then
  MS=$(( (END - START) / 1000000 ))
  echo "  measured latency: ${MS}ms"
  [ "$MS" -lt 3000 ] && ok "representative invocation completes in ${MS}ms (< 3000ms bound)" \
    || bad "representative invocation took ${MS}ms — exceeds the 3000ms bound"
else
  printf '  \033[33mNOTE\033[0m  %s\n' "date +%s%N unsupported on this platform — latency not measured numerically"
fi

# --- collateral check: every other live hook event still present -----------
for EVENT in UserPromptSubmit PreToolUse PostToolUse SessionStart SubagentStop SessionEnd; do
  N=$(jq -r --arg e "$EVENT" '(.hooks[$e] // []) | length' "$HOOKS")
  if [ "${N:-0}" -ge 1 ]; then
    ok "$EVENT still registered ($N entr$([ "$N" = 1 ] && echo y || echo ies))"
  else
    bad "$EVENT lost all entries"
  fi
done

echo "--------------------------------------------------------------------"
printf "heimdall-metric-reminder: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
