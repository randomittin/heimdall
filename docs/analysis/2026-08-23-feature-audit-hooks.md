# Feature audit: hooks/hooks.json + skills/

**Date:** 2026-08-24 (session started 2026-08-23)
**Repo:** heimdall, audited at main tip `71bd0b7`, from an isolated worktree
**Ask (verbatim, repo owner):** "it's to ensure all features announced are actually working."
**Scope:** every entry in `hooks/hooks.json` (22 top-level entries / 6 events), every skill in `skills/` (5 skills).
**Rule:** report, don't fix. Nothing below is marked WORKS without execution evidence.

## Method

- **Registered vs. fires.** Appearing in `hooks/hooks.json` proves a hook is wired, nothing else. Verdicts here are
  earned by one of: a live, freshly-run command this session (`FIRES`, evidence says "live-verified" or quotes real
  output); an on-disk artifact whose content/mtime could only exist if the hook ran for real, e.g. git commit
  history, `.planning/` state, an orphan branch (`FIRES`, evidence names the artifact); a dispatch path confirmed by
  reading source plus a plausible/correct reason it wasn't independently proven this session, usually because
  proving it live would mutate shared state or was excluded on safety grounds (`LIKELY-FIRES`); checked for
  evidence and found none (`REGISTERED-NOT-FIRED` — this bucket is split further below into "correctly idle by
  design" vs. "genuinely unproven"); or excluded from live execution entirely on safety grounds, so simply
  unverified either way (`NOT VERIFIED`).
- **Skill invocations were counted structurally, not by grep.** `find ~/.claude/projects -name '*.jsonl'` → 1,913
  transcripts → prefiltered to 64 files containing the literal substring `"Skill"` (a zero-false-negative filter:
  every genuine `Skill` tool_use record contains that exact quoted substring) → one `jq` pass extracting
  `select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill`
  across all 64 → 73 total invocations, 19 distinct skill names, tallied. Grep hit-counts were never used as
  evidence (a prior audit found 15 grep "hits" that were quoted file content, not real invocations).
- **Safety observed throughout:** no push, no `test/run-all.sh`, no `claude -p`, no destructive/networked bin run
  live (`heimdall-cleanup --auto`, `heimdall-team auto`, `heimdall-presence beat/keeper-start/connect-prompt`,
  `heimdall-reap-idle` — the last excluded specifically because this shared environment had other real concurrent
  agents running whose state it could have disturbed). Where a bin was safe to run for real (session-scoped state,
  or pure read/advisory logic), it was run for real with output discarded (`>/dev/null 2>&1`) and alarm-wrapped
  (`perl -e 'alarm N; exec @ARGV' --`, since `timeout`/`gtimeout` are both absent on this machine) rather than
  guessed at from source alone.
- Two background sub-agent attempts at the SessionStart section crashed from context-window exhaustion
  (autocompact thrashing) even after being re-scoped once with explicit output-bounding instructions; rather than
  retry a third time with the same failing shape, that section was completed directly, one single-purpose,
  output-discarded command at a time.

## Table 1 — Hooks

22 top-level `hooks.json` entries decompose into 45 independently-verifiable sub-behaviors (several entries chain
multiple distinct commands with materially different evidence). Grouped by event/entry below.

### UserPromptSubmit (2 entries)

| Entry | Command | Exists? | Evidence of firing | Latency | Verdict |
|---|---|---|---|---|---|
| 1 | `bin/parallel-gate` | Y | Live stdin test reproduced the exact `hookSpecificOutput` JSON for a multi-part prompt. Pure stdout filter — zero file writes by design (full source read; corrects an earlier hypothesis that it wrote to `metrics.jsonl`, which is false). No artifact is possible by design, so absence of one is not evidence against firing. | not measured (not a SessionStart entry) | **FIRES** (live-verified) |
| 2 | `bin/heimdall-ctx-meter notice` | Y | `do_notice()`: silent when below the context ceiling — silence is correct behavior, not failure. Dispatches unconditionally every prompt. | not measured | **LIKELY-FIRES** |

### PreToolUse (5 matchers, 14 sub-behaviors)

| Matcher | Sub-behavior | Command | Exists? | Evidence of firing | Verdict |
|---|---|---|---|---|---|
| `Bash` | git-verb guard | `heimdall-git-guard` | Y | No git-verb Bash command ran in the checked session window — a session-scoped check only, **not** proof this never fires historically (the repo's whole workflow is agents running `git add`/`git commit --no-verify` constantly). | REGISTERED-NOT-FIRED (caveat: session-scoped check only) |
| `Bash` | secret scan on commit | `secret-scan` | Y | No `git commit` ran in the checked session window — same caveat. | REGISTERED-NOT-FIRED (caveat: session-scoped check only) |
| `Bash` | push: quality-gate chain | `heimdall-state check-quality-gates` → `secret-scan --require` → `heimdall-selfscan` | Y | Push is correctly never attempted (forbidden by this audit's own safety rules) — never fires, by design. | REGISTERED-NOT-FIRED (expected — push never exercised) |
| `Bash` | push: native-hook dedup guard | inline `core.hooksPath`/`.heimdall/hooks/pre-push` check | n/a (inline) | `core.hooksPath=.heimdall/hooks` but `.heimdall/hooks/` is **absent** in this fresh worktree → dedup evaluates false → inline fallback would run. This is CLAUDE.md's own documented expected behavior for a fresh worktree ("coverage unchanged, inline check still runs") — a working fallback, not a bug. | **LIKELY-FIRES** (as designed) |
| `Bash` | push: oracle falsify loop | `falsify` | Y | Run directly (permitted; push itself was not): `changelog-bash32` golden PASS, mutant KILLED, score 1.0000. | **FIRES** (mechanism proven) |
| `Bash` | push: corpus regression | `corpus run` | Y | Run directly: 13/13 caught, 100%; wrote `evals/corpus/CORPUS-STATUS.md` (41 lines, real). `git status --short` immediately after came back completely empty — no residue left in the tree. | **FIRES** (mechanism proven) |
| `Bash` | parallelism tracking (always) | `parallelism-tracker check Bash` | Y | Live state file `$TMPDIR/heimdall-parallel/default.state` (+ `.lock`), mtime today. | **FIRES** |
| `Read\|Grep\|Glob` | parallelism tracking | `parallelism-tracker check <tool>` | Y | Same state file, updated in real time by this audit's own Read calls. | **FIRES** |
| `Agent` | named-agent notice (advisory) | `heimdall-precheck-agent` | Y | 69 distinct transcripts match the notice string; 43 match "mailbox-resident" (targeted literal check, not a grep-as-evidence count). Confirmed: warns on stderr, `allow(){ exit 0; }` — never blocks. | **FIRES** |
| `Agent` | brief-adoption gate (real deny path) — **not in original scope, found during audit** | `heimdall-precheck-agent` (separate code path, same script) | Y | Source-confirmed real `exit 2` + prompt rewrite via `hookSpecificOutput.updatedInput` for the NON_VERIFIED case. Not exercised this session (no Agent spawn triggered it). **Important: this is a genuinely different code path from the named-agent notice above — "the named-agent notice never blocks" is true and confirmed; "heimdall-precheck-agent never blocks" would be false.** | **LIKELY-FIRES** |
| `Write\|Edit` | stub-shape scanner | `bin/lib/heimdall-stub-patterns.sh` | Y | Functional test run live: a `pass`-only function body was correctly flagged. | **FIRES** |
| `Edit\|MultiEdit\|Write` | wip-commit checkpoint | `heimdall-precheck-edit` → `heimdall-wip-commit` | Y | `.planning/ledger/checkpoints` holds 61 real entries. | **FIRES** |
| `Edit\|MultiEdit\|Write` | claim-ledger collision warning — **not in original scope, found during audit** | `heimdall-precheck-edit` → `heimdall-claim` | Y | `.planning/ledger/{claims,collisions,conflicts}` all populated with real entries. | **FIRES** |
| `Edit\|MultiEdit\|Write` | worktree-hooks-gap self-heal — **not in original scope, found during audit** | `heimdall-precheck-edit` → `heimdall-hooks-link` | Y | Explains the live gap found above (`core.hooksPath` set, `.heimdall/hooks/` absent in this worktree). | **LIKELY-FIRES** |

### PostToolUse (4 matchers, 6 sub-behaviors)

| Matcher | Sub-behavior | Command | Exists? | Evidence of firing | Verdict |
|---|---|---|---|---|---|
| `Bash` | corpus failure capture | `corpus-capture` | Y | Confirmed no-op **by design**: only acts on a `report.json` with `status=="fail"`; zero `report.json` anywhere in the worktree right now (each oracle generates one transiently on demand). Correctly idle, not broken. | REGISTERED-NOT-FIRED (legitimate no-op) |
| `Write\|Edit\|MultiEdit\|NotebookEdit` | edit logging | `edit-tracker log` | Y | Live-run by the auditor: `edit-tracker log Read bin/parallel-gate` → "1 files, 1 operations … [ok]". | **FIRES** (live-verified) |
| `Write\|Edit\|MultiEdit\|NotebookEdit` | dirty-state marking | `heimdall-state mark-dirty` | Y | Dispatch confirmed in source; `heimdall-state.json` currently reads `dirty:false/idle` — a default snapshot, not proof of a recent mutation (correctly not run live: shared cwd-relative file). | **LIKELY-FIRES** |
| `Write\|Edit\|MultiEdit\|NotebookEdit` | auto-checkpoint commit | `heimdall-autocommit "auto-checkpoint"` | Y | **12 real `heimdall: auto-checkpoint (N files)` commits found in git history** (`db0d0a3`, `d6e661d`, `35830f9`, +9 more) — historical evidence beyond this session. | **FIRES** |
| `Write\|Edit` (backgrounded) | context sync | `heimdall-context-sync sync` | Y | Dispatch + exact call-site args confirmed in source. Correctly not run live (writes inside the repo). No sync/throttle marker artifact found. | **LIKELY-FIRES** |
| `Bash` | journal commit | `heimdall-journal-hook commit` | Y | `.planning/journal/` holds 4 real files spanning 2026-08-18 to 2026-08-23. | **FIRES** |

### SessionStart (8 entries, 12 sub-behaviors) — none of the 8 entries gate on `.source`

Confirmed directly by reading all 8 raw command strings: **zero** reference `.source` from the hook's stdin JSON.
Every one of these re-fires identically on a mid-session resume or compaction, not just cold start.

| Entry | Sub-behavior | fg/bg | Exists? | Evidence of firing | Latency (real, measured) | Verdict |
|---|---|---|---|---|---|---|
| 1 (mega-chain) | `edit-tracker clear`+`init` — **unconditional** | fg | Y | **Live, this session**: a SessionStart:compact fired "Edit ledger cleared." Confirms the known-broken shape: no `.source` gate means a resume/compact wipes a populated ledger. (This session's ledger happened to be empty already, so nothing was actually lost this time — but the unconditional fire is proven live.) | 0.004s | **FIRES** |
| 1 | `stack-pack detect` (conditional) | fg | Y | `.planning/detected-stack.json` exists, mtime 24 Aug 08:34 — same day as this audit. Not re-run live (would mutate real repo state for a marginal gain). | not re-measured | **FIRES** (artifact evidence) |
| 1 | `heimdall-cleanup --advise` | fg | Y | Dispatch confirmed + live-timed. | 0.011s | **FIRES** |
| 1 | statusline-register, pin-notice, parallelism-tracker/edit-tracker compile-guards, `heimdall-state init`, `heimdall-reap-idle` | fg | Y (all) | Dispatch+existence confirmed only. Not individually run live: `heimdall-state init` touches the shared `heimdall-state.json`, `statusline-register` touches shared statusline config, and `heimdall-reap-idle` could have reaped other real concurrent agents in this shared environment — all declined on safety grounds. | not measured (pattern from the 6 bins actually timed suggests sub-100ms each; this is an inference, not a measurement) | **LIKELY-FIRES** |
| 1 | `heimdall-autoupdate check`, `heimdall-cc-selfheal check`, `heimdall-team auto`+`heimdall-presence beat` subshell, `heimdall-cleanup --auto` | bg | Y (all) | Backgrounded and/or destructive/networked — not run live by rule. Non-blocking by nature regardless. | n/a (backgrounded) | **NOT VERIFIED** (excluded by safety rules) |
| 2 | `heimdall-resume-probe run` | fg, 10s native alarm | Y | **Live, this session**: "[heimdall] resume probe GREEN — 6/6 never-lose categories recovered … Streak: 100 green" on SessionStart:compact. Strongest evidence in this table. | not re-timed (own native 10s cap; returned promptly live) | **FIRES** |
| 3 | `heimdall-maintain-loop resume-hint` | fg, no native timeout | Y | Dispatch+existence confirmed; live-timed (output discarded, so content unconfirmed, only that it ran and returned). | 0.067s | **LIKELY-FIRES** |
| 4 | `heimdall-quota-resume resume-hint` | fg, no native timeout | Y | **Mechanism traced**: `heimdall-quota-resume` is one of only 4 bins in `bin/` that reference `bin/heimdall-agent-resume` internally — precisely the source of the "3 INTERRUPTED SUBAGENT(S) found" notice observed live this session (corrects an initial guess that this came from `heimdall-maintain-loop`, which does not reference it at all). | 0.035s | **FIRES** (live-observed + mechanism traced) |
| 5 | `heimdall-dream-notice` | fg, no native timeout | Y | Dispatch+existence confirmed, live-timed. | 0.028s | **LIKELY-FIRES** |
| 6 | `heimdall-presence keeper-start` | bg | Y | Not run live — starts a persistent daemon that could collide with other real concurrent agents in this environment. Observe-only. | n/a (backgrounded) | **NOT VERIFIED** (excluded by safety rules) |
| 7 | `heimdall-presence connect-prompt` | fg, no native timeout | Y | Not run live — presence/networked. Observe-only. | not measured (declined — network risk) | **NOT VERIFIED** (excluded by safety rules) |
| 8 | `heimdall-ai-select session-start` | fg, no native timeout | Y | Dispatch+existence confirmed, live-timed. | 0.009s | **LIKELY-FIRES** |

**SessionStart latency — honest accounting:** directly measured (real, output-discarded, alarm-wrapped):
0.004 + 0.011 + 0.067 + 0.035 + 0.028 + 0.009 = **0.154s summed across 6 timed foreground bins**. Entry 2
(resume-probe) is excluded from that sum — it carries its own native 10s alarm and returned promptly live, but
wasn't independently re-timed to avoid a redundant real probe run. Entry 1's remaining ~5 foreground sub-steps and
entries 6–7 (presence) were not measured, for the safety reasons stated in the table; every bin actually measured
came back under 70ms, so the unmeasured remainder is *likely* small — except the two presence entries, which may
involve socket/network I/O and are the single largest unknown in the total. **A fully-measured, single total number
cannot be honestly quoted without either running the presence entries live or reconstructing and running entry 1's
full mega-chain (which would also trigger its destructive backgrounded sub-steps) — both against this audit's
safety rules.** What can be said: the measured floor is ~0.15s, and it is very likely still well under 1s in the
common case — consistent with a prior session's report of cutting the total from ~5.5s by moving statusline work
off the synchronous path.

### SubagentStop (1 entry)

| Command | Exists? | Evidence of firing | Latency | Verdict |
|---|---|---|---|---|
| `heimdall-metric-hook stop` | Y | `.planning/metrics.jsonl` tail shows live records through `2026-08-23T20:48:06Z` with `"source":"subagentstop"`. `outcome` is correctly `null`, not a fabricated `"pass"` — source comment documents this was removed 2026-08-23 after being found to poison the one number self-improve/dream routes on (an agent killed by a session limit is not a pass). Wiring commit `6e8ad61` confirmed in git log. | not measured | **FIRES** |

### SessionEnd (2 entries, 10 sub-behaviors)

| Entry | Sub-behavior | fg/bg | Exists? | Evidence of firing | Verdict |
|---|---|---|---|---|---|
| 1 | `heimdall-presence keeper-stop` | fg | Y | Trivial, low-risk; not deeply probed. | **LIKELY-FIRES** |
| 2 | `heimdall-checkpoint write` | fg | Y | Guard is satisfiable (`.planning/` + `heimdall-state.json` both exist) but `CHECKPOINT.md` is **absent** from the worktree. | REGISTERED-NOT-FIRED |
| 2 | `parallelism-tracker grade` | fg | Y | Run live: "82 batched/268 turns, ratio 0.31, 402 calls." | **FIRES** |
| 2 | `verify-edits --quick` | fg | Y | Run live: "ledger present, 0 edits." | **FIRES** |
| 2 | `heimdall-autocommit "session-end checkpoint"` | fg | Y | 73× "session-end checkpoint" commits found in `git log --all` (repo-wide). | **FIRES** |
| 2 | `heimdall-cleanup --auto`/`heimdall-gc`/`heimdall-reap-idle` | bg | Y | Real deletions — excluded from live execution by this audit's own rules. | **NOT VERIFIED** (excluded by safety rules) |
| 2 | `heimdall-reel record` | bg | Y | Guard satisfiable but `.planning/reels/` is **absent**, zero `run-*` artifacts. | REGISTERED-NOT-FIRED |
| 2 | `summary-card --receipt` | bg | Y | stdout-only per source (no disk write) — not independently verifiable without a live run. | **LIKELY-FIRES** (unverifiable by design) |
| 2 | `heimdall-context-sync sync` | bg | Y | The `hmd/context` orphan branch exists with a real commit `77a7da4c`. | **FIRES** |
| 2 | `sentinels/hmd-farewell.sh` | fg | Y (8231 bytes, executable) | stdout-only per source — not independently verifiable without a live run. | **LIKELY-FIRES** (unverifiable by design) |

**Big flag — the SessionEnd timeout is fake safety.** `command -v timeout` and `command -v gtimeout` both fail
(`rc=1`, confirmed absent on this machine). The hook's own `_hmd_to()` wrapper falls back to `else "$@"` when
neither exists — meaning the *entire* foreground SessionEnd chain (`heimdall-checkpoint write` → `parallelism-tracker
grade` → `verify-edits --quick` → `heimdall-autocommit`) runs with **zero actual time bound**, despite the code
visibly claiming a 10-second cap. This is a textbook announced-feature-that-doesn't-do-what-it-says: any one of
those four commands hanging blocks session-end teardown indefinitely, silently, on this machine.

## Table 2 — Skills

| Skill | References valid? | Ever invoked? | Verdict |
|---|---|---|---|
| `designmatch` | Yes — 6/6 referenced files present. `iterate-screen.sh` passes `bash -n`. 4 `.js` files + `visual-qa.ts` could not be syntax-checked — this sandbox has no working `node`/`tsc` (a tooling gap in the audit environment, not a confirmed script defect). | **No** — 0 invocations across 1,913 transcripts | VALID, **NEVER INVOKED** |
| `heimdall` | **No — 6/7.** `SKILL.md`'s "Full Specification" section links `../../docs/conversation-context.md`, which does not exist anywhere in the repo. | **No** — 0 invocations | **BROKEN REFERENCE**, never invoked |
| `self-improve` | Yes — 8/8 | Yes — 1 invocation (rare) | WORKS, rarely used |
| `stacks` | Yes — 7/7 | **No** — 0 invocations | VALID, **NEVER INVOKED** |
| `system-health` | Yes — 5/5 | Yes — 2 invocations (rare) | WORKS, rarely used |

Cross-checked: every SKILL.md's `name:` frontmatter matches its bare directory name exactly, and the live
enabled-skills listing confirms these 5 are actually invoked in `hmd:<name>` plugin-namespaced form — so the
zero-count skills were searched for under the correct real invocation string, not a guessed one. No binary/image/
font files exist anywhere in the 5 skill trees. All 5 are at least referenced in project docs
(`docs/analysis/*.md`/`.planning/*.md`), i.e. someone has written *about* all five, independent of live use.

**Calibration check** (task brief's figures were measured against a 1,103-transcript corpus; this audit's corpus
has grown to 1,913): `claude-code-setup:claude-automation-recommender` → 0 hits, exact match to the brief's "~0".
`mem-search` → 2 bare + 1 `claude-mem:mem-search` = 3 total, vs. the brief's "exactly one" — does not reproduce the
exact count but reproduces the right bucket (rare-but-nonzero, nowhere near the dozens the TDD/debugging skills
show), consistent with real corpus growth rather than a methodology failure.

## Summary counts

- **Hooks:** 22 top-level `hooks.json` entries → 45 independently-verified sub-behaviors.
  - **FIRES:** 22 (live-verified or artifact-proven)
  - **LIKELY-FIRES:** 13 (dispatch-confirmed, correct behavior inferred, not independently artifact-proven — usually because proving it live would require mutating shared state)
  - **REGISTERED-NOT-FIRED:** 6 (see explicit list below)
  - **NOT VERIFIED (excluded by safety rules):** 4 — backgrounded/destructive/networked bins never run live: `heimdall-team auto`+`heimdall-presence beat` subshell + `heimdall-autoupdate check` + `heimdall-cc-selfheal check` + `heimdall-cleanup --auto` (SessionStart entry 1), `heimdall-presence keeper-start` (SessionStart entry 6), `heimdall-presence connect-prompt` (SessionStart entry 7), `heimdall-cleanup --auto`/`heimdall-gc`/`heimdall-reap-idle` (SessionEnd entry 2)
- **Skills:** 5 audited. References valid: 4/5. Broken reference: 1/5 (`heimdall`). Ever invoked: 2/5 (`self-improve`, `system-health`, both rare). Never invoked: 3/5 (`designmatch`, `heimdall`, `stacks`).

### Explicit list — registered but never fired (evidence checked, none found)

1. **PreToolUse Bash — `heimdall-git-guard`** on git-verb commands. No git-verb Bash command ran in the checked session window. *Caveat: session-scoped check only — every coder agent in this repo runs `git add`/`git commit --no-verify` constantly, so this is very likely to fire elsewhere; absence of evidence here is not strong evidence of absence.*
2. **PreToolUse Bash — `secret-scan`** on `git commit`. Same caveat as above (no commit made in the checked window).
3. **PreToolUse Bash — push quality-gate chain** (`heimdall-state check-quality-gates` → `secret-scan --require` → `heimdall-selfscan`). Never fires because push was correctly never attempted — expected, not a defect.
4. **PostToolUse Bash — `corpus-capture`**. No-op by design: it only acts on a `report.json` with `status=="fail"`, and none exist in the worktree right now. Correctly idle, not broken.
5. **SessionEnd — `heimdall-checkpoint write`**. Guard is satisfiable but `CHECKPOINT.md` is absent from the worktree — genuinely unproven, not an obvious by-design no-op like #3/#4.
6. **SessionEnd — `heimdall-reel record`**. Guard is satisfiable but `.planning/reels/` is absent with zero `run-*` artifacts — same caveat as #5.

Items 3 and 4 are correctly-idle-by-design and should not be read as broken. Items 1–2 are session-scoped blind
spots, not confirmed-absent. Items 5–6 are the two genuinely open "might never actually fire" findings in this
audit — distinguishing "never fired" from "fired but its write is silently swallowed" would require live execution
this audit's safety rules exclude.

## Notable findings

1. **SessionEnd's advertised 10-second timeout does nothing on this machine.** `timeout`/`gtimeout` are both
   absent; the fallback silently runs the whole foreground chain unbounded. See the SessionEnd section above.
2. **SessionStart's `edit-tracker clear` is unconditional and ungated on `.source`, confirmed live** — a
   mid-session resume/compact wipes a populated edit ledger. None of the other 7 SessionStart entries gate on
   `.source` either, so this exposure pattern (re-fire-on-resume, not just cold start) is universal across all 8,
   not unique to the edit-tracker entry.
3. **3 of 5 audited skills have never been invoked**, ever, across 1,913 observed transcripts (`designmatch`,
   `heimdall`, `stacks`) — despite all having valid frontmatter and (for `designmatch`/`stacks`) fully valid
   references. "Announced but never used."
4. **`skills/heimdall/SKILL.md` has a broken reference** to `docs/conversation-context.md`, which does not exist.
5. **`heimdall-precheck-agent` has a real `exit 2` deny path (brief-adoption gate) distinct from the named-agent
   notice.** The named-agent notice itself is confirmed advisory-only (stderr + always `exit 0`) — but the blanket
   claim "`heimdall-precheck-agent` never blocks" would be false. Two different code paths in the same script.
6. **3 mechanisms were found beyond the original audit brief**, none previously documented in the task's own hook
   inventory: a claim-ledger collision warning, a worktree-hooks-gap self-heal (which explains why this fresh
   worktree's native pre-push hook isn't wired — `core.hooksPath` is set but `.heimdall/hooks/` doesn't exist here
   yet), and the brief-adoption deny path in finding #5.
