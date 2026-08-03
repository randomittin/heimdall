#!/usr/bin/env bash
# test/heimdall-agents.test.sh — falsifiable acceptance for bin/heimdall-agents.
#
# The tool's whole value is an HONEST live-subagent count plus an automatic,
# never-destructive cleanup. Four failure modes matter, in this order:
#
#   1. REAPING A GENUINELY LIVE AGENT — catastrophic. A subagent that is awaiting
#      a tool result (a 40-minute build, a long test run) has an OLD mtime but is
#      perfectly alive. The tool MUST classify it `working` and MUST NEVER reap
#      it. Fixture agent `acdetrain-…` is exactly that case.
#   2. BURYING A SUCCESS. An agent that finished, emitted its task-notification
#      and had its work merged must NEVER be reported `orphaned`. `orphaned`
#      means "provably dead with nothing to show"; a completion is the opposite.
#      The notification in the PARENT transcript is the authoritative evidence.
#   3. MISSING THE LEAK ENTIRELY. A parked mailbox teammate NEVER gets a task-dir
#      `.output` entry — it exists ONLY as a transcript + `.meta.json` under
#      <projects>/<slug>/<session>/subagents/. Enumerating the task dir alone is
#      blind to the exact agents the tool exists to surface.
#   4. LYING ABOUT A KILL — or about a remedy. NOTHING outside the harness can
#      terminate a parked teammate, so the tool must never claim it killed one.
#      It must exclude it from the live count and name the mechanisms that DO
#      clear it (TaskStop, /tasks, session restart) — without the two opposite
#      overstatements: that a restart is the ONLY way (false since Claude Code
#      2.1.198+ shipped TaskStop), or that TaskStop is PROVEN (unexercised —
#      agent definitions load at session start). Section (8) locks both edges.
#
# THE FIXTURE MIRRORS SHAPES READ OFF DISK ON 2026-08-03, not invention:
#
#   task dir   <tmp>/claude-501/<slug>/<TASK-SESSION>/tasks/<id>.output
#              → symlink CROSS-SESSION into
#              <projects>/<slug>/<AGENT-SESSION>/subagents/agent-<id>.jsonl
#              (measured: task dir lived under session 2ac8810f while every
#               transcript it linked lived under session da3a8887)
#   regular meta.json  {"agentType":"hmd:coder","worktreePath":…,"worktreeBranch":…,
#                       "description":…,"toolUseId":"toolu_…","spawnDepth":1,
#                       "model":"opus"}                     ← NO taskKind key
#   teammate meta.json {"agentType":"termprobe","description":…,"name":"termprobe",
#                       "spawnDepth":0,"model":"haiku",
#                       "taskKind":"in_process_teammate",
#                       "teamName":"session-2ac8810f","color":"blue",
#                       "planModeRequired":false,
#                       "permissionMode":"bypassPermissions"}
#   named agent id     a<name>-<16 hex>   e.g. atermprobe-f3e1380058f70da5
#   completion proof   a top-level {"type":"queue-operation","operation":"enqueue",
#                       …,"content":"<task-notification>\n<task-id>ID</task-id>\n
#                       <tool-use-id>…</tool-use-id>\n<output-file>…</output-file>\n
#                       <status>completed</status>\n<summary>…</summary>…"}
#                      record in <projects>/<slug>/<AGENT-SESSION>.jsonl
#                      (measured statuses: completed | failed | killed)
#   background bash    plain file, id b+8 alnum, no agent metadata at all
#
# Hermetic: HMD_AGENT_TASKDIR + HMD_AGENT_PROJECTS_DIR point at the fixture;
# HMD_AGENT_REAPED_FILE isolates the registry; HMD_NOW pins "now";
# HMD_AGENT_LIVE_SLUGS replaces the pgrep/lsof probe so no real process table is
# ever consulted.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS="$ROOT/bin/heimdall-agents"

[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-agents-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SLUG="-Users-rj-Downloads-testproj"
# Two DIFFERENT sessions, exactly as measured: the task dir belongs to one
# session, the transcripts it symlinks belong to another.
TSESS="2ac8810f-4913-4eda-bc68-8edffb1d5a42"
ASESS="da3a8887-1f95-4283-b2e0-38175ca264e5"
TASKDIR="$WORK/claude-501/$SLUG/$TSESS/tasks"
PROJDIR="$WORK/projects"
SUBDIR="$PROJDIR/$SLUG/$ASESS/subagents"
PARENT="$PROJDIR/$SLUG/$ASESS.jsonl"
REAPED="$WORK/agents-reaped.json"
mkdir -p "$TASKDIR" "$SUBDIR"
: > "$PARENT"

NOW=2000000000
export HMD_NOW="$NOW"
export HMD_AGENT_STALE_SECS=900
export HMD_AGENT_HUNG_SECS=3600
export HMD_AGENT_TASKDIR="$TASKDIR"
export HMD_AGENT_PROJECTS_DIR="$PROJDIR"
export HMD_AGENT_REAPED_FILE="$REAPED"
# World A: the owning session IS alive (its slug is in the live list).
export HMD_AGENT_LIVE_SLUGS="$SLUG"

# Portable mtime setter: GNU (touch -d @epoch) first, BSD (date -r → touch -t).
set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

TOOL_USE_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"tu_1"}]}}'
END_TURN_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Report complete."}]}}'

# mk_agent <id> <age_secs> <last: tool|end> [taskKind] [name] [no_output]
# Builds transcript + .meta.json sidecar and (unless no_output) the CROSS-SESSION
# task-dir symlink, exactly as the harness lays them out. Back-dates the
# TRANSCRIPT because the symlink is followed for mtime.
mk_agent() {
  local id="$1" age="$2" last="$3" kind="${4:-}" name="${5:-}" noout="${6:-}" j m
  j="$SUBDIR/agent-$id.jsonl"
  m="$SUBDIR/agent-$id.meta.json"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    if [ "$last" = "tool" ]; then printf '%s\n' "$TOOL_USE_EV"; else printf '%s\n' "$END_TURN_EV"; fi
  } > "$j"
  if [ -n "$kind" ]; then
    # Real teammate sidecar: name + taskKind + teamName + the extra harness keys.
    jq -n --arg k "$kind" --arg n "$name" \
      '{agentType:$n, description:"fixture teammate", name:$n, spawnDepth:0,
        model:"haiku", taskKind:$k, teamName:"session-2ac8810f", color:"blue",
        planModeRequired:false, permissionMode:"bypassPermissions"}' > "$m"
  else
    # Real regular-subagent sidecar: NO taskKind key at all.
    jq -n --arg i "$id" \
      '{agentType:"hmd:coder",
        worktreePath:("/Users/rj/Downloads/heimdall/.claude/worktrees/agent-"+$i),
        worktreeBranch:("worktree-agent-"+$i),
        description:"fixture", toolUseId:"toolu_01FixtureToolUseId00",
        spawnDepth:1, model:"opus"}' > "$m"
  fi
  [ -n "$noout" ] || ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# mk_notif <id> <status> — append the authoritative completion record to the
# PARENT session transcript, in the harness's exact queue-operation shape.
mk_notif() {
  local id="$1" status="$2" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>%s</status>\n<summary>Agent "fixture" finished</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TASKDIR" "$id" "$status")"
  jq -nc --arg c "$body" --arg s "$ASESS" \
    '{type:"queue-operation", operation:"enqueue",
      timestamp:"2026-08-03T16:52:00.000Z", sessionId:$s, content:$c}' >> "$PARENT"
}

# ── fixture ───────────────────────────────────────────────────────────────────
A_LIVE="a1111111111111111";  mk_agent "$A_LIVE"  10   end          # fresh regular
A_STALE="a2222222222222222"; mk_agent "$A_STALE" 5000 end          # stale, no notif
A_FAIL="a3333333333333333";  mk_agent "$A_FAIL"  10   end          # fresh…
printf 'failed\n' > "$TASKDIR/$A_FAIL.status"                      # …but terminal
A_MBOX="ave-server-4444444444444444"
mk_agent "$A_MBOX"  5000 end  in_process_teammate ve-server        # parked, HAS .output
A_WORK="acdetrain-5555555555555555"
mk_agent "$A_WORK"  1000 tool in_process_teammate cdetrain         # STALE-AGED BUT WORKING
A_HUNG="a6666666666666666";  mk_agent "$A_HUNG"  99999 tool        # wedged on one tool

# DEFECT 1 — completed agents. Both finished long ago and emitted a real
# task-notification; their work was merged. They must read `done`, NEVER
# `orphaned`, in BOTH the alive-session and dead-session worlds.
A_DONE="a62afb613a618761a";  mk_agent "$A_DONE" 4000 end; mk_notif "$A_DONE" completed
A_DONE2="aba9f5e0e568348c1"; mk_agent "$A_DONE2" 4000 end; mk_notif "$A_DONE2" completed
# Measured third status: the harness also emits `killed`.
A_KILL="a8888888888888888";  mk_agent "$A_KILL" 4000 end; mk_notif "$A_KILL" killed

# DEFECT 2 — the parked mailbox teammate with NO `.output` entry AT ALL. This is
# the real `termprobe`: it exists only as transcript + sidecar in the subagents
# dir. Enumerating the task dir alone cannot see it.
A_PARKED="atermprobe-f3e1380058f70da5"
mk_agent "$A_PARKED" 300 end in_process_teammate termprobe no_output

# A background BASH task: same dir, b+8 id, plain file, no agent metadata at all.
B_BASH="b0eqc6c3i"
printf 'resume started\n' > "$TASKDIR/$B_BASH.output"
set_mtime "$TASKDIR/$B_BASH.output" $(( NOW - 4000 ))

state_of() { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.state'; }
name_of()  { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.name'; }

# ── (1) classification ────────────────────────────────────────────────────────
[ "$(state_of "$A_LIVE")"  = "live"    ] && ok "fresh regular subagent → live"      || bad "expected live, got '$(state_of "$A_LIVE")'"
[ "$(state_of "$A_STALE")" = "stale"   ] && ok "old + end_turn + no notif → stale"  || bad "expected stale, got '$(state_of "$A_STALE")'"
[ "$(state_of "$A_FAIL")"  = "failed"  ] && ok "terminal marker beats freshness"    || bad "expected failed, got '$(state_of "$A_FAIL")'"
[ "$(state_of "$A_MBOX")"  = "mailbox" ] && ok "in_process_teammate + alive session → mailbox" || bad "expected mailbox, got '$(state_of "$A_MBOX")'"
[ "$(state_of "$A_HUNG")"  = "hung"    ] && ok "awaiting one tool ≥ HUNG_SECS → hung" || bad "expected hung, got '$(state_of "$A_HUNG")'"
[ "$(name_of  "$A_MBOX")"  = "ve-server" ] && ok "mailbox agent reports its name"   || bad "expected name ve-server, got '$(name_of "$A_MBOX")'"

# ── (2) THE GUARD: old mtime but awaiting a tool result ⇒ working, never reaped ─
[ "$(state_of "$A_WORK")" = "working" ] && ok "GUARD: stale-aged but mid tool_use → working" \
  || bad "GUARD BROKEN: expected working, got '$(state_of "$A_WORK")'"

# ── (3) background Bash tasks are NOT subagents ───────────────────────────────
[ -z "$(state_of "$B_BASH")" ] && ok "background Bash task excluded from agent list" \
  || bad "bash task '$B_BASH' wrongly tracked as agent (got '$(state_of "$B_BASH")')"

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 1 — A COMPLETION MUST NEVER BE CALLED `orphaned`.
# Regression guard for: two agents that finished, emitted task-notifications and
# had their work merged were both reported `orphaned` by `list`.
# ═════════════════════════════════════════════════════════════════════════════
[ "$(state_of "$A_DONE")" = "done" ] && ok "DEFECT-1: notified completion → done" \
  || bad "DEFECT-1: expected done for completed agent, got '$(state_of "$A_DONE")'"
[ "$(state_of "$A_DONE2")" = "done" ] && ok "DEFECT-1: second completion → done" \
  || bad "DEFECT-1: expected done, got '$(state_of "$A_DONE2")'"
[ "$(state_of "$A_DONE")" != "orphaned" ] && ok "DEFECT-1: completion is NOT orphaned" \
  || bad "DEFECT-1 REGRESSION: completed agent reported orphaned"
[ "$(state_of "$A_KILL")" = "killed" ] && ok "DEFECT-1: notified kill → killed" \
  || bad "DEFECT-1: expected killed, got '$(state_of "$A_KILL")'"

# The decisive case: session PROVABLY dead, but the agent completed first. A
# completion outranks a dead session — the work happened and was returned.
DEADW="$(HMD_AGENT_REAPED_FILE="$WORK/reaped-dead.json" HMD_AGENT_LIVE_SLUGS="" "$AGENTS" list --json)"
[ "$(printf '%s' "$DEADW" | jq -r --arg i "$A_DONE" '.[]|select(.id==$i)|.state')" = "done" ] \
  && ok "DEFECT-1: completion outranks dead session (still done, not orphaned)" \
  || bad "DEFECT-1 REGRESSION: completed agent in dead session became '$(printf '%s' "$DEADW" | jq -r --arg i "$A_DONE" '.[]|select(.id==$i)|.state')'"

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 2 — THE PARKED MAILBOX TEAMMATE MUST BE VISIBLE.
# Regression guard for: `termprobe` (live, parked, no `.output` entry) was absent
# from `list` and `list --json` entirely. This is the tool's entire purpose.
# ═════════════════════════════════════════════════════════════════════════════
[ -n "$(state_of "$A_PARKED")" ] && ok "DEFECT-2: teammate with NO .output is enumerated" \
  || bad "DEFECT-2 REGRESSION: parked teammate '$A_PARKED' invisible to list --json"
[ "$(state_of "$A_PARKED")" = "mailbox" ] && ok "DEFECT-2: no-.output teammate → mailbox" \
  || bad "DEFECT-2: expected mailbox, got '$(state_of "$A_PARKED")'"
[ "$(name_of "$A_PARKED")" = "termprobe" ] && ok "DEFECT-2: parked teammate reports its name" \
  || bad "DEFECT-2: expected name termprobe, got '$(name_of "$A_PARKED")'"
# Capture first, then grep. Piping `list` straight into `grep -q` makes the
# producer take a SIGPIPE when grep exits early, and `set -o pipefail` reports
# that 141 as the assertion's result — a false RED that has nothing to do with
# the output's content.
LIST_TXT="$("$AGENTS" list)"
printf '%s' "$LIST_TXT" | grep -q "termprobe" && ok "DEFECT-2: plain-text list shows termprobe" \
  || bad "DEFECT-2 REGRESSION: plain-text list omits termprobe"

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 3 — THE `orphans` SUBCOMMAND MUST EXIST AND SURFACE THE PARKED CLASS.
# Regression guard for: `heimdall-agents orphans` → "error: unknown subcommand".
# ═════════════════════════════════════════════════════════════════════════════
ORPH_OUT="$("$AGENTS" orphans 2>&1)"; ORPH_RC=$?
[ "$ORPH_RC" = "0" ] && ok "DEFECT-3: orphans exits 0" \
  || bad "DEFECT-3 REGRESSION: orphans exit $ORPH_RC (output: $(printf '%s' "$ORPH_OUT" | head -1))"
printf '%s' "$ORPH_OUT" | grep -qi "unknown subcommand" \
  && bad "DEFECT-3 REGRESSION: orphans is not a known subcommand" \
  || ok "DEFECT-3: orphans is a recognised subcommand"
printf '%s' "$ORPH_OUT" | grep -q "termprobe" && ok "DEFECT-3: orphans surfaces termprobe" \
  || bad "DEFECT-3: orphans omitted termprobe"
ORPH_J="$("$AGENTS" orphans --json 2>/dev/null)"
[ "$(printf '%s' "$ORPH_J" | jq -r 'type')" = "array" ] && ok "DEFECT-3: orphans --json is an array" \
  || bad "DEFECT-3: orphans --json not an array"
[ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_PARKED" '[.[]|select(.id==$i)]|length')" = "1" ] \
  && ok "DEFECT-3: orphans --json includes the parked teammate" \
  || bad "DEFECT-3: orphans --json missing parked teammate"
# A completion is NOT an orphan — the defect-1 and defect-3 fixes must agree.
[ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_DONE" '[.[]|select(.id==$i)]|length')" = "0" ] \
  && ok "DEFECT-3: orphans excludes completed agents" \
  || bad "DEFECT-3: orphans wrongly lists a completed agent"
# Never surface a genuinely live/working agent as an orphan.
[ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_WORK" '[.[]|select(.id==$i)]|length')" = "0" ] \
  && ok "GUARD: orphans excludes the working agent" \
  || bad "GUARD BROKEN: orphans lists a working agent"

# ── (4) count is LIVE-only (live + working) ──────────────────────────────────
C="$("$AGENTS" count)"
[ "$C" = "2" ] && ok "count==2 (live + working only)" || bad "count expected 2, got '$C'"

# ── (5) reap records the terminal/parked ones, NEVER the live or working ─────
"$AGENTS" reap >/dev/null
[ "$(jq -r --arg i "$A_STALE" '.[$i].reason // ""' "$REAPED")" = "stale" ]   && ok "stale recorded reason=stale"     || bad "stale not recorded"
[ "$(jq -r --arg i "$A_FAIL"  '.[$i].reason // ""' "$REAPED")" = "failed" ]  && ok "failed recorded reason=failed"   || bad "failed not recorded"
[ "$(jq -r --arg i "$A_HUNG"  '.[$i].reason // ""' "$REAPED")" = "hung" ]    && ok "hung recorded reason=hung"       || bad "hung not recorded"
[ "$(jq -r --arg i "$A_MBOX"  '.[$i].reason // ""' "$REAPED")" = "mailbox-parked" ] && ok "mailbox recorded reason=mailbox-parked" || bad "mailbox not recorded"
[ "$(jq -r --arg i "$A_DONE"  '.[$i].reason // ""' "$REAPED")" = "done" ]    && ok "completed recorded reason=done"  || bad "completed not recorded as done"
[ "$(jq -r --arg i "$A_LIVE"  '.[$i] // "absent"' "$REAPED")" = "absent" ]   && ok "GUARD: live agent NEVER reaped"  || bad "GUARD BROKEN: live agent was reaped"
[ "$(jq -r --arg i "$A_WORK"  '.[$i] // "absent"' "$REAPED")" = "absent" ]   && ok "GUARD: working agent NEVER reaped" || bad "GUARD BROKEN: working agent was reaped"

# ── (6) post-reap: count unchanged; reaped ones show state=reaped ────────────
C2="$("$AGENTS" count)"
[ "$C2" = "2" ] && ok "post-reap count STILL 2 (live+working untouched)" || bad "post-reap count expected 2, got '$C2'"
[ "$(state_of "$A_STALE")" = "reaped" ] && ok "stale now shows reaped"   || bad "stale not reaped (got '$(state_of "$A_STALE")')"
[ "$(state_of "$A_MBOX")"  = "reaped" ] && ok "mailbox now shows reaped" || bad "mailbox not reaped (got '$(state_of "$A_MBOX")')"
[ "$(state_of "$A_WORK")"  = "working" ] && ok "working agent still working" || bad "working agent changed state"

# ── (7) idempotency ──────────────────────────────────────────────────────────
J2="$("$AGENTS" reap --json)"
[ "$J2" = "[]" ] && ok "second reap is idempotent no-op" || bad "second reap not idempotent (got '$J2')"
RN="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
[ "$RN" = "8" ] && ok "registry exactly 8 after re-reap (no drift)" || bad "registry drifted to $RN keys, expected 8"

# ── (8) sweep: reports parked mailbox + names EVERY real remedy, honestly ────
# Both edges are asserted. Understating (restart-only) is the stale claim this
# section used to enshrine; overstating (TaskStop proven) is the equal and
# opposite lie. A test that merely string-matched whatever the tool emits would
# catch neither, so every assertion below names the property, not the phrasing.
SW="$("$AGENTS" sweep 2>&1)"
printf '%s' "$SW" | grep -q "ve-server"      && ok "sweep names the parked agent"        || bad "sweep omitted parked agent name"
printf '%s' "$SW" | grep -q "TaskStop"       && ok "sweep names TaskStop as the programmatic remedy" || bad "sweep failed to name TaskStop"
printf '%s' "$SW" | grep -qi "restart"       && ok "sweep still offers session restart as fallback"  || bad "sweep dropped the restart fallback"
printf '%s' "$SW" | grep -qiE 'only a restart|restart only|restart-only' \
  && bad "sweep STILL claims restart is the only remedy" || ok "sweep no longer claims restart-only"
printf '%s' "$SW" | grep -qi 'not yet verified' \
  && ok "sweep flags TaskStop as documented-not-proven" || bad "sweep overstates TaskStop as proven"
printf '%s' "$SW" | grep -qiE 'killed the|terminated the' && bad "sweep FALSELY claims a kill" || ok "sweep never claims a kill it did not perform"
SWJ="$("$AGENTS" sweep --json 2>/dev/null)"
# CONTRACT: clearable_by is a LIST of mechanism ids, so a consumer branches on
# membership instead of parsing a sentence. The old scalar "session restart only"
# must be gone AND the list must actually name the mechanism that replaced it.
[ "$(printf '%s' "$SWJ" | jq -r '.clearable_by | type')" = "array" ] \
  && ok "sweep --json clearable_by is a machine-readable list" \
  || bad "clearable_by not a list (got type '$(printf '%s' "$SWJ" | jq -r '.clearable_by|type')')"
printf '%s' "$SWJ" | jq -e '.clearable_by | index("TaskStop")' >/dev/null 2>&1 \
  && ok "sweep --json clearable_by names TaskStop" || bad "clearable_by omits TaskStop"
# `type=="array" and` is load-bearing: jq's `length` on the old scalar returns the
# STRING length (20), which would sail past a bare `>= 2` and green-light exactly
# the claim this asserts is gone.
printf '%s' "$SWJ" | jq -e '.clearable_by | type == "array" and length >= 2' >/dev/null 2>&1 \
  && ok "sweep --json offers more than one mechanism (not restart-only)" \
  || bad "clearable_by lists fewer than 2 mechanisms — the restart-only claim survives"
printf '%s' "$SWJ" | jq -e '.clearable_by | index("session-restart")' >/dev/null 2>&1 \
  && ok "sweep --json keeps session-restart as fallback" || bad "clearable_by dropped session-restart"
# Honesty tripwire: TaskStop is documented, NOT verified end to end. It must be
# absent from the verified subset until a run proves it — so the upgrade is a
# deliberate act that turns this assertion red, never a silent wording drift.
printf '%s' "$SWJ" | jq -e '.clearable_by_verified | index("TaskStop") | not' >/dev/null 2>&1 \
  && ok "sweep --json does NOT claim TaskStop is verified" || bad "clearable_by_verified overstates TaskStop as proven"
printf '%s' "$SWJ" | jq -e '.clearable_by_verified | index("session-restart")' >/dev/null 2>&1 \
  && ok "sweep --json marks session-restart as the verified mechanism" || bad "clearable_by_verified omits session-restart"
[ "$(printf '%s' "$SWJ" | jq -r '.parked_mailbox|length')" -ge 1 ] && ok "sweep --json lists parked mailbox agents" || bad "sweep --json parked list empty"

# ── (9) sweep is idempotent and safe to re-run ──────────────────────────────
RN_BEFORE="$(jq 'keys|length' "$REAPED")"
"$AGENTS" sweep >/dev/null 2>&1
"$AGENTS" sweep >/dev/null 2>&1
RN_AFTER="$(jq 'keys|length' "$REAPED")"
[ "$RN_BEFORE" = "$RN_AFTER" ] && ok "sweep idempotent across repeat runs" || bad "sweep drifted registry $RN_BEFORE → $RN_AFTER"
C3="$("$AGENTS" count)"
[ "$C3" = "2" ] && ok "count stable after repeated sweeps" || bad "count drifted to '$C3'"

# ── (10) explicit opt-out ───────────────────────────────────────────────────
OUT="$(HMD_AGENT_NO_SWEEP=1 "$AGENTS" sweep 2>&1)"
printf '%s' "$OUT" | grep -q "disabled" && ok "HMD_AGENT_NO_SWEEP=1 disables sweep" || bad "opt-out not honoured"

# ── (11) World B: owning session process is GONE ⇒ provably dead ⇒ orphaned ──
REAPED_B="$WORK/reaped-b.json"
ORPH="$(HMD_AGENT_REAPED_FILE="$REAPED_B" HMD_AGENT_LIVE_SLUGS="" "$AGENTS" list --json)"
[ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')" = "orphaned" ] \
  && ok "dead session ⇒ un-notified stale agent → orphaned" || bad "expected orphaned for stale in dead session"
[ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_MBOX" '.[]|select(.id==$i)|.state')" = "orphaned" ] \
  && ok "dead session ⇒ parked teammate → orphaned (provably gone)" || bad "expected orphaned for mailbox in dead session"
[ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_WORK" '.[]|select(.id==$i)|.state')" = "working" ] \
  && ok "GUARD: working agent stays working even in dead-session world" \
  || bad "GUARD BROKEN: working agent reclassified in dead-session world"

# ── (11b) LIVENESS EVIDENCE: a freshly-written session transcript proves the
# session is alive. Measured root cause of defect 1: `pgrep -x claude` + lsof cwd
# could not see the very session that was running (2 claude pids, neither with a
# heimdall cwd), so every agent under it fell through to `orphaned`. The parent
# transcript's mtime is the reliable, read-only liveness signal.
LIVEPROBE="$WORK/liveprobe"; mkdir -p "$LIVEPROBE/$SLUG/$ASESS/subagents"
cp "$SUBDIR/agent-$A_STALE.jsonl" "$LIVEPROBE/$SLUG/$ASESS/subagents/" 2>/dev/null
cp "$SUBDIR/agent-$A_STALE.meta.json" "$LIVEPROBE/$SLUG/$ASESS/subagents/" 2>/dev/null
set_mtime "$LIVEPROBE/$SLUG/$ASESS/subagents/agent-$A_STALE.jsonl" $(( NOW - 5000 ))
: > "$LIVEPROBE/$SLUG/$ASESS.jsonl"; set_mtime "$LIVEPROBE/$SLUG/$ASESS.jsonl" $(( NOW - 5 ))
LP="$(HMD_AGENT_PROJECTS_DIR="$LIVEPROBE" HMD_AGENT_REAPED_FILE="$WORK/reaped-lp.json" \
      env -u HMD_AGENT_LIVE_SLUGS "$AGENTS" list --json 2>/dev/null)"
[ "$(printf '%s' "$LP" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')" = "stale" ] \
  && ok "fresh session transcript ⇒ session alive ⇒ stale, not orphaned" \
  || bad "fresh-transcript liveness ignored: got '$(printf '%s' "$LP" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')'"

# ── (12) degraded honesty: unreadable / missing inputs must not crash or lie ──
CZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" count)"
[ "$CZERO" = "0" ] && ok "absent task dir → count 0 (fail-closed)" || bad "absent task dir count expected 0, got '$CZERO'"
LZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" list)"
printf '%s' "$LZERO" | grep -q "no tracked subagents" && ok "absent task dir → honest empty list" || bad "absent task dir list wrong"
SZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" sweep 2>&1)"; SZ_RC=$?
[ "$SZ_RC" = "0" ] && ok "sweep exits 0 on absent task dir" || bad "sweep exit $SZ_RC on absent task dir"
OZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" orphans 2>&1)"; OZ_RC=$?
[ "$OZ_RC" = "0" ] && ok "orphans exits 0 on absent task dir" || bad "orphans exit $OZ_RC on absent task dir"

# Transcript deleted out from under us: metadata gone, must degrade not crash.
BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
ln -sf "$WORK/no-such-transcript.jsonl" "$BROKEN/a7777777777777777.output"
BOUT="$(HMD_AGENT_TASKDIR="$BROKEN" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" list --json 2>/dev/null)"
[ "$(printf '%s' "$BOUT" | jq -r 'type')" = "array" ] && ok "dangling transcript → valid JSON, no crash" || bad "dangling transcript produced invalid output"
BC="$(HMD_AGENT_TASKDIR="$BROKEN" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" count 2>/dev/null)"
case "$BC" in ''|*[!0-9]*) bad "dangling transcript count not numeric: '$BC'" ;; *) ok "dangling transcript → numeric count ($BC)" ;; esac

# Unreadable registry must not wedge the tool.
BADREG="$WORK/corrupt.json"; printf 'not json at all\n' > "$BADREG"
CR="$(HMD_AGENT_REAPED_FILE="$BADREG" "$AGENTS" count 2>/dev/null)"
case "$CR" in ''|*[!0-9]*) bad "corrupt registry broke count: '$CR'" ;; *) ok "corrupt registry → count still numeric ($CR)" ;; esac

# Corrupt / truncated parent transcript must not break classification.
CORRUPTP="$WORK/corruptproj"; mkdir -p "$CORRUPTP/$SLUG/$ASESS/subagents"
cp "$SUBDIR/agent-$A_DONE.jsonl" "$CORRUPTP/$SLUG/$ASESS/subagents/" 2>/dev/null
cp "$SUBDIR/agent-$A_DONE.meta.json" "$CORRUPTP/$SLUG/$ASESS/subagents/" 2>/dev/null
printf '{"type":"queue-operation","content":"<task-notification>\n<task-id>trunc\n' > "$CORRUPTP/$SLUG/$ASESS.jsonl"
CPOUT="$(HMD_AGENT_PROJECTS_DIR="$CORRUPTP" HMD_AGENT_REAPED_FILE="$WORK/reaped-cp.json" "$AGENTS" list --json 2>/dev/null)"
[ "$(printf '%s' "$CPOUT" | jq -r 'type')" = "array" ] && ok "truncated parent transcript → valid JSON, no crash" || bad "truncated parent transcript broke list"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
