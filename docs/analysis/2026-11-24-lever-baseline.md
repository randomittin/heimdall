# Token-lever baseline, before 2026-11-24 (2026-11-24)

Scope: read-only run of `bin/heimdall-cost-forensics --levers` over this machine's heimdall transcripts. Nothing in the repo or in `~/.claude` was changed; the tool never writes a file.
Command: `bin/heimdall-cost-forensics --levers --project Downloads-heimdall --until 2026-11-24` (201 transcript files, 2026-09-11 to 2026-11-23, 73.73 days of data; the same `*Downloads-heimdall*` corpus as `2026-11-22-token-utilization-next.md`, not all 862 project directories).
Label: every number is **DERIVED** by the query printed under its row in the tool's report and in `rows[].query` of its `--json` output. Windows are UTC, `[since, until)`.

## 1. The seven-day verification, one command

```
bin/heimdall-cost-forensics --levers --project Downloads-heimdall \
  --since <date the levers went live> --until <that date + 7 days> --baseline-until 2026-11-24
```

The report then has a `before` column (everything earlier than 2026-11-24, the numbers below) and an `after` column. Every row is a rate, a share, a mean or a per-30-day count, so a 74-day before and a 7-day after compare. A rate needs at least one day of data; a window with less prints `n/a`, never an extrapolation.

## 2. Baseline against each lever's falsifier

| Lever (source doc) | Row | Baseline (before 2026-11-24) | Falsifier |
|---|---|---|---|
| 1 Compaction window (11-22) | `main_requests_gt_300k_share` | **50.2%**, 2,033 of 4,052 main-thread requests | below 10% |
| | `main_spend_gt_300k_usd` / `_share` | $598.32 of $847.16 priced main-thread spend = **70.6%** | falls with the share above |
| 2 Cold-cache return (11-22) | `cache_expiry_rewrites_gt_150k_per_30d` | **37.84** per 30 days (93 events, mean rewrite 384,583 tokens, $377.10 written) | no figure set |
| | `cache_expiry_rewrites_gt_300k_per_30d` | **24.41** per 30 days (60 events, mean rewrite 476,406 tokens, $292.56 written) | below 5 per 30 days |
| 3 Subagent effort (11-22, 11-23) | `subagent_output_tokens_per_agent[<effort>]` | max 145,415 (n=146, median 133,102); high 35,775 (n=9); medium 8,111 (n=13) | compare levels; no threshold |
| 4 Static base trim (11-22) | `subagent_first_request_context_mean[hmd:coder]` | **46,358** tokens (n=147); all agents 45,781 (n=168, p90 49,033) | coder mean at or below 36,000 |
| 5 Report cap (11-22, 11-24 gap 2) | `task_notification_chars_mean`, `_p90` | mean **2,217**, p90 **4,870** chars (n=1,202, 1,048 completed) | mean below 1,600 |
| | `task_notifications_gate_blocked` | 0 of 1,202 (the gate did not exist) | any reading above 0 shows it firing |
| 6 Read dedup (11-24 gap 1) | `subagent_identical_reread_share` / `_of_read_chars` | **0.1%** of subagent tool-result chars (38,510 of 35,265,698; 28 re-reads); **0.2%** of Read chars | below 5% of Read chars (already met, see 3) |
| | `read_dedup_stub_hits` | 0 (the hook did not exist) | any reading above 0 shows it firing |
| 7 Parallel-gate throttle (11-22) | `parallel_gate_injections_per_100_prompts` | **44.36** (661 injections over 1,490 prompts) | below 10 |

Other first-request means (tokens): architect 48,528 (n=9), general-purpose 38,436 (n=5), test-runner 36,210 (n=3), docs-writer 34,204 (n=2), claude-code-guide 53,099 (n=1), Explore 17,503 (n=1).

## 3. Where this differs from the two analysis docs

- **The 44.2% identical re-read figure in `2026-11-24-market-token-techniques.md` (section 2, gap 1) is a counting artifact; the real share is 0.2-0.3%.** Transcripts also hold `api-request-blob` records, each with a `message` of its own: a copy of a message sent to the API. A scan that reads `message.content` from every record type (the doc's `tr4.py` does not filter on type) sees each Read twice, and the second sighting looks like an identical re-read. `bin/heimdall-cost-forensics --levers` reads only `assistant` and `user` records (its one line loop is `iter_records`). The same keying (agent, path, offset, limit, no Edit or Write between) run twice over the whole project on this machine: with the blob records 1,550 repeats of 15.9M chars = 44.2% of Read chars (the doc's figure) and 65.7M chars of tool results; without them 30 repeats of 62,832 chars = 0.3% and 39.7M chars. Consequence: the read-dedup hook (gap 1, "$21 DERIVED") addresses about 0.1-0.2% of subagent tool-result chars; its saving is close to nothing on this corpus. The 18.6% "repeat reads of one path" in the 11-22 doc (lever 6) used a different definition (same path, any range) on user records, so it stands; this tool does not report it.
- **Lever 1 bucket count matches the 11-22 doc exactly**: 2,033 requests above 300K there (1,184 + 776 + 73) and here. The denominator is larger (4,052 vs 3,813) because this run covers every main session of the project, not only `0e12831c`. The spend share (70.6% vs 74.5%) differs because the tool prices from `bin/lib/tier-table.json` (Opus 5.5 and Sonnet 5.5 cache reads at 0.05x), the doc priced the 5.5 models like their tier siblings.
- **Lever 2** counts a main-thread request as an expiry rewrite when it follows an idle gap longer than the cache TTL (3,600 s here: 97% of the main thread's cache-write tokens are 1-hour TTL; pass `--cache-ttl 300` on a 5-minute account) and writes at least half of the previous request's prompt as cache. It gives 93 events above 150K against the doc's 78; the doc's `rep4.py` is scratch, not in the repo, so the two definitions were not diffed.
- **Task notifications**: 1,202 here against 1,152 in the 11-22 doc (two more days); mean 2,217 against 2,390 chars, p90 4,870 against 5,091.
- **Effort**: 146 of the 168 subagents ran at `max`, the rest at `high` (9) and `medium` (13). Lever 3 compares the effort ladder at output-token level; the baseline is dominated by `max`.

## 4. Caveats

- 121 `<synthetic>` placeholders are not counted as requests. No main-thread request in the baseline is unpriced, so the $ rows are list-price equivalents, not a floor.
- A partial run from 2026-11-24 00:00 UTC (0.86 days, 96 main-thread requests) shows 0 above 300K and 2 identical re-reads. That is too short to verify anything; it only shows the after column filling.
- The baseline is one operator, one machine, one project family (n=1). The hook levers (report gate, read dedup, parallel-gate throttle) read 0 before 2026-11-24 by construction, so their rows prove nothing until an after window exists.
- Privacy: `--levers` reads text lengths and fixed markers from transcripts and prints aggregates only; `test/heimdall-cost-forensics.test.sh` plants a secret in every place it looks and asserts it never appears in any output.
