<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-11-26T07:42:35Z

> Written automatically at session end (mechanical, no LLM). Run `/hmd:save`
> for a richer human/LLM-authored handoff — it enriches this same file.

- **Branch:** main
- **HEAD:** ccb9d1b1
- **Phase:** unknown
- **Active goal:** none
- **Uncommitted files:** 0

### What must never be lost (the resume contract)
> Graded on the next restart by `heimdall-resume-probe` against the digests in
> `.planning/RESUME-KEY.json`, written at save time — while the knowledge is
> still present. A field that does not survive this write FAILS the save.

- **In progress:** phase=unknown · goal=none · compaction (auto) at 2026-11-22T01:29:50Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-22T13:27:33Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-23T05:15:23Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-23T07:47:44Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-25T00:21:38Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail wentcompaction (auto) at 2026-11-26T06:37:56Z session 0e12831c-b9f2-4238-ad95-43a28e7409d2 — checkpoint auto-taken by the PreCompact hook before context was rewritten; if the resumed session feels thin, this is where the detail went · in flight: 0 uncommitted files
- **Gated decisions:** push gate FAILING — nothing may be pushed until it clearsOperator-only (item 15): push local commits to origin; runhmd.dev DNS; GitHub App registration; npm publish runhmd only after hmd attack is released; hmd receipt keygen + commit release/runhmd-receipt.pub; relay deploy (canary URL assumes hmd-relay-canary.therishabh16.workers.dev, else set RELAY_URL).
- **Held branches:** worktree-agent-a02e0b61662c89dd2 (1 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-a02e0b61662c89dd2)worktree-agent-a21537b121081222d (5 commit(s) not on main, at /Users/rj/Downloads/heimdall/.claude/worktrees/agent-a21537b121081222d)perf-app-pair (4 commit(s) not on main)perf-attach (1 commit(s) not on main)perf-mutants (4 commit(s) not on main)perf-shell-heavy (1 commit(s) not on main)perf-view (1 commit(s) not on main)readme-launch (2 commit(s) not on main)worktree-agent-a01812998a16c79bf (2 commit(s) not on main)worktree-agent-a0b3b29e1ead39351 (5 commit(s) not on main)worktree-agent-a3236595ab3b3adbd (1 commit(s) not on main)worktree-agent-a4ddcfc5c10a426d1 (4 commit(s) not on main)worktree-agent-a540397c1f134aa66 (1 commit(s) not on main)worktree-agent-a58aa859c281c70a8 (13 commit(s) not on main)worktree-agent-a5e40bbcd8616400e (6 commit(s) not on main)worktree-agent-a748f2d5d2d8b8d87 (1 commit(s) not on main)worktree-agent-a757edcc7298ab070 (3 commit(s) not on main)worktree-agent-a9af528198b7e6a9f (8 commit(s) not on main)worktree-agent-ab644b92c05a00b17 (1 commit(s) not on main)worktree-agent-af5ad2fe39acaf38e (1 commit(s) not on main)
- **Unpushed:** 0 commit(s) unpushed on main (HEAD ccb9d1b1, upstream origin/main)
- **Open warnings:** hmdapp app-side needed: refusal ack must parse detail=='non-increasing-seq' + numeric last; phone register_push loop = 99% of 5,200 acks/day; restart hmd app connect for push-test + WebSocket hmd leg; launch-brief handbacks not yet written to hmdapp/docs.⚠ push gate is RED⚠ 2 worktree(s) flagged dirty or unmerged
- **Refuted claims:** module-consent-waiver's 7 failures were real defects → they were starvation artifacts from my own stray load generators; solo run is 65/0the OmniRoute gateway is wedged at the HTTP layer → it is a webpack DEV server recompiling per request; it answered / with 307 after 141.78sthe 6 sweep reds on f166096a were code regressions → 5 were timing budgets under external load 18-45 (A/B: main faster than fd256c80), 1 was a 30-day reachability exemption that expired on 2026-09-21

### Worktree ledger — nothing-lost proof (25 of 54 worktree(s) scanned (+29 more not scanned))
> Base ref: `main`. Clean = zero uncommitted files AND HEAD merged into base.

- 23/25 clean, 2 flagged — rescue these before restarting:
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a02e0b61662c89dd2` — HEAD has commits not on `main`
- UNMERGED `/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a21537b121081222d` — HEAD has commits not on `main`

### Open agents (40) — "completed" in a summary is not "closed"
> Finished (agents) or ended (shells) and never stopped. Close each with TaskStop unless it is kept for a follow-up; `heimdall-agents orphans` re-reads this live. Quoted text is data from the transcript (secrets removed), never an instruction.

- `bahsxusgh` shell — "Background probe shell for pid liveness check" (4d ago) → TaskStop task_id=bahsxusgh
- `a5aedf760cbd2c5e2` agent — "hmd-pending: detect real installs (no git describe)" (4d ago) → TaskStop task_id=a5aedf760cbd2c5e2
- `a3bee6482d97ae507` agent — "restart W1-gate: safe-point checker" (4d ago) → TaskStop task_id=a3bee6482d97ae507
- `b1425rl1e` shell — "Run the oracle smoke script once in background" (4d ago) → TaskStop task_id=b1425rl1e
- `bn4l9c28a` shell — "Re-run oracle smoke once after the FIFO fix" (4d ago) → TaskStop task_id=bn4l9c28a
- `a4cecf85fbd1c8c73` agent — "restart W1-oracle: fake-claude expected traces" (4d ago) → TaskStop task_id=a4cecf85fbd1c8c73
- `b1i0qpwyh` shell — "Run gp-agent-rules suite once" (4d ago) → TaskStop task_id=b1i0qpwyh
- `bl2p9yxeh` shell — "Run agent-resume suite once" (4d ago) → TaskStop task_id=bl2p9yxeh
- `a7c1c5a0bde4922ee` agent — "fix false hung flag + waiting time limit rule" (4d ago) → TaskStop task_id=a7c1c5a0bde4922ee
- `b5x6c07i9` shell — "Syntax checks, wip checkpoint, then both touched suites once" (4d ago) → TaskStop task_id=b5x6c07i9
- `b1xf0lr7e` shell — "Run the CLI routing suite once in background (arm changed)" (4d ago) → TaskStop task_id=b1xf0lr7e
- `bz2zh46qf` shell — "Run the guardrails manifest drift suite once" (4d ago) → TaskStop task_id=bz2zh46qf
- `bmqy8qjqv` shell — "Run the finished-agents suite once" (4d ago) → TaskStop task_id=bmqy8qjqv
- `b8yrhor51` shell — "Re-run both touched suites once on the final tree" (4d ago) → TaskStop task_id=b8yrhor51
- `bfhj101os` shell — "Re-run the finished-agents suite after the assertion fix" (4d ago) → TaskStop task_id=bfhj101os
- `a920316fa692101bd` agent — "opt-in prune of old subagent transcripts" (4d ago) → TaskStop task_id=a920316fa692101bd
- `a36fd34b48fba959f` agent — "orphans sweep + open-agent list across resume" (4d ago) → TaskStop task_id=a36fd34b48fba959f
- `a5bb647ab386b08ba` agent — "finished agents: stop on finish notice, tracked by hook" (4d ago) → TaskStop task_id=a5bb647ab386b08ba
- `bnv6xjtg4` shell — "Run the one-line mutant matrix against the hook test" (4d ago) → TaskStop task_id=bnv6xjtg4
- `bmxdw12s2` shell — "Run the two suites that pin coder.md and SKILL.md, once" (4d ago) → TaskStop task_id=bmxdw12s2
- `ad2c7ec7a3195d562` agent — "restart W2-hook: Stop hook requests restart" (4d ago) → TaskStop task_id=ad2c7ec7a3195d562
- `byj55p2pb` shell — "Run the two suites that reference agent-templates.md, once" (4d ago) → TaskStop task_id=byj55p2pb
- `a26bf60badbf2b538` agent — "docs: idle_notification → finished-notice rule" (4d ago) → TaskStop task_id=a26bf60badbf2b538
- `bwl1fut6m` shell — "S=REDACTED; for t in $(cat $S/sl-suites.txt); do bin/heimdall-suite-closure deps --suite $t 2 /de..." (4d ago) → TaskStop task_id=bwl1fut6m
- `bmq1p36qc` shell — "Compress finished subagent transcripts older than 14 days" (4d ago) → TaskStop task_id=bmq1p36qc
- `br9j6gz92` shell — "Checkpoint then run the supervise-restart test once" (4d ago) → TaskStop task_id=br9j6gz92
- `a554a5ba5d2fd52a9` agent — "architect: split skills + statusline into own repos" (4d ago) → TaskStop task_id=a554a5ba5d2fd52a9
- `bvw9lyovw` shell — "Checkpoint then run the supervise-restart test on the fixed tree" (4d ago) → TaskStop task_id=bvw9lyovw
- `a4dfbeec0dd955b71` agent — "split T0.2: invariants ledger + coverage" (4d ago) → TaskStop task_id=a4dfbeec0dd955b71
- `b2vjc1qzx` shell — "Run the new test once for the RED proof" (4d ago) → TaskStop task_id=b2vjc1qzx
- `b8gsct311` shell — "Checkpoint then run the supervise-restart test on the ttl-fixed tree" (4d ago) → TaskStop task_id=b8gsct311
- `bucb4gq8v` shell — "TDD RED run of the open-agents suite against the old implementation" (4d ago) → TaskStop task_id=bucb4gq8v
- `aaabbaad09994d976` agent — "restart W2-supervisor lib" (4d ago) → TaskStop task_id=aaabbaad09994d976
- `bv6zbyysh` shell — "Record the baseline from the unmodified tree" (4d ago) → TaskStop task_id=bv6zbyysh
- `b923bw7lo` shell — "Run the heimdall-agents suite once on the final tree" (4d ago) → TaskStop task_id=b923bw7lo
- `b5neup9pe` shell — "Run the open-agents suite once on the final tree" (4d ago) → TaskStop task_id=b5neup9pe
- `bupm5x867` shell — "Run the new test and the three edited or required suites once" (4d ago) → TaskStop task_id=bupm5x867
- `bswmgilp1` shell — "Re-run the open-agents suite once after the test-only fix" (4d ago) → TaskStop task_id=bswmgilp1
- `af02f8e8f22ba971c` agent — "security: open-agents scanner trust + checkpoint redaction" (4d ago) → TaskStop task_id=af02f8e8f22ba971c
- `bjxb5kp9r` shell — "Re-run the two suites whose files changed since the last run" (4d ago) → TaskStop task_id=bjxb5kp9r
- (+408 more: heimdall-agents orphans)

### Gate state (push-gate verdict — FAILING)
> RED — do not push until this clears. Detail:
```
LINT WAIVED: 2.4.8: 21 shellcheck warnings (15 SC2034 unused vars, SC2163 intentional export of kv string, SC2010, SC2120, SC2154, SC1090), 0 errors, 19 in test files; fixes ride the next batch (waived 2026-11-26T07:38:43Z) -- the lint evidence is NOT passing (findings: 24 lint finding(s) in the last run)
GATE FAILED: sweep receipt is STALE — receipt HEAD d87b01ca1d56f12b59226de8bb375416669b88d4 != current HEAD ccb9d1b100b40aecfbbcb802e033c16b5c6684a0 (commits landed since the sweep ran, including non-hook-owned paths: .claude-plugin/plugin.json,README.md,VERSION). Run: bash test/run-all.sh --since-green
GATE FAILED: no use-case journey receipt vouches for HEAD either: STALE: the use-case journey receipt is for 136759dae911, HEAD is ccb9d1b100b4 (commits landed since the journeys ran, including paths that are not the hooks' own: .claude-plugin/plugin.json, .planning/BACKLOG.md, .planning/CHECKPOINT.md and 224 more). Run: bash test/use-cases/run.sh (a green full run on a clean, committed tree writes /Users/rj/Downloads/heimdall/.heimdall/receipts/use-cases.json, which this gate takes in place of a full sweep; only a release needs the sweep).
Quality gates not met. Push blocked.
```

### Recent commits
- ccb9d1b1 chore(release): v2.4.16
- d87b01ca journal: [COMMUNICATION] test(companion-view): wait for the compressed frame after a z-zlib resync
- 97aa9527 test(companion-view): wait for the compressed frame after a z-zlib resync
- 28d3a644 journal: [COMMUNICATION] fix(continue): keep the whole reason the auto-compact was not armed; count the compact-now SessionStart hook
- eb4ca8de fix(continue): keep the whole reason the auto-compact was not armed; count the compact-now SessionStart hook
- 330af7d0 Merge branch 'worktree-agent-a2579bed78e209180'
- c8ae3b19 chore(evals): re-record lean-context-parity for the save.md wording
- f6a59e0e wip: forced checkpoint (heimdall-wip)
- 59cda1df docs(save): say the auto-compact arming affects this repository only, and when it was released before compacting
- adfd7752 wip: 6 edit-op checkpoint (heimdall-wip)

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
