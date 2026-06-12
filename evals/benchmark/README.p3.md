# Benchmark Harness — P3 Parity Prep

This directory contains the **3-arm benchmark harness** for the heimdall parity plan, phase 3.
It was created in-worktree on branch `parity/p3-benchharness` and is NOT yet merged to main.

## Status: PREP ONLY — runs are GATED

**No models have been invoked. No tokens have been spent.**

All execution scripts are guarded by a `--confirm-spend` flag. Without it, every script prints:

```
GATED: awaiting RJ stranger-test pass — no token spend
```

and exits 0. The gate is intentional — it must be lifted by RJ after the stranger-test pass.

## What is here

```
evals/benchmark/
  tasks/
    01-multifile-feature.{json,md}   multi-file feature: rate-limiter middleware + store + tests
    02-bugfix-with-tests.{json,md}   bug fix: off-by-one + DST bug in date-range util
    03-lint-refactor-batch.{json,md} lint/refactor: zero ESLint warnings on a messy module
    04-fullstack-scaffold.{json,md}  full-stack scaffold: notes API + client + integration test
    05-docs-and-tests.{json,md}      docs + tests: document and cover a CSV parser
  run.sh                 single arm × task × run, with spend gate
  harness.sh             orchestrator: loops 3 arms × 5 tasks × 3 runs, spend-gated
  summarize.sh           computes median + [min-max] range from results.jsonl
  model-pins.json        arm → model ID mapping (fill before live run)
  BENCHMARKS.template.md empty results table + metric definitions + how-to-run
  README.md              original 2-arm harness README (unmodified)
  README.p3.md           this file
  results.md             markdown table fragment (written by run.sh; starts empty)
  results.jsonl          raw JSONL records (one per invocation; written by run.sh)
  summary.jsonl          median/range summary (written by summarize.sh)
```

## The 3-arm design

| Arm | What it is |
| --- | --- |
| `raw` | Plain `claude` CLI, no agent, no plugin, no goal preamble |
| `superx` | superx last-tag binary wrapping claude |
| `heimdall` | `claude --agent heimdall --plugin-dir <repo>` with `/goal` preamble |

Same 5 tasks, same seeded workspaces, same oracle checks. 3 runs per arm × task cell.
Final report: median + [min–max] range per cell. Every cell published — including losses.

## Spend budget

~600k tokens approved for the full 45-run matrix (3 arms × 5 tasks × 3 runs).
See `model-pins.json` for where to record model IDs before executing.

## Metrics captured per run

- `tokens.total` — total tokens (input + cache + output)
- `tokens.input / output / cache_read / cache_write` — by role (token ledger)
- `wall_seconds` — wall-clock time for the arm invocation
- `tests.passed / tests.total` — external oracle result (not self-reported)
- `human_interventions` — 0 for automated; set via `--interventions N` for manual
- `bloat_lines` — git diff insertion count in workspace after run
- `cost_usd` — from `claude --output-format json .total_cost_usd`

## To run once unblocked

```sh
# Dry run (safe, no models):
bash evals/benchmark/harness.sh --dry

# Single invocation to test harness mechanics:
bash evals/benchmark/run.sh \
  --arm raw --task 01-multifile-feature --run 1 \
  --confirm-spend

# Full matrix:
bash evals/benchmark/harness.sh --confirm-spend

# Summarize:
bash evals/benchmark/summarize.sh
```

Fill `model-pins.json` first. Commit results as one atomic commit after all runs.

## Honesty rule

Every measured cell is published, including cells where heimdall loses on tokens, cost, or wall time.
A cell that prints a loss is more trustworthy than a cherry-picked table that hides one.
