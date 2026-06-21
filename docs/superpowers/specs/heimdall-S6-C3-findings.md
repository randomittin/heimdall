# S-6 C3 — Generalization Verdict + Findings (kept record)

**Date:** 2026-06-21 · **Runs:** full-10 `20260620T050833Z`, re-run-3 `20260621T164007Z`
**Bands:** frozen pre-result (GENERALIZES R≥0.45 ∧ W≥7 ∧ B≤2 · CORE-GAP R<0.30 ∨ W<5 · MIXED else; bimodal guard B≥3 caps at MIXED). Not moved.

## Verdict: **GENERALIZES**
- **R (median of 8 reuse-measured) = 0.50** — clears 0.45.
- **W = 8/10 confirmed PASS, 0 confirmed FAIL, 2 undetermined** — clears 7. Robust: even if both undetermined repos were real fails, W=8/10 ≥ 7.
- **B (count of 8 reuse% < 0.30) = 1** — bimodal guard did NOT fire (needs ≥3); median not masking a reinvention cluster.
- Triggering: all three GENERALIZES conditions met. Not CORE-GAP (R≥0.30, W≥5).

### Per-repo distribution (clean — cachecontrol = re-run value)
| repo | lang | reuse% | working-output |
|---|---|---|---|
| slugify | js | 0.40 | PASS |
| p-map | js | 0.50 | PASS |
| wrap-ansi | js | 0.56 | PASS |
| records | py | 0.6552 | PASS |
| cachecontrol | py | 0.375 | PASS (re-run, hardened) |
| jmespath.py | py | 0.9524 | PASS (assertion exit 0) |
| commander.js | js | 0.2581 | PASS |
| yocto-queue | js | 0.50 | PASS |
| cobra | go | null | UNDETERMINED (assertion-escaping artifact) |
| anyhow | rust | null | UNDETERMINED (assertion-escaping artifact) |

8 reuse-measured sorted: 0.2581, 0.375, 0.40, **0.50, 0.50**, 0.56, 0.6552, 0.9524 → median 0.50 (robust; two middle values both 0.50).

### Spend
Full-10 $17.47 + re-run-3 $3.74 = **$21.21** total. Tokens: full-10 10.55M, re-run 2.17M. Soft non-cache budget (3M/task) never exceeded (max 133k). Estimate was ~$14 → ~50% over across both runs.

## THE FINDING — the harness working-output gate had 4 un-hardened acceptance-bug layers
The verdict was nearly mis-read as MIXED because the **working-output measurement** (not Heimdall's output) was broken in four distinct ways — the same class as Stage A's `eval`-on-prose. None was a Heimdall failure; every confirmed working-output result is real.

1. **Missing toolchains** — `go`/`cargo` absent → cobra/anyhow exit 127 `command not found`. (Fixed: installed go 1.26.4, cargo 1.96.0.)
2. **Missing test-deps** — repo baselines needed `cherrypy` (cachecontrol) / `hypothesis` (jmespath), not installed → baseline collection errors. (Fixed: pip-installed both.)
3. **Buggy auto-discovery assertion** — cachecontrol's probe scanned BaseCache subclasses excluding only BaseCache/DictCache → picked up the existing `FileCache`, constructed `FileCache(2)`, crashed in existing code before reaching the agent's LRU. (Fixed: exclude all 6 shipped backends; falsifiable — correct-LRU PASS, no-LRU honest FAIL, broken-cap FAIL.)
4. **Shell-escaping in probe authoring** — cobra/anyhow assertion_cmds write a Go/Rust test file via `printf '%s' '...\"x\"...'`; inside single quotes the `\"` stays literal → `illegal character U+005C '\'` / `unknown start of token: \`. The toolchain runs, the baseline passes, but the generated probe won't compile. (NOT yet fixed — cobra/anyhow remain undetermined; does not change the verdict since W=8/10 already clears the bar.)

**Lesson (kept):** a working-output FAIL is only signal if the acceptance command RAN and the code failed it. The C3 harness needs an acceptance-command linter / dry-compile of every probe before a sweep, and a toolchain/dep preflight, else W measures environment completeness, not generalization. Verifying every fail's runnable evidence (per R7) is what kept a falsely-low MIXED from shipping.

## Reading
The core **generalizes**: 8/8 reuse-measured repos produced working output, reuse median 0.50 with only one reinvention. The two undetermined repos (Go/Rust working-output-only probes) are blocked by a manifest escaping bug, not by Heimdall — fixing their assertion escaping + re-running would yield a cosmetic 10/10 but cannot change the verdict.
