#!/usr/bin/env bash
# test/heimdall-reap-idle.test.sh — falsifiable acceptance for bin/heimdall-reap-idle.
#
# The reaper's ONE dangerous power is destroying git worktrees + branches. The
# whole point of the tool is to reap MERGED/abandoned agent worktrees WITHOUT ever
# losing unmerged work (the R2/R7 convention: inspect from git, never trust a
# truncated agent's word that "it's done"). So every assertion here is built to
# CATCH the tool destroying something it must not:
#
#   (a) MERGED agent worktree (branch head is an ancestor of main) -> REAPED on
#       --apply (dir gone, branch gone, `git worktree list` no longer shows it).
#   (b) UNMERGED agent worktree (a commit that is NOT on main) -> KEPT + reported.
#       FALSIFIER: capture the commit sha + file content BEFORE reaping; after
#       --apply assert the worktree dir, the file, the branch, AND the commit
#       object ALL survive. If the reaper ever `-D`s an unmerged branch, this
#       fails and a commit is lost.
#   (c) --dry-run (the DEFAULT, no --apply) mutates NOTHING — the merged worktree
#       that (d) proves is reapable is still fully present after a default run.
#   (d) --apply removes ONLY the merged one (unmerged + out-of-scope untouched).
#   (e) a non-agent `.worktrees/real-feature` with unmerged commits is NOT touched;
#       and an out-of-scope worktree OUTSIDE the repo tree is NEVER touched even
#       though it is merged (protects the operator's real live worktrees).
#   (f) pollers: a watcher-shaped process line is REPORTED (K>=1) but NOT killed
#       without --kill (report-only is default-safe).
#
# ── THE GUARD CASES (g1-g5): MERGED IS NOT PERMISSION TO DELETE ──────────────
# `merge-base --is-ancestor` rules on COMMITS. The removal deletes a DIRECTORY.
# For a long time the reaper conflated the two and ran `git worktree remove
# --force` on any worktree whose commits were on main — which deletes modified
# files, untracked files and gitignored files without a word. These four cases
# are the falsifiers for that, plus one that proves the guard did not simply
# switch the tool off:
#
#   (g1) merged + a MODIFIED TRACKED file            -> KEPT
#   (g2) merged + ONLY an UNTRACKED file             -> KEPT  (untracked is the
#        common shape: a file an agent wrote and has not added yet)
#   (g3) merged + ONLY a GITIGNORED .claude/agent-memory/ file -> KEPT. This is
#        the case `git status --porcelain` structurally CANNOT see, and the test
#        asserts that blindness directly before asserting survival — otherwise
#        it would pass for the wrong reason.
#   (g4) merged + an EMPTY .claude/agent-memory/ skeleton, clean tree -> REAPED.
#        The harness mints that skeleton for every spawn; if its mere existence
#        protected, the reaper would be a permanent no-op and this suite would
#        still be green. ANTI-NEUTER.
#   (g5) merged + `git status` CANNOT RUN (broken gitdir link) -> KEPT. Fail
#        closed: "we could not tell" is never a licence to delete.
#
# Exit 0 = every assertion passed. Non-zero = a regression. Hermetic: throwaway
# git repos, no network, no real agent-pool, no process is ever actually killed.
#
# HMD_REAP_BIN overrides the binary under test, so the guard can be MUTATED OFF
# in a copy and this suite re-run to prove g1-g3/g5 actually go red. A guard whose
# removal keeps the suite green is not a guard, it is decoration.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REAP="${HMD_REAP_BIN:-$ROOT/bin/heimdall-reap-idle}"

[ -x "$REAP" ] || { echo "FATAL: $REAP not executable" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Classification predicates over a captured report. Anchored to the decision tag
# so "agent-x appears somewhere in the output" can never be mistaken for a verdict.
says_reap() { printf '%s\n' "$1" | grep -E '^\[REAP' | grep -q -- "$2"; }
says_keep() { printf '%s\n' "$1" | grep -E '^\[KEEP' | grep -q -- "$2"; }

TMPL="$(printf 'X%.0s' 1 2 3 4 5 6)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-reap-test.$TMPL")"
trap 'git -C "$WORK/repo" worktree prune 2>/dev/null; rm -rf "$WORK"' EXIT

# Seams so the test never touches a real agent-pool or a real process table.
export HEIMDALL_REAP_AGENTPOOL="/usr/bin/true"    # noop lease reconciler
FAKE_PS="$WORK/fake-ps.sh"                          # deterministic process table
cat > "$FAKE_PS" <<'PS'
#!/usr/bin/env bash
# emulate: pid pgid command  (a gcloud watcher poll-loop, on ONE line as real ps
# emits it; pgid != caller pgid so it is NEVER classified safe-to-kill). Single
# quotes keep the command-substitution literal — this line must not run seq.
echo ' 999321 999321 bash -c for i in $(seq 1 600); do gcloud run jobs executions describe foo --region us; sleep 5; done'
PS
chmod +x "$FAKE_PS"
export HEIMDALL_REAP_PS_CMD="$FAKE_PS"

# The idle-AGENT axis is not what this suite grades, but left unseamed it reads the
# REAL process table on every invocation — non-hermetic and slow. An empty table
# keeps that axis a no-op without touching a single real process.
FAKE_AGENT_PS="$WORK/fake-agent-ps.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_AGENT_PS"
chmod +x "$FAKE_AGENT_PS"
export HEIMDALL_REAP_AGENT_PS_CMD="$FAKE_AGENT_PS"

# ── Build the fixture repo with four worktrees ──────────────────────────────
R="$WORK/repo"
git init -q "$R"
git -C "$R" config user.email t@t.dev
git -C "$R" config user.name  tester
git -C "$R" config commit.gpgsign false
mkdir -p "$R/src"
echo "base" > "$R/src/base.txt"
# Mirror the real repo's .gitignore:33 — agent memory is IGNORED, which is exactly
# why `git status --porcelain` cannot be the only thing standing between an agent's
# memory home and `git worktree remove --force`.
printf '.claude/agent-memory/\n' > "$R/.gitignore"
git -C "$R" add -A
git -C "$R" commit -qm "base"
git -C "$R" branch -M main

# (a) MERGED agent worktree — branch sits AT main head => head is ancestor of main.
git -C "$R" worktree add -q -b worktree-agent-merged "$R/.claude/worktrees/agent-merged" main

# (b) UNMERGED agent worktree — a real commit that is NOT on main.
git -C "$R" worktree add -q -b worktree-agent-unmerged "$R/.claude/worktrees/agent-unmerged" main
echo "precious unmerged work" > "$R/.claude/worktrees/agent-unmerged/src/feature.txt"
git -C "$R/.claude/worktrees/agent-unmerged" add -A
git -C "$R/.claude/worktrees/agent-unmerged" commit -qm "unmerged: precious feature"
UNMERGED_SHA="$(git -C "$R/.claude/worktrees/agent-unmerged" rev-parse HEAD)"

# (e1) non-agent .worktrees/real-feature — also carries unmerged commits.
git -C "$R" worktree add -q -b real-feature "$R/.worktrees/real-feature" main
echo "human feature" > "$R/.worktrees/real-feature/src/human.txt"
git -C "$R/.worktrees/real-feature" add -A
git -C "$R/.worktrees/real-feature" commit -qm "real-feature commit"
REALFEAT_SHA="$(git -C "$R/.worktrees/real-feature" rev-parse HEAD)"

# (e2) out-of-scope worktree OUTSIDE the repo tree, at main head (merged) — must
#      never be touched because it is not under .claude/worktrees or .worktrees.
OUTSIDE="$WORK/outside-live-wt"
git -C "$R" worktree add -q -b outside-live "$OUTSIDE" main

# ── (g1-g5) MERGED worktrees that still hold something ──────────────────────
# Every one of these sits AT main head, so ancestry alone classifies all five as
# reapable. Four must survive anyway; the fifth must not.
WT="$R/.claude/worktrees"

# (g1) a modified TRACKED file, never committed.
git -C "$R" worktree add -q -b worktree-agent-dirtytracked "$WT/agent-dirtytracked" main
echo "edited in place, never committed" > "$WT/agent-dirtytracked/src/base.txt"

# (g2) ONLY an UNTRACKED file — nothing tracked was touched at all.
git -C "$R" worktree add -q -b worktree-agent-untracked "$WT/agent-untracked" main
echo "written by an agent, never git-added" > "$WT/agent-untracked/src/token_cumulative.py"

# (g3) ONLY a GITIGNORED agent memory home. git reports this worktree CLEAN.
git -C "$R" worktree add -q -b worktree-agent-memhome "$WT/agent-memhome" main
mkdir -p "$WT/agent-memhome/.claude/agent-memory/hmd-coder"
printf '# Agent Memory\n- [Feedback](feedback_x.md) — one-line hook\n' \
  > "$WT/agent-memhome/.claude/agent-memory/hmd-coder/MEMORY.md"

# (g4) ANTI-NEUTER: the empty memory skeleton the harness mints for every spawn,
#      and a clean tree. Holds nothing, so it MUST still be reaped.
git -C "$R" worktree add -q -b worktree-agent-emptymem "$WT/agent-emptymem" main
mkdir -p "$WT/agent-emptymem/.claude/agent-memory/hmd-coder"

# (g5) FAIL-CLOSED: the gitdir link points nowhere, so `git status` exits 128.
#      Verified against git 2.53.0: git does NOT mark this prunable, so the
#      classifier really does reach the guard rather than short-circuiting.
git -C "$R" worktree add -q -b worktree-agent-brokengit "$WT/agent-brokengit" main
echo "content that must not be deleted on a guess" > "$WT/agent-brokengit/src/base.txt"
printf 'gitdir: /nonexistent/hmd-reap-test/no/such/gitdir\n' > "$WT/agent-brokengit/.git"

echo "── (c) --dry-run (default) mutates NOTHING ─────────────────────────────"
OUT_DRY="$("$REAP" --repo "$R" 2>&1)"
if [ -d "$R/.claude/worktrees/agent-merged" ] \
   && git -C "$R" rev-parse --verify -q worktree-agent-merged >/dev/null; then
  ok "dry-run left the merged worktree + branch fully intact"
else
  bad "dry-run DESTROYED something (merged worktree/branch missing after default run)"
fi
if echo "$OUT_DRY" | grep -q "agent-merged"; then
  ok "dry-run still names the reap candidate (agent-merged) in its report"
else
  bad "dry-run report never mentioned agent-merged"; echo "$OUT_DRY"
fi

echo "── (b-pre) dry-run classifies the unmerged worktree as KEEP ────────────"
if echo "$OUT_DRY" | grep -Ei "keep" | grep -q "agent-unmerged"; then
  ok "unmerged agent worktree reported as KEEP"
else
  bad "unmerged agent worktree NOT reported as KEEP"; echo "$OUT_DRY"
fi

echo "── (g3-pre) git is STRUCTURALLY BLIND to the memory home ───────────────"
# Load-bearing: if this ever reported the memory file as dirty, (g3) below would
# be passing on the dirty-tree axis and proving nothing about the path axis.
MEMSTAT="$(git -C "$WT/agent-memhome" status --porcelain 2>&1)"; MEMRC=$?
if [ "$MEMRC" -eq 0 ] && [ -z "$MEMSTAT" ]; then
  ok "(g3-pre) \`git status --porcelain\` reports the memory-home worktree CLEAN (rc=0, no output)"
else
  bad "(g3-pre) memory home was visible to git (rc=$MEMRC) — fixture no longer models .gitignore:33"
  printf '%s\n' "$MEMSTAT"
fi

echo "── (g1-g5) merged-but-occupied worktrees are NOT classified reapable ───"
for CASE in \
  "agent-dirtytracked|a modified TRACKED file" \
  "agent-untracked|ONLY an untracked file" \
  "agent-memhome|ONLY a gitignored .claude/agent-memory/ file" \
  "agent-brokengit|an unreadable git state (fail-closed)"
do
  NAME="${CASE%%|*}"; DESC="${CASE#*|}"
  if says_reap "$OUT_DRY" "$NAME"; then
    bad "($NAME) classified REAPABLE despite $DESC — --apply would delete it"
    printf '%s\n' "$OUT_DRY" | grep -- "$NAME"
  elif says_keep "$OUT_DRY" "$NAME"; then
    ok "($NAME) held back as KEEP — $DESC"
  else
    bad "($NAME) got no decision line at all — the guard never ran on it"
    printf '%s\n' "$OUT_DRY"
  fi
done

echo "── (g4) ANTI-NEUTER: an EMPTY memory skeleton still reaps ──────────────"
if says_reap "$OUT_DRY" "agent-emptymem"; then
  ok "(g4) clean worktree with an empty .claude/agent-memory/ skeleton is still reapable"
else
  bad "(g4) the guard swallowed a worktree holding NOTHING — reaper neutered to a no-op"
  printf '%s\n' "$OUT_DRY" | grep -- "agent-emptymem"
fi

echo "── (d) --apply removes ONLY the merged worktree ────────────────────────"
OUT_APPLY="$("$REAP" --repo "$R" --apply 2>&1)"

# (a) merged -> gone
if [ ! -d "$R/.claude/worktrees/agent-merged" ] \
   && ! git -C "$R" rev-parse --verify -q worktree-agent-merged >/dev/null 2>&1; then
  ok "(a) MERGED agent worktree + branch were reaped"
else
  bad "(a) MERGED agent worktree survived --apply"; echo "$OUT_APPLY"
fi
if git -C "$R" worktree list --porcelain | grep -q "agent-merged"; then
  bad "(a) reaped worktree still registered in git worktree list"
else
  ok "(a) reaped worktree deregistered from git worktree list"
fi

# (b) unmerged -> FULLY survives (dir, file, branch, commit object)
SURV=1
[ -d "$R/.claude/worktrees/agent-unmerged" ] || SURV=0
[ -f "$R/.claude/worktrees/agent-unmerged/src/feature.txt" ] || SURV=0
grep -q "precious unmerged work" "$R/.claude/worktrees/agent-unmerged/src/feature.txt" 2>/dev/null || SURV=0
git -C "$R" rev-parse --verify -q worktree-agent-unmerged >/dev/null 2>&1 || SURV=0
git -C "$R" cat-file -e "$UNMERGED_SHA" 2>/dev/null || SURV=0
if [ "$SURV" = 1 ]; then
  ok "(b) FALSIFIER: unmerged commit $UNMERGED_SHA + file + branch all survived --apply"
else
  bad "(b) FALSIFIER TRIPPED: reaper LOST unmerged work (commit/file/branch destroyed)"; echo "$OUT_APPLY"
fi

# (e1) .worktrees/real-feature unmerged -> untouched
if [ -d "$R/.worktrees/real-feature" ] \
   && grep -q "human feature" "$R/.worktrees/real-feature/src/human.txt" 2>/dev/null \
   && git -C "$R" cat-file -e "$REALFEAT_SHA" 2>/dev/null; then
  ok "(e) non-agent .worktrees/real-feature (unmerged) was NOT touched"
else
  bad "(e) non-agent .worktrees/real-feature was destroyed"; echo "$OUT_APPLY"
fi

# (e2) out-of-scope worktree -> untouched even though merged
if [ -d "$OUTSIDE" ] && git -C "$R" rev-parse --verify -q outside-live >/dev/null 2>&1; then
  ok "(e) out-of-scope worktree OUTSIDE repo tree was NOT touched (even though merged)"
else
  bad "(e) out-of-scope worktree was reaped — scope filter FAILED (operator worktrees at risk)"; echo "$OUT_APPLY"
fi

echo "── (g1-g5) FALSIFIER: --apply destroyed none of the occupied worktrees ─"
# The real test of a guard is not what the report SAYS, it is what is still on
# disk after the destructive path has actually run.
guard_survived() { # <label> <file-that-must-exist> <string-that-must-still-be-in-it>
  if [ -f "$2" ] && grep -q -- "$3" "$2" 2>/dev/null; then
    ok "$1"
  else
    bad "DATA LOSS: $1 — file gone or content destroyed by --apply ($2)"
    printf '%s\n' "$OUT_APPLY"
  fi
}
guard_survived "(g1) modified tracked file survived --apply" \
  "$WT/agent-dirtytracked/src/base.txt" "edited in place, never committed"
guard_survived "(g2) untracked-only file survived --apply" \
  "$WT/agent-untracked/src/token_cumulative.py" "written by an agent, never git-added"
guard_survived "(g3) gitignored agent memory home survived --apply" \
  "$WT/agent-memhome/.claude/agent-memory/hmd-coder/MEMORY.md" "Agent Memory"
guard_survived "(g5) undeterminable worktree survived --apply (fail-closed)" \
  "$WT/agent-brokengit/src/base.txt" "content that must not be deleted on a guess"

if [ ! -d "$WT/agent-emptymem" ]; then
  ok "(g4) ANTI-NEUTER: the empty-skeleton worktree WAS reaped by --apply"
else
  bad "(g4) --apply reaped nothing here — guard is over-broad, reaper reclaims no disk"
  printf '%s\n' "$OUT_APPLY"
fi

if echo "$OUT_APPLY" | grep -q "protected"; then
  ok "apply summary reports a protected count"
else
  bad "apply summary never mentions protected worktrees"; echo "$OUT_APPLY"
fi

echo "── (a) apply report names the reaped one + summary counts ──────────────"
if echo "$OUT_APPLY" | grep -Ei "reap" | grep -q "agent-merged"; then
  ok "apply report names agent-merged as reaped"
else
  bad "apply report did not name agent-merged as reaped"; echo "$OUT_APPLY"
fi
if echo "$OUT_APPLY" | grep -qiE "[0-9]+ kept-unmerged|kept .*unmerged|unmerged.*kept"; then
  ok "apply summary reports kept-unmerged count"
else
  bad "apply summary missing kept-unmerged count"; echo "$OUT_APPLY"
fi

echo "── (a) idempotent: a second --apply is a clean no-op ───────────────────"
if OUT2="$("$REAP" --repo "$R" --apply 2>&1)"; then
  ok "second --apply exited 0 (idempotent)"
else
  bad "second --apply errored"; echo "$OUT2"
fi

echo "── (f) pollers reported, NOT killed without --kill ─────────────────────"
if echo "$OUT_DRY" | grep -Ei "poller|watcher" | grep -q "999321"; then
  ok "(f) watcher-shaped process 999321 was reported"
else
  bad "(f) watcher process not reported"; echo "$OUT_DRY"
fi
if echo "$OUT_DRY" | grep -q "kill 999321"; then
  ok "(f) a ready-to-run kill command was offered for the poller"
else
  bad "(f) no kill command offered for the poller"; echo "$OUT_DRY"
fi

echo "── (f2) --kill terminates ONLY a watcher in THIS process group ─────────"
# The reaper runs in the test's process group, so a same-pgid planted child is
# 'safe to kill'. The seam lists ONLY our planted pid, so --kill can target
# nothing but this one harmless process (': gh pr list' never invokes gh).
TPGID="$( (ps -o pgid= -p $$ 2>/dev/null || echo 0) | tr -d ' ' )"
bash -c 'while true; do : gh pr list; sleep 30; done' &
WPID_SAME=$!
PS_SAME="$WORK/fake-ps-same.sh"
printf '#!/usr/bin/env bash\necho " %s %s bash -c while true do gh pr list sleep 30 done"\n' "$WPID_SAME" "$TPGID" > "$PS_SAME"
chmod +x "$PS_SAME"
HEIMDALL_REAP_PS_CMD="$PS_SAME" "$REAP" --repo "$R" --kill >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$WPID_SAME" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$WPID_SAME" 2>/dev/null; then
  bad "(f2) same-group watcher SURVIVED --kill"; kill "$WPID_SAME" 2>/dev/null
else
  ok "(f2) --kill terminated the same-process-group watcher child"
fi
wait "$WPID_SAME" 2>/dev/null || true

echo "── (f3) --kill NEVER kills a watcher in a DIFFERENT process group ───────"
# FALSIFIER for the safety boundary: same watcher shape, but the seam reports a
# foreign pgid. --kill must refuse (report-only) and the process must SURVIVE.
bash -c 'while true; do : gh pr list; sleep 30; done' &
WPID_OTHER=$!
PS_OTHER="$WORK/fake-ps-other.sh"
printf '#!/usr/bin/env bash\necho " %s 111111 bash -c while true do gh pr list sleep 30 done"\n' "$WPID_OTHER" > "$PS_OTHER"
chmod +x "$PS_OTHER"
HEIMDALL_REAP_PS_CMD="$PS_OTHER" "$REAP" --repo "$R" --kill >/dev/null 2>&1
sleep 0.3
if kill -0 "$WPID_OTHER" 2>/dev/null; then
  ok "(f3) foreign-pgid watcher SURVIVED --kill (pgid scoping holds)"
else
  bad "(f3) --kill killed a process NOT in its own group — safety boundary breached"
fi
kill "$WPID_OTHER" 2>/dev/null || true
wait "$WPID_OTHER" 2>/dev/null || true

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL GREEN"
  echo "heimdall-reap-idle: $PASS passed, $FAIL failed"
  exit 0
else
  echo "  REGRESSION"
  echo "heimdall-reap-idle: $PASS passed, $FAIL failed"
  exit 1
fi
