# Feature Audit — Slash Commands & Agent Definitions

**Repo:** `/Users/rj/Downloads/heimdall` · **Audited at:** `71bd0b7c5c0f34ca873d73f34f8ae0f16ee45ba8` (fast-forwarded from a stale `b5ed53b` worktree tip before auditing — 97 files, 12179 insertions changed in between)
**Scope:** every file in `commands/*.md` (18) and `agents/*.md` (16)
**Ask (verbatim, from the repo owner):** *"it's to ensure all features announced are actually working"*
**Method:** live execution wherever safe; source-trace + diff where live execution would violate the hard safety rules (no push, no PR, no real GitHub issue, no `claude -p`, no paid API). Nothing below is marked WORKS without a command run or a quoted diff/grep behind it. Unverified items are marked UNTESTED, PARTIAL, or UNSAFE-TO-TEST with the specific reason.

---

## ⚠ Operational incident surfaced during this audit (read before the findings)

Executing `bin/heimdall-invite` (documented in `commands/invite.md`) as part of "execute what is safe to execute" printed a **real, live `HEIMDALL_TEAM_SECRET` credential** into this audit session's tool output/transcript, inside a shareable shell one-liner, with the tool's own on-screen warning ("⚠ contains your team secret — share only with teammates") displayed alongside it.

This is **documented, intended tool behavior, not a code defect** — `invite`'s entire purpose is to hand a teammate a working join command, which structurally requires emitting the real secret at least once. The mistake was mine: I did not recognize before executing it that *any* live run of this specific command necessarily emits a live credential, and "safe to execute" should have excluded it the way filing a real GitHub issue was excluded.

Constraints I have held since noticing this, and am reporting explicitly rather than quietly working around:
- The literal secret is **not** reproduced anywhere in this report or any other file I've written.
- I have **not** attempted to rotate, revoke, or otherwise touch the secret — that decision belongs to the repo owner, not to an audit agent.
- I am surfacing this prominently, separately from ordinary audit findings, in both this document and my final status message.

**Recommended follow-up (not performed by me — outside audit scope):** the repo owner should treat the value that was printed during this session as potentially exposed and decide whether to re-mint it (`bin/heimdall-team new --force`).

---

## Precedent verification (the two cases the task named explicitly)

**Precedent #1 — `commands/maintain.md`'s false `issue_queue` claim.** CONFIRMED FIXED. `git diff b5ed53b..71bd0b7 -- commands/maintain.md` shows the old claim ("GitHub issues normalized by `issue_queue`") replaced with an explicit new section, "This pipeline vs the engine-driven autopilot," stating in so many words that the prose seeker→fixer pipeline "does **not** use `bin/heimdall-issue-queue`," and rewriting Phase 2 step 1 to `gh issue list --label bug --state open` directly, "no `issue_queue` involved." The two systems are now accurately described as separate.

**Precedent #2 — the severed label.** The label-level fix is REAL and verified, but **does not fully explain** the original symptom — this is my own analysis on top of the given precedent, not a restatement of it:
- `git diff` on `agents/seeker.md` confirms `gh issue create --label` changed from `"bug,seeker"` to `"bug,seeker,maintainer"`, with a new paragraph citing `sync_queue_from_github` in `bin/lib/maintain_loop.py` and `gh`'s AND/superset `--label` semantics.
- `bin/lib/maintain_loop.py` confirms `DEFAULT_MAINTAINER_LABEL = "maintainer"` is what the engine's GitHub ingest actually filters on; a new comment there cross-references the fix and `test/heimdall-maintain-loop.test.sh`'s "(20) SEEKER CONTRACT" section (confirmed present).
- **The qualification:** this fix reconnects seeker's issues to the *engine* (`/hmd:maintain-check`, `bin/heimdall-maintain-loop`). It does **not** touch the *prose* fixer's own pickup filter (`gh issue list --label bug` — single label, always satisfied by seeker's issues since they always carried `bug`). `gh`'s AND-match semantics only bite on multi-label filters, and the prose fixer never used one. So the label fix is real and correct for the engine path, but it is very unlikely to be the reason `hmd:seeker`/`hmd:fixer` measured **zero real Agent spawns** in `docs/analysis/2026-08-22-capability-census.md` (432-call corpus, commit `c6bc79d`, 2026-08-22 — cited as prior, dated, measured evidence, not re-derived here). A static grep of the whole repo (`.md`/`.py`/`.sh`, excluding `.git`/`node_modules`/`.heimdall`/`.planning`) found the literal strings `hmd:seeker` and `hmd:fixer` in exactly two places — `bin/heimdall:4104` and `agents/heimdall.md:408` — and both are roster/help-text enumeration lines, never an instructional "spawn this agent" call site. `commands/maintain.md` never writes a literal `Agent(subagent_type:"hmd:seeker")`-shaped instruction anywhere. **Working theory:** the zero-spawn symptom is a separate, still-open usage/invocation gap — the prose command never reliably gets translated into a real spawn call — not something the 2026-08-23 label fix addresses. Recommend re-measuring spawn counts after this fix has had time to accumulate real invocations before declaring the precedent closed.

## Bonus finding — worktree-vs-primary-checkout path resolution defect

Found via direct execution while investigating the engine path above, not part of either given precedent. `bin/lib/issue_queue.py`'s `_repo_root()` (lines ~89–98) walks up from cwd looking for a `.git` **directory**:

```python
def _repo_root(start):
    cur = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start)
        cur = parent
```

A git **worktree**'s `.git` is a *file* (a gitdir pointer), not a directory, so `os.path.isdir` is always `False` there. Because Heimdall nests worktrees under `<primary>/.claude/worktrees/<name>/`, the walk never stops at the worktree root and always lands on the primary checkout instead — **regardless of whether `--repo` was passed explicitly.** Reproduced twice, live, from inside this audit worktree:

```
$ bin/heimdall-issue-loop status --repo .
...  "path": "/Users/rj/Downloads/heimdall/.heimdall/issues/queue.json"   ← primary checkout, not this worktree
$ bin/heimdall-issue-queue status
...  "path": "/Users/rj/Downloads/heimdall/.heimdall/issues/queue.json"   ← same, and --repo wasn't even given
```

Any two worktrees running the issue-queue tooling concurrently are silently sharing (and can race on) the *primary* checkout's queue file, not their own — directly relevant to this task's own stated sandbox-escape concern. Reporting only, per instructions; not fixed.

---

## Table 1 — Slash Commands (`commands/*.md`, 18)

| Command | Claims | Verdict | Evidence |
|---|---|---|---|
| `autocommit.md` | Toggle `.heimdall-no-autocommit` sentinel to disable/enable per-task auto-commit | **WORKS** | Live: `touch .heimdall-no-autocommit && test -f ...` → `toggle-on OK`; `rm -f ... && test ! -f ...` → `toggle-off OK (restored clean baseline)` |
| `autonomy.md` | Get/set `.project.autonomy_level` (1/2/3, `+`/`-` cycle) via `heimdall-state` | **WORKS** | Live: `heimdall-state get '.project.autonomy_level'` → `2`; cross-confirmed by `heimdall-state status`'s own `Autonomy: 2` line |
| `bench.md` | `bin/heimdall-bench` reproduces the public benchmark table; dry = zero API spend + capture plan; live = real tokens | **WORKS** (dry path) | Live: `bin/heimdall-bench --dry` → real 5-task suite, per-task verify-step counts, `"mode: dry (no API calls, nothing captured)"`, documented arm commands shown verbatim. `--live` correctly **UNSAFE-TO-TEST** — spends real API tokens |
| `debloat.md` | Analyze/report repo bloat | **WORKS** | `bin/heimdall-debloat report` executed this session — proven by its own real side effect: `BLOAT-REPORT.md` shows modified in `git status --porcelain` |
| `demo.md` | `--dry` scaffolds a demo task + `.planning/` with no side effects on the real repo | **WORKS** | Live, in an isolated `mktemp -d`: `bin/heimdall-demo --dry` → `ls -la` on the scratch dir confirmed real `.heimdall-demo-task.md` and `.planning/` were created, not just a printed message |
| `designmatch.md` | Match Claude-generated design HTML to React Native at ≥95% visual parity via init/wire/fetch/port/render/diff/iterate/regen | **PARTIAL** | Live: `bin/designmatch --help` → all claimed subcommands present verbatim (init, wire, fetch, port, port-all, render, diff, iterate, regen, regen-all, regen-gate, web). Full pipeline **UNTESTED** — needs a real React Native app fixture, none available; running `init` against a non-RN dir wouldn't exercise real behavior |
| `dream.md` | Overnight autoresearch + maintainer sweep → morning report; "shadow-first, agent-never-pushes" | **PARTIAL** | Live: `bin/heimdall-dream --help` → literally contains `"Shadow-first; agent-never-pushes"`, matching the doc's safety claim verbatim. `bin/heimdall-dream where` → real computed report path. Full `run` **UNSAFE-TO-TEST** — "overnight autoresearch" invokes real Claude/API calls. Side note: `heimdall-dream-schedule status` shows a real, pre-existing macOS LaunchAgent registered and pointed at this audit worktree's path — not created by this audit, flagged only as an observation |
| `feedback.md` | File team feedback as a GitHub issue via `bin/heimdall-feedback`, verbatim words only, `--dry-run` available | **WORKS** | Live: `bin/heimdall-feedback --dry-run "audit test message, safe to discard"` → exact well-formed JSON payload (`title`/`body`/`labels: ["feedback","from-hmd"]`/`repo`), nothing filed. Non-dry-run correctly not run — would file a real issue |
| `invite.md` | Print a shareable join one-liner carrying the team secret, with an on-screen sharing warning | **WORKS — SEE INCIDENT ABOVE** | Behaved exactly as documented, including its own warning. Live execution during this audit printed a real credential into the transcript — see flagged section at top of this report |
| `level.md` | Deprecated alias of `/hmd:autonomy`; prints a rename notice, then behaves identically | **WORKS** (inherited) | Uses the identical `heimdall-state get/set '.project.autonomy_level'` mechanism verified live under `autonomy.md`. No separate bin exists for `level` to break independently; the only unique behavior (the notice line) is static prose |
| `maintain.md` | Prose seeker→fixer pipeline; picks issues directly via `gh issue list --label bug`, explicitly not via `issue_queue` | **WORKS** (precedent #1) | `git diff b5ed53b..71bd0b7` on this file — false claim replaced with an accurate one, new section separating it from the engine. Full live run **UNSAFE-TO-TEST** (real `gh issue create`/PRs); verified via source-trace, not execution |
| `maintain-check.md` | Engine-driven autopilot via `bin/heimdall-issue-queue`/`bin/heimdall-maintain-loop`, GitHub ingest gated on `maintainer` label | **WORKS, QUALIFIED** (precedent #2) | Live: `bin/heimdall-issue-queue status` → real JSON queue state (read-only). Label fix confirmed via diff + `bin/lib/maintain_loop.py` read + `test/heimdall-maintain-loop.test.sh` §20 existing. Qualification: see Precedent #2 section above — reconnects seeker to the engine, doesn't by itself explain historical zero agent-spawns |
| `reflect.md` | Force a reflection pass over unresolved conflicts via `conflict-log unresolved`/`reflect-all` | **WORKS** | Live: `bin/conflict-log unresolved` → `[]` (valid JSON, real execution, no unresolved conflicts currently) |
| `report-bug.md` | File a GitHub issue against the Heimdall plugin repo via `bin/report-issue`, auto-Environment section, requires `gh auth status` | **PARTIAL** | Live: `bin/report-issue --help` → matches doc claims (title/body-file/kind/label/repo flags, auto-Environment section, gh-auth requirement). Full run **UNSAFE-TO-TEST** — would file a real issue |
| `save.md` | Write/update `.planning/STATE.md`, `CHECKPOINT.md`, `settings.json`, then `git add -A && git commit` | **UNTESTED — BY CHOICE** | Pure Claude-native prose, no dedicated bin to probe. Live execution would write multiple new files and force an unrelated git commit into this audit worktree's history — declined for hygiene, not a defect. Prose itself is internally consistent, including an honest self-disclosure that `model_routing.default_code` is advisory-only |
| `status.md` | Show project phase/active agents/quality gates/conflicts via `heimdall-state status` | **WORKS** | Live: `bin/heimdall-state status` → real formatted block (Project/Phase/Autonomy/Quality Gates/Active agents/Conflicts/Sub-projects/Maintainer/Budget/Goal), consistent with the autonomy value confirmed separately |
| `switch-ai.md` | Show/change preferred coding-AI CLI backend, persisted to `.planning/settings.json` | **WORKS** | Live: `bin/heimdall-ai-select current .` → `none` (correct, honest default — no preference set in this worktree) |
| `team.md` | Mint/join/inspect a per-repo team secret; `show` never prints the secret | **WORKS** | Live: `bin/heimdall-team show` → real team_id/mode/owner/visibility/created/store path, plus an explicit `"(the team secret is never printed — see <path>)"` line — verified in direct, deliberate contrast to `invite.md` above |

## Table 2 — Agent Definitions (`agents/*.md`, 16)

*Tier column verified live via `bin/heimdall-tier agents` (all 16 resolve cleanly, zero errors — including `inherit`). Spawn counts are cited from `docs/analysis/2026-08-22-capability-census.md` (432-call corpus, commit `c6bc79d`, dated 2026-08-22 — two days before this audit's tip) as attributed prior measurement, not re-derived. "Definition valid?" cross-checks each declared tool against this session's live Agent-type registry.*

| Agent | Tier | Ever spawned? | Definition valid? | Verdict |
|---|---|---|---|---|
| `coder` | sonnet | Yes — 361/432 (84%) | Yes | **CONNECTED** — dominant workhorse |
| `architect` | sonnet | Yes — 24 | Yes | **CONNECTED** |
| `verifier` | opus | Yes — 12 | Yes | **CONNECTED** (opus matches CLAUDE.md's adjudication-only opus rule) |
| `docs-writer` | sonnet | Yes — 9 | Yes | **CONNECTED** |
| `reviewer` | opus | Yes — 4 | Yes | **CONNECTED**, low volume (opus, adjudication) |
| `test-runner` | sonnet | Yes — 2 | Yes | **CONNECTED**, low volume |
| `security-auditor` | opus | Yes — 1 | Yes | **CONNECTED**, low volume — its own doc honestly notes "no code spawns it for you, the orchestrator has to decide" |
| `design` | sonnet | Yes — 1 | Yes | **CONNECTED**, low volume |
| `planner` | sonnet | No — 0 | Yes | **ORPHANED** — valid definition, never spawned; plausibly subsumed by `architect`'s own plan-emission (its description already says it "emits machine-readable plans") — inference, not confirmed |
| `wave-executor` | sonnet | No — 0 | Yes | **ORPHANED** — valid, never spawned; plausibly subsumed by `coder`'s own parallel-task handling — inference, not confirmed |
| `lint-quality` | haiku | No — 0 | Yes | **ORPHANED** — valid, never spawned |
| `fixer` | sonnet | No — 0 | Yes | **ORPHANED, PRECEDENT-RELEVANT** — half of `/hmd:maintain`. Name (`hmd:fixer`) found in only 2 repo-wide grep hits, both roster/help-text, never an instructional spawn site |
| `seeker` | sonnet | No — 0 | Yes | **ORPHANED, PRECEDENT-RELEVANT** — other half of `/hmd:maintain`. Same roster-only grep pattern as `fixer`. 2026-08-23 label fix is real (see Precedent #2) but reconnects it to the *engine*, not to being spawned as a subagent — zero-spawn symptom likely still open |
| `database-architect` | sonnet | No — 0 | Yes | **ORPHANED** — same roster-only grep pattern confirmed |
| `incident-responder` | sonnet | No — 0 | Yes | **ORPHANED** — same roster-only grep pattern confirmed |
| `heimdall` | inherit | 0 as subagent | Yes | **REACHABLE (session-level, not a subagent)** — `tier: inherit` is a deliberate design choice (CLAUDE.md "Model routing": main agent never pinned), confirmed to resolve cleanly, not an error. Present as `hmd:heimdall` in the live top-level Agent-type registry — it's the entry point invoked directly, not something spawned as a child `Agent()` call, so 0 subagent-spawns is expected, not a defect |

---

## Summary counts

**Commands (18):** WORKS — 12 (`autocommit`, `autonomy`, `bench`, `debloat`, `demo`, `feedback`, `level`, `maintain`, `reflect`, `status`, `switch-ai`, `team`) · WORKS-with-flagged-incident — 1 (`invite`) · WORKS-qualified — 1 (`maintain-check`) · PARTIAL (safe surface verified, deep path UNSAFE/UNTESTED) — 3 (`designmatch`, `dream`, `report-bug`) · UNTESTED-by-choice — 1 (`save`) · **BROKEN — 0**

**Agents (16):** CONNECTED (measured spawns, valid definition) — 8 · ORPHANED (valid definition, zero measured spawns) — 7 · REACHABLE session-level (valid, 0 subagent-spawns by design) — 1 · **Invalid tools/tier — 0 of 16** · **Definition-valid rate — 16/16 (100%)**

**Precedents:** #1 (issue_queue misattribution) — **fully fixed, confirmed via diff**. #2 (severed label) — **label-level fix real and confirmed**, but qualified: does not by itself account for the historical zero-spawn measurement on `hmd:seeker`/`hmd:fixer`, which most likely traces to a separate, still-open prose→spawn invocation gap.

**New findings beyond the two given precedents:** (1) `bin/lib/issue_queue.py:_repo_root()` resolves to the primary checkout instead of the current worktree for every git-worktree caller, regardless of `--repo` — a real, reproduced sandbox-isolation defect. (2) A live credential was printed into this session's transcript by `bin/heimdall-invite` during audit execution — an operational incident, not a code defect; disclosed prominently above and in the final status report, literal secret never repeated.
