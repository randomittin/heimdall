# Firecrawl integration assessment

**Date:** 2026-08-23 (assessed 2026-08-24) · **Repo:** `github.com/firecrawl/firecrawl`, HEAD verified against `main` on 2026-08-24 · **hmd tip at assessment time:** `71bd0b7`
**Ask (verbatim):** "deeply analyse this: https://github.com/firecrawl/firecrawl and add it to the mix the same way, maybe by utilizing the code or via integrating"

## Answer to the framing question first: what does vendoring/self-hosting buy over the MCP already wired?

**Nothing material, and self-hosting is a strict downgrade on two axes (licence exposure, operational cost) for zero measured capability gain.** The Firecrawl MCP server is already connected at the account level in this environment (`firecrawl_scrape`, `firecrawl_search`, `firecrawl_map`, `firecrawl_agent`, `firecrawl_agent_status` — confirmed present in this session's own MCP server-instructions block) and its unauthenticated endpoint already exposes Search/Scrape/Parse. Self-hosting the OSS repo would only be worth it to get capability the hosted/MCP path lacks — and by Firecrawl's **own** published comparison (§3 below), the OSS self-hosted build is *missing* capability the Cloud/MCP path has (Agent, Browser, Interact, managed anti-bot), not the reverse. There is no delta in hmd's favor: self-hosting adds AGPL-3.0 exposure (§2) and a multi-service browser-pool stack (§3) to *reach a feature-poorer* version of what is already one API call away. Verdict: **(a) use what's already wired, integrate nothing** — see §6 for the one caveat worth naming.

---

## 1. What Firecrawl is

Verified via `api.github.com/repos/firecrawl/firecrawl` and the repo's own `main`-branch files, fetched 2026-08-24:

| Fact | Value | Source |
|---|---|---|
| Description | "The context API to search, scrape, and interact with the web at scale" | GitHub API `description` |
| Stars / forks / open issues | 171,428 / 9,501 / 552 | GitHub API |
| Created / last push | 2024-04-15 → 2026-08-23 (active, day before assessment) | GitHub API `created_at`/`pushed_at` |
| Language | TypeScript | GitHub API |
| Archived | false | GitHub API |
| Top-level layout | `apps/api`, `apps/playwright-service-ts`, `apps/redis`, `apps/nuq-postgres`, `apps/go-html-to-md-service`, 8 language SDKs (`js`, `python`, `go`, `rust`, `ruby`, `php`, `java`, `dot-net`, `elixir`), `docker-compose.yaml`, `SELF_HOST.md`, `firecrawl-cli`, `skills/` (agent-skills for calling the API, not for scraping itself — see §5) | `contents/` API |

Real, active, very large project — maturity is not in question. The question is capability parity and cost, not legitimacy.

---

## 2. Licence — checked carefully, per the brief's flag

**Root licence: AGPL-3.0** (`LICENSE` file, confirmed via both GitHub API `license.spdx_id: AGPL-3.0` and the raw file text). AGPL-3.0's network-use clause requires anyone who runs a *modified* version of the code as a network service to publish that modified source to the service's users — the exact "sub-licence split" precedent the brief flagged.

**The split is real and documented by the maintainers themselves.** README §License, verbatim:
> "This project is primarily licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). The SDKs and some UI components are licensed under the MIT License. See the LICENSE files in specific directories for details."

Practical read: the core scrape/crawl engine (`apps/api` and friends) is AGPL — copyleft, network-triggering. The client SDKs (`js-sdk`, `python-sdk`, etc.) are MIT — safe to vendor/import as a *client of* someone else's Firecrawl instance (self-hosted or cloud) without AGPL obligations, because calling a remote API over HTTP is not "distributing" or "modifying" the AGPL server code.

**Implication for hmd:** using the MCP tools or an SDK against Firecrawl's *hosted* API (or a third party's self-hosted instance) carries no AGPL exposure — hmd is a client, not a distributor of modified AGPL code. **Self-hosting and modifying `apps/api`** (e.g. to add a hmd-specific auth shim or output format) would put hmd in AGPL's network-service clause and obligate publishing the modified source to every user of that internal service — a real constraint "for a tool other people install," exactly as the brief anticipated. Since §1/§6 conclude there is no reason to self-host at all, this exposure is avoidable by simply not doing so, but it is the correct reason to reject option (c) (vendor/self-host) outright rather than on cost grounds alone.

---

## 3. Self-host requirements and OSS-vs-Cloud feature parity

**Self-host is real infrastructure, not a `docker run`.** Per `docker-compose.yaml` (`main`, fetched 2026-08-24), the stack is: `api` + workers, `playwright-service-ts` (a dedicated headless-browser microservice, `cpus: 2.0`, `mem_limit: 4G`, its own `tmpfs`), `redis`, `nuq-postgres` (Firecrawl's own Postgres-backed job queue, "NuQ"), and an optional FoundationDB backend for the queue. `SELF_HOST.md` (`main`) states this plainly: *"At this revision, Compose runs the Firecrawl API and workers, Playwright, Redis, RabbitMQ, NuQ PostgreSQL, and FoundationDB services... Self-hosting gives you source and infrastructure control. You also own security, availability, capacity, upgrades, data retention, and compliance."* No persistent volumes are defined by default; the API is unauthenticated by default (`USE_DB_AUTHENTICATION=false`).

**The OSS build is explicitly, deliberately reduced relative to Cloud — this is Firecrawl's own stated positioning, not an inference.** From `docs.firecrawl.dev/contributing/open-source-or-cloud` (fetched 2026-08-24), the maintainers' own comparison table:

| Capability | Open source (self-host) | Firecrawl Cloud |
|---|---|---|
| Core scrape/crawl/map/search APIs | Included | Included and managed |
| Fetch and Playwright processing | Included in the default stack | Managed |
| LLM-backed extraction/formats | Connect your own OpenAI-compatible/Ollama provider | Managed provider path |
| **Advanced anti-bot / specialized extraction** | **Run and configure the required service separately** | **Managed where Cloud supports it** |
| **Agent, Browser, Interact, dashboard, enterprise controls** | **Not included in the default stack** | **Included by product/plan** |
| Security, persistence, availability, upgrades | You own them | Firecrawl operates them |

And the maintainers' own recommendation, same page: *"start with Firecrawl Cloud unless source access or infrastructure control is worth the operational work."*

This directly answers the brief's maturity/parity question: **no, the OSS build is not feature-equivalent to the hosted API** — most notably, `firecrawl_agent` (multi-source research) and any "advanced anti-bot" capability the MCP tools rely on are Cloud-managed surfaces the self-hosted stack either lacks outright or requires the operator to separately stand up and pay for (Firecrawl's own commercial anti-bot engine is not part of the open-source repo). Self-hosting to get "the same thing as the MCP" does not, by the vendor's own account, get you the same thing.

---

## 4. What problem in hmd would this solve? Tested against each candidate, sceptically

**Candidate A — agent web research.** `WebFetch`/`WebSearch` are Anthropic-native tools and the Firecrawl MCP is already connected — but structurally scanning this repo's own transcript history (not grepping text; see method below) shows **zero calls to any web/fetch/firecrawl tool, ever, by any role, in this corpus**: 367 `.jsonl` transcripts across the main session and all `--claude-worktrees-agent-*` sub-agent sessions, 43,347 tool-bearing lines, tool_use histogram dominated by `Bash` (3,565), `Read` (1,280), `Agent` (458), `Grep` (404) — `WebFetch`/`WebSearch`/`firecrawl_*` count: **0**. No tool-grant record for those names appears either. **A second, self-demonstrating data point from this very task**: I am `hmd:architect`, spawned via `Agent`/`Task` to do exactly this kind of investigation, and my own tool list for this invocation is `Read, Write, Edit, Bash, Skill` — no `WebFetch`, `WebSearch`, or `firecrawl_*` function was exposed to me. Every fetch in this assessment (GitHub API, raw README/LICENSE/docs pages) was done via `curl` inside `Bash`, not via the "already wired" MCP tools the brief's framing describes. So the framing's premise — "live tools available to hmd's agents right now, with no integration work" — is true for whatever interactive/top-level session holds the account-level MCP connection, but **not measurably true for the dispatched worker fleet** (architect/coder/reviewer/verifier), which has never called it, by grant or by use, in this whole corpus. That cuts against "just use the MCP" as a *fleet-wide* answer, but it does not support vendoring Firecrawl either — the fix, if a concrete need ever appears, is granting the already-built-in `WebFetch`/`WebSearch` tools to the specific spawned role that needs them, which is a permissions change, not an integration. Net: **zero measured demand for web content in 43,347 tool calls; no case to build for.**

**Candidate B — ingesting library docs into `skills/stacks/`.** Checked directly: `skills/stacks/` contains exactly 4 hand-authored packs (`fastapi`, `nextjs`, `react-native`, `spring-boot`) plus `README.md`/`SKILL.md` — 6 files total, zero references to `scrape`, `WebFetch`, or `WebSearch` anywhere in the directory. **Nothing today consumes scraped or fetched documentation** — there is no pipeline this would plug into; building one would be new, unscoped work, not "integrating Firecrawl into an existing consumer."

**Candidate C — seeker/fixer / `/hmd:maintain` context enrichment.** Corroborated from this repo's own journal: `.planning/journal/2026-08-23-*.md` records *"One label set severed the pipeline. seeker filed issues as 'bug,seeker'; the engine's..."* and `.planning/journal/2026-08-22-*.md` records *"...calls — not disinterest, a severed connection."* The brief's specific figure (severed until 2026-08-24, 432 `Agent` calls with zero spawns across the severed halves) traces qualitatively to these same journal entries; the exact "432" was not independently re-derived in this pass and is carried as the brief's own figure, marked **UNVERIFIED (qualitative direction corroborated, exact count not re-counted here)**. Either way, the conclusion holds without needing the exact number: **adding a web-scraping dependency to a pipeline that has a documented history of not running is premature** — fix the pipeline first; a dependency added to a broken loop cannot be evaluated for whether it helps.

None of the three candidates survive contact with what already exists in this repo.

---

## 5. On the `skills/` directories in the Firecrawl repo

Firecrawl ships `skills/`, `firecrawl-skills/`, `firecrawl-cli-skills/` at repo root. Read directly (not assumed from the names): these are **Claude/agent "build skills" for writing product code that calls the Firecrawl API** (`skills/README.md`, verbatim: *"agent skills for integrating Firecrawl APIs into product code (SDKs, REST, endpoint selection, API keys)"*), installed via `npx skills add firecrawl/skills --skill firecrawl-build`. They are not scraping skills, not self-host skills, and not a shortcut around needing an API key (hosted or self-hosted) — they teach an agent to wire an existing Firecrawl instance into a codebase. Interesting as a category (a vendor shipping install-on-demand skills for its own API) but orthogonal to this decision: they don't change §1–§4's conclusion, since hmd has no concrete workflow that needs Firecrawl's API at all yet.

---

## 6. The three disqualifiers, applied

1. **Data handling.** Both the MCP's unauthenticated endpoint and any self-hosted default deployment send scraped page content to the URL's own host (that's what scraping does) and, for the MCP path, to Firecrawl's own hosted infrastructure. This is opt-in by construction — a tool must explicitly call `firecrawl_scrape`/`firecrawl_search`/etc. with a specific URL; it is not a default-on data path the way OmniRoute's provider fan-out was. **Passes**, conditioned on staying opt-in and per-call (never wiring it as an always-on default for every agent turn).
2. **Does it address a measured problem?** No. §4's structural transcript scan found zero web/fetch/firecrawl tool_use records across 367 transcripts / 43,347 tool-bearing lines — no evidence any agent role has ever been blocked on web content. **Fails** — this is uncontested "solution seeking a problem" territory, the same shape as the OmniRoute/RTK/headroom declines this repo has already made after measurement.
3. **Operational cost.** Only triggers under the self-host path (option c), which §2–§3 already rule out on licence and feature-parity grounds independently. The MCP path (option a) has zero operational cost to hmd — Firecrawl operates that infrastructure. Given this repo just measured **32 live orphaned processes at load 6.23** from unrelated per-project temp-HOME leakage (`.planning/journal/2026-08-22-*.md`) and spent real effort eliminating background-daemon leaks, standing up a browser-pool + Redis + Postgres + optional-FoundationDB service stack for a capability nothing has asked for would be adding exactly the class of operational surface this repo just paid down. **N/A for (a), disqualifying for (c).**

---

## Verdict

**(a) — use the already-wired MCP, integrate nothing**, with one narrow, explicitly-scoped caveat: if a *specific, named* future workflow needs web content inside a spawned sub-agent (not the interactive top-level session), the correct fix is granting that role the built-in `WebFetch`/`WebSearch` tools (zero infra, zero licence exposure, already part of Claude Code) for that one role, evaluated on its own merits when that workflow is actually designed — not a blanket grant made now speculatively, and not Firecrawl specifically, since §3 shows the OSS repo would arrive feature-*behind* the MCP that is already present. This is not "(b) thin wrapper" because no named workflow exists yet to wrap; it is not "(c) vendor/self-host" because that is a licence and infrastructure downgrade with no offsetting capability; it is not a hard "(d) decline forever" because the door stays open the moment a concrete, measured need shows up — it is simply not open today.

---

## Sources

- `api.github.com/repos/firecrawl/firecrawl` (stars/forks/issues/licence/dates/language) — fetched 2026-08-24
- `raw.githubusercontent.com/firecrawl/firecrawl/main/LICENSE`, `/README.md`, `/SELF_HOST.md`, `/CONTRIBUTING.md`, `/docker-compose.yaml`, `/skills/README.md`, `/firecrawl-skills/README.md` — fetched 2026-08-24
- `api.github.com/repos/firecrawl/firecrawl/contents/` (root, `apps/`, `skills/`, `firecrawl-skills/`, `firecrawl-cli-skills/`) — fetched 2026-08-24
- `docs.firecrawl.dev/contributing/open-source-or-cloud` (OSS-vs-Cloud comparison table, maintainers' own recommendation) — fetched 2026-08-24
- This session's own MCP server-instructions block (`claude.ai Firecrawl` tool descriptions: `firecrawl_scrape`, `firecrawl_search`, `firecrawl_map`, `firecrawl_agent`, `firecrawl_agent_status`, unauthenticated-endpoint limits)
- Structural scan (Python, `json.loads` per line + `message.content[].type == "tool_use"`, not text grep) over `/Users/rj/.claude/projects/-Users-rj-Downloads-heimdall*/*.jsonl` — 367 files, 43,347 tool-bearing lines, 0 `json.loads` errors, 0 web/fetch/firecrawl tool_use records found
- This invocation's own tool list (`hmd:architect`, spawned via `Agent`): `Read, Write, Edit, Bash, Skill` — no `WebFetch`/`WebSearch`/`firecrawl_*` present
- `/Users/rj/Downloads/heimdall/skills/stacks/` (directory listing — 6 files, no scrape/fetch references)
- `/Users/rj/Downloads/heimdall/.planning/journal/2026-08-22-haid_rj.rishabhs-macbook-air-46d5.md` (32-orphans/load-6.23 figure), `/Users/rj/Downloads/heimdall/.planning/journal/2026-08-23-haid_rj.rishabhs-macbook-air-46d5.md` (seeker label-severed-pipeline note)
- `/Users/rj/Downloads/heimdall/docs/analysis/2026-08-23-omniroute-assessment.md` (structure/precedent for this doc's format and the "disqualifiers" framing)
- `/Users/rj/Downloads/heimdall/.mcp.json` (confirms this repo's own committed MCP config wires only `heimdall-ledger`; Firecrawl/Figma are account-level connections, not repo-level)

## OUT OF SCOPE

- Legal review of AGPL-3.0 obligations beyond the network-use clause already summarized (this is not a substitute for counsel if hmd ever *does* modify and redistribute `apps/api`)
- Benchmarking Firecrawl's scrape/crawl quality or latency against `WebFetch`/`WebSearch` (moot — §4 found zero measured demand for either)
- Designing the seeker/fixer or `/hmd:maintain` pipeline fix referenced in Candidate C (a distinct, already-tracked repair task, not part of this ask)
- Any code, hook, permission, or `.mcp.json` change — this is a read-only assessment plus the one permitted document
- Auditing Firecrawl's own data-retention/training policy for the hosted API in depth beyond the unauthenticated-endpoint description already surfaced in this session's MCP instructions
