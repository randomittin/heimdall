#!/usr/bin/env bash
# test/agents-orphans-finished.test.sh -- the sweep and the checkpoint see OPEN agents.
#
# CLAIM (docs/analysis/2026-11-20-finished-agents-still-listed.md, recommendations 3 and 4): an agent that sent its "finished" notice
# and was never TaskStop'd stays listed as running, and so does a background shell whose process is gone, yet `heimdall-agents
# orphans` said "no orphaned, parked or wedged subagents" and a checkpoint carried "completed" where it should carry "still open".
# This builds a synthetic session transcript in the REAL row shapes (measured on a 70 MB session, 2026-11-22: queue-operation and
# user rows holding <task-notification> blocks, TaskStop tool_use + tool_result, background Bash tool_use + launch tool_result,
# SendMessage tool_use) and proves, through the public entry points (orphans, open, checkpoint write, the SessionStart hook):
#   finished + never stopped -> reported          finished + stopped / gone / resumed / waiting / turn-limit / quoted -> not
#   stopped, then finished again -> reported      dead shell (no process holds its file) -> reported; a live one (held by a real
#   `sleep`, found by a real lsof) -> not          lsof missing -> shells with no notice are NOT reported (cannot tell != dead)
#   fail-open and read-only                       the checkpoint lists them; the resume hook prints them on source=resume only
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS="$ROOT/bin/heimdall-agents"
CKPT="$ROOT/bin/heimdall-checkpoint"
HOOKS="$ROOT/hooks/hooks.json"
for t in "$AGENTS" "$CKPT"; do [ -x "$t" ] || { echo "FATAL: $t not executable" >&2; exit 2; }; done
for c in jq perl git; do command -v "$c" >/dev/null 2>&1 || { echo "FATAL: $c not found" >&2; exit 2; }; done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-open-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
HOLD_PID=""
trap '[ -z "$HOLD_PID" ] || kill "$HOLD_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

NOW=2000000000
SLUG="-Users-rj-Downloads-testproj"
PROJ="$WORK/projects"
TASKDIR="$WORK/claude-501/$SLUG/tsess/tasks"
TR="$PROJ/$SLUG/sess-1.jsonl"
mkdir -p "$TASKDIR" "$PROJ/$SLUG"
: > "$TR"

set_mtime() { local f="$1" e="$2" ts; touch -d "@$e" "$f" 2>/dev/null && return 0; ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1; touch -t "$ts" "$f"; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# notice <id> <status> <summary> <result> <at-epoch> [both]: the enqueue row, plus the identical delivery row when `both`.
notice() {
  local id="$1" status="$2" sum="$3" res="$4" at="$5" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_n_%s</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>%s</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops with no live background children of its own.</note>\n<result>%s</result>\n</task-notification>' "$id" "$id" "$TASKDIR" "$id" "$status" "$sum" "$res")"
  jq -nc --arg c "$body" --arg t "$(iso "$at")" '{type:"queue-operation",operation:"enqueue",timestamp:$t,sessionId:"sess-1",content:$c}' >> "$TR"
  [ "${6:-}" != both ] || jq -nc --arg c "$body" --arg t "$(iso "$at")" '{parentUuid:"p1",type:"user",message:{role:"user",content:$c},origin:{kind:"task-notification"},timestamp:$t}' >> "$TR"
}
# stop <tool-use-id> <task-id> <result-text>: a TaskStop call and the result the harness returned.
stop() {
  jq -nc --arg u "$1" --arg i "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$u,name:"TaskStop",input:{task_id:$i},caller:{type:"direct"}}]}}' >> "$TR"
  jq -nc --arg u "$1" --arg m "$3" '{type:"user",message:{role:"user",content:[{tool_use_id:$u,type:"tool_result",content:$m}]}}' >> "$TR"
}
stop_ok() { stop "$1" "$2" "$(jq -nc --arg i "$2" '{message:("Successfully stopped task: "+$i+" (x)"),task_id:$i,task_type:"local_agent"}')"; }
# launch <tool-use-id> <shell-id> <description>: a background Bash call and its launch result.
launch() {
  jq -nc --arg u "$1" --arg d "$3" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$u,name:"Bash",input:{command:"make slow",description:$d,run_in_background:true},caller:{type:"direct"}}]}}' >> "$TR"
  jq -nc --arg u "$1" --arg t "Command running in background with ID: $2. Output is being written to: $TASKDIR/$2.output. You will be notified when it completes." '{type:"user",message:{role:"user",content:[{tool_use_id:$u,type:"tool_result",content:$t,is_error:false}]}}' >> "$TR"
}
resume() { jq -nc --arg i "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_sm",name:"SendMessage",input:{to:$i,message:"go on"},caller:{type:"direct"}}]}}' >> "$TR"; }

A_OPEN=a1111111111111111;    A_STOPPED=a2222222222222222; A_GONE=a3333333333333333;  A_WAIT=a4444444444444444
A_RESUMED=a5555555555555555; A_AGAIN=a6666666666666666;   A_TURN=a7777777777777777;  A_QUOTED=a8888888888888888
A_ANCIENT=a9999999999999999
S_DEAD=bdeadshl1; S_LIVE=blivesh02; S_NOTICE=bnotice03; S_STOPPED=bstopped4; S_NOFILE=bnofile05; S_DIRONLY=bdironly6

notice "$A_OPEN"    completed 'Agent "Pill overlap + private-tab journey" finished' 'done' $((NOW-7200)) both
notice "$A_STOPPED" completed 'Agent "Two red UI tests" finished' 'done' $((NOW-9000));          stop_ok toolu_s2 "$A_STOPPED"
notice "$A_GONE"    completed 'Agent "Flipkart inner pages" finished' 'done' $((NOW-9000));      stop toolu_s3 "$A_GONE" "No task found with ID: $A_GONE"
notice "$A_WAIT"    completed 'Agent "Speed agent" is waiting on its own background work' 'done' $((NOW-9000))
notice "$A_RESUMED" completed 'Agent "Resumed agent" finished' 'done' $((NOW-9000));             resume "$A_RESUMED"
notice "$A_AGAIN"   completed 'Agent "Looping agent" finished' r1 $((NOW-9000));               stop_ok toolu_s6 "$A_AGAIN"
notice "$A_AGAIN"   completed 'Agent "Looping agent" finished' r2 $((NOW-300))
notice "$A_TURN"    completed 'Agent "Turn limit agent" stopped at its 40-turn limit (partial result; SendMessage to task-id to continue)' 'done' $((NOW-9000))
notice "$A_ANCIENT" completed 'Agent "Ancient agent" finished' 'done' $((NOW-30*86400))
jq -nc --arg t "I saw <task-notification>
<task-id>$A_QUOTED</task-id>
<status>completed</status>
<summary>Agent \"Quoted\" finished</summary>
</task-notification> in the log" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$TR"

launch toolu_b1 "$S_DEAD" "Dead build"
launch toolu_b2 "$S_LIVE" "Live server"
notice "$S_NOTICE"  completed 'Background command "Finished build" completed (exit code 0)' '' $((NOW-1800))
notice "$S_STOPPED" completed 'Background command "Stopped build" completed (exit code 0)' '' $((NOW-1800)); stop_ok toolu_s4 "$S_STOPPED"
notice "$S_NOFILE"  completed 'Background command "Cleaned build" completed (exit code 0)' '' $((NOW-1800))

for s in "$S_DEAD" "$S_LIVE" "$S_NOTICE" "$S_STOPPED" "$S_DIRONLY"; do : > "$TASKDIR/$s.output"; set_mtime "$TASKDIR/$s.output" $((NOW-3600)); done
set_mtime "$TASKDIR/$S_DIRONLY.output" $((NOW-5000))
HAS_LSOF=0; command -v lsof >/dev/null 2>&1 && HAS_LSOF=1
if [ "$HAS_LSOF" = 1 ]; then ( exec sleep 120 ) >> "$TASKDIR/$S_LIVE.output" 2>&1 & HOLD_PID=$!; fi

# ag: the tool under test, hermetic. T_PROJ / T_TASKDIR / T_LSOF override one seam for a single call.
ag() {
  local -a e=(HMD_NOW="$NOW" HMD_AGENT_TASKDIR="${T_TASKDIR:-$TASKDIR}" HMD_AGENT_PROJECTS_DIR="${T_PROJ:-$PROJ}" HMD_AGENT_REAPED_FILE="$WORK/reaped.json" HMD_AGENT_LIVE_SLUGS="$SLUG")
  [ -z "${T_LSOF:-}" ] || e+=(HMD_AGENT_LSOF="$T_LSOF")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "${e[@]}" "$AGENTS" "$@"
}
ids_of() { jq -r '[.[].id] | sort | join(" ")' 2>/dev/null; }
row() { jq -c --arg i "$2" '.[] | select(.id==$i)' <<<"$1" 2>/dev/null; }

echo "(1) agents: finished + never stopped is reported, everything else is not"
BEFORE="$(cksum < "$TR")"; NFILES="$(find "$PROJ" | wc -l | tr -d ' ')"
OPEN_J="$(ag open --json)"
if [ "$HAS_LSOF" = 1 ]; then EXPECT="$A_OPEN $A_AGAIN $S_DEAD $S_DIRONLY $S_NOTICE"; else EXPECT="$A_OPEN $A_AGAIN $S_NOTICE"; echo "  (no lsof on this machine: shells with no notice cannot be judged, so they are not expected)"; fi
GOT="$(ids_of <<<"$OPEN_J")"
if [ "$GOT" = "$EXPECT" ]; then ok "open lists exactly: $GOT"; else bad "open listed '$GOT', expected '$EXPECT'"; fi
R="$(row "$OPEN_J" "$A_OPEN")"
if [ "$(jq -r '.kind' <<<"$R")" = agent ] && [ "$(jq -r '.age_secs' <<<"$R")" = 7200 ] && [ "$(jq -r '.description' <<<"$R")" = "Pill overlap + private-tab journey" ]; then
  ok "finished agent: kind, age from its notice (7200s), description"
else bad "finished agent row wrong: $R"; fi
[ "$(jq -r '.taskstop' <<<"$R")" = "TaskStop task_id=$A_OPEN" ] && ok "row carries the exact TaskStop to run" || bad "taskstop wrong: $R"
[ "$(jq -r --arg i "$A_OPEN" '[.[]|select(.id==$i)]|length' <<<"$OPEN_J")" = 1 ] && ok "the same notice in two rows (enqueue + delivery) is one agent" || bad "duplicate rows listed the agent twice"
[ "$(jq -r '.age_secs' <<<"$(row "$OPEN_J" "$A_AGAIN")")" = 300 ] && ok "stopped, then finished AGAIN -> open again, aged from the second notice" || bad "re-finished agent wrong: $(row "$OPEN_J" "$A_AGAIN")"
for pair in "$A_STOPPED:TaskStop success" "$A_GONE:TaskStop 'No task found'" "$A_WAIT:waiting on its own background work" "$A_RESUMED:SendMessage resumed it" "$A_TURN:stopped at its turn limit" "$A_QUOTED:notice only quoted in assistant text" "$A_ANCIENT:finished 30 days ago, past the 7-day window" "$S_STOPPED:shell stopped" "$S_NOFILE:shell output file gone"; do
  if has "$GOT" "${pair%%:*}"; then bad "${pair%%:*} is listed but must not be (${pair#*:})"; else ok "${pair%%:*} not listed (${pair#*:})"; fi
done

WIDE="$(HMD_AGENT_OPEN_MAX_AGE_SECS=99999999 ag open --json | ids_of)"
if has "$WIDE" "$A_ANCIENT"; then ok "HMD_AGENT_OPEN_MAX_AGE_SECS widens the window (the 30-day-old agent is then listed)"; else bad "window override ignored: $WIDE"; fi

echo "(2) shells: a dead process is reported, a live one is not"
S="$(row "$OPEN_J" "$S_NOTICE")"
if [ "$(jq -r '.kind' <<<"$S")" = shell ] && [ "$(jq -r '.age_secs' <<<"$S")" = 3600 ] && [ "$(jq -r '.description' <<<"$S")" = "Finished build" ]; then ok "ended shell (completed notice, file exists): kind, age from the file, description from the notice"; else bad "ended shell row wrong: $S"; fi
if [ "$HAS_LSOF" = 1 ]; then
  [ "$(jq -r '.description' <<<"$(row "$OPEN_J" "$S_DEAD")")" = "Dead build" ] && ok "dead shell with no notice: reported, description from its Bash call" || bad "dead shell row wrong: $(row "$OPEN_J" "$S_DEAD")"
  [ "$(jq -r '.description' <<<"$(row "$OPEN_J" "$S_DIRONLY")")" = null ] && ok "task-dir-only shell: reported, description unknown" || bad "dir-only shell row wrong: $(row "$OPEN_J" "$S_DIRONLY")"
  if has "$GOT" "$S_LIVE"; then bad "a shell whose process holds its output file was reported dead"; else ok "live shell (a real sleep holds its file) is NOT reported"; fi
fi
NOLSOF="$(T_LSOF=/nonexistent/lsof ag open --json | ids_of)"
if [ "$NOLSOF" = "$A_OPEN $A_AGAIN $S_NOTICE" ]; then ok "lsof unavailable: shells without a notice are skipped (cannot tell is not dead), notice-backed ones stay"; else bad "no-lsof run listed '$NOLSOF'"; fi

echo "(3) orphans: the same rows, in text and JSON, next to the old classes"
ORPH_J="$(ag orphans --json)"
R="$(row "$ORPH_J" "$A_OPEN")"
if [ "$(jq -r '.state' <<<"$R")" = finished-open ] && [ "$(jq -r '.kind' <<<"$R")" = agent ] && [ "$(jq -r '.name' <<<"$R")" = "-" ]; then ok "orphans --json: finished agent as state finished-open"; else bad "orphans --json row wrong: $R"; fi
[ "$HAS_LSOF" != 1 ] || { [ "$(jq -r '.state' <<<"$(row "$ORPH_J" "$S_DEAD")")" = shell-dead ] && ok "orphans --json: dead shell as state shell-dead" || bad "dead shell missing from orphans --json"; }
[ "$(jq -r 'type' <<<"$ORPH_J")" = array ] && ok "orphans --json stays an array" || bad "orphans --json is not an array"
ORPH_T="$(ag orphans 2>&1)"; ORPH_RC=$?
[ "$ORPH_RC" = 0 ] && ok "orphans exits 0" || bad "orphans exited $ORPH_RC"
if has "$ORPH_T" "TaskStop task_id=$A_OPEN" && has "$ORPH_T" "Pill overlap + private-tab journey" && has "$ORPH_T" "AGE(s)"; then ok "orphans text: id, description, age column and the exact TaskStop"; else bad "orphans text lacks the finished agent: $ORPH_T"; fi
NONE_T="$(T_PROJ="$WORK/none-proj" T_TASKDIR="$WORK/none-t/claude-501/$SLUG/x/tasks" ag orphans 2>&1)"
[ "$NONE_T" = "no orphaned, parked or wedged subagents" ] && ok "nothing open: the old one-line answer is unchanged" || bad "empty world printed: $NONE_T"

echo "(4) fail-open and read-only"
mkdir -p "$WORK/projects2/$SLUG"
printf '\377\376 not json\n{"type":"queue-operation","content":"<task-notification>\\n<task-id>trunc\n' > "$WORK/projects2/$SLUG/garbage.jsonl"
G_OUT="$(T_PROJ="$WORK/projects2" T_TASKDIR="$WORK/claude-501/$SLUG/none/tasks" ag open --json 2>&1)"; G_RC=$?
if [ "$G_RC" = 0 ] && [ "$G_OUT" = "[]" ]; then ok "garbage / truncated transcript: exit 0, empty list, no crash"; else bad "garbage transcript gave rc=$G_RC out=$G_OUT"; fi
[ "$(cksum < "$TR")" = "$BEFORE" ] && [ "$(find "$PROJ" | wc -l | tr -d ' ')" = "$NFILES" ] && ok "read-only: the transcript is byte-identical and nothing was created beside it" || bad "a transcript was modified or a file created"

echo "(5) checkpoint write carries the Open agents list"
REPOC="$WORK/repo"; mkdir -p "$REPOC"
git -C "$REPOC" init -q; printf 'x\n' > "$REPOC/f"; git -C "$REPOC" add f
git -C "$REPOC" -c user.email=t@t -c user.name=t commit -q -m init
REPOC="$(cd "$REPOC" && pwd)"
SLUGC="$(printf '%s' "$REPOC" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$PROJ/$SLUGC"; cp "$TR" "$PROJ/$SLUGC/sess-1.jsonl"
ckw() { env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HEIMDALL_HOME="$WORK/home" HMD_NOW="$NOW" HMD_AGENT_PROJECTS_DIR="${1:-$PROJ}" "$CKPT" write "$REPOC" >"$WORK/ckpt.out" 2>&1; }
ckw; CK_RC=$?
CK="$(cat "$REPOC/.planning/CHECKPOINT.md" 2>/dev/null)"
[ "$CK_RC" = 0 ] && ok "checkpoint write exits 0" || bad "checkpoint write exited $CK_RC: $(head -3 "$WORK/ckpt.out")"
if has "$CK" '### Open agents' && has "$CK" "\`$A_OPEN\`" && has "$CK" "Pill overlap + private-tab journey" && has "$CK" "TaskStop task_id=$A_OPEN" && has "$CK" "\`$A_AGAIN\`"; then ok "the block lists the open agents: id, description, exact TaskStop"; else bad "Open agents section missing or incomplete: $(printf '%s' "$CK" | grep -A6 'Open agents')"; fi
if has "$CK" "$A_STOPPED" || has "$CK" "$A_WAIT" || has "$CK" "$A_QUOTED"; then bad "the checkpoint lists an agent that is not open"; else ok "stopped, waiting and quoted agents are not in the checkpoint"; fi
mkdir -p "$WORK/empty-projects"; ckw "$WORK/empty-projects"
if has "$(cat "$REPOC/.planning/CHECKPOINT.md")" 'Open agents'; then bad "nothing open but the section is still there (stale block not replaced)"; else ok "nothing open: no section, and the old one is replaced in place"; fi

echo "(6) the SessionStart resume hook prints the list on a resume only"
HOOK_CMD="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$HOOKS" 2>/dev/null | grep -F 'heimdall-resume-probe' | head -1)"
run_hook() { # <stdin> <project-dir>
  printf '%s' "$1" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$2" HEIMDALL_HOME="$WORK/home-hook" HMD_NOW="$NOW" HMD_AGENT_PROJECTS_DIR="$PROJ" sh -c "$HOOK_CMD" 2>&1
}
if [ -z "$HOOK_CMD" ]; then bad "no SessionStart hook runs heimdall-resume-probe"; else
  HR="$(run_hook '{"source":"resume"}' "$REPOC")"
  if has "$HR" "TaskStop task_id=$A_OPEN" && has "$HR" "never stopped"; then ok "source=resume: the hook lists the open agents with their TaskStop"; else bad "resume hook printed: $HR"; fi
  HS="$(run_hook '{"source":"startup"}' "$REPOC")"
  if has "$HS" "$A_OPEN"; then bad "source=startup printed another conversation's agents"; else ok "source=startup: silent about agents"; fi
  HU="$(run_hook '' "$REPOC")"
  if has "$HU" "$A_OPEN"; then ok "no payload (source unknown): still printed, failing toward showing"; else bad "unknown source swallowed the list: $HU"; fi
  mkdir -p "$WORK/nockpt"; HN="$(run_hook '{"source":"resume"}' "$WORK/nockpt")"
  [ -z "$HN" ] && ok "no CHECKPOINT.md: the hook says nothing at all" || bad "hook spoke in a repo with nothing to resume: $HN"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
