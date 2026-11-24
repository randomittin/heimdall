# Token utilization: next highest-yield levers (2026-11-22)

Scope: read-only measurement of hmd sessions on this machine, Claude Code 2.1.330. Nothing in the repo was changed and no test sweep was run.
Corpus: 158 transcripts under `~/.claude/projects/*Downloads-heimdall*`: 7 main sessions, 148 subagent files of the big session, 3 small.
One main session (`0e12831c`) is 98.7% of the main-thread spend: 3,813 unique requests, 2026-09-11 to 2026-11-22 (72 days, one never-ended session). Subagents: 6,895 requests.

Labels: **MEAS** = a command in the appendix printed it. **DERIVED** = arithmetic on MEAS numbers. **INF** = estimate, method stated, not a measurement.

## 0. Pricing and caveats (read before trusting any dollar)

- List-price-equivalent $, per request: input and cache-read at the tier rate (opus 5/0.5, sonnet 2/0.2, haiku 1/0.1, fable 10/0.25 per MTok, the claude-api skill table via `bin/heimdall-cost-forensics:85-97`), cache write 1.25x (5m) or 2.0x (1h) read from `usage.cache_creation`, output 5x input.
- ASSUMPTION: `claude-opus-5-5`, `claude-sonnet-5-5` and `claude-haiku-5-5` price like their tier siblings. Not confirmed in any file. Shares are robust to this, absolute $ are not.
- The operator looks to be on a subscription (main thread writes are 97% 1h-TTL, which docs say is the subscription default: https://code.claude.com/docs/en/prompt-caching#which-ttl-each-request-gets). $ here means plan-usage weight, not an invoice.
- 110 `<synthetic>` requests are excluded. Usage is deduplicated by `message.id` (one request spans several JSONL lines).
- **Finding (tool bug):** `bin/heimdall-cost-forensics --root <this project> --json` priced only ~12% of tokens. `unpriced_models` lists `claude-opus-5-5` 1.009B, `claude-sonnet-5-5` 1.502B and `claude-haiku-5-5` 17.7M tokens, because `PRICING` (lines 85-97) has no 5.5 rows and no `claude-fable-5-2`. Every figure it prints for this repo is a floor. Fix is a table update (S effort). Until then use the appendix scripts.

## 1. Where the spend is (MEAS)

Corpus total about **$1,805** list-equivalent: main $1,182 (fable cache-read at 0.25), subagents $621. Token mix 2,884M: cache read 2,767M (96%), cache write 96M, output 21M, fresh input 0.04M.

| Bucket | Main (3,813 req) | Subagents (6,895 req) |
|---|---|---|
| Cache read | $575 (48.6%) | $298 (48.0%) |
| Cache write | $539 (45.6%), all 1h-TTL | $131 (21.2%), all 5m-TTL |
| Output | $72 (6.1%) | $191 (30.8%) |
| Fresh input | ~0 | ~0 |

Main thread by model: opus-5-5 2,832 req $828 (70%); fable-5-1 723 req $302 (25.5%); opus-5 258 req $53 (4.4%). User default is now `claude-fable-5-2[1m]` in `~/.claude/settings.json`.

Main-thread spend by context size at request time (MEAS, `rep2.py`):

| Context | Requests | Share of main $ |
|---|---|---|
| <150K | 685 | 5.9% |
| 150-300K | 1,185 | 19.6% |
| 300-500K | 1,184 | 36.3% |
| 500-800K | 776 | 33.8% |
| >800K | 73 | 4.4% |

Median context 310K, p90 646K, max 888K. **74.5% of main spend is at >300K context.**

Main-thread cache-write causes (MEAS, `rep4.py`):

| Cause | Events | Write tokens | $ | Share of main |
|---|---|---|---|---|
| Idle gap >1h (cache expired, whole prefix rewritten) | 102 | 36.4M | $441.88 | **37.2%** |
| Incremental growth | 3,691 | 5.5M | $67.45 | 5.7% |
| Compaction or new session | 11 | 0.9M | $10.45 | 0.9% |
| Unexplained full invalidation | 6 | 1.2M | $19.05 | 1.6% |

Of the 102 expiry events, 78 had >150K prior context; mean rewrite is 357K tokens. Only 2 model switches in 72 days (cold write $10 total), so model switching is not a lever.

## 2. What was already decided: not re-proposed

- Context cap at ~150K is lever #1 in `token-spend-forensics.md` and `2026-09-02-input-context-cost.md` §5. Headroom rejected (0.271-0.558% of spend, `2026-08-25-headroom-inpath-measurement.md`). Reasoning-bank wiring rejected (`2026-08-22-reasoning-bank-wiring-decision.md`). Caveman ultra low priority (`2026-08-11`, `2026-08-30` audits). Preamble trim low priority (~$14.65 per 10K tokens).
- `2026-09-08-context-discipline-gate.md` built `ctx-meter gate`. **New evidence: it did not bind.** This session started 3 days after it shipped and ran at median 310K, with 73 requests above 800K.
- `2026-09-07-cache-create-mechanism.md` classed main-thread TTL expiry as "expected, unavoidable." This doc measures that bucket at 37.2% of main spend and shows it is the cheapest moment to compact (section 4, lever 2).

## 3. Ranked levers

Savings are not additive where marked. "Falsify" is a check that goes red if the lever did not work.

| # | Lever | Measured bucket | Est. saving and method | Effort | Risk | Falsify |
|---|---|---|---|---|---|---|
| 1 | **Native auto-compact window**: set `autoCompactWindow` (settings) or `CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000` (>=100000 allowed). `/autocompact 300k` does it live | 74.5% of main $ (about $880) is at >300K context | **$470 = 39.6% of main, 26% of corpus** (DERIVED: replay with offset subtraction at each 300K crossing, 19 compactions, 80K post-compact base, 10K output per compaction; `rep4.py sim`). Cap 150K: $620 (52%), 70 compactions | S: one settings line | Compaction loses detail. Mitigated by existing `/hmd:continue` handoff and the SessionStart(compact) re-inject (`hooks.json`, 11 compact injects measured). Needs the operator's yes | After 7 days, rerun `rep2.py` on the new session: share of requests >300K must be <10% of requests, and `/usage` "Prompt cache (main)" line shows expected rebuilds not misses |
| 2 | **Cold-cache return handling** (37.2% bucket): make `ctx-meter` emit one model-visible line only when idle gap >55 min and context >150K ("cache cold: compact now costs ~0 extra, continuing re-writes N tokens"); also try env `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=100000` (default 200000) | 102 expiry events, $442. 45 events with >=200K context happened AFTER v2.1.290 (idle compaction available), $184, so native idle compaction did not prevent them | $476 (idle-only at 300K, 13 restarts) to $624 (idle-only at 150K, 33 restarts); sensitivity with 150K re-work base: $493. **Not additive with #1**; incremental over #1 about $150 (DERIVED, `rep4.py`) | M (hook plus state file for last-activity time) | A nudge only; the operator can ignore it, as with the current notice | New unit test: simulate gap 3700s, ctx 400K, assert one stdout line; in transcripts, expiry events at >300K context drop to <5 per 30 days (`rep4.py`) |
| 3 | **Subagent thinking effort**: 19.0M subagent output tokens = $191 (30.8% of subagent $, 10.6% of corpus). Visible output is about 2.2M tokens (chars/4: Write/Edit input 5.8M chars, other tool_use 2.6M, text 0.45M, thinking 0.04M chars), so roughly 88% of output is hidden thinking. Thinking cannot be switched off on Sonnet 5.5 or Opus 5.5 (https://code.claude.com/docs/en/costs#adjust-extended-thinking). Lever is effort level (`CLAUDE_CODE_EFFORT_LEVEL`, per-agent frontmatter UNVERIFIED) | $191 sub plus $72 main output | $25-50 (INF: 15-25% output reduction at `medium` vs current. No measurement of effort vs output exists in this repo) | S to try, M to measure | Quality drop on hard tasks | A/B on 10 identical tasks: output tokens per task and verifier pass rate. Go only if pass rate is equal |
| 4 | **Static base trim**: CLAUDE.md chain is 51,682 chars (about 12.9K tok) and skill listing 29,268 chars (about 7.3K tok) in EVERY subagent first request of 47.5K tokens (42%). Main system prompt part is 79.7K chars (full `agents/heimdall.md`, not the lean one) | 20K tok x (3,813 x $0.445 + 6,895 x $0.20 per M) | CLAUDE.md to <=13 KB: about **$30** (DERIVED). Lean main prompt (29.3K vs 67.4K chars): about $16 (DERIVED: 9.5K tok x 3,813 x $0.445). About 2.5% of corpus together | M (CLAUDE.md prose is load-bearing for hooks docs) | Behavior drift. `evals/lean/prompt-parity.receipt.json` verdict is `unverified` (no recorded traces), so lean cannot ship yet | `wc -c CLAUDE.md` <= 13000; subagent first-request ctx (`sub.py`) drops from 46.4K mean to <=36K |
| 5 | **Cap agent final reports**: 1,152 task-notifications injected as user text into main, 641K tokens, carried to the next compaction; mean 2,390 chars, p90 5,091, max 10,307 (completed n=999) | $61.26 = 5.2% of main (DERIVED: tokens x remaining requests x $0.445 plus write at $12.2/MTok) | $20-25 (INF: cap at 1,500 chars saves about 37% of mean). Details go to a `.planning/` file the main thread reads only when needed | S (`agents/*.md` report clause plus a SubagentStop length check) | Coordinator loses detail. It can Read the file | Next 100 notifications: mean chars <1,600 (`rep5` task-notification query) |
| 6 | **Subagent Read discipline**: 1,599 Reads, 16.4M chars (4.1M tok), 52% of Read results have no offset or limit; 3.05M chars (18.6%) are repeat reads of one path inside the same agent; plan files read whole by 76, 22, 17 and 13 coders (12.5% of Read chars) | carried 188M tok = about $47 (7.6% of subagent $) | $10-15 (INF: remove repeats plus slice plans per task). Under 1% of corpus | M | Low | Same query: repeat-read chars <10% |
| 7 | **hmd-owned hook injections** into model context: parallel-gate "MULTI-PART TASK DETECTED" 637 x 851 chars ($13.06); caveman per-prompt 1,471 x about 130 chars ($4.53) | $17.6 = 1.5% of main | <=$10 (throttle parallel-gate to once per N prompts or when text changes). Caveman stays: $4.5 does not justify losing the compression | S | Low | `hook_additional_context` count of MULTI-PART per 100 prompts <10 |
| 8 | Main-thread default model (informational): fable-5-1 was 723 requests, $302, $0.417/req vs opus-5-5 $0.292/req | 25.5% of main $ for 19% of requests | Not estimated: contexts differ per segment, so per-request ratio is confounded. Operator choice, not a repo change | n/a | n/a | n/a |

Rejected with new evidence:
- **`subagentPromptCacheTtl=1h`** (and `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL`): subagent 5m-TTL expiries cost only $9.95 (21 events, 4.0M tokens). Moving every subagent write to 2.0x costs about **+$70 net** (DERIVED, `rep6.py`). Do not do it. Subagent median lifetime is 1,044 s.
- **Stop-hook output** (2.16 MB stdout, 1,243 fires, 9.3M ms wall = 2.6 h of hook time): not model-visible (no `hook_additional_context` rows for Stop). A latency issue, not a token one.
- **ctx-meter per-turn notice to the model**: would cost tokens every turn; the existing stderr-only design is right. Lever 2 differs because it fires on a rare cold-return event.

## 4. Why the ctx-meter has not bound (MEAS plus code reading)

- `hooks/hooks.json` wires only `heimdall-ctx-meter notice` at UserPromptSubmit. `gate` (the tiered, exit-coded verb) is "invoked deliberately by the orchestrator" (`bin/heimdall-ctx-meter` header) and is not on any hook.
- `notice` writes to stderr (header: "UserPromptSubmit stdout becomes model context"). In 72 days the session transcript contains **0** occurrences of `[heimdall] CONTEXT`, so the operator and the model never saw it in the recorded stream.
- Lever 2 is therefore not a second meter. It is one new trigger (idle gap) reusing the meter's existing published ctx record and its existing 150K ceiling: zero new thresholds, same rule as the 2026-09-08 design.
- Why idle-return is the best compaction moment: https://code.claude.com/docs/en/prompt-caching#compacting-the-conversation says a compaction request after the TTL reprocesses the history uncached, but the turn after it rebuilds only the short history. The full-prefix write is paid either way, so compacting then costs about one 10K summary and saves every later read of the discarded context. Mid-task, a warm compaction reads the prefix at 0.1x. Both are cheap; skipping it is what costs.

## 5. External facts used (all fetched 2026-11-22)

- Env vars: https://code.claude.com/docs/en/env-vars. `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (can only lower), `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (token count >=100000), `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` (default 200000, v2.1.290+). The page was truncated at 100K chars, so `ENABLE_PROMPT_CACHING_1H`/`FORCE_PROMPT_CACHING_5M` came from the prompt-caching page instead.
- Prompt caching: https://code.claude.com/docs/en/prompt-caching (TTL buckets, `promptCacheTtl`, `subagentPromptCacheTtl`, model switch and compaction invalidation, plugin enable keeps cache, subagent first request never reads parent cache).
- Costs: https://code.claude.com/docs/en/costs (`/usage` "Prompt cache (main)" line shows warm/cold; recommends compacting before stepping away, CLAUDE.md under 200 lines, delegation to subagents).
- Context window: https://code.claude.com/docs/en/context-window (`/autocompact 500k`, what survives compaction, SessionStart(compact) hooks re-run).
- **UNVERIFIED:** exact semantics and default of `idleCompaction` and the "Default auto-compact thresholds" table. The settings-reference and model-config fetches were truncated before those entries. Lever 2's env-var trial must be treated as an experiment until read.
- **UNVERIFIED:** whether a plugin `settings.json` can carry `autoCompactWindow`. `2026-11-12-lean-agent-override.md` shows the plugin `agent` key is deprecated, so put it in the user `~/.claude/settings.json` (operator-owned), not in the plugin.

## 6. Top-3 recommendation, file-level

1. **Set the compaction window (lever 1).** In the operator's `~/.claude/settings.json` add `"autoCompactWindow": 300000` (or env `CLAUDE_CODE_AUTO_COMPACT_WINDOW`). Add a one-line note to `skills/heimdall/references/definition-of-done.md` or `CLAUDE.md` Token Efficiency section stating the value and the measurement that justifies it. No hmd code needed. Try 300K first (13-19 compactions per 72 days); drop to 250K only if 7-day data still shows >10% of requests above 300K.
2. **Cold-return trigger in the meter (lever 2).** `bin/heimdall-ctx-meter` `notice`: read the last-activity time (a small state file touched by an existing Stop hook, or the transcript mtime from the published record), and when idle > `HMD_CTX_TTL`-style 3300 s and published tokens >= the existing ceiling, print ONE stdout line once per cold return. Test: new `test/ctx-meter-cold-return.test.sh` (mirror `test/ctx-meter*.test.sh`; assert one line, assert silence when warm or below ceiling). Keep the per-turn path silent.
3. **Fix the measuring stick first, then cap reports.** (a) Add the 5.5 and fable-5-2 rows to `PRICING` in `bin/heimdall-cost-forensics:85-97` so the next audit is priced (prices must be confirmed from https://platform.claude.com/docs/en/about-claude/pricing; not done here). (b) Add a "final report <=1,500 chars, details to `.planning/<task>.md`" clause to `agents/coder.md`, `architect.md`, `test-runner.md`, `docs-writer.md` (lever 5, about $20-25).

Do not chase levers 6-8 first: together under 2% of corpus.

## 7. Red flags

- Lever 1 and 2 numbers come from one operator's one long session (n=1). The counterfactual replays tokens but cannot price the quality loss of compaction or the extra file re-reads after it (one sensitivity row is given).
- The corpus window only reaches back to 2026-09-11 (older transcripts rotated away), so the August measurements in other docs cannot be cross-checked here.
- Lever 3 has no in-repo measurement of effort vs output; it is the weakest number in the table.

## OUT OF SCOPE

Code edits, settings edits, running `test/run-all.sh`, wiring `ctx-meter gate` as a blocking hook, changing the main-thread model, Headroom or claude-mem work, caveman wording changes, release or deploy.

## Appendix: commands run (every number above traces here)

Scripts live in `/private/tmp/claude-501/-Users-rj-Downloads-heimdall/0e12831c-b9f2-4238-ad95-43a28e7409d2/scratchpad/` (scratch may be cleared; each is under 80 lines of `python3 -I` with only `json`, `glob`, `collections`, `pickle`).

```
python3 -I agg.py                         # 158 files, 10,859 deduped requests -> rows.pkl (usage per message.id, model, 5m/1h write split, agentType from *.meta.json)
python3 -I rep1.py                        # section 1 token and $ split: all, main, subagents, per session, per agent type
python3 -I rep2.py                        # context-size buckets, context drops, models, per-month $
python3 -I rep3.py                        # per-model main $, model switches (2)
python3 -I rep4.py                        # write causes, expiry by gap and ctx, restart replay (caps 150K/300K, idle-only or any-time), pre/post v2.1.290, sensitivity
python3 -I carry.py                       # carried-context weight by tool and injection in main (main_ev.pkl)
python3 -I rep5.py                        # $ per prompt/hook category: task-notification, parallel-gate, caveman, environment (avg $0.445/MTok read, $12.2/MTok 1h write)
python3 -I sub.py                         # subagent first-request ctx by agent type, Read/Bash carry, output block chars
python3 -I rep6.py                        # subagent 5m expiry cost and 1h-TTL counterfactual (+$70)
inline python (task-notification sizes by status; Read result sizes, repeat reads, top paths, limit/offset use; hook_success stdout by hook; compact_boundary metadata; CC version timeline; attachment census; prompt_snapshot composition)
bin/heimdall-cost-forensics --root ~/.claude/projects/-Users-rj-Downloads-heimdall --json   # exposed the unpriced-model gap
grep -c '\[heimdall\] CONTEXT' 0e12831c-....jsonl                                           # 0
wc -c agents/heimdall.md agents/heimdall-lean.md agents/coder.md skills/heimdall/SKILL.md CLAUDE.md                          # 67385 29336 20779 11777 51990
python3 -I (hooks.json walk)              # which hooks are wired; only ctx-meter `notice`
WebFetch: code.claude.com/docs/en/{env-vars,costs,prompt-caching,settings-reference,model-config,context-window}
```

Key raw outputs: `compact_boundary` rows show 11 compactions (3 manual, 8 auto; preTokens 261K to 889K, postTokens 13K to 21K). Subagent first request is 47,535 tokens for a sampled coder: skill_listing 29,268 chars, instructions 51,682 chars, prompt_snapshot 35,945 chars. Per-agent-type first-request mean: coder 46.4K (n=133), architect 48.5K (n=9), test-runner 36.2K, docs-writer 34.2K, Explore 17.5K.
