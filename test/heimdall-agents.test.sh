#!/usr/bin/env bash
# test/heimdall-agents.test.sh — falsifiable acceptance for bin/heimdall-agents.
#
# The tool's whole value is an HONEST live-subagent count plus an automatic,
# never-destructive cleanup. Two failure modes matter, in this order:
#
#   1. REAPING A GENUINELY LIVE AGENT — catastrophic. A subagent that is awaiting
#      a tool result (a 40-minute build, a long test run) has an OLD mtime but is
#      perfectly alive. The tool MUST classify it `working` and MUST NEVER reap
#      it. Fixture agent `acdetrain-…` is exactly that case, modelled on the real
#      one measured on 2026-08-03.
#   2. LYING ABOUT A KILL — a parked mailbox teammate (taskKind
#      "in_process_teammate") CANNOT be terminated from outside the harness: it is
#      an in-process coroutine with no PID and no control file. The tool must
#      exclude it from the live count and say plainly that only a session restart
#      clears it — never claim it was killed.
#
# The fixture mirrors the REAL harness layout so the test exercises the same path
# resolution production does:
#   <root>/claude-501/<slug>/<session>/tasks/<id>.output  ->  symlink to
#   <projects>/<slug>/<session>/subagents/agent-<id>.jsonl (+ .meta.json sidecar)
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
SESS="11111111-2222-3333-4444-555555555555"
TASKDIR="$WORK/claude-501/$SLUG/$SESS/tasks"
PROJDIR="$WORK/projects"
SUBDIR="$PROJDIR/$SLUG/$SESS/subagents"
REAPED="$WORK/agents-reaped.json"
mkdir -p "$TASKDIR" "$SUBDIR"

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

# mk_agent <id> <age_secs> <last_event: tool|end> [taskKind] [name]
# Builds transcript + .meta.json sidecar + the task-dir symlink, exactly as the
# harness lays them out, and back-dates the TRANSCRIPT (the symlink is followed).
mk_agent() {
  local id="$1" age="$2" last="$3" kind="${4:-}" name="${5:-}" j m
  j="$SUBDIR/agent-$id.jsonl"
  m="$SUBDIR/agent-$id.meta.json"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    if [ "$last" = "tool" ]; then printf '%s\n' "$TOOL_USE_EV"; else printf '%s\n' "$END_TURN_EV"; fi
  } > "$j"
  if [ -n "$kind" ]; then
    jq -n --arg k "$kind" --arg n "$name" \
      '{agentType:"hmd:coder", description:"fixture", name:$n, taskKind:$k, spawnDepth:0}' > "$m"
  else
    jq -n '{agentType:"hmd:coder", description:"fixture", spawnDepth:1}' > "$m"
  fi
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# ── fixture ───────────────────────────────────────────────────────────────────
A_LIVE="a1111111111111111"; mk_agent "$A_LIVE"  10   end          # fresh regular
A_STALE="a2222222222222222"; mk_agent "$A_STALE" 5000 end         # stale regular
A_FAIL="a3333333333333333"; mk_agent "$A_FAIL"  10   end          # fresh…
printf 'failed\n' > "$TASKDIR/$A_FAIL.status"                     # …but terminal
A_MBOX="ave-server-4444444444444444"
mk_agent "$A_MBOX"  5000 end  in_process_teammate ve-server       # parked teammate
A_WORK="acdetrain-5555555555555555"
mk_agent "$A_WORK"  1000 tool in_process_teammate cdetrain        # STALE-AGED BUT WORKING
A_HUNG="a6666666666666666"; mk_agent "$A_HUNG"  99999 tool        # wedged on one tool
# A background BASH task: same dir, b+8 id, plain file, no agent metadata at all.
B_BASH="b0eqc6c3i"
printf 'resume started\n' > "$TASKDIR/$B_BASH.output"
set_mtime "$TASKDIR/$B_BASH.output" $(( NOW - 4000 ))

state_of() { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.state'; }
name_of()  { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.name'; }

# ── (1) classification ────────────────────────────────────────────────────────
[ "$(state_of "$A_LIVE")"  = "live"    ] && ok "fresh regular subagent → live"      || bad "expected live, got '$(state_of "$A_LIVE")'"
[ "$(state_of "$A_STALE")" = "stale"   ] && ok "old + end_turn → stale"             || bad "expected stale, got '$(state_of "$A_STALE")'"
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

# ── (4) count is LIVE-only (live + working) ──────────────────────────────────
C="$("$AGENTS" count)"
[ "$C" = "2" ] && ok "count==2 (live + working only)" || bad "count expected 2, got '$C'"

# ── (5) reap records the terminal/parked ones, NEVER the live or working ─────
"$AGENTS" reap >/dev/null
[ "$(jq -r --arg i "$A_STALE" '.[$i].reason // ""' "$REAPED")" = "stale" ]   && ok "stale recorded reason=stale"     || bad "stale not recorded"
[ "$(jq -r --arg i "$A_FAIL"  '.[$i].reason // ""' "$REAPED")" = "failed" ]  && ok "failed recorded reason=failed"   || bad "failed not recorded"
[ "$(jq -r --arg i "$A_HUNG"  '.[$i].reason // ""' "$REAPED")" = "hung" ]    && ok "hung recorded reason=hung"       || bad "hung not recorded"
[ "$(jq -r --arg i "$A_MBOX"  '.[$i].reason // ""' "$REAPED")" = "mailbox-parked" ] && ok "mailbox recorded reason=mailbox-parked" || bad "mailbox not recorded"
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
[ "$RN" = "4" ] && ok "registry exactly 4 after re-reap (no drift)" || bad "registry drifted to $RN keys, expected 4"

# ── (8) sweep: reports parked mailbox + names the ONLY remedy ────────────────
SW="$("$AGENTS" sweep 2>&1)"
printf '%s' "$SW" | grep -q "ve-server"      && ok "sweep names the parked agent"        || bad "sweep omitted parked agent name"
printf '%s' "$SW" | grep -qi "restart"       && ok "sweep states restart is the remedy"  || bad "sweep failed to state the remedy"
printf '%s' "$SW" | grep -qiE 'killed|terminated the' && bad "sweep FALSELY claims a kill" || ok "sweep never claims a kill it did not perform"
SWJ="$("$AGENTS" sweep --json 2>/dev/null)"
[ "$(printf '%s' "$SWJ" | jq -r '.clearable_by')" = "session restart only" ] && ok "sweep --json reports clearable_by" || bad "sweep --json clearable_by wrong"
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
  && ok "dead session ⇒ stale agent → orphaned" || bad "expected orphaned for stale in dead session"
[ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_MBOX" '.[]|select(.id==$i)|.state')" = "orphaned" ] \
  && ok "dead session ⇒ parked teammate → orphaned (provably gone)" || bad "expected orphaned for mailbox in dead session"
[ "$(printf '%s' "$ORPH" | jq -r --arg i "$A_WORK" '.[]|select(.id==$i)|.state')" = "working" ] \
  && ok "GUARD: working agent stays working even in dead-session world" \
  || bad "GUARD BROKEN: working agent reclassified in dead-session world"

# ── (12) degraded honesty: unreadable / missing inputs must not crash or lie ──
CZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" "$AGENTS" count)"
[ "$CZERO" = "0" ] && ok "absent task dir → count 0 (fail-closed)" || bad "absent task dir count expected 0, got '$CZERO'"
LZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" "$AGENTS" list)"
printf '%s' "$LZERO" | grep -q "no tracked subagents" && ok "absent task dir → honest empty list" || bad "absent task dir list wrong"
SZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" "$AGENTS" sweep 2>&1)"; SZ_RC=$?
[ "$SZ_RC" = "0" ] && ok "sweep exits 0 on absent task dir" || bad "sweep exit $SZ_RC on absent task dir"

# Transcript deleted out from under us: metadata gone, must degrade not crash.
BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
ln -sf "$WORK/no-such-transcript.jsonl" "$BROKEN/a7777777777777777.output"
BOUT="$(HMD_AGENT_TASKDIR="$BROKEN" "$AGENTS" list --json 2>/dev/null)"
[ "$(printf '%s' "$BOUT" | jq -r 'type')" = "array" ] && ok "dangling transcript → valid JSON, no crash" || bad "dangling transcript produced invalid output"
BC="$(HMD_AGENT_TASKDIR="$BROKEN" "$AGENTS" count 2>/dev/null)"
case "$BC" in ''|*[!0-9]*) bad "dangling transcript count not numeric: '$BC'" ;; *) ok "dangling transcript → numeric count ($BC)" ;; esac

# Unreadable registry must not wedge the tool.
BADREG="$WORK/corrupt.json"; printf 'not json at all\n' > "$BADREG"
CR="$(HMD_AGENT_REAPED_FILE="$BADREG" "$AGENTS" count 2>/dev/null)"
case "$CR" in ''|*[!0-9]*) bad "corrupt registry broke count: '$CR'" ;; *) ok "corrupt registry → count still numeric ($CR)" ;; esac

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
