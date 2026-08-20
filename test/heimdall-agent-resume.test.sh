#!/usr/bin/env bash
# test/heimdall-agent-resume.test.sh — hermetic acceptance for
# bin/heimdall-agent-resume: turns "N subagents were interrupted by a quota
# kill" into a durable, SendMessage-ready resume payload without redoing any
# already-committed work.
#
# WHAT MUST HOLD, in order of how badly getting it wrong hurts:
#   1. THE INTERRUPTED SET IS EXACT. list/report must include every failed,
#      killed, orphaned or hung agent and EXCLUDE every live, working, done,
#      mailbox or stale one. Getting this wrong either hides a real
#      interruption (silent work loss) or nags about agents that are fine.
#   2. COMMITTED WORK IS NEVER MISTAKEN FOR LOST WORK. An agent whose worktree
#      already has commits ahead of base must have those NAMED as
#      already-done ("DO NOT REDO"), and only its actually-dirty files
#      flagged as at risk. This is the entire point of the tool: a resumed
#      agent must not redo work it already finished.
#   3. QUOTA CLASSIFICATION IS HONEST, NOT GUESSED. `quota.suspected` is
#      true/false only where a real notification summary was classified;
#      null ("unknown") for orphaned/hung, which never got a notification at
#      all. Never inferred from state alone.
#   4. resume-hint STAYS SILENT WHEN THERE IS NOTHING TO DO, and speaks up
#      the moment there is — this is the SessionStart hot path, wired via
#      bin/heimdall-quota-resume's own resume-hint (see its cmd_resume_hint).
#
# Hermetic: mirrors test/heimdall-agents.test.sh's fixture shapes exactly
# (this tool shells out to bin/heimdall-agents and must see the real thing),
# and test/quota-resume.test.sh's real-git-repo pattern for the
# committed-vs-dirty checks. No network. HOME never touched — every path
# lives under a mktemp -d workdir.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AR="$ROOT/bin/heimdall-agent-resume"
AGENTS="$ROOT/bin/heimdall-agents"

[ -x "$AR" ] || { echo "FATAL: $AR not executable" >&2; exit 2; }
[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-agent-resume-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --repo must be a REAL, cd-able directory: cmd_report resolves it via
# `cd "$repo" && pwd`, then slugifies THAT resolved (symlink-followed) path
# the identical way bin/heimdall-agents' _slug_for_cwd does
# ("${x//[^A-Za-z0-9]/-}"), to find this repo's own parent-session
# transcripts under <projects>/<slug>/*.jsonl. SLUG must be computed from the
# SAME resolved form, or a macOS /tmp -> /private/tmp symlink hop silently
# breaks the notification lookup.
REPO="$WORK/testproj"
mkdir -p "$REPO"
REPO="$(cd "$REPO" && pwd)"
SLUG="${REPO//[^A-Za-z0-9]/-}"

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
export HEIMDALL_QUOTA_NOW_EPOCH="$NOW"
export HMD_AGENT_STALE_SECS=900
export HMD_AGENT_HUNG_SECS=3600
export HMD_AGENT_TASKDIR="$TASKDIR"
export HMD_AGENT_PROJECTS_DIR="$PROJDIR"
export HMD_AGENT_REAPED_FILE="$REAPED"
# Session alive by default (matches production's common case): only an
# explicit per-call override flips this for the orphaned-agent assertions.
export HMD_AGENT_LIVE_SLUGS="$SLUG"

set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

TOOL_USE_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"tu_1"}]}}'
END_TURN_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Report complete."}]}}'

# mk_agent <id> <age_secs> <last:tool|end> [taskKind] [name] — same fixture
# shapes as test/heimdall-agents.test.sh (regular sidecar has NO taskKind
# key; teammate sidecar has NO worktreePath/worktreeBranch keys at all —
# both measured harness shapes, see that file's header).
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
      '{agentType:$n, description:"fixture teammate", name:$n, spawnDepth:0,
        model:"haiku", taskKind:$k, teamName:"session-2ac8810f", color:"blue",
        planModeRequired:false, permissionMode:"bypassPermissions"}' > "$m"
  else
    jq -n --arg i "$id" \
      '{agentType:"hmd:coder",
        worktreePath:("/Users/rj/Downloads/heimdall/.claude/worktrees/agent-"+$i),
        worktreeBranch:("worktree-agent-"+$i),
        description:"fixture", toolUseId:"toolu_01FixtureToolUseId00",
        spawnDepth:1, model:"opus"}' > "$m"
  fi
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# mk_agent_wt <id> <age> <last> <worktree_path> <worktree_branch> <description>
# — a regular (non-teammate) fixture with a CALLER-CHOSEN worktreePath, so
# the committed-vs-dirty git-plumbing composition can be tested against a
# REAL repo instead of the fixed fake path plain mk_agent() always writes.
mk_agent_wt() {
  local id="$1" age="$2" last="$3" wt="$4" br="$5" desc="$6" j m
  j="$SUBDIR/agent-$id.jsonl"; m="$SUBDIR/agent-$id.meta.json"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    if [ "$last" = "tool" ]; then printf '%s\n' "$TOOL_USE_EV"; else printf '%s\n' "$END_TURN_EV"; fi
  } > "$j"
  jq -n --arg wt "$wt" --arg br "$br" --arg d "$desc" \
    '{agentType:"hmd:coder", worktreePath:$wt, worktreeBranch:$br,
      description:$d, toolUseId:"toolu_01FixtureToolUseId00",
      spawnDepth:1, model:"opus"}' > "$m"
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# mk_notif2 <id> <status> <summary> — same queue-operation shape as
# test/heimdall-agents.test.sh's mk_notif(), with a caller-chosen summary so
# the quota classifier has real, distinct text to work on per fixture.
mk_notif2() {
  local id="$1" status="$2" summary="$3" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>%s</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TASKDIR" "$id" "$status" "$summary")"
  jq -nc --arg c "$body" --arg s "$ASESS" \
    '{type:"queue-operation", operation:"enqueue",
      timestamp:"2026-08-20T16:00:00.000Z", sessionId:$s, content:$c}' >> "$PARENT"
}

report_field() { # <repo> <id> <jq-filter-on-one-object, e.g. .quota.suspected>
  "$AR" report --json --repo "$1" --id "$2" 2>/dev/null | jq -r ".[0]$3"
}

QUOTA_TEXT="Agent terminated early due to an API error: You've hit your usage limit · resets 5:40pm (Asia/Calcutta)"

# ── control fixtures: must NEVER be reported as interrupted ─────────────────
R_LIVE="arlive00000000000001"
mk_agent "$R_LIVE" 10 end

R_DONE="ardone00000000000002"
mk_agent "$R_DONE" 4000 end
mk_notif2 "$R_DONE" completed "Agent \"fixture\" finished cleanly"

R_MBOX="armbox-0000000000003"
mk_agent "$R_MBOX" 5000 end in_process_teammate mboxfixture

# ═════════════════════════════════════════════════════════════════════════════
# (1) BEFORE any interrupted agent exists: list/report empty, resume-hint SILENT
# ═════════════════════════════════════════════════════════════════════════════
PRE_LIST="$("$AR" list --json --repo "$REPO" 2>/dev/null)"
[ "$(printf '%s' "$PRE_LIST" | jq 'length')" = "0" ] \
  && ok "no interrupted agents yet -> list --json is an empty array" \
  || bad "expected empty list before any interruption, got: $PRE_LIST"

PRE_HINT="$("$AR" resume-hint --repo "$REPO" 2>/dev/null)"
[ -z "$PRE_HINT" ] \
  && ok "resume-hint: silent when nothing is interrupted (live/done/mailbox only)" \
  || bad "resume-hint should be silent — got: $PRE_HINT"

# ── the interrupted fixtures ──────────────────────────────────────────────────
R_KQ="arkilledquota0000004"
mk_agent "$R_KQ" 10 end
mk_notif2 "$R_KQ" killed "$QUOTA_TEXT"

R_FG="arfailedgeneric00005"
mk_agent "$R_FG" 10 end
mk_notif2 "$R_FG" failed "TypeError: cannot read properties of undefined (reading 'foo') at handler.js:42:10"

R_HUNG="arhungwedged0000006"
mk_agent "$R_HUNG" 99999 tool   # awaiting one tool result, way past HUNG_SECS, NO notif at all

R_ORPH="arorphanedstale0007"
mk_agent "$R_ORPH" 5000 end     # old + no notif: 'stale' while alive, 'orphaned' once session is dead

WT="$WORK/agent-worktree"
mkdir -p "$WT"
git -C "$WT" init -q -b main >/dev/null 2>&1
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WT" checkout -q -b worktree-agent-rwt
printf 'feature code\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "implement feature X"
printf 'work in progress\n' > "$WT/wip.txt"   # left uncommitted, AT RISK
R_WT="arworktreecommits008"
mk_agent_wt "$R_WT" 10 end "$WT" "worktree-agent-rwt" "Implement feature X"
mk_notif2 "$R_WT" killed "$QUOTA_TEXT"

R_NOWT="arnowt-000000000009"
mk_agent "$R_NOWT" 10 end in_process_teammate nowtfixture
mk_notif2 "$R_NOWT" failed "connection refused to internal service"

# ═════════════════════════════════════════════════════════════════════════════
# (2) THE INTERRUPTED SET IS EXACT — default states, alive session.
# ═════════════════════════════════════════════════════════════════════════════
LJ="$("$AR" list --json --repo "$REPO" 2>/dev/null)"
ids_in() { printf '%s' "$1" | jq -r --arg i "$2" '[.[]|select(.id==$i)]|length'; }

[ "$(ids_in "$LJ" "$R_KQ")"   = "1" ] && ok "killed agent present in default interrupted list"    || bad "killed agent missing from list"
[ "$(ids_in "$LJ" "$R_FG")"   = "1" ] && ok "failed agent present in default interrupted list"    || bad "failed agent missing from list"
[ "$(ids_in "$LJ" "$R_HUNG")" = "1" ] && ok "hung agent present in default interrupted list"      || bad "hung agent missing from list"
[ "$(ids_in "$LJ" "$R_WT")"   = "1" ] && ok "killed worktree agent present in default list"       || bad "worktree agent missing from list"
[ "$(ids_in "$LJ" "$R_NOWT")" = "1" ] && ok "failed no-worktree teammate present in default list"  || bad "no-worktree teammate missing from list"

[ "$(ids_in "$LJ" "$R_LIVE")" = "0" ] && ok "EXCLUDE: live agent absent from interrupted list"    || bad "GUARD BROKEN: live agent wrongly listed as interrupted"
[ "$(ids_in "$LJ" "$R_DONE")" = "0" ] && ok "EXCLUDE: done agent absent from interrupted list"    || bad "GUARD BROKEN: done agent wrongly listed as interrupted"
[ "$(ids_in "$LJ" "$R_MBOX")" = "0" ] && ok "EXCLUDE: parked mailbox absent from interrupted list" || bad "GUARD BROKEN: mailbox wrongly listed as interrupted"
[ "$(ids_in "$LJ" "$R_ORPH")" = "0" ] && ok "EXCLUDE: un-notified agent in an ALIVE session is 'stale', not listed" || bad "GUARD BROKEN: stale agent (alive session) wrongly listed as interrupted"

[ "$(printf '%s' "$LJ" | jq 'length')" = "5" ] \
  && ok "exactly 5 interrupted agents counted, no more, no less" \
  || bad "expected exactly 5 interrupted agents, got $(printf '%s' "$LJ" | jq 'length')"

# plain-text list: shows id + description, never crashes
LTXT="$("$AR" list --repo "$REPO" 2>&1)"
printf '%s' "$LTXT" | grep -q "$R_KQ" && printf '%s' "$LTXT" | grep -q "fixture" \
  && ok "plain-text list shows the killed agent id and its description" \
  || bad "plain-text list missing id/description for killed agent"

# ═════════════════════════════════════════════════════════════════════════════
# (3) THE ORPHANED CASE — only surfaces once the owning session is provably dead
# ═════════════════════════════════════════════════════════════════════════════
ORPH_ALONE="$(HMD_AGENT_LIVE_SLUGS="" "$AR" list --json --repo "$REPO" --id-unused 2>/dev/null || true)"
ORPH_REPORT="$(HMD_AGENT_LIVE_SLUGS="" "$AR" report --json --repo "$REPO" --id "$R_ORPH" 2>/dev/null)"
[ "$(printf '%s' "$ORPH_REPORT" | jq -r '.[0].state')" = "orphaned" ] \
  && ok "dead session -> un-notified stale agent reclassifies to orphaned" \
  || bad "expected orphaned in a dead session, got '$(printf '%s' "$ORPH_REPORT" | jq -r '.[0].state')'"
[ "$(printf '%s' "$ORPH_REPORT" | jq -r '.[0].quota.suspected')" = "null" ] \
  && ok "orphaned agent: quota.suspected is null (no notification ever existed to classify)" \
  || bad "orphaned agent quota.suspected should be null, got '$(printf '%s' "$ORPH_REPORT" | jq -r '.[0].quota.suspected')'"

# ═════════════════════════════════════════════════════════════════════════════
# (4) QUOTA CLASSIFICATION HONESTY — true/false/null, never guessed from state
# ═════════════════════════════════════════════════════════════════════════════
[ "$(report_field "$REPO" "$R_KQ" .quota.suspected)" = "true" ] \
  && ok "killed + real quota-phrase summary -> quota.suspected = true" \
  || bad "expected quota.suspected=true for killed quota agent, got '$(report_field "$REPO" "$R_KQ" .quota.suspected)'"
[ "$(report_field "$REPO" "$R_KQ" .quota.reset_local)" = "5:40pm" ] \
  && ok "quota classification carries the real reset_local (5:40pm)" \
  || bad "reset_local wrong, got '$(report_field "$REPO" "$R_KQ" .quota.reset_local)'"
[ "$(report_field "$REPO" "$R_KQ" .quota.reset_tz)" = "Asia/Calcutta" ] \
  && ok "quota classification carries the real reset_tz (Asia/Calcutta)" \
  || bad "reset_tz wrong, got '$(report_field "$REPO" "$R_KQ" .quota.reset_tz)'"

[ "$(report_field "$REPO" "$R_FG" .quota.suspected)" = "false" ] \
  && ok "failed + generic stack-trace summary -> quota.suspected = false (a real failure, not a quota window)" \
  || bad "expected quota.suspected=false for generic failure, got '$(report_field "$REPO" "$R_FG" .quota.suspected)'"

[ "$(report_field "$REPO" "$R_HUNG" .quota.suspected)" = "null" ] \
  && ok "hung agent: quota.suspected is null (never notified, no signal to classify)" \
  || bad "hung agent quota.suspected should be null, got '$(report_field "$REPO" "$R_HUNG" .quota.suspected)'"

# FALSIFIER: two different agents' quota classification differ (proves the
# classifier reads each agent's OWN notification text, not a hardcoded value).
[ "$(report_field "$REPO" "$R_KQ" .quota.suspected)" != "$(report_field "$REPO" "$R_FG" .quota.suspected)" ] \
  && ok "FALSIFIER: quota classification differs per-agent (true vs false) — not hardcoded" \
  || bad "FALSIFIER FAILED: quota classification looks constant across different agents"

# ═════════════════════════════════════════════════════════════════════════════
# (5) COMMITTED WORK IS NEVER MISTAKEN FOR LOST WORK — real git-repo composition
# ═════════════════════════════════════════════════════════════════════════════
[ "$(report_field "$REPO" "$R_WT" .resume_brief.available)" = "true" ] \
  && ok "worktree agent: resume-brief composition available" \
  || bad "expected resume_brief.available=true, got '$(report_field "$REPO" "$R_WT" .resume_brief.available)'"
[ "$(report_field "$REPO" "$R_WT" .resume_brief.ahead_of_base)" = "1" ] \
  && ok "resume-brief: exactly 1 commit already landed ahead of base (must not be redone)" \
  || bad "ahead_of_base wrong, got '$(report_field "$REPO" "$R_WT" .resume_brief.ahead_of_base)'"
[ "$(report_field "$REPO" "$R_WT" .resume_brief.dirty)" = "1" ] \
  && ok "resume-brief: exactly 1 uncommitted file (the actually-at-risk one)" \
  || bad "dirty count wrong, got '$(report_field "$REPO" "$R_WT" .resume_brief.dirty)'"
[ "$(report_field "$REPO" "$R_WT" '.resume_brief.dirty_files[0]')" = "wip.txt" ] \
  && ok "resume-brief: names the actual dirty file (wip.txt)" \
  || bad "dirty_files wrong, got '$(report_field "$REPO" "$R_WT" '.resume_brief.dirty_files')'"

PAYLOAD_WT="$(report_field "$REPO" "$R_WT" .payload)"
printf '%s' "$PAYLOAD_WT" | grep -q "DO NOT REDO" \
  && ok "payload explicitly warns not to redo the already-committed commit" \
  || bad "payload missing the DO NOT REDO warning"
printf '%s' "$PAYLOAD_WT" | grep -q "wip.txt" \
  && ok "payload names the at-risk dirty file" \
  || bad "payload missing the dirty filename"
printf '%s' "$PAYLOAD_WT" | grep -q "Implement feature X" \
  && ok "payload carries the agent's own task description" \
  || bad "payload missing task description"
printf '%s' "$PAYLOAD_WT" | grep -q "Resume from this state" \
  && ok "payload ends with the resume-not-restart instruction" \
  || bad "payload missing the resume-not-restart closing line"

# ── worktree recorded but the agent has none / it no longer exists on disk ──
[ "$(report_field "$REPO" "$R_NOWT" .worktree_path)" = "null" ] \
  && ok "teammate shape: worktree_path is JSON null (no worktree keys recorded at all)" \
  || bad "expected null worktree_path for teammate, got '$(report_field "$REPO" "$R_NOWT" .worktree_path)'"
[ "$(report_field "$REPO" "$R_NOWT" .resume_brief)" = "null" ] \
  && ok "no worktree recorded -> resume_brief is JSON null (never a fabricated brief)" \
  || bad "expected null resume_brief for no-worktree agent"
printf '%s' "$(report_field "$REPO" "$R_NOWT" .payload)" | grep -q "No isolated worktree recorded" \
  && ok "payload for a no-worktree agent says so plainly" \
  || bad "payload for no-worktree agent missing the plain-language explanation"

# R_KQ's meta.json (plain mk_agent) always records a worktreePath that was
# never actually created on disk — the "recorded but gone/never materialized"
# case, mechanically identical to a worktree that WAS reaped after spawn.
[ "$(report_field "$REPO" "$R_KQ" .resume_brief.available)" = "false" ] \
  && ok "recorded-but-nonexistent worktree -> resume_brief.available = false" \
  || bad "expected resume_brief.available=false for a nonexistent worktree path"
printf '%s' "$(report_field "$REPO" "$R_KQ" .resume_brief.reason)" | grep -qi "no longer exists" \
  && ok "reason names the worktree as gone, never silently fabricates git facts" \
  || bad "resume_brief.reason did not explain the missing worktree"

# ═════════════════════════════════════════════════════════════════════════════
# (6) --id NEVER BYPASSES THE STATES GATE
# ═════════════════════════════════════════════════════════════════════════════
IDBYPASS="$("$AR" report --json --repo "$REPO" --id "$R_MBOX" 2>/dev/null)"
[ "$(printf '%s' "$IDBYPASS" | jq 'length')" = "0" ] \
  && ok "--id on a non-interrupted agent (mailbox) still returns empty — states gate is not bypassed" \
  || bad "GUARD BROKEN: --id bypassed the states filter for a mailbox agent"

# ═════════════════════════════════════════════════════════════════════════════
# (7) FALSIFIER — --states is load-bearing, not decorative.
# ═════════════════════════════════════════════════════════════════════════════
DEFAULT_HAS_DONE="$(ids_in "$LJ" "$R_DONE")"
OVERRIDE_LIST="$("$AR" list --json --repo "$REPO" --states done 2>/dev/null)"
OVERRIDE_HAS_DONE="$(ids_in "$OVERRIDE_LIST" "$R_DONE")"
[ "$DEFAULT_HAS_DONE" = "0" ] && [ "$OVERRIDE_HAS_DONE" = "1" ] \
  && ok "FALSIFIER: --states done excludes-by-default then includes-on-override — the filter is real" \
  || bad "FALSIFIER FAILED: --states override had no effect (default=$DEFAULT_HAS_DONE override=$OVERRIDE_HAS_DONE)"

# ═════════════════════════════════════════════════════════════════════════════
# (8) resume-hint SPEAKS UP once real interruptions exist
# ═════════════════════════════════════════════════════════════════════════════
POST_HINT="$("$AR" resume-hint --repo "$REPO" 2>/dev/null)"
[ -n "$POST_HINT" ] \
  && ok "resume-hint: speaks up once interrupted agents exist" \
  || bad "resume-hint should be non-empty now"
printf '%s' "$POST_HINT" | grep -q "INTERRUPTED SUBAGENT" \
  && ok "resume-hint names the situation explicitly" \
  || bad "resume-hint missing the INTERRUPTED SUBAGENT header"
printf '%s' "$POST_HINT" | grep -q "$R_KQ" \
  && ok "resume-hint names the specific interrupted agent id" \
  || bad "resume-hint did not name $R_KQ"
printf '%s' "$POST_HINT" | grep -q "heimdall-agent-resume report" \
  && ok "resume-hint points at the full report command" \
  || bad "resume-hint missing the pointer to the full report"

# ═════════════════════════════════════════════════════════════════════════════
# (9) DEGRADED HONESTY / USAGE CONTRACT — never crash, exit codes as documented
# ═════════════════════════════════════════════════════════════════════════════
BOGUS="$("$AR" list --json --repo "/no/such/path/xyz-does-not-exist" 2>/dev/null)"; BRC=$?
[ "$BRC" = "0" ] && [ "$(printf '%s' "$BOGUS" | jq -r 'type' 2>/dev/null)" = "array" ] \
  && ok "unreachable --repo path degrades to a valid (likely empty) JSON array, never crashes" \
  || bad "unreachable --repo broke list --json (rc=$BRC out=$BOGUS)"

"$AR" bogus-subcommand >/dev/null 2>"$WORK/ar_err.$$"; UNK_RC=$?
UNK_ERR="$(cat "$WORK/ar_err.$$" 2>/dev/null)"; rm -f "$WORK/ar_err.$$"
[ "$UNK_RC" = "2" ] && printf '%s' "$UNK_ERR" | grep -qi "unknown subcommand" \
  && ok "unknown subcommand exits 2 with a named error on stderr" \
  || bad "unknown subcommand contract broken (rc=$UNK_RC err=$UNK_ERR)"

HELP_OUT="$("$AR" help 2>&1)"; HELP_RC=$?
[ "$HELP_RC" = "0" ] && printf '%s' "$HELP_OUT" | grep -qi "heimdall-agent-resume" \
  && ok "help exits 0 and identifies itself" \
  || bad "help contract broken (rc=$HELP_RC)"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
