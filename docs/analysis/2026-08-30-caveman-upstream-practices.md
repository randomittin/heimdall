# Caveman upstream (JuliusBrussee/caveman): what they do differently

Source: https://github.com/JuliusBrussee/caveman (public GitHub, read via `gh api`, no clone). 101,843 stars; last push 2026-08-29T22:17Z. Root license `other` (split MIT/BSL-1.1, see `LICENSING.md`). Version pin observed: `2.4.0` (root `package.json`, matches `install.sh` URL in README).

Every claim below is tagged:
- **MEASURED** — I ran something myself against this repo/tooling.
- **READ-FROM-SOURCE** — read directly in upstream's files (README, LICENSING.md, docs/*, directory listings, package.json, workflow filenames). Not independently re-verified by running upstream's code.
- **NOT VERIFIED** — inferred or stated by upstream without me confirming it.

No BSL-1.1-covered code was copied into this repo. Nothing here proposes vendoring BSL code. Where a recommendation would require BSL code, it is flagged explicitly (see §6).

## 0. What "caveman" actually is now (not just a skill)

**READ-FROM-SOURCE.** The repo we vendored the skill from has grown into a multi-component product line ("Caveman 2"):

| Component | Dir | License | What it is |
|---|---|---|---|
| Response skill | `skills/caveman/` | MIT | The original prompt-injection skill (what heimdall vendored) |
| Caveman Engine | `engine/` | BSL-1.1 | Local deterministic content-type compressor + byte-exact recovery store |
| Caveman Proxy | `proxy/` | BSL-1.1 | Local HTTP(S) proxy that routes agent↔provider traffic through Engine |
| Reflection rewriter | `rewriter/` | BSL-1.1 | Engine-linked rewrite/recovery-gate layer (see §2 crux) |
| Cache engine | `cacheengine/` | BSL-1.1 | Provider prompt-cache planner/wire-format handling (Anthropic/OpenAI/Bedrock) |
| Shrink | `shrink/` | BSL-1.1 | Compresses noisy CLI command output, byte-recoverable |
| Browse | `browse/` | BSL-1.1 | Local Chrome driver emitting compressed a11y-tree instead of full DOM/ARIA |
| MCP server | `mcp/` | BSL-1.1 | Exposes `caveman_compress`/`retrieve`/`stats`/`toon_encode`/`toon_decode` as MCP tools |
| `caveman-compress` skill | `skills/caveman-compress/` | MIT | Memory-file compression skill, separate from the response skill |
| `caveman-learn` | (agent/CLI feature) | — | Reads local agent-history logs read-only, scores a "Cave Score," proposes fixes with consent + re-measure + auto-revert-if-worse |
| Pixel mode | `engine/pixel/` | BSL-1.1 | Renders installed SKILL.md bodies to PNG so the model reads an image instead of full text each load |

This directly answers **Q1**: the "skill" heimdall vendored is a small fraction of what upstream ships. The bulk of upstream's engineering investment is in the BSL-licensed local proxy/engine stack, not the prompt-injection skill.

## 1. The crux question: is this mechanical compression, or just a fancier prompt?

**Answer: both exist, and they are architecturally distinct. This falsifies the general form of "a hook can only inject text" — but only for upstream's proxy/engine, not for the skill, and not for heimdall's own installed plugin.**

**READ-FROM-SOURCE**, `engine/README.md`:

> "Compression changes what model sees, so Engine stores original bytes locally before emitting lossy result. Agent can retrieve exact original later."

Pipeline as documented:

```
agent context → detect content type → matching compressor →
store original locally (recovery handle) → smaller context returned to agent
```

- `detect()` classifies payload shape: JSON, logs, code, diffs, search results, text, HTML, tables, config, tool schemas, tool-schema annotations, TOON, accessibility trees, repetition, terminal output — **15 compressors in the default registry** (READ-FROM-SOURCE, `engine/README.md`).
- This is **deterministic, type-specific mechanical transformation** of the actual bytes sent to the provider — done by a local proxy sitting between the agent and the model API, not by asking the model to behave differently. That is categorically different from a hook that injects instruction text into context (which is all heimdall's installed plugin does, and all the original MIT skill does).
- Recovery ("CCR"): original bytes are kept in local storage (`CAVEMAN_CCR_MAX_BYTES`, default cap 512 MiB) and retrievable via a handle; at cap, engine "fails closed" to pass-through-original rather than silently dropping recoverability (READ-FROM-SOURCE, `engine/README.md`).
- **Explicit fail-safe discipline, stated directly**: "If input cannot be parsed, recovery storage is unavailable, or result is not smaller in tokens, Engine returns original unchanged and claims nothing." (READ-FROM-SOURCE, `engine/README.md`). This is a real quality property — it will not report a fake win.
- **Labeling discipline on the numbers this component itself produces**: "Token reductions are local `o200k_base` estimates labeled `inferred`; they are not provider bills or verified savings." (READ-FROM-SOURCE, same file). Upstream does not let its own engine claim more certainty than it has.

**Unresolved nuance (honest gap):** `rewriter/` ("Engine-linked reflection rewriter and recovery gates," BSL-1.1) contains `gate.go`, `prompt.go`, `provider.go`, `rewriter.go`, `tokens.go` (READ-FROM-SOURCE, directory listing). The presence of `prompt.go` and `provider.go` strongly suggests this layer calls out to an LLM provider for a "reflection" pass, i.e. a *second*, model-based rewriting mechanism layered on top of the deterministic Engine compressors, gated by `gate.go` (presumably validating that a rewrite didn't lose required content before it's allowed through). **NOT VERIFIED**: I did not fetch `rewriter/README.md` or the Go source itself in this pass, so I cannot confirm the rewriter is LLM-based rather than another deterministic transform. Filed here as the one open thread rather than asserted as fact.

Net effect on the crux: **the "hook can only inject text" claim is true only of heimdall's specific implementation (a text-injection plugin) and of caveman's original skill.** It is not a universal law of "AI coding tool compression" — upstream proves a local proxy *can* mechanically rewrite wire payloads while preserving recoverability. Heimdall does not have (and per license, cannot simply copy) an equivalent mechanism; it would have to build one, as its own original work, if it wanted equivalent guarantees.

## 2. What upstream's compression mechanism claims and measures (Q2 continued)

**READ-FROM-SOURCE**, `docs/WRAP-BENCHMARK.md` ("CaveBench Wrap benchmark," generated `2026-08-06T14:31:43Z`):

- Claim: Caveman-wrapped Claude Code used **33.2% fewer provider-reported input tokens** than direct Claude Code across 18 paired runs (591,673 vs 885,793 tokens), passing 18/18 exact-answer checks. 95% CI (case-clustered bootstrap): **14.6%–48.5%**.
- Explicitly labeled `benchmark_counterfactual` — upstream's own middle evidentiary tier, explicitly **not** claimed as "a provider invoice, or Caveman `verified_savings`."
- Method is unusually disclosed for an open-source README: 6 fixed MCP fixtures (60–95 KB each: logs, deployment JSON, fraud CSV, test output, config YAML, dashboard HTML), 3 reps × 3 arms (direct / Caveman / a competitor "Headroom") = 54 runs, pinned Claude Code version `2.1.223`, model `claude-sonnet-5`, exact `modelUsage` counter formula stated (`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`), fixture called exactly once per run, corpus/harness/binary SHA-256 hashes published, git commit of harness pinned (`630e157...`).
- **Negative result kept in the aggregate, not hidden**: the HTML fixture case *regressed* -9.9% ("HTML regressed because no compression transform applied while full Caveman skill overhead remained counted") and is left in the table rather than excluded.
- **Explicit non-reproducibility admission**: "This repository contains published report and provenance hashes, but not raw harness or run artifacts for this result. It cannot be independently reproduced from this checkout." Upstream states its own publication bar (≥6 cases, ≥3 reps, exact quality tracked per run, 95% CI entirely above zero, no removing negative/no-op cases) and admits this specific result doesn't yet meet full reproducibility, only the reporting bar.

This is a materially more rigorous public disclosure than a typical "we save X%" marketing README.

## 3. Quality practices upstream has that heimdall does not (Q3)

**READ-FROM-SOURCE / MEASURED (via `gh api` directory listings):**

1. **A three-arm eval harness with a corrected methodology, explained in the open.** `evals/README.md`:
   - Arms: `__baseline__` (no system prompt), `__terse__` ("Answer concisely."), `<skill>` ("Answer concisely." + full SKILL.md).
   - States plainly: "The honest delta for any skill is `<skill>` vs `__terse__`... Comparing a skill to the no-system-prompt baseline conflates the skill with the generic terseness ask, **which is what an earlier version of this harness did and is why its numbers were inflated.**" This is a documented self-correction of their own prior overclaiming — rare to see stated this directly in a README.
   - Snapshot-based: `llm_run.py` calls real Claude Code once per (prompt × arm) and commits `snapshots/results.json` to git; `measure.py` reads the committed snapshot with `tiktoken o200k_base` and runs in CI with **no API key and no network call** — deterministic, free, reviewable as a diff.
   - Explicitly lists what it does **not** measure: fidelity/semantic equivalence ("a skill that replies `k` to everything would score −99% and win"), latency/cost, cross-model behavior, exact Claude tokenization (tiktoken is an approximation), statistical significance (single run per cell, no power analysis). This "what this does not measure" section is a level of self-scrutiny heimdall's own `bin/heimdall-caveman-compliance` doc does not currently carry.

2. **A dedicated, skeptical "Honest Numbers" page** (`docs/HONEST-NUMBERS.md`) that is essentially a savings-claims audit of their own product:
   - States the skill's input-token reduction is **0%** ("It's an output-style instruction") and that it **costs** ~1–1.5k input tokens/turn (SKILL.md injection).
   - Cites three real GitHub issues as counter-evidence: #145 (net loss on terse coding Q&A), #506 (GitHub Copilot bills per-request, so a shorter answer saves zero Copilot credits), #550 (a Cursor user's A/B showed 4.3M tokens with caveman vs 1M without, 2x wall clock — flagged as possibly a measurement artifact, but published anyway with "Exact run was not reproducible, so only safe conclusion is that rule re-injection, retries, and cache or context accounting can overwhelm output savings").
   - Ends with an explicit "when caveman loses" section and a literal instruction to turn the tool off if your own A/B is net-negative.

3. **A three-tier evidentiary framework applied consistently across all publicized numbers**: `inferred` (local estimate, e.g. Engine's own token math) → `benchmark_counterfactual` (controlled/pinned benchmark, e.g. the 33.2% figure) → `verified` (signed receipts from a not-yet-shipped "Caveman Cloud" with eval gates and rollback-on-quality-loss). Every number in the README/docs is tagged with one of these, and upstream states outright that offline caveman never reaches `verified`.

4. **Test surface breadth** (MEASURED, directory listings): `tests/` (~19 files, mixed Python/JS, includes `test_compress_safety.py` and `test_compress_concurrency.py`), `evals/` (own harness + `snapshots/`), `benchmarks/` (separate Python harness: `prompts.json`, `run.py`, `results/`), plus per-BSL-package Go `*_test.go` suites in `engine/`, `proxy/`, `rewriter/`, `cacheengine/`, `shrink/`, `browse/`, `mcp/` — several with their own nested `evals/`/`testdata`/`safety` subdirs (e.g. `engine/evals/`, `engine/safety/`). `browse/BENCHMARK.md` documents a specific, reproducible-looking number: 121 tokens vs. 15,704-token Playwright ARIA baseline (129.8x).

5. **CI as multiple purpose-built workflows, not one monolith** (MEASURED, `.github/workflows` listing): `ci.yml`, `engine-ci.yml`, `profiles.yml`, `provider-catalog.yml`, `release-binaries.yml`, `release-packages.yml`, `sync-skill.yml` — separate pipelines for the Go engine, provider-profile compatibility, release binaries, release packages, and skill-sync, rather than one undifferentiated test job.

What heimdall has that is comparable or arguably better in one respect: `bin/heimdall-caveman-compliance` reads back actual model output for a *measured filler floor* (3.25%) rather than relying on self-reported/estimated token counts — i.e., heimdall measures compliance with the instruction, where upstream's `evals/` measures the instruction's raw effect size. These are different, complementary things; upstream does not appear to have an equivalent "did the model actually comply with the injected rules" auditor for its skill layer — its rigor is concentrated on the engine/proxy's mechanical guarantees, not on measuring LLM instruction-following fidelity for the skill.

## 4. Delivery practices (Q4)

**READ-FROM-SOURCE / MEASURED:**

- Current pinned version: `2.4.0` (root `package.json`; matches the `install.sh` URL pin in README, so docs and package manifest agree).
- Multiple install surfaces, each suited to a different adoption depth: `npm install -g @caveman-ai/cli && caveman setup --install` (full), `npx skills add JuliusBrussee/caveman` (skill-only, any of 30+ skills-compatible agents), `curl .../install.sh | bash` / `install.ps1` (full installer, Unix/Windows), Claude Code plugin marketplace (`claude plugin marketplace add ... && claude plugin install caveman@caveman`), Gemini CLI extension. Full matrix lives in `INSTALL.md` (not fetched this pass).
- Dedicated release workflows separate binary releases (`release-binaries.yml`) from package releases (`release-packages.yml`) — implies these are versioned/shipped independently, consistent with a monorepo housing both Go binaries and JS/npm packages.
- `docs/PACKAGE_RELEASES.md` exists (title implies a documented release process) — **not fetched this pass**, so cadence/changelog discipline specifics are **NOT VERIFIED** beyond "a dedicated doc and dedicated CI workflow for it exist."
- Ecosystem is explicitly staged, not all shipped at once (README's "the whole cave" framing, READ-FROM-SOURCE): caveman (live), caveman-browse (live, separate repo), caveman-agent-sdk (in dev), cavegemma (labs-stage, a fine-tune baking compression into weights), caveman-code / cavemem / cavekit (explicitly marked **frozen**, with their useful ideas folded back into the main repo rather than left as abandoned parallel products). This is a disciplined way to avoid a sprawl of half-maintained repos — dead ends are marked dead, not left ambiguous.
- BSL-1.1 change date is fixed and public: **2030-06-21, or 4 years after a given version's first public release, whichever is earlier** — so every BSL file has a knowable, bounded date at which it becomes Apache-2.0. This is a real, verifiable commitment, not an open-ended "trust us."

## 5. Savings-claim scrutiny (Q5)

Two headline numbers exist and upstream itself keeps them from being conflated:

| Claim | Value | Tier | What it actually measures | Caveat stated by upstream |
|---|---:|---|---|---|
| Skill benchmark table (README) | 65% avg, 10 tasks | implicitly `inferred`/harness-based | **Output** tokens only, skill vs (per `evals/README.md`'s corrected method) a terse-instruction control | Skill adds ~1–1.5k input tokens/turn; can go net-negative; input reduction is 0% |
| CaveBench Wrap (`docs/WRAP-BENCHMARK.md`) | 33.2% (CI 14.6–48.5%) | `benchmark_counterfactual` | **Input** tokens (incl. cache buckets), Engine+proxy+skill combined, pinned 54-run/18-pair suite | Not reproducible from this checkout (no raw artifacts published); one fixture (HTML) regressed −9.9% and is left in |

**Verdict: this is not unsubstantiated marketing.** Upstream (a) separates two different numbers that measure two different things instead of blending them, (b) publishes a named methodology with a stated corpus, pinned software versions, and hash provenance for the harder number, (c) keeps a negative case in the aggregate rather than cherry-picking, (d) maintains a whole separate page (`HONEST-NUMBERS.md`) whose explicit purpose is to argue against its own product in some workloads, citing real user-reported net losses by issue number. The repeatable weak point is that the 33.2% figure explicitly **cannot be independently reproduced today** from the public checkout — it's a pinned report with hashes, not a runnable benchmark — so it sits between "trust the number" and "verify the number yourself," and upstream says so outright rather than implying reproducibility it doesn't yet have.

Compared to heimdall's stance (refuse to claim a savings number at all, publish only a measured *filler floor*): upstream is doing something harder and arguably more useful — publishing numbers *with* honest uncertainty bounds and counter-examples — rather than declining to publish. Silence isn't more honest than a well-caveated number; it's just a different, more conservative choice. Both are legitimate, but upstream's approach gives users more to act on.

## 6. Recommendations

### Adopt (architecture/practice, not code — no BSL dependency)

1. **Corrected-baseline eval methodology.** Heimdall's own compliance tooling should make sure its filler-floor measurement is compared against the right control (a plain "be concise" instruction, not "no instruction at all") — upstream's own README admits they got exactly this wrong once (`evals/README.md`). This is a documented failure mode heimdall can avoid for free just by knowing about it. Pure methodology, zero code dependency, zero BSL exposure.
2. **A "when this loses" page for heimdall's own caveman tooling**, modeled on `docs/HONEST-NUMBERS.md`'s structure: state explicitly the cases where compression instruction overhead can exceed savings (e.g., very short exchanges, tools that bill per-request/per-message rather than per-token, contexts where the injected rule text itself is a nontrivial fraction of the turn). This is pure documentation discipline, not code.
3. **Explicit evidentiary tiering on any number heimdall publishes** — adopt upstream's inferred / benchmark_counterfactual / verified vocabulary (or heimdall's own equivalent) as a standing convention so every measured/claimed number in `bin/heimdall-caveman*` output and docs is self-labeled with its own confidence tier, the way heimdall already labels this very document's claims MEASURED/READ-FROM-SOURCE/NOT VERIFIED. This is a documentation-and-CLI-output convention, not code to import.
4. **Committed-snapshot eval pattern** for any future heimdall benchmark of its own compression/compliance tooling: run once against a real model, commit the raw output as a fixture, then have CI re-derive metrics from the committed snapshot with no network call and no API key. Cheap, deterministic, reviewable as a diff — same idea heimdall could apply to `heimdall-caveman-compliance`'s own regression testing.

### Deliberately do NOT adopt

1. **Do not build or vendor a mechanical compression proxy to match `engine/`+`proxy/`.** This is real, substantial, BSL-1.1-licensed engineering (Go, 15 compressors, a byte-exact recovery store, wire-level provider integration). Building an equivalent is a multi-month systems project, not a documentation or prompt change, and copying upstream's implementation is explicitly off the table under the license and under this task's constraints. If heimdall ever wants mechanical (not prompt-based) compression, it would need to be designed and built from scratch as heimdall's own work — this doc does not recommend starting that project; it only flags that the *idea* (detect-then-dispatch-to-type-specific-compressor, with local recoverable storage) is sound and could be reimplemented independently if a future task calls for it.
2. **Do not chase the 33.2%/65% numbers as targets.** Both are workload-specific, pinned-benchmark numbers with explicitly bounded applicability (upstream says so itself). Treating them as a general performance bar to hit would repeat exactly the kind of context-free number-chasing upstream's own `HONEST-NUMBERS.md` warns against.
3. **Do not adopt a "Caveman Cloud"-style `verified` tier with signed receipts** unless heimdall actually stands up server-side eval-gated infrastructure to back it — an unearned "verified" label would be worse than heimdall's current honest silence on savings numbers.

### Where upstream is genuinely ahead

- **Self-correction culture, stated in public.** The `evals/README.md` admission of a prior inflated-baseline bug, and `HONEST-NUMBERS.md`'s citation of real GitHub issues showing their own tool losing, are not things most projects publish. Heimdall's own self-measured 3.25% filler-floor finding is philosophically the same instinct (measure honestly, publish even if it's not flattering) — upstream just has more of this, spread across more surfaces, over more time.
- **Mechanical compression with recoverability guarantees exists and works as a real product**, not a research prototype — this is a genuine capability gap versus heimdall's text-injection-only approach, acknowledged in §1 above.
- **Reproducibility provenance discipline** (hashes for corpus/harness/binary/commit, explicit "cannot be independently reproduced from this checkout" admission) on their hardest benchmark claim is a stronger practice than most open-source READMEs, heimdall's current docs included.

No part of this doc found "little that applies" — upstream has substantial, specific practices worth learning from, mostly on the documentation/methodology side (§6 Adopt), with one clear capability gap (mechanical compression) that is real but not something to close by copying BSL code.
