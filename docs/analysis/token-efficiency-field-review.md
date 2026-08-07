# Token-efficiency field review — tracerml.ai and the broader technique surface

**Date:** 2026-08-08 · **Type:** research + proposal, read-only · **Status:** no behaviour changed
**Companion measurement:** `docs/analysis/token-spend-forensics.md` (separate agent, hmd's own
transcript-derived spend). This document does **not** measure hmd's live spend — it reviews one
vendor and surveys the technique field, then proposes against hmd's real surfaces.

Every number below is either (a) a byte count I measured in this repo, or (b) a figure quoted from a
cited URL. Nothing is estimated without being labelled an estimate. Token figures derived from byte
counts use the ~4-chars-per-token English heuristic and are marked `≈`.

---

## Verdict on tracerml.ai

**Tracer is not an observability or tracing layer, and it does not cut hmd's spend.** Despite the
name, Tracer is a YC-backed research lab whose shipping product, Echo, is an *inference endpoint*: a
single OpenAI-compatible URL (`https://echo.tracerml.ai/v1`, wire model `echo`) that routes each
request across "adaptively coordinated open-weight models" to spend less compute on easy work
([tracerml.ai](https://tracerml.ai/), [echo.tracerml.ai/docs/api](https://echo.tracerml.ai/docs/api)).
The only mechanism they document in technical detail is in their paper, TRACER
([arXiv:2604.14531](https://arxiv.org/abs/2604.14531)), and it is *narrower than the marketing*: it
trains a lightweight ML surrogate on an LLM's own production traces for **classification** tasks, and
gates deployment behind a "parity gate" that activates the surrogate only when its agreement with the
teacher LLM exceeds a threshold α — reporting 83–100% surrogate coverage on a 77-class intent
benchmark and full replacement on a 150-class benchmark. That is a genuinely good idea for
high-volume, low-cardinality *classification* traffic. It is not applicable to hmd, whose workload is
open-ended multi-file code generation with no recurring label space to distill. The product that *is*
applicable in principle — Echo — is inapplicable in practice for two hard reasons: hmd runs inside
Claude Code against Claude models, and Echo's own integration catalog lists only OpenCode as a
"production route validated" harness with every other row marked "Not certified" (Claude Code is not
on the list at all); and swapping frontier Claude models for open-weight substitutes is precisely the
quality change the owner ruled out as a hard requirement. Echo's own UI hedges the same way, labelling
its savings figure "Estimate only. Not an invoice or a quality claim." **One line: interesting lab,
real paper, wrong shape for hmd — adopt nothing, revisit only if hmd ever ships a high-volume
classification endpoint.** The one *idea* worth stealing is the parity gate as a pattern (§Proposal 6),
not the product.

### Real and documented vs. claimed without detail

| Claim | Status | Source |
|---|---|---|
| OpenAI-compatible endpoint, model `echo`, Chat Completions + stateless Responses, function tools, SSE | **Documented**, with curl/Python/JS examples and an error/rate-limit table | [docs/api](https://echo.tracerml.ai/docs/api) |
| OpenCode 1.18.9 validated as a production route; Codex/Cline/Roo/Continue/Goose/SWE-agent "Not certified" | **Documented**, explicitly self-limited | [docs/api](https://echo.tracerml.ai/docs/api) |
| Trace-trained surrogate + parity gate for LLM **classification**; 83–100% coverage | **Documented** in a peer-postable paper with benchmarks and a negative result (parity gate correctly *refuses* deployment on an NLI task) | [arXiv:2604.14531](https://arxiv.org/abs/2604.14531) |
| "Adaptively coordinated open-weight models" behind Echo — which models, what router, what allocation policy | **Claimed without mechanism.** No architecture, model list, or routing algorithm published | [tracerml.ai](https://tracerml.ai/) |
| "Better performance per token" / "1 + 1 > 2" / emergence from coordination | **Thesis, not result.** Their own FAQ concedes "emergence remains a hypothesis to test" and that the site animation "is not a live execution trace" | [tracerml.ai](https://tracerml.ai/) |
| Cost comparison vs. Claude in the Echo UI | **Self-hedged estimate**, explicitly reprices uncached list rates and excludes caching — i.e. it compares against the *worst case* for the competitor | [echo.tracerml.ai](https://echo.tracerml.ai/) |
| "TRACER OSS, 1k+ stars" GitHub org | **Unverified.** The `tracerml` GitHub org returns 404 from the API; the site's link target was not resolvable to a repo during this review | measured: `api.github.com/orgs/tracerml/repos` → `Not Found` |

The site is thin on the mechanism that matters for its headline (how Echo allocates). I am not going
to infer an architecture for it.

---

## What I measured in this repo

Hard byte counts, taken 2026-08-08 on `main`:

| Surface | Measured | ≈ tokens |
|---|---|---|
| `agents/heimdall.md` (orchestrator system prompt) | 59,062 B | ≈14.8k |
| `agents/architect.md` | 22,098 B | ≈5.5k |
| `agents/*.md` total (16 agents) | 144,204 B | ≈36k |
| `skills/**/*.md` total | 138,141 B | ≈34.5k |
| CLAUDE.md chain loaded per session | 4,947 B across 3 files | ≈1.2k |
| — of which `/Users/rj/CLAUDE.md` and `/Users/rj/Downloads/CLAUDE.md` | **byte-identical**, 767 B each | pure duplication |
| — plus 17 lines shared with `heimdall/CLAUDE.md` | third near-copy | pure duplication |
| Test suites discovered by `test/run-all.sh` | **300** `.sh` suites | — |
| `test/run-all.sh` output-compaction flags | **none** (`--include-live --no-retry --jobs --timeout --min --filter -h` only) | — |
| Agent frontmatter `description:` fields (loaded into main context) | 156–351 B each | already tight — not a problem |

Two structural findings matter more than any of those counts:

**Finding 1 — hmd already built a token-frugal protocol and never wired it to the agents.**
`PROTOCOL.md` specifies "Heimdall Token-Frugal Protocol v2.0.0" with six mechanisms, and the binaries
exist and are tested: `bin/heimdall-capsule` (≤10-line context capsules with transitive `depends`
hydration), `bin/heimdall-brief` (delta briefs — "NEVER the plan, NEVER prior conversation, NEVER
restated acceptance criteria"), `bin/heimdall-resolve` (symbol table), `bin/heimdall-blackboard`.
Its stated purpose is exactly the owner's problem: *"Three spawns in a wave → the plan is paid for
three times; ten waves → thirty times. That is the orchestration token tax this protocol exists to
kill."* But `grep -rl` for `heimdall-brief` and `heimdall-capsule` across `agents/`, `skills/`,
`hooks/`, and `commands/` returns **zero files**. The machinery is reachable only from
`bin/heimdall-protocol` and its own test suite. The agents that actually spend the tokens have never
been told it exists. This is the single largest gap in the repo and it requires no new code.

**Finding 2 — hmd's prompt-cache ordering is already correct, and I want to say so rather than
propose a fix it doesn't need.** Anthropic's cache hierarchy is `tools` → `system` → `messages`, and
a change at any level invalidates that level and everything after it
([prompt-caching](https://docs.claude.com/en/docs/build-with-claude/prompt-caching)). hmd's volatile
per-turn injection (`bin/parallel-gate`) emits via `hookSpecificOutput.additionalContext`, which
Claude Code appends into the *turn's messages* — after the stable prefix, not into `system`. The
agent prompts themselves are static files. So the classic cache-buster (a timestamp or session ID in
the system prefix) is **not** present. The statusline runs outside the prompt entirely. No proposal
here; this one is already right.

---

## Ranked proposals

Ranked by (saving × confidence) / risk. "Saving" is qualitative where I have no measurement — I am
not going to attach a fake percentage to an unmeasured surface. Quantify these against the companion
`token-spend-forensics.md` before acting on any of them.

| # | Technique | Mechanism against hmd's actual surface | Est. saving | Quality risk | hmd already? | Source |
|---|---|---|---|---|---|---|
| 1 | **Compact test-suite tool results** | `test/run-all.sh` discovers **300** suites and has no `--quiet`/`--json`/summary flag (measured). Every full-suite run pipes the whole per-suite table plus red bodies into context, and hmd's quality gate makes agents run it repeatedly. Add `--json` (machine summary) and `--quiet` (counts + red suites only); point agent prompts at them. Full output stays on disk and stays one `cat` away. | **High** — largest single tool-result payload in the repo, paid on every verification pass | **None → positive.** Pass/fail verdict is unchanged; the agent grades on exit code, and red bodies are still shown. Anthropic: shrinking low-signal context *improves* recall ("context rot") | **No** | [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) |
| 2 | **Wire the already-built delta-brief + capsule protocol** | Finding 1. `bin/heimdall-brief` and `bin/heimdall-capsule` are built, spec'd in `PROTOCOL.md`, tested, and referenced by **zero** agent prompts. Add invocation steps to `agents/wave-executor.md` (emit a capsule per completed task) and `agents/coder.md` (hydrate only the `depends` closure). Kills the "plan paid for N times per wave" tax the protocol was written to kill. | **High** — scales with wave count × spawn count | **Low-medium.** Over-compaction can drop a detail a later wave needed. Mitigate: capsules *supplement* the full task spec (which stays verbatim per the writing-plans no-incomplete-code rule), never replace it. Roll out on one wave and diff outcomes first | **Built, not wired** | `PROTOCOL.md`; measured grep |
| 3 | **Tool-result clearing between waves** | Anthropic ships server-side `clear_tool_uses_20250919`, which drops stale tool results (file contents, search output) once the model has processed them — "particularly useful for agentic workflows with heavy tool use". hmd's orchestrator accumulates every wave's tool output for the whole session. Enable context editing / compaction on the long-lived orchestrator loop. | **High** on long sessions — this is exactly the "10+ sessions" failure shape | **Low.** Clears *tool results*, not reasoning or decisions; hmd already persists wave state to `.planning/SUMMARY-*.md` on disk, so cleared results remain retrievable | **No** | [context editing](https://docs.claude.com/en/docs/build-with-claude/context-editing), [compaction](https://docs.claude.com/en/docs/build-with-claude/compaction) |
| 4 | **Retrieval instead of whole-file reads** | hmd already ships `bin/heimdall-ast` (real tree-sitter structural extraction for JS/TS/TSX/Python/Go/Rust) but no agent prompt directs orientation through it. Have `coder`/`architect` pull the structural surface first and Read only the spans they will edit. `agents/coder.md:38` currently just says "Read first (batched)" — batched, but still whole-file. | **Medium-high** — `agents/heimdall.md` alone is 59 KB; source files in this repo run comparable | **Medium — the real one.** An agent that never sees full context can miss an invariant. Mitigate: retrieval for *orientation*, mandatory full Read of any file being edited. Never let AST-only reads gate a correctness decision | **Tool exists, not wired** | measured; [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) |
| 5 | **Dedupe the CLAUDE.md chain** | `/Users/rj/CLAUDE.md` and `/Users/rj/Downloads/CLAUDE.md` are byte-identical (767 B each) and 17 further lines repeat in `heimdall/CLAUDE.md`. All three load every session. Collapse to one authoritative file. | **Low** (≈1k tokens/session) but **free** | **None.** Identical text; removing a duplicate changes no instruction | **No** | measured: `diff` |
| 6 | **Parity-gated cheap-model triage** (the one idea worth taking from Tracer) | hmd routes by *declared tier* (haiku/sonnet/opus per task, in `agents/architect.md`) but never *verifies* the cheap tier was adequate. TRACER's contribution is the gate, not the router: activate the cheap path only where measured agreement with the expensive path exceeds α. hmd has the substrate — `bin/falsify`, `evals/oracles/`, `bin/corpus` — to measure tier agreement on its own corpus and demote task classes only where agreement is proven. | **Medium**, and it is the only proposal that *raises* confidence in existing routing | **Low by construction** — the gate's entire purpose is refusing to demote when quality would drop. TRACER's own NLI result is a case where the gate correctly refused | **Routes by tier; does not gate** | [arXiv:2604.14531](https://arxiv.org/abs/2604.14531) |
| — | Prompt-cache-friendly ordering | Verified already correct (Finding 2) — volatile hook context goes to `messages`, prompts are static files | n/a | n/a | **Yes** | [prompt-caching](https://docs.claude.com/en/docs/build-with-claude/prompt-caching) |
| — | Sub-agent context isolation | Subagents already run with their own context windows + worktree isolation; parent pays only for the returned summary | n/a | n/a | **Yes** | [multi-agent system](https://www.anthropic.com/engineering/multi-agent-research-system) |
| — | Cheap-model triage by tier | Already in `agents/architect.md` (haiku→low / sonnet→default / opus→high/max) with an escalate-one-tier-on-failure rule | n/a | n/a | **Yes** | `agents/architect.md` |

### Field context worth holding onto

Anthropic's own multi-agent writeup is blunt about the cost shape hmd lives in: *"agents typically use
about 4× more tokens than chat interactions, and multi-agent systems use about 15× more tokens than
chats"*, and token usage alone explained **80%** of performance variance on BrowseComp
([multi-agent-research-system](https://www.anthropic.com/engineering/multi-agent-research-system)).
Two consequences for hmd. First, a 15× multiplier is the *expected* cost of the architecture, not a
defect — the owner burning sessions on simple tasks is partly the orchestration tax working as
designed, and the fix is scoping simple tasks *out* of the wave machinery, not shrinking the waves.
That same post prescribes it directly: *"Scale effort to query complexity … Simple fact-finding
requires just 1 agent with 3-10 tool calls"*, and names overinvestment in simple queries as a common
early failure mode. Second, because token spend *correlates with quality*, every proposal above is
deliberately confined to removing **low-signal** tokens (duplicated instructions, stale tool results,
suite output the agent already reduced to an exit code) rather than reasoning budget. Cutting
reasoning tokens would cut quality, which is out of bounds.

Pricing anchor for any future estimate: cache reads cost **0.1×** base input, 5-minute cache writes
**1.25×**, 1-hour writes **2×**
([prompt-caching](https://docs.claude.com/en/docs/build-with-claude/prompt-caching)) — so a stable
prefix like `agents/heimdall.md` (59 KB, ≈14.8k tokens) is cheap *after* its first write, and the
recurring burn is almost certainly volatile tool results, not system prompts. Confirm against
`token-spend-forensics.md` before spending effort on prompt-size reduction.

---

## Red flags in this review

- Proposals 1–5 carry **no measured saving**, only a measured *surface size*. Ranking them is a
  judgement call until the companion forensics doc lands. Do not cite these rows as savings figures.
- Proposal 4 is the only one with real quality risk, and it is ranked below three safer wins
  deliberately. If only three things get done, do 1, 2, 3.
- The "1k+ stars" TRACER OSS claim on tracerml.ai could not be verified (org 404s). I did not treat
  it as evidence either way.
- I did not run `test/run-all.sh` (constraint), so the 300-suite figure is a discovery count, not an
  observed output volume.

---

## OUT OF SCOPE

- Measuring hmd's live token spend — that is `docs/analysis/token-spend-forensics.md` (companion agent).
- Implementing any proposal above. This document is research + proposal only; no hmd behaviour changed.
- Adopting Echo or any non-Claude inference endpoint — ruled out by the hard quality requirement.
- Reducing reasoning/thinking budgets, agent count, or verification passes — these buy tokens with
  quality, which is out of bounds.
- Rewriting `agents/heimdall.md` for size. It is a stable cached prefix at 0.1× read cost; shrinking
  it is likely the *lowest*-yield change available and risks dropping load-bearing instructions.
- Prompt-cache breakpoint placement — hmd does not control `cache_control` from inside Claude Code,
  and its ordering is already correct (Finding 2).
- Any change to `evals/oracles/`, `bin/falsify`, or the corpus gates beyond the Proposal 6 sketch.
