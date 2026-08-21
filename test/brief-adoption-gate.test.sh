#!/usr/bin/env bash
# test/brief-adoption-gate.test.sh — falsifiable tests for the PreToolUse/Agent
# hook's brief-adoption notice (hooks/hooks.json): warns when a spawn prompt is
# oversized and doesn't look heimdall-brief-built, nudging toward heimdall-brief
# (send) and heimdall-task-result (return). Mechanical enforcement, not
# advisory -- this is the adoption half of the H-4 protocol gap.
#
# Hermetic: extracts the live hook command from hooks/hooks.json and fires it
# against synthetic payloads in a sandboxed cwd. No network, no real spawns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

WORK="$(mktemp -d)"
SANDBOX="$WORK/sandbox"; mkdir -p "$SANDBOX"
GATE="$WORK/gate.sh"
OUT="$WORK/out"; ERR="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

AGENT_MATCHERS="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length' "$HOOKS")"
checkeq "exactly one PreToolUse/Agent matcher block" "$AGENT_MATCHERS" "1"

jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | .[0].hooks[0].command // empty' "$HOOKS" > "$GATE"
if [ -s "$GATE" ]; then ok "extracted the Agent hook command"; else bad "extracted the Agent hook command"; fi

if grep -qE 'exit[[:space:]]+2' "$GATE"; then bad "hook never hard-blocks (no exit 2 anywhere)"; else ok "hook never hard-blocks (no exit 2 anywhere)"; fi
if grep -q 'parallelism-tracker' "$GATE"; then ok "parallelism-tracker call preserved"; else bad "parallelism-tracker call preserved"; fi
if grep -qE 'echo[[:space:]]*"\$' "$GATE"; then bad 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; else ok 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; fi

fire() {
  ( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" sh "$GATE" <"$1" >"$OUT" 2>"$ERR" )
  RC=$?
}

payload() {
  # payload <words> <subagent_type|""> <name|""> -> synthetic Agent tool_input JSON on stdout.
  words="$1"; satype="$2"; name="$3"
  prompt="$(i=0; while [ "$i" -lt "$words" ]; do i=$((i+1)); printf 'word%d ' "$i"; done)"
  jq -cn --arg p "$prompt" --arg s "$satype" --arg n "$name" \
    '{tool_name:"Agent", tool_input:({description:"t", prompt:$p}
      + (if $s != "" then {subagent_type:$s} else {} end)
      + (if $n != "" then {name:$n} else {} end))}'
}

echo "== fires on oversized, brief-less spawn =="
payload 400 general-purpose "" > "$WORK/p1.json"
fire "$WORK/p1.json"
checkeq "oversized spawn exits 0 (warns, never blocks)" "$RC" "0"
if grep -q "brief-adoption notice" "$ERR"; then ok "oversized brief-less spawn WARNS with the brief-adoption marker"; else bad "oversized brief-less spawn WARNS with the brief-adoption marker"; fi

echo "== does not fire on a small prompt =="
payload 50 general-purpose "" > "$WORK/p2.json"
fire "$WORK/p2.json"
if grep -q "brief-adoption notice" "$ERR"; then bad "small prompt does not warn"; else ok "small prompt does not warn"; fi

echo "== fork is exempt regardless of size =="
payload 900 fork "" > "$WORK/p3.json"
fire "$WORK/p3.json"
if grep -q "brief-adoption notice" "$ERR"; then bad "subagent_type:fork with a huge prompt does not warn"; else ok "subagent_type:fork with a huge prompt does not warn"; fi

echo "== a heimdall-brief-built prompt is exempt regardless of size =="
BRIEF_WORDS="$(i=0; while [ "$i" -lt 400 ]; do i=$((i+1)); printf 'word%d ' "$i"; done)"
jq -cn --arg p "=== DELTA BRIEF — task T-x ===
$BRIEF_WORDS" '{tool_name:"Agent", tool_input:{description:"t", prompt:$p, subagent_type:"general-purpose"}}' > "$WORK/p4.json"
fire "$WORK/p4.json"
if grep -q "brief-adoption notice" "$ERR"; then bad "a === DELTA BRIEF prompt does not warn even when long"; else ok "a === DELTA BRIEF prompt does not warn even when long"; fi

echo "== HEIMDALL_ALLOW_LONG_BRIEF=1 silences it =="
( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" HEIMDALL_ALLOW_LONG_BRIEF=1 sh "$GATE" <"$WORK/p1.json" >"$OUT" 2>"$ERR" ) || true
if grep -q "brief-adoption notice" "$ERR"; then bad "HEIMDALL_ALLOW_LONG_BRIEF=1 suppresses the notice"; else ok "HEIMDALL_ALLOW_LONG_BRIEF=1 suppresses the notice"; fi

echo "== combined name: + oversized prompt fires BOTH markers =="
payload 400 general-purpose "my-named-agent" > "$WORK/p5.json"
fire "$WORK/p5.json"
if grep -q "brief-adoption notice" "$ERR"; then ok "combined payload still fires the brief-adoption marker"; else bad "combined payload still fires the brief-adoption marker"; fi
if grep -q "named-agent notice" "$ERR"; then ok "combined payload still fires the named-agent marker"; else bad "combined payload still fires the named-agent marker"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
