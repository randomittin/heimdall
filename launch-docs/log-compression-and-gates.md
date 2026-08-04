---
title: Does context compression break AI code verification? We measured it
date: TBD — the publication date is the day the last receipt is filled, not before
slug: log-compression-and-gates
description: A compression proxy can measure its own token savings. It cannot measure whether the diff that came back still passes an external oracle. We ran the A/B and scored it on gate outcomes.
tags: [context compression, verification, falsifiability, a/b testing, pre-registration]
author: Heimdall Engineering
read_time: 10 min read
canonical: https://runheimdall.dev/log-compression-and-gates.html
crosspost:
  - dev.to      (canonical_url: https://runheimdall.dev/log-compression-and-gates.html)
---

> ## ⛔ NOT PUBLISHED. THE A/B HAS NOT RUN. DO NOT POST THIS.
>
> **Every `[RECEIPT: …]` below is an unfilled measurement.** Every `[SOURCE: …]` is a sentence
> about someone else's product that has not been read against their documentation yet. Each
> marker names exactly what fills it and where that comes from.
>
> **Hard gate: if a single `[RECEIPT:]` or `[SOURCE:]` marker is still in the text, the post does
> not go out.** Filling one with an estimate, a round number, or a plausible-sounding figure is
> the worst thing anyone can do to this repo. The same rule already governs
> [`SHOW-HN-DRAFT.md`](SHOW-HN-DRAFT.md) and the sourcing table in
> [`log-runner-and-gate.md`](log-runner-and-gate.md), and it is not negotiable here because the
> entire subject of this post is whether a number can be trusted.
>
> **The title is not a promise about the answer.** "We measured it" is true whether the answer is
> yes, no, or underpowered. If the finding is that compression degrades verification, this exact
> title still ships, over the negative result. That is the test of whether the framing is honest:
> a piece that only works when the answer is favourable is an advertisement, and readers can tell.

---

A context-compression proxy can measure itself. It knows how many tokens went in against how many
came out. That number is real and it is cheap to produce.

The question underneath them is not. If the proxy drops something the model needed, the model
writes worse code, and the token savings are still exactly as large as they were. Compression
ratio and correctness are independent readouts. Publishing the first one tells you nothing about
the second.

So: does compressing an agent's context degrade the code it produces? We ran it as a paired A/B
for one week and scored it on gate outcomes.

## Why a proxy cannot answer this about itself

That is not a deficiency in a proxy. It is a description of where a proxy sits. To report whether
the output is still correct you need something that decides correctness, and a proxy has no such
thing. It sits upstream of the model and hands off. Whatever happens after the diff exists happens
outside its field of view.

The same holds for the agent. An agent's own test suite is a claim, not a check, because the
thing under test wrote it. Ask an agent whether its output survived compression and you get the
agent's opinion of the agent's work, which is the measurement problem restated.

What can answer it is an external gate: a check the implementing agent never sees, that has been
proven able to fail before it is trusted to pass. That is the only instrument in this stack whose
output means anything about correctness, and it happens to be what Heimdall is. This post exists
because we had the instrument sitting there and the question was obvious.

## The metric is gate outcomes

Four numbers, all of them already in the record Heimdall writes for every verified change
(`DATA.md` §2, the `pmr_v1` schema — a zero-content record of counts and coded tags, never the
change itself):

- **Oracle pass-rate** — `verify.verdict`. The fraction of tasks whose change passed the external
  oracle. This is the correctness readout.
- **Falsify survival** — `verify.falsify.survived` against `verify.falsify.mutants_run`. The count
  of injected mutants the gate failed to kill. Heimdall's contract is that this is zero:
  `bin/falsify <domain> --assert-score 1.0` reports PASS only when every mutant dies. A survivor
  is not a bad score, it is a broken gate.
- **Gate retry-count** — `verify.retry_count`. How many times the agent went back and tried again
  before the gate went green. This is the cost readout, and it is the one most likely to move.
- **Time-to-green** — `verify.time_to_green_s`. Wall-clock from first attempt to a passing gate.

Token savings are reported alongside as context, from `bin/heimdall-tokens`, which measures real
per-run consumption from the session transcript rather than estimating it (`TOKEN-METRIC.md`).
They are not the finding. A run that saves 60% of its tokens and fails the oracle is a worse run.

The reason to lead with gate outcomes is that they are the only figures in this comparison that
are *about the code*. Everything else is about the pipeline.

## The design, and whose it is

The holdout structure is not ours. We took it from Headroom's own methodology:
`[SOURCE: one paragraph describing Headroom's holdout methodology, written from their own
documentation — what they hold out, how they pair, what they report. Do not paraphrase from
memory. Open the page, read it, and describe it in their terms with a link.]`

We adopted it for two reasons. It is the right shape for this question, and using someone else's
published method to evaluate their own tool removes an argument about whether the evaluation was
rigged toward a conclusion. If the method is theirs and the result is unfavourable to them, the
method is not what produced the result.

The rest of the setup:

- **One task list, pinned by commit.** The same tasks in both arms. Real issues from real repos,
  fixed before the run starts, published with the post.
- **Arm A** — the agent, no proxy. **Arm B** — the same agent, same model, same gates, with the
  compression proxy in front of it. Exactly one thing differs.
- **Paired.** Every task appears in both arms, so each task is its own control. Arm order is
  counterbalanced across the task list to keep ordering effects from loading onto one arm.
- **One week.** Stated up front because it bounds what the result can mean.
- **Single operator, our own repos.** This is not a corpus aggregate over contributing teams, and
  it is not published as one. Heimdall's k-anonymity rule (`DATA.md` §7, k ≥ 5 distinct teams)
  binds published aggregates from the shared corpus; these figures come from our own machines and
  are labelled as one operator's runs, not as a population.

## Pre-registration — written before the run, published unchanged

The decision rule below was fixed before a single task executed. It is here so you can check that
the analysis we ran is the analysis we said we would run.

**Falsify survival is categorical, not statistical.** Any mutant surviving in arm B that dies in
arm A is a hard stop. There is no confidence interval on a gate that failed to kill something it
is contractually required to kill. One survivor and the finding is "compression broke the gate,"
the proxy comes out of the wrapper, and the negative receipt publishes that day.

**Oracle pass-rate is statistical.** Per-arm rates get a Wilson score 95% interval. The arm B
minus arm A difference gets a paired bootstrap, 10,000 resamples over tasks, reported as a 95%
interval. Degradation is declared when that interval lies entirely below zero.

**Retry-count and time-to-green are cost, not correctness.** Median paired difference with a
bootstrap interval, reported separately and never merged into a correctness claim. Time-to-green
in arm B carries the proxy's own latency, which is a real cost but not evidence about the code.

**Underpowered is a publishable outcome.** One week is one week. If the 95% interval on the
pass-rate difference is wider than ±10 percentage points, the answer is "this run could not tell,"
and that is what gets written. An underpowered null reported as "no degradation found" is the
most common way an honest A/B turns into an advertisement, and we are pre-committing against it.

**A favourable result is held to the same standard.** If gate outcomes improve in arm B, it gets
the same interval, the same label, and the same power check. A finding that only survives scrutiny
in one direction is not a finding.

## The labelling convention

Adopted from Headroom's own reporting discipline:
`[SOURCE: their stated convention for labelling counterfactual figures — the exact terms they use
for measured versus estimated, and how they attach intervals. Quote it and link it. If our reading
of it here is wrong, fix the table's column headers to match theirs, not ours.]`

Every counterfactual number in the results table carries two things: an interval, and a label
saying whether it was measured or estimated.

- **MEASURED** — both arms actually ran and both numbers come from recorded runs. In a paired
  design that is most cells, which is the point of paying for a paired design.
- **ESTIMATED** — anything projected, extrapolated, or derived from a table rather than observed.
  Dollar cost is the standard trap here: `heimdall-tokens` reports `total_cost_usd` only when the
  source data actually carries per-turn cost, and emits `null` plus an honesty note otherwise,
  because a cost derived from a published price table is a guess wearing a currency symbol
  (`TOKEN-METRIC.md` §"Honesty & fail-open contract"). Any dollar figure in this post is labelled
  ESTIMATED or it is absent.

An unlabelled number in the table below is a bug in the table.

## Results

`[RECEIPT: the headline sentence. One line stating the oracle pass-rate difference, arm B minus
arm A, with its 95% paired-bootstrap interval and its MEASURED label, and the verdict from the
pre-registered rule — degraded, not degraded, or underpowered. Source: the pmr_v1 verify.verdict
field across both arms of the run, aggregated by the analysis script published with the post.]`

| Metric | Arm A — no proxy | Arm B — with proxy | Difference (B − A), 95% CI | Label |
|---|---|---|---|---|
| Oracle pass-rate | `[RECEIPT: rate + Wilson 95% CI, from verify.verdict]` | `[RECEIPT: same]` | `[RECEIPT: paired bootstrap 95% CI]` | `[RECEIPT: MEASURED]` |
| Falsify survivors | `[RECEIPT: count, from verify.falsify.survived]` | `[RECEIPT: same]` | `[RECEIPT: categorical — any nonzero in B is a stop]` | `[RECEIPT: MEASURED]` |
| Gate retry-count (median) | `[RECEIPT: median, from verify.retry_count]` | `[RECEIPT: same]` | `[RECEIPT: median paired diff + bootstrap 95% CI]` | `[RECEIPT: MEASURED]` |
| Time-to-green (median s) | `[RECEIPT: median, from verify.time_to_green_s]` | `[RECEIPT: same]` | `[RECEIPT: median paired diff + bootstrap 95% CI]` | `[RECEIPT: MEASURED]` |
| Total tokens per task (median) | `[RECEIPT: from bin/heimdall-tokens session]` | `[RECEIPT: same]` | `[RECEIPT: median paired diff + bootstrap 95% CI]` | `[RECEIPT: MEASURED]` |
| Cost per task | `[RECEIPT: total_cost_usd if the source carries it, else "not reported — the transcript carries no cost field"]` | `[RECEIPT: same]` | `[RECEIPT: diff or "not reported"]` | `[RECEIPT: MEASURED or ESTIMATED — never blank]` |

**Task count:** `[RECEIPT: N paired tasks completed in both arms. A task that ran in one arm only
is excluded and the exclusion is counted here. Source: the pinned task list plus the run log.]`

**Power check:** `[RECEIPT: the half-width of the pass-rate difference interval, against the
pre-registered ±10pp threshold, and the resulting call — conclusive or underpowered.]`

## Reading it

Four shapes are possible and they mean different things. Naming them before the numbers land is
what stops a result from being narrated into whatever story is convenient.

**Pass-rate holds, retries hold.** Compression is free on this workload at this size. It says
nothing about a workload with different context pressure, and it does not generalise past the
task list.

**Pass-rate holds, retries rise.** The interesting one. Compression dropped something the agent
needed, the agent produced a worse first attempt, and the gate caught it. The system stayed
correct because the gate did its job, and the cost moved from tokens to iterations. Anyone
reporting only compression ratio would see a pure win here. The retry column is where the bill
actually landed.

**Pass-rate falls.** Compression cost correctness. Size and interval decide whether it matters,
and the pre-registered rule decides whether we call it.

**A mutant survives in arm B.** The worst case and the only categorical one. It means a defect
class the gate normally kills got past it under compression, which is a safety finding rather than
a performance one. It stops the run.

## If it degrades

Then that is the post. The proxy comes out of the wrapper, the number publishes with its interval
and its label, and the mechanism gets named if the run identifies one.

Writing this section before the run is deliberate. The pre-registration is public, the analysis
script ships with the post, and both arms' raw records are committed, so the difference between a
finding and a suppressed finding is checkable from outside. A negative result on someone else's
tool, produced with that tool's own methodology, published under a title that does not flinch, is
worth more to their users than another compression-ratio chart. It is also the only version of
this piece that would be worth reading if the answer had gone the other way.

We are not neutral about the tools and it would be silly to pretend otherwise. What we are
neutral about is the number, and the pre-registration is how you check that rather than take it
on trust.

## What this does not measure

- One week, one operator, one pinned task list. Not a population, not a benchmark, not a general
  claim about compression.
- Two flagship gate domains hold falsifiability 1.0 — exchange-lob at 6 of 6 mutants caught,
  emulator-gb at 3 of 3 (`evals/flagship/STATUS.md`). Two domains is two domains. Depth, not
  breadth.
- The regression corpus is 13 cases, 13 caught, 100% at v0.1 (`evals/corpus/CORPUS-STATUS.md`).
  That is small, and it is published as a time series with a dip log so you can watch it move
  instead of trusting the adjective.
- A gate catches defects its oracle can express. If compression degrades something no oracle in
  the suite models, this measurement is blind to it, and the pass-rate column would look fine.
  That limitation belongs in your reading of every number above.
- Heimdall's own generalisation figure is modest and published as-is: 0.50 median reuse across 8
  cold repos, full sorted per-repo table committed at `ae88a55`. The companion "8/10 working
  output" figure is **adjudicated**, not raw — the raw machine count in that run is 6/10, and the
  four adjudication layers are written down.
- Gates run 100% locally. Your code never leaves your machine. What does leave, and when, is
  enumerated field by field with a kill switch per item in
  [`DATA.md`](https://github.com/randomittin/heimdall/blob/main/DATA.md).

## The receipts, and where they live

The pinned task list, both arms' `pmr_v1` records, the analysis script, and the pre-registration
in the exact form it had before the run are committed at `[RECEIPT: commit sha of the results
drop]`. Re-run the analysis over the records and you should reproduce every cell in the table. If
you do not, that is a bug report we want.

*Nothing ships unproven.*

---

*This was taken to Headroom's community channel and their issue tracker at the same time it went
up here, before it went anywhere else. `[SOURCE: name the exact channel and link it, resolved from
their README — not reconstructed. Confirm their rules on posting links first.]` It is a finding
about their tool produced with their method, and they get to argue with it in their own room. The
canonical copy stays here; dev.to carries a crosspost with `canonical_url` set to
`https://runheimdall.dev/log-compression-and-gates.html`.*

---

## ⛔ DRAFT NOTE — resolve this block, then delete it before publishing

### A. External claims — none of these have been read against Headroom's own documentation

Everything Heimdall knows about Headroom in this draft came from a task brief. A brief is not a
source. Each row is confirmed at the cited page before publication, and a row that cannot be
confirmed is cut rather than softened. The identical rule blocked
[`log-runner-and-gate.md`](log-runner-and-gate.md) from shipping until its table was cleared.

| # | Claim as written | Must be confirmed at | Status |
|---|---|---|---|
| 1 | Headroom is a local-first context-compression proxy — the premise of the whole piece, including "sits upstream of the model and hands off" | `https://github.com/headroomlabs-ai/headroom` — README, opening self-description. Use their verb for what it does. | **UNVERIFIED — confirm** |
| 2 | The holdout methodology is theirs, and the paragraph describing it | Their documentation page for the methodology, linked from the README. Describe it in their terms with a direct link, do not reconstruct it. | **PLACEHOLDER — write from the doc** |
| 3 | The measured-vs-estimated labelling convention with intervals is their convention | Same source as #2, or wherever they state their reporting rules. If the convention differs from what is written here, the table's headers change to match theirs. | **PLACEHOLDER — write from the doc** |
| 4 | Their community channel is the right venue for the distribution line, and linking a post there is permitted | The community link **in their README**, plus that channel's own posting rules. Never reconstruct an invite URL. | **UNVERIFIED — resolve the real link** |
| 5 | Repo slug `headroomlabs-ai/headroom` | The repo page. Every link in this post depends on it. | **UNVERIFIED — confirm** |
| 6 | Any characterisation of what Headroom does *not* do | Nothing. There is none in this draft and none may be added. §"Why a proxy cannot answer this about itself" describes a structural property of proxies in general and must stay that way. | **RULE — keep it out** |

### B. Publication preconditions

- [ ] Zero `[RECEIPT:]` and zero `[SOURCE:]` markers remain.
- [ ] Table A above is fully cleared, every row confirmed at its cited page.
- [ ] The pre-registration section matches the version committed before the run, byte for byte. If
      it was edited after the run started, say so in the post or do not publish.
- [ ] Every counterfactual cell carries an interval and a MEASURED/ESTIMATED label. No blanks.
- [ ] The power check is filled and the pre-registered call was applied as written, including if
      the call is "underpowered."
- [ ] Task count, exclusions, and the reason for each exclusion are stated.
- [ ] No dollar figure appears unless the transcript carried a real cost field, or it is labelled
      ESTIMATED.
- [ ] Records, task list, and analysis script are committed and the sha is in the post.
- [ ] `bash test/truth-pass-claims.test.sh` still reports 9 passed, 0 failed.
- [ ] No bare privacy absolute anywhere in the text. Only the scoped S1–S6 set.
- [ ] "8/10 working output" appears only with the word **adjudicated** beside the raw 6/10.

### C. Heimdall-side claims — all in-repo, no external check needed

`bin/falsify --assert-score 1.0` semantics and the 6/6 + 3/3 flagship scores at falsifiability
1.0 → `evals/flagship/STATUS.md` ·
13 cases, 13 caught, 100% at v0.1, with the dip log → `evals/corpus/CORPUS-STATUS.md` ·
the `pmr_v1` record and its `verify` block (`verdict`, `retry_count`, `time_to_green_s`,
`falsify.mutants_run`, `falsify.survived`), zero-content by construction → `DATA.md` §2 ·
k-anonymity k ≥ 5 for published corpus aggregates → `DATA.md` §7 ·
per-run token measurement from the session transcript, and cost reported only when the source
carries it → `TOKEN-METRIC.md` §"Definition" and §"Honesty & fail-open contract" ·
S1 verbatim, "Gates run 100% locally. Your code never leaves your machine." → `README.md`
§"Your code stays yours", gated by `test/truth-pass-claims.test.sh` ·
0.50 median reuse across 8 cold repos; adjudicated 8/10 vs raw machine count 6/10 → commit
`ae88a55`, `docs/archive/docs/superpowers/specs/heimdall-S6-C3-findings.md` §THE FINDING.

### D. Static gate check on `test/truth-pass-claims.test.sh`

Verified by reading the test, not by running it (no shell available in this pass). Its swept
surfaces are `$REPO/README.md`, `$REPO/install.sh`, `$REPO/packages/runheimdall/README.md` when
present, and — as a sibling repo — the published `*.html|txt|js|css|xml` files under
`HEIMDALL_SITE_DIR` (`truth-pass-claims.test.sh:186-212`). `launch-docs/**` is in none of those
sets, and this file is markdown, which is not a swept extension on the site sweep either. Adding
these two drafts cannot change the result: 9 assertions total (Guarantee A = 1, Guarantee B = 6
scoped sentences, Guarantee C = 2), still 9 passed / 0 failed by construction. That holds only
while this content stays in `launch-docs/`. **Any line of it that later moves onto `README.md` or
the site is inside the swept surface and must be re-checked against the bare-absolute list before
it lands.**
