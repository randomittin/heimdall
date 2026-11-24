#!/usr/bin/env bash
# parallel-gate-throttle harness
#
# Covers the two guards on the injection of bin/parallel-gate (2026-11-24; docs/analysis/2026-11-22-token-utilization-next.md lever 7:
# 637 "MULTI-PART TASK DETECTED" injections, $13.06). Measured on the orchestrator transcript: 589 of 644 injections fired on SYSTEM turns
# (a <task-notification> or "[SYSTEM NOTIFICATION - NOT USER INPUT]" turn is a UserPromptSubmit too, and its body of lists and verbs scored
# "~10 independent subtasks"), and a real prompt got the same 850-character contract again and again.
#   1. a system turn (<task-notification>, [SYSTEM NOTIFICATION, <agent-message>, <cross-session-message>, <system-reminder>) is never
#      injected into and never touches the throttle state;
#   2. once a session has been shown the contract it is shown again only after HMD_PARALLEL_GATE_EVERY (default 5) prompts, or at once
#      when the detected subtask count RISES above the one the model was last shown.
# The detection heuristic itself is untouched; this suite pins only the guards around it. It is a use-case scenario per claim: given a
# session's prompts, when the hook runs, then it injects or stays silent. The REAL hook runs end to end in a sandboxed HOME.
#
# Falsifiable: the first injection, the K-th-prompt re-injection, a rise, a system wrapper of each kind (with a control that the same body
# injects when unwrapped), trivial prompts counting toward K, sessions apart, every fail-open path (no session id, hostile ids, an unwritable
# state dir, a corrupt record: silent AND exit 0), the knob, and the 7-day prune each have an assertion; and three mutants of the hook
# (the notification skip, the K boundary, the rise rule) each flip a verdict. Cost: about 70 hook runs, a few seconds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOOK="$REPO/bin/parallel-gate"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl required" >&2; exit 2; }
[ -f "$REAL_HOOK" ] || { echo "FATAL: missing $REAL_HOOK" >&2; exit 2; }

# The knob must not leak in from the caller, or the default-K scenarios below would run with someone else's K.
unset HMD_PARALLEL_GATE_EVERY

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/parallel-gate-throttle.XXXXXX")"
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

HOOK="$REAL_HOOK"
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# The prompts, and the subtask count the heuristic gives each (probed on the unmodified hook before the guards existed).
P_LOW=$'Refactor the parser and then write tests'
P_HIGH=$'Please handle these:\n1. fix the login bug\n2. add a retry to the client\n3. update the README'
P_HIGHER=$'Do all of this:\n1. fix the login bug\n2. add a retry to the client\n3. update the README\n4. remove the dead flag\n5. write the changelog entry'
# System wrappers, as the harness words them (measured in session transcripts); the body that follows each is P_HIGHER, which scores ~9 alone.
W_TASK=$'<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>\n'
W_SYS=$'[SYSTEM NOTIFICATION - NOT USER INPUT]\nThis is an automated background-task event, NOT a message from the user.\n'
W_AGENT=$'<agent-message from="worker-1">\n'
W_XSESS=$'<cross-session-message from="sess-9">\n'
W_REMIND=$'<system-reminder>\n'

new_home() { mkdir -p "$SANDBOX/home.$1"; printf '%s' "$SANDBOX/home.$1"; }

# fire_raw HOME PAYLOAD [VAR=value ...] -> RC, $OUT, $ERR   (the hook of $HOOK, from the sandbox, in a clean environment)
fire_raw() {
  local home="$1" pl="$2"
  shift 2
  : >"$OUT"; : >"$ERR"
  ( cd "$SANDBOX" && printf '%s' "$pl" | env -i "HOME=$home" "HEIMDALL_HOME=$home/.heimdall" "PATH=$PATH" "$@" bash "$HOOK" >"$OUT" 2>"$ERR" )
  RC=$?
}
# fire HOME SESSION|- PROMPT [VAR=value ...]   (SESSION "-" = a payload with no session_id)
fire() {
  local home="$1" sid="$2" prompt="$3" pl
  shift 3
  if [ "$sid" = "-" ]; then
    pl="$(jq -cn --arg p "$prompt" '{prompt:$p}')"
  else
    pl="$(jq -cn --arg s "$sid" --arg p "$prompt" '{session_id:$s,prompt:$p}')"
  fi
  fire_raw "$home" "$pl" "$@"
}

# injected N: the last fire exited 0 and put the whole contract, for ~N subtasks, on stdout as UserPromptSubmit additionalContext
injected() {
  [ "$RC" = 0 ] && jq -e --arg n "$1" '.hookSpecificOutput | .hookEventName == "UserPromptSubmit" and (.additionalContext | contains("MULTI-PART TASK DETECTED (~" + $n + " independent subtasks)") and contains("MANDATORY EXECUTION CONTRACT"))' "$OUT" >/dev/null 2>&1
}
silent() { [ "$RC" = 0 ] && [ ! -s "$OUT" ]; }
expect_inject() { if injected "$2"; then ok "$1"; else bad "$1 (rc=$RC want ~$2, out=[$(head -c 140 "$OUT")] err=[$(head -c 140 "$ERR")])"; fi; }
expect_silent() { if silent; then ok "$1"; else bad "$1 (rc=$RC out=[$(head -c 140 "$OUT")] err=[$(head -c 140 "$ERR")])"; fi; }
# state_of HOME SESSION -> the one-line record, empty when there is none
state_of() { cat "$1/.heimdall/parallel-gate/$2" 2>/dev/null; }

echo "parallel-gate-throttle harness"

# -- 1. a real multi-part prompt is injected, then once per K=5 prompts ------------------------------------------------------------
echo "1. once per K prompts"
H="$(new_home once)"
fire "$H" s-one "$P_HIGH"
expect_inject "1a. the first multi-part prompt of a session gets the contract (~5 subtasks, the full text, exit 0)" 5
n_silent=0
for _ in 1 2 3 4; do fire "$H" s-one "$P_HIGH"; silent && n_silent=$((n_silent+1)); done
[ "$n_silent" = 4 ] && ok "1b. the same prompt on each of the next 4 prompts (inside K=5) is silent, exit 0" || bad "1b. only $n_silent of 4 repeats inside K were silent"
fire "$H" s-one "$P_HIGH"
expect_inject "1c. the 5th prompt after an injection gets the contract again (at most once per K prompts, not never again)" 5
fire "$H" s-one "$P_HIGH"
expect_silent "1d. ...and the window restarts from that injection: the next repeat is silent"

# -- 2. a higher subtask count re-injects; an equal or lower one does not --------------------------------------------------------------
echo "2. the count rises"
H="$(new_home rise)"
fire "$H" s-rise "$P_LOW";    expect_inject "2a. ~2 subtasks: injected" 2
fire "$H" s-rise "$P_HIGH";   expect_inject "2b. ~5 subtasks right after: injected again (the count rose above the 2 the model was shown)" 5
fire "$H" s-rise "$P_HIGH";   expect_silent "2c. ~5 again: silent (not above the 5 the model holds)"
fire "$H" s-rise "$P_LOW";    expect_silent "2d. ~2 after ~5: silent (a lower count never re-injects)"
fire "$H" s-rise "$P_HIGHER"; expect_inject "2e. ~9 subtasks: injected again (rose above 5)" 9
fire "$H" s-rise "$P_HIGHER"; expect_silent "2f. ~9 again: silent"

# -- 3. every real prompt counts toward K, trivial ones included -------------------------------------------------------------------------
echo "3. trivial prompts count toward K"
H="$(new_home count)"
fire "$H" s-count "$P_HIGH"; expect_inject "3a. first multi-part prompt: injected" 5
n_silent=0
for t in "ok" "thanks a lot" "what is the status now" "show me the diff please"; do fire "$H" s-count "$t"; silent && n_silent=$((n_silent+1)); done
[ "$n_silent" = 4 ] && ok "3b. four trivial prompts (too short, a question): silent, exit 0" || bad "3b. only $n_silent of 4 trivial prompts were silent"
fire "$H" s-count "$P_HIGH"
expect_inject "3c. the next multi-part prompt (the 5th since the injection) is injected: the four trivial prompts counted" 5

# -- 4. system turns: never injected into, never counted -----------------------------------------------------------------------------------
echo "4. system turns"
H="$(new_home sys)"
fire "$H" s-ctl "$P_HIGHER"
expect_inject "4a. control: the body alone IS detected (~9), so the silence below is the wrapper's doing" 9
i=0
for w in "$W_TASK" "$W_SYS" "$W_AGENT" "$W_XSESS" "$W_REMIND" $'\n  '"$W_TASK"; do
  i=$((i+1))
  fire "$H" "s-sys-$i" "$w$P_HIGHER"
  expect_silent "4b.$i. a system turn ($(printf '%s' "$w" | tr -s '[:space:]' ' ' | cut -c1-32)...) with that body: silent, exit 0"
done
[ ! -e "$H/.heimdall/parallel-gate/s-sys-1" ] && [ ! -e "$H/.heimdall/parallel-gate/s-sys-2" ] \
  && ok "4c. a system turn creates no throttle state" || bad "4c. a system turn wrote a record"
fire "$H" s-state "$P_HIGH"; expect_inject "4d. (setup) a session is shown the contract" 5
before="$(state_of "$H" s-state)"
for w in "$W_TASK" "$W_SYS" "$W_AGENT" "$W_XSESS" "$W_REMIND"; do fire "$H" s-state "$w$P_HIGHER"; done
[ -n "$before" ] && [ "$before" = "$(state_of "$H" s-state)" ] \
  && ok "4e. five system turns later the record is byte-identical (they neither inject nor advance the count)" || bad "4e. system turns changed the record: [$before] -> [$(state_of "$H" s-state)]"
fire "$H" s-mention $'Fix the hook so it ignores <task-notification> turns and also add a test:\n1. fix the gate\n2. add the test\n3. update the docs'
if [ "$RC" = 0 ] && grep -qF 'MULTI-PART TASK DETECTED' "$OUT"; then ok "4f. a real prompt that only MENTIONS <task-notification> mid-text is still detected (the skip is a prefix, not a substring)"; else bad "4f. a real prompt that mentions the tag was skipped (rc=$RC out=[$(head -c 140 "$OUT")])"; fi

# -- 5. sessions are throttled apart ------------------------------------------------------------------------------------------------------------
echo "5. sessions"
H="$(new_home apart)"
fire "$H" sess-A "$P_HIGH"; expect_inject "5a. session A is shown the contract" 5
fire "$H" sess-B "$P_HIGH"; expect_inject "5b. session B, right after, is shown it too (A's injection does not throttle B)" 5
fire "$H" sess-A "$P_HIGH"; expect_silent "5c. session A repeats: silent"
fire "$H" sess-B "$P_HIGH"; expect_silent "5d. session B repeats: silent"

# -- 6. fail open: every error is silence and exit 0 ---------------------------------------------------------------------------------------------
echo "6. fail open"
H="$(new_home nosid)"
fire "$H" - "$P_HIGH"
expect_silent "6a. a payload with no session_id: no injection, exit 0 (the throttle cannot work, so the nudge stands down)"
[ ! -e "$H/.heimdall/parallel-gate" ] && ok "6b. ...and no state is written" || bad "6b. a payload with no session id wrote state"
H="$(new_home hostile)"
n_silent=0
for sid in '../escape' 'a/b' '.hidden' 'x y' '..'; do fire "$H" "$sid" "$P_HIGH"; silent && n_silent=$((n_silent+1)); done
[ "$n_silent" = 5 ] && ok "6c. hostile session ids (../escape, a/b, .hidden, a space, ..): silent, exit 0" || bad "6c. only $n_silent of 5 hostile ids were silent"
[ ! -e "$H/.heimdall/escape" ] && [ ! -e "$H/.heimdall/parallel-gate" ] && ok "6d. ...and nothing was written for any of them" || bad "6d. a hostile id wrote state: $(find "$H" -type f 2>/dev/null | head -3 | tr '\n' ' ')"
H="$(new_home nowrite)"; mkdir -p "$H/.heimdall"; : >"$H/.heimdall/parallel-gate"
fire "$H" s-nowrite "$P_HIGH"
expect_silent "6e. the state dir cannot be created (a file sits where it belongs): no injection, exit 0"
H="$(new_home corrupt)"; mkdir -p "$H/.heimdall/parallel-gate"; printf 'garbage here\n' >"$H/.heimdall/parallel-gate/s-bad"
fire "$H" s-bad "$P_HIGH"
expect_silent "6f. a record that does not parse: no injection on that prompt, exit 0"
fire "$H" s-bad "$P_HIGH"
if injected 5 && [ "$(state_of "$H" s-bad)" = "0 5" ]; then ok "6g. ...and the record healed: the next multi-part prompt is injected and the record reads '0 5'"; else bad "6g. the corrupt record did not heal (rc=$RC rec=[$(state_of "$H" s-bad)])"; fi

# -- 7. the knob -----------------------------------------------------------------------------------------------------------------------------------
echo "7. HMD_PARALLEL_GATE_EVERY"
H="$(new_home k1)"
n_inj=0
for _ in 1 2 3; do fire "$H" s-k1 "$P_HIGH" HMD_PARALLEL_GATE_EVERY=1; injected 5 && n_inj=$((n_inj+1)); done
[ "$n_inj" = 3 ] && ok "7a. =1 restores the old behaviour: every multi-part prompt is injected" || bad "7a. =1 injected only $n_inj of 3"
H="$(new_home k2)"
fire "$H" s-k2 "$P_HIGH" HMD_PARALLEL_GATE_EVERY=2; ia=0; injected 5 && ia=1
fire "$H" s-k2 "$P_HIGH" HMD_PARALLEL_GATE_EVERY=2; ib=0; silent && ib=1
fire "$H" s-k2 "$P_HIGH" HMD_PARALLEL_GATE_EVERY=2; ic=0; injected 5 && ic=1
[ "$ia$ib$ic" = 111 ] && ok "7b. =2 injects, stays silent, injects (the knob is read)" || bad "7b. =2 gave inject/silent/inject = $ia/$ib/$ic"
for v in abc 0 08 99999999 -3 ''; do
  H="$(new_home "kbad$v")"
  fire "$H" s-kb "$P_HIGH" "HMD_PARALLEL_GATE_EVERY=$v"; first=0; injected 5 && first=1
  fire "$H" s-kb "$P_HIGH" "HMD_PARALLEL_GATE_EVERY=$v"; second=0; silent && second=1
  [ "$first$second" = 11 ] && ok "7c. a bad value [$v] falls back to K=5 (injects, then silent, exit 0)" || bad "7c. a bad value [$v] gave inject/silent = $first/$second (rc=$RC)"
done

# -- 8. state stays bounded ----------------------------------------------------------------------------------------------------------------------
echo "8. prune"
H="$(new_home prune)"; mkdir -p "$H/.heimdall/parallel-gate"
printf '3 5\n' >"$H/.heimdall/parallel-gate/old-sess"; printf '3 5\n' >"$H/.heimdall/parallel-gate/fresh-sess"
perl -e 'my $t = time - 8 * 86400; utime $t, $t, $ARGV[0]' "$H/.heimdall/parallel-gate/old-sess"
fire "$H" s-new "$P_HIGH"
if [ ! -e "$H/.heimdall/parallel-gate/old-sess" ] && [ -e "$H/.heimdall/parallel-gate/fresh-sess" ] && [ -e "$H/.heimdall/parallel-gate/s-new" ]; then
  ok "8a. a new session sweeps records untouched for over 7 days, keeps recent ones, writes its own"
else
  bad "8a. prune: old=$([ -e "$H/.heimdall/parallel-gate/old-sess" ] && echo kept || echo gone) fresh=$([ -e "$H/.heimdall/parallel-gate/fresh-sess" ] && echo kept || echo gone) new=$([ -e "$H/.heimdall/parallel-gate/s-new" ] && echo written || echo missing)"
fi

# -- 9. mutants: each guard, broken by one edit to a sandboxed COPY of the hook, must flip a verdict ------------------------------------------
echo "9. mutants"
MUT_HOOK="$SANDBOX/parallel-gate.mut"
mutate() { sed -e "$1" "$REAL_HOOK" >"$MUT_HOOK" 2>/dev/null; ! cmp -s "$REAL_HOOK" "$MUT_HOOK"; }

if mutate 's|"<task-notification"\*|"<task-notification-x"*|'; then
  HOOK="$MUT_HOOK"; H="$(new_home m1)"
  fire "$H" s-m1 "$W_TASK$P_HIGHER"
  HOOK="$REAL_HOOK"
  injected 9 && ok "M1 KILLED: without the <task-notification> skip a notification turn is injected -> section 4 is a real check" \
    || bad "M1 SURVIVED: the mutant without the notification skip was still silent"
else
  bad "M1 NOT APPLIED: the notification-skip pattern no longer matches — this mutation proof is dead"
fi

if mutate 's|-lt "\$PG_K"|-le "$PG_K"|'; then
  HOOK="$MUT_HOOK"; H="$(new_home m2)"
  fire "$H" s-m2 "$P_HIGH"
  for _ in 1 2 3 4; do fire "$H" s-m2 "$P_HIGH"; done
  fire "$H" s-m2 "$P_HIGH"
  HOOK="$REAL_HOOK"
  silent && ok "M2 KILLED: with the K boundary off by one the 5th prompt after an injection stays silent -> section 1 is a real check" \
    || bad "M2 SURVIVED: the off-by-one mutant still injected on the 5th prompt"
else
  bad "M2 NOT APPLIED: the K comparison no longer matches — this mutation proof is dead"
fi

if mutate 's|"\$parts" -le "\$pg_last"|0 -eq 0|'; then
  HOOK="$MUT_HOOK"; H="$(new_home m3)"
  fire "$H" s-m3 "$P_LOW"
  fire "$H" s-m3 "$P_HIGH"
  HOOK="$REAL_HOOK"
  silent && ok "M3 KILLED: without the rise rule ~5 right after ~2 is suppressed -> section 2 is a real check" \
    || bad "M3 SURVIVED: the mutant without the rise rule still injected the higher count"
else
  bad "M3 NOT APPLIED: the rise comparison no longer matches — this mutation proof is dead"
fi
cmp -s "$REAL_HOOK" "$MUT_HOOK" && bad "the last mutant is byte-identical to the shipped hook — the mutations edited the wrong file" \
  || ok "every mutant is a sandboxed COPY; bin/parallel-gate itself is never edited"

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
