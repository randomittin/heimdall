# Web research tools for hmd's role agents — rollout + Firecrawl re-check

**Date:** 2026-09-05 · **Task:** brief-1788601687-20368 · **Repo:** `/Users/rj/Downloads/heimdall`

**Ask:** 0 `WebSearch`/`WebFetch` refs across `agents/`+`skills/`, 0 `firecrawl` refs anywhere in repo, across 16 role agents. Part 1: wire native `WebSearch`/`WebFetch` into the roles that genuinely need it. Part 2: assess Firecrawl as an opt-in module, self-host bar included.

---

## Part 1 — per-role table (all 16 agents)

| Role | Tools added | Why |
|---|---|---|
| `architect` | `WebSearch`, `WebFetch` | Technology Evaluation + Risk Assessment are named responsibilities (`agents/architect.md` items 3–4); a plan that names a library/approach without checking its current docs risks citing an API that doesn't exist. New `## Web Research` section scopes both tools to that use, ranks in-repo precedent above a generic web result. |
| `database-architect` | `WebSearch`, `WebFetch` | Item 5 "Technology Evaluation" explicitly compares engines/extensions (Postgres vs Redis vs document store); current version/LTS/extension-compat facts (e.g. pgvector index types) age out fast. Guidance appended to that item. |
| `incident-responder` | `WebSearch`, `WebFetch` | DIAGNOSE step (§2) checks "recent changes" and "dependencies" under time pressure; a known upstream bug in an implicated dependency is exactly the kind of fact a status page/issue tracker answers faster than re-deriving from a stack trace. Guidance appended after the "Binary search" bullet. |
| `security-auditor` | `WebSearch`, `WebFetch` | Item 2 "Dependency Vulnerability Scan" already runs `npm audit`/`pip audit`/etc.; those tools go stale or miss advisories the CVE/GitHub-Advisory-DB feeds carry sooner. Guidance frames it as supplementing, never replacing, the audit commands. |
| `seeker` | `WebSearch`, `WebFetch` | Files GitHub issues with a "Suggested Fix" field from log analysis; checking whether an error signature matches a known upstream issue before suggesting a fix measurably improves the fix's quality. Edited the issue-body template's Suggested-Fix line rather than inserting a new numbered step (step 5 "Verify old fixes" is cross-referenced elsewhere in the file — renumbering would break that reference). |
| `docs-writer` | `WebSearch`, `WebFetch` | Item 2 "API documentation" — documenting an upstream dependency's API from memory is exactly the "wrong docs are worse than no docs" failure its own Documentation Principles section warns against. |
| `coder` | NONE | Implementation role: builds what a plan already specifies (TDD against given acceptance criteria), doesn't re-litigate architecture mid-build. Technology selection is `architect`'s job upstream; granting research tools here invites scope creep into re-deciding things a plan already settled. My own tool list this session (`Agent, TaskStop, Read, Write, Edit, Bash, Skill`) already has neither — consistent, no change needed. |
| `design` | NONE | Visual/UX design decisions ground in the existing design system and codebase (per its own description); no stated research need, and no exemplar in the file suggesting one. |
| `fixer` | NONE | Picks up a labeled GitHub issue, implements a fix, raises a PR — same shape as `coder`: scoped to a given issue's local repro/fix, not open-ended web research. |
| `heimdall` | NONE | Orchestrator — decomposes and dispatches, doesn't do hands-on technical research itself (`architect` does). Also deliberately not touched at all this task: its §2d Clarification Protocol section is exact-string-tested (`test/heimdall-clarification-protocol.test.sh`, 25 assertions) and there's no evidence-backed need to risk it for an unrelated add. |
| `lint-quality` | NONE | "Fast and mechanical" by its own description. Same nondeterminism argument as the brief's named exclusions: a linter reaching for the web mid-check is a new source of run-to-run variance in a role whose value IS determinism. |
| `planner` | NONE | Structures already-decided work into dependency-ordered waves with runnable acceptance criteria — technology/approach selection happens upstream in `architect`. Adding web tools here would blur that boundary. Separately, this repo has an existing self-disclosed usage gap on `planner` (near-zero spawns) — weak payoff for a speculative add to an already-underused role. |
| `reviewer` | NONE | Adjudication role (opus-only, "Mandatory before any push"). Brief's own reasoning applies directly: "a judge browsing the web mid-verdict is a new nondeterminism source." Reviews the diff against the repo's own standards, not external opinion. |
| `test-runner` | NONE | Brief-named exclude candidate. Mechanical test-writing/running (`isolation: worktree`); same nondeterminism argument. |
| `verifier` | NONE | Brief-named exclude candidate. Opus-only adjudication, "Never skips a criterion," grades against wired oracles/acceptance criteria and a Sentinel factcheck against the filesystem — a deterministic evidence trail. Web access would let it grade against something other than that trail. |
| `wave-executor` | NONE | Executes tasks from an already-written plan, commits atomically, spawns coder-like subprocesses for independent tasks — structurally identical to `coder`/`fixer` in shape and scope. No research need of its own. |

**6 added, 10 excluded, all 16 covered.** Every guidance insertion lands only in a role whose `tools:` line now actually grants the tool (checked against the brief's own named inverse-bug precedent: three roles whose prose invoked `Skill` without `tools:` granting it). No `agents/researcher.md` created — a new role would need a matching `bin/lib/tier-table.json` class entry (`bin/heimdall-tier`'s `cmd_check` fails closed on any agent name absent from that map) that nothing in the brief asked for, and the acceptance criteria only require a table over the *existing* 16.

**Tests:** `test/tier-declaration.test.sh` (37/37), `test/operational-model-pin.test.sh` (24/24), `test/heimdall-clarification-protocol.test.sh` (25/25) — all green after the edit, quoted in the task's final status report. A targeted grep found no other suite that both scans `agents/*.md` broadly and asserts on `tools:` contents, so no hidden coupling beyond the three named suites.

---

## Part 2 — Firecrawl: re-checked, not re-researched from scratch

**A prior assessment already exists in this repo**: `docs/analysis/2026-08-23-firecrawl-assessment.md` (assessed 2026-08-24, ~13 days before this task), written by a prior `hmd:architect` invocation with live `curl`-based verification against `api.github.com`, the repo's raw files, and `docs.firecrawl.dev`. It is thorough, sourced, and reaches a verdict. Redoing that research from scratch would duplicate real work for no benefit — the right move is to confirm it still holds and connect it to what Part 1 just did, not re-derive it.

### What it found (summary, full detail in that file)

- **Verdict: (a) — use what's already wired (the account-level Firecrawl MCP), integrate nothing.** No `modules/firecrawl/` was ever created after that verdict — confirms it was acted on, not just written and shelved.
- **License: AGPL-3.0** on the core engine (`apps/api`), MIT on the client SDKs. Using a hosted/MCP instance as a *client* carries no AGPL exposure; self-hosting *and modifying* the engine would trigger AGPL's network-use clause (must publish modified source to that internal service's users).
- **Self-host is real infrastructure, not `docker run`**: API+workers, a dedicated Playwright browser-pool service (2 CPU / 4GB mem in the shipped compose file), Redis, a Postgres-backed job queue ("NuQ"), optional FoundationDB.
- **The OSS self-hosted build is explicitly feature-*behind* Firecrawl's own hosted Cloud/MCP path**, by the maintainers' own published comparison (`docs.firecrawl.dev/contributing/open-source-or-cloud`): Agent, Browser, Interact, managed anti-bot, and enterprise controls are Cloud-only, not in the default self-hosted stack. Self-hosting to "get the same thing as the MCP" doesn't — it gets a strictly smaller feature set for real standing infrastructure cost.
- **Zero measured demand**: a structural scan (not text grep — `json.loads` per transcript line, checked `message.content[].type == "tool_use"`) over 367 `.jsonl` transcripts / 43,347 tool-bearing lines found **0** `WebFetch`/`WebSearch`/`firecrawl_*` tool_use records, ever, by any role. Same shape as this repo's other measured declines (claude-mem at 0% usage, a Headroom fork at 0.27–0.56%).
- **The exact caveat that matters for this task**: the doc's own closing recommendation was — *"if a specific, named future workflow needs web content inside a spawned sub-agent... the correct fix is granting that role the built-in `WebFetch`/`WebSearch` tools... for that one role, evaluated on its own merits when that workflow is actually designed — not a blanket grant made now speculatively, and not Firecrawl specifically."* **Part 1 of this task is that named workflow arriving**, and the fix applied is exactly the one that doc predicted: a per-role native-tool grant, not a Firecrawl integration.

### Live re-verification today (2026-09-05), not carried over unchecked

Network was reachable this session, so the load-bearing facts were re-pulled rather than assumed still true 13 days later:

```
$ curl -s https://api.github.com/repos/firecrawl/firecrawl | jq …
pushed_at:            2026-09-05T06:22:40Z   (pushed TODAY — still active)
stargazers_count:     176,674                 (was 171,428 on 2026-08-24)
forks_count:          9,665                   (was 9,501)
open_issues_count:    596                     (was 552)
license.spdx_id:      AGPL-3.0                (unchanged)
archived:             False
```

`raw.githubusercontent.com/firecrawl/firecrawl/main/SELF_HOST.md` still reads:

```
- **API authentication: `USE_DB_AUTHENTICATION=false`.** Add authentication
```

Nothing material changed: license is the same, the project is still active and growing, and the self-host default is still keyless. The prior verdict's reasoning is unweakened by time.

### The operator's stated bar, answered directly

- **"Can it run entirely locally with no API key? This matters most."** — Self-hosted Firecrawl's default config (`USE_DB_AUTHENTICATION=false`) requires no key/auth at all, confirmed live today. But this is moot: self-hosting is *already* disqualified on independent grounds above (AGPL exposure on any modification, real multi-service infra, and a feature set *behind* what's already connected) — a keyless self-host would still be a strict downgrade from the status quo, not an improvement worth building.
- **"If any key is ever pasted or there in project, it should never go to claude or omni or anyone."** — No key-handling design is needed *now*: the currently-connected Firecrawl MCP tier is itself keyless (this session's own MCP tool description: *"Hosted keyless sessions expose `firecrawl_search`, `firecrawl_scrape`, and `firecrawl_parse` with usage limits"*), and the verdict here adds nothing that stores or transmits a credential. If a future, concretely-scoped need ever requires the higher-limit authenticated tier, the template to follow is already in this repo — `bin/heimdall-fallback`'s `operator_key_env` pattern (`bin/heimdall-fallback` lines ~60–160): store only the **name** of an env var, never a value; refuse any name that resolves to a Claude/Anthropic credential; every subcommand reports key presence, never the value. Not built here because nothing needs it yet — building it now would be evidence-free scaffolding.
- **Cost/complexity vs. what a research agent actually needs ("fetch this page, search that term")**: exactly the mismatch the prior doc's §3/§6 already quantify — a browser-pool + Redis + Postgres(+FoundationDB) stack to reach a feature set *narrower* than the already-connected hosted MCP, for a workload that's two native, already-shipped Claude Code tools.

### Verdict: REJECT (no new module, no manifest)

Part 1 already closes the measured gap (0 web-tool refs → 6 roles wired) at zero install cost, zero license exposure, and zero new infrastructure. Firecrawl's genuine differentiators (recursive crawl, JS-rendered scraping, schema-constrained extraction, batch/map, agentic multi-source research) are real, but the OSS self-hosted build that would satisfy the operator's self-host bar ships *fewer* of them than the hosted MCP already connected to this account — so self-hosting buys nothing even where those differentiators might someday matter. No `modules/firecrawl/manifest.json` is written; writing one would be a manifest without supporting evidence, which `modules/README.md`'s own tier rule calls "an advertisement," not a recommendation.

**This is a normal, respected outcome here** — consistent with the claude-mem (0% usage) and Headroom-fork (0.27–0.56%, inside rounding-error band) declines already on record. The door stays open exactly as the prior doc said: the moment a concrete, named workflow needs crawl-depth/JS-render/structured-extraction/batch that `WebFetch`/`WebSearch` genuinely can't do, re-open this with that workflow named — not speculatively, and not now.

---

## Sources

- `docs/analysis/2026-08-23-firecrawl-assessment.md` (prior assessment — full citation list inside that file)
- Live re-verification, 2026-09-05: `api.github.com/repos/firecrawl/firecrawl`, `raw.githubusercontent.com/firecrawl/firecrawl/main/SELF_HOST.md`
- This session's own MCP server-instructions block (`claude.ai Firecrawl` tool descriptions)
- `bin/heimdall-fallback` (`operator_key_env` name-only credential pattern, lines ~60–160)
- `modules/README.md`, `modules/_classes/tool-adapter.json`, `modules/_classes/traffic-proxy.json` (manifest schema, consulted to confirm no manifest is warranted without `tier_evidence`)
- `bin/lib/tier-table.json`, `bin/heimdall-tier` (`cmd_check`) — basis for not creating a new agent file
- `agents/architect.md`, `agents/database-architect.md`, `agents/incident-responder.md`, `agents/security-auditor.md`, `agents/seeker.md`, `agents/docs-writer.md` — this task's edits
- `agents/coder.md`, `agents/design.md`, `agents/fixer.md`, `agents/heimdall.md`, `agents/lint-quality.md`, `agents/planner.md`, `agents/reviewer.md`, `agents/test-runner.md`, `agents/verifier.md`, `agents/wave-executor.md` — read (frontmatter + body, or harness-generated description) for the exclude column, not modified

## OUT OF SCOPE

- Re-deriving the Firecrawl OSS-vs-Cloud feature comparison from scratch (already sourced and cited above)
- Legal review of AGPL-3.0 beyond the network-use clause already summarized in the prior assessment
- Building the Tier-1-style `operator_key_env` handling for Firecrawl (no concrete need exists to build it against)
- A new `agents/researcher.md` role (evaluated and declined — see Part 1 table)
- Adding an `INDEX.md` entry for this file or backfilling one for the pre-existing `2026-08-23-firecrawl-assessment.md` (INDEX.md is not in this task's assigned scope; 54 of the 57 git-tracked `docs/analysis/` files already have no INDEX.md entry, so this is consistent with existing convention, not a gap this task introduces)
- Fixing the `skills/designmatch` / `agents/design.md` skill-wiring gap noticed in passing (out of scope for this task; flagged here only for visibility)
