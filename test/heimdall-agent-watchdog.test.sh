#!/usr/bin/env bash
# test/heimdall-agent-watchdog.test.sh — hermetic acceptance for
# bin/heimdall-agent-watchdog: the ENFORCEMENT layer on top of
# bin/heimdall-agent-resume's REPORTING. Proves the three things that matter
# for a tool whose entire job is "don't lose work when an agent stalls":
#
#   1. PRESERVE IS ADDITIVE AND UNCONDITIONAL. A worktree with uncommitted
#      work gets a real commit (before/after `git status` proof); a clean
#      worktree gets NO commit (no empty commits, ever); a worktree_path that
#      isn't a real git worktree, or is missing, or somehow resolves to the
#      reporting repo itself, is never touched — reported, not guessed.
#   2. QUOTA IS NEVER RECOMMENDED FOR RETRY. Full stop, regardless of any
#      other signal.
#   3. RESUMABLE VS UNDETERMINED FOLLOWS UPSTREAM HONESTLY. A transient
#      (overloaded/network) cause with headroom left on the retry budget is
#      "resumable" and carries a real, non-empty, agent-naming SendMessage
#      payload verbatim from bin/heimdall-agent-resume. A `null` cause (the
#      measured shape of a stream-watchdog stall or turn-limit cutoff — see
#      bin/heimdall-agent-watchdog's own header) is "undetermined" — reported
#      plainly, NEVER guessed into a friendlier bucket, NEVER auto-retried.
#
# This drives the REAL bin/heimdall-agent-resume (and, under it, the REAL
# bin/heimdall-agents) through the same fixture mechanism
# test/heimdall-agent-resume.test.sh itself uses — an integration test of the
# full chain, not a mock of it. Hermetic: mktemp -d workdir only, throwaway
# git repos only. NEVER operates on the real .claude/worktrees/ or the main
# checkout.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WD="$ROOT/bin/heimdall-agent-watchdog"
AR="$ROOT/bin/heimdall-agent-resume"
AGENTS="$ROOT/bin/heimdall-agents"

[ -x "$WD" ] || { echo "FATAL: $WD not executable" >&2; exit 2; }
[ -x "$AR" ] || { echo "FATAL: $AR not executable" >&2; exit 2; }
[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-agent-watchdog-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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
export HMD_AGENT_LIVE_SLUGS="$SLUG"
export HMD_AGENT_RESUME_PRESSURE_BIN="$WORK/no-heimdall-pressure-here"

set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

TOOL_USE_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"tu_1"}]}}'
END_TURN_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Report complete."}]}}'

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
        worktreePath:("/nonexistent/agent-"+$i),
        worktreeBranch:("worktree-agent-"+$i),
        description:"fixture", toolUseId:"toolu_01FixtureToolUseId00",
        spawnDepth:1, model:"opus"}' > "$m"
  fi
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

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

mk_notif2() {
  local id="$1" status="$2" summary="$3" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>%s</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TASKDIR" "$id" "$status" "$summary")"
  jq -nc --arg c "$body" --arg s "$ASESS" \
    '{type:"queue-operation", operation:"enqueue",
      timestamp:"2026-08-20T16:00:00.000Z", sessionId:$s, content:$c}' >> "$PARENT"
}

mk_wt_repo() {
  # mk_wt_repo <dir> — a real, hermetic, throwaway git repo with identity
  # configured PERSISTENTLY (not via one-off `-c`), since
  # bin/heimdall-agent-watchdog's own preserve commit deliberately never
  # injects a bot identity into a worktree it does not own (production
  # worktrees already inherit identity from the shared repo config) — this
  # fixture supplies it up front instead, once, so the tool's own bare
  # `git commit` calls succeed.
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main >/dev/null 2>&1
  git -C "$dir" config user.email "t@t.example"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit -q --allow-empty -m init
}

QUOTA_TEXT="Agent terminated early due to an API error: You've hit your usage limit resets 5:40pm (Asia/Calcutta)"
NETWORK_TEXT="connection reset by peer while streaming a tool result"

# ═════════════════════════════════════════════════════════════════════════
# Fixture A — dirty worktree + quota kill: PRESERVE must commit it;
# RECOMMEND must be do_not_retry no matter what.
# ═════════════════════════════════════════════════════════════════════════
WT_A="$WORK/wt-quota-dirty"
mk_wt_repo "$WT_A"
git -C "$WT_A" checkout -q -b worktree-agent-a
printf 'feature code\n' > "$WT_A/feature.txt"
git -C "$WT_A" add feature.txt
git -C "$WT_A" commit -q -m "implement feature A"
printf 'work in progress\n' > "$WT_A/wip.txt"
R_A="arwatchdogquota00001"
mk_agent_wt "$R_A" 10 end "$WT_A" "worktree-agent-a" "Implement feature A"
mk_notif2 "$R_A" killed "$QUOTA_TEXT"

BEFORE_A="$(git -C "$WT_A" status --porcelain)"
BEFORE_A_HEAD="$(git -C "$WT_A" rev-parse HEAD)"

# ═════════════════════════════════════════════════════════════════════════
# Fixture B — clean worktree (fully committed, no dirty files): PRESERVE
# must be a no-op. No empty commit, ever.
# ═════════════════════════════════════════════════════════════════════════
WT_B="$WORK/wt-clean"
mk_wt_repo "$WT_B"
git -C "$WT_B" checkout -q -b worktree-agent-b
printf 'all committed\n' > "$WT_B/done.txt"
git -C "$WT_B" add done.txt
git -C "$WT_B" commit -q -m "finish feature B"
R_B="arwatchdogclean00002"
mk_agent_wt "$R_B" 10 end "$WT_B" "worktree-agent-b" "Implement feature B"
mk_notif2 "$R_B" failed "TypeError: cannot read properties of undefined (reading 'foo') at handler.js:42:10"

BEFORE_B_HEAD="$(git -C "$WT_B" rev-parse HEAD)"
BEFORE_B_LOG="$(git -C "$WT_B" log --oneline | wc -l | tr -d ' ')"

# ═════════════════════════════════════════════════════════════════════════
# Fixture C — dirty worktree + transient network cause: RECOMMEND must be
# resumable with a real, non-empty, agent-naming payload, AND the dirty
# file must still get preserved (resumable != skip-preserve).
# ═════════════════════════════════════════════════════════════════════════
WT_C="$WORK/wt-resumable"
mk_wt_repo "$WT_C"
git -C "$WT_C" checkout -q -b worktree-agent-c
printf 'partial\n' > "$WT_C/partial.txt"
R_C="arwatchdogresume0003"
mk_agent_wt "$R_C" 10 end "$WT_C" "worktree-agent-c" "Implement feature C"
mk_notif2 "$R_C" failed "$NETWORK_TEXT"

# ═════════════════════════════════════════════════════════════════════════
# Fixture D — undetermined: hung, no worktree on disk, no notification at
# all (the measured shape of a stall/turn-limit death). Must be REPORTED,
# never guessed, never recommended for retry.
# ═════════════════════════════════════════════════════════════════════════
R_D="arwatchdoghung00004"
mk_agent "$R_D" 99999 tool   # awaiting a tool result, way past HUNG_SECS, no notif

# ═════════════════════════════════════════════════════════════════════════
# Fixture E — worktree_path recorded but points at a plain, non-git
# directory. PRESERVE must refuse it (not_a_git_worktree), never touch it.
# ═════════════════════════════════════════════════════════════════════════
WT_E="$WORK/wt-not-a-repo"
mkdir -p "$WT_E"
printf 'just a file, not a git repo\n' > "$WT_E/plain.txt"
R_E="arwatchdognotgit0005"
mk_agent_wt "$R_E" 10 end "$WT_E" "n/a" "Not actually a git worktree"
mk_notif2 "$R_E" failed "TypeError: unexpected token"

# ═════════════════════════════════════════════════════════════════════════
# RUN the watchdog once over all of them, in --json mode.
# ═════════════════════════════════════════════════════════════════════════
OUT="$("$WD" run --json --repo "$REPO" --base main 2>&1)"
echo "$OUT" | jq -e . >/dev/null 2>&1 \
  && ok "run --json emits valid JSON" \
  || bad "run --json did not emit valid JSON: $OUT"

by_id() { printf '%s' "$OUT" | jq -c --arg i "$1" '[.[]|select(.id==$i)][0]'; }

# ── (1) Fixture A: dirty + quota -> preserved, before/after proof ─────────
A_OBJ="$(by_id "$R_A")"
AFTER_A="$(git -C "$WT_A" status --porcelain)"
AFTER_A_HEAD="$(git -C "$WT_A" rev-parse HEAD)"

[ -n "$BEFORE_A" ] \
  && ok "fixture A before-state: worktree WAS dirty (wip.txt uncommitted)" \
  || bad "fixture A setup broken: expected dirty worktree before run"

[ -z "$AFTER_A" ] \
  && ok "PRESERVE: dirty worktree is clean after watchdog run (git status --porcelain empty)" \
  || bad "PRESERVE FAILED: worktree still dirty after run: '$AFTER_A'"

[ "$BEFORE_A_HEAD" != "$AFTER_A_HEAD" ] \
  && ok "PRESERVE: HEAD moved (a real commit landed) — before=$BEFORE_A_HEAD after=$AFTER_A_HEAD" \
  || bad "PRESERVE FAILED: HEAD did not move, no commit landed"

[ "$(printf '%s' "$A_OBJ" | jq -r '.preserve.committed')" = "true" ] \
  && ok "fixture A JSON: preserve.committed == true" \
  || bad "fixture A JSON: preserve.committed should be true, got $(printf '%s' "$A_OBJ" | jq -r '.preserve.committed')"

[ "$(printf '%s' "$A_OBJ" | jq -r '.preserve.commit_sha')" = "$AFTER_A_HEAD" ] \
  && ok "fixture A JSON: preserve.commit_sha matches the real new HEAD" \
  || bad "fixture A JSON: commit_sha mismatch"

git -C "$WT_A" show --name-only --format="" "$AFTER_A_HEAD" 2>/dev/null | grep -qx "wip.txt" \
  && ok "PRESERVE commit actually contains wip.txt (the at-risk file)" \
  || bad "PRESERVE commit does not contain the previously-dirty file"

[ "$(printf '%s' "$A_OBJ" | jq -r '.recommendation.action')" = "do_not_retry" ] \
  && ok "fixture A (quota): recommendation == do_not_retry" \
  || bad "fixture A: expected do_not_retry, got $(printf '%s' "$A_OBJ" | jq -r '.recommendation.action')"

[ "$(printf '%s' "$A_OBJ" | jq -r '.recommendation.reason')" = "quota" ] \
  && ok "fixture A: recommendation.reason == quota" \
  || bad "fixture A: expected reason quota, got $(printf '%s' "$A_OBJ" | jq -r '.recommendation.reason')"

[ "$(printf '%s' "$A_OBJ" | jq -r '.recommendation.payload')" = "null" ] \
  && ok "fixture A: NEVER emits a retry payload for a quota death" \
  || bad "fixture A: quota death should never carry a retry payload"

# ── (2) Fixture B: clean worktree -> untouched, no empty commit ───────────
B_OBJ="$(by_id "$R_B")"
AFTER_B_HEAD="$(git -C "$WT_B" rev-parse HEAD)"
AFTER_B_LOG="$(git -C "$WT_B" log --oneline | wc -l | tr -d ' ')"

[ "$BEFORE_B_HEAD" = "$AFTER_B_HEAD" ] \
  && ok "CLEAN WORKTREE: HEAD unchanged after run (before=after=$AFTER_B_HEAD)" \
  || bad "CLEAN WORKTREE BUG: HEAD moved on a clean worktree — empty commit created"

[ "$BEFORE_B_LOG" = "$AFTER_B_LOG" ] \
  && ok "CLEAN WORKTREE: commit count unchanged ($AFTER_B_LOG) — no empty commit" \
  || bad "CLEAN WORKTREE BUG: commit count changed ($BEFORE_B_LOG -> $AFTER_B_LOG)"

[ "$(printf '%s' "$B_OBJ" | jq -r '.preserve.reason')" = "clean" ] \
  && ok "fixture B JSON: preserve.reason == clean" \
  || bad "fixture B JSON: expected reason clean, got $(printf '%s' "$B_OBJ" | jq -r '.preserve.reason')"

[ "$(printf '%s' "$B_OBJ" | jq -r '.preserve.committed')" = "false" ] \
  && ok "fixture B JSON: preserve.committed == false" \
  || bad "fixture B JSON: committed should be false on a clean worktree"

# ── (3) Fixture C: transient network cause -> resumable, real payload ────
C_OBJ="$(by_id "$R_C")"
[ "$(printf '%s' "$C_OBJ" | jq -r '.recommendation.action')" = "resumable" ] \
  && ok "fixture C (network): recommendation == resumable" \
  || bad "fixture C: expected resumable, got $(printf '%s' "$C_OBJ" | jq -r '.recommendation.action')"

PAYLOAD_C="$(printf '%s' "$C_OBJ" | jq -r '.recommendation.payload')"
[ -n "$PAYLOAD_C" ] && [ "$PAYLOAD_C" != "null" ] \
  && ok "fixture C: recommendation.payload is non-empty" \
  || bad "fixture C: expected a non-empty payload, got '$PAYLOAD_C'"

printf '%s' "$PAYLOAD_C" | grep -q "$R_C" \
  && ok "fixture C: payload names the right agent ($R_C)" \
  || bad "fixture C: payload does not name agent $R_C: $PAYLOAD_C"

git -C "$WT_C" status --porcelain | grep -q . \
  && bad "fixture C: worktree still dirty after run (partial.txt not preserved)" \
  || ok "fixture C: transient-cause worktree ALSO preserved (not just recommended)"

# ── (4) Fixture D: undetermined -> reported, never guessed, never retried ─
D_OBJ="$(by_id "$R_D")"
[ "$(printf '%s' "$D_OBJ" | jq -r '.recommendation.action')" = "undetermined" ] \
  && ok "fixture D (no notif, hung): recommendation == undetermined" \
  || bad "fixture D: expected undetermined, got $(printf '%s' "$D_OBJ" | jq -r '.recommendation.action')"

[ "$(printf '%s' "$D_OBJ" | jq -r '.recommendation.payload')" = "null" ] \
  && ok "fixture D: no fabricated retry payload for an undetermined cause" \
  || bad "fixture D: undetermined case must never carry a payload"

[ "$(printf '%s' "$D_OBJ" | jq -r '.preserve.reason')" = "worktree_missing" ] \
  && ok "fixture D: no real worktree on disk -> preserve reports worktree_missing, not guessed" \
  || bad "fixture D: expected worktree_missing, got $(printf '%s' "$D_OBJ" | jq -r '.preserve.reason')"

# ── (5) Fixture E: worktree_path recorded but not a real git worktree ─────
E_OBJ="$(by_id "$R_E")"
[ "$(printf '%s' "$E_OBJ" | jq -r '.preserve.reason')" = "not_a_git_worktree" ] \
  && ok "fixture E: plain non-git directory -> not_a_git_worktree, never touched" \
  || bad "fixture E: expected not_a_git_worktree, got $(printf '%s' "$E_OBJ" | jq -r '.preserve.reason')"

[ "$(printf '%s' "$E_OBJ" | jq -r '.preserve.attempted')" = "false" ] \
  && ok "fixture E: preserve.attempted == false (never ran git add/commit there)" \
  || bad "fixture E: attempted should be false"

[ -f "$WT_E/plain.txt" ] && [ ! -d "$WT_E/.git" ] \
  && ok "fixture E: directory genuinely untouched (still not a git repo)" \
  || bad "fixture E: directory state changed unexpectedly"

# ── --no-preserve: dry-run mode, never commits anything ───────────────────
WT_F="$WORK/wt-no-preserve"
mk_wt_repo "$WT_F"
git -C "$WT_F" checkout -q -b worktree-agent-f
printf 'should stay dirty\n' > "$WT_F/dirty.txt"
R_F="arwatchdognopreserve6"
mk_agent_wt "$R_F" 10 end "$WT_F" "worktree-agent-f" "Feature F"
mk_notif2 "$R_F" killed "$QUOTA_TEXT"
BEFORE_F_HEAD="$(git -C "$WT_F" rev-parse HEAD)"

NOPRESERVE_OUT="$("$WD" run --json --repo "$REPO" --base main --no-preserve 2>&1)"
AFTER_F_HEAD="$(git -C "$WT_F" rev-parse HEAD)"
F_OBJ="$(printf '%s' "$NOPRESERVE_OUT" | jq -c --arg i "$R_F" '[.[]|select(.id==$i)][0]')"

[ "$BEFORE_F_HEAD" = "$AFTER_F_HEAD" ] \
  && ok "--no-preserve: HEAD unchanged, nothing committed" \
  || bad "--no-preserve BUG: a commit landed anyway"

[ "$(printf '%s' "$F_OBJ" | jq -r '.preserve.reason')" = "skipped_by_flag" ] \
  && ok "--no-preserve: preserve.reason == skipped_by_flag" \
  || bad "--no-preserve: expected skipped_by_flag, got $(printf '%s' "$F_OBJ" | jq -r '.preserve.reason')"

# ── human-readable mode never crashes, mentions every interrupted agent ───
TXT_OUT="$("$WD" run --repo "$REPO" --base main 2>&1)"
ALL_OK=1
for id in "$R_A" "$R_B" "$R_C" "$R_D" "$R_E"; do
  printf '%s' "$TXT_OUT" | grep -q "$id" || ALL_OK=0
done
[ "$ALL_OK" = "1" ] \
  && ok "plain-text run mentions every interrupted agent id" \
  || bad "plain-text run output missing one or more agent ids: $TXT_OUT"

# ── usage error -> exit 2 ──────────────────────────────────────────────────
"$WD" run --bogus-flag --repo "$REPO" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
  && ok "unknown flag -> exit 2 (usage error)" \
  || bad "expected exit 2 on unknown flag, got $RC"

# ── --id targeting a nonexistent agent -> exit 0, empty JSON, no crash ────
NOAGENT_OUT="$("$WD" run --json --repo "$REPO" --id "nonexistent-agent-id-zzz" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$NOAGENT_OUT" | jq 'length' 2>/dev/null)" = "0" ] \
  && ok "--id targeting a nonexistent agent -> exit 0, empty JSON array" \
  || bad "expected exit 0 + [] for a nonexistent --id, got rc=$RC out=$NOAGENT_OUT"

# ═════════════════════════════════════════════════════════════════════════
# stop-hook: SubagentStop-shaped stdin -> resolves worktree from the dying
# subagent's OWN transcript, preserves ONLY that one worktree, always
# exits 0.
# ═════════════════════════════════════════════════════════════════════════
WT_G="$WORK/wt-stophook"
mk_wt_repo "$WT_G"
git -C "$WT_G" checkout -q -b worktree-agent-g
printf 'unsaved investigation notes\n' > "$WT_G/notes.txt"
BEFORE_G_HEAD="$(git -C "$WT_G" rev-parse HEAD)"

FAKE_TRANSCRIPT="$WORK/fake-subagent-transcript.jsonl"
# Mirrors the real <env> block Claude Code injects into every agent's own
# transcript (the same block visible at the top of THIS tool's own
# transcript) — embedded as escaped JSON string content, exactly as JSON's
# own grammar requires any embedded newline to be encoded, so the
# grep+sed extraction is exercised against realistic noise, not a bare
# text file.
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Here is useful information about the environment you are running in:\n<env>\nWorking directory: '"$WT_G"'\nIs directory a git repo: Yes\nPlatform: darwin\n</env>\n"}]}}' > "$FAKE_TRANSCRIPT"

HOOK_PAYLOAD="$(jq -n --arg tp "$FAKE_TRANSCRIPT" '{agent_type:"hmd:coder", agent_transcript_path:$tp, effort:{level:"high"}}')"
printf '%s' "$HOOK_PAYLOAD" | "$WD" stop-hook --repo "$REPO" >/dev/null 2>&1
RC=$?
AFTER_G_HEAD="$(git -C "$WT_G" rev-parse HEAD)"

[ "$RC" -eq 0 ] \
  && ok "stop-hook: always exits 0" \
  || bad "stop-hook: expected exit 0, got $RC"

[ "$BEFORE_G_HEAD" != "$AFTER_G_HEAD" ] \
  && ok "stop-hook: resolved worktree from transcript's env block and preserved it (HEAD moved)" \
  || bad "stop-hook FAILED to preserve: HEAD unchanged ($AFTER_G_HEAD)"

[ -z "$(git -C "$WT_G" status --porcelain)" ] \
  && ok "stop-hook: worktree clean after preserve" \
  || bad "stop-hook: worktree still dirty after preserve"

# ── stop-hook negative case: no agent_transcript_path -> no-op, exit 0 ────
WT_H="$WORK/wt-stophook-negative"
mk_wt_repo "$WT_H"
printf 'should never be touched\n' > "$WT_H/untouched.txt"
BEFORE_H_HEAD="$(git -C "$WT_H" rev-parse HEAD)"

printf '%s' '{"agent_type":"hmd:coder"}' | "$WD" stop-hook --repo "$REPO" >/dev/null 2>&1
RC=$?
AFTER_H_HEAD="$(git -C "$WT_H" rev-parse HEAD)"

[ "$RC" -eq 0 ] \
  && ok "stop-hook with no agent_transcript_path: still exits 0 (fail-open)" \
  || bad "stop-hook: expected exit 0 even with no usable payload, got $RC"

[ "$BEFORE_H_HEAD" = "$AFTER_H_HEAD" ] \
  && ok "stop-hook with no resolvable worktree: touches NOTHING, guesses nothing" \
  || bad "stop-hook BUG: committed to an unrelated worktree with no real signal"

# ── stop-hook: empty stdin -> exit 0, no crash ─────────────────────────────
: | "$WD" stop-hook --repo "$REPO" >/dev/null 2>&1
[ $? -eq 0 ] \
  && ok "stop-hook: empty stdin -> exit 0" \
  || bad "stop-hook: empty stdin should still exit 0"

# ── regression: heimdall-agent-resume's own suite must still pass ────────
echo
echo "── regression: bash test/heimdall-agent-resume.test.sh ──"
if bash "$ROOT/test/heimdall-agent-resume.test.sh" >"$WORK/ar-regression.out" 2>&1; then
  ok "bash test/heimdall-agent-resume.test.sh still green after this change"
else
  bad "REGRESSION: test/heimdall-agent-resume.test.sh now fails — see tail below"
  tail -40 "$WORK/ar-regression.out" >&2
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
