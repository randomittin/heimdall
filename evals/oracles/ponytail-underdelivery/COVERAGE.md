# ponytail-underdelivery — coverage

The falsifiable **under-delivery guard**. It proves the claim the user cares most
about in the Heimdall × Ponytail integration: adopting ponytail's write-time
lazy-ladder (now in `agents/coder.md`) **cannot** cause an agent to ship a
half-built feature, because the oracle gate is non-bypassable. A deliberately
under-delivered "lazy" shortcut **fails the gate**.

## The feature under test

`roman(n)` — integer `1..3999` → canonical Roman numeral string. Chosen because
it has a clear **hard part** (subtractive notation: `IV IX XL XC CD CM`) that a
too-aggressive minimalist is tempted to skip, plus a **required scope** (the full
range up to `3999` via `M`) that is temptingly "YAGNI-able".

- **Subject** (`--input`): a candidate implementation — an ES module exporting
  `default function roman(n)`.
- **Acceptance oracle** (`--truth`, default `fixtures/golden/acceptance.json`):
  the fixed `{n → expected}` truth table, applied identically to golden and every
  mutant. `run.sh` is the single source of diff-truth; `grade.mjs` only executes
  the candidate.

## Golden

`fixtures/golden/candidate.mjs` — terse (one greedy loop, no scaffolding, no
dependency) yet **fully delivered**: subtractive notation and the full range are
both present. It PASSES every acceptance case. This is what "lazy but complete"
looks like — minimalism cut the gold-plating, never the requirements.

## Mutants — the exact under-delivery modes the ladder could cause

Each is real, running code (no banned marker tokens) whose defect is
**behavioral** and caught by the acceptance oracle. `bin/falsify` requires all
three REJECTED (plus golden PASS) for score `1.0`.

| Mutant | Ladder-risk mode | Defect | First fail |
|--------|------------------|--------|-----------|
| `hard-part-skipped` | (a) hard part skipped | only additive symbols built; subtractive branch never written (`4 → IIII`) | `roman(4)` expected `IV`, got `IIII` |
| `criterion-dropped` | (b) required criterion silently dropped | subtractive correct, but the required `1..3999` range narrowed to `1..999` — thousands scope gone (`1000 → ""`) | `roman(1000)` expected `M`, got `""` |
| `terse-but-broken` | (c) small-but-broken | smallest one-liner reduce, full map + range, but off-by-one `n > v` (must be `n >= v`) collapses exact boundaries (`1 → ""`) | `roman(1)` expected `I`, got `""` |

## The falsifiability proof (not a tautology)

`test/heimdall-underdelivery-guard.test.sh` proves the gate's **strength is
load-bearing**: WEAKEN the acceptance oracle (strip the subtractive/thousands
cases) and `hard-part-skipped` SURVIVES (passes) — the falsify sweep score drops
from `3/3 = 1.0000` to `1/3 = 0.3333`. Restore the hard cases and it is caught
again. The score moves **because the gate does the work**, not because the check
is rigged to pass. That is the whole thesis: minimalism can't ship a shortcut,
because nothing ships that fails the (unweakened) gate.

## Run

```
bin/falsify ponytail-underdelivery --assert-score 1.0     # -> 3/3 = 1.0000, exit 0
bash test/heimdall-underdelivery-guard.test.sh            # -> 12 passed, 0 failed
```

The pre-push hook auto-discovers this domain under `evals/oracles/*` and blocks
any push where the score is below `1.0` — the guard is enforced, not advisory.
