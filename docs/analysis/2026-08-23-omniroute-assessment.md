# OmniRoute integration assessment

**Date:** 2026-08-23 (assessed 2026-08-24) · **Repo:** `github.com/diegosouzapw/OmniRoute` (verified to exist and is exactly what the name suggests — a large, active, real LLM gateway)
**Ask:** route "easy/normal" tasks to free/cheap third-party channels via OmniRoute, reserving paid Claude capacity for hard work.

## Verdict: NO — do not integrate

All three disqualifiers the brief asked me to test trigger, and the first one triggers hardest:
OmniRoute's own shipped documentation states, in its own words, that the ToS-conflict flag on
its free-tier providers is **"advisory, not a routing gate"** — it routes real prompt content to
providers whose terms explicitly forbid proxy use, by default, with the safety check reduced to
a dashboard label the user has to notice. That is precisely the "routing client code to an
unknown third party [that] cannot be made safe by default" condition the brief said ends the
evaluation on its own (disqualifier 1). Disqualifiers 2 and 3 independently support the same
answer: this repo already runs sonnet-by-default with opus reserved for adjudication (measured
86% sonnet / 14% opus across the 22 model-tagged task records in `.planning/metrics.jsonl`), so
the "easy work on a cheap channel" headroom a router could still capture is small and the data
here can't size it precisely; and the repo's own cost forensics show spend is driven by
turns × context carried per turn (one 15-day session at 82.8% of all measured spend, 95.56% of
all tokens served from Anthropic prompt cache), a lever a router does not touch and can actively
work against — see §4. This is a clean, evidence-supported "no," in the same family as the
headroom/RTK/claude-mem declines this repo has already made after measurement, and it should be
treated the same way: not revisited without new facts.

---

## 1. What OmniRoute actually is

Verified directly via `gh`-equivalent API calls (`api.github.com/repos/diegosouzapw/OmniRoute`) and
the repo's own README/docs at tag `release/v3.8.50`, fetched 2026-08-24:

| Fact | Value | Source |
|---|---|---|
| Description | "Free MIT AI gateway: one endpoint, 350 providers (90+ free), 1200+ models" | GitHub API `description` |
| Stars / forks / open issues / subscribers | 53,721 / 7,347 / 41 / 312 | GitHub API |
| Created / last push | 2026-02-13 → 2026-08-23 (active, same day as assessment) | GitHub API `created_at`/`pushed_at` |
| Licence | MIT | GitHub API `license` |
| Language | TypeScript | GitHub API |
| Contributors | 4,288 commits from the owner (`diegosouzapw`), long tail of 30 shown on the first API page from 40–219 commits each; README claims "450+ contributors" (unverified beyond the visible page) | `contributors` API, README |
| CI | 35 GitHub Actions workflows (`CI`, `CodeQL`, `DAST smoke (PR)`, `Build App`, `Deploy to VPS`, …), real `npm test` wired to `node --test` over `tests/unit/{api,auth,authz,build,cli,combo,compression,correctness,cors,db,guardrails,mcp,memory,runtime,security,...}` | `actions/workflows` API, `package.json` |
| Architecture | **Self-hosted local reverse-proxy / gateway**, not a client library. Runs on `localhost:20128`, exposes an OpenAI-compatible `/v1` endpoint any tool (Claude Code, Cursor, Copilot, …) points at; it then fans requests out across 350 backend providers. It is the OmniRoute *server* that is local — the providers it forwards to are not. | README "Works the second you install it," "tier-cascade" diagram |
| Provenance / lineage | Fork of `9router` + a TS port of `CLIProxyAPI` (43.6k★ Go project); credits ~15 other OSS projects for specific subsystems | README "Acknowledgements" |

This is a real, actively engineered, well-tested project, not an abandoned or misrepresented
repo. That is exactly why the disqualifiers below are load-bearing: the problem is not
maturity, it is what the tool is built to do.

---

## 2. Disqualifier 1 — data handling: FAILS, and fails hard

**Who receives the prompt on each route.** For the "free" tier this is the whole point of the
tool: your prompt goes to whichever of 42 free-tier provider pools / 495 models the router
picked (Pollinations, Kiro, Qoder, SiliconFlow, GLM-Flash, Baidu, Tencent, DeepSeek, Groq, and
dozens more), not to OmniRoute itself. OmniRoute's own privacy claims ("local-first," "zero
telemetry by default," "never phones home") describe the *local proxy process* — they say
nothing about, and cannot control, what each of those 42+ third parties does with the prompt
content once it leaves the local machine.

**OmniRoute's own audit says this is not safe by default.** `docs/reference/FREE_TIERS.md` ships
a "ToS attention table" the maintainers built by researching each provider's terms. It lists
**19 providers under an explicit "caution" heading** whose terms it quotes as directly
prohibiting proxy/resale/third-party use — e.g.:

- `groq`: "Services Agreement §6.3 prohibits reselling, sublicensing, or distributing API access"
- `fireworks`: "ToS explicitly prohibits proxy/intermediary use... Sections 2.1 and 2.2(i)(j)"
- `together`: "ToS Section 4.3(d) explicitly prohibits transferring, distributing, reselling, leasing, or offering the Services on a s[tandalone basis]"
- `siliconflow`: "ToS (Clause 3.4(e)(f)(p)) explicitly prohibits making the service available to any third party, reselling/sublicensing"
- `kiro`: "Kiro FAQ explicitly prohibits use with 'OpenClaw and similar tools that leverage third-party harnesses' — a self-hosted AI proxy (like OmniRoute) rou[tes exactly this way]"
- plus `blackbox`, `friendliai`, `modal`, `nlpcloud`, `ai21`, `agy` (Google Antigravity), `coze`, `iflytek`, `duckduckgo-web`, `featherless-ai`, `amazon-q`, `qwen-web`, `t3-web`, `muse-spark-web` (Meta)

A further ~40+ providers are tagged `caution`/`ambiguous`/`unknown` for the same reason with
lower confidence (`mistral`, `openrouter`, `nvidia`, `cerebras`, `cohere`, `huggingface`,
`vertex`, `baidu`, `tencent`, `doubao`, and more). Several of the Chinese-hosted free pools
(`baidu`, `tencent`, `siliconflow`, `glm-cn`, `doubao`) additionally require real-name ID
verification, and none of them carries any independently verified no-training/no-retention
guarantee — none was found, none is cited, and this report is not asserting one exists.

Critically, per the same doc (`FREE_TIERS.md` §"ToS attention table"): **"ToS flag is
advisory, not a routing gate. Providers marked `tos` are still included in routing and
combo/fallback by default."** The maintainers know their own tool routes to providers whose
terms forbid it, and ship it wired on by default anyway, with the mitigation being a label on a
dashboard page a user has to go look at. That is the textbook version of "cannot be made safe by
default."

**A second, sharper problem specific to this repo.** OmniRoute's "Tier 1 Subscription" fallback
explicitly repurposes **Claude Code, Codex, and Copilot subscription auth** as a backend for
arbitrary routed traffic (README tier-cascade diagram: "Tier 1 Subscription (Claude Code, Codex,
Copilot)"). hmd runs inside Claude Code. Wiring a tool whose documented design is to reuse a
Claude Code subscription's own OAuth session to serve non-Claude-Code traffic is very likely a
violation of Anthropic's own consumer terms for that product — the one thing this repo is least
positioned to shrug off. This was not one of the brief's three named disqualifiers, but it is
directly downstream of disqualifier 1 ("who receives the data / on what terms") and independently
sufficient to stop here.

**A third, independent red flag, also data-handling-adjacent.** OmniRoute ships an opt-in
**TPROXY MITM mode** (`docs/security/MITM-TPROXY-DECRYPT.md`) that installs a dynamically-issued,
per-SNI trust-anchor CA on the host and transparently decrypts arbitrary local HTTPS traffic at
the kernel level, specifically to capture traffic from processes that don't honor proxy env
vars. Root-only and off by default, per its own docs — but a tool whose feature set includes
"install a CA that can impersonate any HTTPS host, to decrypt whatever a client sends" is a
materially larger attack surface than "route some completions to a cheaper model," and it is not
something a coding-agent supply chain should carry for the stated goal.

**Conclusion on disqualifier 1: fails.** Default routing sends real prompt content to dozens of
providers OmniRoute's own research flags as ToS-prohibited, with the flag not gating routing;
one fallback tier is built to reuse Claude Code's own subscription session outside Claude Code;
and the project ships a root-CA MITM capability. None of this is disqualifying because the
project is disreputable — it is disqualifying because this is what the architecture *is*.

---

## 3. Disqualifier 2 — is "easy" separable, and how much headroom exists

The brief's premise checks out against this repo's own routing directive
(`CLAUDE.md` "Model routing (2026-08-11 directive)"): sonnet is the coding default, opus is
reserved for reviewer/verifier/security-auditor adjudication, and Fable 5 is escalation-only.
`.planning/metrics.jsonl` has 22 records carrying a `metric:"task"` + `model` field (all other
136 records are `parallelism` metrics with no model tag):

| model | count | share |
|---|---|---|
| sonnet | 19 | 86% |
| opus | 3 | 14% |

Of the 3 opus records, one is tagged `task_type:"review"` (adjudication, as directed) and two
are `task_type:"code"` at `effort:"max"` (plausible escalations after a looping failure, per the
directive's escalation path — the schema does not carry a distinct "escalated" boolean for these
two, so this is inferred from `effort:"max"` co-occurring with `task_type:"code"`, not confirmed
from a field, and I am not asserting it as measured).

**This is the number, and I will not extrapolate past it.** n=22 is too small to further split
"sonnet tasks" into "easy" vs "hard" with any defensible precision — the metrics schema does not
carry a difficulty label, and inventing a proxy (e.g., `wall_secs`, `retries`) to manufacture a
percentage here would be exactly the kind of estimate the brief told me not to make. What the
data *does* support: **the routing directive is already followed** (86% sonnet, not opus), so
whatever headroom a third-party free channel could additionally capture is bounded by "cheaper
than sonnet" on an already-mostly-sonnet workload, not "cheaper than opus" on an opus-heavy one.
That is consistent with the brief's hypothesis that the headroom may be near zero; I cannot
produce a specific percentage from this corpus and I am flagging that rather than guessing one.

---

## 4. Disqualifier 3 — does this address the measured cost driver

Verified against `docs/analysis/token-spend-forensics.md` (234 sessions / 3,830 requests /
$1,103.05, method independently re-checked in this pass — the doc's own dedup-by-`message.id`
methodology and its two independent aggregation passes agreeing to within 0.07% are documented
in the file itself):

- **Cost = turns × context, confirmed.** One 15-day session was $913.54 = 82.8% of all spend, at
  a mean context of 501,000 tokens/request and a peak of 998,857. $369.50 is shown as provably
  recoverable by capping context at ~150K — same repo, same working style, two days apart:
  731,707 mean context → $0.366/request vs 118,678 mean context → $0.0593/request, a measured
  **6.17×** difference from context alone, "nothing was skipped to get there" (doc's own words).
- **95.56% of all input tokens are cache-read**, at Anthropic's 0.1× cache-read multiplier — this
  is the mechanism that makes the current spend as low as it is relative to raw context size.
- The doc's own refuted-hypotheses section already killed "cache is being re-paid" (cache-read is
  95.56% of input, genuinely uncached input is 0.0023% of all tokens) — caching is already
  working close to optimally on the current single-provider setup.

**The $19,938.47-vs-$53.16 caching-vs-compression figure named in the brief**: I could not trace
this exact pair of numbers to a first-party computation inside `docs/analysis/` in this pass —
the closest artifact is `rtk-incorporation-assessment-2026-08-22.md`, which computes a lifetime
input+output spend of $20,210.44 on its own corpus and separately notes "consistent with the
$19,938.47 in the brief" (i.e., it corroborates a figure supplied to *that* analysis rather than
deriving it independently in view). **Marking this figure UNVERIFIED-but-plausible**: the
direction (cache reuse dwarfs compression) is independently supported by this pass's own read of
`token-spend-forensics.md` (95.56% cache-read ratio, cache genuinely working) and by
`rtk-incorporation-assessment-2026-08-22.md`'s finding that RTK — the strongest of the three
prior compression candidates — only reached ~3.32% of spend and headroom/caveman were
0.30%/0.49%. I am not asserting the exact dollar figures as independently re-derived here.

**Does OmniRoute address this driver? No — and it plausibly makes it worse.** A router changes
*which provider* answers a request; it does not touch how much context is carried into that
request. Two specific ways this cuts against the actual problem:

1. **It doesn't shrink turns × context.** The forensics doc's own ranking puts "context never
   reset" and "cache-write blow-up above 800K" as #1 and #2 by cost, both fixed by session
   hygiene (restart/compact at ~150K), not by choosing a cheaper backend for the same oversized
   context.
2. **Provider-hopping forfeits the thing that is already working.** Anthropic's prompt cache
   (0.1× cache-read pricing, 95.56% of all tokens in this corpus) is per-provider, per-session
   state. Every request OmniRoute reroutes to a different backend for a "free" answer starts that
   turn's context from zero on the new provider — it cannot benefit from Anthropic's
   accumulated cache, and depending on the alternate provider's own caching (undocumented per
   provider in this pass), may force a full-context re-send at a *worse* effective rate than a
   0.1×-cached Anthropic call, even where the sticker price per token is nominally "free." This
   is the opposite of fix #1 in the forensics doc's own ranked list ("cap context, don't reset
   providers").

Conclusion: the framing in the brief holds up against the forensics doc, and OmniRoute is aimed
at the wrong lever.

---

## 5. Smallest safe integration shape

Not applicable — the verdict is a flat no on disqualifier 1 alone, independently reinforced by 2
and 3. Per the brief's own instruction, this section is only owed if the verdict were anything
but flat no. I am not designing a narrow allow-list/opt-in shape here, because doing so would
require re-litigating disqualifier 1 provider-by-provider (auditing retention/training terms for
each of 42+ pools independently of OmniRoute's own admittedly-non-gating flag) — that is a
distinct, much narrower research task from "integrate OmniRoute," and nothing in this pass
found a subset of providers with both a verified no-train/no-retention guarantee *and* ToS
permission for proxy use *and* meaningful cost headroom beyond what disqualifier 2 already shows
is small. If that combination is ever found, it would not look like "integrate OmniRoute" — it
would look like a hand-picked, explicitly-consented `repo-policy allow_non_zdr_models`-style gate
per provider, the same pattern this repo already uses for Fable 5.

---

## Sources

- `gh api repos/diegosouzapw/OmniRoute` (stars/forks/issues/licence/dates), `.../contributors`, `.../commits`, `.../actions/workflows` — fetched 2026-08-24
- `raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/README.md`
- `raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/reference/FREE_TIERS.md`
- `raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/security/MITM-TPROXY-DECRYPT.md`
- `raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/package.json`
- `/Users/rj/Downloads/heimdall/docs/analysis/token-spend-forensics.md`
- `/Users/rj/Downloads/heimdall/docs/analysis/rtk-incorporation-assessment-2026-08-22.md`
- `/Users/rj/Downloads/heimdall/docs/analysis/2026-08-19-headroom-compression-diagnosis.md`, `headroom-did-it-help.md`
- `/Users/rj/Downloads/heimdall/docs/analysis/2026-08-22-reasoning-bank-wiring-decision.md`, `2026-08-22-capability-census.md`
- `/Users/rj/Downloads/heimdall/.planning/metrics.jsonl`
- `/Users/rj/Downloads/heimdall/CLAUDE.md` ("Model routing (2026-08-11 directive)")

## OUT OF SCOPE

- Per-provider retention/training legal review of all 350 OmniRoute-fronted providers (only the
  19 explicitly ToS-flagged-`caution` providers and a handful of others are quoted here; a full
  audit of all 350 was not performed and is not needed to reach this verdict)
- Benchmarking OmniRoute's actual routing/latency/quality behavior (moot given §2's disqualifier)
- Any code change, hook change, or config change — this is a read-only assessment
- Evaluating OmniRoute for uses outside hmd/Claude Code (e.g., as a personal tool unrelated to
  this repo) — out of scope for this ask
