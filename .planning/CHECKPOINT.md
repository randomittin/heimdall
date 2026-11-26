<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-11-26T10:46:08Z

> Written automatically at session end (mechanical, no LLM). Run `/hmd:save`
> for a richer human/LLM-authored handoff — it enriches this same file.

- **Branch:** main
- **HEAD:** c5d2d60b
- **Phase:** unknown
- **Active goal:** none
- **Uncommitted files:** 2

### What must never be lost (the resume contract)
> Graded on the next restart by `heimdall-resume-probe` against the digests in
> `.planning/RESUME-KEY.json`, written at save time — while the knowledge is
> still present. A field that does not survive this write FAILS the save.

- **In progress:** phase=unknown · goal=none · compaction (auto) at 2026-11-22T13:27:33Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-23T05:15:23Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-23T07:47:44Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-25T00:21:38Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-26T06:37:56Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentnext: ask operator for npm publish (npm login && release/ship.sh --npm-only) and the live /hmd:save auto-compact result; then backlog MEDIUM compact-now expiry check on UserPromptSubmit/Stop via one hmd:coder, its own compact-window suite once · in flight: 2 uncommitted file(s) — .planning/CHECKPOINT.md.planning/STATE.md
- **Gated decisions:** push gate FAILING — nothing may be pushed until it clearsOperator-only (item 15): push local commits to origin; runhmd.dev DNS; GitHub App registration; npm publish runhmd only after hmd attack is released; hmd receipt keygen + commit release/runhmd-receipt.pub; relay deploy (canary URL assumes hmd-relay-canary.therishabh16.workers.dev, else set RELAY_URL).npm publish of 2.4.16 (operator holds credentials)live confirmation that /hmd:save compacts by itself
- **Held branches:** worktree-agent-a02e0b61662c89dd2 (1 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-a02e0b61662c89dd2)worktree-agent-a21537b121081222d (5 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-a21537b121081222d)perf-app-pair (4 commit(s) not on main)perf-attach (1 commit(s) not on main)perf-mutants (4 commit(s) not on main)perf-shell-heavy (1 commit(s) not on main)perf-view (1 commit(s) not on main)readme-launch (2 commit(s) not on main)worktree-agent-a01812998a16c79bf (2 commit(s) not on main)worktree-agent-a0b3b29e1ead39351 (5 commit(s) not on main)worktree-agent-a3236595ab3b3adbd (1 commit(s) not on main)worktree-agent-a4ddcfc5c10a426d1 (4 commit(s) not on main)worktree-agent-a540397c1f134aa66 (1 commit(s) not on main)worktree-agent-a58aa859c281c70a8 (13 commit(s) not on main)worktree-agent-a5e40bbcd8616400e (6 commit(s) not on main)worktree-agent-a748f2d5d2d8b8d87 (1 commit(s) not on main)worktree-agent-a757edcc7298ab070 (3 commit(s) not on main)worktree-agent-a9af528198b7e6a9f (8 commit(s) not on main)worktree-agent-ab644b92c05a00b17 (1 commit(s) not on main)worktree-agent-af5ad2fe39acaf38e (1 commit(s) not on main)
- **Unpushed:** 2 commit(s) unpushed on main (HEAD c5d2d60b, upstream origin/main)
- **Open warnings:** hmdapp app-side needed: refusal ack must parse detail=='non-increasing-seq' + numeric last; phone register_push loop = 99% of 5,200 acks/day; restart hmd app connect for push-test + WebSocket hmd leg; launch-brief handbacks not yet written to hmdapp/docs.⚠ push gate is RED⚠ 3 worktree(s) flagged dirty or unmerged
- **Refuted claims:** module-consent-waiver's 7 failures were real defects → they were starvation artifacts from my own stray load generators; solo run is 65/0the OmniRoute gateway is wedged at the HTTP layer → it is a webpack DEV server recompiling per request; it answered / with 307 after 141.78sthe 6 sweep reds on f166096a were code regressions → 5 were timing budgets under external load 18-45 (A/B: main faster than fd256c80), 1 was a 30-day reachability exemption that expired on 2026-09-21companion-view zlib size red was a load flake → a real test race: a plain frame in flight answered the wait; fixed 97aa9527

### Worktree ledger — nothing-lost proof (25 of 54 worktree(s) scanned (+29 more not scanned))
> Base ref: `main`. Clean = zero uncommitted files AND HEAD merged into base.

- 22/25 clean, 3 flagged — rescue these before restarting:
- DIRTY `/Users/rj/Downloads/heimdall` — 2 uncommitted file(s)
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a02e0b61662c89dd2` — HEAD has commits not on `main`
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a21537b121081222d` — HEAD has commits not on `main`

### Gate state (push-gate verdict — FAILING)
> RED — do not push until this clears. Detail:
```
LINT WAIVED: 2.4.8: 21 shellcheck warnings (15 SC2034 unused vars, SC2163 intentional export of kv string, SC2010, SC2120, SC2154, SC1090), 0 errors, 19 in test files; fixes ride the next batch (waived 2026-11-26T07:38:43Z) -- the lint evidence is NOT passing (findings: 24 lint finding(s) in the last run)
GATE FAILED: sweep receipt is STALE — receipt HEAD d87b01ca1d56f12b59226de8bb375416669b88d4 != current HEAD c5d2d60bdf499bf74095cd77a4f06624ab933fbb (commits landed since the sweep ran, including non-hook-owned paths: .claude-plugin/plugin.json,.planning/CHECKPOINT.md,.planning/settings.json). Run: bash test/run-all.sh --since-green
GATE FAILED: no use-case journey receipt vouches for HEAD either: STALE: the use-case journey receipt is for 136759dae911, HEAD is c5d2d60bdf49 (commits landed since the journeys ran, including paths that are not the hooks' own: .claude-plugin/plugin.json, .planning/BACKLOG.md, .planning/CHECKPOINT.md and 224 more). Run: bash test/use-cases/run.sh (a green full run on a clean, committed tree writes /Users/rj/Downloads/heimdall/.heimdall/receipts/use-cases.json, which this gate takes in place of a full sweep; only a release needs the sweep).
Quality gates not met. Push blocked.
```

### Recent commits
- c5d2d60b journal: [COMMUNICATION] chore(planning): checkpoint after 2.4.16
- 31dd7a81 chore(planning): checkpoint after 2.4.16
- ccb9d1b1 chore(release): v2.4.16
- d87b01ca journal: [COMMUNICATION] test(companion-view): wait for the compressed frame after a z-zlib resync
- 97aa9527 test(companion-view): wait for the compressed frame after a z-zlib resync
- 28d3a644 journal: [COMMUNICATION] fix(continue): keep the whole reason the auto-compact was not armed; count the compact-now SessionStart hook
- eb4ca8de fix(continue): keep the whole reason the auto-compact was not armed; count the compact-now SessionStart hook
- 330af7d0 Merge branch 'worktree-agent-a2579bed78e209180'
- c8ae3b19 chore(evals): re-record lean-context-parity for the save.md wording
- f6a59e0e wip: forced checkpoint (heimdall-wip)

### Uncommitted changes (git status --porcelain)
```
 M .planning/CHECKPOINT.md
 M .planning/STATE.md
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
- [x] 2.4.14 — /hmd:save absorbs /hmd:continue (alias); compact-window --bash-cap; ship.sh commits+pushes site pins
- [x] 2.4.15 — ship.sh fetch + foreign-commit refusal; relay-client shutdown join (c7eaea83) + ghost record fix (522e3019); journal prefix strip; read-dedup outline
- [x] 2.4.16 — ccb9d1b1, GitHub release 07:42Z, site e3ed900: /hmd:save arms auto-compact (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1 in project .claude/settings.local.json; released by PreCompact/SessionStart/300 s timer/off). Sweep reds fixed: eb4ca8de (reason cap 200→800, G9 18 hooks), 97aa9527 (companion-view zlib wait race)
- [x] Checkpoint 31dd7a81

## In Progress
- none. Tree clean, no agents running.

## Not Started (in order)
1. Operator: `npm login && release/ship.sh --npm-only` for 2.4.16.
2. Operator: run /hmd:save in a fresh session (2.4.16 plugin) → confirm it compacts by itself and handoff re-injects. This session ran the pre-2.4.16 save.md text.
3. Backlog MEDIUM: compact-now expiry check on UserPromptSubmit/Stop hooks (review of 2.4.16); MEDIUM: say in save.md step 7 when another session's SessionStart released the arming.
4. Backlog 2.4.15 LOWs (.planning/BACKLOG.md), 3.x M1 skill registry, 2.5.0 relay capabilities.

## Resume Instructions
Ask operator for the /hmd:save live result; if it did not compact, read the printed reason and fix in bin/heimdall-compact-window. Else take Not Started #3 as one hmd:coder (own suite once: bash test/heimdall-compact-window.test.sh). No full run yet for new work; recommend it before the merge. Disk at floor: free space before any sweep, or run with inline HMD_MIN_FREE_PCT=8.

## Key Context
- Release convergence (enforced): one review/release, only BLOCKER/HIGH block, MEDIUM/LOW→backlog, one sweep last, `--failed` after red. Never chain an agent per finding.
- Security-bot findings on own commits: triage same way.
- Agents routinely hit 50-turn limit: resume via SendMessage, never respawn; cap scope ~1 finding/agent.
- npm: operator runs `npm login && release/ship.sh --npm-only`; agent never publishes npm. ship.sh --no-npm is agent-run with operator go.
- Judge fence: reviewer via `HMD_JUDGMENT=1 bin/lib/hmd-route-claude -p --model opus --allowedTools ... < prompt`.
- Tests must never write real ~/.heimdall (run-all guards it: REAL HOME WRITTEN → red).
- Never kill hmd relay/ui by name; never touch Keychain/login store; never edit hmdapp code.
- Literal push-command text in any Bash command trips the push gate; reword heredocs.
- Do not clear fret, ~/.gradle, ~/Library/Caches; claude versions in use (ps) stay.

## Project Settings
- Parallelism: max 10, disjoint files per agent; sonnet coders, opus judges.
- Test: `bash test/run-all.sh --jobs 3 --timeout 400` (cached; `--cold` for x.y.0); one suite: `bash test/<name>.test.sh`.
- Release: `release/ship.sh --no-npm` then operator `--npm-only`; site checks `bin/heimdall-repo-checks run --repo ../heimdall-site`.
- Avoid: .claude/worktrees, /tmp/heimdall-*, routine scratchpad, ~/.gradle, ~/Library/Caches.
