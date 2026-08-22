#!/usr/bin/env bash
# test/brief-adoption-gate.test.sh — falsifiable tests for the PreToolUse/Agent
# hook's brief-adoption ENFORCEMENT (hooks/hooks.json delegates to
# bin/heimdall-precheck-agent): an oversized, brief-less, non-fork spawn prompt
# gets a REAL delta brief built via heimdall-brief and MECHANICALLY
# SUBSTITUTED into tool_input via the hook's updatedInput (Claude Code's
# PreToolUse contract — confirmed by inspecting the installed CLI binary:
# hookSpecificOutput.updatedInput is schema-validated and actually applied,
# not advisory). This is the adoption half of the H-4 protocol gap: the
# orchestrator no longer has to choose to adopt heimdall-brief — a warning was
# measured to be ignored 100% of the time (0 real heimdall-brief invocations
# across ~40 hand-written oversized spawn prompts in one session); a warning
# is just a prompt delivered by a hook, and it fails exactly like a prompt.
#
# The ONE case this cannot silently paper over: if heimdall-brief itself
# cannot verify the protocol store (NON_VERIFIED, exit 3 — the store is
# unreachable, not merely empty), substituting a brief that was never checked
# would be worse than the old advisory-only gap, so the hook DENIES instead,
# naming the exact command. Everything else (missing jq, missing
# heimdall-brief binary, any other unexpected exit code) fails OPEN — a broken
# hook must never block all work; only a store-level NON_VERIFIED is a
# deliberate deny.
#
# Hermetic: extracts the live hook command from hooks/hooks.json and fires it
# against synthetic payloads in a sandboxed cwd, with HEIMDALL_PLANNING_DIR
# pointed at a throwaway dir so this never touches the real repo's .planning/.
# No network, no real spawns.
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
PLANNING="$WORK/planning"; mkdir -p "$PLANNING"
GATE="$WORK/gate.sh"
OUT="$WORK/out"; ERR="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

AGENT_MATCHERS="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length' "$HOOKS")"
checkeq "exactly one PreToolUse/Agent matcher block" "$AGENT_MATCHERS" "1"

jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | .[0].hooks[0].command // empty' "$HOOKS" > "$GATE"
if [ -s "$GATE" ]; then ok "extracted the Agent hook command"; else bad "extracted the Agent hook command"; fi

if grep -q 'heimdall-precheck-agent' "$GATE"; then ok "hook delegates enforcement to heimdall-precheck-agent"; else bad "hook delegates enforcement to heimdall-precheck-agent"; fi
if grep -q 'parallelism-tracker' "$GATE"; then ok "parallelism-tracker call preserved"; else bad "parallelism-tracker call preserved"; fi
if grep -qE 'echo[[:space:]]*"\$' "$GATE"; then bad 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; else ok 'no echo "$VAR" (macOS /bin/sh backslash-escape bug)'; fi

PRECHECK="$ROOT/bin/heimdall-precheck-agent"
if [ -x "$PRECHECK" ]; then ok "bin/heimdall-precheck-agent exists and is executable"; else bad "bin/heimdall-precheck-agent exists and is executable"; fi
if bash -n "$PRECHECK" 2>/dev/null; then ok "bash -n heimdall-precheck-agent"; else bad "bash -n heimdall-precheck-agent"; fi

fire() {
  set +e
  ( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" HEIMDALL_PLANNING_DIR="$PLANNING" sh "$GATE" <"$1" >"$OUT" 2>"$ERR" )
  RC=$?
  set -e
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

echo "== oversized, brief-less spawn: gets a real brief built and substituted =="
payload 400 general-purpose "" > "$WORK/p1.json"
fire "$WORK/p1.json"
checkeq "oversized spawn exits 0 (substituted, not blocked)" "$RC" "0"
if grep -q "brief-adoption notice" "$ERR"; then ok "substitution is announced with the brief-adoption marker"; else bad "substitution is announced with the brief-adoption marker"; fi
NEWPROMPT="$(jq -r '.hookSpecificOutput.updatedInput.prompt // empty' "$OUT" 2>/dev/null)"
case "$NEWPROMPT" in
  "=== DELTA BRIEF"*) ok "updatedInput.prompt is a real === DELTA BRIEF (not the raw prose)" ;;
  *) bad "updatedInput.prompt is a real === DELTA BRIEF (not the raw prose)" ;;
esac
if printf '%s' "$NEWPROMPT" | grep -q "^TASK SPEC:"; then ok "the substituted brief carries the original spec"; else bad "the substituted brief carries the original spec"; fi
DESC="$(jq -r '.hookSpecificOutput.updatedInput.description // empty' "$OUT" 2>/dev/null)"
checkeq "updatedInput preserves the other tool_input fields (description)" "$DESC" "t"
SATYPE_OUT="$(jq -r '.hookSpecificOutput.updatedInput.subagent_type // empty' "$OUT" 2>/dev/null)"
checkeq "updatedInput preserves the other tool_input fields (subagent_type)" "$SATYPE_OUT" "general-purpose"
PDEC="$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$OUT" 2>/dev/null)"
checkeq "permissionDecision is allow (never blocks a healthy substitution)" "$PDEC" "allow"

echo "== does not fire on a small prompt =="
payload 50 general-purpose "" > "$WORK/p2.json"
fire "$WORK/p2.json"
checkeq "small prompt exits 0" "$RC" "0"
if [ -s "$OUT" ]; then bad "small prompt: no substitution (stdout empty)"; else ok "small prompt: no substitution (stdout empty)"; fi
if grep -q "brief-adoption notice" "$ERR"; then bad "small prompt does not warn"; else ok "small prompt does not warn"; fi

echo "== fork is exempt regardless of size =="
payload 900 fork "" > "$WORK/p3.json"
fire "$WORK/p3.json"
if [ -s "$OUT" ]; then bad "subagent_type:fork with a huge prompt is not substituted"; else ok "subagent_type:fork with a huge prompt is not substituted"; fi
if grep -q "brief-adoption notice" "$ERR"; then bad "subagent_type:fork with a huge prompt does not warn"; else ok "subagent_type:fork with a huge prompt does not warn"; fi

echo "== a heimdall-brief-built prompt is exempt regardless of size =="
BRIEF_WORDS="$(i=0; while [ "$i" -lt 400 ]; do i=$((i+1)); printf 'word%d ' "$i"; done)"
jq -cn --arg p "=== DELTA BRIEF — task T-x ===
$BRIEF_WORDS" '{tool_name:"Agent", tool_input:{description:"t", prompt:$p, subagent_type:"general-purpose"}}' > "$WORK/p4.json"
fire "$WORK/p4.json"
if [ -s "$OUT" ]; then bad "a === DELTA BRIEF prompt is not re-substituted even when long"; else ok "a === DELTA BRIEF prompt is not re-substituted even when long"; fi
if grep -q "brief-adoption notice" "$ERR"; then bad "a === DELTA BRIEF prompt does not warn even when long"; else ok "a === DELTA BRIEF prompt does not warn even when long"; fi

echo "== HEIMDALL_ALLOW_LONG_BRIEF=1 opts a spawn out of auto-substitution =="
set +e
( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" HEIMDALL_PLANNING_DIR="$PLANNING" HEIMDALL_ALLOW_LONG_BRIEF=1 sh "$GATE" <"$WORK/p1.json" >"$OUT" 2>"$ERR" )
set -e
if [ -s "$OUT" ]; then bad "HEIMDALL_ALLOW_LONG_BRIEF=1 skips substitution"; else ok "HEIMDALL_ALLOW_LONG_BRIEF=1 skips substitution"; fi
if grep -q "brief-adoption notice" "$ERR"; then bad "HEIMDALL_ALLOW_LONG_BRIEF=1 suppresses the notice"; else ok "HEIMDALL_ALLOW_LONG_BRIEF=1 suppresses the notice"; fi

echo "== combined name: + oversized prompt still substitutes AND fires the named-agent marker =="
payload 400 general-purpose "my-named-agent" > "$WORK/p5.json"
fire "$WORK/p5.json"
checkeq "combined payload still exits 0 (substituted)" "$RC" "0"
if grep -q "brief-adoption notice" "$ERR"; then ok "combined payload still fires the brief-adoption marker"; else bad "combined payload still fires the brief-adoption marker"; fi
if grep -q "named-agent notice" "$ERR"; then ok "combined payload still fires the named-agent marker"; else bad "combined payload still fires the named-agent marker"; fi

echo "== the ONE real deny: heimdall-brief NON_VERIFIED (protocol store unreachable) =="
BLOCKED="$WORK/blocked-planning"
: > "$BLOCKED"   # a FILE at this path, not a dir -> mkdir -p "$BLOCKED/protocol" fails -> NON_VERIFIED
set +e
( cd "$SANDBOX" 2>/dev/null && CLAUDE_PLUGIN_ROOT="$ROOT" HEIMDALL_PLANNING_DIR="$BLOCKED" sh "$GATE" <"$WORK/p1.json" >"$OUT" 2>"$ERR" )
RC=$?
set -e
checkeq "NON_VERIFIED store denies (exit 2)" "$RC" "2"
if jq -e . "$OUT" >/dev/null 2>&1; then ok "deny stdout is valid JSON"; else bad "deny stdout is valid JSON"; fi
if jq -r '.error // empty' "$OUT" 2>/dev/null | grep -q "heimdall-brief build --task"; then ok "deny names the exact command (heimdall-brief build --task)"; else bad "deny names the exact command (heimdall-brief build --task)"; fi
if grep -q "brief-adoption notice" "$ERR"; then ok "deny is also announced on stderr with the brief-adoption marker"; else bad "deny is also announced on stderr with the brief-adoption marker"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
