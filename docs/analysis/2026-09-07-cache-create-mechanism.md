# Cache-CREATE mechanism: what triggers it, is it self-inflicted, what's addressable

Follow-up to `2026-09-02-input-context-cost.md`, which ranked "cache-CREATE
concentration" the #2 cost lever (36.88% of dollars at a chosen 5-minute-TTL
assumption) and flagged the underlying mechanism as its top open research
question. This doc closes that question with direct transcript measurement
and, separately, with a full-repo-history forensic pass that supersedes the
original doc's single-session estimate.

## Method

- New tool: `evals/context-cost/measure_cache_transitions.py` (commits
  `c92b9414`, `3e6071f8`). Streams a transcript, dedups by `message.id`,
  classifies every request CREATE_ONLY / READ_ONLY / MIXED / NEITHER from
  `usage.cache_creation_input_tokens` / `usage.cache_read_input_tokens`, then
  buckets every CREATE-bearing request by cause: `first_in_thread` (no prior
  request to inherit a prefix from), `ttl_expiry` (gap since the previous
  request ≥ the cache's TTL — fully explained), `incremental` (gap < TTL, but
  a nonzero cache read alongside the create — normal mid-conversation prefix
  growth), `unexplained` (gap < TTL, cache_read == 0 — a full-prefix
  invalidation the TTL cannot explain).
- Data: the main session transcript (this repo, this conversation,
  `01313446-ae34-4e0c-9f91-4ef0bd66593c.jsonl`) plus all 331 of its subagent
  transcripts, run separately since (see Q3) they use different cache TTL
  tiers. Both re-run fresh in this pass.
- Second tool, not written by me: `bin/heimdall-cost-forensics`, landed on
  `main` after this investigation started (54 assertions, reachable). It
  reads `usage` fields only (never prompt/tool content — mechanically proven
  by its own test), and prices every request by its own model's real per-MTok
  rate rather than one repo-wide assumption. Extracted read-only via `git
  show main:bin/heimdall-cost-forensics` (this worktree stays on its own
  branch; nothing was merged) and run fresh, twice: once at its default
  scope, once `--root`-scoped to just this project's transcripts. Its
  larger, per-request-exact sample supersedes this doc's own hand-rolled
  blend wherever the two overlap, per explicit instruction.
- Pricing multipliers (cache read ≈0.1x input, cache write 1.25x at 5-min
  TTL / 2.0x at 1-hour TTL, output 5x input): confirmed against the
  `claude-api` skill's pricing reference, unchanged from the original doc.

## Q1 — what actually triggers a CREATE vs a READ, measured

Request-class split, this session, freshly re-run:

| source | requests | CREATE_ONLY | READ_ONLY | MIXED | NEITHER |
|---|---|---|---|---|---|
| main thread | 3,491 | 88 (2.5%) | 5 (0.1%) | 3,326 (95.3%) | 72 (2.1%) |
| subagents (331 files) | 14,840 | 381 (2.6%) | 22 (0.1%) | 14,367 (96.8%) | 70 (0.5%) |

The overwhelming majority of every request is MIXED — a request reads most
of its prefix from cache and creates a small new tail. Pure CREATE_ONLY
(everything new, nothing reused) is a small, structurally-expected minority:
mostly `first_in_thread` (a subagent's first call, no prefix yet to hit) or
genuine TTL expiry.

CREATE-bearing requests, bucketed by cause, each source classified against
**its own actual TTL** (see Q3 for why these differ):

| bucket | main (TTL=3600s) events | main tokens | subagent (TTL=300s) events | subagent tokens |
|---|---|---|---|---|
| first_in_thread | 1 (0.0%) | 63,327 (0.1%) | 328 (2.2%) | 7,749,367 (6.1%) |
| ttl_expiry | 62 (1.8%) | 29,271,948 (45.4%) | 297 (2.0%) | 13,651,910 (10.7%) |
| incremental | 3,320 (97.2%) | 22,603,013 (35.1%) | 13,969 (94.7%) | 97,813,216 (76.6%) |
| unexplained | 31 (0.9%) | 12,473,851 (19.4%) | 154 (1.0%) | 8,515,545 (6.7%) |

Reading this straight: on the main thread, TTL expiry and ordinary
incremental growth together account for 80.5% of create tokens — expected,
unavoidable cache behavior, not a bug. Subagents lean even more heavily
incremental (76.6%) because most subagent lifetimes are shorter than one
cache TTL, so a subagent rarely lives long enough to hit genuine expiry.

## Q2 — is hmd's own hook injection causing avoidable churn?

No, on two independent lines of evidence — the second gathered by the
coordinator while this pass was running, and it changes the second half of
the answer:

- **The coordinator hashed the actual live injected text twice each**:
  `bin/heimdall-caveman rules` → identical hash both times
  (`c0384ba90e6fb638`); `bin/heimdall-ctx-meter notice` → identical hash both
  times, and that hash (`e3b0c44298fc1c14…`) is the SHA-256 of the empty
  string — meaning ctx-meter is not just stable, it is currently emitting
  **nothing at all** (it only writes when context is over its ceiling, and
  it writes to stderr regardless, which never reaches model-visible
  context). The injected-prefix surface from hmd's own hooks is smaller than
  this investigation's own brief assumed.
- **Independently, earlier in this pass**: sampled the actual
  `UserPromptSubmit`-injected caveman text at first and last occurrence
  within each of its two wording eras (a pre-2026-09-03 verbose form, a
  post-migration terse form) — byte-identical within each era. The wording
  changed exactly once, as a deliberate edit, not per-turn drift.

Conclusion: hmd's own hooks are ruled out as a cache-churn cause. This was
the single most plausible self-inflicted explanation the original doc's
open question could have resolved to, and it didn't — a real, useful
negative result.

## Q3 — the addressable slice, quantified honestly

### The headline number needs correcting, not confirming

The original doc picked 5-minute TTL as its "dominant case" and got 36.88%
cache-create / 56.29% cache-read. Measuring the actual `usage.cache_creation`
object (it splits into `ephemeral_1h_input_tokens` and
`ephemeral_5m_input_tokens` — ground truth per request, not inferred) shows
that assumption is wrong in a specific, structural way: **this repo's main
thread uses the 1-hour TTL tier exclusively; every subagent uses the 5-minute
tier exclusively.** Zero overlap either direction, across the full main
transcript and all 331 subagent files. This is a harness-level, source-
dependent split, not incidental variation.

`bin/heimdall-cost-forensics`, run fresh against this repo's full local
history (835 sessions, 36,011 priced requests, 2026-07-16 through
2026-09-06 — by far the largest sample any doc in this directory has used):

```
cache read             $ 2279.3408  ( 51.5% of priced $)   5,445,636,618 tok
cache write 1h         $ 1116.7108  ( 25.2% of priced $)     111,987,744 tok
cache write 5m         $  789.1929  ( 17.8% of priced $)     206,953,689 tok
output                 $  214.8493  (  4.9% of priced $)       9,721,184 tok
input                  $   23.0704  (  0.5% of priced $)      10,805,301 tok
```
(477,511 tokens from an unpriced model excluded; totals are a floor, not a
ceiling, per the tool's own stated policy.)

Combined cache write (create) = 25.2% + 17.8% = **43.0%** of dollars.
Combined cache read+write = **94.5%**.

So: does 36.88% survive at scale? **No.** The real, full-history,
per-request-exact figure is 43.0% — about 6 points higher, not lower, than
the original doc's headline. Cache READ, likewise, comes in at 51.5%, about
5 points lower than the doc's 56.29%. The *direction* of the original
finding survives and strengthens (cache create is a huge, genuinely
second-place cost lever); the *precise number* does not, and 43.0% /
51.5% should replace 36.88% / 56.29% wherever this repo cites a headline
create/read split going forward. (This session's own hand-rolled main+
subagent blend, using each source's correct TTL and computing an effective
multiplier of ≈1.50x, lands at read≈47.7% / create≈47.0% — a third,
narrower estimate. All three numbers — 36.88/56.29, 43.0/51.5, 47.0/47.7 —
agree on one thing: read and create are much closer in cost than a 5m-only
assumption implies, and get closer still the more of this repo's real
history you include.)

### The "unexplained" bucket: a confirmed partial cause, not a closed case

19.4% of main-thread create tokens and 6.7% of subagent create tokens fall
in the `unexplained` bucket — gap under the source's own real TTL, no
accompanying read, so neither ordinary expiry nor ordinary incremental
growth explains them. Two things are true about this bucket, and only one
of them is fully nailed down:

- **Confirmed, not hypothesized**: an earlier pass in this investigation
  (at a since-corrected TTL assumption, over a smaller 23-event version of
  this same bucket) direct-timestamp-matched 3 events to real
  `isCompactSummary:true` compaction records — compaction genuinely does
  force full-prefix recreation, with hard evidence, not inference.
- **Not re-verified against the corrected 31-event list**: closing that
  gap fully would mean re-pulling every compaction timestamp and
  cross-matching again, which this pass explicitly did not do (per the
  coordinator's "stop investigating, write it down" instruction). The
  remaining share is plausibly explained by mid-session model-string
  switches (this transcript alone uses five distinct model identifiers —
  a documented, no-escape-hatch cache invalidator) or genuine 20-block
  lookback misses (this investigation's own original hypothesis) — neither
  confirmed per-event.

Honest framing: compaction is a real, proven contributor to this bucket;
the rest is a plausible-but-open lead, not a confirmed mechanism and not
yet an actionable fix.

### Subagent fragmentation: real, but architectural, not a bug

Subagents' `first_in_thread` share of their own create tokens (6.1%,
7.75M tokens across 328 of 331 files) is far above the main thread's
(0.1%, one event) — every subagent spawn pays a cold-start create with
nothing to reuse. This is the direct, structural cost of the
mandatory-parallelism / isolated-subagent architecture this repo requires
elsewhere in its own conventions, trading against the latency and
collision-avoidance benefits that architecture buys. It is not a defect
to patch; it is a tradeoff already being made on purpose.

## Q4 — ranked fixes, evidence-gated

1. **Correct the headline number.** Re-baseline the original doc's
   36.88%/56.29% cost-share claim to the cost-forensics figures above
   (43.0%/51.5%, 36,011-request sample) or this doc's own 47.0%/47.7%
   session-blend. Zero risk, immediately actionable, purely a documentation
   fix — no code changes.
2. **Trace the corrected 31-event main-thread `unexplained` bucket fully**
   (re-pull compaction timestamps, cross-match against the new list, check
   model-string transitions per event). This is a lead, not yet a fix —
   listed so the next person doesn't have to rediscover it.
3. **Do not touch hmd's own hook injection.** Ruled out twice, independently
   (byte-hash and byte-sample). No fix needed because there is no fault.
4. **Do not "fix" subagent fragmentation.** It is the architecture's own
   parallelism guarantee paying its structural cost. Any fix (e.g. batching
   subagent spawns to share a prefix) would trade away the isolation the
   parallelism rule depends on — not a free win.
5. **No fix for TTL-tier choice itself** — main-thread 1h vs subagent 5m is
   already the harness's own deliberate default, not misconfiguration this
   investigation found a reason to change.

**Bottom line, stated plainly per this investigation's own honesty mandate:
cache-create cost is real, large (43% of all-time dollars, confirmed at
36,011-request scale), and mostly unavoidable.** Of the two levers actually
tested and cleared — hmd's own hook injection, and subagent fragmentation
as a "just batch it" fix — neither yields an addressable saving. The one
still-open thread (the corrected unexplained bucket, 19.4%/6.7%) is real
but only partially traced; it is handed off as a lead, not oversold as a
saving.
