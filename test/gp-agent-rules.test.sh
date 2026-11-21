#!/usr/bin/env bash
# gp-agent-rules harness
#
# Covers the general-purpose rules section of bin/heimdall-precheck-agent (2026-11-10; docs/analysis/2026-11-10-stale-general-purpose-agents.md,
# Fix item 2). A general-purpose subagent gets none of hmd's agent rules, and measured on 2102 subagent transcripts that is where the stale
# agents come from: they wait in a FOREGROUND poll loop for a job they started themselves and run long Bash commands with no timeout. The hook
# now appends a short rules block, opened by the marker line `[hmd agent rules]`, to the PROMPT of a spawn whose subagent_type is
# general-purpose or absent/empty (the Agent tool takes that as general-purpose), through the hook's own updatedInput.
#
# Falsifiable both ways: general-purpose, an absent and an empty subagent_type each get the block, after the original prompt, marker once, rules
# present, terse; hmd:* and every other type (fork, Explore, a type that only CONTAINS the words) get nothing at all on stdout; a prompt that
# already carries the marker is not rewritten again; HMD_GP_RULES_OFF=1 opts out and only exactly 1 does; every other tool_input field survives
# (model, run_in_background, isolation, description); the commit rule follows the spawn's isolation (isolation "worktree" has a checkout of its own and is
# told to commit early; every other spawn runs in the MAIN checkout, where a commit sweeps in parallel agents' edits, so it is told NOT to commit and to leave
# its changes to the orchestrator: review finding F2); it composes with the brief-adoption gate (the block is NOT counted against the brief word
# threshold, and a prompt that gate DOES replace carries the block too, in the same updatedInput); every shape it cannot rewrite, a malformed or
# empty payload and a jq that fails on the rewrite leave the spawn untouched (exit 0, nothing on stdout); the section has no `exit`, so it cannot
# deny; the shipped hooks.json Agent command delivers the rewrite; and six mutants of the hook (opt-out ignored, idempotence gone, every type
# matched, isolation ignored, isolation never recognised, the 30-minute wait limit dropped) each go wrong in the way an assertion above catches.
#
# Hermetic: every invocation runs the REAL hook under `env -i` from a scratch cwd with its own HOME/HEIMDALL_HOME/planning dir, with
# HMD_MIN_FREE_PCT=0 (the disk-floor fence would otherwise read THIS machine's free space) and HMD_CTX_GATE_OFF=1 (the context fence would
# otherwise consult ambient state), like test/agent-name-gate.test.sh and test/agent-fix-chain.test.sh, whose one-suite-per-hook-section shape
# this follows. No network, no real spawns.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
HOOKS_JSON="$REPO/hooks/hooks.json"
MARKER='[hmd agent rules]'

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$REAL_HOOK" ] || { echo "FATAL: missing $REAL_HOOK" >&2; exit 2; }
[ -f "$HOOKS_JSON" ] || { echo "FATAL: missing $HOOKS_JSON" >&2; exit 2; }
REAL_JQ="$(command -v jq)"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gp-agent-rules.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/cwd" "$SANDBOX/home" "$SANDBOX/planning" "$SANDBOX/mut" "$SANDBOX/fakebin"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { # check <label> <command...>   ok when the command succeeds
  local label="$1"
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# fire_hook <hook> <payload-file> [VAR=value ...]  -> RC, $OUT, $ERR   (clean environment, scratch cwd, payload on stdin)
fire_hook() {
  local hook="$1" pf="$2"
  shift 2
  : >"$OUT"; : >"$ERR"
  ( cd "$SANDBOX/cwd" && env -i "HOME=$SANDBOX/home" "HEIMDALL_HOME=$SANDBOX/home/.heimdall" "HEIMDALL_PLANNING_DIR=$SANDBOX/planning" \
      "PATH=$PATH" "HMD_MIN_FREE_PCT=0" "HMD_CTX_GATE_OFF=1" "$@" bash "$hook" <"$pf" >"$OUT" 2>"$ERR" )
  RC=$?
}
fire() { fire_hook "$REAL_HOOK" "$@"; }

# payload <file> <subagent_type|-> <prompt> [extra tool_input fields as one JSON object]   ("-" leaves subagent_type out altogether)
payload() {
  local extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg s "$2" --arg p "$3" --argjson x "$extra" \
    '{tool_name:"Agent", tool_input: ({description:"probe", prompt:$p} + (if $s == "-" then {} else {subagent_type:$s} end) + $x)}' >"$1"
}

jqt() { jq -e "$@" >/dev/null 2>&1; }                                           # jqt <jq args...> <file>   true when the filter is truthy
newprompt() { jq -r '.hookSpecificOutput.updatedInput.prompt // empty' "$OUT"; }  # the prompt the hook sends on
untouched() { [ "$RC" = 0 ] && [ ! -s "$OUT" ]; }                                 # exit 0 and nothing on stdout: the spawn goes through as sent
rewrote() { [ "$RC" = 0 ] && jqt --arg m "$MARKER" '.hookSpecificOutput.updatedInput.prompt | contains($m)' "$OUT"; }
marker_lines() { printf '%s\n' "$1" | grep -cxF -- "$MARKER"; }                   # marker occurrences as a line of its own
block_of() { printf '%s\n' "$1" | sed -n '/^\[hmd agent rules\]$/,$p'; }          # the marker line and everything after it
marker_after_spec() { printf '%s\n' "$1" | awk -v m="$MARKER" 'index($0, "TASK SPEC:") == 1 { s = NR } $0 == m { b = NR } END { exit !(s > 0 && b > s) }'; }
lacks() { ! grep -qF -- "$1" "$2"; }                                              # lacks <text> <file>   true when the file does not contain the text
has_text() { grep -qiF -- "$1" <<<"$2"; }                                         # has_text <text> <string>   true when the string contains the text (case-insensitive)
lacks_text() { ! has_text "$1" "$2"; }
words() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "word%d ", i }'; }

echo "gp-agent-rules harness"
echo "--------------------------------------------------------------------"

# ── 0. the subject exists and is wired the way it must stay ───────────────────────────────────
bash -n "$REAL_HOOK" 2>/dev/null && ok "real hook parses (bash -n)" || bad "real hook fails bash -n"
SECTION="$(sed -n '/^# -- general-purpose agent rules/,/^# -- end general-purpose agent rules/p' "$REAL_HOOK")"
if [ -z "$SECTION" ]; then
  bad "could not isolate the general-purpose rules section (markers missing or moved) — the no-exit check below would be vacuous"
elif grep -v '^[[:space:]]*#' <<<"$SECTION" | grep -qE '(^|[^A-Za-z_])exit([[:space:]]|$)'; then
  bad "the general-purpose rules section contains an exit — some input path could end the hook, and it must never be able to deny"
else
  ok "the general-purpose rules section contains no exit — it can rewrite, it cannot deny"
fi

# ── 1. general-purpose, an absent and an empty subagent_type each get the block ───────────────
P1='Find where the retry logic lives and report the file paths.'
payload "$SANDBOX/gp.json" general-purpose "$P1"
fire "$SANDBOX/gp.json"
NEWP="$(newprompt)"
check "general-purpose: exits 0" test "$RC" = 0
check "general-purpose: stdout is a PreToolUse allow carrying an updatedInput object" \
  jqt '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "allow" and (.updatedInput | type) == "object"' "$OUT"
check "general-purpose: the original prompt is kept verbatim, at the start" \
  jqt --arg o "$P1" '.hookSpecificOutput.updatedInput.prompt | startswith($o)' "$OUT"
check "general-purpose: the marker line is there exactly once" test "$(marker_lines "$NEWP")" = 1
BLOCK="$(block_of "$NEWP")"
MISSING=""
for tok in 'until' 'tail -f' 'pgrep' 'run_in_background' 'Monitor' 'timeout' '30 minutes' 'waiting for' 'commit' 'once' 'concise'; do
  grep -qiF -- "$tok" <<<"$BLOCK" || MISSING="$MISSING [$tok]"
done
[ -z "$MISSING" ] && ok "general-purpose: the block carries every rule (no foreground polling, run_in_background + Monitor, explicit timeout, give up waiting after 30 minutes and report what it waited for, a commit rule, tests once, concise report)" \
  || bad "general-purpose: the block is missing:$MISSING"
BLOCK_LINES="$(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ')"
[ "$BLOCK_LINES" -ge 5 ] && [ "$BLOCK_LINES" -le 10 ] && ok "general-purpose: the block is terse (5 to 10 lines, it is $BLOCK_LINES)" || bad "general-purpose: the block is $BLOCK_LINES lines, want 5 to 10"

payload "$SANDBOX/untyped.json" - "$P1"
fire "$SANDBOX/untyped.json"
check "absent subagent_type (defaults to general-purpose): gets the block" rewrote
check "absent subagent_type: marker once" test "$(marker_lines "$(newprompt)")" = 1
payload "$SANDBOX/emptytype.json" "" "$P1"
fire "$SANDBOX/emptytype.json"
check "empty subagent_type: gets the block" rewrote

# ── 2. every other type is untouched ──────────────────────────────────────────────────────────
for t in hmd:coder hmd:test-runner Explore fork my:general-purpose general-purpose-2; do
  payload "$SANDBOX/other.json" "$t" "$P1"
  fire "$SANDBOX/other.json"
  check "subagent_type=$t: untouched (exit 0, nothing on stdout)" untouched
done

# ── 3. idempotent ─────────────────────────────────────────────────────────────────────────────
payload "$SANDBOX/again.json" general-purpose "$NEWP"
fire "$SANDBOX/again.json"
check "a prompt that already carries the marker is not rewritten again (nothing on stdout)" untouched

# ── 4. the opt-out ────────────────────────────────────────────────────────────────────────────
fire "$SANDBOX/gp.json" HMD_GP_RULES_OFF=1
check "HMD_GP_RULES_OFF=1: untouched" untouched
fire "$SANDBOX/gp.json" HMD_GP_RULES_OFF=0
check "HMD_GP_RULES_OFF=0 does not opt out (only exactly 1 does)" rewrote
fire "$SANDBOX/gp.json" HMD_GP_RULES_OFF=yes
check "HMD_GP_RULES_OFF=yes does not opt out either" rewrote

# ── 5. every other tool_input field survives ──────────────────────────────────────────────────
payload "$SANDBOX/fields.json" general-purpose "$P1" '{"model":"sonnet","run_in_background":true,"isolation":"worktree"}'
fire "$SANDBOX/fields.json"
check "the rewrite happened" rewrote
check "every field but the prompt is carried over unchanged (updatedInput is the whole tool_input, not a delta)" \
  jqt --slurpfile inp "$SANDBOX/fields.json" '(.hookSpecificOutput.updatedInput | del(.prompt)) == ($inp[0].tool_input | del(.prompt))' "$OUT"
check "model, run_in_background, isolation, description and subagent_type are really in the output (the comparison above is not vacuous)" \
  jqt '.hookSpecificOutput.updatedInput | .model == "sonnet" and .run_in_background == true and .isolation == "worktree" and .description == "probe" and .subagent_type == "general-purpose"' "$OUT"

# ── 5b. the commit rule follows the spawn's isolation (review finding F2) ─────────────────────
# A spawn with isolation "worktree" has a checkout of its own, so "commit early and often" is safe for it. Any other spawn runs in the MAIN checkout: told to commit early it would commit on main
# mid-task and sweep in whatever parallel agents have edited, so it is told NOT to commit and to leave its changes to the orchestrator, and it is not asked for a commit sha either.
# gp.json (section 1) carries no isolation at all.
fire "$SANDBOX/gp.json"
SHARED_BLOCK="$(block_of "$(newprompt)")"
check "no isolation: the block tells the agent NOT to commit" has_text 'Do not commit' "$SHARED_BLOCK"
check "no isolation: the block does not tell the agent to commit early" lacks_text 'commit early' "$SHARED_BLOCK"
check "no isolation: the report line does not ask for a commit sha (an agent told not to commit has none to give)" lacks_text 'commit sha' "$SHARED_BLOCK"

payload "$SANDBOX/wt.json" general-purpose "$P1" '{"isolation":"worktree"}'
fire "$SANDBOX/wt.json"
WT_BLOCK="$(block_of "$(newprompt)")"
check "isolation worktree: the block tells the agent to commit early and often in its worktree" has_text 'Commit early and often in your worktree' "$WT_BLOCK"
check "isolation worktree: the block does not tell the agent to refrain from committing" lacks_text 'do not commit' "$WT_BLOCK"
check "isolation worktree: the report line still asks for the commit sha" has_text 'commit sha' "$WT_BLOCK"
check "isolation worktree: the block carries the wait limit too (give up after 30 minutes, report what it waited for)" has_text 'give up after 30 minutes and report what you were waiting for' "$WT_BLOCK"
check "no isolation: the block carries the wait limit (give up after 30 minutes, report what it waited for)" has_text 'give up after 30 minutes and report what you were waiting for' "$SHARED_BLOCK"
check "the two variants differ only in rules 5 and 7: the marker and every other rule are the same line for line" \
  test "$(printf '%s\n' "$WT_BLOCK" | grep -v '^[57]\. ')" = "$(printf '%s\n' "$SHARED_BLOCK" | grep -v '^[57]\. ')"

payload "$SANDBOX/remote.json" general-purpose "$P1" '{"isolation":"remote"}'
fire "$SANDBOX/remote.json"
REMOTE_BLOCK="$(block_of "$(newprompt)")"
check "isolation present but not worktree (remote): the block tells the agent NOT to commit" has_text 'Do not commit' "$REMOTE_BLOCK"
check "isolation present but not worktree (remote): the block does not tell the agent to commit early" lacks_text 'commit early' "$REMOTE_BLOCK"

# ── 6. it composes with the brief-adoption gate ───────────────────────────────────────────────
BIGWORDS="$(words 400)"
payload "$SANDBOX/big.json" general-purpose "$BIGWORDS" '{"model":"sonnet"}'
fire "$SANDBOX/big.json"
BIGP="$(newprompt)"
check "oversized prompt: exits 0" test "$RC" = 0
case "$BIGP" in
  "=== DELTA BRIEF"*) ok "oversized prompt: the brief gate still replaces it with a real === DELTA BRIEF" ;;
  *) bad "oversized prompt: the prompt sent on is not a === DELTA BRIEF" ;;
esac
check "oversized prompt: the brief-adoption notice is still announced" grep -q 'brief-adoption notice' "$ERR"
check "oversized prompt: the block rides on the substituted prompt, once" test "$(marker_lines "$BIGP")" = 1
check "oversized prompt: the block comes after the brief's TASK SPEC (appended, not prepended)" marker_after_spec "$BIGP"
check "oversized prompt: model survives the double rewrite" jqt '.hookSpecificOutput.updatedInput | .model == "sonnet" and .subagent_type == "general-purpose"' "$OUT"
check "oversized prompt, no isolation: the block on the substituted brief tells the agent NOT to commit" has_text 'Do not commit' "$(block_of "$BIGP")"
payload "$SANDBOX/bigwt.json" general-purpose "$BIGWORDS" '{"isolation":"worktree"}'
fire "$SANDBOX/bigwt.json"
check "oversized prompt, isolation worktree: the block on the substituted brief tells the agent to commit early (isolation survives the brief rewrite)" \
  has_text 'commit early' "$(block_of "$(newprompt)")"

MIDWORDS="$(words 290)"
payload "$SANDBOX/mid.json" general-purpose "$MIDWORDS"
fire "$SANDBOX/mid.json"
MIDP="$(newprompt)"
case "$MIDP" in
  "=== DELTA BRIEF"*) bad "a 290-word prompt (under the 300-word brief threshold) was replaced by a brief: the block is being counted BEFORE the brief gate decides" ;;
  "word1 "*) ok "a 290-word prompt stays a prompt: the block is added after the brief gate counts words, not before" ;;
  *) bad "a 290-word prompt came back as neither the prompt nor a brief (rc=$RC out=[$(head -c 200 "$OUT")])" ;;
esac
check "a 290-word prompt still gets the block" rewrote
check "a 290-word prompt: no brief-adoption notice" lacks 'brief-adoption notice' "$ERR"
EXTRA_WORDS=$(( $(printf '%s' "$MIDP" | wc -w | tr -d ' ') - 290 ))
check "the block is long enough to push 290 words over the 300 threshold (the ordering assertion above is not vacuous; block is $EXTRA_WORDS words)" test "$EXTRA_WORDS" -gt 10

# ── 7. everything it cannot rewrite, and every failure, leaves the spawn alone ────────────────
payload "$SANDBOX/emptyprompt.json" general-purpose ""
fire "$SANDBOX/emptyprompt.json"
check "an empty prompt is left alone" untouched
jq -cn '{tool_name:"Agent", tool_input:{description:"probe", subagent_type:"general-purpose"}}' >"$SANDBOX/noprompt.json"
fire "$SANDBOX/noprompt.json"
check "no prompt at all is left alone" untouched
jq -cn '{tool_name:"Agent", tool_input:{description:"probe", subagent_type:"general-purpose", prompt:42}}' >"$SANDBOX/numprompt.json"
fire "$SANDBOX/numprompt.json"
check "a prompt that is not a string is left alone" untouched
printf '%s' '{"tool_name":"Agent","tool_input":{"description":"truncated' >"$SANDBOX/malformed.json"
fire "$SANDBOX/malformed.json"
check "a malformed payload is left alone (exit 0, nothing on stdout)" untouched
: >"$SANDBOX/empty.json"
fire "$SANDBOX/empty.json"
check "an empty payload is left alone (exit 0, nothing on stdout)" untouched

# A jq that fails exactly on the rewrite (the one call that carries the marker as an argument) and is the real jq for every other call.
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do\n'
  printf '  case "$a" in *"hmd agent rules"*) echo hit >> "%s/hits"; exit 5 ;; esac\n' "$SANDBOX/fakebin"
  printf 'done\n'
  printf 'exec "%s" "$@"\n' "$REAL_JQ"
} >"$SANDBOX/fakebin/jq"
chmod +x "$SANDBOX/fakebin/jq"
fire "$SANDBOX/gp.json" "PATH=$SANDBOX/fakebin:$PATH"
check "a jq that fails on the rewrite: the spawn goes through untouched (exit 0, nothing on stdout)" untouched
check "the injected jq failure was actually reached (not a vacuous pass)" test -s "$SANDBOX/fakebin/hits"

# ── 8. wiring: the shipped hooks.json Agent command delivers the rewrite ──────────────────────
GATE="$SANDBOX/gate.sh"
jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | .[0].hooks[0].command // empty' "$HOOKS_JSON" >"$GATE"
check "hooks.json wires the Agent hook to bin/heimdall-precheck-agent" grep -q 'heimdall-precheck-agent' "$GATE"
: >"$OUT"; : >"$ERR"
( cd "$SANDBOX/cwd" && env -i "HOME=$SANDBOX/home" "HEIMDALL_HOME=$SANDBOX/home/.heimdall" "HEIMDALL_PLANNING_DIR=$SANDBOX/planning" "PATH=$PATH" \
    "HMD_MIN_FREE_PCT=0" "HMD_CTX_GATE_OFF=1" "CLAUDE_PLUGIN_ROOT=$REPO" sh "$GATE" <"$SANDBOX/gp.json" >"$OUT" 2>"$ERR" )
RC=$?
check "the shipped hooks.json Agent command rewrites a general-purpose spawn" rewrote

# ── 9. the assertions bite: six mutants of the hook each go wrong ────────────────────────────
# Each mutant is a lone copy of the hook (no sibling libs or binaries, so every other fence is inert and only the section under test runs).
mutant() { # mutant <name> <sed expression>   writes $SANDBOX/mut/<name>; false when the expression changed nothing
  sed "$2" "$REAL_HOOK" >"$SANDBOX/mut/$1"
  chmod +x "$SANDBOX/mut/$1"
  if cmp -s "$REAL_HOOK" "$SANDBOX/mut/$1"; then bad "mutant $1 is identical to the hook — its sed expression matched nothing, so the proof below would be vacuous"; return 1; fi
}
if mutant ignores-optout 's/HMD_GP_RULES_OFF/HMD_GP_RULES_OFF_IGNORED/g'; then
  fire_hook "$SANDBOX/mut/ignores-optout" "$SANDBOX/gp.json" HMD_GP_RULES_OFF=1
  check "RED-PROOF: a hook that ignores HMD_GP_RULES_OFF still rewrites an opted-out spawn (so the opt-out assertion above bites)" rewrote
fi
if mutant not-idempotent 's/((\.prompt | contains(\$m)) | not)/true/'; then
  fire_hook "$SANDBOX/mut/not-idempotent" "$SANDBOX/again.json"
  check "RED-PROOF: a hook with no idempotence check doubles the block on an already-marked prompt (so the idempotence assertion above bites)" \
    test "$(marker_lines "$(newprompt)")" = 2
fi
if mutant every-type "s/general-purpose|'')/*)/"; then
  payload "$SANDBOX/coder.json" hmd:coder "$P1"
  fire_hook "$SANDBOX/mut/every-type" "$SANDBOX/coder.json"
  check "RED-PROOF: a hook that matches every subagent_type rewrites hmd:coder (so the untouched assertions above bite)" rewrote
fi
if mutant ignores-isolation 's/\.isolation == "worktree"/true/'; then
  fire_hook "$SANDBOX/mut/ignores-isolation" "$SANDBOX/gp.json"
  check "RED-PROOF: a hook that treats every spawn as isolated tells a no-isolation spawn to commit early (so the no-isolation assertions above bite)" \
    has_text 'commit early' "$(block_of "$(newprompt)")"
fi
if mutant never-isolated 's/\.isolation == "worktree"/false/'; then
  fire_hook "$SANDBOX/mut/never-isolated" "$SANDBOX/wt.json"
  check "RED-PROOF: a hook that never recognises isolation worktree tells that spawn NOT to commit (so the isolation worktree assertions above bite)" \
    has_text 'Do not commit' "$(block_of "$(newprompt)")"
fi
if mutant no-wait-limit 's/give up after 30 minutes/wait as long as it takes/'; then
  fire_hook "$SANDBOX/mut/no-wait-limit" "$SANDBOX/gp.json"
  check "RED-PROOF: a hook whose rule 4 drops the 30-minute limit sends a block without it (so the wait-limit assertions above bite)" \
    lacks_text '30 minutes' "$(block_of "$(newprompt)")"
fi

echo "--------------------------------------------------------------------"
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
