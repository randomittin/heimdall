# Token-Spend Forensics

**Measured:** 2026-08-08 · **Window:** 2026-07-14 → 2026-08-07 · **Corpus:** 234 sessions / 3,830 API requests / 1,147,306,644 tokens
**Source:** `~/.claude/projects/-Users-rj-Downloads-heimdall*/**.jsonl` (main project dir + 141 worktree-agent dirs)
**Priced at Opus 5 list:** $5/MTok in, $25/MTok out, cache read 0.1×, 5m write 1.25×, 1h write 2.0×

Total measured spend: **$1,103.05**. Commits landed in the window: **480**. Blended: **$2.30 / commit**.

> **The corpus is live, and that is itself evidence.** Re-running the aggregator a few minutes after the analysis snapshot returned **$1,104.73 / 3,846 requests** — the top session grew from 2,022 to 2,059 requests *while it was being measured*. **The $913 session is the one running right now.** This is not a historical post-mortem of a session that already ended; it is a live meter. Figures below are the frozen snapshot; re-running the script will return slightly larger numbers for the same reason the report exists.

---

## Ranking — cause by measured cost

| # | Cause | Measured cost | Share | Waste or inherent | Fix |
|---|---|---|---|---|---|
| 1 | **Context never reset.** One 15-day session held a working set that grew to 998,857 tokens and re-read it 2,022 times | **$913.54** (session total); **$369.50** provably recoverable | 82.8% of spend; 33.5% recoverable | **Waste** (the re-reading), inherent (the turns) | Restart/compact at ~150K. His own 2026-08-07 data already proves 6.2× |
| 2 | **Cache-write blow-up above 800K context.** cache-create jumps 3.2× once context clears 800K | **$118.92** | 10.8% | **Waste** | Same fix as #1 — never operate above ~800K |
| 3 | ~~**`security-guidance` plugin Stop hook** firing Opus-4-7 on every stop-with-diff, 89 times~~ **REFUTED — wrong hook.** It is the PostToolUse commit/push *agentic* review; the Stop hook contributed $0 | **$57.73** | 5.2% | **Inherent** (right check, right tier) | ~~`export SECURITY_REVIEW_MODEL=claude-haiku-4-5`~~ saves **$0.00** — wrong knob. See [`2026-08-08-security-review-tier-decision.md`](./2026-08-08-security-review-tier-decision.md) |
| 4 | **Preamble carried on every request.** Median 35,174 tok of system prompt + CLAUDE.md stack + hooks, re-read 2,930× | **~$51.53** (estimate) | 4.7% | **Inherent** (mostly) — it is cached at 0.1× and works | Trimming 10K off the stack saves ~$14.65. Low priority |
| 5 | **Read-only research subagents.** 141 worktree agents; 140 wrote zero files | **$75.04** | 6.8% | **Inherent** — this is correct delegation | Keep. This is what keeps #1 from being worse |
| 6 | **Re-reading the same file** across sessions — 203 redundant reads, 2.34 MB (55% of all Read bytes) | **~$5.85** (estimate) | 0.5% | **Waste** | Real but immaterial. Do not spend effort here |
| 7 | **Full test-suite runs** (`bash test/run-all.sh`) — 25 invocations | **6,543 bytes total** | ~0.0% | **Inherent, already optimal** | Nothing to fix — output is already redirected to files |

**Addressable total: ~$505 (45.8%)** — and none of it requires giving up a single verification. *(Corrected 2026-08-08: row 3's $46.18 was refuted and removed; the honest Stop-surface saving of ~$8–$14 replaces it. See §Row 3.)*

---

## The one-sentence finding

> The unique content this project generated in three weeks is **~1.03M tokens**. It was billed **1.147 billion tokens** — an amplification of roughly **1,000×**. The money did not go into producing work. It went into re-reading work that was already produced.

Per-call hygiene is **excellent** and is not the problem: 1,288 Bash calls in the big session returned 830,563 bytes total (645 B/call — output is already piped to files), and full-suite runs contributed 6.5 KB across the entire corpus. The owner does everything right at the micro level, then pays for it a thousand times because the session never ends.

---

## Method, and the trap that would have made this report wrong

**One API request emits multiple JSONL lines** — one per content block (`thinking`, `text`, each `tool_use`) — and **every line repeats the same `message.usage` object**. In one sampled file: 381 assistant lines, **166 unique `message.id`**, and 0 of the 126 duplicated ids carried a differing usage tuple. Summing usage per line inflates every figure by ~2.3×.

Every number here dedupes usage by `message.id`. Verification of the trap:

```bash
python3 - <<'PY'
import json,collections
f='/Users/rj/.claude/projects/-Users-rj-Downloads-heimdall/05d259a8-f6b3-4142-812c-0607d06267a9.jsonl'
ids=collections.Counter(); u=collections.defaultdict(set)
for l in open(f):
    r=json.loads(l)
    if r.get('type')!='assistant': continue
    m=r['message']; g=m.get('usage') or {}
    ids[m.get('id')]+=1
    u[m.get('id')].add((g.get('input_tokens'),g.get('output_tokens'),
                        g.get('cache_creation_input_tokens'),g.get('cache_read_input_tokens')))
print('lines',sum(ids.values()),'unique ids',len(ids),
      'dupes w/ differing usage',sum(1 for k,v in ids.items() if v>1 and len(u[k])>1))
PY
# -> lines 381 unique ids 166 dupes w/ differing usage 0
```

`usage.iterations[]` was checked and always sums to the top-level figure (0 mismatches / 381 records), so top-level is authoritative. Re-runnable aggregator: [`token-spend-forensics.py`](./token-spend-forensics.py).

---

## Row 1 — Context never reset · $913.54

A single session file, `da3a8887-1f95-4283-b2e0-38175ca264e5.jsonl`, resumed across 15 days:

| metric | value |
|---|---|
| requests | 2,022 |
| total tokens | 1,015,039,978 |
| **mean context / request** | **501,000** |
| peak context | 998,857 |
| cache read | 975,634,729 → $487.82 |
| cache create (all 1h) | 37,382,817 → $373.83 |
| output | 2,018,426 → $50.46 |
| **unique content generated** | **4,125,494 B (~1.03M tok)** |
| **amplification** | **billed input ÷ peak working set = 1,014×** |

That session alone is **82.8%** of all spend measured. Its tool mix — Bash 1,288 · Agent 272 · Edit 51 · Read 23 — is disciplined. The cost is not what entered context; it is how long it stayed.

### The acceleration, per day

Mean context climbs, and the daily bill tracks it exactly:

| day | reqs | mean ctx | input tokens | cache-read $ |
|---|---|---|---|---|
| 2026-07-23 | 82 | 196,969 | 16,151,460 | $8.08 |
| 2026-07-25 | 86 | 643,824 | 55,368,878 | $27.68 |
| 2026-07-29 | 7 | 957,434 | 6,702,040 | $3.35 |
| 2026-08-02 | 267 | 373,100 | 99,617,833 | $49.81 |
| 2026-08-03 | 172 | 714,448 | 122,885,032 | $61.44 |
| 2026-08-04 | 446 | 424,328 | 189,250,181 | $94.63 |
| **2026-08-05** | **476** | **731,707** | **348,292,630** | **$174.15** |
| **2026-08-07** | **153** | **118,678** | **18,157,674** | **$9.08** |

### His own natural experiment

The last two rows are the proof, from his own data, same repo, same working style:

- **2026-08-05** — 476 requests at 731,707 mean context → **$0.366 / request**
- **2026-08-07** — 153 requests at 118,678 mean context → **$0.0593 / request**

**6.17× cheaper per request**, purely because the context was smaller. Nothing was skipped to get there.

### Counterfactual (cache-read only; cache-create held constant)

| cap | input tokens | % of actual | cache-read saved |
|---|---|---|---|
| 100,000 | 305,248,851 | 26.7% | **$419.28** |
| 150,000 | 404,803,851 | 35.4% | **$369.50** |
| 200,000 | 493,332,282 | 43.1% | **$325.24** |

Cost of the fix: re-establishing a preamble is ~35K tokens (~$0.02 cached). Against $369.50, that is free.

---

## Row 2 — Cache-write blow-up above 800K · $118.92

cache-creation per request, by context quintile, in the big session:

| quintile | context range | mean cache-create / req |
|---|---|---|
| 1 | 0 – 163,959 | 9,216 |
| 2 | 164,053 – 389,880 | 12,539 |
| 3 | 391,988 – 602,125 | 13,964 |
| 4 | 602,468 – 803,811 | 13,457 |
| **5** | **804,141 – 998,857** | **42,183** |

Quintiles 2–4 sit flat at ~13,320 — that is the honest per-turn delta. Quintile 5 is **3.2× higher**. Excess: 412 requests × (42,183 − 13,320) = **11,891,556 tokens** × $10/MTok (1h write) = **$118.92**.

Pearson r(context, cache-create) across all 2,048 requests is only 0.092 — the relationship is *not* linear; it is a cliff at ~800K. The mechanism is consistent with cache-breakpoint churn (re-writing a large span when breakpoints consolidate), but I did not prove the mechanism — **only the 3.2× cost jump is measured.** The fix does not depend on the mechanism: stay under 800K.

---

## Row 3 — The security hook · $57.73

> **⚠ REFUTED 2026-08-08 — this row named the wrong hook and the wrong knob.** The measurement below ($57.73, opus-4-7, 646/646) is sound; the *attribution* and the *fix* are not. The spend is the plugin's **PostToolUse commit/push agentic review** (`SG_AGENTIC_MODEL`), not the Stop hook (`SECURITY_REVIEW_MODEL`) — the Stop hook posts over raw HTTP, writes no session transcript, and so contributed **$0.00** to a figure derived entirely from session transcripts. The prescribed export would therefore have saved **nothing**. Aimed at the correct knob it would have saved ~$46 by downgrading a genuine, tool-using vulnerability reviewer below the tier `bin/heimdall:3691` reserves for security work. **The tier stays opus and this line is irreducible.** Full evidence, the honest ~$8–$14/window alternative, and the config that needs the owner's hand: [`2026-08-08-security-review-tier-decision.md`](./2026-08-08-security-review-tier-decision.md). The paragraphs below are retained as originally written, for provenance.

89 sessions with entrypoint `sdk-py` whose first prompt begins `"Review this change for security vulnerabilities."`

- **646 requests, 37,413,500 tokens, $57.73, mean $0.65/run**, 2026-07-14 → 2026-08-06
- Model: **`claude-opus-4-7` on 646/646 requests** — the most expensive tier
- Tools used: Read 371 · Grep 159 · Bash 82 · StructuredOutput 57 · Glob 4

Source: `~/.claude/plugins/cache/claude-plugins-official/security-guidance/2.0.6/hooks/hooks.json`, described as *"git-diff-based LLM review on stop"* — it is a **Stop hook**, so it fires every time an agent stops with a diff present. This is not the owner's code; it is an installed official plugin.

`llm.py:131` — `SECURITY_REVIEW_MODEL = os.environ.get("SECURITY_REVIEW_MODEL", "").strip() or "claude-opus-4-7"`

**Fix:** `export SECURITY_REVIEW_MODEL=claude-haiku-4-5`. Haiku is 5× cheaper on both input and output → ~$11.55, **saving $46.18**. Pattern-matching a diff for known vulnerability shapes is exactly the bounded, mechanical task a small model handles well. The check keeps running; only the tier changes.

---

## Row 4 — Preamble · ~$51.53 (estimate, and it is fine)

Measured as the first request's full context per session (system prompt + CLAUDE.md stack + SessionStart hook injections + first user message):

- median **35,174** tokens · mean 39,332 · min 28,597 · max 169,370
- total paid on first requests: 3,657,917 tokens

Carrying cost estimate: 35,174 × 2,930 requests × $0.50/MTok = **~$51.53**. Labelled an estimate — it assumes the preamble persists unchanged and stays cached, which the 95.6% cache-read ratio supports but does not prove per-block.

**This is not the problem, and the brief's hypothesis that it might be is refuted below.** It is cached at 0.1× and it is working.

---

## Refuted hypotheses

Stated plainly, because each was a plausible target that the data kills:

**1. "Cache is being re-paid rather than reused."** No. Cache-read is **95.56%** of all input; cache-create 4.44%; genuinely uncached input **0.0023%** (16,122 tokens out of 1.14 billion). Caching is working near-perfectly. There is no cheap win here — it has already been taken.

**2. "The 1-hour cache TTL is wasteful."** No — it is *saving* money, and I checked before recommending against it. The 1h premium over the 5m rate is **$150.65**. But 234 requests were preceded by a gap >5 min (8.3% of 2,816 gaps; p90 gap = 222.7s, p95 = 612.8s), and those requests carried **118,487,374 tokens** of context that a 5m TTL would have forced to be re-created — **$740.55** at the 5m write rate. Switching to 5m TTL would cost roughly **$590 more**. Leave it alone.

**3. "The 299-suite / ~800s test runs are eating context."** No. **25** suite-like invocations across the entire corpus returned **6,543 bytes total** — the largest single one was 745 B. Output is already redirected (`bash test/run-all.sh > /tmp/board-fin…`, `nohup … > /tmp/boa…`). This discipline is already correct and costs essentially nothing.

**4. "Duplicate commands are burning tokens."** Barely. Intra-session duplicate Bash: **3 re-runs, 954 bytes**. Cross-session redundant Reads: 203 re-reads, 2,339,918 B (~$5.85 estimated). Real, but 0.5% — not worth engineering against.

**5. "Output tokens are a major line."** No. Output is **0.30%** of all tokens (3,497,383) and 7.9% of cost ($87.43). Notably `thinking` blocks measured 0 bytes in the persisted transcripts.

---

## Truncation — what I could and could not find

**I could not reproduce the reported truncations, and I am not going to claim I did.**

- **Zero** requests in all 3,830 carry a `max_tokens` stop reason. Distribution: `tool_use` 3,318 · `end_turn` 455 · `stop_sequence` 25 · null 16.
- Worktree agents **peak at 100,916 tokens** (p50 57,078 · p95 88,927). Not one reaches 126K, let alone 147K.
- The persisted corpus ends **2026-08-07**; this measurement ran 2026-08-08. **The session in which those three agents truncated has not been flushed to disk yet.**

So the 126k/135k/147k figures are almost certainly real but live in today's not-yet-written transcript. What the historical data *does* show about agent outcomes:

| outcome | sessions | cost |
|---|---|---|
| wrote files AND committed | 1 | $1.80 |
| wrote files, never committed | **0** | $0.00 |
| no writes (read-only research) | 140 | $73.24 |

**No historical agent lost written work.** The 140 zero-commit agents wrote nothing because they were research agents — that is correct delegation, and it is the thing keeping row 1 from being far worse. The `$/commit` denominator is low (480 commits) because the parent session does the committing, not because agents are failing.

---

## Waste vs inherent — the honest split

The brief asked whether this repo's re-verification discipline is the largest line item. **It is not, and the distinction matters:**

Cost = **turns × context size**.

- **Turns are inherent.** 3,830 requests is what falsifiability, re-measuring instead of recalling, and full-suite gating actually cost. That policy is intact in every counterfactual above — not one verification is removed.
- **Context size is not inherent.** Mean context was 298,645 corpus-wide and 501,000 in the big session, against a working set that never needed to exceed ~1M and a proven-workable operating point of 118,678.

Holding the same 3,830 verified turns at a 150K context yields **~$733.55** instead of $1,103.05. **The discipline is not expensive. Carrying half a megabyte of history while performing it is.**

---

## Fixes, ranked by measured value

1. **Restart or compact the session at ~150K context** — saves **$369.50** (33.5%). Zero verifications lost. Already demonstrated at 6.17× on 2026-08-07.
2. **Never operate above 800K context** — saves **$118.92** in cache-write blow-up. Same discipline as #1.
3. ~~`export SECURITY_REVIEW_MODEL=…`~~ **REFUTED — do not run.** It saves **$0.00**: it retiers the Stop hook, which contributed nothing to the $57.73 (that spend is the *agentic* commit/push review, knob `SG_AGENTIC_MODEL`), and setting the var also suppresses the plugin's fallback. The measured spend is the correct check on the correct tier — **irreducible**. A real ~$8–$14/window saving exists on the Stop surface via `MAX_STOP_HOOK_FIRINGS`. Full reasoning and the owner-applied config: [`2026-08-08-security-review-tier-decision.md`](./2026-08-08-security-review-tier-decision.md).
4. Trim the CLAUDE.md/hook preamble — ~$1.47 per 1K tokens removed. Marginal.
5. Do nothing about cache TTL, test-suite output, duplicate reads, or output tokens. Measured, and they are not the problem.

**Highest-value single fix: cap context at 150K.** It is worth more than every other fix combined, ~8× the security-model change, and it costs one restart.

---

## Limitations

- **Bytes→tokens conversions are labelled estimates** at ~4 B/token (rows 4, 6, and the "unique content" figure). All primary cost figures come from `message.usage` and involve no conversion.
- Prices are **Anthropic first-party list prices**, applied uniformly at the Opus 5 tier. 73.7% of tokens ran on `claude-opus-5`, 22.9% on `claude-opus-4-8`, 3.4% on `claude-opus-4-7` — all three share $5/$25, so the blend is exact. Any enterprise discount scales every row equally and changes no ranking.
- **No long-context premium was applied.** If a >200K-context surcharge applies to this account, rows 1 and 2 are *understated* and the top fix is worth more, not less.
- Independent aggregation passes agreed to within **0.07%** (1,097.8M vs 1,098.6M for the main dir) — the delta is the handling of 16 records with a null `message.id`, which cannot be safely collapsed. The authoritative pass treats them as distinct.
- **The corpus grows while it is read.** The verification re-run of `token-spend-forensics.py` returned $1,104.73 / 3,846 requests / 235 sessions against the snapshot's $1,103.05 / 3,830 / 234 — a +0.15% drift over minutes, entirely from the live session appending. Expect any re-run to exceed these figures. Row rankings are unaffected.
- One session reports a first-request context of 0 (a `<synthetic>` record); the preamble median of ~35.1K is unaffected by it.
- Records with no `usage` object (`file-history-snapshot`, `queue-operation`, `attachment`, `system`, and 22 `<synthetic>` assistant records carrying zero usage) contribute no tokens and were excluded from cost, by design.
