#!/usr/bin/env bash
# test/finished-agents.test.sh
#
# Proof for the finished-agents tracker (docs/analysis/2026-11-20-finished-agents-still-listed.md, recommendations 1 and 2): a
# background agent that finishes is recorded, ONE line to the model names it on every prompt until it is closed, and any way of
# closing it (TaskStop, a SendMessage that resumes it) takes it off the list.
#
# Everything runs through the REAL command strings of hooks/hooks.json (pulled out with jq and run with `bash -c`, the way Claude
# Code runs them) fed fake payloads, so the wiring is proven together with the behaviour, not beside it.
#
#    1  wiring      the four hooks, their events and matchers; ids in the sidecar, none locked, none remote_toggle
#    2  finish      SubagentStop -> the next prompt gets ONE line naming the agent (id, description, age) and the TaskStop advice
#    3  TaskStop    PostToolUse TaskStop success -> gone; the last one gone removes the log
#    4  resume      PostToolUse SendMessage to the id -> gone; finishing again -> listed again
#    5  zero        nothing recorded -> silent, creates nothing, starts no interpreter (the per-prompt fast path)
#    6  not agents  a foreground agent, a grandchild (spawnDepth 2), an agent still waiting on its own background tasks, an agent
#                   with no sidecar: never recorded (the line would name something TaskStop cannot or must not close)
#    7  failed stop PostToolUseFailure TaskStop "No task found" / "is not running" -> gone (else the line asks for the impossible
#                   on every prompt); any other failure leaves the entry
#    8  the line    ages, the cap on how many agents it names
#    9  hygiene     private (0700 dir, 0600 log), bounded (compaction keeps the newest), expiry, old-session pruning, a hostile
#                   session id, a description with control characters
#   10  CLI         list [--json], clear --id / --session / --all, usage
#   11  dispatcher  hmd agents finished -> the tool; hmd agents -> still the background-session list
#   12  fail-open   garbage, empty and wrong-shape payloads, an unwritable home, the kill switch
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"
TOOL="$REPO/bin/heimdall-finished-agents"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
check() { # check DESCRIPTION CMD... -- ok when CMD succeeds
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

command -v jq >/dev/null 2>&1      || { echo "FATAL: jq is required"; exit 1; }
command -v perl >/dev/null 2>&1    || { echo "FATAL: perl is required"; exit 1; }
REAL_PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -n "$REAL_PY" ] && [ -x "$REAL_PY" ] || { echo "FATAL: python3 is required"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HHOME="$TMP/home"                  # HEIMDALL_HOME: where the tracker keeps its state
USERHOME="$TMP/user"               # HOME and the working directory of every run
mkdir -p "$HHOME" "$USERHOME"
STATE="$HHOME/finished-agents"

# The interpreter the launcher resolves is a stub that counts its launches and then runs the real one: "no interpreter" is observable.
PYCALLS="$TMP/py-calls"; : > "$PYCALLS"
cat > "$TMP/py-stub" <<EOF
#!/bin/sh
echo run >> "$PYCALLS"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$TMP/py-stub"
py_calls() { wc -l < "$PYCALLS" | tr -d ' '; }

mode_of() { perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$1"; }

# ── the hooks, as wired ─────────────────────────────────────────────────────────────────────────────────────────────────────────
hook_command() { # hook_command EVENT FRAGMENT -> the first command of that event that contains FRAGMENT
  jq -r --arg ev "$1" --arg frag "$2" '[.hooks[$ev][]?.hooks[]?.command | select(contains($frag))] | first // empty' "$HOOKS"
}
CMD_STOP="$(hook_command SubagentStop heimdall-finished-agents)"
CMD_DONE="$(hook_command PostToolUse heimdall-finished-agents)"
CMD_FAIL="$(hook_command PostToolUseFailure heimdall-finished-agents)"
CMD_PROMPT="$(hook_command UserPromptSubmit heimdall-finished-agents)"

# fire COMMAND PAYLOAD -- the way Claude Code runs a hook: bash -c <command>, the payload on stdin. Stdout lands in $OUT, the
# status in $RC, stderr in $TMP/stderr. FIRE_HOME is the HEIMDALL_HOME the hook sees.
FIRE_HOME="$HHOME"
fire() {
  OUT="$(printf '%s' "$2" | ( cd "$USERHOME" && env CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$FIRE_HOME" HOME="$USERHOME" \
    HMD_PYTHON="$TMP/py-stub" bash -c "$1" ) 2>"$TMP/stderr")"
  RC=$?
}
# run_tool ARGS... -- the tool itself, for the CLI verbs
run_tool() {
  OUT="$(cd "$USERHOME" && env HEIMDALL_HOME="$HHOME" HOME="$USERHOME" HMD_PYTHON="$TMP/py-stub" "$TOOL" "$@" 2>"$TMP/stderr")"
  RC=$?
}

SID="3f2a9c1e-7b44-4d2e-9a10-5c6e8d1b7f20"
PROJ="$TMP/proj"

# ── payloads, in the shapes Claude Code sends ───────────────────────────────────────────────────────────────────────────────────
agent_files() { # agent_files ID SHAPE DEPTH DESCRIPTION -- the harness's sidecar next to the agent's transcript
  mkdir -p "$PROJ/$SID/subagents"
  : > "$PROJ/$SID/subagents/agent-$1.jsonl"
  jq -cn --arg d "$4" --arg s "$2" --argjson n "$3" \
    '{agentType:"hmd:coder", isBuiltIn:false, description:$d, requestShape:$s, spawnDepth:$n, finished:true}' \
    > "$PROJ/$SID/subagents/agent-$1.meta.json"
}
stop_payload() { # stop_payload ID [BACKGROUND_TASKS_JSON]
  jq -cn --arg sid "$SID" --arg id "$1" --arg tp "$PROJ/$SID.jsonl" --arg atp "$PROJ/$SID/subagents/agent-$1.jsonl" \
    --argjson bg "${2:-[]}" \
    '{session_id:$sid, transcript_path:$tp, cwd:"/work", permission_mode:"default", hook_event_name:"SubagentStop",
      stop_hook_active:false, agent_id:$id, agent_type:"hmd:coder", agent_transcript_path:$atp,
      last_assistant_message:"DONE", background_tasks:$bg}'
}
finish() { # finish ID DESCRIPTION [SHAPE] [DEPTH] -- a background agent ends: its sidecar, then the SubagentStop hook
  agent_files "$1" "${3:-background}" "${4:-1}" "$2"
  fire "$CMD_STOP" "$(stop_payload "$1")"
}
taskstop_ok() {
  jq -cn --arg sid "$SID" --arg id "$1" \
    '{session_id:$sid, hook_event_name:"PostToolUse", tool_name:"TaskStop", tool_input:{task_id:$id},
      tool_response:{message:("Successfully stopped task: " + $id), task_id:$id, task_type:"local_agent"}}'
}
send_message() {
  jq -cn --arg sid "$SID" --arg to "$1" \
    '{session_id:$sid, hook_event_name:"PostToolUse", tool_name:"SendMessage",
      tool_input:{to:$to, message:"continue with the next step", summary:"continue"}, tool_response:{success:true}}'
}
taskstop_failed() { # taskstop_failed ID ERROR_TEXT
  jq -cn --arg sid "$SID" --arg id "$1" --arg e "$2" \
    '{session_id:$sid, hook_event_name:"PostToolUseFailure", tool_name:"TaskStop", tool_input:{task_id:$id}, error:$e, is_interrupt:false}'
}
prompt_payload() { # prompt_payload [SESSION] -- a prompt, or a task-notification turn: the same event, the same payload shape
  jq -cn --arg sid "${1:-$SID}" '{session_id:$sid, transcript_path:"/x/t.jsonl", cwd:"/work", permission_mode:"default",
    hook_event_name:"UserPromptSubmit", prompt:"<task-notification>\n<task-id>a1</task-id>\n</task-notification>"}'
}
# ask [SESSION] -- fire the prompt hook; the model-facing line lands in $LINE (empty when the hook said nothing)
ask() {
  fire "$CMD_PROMPT" "$(prompt_payload "${1:-$SID}")"
  LINE="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
reset_state() { rm -rf "$STATE"; }
log_of() { printf '%s/%s.jsonl' "$STATE" "${1:-$SID}"; }
seed_log() { # seed_log SESSION COUNT PREFIX BASE_TS -- COUNT finish events, oldest first, 0600 in a 0700 directory
  mkdir -p "$STATE"; chmod 700 "$STATE"
  awk -v n="$2" -v p="$3" -v t="$4" 'BEGIN { for (i = 1; i <= n; i++)
    printf "{\"ev\":\"finished\",\"id\":\"%s%04d\",\"ts\":%d,\"desc\":\"seeded agent %d\",\"type\":\"hmd:coder\"}\n", p, i, t + i, i }' \
    > "$(log_of "$1")"
  chmod 600 "$(log_of "$1")"
}
NOW="$(date +%s)"

echo "finished-agents"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "1. wiring"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
[ -n "$CMD_STOP" ]   && ok "a SubagentStop hook runs heimdall-finished-agents"                  || bad "no SubagentStop hook runs heimdall-finished-agents"
[ -n "$CMD_DONE" ]   && ok "a PostToolUse hook runs heimdall-finished-agents"                   || bad "no PostToolUse hook runs heimdall-finished-agents"
[ -n "$CMD_FAIL" ]   && ok "a PostToolUseFailure hook runs heimdall-finished-agents"            || bad "no PostToolUseFailure hook runs heimdall-finished-agents"
[ -n "$CMD_PROMPT" ] && ok "a UserPromptSubmit hook runs heimdall-finished-agents"              || bad "no UserPromptSubmit hook runs heimdall-finished-agents"
[ "$(jq -r '.hooks.PostToolUse[] | select(.hooks[0].command | contains("heimdall-finished-agents")) | .matcher' "$HOOKS" 2>/dev/null)" = 'TaskStop|SendMessage' ] \
  && ok "the PostToolUse hook matches exactly TaskStop|SendMessage (no cost on any other tool call)" || bad "the PostToolUse matcher is not exactly TaskStop|SendMessage"
[ "$(jq -r '.hooks.PostToolUseFailure[] | select(.hooks[0].command | contains("heimdall-finished-agents")) | .matcher' "$HOOKS" 2>/dev/null)" = 'TaskStop' ] \
  && ok "the PostToolUseFailure hook matches exactly TaskStop" || bad "the PostToolUseFailure matcher is not exactly TaskStop"
wiring_bad=""
for pair in "$CMD_STOP|finished-agents-record" "$CMD_DONE|finished-agents-close" "$CMD_FAIL|finished-agents-close-failed" "$CMD_PROMPT|finished-agents-prompt"; do
  cmd="${pair%%|*}"; id="${pair##*|}"
  printf '%s' "$cmd" | grep -qF "hmd_hook_enabled $id &&" || wiring_bad="$wiring_bad $id(no kill switch)"
  printf '%s' "$cmd" | bash -n 2>/dev/null                 || wiring_bad="$wiring_bad $id(bash -n)"
  jq -e --arg id "$id" '.hooks[] | select(.id == $id) | (.locked == false and .remote_toggle == false)' "$META" >/dev/null 2>&1 \
    || wiring_bad="$wiring_bad $id(sidecar: missing, locked or remote_toggle)"
done
[ -z "$wiring_bad" ] && ok "each command passes bash -n and carries its own kill switch; each id is in the sidecar, unlocked, not remote_toggle" \
                     || bad "wiring" "$wiring_bad"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "2. a finished agent is recorded and named on the next prompt"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
finish a1 "Pill overlap + private-tab journey"
silent && ok "SubagentStop prints nothing and exits 0" || bad "SubagentStop hook: rc=$RC out=$OUT"
ask
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1 \
  && ok "the prompt hook answers as UserPromptSubmit additionalContext JSON" || bad "prompt hook output is not UserPromptSubmit additionalContext: $OUT"
case "$LINE" in
  '1 finished agent still open: a1 (Pill overlap + private-tab journey, finished '*) ok "the line names the agent: id, description, age" ;;
  *) bad "the line does not name the agent as asked" "$LINE" ;;
esac
case "$LINE" in *'TaskStop it unless keeping it for follow-up.') ok "the line ends with the TaskStop advice (singular)" ;; *) bad "advice missing or wrong" "$LINE" ;; esac
[ "$(printf '%s' "$LINE" | grep -c '')" = 1 ] && ok "it is ONE line" || bad "the line spans several lines" "$LINE"
finish a2 "Flipkart inner pages not converting"
ask
case "$LINE" in '2 finished agents still open: '*) ok "two finished agents: the count is 2, plural" ;; *) bad "two agents not counted" "$LINE" ;; esac
case "$LINE" in *'TaskStop them unless keeping one for follow-up.') ok "plural advice: TaskStop them unless keeping one for follow-up" ;; *) bad "plural advice wrong" "$LINE" ;; esac
awk -v l="$LINE" 'BEGIN { a = index(l, "a1 ("); b = index(l, "a2 ("); exit !(a > 0 && b > a) }' \
  && ok "both are named, the one that finished first first" || bad "ids missing or out of order" "$LINE"
finish a1 "Pill overlap + private-tab journey"
ask
case "$LINE" in '2 finished agents still open: '*) ok "the same agent finishing again is one entry, not two" ;; *) bad "a repeated finish was counted twice" "$LINE" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "3. TaskStop success closes it"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
fire "$CMD_DONE" "$(taskstop_ok a1)"
silent && ok "PostToolUse TaskStop prints nothing and exits 0" || bad "PostToolUse hook: rc=$RC out=$OUT"
ask
case "$LINE" in '1 finished agent still open: a2 ('*) ok "after TaskStop a1 only a2 is named" ;; *) bad "a1 still listed (or a2 lost)" "$LINE" ;; esac
fire "$CMD_DONE" "$(taskstop_ok b3ykq8z7n)"
ask
case "$LINE" in '1 finished agent still open: a2 ('*) ok "a TaskStop of something that was never listed (a shell) changes nothing" ;; *) bad "an unrelated TaskStop disturbed the list" "$LINE" ;; esac
fire "$CMD_DONE" "$(taskstop_ok a2)"
ask
silent && [ ! -e "$(log_of)" ] && ok "the last one closed: the prompt is silent and the log is gone" || bad "list not empty after the last TaskStop" "$LINE / $(ls "$STATE" 2>&1)"
fire "$CMD_DONE" "$(taskstop_ok b3ykq8z7n)"
[ ! -e "$STATE" ] || [ -z "$(ls "$STATE" | grep -v '^\.lock$')" ] && ok "a TaskStop with nothing listed writes no log" || bad "a log appeared for a TaskStop of nothing" "$(ls "$STATE")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "4. a SendMessage that resumes an agent closes the entry; finishing again lists it again"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
finish a3 "Two red Jev-patch UI tests"
ask
case "$LINE" in '1 finished agent still open: a3 ('*) ok "a3 is listed" ;; *) bad "a3 not listed" "$LINE" ;; esac
fire "$CMD_DONE" "$(send_message a3)"
ask
silent && ok "SendMessage to a3: it is live again, the prompt is silent" || bad "a resumed agent is still listed" "$LINE"
fire "$CMD_DONE" "$(send_message researcher)"
silent && ok "a SendMessage to a name that was never listed changes nothing" || bad "SendMessage to a stranger: rc=$RC out=$OUT"
finish a3 "Two red Jev-patch UI tests"
ask
case "$LINE" in '1 finished agent still open: a3 ('*) ok "a3 finishes again: listed again" ;; *) bad "a second finish was not recorded" "$LINE" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "5. zero: silent, creates nothing, starts no interpreter"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
before="$(py_calls)"
ask "00000000-0000-4000-8000-000000000000"
after="$(py_calls)"
silent && ok "a session with nothing recorded: the hook says nothing and exits 0" || bad "zero case not silent: rc=$RC out=$OUT"
[ "$before" = "$after" ] && ok "and starts no interpreter (the per-prompt cost is a file test)" || bad "an interpreter was started for an empty session ($before -> $after)"
ask
[ "$(py_calls)" = $((after + 1)) ] && ok "with an entry present the interpreter runs exactly once" || bad "interpreter launches for a populated session: $after -> $(py_calls)"
ask "../../etc/passwd"
silent && ok "a session id that is not a plain id is ignored" || bad "hostile session id on a prompt: rc=$RC out=$OUT"
GONE_HOME="$TMP/never-created"
FIRE_HOME="$GONE_HOME"; ask; FIRE_HOME="$HHOME"
silent && [ ! -e "$GONE_HOME" ] && ok "a HEIMDALL_HOME that does not exist: silent, and the prompt hook does not create it" || bad "prompt hook without a home: rc=$RC out=$OUT, home exists: $([ -e "$GONE_HOME" ] && echo yes || echo no)"
FIRE_HOME="$TMP/made-on-demand"; finish n1 "creates its home"; FIRE_HOME="$HHOME"
[ -d "$TMP/made-on-demand/finished-agents" ] && ok "the recorder creates a missing HEIMDALL_HOME" || bad "the recorder did not create a missing HEIMDALL_HOME: $(ls "$TMP/made-on-demand" 2>&1)"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "6. what is never recorded"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
finish f1 "a foreground agent" foreground 1
ask; silent && ok "a foreground agent (it answered its spawn call; nothing is listed to stop)" || bad "foreground agent recorded" "$LINE"
finish d2 "a grandchild" background 2
ask; silent && ok "a grandchild (spawnDepth 2: its parent owns it, the orchestrator's TaskStop cannot reach it)" || bad "grandchild recorded" "$LINE"
agent_files w1 background 1 "waits on a build"
fire "$CMD_STOP" "$(stop_payload w1 '[{"id":"bws24qgmh","type":"shell","status":"running","description":"sleep 240","command":"sleep 240"}]')"
ask; silent && ok "an agent that stopped with a background task still running (waiting, not finished)" || bad "a waiting agent was recorded" "$LINE"
fire "$CMD_STOP" "$(stop_payload w1 '[{"id":"bws24qgmh","type":"shell","status":"completed"}]')"
ask
case "$LINE" in '1 finished agent still open: w1 ('*) ok "the same agent once its background tasks are all done: recorded" ;; *) bad "a finished agent with only completed background tasks was not recorded" "$LINE" ;; esac
reset_state
fire "$CMD_STOP" "$(stop_payload n9)"
ask; silent && ok "an agent with no sidecar (background cannot be shown): not recorded" || bad "agent without a sidecar recorded" "$LINE"
agent_files p1 background 1 "found through the main transcript path"
fire "$CMD_STOP" "$(stop_payload p1 | jq -c 'del(.agent_transcript_path)')"
ask
case "$LINE" in '1 finished agent still open: p1 ('*) ok "no agent_transcript_path: the sidecar is found from transcript_path" ;; *) bad "sidecar fallback failed" "$LINE" ;; esac
reset_state
agent_files q1 background 1 "an older harness: no spawnDepth"
jq -c 'del(.spawnDepth)' "$PROJ/$SID/subagents/agent-q1.meta.json" > "$TMP/m.json" && mv "$TMP/m.json" "$PROJ/$SID/subagents/agent-q1.meta.json"
fire "$CMD_STOP" "$(stop_payload q1)"
ask
case "$LINE" in '1 finished agent still open: q1 ('*) ok "a sidecar without spawnDepth is a direct child" ;; *) bad "missing spawnDepth dropped the agent" "$LINE" ;; esac
fire "$CMD_STOP" "$(stop_payload 'bad id/../x')"
fire "$CMD_STOP" "$(stop_payload q1 | jq -c '.agent_id = ""')"
ask
case "$LINE" in '1 finished agent still open: q1 ('*) ok "an agent id that is not a plain id, or is empty, is ignored" ;; *) bad "odd agent ids changed the list" "$LINE" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "7. a TaskStop that fails"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
finish e1 "gone from the harness"; finish e2 "already completed"; finish e3 "stays on a transient error"
fire "$CMD_FAIL" "$(taskstop_failed e1 'No task found with ID: e1')"
silent && ok "PostToolUseFailure prints nothing and exits 0" || bad "failure hook: rc=$RC out=$OUT"
fire "$CMD_FAIL" "$(taskstop_failed e2 'Task e2 is not running (status: completed)')"
fire "$CMD_FAIL" "$(taskstop_failed e3 'EBUSY: the harness is restarting')"
ask
case "$LINE" in
  '1 finished agent still open: e3 ('*) ok "\"No task found\" and \"is not running\" take the entry off (the harness holds nothing to stop); another failure keeps it" ;;
  *) bad "failed-stop handling" "$LINE" ;;
esac
fire "$CMD_FAIL" "$(taskstop_failed e3 'Not found' | jq -c '.tool_name = "Bash"')"
ask
case "$LINE" in '1 finished agent still open: e3 ('*) ok "a failure of any tool but TaskStop is not read as one" ;; *) bad "foreign tool failure changed the list" "$LINE" ;; esac
fire "$CMD_DONE" "$(taskstop_ok e3 | jq -c '.tool_response = {is_error:true, error:"No task found"}')"
ask
case "$LINE" in '1 finished agent still open: e3 ('*) ok "a PostToolUse whose response is an error does not count as a stop" ;; *) bad "an errored TaskStop response closed the entry" "$LINE" ;; esac
fire "$CMD_DONE" "$(taskstop_ok e3 | jq -c 'del(.tool_input.task_id) | .tool_input.shell_id = "e3"')"
ask
silent && ok "the deprecated shell_id argument of TaskStop closes it too" || bad "shell_id not honoured" "$LINE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "8. the line: ages, and a cap on how many agents it names"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
mkdir -p "$STATE"; chmod 700 "$STATE"
{
  printf '{"ev":"finished","id":"old3d","ts":%d,"desc":"three days","type":"x"}\n' $((NOW - 3 * 86400 - 3600))
  printf '{"ev":"finished","id":"old2h","ts":%d,"desc":"two hours","type":"x"}\n' $((NOW - 7500))
  printf '{"ev":"finished","id":"old12m","ts":%d,"desc":"twelve minutes","type":"x"}\n' $((NOW - 725))
  printf '{"ev":"finished","id":"nodesc","ts":%d,"desc":"","type":"x"}\n' $((NOW - 61))
} > "$(log_of)"; chmod 600 "$(log_of)"
ask
case "$LINE" in *'old3d (three days, finished 3d01h ago)'*) ok "an age of days reads 3d01h" ;; *) bad "days age" "$LINE" ;; esac
case "$LINE" in *'old2h (two hours, finished 2h05m ago)'*) ok "an age of hours reads 2h05m" ;; *) bad "hours age" "$LINE" ;; esac
case "$LINE" in *'old12m (twelve minutes, finished 12m ago)'*) ok "an age of minutes reads 12m" ;; *) bad "minutes age" "$LINE" ;; esac
case "$LINE" in *'nodesc (finished 1m ago)'*) ok "no description: the age alone, no empty parentheses" ;; *) bad "empty description rendering" "$LINE" ;; esac
reset_state
seed_log "$SID" 9 cap $((NOW - 3600))
ask
case "$LINE" in '9 finished agents still open: '*) ok "nine agents: the count says 9" ;; *) bad "count with many agents" "$LINE" ;; esac
named="$(printf '%s' "$LINE" | grep -o 'cap[0-9]\{4\} (' | wc -l | tr -d ' ')"
[ "$named" = 6 ] && ok "only six are named" || bad "the line names $named agents, expected 6" "$LINE"
case "$LINE" in *'(+3 more: hmd agents finished list)'*) ok "the rest are counted, with where to see them" ;; *) bad "the remainder is not pointed at" "$LINE" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "9. hygiene: private, bounded, expiring, hostile input"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
finish h1 "private state"
[ "$(mode_of "$STATE")" = 700 ] && [ "$(mode_of "$(log_of)")" = 600 ] \
  && ok "the directory is 0700 and the log 0600" || bad "modes: dir $(mode_of "$STATE"), log $(mode_of "$(log_of)")"
reset_state
seed_log "$SID" 400 seed $((NOW - 3600))
[ "$(wc -c < "$(log_of)" | tr -d ' ')" -gt 32768 ] || bad "fixture: the seeded log is not past the compaction size"
finish anew "the one that tips it over"
lines="$(grep -c '' "$(log_of)")"
[ "$lines" = 100 ] && ok "a log past 32 KiB is rewritten as its newest 100 open entries" || bad "after compaction the log has $lines lines, expected 100"
grep -q '"id":"anew"' "$(log_of)" && grep -q '"id":"seed0400"' "$(log_of)" && ! grep -q '"id":"seed0301"' "$(log_of)" \
  && ok "compaction keeps the newest (the new entry and seed0400) and drops the oldest (seed0301)" || bad "compaction kept the wrong entries"
[ "$(mode_of "$(log_of)")" = 600 ] && ok "the compacted log is 0600" || bad "compacted log mode $(mode_of "$(log_of)")"
reset_state
OLD_SID="aaaaaaaa-0000-4000-8000-000000000001"
seed_log "$OLD_SID" 1 gone $((NOW - 8 * 86400))
ask "$OLD_SID"
silent && [ ! -e "$(log_of "$OLD_SID")" ] && ok "an entry older than 7 days is forgotten, and a log with nothing left is removed" || bad "expired entry still listed or its log kept" "$LINE"
STALE_SID="bbbbbbbb-0000-4000-8000-000000000002"
seed_log "$STALE_SID" 1 stale $((NOW - 60))
perl -e 'my $t = time - 8 * 86400; utime $t, $t, $ARGV[0]' "$(log_of "$STALE_SID")"
finish k1 "a record prunes other sessions' stale logs"
[ ! -e "$(log_of "$STALE_SID")" ] && [ -e "$(log_of)" ] && ok "recording prunes another session's log untouched for 8 days and keeps its own" || bad "pruning: stale log $([ -e "$(log_of "$STALE_SID")" ] && echo kept || echo gone), own log $([ -e "$(log_of)" ] && echo kept || echo gone)"
before="$(ls "$STATE" | tr '\n' ' ')"
fire "$CMD_STOP" "$(stop_payload k1 | jq -c '.session_id = "../../evil"')"
[ "$(ls "$STATE" | tr '\n' ' ')" = "$before" ] && [ ! -e "$TMP/evil.jsonl" ] && [ ! -e "$HHOME/../evil.jsonl" ] \
  && ok "a hostile session id writes nothing, nowhere" || bad "hostile session id left something behind" "$(ls "$STATE")"
reset_state
agent_files c1 background 1 "$(printf 'alpha\nbeta \033[31mred %0200d' 0)"
fire "$CMD_STOP" "$(stop_payload c1)"
run_tool list --json
printf '%s' "$OUT" | jq -e '.[0].description | (explode | all((. >= 32 and . < 127) or . > 159)) and length <= 120 and startswith("alpha beta ")' >/dev/null 2>&1 \
  && ok "a description is one line, without control characters, at most 120 characters" || bad "description not sanitised" "$OUT"
ask
case "$LINE" in *"$(printf '\033')"*) bad "an escape character reached the model-facing line" ;; *) ok "no escape character reaches the model-facing line" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "10. the CLI"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
finish l1 "first listed"; finish l2 "second listed"
run_tool list --json
printf '%s' "$OUT" | jq -e --arg sid "$SID" 'length == 2 and .[0].id == "l1" and .[0].session == $sid and .[0].description == "first listed"
  and .[0].agent_type == "hmd:coder" and (.[0].finished_at | type == "number") and (.[0].age_secs | type == "number" and . >= 0)' >/dev/null 2>&1 \
  && ok "list --json: id, session, description, agent_type, finished_at, age_secs, oldest first" || bad "list --json shape" "$OUT"
run_tool list
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'l1' && printf '%s' "$OUT" | grep -q 'second listed' && printf '%s' "$OUT" | grep -q "${SID%%-*}" \
  && ok "list: a readable table with the ids, the descriptions and the session" || bad "list output" "$OUT"
run_tool
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'l2' && ok "no verb is list" || bad "bare invocation is not list" "$OUT"
run_tool list --session "00000000-0000-4000-8000-0000000000ff"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qi 'no finished agents' && ok "list --session of a session with none: says so, exit 0" || bad "empty list message" "$OUT"
run_tool clear
[ "$RC" = 2 ] && [ -e "$(log_of)" ] && ok "clear with no scope is a usage error (exit 2) and clears nothing" || bad "bare clear: rc=$RC" "$OUT"
run_tool clear --id l1
printf '%s' "$OUT" | grep -q 'cleared 1' && ok "clear --id forgets one entry" || bad "clear --id output" "$OUT"
run_tool list --json
printf '%s' "$OUT" | jq -e 'length == 1 and .[0].id == "l2"' >/dev/null 2>&1 && ok "and only that one" || bad "clear --id removed the wrong entries" "$OUT"
run_tool clear --session "$SID"
printf '%s' "$OUT" | grep -q 'cleared 1' && [ ! -e "$(log_of)" ] && ok "clear --session forgets a session's entries and removes its log" || bad "clear --session" "$OUT"
finish l3 "third"; OTHER_SID="cccccccc-0000-4000-8000-000000000003"; seed_log "$OTHER_SID" 2 oth $((NOW - 600))
run_tool clear --all
printf '%s' "$OUT" | grep -q 'cleared 3' && run_tool list --json && [ "$OUT" = '[]' ] && ok "clear --all forgets every session's entries" || bad "clear --all" "$OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "11. hmd agents finished"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
FAKE="$TMP/plugin"; mkdir -p "$FAKE/bin" "$FAKE/.claude-plugin" "$TMP/fhome"
cp "$REPO/bin/heimdall" "$FAKE/bin/heimdall"; chmod +x "$FAKE/bin/heimdall"
touch "$TMP/fhome/setup-done"
STUB_OUT="$TMP/stub-out"
for stub in heimdall-finished-agents heimdall-bg-sessions; do
  cat > "$FAKE/bin/$stub" <<EOF
#!/usr/bin/env bash
printf '%s ARGS:%s\n' "$stub" "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOF
  chmod +x "$FAKE/bin/$stub"
done
run_hmd() {
  : > "$STUB_OUT"
  ( cd "$USERHOME" && PATH="$FAKE/bin:$PATH" HEIMDALL_HOME="$TMP/fhome" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 \
    HMD_STUB_OUT="$STUB_OUT" bash "$FAKE/bin/heimdall" "$@" >/dev/null 2>&1 )
  RC=$?
}
run_hmd agents finished list --json
[ "$(cat "$STUB_OUT")" = 'heimdall-finished-agents ARGS:list --json' ] && ok "hmd agents finished list --json -> the tool, arguments forwarded verbatim" || bad "dispatch of agents finished" "$(cat "$STUB_OUT")"
run_hmd agents finished
[ "$(cat "$STUB_OUT")" = 'heimdall-finished-agents ARGS:' ] && ok "hmd agents finished -> the tool with no arguments (it lists)" || bad "bare agents finished" "$(cat "$STUB_OUT")"
run_hmd agents finished clear --id a1
[ "$(cat "$STUB_OUT")" = 'heimdall-finished-agents ARGS:clear --id a1' ] && ok "hmd agents finished clear --id a1 -> forwarded" || bad "agents finished clear" "$(cat "$STUB_OUT")"
run_hmd agents
case "$(cat "$STUB_OUT")" in 'heimdall-bg-sessions ARGS:list --dir '*) ok "hmd agents is still the background-session list" ;; *) bad "hmd agents no longer reaches heimdall-bg-sessions" "$(cat "$STUB_OUT")" ;; esac
run_hmd agents --all
case "$(cat "$STUB_OUT")" in 'heimdall-bg-sessions ARGS:list --dir '*' --all') ok "hmd agents ARGS still forwarded to the background-session list" ;; *) bad "hmd agents --all" "$(cat "$STUB_OUT")" ;; esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "12. fail-open"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
reset_state
junk_bad=""
for verb in subagent-stop tool-done tool-failed prompt; do
  for junk in '' 'not json at all' '[1,2,3]' '{"session_id":7}' '{"session_id":"s","agent_id":{"x":1},"tool_input":"no","background_tasks":"no"}'; do
    OUT="$(printf '%s' "$junk" | env HEIMDALL_HOME="$HHOME" HOME="$USERHOME" HMD_PYTHON="$TMP/py-stub" "$TOOL" "$verb" 2>/dev/null)"; RC=$?
    { [ "$RC" = 0 ] && [ -z "$OUT" ]; } || junk_bad="$junk_bad $verb<${junk:-empty}>(rc=$RC)"
  done
done
[ -z "$junk_bad" ] && [ ! -e "$STATE" ] && ok "empty, garbage and wrong-shape payloads on every hook verb: exit 0, no output, no state" || bad "junk payloads" "$junk_bad $(ls "$STATE" 2>&1)"
if [ "$(id -u)" != 0 ]; then
  RO="$TMP/ro-home"; mkdir -p "$RO"; chmod 500 "$RO"
  agent_files r1 background 1 "cannot be written"
  OUT="$(stop_payload r1 | env HEIMDALL_HOME="$RO" HOME="$USERHOME" HMD_PYTHON="$TMP/py-stub" "$TOOL" subagent-stop 2>"$TMP/stderr")"; RC=$?
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ -s "$TMP/stderr" ] && ! ls "$RO"/* >/dev/null 2>&1 \
    && ok "an unwritable HEIMDALL_HOME: exit 0, nothing recorded, one line on stderr says why" || bad "unwritable home: rc=$RC out=$OUT stderr=$(cat "$TMP/stderr")"
  chmod 700 "$RO"
else
  ok "unwritable home: skipped (running as root)"
fi
KS="$TMP/ks-home"; mkdir -p "$KS"; printf 'finished-agents-record\n' > "$KS/hooks-disabled"
agent_files s1 background 1 "switched off"
FIRE_HOME="$KS"; fire "$CMD_STOP" "$(stop_payload s1)"; FIRE_HOME="$HHOME"
[ "$RC" = 0 ] && [ ! -e "$KS/finished-agents" ] && ok "hmd hooks disable finished-agents-record: the SubagentStop hook records nothing" || bad "kill switch ignored" "$(ls "$KS")"
printf 'finished-agents-prompt\n' > "$KS/hooks-disabled"
seed_log "$SID" 1 ks $((NOW - 60)); cp -R "$STATE" "$KS/finished-agents"
FIRE_HOME="$KS"; ask; FIRE_HOME="$HHOME"
silent && ok "hmd hooks disable finished-agents-prompt: the line is not printed" || bad "prompt kill switch ignored" "$LINE"
FIRE_HOME="$HHOME"; ask
[ -n "$LINE" ] && ok "(and the same state is named without the switch)" || bad "control for the prompt kill switch failed"
bash -n "$TOOL" 2>/dev/null && ok "bin/heimdall-finished-agents passes bash -n" || bad "bin/heimdall-finished-agents has a syntax error"
"$REAL_PY" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$REPO/bin/lib/hmd_finished_agents.py" 2>/dev/null \
  && ok "bin/lib/hmd_finished_agents.py parses" || bad "bin/lib/hmd_finished_agents.py is missing or has a syntax error"

printf '\n  finished-agents: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
