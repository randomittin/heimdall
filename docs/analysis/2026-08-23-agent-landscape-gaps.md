# GitHub `ai-agents` topic survey — what hmd genuinely lacks

**Date:** 2026-08-23 (assessed 2026-08-24) · **Repo:** `/Users/rj/Downloads/heimdall`, tip `97e301e` · **Ask (verbatim):** "https://github.com/topics/ai-agents -- see here what all is truly missing and what all can be picked to improve"
**Production code changed by this task: NONE.** Read-only except this document.

## Method, and its limits — stated up front, not buried

**Constraint confirmed structurally, not just asserted.** This invocation (`hmd:architect`, spawned via `Agent`) exposes exactly `Read, Write, Edit, Bash, Skill` — no `WebFetch`, `WebSearch`, or `firecrawl_*` function is in my tool schema, matching the prior 43,347-tool-call/367-transcript scan cited in the dispatch brief that found zero web-tool invocations by any dispatched role, ever. I additionally grepped every `agents/*.md` frontmatter `tools:` line and `hooks/hooks.json` in this repo directly (not from memory): **zero agent role definitions carry `WebFetch` or `WebSearch`.** This is a structural, repo-wide fact, not a per-session accident.

**Workaround used, and its honest limit.** `curl` inside `Bash` reached `api.github.com` and `github.com` fine in this sandbox (verified: `HTTP:200` on both `github.com/topics/ai-agents` and the search API). I queried `api.github.com/search/repositories?q=topic:ai-agents` (sorted by stars, base query + `+eval`/`+sandbox`/`+orchestration`/`+memory`/`+cost` sub-slices) rather than scraping the rendered topics HTML page, which is JS-templated and not reliably `curl`-parseable. **This is real GitHub Search API data, fetched live in this session — but it is a keyword/star-sort slice of a 77,095-repo topic, not an exhaustive survey.** I did not page past the top ~30 per query, did not read full source of any candidate beyond its README/description, and did not independently verify star counts against a second source (several — e.g. 242,588★ for `affaan-m/ECC` — are higher than any real-world repo I have prior knowledge of as of my training cutoff; I am reporting what the API returned and flagging the anomaly rather than silently normalizing it away). Anything below sourced only from a description string is marked as such. Where I could check hmd's own repo state directly (grep, file reads), I did, and that evidence is stronger than anything sourced from a README blurb.

## What hmd already has (established before claiming any gap)

Read directly: `README.md`, `bin/heimdall --help`, all 16 `agents/*.md`, `hooks/hooks.json`, `skills/`, plus five prior audits in `docs/analysis/` dated 2026-08-22/23. Confirmed present and real (not claimed-only — cross-checked against the capability census's LIVE/REACHABLE/ORPHANED/CLAIMED-ONLY framework):

- Parallel agent orchestration in git worktrees, wave-based execution (`agents/wave-executor.md`), up to 10 background subprocesses
- Falsifiable oracle gates with a registry (`bin/oracle-select`, `bin/falsify --assert-score 1.0`), differential > trace-diff > verdict > property > example ranking enforced at plan-verification
- A deterministic, no-vector-store AST/symbol-graph tool (`bin/heimdall-graph`: def/refs/callers/callees/impact/outline) — REACHABLE but 0/384 measured invocations per `docs/analysis/2026-08-22-capability-census.md`
- A tree-integrity guard, quota advisory, presence/team wall, delta-brief context compression, checkpoint/resume
- A self-improvement loop (`skills/self-improve/`, `bin/heimdall-self-improve`) with an explicit sample-size floor (a 3-sample routing comparison clears a 0.10 delta ~73% of the time by chance — the documented reason the floor exists) and a keep-only-with-measured-delta discipline ported from karpathy/autoresearch
- An A/B holdout telemetry mechanism (`bin/heimdall-holdout`) that refuses to print an unmeasured comparison number, and a bespoke benchmark harness (`bin/heimdall-vm-bench`) comparing a verified-memory retrieval method against three baselines on a git-true labeled fixture — both real evaluation-harness infrastructure, both narrow-scope (self-improve routing / one memory subsystem) and both 0/384 measured invocations
- A cost telemetry stack — but pointed at hmd's OWN control-plane infra spend (`bin/heimdall-cost-report`: Firestore + Cloud Run $/day, alerts at 50/75/90% of a $10k/mo budget) and a weekly re-validation model (`bin/heimdall-cost-model-refresh`), NOT at forecasting a given user task's token cost before it runs
- `bin/heimdall-tokens`: post-hoc, per-session token/cost accounting from transcripts — measured after a run, never before one

## Ranked findings

### 1. Sandboxed/containerized execution isolation for the code an agent runs — BUILD (low cost, real gap)

**What in the landscape does it:** `daytonaio/daytona` (71,904★, "Secure and Elastic Infrastructure for Running AI-Generated Code"), `steel-dev/steel-browser` (7,531★, "batteries-included browser sandbox"), `ComposioHQ/composio` (29,850★, "a sandboxed workbench"), `astrid-runtime/astrid` (10,271★, "capability-secure operating system for composable software") — a full, populated category (1,295 repos under `topic:ai-agents+sandbox`) of tools whose entire job is "isolate what the agent's generated code can touch."

**Measured hmd gap.** `agents/wave-executor.md` frontmatter declares `isolation: worktree` — this isolates *git state* (so parallel tasks don't collide on the same file) and nothing else: no filesystem jail, no network egress control, no process/resource ceiling on the code an agent runs. Grepping the entire `bin/` and `agents/` tree for `docker|container|sandbox` (excluding tests) returns exactly one hit, `bin/lib/real-home.sh` — which detects whether a process is running under a *real* `$HOME` for launchd-targeting reasons, the opposite of execution sandboxing. `Dockerfile.install` exists but only wraps the *installer*, not runtime task execution. **hmd's own `SECURITY.md` says this explicitly, unprompted** (line 79): issues requiring `--dangerously-skip-permissions` are scoped as "issues that require a user to run [it] in a throwaway sandbox (that flag is documented as autonomy with no safety classifier in the loop)" — i.e., hmd's security boundary document already assumes the user supplies the sandbox; hmd does not provide one.

**Cost.** A real container/VM runtime dependency (Docker, gVisor, Firecracker, or a hosted equivalent) is a materially larger addition than anything declined in the last 48 hours — daemons, image builds, a new failure surface, and (per the same 48 hours' pattern) exactly the class of background-process risk this repo just spent two days paying down (32 orphaned processes at load 6.23). This is not free.

**Verdict: BUILD, scoped narrowly.** Not "adopt Daytona" (a hosted third-party service is a new data-egress and trust-boundary question this repo's own disqualifier framework would fail on sight, the same shape as the OmniRoute decline). The concrete, scoped version: extend the *existing* `Dockerfile.install` pattern from install-time to task-execution-time — a `hmd wrap --sandbox <tool>` mode that runs the wave-executor's actual `git commit`-producing work inside a container with the repo mounted and network egress limited to the model API, opt-in and off by default (mirroring how `headroom` shipped: disclosed, not silently defaulted on). This is the one item on this list I'd call genuinely missing *and* worth building, because it is the one place where "the agent runs arbitrary code with full user privileges" is a stated-but-unmitigated risk in hmd's own threat model, not a speculative one.

### 2. Pre-run cost forecasting for a user's task — DECLINE (real gap, but low value against the measured cost driver)

**What in the landscape does it:** `mikehasa/agentacct` (623★, "See what your coding agents did and what it cost... Local-first dashboard"), `SethGammon/Citadel` (909★, "cost telemetry, and parallel agent fleets"), `cobusgreyling/loop-engineering`'s `loop-cost` tool (10,609★) — a populated but smaller category (1,147 repos under `topic:ai-agents+cost`), mostly post-hoc dashboards, not pre-run estimators.

**Measured hmd gap, confirmed real.** hmd has extensive cost *telemetry* (`heimdall-tokens`, `heimdall-cost-report`) but every one of them is post-hoc (reads a completed session transcript or yesterday's actual spend). Nothing in `bin/` estimates "this plan's N waves × M tasks will cost approximately $X" before a wave-executor spawn. Confirmed by reading `heimdall-cost-report`'s own header comment: it models hmd's *infrastructure* $/day (Firestore + Cloud Run), unrelated to a user's per-task model spend.

**Why this still doesn't clear the bar.** `docs/analysis/token-spend-forensics.md` (cited in the omniroute-assessment doc, re-checked there) already identified the actual cost driver as **context carried per turn**, not task count or task selection: one 15-day session was 82.8% of all measured spend at a mean 501K-token context, and capping context at ~150K is independently shown to cut cost 6.17× on the same repo. A pre-run cost *estimate* doesn't touch that lever — it would tell you a number before the fact, but the number's dominant variable (how much context balloons mid-session) is exactly what a static pre-run estimate cannot see, since it's a property of how long the session runs and how well `/compact` discipline holds, not of the task description. Building an estimator would produce a number that is routinely wrong by the same multiple the forensics doc already quantified, creating false confidence rather than removing a real blocker.

**Verdict: DECLINE for now.** The measured problem ("spend is unpredictable") is real, but the fix that already exists and is proven to work (context-capping / session hygiene) addresses it more directly than a forecaster would, and a forecaster built on the wrong variable would mislead rather than help. Revisit only if a future audit finds token spend varies primarily by *task selection* rather than *session length* — the opposite of what's measured today.

### 3. Web research / browser tools for dispatched agent roles — ALREADY-DECLINED (do not re-litigate)

**What in the landscape does it:** `browser-use/browser-use` (110,276★), `steel-dev/steel-browser` (7,531★), `ntegrals/openbrowser` (9,514★) — a large, real category.

**Measured hmd gap:** confirmed twice now — the 43,347-tool-call/367-transcript scan (zero web/fetch/firecrawl calls, ever) and, in this task, a direct grep of every `agents/*.md` `tools:` line (zero `WebFetch`/`WebSearch` grants anywhere). The gap is real and structural.

**Verdict: ALREADY-DECLINED, correctly.** `docs/analysis/2026-08-23-firecrawl-assessment.md` (dated the same day as this brief) already reached the right conclusion on this exact question: zero measured demand across the entire corpus, so there is nothing to build *for* yet. That doc's own scoped caveat stands and I re-affirm it rather than re-deriving it: if a *specific, named* workflow needs web content inside a spawned role, grant that one role the built-in `WebFetch`/`WebSearch` (zero infra, zero licence exposure, already part of Claude Code) — evaluated when that workflow is designed, not granted blanket and speculatively now. Vendoring a browser-automation project (self-hosted or otherwise) would repeat the Firecrawl doc's finding: capability nobody has asked for, at real infra cost (steel-dev and browser-use both require a browser runtime).

### 4. Multi-repo / cross-project orchestration — DECLINE (real gap, not measured as a problem)

**What in the landscape does it:** `stablyai/orca` (51,996★, "ADE for working with a fleet of parallel agents... desktop, mobile and VPS"), `rowboatlabs/rowboat` (17,379★), `kestra-io/kestra` (27,900★, "Event Driven Orchestration... Mission Critical") — real, but the majority of what surfaces under `topic:ai-agents+orchestration` is *multi-agent-on-one-codebase* orchestration (crewAI, oh-my-openagent), which hmd already does (waves, `--team N`).

**Measured hmd gap, confirmed by direct inspection.** `agents/wave-executor.md`'s `.planning/PLAN-{phase}.md` model and `bin/heimdall-team`/`heimdall-team-converge` both operate within or across *humans on one repo* (team presence, shared secret scoped to a single repo's `team_id`), not across *multiple distinct codebases* in one task (e.g., "this fix touches the API repo and the client SDK repo"). `heimdall --team N "task"` spawns N parallel workers in tmux on **one** repo, confirmed from `bin/heimdall --help`. Grepping for `multi-repo|cross-repo` in `bin/` returns only team-presence fallback UX strings ("for cross-repo / non-GitHub teammates use `hmd invite`") — identity sharing, not work orchestration.

**Verdict: DECLINE.** No transcript, journal entry, or metrics record in this repo's own history shows a task blocked on needing two repos in one plan. This is the same "solution seeking a problem" shape the OmniRoute/Firecrawl/RTK declines already established as this repo's bar. Worth re-raising only if a concrete multi-repo task is attempted and fails for exactly this reason — not before.

### 5. General-purpose LLM-judge / rubric eval harness for arbitrary agent output — ALREADY-HAVE (narrow), gap is scope not category

**What in the landscape does it:** `future-agi/future-agi` (1,797★, "Tracing · Evals · Simulations · Datasets · Gateway · Guardrails"), `benchflow-ai/awesome-evals` (838★), `YutoTerashima/agent-safety-eval-lab` (310★) — a populated category under `topic:ai-agents+eval` (1,014 repos), oriented around tracing + scored eval datasets, not just pass/fail.

**Measured hmd gap — smaller than it looks.** hmd already has: (a) `agents/verifier.md`'s PASS/FAIL-with-evidence report plus mandatory falsifiability proof (`bin/falsify --assert-score 1.0`) before any oracle gate counts; (b) `agents/reviewer.md`'s APPROVE/REQUEST CHANGES/BLOCK judgment; (c) `bin/heimdall-self-improve`'s measured-delta-over-baseline loop with a sample-size floor; (d) `bin/heimdall-vm-bench`'s labeled-fixture benchmark comparing methods against baselines with a `measured|est.|blank` provenance discipline. This is a real, working, better-than-most-projects' eval discipline for the specific things hmd already scores: acceptance-criteria correctness, oracle falsifiability, and self-improve routing deltas.

**What's genuinely missing:** none of the above evaluates code *quality* along axes acceptance criteria don't capture (idiom fit, maintainability, security posture *beyond* what security-auditor's checklist already covers) via a standing labeled benchmark replayed on every routing/prompt change — the "does changing the coder agent's prompt make its OUTPUT worse across 50 known cases" question a `future-agi`/`benchflow-ai`-style eval suite answers. hmd's two eval mechanisms (`heimdall-holdout`, `heimdall-vm-bench`) are both wired to one subsystem each (self-improve routing, verified-memory) and both show 0/384 measured invocations — built, correct, unused.

**Cost of building the general version:** a labeled benchmark corpus is real, ongoing maintenance (someone has to write and keep curating the 50 cases), and the two purpose-built precedents hmd already has are sitting unused — a strong signal that building a third, broader one would land in the same orphaned state without first fixing *why* the first two aren't invoked, which is a wiring problem, not a missing-capability problem.

**Verdict: ALREADY-HAVE the mechanism, DECLINE building a broader one until `heimdall-holdout`/`heimdall-vm-bench` show measured use.** The right next step, if any, is wiring the existing harnesses into a trigger point (e.g., `/hmd:self-improve` invoking `heimdall-vm-bench` automatically when a memory-subsystem change is proposed) — not building a fourth eval mechanism.

### 6. Codebase knowledge graph — ALREADY-HAVE, unused

**What in the landscape does it:** `Graphify-Labs/graphify` (109,854★, "Turn any codebase... into a queryable knowledge graph... local deterministic AST parsing, every edge explained, no vector store").

**Measured hmd finding:** `bin/heimdall-graph`/`bin/heimdall-ast` already implement exactly this shape (def/refs/callers/callees/impact/outline, deterministic AST-based, no vector store — confirmed by reading the tool's own header). The capability census independently found this REACHABLE-but-0/384-invocations. This is not a gap; it's an unused asset. **Verdict: ALREADY-HAVE — the fix is adoption (agents should be told to `heimdall-graph outline` before reading a file whole), not a new build.**

### 7. Managed AI-gateway / multi-provider routing — ALREADY-DECLINED

`diegosouzapw/OmniRoute` (53,902★) headlines this category. `docs/analysis/2026-08-23-omniroute-assessment.md` already declined this in depth (ToS-violating default routing, Claude Code subscription reuse risk, MITM CA capability, and — independent of the safety concerns — it targets the wrong cost lever per the forensics doc). No new evidence in this survey changes that. **Verdict: ALREADY-DECLINED, do not re-litigate.**

### 8. Agent memory layers (mem0, cognee) — ALREADY-DECLINED

`mem0ai/mem0` (63,900★), `topoteretes/cognee` (30,201★) headline this category. The dispatch brief itself already cites the relevant finding: claude-mem's active-query feature shows 0 adoption across ~40 spawns in this repo. Adding a *second* competing memory layer on top of one already measured as unused would compound the same failure mode, not fix it. **Verdict: ALREADY-DECLINED (by extension of the claude-mem finding) — fix adoption of what's installed before adding another.**

## The one paragraph on the single highest-value addition

**Sandboxed/containerized task-execution isolation (finding #1).** It is the only item on this list that is simultaneously a measured, structural, self-acknowledged gap (hmd's own `SECURITY.md` names the missing mitigation in its own words) and cheap to scope narrowly: extend the install-time `Dockerfile.install` pattern to an opt-in `hmd wrap --sandbox` execution mode, rather than adopting a third-party hosted sandbox service (which would fail this repo's own data-egress disqualifier the way OmniRoute did). Every other candidate on this list is either already declined with good evidence, already built and sitting unused, or aimed at a cost lever this repo has already proven isn't the dominant one.

## The one paragraph on what hmd should deliberately NOT add

**A general-purpose multi-provider AI gateway or a second agent-memory layer.** Both categories are large and popular in the `ai-agents` topic (OmniRoute at 53,902★, mem0 at 63,900★), and both have already been evaluated against this repo's own measured evidence and declined — OmniRoute for routing real prompt content to ToS-prohibited free-tier providers by default while targeting a cost lever (provider choice) the forensics data shows isn't the actual driver (context-per-turn is), and a second memory layer because the one already installed (claude-mem) is measured at zero adoption across ~40 spawns. Adding either would be optimizing for landscape popularity over this repo's own measurement discipline — the exact failure mode the last 48 hours of assessments in this directory were built to catch.

## OUT OF SCOPE

- Re-running or re-verifying the Firecrawl, OmniRoute, RTK, or claude-mem assessments already completed in this directory — their verdicts are cited, not re-derived
- Designing the scoped `hmd wrap --sandbox` implementation named in finding #1 (a follow-on design task, not part of this survey)
- Independently re-verifying GitHub star counts against a second data source — the anomaly (several counts exceeding known real-world repos) is flagged in the Method section, not resolved
- Paging past the top ~30 results per search query, or reading full source of any landscape candidate beyond its README/description string
- Any code, hook, permission, or config change — this is a read-only survey plus the one permitted document
