# Compaction arithmetic — Section A measurement, and how it reorders the diet

Run: `python3 docs/analysis/compaction-arithmetic.py` over 100 sessions / 3,072
requests / 8 compacts / 2,924 turns. Request count cross-checks against
`token-spend-forensics.py`: **3,072, AGREE**. Harness pinned by
`test/compaction-arithmetic.test.sh` (32/0, proven read-only).

The spec's own rule is what this document exists to honour: *everything executes
IN THE ORDER THE MEASUREMENT RANKS, not the doc's order.* The measurement
changes that order, and contradicts two of the spec's premises.

---

## 0. The premise, corrected: "compact every ~2 turns" is true in PROMPTS, not turns

The four recent auto-compacts on the heavy session:

| # | threshold (preTokens) | baseline | headroom | **requests** | **user prompts** |
|---|---|---|---|---|---|
| 5 | 166,922 | 64,794 | 102,128 | 62 | **5** |
| 6 | 176,874 | 78,549 | 98,325 | 80 | **3** |
| 7 | 171,865 | 73,215 | 98,650 | 42 | **1** |
| 8 | 171,323 | 74,105 | 97,218 | 57 | **3** |

Between two compacts sit **42–80 API requests but only 1–5 human prompts**. So
the felt symptom is real — you type three times and it compacts — while the
mechanism is not "each turn is bloated". It is **~50 requests per prompt**, each
adding a median 989 tokens.

**This kills the obvious wrong fix.** Nothing here is solved by writing less per
turn, and the median turn is already small (989 tokens; mean 1,677 is dragged by
a 26,941 max). The levers are the *standing baseline* and the *per-request
additions that agent orchestration generates*, in that order.

A second regime exists in the same session: 3 compacts at a **984K–1,001K**
threshold, where the same ~69K baseline is only 7% of the window. The 167–177K
threshold is the punishing one — there, **baseline is 42% of the window** and
only ~99K of headroom is usable.

## 1. The BASELINE term — ranked

Mean post-compact baseline **72,666**, of which `postTokens` (the retained
message array) is only ~17K. The remainder is standing overhead.

| Rank | Contributor | Size | Share of baseline |
|---|---|---|---|
| **1** | **STANDING overhead** (system preamble, tool defs, CLAUDE.md stack, skills prose — never in the transcript) | **~55,247 tok** | **~76%** |
| 2 | `attach:agent_listing_delta` | 16,295 B/compact | — |
| 3 | `compact_summary` | 15,061 B/compact | — |
| 4 | `attach:file` | 10,108 B/compact | — |
| 5 | `hook:SessionStart` | 9,311 B/compact | — |
| 6 | `hook:SessionStart:compact` (the observation index) | **6,601 B/compact** | — |

Bytes ≈ 2–4 B/token, so the re-injections are ~3–8K tokens each.

**Refutation 1 — B1's prime suspect is fifth, and smaller than claimed.** The
spec calls the SessionStart:compact index injection "the prime suspect" at
"10–18KB". Measured: **6,601 B per compact** — a third of the low end of that
estimate, and behind the agent listing, the compact summary, file attachments,
and the other SessionStart hook. Stubbing the index is still worth doing (it is
cheap and its own header already advertises fetch-by-ID), but it is **not** the
lever, and the diet must not be sequenced as though it were.

**The actual lever is the standing overhead at ~76% of baseline** — spec item
B4, which the doc lists fourth. It moves to first.

**Unranked in the spec at all:** `attach:agent_listing_delta`, the single
largest re-injected block at 16,295 B/compact. That is the agent-type listing,
re-sent at every boundary.

## 2. The PER-TURN term — ranked

n=2,111 turns, total 3,541,200 tokens, **median 989**, mean 1,677.5, p90 3,825,
max 26,941. Attributed by NNLS over 32 parameters, **R²=0.8603**.

| Rank | Source | Tokens | Share |
|---|---|---|---|
| 1 | `model:tool_use` | 1,073,270 | **29.9%** |
| 2 | `model:thinking` | 687,601 | **19.2%** |
| 3 | `model:text` | 520,623 | 14.5% |
| 4 | `tool:Bash` | 443,789 | 12.4% |
| 5 | **`user:task_notification`** | 386,634 | **10.8%** |
| 6 | `user:prompt` | 112,235 | 3.1% |
| 7 | `hook:PreToolUse:Agent` | 81,819 | 2.3% |
| … | `tool:Read` | 28,571 | **0.8%** |
| … | `attach:edited_text_file` | 41,231 | 1.2% |

**B3 (envelope handbacks) is confirmed and is the top actionable item.** The
agent-orchestration family — `user:task_notification` 10.8% + `hook:PreToolUse:Agent`
2.3% + `tool:Agent` 1.3% — is **14.4% of all per-turn additions**, and it is the
one term that grows with parallelism. Eight agents reporting narratives is the
per-turn flood the spec predicted; this is the number that proves it.

**Refutation 2 — B2 (graph-first reading for the orchestrator) is the smallest
of the four fixes, not a headline.** `tool:Read` is **0.8%** of per-turn
additions and `attach:edited_text_file` 1.2%. The orchestrator's file reading is
already close to immaterial per-turn. The graph's value is real but it is
*generation-side* (composing spawn briefs — measured 28.7× on a real file), not
orchestrator-side context control. Ranking it above B4/B3 would spend effort
where ~2% lives.

**Not cuttable without hitting quality:** `model:thinking` at 19.2% (1,331
blocks). RJ's standing constraint is *"work quality shouldn't be impacted"*, and
reasoning is the work. It is recorded here as measured-and-excluded, not as a
target. Note it is also **not measurable from disk** — the text is never
persisted, only 3,081,588 B of signatures — so it can be sized but never audited
line by line.

## 3. Resulting execution order (replaces the doc's B1→B6)

1. **B4 — standing-baseline audit.** ~55K tokens, ~76% of baseline. Includes the
   unlisted `agent_listing_delta` (16,295 B/compact), the largest re-injection.
2. **B3 — envelope handbacks.** 14.4% of per-turn additions, and the term that
   scales with the parallelism this repo depends on.
3. **B1 — index stub.** Real but 6,601 B/compact, not the 10–18KB assumed. Cheap,
   so still worth doing — just not first.
4. **B2 — graph-first orchestrator reading.** ~2% per-turn. Do it for brief
   composition, where it measures 28.7×, not for orchestrator context control.

**B5 stands untouched and reinforced:** do NOT raise the auto-compact threshold.
The 984K–1M regime in this very session is the one that hits the measured
cache-write cliff (42,183 tok/req vs ~13,320). Raising the threshold buys fewer
compacts at the exact price the context meter exists to prevent.

**B6 is not yet decidable.** `compact_summary` costs 15,061 B/compact — second
largest re-injection — but whether it is *lossy* relative to the checkpoint path
is a fidelity question the resume probe answers, not this arithmetic.

## 4. Honest limits

- **85.5% attribution exactness.** Δctx agrees with the `cache_creation` witness
  exactly on 2,500 of 2,924 turns; 114 within 20 tokens; **310 off**. The shares
  above are strong but not exact, and no decision here rests on a margin
  narrower than the gaps between ranks.
- **R²=0.8603**, so ~14% of per-turn variance is unexplained by the 32 sources.
- **1,331 thinking blocks and 18 images are not measurable from disk** (images
  are priced by dimensions, not bytes).
- Several sources price at **zero tokens** despite non-trivial observed bytes
  (`hook:PreToolUse:Bash` 118,368 B, `hook:UserPromptSubmit` 195,753 B
  corpus-wide) — the fit assigns them no cost, which most likely means they are
  cache-resident rather than genuinely free. Do not cite them as savings.
