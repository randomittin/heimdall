# Token-stack remeasure: headroom, claude-mem, auto-skills vs. what already works

**Date measured:** 2026-08-24 (repo main tip `c054600`) · **Method:** read-only against live
state on this machine — `~/.headroom/*`, `~/.claude-mem/claude-mem.db`,
`~/.claude/projects/-Users-rj-Downloads-heimdall*` (866 main-corpus + 237 worktree transcript
files, 1,103 total scanned), and this repo's own `docs/analysis/*.md`.

**Headline, first paragraph as requested:** all three candidates (headroom compression,
claude-mem active retrieval, auto-generated skills) are rounding errors or exact zeros next to
the two things already working. Prompt caching: **$22,375.72** lifetime cache-savings on
headroom's own proxy ledger (traceable, see §4), against **$63.95** lifetime compression
savings from the identical ledger — caching outperforms compression **350×**, measured from one
file. Context discipline: **$369.50** provably recoverable on a single 15-day session by capping
context at ~150K (`docs/analysis/token-spend-forensics.md`, unchanged, re-cited not re-derived).
Headroom compression's own lifetime aggregate is **0.331%** of total input tokens. claude-mem's
active per-task query has never run in production (1 invocation, ever, out of the entire
corpus). Auto-generated skills have **zero** recorded invocations, ever. None of the three
candidates clears the bar the two working mechanisms already cleared by two to four orders of
magnitude.

---

## 1. Headroom — is it firing, and what has it saved?

**Yes, it is firing continuously** (live proxy, PID confirmed via `ps aux`, `/health` reports
`"status":"healthy","ready":true`, `kompress backend=onnx`). The prior $53.16/176-events figure
cited in the task brief is **not headroom's number** — it is the number from
`~/.heimdall/headroom/proxy.log`, the exact trap this task warned about
(`docs/analysis/2026-08-19-headroom-compression-diagnosis.md` documents this misattribution in
detail — hmd's own stdout-redirect log captures only the `diff_compressor` Rust component's
logger, never `kompress`, which does nearly all the real compression work). Confirmed fresh,
right now:

```
$ grep -ic kompress ~/.heimdall/headroom/proxy.log   → 0   (structurally cannot show kompress)
$ grep -ic kompress ~/.headroom/logs/proxy.log.1     → 7   (the real log can)
```

**Authoritative source: `~/.headroom/proxy_savings.json`** (headroom's own persistent lifetime
ledger, updated on every request, 55,242 requests, started 2026-08-06T09:15:45Z, last activity
2026-08-23T19:02:33Z):

| Metric | Value |
|---|---|
| Lifetime requests | 55,242 |
| Lifetime `tokens_saved` (compression) | 16,286,676 |
| Lifetime `compression_savings_usd` | **$63.95** |
| Lifetime `cache_read_tokens` | 5,600,244,667 |
| Lifetime `cache_savings_usd` | **$22,375.72** |
| Lifetime `total_input_tokens` | 4,916,066,167 |
| Lifetime `total_input_cost_usd` (what was actually billed) | $7,129.56 |
| **Compression as % of total input tokens** | **0.331%** |
| **Cache savings ÷ compression savings** | **349.9×** |

This is the corrected version of the earlier $53.16 figure: it grew to **$63.95** over the
additional days of traffic since that snapshot — consistent growth, not a contradiction.

### The "does it collapse as context warms" question

I re-derived this from `~/.headroom/savings_events.jsonl` (29,966 events, 2026-08-06 →
2026-08-23 — a subset of the 55,242 lifetime requests; every logged event here has `saved > 0`,
so this file specifically captures requests where compression did something, not all traffic).
Bucketed by `before` (pre-compression context size, a warmth proxy):

| Context bucket | n events | saved / before (%) |
|---|---|---|
| < 10k | 260 | 1.86% |
| 10k–50k | 7,282 | 1.55% |
| 50k–100k | 10,278 | 2.72% |
| ≥ 100k | 12,100 | **2.14%** |
| **Aggregate, this file** | 29,966 | **2.23%** |

**This does not collapse with context size — it is roughly flat, 1.55%–2.72% across every
bucket, with the largest bucket (≥100k) at 2.14%.** This confirms the "roughly flat" framing
over the "collapses as context warms" framing. My exact number (2.14% at ≥100k) differs
from the "~1.45%" cited in the task brief — plausibly because the ledger has grown ~56% more
events since that number was taken (19,168 → 29,966) and the bucket boundaries may not be
identical; I could not find the file containing the original 1.45% computation to diff against
line-for-line, so I mark the **exact 1.45% figure UNVERIFIED** while confirming its **directional
claim (flat, not collapsing) as TRUE** against fresh data.

**Reconciling this against the earlier 0.35% figure — both are correct, over different
denominators, not a contradiction to resolve in favor of one:**
- **0.331%** (≈ the earlier "0.35%") = `tokens_saved / total_input_tokens` over **all** 55,242
  lifetime requests, including the ~46% of requests that never produced a loggable compression
  event at all (health checks, `count_tokens` passthrough calls, requests with no compressible
  content).
- **2.23%** (≈ the "fuller pass" range) = the same ratio computed only over the 29,966 requests
  where compression actually did something, per `savings_events.jsonl`.
  Restricting the denominator to attempted-and-successful compressions raises the average by
  ~6.7×, but does not change the total dollars saved — both views agree exactly on the dollar
  figure ($63.95); they disagree only on what population to average over. **Use $63.95 as the
  dollar fact; treat both percentages as correct descriptions of different subsets, and note
  neither changes the 350× gap to caching.**

## 2. claude-mem — is retrieval actually used, and what does injection cost?

**Passive `SessionStart` injection is live**, exactly as the task brief states, and unaffected
by this measurement. Re-derived independently from `~/.claude-mem/claude-mem.db` (read-only,
`?mode=ro`), replicating the tool's own `context-generator.cjs` formula
(`chars(title+subtitle+narrative+facts)/4`, ceil):

| Metric | Value | Source |
|---|---|---|
| Lifetime observations | 27,208 (up from 25,914 on 2026-08-22) | `select count(*) from observations` |
| Lifetime `Σdiscovery_tokens` | 336,375,166 | `select sum(discovery_tokens)` |
| Lifetime `Σread_tokens` (recomputed) | 11,093,053 | recomputed from title/subtitle/narrative/facts |
| Lifetime savings% (recomputed) | 96.70% | matches tool's own self-report class of number |
| Recent-50 window (actual `SessionStart` default) discovery/read | 635,391 / 19,633 | same DB, most recent 50 rows |
| Recent-50 savings% | 96.91% | — |

This "96.70%/96.91%" is the same **compression-ratio-not-session-saving** metric the
2026-08-22 audit flagged: it divides the historical cost of the sessions that *produced* a
memory by the cost of *reading* it back now — not this session's before/after. Re-deriving the
session-relative cost:

- **Real session-token baseline, re-run just now** via
  `docs/analysis/token-spend-forensics.py` against the live corpus: 356 sessions, 6,778
  requests, **1,919,088,748 tokens**, $1,917.19 (this window is smaller than the 2026-08-22
  audit's whole-history baseline — see note below).
- Injection cost as % of an average session, using the recent-50 read-token figure (19,633) and
  mean tokens/session from this same live run (1,919,088,748 / 356 = 5,390,698):
  **19,633 / 5,390,698 = 0.3643%.**
- A hypothetical active per-task query (measured live earlier at ~273 tokens/call, 40 calls in
  the 2026-08-22 audit's reference session): 40 × 273 / 5,390,698 = **0.2026%.**

**Both numbers land inside the same rounding-error band the 2026-08-22 doc already used to
reject wiring** (that doc's own figures: 0.3516% / 0.2225%; mine: 0.3643% / 0.2026% — within
4% of each other despite the corpus growing by ~120 sessions and ~770M tokens in the interim).
**This confirms, not overturns, the 2026-08-22 verdict.**

**Adoption check — was the "0 across ~40 spawns" claim still true?** I scanned every `Skill`
tool_use call across the full corpus (866 main + subagent files, 237 worktree files — 1,103
files total) for the literal skill name `mem-search`:

```
total Skill tool_use calls found: 39 (main corpus) + 2 (worktrees) = 41
mem-search: 1 occurrence, timestamp 2026-08-20T12:36:55.091Z
claude-code-setup:claude-automation-recommender: 0 occurrences, ever
```

**This slightly refines, but does not overturn, the "0/~40" finding**: across this machine's
*entire* recorded history, `mem-search` has been invoked exactly **once**, not zero times. That
one invocation predates the 2026-08-22 audit (which measured zero within one specific ~40-spawn
batch, a narrower and still-accurate claim). One invocation out of 41 total `Skill` calls ever
made, and zero in the specific batch the audit measured, is "effectively never adopted," not
"never adopted" — worth stating precisely rather than rounding to zero.

**Verdict on the reasoning-bank decision: CONFIRMED.** Do not wire an active per-task claude-mem
query. Nothing measured here moves the number out of the rounding-error band.

## 3. Auto-generated skills — is there anything to measure?

`claude-code-setup:claude-automation-recommender` is real and installed
(`~/.claude/plugins/cache/claude-plugins-official/claude-code-setup/1.0.0/skills/claude-automation-recommender`
exists on disk) and is referenced twice in `agents/heimdall.md` (lines 58, 94) as the
recommended step for new-project setup.

**It has never been invoked, anywhere, in this machine's recorded history.** Scanned every
`Skill` tool_use call (name field, not incidental text matches) across 1,103 transcript files
(866 main-corpus + subagent, 237 worktree-agent):

```
Skill tool_use calls found across the corpus: 41
"claude-automation-recommender" among them: 0
```

The 15 files that matched a raw text grep for `claude-automation-recommender` all matched
because the string appears in *quoted file content* (someone `Read` `agents/heimdall.md`, or —
self-referentially — this very delta brief names the skill) — none of those hits is an actual
tool invocation. This is precisely the trap `docs/analysis/2026-08-22-capability-census.md`
already names generally: **"referenced in a prompt" and "has ever run" are different claims.**
That census independently found **7 of 16 agent definitions never spawned** (line 391,
`docs/analysis/2026-08-22-capability-census.md`) and **51 bins with zero invocations** (line
332, same file) — this task adds one more zero-invocation data point (a skill, not a bin/agent)
to that same pattern, from the same corpus, using the same method (actual tool-call scan, not
text-presence).

**Conclusion: there is nothing to measure for auto-generated skills beyond "it has never run."**
No cost, no saving, no adoption — a flat zero, not a rounding error.

## 4. Ranking the levers

| Lever | Measured value | Basis |
|---|---|---|
| Prompt caching (already working) | **$22,375.72** lifetime cache-savings (headroom's own ledger) | §1, `proxy_savings.json` |
| Context discipline (already working) | **$369.50** provably recoverable, one session, capping at ~150K; 6.17× cost-per-request gap (731K-mean day $0.366/req vs 118K-mean day $0.0593/req) | `docs/analysis/token-spend-forensics.md` (unchanged, re-cited) |
| Headroom compression | $63.95 lifetime (0.331% of total input tokens; 2.23% of attempted-compression-only traffic) | §1 |
| claude-mem active query (hypothetical, never shipped) | ~0.20% of session cost, if it ran (it has run once, ever) | §2 |
| claude-mem passive injection (already live) | ~0.36% of session cost | §2 |
| Auto-generated skills | **0** — never invoked | §3 |

**Caching outperforms headroom compression by 350×, from one authoritative file
(`proxy_savings.json`)**, and outperforms the *hypothetical* claude-mem active query by roughly
three orders of magnitude on the same basis. Context discipline's $369.50-on-one-session figure
alone exceeds headroom's entire multi-week lifetime compression total by ~5.8×. All three
candidates are rounding errors or exact zeros next to the two mechanisms already in place.

**Note on the brief's `$19,938.47` / `95.56%` figures:** I could not find a file on this
machine containing that exact `$19,938.47` figure as a primary computation — only
`docs/analysis/rtk-incorporation-assessment-2026-08-22.md:148`, which cites it as "consistent
with the brief" (i.e., citing an external number, not deriving it) alongside its own
independently-computed **$20,210.44** lifetime total over a larger corpus scan than
`token-spend-forensics.md`'s committed $1,103.05 (that doc's total covers a 2026-07-14→08-07
window only, not lifetime). **I mark `$19,938.47` UNVERIFIED** (cited-but-not-locally-traceable)
and use two numbers I can trace directly instead: the committed-doc figure ($1,103.05,
windowed) and headroom's own independent lifetime cache-ledger figure ($22,375.72, traced to
`proxy_savings.json` above) — both point the same direction and are within the same order of
magnitude as the brief's number. The **95.56%** cache-read figure is directly confirmed,
verbatim, in `docs/analysis/token-spend-forensics.md:172` and
`docs/analysis/2026-08-19-headroom-compression-diagnosis.md:394`. The **$369.50** and **6.17×**
figures are both directly confirmed in `docs/analysis/token-spend-forensics.md` (Row 1,
"Counterfactual" table and "His own natural experiment" section) — re-cited, not re-derived,
since re-running the aggregator against a live-growing corpus would only ever grow the number,
not falsify it.

## The honest question: why do these tools measure as noise here, if they work elsewhere?

**Hypothesis, clearly marked as such — not asserted as evidenced fact.**

The most likely explanation is a **combination of the first two candidates below**, not a
single cause:

1. **This repo already has prompt caching doing the heavy lifting (95.56%–95.14% cache-read
   across every measured window), so there is very little left in the token stream for a
   compressor to compress.** Headroom's own bucketed data (§1) shows its compression ratio stays
   flat around 1.5–2.7% regardless of context size — consistent with a compressor working on
   whatever small residual (usually the newest, uncached turn) survives after caching has
   already absorbed the bulk of repeated context. A workload that reuses cached context this
   heavily leaves compression very little surface area, by construction.
2. **hmd's own delta-brief machinery may already occupy the retrieval/compaction niche these
   tools are marketed for.** `bin/heimdall-brief` is real, hook-wired
   (`bin/heimdall-precheck-agent:70`, confirmed above), and — per its own source comments — was
   previously "measured to be ignored 100% of the time" as an advisory suggestion before being
   converted to a substituting hook. I confirmed **8 transcript files from today (2026-08-24, as
   of this measurement) reference brief/capsule content**, consistent with the "hook-wired and
   firing" claim in the task brief, though I could not independently confirm the exact figure of
   21 (the day was not yet complete at measurement time, and my grep matched file-content
   presence, not a strict per-brief-invocation count — a stricter count would need to grep the
   `heimdall-precheck-agent` hook's own exit-code log, which I did not do here to keep this
   read-only pass small). If this mechanism already delivers task-scoped context/history
   injection mechanically, on every spawn, at effectively zero marginal API cost (it runs
   locally before the request is sent, not as an extra model call), it would leave both
   headroom-style compression and claude-mem-style retrieval with less unclaimed value to add.
3. **The published wins for this class of tool very plausibly come from workflows without
   prompt caching this aggressive, and without any brief/capsule mechanism** — e.g., shorter
   sessions that reset context often (defeating cache-read economics before it compounds), or
   agents that re-explain project context from scratch each session (exactly what claude-mem's
   injected summary would legitimately shortcut). This repo's own natural experiment
   (`token-spend-forensics.md` — the 6.17× gap between a 731K-mean-context day and a
   118K-mean-context day) shows this repo's dominant cost driver is long-lived, cache-heavy
   sessions — a workload shape where compression and retrieval summaries have comparatively
   little left to contribute, not because the tools are broken, but because the marginal token
   they could remove is already the cheapest token in the request (cache-read, priced at
   0.1× input).

I cannot evidence which of these three is dominant without an external benchmark on a workload
that does NOT already have this repo's caching/brief setup — that comparison does not exist on
this machine. What would make that determination possible: a controlled run of an equivalent
task in a repo/session with prompt caching disabled and no brief mechanism, with headroom and
claude-mem active, measuring the same before/after ratios shown here.

## Sources (all read-only)

- `~/.headroom/proxy_savings.json`, `~/.headroom/savings_events.jsonl` (29,966 events),
  `~/.headroom/logs/proxy.log{,.1..5}`, `~/.heimdall/headroom/proxy.log` (the trap log, cited
  only to confirm it cannot show kompress)
- `~/.claude-mem/claude-mem.db` (`?mode=ro`, `select`-only)
- `~/.claude/projects/-Users-rj-Downloads-heimdall/**/*.jsonl` (866 files) +
  `~/.claude/projects/-Users-rj-Downloads-heimdall--claude-worktrees-agent-*/**/*.jsonl`
  (237 files) — 1,103 transcript files total, scanned for `Skill` tool_use blocks by structured
  JSON field, not raw text grep, to avoid the false-positive class documented in §3
- `docs/analysis/token-spend-forensics.md` + `token-spend-forensics.py` (re-run live, not
  edited)
- `docs/analysis/2026-08-22-reasoning-bank-wiring-decision.md`,
  `docs/analysis/2026-08-19-headroom-compression-diagnosis.md`,
  `docs/analysis/headroom-did-it-help.md`, `docs/analysis/2026-08-22-capability-census.md`,
  `docs/analysis/rtk-incorporation-assessment-2026-08-22.md` (all read, none modified)
- `agents/heimdall.md`, `hooks/hooks.json`, `bin/heimdall-precheck-agent` (read-only, confirming
  wiring claims; none modified)

**Not modified:** no bin, hook, or test in this repo. The only file touched by this task is this
document.
