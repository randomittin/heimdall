#!/usr/bin/env bash
#
# stale-work-reclaim.test.sh — two defects that together made hmd accumulate worktrees
# forever while mislabelling what its own checkpoints contained.
#
# WHAT WAS MEASURED, on this repo, before either fix:
#   · `heimdall-reap-idle` reported 21 worktrees and ZERO reapable. Eight were held by
#     19 "commit(s) not on main" — and every feature those commits claimed (the
#     `feat(modules)` reconcile, `feat(agents)` states, the dream toolchain, the Headroom
#     consent waiver) was verified present in main, which had evolved past all of them.
#     They were stale ancestors, not pending work. The reaper judged UNMERGED by commit
#     identity, which rebase, squash-merge and re-implementation all destroy.
#   · Five of those commits were titled `session-end checkpoint (0 files)` and every one
#     of them actually contained one or two files. The SessionEnd hook guarded on
#     `git status --porcelain` (which sees untracked files) but counted with
#     `git diff --name-only` (which does not) BEFORE `git add -A` staged anything. A
#     commit message that understates its own contents is the exact class of claim this
#     repo exists to prevent.
#
# Guarantees proved:
#   1. A branch whose commits differ from main but whose CONTENT is already on main is
#      reported REAP-able, not "unmerged" — the accumulation engine.
#   2. Such a branch is STILL protected when its directory holds uncommitted work. The
#      content rule answers "are the bytes on main"; it says nothing about the directory,
#      so the directory guard has to keep running.
#   3. Such a branch is STILL protected when it holds gitignored agent memory — the guard
#      `git status` cannot see, and the one that actually saved this repo's worktrees.
#   4. A branch carrying genuine content main lacks is STILL kept. The control: without
#      it guarantee 1 could be satisfied by reaping everything.
#   5. A branch that adds a file main also added independently is NOT reaped. The rule is
#      deliberately asymmetric — it reads what the BRANCH changed since the fork point,
#      never what main gained — so this fails conservative rather than clever.
#   6. The SessionEnd checkpoint counts files from the INDEX after staging, so a session
#      whose only change is an untracked file is labelled `(1 files)`, not `(0 files)`.
#   7. hooks.json no longer computes that count with `git diff --name-only` before the
#      add — the specific broken idiom, asserted by absence so it cannot come back.
#
# Usage:  bash test/stale-work-reclaim.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAP="$REPO/bin/heimdall-reap-idle"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stale-reclaim.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

G="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false"

# ── a repo with one worktree per scenario ────────────────────────────────────────────
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX"
(
  cd "$SANDBOX" || exit 1
  $G init -q -b main .
  printf 'base\n' > base.txt
  $G add base.txt && $G commit -qm "init"
) >/dev/null 2>&1

# mk_worktree <name> — a worktree + branch forked from main.
mk_worktree() {
  mkdir -p "$SANDBOX/.claude/worktrees"
  $G -C "$SANDBOX" worktree add -q -b "wt-$1" "$SANDBOX/.claude/worktrees/agent-$1" main >/dev/null 2>&1
}

# reap_line <name> — the reaper's verdict line for one worktree.
reap_line() {
  ( cd "$SANDBOX" && "$REAP" 2>/dev/null ) | grep -F "agent-$1" | head -1
}

# ── scenario A: content-merged, modelled on the real one this fix was written for.
#    agent-a2e5eaa0a00f8a0d3 carried three commits — two docs commits and a
#    `merge: reconcile with main (same docs landed via sweep)`. The branch did work,
#    main landed the same content by another route, and the branch then merged main
#    back in. After that merge the branch's TREE equals main's while its COMMITS remain
#    distinct forever, which is precisely the state ancestry cannot see and this rule
#    can. Note the difference from scenario E below: it is the merge-back that makes
#    the three-dot diff empty, not the fact that main happens to hold the same bytes. ──
mk_worktree contentmerged
(
  cd "$SANDBOX/.claude/worktrees/agent-contentmerged" || exit 1
  printf 'shared feature\n' > feature.txt
  $G add feature.txt && $G commit -qm "feat: the branch's version"
) >/dev/null 2>&1
(
  cd "$SANDBOX" || exit 1
  printf 'shared feature\n' > feature.txt
  $G add feature.txt && $G commit -qm "feat: main's own re-implementation of the same bytes"
) >/dev/null 2>&1
(
  cd "$SANDBOX/.claude/worktrees/agent-contentmerged" || exit 1
  $G merge --no-edit -m "merge: reconcile with main (same bytes landed there)" main
) >/dev/null 2>&1

echo
echo "1 — a branch whose CONTENT is already on main is reapable, not 'unmerged'"
L="$(reap_line contentmerged)"
case "$L" in
  *"[REAP"*) ok "reported REAP: ${L#*— }" ;;
  *"commit(s) not on"*) bad "still reported as unmerged work — the accumulation engine is intact: $L" ;;
  *) bad "unexpected verdict: '$L'" ;;
esac
case "$L" in
  *"content already on"*) ok "the reason says the content is already on main, not merely 'merged'" ;;
  *) bad "the reason does not explain WHY it is safe: '$L'" ;;
esac

# ── scenario B: same content-merge, but the directory holds uncommitted work ──
mk_worktree dirtymerged
(
  cd "$SANDBOX/.claude/worktrees/agent-dirtymerged" || exit 1
  printf 'shared feature\n' > feature.txt
  $G add feature.txt && $G commit -qm "feat: same bytes again"
  printf 'work in progress\n' > wip.txt
) >/dev/null 2>&1

echo
echo "2 — content-merged but DIRTY is still protected"
L="$(reap_line dirtymerged)"
case "$L" in
  *"[KEEP"*PROTECTED*) ok "protected despite the content being on main: ${L#*— }" ;;
  *"[REAP"*) bad "a worktree with uncommitted files was marked reapable: $L" ;;
  *) bad "unexpected verdict: '$L'" ;;
esac

# ── scenario C: same content-merge, but the directory holds gitignored agent memory ──
mk_worktree memmerged
(
  cd "$SANDBOX/.claude/worktrees/agent-memmerged" || exit 1
  printf 'shared feature\n' > feature.txt
  $G add feature.txt && $G commit -qm "feat: same bytes, third time"
  mkdir -p .claude/agent-memory
  printf 'remembered\n' > .claude/agent-memory/note.md
) >/dev/null 2>&1

echo
echo "3 — content-merged but holding agent memory is still protected"
L="$(reap_line memmerged)"
case "$L" in
  *"[KEEP"*PROTECTED*) ok "protected by the gitignored-memory guard: ${L#*— }" ;;
  *"[REAP"*) bad "a worktree holding agent memory was marked reapable: $L" ;;
  *) bad "unexpected verdict: '$L'" ;;
esac

# ── scenario D: genuine unmerged work. The control. ──
mk_worktree realwork
(
  cd "$SANDBOX/.claude/worktrees/agent-realwork" || exit 1
  printf 'only here\n' > exclusive.txt
  $G add exclusive.txt && $G commit -qm "feat: content main has never seen"
) >/dev/null 2>&1

echo
echo "4 — genuine unmerged content is still KEPT (control)"
L="$(reap_line realwork)"
case "$L" in
  *"commit(s) not on"*) ok "kept as unmerged work: ${L#*— }" ;;
  *"[REAP"*) bad "REAL WORK WAS MARKED REAPABLE — the content rule is too loose: $L" ;;
  *) bad "unexpected verdict: '$L'" ;;
esac

# ── scenario E: the branch adds a file main ALSO added, with different bytes. The
#    three-dot diff is non-empty (the fork point has neither), so it must be kept. ──
mk_worktree parallel
(
  cd "$SANDBOX/.claude/worktrees/agent-parallel" || exit 1
  printf 'branch flavour\n' > parallel.txt
  $G add parallel.txt && $G commit -qm "feat: branch's parallel.txt"
) >/dev/null 2>&1
(
  cd "$SANDBOX" || exit 1
  printf 'main flavour\n' > parallel.txt
  $G add parallel.txt && $G commit -qm "feat: main's different parallel.txt"
) >/dev/null 2>&1

echo
echo "5 — a branch racing main on the same path is NOT reaped (fails conservative)"
L="$(reap_line parallel)"
case "$L" in
  *"commit(s) not on"*) ok "kept — the rule reads only what the branch changed: ${L#*— }" ;;
  *"[REAP"*) bad "divergent content on a shared path was reaped: $L" ;;
  *) bad "unexpected verdict: '$L'" ;;
esac

# ── the checkpoint count ──────────────────────────────────────────────────────────
echo
echo "6 — the SessionEnd checkpoint counts what it actually commits"
# The exact idiom from hooks.json, driven against a repo whose ONLY change is an
# untracked file — the case the old count could not see.
CK="$TMP/ckrepo"; mkdir -p "$CK"
(
  cd "$CK" || exit 1
  $G init -q -b main .
  printf 'seed\n' > seed.txt
  $G add seed.txt && $G commit -qm init
  printf 'brand new\n' > untracked-only.txt        # untracked: invisible to `git diff`
  $G add -A && count=$($G diff --cached --name-only 2>/dev/null | wc -l | tr -d " ") \
    && $G commit -qm "heimdall: session-end checkpoint (${count} files)" --no-verify
) >/dev/null 2>&1
SUBJ="$($G -C "$CK" log --format=%s -1 2>/dev/null)"
REAL="$($G -C "$CK" show --stat --format='' HEAD 2>/dev/null | grep -cE '^ [a-z]')"
case "$SUBJ" in
  *"(1 files)"*) ok "an untracked-only session is labelled (1 files): $SUBJ" ;;
  *"(0 files)"*) bad "still labelled (0 files) while committing $REAL file(s): $SUBJ" ;;
  *) bad "unexpected subject: '$SUBJ'" ;;
esac
# The old idiom, run against the same tree, to prove the test is not vacuous.
OLD="$( cd "$CK" && $G diff --name-only 2>/dev/null | wc -l | tr -d ' ' )"
[ "$OLD" = "0" ] \
  && ok "the OLD idiom (git diff --name-only) really does report 0 here — the bug is real" \
  || bad "the old idiom reported $OLD, so this scenario does not reproduce the defect"

echo
echo "7 — hooks.json no longer counts before staging"
if grep -q 'count=\$(git diff --name-only 2>/dev/null | wc -l | tr -d \\" \\"); if \[ -x \\"\$PLUGIN/bin/heimdall-git-guard' "$HOOKS"; then
  bad "hooks.json still counts with 'git diff --name-only' before 'git add -A'"
else
  ok "the pre-staging count idiom is gone from hooks.json"
fi
if grep -q 'git add -A && count=\$(git diff --cached --name-only' "$HOOKS"; then
  ok "hooks.json counts from the index after staging"
else
  bad "hooks.json does not count from the index after staging"
fi
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOOKS" 2>/dev/null \
  && ok "hooks.json is still valid JSON" \
  || bad "hooks.json is not valid JSON"

echo
echo "--------------------------------------------------------------------"
printf 'stale-work-reclaim: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
