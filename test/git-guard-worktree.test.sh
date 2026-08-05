#!/usr/bin/env bash
# test/git-guard-worktree.test.sh — the git self-heal must work where Heimdall's own
# agents actually live: inside a LINKED GIT WORKTREE.
#
# THE DEFECT, in two layers, both measured (git 2.53.0, macOS):
#
#   LAYER 1 — the hook gate.  hooks.json gated the auto-checkpoint on `[ -d .git ]`.
#     In a linked worktree `.git` is a FILE (103 bytes: "gitdir: …"), not a directory,
#     so that test is FALSE and the whole auto-checkpoint branch — including the
#     heimdall-git-guard call routed into it — never executed. Heimdall spawns
#     hmd:coder and hmd:wave-executor with `isolation: worktree`, so the safety net
#     was off for exactly the population that runs the most git writes.
#
#   LAYER 2 — the guard's own path.  The guard looked for "$repo/.git/index.lock".
#     A worktree's index lock is NOT there; it lives in the per-worktree git dir,
#     <common>/.git/worktrees/<name>/index.lock. Measured: `git add` in a locked
#     worktree fails naming that path, while <worktree>/.git/index.lock does not
#     exist at all. So even once reached, the guard was looking at the wrong file
#     and silently found nothing to heal.
#
# Fixing layer 1 without layer 2 (or vice versa) still leaves a worktree unhealed,
# so both are pinned here, plus the normal-repo case to prove nothing regressed.
#
# `git rev-parse --absolute-git-dir` (git >= 2.13) is the resolver for both shapes:
# it returns <repo>/.git in a normal checkout and the per-worktree dir in a worktree.
#
# NO REAL-REPO MUTATION: every git write below targets a mktemp repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/bin/heimdall-git-guard"
HOOKS_JSON="$ROOT/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$GUARD" ] || { echo "FATAL: $GUARD not executable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hmd-guard-wt-XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# mkpair N — a main repo plus a linked worktree, both with 6 tracked files that are
# dirty in the worktree (so the hook's `count >= 5` threshold is met there).
# Echoes "<main> <worktree>".
mkpair() {
  local base="$SCRATCH/pair$1" main wt i
  main="$base/main"; wt="$base/wt"
  mkdir -p "$base"
  git -C "$base" init -q main
  git -C "$main" config user.email guard@test.local
  git -C "$main" config user.name  guard-test
  for i in 1 2 3 4 5 6; do printf 'a\n' > "$main/f$i"; done
  git -C "$main" add -A >/dev/null 2>&1
  git -C "$main" commit -qm init >/dev/null 2>&1
  git -C "$main" worktree add -q --detach "$wt" HEAD >/dev/null 2>&1
  for i in 1 2 3 4 5 6; do printf 'b\n' > "$wt/f$i"; done
  printf '%s %s' "$main" "$wt"
}

wt_gitdir()  { git -C "$1" rev-parse --absolute-git-dir 2>/dev/null; }
commits_in() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }

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

HOOK_STDIN='{"tool_name":"Write","tool_input":{"file_path":"f1","content":"b"},"session_id":"wt-test"}'

# ══════════════════════════════════════════════════════════════════════════════
# 0. PLATFORM FACTS — the premises this whole file rests on. If git ever changes
#    them, these fail first and say so, instead of the tests below going mystery-red.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN0 WT0 <<<"$(mkpair 0)"
if [ -f "$WT0/.git" ] && [ ! -d "$WT0/.git" ]; then
  ok "platform: a linked worktree's .git is a FILE, so [ -d .git ] is false there"
else
  bad "platform: expected <worktree>/.git to be a file; the premise has changed"
fi
GD0="$(wt_gitdir "$WT0")"
case "$GD0" in
  */worktrees/*) ok "platform: --absolute-git-dir resolves a worktree to its per-worktree git dir" ;;
  *) bad "platform: --absolute-git-dir returned '$GD0' (expected a .../worktrees/... path)" ;;
esac
# Compare through a resolved path: on macOS $TMPDIR is /var/... while git reports the
# /private/var/... realpath, so a raw string compare fails for the wrong reason.
MAIN0_REAL="$(cd "$MAIN0" && pwd -P)"
if [ "$(git -C "$MAIN0" rev-parse --absolute-git-dir)" = "$MAIN0_REAL/.git" ]; then
  ok "platform: --absolute-git-dir resolves a normal repo to <repo>/.git (unchanged shape)"
else
  bad "platform: --absolute-git-dir misresolved a normal repo"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1. LAYER 2 — the guard finds and clears a worktree's REAL stale index.lock.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN1 WT1 <<<"$(mkpair 1)"
GD1="$(wt_gitdir "$WT1")"
: > "$GD1/index.lock"
HMD_GIT_GUARD_PGREP="false" "$GUARD" "$WT1" >/dev/null 2>&1
if [ ! -f "$GD1/index.lock" ]; then
  ok "guard clears a stale lock in a LINKED WORKTREE (resolves the per-worktree git dir)"
else
  bad "guard did NOT clear the worktree's real lock at $GD1/index.lock — it is blind in a worktree"
fi

# 1b. …and a git write in that worktree now succeeds, which is the point.
: > "$GD1/index.lock"
HMD_GIT_GUARD_PGREP="false" "$GUARD" "$WT1" >/dev/null 2>&1
if git -C "$WT1" add -A >/dev/null 2>&1; then
  ok "git add succeeds in the worktree after the guard ran"
else
  bad "git add still fails in the worktree after the guard ran"
fi

# 1c. CONSERVATISM in a worktree: a live-owned lock is still never cleared.
read -r MAIN1c WT1c <<<"$(mkpair 1c)"
GD1c="$(wt_gitdir "$WT1c")"
: > "$GD1c/index.lock"
HMD_GIT_GUARD_PGREP="true" "$GUARD" "$WT1c" >/dev/null 2>&1
if [ -f "$GD1c/index.lock" ]; then
  ok "guard preserves a LIVE-owned lock in a worktree (contract unchanged)"
else
  bad "guard cleared a live-owned lock in a worktree — UNSAFE"
fi

# 1d. NO REGRESSION: the normal (non-worktree) repo path still heals.
read -r MAIN1d _WT1d <<<"$(mkpair 1d)"
: > "$MAIN1d/.git/index.lock"
HMD_GIT_GUARD_PGREP="false" "$GUARD" "$MAIN1d" >/dev/null 2>&1
if [ ! -f "$MAIN1d/.git/index.lock" ]; then
  ok "guard still clears a stale lock in a NORMAL repo (no regression)"
else
  bad "guard stopped healing the normal-repo case"
fi

# 1e. The guard never blocks a caller, in either repo shape.
read -r _M1e WT1e <<<"$(mkpair 1e)"
"$GUARD" "$WT1e" >/dev/null 2>&1; rc_wt=$?
if [ "$rc_wt" -eq 0 ]; then
  ok "guard exits 0 in a worktree with no lock (rc=$rc_wt)"
else
  bad "guard exited $rc_wt in a worktree — it can now block git"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. LAYER 1 — the shipped auto-checkpoint hook actually RUNS inside a worktree.
#    Executes the real hooks.json body with the worktree as CWD.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN2 WT2 <<<"$(mkpair 2)"
BEFORE="$(commits_in "$WT2")"
printf '%s' "$HOOK_STDIN" > "$SCRATCH/stdin2"
( cd "$WT2" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WT2" \
  sh -c "$(post_autocommit_body)" < "$SCRATCH/stdin2" ) >/dev/null 2>&1
AFTER="$(commits_in "$WT2")"
if [ "$AFTER" -gt "$BEFORE" ]; then
  ok "auto-checkpoint fires inside a worktree ($BEFORE → $AFTER)"
else
  bad "auto-checkpoint SILENTLY SKIPPED in a worktree (commits $BEFORE → $AFTER) — [ -d .git ] is false there"
fi

# 2b. …and the guard reached through it heals a worktree lock end to end.
read -r MAIN2b WT2b <<<"$(mkpair 2b)"
GD2b="$(wt_gitdir "$WT2b")"
: > "$GD2b/index.lock"
BEFORE="$(commits_in "$WT2b")"
printf '%s' "$HOOK_STDIN" > "$SCRATCH/stdin2b"
( cd "$WT2b" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WT2b" \
  sh -c "$(post_autocommit_body)" < "$SCRATCH/stdin2b" ) >/dev/null 2>&1
AFTER="$(commits_in "$WT2b")"
if [ ! -f "$GD2b/index.lock" ] && [ "$AFTER" -gt "$BEFORE" ]; then
  ok "END TO END: stale lock in a worktree healed and the checkpoint landed ($BEFORE → $AFTER)"
else
  bad "worktree end-to-end failed: lock present=$([ -f "$GD2b/index.lock" ] && echo yes || echo no), commits $BEFORE → $AFTER"
fi

# 2c. SessionEnd checkpoint fires in a worktree too.
read -r MAIN2c WT2c <<<"$(mkpair 2c)"
BEFORE="$(commits_in "$WT2c")"
( cd "$WT2c" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WT2c" \
  HEIMDALL_HOME="$SCRATCH/home2c" sh -c "$(session_end_body)" </dev/null ) >/dev/null 2>&1
AFTER="$(commits_in "$WT2c")"
if [ "$AFTER" -gt "$BEFORE" ]; then
  ok "session-end checkpoint fires inside a worktree ($BEFORE → $AFTER)"
else
  bad "session-end checkpoint SILENTLY SKIPPED in a worktree (commits $BEFORE → $AFTER)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. FALSIFIERS — the gate must still GATE. A repo test that says "yes" to
#    everything is not a fix, it is a different bug.
# ══════════════════════════════════════════════════════════════════════════════
# 3a. A directory that is NOT a git repo at all must not be committed into.
NOTREPO="$SCRATCH/notrepo"
mkdir -p "$NOTREPO"
for i in 1 2 3 4 5 6; do printf 'x\n' > "$NOTREPO/f$i"; done
printf '%s' "$HOOK_STDIN" > "$SCRATCH/stdin3a"
( cd "$NOTREPO" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$NOTREPO" \
  sh -c "$(post_autocommit_body)" < "$SCRATCH/stdin3a" ) >/dev/null 2>&1
if [ ! -e "$NOTREPO/.git" ]; then
  ok "falsifier: a non-git directory is never turned into a repo by the hook"
else
  bad "falsifier: the hook created a git repo in a plain directory"
fi

# 3b. .heimdall-no-autocommit still opts out — inside a worktree.
read -r MAIN3b WT3b <<<"$(mkpair 3b)"
touch "$WT3b/.heimdall-no-autocommit"
BEFORE="$(commits_in "$WT3b")"
printf '%s' "$HOOK_STDIN" > "$SCRATCH/stdin3b"
( cd "$WT3b" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WT3b" \
  sh -c "$(post_autocommit_body)" < "$SCRATCH/stdin3b" ) >/dev/null 2>&1
AFTER="$(commits_in "$WT3b")"
if [ "$AFTER" -eq "$BEFORE" ]; then
  ok "falsifier: .heimdall-no-autocommit still suppresses the checkpoint in a worktree"
else
  bad "falsifier: opt-out ignored in a worktree — committed anyway ($BEFORE → $AFTER)"
fi

# 3c. Under the threshold (fewer than 5 dirty files) nothing is committed.
read -r MAIN3c WT3c <<<"$(mkpair 3c)"
git -C "$WT3c" checkout -- . >/dev/null 2>&1
printf 'b\n' > "$WT3c/f1"
BEFORE="$(commits_in "$WT3c")"
printf '%s' "$HOOK_STDIN" > "$SCRATCH/stdin3c"
( cd "$WT3c" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WT3c" \
  sh -c "$(post_autocommit_body)" < "$SCRATCH/stdin3c" ) >/dev/null 2>&1
AFTER="$(commits_in "$WT3c")"
if [ "$AFTER" -eq "$BEFORE" ]; then
  ok "falsifier: below the 5-file threshold the worktree is not committed ($BEFORE → $AFTER)"
else
  bad "falsifier: hook committed below its own threshold ($BEFORE → $AFTER)"
fi

printf "\n  git-guard-worktree: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
