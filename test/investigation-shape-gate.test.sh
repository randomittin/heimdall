#!/usr/bin/env bash
# test/investigation-shape-gate.test.sh — falsifiable tests for the PreToolUse/
# Agent hook's investigation-shape notice (hooks/hooks.json): warns when a spawn
# prompt reads as open-ended discovery (find why / diagnose / root-cause /
# investigate / profile) but names no acceptance test, target metric, or
# expected count. Mechanical enforcement, not advisory.
#
# WHY THIS EXISTS
# ----------------
# Measured in one real session: ~500k tokens went to agents spawned with
# exactly this shape of prompt ("find why X is slow", "root-cause Y") and every
# one of them landed zero commits, zero dirty files, zero report — the agent
# explored until its context died because an investigation has no natural
# stopping point. By contrast, every task handed a completed diagnosis PLUS a
# concrete target ("take the subagent count off the render path", "suite X
# 46/1 -> 47/0") converged and landed a working fix. This hook cannot tell a
# good investigation from a bad one, so it never blocks — it only nudges
# toward diagnosing first (cheap, 3-6 tool calls) and delegating the bounded
# implementation instead, pointing at heimdall-brief for the handoff itself.
#
# TWO-SIGNAL DESIGN (why this doesn't fire on everything)
# ---------------------------------------------------------
# The notice requires BOTH: (a) an investigation verb/phrase AND (b) the
# ABSENCE of any falsifiable-criterion marker (a named test file, a numeric
# target/metric, an explicit "acceptance"/"target:"/"assert" marker). Verb
# alone would fire on legitimate "diagnose and fix, target: p95 <200ms in
# test/x.test.sh" tasks — exactly the pattern that DID work this session.
# Criterion-absence alone would fire on huge swaths of ordinary implementation
# prompts that simply don't happen to cite a number. Requiring both is what
# keeps the false-positive rate low enough that the notice stays a signal
# instead of noise that gets muted.
#
# subagent_type:fork is exempt regardless of shape: forking is the sanctioned
# way to delegate open-ended research (it shares the parent's prompt cache, so
# the cost profile that makes fresh-context investigation agents so expensive
# does not apply) — same exemption brief-adoption-gate already grants forks,
# for the same underlying reason.
#
# Hermetic: extracts the live hook command from hooks/hooks.json and fires it
# against synthetic payloads in a sandboxed cwd. No network, no real spawns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# Mute switches must not leak in from the caller's environment, or the
# assertions that expect a warning would go silently, misleadingly green.
unset HEIMDALL_ALLOW_INVESTIGATION HEIMDALL_ALLOW_LONG_BRIEF HEIMDALL_ALLOW_NAMED_AGENT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

WORK="$(mktemp -d)"
SANDBOX="$WORK/sandbox"; mkdir -p "$SANDBOX"
GATE="$WORK/gate.sh"
OUT="$WORK/out"; ERR="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

MARKER="investigation-shape notice"

echo "== structural: still exactly one PreToolUse/Agent matcher (extended, not duplicated) =="
AGENT_MATCHERS="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length' "$HOOKS")"
checkeq "exactly one PreToolUse/Agent matcher block" "$AGENT_MATCHERS" "1"

jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | .[0].hooks[0].command // empty' "$HOOKS" > "$GATE"
if [ -s "$GATE" ]; then ok "extracted the Agent hook command"; else bad "extracted the Agent hook command"; fi

if grep -qE 'exit[[:space:]]+2' "$GATE"; then bad "hook never hard-blocks (no exit 2 anywhere)"; else ok "hook never hard-blocks (no exit 2 anywhere)"; fi
if grep -q 'parallelism-tracker' "$GATE"; then ok "parallelism-tracker call preserved"; else bad "parallelism-tracker call preserved"; fi
if grep -q 'brief-adoption notice' "$GATE"; then ok "brief-adoption notice preserved (not weakened)"; else bad "brief-adoption notice preserved (not weakened)"; fi
if grep -q 'named-agent notice' "$GATE"; then ok "named-agent notice preserved (not weakened)"; else bad "named-agent notice preserved (not weakened)"; fi
if grep -qE 'echo[[:space:]]*"\$' "$GATE"; then bad 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; else ok 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; fi
if grep -q 'HEIMDALL_ALLOW_INVESTIGATION' "$GATE"; then ok "mute switch HEIMDALL_ALLOW_INVESTIGATION is wired"; else bad "mute switch HEIMDALL_ALLOW_INVESTIGATION is wired"; fi

fire() {
  # fire <payload-file> [env assignments...] — runs the shipped command under
  # /bin/sh, exactly as the harness does, in the sandboxed cwd.
  local payload="$1"; shift
  ( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" env "$@" sh "$GATE" <"$payload" >"$OUT" 2>"$ERR" )
  RC=$?
}

payload() {
  # payload <prompt> <subagent_type|""> <name|""> -> synthetic Agent
  # tool_input JSON on stdout.
  prompt="$1"; satype="$2"; name="$3"
  jq -cn --arg p "$prompt" --arg s "$satype" --arg n "$name" \
    '{tool_name:"Agent", tool_input:({description:"t", prompt:$p}
      + (if $s != "" then {subagent_type:$s} else {} end)
      + (if $n != "" then {name:$n} else {} end))}'
}

padwords() { # padwords <n> -> "word1 word2 ... wordN"
  i=0; while [ "$i" -lt "$1" ]; do i=$((i+1)); printf 'word%d ' "$i"; done
}

echo "== fires: investigation verb, no falsifiable criterion =="
payload "find why the statusline is slow" general-purpose "" > "$WORK/p1.json"
fire "$WORK/p1.json"
checkeq "investigation-shaped spawn exits 0 (warns, never blocks)" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then ok "investigation-shaped, target-less spawn WARNS"; else bad "investigation-shaped, target-less spawn WARNS"; fi
if grep -q "heimdall-brief" "$ERR"; then ok "notice points at heimdall-brief"; else bad "notice points at heimdall-brief"; fi
if grep -qE '3-6' "$ERR"; then ok "notice names the cheap diagnose-first bound (3-6 tool calls)"; else bad "notice names the cheap diagnose-first bound (3-6 tool calls)"; fi
if grep -qiE 'zero commit|500k' "$ERR"; then ok "notice keeps the measured cost (500k tokens / zero commits)"; else bad "notice keeps the measured cost (500k tokens / zero commits)"; fi
if grep -q "HEIMDALL_ALLOW_INVESTIGATION" "$ERR"; then ok "notice names its own mute switch"; else bad "notice names its own mute switch"; fi

echo "== fires: each named verb (find why / diagnose / root-cause / investigate / profile) =="
for phrase in \
  "find why the queue backs up under load" \
  "diagnose the memory leak in the worker pool" \
  "root-cause the intermittent 500s" \
  "investigate the timeout in the ingest path" \
  "profile the render loop"
do
  payload "$phrase" general-purpose "" > "$WORK/pv.json"
  fire "$WORK/pv.json"
  if [ "$RC" = "0" ] && grep -q "$MARKER" "$ERR"; then
    ok "warns on: '$phrase'"
  else
    bad "warns on: '$phrase' (rc=$RC)"
  fi
done

echo "== silent: well-formed implementation prompt naming a test file + numeric target =="
payload "Refactor the wall renderer to take the subagent count off the render path. Acceptance: test/widget-status.test.sh goes from 46/1 to 47/0." general-purpose "" > "$WORK/p2.json"
fire "$WORK/p2.json"
checkeq "targeted implementation spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then bad "targeted implementation prompt does not warn"; else ok "targeted implementation prompt does not warn"; fi

echo "== silent: investigation verb PLUS an explicit target (the AND-gate) =="
payload "Diagnose and fix the statusline slowdown; target: p95 render time under 200ms, verified by test/statusline-perf.test.sh." general-purpose "" > "$WORK/p3.json"
fire "$WORK/p3.json"
checkeq "diagnose-with-target spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then bad "an investigation verb WITH a named target does not warn (bounded diagnose-then-fix)"; else ok "an investigation verb WITH a named target does not warn (bounded diagnose-then-fix)"; fi

echo "== silent: ordinary bounded prompt, no investigation verb, no metrics either =="
payload "Add a login page following the existing pattern in src/pages/Signup.tsx" general-purpose "" > "$WORK/p4.json"
fire "$WORK/p4.json"
checkeq "ordinary bounded spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then bad "an ordinary bounded prompt without metrics does not false-positive"; else ok "an ordinary bounded prompt without metrics does not false-positive"; fi

echo "== silent: fork is exempt regardless of shape =="
payload "find why the statusline is slow, profile it end to end, investigate the root cause" fork "" > "$WORK/p5.json"
fire "$WORK/p5.json"
checkeq "fork spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then bad "subagent_type:fork with heavy investigation language does not warn"; else ok "subagent_type:fork with heavy investigation language does not warn"; fi

echo "== HEIMDALL_ALLOW_INVESTIGATION=1 silences it =="
fire "$WORK/p1.json" HEIMDALL_ALLOW_INVESTIGATION=1
checkeq "muted investigation-shaped spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then bad "HEIMDALL_ALLOW_INVESTIGATION=1 suppresses the notice"; else ok "HEIMDALL_ALLOW_INVESTIGATION=1 suppresses the notice"; fi

echo "== composes with the named-agent notice (both fire, neither displaces the other) =="
payload "find why the statusline is slow" general-purpose "my-named-agent" > "$WORK/p6.json"
fire "$WORK/p6.json"
checkeq "combined investigation+name spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then ok "combined payload still fires the investigation-shape marker"; else bad "combined payload still fires the investigation-shape marker"; fi
if grep -q "named-agent notice" "$ERR"; then ok "combined payload still fires the named-agent marker"; else bad "combined payload still fires the named-agent marker"; fi

echo "== composes with the brief-adoption notice (both fire on a big, brief-less, investigation-shaped prompt) =="
BIGPROMPT="find why this subsystem is slow $(padwords 350)"
payload "$BIGPROMPT" general-purpose "" > "$WORK/p7.json"
fire "$WORK/p7.json"
checkeq "combined investigation+oversized spawn exits 0" "$RC" "0"
if grep -q "$MARKER" "$ERR"; then ok "combined payload still fires the investigation-shape marker"; else bad "combined payload still fires the investigation-shape marker"; fi
if grep -q "brief-adoption notice" "$ERR"; then ok "combined payload still fires the brief-adoption marker"; else bad "combined payload still fires the brief-adoption marker"; fi

echo "== never blocks: malformed and empty payloads =="
printf '%s' '{"tool_name":"Agent","tool_input":{"description":"truncated' > "$WORK/malformed.json"
fire "$WORK/malformed.json"
checkeq "malformed payload exits 0 (never blocks)" "$RC" "0"

: > "$WORK/empty.json"
fire "$WORK/empty.json"
checkeq "empty payload exits 0 (never blocks)" "$RC" "0"

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
