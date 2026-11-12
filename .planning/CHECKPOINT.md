<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-11-12T09:18:58Z

> Written automatically at session end (mechanical, no LLM). Run `/hmd:save`
> for a richer human/LLM-authored handoff — it enriches this same file.

- **Branch:** main
- **HEAD:** 1d4d6a81
- **Phase:** unknown
- **Active goal:** none
- **Uncommitted files:** 4

### What must never be lost (the resume contract)
> Graded on the next restart by `heimdall-resume-probe` against the digests in
> `.planning/RESUME-KEY.json`, written at save time — while the knowledge is
> still present. A field that does not survive this write FAILS the save.

- **In progress:** phase=unknown · goal=none · in flight: 4 uncommitted file(s) — .planning/CHECKPOINT.md.planning/settings.json.planning/ledger/checkpoints/haid_unknown.rishabhs-macbook-air-70af.json.planning/ledger/checkpoints/haid_unknown.rishabhs-macbook-air-a8fa.json
- **Gated decisions:** push gate FAILING — nothing may be pushed until it clears
- **Held branches:** worktree-agent-a9ac1801deebf9b9f (1 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-a9ac1801deebf9b9f)worktree-agent-abbd360b35aa59e9a (1 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-abbd360b35aa59e9a)perf-app-pair (4 commit(s) not on main)perf-attach (1 commit(s) not on main)perf-mutants (4 commit(s) not on main)perf-shell-heavy (1 commit(s) not on main)perf-view (1 commit(s) not on main)readme-launch (2 commit(s) not on main)worktree-agent-a01812998a16c79bf (2 commit(s) not on main)worktree-agent-a0b3b29e1ead39351 (5 commit(s) not on main)worktree-agent-a3236595ab3b3adbd (1 commit(s) not on main)worktree-agent-a4ddcfc5c10a426d1 (4 commit(s) not on main)worktree-agent-a540397c1f134aa66 (1 commit(s) not on main)worktree-agent-a58aa859c281c70a8 (13 commit(s) not on main)worktree-agent-a5e40bbcd8616400e (6 commit(s) not on main)worktree-agent-a748f2d5d2d8b8d87 (1 commit(s) not on main)worktree-agent-a757edcc7298ab070 (3 commit(s) not on main)worktree-agent-ab644b92c05a00b17 (1 commit(s) not on main)
- **Unpushed:** 151 commit(s) unpushed on main (HEAD 1d4d6a81, upstream origin/main)
- **Open warnings:** ⚠ push gate is RED⚠ 3 worktree(s) flagged dirty or unmerged
- **Refuted claims:** none recorded this session — record one with: heimdall-checkpoint note refuted "<claim> → what was actually true"

### Worktree ledger — nothing-lost proof (11 of 11 worktree(s) scanned)
> Base ref: `main`. Clean = zero uncommitted files AND HEAD merged into base.

- 8/11 clean, 3 flagged — rescue these before restarting:
- DIRTY `/Users/rj/Downloads/heimdall` — 4 uncommitted file(s)
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a9ac1801deebf9b9f` — HEAD has commits not on `main`
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-abbd360b35aa59e9a` — HEAD has commits not on `main`

### This session's edited files (edit-tracker — git log cannot attribute these)
```
[heimdall] edit tracker: 0 files, 0 operations
```

### Gate state (push-gate verdict — FAILING)
> RED — do not push until this clears. Detail:
```
GATE FAILED: Tests not passing
LINT WAIVED: 2.4.8: 21 shellcheck warnings (15 SC2034 unused vars, SC2163 intentional export of kv string, SC2010, SC2120, SC2154, SC1090), 0 errors, 19 in test files; fixing them stales the green full receipt 3a0f2c0b; fixes ride the 2.4.9 batch (waived 2026-10-19T20:50:33Z) -- the lint evidence is NOT passing (findings: 24 lint finding(s) in the last run)
GATE FAILED: Changes pending re-test
GATE FAILED: no sweep receipt at /var/folders/t3/17x0hkw12n3g0qy3sjkggbsr0000gn/T/hr.3Kgl/s9/install-stranger.z3BIO0/tmp.ZznfOpkY/.heimdall/.heimdall/receipts/last-sweep.json — a full sweep has never recorded a result in this checkout. Run: bash test/run-all.sh
Quality gates not met. Push blocked.
```

### Recent commits
- 1d4d6a81 journal: [COMMUNICATION] docs(backlog): consent menu header repo
- 12d2e6e9 docs(backlog): consent menu header repo
- c4d290cf Merge branch 'worktree-agent-a69eb45d5e3363123'
- 618b8782 journal: [COMMUNICATION] Merge branch 'worktree-agent-a0a5934b6e6c88f7f'
- 1566e0ab fix(security): allowlist consent binds to the manifest repo, not the name
- dd5a0d69 Merge branch 'worktree-agent-a0a5934b6e6c88f7f'
- e7f90f96 journal: [COMMUNICATION] journal: [COMMUNICATION] docs(backlog): review round 1 MEDIUM/LOW findings
- 1eba11b0 fix(hooks): gp agent rules say commit only when the spawn has its own worktree
- 37aac851 journal: [COMMUNICATION] docs(backlog): review round 1 MEDIUM/LOW findings
- 19f68bb3 docs(backlog): review round 1 MEDIUM/LOW findings

### Uncommitted changes (git status --porcelain)
```
 M .planning/CHECKPOINT.md
 M .planning/settings.json
?? .planning/ledger/checkpoints/haid_unknown.rishabhs-macbook-air-70af.json
?? .planning/ledger/checkpoints/haid_unknown.rishabhs-macbook-air-a8fa.json
```

### Resume
Runnable, in order:
```bash
cat "/Users/rj/Downloads/heimdall/.planning/CHECKPOINT.md"    # this file, full context
heimdall-state check-quality-gates  # gate must be green before any push
git -C "/Users/rj/Downloads/heimdall" status --porcelain      # confirm nothing changed since this write
```
Then `heimdall` to resume. If a goal is set above, restore it with `/goal <condition>`.
<!-- heimdall-auto-checkpoint:end -->
## Completed (this session)
- [x] 2.4.8 — GitHub/site 2be30a44; npm via heimdall-248 worktree (swept bump parent 3a0f2c0b)
- [x] 2.4.9 — 3afb282d: test cache/--failed/--fail-fast, per-commit receipt archive (d8123803), pair default-ON + relay pinning + opt-out hardening, link-safety (hmd_nofollow_write.py), statusline pair-code marker, CI guard, keychain probe
- [x] Release-loop enforcement: sweep guard d9c006a9, heimdall-findings e82a7a72, fix-chain conformance 1604cf84, CLAUDE.md "Release convergence" cf59dc63
- [x] 2.4.10 — 1a3f80e6: all SessionEnd hooks detached + generic test (bc91aced), /hmd:continue (b62b6e4f, 3a98d953), init gitignores CONTINUE.md (cc244196), 2.4.9 changelog section (99bc55f5)
- [x] Site pins v2.4.10 pushed e0386e3 (hand-pushed; see Not Started #1)

## In Progress
- none. Tree clean, all agents finished.

## Not Started (in order)
1. Operator reviews `docs/GTM-2.4.x.md` — HARD GATE: no new version until reviewed (note: S7 gh-token line rewritten for default-ON pairing).
2. Fix `release/ship.sh`: commit+push heimdall-site page pins itself (14 html + llms-full.txt + version.js; verify install sha == tag install.sh). Today it commits only netlify.toml → 15 dirty files on 2.4.9 and 2.4.10.
3. 3.x M1: skill registry, zero behaviour change — /Users/rj/Downloads/01-skills-separation.md, handoff/heimdall/{PLAN.md,goals.yaml,CONTRACTS.md}. goals.yaml human-owned (propose via PR). No release until GTM review.
4. Backlog `.planning/BACKLOG.md`: 2.5.0 hmdapp relay capabilities (verdict-v1, status-v1, allow+audit, pause/resume, commands, approval_tier, denied push kind, watch rate limit); link-safety leftovers (autocommit/reel/context-sync); pair-optin env test seam (MEDIUM); toolchain versions in salt; closure gaps.

## Resume Instructions
Ask operator for GTM review result. Meanwhile, item 2 is a Medium-path fix: one hmd:coder, test in ship suite, its suite once. Full sweep last, once, `--failed` after a red. Operator live checks pending: phone pairs from a fresh `hmd` session (code self-registers, 6-min window); `/hmd:continue` in a real compaction; quitting 2.4.10 shows no "Hook cancelled".

## Key Context
- Release convergence (enforced): one review/release, only BLOCKER/HIGH block, MEDIUM/LOW→backlog, one sweep last, `--failed` after red. Never chain an agent per finding.
- Security-bot findings on own commits: triage same way.
- Agents routinely hit 50-turn limit: resume via SendMessage, never respawn; cap scope ~1 finding/agent.
- npm: operator runs `npm login && release/ship.sh --npm-only`; agent never publishes npm. ship.sh --no-npm is agent-run with operator go.
- Judge fence: reviewer via `HMD_JUDGMENT=1 bin/lib/hmd-route-claude -p --model opus --allowedTools ... < prompt`.
- Tests must never write real ~/.heimdall (run-all guards it: REAL HOME WRITTEN → red).
- Never kill hmd relay/ui by name; never touch Keychain/login store; never edit hmdapp code.

## Project Settings
- Parallelism: max 10, disjoint files per agent; sonnet coders, opus judges.
- Test: `bash test/run-all.sh --jobs 3 --timeout 400` (cached; `--cold` for x.y.0); one suite: `bash test/<name>.test.sh`.
- Release: `release/ship.sh --no-npm` then operator `--npm-only`; site checks `bin/heimdall-repo-checks run --repo ../heimdall-site`.
- Avoid: .claude/worktrees, /tmp/heimdall-*, routine scratchpad, ~/.gradle, ~/Library/Caches.
