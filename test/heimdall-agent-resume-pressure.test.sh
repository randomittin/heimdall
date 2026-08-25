#!/usr/bin/env bash
# test/heimdall-agent-resume-pressure.test.sh — hermetic acceptance for the
# ONE outbound side effect wired between bin/heimdall-agent-resume and
# bin/heimdall-pressure: an `overloaded` cause classification is the ONLY
# overload signal hmd has at all (it cannot read the harness's raw HTTP
# responses), and until this wiring it was computed by _classify_cause and
# then discarded. See "OVERLOAD -> PRESSURE" in bin/heimdall-agent-resume's
# own header for the full design; this file is the falsifiable proof of it.
#
# WHAT MUST HOLD, in order of how badly getting it wrong hurts:
#   1. EXACTLY-ONCE PER DEATH. These CLIs mutate state on every invocation —
#      there is no side-effect-free peek. `report` runs routinely more than
#      once for the SAME dead agent (a status refresh, a statusline poll, a
#      human re-running it); a naive hook would record one pressure event per
#      CALL instead of one per DEATH, and a harmless third refresh could
#      falsely breach the AIMD threshold and halve concurrency off ONE real
#      failure. This is the single most load-bearing property in this file.
#   2. CAUSE-GATED, NOT DEATH-GATED. A `task-failure`/`unknown` death (a real
#      bug, not transient pressure) must record NOTHING — this hook fires on
#      the classification, never on the mere fact that an agent died.
#   3. `network` STAYS UNWIRED, ON PURPOSE — not a deferral but a signal-
#      quality decision (full evidence in bin/heimdall-agent-resume's own
#      header: connection_reset and overloaded_error share one unweighted
#      AIMD window, but a network death routinely means the OPERATOR's own
#      link dropped — not that the API is pressured — and hmd's own
#      concurrent agents all share that one local link). A
#      `connection_reset`-shaped classification must record nothing,
#      checked below at BOTH the no-worktree case and the exact
#      attempts==1 boundary the overload path itself fires on — proving
#      this isn't secretly keying off "any transient cause" and cannot
#      quietly regress.
#   4. NEVER LOAD-BEARING. heimdall-pressure absent or actively failing must
#      never change heimdall-agent-resume's own exit code or `.cause` shape —
#      a telemetry integration must never become a new way for `report` to
#      break.
#
# Hermetic: mirrors test/heimdall-agent-resume.test.sh's own fixture shapes
# exactly (mk_agent_wt/mk_agent/mk_notif2/set_mtime — this tool shells out to
# bin/heimdall-agents and must see the real thing) and
# test/heimdall-pressure.test.sh's own fresh-HOME-per-case pattern (pressure
# state lives under $HOME/.heimdall/, exactly like bin/agent-pool's own pool
# file). No network. The REAL HOME is never touched — every HOME used here is
# its own mktemp -d, switched explicitly per section below.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AR="$ROOT/bin/heimdall-agent-resume"
PRESSURE="$ROOT/bin/heimdall-pressure"

[ -x "$AR" ] || { echo "FATAL: $AR not executable" >&2; exit 2; }
[ -x "$PRESSURE" ] || { echo "FATAL: $PRESSURE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-ar-pressure-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --repo must be a REAL, cd-able directory — same resolution caution as
# test/heimdall-agent-resume.test.sh's own header (macOS /tmp -> /private/tmp
# symlink hop must not desync the notification-lookup slug).
REPO="$WORK/testproj"
mkdir -p "$REPO/.planning"
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

set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

TOOL_USE_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"tu_1"}]}}'
END_TURN_EV='{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Report complete."}]}}'

# mk_agent <id> <age_secs> — a synthetic (non-real-worktree) fixture. Only
# used below for control cases whose cause class never reaches
# _resume_attempts_bump (unknown/network both skip it — see
# _classify_cause's overloaded|network) branch, which only bumps when a REAL
# worktree exists), so a fabricated, never-materialized worktreePath is fine.
mk_agent() {
  local id="$1" age="$2" j m
  j="$SUBDIR/agent-$id.jsonl"; m="$SUBDIR/agent-$id.meta.json"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    printf '%s\n' "$END_TURN_EV"
  } > "$j"
  jq -n --arg i "$id" \
    '{agentType:"hmd:coder",
      worktreePath:("/nonexistent/worktree-"+$i),
      worktreeBranch:("worktree-agent-"+$i),
      description:"fixture", toolUseId:"toolu_01FixtureToolUseId00",
      spawnDepth:1, model:"opus"}' > "$m"
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# mk_agent_wt <id> <age> <worktree_path> <worktree_branch> <description> — a
# fixture backed by a REAL git worktree, so _resume_attempts_bump has a real
# HEAD sha to key RESUME-ATTEMPTS.json off. Mirrors
# test/heimdall-agent-resume.test.sh's own mk_agent_wt (minus the unused
# <last> discriminator — every fixture here ends its transcript on end_turn).
mk_agent_wt() {
  local id="$1" age="$2" wt="$3" br="$4" desc="$5" j m
  j="$SUBDIR/agent-$id.jsonl"; m="$SUBDIR/agent-$id.meta.json"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    printf '%s\n' "$END_TURN_EV"
  } > "$j"
  jq -n --arg wt "$wt" --arg br "$br" --arg d "$desc" \
    '{agentType:"hmd:coder", worktreePath:$wt, worktreeBranch:$br,
      description:$d, toolUseId:"toolu_01FixtureToolUseId00",
      spawnDepth:1, model:"opus"}' > "$m"
  ln -sf "$j" "$TASKDIR/$id.output"
  set_mtime "$j" $(( NOW - age ))
}

# mk_notif2 <id> <status> <summary> — same queue-operation shape as
# test/heimdall-agent-resume.test.sh's own mk_notif2.
mk_notif2() {
  local id="$1" status="$2" summary="$3" body
  body="$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01FixtureToolUseId00</tool-use-id>\n<output-file>%s/%s.output</output-file>\n<status>%s</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops.</note>' \
    "$id" "$TASKDIR" "$id" "$status" "$summary")"
  jq -nc --arg c "$body" --arg s "$ASESS" \
    '{type:"queue-operation", operation:"enqueue",
      timestamp:"2026-08-20T16:00:00.000Z", sessionId:$s, content:$c}' >> "$PARENT"
}

# mk_worktree <path> <branch> — mirrors test/heimdall-agent-resume.test.sh's
# own WT2 (the overload fixture's worktree) exactly: a real git repo with
# .planning/* gitignored, so RESUME-ATTEMPTS.json never shows up as a dirty
# file, and a checked-out branch matching the meta.json's worktreeBranch.
mk_worktree() {
  local wt="$1" br="$2"
  mkdir -p "$wt"
  git -C "$wt" init -q -b main >/dev/null 2>&1
  printf '.planning/*\n' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$wt" checkout -q -b "$br" >/dev/null 2>&1
}

OVERLOAD_TEXT='Agent terminated early due to an API error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
UNKNOWN_TEXT="TypeError: cannot read properties of undefined (reading 'foo') at handler.js:42:10"
NETWORK_TEXT="connection refused to internal service"

state_file() { echo "$HOME/.heimdall/pressure-state.json"; }
window_len() {
  if [ -f "$(state_file)" ]; then
    jq '.window_events | length' "$(state_file)" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

echo "heimdall-agent-resume -> heimdall-pressure integration"
echo "--------------------------------------------------------------------"

# ═════════════════════════════════════════════════════════════════════════
# (a)+(b) EXACTLY-ONCE: first `report` on an overload death records ONE
# event; a second (and third) `report` for the SAME death (same worktree
# HEAD) records NONE more; a call AFTER real forward progress (a new commit,
# which resets the attempts marker to a fresh 1) legitimately records a
# SECOND event — proving the marker tracks freshness, not a permanent latch.
# ═════════════════════════════════════════════════════════════════════════
export HOME; HOME="$WORK/home-a"
WT_A="$WORK/wt-overload-a"
mk_worktree "$WT_A" "worktree-agent-rovla"
R_OVLA="arpressovla00000001"
mk_agent_wt "$R_OVLA" 10 "$WT_A" "worktree-agent-rovla" "Pressure fixture A"
mk_notif2 "$R_OVLA" killed "$OVERLOAD_TEXT"

[ "$(window_len)" = "0" ] \
  && ok "(a) before any report call: no pressure state file yet" \
  || bad "(a) unexpected pre-existing pressure state: $(window_len)"

R1="$("$AR" report --json --repo "$REPO" --id "$R_OVLA" 2>/dev/null)"
[ "$(printf '%s' "$R1" | jq -r '.[0].cause.class')" = "overloaded" ] \
  && ok "(a) fixture classifies as overloaded" \
  || bad "(a) expected cause.class=overloaded, got $(printf '%s' "$R1" | jq -c '.[0].cause')"
[ "$(printf '%s' "$R1" | jq -r '.[0].cause.attempts')" = "1" ] \
  && ok "(a) first report: attempts=1 (fresh marker)" \
  || bad "(a) expected attempts=1, got $(printf '%s' "$R1" | jq -r '.[0].cause.attempts')"
[ "$(window_len)" = "1" ] \
  && ok "(a) FALSIFIER: one overload death -> exactly ONE pressure event recorded" \
  || bad "(a) FALSIFIER FAILED: expected window_events length 1, got $(window_len)"

R2="$("$AR" report --json --repo "$REPO" --id "$R_OVLA" 2>/dev/null)"
[ "$(printf '%s' "$R2" | jq -r '.[0].cause.attempts')" = "2" ] \
  && ok "(b) second report on the SAME death: attempts=2 (bump still counts calls)" \
  || bad "(b) expected attempts=2, got $(printf '%s' "$R2" | jq -r '.[0].cause.attempts')"
[ "$(window_len)" = "1" ] \
  && ok "(b) FALSIFIER (the crux): re-running report for the SAME death records NO further pressure events" \
  || bad "(b) FALSIFIER FAILED: a repeated report call double-recorded — window_events length is $(window_len), want 1"

R3="$("$AR" report --json --repo "$REPO" --id "$R_OVLA" 2>/dev/null)"
[ "$(window_len)" = "1" ] \
  && ok "(b) a third repeated report call STILL records nothing more (not just a one-call grace)" \
  || bad "(b) a third report call changed window_events: $(window_len)"

git -C "$WT_A" commit -q --allow-empty -m "progress landed"
R4="$("$AR" report --json --repo "$REPO" --id "$R_OVLA" 2>/dev/null)"
[ "$(printf '%s' "$R4" | jq -r '.[0].cause.attempts')" = "1" ] \
  && ok "real forward progress resets the attempts marker to a fresh 1" \
  || bad "expected attempts to reset to 1 after a new commit, got $(printf '%s' "$R4" | jq -r '.[0].cause.attempts')"
[ "$(window_len)" = "2" ] \
  && ok "a genuinely NEW death after forward progress legitimately records a SECOND event (marker tracks freshness, not a permanent latch)" \
  || bad "expected a second pressure event after forward progress, window_events length is $(window_len)"

LEDGER="$REPO/.planning/metrics.jsonl"
[ -f "$LEDGER" ] && grep -q '"kind":"overloaded_error"' "$LEDGER" && grep -q '"source":"agent-resume"' "$LEDGER" \
  && ok "the top-level --repo (not the agent's own worktree) receives the audit ledger line, source=agent-resume" \
  || bad "ledger missing/malformed at $LEDGER: $(cat "$LEDGER" 2>/dev/null)"
[ "$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')" = "2" ] \
  && ok "cross-check via a SECOND observable: the ledger itself has exactly 2 lines (R1 + R4, not R2/R3)" \
  || bad "expected exactly 2 ledger lines, got $(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')"

# ═════════════════════════════════════════════════════════════════════════
# (c) CAUSE-GATED: a task-failure (unknown) death records NOTHING.
# ═════════════════════════════════════════════════════════════════════════
export HOME; HOME="$WORK/home-c"
R_FAIL="arpressfail0000002"
mk_agent "$R_FAIL" 10
mk_notif2 "$R_FAIL" failed "$UNKNOWN_TEXT"
RC="$("$AR" report --json --repo "$REPO" --id "$R_FAIL" 2>/dev/null)"
[ "$(printf '%s' "$RC" | jq -r '.[0].cause.class')" = "unknown" ] \
  && ok "(c) fixture classifies as unknown/task-failure" \
  || bad "(c) expected cause.class=unknown, got $(printf '%s' "$RC" | jq -c '.[0].cause')"
[ ! -f "$(state_file)" ] \
  && ok "(c) FALSIFIER: a task-failure/unknown death records NOTHING — no pressure state file created at all" \
  || bad "(c) FALSIFIER FAILED: a task-failure death created pressure state: $(cat "$(state_file)" 2>/dev/null)"

# ── network, part 1/2: no-worktree case — deliberately unwired ON PURPOSE
# (signal quality, not scope; see bin/heimdall-agent-resume's own header) ──
export HOME; HOME="$WORK/home-net"
R_NET="arpressnet00000003"
mk_agent "$R_NET" 10
mk_notif2 "$R_NET" failed "$NETWORK_TEXT"
RN="$("$AR" report --json --repo "$REPO" --id "$R_NET" 2>/dev/null)"
[ "$(printf '%s' "$RN" | jq -r '.[0].cause.class')" = "network" ] \
  && ok "network fixture classifies as network" \
  || bad "expected cause.class=network, got $(printf '%s' "$RN" | jq -c '.[0].cause')"
[ ! -f "$(state_file)" ] \
  && ok "network cause stays deliberately unwired: no pressure event recorded" \
  || bad "GUARD BROKEN: a network cause recorded a pressure event — network was supposed to stay unwired"

# ── network, part 2/2, THE STRONG CASE: a REAL worktree, freshly bumped to
# the EXACT attempts==1 boundary _record_pressure_if_fresh_overload treats
# as "fire" for `overloaded`. This is the boundary a future "just add
# network here too" patch would most plausibly get wrong — proving the
# guard holds even under the identical condition that fires the overload
# path, not just the weaker no-worktree/attempts=null case above. ─────────
export HOME; HOME="$WORK/home-net-real"
WT_NET="$WORK/wt-network-real"
mk_worktree "$WT_NET" "worktree-agent-rnetreal"
R_NETREAL="arpressnetreal000006"
mk_agent_wt "$R_NETREAL" 10 "$WT_NET" "worktree-agent-rnetreal" "Pressure fixture network-real"
mk_notif2 "$R_NETREAL" killed "$NETWORK_TEXT"
RNR="$("$AR" report --json --repo "$REPO" --id "$R_NETREAL" 2>/dev/null)"
[ "$(printf '%s' "$RNR" | jq -r '.[0].cause.class')" = "network" ] \
  && ok "network+real-worktree fixture classifies as network" \
  || bad "expected cause.class=network, got $(printf '%s' "$RNR" | jq -c '.[0].cause')"
[ "$(printf '%s' "$RNR" | jq -r '.[0].cause.attempts')" = "1" ] \
  && ok "network+real-worktree: attempts=1 — the EXACT boundary that fires the overloaded path" \
  || bad "expected cause.attempts=1, got $(printf '%s' "$RNR" | jq -r '.[0].cause.attempts')"
[ ! -f "$(state_file)" ] \
  && ok "FALSIFIER: network at attempts=1 (the overload path's own fire condition) still records nothing" \
  || bad "GUARD BROKEN: network at attempts=1 recorded a pressure event — network must stay unwired even at the fire boundary"

# ═════════════════════════════════════════════════════════════════════════
# RATE-LIMIT/429 STAYS UNWIRED TOO — same signal-quality reasoning as
# `network` above, different root cause: _OVERLOAD_RE classifies a bare
# 429/"too many requests"/rate-limit death as cause.class="overloaded" ON
# PURPOSE (429 is exactly as retryable as 529 from the caller's own point of
# view — retry_now/attempts/backoff must treat it identically; see
# test/heimdall-agent-resume.test.sh's own R_RL fixture for that proof). But
# a 429 is a SELF-INFLICTED, per-caller admission-control signal, not
# backend distress — the same exclusion bin/lib/pressure_control.py's
# PRESSURE_KINDS comment and bin/heimdall-529-scan's classify() both already
# draw independently. Proven at both the weak (no-worktree) case and the
# exact attempts==1 fire boundary, mirroring the network proof above.
# ═════════════════════════════════════════════════════════════════════════
RATE_LIMIT_TEXT="Agent terminated early due to an API error: 429 Too Many Requests · rate limit exceeded, retry after 20s"

export HOME; HOME="$WORK/home-rl"
R_RL="arpressratelim000007"
mk_agent "$R_RL" 10
mk_notif2 "$R_RL" failed "$RATE_LIMIT_TEXT"
RRL="$("$AR" report --json --repo "$REPO" --id "$R_RL" 2>/dev/null)"
[ "$(printf '%s' "$RRL" | jq -r '.[0].cause.class')" = "overloaded" ] \
  && ok "bare 429/rate-limit fixture STILL classifies overloaded (retry semantics unchanged)" \
  || bad "expected cause.class=overloaded for a bare 429, got $(printf '%s' "$RRL" | jq -c '.[0].cause')"
[ ! -f "$(state_file)" ] \
  && ok "FALSIFIER (a): a death whose text carries ONLY a 429/rate-limit marker records NO overloaded_error pressure event" \
  || bad "GUARD BROKEN: a bare 429/rate-limit death recorded a pressure event — 429 must never be counted as backend capacity pressure"

# ── the strong case: a REAL worktree, freshly bumped to the EXACT
# attempts==1 boundary the overload path itself fires on — proving the
# guard isn't just "no worktree means no marker to fire from" but a real
# text-based discrimination that holds even when every OTHER condition for
# firing is satisfied. ──────────────────────────────────────────────────
export HOME; HOME="$WORK/home-rl-real"
WT_RL="$WORK/wt-ratelimit-real"
mk_worktree "$WT_RL" "worktree-agent-rrlreal"
R_RLREAL="arpressratelimreal008"
mk_agent_wt "$R_RLREAL" 10 "$WT_RL" "worktree-agent-rrlreal" "Pressure fixture rate-limit-real"
mk_notif2 "$R_RLREAL" killed "$RATE_LIMIT_TEXT"
RRLR="$("$AR" report --json --repo "$REPO" --id "$R_RLREAL" 2>/dev/null)"
[ "$(printf '%s' "$RRLR" | jq -r '.[0].cause.class')" = "overloaded" ] \
  && ok "429+real-worktree fixture classifies overloaded" \
  || bad "expected cause.class=overloaded, got $(printf '%s' "$RRLR" | jq -c '.[0].cause')"
[ "$(printf '%s' "$RRLR" | jq -r '.[0].cause.retry_now')" = "true" ] && [ "$(printf '%s' "$RRLR" | jq -r '.[0].cause.attempts')" = "1" ] \
  && ok "429+real-worktree: retry_now=true, attempts=1 — bounded-retry bookkeeping is IDENTICAL to a genuine 529 (falsifier (c))" \
  || bad "expected retry_now=true, attempts=1 for a bare 429, got $(printf '%s' "$RRLR" | jq -c '.[0].cause')"
[ ! -f "$(state_file)" ] \
  && ok "FALSIFIER: 429 at attempts=1 (the overload path's own fire condition) still records nothing" \
  || bad "GUARD BROKEN: a bare 429 at attempts=1 recorded a pressure event — 429 must stay unwired even at the fire boundary"

# ═════════════════════════════════════════════════════════════════════════
# (d) NEVER LOAD-BEARING: heimdall-pressure absent, then actively failing —
# heimdall-agent-resume must still exit 0 with its normal .cause shape.
# ═════════════════════════════════════════════════════════════════════════
CAUSE_KEYS='class,retry_now,action,attempts,max_attempts,backoff_secs,attempts_exhausted'
assert_cause_shape() {
  local json="$1" label="$2" k present
  for k in class retry_now action attempts max_attempts backoff_secs attempts_exhausted; do
    present="$(printf '%s' "$json" | jq "has(\"$k\")" 2>/dev/null)"
    [ "$present" = "true" ] || { bad "$label: .cause missing key '$k'"; return 1; }
  done
  ok "$label: .cause carries its normal shape ($CAUSE_KEYS)"
}

export HOME; HOME="$WORK/home-d-absent"
WT_D1="$WORK/wt-overload-d1"
mk_worktree "$WT_D1" "worktree-agent-rovld1"
R_OVLD1="arpressovld10000004"
mk_agent_wt "$R_OVLD1" 10 "$WT_D1" "worktree-agent-rovld1" "Pressure fixture D1"
mk_notif2 "$R_OVLD1" killed "$OVERLOAD_TEXT"

RD1="$(HMD_AGENT_RESUME_PRESSURE_BIN="$WORK/no-such-heimdall-pressure" \
  "$AR" report --json --repo "$REPO" --id "$R_OVLD1" 2>/dev/null)"; RD1_RC=$?
[ "$RD1_RC" = "0" ] \
  && ok "(d) heimdall-pressure ABSENT: report still exits 0" \
  || bad "(d) heimdall-pressure absent changed report's exit code to $RD1_RC"
[ "$(printf '%s' "$RD1" | jq -r '.[0].cause.class')" = "overloaded" ] \
  && ok "(d) heimdall-pressure ABSENT: cause.class is still overloaded (classification unaffected)" \
  || bad "(d) heimdall-pressure absent corrupted cause.class: $(printf '%s' "$RD1" | jq -c '.[0].cause')"
assert_cause_shape "$(printf '%s' "$RD1" | jq -c '.[0].cause')" "(d) heimdall-pressure ABSENT"

FAKE_FAIL="$WORK/fake-heimdall-pressure-fail"
printf '#!/bin/sh\necho "boom: heimdall-pressure exploded" >&2\nexit 17\n' > "$FAKE_FAIL"
chmod +x "$FAKE_FAIL"

export HOME; HOME="$WORK/home-d-failing"
WT_D2="$WORK/wt-overload-d2"
mk_worktree "$WT_D2" "worktree-agent-rovld2"
R_OVLD2="arpressovld20000005"
mk_agent_wt "$R_OVLD2" 10 "$WT_D2" "worktree-agent-rovld2" "Pressure fixture D2"
mk_notif2 "$R_OVLD2" killed "$OVERLOAD_TEXT"

RD2="$(HMD_AGENT_RESUME_PRESSURE_BIN="$FAKE_FAIL" \
  "$AR" report --json --repo "$REPO" --id "$R_OVLD2" 2>/dev/null)"; RD2_RC=$?
[ "$RD2_RC" = "0" ] \
  && ok "(d) heimdall-pressure FAILING (exit 17): report still exits 0" \
  || bad "(d) a failing heimdall-pressure changed report's exit code to $RD2_RC"
[ "$(printf '%s' "$RD2" | jq -r '.[0].cause.class')" = "overloaded" ] \
  && ok "(d) heimdall-pressure FAILING: cause.class is still overloaded" \
  || bad "(d) a failing heimdall-pressure corrupted cause.class: $(printf '%s' "$RD2" | jq -c '.[0].cause')"
assert_cause_shape "$(printf '%s' "$RD2" | jq -c '.[0].cause')" "(d) heimdall-pressure FAILING"

echo "--------------------------------------------------------------------"
echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
