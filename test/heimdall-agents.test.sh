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
if [ "$(state_of "$A_LIVE")"  = "live"    ]; then ok "fresh regular subagent → live"; else bad "expected live, got '$(state_of "$A_LIVE")'"; fi
if [ "$(state_of "$A_STALE")" = "stale"   ]; then ok "old + end_turn + no notif → stale"; else bad "expected stale, got '$(state_of "$A_STALE")'"; fi
if [ "$(state_of "$A_FAIL")"  = "failed"  ]; then ok "terminal marker beats freshness"; else bad "expected failed, got '$(state_of "$A_FAIL")'"; fi
if [ "$(state_of "$A_MBOX")"  = "mailbox" ]; then ok "in_process_teammate + alive session → mailbox"; else bad "expected mailbox, got '$(state_of "$A_MBOX")'"; fi
if [ "$(state_of "$A_HUNG")"  = "hung"    ]; then ok "awaiting one tool ≥ HUNG_SECS → hung"; else bad "expected hung, got '$(state_of "$A_HUNG")'"; fi
if [ "$(name_of  "$A_MBOX")"  = "ve-server" ]; then ok "mailbox agent reports its name"; else bad "expected name ve-server, got '$(name_of "$A_MBOX")'"; fi

# ── (2) THE GUARD: old mtime but awaiting a tool result ⇒ working, never reaped ─
if [ "$(state_of "$A_WORK")" = "working" ]; then
  ok "GUARD: stale-aged but mid tool_use → working"
else
  bad "GUARD BROKEN: expected working, got '$(state_of "$A_WORK")'"
fi

# ── (3) background Bash tasks are NOT subagents ───────────────────────────────
if [ -z "$(state_of "$B_BASH")" ]; then
  ok "background Bash task excluded from agent list"
else
  bad "bash task '$B_BASH' wrongly tracked as agent (got '$(state_of "$B_BASH")')"
fi

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 1 — A COMPLETION MUST NEVER BE CALLED `orphaned`.
# Regression guard for: two agents that finished, emitted task-notifications and
# had their work merged were both reported `orphaned` by `list`.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$(state_of "$A_DONE")" = "done" ]; then
  ok "DEFECT-1: notified completion → done"
else
  bad "DEFECT-1: expected done for completed agent, got '$(state_of "$A_DONE")'"
fi
if [ "$(state_of "$A_DONE2")" = "done" ]; then
  ok "DEFECT-1: second completion → done"
else
  bad "DEFECT-1: expected done, got '$(state_of "$A_DONE2")'"
fi
if [ "$(state_of "$A_DONE")" != "orphaned" ]; then
  ok "DEFECT-1: completion is NOT orphaned"
else
  bad "DEFECT-1 REGRESSION: completed agent reported orphaned"
fi
if [ "$(state_of "$A_KILL")" = "killed" ]; then
  ok "DEFECT-1: notified kill → killed"
else
  bad "DEFECT-1: expected killed, got '$(state_of "$A_KILL")'"
fi

# The decisive case: session PROVABLY dead, but the agent completed first. A
# completion outranks a dead session — the work happened and was returned.
DEADW="$(HMD_AGENT_REAPED_FILE="$WORK/reaped-dead.json" HMD_AGENT_LIVE_SLUGS="" "$AGENTS" list --json)"
if [ "$(printf '%s' "$DEADW" | jq -r --arg i "$A_DONE" '.[]|select(.id==$i)|.state')" = "done" ]; then
  ok "DEFECT-1: completion outranks dead session (still done, not orphaned)"
else
  bad "DEFECT-1 REGRESSION: completed agent in dead session became '$(printf '%s' "$DEADW" | jq -r --arg i "$A_DONE" '.[]|select(.id==$i)|.state')'"
fi

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 2 — THE PARKED MAILBOX TEAMMATE MUST BE VISIBLE.
# Regression guard for: `termprobe` (live, parked, no `.output` entry) was absent
# from `list` and `list --json` entirely. This is the tool's entire purpose.
# ═════════════════════════════════════════════════════════════════════════════
if [ -n "$(state_of "$A_PARKED")" ]; then
  ok "DEFECT-2: teammate with NO .output is enumerated"
else
  bad "DEFECT-2 REGRESSION: parked teammate '$A_PARKED' invisible to list --json"
fi
if [ "$(state_of "$A_PARKED")" = "mailbox" ]; then
  ok "DEFECT-2: no-.output teammate → mailbox"
else
  bad "DEFECT-2: expected mailbox, got '$(state_of "$A_PARKED")'"
fi
if [ "$(name_of "$A_PARKED")" = "termprobe" ]; then
  ok "DEFECT-2: parked teammate reports its name"
else
  bad "DEFECT-2: expected name termprobe, got '$(name_of "$A_PARKED")'"
fi
# Capture first, then grep. Piping `list` straight into `grep -q` makes the
# producer take a SIGPIPE when grep exits early, and `set -o pipefail` reports
# that 141 as the assertion's result — a false RED that has nothing to do with
# the output's content.
LIST_TXT="$("$AGENTS" list)"
if grep -q "termprobe" <<<"$LIST_TXT"; then
  ok "DEFECT-2: plain-text list shows termprobe"
else
  bad "DEFECT-2 REGRESSION: plain-text list omits termprobe"
fi

# ═════════════════════════════════════════════════════════════════════════════
# DEFECT 3 — THE `orphans` SUBCOMMAND MUST EXIST AND SURFACE THE PARKED CLASS.
# Regression guard for: `heimdall-agents orphans` → "error: unknown subcommand".
# ═════════════════════════════════════════════════════════════════════════════
ORPH_OUT="$("$AGENTS" orphans 2>&1)"; ORPH_RC=$?
if [ "$ORPH_RC" = "0" ]; then
  ok "DEFECT-3: orphans exits 0"
else
  bad "DEFECT-3 REGRESSION: orphans exit $ORPH_RC (output: $(printf '%s' "$ORPH_OUT" | head -1))"
fi
if grep -qi "unknown subcommand" <<<"$ORPH_OUT"; then
  bad "DEFECT-3 REGRESSION: orphans is not a known subcommand"
else
  ok "DEFECT-3: orphans is a recognised subcommand"
fi
if grep -q "termprobe" <<<"$ORPH_OUT"; then
  ok "DEFECT-3: orphans surfaces termprobe"
else
  bad "DEFECT-3: orphans omitted termprobe"
fi
ORPH_J="$("$AGENTS" orphans --json 2>/dev/null)"
if [ "$(printf '%s' "$ORPH_J" | jq -r 'type')" = "array" ]; then
  ok "DEFECT-3: orphans --json is an array"
else
  bad "DEFECT-3: orphans --json not an array"
fi
if [ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_PARKED" '[.[]|select(.id==$i)]|length')" = "1" ]; then
  ok "DEFECT-3: orphans --json includes the parked teammate"
else
  bad "DEFECT-3: orphans --json missing parked teammate"
fi
# A completion is NOT an orphan — the defect-1 and defect-3 fixes must agree.
if [ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_DONE" '[.[]|select(.id==$i)]|length')" = "0" ]; then
  ok "DEFECT-3: orphans excludes completed agents"
else
  bad "DEFECT-3: orphans wrongly lists a completed agent"
fi
# Never surface a genuinely live/working agent as an orphan.
if [ "$(printf '%s' "$ORPH_J" | jq -r --arg i "$A_WORK" '[.[]|select(.id==$i)]|length')" = "0" ]; then
  ok "GUARD: orphans excludes the working agent"
else
  bad "GUARD BROKEN: orphans lists a working agent"
fi

# ── (4) count is LIVE-only (live + working) ──────────────────────────────────
C="$("$AGENTS" count)"
if [ "$C" = "2" ]; then ok "count==2 (live + working only)"; else bad "count expected 2, got '$C'"; fi

# ── (5) reap records the terminal/parked ones, NEVER the live or working ─────
"$AGENTS" reap >/dev/null
if [ "$(jq -r --arg i "$A_STALE" '.[$i].reason // ""' "$REAPED")" = "stale" ]; then ok "stale recorded reason=stale"; else bad "stale not recorded"; fi
if [ "$(jq -r --arg i "$A_FAIL"  '.[$i].reason // ""' "$REAPED")" = "failed" ]; then ok "failed recorded reason=failed"; else bad "failed not recorded"; fi
if [ "$(jq -r --arg i "$A_HUNG"  '.[$i].reason // ""' "$REAPED")" = "hung" ]; then ok "hung recorded reason=hung"; else bad "hung not recorded"; fi
if [ "$(jq -r --arg i "$A_MBOX"  '.[$i].reason // ""' "$REAPED")" = "mailbox-parked" ]; then ok "mailbox recorded reason=mailbox-parked"; else bad "mailbox not recorded"; fi
if [ "$(jq -r --arg i "$A_DONE"  '.[$i].reason // ""' "$REAPED")" = "done" ]; then ok "completed recorded reason=done"; else bad "completed not recorded as done"; fi
if [ "$(jq -r --arg i "$A_LIVE"  '.[$i] // "absent"' "$REAPED")" = "absent" ]; then ok "GUARD: live agent NEVER reaped"; else bad "GUARD BROKEN: live agent was reaped"; fi
if [ "$(jq -r --arg i "$A_WORK"  '.[$i] // "absent"' "$REAPED")" = "absent" ]; then ok "GUARD: working agent NEVER reaped"; else bad "GUARD BROKEN: working agent was reaped"; fi

# ── (6) post-reap: count unchanged; reaped ones show state=reaped ────────────
C2="$("$AGENTS" count)"
if [ "$C2" = "2" ]; then ok "post-reap count STILL 2 (live+working untouched)"; else bad "post-reap count expected 2, got '$C2'"; fi
if [ "$(state_of "$A_STALE")" = "reaped" ]; then ok "stale now shows reaped"; else bad "stale not reaped (got '$(state_of "$A_STALE")')"; fi
if [ "$(state_of "$A_MBOX")"  = "reaped" ]; then ok "mailbox now shows reaped"; else bad "mailbox not reaped (got '$(state_of "$A_MBOX")')"; fi
if [ "$(state_of "$A_WORK")"  = "working" ]; then ok "working agent still working"; else bad "working agent changed state"; fi

# ── (7) idempotency ──────────────────────────────────────────────────────────
J2="$("$AGENTS" reap --json)"
if [ "$J2" = "[]" ]; then ok "second reap is idempotent no-op"; else bad "second reap not idempotent (got '$J2')"; fi
RN="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
if [ "$RN" = "8" ]; then ok "registry exactly 8 after re-reap (no drift)"; else bad "registry drifted to $RN keys, expected 8"; fi

# ── (8) sweep: reports parked mailbox + names EVERY real remedy, honestly ────
# Both edges are asserted. Understating (restart-only) is the stale claim this
# section used to enshrine; overstating (TaskStop proven) is the equal and
# opposite lie. A test that merely string-matched whatever the tool emits would
# catch neither, so every assertion below names the property, not the phrasing.
SW="$("$AGENTS" sweep 2>&1)"
if grep -q "ve-server" <<<"$SW"; then ok "sweep names the parked agent"; else bad "sweep omitted parked agent name"; fi
if grep -q "TaskStop" <<<"$SW"; then ok "sweep names TaskStop as the programmatic remedy"; else bad "sweep failed to name TaskStop"; fi
if grep -qi "restart" <<<"$SW"; then ok "sweep still offers session restart as fallback"; else bad "sweep dropped the restart fallback"; fi
if grep -qiE 'only a restart|restart only|restart-only' <<<"$SW"; then
  bad "sweep STILL claims restart is the only remedy"
else
  ok "sweep no longer claims restart-only"
fi
if grep -qi 'not yet verified' <<<"$SW"; then
  ok "sweep flags TaskStop as documented-not-proven"
else
  bad "sweep overstates TaskStop as proven"
fi
if grep -qiE 'killed the|terminated the' <<<"$SW"; then bad "sweep FALSELY claims a kill"; else ok "sweep never claims a kill it did not perform"; fi
SWJ="$("$AGENTS" sweep --json 2>/dev/null)"
# CONTRACT: clearable_by is a LIST of mechanism ids, so a consumer branches on
# membership instead of parsing a sentence. The old scalar "session restart only"
# must be gone AND the list must actually name the mechanism that replaced it.
if [ "$(printf '%s' "$SWJ" | jq -r '.clearable_by | type')" = "array" ]; then
  ok "sweep --json clearable_by is a machine-readable list"
else
  bad "clearable_by not a list (got type '$(printf '%s' "$SWJ" | jq -r '.clearable_by|type')')"
fi
if printf '%s' "$SWJ" | jq -e '.clearable_by | index("TaskStop")' >/dev/null 2>&1; then
  ok "sweep --json clearable_by names TaskStop"
else
  bad "clearable_by omits TaskStop"
fi
# `type=="array" and` is load-bearing: jq's `length` on the old scalar returns the
# STRING length (20), which would sail past a bare `>= 2` and green-light exactly
# the claim this asserts is gone.
if printf '%s' "$SWJ" | jq -e '.clearable_by | type == "array" and length >= 2' >/dev/null 2>&1; then
  ok "sweep --json offers more than one mechanism (not restart-only)"
else
  bad "clearable_by lists fewer than 2 mechanisms — the restart-only claim survives"
fi
if printf '%s' "$SWJ" | jq -e '.clearable_by | index("session-restart")' >/dev/null 2>&1; then
  ok "sweep --json keeps session-restart as fallback"
else
  bad "clearable_by dropped session-restart"
fi
# Honesty tripwire: TaskStop is documented, NOT verified end to end. It must be
# absent from the verified subset until a run proves it — so the upgrade is a
# deliberate act that turns this assertion red, never a silent wording drift.
if printf '%s' "$SWJ" | jq -e '.clearable_by_verified | index("TaskStop") | not' >/dev/null 2>&1; then
  ok "sweep --json does NOT claim TaskStop is verified"
else
  bad "clearable_by_verified overstates TaskStop as proven"
fi
if printf '%s' "$SWJ" | jq -e '.clearable_by_verified | index("session-restart")' >/dev/null 2>&1; then
  ok "sweep --json marks session-restart as the verified mechanism"
else
  bad "clearable_by_verified omits session-restart"
fi
if [ "$(printf '%s' "$SWJ" | jq -r '.parked_mailbox|length')" -ge 1 ]; then ok "sweep --json lists parked mailbox agents"; else bad "sweep --json parked list empty"; fi

# ── (9) sweep is idempotent and safe to re-run ──────────────────────────────
RN_BEFORE="$(jq 'keys|length' "$REAPED")"
"$AGENTS" sweep >/dev/null 2>&1
"$AGENTS" sweep >/dev/null 2>&1
RN_AFTER="$(jq 'keys|length' "$REAPED")"
if [ "$RN_BEFORE" = "$RN_AFTER" ]; then ok "sweep idempotent across repeat runs"; else bad "sweep drifted registry $RN_BEFORE → $RN_AFTER"; fi
C3="$("$AGENTS" count)"
if [ "$C3" = "2" ]; then ok "count stable after repeated sweeps"; else bad "count drifted to '$C3'"; fi

# ── (10) explicit opt-out ───────────────────────────────────────────────────
OUT="$(HMD_AGENT_NO_SWEEP=1 "$AGENTS" sweep 2>&1)"
if grep -q "disabled" <<<"$OUT"; then ok "HMD_AGENT_NO_SWEEP=1 disables sweep"; else bad "opt-out not honoured"; fi

# ── (11) World B: owning session process is GONE ⇒ provably dead ⇒ orphaned ──
REAPED_B="$WORK/reaped-b.json"
ORPH="$(HMD_AGENT_REAPED_FILE="$REAPED_B" HMD_AGENT_LIVE_SLUGS="" "$AGENTS" list --json)"
if [ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')" = "orphaned" ]; then
  ok "dead session ⇒ un-notified stale agent → orphaned"
else
  bad "expected orphaned for stale in dead session"
fi
if [ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_MBOX" '.[]|select(.id==$i)|.state')" = "orphaned" ]; then
  ok "dead session ⇒ parked teammate → orphaned (provably gone)"
else
  bad "expected orphaned for mailbox in dead session"
fi
if [ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_WORK" '.[]|select(.id==$i)|.state')" = "working" ]; then
  ok "GUARD: working agent stays working even in dead-session world"
else
  bad "GUARD BROKEN: working agent reclassified in dead-session world"
fi

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
if [ "$(printf '%s' "$LP" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')" = "stale" ]; then
  ok "fresh session transcript ⇒ session alive ⇒ stale, not orphaned"
else
  bad "fresh-transcript liveness ignored: got '$(printf '%s' "$LP" | jq -r --arg i "$A_STALE" '.[]|select(.id==$i)|.state')'"
fi

# ── (12) degraded honesty: unreadable / missing inputs must not crash or lie ──
CZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" count)"
if [ "$CZERO" = "0" ]; then ok "absent task dir → count 0 (fail-closed)"; else bad "absent task dir count expected 0, got '$CZERO'"; fi
LZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" list)"
if grep -q "no tracked subagents" <<<"$LZERO"; then ok "absent task dir → honest empty list"; else bad "absent task dir list wrong"; fi
SZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" sweep 2>&1)"; SZ_RC=$?
if [ "$SZ_RC" = "0" ]; then ok "sweep exits 0 on absent task dir"; else bad "sweep exit $SZ_RC on absent task dir: $SZERO"; fi
OZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" orphans 2>&1)"; OZ_RC=$?
if [ "$OZ_RC" = "0" ]; then ok "orphans exits 0 on absent task dir"; else bad "orphans exit $OZ_RC on absent task dir: $OZERO"; fi

# Transcript deleted out from under us: metadata gone, must degrade not crash.
BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
ln -sf "$WORK/no-such-transcript.jsonl" "$BROKEN/a7777777777777777.output"
BOUT="$(HMD_AGENT_TASKDIR="$BROKEN" HMD_AGENT_SUBAGENTS_DIR="$WORK/no-subagents" "$AGENTS" list --json 2>/dev/null)"
if [ "$(printf '%s' "$BOUT" | jq -r 'type')" = "array" ]; then ok "dangling transcript → valid JSON, no crash"; else bad "dangling transcript produced invalid output"; fi
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
if [ "$(printf '%s' "$CPOUT" | jq -r 'type')" = "array" ]; then ok "truncated parent transcript → valid JSON, no crash"; else bad "truncated parent transcript broke list"; fi

# ═════════════════════════════════════════════════════════════════════════════
# (13) live_slugs ON-DISK CACHE — a fresh cache is read without re-probing; a
# cache past its TTL re-probes; HMD_AGENT_LIVE_SLUGS_TTL is actually honoured;
# HMD_AGENT_LIVE_SLUGS still bypasses BOTH the probe and the cache entirely.
# Regression guard for: 3 concurrent statuslines each re-invoking `count` every
# few seconds, each paying a fresh pgrep+lsof cost on EVERY call (measured
# 8.1s wall at load 40-50, 2026-09-24). This proves the caching MECHANISM —
# wall-clock improvement is reported separately; asserting timing thresholds
# on a shared, variably-loaded box is exactly the flake this suite avoids.
#
# A fake `pgrep` goes on PATH so no real process table is ever touched, and so
# every real invocation of live_slugs()'s probe leaves a countable trace. It
# emits NO pids (a fully valid "nobody's alive" probe result), which keeps the
# fixture from also needing a fake `lsof`.
# ═════════════════════════════════════════════════════════════════════════════
LS_DIR="$WORK/liveslugs"
LS_CWD="$LS_DIR/cwd"; LS_PROJ="$LS_DIR/projects"; LS_FAKEBIN="$LS_DIR/fakebin"
LS_SLUG="-Users-fake-liveslugs-project"
LS_SESS="11111111-1111-1111-1111-111111111111"
LS_TASKDIR="$LS_DIR/claude-501/$LS_SLUG/$LS_SESS/tasks"
LS_SUBDIR="$LS_PROJ/$LS_SLUG/$LS_SESS/subagents"
LS_CACHE="$LS_CWD/.heimdall/.live-slugs-cache"
LS_PGREP_LOG="$LS_DIR/pgrep.log"
mkdir -p "$LS_CWD" "$LS_TASKDIR" "$LS_SUBDIR" "$LS_FAKEBIN"
: > "$LS_PGREP_LOG"
{
  echo '#!/usr/bin/env bash'
  printf 'echo "call $$ $*" >> %q\n' "$LS_PGREP_LOG"
  echo 'exit 0'
} > "$LS_FAKEBIN/pgrep"
chmod +x "$LS_FAKEBIN/pgrep"
ls_pgrep_calls() { wc -l < "$LS_PGREP_LOG" 2>/dev/null | tr -d ' '; }

# Reuse the existing stale fixture agent's shape (id, transcript, meta) rather
# than inventing a new one — same pattern as the (11b) liveness-evidence block
# above. Deliberately NO parent-session transcript at
# "$LS_PROJ/$LS_SLUG/$LS_SESS.jsonl": session_is_alive's mtime fast-path
# requires that file to EXIST, so leaving it absent is what forces the
# fall-through into live_slugs() on every call below — the only way a plain
# `count` invocation ever reaches the code this section exists to test.
cp "$SUBDIR/agent-$A_STALE.jsonl" "$LS_SUBDIR/" 2>/dev/null
cp "$SUBDIR/agent-$A_STALE.meta.json" "$LS_SUBDIR/" 2>/dev/null
set_mtime "$LS_SUBDIR/agent-$A_STALE.jsonl" $(( NOW - 5000 ))
ln -sf "$LS_SUBDIR/agent-$A_STALE.jsonl" "$LS_TASKDIR/$A_STALE.output"

# $1 (optional): HMD_AGENT_LIVE_SLUGS_TTL value; defaults to the tool's own
# default (15) so callers not exercising the TTL itself get ordinary behaviour.
# Override is explicitly UNSET (env -u) so the real cache/probe path runs.
ls_count() {
  env -u HMD_AGENT_LIVE_SLUGS \
    HMD_AGENT_TASKDIR="$LS_TASKDIR" HMD_AGENT_PROJECTS_DIR="$LS_PROJ" \
    HMD_AGENT_REAPED_FILE="$LS_DIR/reaped.json" HMD_AGENT_CWD="$LS_CWD" \
    HMD_AGENT_LIVE_SLUGS_TTL="${1:-15}" \
    PATH="$LS_FAKEBIN:$PATH" "$AGENTS" count
}

# (13a) no cache file on disk yet ⇒ the real probe runs (fake pgrep invoked)
# and the result is written through to the cache.
rm -f "$LS_CACHE"
N0="$(ls_pgrep_calls)"
C1="$(ls_count)"
N1="$(ls_pgrep_calls)"
if [ "$N1" -gt "$N0" ]; then
  ok "missing cache -> live_slugs probes (pgrep invoked)"
else
  bad "missing cache should have probed pgrep ($N0 -> $N1 calls)"
fi
if [ -f "$LS_CACHE" ]; then
  ok "probe result written through to the on-disk cache"
else
  bad "cache file not created after a real probe"
fi
case "$C1" in ''|*[!0-9]*) bad "count not numeric after cold probe: '$C1'" ;; *) ok "count numeric after cold probe ($C1)" ;; esac

# (13b) cache just written -> pin its mtime to the fictional test clock (the
# code stamps a REAL wall-clock mtime; HMD_NOW is a fictional pinned epoch, so
# without this the file would misread as ancient no matter how recently it was
# actually written) -> a fresh cache must be served WITHOUT touching pgrep.
set_mtime "$LS_CACHE" "$NOW"
N0="$(ls_pgrep_calls)"
C2="$(ls_count)"
N1="$(ls_pgrep_calls)"
if [ "$N1" = "$N0" ]; then
  ok "fresh cache served without re-probing pgrep"
else
  bad "fresh cache still re-probed pgrep ($N0 -> $N1 calls)"
fi
if [ "$C1" = "$C2" ]; then
  ok "cached count matches the freshly-probed count"
else
  bad "count changed between fresh-cache reads ($C1 vs $C2)"
fi

# (13c) HMD_AGENT_LIVE_SLUGS_TTL is actually honoured, not just the hardcoded
# default: age the cache PAST a short override TTL while still well inside the
# 15s default — that alone must be enough to force a re-probe.
set_mtime "$LS_CACHE" $(( NOW - 10 ))
N0="$(ls_pgrep_calls)"
ls_count 5 >/dev/null
N1="$(ls_pgrep_calls)"
if [ "$N1" -gt "$N0" ]; then
  ok "HMD_AGENT_LIVE_SLUGS_TTL shortens freshness (age 10s, ttl 5s -> re-probe)"
else
  bad "TTL override not honoured ($N0 -> $N1 calls)"
fi

# (13d) cache aged past even the default TTL -> re-probes.
set_mtime "$LS_CACHE" $(( NOW - 9999 ))
N0="$(ls_pgrep_calls)"
C3="$(ls_count)"
N1="$(ls_pgrep_calls)"
if [ "$N1" -gt "$N0" ]; then
  ok "stale cache (past default TTL) triggers a fresh probe"
else
  bad "stale cache did not re-probe ($N0 -> $N1 calls)"
fi
case "$C3" in ''|*[!0-9]*) bad "count not numeric after stale re-probe: '$C3'" ;; *) ok "count numeric after stale re-probe ($C3)" ;; esac

# (13e) HMD_AGENT_LIVE_SLUGS override still bypasses the cache ENTIRELY — never
# probes, never reads, never writes it — even with no cache file present.
rm -f "$LS_CACHE"
N0="$(ls_pgrep_calls)"
OV="$(HMD_AGENT_TASKDIR="$LS_TASKDIR" HMD_AGENT_PROJECTS_DIR="$LS_PROJ" \
      HMD_AGENT_REAPED_FILE="$LS_DIR/reaped-ov.json" HMD_AGENT_CWD="$LS_CWD" \
      HMD_AGENT_LIVE_SLUGS="" PATH="$LS_FAKEBIN:$PATH" "$AGENTS" count)"
N1="$(ls_pgrep_calls)"
if [ "$N1" = "$N0" ]; then
  ok "HMD_AGENT_LIVE_SLUGS override bypasses the disk cache entirely (no probe)"
else
  bad "override still triggered a probe ($N0 -> $N1 calls)"
fi
if [ ! -f "$LS_CACHE" ]; then
  ok "override never writes the cache file"
else
  bad "override unexpectedly created a cache file"
fi
case "$OV" in ''|*[!0-9]*) bad "count not numeric under override: '$OV'" ;; *) ok "count numeric under override ($OV)" ;; esac

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
