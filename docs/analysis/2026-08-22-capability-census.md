# hmd capability census — four-state audit
**Date:** 2026-08-22 · **Repo:** `/Users/rj/Downloads/heimdall` · **Branch:** `main` · **Version:** v2.4.0
**Rebase state:** `merge-base(HEAD, main) == main tip == c6bc79d67531bdd8e5b89b8476a727c6bc9bae96` — clean tree, no rebase needed.
**Production code changed by this audit: NONE.** Read-only except this report.

---

## 0. How to read this

Four states, applied to every capability hmd claims:

| State | Means | Evidence bar |
|---|---|---|
| **LIVE** | Runs automatically in a normal session | A `hooks/hooks.json` entry, an installer step, or a measured invocation |
| **REACHABLE** | Works when invoked, but a human/agent must invoke it | A dispatcher arm, slash command, or documented call path |
| **ORPHANED** | Exists, tests may pass, nothing calls it | Zero measured invocations AND no automatic trigger |
| **CLAIMED-ONLY** | Advertised in docs/help/banner but absent or non-functional | Named in README/panel/`--help`, no working implementation |

Every row is tagged **MEASURED** (I ran a command / counted real events) or **INFERRED** (read the code, did not observe execution).

**Measurement corpus (MEASURED).** 384 session transcripts across 155 `~/.claude/projects/*heimdall*` directories, 42,296 JSONL records, ~430 MB. For each of the 177 `bin/` executables I counted: appearances inside a `Bash` tool-use `command` string (a real execution), appearances in hook/system feedback, and appearances anywhere else (prose, file reads, tool results). Script: `/private/tmp/claude-501/-Users-rj-Downloads-heimdall/01313446-ae34-4e0c-9f91-4ef0bd66593c/scratchpad/census.py`.

**A second pass closed the obvious hole in that method.** Counting *bin names* would miss a binary invoked through its dispatcher arm (`hmd badge` never contains the string `heimdall-badge`). So I separately counted arm-form invocations — `(hmd|heimdall) <arm>` — across the same corpus (§9). Every orphan verdict below survived that control.

**The one caveat that governs everything below.** "Appears in a Bash command" is an *upper bound* on production liveness — much of this corpus is hmd developing hmd, so an appearance may be an agent testing the tool rather than using it. Conversely, **zero appearances across 384 sessions is strong evidence of orphanhood**, and that is the direction this report leans on.

---

## 1. HEADLINE: the orphan detector cannot detect this repo's dominant orphan class

This is the most important finding in the census, because it invalidates the tool the repo currently trusts to answer exactly this question.

`bin/heimdall-deadcode` and `test/bin-reachability-gate.test.sh` compute **transitive reference reachability**: does a path of file-mentions connect this binary to a declared "entry point"? They do not, and cannot, tell whether anything ever *executes* it.

**Proof (MEASURED):**

```
$ bash bin/heimdall-deadcode --why heimdall-brief
REACHABLE  bin/heimdall-brief <- agents/heimdall.md <- <entry-point>
```

`heimdall-brief` is the canonical known-orphan — the 8-mechanism Token-Frugal Protocol that was instructed in the orchestrator prompt and invoked zero times across ~40 spawns. **The gate reports it REACHABLE.** Its "reachability" is a sentence of prose in a Markdown prompt file. A prose instruction is not a caller.

The same pattern clears many others. Every chain below is MEASURED via `--why`, and every one bottoms out in (a) Markdown prose, (b) a slash command a human must type, or (c) another binary with zero measured invocations:

```
heimdall-ast        <- heimdall-graph        <- skills/heimdall/references/agent-templates.md   # a reference doc
heimdall-md         <- heimdall-ast          <- heimdall-graph <- (same reference doc)
heimdall-gate-surface <- heimdall-journal    <- skills/heimdall/SKILL.md                        # prose
heimdall-ponytail-ab <- heimdall-debloat     <- commands/debloat.md                             # human-typed
heimdall-queue      <- heimdall-drain        <- bin/heimdall                                    # drain: 0 invocations
heimdall-holdout    <- heimdall-report       <- bin/heimdall                                    # report: 0 invocations
heimdall-blackboard <- heimdall-protocol     <- bin/lib/protocol.sh <- heimdall-ledger <- .mcp.json
heimdall-resolve    <- heimdall-protocol     <- (same)
heimdall-context-capsule <- bin/rr           <- bin/heimdall
heimdall-connector  <- bin/lib/connectors/github.py <- commands/feedback.md                     # human-typed
```

**Verdict on the auditors themselves:**

| Capability | Verdict | Evidence |
|---|---|---|
| `bin/heimdall-deadcode` — consumer audit | **LIVE** as a tool, **but structurally blind** | Runs clean (`verdict CLEAN`); reports `heimdall-brief` REACHABLE (MEASURED) |
| `test/bin-reachability-gate.test.sh` | **REACHABLE** (test-suite member) | Same reference-reachability model; same blindness |
| `bin/lib/reachability-exemptions.tsv` | **LIVE** (read by both) | 20 acknowledged-dead rows, all in-date, all expiring — a genuinely good design |

**Do the exemptions hide orphans? Yes — but not the way you'd expect.** The registry is honest and well-built: 20 rows, three candid categories (`BY DESIGN` / `KNOWN GAP` / `DEAD`), every row carries a recheck date, and §3c of the gate proves the registry is not itself a reference surface. The registry is not the leak.

**The leak is the REACHABLE class.** Of the 54 binaries with **zero measured Bash invocations and zero hook appearances**, only **10** are acknowledged in the exemption registry. The other **44** are cleared by the gate as "reachable" and are therefore invisible to it (MEASURED — see §2).

```
$ bash bin/heimdall-deadcode | tail -3
  verdict    CLEAN — every dead executable carries a written, in-date reason.
             "clean" does NOT mean "nothing is dead": 20 are, and each one expires.
```

The tool's own closing line is more honest than the word CLEAN. But it still undercounts by ~4x, because it counts references, not executions.

**What would have to change to make the gate see this class:** feed it an execution ledger, not a reference graph — count invocations from session transcripts (or emit a per-bin invocation counter) and fail when a binary claimed as wired has zero executions over N sessions. Reference reachability and execution liveness are different properties and the repo currently only measures the first.

---

## 2. ORPHANED — ranked by user-visible impact

54 of 177 `bin/` executables have **zero measured Bash invocations and zero hook appearances across 384 sessions** (MEASURED).

Three of the 54 are **false positives** and are corrected out first, because they are named inside `hooks/hooks.json` command strings — the harness runs them, so they never appear as typed commands:

| Binary | Corrected verdict | Evidence |
|---|---|---|
| `secret-scan` | **LIVE** | `PreToolUse/Bash` entry in `hooks/hooks.json` (MEASURED) |
| `build-tracker.sh` | **LIVE** | `SessionStart` entry (MEASURED) |
| `heimdall-reel` | **LIVE** | `SessionEnd` entry (MEASURED) |

That leaves **51 genuinely uninvoked binaries**, of which **41 are unacknowledged** by the exemption registry.

Ranked by user-visible impact — a first-run/onboarding orphan outranks an internal helper:

### Tier 1 — on the onboarding / first-impression path (highest impact)

| # | Binary | Verdict | Why it matters | Evidence |
|---|---|---|---|---|
| 1 | `heimdall-funnel` | **ORPHANED** | Named in `install.sh` (`FUNNEL_BIN`, line 1713) — the post-install conversion funnel. Zero invocations. | `install.sh:1713`; 0 Bash / 0 hook (MEASURED) |
| 2 | `heimdall-face` | **ORPHANED** | The watchman face rendered in the install banner; `install.sh` references it, `hmd` has an arm. Zero invocations. | `install.sh` ref; 0/384 (MEASURED) |
| 3 | `heimdall-city` | **ORPHANED** | Referenced from `install.sh`. Zero invocations. | 0/384 (MEASURED) |
| 4 | `heimdall-frontdoor` | **ORPHANED** | `hmd` dispatcher arm exists; the "front door" nobody opens. | 0/384 (MEASURED) |
| 5 | `heimdall-sigil-png` | **ORPHANED** | `hmd sigil-png` arm (`bin/heimdall:1748`). Identity artwork export. | 0/384 (MEASURED) |
| 6 | `heimdall-badge` | **ORPHANED** | `hmd badge` arm (`bin/heimdall:2186`). A README badge generator nobody runs. | 0/384 (MEASURED) |
| 7 | `heimdall-verdict` | **ORPHANED** | `hmd verdict` arm (`bin/heimdall:2174`); `.heimdall/verdict.json` exists so *something* wrote one historically. | 0/384 (MEASURED) |
| 8 | `heimdall-report` | **ORPHANED** | `hmd report` arm (`bin/heimdall:2376`); README says "hmd report". | 0/384 (MEASURED) |
| 9 | `heimdall-feedback` | **ORPHANED** | Backs `/hmd:feedback` (`commands/feedback.md`) + skill. The team-feedback path. | 0/384 (MEASURED) |
| 10 | `report-issue` | **ORPHANED** | Backs `commands/report-bug.md` — the bug-report path advertised to users. | 0/384 (MEASURED) |

### Tier 2 — advertised subsystems whose entry point is a dispatcher arm

| # | Binary | Verdict | Note | Evidence |
|---|---|---|---|---|
| 11 | `heimdall-watch-tui` | **ORPHANED** | `hmd watch` arm (`:2241`) — the live TUI. | 0/384 |
| 12 | `heimdall-redum` | **ORPHANED** | `hmd redum` arm (`:2430`), named in README. | 0/384 |
| 13 | `heimdall-reuse-metric` | **ORPHANED** | Backs `REUSE-METRIC.md`, a published claim. | 0/384 |
| 14 | `heimdall-drain` | **ORPHANED** | `hmd` arm; also the *only* path to `heimdall-queue`. Two-corpse chain. | 0/384 |
| 15 | `heimdall-queue` | **ORPHANED** | Reachable only via `heimdall-drain` (itself orphaned). | 0/384 |
| 16 | `heimdall-persona` | **ORPHANED** | `hmd` arm. | 0/384 |
| 17 | `heimdall-check-identities` | **ORPHANED** | `hmd` arm; identity integrity — `IDENTITY.md` is a published claim. | 0/384 |
| 18 | `heimdall-protocol` | **ORPHANED** | 164 prose mentions, 0 executions. Backs `PROTOCOL.md`. | 0/384 |
| 19 | `heimdall-blackboard` | **ORPHANED** | Reached only via `heimdall-protocol`. | 0/384 |
| 20 | `heimdall-resolve` | **ORPHANED** | Reached only via `heimdall-protocol`. | 0/384 |
| 21 | `heimdall-claim` | **ORPHANED** (as a bin) | Coordination claims — but see §5: the *MCP* path is live, the bin is not. | 0/384 |
| 22 | `conflict-log` | **ORPHANED** | Named in `commands/`, `agents/`, and a skill. | 0/384 |
| 23 | `heimdall-who` | **ORPHANED** | 129 prose mentions, 0 executions. | 0/384 |
| 24 | `heimdall-activity` | **ORPHANED** | Named in a skill. | 0/384 |
| 25 | `heimdall-attest` | **ORPHANED** | Named in `agents/`; attestation is a trust claim. | 0/384 |
| 26 | `authenticity-check` | **ORPHANED** | Named in a skill; authenticity is a trust claim. | 0/384 |
| 27 | `heimdall-validate` | **ORPHANED** | Cleared via `heimdall-gate` ← `heimdall-stamp` ← hooks. Never executed itself. | 0/384 |
| 28 | `heimdall-gate-surface` | **ORPHANED** | Cleared via prose in `skills/heimdall/SKILL.md`. | 0/384 |
| 29 | `detect-skills` | **ORPHANED** | Skill auto-detection — named in `agents/` + skill, never runs. | 0/384 |
| 30 | `stack-detect` | **ORPHANED** | Stack detection, named in a skill. | 0/384 |

### Tier 3 — internal / research / maintainer helpers (lowest impact)

`heimdall-ast`, `heimdall-md`, `heimdall-context-capsule`, `heimdall-checkpoint-share`, `heimdall-connector`, `heimdall-gh-app-token`, `heimdall-holdout`, `heimdall-issue-config`, `heimdall-issue-queue`, `heimdall-ponytail-ab`, `heimdall-face-test`, `heimdall-md` — all **ORPHANED**, 0/384 each (MEASURED).

Plus the **10 already-acknowledged** rows that also measure zero (registry is correct about these): `generate-changelog`, `heimdall-banner-test`, `heimdall-branch-context`, `heimdall-collision`, `heimdall-cost-model-refresh`, `heimdall-issue-corpus`, `heimdall-queue-mcp`, `heimdall-registry-hygiene`, `heimdall-s6-manifest`, `heimdall-vm-bench`.

---

## 3. ORPHANED — agent definitions (MEASURED, high confidence)

Across **432 `Agent` tool calls** in the corpus, only 9 of 16 agent definitions were ever spawned.

| Agent | Spawns / 432 | Verdict |
|---|---|---|
| `hmd:coder` | 361 (84%) | **LIVE** |
| `hmd:architect` | 24 | **LIVE** |
| `hmd:verifier` | 12 | **LIVE** |
| `hmd:docs-writer` | 9 | **LIVE** |
| `hmd:reviewer` | 4 | **REACHABLE** — see impact note below |
| `hmd:test-runner` | 2 | **REACHABLE** |
| `hmd:security-auditor` | 1 | **REACHABLE** |
| `hmd:design` | 1 | **REACHABLE** |
| `agents/planner.md` | **0** | **ORPHANED** |
| `agents/wave-executor.md` | **0** | **ORPHANED** — yet `waves.json` is core to the documented plan model |
| `agents/lint-quality.md` | **0** | **ORPHANED** — "Lint clean (zero warnings)" is a stated quality gate |
| `agents/fixer.md` | **0** | **ORPHANED** — half of the advertised `/hmd:maintain` loop |
| `agents/seeker.md` | **0** | **ORPHANED** — the other half of `/hmd:maintain` |
| `agents/database-architect.md` | **0** | **ORPHANED** |
| `agents/incident-responder.md` | **0** | **ORPHANED** |
| `agents/heimdall.md` | **0** as a subagent | **REACHABLE** (loads as the session agent, not spawned) |

**Highest-impact reading of this table:** `hmd:reviewer` ran **4 times in 432 spawns** while `CLAUDE.md` lists "Code review completed" as a quality gate enforced before push, and `agents/reviewer.md` says review is "Mandatory before any push". That is a documented-mandatory gate with ~1% observed coverage — a docs-vs-reality gap, not a missing binary. Same shape for `lint-quality` (0 spawns vs "Lint clean (zero warnings)" gate).

**`/hmd:maintain` is doubly orphaned:** both agents it composes (`seeker`, `fixer`) have zero spawns, and `heimdall-issue-queue` / `heimdall-issue-config` (its plumbing) also measure zero.

---

## 4. Verification of the nine known instances

Every one re-checked with a command.

| # | Known instance | Status now | Evidence |
|---|---|---|---|
| 1 | `heimdall-brief` + 8-mechanism Token-Frugal Protocol | **CONFIRMED ORPHANED** | Bash invocations by date: `2026-08-07:1, 2026-08-08:2, 2026-08-21:4, 2026-08-22:3` — the 08-21/22 hits are the discovery session and this audit. **Zero invocations across the whole 08-08 → 08-21 production window.** Gate still reports it `REACHABLE` (MEASURED) |
| 2 | `_MONO_CAPS` away-teammate drain | **FIXED → LIVE** | `grep -c '_MONO_CAPS' sentinels/hmd-statusline.py` → **0** (symbol removed by `d3fd560`). Drain now implemented as desaturation (`hmd-statusline.py:1430`) and genuinely asserted: `bash test/wall-presence-drain.test.sh` → `7 passed, 0 failed`. The surviving `_MONO_CAPS` strings in that test are historical **comments**, not vacuous assertions — I checked (MEASURED) |
| 3 | Statusline "hard time ceiling" via `timeout`/`gtimeout` | **CONFIRMED BROKEN (environmental)** | `command -v timeout` → ABSENT; `command -v gtimeout` → ABSENT on this macOS host. Independently reproduced: my own first `timeout 300 …` call in this audit failed with `command not found`. Statusline now uses Python-level `subprocess(timeout=…)` at lines 220/417/1556 — which *does* bind — but any shell-level ceiling probing `timeout` never did (MEASURED) |
| 4 | `hmd wrap --always` non-TTY guard | **NOT RE-VERIFIED** | `bin/heimdall-wrap` and `sentinels/` are out of scope by instruction. Carried forward unchanged from the discovery session (INFERRED) |
| 5 | `skills/stacks` missing `SKILL.md` | **FIXED** | All five bundled skills now carry one: `designmatch`, `heimdall`, `self-improve`, `stacks`, `system-health` (MEASURED) |
| 6 | `sysmon` not in hooks | **CONFIRMED** | `grep -c sysmon hooks/hooks.json` → **0**. Only surface naming it is `skills/system-health/SKILL.md` (prose). Yet `heimdall-sysmon` shows 44 Bash + 8 hook-context appearances — so it is **REACHABLE and actively used by agents**, never automatic (MEASURED) |
| 7 | `heimdall-comprehend` does not auto-load for `hmd wrap cursor/codex/gemini/aider` | **CONFIRMED, low usage** | 4 Bash invocations / 384 sessions; no hook entry. **ORPHANED-adjacent / REACHABLE** (MEASURED) |
| 8 | `/hmd:verify` advertised but never existed | **FIXED** | `ls commands/verify.md` → No such file; `grep 'hmd:verify' README.md install.sh` → no hits. Cleanly removed (MEASURED) |
| 9 | Fabricated "~65-75% tokens saved" in onboarding banner | **FIXED** | No hits in `install.sh` / `README.md` (MEASURED) |

**Score: 4 confirmed still-broken, 4 fixed, 1 out of scope.** The two that matter most for launch are #1 (the flagship token-frugality protocol is inert) and #6 (`sysmon` grades disk CRIT correctly and nothing ever asks it).

---

## 5. LIVE — what genuinely runs automatically

**MEASURED** from `hooks/hooks.json` (181 lines, 22 hook entries). These execute without anyone asking:

| Event | Matcher | Bins invoked |
|---|---|---|
| `UserPromptSubmit` | `*` | `parallel-gate`, `heimdall-ctx-meter` |
| `PreToolUse` | `Bash` | `corpus`, `falsify`, `heimdall-git-guard`, `heimdall-selfscan`, `heimdall-stamp`, `heimdall-state`, `parallelism-tracker`, `secret-scan` |
| `PreToolUse` | `Read\|Grep\|Glob` | `parallelism-tracker` |
| `PreToolUse` | `Agent` | `heimdall-agents`, `parallelism-tracker` |
| `PreToolUse` | `Write\|Edit` | `bin/lib/*`, `parallelism-tracker` |
| `PreToolUse` | `Edit\|MultiEdit\|Write` | `heimdall-precheck-edit` |
| `PostToolUse` | `Bash` | `corpus-capture` |
| `PostToolUse` | `Write\|Edit\|MultiEdit\|NotebookEdit` | `edit-tracker`, `heimdall-autocommit` |
| `PostToolUse` | `Write\|Edit` | `heimdall-context-sync` |
| `SessionStart` | `*` | `build-tracker.sh`, `edit-tracker`, `heimdall-autoupdate`, `heimdall-cc-selfheal`, `heimdall-cleanup`, `heimdall-gc`, `heimdall-presence`, `heimdall-reap-idle`, `heimdall-statusline-register`, `heimdall-team`, `parallelism-tracker`, `stack-pack`, `heimdall-resume-probe`, `heimdall-maintain-loop`, `heimdall-quota-resume`, `heimdall-dream-notice`, `heimdall-ai-select` |
| `SessionEnd` | `*` | `heimdall-presence`, `heimdall-autocommit`, `heimdall-checkpoint`, `heimdall-cleanup`, `heimdall-context-sync`, `heimdall-gc`, `heimdall-reap-idle`, `heimdall-reel`, `parallelism-tracker`, `summary-card`, `verify-edits`, `sentinels/hmd-farewell.sh` |

**Every bin named in `hooks/hooks.json` exists and is executable** — cross-checked, zero dangling references (MEASURED). That is a genuinely clean surface.

**LIVE, corroborated by high measured invocation counts:** `heimdall` (dispatcher), `rr`, `heimdall-ledger` (MCP-registered, 13 invocations), `heimdall-presence`, `heimdall-team`, `heimdall-state`, `heimdall-gc`, `heimdall-cleanup`, `corpus`, `falsify`.

---

## 6. REACHABLE — works, but only when asked

- **Dispatcher arms** (`bin/heimdall`, 4,296 lines, ~48 arms at the main `case` on line 1628): `help demo rr sigil sigil-png guard uninstall team invite join connect presence context chat link beat roster dashboard god telemetry init verdict badge metrics clip funnel watch rules route modules tier status cursor-statusline weekly-log report designmatch check redum wrap unwrap`. All REACHABLE by construction; several are simultaneously ORPHANED (§2) because nobody types them.
- **Slash commands** (18 in `commands/`): only 5 have a matching `hmd` dispatcher arm (`demo`, `designmatch`, `invite`, `status`, `team`). The other 13 (`autocommit autonomy bench debloat dream feedback level maintain maintain-check reflect report-bug save switch-ai`) are slash-only. **This is not a defect** — they are Claude Code commands, not CLI arms — but it means the CLI and the slash surface advertise different capability sets, which is a launch-docs risk.
- **`heimdall-sysmon`** — REACHABLE, actively used (44 invocations), never automatic. **To make it LIVE:** add a `SessionStart` entry to `hooks/hooks.json`.
- **`skills/`** — all 5 bundled skills carry `SKILL.md`, so all are discoverable → REACHABLE.
- **`modules/`** — 4 `_classes/*.json` + `modules/headroom/manifest.json`. `hmd modules` arm exists (README's most-repeated claim, 25 mentions). REACHABLE.
- **`evals/oracles/`** — 10 oracle dirs + `registry.json` + 3 docs. Driven by `bin/falsify`, which **is** hook-wired (`PreToolUse/Bash`) → the oracle harness is **LIVE**; individual oracles are REACHABLE.
- **MCP surface** — `heimdall-ledger-mcp` registered in `.mcp.json` → LIVE. `heimdall-queue-mcp` **not** registered → ORPHANED (correctly acknowledged in the registry).

---

## 7. CLAIMED-ONLY

Small list — the repo is better here than the orphan count suggests, and today's removals (#8, #9 in §4) closed the two worst.

| Claim | Where | Verdict | Evidence |
|---|---|---|---|
| `/hmd:verify` "Shipped" | README + post-install panel | **RESOLVED** — claim removed | `grep 'hmd:verify' README.md install.sh` → 0 hits (MEASURED) |
| "~65-75% tokens saved" | onboarding banner | **RESOLVED** — claim removed | 0 hits (MEASURED) |
| "Lint clean (zero warnings)" as an enforced gate | `CLAUDE.md` Quality Gates | **CLAIMED-ONLY in practice** | `agents/lint-quality.md` spawned 0/432 times (MEASURED) |
| "Code review completed" as an enforced gate | `CLAUDE.md` Quality Gates | **WEAKLY LIVE** | `hmd:reviewer` 4/432 spawns (MEASURED) |
| Token-Frugal Protocol (8 mechanisms) | orchestrator prompt / `agents/heimdall.md` | **CLAIMED-ONLY in effect** | `heimdall-brief` zero invocations in the production window (MEASURED) |
| `heimdall-registry-hygiene` "MONTHLY job" | its own header | **CLAIMED-ONLY** | No cron/LaunchAgent/workflow calls it — registry admits this (MEASURED) |

---

## 9. Dispatcher-arm usage — the control that confirms §2 (MEASURED)

Counted `(hmd|heimdall) <arm>` occurrences inside real `Bash` tool-use command strings across all 384 transcripts. **23 of 40 arms have never been typed once.**

| Arm | Invocations | Arm | Invocations |
|---|---|---|---|
| `route` | 19 | `tier` | 4 |
| `modules` | 16 | `team` | 3 |
| `wrap` | 16 | `dashboard` | 3 |
| `god` | 10 | `init` | 3 |
| `link` | 6 | `presence` | 2 |
| `rules` | 6 | `context` | 1 |
| `status` | 5 | `roster` | 1 |
| `weekly-log` | 5 | `cursor-statusline` | 1 |
| `chat` | 4 | | |

**Zero-invocation arms (23):** `help demo rr sigil sigil-png guard uninstall invite join connect beat telemetry verdict badge metrics clip funnel watch report designmatch check redum unwrap`

**Why this matters:** the arms backing every Tier-1/Tier-2 orphan in §2 — `badge`, `verdict`, `funnel`, `watch`, `report`, `redum`, `sigil-png`, `demo`, `check`, `designmatch` — are **all zero**. The orphan verdicts are therefore not an artifact of name-vs-arm counting. Both the binary and its only entry point are cold.

**Single most alarming row: `demo` = 0 arm invocations, `heimdall-demo` = 1 direct invocation, across 384 sessions.** `hmd demo` is the headline next-step printed by `install.sh`'s post-install panel and the whole point of the `hmd:demo` skill ("the first-five-minutes wow"). The primary onboarding path for every new user is, empirically, almost completely unexercised. For a launch, this is the highest-priority item in this report: it is the one orphan a *new user* hits first.

---

## 10. `hmd --help` — the inverse problem (MEASURED)

`bash bin/heimdall help` is clean on claims but very thin on coverage.

- **All 13 advertised flags are genuinely handled** in `bin/heimdall`: `--resume --auto --no-goal --skip-checkpoint --no-autocommit --autocommit --skills --update --setup --team --reinstall --uninstall --help`. Zero CLAIMED-ONLY flags (MEASURED).
- **All 8 advertised subcommands have real dispatcher arms**: `team invite join connect presence tier status weekly-log`. Zero CLAIMED-ONLY subcommands (MEASURED).
- **But `--help` documents 8 of ~40 dispatcher arms (20%).** 32 working arms — including `god`, `route`, `modules`, `rules`, `wrap`, `dashboard`, `verdict`, `badge`, `watch`, `report`, `check`, `redum`, `funnel`, `clip`, `metrics` — are **undiscoverable from the CLI's own help**. Note that `route` (19), `modules` (16) and `wrap` (16) are among the *most-used* arms in the entire corpus and none appear in help.

This is the mirror image of CLAIMED-ONLY: not overclaiming, but under-advertising working capability. It is a launch-docs defect rather than a code defect, and it partly explains the orphan rate — an arm nobody can discover is an arm nobody calls.

---

## 11. Surfaces that are genuinely clean (MEASURED)

Recording these explicitly so the census is not read as uniformly negative.

| Surface | Result |
|---|---|
| `hooks/hooks.json` → referenced paths | **38/38 resolve.** Zero dangling references. The only two non-executable entries are `bin/edit-tracker.c` and `bin/parallelism-tracker.c` — C *sources* named as compile inputs, not invocations |
| `skills/` `SKILL.md` coverage | **5/5** present (`designmatch heimdall self-improve stacks system-health`) |
| `skills/` + `commands/` + `agents/` → `heimdall-*` bin references | **Zero real dangling references.** Six apparent hits are regex artifacts (`heimdall-demo-app` is a repo directory; `heimdall-no-autocommit` is a flag) |
| `--help` flags / subcommands | **21/21** backed by real code |
| `install.sh` post-install panel claims | **4/4 exist**: `commands/save.md`, `commands/status.md`, `bin/heimdall-demo` (`hmd demo` arm at `bin/heimdall:1651`), `bin/heimdall-doctor-install` |
| `bin/lib/reachability-exemptions.tsv` | 20 rows, all well-formed, in-date, and genuinely unreachable; gate §3c proves the registry is not a self-vouching reference surface. Honest design — the problem is what it *doesn't* cover, not what it says |


---

## 12. "Has a passing test" vs "runs in production" — the central distinction (MEASURED)

The task asked for precision here because four of the nine known instances had green tests and zero real invocations. The census quantifies it.

Of the **51 zero-invocation, non-hook-wired binaries** (§2):

| | Count |
|---|---|
| **Named by at least one test file** | **41** |
| Named by no test at all | 10 |

**41 of 51 orphans are under test.** Test coverage in this repo is therefore *anti-correlated* with production liveness — the well-tested tools are disproportionately the cold ones, because a test is what a careful author writes instead of a caller.

**Measured proof that these are green, not merely present.** I ran five dedicated orphan suites:

```
$ bash test/heimdall-sigil-png.test.sh        → sigil-png: 19 passed, 0 failed        (exit 0)
$ bash test/heimdall-ponytail-ab.test.sh      → 8 passed, 0 failed                    (exit 0)
$ bash test/heimdall-context-capsule.test.sh  → ALL GREEN — build gathers state …      (exit 0)
$ bash test/feedback.test.sh                  → 10 passed, 0 failed                   (exit 0)
$ bash test/vm-bench.test.sh                  → vm-bench: 29 passed, 0 failed         (exit 0)
```

That is 66+ green assertions across five binaries with **zero measured invocations between them**. `heimdall-sigil-png` has 19 passing tests and its `hmd sigil-png` arm has never been typed once in 384 sessions. `heimdall-vm-bench` has 29 passing tests and is on the acknowledged-DEAD list.

**Orphans with the heaviest test investment** (test files naming them): `heimdall-issue-queue` (7), `heimdall-gh-app-token` (6), `heimdall-attest` (5), `heimdall-claim` (5), `heimdall-reuse-metric` (5), `heimdall-activity` (4), `heimdall-issue-corpus` (4). Seven binaries, 36 test files, zero invocations.

**Orphans with no test at all (10):** `authenticity-check`, `conflict-log`, `detect-skills`, `heimdall-banner-test`, `heimdall-blackboard`, `heimdall-checkpoint-share`, `heimdall-face-test`, `heimdall-queue-mcp`, `report-issue`, `stack-detect`. These are the genuinely unguarded ones — `report-issue` (backs `/hmd:report-bug`) and `detect-skills` / `stack-detect` (skill auto-detection) are the highest-impact members.

**The rule to carry into launch:** in this repo, `350 test suites, all green` and `51 binaries that have never run` are both true simultaneously and neither contradicts the other. A green suite is evidence about the code; only an invocation count is evidence about the system.

---

## 13. `evals/oracles/` and `modules/` (MEASURED)

**Oracles — the harness is LIVE, the registry is an orphan.**

- `bin/falsify` is hook-wired (`PreToolUse/Bash`) and `bin/corpus` is too, so the oracle harness genuinely runs automatically → **LIVE**.
- Oracle *discovery is by path convention*, not by registry: `bin/corpus:14` documents the seam as `evals/oracles/<gate>/run.sh` and `bin/corpus:76` resolves `ORACLES_DIR` by path. **Neither `bin/corpus` nor `bin/falsify` reads `registry.json`** (MEASURED — grep over `bin/` returns nothing).
- `evals/oracles/registry.json` is read by exactly two files, both tests: `test/oracle-registry-integrity.test.sh`, `test/heimdall-hmd-bootstrap.test.sh`. **Verdict: ORPHANED** — a test-only artifact that reads like production configuration.
- Consequence, and a correction to the obvious first reading: the registry lists 9 entries while 10 oracle directories exist (`changelog-bash32` is unlisted), but because discovery is convention-based, `changelog-bash32` **does** run. The drift is harmless *today* and is exactly the kind of latent inconsistency that becomes a silent gap the moment someone wires the registry up. Worth reconciling before launch, not urgent.

**Modules — works, but thin relative to how loudly it is advertised.**

- `bash bin/heimdall modules` → renders correctly: `headroom 0.35.0 (traffic-proxy + storage-codec wired)`, plus a registry listing `headroom` as available. **REACHABLE**, and genuinely used (16 arm invocations, one of the top-4 most-used arms).
- `hmd modules` is **README's single most-repeated claim (25 mentions)** and the module system ships **exactly one module** (`modules/headroom/manifest.json`) against four declared classes (`tool-adapter`, `rule-pack`, `storage-codec`, `traffic-proxy`). Not a defect — the machinery is real and exercised — but the docs:capability ratio is the widest in the repo and a reviewer reading README will expect an ecosystem.


---

## 8. Bottom line for launch

Ordered by what an owner should act on first.

1. **`hmd demo` — the primary onboarding path — is empirically unexercised.** 0 arm invocations, 1 direct invocation, across 384 sessions, while `install.sh` prints it as *the* next step. Highest user-visible risk in the repo: it is the first thing a new user runs and the least-tested thing hmd ships. (§9)
2. **The reachability gate is not a liveness gate.** `bin/heimdall-deadcode` clears 44 never-executed binaries as "reachable" because it computes transitive *reference* reachability. Its chains bottom out in Markdown prose, human-typed slash commands, and other cold binaries. Read `verdict CLEAN` as *"no unreferenced files"*, never as *"no dead capability"*. (§1)
3. **~29% of `bin/` (51 of 177) has never executed once**, and 41 of those are unacknowledged by the exemption registry. Ten sit on the onboarding/trust path: `heimdall-funnel`, `heimdall-face`, `heimdall-city`, `heimdall-frontdoor`, `report-issue`, `heimdall-feedback`, `heimdall-badge`, `heimdall-verdict`, `heimdall-report`, `heimdall-sigil-png`. (§2)
4. **23 of 40 dispatcher arms have never been typed** — and `--help` documents only 8 of them, omitting three of the four most-used arms (`route`, `modules`, `wrap`). Under-advertised capability is a partial *cause* of the orphan rate, not just a symptom. (§9, §10)
5. **7 of 16 agent definitions have never been spawned** across 432 `Agent` calls, including both halves of the advertised `/hmd:maintain` loop (`seeker`, `fixer`) and the entire `waves.json` executor (`wave-executor`). (§3)
6. **Two documented quality gates are effectively unenforced**: lint (`lint-quality` 0/432 spawns vs "Lint clean (zero warnings)") and review (`hmd:reviewer` 4/432 vs "Mandatory before any push"). (§3, §7)
7. **`sysmon` still is not wired.** `grep -c sysmon hooks/hooks.json` → 0. It grades disk CRIT correctly and 44 measured invocations prove agents find it useful — it just never runs on its own. One `SessionStart` line would make it LIVE. (§4 #6)
8. **`heimdall-brief` is the template defect and it is still inert.** Real code, green tests, instructed in the orchestrator prompt, zero invocations across the entire 08-08 → 08-21 production window. A passing test proves the code works; it does not prove anything calls it. Four of the nine known instances had exactly this shape, which is why the census weighted measured execution over reference reachability throughout. (§1, §4 #1)

9. **Test coverage is anti-correlated with liveness: 41 of 51 orphans are under test**, and five sampled orphan suites returned 66+ green assertions with zero invocations between them. `350 suites all green` and `51 binaries never run` are simultaneously true. (§12)
10. **`evals/oracles/registry.json` is read only by tests** — oracle discovery is path-convention based, so the registry is production-shaped configuration that nothing in production reads. Its 9-entries-vs-10-directories drift is harmless today and load-bearing the day someone wires it up. (§13)

**What is genuinely clean** (§11): every hooks.json reference resolves, all 5 skills are discoverable, all 21 `--help` claims are backed by code, all 4 post-install panel claims exist, and the exemption registry is well-built and honest. The repo's problem is not broken claims — today's fixes closed the two worst of those. It is **cold capability**: a large, working, well-tested surface that nothing ever invokes.
