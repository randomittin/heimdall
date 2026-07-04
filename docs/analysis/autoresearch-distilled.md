# autoresearch, distilled — the transferable mechanics

Source: [karpathy/autoresearch](https://github.com/karpathy/autoresearch) (README + repo tree,
fetched 2026-07-05). Upstream is an overnight autonomous **LLM-training** research org; this
page keeps only the mechanics that transfer to Heimdall's maintainer loop, stripped of the GPU.

## What it actually is

Give an agent a small-but-real experiment harness and let it iterate autonomously overnight.
The agent **modifies code → runs a fixed-budget experiment → checks if a single metric improved
→ keeps or discards → repeats**. You wake up to a *log of experiments* and (hopefully) a better
artifact. Only three files matter:

- `train.py` — the ONE file the agent edits. Model, optimizer, loop — all fair game.
- `prepare.py` — fixed harness: data prep, the dataloader, and **the evaluator**. Never modified.
- `program.md` — the agent's instructions. A "super lightweight skill." **The human iterates on
  THIS** to make the research org itself faster — the meta-loop.

## The core loop (hypothesis → experiment → evaluate → iterate)

```
edit train.py  →  train for a FIXED 5-min wall-clock budget  →  read val_bpb
      ^                                                              |
      +----------- keep change iff metric improved, else discard ----+
```

~12 experiments/hour, ~100 overnight. The output artifact is the **experiment log**, not prose.

## Why it works — the five design invariants (these are what transfer)

1. **One scalar metric, objectively comparable.** `val_bpb` (validation bits per byte) — lower is
   better and *vocab-size-independent*, so architectural changes are compared fairly. The
   keep/discard decision is arithmetic, never vibes.
2. **Fixed budget per experiment.** Every run is exactly 5 minutes wall-clock (excl. compile), so
   any two experiments are directly comparable regardless of what changed. Budget also bounds cost
   and yields a predictable experiment *rate*.
3. **Small, reviewable surface per experiment.** Exactly one file changes. Diffs stay reviewable;
   the cause of a metric move is localizable.
4. **The evaluator is fixed and outside the agent's reach.** `prepare.py` (which computes the
   metric) is never edited by the agent — the thing being optimized can't grade its own homework.
5. **Persistent experiment log = accumulated knowledge.** You resume from the log, not memory.

## The meta-loop (the "improve its own capabilities" part)

The human doesn't touch the Python — they **program `program.md`**, the research-org instructions.
"It's obvious how one would iterate on it over time to find the research-org code that achieves the
fastest research progress, add more agents, etc." The system that runs experiments is itself the
subject of a slower, outer optimization loop. **Improving the improver is a first-class activity.**

## Mapping to Heimdall (what we build)

| autoresearch | Heimdall self-improve |
|---|---|
| `val_bpb`, lower better | first-attempt AC **pass-rate** (+ retries, wall-secs) per task-type |
| fixed 5-min budget | **bounded experiment**: the next N matching tasks get the variant, tracked |
| edit `train.py`, keep/discard | apply a **routing-override** (or pattern/prompt) variant, keep/discard |
| `prepare.py` fixed evaluator | `bin/falsify` + the recorded real gate verdict — external, unspoofable |
| overnight experiment log | `.planning/experiments.jsonl` — every hypothesis, its delta, its verdict |
| iterate `program.md` | iterate routing-overrides, `.planning/skills/*.md`, prompt refinements |

**The one discipline we import above all:** an "improvement" persists **only** with a *measured
delta over a baseline on enough samples* — never because it seemed better. Falsifiability, applied
to Heimdall's own maintenance capability. Implemented in `bin/heimdall-self-improve` +
`skills/self-improve/SKILL.md`; triggered every Nth maintainer cycle (see `/hmd:maintain-check`).
