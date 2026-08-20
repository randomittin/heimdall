#!/usr/bin/env bash
# test/git-guard-routing.test.sh — bin/heimdall-git-guard must actually RUN before the
# git writes Heimdall issues on the user's behalf.
#
# WHY THIS EXISTS. The guard was built, tested 4/0, and wired to NOTHING: `grep -rl
# git-guard bin/ hooks/ sentinels/` matched only the file itself. Meanwhile the failure
# it heals is real and was hit in this repo: a git process killed mid-write leaves a
# 0-byte `.git/index.lock`, and every later git write dies with
#     fatal: Unable to create '<repo>/.git/index.lock': File exists.
# (measured: `git add -A` → rc 128, `git commit` → rc 128).
#
# In the autocommit hooks that failure is SWALLOWED (`2>/dev/null || true`), so the user
# loses every auto-checkpoint from the moment the lock appears until they clear it by
# hand — silently. Routing the guard in front of those writes is the self-heal.
#
# WHAT IS PINNED — the shipped artifact, not a copy. Every behavioural case extracts the
# REAL command string out of hooks/hooks.json with jq and executes it in a throwaway repo.
# A hook body that stops calling the guard fails here even if the grep still matches.
#
# BOTH DIRECTIONS. Clearing an ownerless lock is only half the contract; the other half is
# NEVER clearing one a live git op owns. §3 forces the guard's ownership probe to report
# "a git process is alive" and asserts the lock SURVIVES — so a future "fix" that makes the
# routing more aggressive fails here.
#
# NO REAL-REPO MUTATION: every git write below targets a mktemp repo. Nothing in this file
# runs git against the heimdall worktree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOKS_JSON="$ROOT/hooks/hooks.json"
GUARD="$ROOT/bin/heimdall-git-guard"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
[ -f "$HOOKS_JSON" ] || { echo "FATAL: $HOOKS_JSON missing"; exit 2; }
[ -x "$GUARD" ]      || { echo "FATAL: $GUARD not executable"; exit 2; }

# ── hook-body extractors (the shipped strings, straight out of hooks.json) ─────
post_autocommit_body() {
  jq -r '.hooks.PostToolUse[]
         | select(.matcher=="Write|Edit|MultiEdit|NotebookEdit")
         | .hooks[0].command' "$HOOKS_JSON"
}
session_end_body() {
  jq -r '.hooks.SessionEnd[]
         | select(.hooks[0].command | contains("session-end checkpoint"))
         | .hooks[0].command' "$HOOKS_JSON"
}
pre_bash_body() {
  jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$HOOKS_JSON"
}

# routes_to_guard BODY — true if BODY calls the guard directly, or delegates to
# bin/heimdall-autocommit, which now runs the guard itself before any staging or
# commit (the scoped-staging refactor, commit 386966f, centralized staging+guard+
# commit there instead of inlining `git add -A && git commit` per hook). A literal
# grep on BODY alone went stale the moment that delegation landed even though the
# guard still fires every time — proven by the behavioural sections below, which
# execute the real body and watch a stale lock get cleared. This resolves the one
# hop of indirection the naive grep couldn't see.
routes_to_guard() {
  local body="$1"
  printf '%s\n' "$body" | grep -q 'heimdall-git-guard' && return 0
  printf '%s\n' "$body" | grep -q 'heimdall-autocommit' \
    && grep -q 'heimdall-git-guard' "$ROOT/bin/heimdall-autocommit" 2>/dev/null
}

# mkrepo — a throwaway git repo with 6 tracked files, all dirty (so the autocommit
# hook's `count >= 5` threshold is met). Echoes the repo path.
mkrepo() {
  local w; w="$(mktemp -d "${TMPDIR:-/tmp}/hmd-guard-route-XXXXXX")"
  git -C "$w" init -q
  git -C "$w" config user.email guard@test.local
  git -C "$w" config user.name  guard-test
  local i
  for i in 1 2 3 4 5 6; do printf 'a\n' > "$w/f$i"; done
  git -C "$w" add -A >/dev/null 2>&1
  git -C "$w" commit -qm init >/dev/null 2>&1
  for i in 1 2 3 4 5 6; do printf 'b\n' > "$w/f$i"; done
  printf '%s' "$w"
}
commits_in()  { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
has_lock()    { [ -f "$1/.git/index.lock" ]; }

# run_hook BODY REPO [PGREP_OVERRIDE] — execute a hook body under /bin/sh with the repo
# as CWD, exactly as Claude Code would. CLAUDE_PLUGIN_ROOT is pinned to the heimdall
# checkout so $PLUGIN/bin/... resolves while git writes land in the throwaway repo.
run_hook() {
  local body="$1" repo="$2" pg="${3:-}"
  ( cd "$repo" || exit 1
    CLAUDE_PLUGIN_ROOT="$ROOT" \
    CLAUDE_PROJECT_DIR="$repo" \
    HMD_GIT_GUARD_PGREP="$pg" \
    sh -c "$body" ) >/dev/null 2>&1
  return 0
}

HOOK_STDIN='{"tool_name":"Write","tool_input":{"file_path":"f1","content":"b"},"session_id":"guard-route-test"}'

# ══════════════════════════════════════════════════════════════════════════════
# 1. ROUTING — the guard is referenced from every hmd-driven git-write path.
#    A built-and-unreachable tool is the exact defect this file exists to stop.
# ══════════════════════════════════════════════════════════════════════════════
if routes_to_guard "$(post_autocommit_body)"; then
  ok "PostToolUse auto-checkpoint hook references heimdall-git-guard"
else
  bad "PostToolUse auto-checkpoint hook does NOT reference heimdall-git-guard"
fi

if routes_to_guard "$(session_end_body)"; then
  ok "SessionEnd checkpoint hook references heimdall-git-guard"
else
  bad "SessionEnd checkpoint hook does NOT reference heimdall-git-guard"
fi

if routes_to_guard "$(pre_bash_body)"; then
  ok "PreToolUse Bash hook references heimdall-git-guard (agent-issued git writes)"
else
  bad "PreToolUse Bash hook does NOT reference heimdall-git-guard"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. BEHAVIOUR — a PROVEN-STALE lock is healed and the auto-checkpoint lands.
#    Without the routing: `git add -A` exits 128, `|| true` eats it, 0 new commits.
# ══════════════════════════════════════════════════════════════════════════════
REPO="$(mkrepo)"
: > "$REPO/.git/index.lock"
BEFORE="$(commits_in "$REPO")"
printf '%s' "$HOOK_STDIN" > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  sh -c "$(post_autocommit_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
AFTER="$(commits_in "$REPO")"

if ! has_lock "$REPO"; then
  ok "stale index.lock cleared by the routed guard (auto-checkpoint path)"
else
  bad "stale index.lock SURVIVED the auto-checkpoint hook — guard not routed"
fi
if [ "$AFTER" -gt "$BEFORE" ]; then
  ok "auto-checkpoint commit lands despite a stale lock ($BEFORE → $AFTER)"
else
  bad "auto-checkpoint silently lost: commits $BEFORE → $AFTER with a stale lock present"
fi
rm -rf "$REPO"

# ══════════════════════════════════════════════════════════════════════════════
# 3. CONSERVATISM — a lock a LIVE git op owns is NEVER cleared by the routing.
#    HMD_GIT_GUARD_PGREP=true forces the ownership probe to report "git is alive";
#    the guard must exhaust its wait budget and leave the lock intact. Making the
#    routing more aggressive than the guard's own contract fails right here.
# ══════════════════════════════════════════════════════════════════════════════
REPO="$(mkrepo)"
: > "$REPO/.git/index.lock"
BEFORE="$(commits_in "$REPO")"
printf '%s' "$HOOK_STDIN" > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  HMD_GIT_GUARD_PGREP="true" sh -c "$(post_autocommit_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
AFTER="$(commits_in "$REPO")"

if has_lock "$REPO"; then
  ok "lock held by a LIVE git op is preserved (routing is not more aggressive)"
else
  bad "routing cleared a lock while a git process was alive — UNSAFE"
fi
if [ "$AFTER" -eq "$BEFORE" ]; then
  ok "no commit forced past a live-owned lock (fails safe, stays silent-free)"
else
  bad "hook committed while another git op held the index lock"
fi
rm -rf "$REPO"

# ══════════════════════════════════════════════════════════════════════════════
# 4. NO REGRESSION — with no lock at all the hook behaves exactly as before.
#    Falsifier for a guard that somehow blocks or slows the normal path.
# ══════════════════════════════════════════════════════════════════════════════
REPO="$(mkrepo)"
BEFORE="$(commits_in "$REPO")"
printf '%s' "$HOOK_STDIN" > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  sh -c "$(post_autocommit_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
AFTER="$(commits_in "$REPO")"
if [ "$AFTER" -gt "$BEFORE" ]; then
  ok "clean repo (no lock) still auto-checkpoints — guard is a no-op there"
else
  bad "guard broke the normal auto-checkpoint path (no lock present)"
fi
if ! has_lock "$REPO"; then
  ok "no stray index.lock left behind on the clean path"
else
  bad "hook left an index.lock behind on the clean path"
fi
rm -rf "$REPO"

# ══════════════════════════════════════════════════════════════════════════════
# 5. AGENT-ISSUED git writes — `hmd` users drive git through the Bash tool, so the
#    PreToolUse Bash hook is the hot path. A `git commit` command must get the same
#    self-heal BEFORE the command runs. (Exit code is not asserted: the same hook
#    also runs the secret gate, whose verdict is not this test's subject.)
# ══════════════════════════════════════════════════════════════════════════════
REPO="$(mkrepo)"
: > "$REPO/.git/index.lock"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git add -A && git commit -m wip"}}' > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  sh -c "$(pre_bash_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
if ! has_lock "$REPO"; then
  ok "PreToolUse Bash clears a stale lock ahead of an agent-issued git write"
else
  bad "PreToolUse Bash left a stale lock in place — the agent's git write will die"
fi
rm -rf "$REPO"

# 5b. …and the same path must NOT clear a live-owned lock either.
REPO="$(mkrepo)"
: > "$REPO/.git/index.lock"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}' > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  HMD_GIT_GUARD_PGREP="true" sh -c "$(pre_bash_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
if has_lock "$REPO"; then
  ok "PreToolUse Bash preserves a live-owned lock (conservative both sides)"
else
  bad "PreToolUse Bash cleared a live-owned lock — UNSAFE"
fi
rm -rf "$REPO"

# 5c. FALSIFIER — a NON-git Bash command must not be treated as a git write. The
#     guard is harmless, but a routing that fires on everything is a routing that
#     was never actually scoped; pin the scoping so it cannot rot into a catch-all.
REPO="$(mkrepo)"
: > "$REPO/.git/index.lock"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' > "$REPO/.stdin"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" \
  sh -c "$(pre_bash_body)" < "$REPO/.stdin" ) >/dev/null 2>&1
if has_lock "$REPO"; then
  ok "non-git Bash command does NOT trigger the guard (routing is scoped)"
else
  bad "guard fired on a non-git command — routing is an unscoped catch-all"
fi
rm -rf "$REPO"

# ══════════════════════════════════════════════════════════════════════════════
# 6. THE GUARD'S OWN CONTRACT still holds after routing: it can never block a
#    caller. Exit 0 on every branch — no lock, stale lock, live-owned lock.
# ══════════════════════════════════════════════════════════════════════════════
REPO="$(mkrepo)"
"$GUARD" "$REPO" >/dev/null 2>&1; rc_nolock=$?
: > "$REPO/.git/index.lock"
HMD_GIT_GUARD_PGREP="false" "$GUARD" "$REPO" >/dev/null 2>&1; rc_stale=$?
: > "$REPO/.git/index.lock"
HMD_GIT_GUARD_PGREP="true"  "$GUARD" "$REPO" >/dev/null 2>&1; rc_live=$?
if [ "$rc_nolock" -eq 0 ] && [ "$rc_stale" -eq 0 ] && [ "$rc_live" -eq 0 ]; then
  ok "guard always exits 0 (no-lock=$rc_nolock stale=$rc_stale live=$rc_live) — never blocks a caller"
else
  bad "guard returned nonzero (no-lock=$rc_nolock stale=$rc_stale live=$rc_live) — it can now block git"
fi
rm -rf "$REPO"

# ══════════════════════════════════════════════════════════════════════════════
# 7. hooks.json stays valid JSON after the routing edits.
# ══════════════════════════════════════════════════════════════════════════════
if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks/hooks.json is valid JSON"
else
  bad "hooks/hooks.json is not valid JSON"
fi

printf "\n  git-guard-routing: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
