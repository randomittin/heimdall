---
name: self-improve
description: The deliberate self-improvement loop for the maintainer — after every Nth maintenance cycle (or on /hmd:self-improve), step back from fixing issues and improve Heimdall's OWN capability. Ports karpathy/autoresearch to Heimdall's routing/planning: collect evidence from metrics.jsonl + queue dead/done stats → form testable hypotheses → run a bounded routing experiment → evaluate against a measured delta → keep the improvement ONLY if it beats a baseline on enough samples, else roll it back. Falsifiability over vibes. Use when a maintainer run has completed N cycles, when the user asks Heimdall to "get better over time", "improve itself", "tune routing", "learn from past runs", or invokes /hmd:self-improve.
---

# self-improve — improve the improver

The maintainer loop (`/hmd:maintain-check`) *fixes issues*. This skill makes the maintainer
*get better at fixing issues* over time. It is [karpathy/autoresearch](https://github.com/karpathy/autoresearch)
applied to Heimdall's own routing and planning — see
[docs/analysis/autoresearch-distilled.md](../../docs/analysis/autoresearch-distilled.md) for the
distilled mechanics this is built on.

autoresearch's one non-negotiable rule, imported wholesale: **an improvement persists only with a
measured delta over a baseline on enough samples — never because it seemed better.** The mechanical
parts (aggregation, hypothesis generation, override apply/rollback, experiment logging) live in
`bin/heimdall-self-improve`; your job is the judgement of *which* hypothesis is worth an experiment.

## When this runs

- **Every Nth maintainer cycle.** `/hmd:maintain-check` fires this after every `self_improve.every`
  completed cycles (default 10 — matching the "after every 10 completed tasks" cadence in
  `agents/heimdall.md` → *Pattern Learning (SONA-inspired)*). One experiment per invocation.
- **On demand:** the user runs `/hmd:self-improve` or asks Heimdall to improve/tune itself.

Do NOT run it mid-fix. It is a deliberate *step back* between batches of work, exactly like
autoresearch's overnight step-back between training runs.

## The loop (autoresearch's five invariants, ported)

```
collect  ->  hypothesize  ->  experiment (bounded)  ->  evaluate (measured)  ->  keep | discard
   ^                                                                                    |
   +------------------------ the experiment LOG is the accumulated knowledge -----------+
```

### 1. Collect evidence

The comparable scalar is **first-attempt AC pass-rate** per `(task_type, model)` (plus avg retries
and wall-secs) — Heimdall's `val_bpb`. Read it from `.planning/metrics.jsonl` (task-outcome records)
and the queue dead/done stats:

```bash
heimdall-self-improve collect --repo .          # the aggregated scalar per (task_type, model)
```

Task-outcome record shape (one JSON line; non-`task` records are ignored):
`{"metric":"task","task_type":"lint","model":"sonnet","outcome":"pass"|"fail","retries":N,"wall_secs":N,"ts":"..."}`.
Queue dead/done stats (optional) live at `.planning/queue-stats.json`:
`{"dead":[{"reason":"lint-timeout","task_type":"lint","count":4}], "done":[...]}`.

### 2. Hypothesize

```bash
heimdall-self-improve hypotheses --repo . --min-samples 3
```

Emits testable candidates, each with its measured baseline evidence:

- **escalate** (`hyp-esc-<type>-<model>`) — a task_type failing on its current tier → bump a tier.
  *("If haiku tasks fail > 30% → bump to sonnet." — agents/heimdall.md.)*
- **cheapen** (`hyp-cheap-<type>-<model>`) — a task_type passing flawlessly with zero retries → try
  the cheaper tier and keep only if the pass-rate holds. *(cost savings, same outcome.)*
- **precheck** (`hyp-precheck-<reason>`) — a recurring dead-task reason cluster → suggests a
  pre-check or a new `.planning/skills/*.md` pattern (surfaced for a human, not auto-A/B'd).

The `--min-samples` gate is the autoresearch invariant: **no hypothesis without enough evidence.**

Pick the ONE highest-value hypothesis. Prefer an escalate on a high-traffic failing type; a cheapen
only when the baseline is genuinely flawless.

### 3. Experiment (bounded)

Apply the variant as a routing-override. It is bounded — the next matching tasks get the variant,
tracked — exactly like autoresearch's fixed 5-min budget makes runs comparable:

```bash
heimdall-self-improve experiment start --hypothesis hyp-esc-lint-sonnet \
    --min-samples 3 --min-delta 0.10 --repo .
```

This writes `.planning/routing-overrides.json` (which the planner reads when assigning model tiers),
snapshots the baseline **and the prior override** (for exact reversibility), and appends an OPEN
record to `.planning/experiments.jsonl`. Let the next maintainer cycles run the variant.

### 4. Evaluate (measured — the falsifier)

The evaluator is the recorded task **outcomes** from the real gate — the routing change being tested
cannot grade its own homework (autoresearch invariant 4). After enough matching tasks have run:

```bash
heimdall-self-improve experiment evaluate --id <exp-id> --repo .
```

- **KEEP** iff `variant_samples >= min_samples` AND `delta_pass_rate >= min_delta`. The override is
  marked `validated` and stays.
- **DISCARD** otherwise (too few samples, or no measured improvement) — the override is **rolled
  back to its prior value** and the experiment is logged `discarded`. Never persist on vibes.

### 5. The log is the memory

`.planning/experiments.jsonl` is the append-only record you resume from — every hypothesis, its
baseline, its measured delta, its verdict. `heimdall-self-improve status --repo .` folds it to the
current picture (active overrides, validated wins, open experiments).

## What a validated improvement becomes

- **Routing:** a `validated` entry in `.planning/routing-overrides.json` (the planner consumes it).
- **Pattern:** a precheck cluster → a new `.planning/skills/*.md` reusable pattern (write it, cite
  the dead-reason cluster + count as evidence).
- **Capability gap the repo should own:** if the fix belongs in the codebase (a flaky test, a
  missing pre-commit hook), file a GitHub ISSUE via `heimdall-feedback` describing the measured
  cluster — do not silently paper over it with a routing tweak.

## Discipline (do not skip)

- One experiment per invocation. Compounding many at once destroys comparability.
- Never mark an improvement kept without a fresh `evaluate` verdict in this run — quote its
  `result` block as evidence.
- A cheapen experiment that even *ties* the baseline on too few samples is DISCARDED, not kept —
  the burden of proof is on the change.
- Archive failed hypotheses by leaving them in the log; do not re-run an identical experiment that
  was already discarded without new evidence.

## Reference

- CLI: `bin/heimdall-self-improve` (stdlib python3; `-h` for full usage).
- Distilled source mechanics: `docs/analysis/autoresearch-distilled.md`.
- The SONA-inspired feedback loop this formalizes: `agents/heimdall.md` → *Pattern Learning*.
- Acceptance: `test/heimdall-self-improve.test.sh` (hermetic; proves the falsifier).
