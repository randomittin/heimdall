# Branch Cleanup — Launch Prep (item 10)

Date: 2026-07-07 · Author: hmd · Executor: **RJ** (hmd does NOT run deletes)

## Headline finding: origin is ALREADY clean
`git ls-remote --heads origin` returns **exactly one ref: `refs/heads/main`.** There are **zero
stale remote branches** — including the `heimdall/issue-*` class. The R9-failure leak
(`heimdall/issue-2-mcp-path`) is a **local-only** branch that was never pushed.

**→ No `git push origin --delete` commands are needed. Item 10's remote hazard does not exist on
origin.** The cleanup is entirely **local branches + worktrees.**

Current state: **80 local branches** (`git branch | wc -l`), **17 worktrees**, target `< ~10`.

---

## A. Merged-into-main local branches — SAFE to delete (RJ)
72 local branches are fully merged into `main` (`git branch --merged main`). All safe to remove
with `-d`. **Exclude** `main` and the branch of any live worktree (delete the worktree first — §C).

Not checked out in a worktree — delete directly:
```bash
cd ~/Downloads/heimdall
git branch -d \
  backup/pre-secret-scrub-branch bug20-finish \
  cp-deploy-diagnose cp-deploy-server cp-dispatch-loud-log cp-firestore-doc-inspector \
  cp-getjobs-query-param cp-getjobs-readpath cp-job-runner-cloudrun cp-self-enroll \
  cp-state-firestore cp-state-interface cp-state-scheduler \
  feat/cp-enroll feat/cp-nonce feat/cp-nonce2 feat/cp-public-surface feat/cp-ratelimit \
  feat/deploy-split-surface feat/f3-redum feat/file-identity feat/gate-verdict-hud-events \
  feat/go-live-runbook feat/go-live-script feat/heimdall-land-team-flow \
  feat/hmd-emit-usage-from-output feat/statusline-autobeat feat/statusline-presence-wiring \
  feat/wire-watchman-statusline fix-dashboard-firestore-path fix-f1-nontty-launcher \
  fix-readyz-backend-health fix-server-haid-canonical fix/cp-presence-deployed-seed \
  fix/parity-findings fix/s6-c3-manifest-v2 fix/sigil-clean-watchman \
  fix/statusline-squint-parity integ/zero-config parity/staging \
  polish/idle-statusline-tease presence-zeroconf-bootstrap s6-c3-proposal-20260617-092340 \
  verify-flightfix-image-timing verify-step5-readback-timing \
  worktree-agent-a094d12d28e544c15 worktree-agent-a0ab9984b834eac1f \
  worktree-agent-a2e6181ebb2c0b151 worktree-agent-a3ffa3fbaf2c7e81e \
  worktree-agent-a6226df4a2b612fd7 worktree-agent-a998a32e67a11d73f \
  worktree-agent-a9a52187cd203993a worktree-agent-ab0c21d303a81893e \
  worktree-agent-ab4df718b6e4ca911 worktree-agent-ac4bb9adf890a0dff \
  worktree-agent-ac5a659d60b962298 worktree-agent-ac89fcd2d435bb1c5 \
  worktree-agent-ad331ea9b8e3a009c worktree-agent-adb702e0bb3d49d36 \
  worktree-agent-ae00cc31296a14aa3 worktree-agent-ae2b5d3cd9c67916f
```

Merged **but checked out in a worktree** (remove the worktree in §C first, then these `-d` succeed):
`cp-presence`, `feat/deploy-public-rr`, `feat/hmd-feedback`, `feat/landmine-astgrep`,
`feat/viral-statusline-conformance`, `fix/cloud-maintainer-blockers`,
`worktree-agent-acc7bd7e5437765ef`, `worktree-agent-ad70ec75c2280cb34`,
`worktree-agent-af22cdfcf92cb682e`. **Do NOT touch `worktree-agent-a23f96d0277ae2037`** — that is
the live hmd worktree running this task (locked).

---

## B. UNMERGED local branches — RJ decides (do NOT blind-delete)
8 branches have commits not in `main` (`git branch --no-merged main`). Recommendations from
`git log main..<branch>`:

| Branch | Ahead | Content | Rec |
|---|---|---|---|
| `feat/autoupdate-core` | 2 | autoupdate feature | **KILL** — superseded; `bin/heimdall-autoupdate` already on main (v2.0.16) |
| `feat/autoupdate-wiring` | 3 | merge of autoupdate-core | **KILL** — same, superseded |
| `feat/deploy-split2` | 1 | two-service split | **KILL** — superseded by `feat/deploy-public-rr`+go-live (both merged) |
| `heimdall/issue-2-mcp-path` | 1 | `test(mcp): guard heimdall-ledger MCP cwd-relative path (fixes #2)` | **REVIEW** — real test for issue #2; cherry-pick the test to main, then kill (the leak that caused R9) |
| `worktree-agent-a0f4a8710f7556595` | 1 | `feat(team): zero-command default — bare 'hmd team' smart dispatch + SessionStart auto` | **REVIEW/KEEP** — real feature not on main |
| `worktree-agent-a1be14557112a27e8` | 1 | `docs(public-surface): document GET /roster-public unsigned browser read` | **REVIEW** — cherry-pick the docs, then kill |
| `worktree-agent-aa768c1a78afb8021` | 1 | `fix(issue-pr): bug #21 — open_pr commits fix onto heimdall/issue/<id>, bot push, never main` | **REVIEW/KEEP** — cloud-maintainer bug fix; confirm not superseded before kill |
| `worktree-agent-af3eec7e70ca385d8` | 1 | `fix(issue-pr): bug #26 — gh pr create got empty/stale App-JWT` | **REVIEW/KEEP** — cloud-maintainer bug fix |

Force-delete (only after RJ confirms superseded — `-D`, not `-d`):
```bash
git branch -D feat/autoupdate-core feat/autoupdate-wiring feat/deploy-split2
```
Leave the four maintainer/team fixes and `heimdall/issue-2-mcp-path` until their content is
cherry-picked to main or explicitly abandoned.

---

## C. Worktrees — remove stale, then their branches become deletable
`git worktree prune -n` reports **nothing stale** (all 17 worktrees have live gitdirs), so pruning
alone won't reduce the count — the worktrees must be explicitly removed. Remove the ones whose work
is merged or abandoned (keep the live one you're in):
```bash
# Merged / disposable worktrees — safe to remove:
git worktree remove ~/Downloads/heimdall/.claude/worktrees/cp-presence
git worktree remove ~/Downloads/heimdall/.claude/worktrees/feat-hmd-feedback
git worktree remove ~/Downloads/heimdall/.claude/worktrees/viral-statusline-conf
git worktree remove ~/Downloads/heimdall-wt-landmine
git worktree remove /private/tmp/claude-501/.../wt-cloudmaint   # fix/cloud-maintainer-blockers (merged)
git worktree remove /private/tmp/claude-501/.../wt-public-rr    # feat/deploy-public-rr (merged)
git worktree remove /private/tmp/claude-501/.../wtA             # detached HEAD
git worktree remove /private/tmp/claude-501/.../wtB             # detached HEAD
git worktree prune -v   # clean up any now-dangling admin entries
# DO NOT remove worktrees/agent-a23f96d0277ae2037 (locked, live hmd session).
# Keep worktrees whose branch is UNMERGED in §B until decided:
#   agent-a0f4a8710f7556595, agent-a1be14557112a27e8, agent-aa768c1a78afb8021,
#   agent-a6226df4a2b612fd7 (heimdall/issue-2-mcp-path)
```
After removing a worktree, its merged branch (§A "checked out" list) deletes cleanly with `git branch -d`.

---

## Kill-list summary (for RJ)
- **Remote:** nothing — origin already only has `main`.
- **Local merged:** 72 branches → `git branch -d` (§A); ~9 need their worktree removed first (§C).
- **Local unmerged KILL:** `feat/autoupdate-core`, `feat/autoupdate-wiring`, `feat/deploy-split2` (superseded).
- **Local unmerged REVIEW (do not kill yet):** `heimdall/issue-2-mcp-path`, `worktree-agent-a0f4a8710f7556595`, `worktree-agent-a1be14557112a27e8`, `worktree-agent-aa768c1a78afb8021`, `worktree-agent-af3eec7e70ca385d8`.
- **Never touch:** `main`, `worktree-agent-a23f96d0277ae2037` (live locked worktree).

Result after §A+§C+the 3 KILLs: ~80 → **≈ 6 local branches** (main + the 5 REVIEW branches),
under the `< ~10` target.
