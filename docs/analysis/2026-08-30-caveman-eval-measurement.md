# Caveman eval: real measurement, hmd vs upstream's MIT skill

Companion to `docs/analysis/2026-08-30-caveman-upstream-practices.md` (the
license-boundary map). That doc established the valid comparison is hmd's
caveman levels vs upstream's MIT-licensed `skills/caveman/SKILL.md` — **never**
vs upstream's BSL-1.1 Engine/Proxy, which mechanically rewrites bytes on the
wire and is a different category of thing entirely (instruction injection vs
mechanical rewrite). This doc does not touch the Engine/Proxy at all and makes
no claim about it in either direction.

Every number below is tagged:
- **MEASURED** — read straight out of `evals/caveman/snapshot.json`, generated
  by a real `refresh --confirm-spend` run (10 real `claude -p` prompts x 6
  arms = 60 real model calls, see §1). Reproducible: `bin/heimdall-caveman-eval
  report --json`.
- **READ-FROM-SOURCE** — read directly from `bin/heimdall-caveman` or
  `evals/caveman/upstream_skill.md`, not run.
- **ANALYSIS** — my own inference connecting the measured numbers to the
  source text. Flagged as such because it is a judgment call, not a fact.

No number in this document is estimated, rounded from a guess, or backfilled.
Where I did not measure something, I say so instead of guessing (e.g. §6 does
not attempt a hypothetical "if we changed X, savings would be Y" — that would
be exactly the fabrication this eval exists to prevent).

## 0. tl;dr verdict

**MEASURED. hmd is behind upstream's MIT skill, on this measurement, at every
level, by a wide margin.** Head-to-head median delta (hmd vs upstream_skill,
positive would mean hmd uses fewer tokens for the same prompt):

| hmd level | vs upstream_skill (median) | vs upstream_skill (mean) |
|---|---|---|
| hmd_lite  | **−42.7%** (hmd uses ~43% more tokens) | −81.2% |
| hmd_full  | **−21.9%** (hmd uses ~22% more tokens) | −49.1% |
| hmd_ultra | **−32.9%** (hmd uses ~33% more tokens) | −32.1% |

No hmd level beats upstream's skill on this run, on either median or mean.
hmd_full and hmd_lite do not reliably beat *doing nothing* (see §2 — both
land above the raw no-system-prompt baseline's total token count). This
triggers the orchestrator's stated condition for Task 5 ("only if hmd is
measurably behind, improve the rule text and re-measure") — see §6 for why
that edit did not happen in this pass.

## 1. Setup — MEASURED

- Tool: `bin/heimdall-caveman-eval refresh --confirm-spend --model sonnet`
- Prompts: `evals/caveman/prompts.txt`, 10 real dev questions (unchanged,
  vendored verbatim from upstream's own `evals/prompts/en.txt`)
- Arms (6): `__baseline__` (no system prompt), `__terse__` ("Answer
  concisely." only), `upstream_skill` (upstream's MIT SKILL.md, vendored
  byte-identical, composed as upstream's own harness composes it — see
  `bin/heimdall-caveman-eval`'s header), `hmd_lite`, `hmd_full`, `hmd_ultra`
  (`heimdall-caveman rules <level>`, unmodified, live production text)
- Model: `sonnet` (the tier alias). Not `haiku` — checked `claude --help`
  first; this environment's only documented `--model` aliases are `fable`,
  `opus`, `sonnet` (no haiku in this generation's lineup), so `sonnet` is the
  cheapest of the three named tiers and also this repo's own documented
  default coding tier (`CLAUDE.md`, "Model routing")
- Calls made: 60 real `claude -p --output-format json` calls (10 prompts x 6
  arms), plus 1 `claude --version` probe = 61 total
- **Cost: $3.7522** (summed from real `total_cost_usd` on every one of the 60
  calls — `cost_usd_calls_missing: 0`, so this is a complete sum, not a
  partial one). Per-arm breakdown:

  | arm | calls | cost | tokens (total) |
  |---|---|---|---|
  | `__baseline__` | 10 | $0.6946 | 3920 |
  | `__terse__` | 10 | $0.6142 | 3843 |
  | `upstream_skill` | 10 | $0.6110 | 3106 |
  | `hmd_lite` | 10 | $0.6183 | 4285 |
  | `hmd_full` | 10 | $0.6093 | 3976 |
  | `hmd_ultra` | 10 | $0.6048 | 3508 |

- Snapshot committed: `evals/caveman/snapshot.json`
  (`generated_at: 2026-08-30T18:12:58.310805+00:00`)

**Sample-size caveat, stated plainly:** n=10 prompts. The stdevs below (27%
to 102%) are large relative to the medians — this is a real, honest signal
from a small, noisy sample, not a bug. Treat the *direction* of the finding
(hmd behind, consistently, across all 3 levels and both median and mean) as
solid; treat the *exact magnitude* of any one percentage as a rough estimate
that a larger corpus could shift. I did not run a second batch to compute a
confidence interval — that would roughly double the $3.75 cost for a
refinement, not a reversal, of the direction already visible here.

## 2. Reference arms — MEASURED

- `__baseline__` (no system prompt): 3920 tokens total
- `__terse__` ("Answer concisely."): 3843 tokens total, **+2.0% vs baseline**
  (`terse_vs_baseline_pct: 0.0196` — a totals ratio, matching upstream's own
  `measure.py` convention of reporting this one number as a totals ratio
  rather than a per-prompt distribution; every other number in this doc is a
  per-prompt distribution)

A generic terse instruction alone buys almost nothing here (+2%). This is
exactly upstream's own point in shipping this control arm: whatever an actual
skill/level buys has to clear this near-zero bar to mean anything, and be
measured against *this* arm, never against raw baseline.

## 3. upstream_skill vs `__terse__` — MEASURED

| median | mean | min | max | stdev | tokens (skill / terse) |
|---|---|---|---|---|---|
| +20.0% | +23.6% | −15.1% | +73.7% | 26.8% | 3106 / 3843 |

Upstream's own MIT skill clears the terse-control bar clearly: a median 20%
reduction, mean 24%, on top of the generic terse instruction. One prompt
(min −15.1%) got worse, everything else got better, up to −74% better on the
best case. This is upstream's skill doing real, measurable work.

## 4. hmd levels vs `__terse__` — MEASURED

| level | median | mean | min | max | stdev | tokens (level / terse) |
|---|---|---|---|---|---|---|
| hmd_ultra | +0.1% | +5.9% | −41.9% | +61.1% | 32.7% | 3508 / 3843 |
| hmd_full  | −0.9% | −2.5% | −50.5% | +37.8% | 30.9% | 3976 / 3843 |
| hmd_lite  | −12.1% | −18.6% | −115.4% | +22.8% | 39.7% | 4285 / 3843 |

None of hmd's three levels clear the terse-control bar in any convincing way.
`hmd_ultra`'s median (+0.1%) is statistical noise — indistinguishable from
zero given a 32.7% stdev on n=10. `hmd_full` and `hmd_lite` have *negative*
median savings vs terse — i.e., on the typical prompt in this sample, turning
on hmd's `full` or `lite` caveman level made Claude's answer *longer* than
just saying "Answer concisely." with no caveman rules at all. `hmd_lite`'s
worst case (−115.4%) means output tokens more than doubled vs the terse
control on at least one prompt.

## 5. hmd levels vs `upstream_skill` DIRECTLY — MEASURED (the actual question)

This is the head-to-head the orchestrator asked for: positive means hmd used
*fewer* tokens than upstream's skill for the same prompt.

| level | median | mean | min | max | stdev | tokens (hmd / upstream) |
|---|---|---|---|---|---|---|
| hmd_full  | −21.9% | −49.1% | −184.5% | +10.0% | 64.6% | 3976 / 3106 |
| hmd_ultra | −32.9% | −32.1% | −107.6% | +35.1% | 48.3% | 3508 / 3106 |
| hmd_lite  | −42.7% | −81.2% | −281.8% | +14.7% | 101.6% | 4285 / 3106 |

All three negative, on both median and mean. hmd does not win this comparison
on any level, by either measure. `hmd_full` is the closest (median −21.9%)
but still meaningfully behind. `hmd_lite` is worst, by a wide margin, on
every statistic including its own worst case (−281.8% — output tokens
nearly 4x upstream's on at least one prompt).

## 6. Root cause — READ-FROM-SOURCE + ANALYSIS

`bin/heimdall-caveman`'s `_rules_lite`/`_rules_full`/`_rules_ultra`
(`bin/heimdall-caveman:405-526`) and `evals/caveman/upstream_skill.md` are
**not independently written texts that happen to differ** — hmd's rule text
was adapted from upstream's, and the "Rules" section, the
Not/Yes contrast pair, and both worked examples are close to word-for-word
identical between the two. This makes the gap in §5 more interesting than
"hmd's wording is weaker" — the wording is nearly the *same* wording.

The structural difference I can point to, reading both files side by side:

- **Upstream's skill is one omnibus document covering all six intensity
  levels at once** (`lite`, `full`, `ultra`, `wenyan-lite`, `wenyan-full`,
  `wenyan-ultra`), with a comparison table and a full ladder of worked
  examples from mild (`lite`) to extreme (`wenyan-ultra`: `"新參照→重繪。
  useMemo Wrap。"`) shown together in the *same* system prompt, every time —
  regardless of which level a user actually asked for. Upstream's own
  `evals/llm_run.py` measures this single document as one arm; there is no
  "just the lite part" variant to compare against.
- **hmd's rules text is deliberately split per level** (`_rules_lite` /
  `_rules_full` / `_rules_ultra`, dispatched by `_rules_text_for_level` at
  `bin/heimdall-caveman:532-539`) — a real, intentional design choice (one
  level injected per session, not a 6-way menu), and each level's text shows
  *only that level's own* two worked examples, never the more aggressive
  levels' examples.

**ANALYSIS:** the most plausible explanation for hmd trailing on every level,
despite near-identical rule wording, is that upstream's single prompt anchors
the model against a *visible ladder of increasing compression*, including
genuinely extreme examples (`wenyan-ultra`), on every single call regardless
of requested level — and that anchoring measurably pulls output shorter even
for calls where a milder level's rules are what's nominally "in force." hmd's
per-level isolation is architecturally cleaner (no unrelated wenyan content
injected into a plain-English session) but appears to forfeit that anchoring
effect entirely. I have not verified this hypothesis with a controlled
measurement (e.g., an arm that injects hmd's per-level text *plus* a ladder
of contrast examples) — doing so would cost another real `refresh` run
(~$3.75 again, going by this one), and confirming a causal mechanism was not
in scope for this pass. This paragraph is a hypothesis with supporting
circumstantial evidence, not a second measurement — treated and labeled as
such.

A second, smaller, also-unverified candidate: the extra header line hmd
prepends that upstream's skill does not have (`"HMD OUTPUT COMPRESSION —
level: X (rules injected below; not a compliance guarantee — audit via `hmd
caveman-audit`)"`, `bin/heimdall-caveman:407`) explicitly tells the model its
own compliance is *not guaranteed* and *will be audited* — plausible that
hedged framing reads as lower-stakes than upstream's unqualified imperative
opening, but I have no measurement isolating this line's effect either.

## 7. What this document does NOT claim

- Does **not** claim hmd beats, or is compared against, upstream's BSL-1.1
  Engine or Proxy (the mechanical byte-rewriting layer). Different category,
  not measured here, not claimed here in either direction.
- Does **not** claim a precise magnitude is stable — see the n=10 caveat in
  §1. The direction (behind, consistently) is the load-bearing claim.
- Does **not** claim the root cause in §6 is confirmed. It is the best
  explanation I have given a close read of both texts, explicitly labeled
  ANALYSIS/hypothesis, not re-verified by a follow-up measurement.
- Does **not** propose or apply a specific text change to
  `bin/heimdall-caveman`. That file is outside this task's assigned scope
  (`bin/heimdall-caveman-eval`, `evals/caveman/*`, this doc's own test file,
  and this doc — not the rules-text file itself); editing hmd's live,
  every-session production rules text on the strength of a single 10-prompt,
  $3.75 measurement, without sign-off from whoever owns that file, is a
  bigger blast radius than this task's scope covers. §6 hands the next owner
  a specific, falsifiable hypothesis (add a compression-ladder/contrast
  section to each level, re-measure the same way) rather than a vague
  "make it better."

## 8. Reproduction

```
# Free, deterministic, reads the committed snapshot:
bin/heimdall-caveman-eval report
bin/heimdall-caveman-eval report --json

# Re-run the real measurement (costs real quota, ~$3.75 going by this run):
bin/heimdall-caveman-eval refresh --confirm-spend --model sonnet

# Estimate the call count / cost shape without spending anything:
bin/heimdall-caveman-eval refresh --dry-run
```

---

## §8 — Ladder hypothesis TESTED and NOT SUPPORTED (2026-08-31)

§6 hypothesised that upstream wins because its skill is one omnibus document
showing all six levels at once — a visible compression ladder anchoring what
"more" and "less" compressed mean — while hmd emits only the active level in
isolation.

**Implemented and re-measured with the same instrument** (same 10 prompts, same
6 arms, same model, second real paid run). Every level's rules gained an
`## Intensity Ladder` — a 3-row table plus two 3-way worked examples with the
active level marked `← ACTIVE`.

### Result: rejected.

vs upstream's MIT skill, median (negative = hmd used MORE tokens):

| level | before | after | change |
|---|---|---|---|
| hmd_full  | −22% | **−46%** | 24 pts WORSE |
| hmd_ultra | −33% | −33% | flat |
| hmd_lite  | −43% | −31% | 12 pts better |

Run-to-run noise, measured from the control arms: upstream vs terse moved
+20% → +17% between runs with no change to either, so ~3 points is baseline
variance. hmd_lite's +12 is above that but hmd_full's −24 is larger still and
in the wrong direction, and stdevs remain 20-46%. Net across three levels:
no improvement, one clear regression.

**The change was NOT merged.** It lives unmerged on
`worktree-agent-a660afccd7d9a25c2` should anyone want to re-test it with a
larger corpus. The main checkout was verified byte-identical to HEAD after the
agent self-reported (and self-corrected) an accidental write to the shared
checkout.

### What this rules out, and what it does not

RULED OUT: that hmd's deficit is explained by the missing ladder. It is not —
adding it did not close the gap and made the most-used level worse.

NOT RULED OUT: everything else about upstream's rule text. The gap is real
(hmd loses at every level, on two independent runs) and its cause is still
unidentified. A third guess should not be implemented against n=10 with these
stdevs; the next honest step is a LARGER corpus first, so a real effect can be
distinguished from a 30-point standard deviation.

### Cost

Two real runs, 60 `claude -p` calls each. First $3.75; second comparable.
Roughly $7.50 total to learn that one specific hypothesis is wrong — which is
the price of not shipping a guess as a fix.
