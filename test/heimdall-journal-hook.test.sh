#!/usr/bin/env bash
# test/heimdall-journal-hook.test.sh
#
# Proves bin/heimdall-journal-hook + its hooks.json PostToolUse:Bash wiring
# make heimdall-journal write itself on a real `git commit`, mechanically,
# with zero agent action required — the owner's own standing verdict quoted
# in hooks/hooks.json's SubagentStop rationale applies here too: "by nature,
# hmd should use these skills on autopilot and not by an external invocation".
#
# Guarantees under test:
#   1. hooks.json carries a PostToolUse:Bash entry invoking heimdall-journal-hook.
#   2. No "matcher" typo — must be exactly "Bash".
#   3. The extracted command is syntactically valid bash (bash -n).
#   4. A real `git commit` -> a real new .planning/journal/*.md entry appears.
#   5. The entry's subject/evidence match the commit's subject/SHA.
#   6. Empty commit body falls back to using the subject as the body.
#   7. A non-empty commit body is preserved verbatim (not overwritten by the
#      subject fallback).
#   8. Re-running the hook with NO new commit (HEAD unchanged) does NOT
#      duplicate the entry (dedup via git config).
#   9. A non-commit Bash command (e.g. `ls`) never touches the journal.
#  10. Fail-open: malformed JSON on stdin, empty stdin, missing
#      heimdall-journal binary, and a non-git target dir all exit 0 with no
#      journal write and no crash.
#  11. Collateral: every other hooks.json event key is still present and
#      non-empty (this edit must not disturb unrelated hooks).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s (expected %s, got %s)\n' "$1" "$2" "$3"; }

command -v jq >/dev/null 2>&1 || { echo "heimdall-journal-hook: jq required, skipping"; exit 0; }

# --- 1/2/3: hooks.json shape -------------------------------------------
ENTRY_JSON="$(jq -c '.hooks.PostToolUse[]? | select(any(.hooks[]?; .command | contains("heimdall-journal-hook")))' "$HOOKS_JSON" 2>/dev/null)"
if [ -z "$ENTRY_JSON" ]; then
  bad "PostToolUse entry invoking heimdall-journal-hook exists" "found" "not found"
  printf 'heimdall-journal-hook: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
ok "PostToolUse entry invoking heimdall-journal-hook exists"

MATCHER="$(printf '%s' "$ENTRY_JSON" | jq -r '.matcher // empty')"
[ "$MATCHER" = "Bash" ] && ok "matcher is exactly Bash" || bad "matcher is exactly Bash" "Bash" "$MATCHER"

HOOK_CMD_FILE="$(mktemp)"
printf '%s' "$ENTRY_JSON" | jq -r '.hooks[0].command' > "$HOOK_CMD_FILE"
if bash -n "$HOOK_CMD_FILE" 2>/tmp/journal-hook-syntax.err; then
  ok "extracted PostToolUse command is syntactically valid bash"
else
  bad "extracted PostToolUse command is syntactically valid bash" "valid" "$(cat /tmp/journal-hook-syntax.err)"
fi

# --- sandbox -------------------------------------------------------------
SANDBOX="$(mktemp -d)"
PLUGIN="$SANDBOX/plugin"
PROJECT="$SANDBOX/project"
mkdir -p "$PLUGIN/bin" "$PROJECT"

cp "$REPO_ROOT/bin/heimdall-journal-hook" "$PLUGIN/bin/heimdall-journal-hook"
cp "$REPO_ROOT/bin/heimdall-journal" "$PLUGIN/bin/heimdall-journal"
chmod +x "$PLUGIN/bin/heimdall-journal-hook" "$PLUGIN/bin/heimdall-journal"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "sandbox@test.local"
git -C "$PROJECT" config user.name "Sandbox"
echo "seed" > "$PROJECT/seed.txt"
git -C "$PROJECT" add seed.txt
git -C "$PROJECT" commit -q -m "chore: seed"
# heimdall-journal add's OWN documented behavior is to auto-commit the entry
# file it just wrote (see bin/heimdall-journal's header + cmd_add). Left on,
# that would advance HEAD as a side effect of every run_hook() call below,
# confounding the dedup assertion (which needs HEAD to stay put between two
# calls with no new *agent* commit in between) with a real but orthogonal
# behavior of the tool being wrapped, not this hook's own logic. Opting out
# via the documented flag isolates the one thing this suite is testing.
touch "$PROJECT/.heimdall-no-autocommit"

TMPDIR_SAVE="$TMPDIR"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export HEIMDALL_HAID="testwriter"

run_hook() { # <bash-command-string>
  local payload
  payload="$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  printf '%s' "$payload" | bash "$HOOK_CMD_FILE"
}

journal_dir="$PROJECT/.planning/journal"
entry_count() { [ -d "$journal_dir" ] && grep -rc '^## ' "$journal_dir"/*.md 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || echo 0; }

# --- 9: non-commit command never touches the journal ----------------------
run_hook "ls -la" >/dev/null 2>&1
N0="$(entry_count)"
[ "$N0" -eq 0 ] && ok "non-commit Bash command writes nothing" || bad "non-commit Bash command writes nothing" 0 "$N0"

# --- 4/5/6: real commit with EMPTY body -> journal entry, body=subject fallback
git -C "$PROJECT" commit -q --allow-empty -m "feat: empty-body commit"
SHA1="$(git -C "$PROJECT" rev-parse HEAD)"
run_hook "git commit -m 'feat: empty-body commit'" >/dev/null 2>&1
N1="$(entry_count)"
[ "$N1" -eq 1 ] && ok "real commit produces exactly one journal entry" || bad "real commit produces exactly one journal entry" 1 "$N1"

CONTENT="$(cat "$journal_dir"/*.md 2>/dev/null)"
printf '%s' "$CONTENT" | grep -q "feat: empty-body commit" && ok "entry contains commit subject" || bad "entry contains commit subject" "present" "absent"
printf '%s' "$CONTENT" | grep -q "commit $SHA1" && ok "entry evidence names the commit SHA" || bad "entry evidence names the commit SHA" "present" "absent"

# --- 8: dedup - same HEAD, run again -> no duplicate ----------------------
run_hook "git commit -m 'feat: empty-body commit'" >/dev/null 2>&1
N2="$(entry_count)"
[ "$N2" -eq 1 ] && ok "re-running hook at same HEAD does not duplicate the entry" || bad "re-running hook at same HEAD does not duplicate the entry" 1 "$N2"

# --- 7: NEW commit with a real, distinct body ------------------------------
echo "more" > "$PROJECT/more.txt"
git -C "$PROJECT" add more.txt
git -C "$PROJECT" commit -q -m "fix: distinct body commit" -m "This is the real body text, not the subject."
SHA2="$(git -C "$PROJECT" rev-parse HEAD)"
run_hook "git commit -m 'fix: distinct body commit' -m 'This is the real body text, not the subject.'" >/dev/null 2>&1
N3="$(entry_count)"
[ "$N3" -eq 2 ] && ok "second distinct commit adds exactly one more entry" || bad "second distinct commit adds exactly one more entry" 2 "$N3"
CONTENT2="$(cat "$journal_dir"/*.md 2>/dev/null)"
printf '%s' "$CONTENT2" | grep -q "This is the real body text, not the subject." && ok "non-empty commit body preserved verbatim" || bad "non-empty commit body preserved verbatim" "present" "absent"
printf '%s' "$CONTENT2" | grep -q "commit $SHA2" && ok "second entry evidence names the second SHA" || bad "second entry evidence names the second SHA" "present" "absent"

# --- 10: fail-open cases ---------------------------------------------------
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
export CLAUDE_PROJECT_DIR="$PROJECT"
printf '%s' '{not valid json' > /tmp/journal-malformed.json
OUT=$(bash "$HOOK_CMD_FILE" < /tmp/journal-malformed.json 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "malformed JSON on stdin exits 0" || bad "malformed JSON on stdin exits 0" 0 "$RC"

OUT=$(printf '' | bash "$HOOK_CMD_FILE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "empty stdin exits 0" || bad "empty stdin exits 0" 0 "$RC"

NOBIN_PLUGIN="$SANDBOX/plugin-nobin"
mkdir -p "$NOBIN_PLUGIN/bin"
cp "$REPO_ROOT/bin/heimdall-journal-hook" "$NOBIN_PLUGIN/bin/heimdall-journal-hook"
chmod +x "$NOBIN_PLUGIN/bin/heimdall-journal-hook"
export CLAUDE_PLUGIN_ROOT="$NOBIN_PLUGIN"
export CLAUDE_PROJECT_DIR="$PROJECT"
PRECOUNT="$(entry_count)"
payload="$(jq -cn --arg c "git commit -m 'should not journal, binary missing'" '{tool_name:"Bash", tool_input:{command:$c}}')"
OUT=$(printf '%s' "$payload" | bash "$HOOK_CMD_FILE" 2>&1); RC=$?
POSTCOUNT="$(entry_count)"
[ "$RC" -eq 0 ] && ok "missing heimdall-journal binary exits 0" || bad "missing heimdall-journal binary exits 0" 0 "$RC"
[ "$POSTCOUNT" -eq "$PRECOUNT" ] && ok "missing heimdall-journal binary writes nothing" || bad "missing heimdall-journal binary writes nothing" "$PRECOUNT" "$POSTCOUNT"

NONGIT="$SANDBOX/notgit"
mkdir -p "$NONGIT"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
export CLAUDE_PROJECT_DIR="$NONGIT"
payload="$(jq -cn --arg c "git commit -m 'target is not a repo'" '{tool_name:"Bash", tool_input:{command:$c}}')"
OUT=$(printf '%s' "$payload" | bash "$HOOK_CMD_FILE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "non-git target dir exits 0" || bad "non-git target dir exits 0" 0 "$RC"

export TMPDIR="$TMPDIR_SAVE"
rm -rf "$SANDBOX" /tmp/journal-hook-syntax.err /tmp/journal-malformed.json

# --- 11: collateral — every other event key still present -----------------
for EVT in UserPromptSubmit PreToolUse PostToolUse SessionStart SubagentStop SessionEnd; do
  N="$(jq ".hooks.$EVT | length" "$HOOKS_JSON" 2>/dev/null || echo 0)"
  if [ "${N:-0}" -gt 0 ]; then
    ok "$EVT still registered ($N entries)"
  else
    bad "$EVT still registered" ">0 entries" "$N"
  fi
done

rm -f "$HOOK_CMD_FILE"

printf 'heimdall-journal-hook: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
