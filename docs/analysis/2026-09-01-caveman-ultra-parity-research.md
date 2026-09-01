# Caveman ultra parity research: why upstream's skill produces fewer output tokens, and what rule text closes it

Every claim below is tagged **MEASURED** (computed directly from `evals/caveman/snapshot.json` in
this pass, commands shown inline — all free, zero new spend), **READ-FROM-SOURCE** (read directly
in the named file), or **ANALYSIS** (my interpretation, explicitly not a re-verified causal claim).
No `heimdall-caveman-eval refresh` was run. Every number traces to
`evals/caveman/snapshot.json` (`generated_at: 2026-09-01T00:57:40Z`, `n_prompts: 30`,
`claude_cli_version: 2.1.252`, `model: sonnet`) or to a file path cited alongside it.

Scope note: `bin/heimdall-caveman` and `test/heimdall-caveman.test.sh` were being edited by a
sibling agent during this pass and were only read, never written. This document proposes text for
that sibling to apply; nothing outside this file was changed.

## 0. tl;dr verdict

The gap is **real, concentrated, and not explained by upstream's rule text saying anything hmd's
doesn't.** Read side by side, `evals/caveman/upstream_skill.md` and hmd's current `_rules_ultra`
(`bin/heimdall-caveman:487-522`) are near word-for-word identical outside the intensity ladder —
which was already tested as the explanation and already reverted (measurement doc §8, confirmed
below, not resurrected here). Neither text bans headers/tables, caps length, or shows a multi-step
worked example. **There is nothing left to copy.** Closing the gap, and going beyond it, requires
genuinely new rule content, not better alignment with upstream's wording.

The deficit is not spread evenly across all 30 prompts. **One prompt (i=26, "steps to safely roll
back a bad database migration in production") accounts for 38% of the entire net 30-prompt token
deficit by itself** (+621 of +1630 net tokens), and it is also the single prompt with the largest
header/bullet-count divergence (7 headers / 22 bullets for hmd_ultra vs 0 headers / 9 bullets for
upstream, covering the *same* 7 rollback steps). The top 5 gap prompts account for 84% of the net
deficit. hmd_ultra actually uses **fewer** tokens than upstream on 11 of 30 prompts (37%) — the
problem is concentrated in a specific prompt *shape* (open-ended "how/why does X work" and
"steps to do X" questions), not a uniform per-response tax.

The concrete, quoted failure mode: on multi-cause/multi-step questions, hmd_ultra breaks into
markdown `##` headers per item and adds an unrequested worked example under some items, while
upstream and hmd's own simpler-question answers stay in flat caveman-fragment style. This is a
measured, reproducible pattern (§2-§4 below), not a guess.

## 1. Headline numbers, recomputed directly from the snapshot (sanity check)

```
jq '[.arms.hmd_ultra[].output_tokens] | add' evals/caveman/snapshot.json      # 13573
jq '[.arms.upstream_skill[].output_tokens] | add' evals/caveman/snapshot.json # 11943
```

| comparison | median | mean | min | max | stdev |
|---|---:|---:|---:|---:|---:|
| hmd_ultra vs upstream_skill | −11.1% | −20.7% | −114.3% | +54.5% | 40.3% |
| hmd_full vs upstream_skill | −9.9% | −23.4% | −190.0% | +48.8% | 54.5% |
| hmd_lite vs upstream_skill | −25.1% | −48.4% | −320.0% | +73.5% | 74.5% |
| upstream_skill vs `__terse__` | +18.4% | +20.4% | — | — | — |
| hmd_ultra vs `__terse__` | +8.6% | +9.6% | — | — | — |

(positive = fewer tokens = better; recomputed from `output_tokens` — the real
`usage.output_tokens` field the `claude` CLI itself reported per call, not a tiktoken estimate)

Total `output_tokens` summed across all 30 prompts, all 6 arms:

| `__baseline__` | `__terse__` | `upstream_skill` | `hmd_full` | `hmd_ultra` | `hmd_lite` |
|---:|---:|---:|---:|---:|---:|
| 14506 | 14929 | **11943** | 13623 | 13573 | 15354 |

This reproduces the orchestrator's briefed n=30 figures (hmd_ultra −11%, full −10%, lite −25%
median vs upstream; upstream +18% and hmd_ultra +9% median vs terse) to within rounding —
independent confirmation the briefing numbers are real, not stale n=10 noise.

## 2. Where the deficit actually lives: it's one outlier, not a uniform tax

Per-prompt gap = `hmd_ultra.output_tokens − upstream_skill.output_tokens` (positive = hmd used
more). Full 30-row table, worst-for-hmd first:

| i | gap | hmd_ultra | upstream | pct | prompt |
|--:|--:|--:|--:|--:|---|
| 26 | **+621** | 1188 | 567 | −109.5% | steps to safely roll back a bad DB migration in production |
| 22 | +199 | 809 | 610 | −32.6% | How does garbage collection work in Java/Go? |
| 6 | +187 | 634 | 447 | −41.8% | Why am I getting CORS errors? |
| 16 | +184 | 807 | 623 | −29.5% | Why does my API return 401 with a valid token? |
| 11 | +173 | 393 | 220 | −78.6% | What is idempotency, why does it matter for REST? |
| 24 | +162 | 438 | 276 | −58.7% | How does DNS resolution work? |
| 18 | +151 | 319 | 168 | −89.9% | "port already in use" on dev server |
| 20 | +106 | 539 | 433 | −24.5% | Explain JWT authentication |
| 12 | +98 | 214 | 116 | −84.5% | authentication vs authorization |
| 21 | +82 | 420 | 338 | −24.3% | Explain the CAP theorem |
| 19 | +80 | 150 | 70 | −114.3% | why does useEffect run twice in dev |
| 10 | +46 | 330 | 284 | −16.2% | process vs thread |
| 1 | +38 | 234 | 196 | −19.4% | database connection pooling |
| 23 | +29 | 422 | 393 | −7.4% | race condition |
| 5 | +21 | 223 | 202 | −10.4% | hash table collisions |
| 29 | +20 | 649 | 629 | −3.2% | rotate a leaked API key |
| 2 | +17 | 160 | 143 | −11.9% | TCP vs UDP |
| 13 | +11 | 56 | 45 | −24.4% | HTTP 429 |
| 7 | +3 | 171 | 168 | −1.8% | debounce a search input |
| 25 | −1 | 727 | 728 | +0.1% | CI pipeline for Node.js |
| 8 | −3 | 238 | 241 | +1.2% | git rebase vs merge |
| 9 | −11 | 136 | 147 | +7.5% | queue vs topic |
| 27 | −24 | 961 | 985 | +2.4% | blue-green deployment |
| 15 | −35 | 518 | 553 | +6.3% | Docker container exits immediately |
| 4 | −48 | 244 | 292 | +16.4% | SQL EXPLAIN |
| 28 | −50 | 1184 | 1234 | +4.1% | debugging a slow prod API endpoint |
| 14 | −67 | 109 | 176 | +38.1% | `==` vs `===` |
| 17 | −88 | 429 | 517 | +17.0% | Python script OOM on large CSV |
| 3 | −132 | 755 | 887 | +14.9% | memory leak in Node.js |
| 0 | −139 | 116 | 255 | +54.5% | why does my React component re-render |

Net over 30 prompts: +1630 tokens (13573−11943). **19/30 prompts hmd_ultra loses, 11/30 it wins.**
i=26 alone is 38.1% of the net deficit; the top 5 rows are 83.7% of it
(621+199+187+184+173 = 1364 of 1630).

Stdev on the ultra-vs-upstream distribution is 40.3% — the median (−11.1%) undersells how lopsided
this is. A fix aimed at the tail should move the **mean** and **stdev** far more than the median.

## 3. Structural metrics, computed from the response text itself

Methodology: regex over each response's raw text. `headers` = lines matching `^#{1,6}\s`;
`code_blocks` = paired `` ``` `` fence count; `bullets` = lines starting with `-`/`*`/`N.`;
`avg_sentence_len` = words per `.`/`!`/`?`-delimited unit after stripping code fences and inline
code (approximate — caveman fragment style under-uses terminal punctuation, so this number is
noisier than the others; reported anyway because the direction is consistent and it's cheap to
falsify).

| metric (mean per response) | hmd_ultra, all 30 | upstream, all 30 | hmd_ultra, top-10 gap | upstream, top-10 gap |
|---|--:|--:|--:|--:|
| words | 152.87 | 134.57 | 189.00 | 133.90 |
| lines | 13.43 | 12.70 | 14.70 | 10.80 |
| **headers** | **0.57** | **0.13** | **0.70** | **0.00** |
| code_blocks | 0.33 | 0.47 | 0.30 | 0.20 |
| bullets | 7.07 | 6.03 | 9.40 | 6.40 |
| avg_sentence_len (words) | 14.25 | 11.12 | 14.30 | 12.54 |

Header use is not spread across the corpus — it is concentrated in exactly 3 of 30 hmd_ultra
responses (i=26: 7, i=27: 6, i=28: 4; total 17 headers, 3 prompts) vs 1 of 30 for upstream (i=28: 4
headers, tied with hmd there — not a differentiator on that specific prompt). All three are "walk
me through / steps to" procedural prompts. hmd_ultra is **4.4x** more likely to emit a header on
average than upstream, entirely because of this 3-prompt cluster.

`code_blocks` runs the other way (upstream uses slightly *more* code blocks per response, 0.47 vs
0.33) — ruling out "hmd overuses code fences" as a contributor.

## 4. Reading the actual text: three concrete, quoted failure categories

### 4a. Headers + full-sentence bullets replace flat fragment style (dominant category)

i=26, `hmd_ultra` (1188 tokens) vs `upstream_skill` (567 tokens) — same question, same 7 rollback
steps, in both:

> hmd_ultra opens: *"Rolling back a bad DB migration in prod is risky — sequence matters and
> mistakes compound. Writing this out clearly rather than in fragments."* — then 7 `## N. Title`
> sections, each with 3-4 full-sentence bullets (22 bullets total). Example bullet:
> *"Put app in maintenance mode or fail over to read-only if writes are corrupting data."*
>
> upstream opens directly: *"Rollback bad prod migration — steps:"* — then a flat `1.`-`7.`
> numbered list, each item one dense fragment-style line with a bold lead-in (9 bullets total).
> Example item: *"**Stop bleeding.** Freeze deploys/writes if migration mid-run or corrupting
> data. Alert team."*

Both cover the identical 7 steps (stop bleeding / assess damage / run or skip down-migration /
restore from backup / app-compat check / verify / postmortem) — this is not upstream omitting
content. hmd's version just re-renders each step as a header block with prose-register bullets
instead of one compressed fragment-style line. The second sentence of hmd's opening
(*"Writing this out clearly rather than in fragments"*) is the model explicitly narrating a
decision to leave compression mode — a direct contradiction of the injected
`## Persistence: ACTIVE EVERY RESPONSE... Still active if unsure` rule. This exact phrase appears
on only this one response (checked: first line of all 30 hmd_ultra responses, `evals/caveman/
snapshot.json`) — rare, but a clean, quotable, unambiguous violation.

### 4b. Unrequested nested worked examples inside bullets

i=11, "What is idempotency, and why does it matter for REST APIs?" (hmd 393 vs upstream 220
tokens, −78.6%). hmd's "Method semantics" bullet expands into three sub-bullets of invented
endpoint examples never asked for:

> *"PUT /users/5 {name: "Bob"} → run 1x or 5x, user 5 end state same."*
> *"DELETE /users/5 → 1st call delete, 2nd+ call no-op..."*
> *"POST /orders → each call creates new order → NOT idempotent."*

upstream states the same rule in one line, no invented endpoints: *"GET/PUT/DELETE = idempotent by
spec. POST = not (each call creates new thing)."* hmd also closes with a generic recap
(*"Break idempotency → retries cause data corruption, dup records, inconsistent state."*) that
restates the opening rather than adding new information; upstream's closing line instead adds a
new, non-redundant fact (the `Idempotency-Key` header pattern).

i=6, CORS errors (hmd 634 vs upstream 447, −41.8%) shows the same pattern in miniature: hmd adds
an unrequested closing sub-taxonomy mapping three exact browser console error strings to causes
(3 extra bullets) where upstream's closing is one line: *"Check exact error text in console — tell
me if want pinpoint cause."*

The existing scope-discipline sentence (`bin/heimdall-caveman:501`, pinned in
`test/heimdall-caveman.test.sh:147`) already says *"skip unrequested examples/names/failure-mode
asides/code samples"* — general-purpose "examples" is already covered by that phrase, in principle.
It measurably isn't stopping this specific sub-case (invented endpoint illustrations, invented
error-string taxonomies nested under a bullet). An abstract rule not firing on a concrete instance
is exactly the case a concrete contrastive example is supposed to fix — of the type the file
already uses successfully for the pleasantries rule (`Not: "Sure!..."` / `Yes: "Bug in..."`), just
not yet applied to this failure mode.

### 4c. What this is *not*: not an abbreviation-vocabulary gap

Checked directly, in case hmd's word choices were simply less compressed than upstream's:

| token | hmd_ultra count (30 responses) | upstream count |
|---|--:|--:|
| `w/` (with) | 9 | 7 |
| `diff` (different) | 7 | 4 |
| `different` (spelled out) | 4 | 3 |
| `config` | 8 | 6 |
| `b/c` (because) | 0 | 0 |

hmd_ultra uses every one of these abbreviations at least as often as upstream. **Ruled out**:
hmd's per-word compression is not behind upstream's; the gap is structural (§4a/§4b), not lexical.

## 5. Conceptual diff: what does upstream instruct that hmd's ultra doesn't?

Full texts read side by side: `evals/caveman/upstream_skill.md` (66 lines, read in full) and the
current `_rules_ultra` output (`bin/heimdall-caveman rules ultra`, source at
`bin/heimdall-caveman:487-522`, read in full). Section by section:

| upstream_skill.md | hmd `_rules_ultra` | delta |
|---|---|---|
| Opening terseness line | Opening terseness line | near-identical wording |
| `## Persistence` | `## Persistence` | identical wording |
| `## Rules` (drop articles/filler/pleasantries/hedging, fragments OK, short synonyms, Not/Yes pair) | `## Rules` (same, plus abbreviate/arrows/conjunctions and the scope-discipline sentence) | hmd's is a **superset** — it already has content upstream doesn't (the ladder-adjacent abbreviation rule and the scope-discipline sentence) |
| `## Intensity` — all 6 levels in one table + 2 worked examples shown at **all 6 levels simultaneously** | `## This level (ultra)` — 2 worked examples, **this level only** | the one real structural difference; **already tested as the cause (measurement doc §8) and already reverted** — not proposed again here |
| `## Auto-Clarity` | `## Auto-Clarity` | identical wording |
| `## Boundaries` | `## Boundaries` | identical wording |

Explicitly checking for the four things asked for: **none of them are present in upstream's
text.**

- Output-shape rule (no headers/no tables/no bullets/prose-only): **absent from upstream_skill.md.**
  Grepped the full 66 lines: no mention of headers, tables, or bullet restrictions anywhere.
- A length cap (word/line/sentence limit): **absent.** No numeric limit stated anywhere in the file.
- An explicit "one sentence per point" rule: **absent.**
- A worked example demonstrating a multi-step/multi-cause compressed answer: **absent.** Both of
  upstream's own examples (`"Why React component re-render?"`, `"Explain database connection
  pooling."`) are single-sentence answers to single-cause questions — the same two examples hmd
  already has, and neither text shows what a compressed *multi-item* answer should look like.

**This is the honest null result the task asked for if true: it is true.** hmd cannot close this
gap by importing an upstream instruction, because there is no upstream instruction to import
outside the already-reverted ladder. Parity-via-copying is not on the table. Closing the gap, and
the owner's further ask to exceed it, requires rule content that exists in **neither** text today.

## 6. A secondary, mechanical asymmetry in how the two arms are actually measured

`bin/heimdall-caveman-eval:228-236` (`resolve_upstream_skill_prompt`) builds the `upstream_skill`
arm's system prompt as `TERSE_PREFIX + "\n\n" + <raw upstream_skill.md>`, i.e.
`"Answer concisely.\n\n" + skill text` — reproducing upstream's own eval methodology exactly, per
that function's docstring. `bin/heimdall-caveman-eval:209-219` (`resolve_hmd_level_prompt`) builds
each `hmd_<level>` arm as the *unmodified* `heimdall-caveman rules <level>` output — no
`TERSE_PREFIX` is prepended. So upstream's measured arm gets **two** stacked terseness
instructions ("Answer concisely." plus the skill's own "Respond terse like smart caveman...");
hmd's measured arm gets **one** (only its own "Respond max terse...").

This is not a methodology bug to fix in the harness — both arms are measured "the way they're
actually deployed" (upstream's own eval convention for the skill arm; hmd's own SessionStart
injection for its arm), and the harness is out of this task's scope regardless. It is, however, a
mechanical, cheap, content-only lever: hmd's rules text can bake in an equivalent (or stronger)
terseness anchor itself, rather than relying on an external wrapper it will never get in real
deployment either. §7's proposal folds this in as one added clause rather than literally
duplicating the generic "Answer concisely." (see §9.6 for why literal duplication was rejected).

## 7. One caveat on the metric itself: shorter isn't automatically better

i=0 ("why does my React component re-render") is hmd_ultra's *best* win (116 vs 255 tokens, +54.5%
better than upstream) — but reading both texts, upstream's answer lists 4 distinct causes
(no memoization, new inline object/fn props, context changes, state lifted too high) while hmd's
answer effectively covers 1-2 of those before jumping to fixes. hmd is shorter here partly because
it answered a narrower slice of the question, not because it compressed the same content harder.
Raw `output_tokens` never verifies semantic completeness (the same caveat upstream's own
`evals/README.md` states about its own harness — see
`docs/analysis/2026-08-30-caveman-upstream-practices.md` §3.1: *"a skill that replies `k` to
everything would score −99% and win"*). This is why §4's proposal is scoped only to the three cases
(i=26, i=11, i=6) verified by manual side-by-side reading to be same-content-more-formatting, not a
blanket "make every answer shorter" instinct that would also reward incompleteness like i=0's.

## 8. Proposed `_rules_ultra` replacement (paste-ready)

Preserves both substrings pinned in `test/heimdall-caveman.test.sh` verbatim: `"Abbreviate"`
(line 128) and `"skip unrequested examples/names/failure-mode asides/code samples"` (line 147) —
confirmed by grepping every `ultra_out` assertion in that file (lines 108-156, 273, 382-386,
457-461); none of the others pin exact-match text, only non-emptiness and difference-from-other-
levels, both unaffected by this change. New content is additive (appended clauses, one new
worked example, one new contrastive pair) — nothing existing is deleted or reworded, to minimize
collision with whatever the sibling agent is doing to the test file concurrently.

```
HMD OUTPUT COMPRESSION — level: ultra (rules injected below; not a compliance guarantee — audit via `hmd caveman-audit`)

Respond max terse. All technical substance stay. Only fluff die. Shortest correct answer wins: if cutting a fact doesn't change the answer, cut it.

## Persistence

ACTIVE EVERY RESPONSE. No revert after many turns. No filler drift. Still active if unsure. Off only: "stop caveman" / "normal mode".

Default level: full. Change level: `heimdall-caveman set lite|full|ultra`.

## Rules

Drop: articles (a/an/the), filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging, conjunctions. Fragments OK. Abbreviate (DB/auth/config/req/res/fn/impl). Arrows for causality (X → Y). One word when one word is enough. Technical terms exact. Code blocks unchanged. Errors quoted exact. Answer only what's asked: skip unrequested examples/names/failure-mode asides/code samples. No headers (`#`/`##`) in answers — a flat list or plain fragments only, never a sectioned doc. Multi-cause or multi-step answers: one line per item, no per-item header, no per-item example — the user asked about the whole thing, not each part separately. Never narrate your own formatting ("writing this clearly", "let me structure this" — banned, just answer). Closing line adds a new fact or is dropped — never restate the opening in different words.

Pattern: [thing] [action] [reason]. [next step].

Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
Yes: "Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:"

Not (multi-cause, headered + example per cause — measured: ~2x the tokens of the line below, same content): a "## Cause 1" section with its own bullet list and code sample, repeated per cause.
Yes (multi-cause, flat): "Causes: server missing CORS header, preflight OPTIONS unhandled, credentials+wildcard origin mismatch. Check response headers first."

## This level (ultra)

Abbreviate (DB/auth/config/req/res/fn/impl), strip conjunctions, arrows for causality (X → Y), one word when one word is enough.

Example — "Why React component re-render?"
ultra: "Inline obj prop → new ref → re-render. `useMemo`."

Example — "Explain database connection pooling."
ultra: "Pool = reuse DB conn. Skip handshake → fast under load."

Example — "Why is my build failing in CI but passing locally?"
ultra: "Causes: env var missing in CI, Node/lang version mismatch, case-sensitive path (CI=Linux, local=Mac/Win), stale lockfile, timezone/locale diff. Diff CI log vs local run first."

## Auto-Clarity

Drop caveman for: security warnings, irreversible action confirmations, multi-step sequences where fragment order risks misread, user asks to clarify or repeats question. Resume caveman after clear part done.

## Boundaries

Code/commits/PRs: write normal. "stop caveman" or "normal mode": revert. Level persists until changed or session end.
```

What changed vs current (`bin/heimdall-caveman:487-522`), line by line:

1. Opening paragraph: appended *"Shortest correct answer wins: if cutting a fact doesn't change
   the answer, cut it."* — an explicit objective-function sentence neither text currently states
   (§5, §6). Folds in the spirit of upstream's double-stacked terse instruction as hmd's own
   content rather than literally duplicating "Answer concisely." (§9.6).
2. `## Rules` paragraph: appended four clauses after the existing (preserved, pinned) scope-
   discipline sentence — headers ban, per-item-example/per-item-header ban for enumerable answers,
   self-referential-narration ban, redundant-closing-recap ban. Each maps directly to a quoted,
   measured instance in §4.
3. New contrastive pair (`Not (multi-cause...)` / `Yes (multi-cause...)`) — same pedagogical
   pattern the file already uses for the pleasantries rule, applied to the new failure mode from
   §4b, using the actual CORS causes from i=6 as the "Yes" line.
4. `## This level (ultra)`: added a third worked example (CI failing in CI-not-locally) —
   deliberately a multi-cause question rendered as ONE flat compressed line, the exact target
   shape for the §4a/§2 failure cluster. Not a new prompt from the graded corpus (avoids literally
   teaching to the eval's own 30 prompts) and not a cross-level ladder (stays ultra-only, does not
   resurrect the reverted hypothesis).

## 9. Falsifiable predictions for the next measurement

Ceiling estimate (if the model followed every new clause perfectly on exactly the flagged
prompts): fixing i=26 alone (its −109.5% pushed to roughly 0%) moves the ultra-vs-upstream **mean**
from −20.7% to about −17.0% (a +109.5-point swing on that one row, divided across n=30). Fixing the
next four worst rows (i=22, i=6, i=16, i=11) similarly moves the mean to roughly −13%. This is a
best case, not an expectation — the repo's own prior finding (§6 of `docs/analysis/2026-08-30-
caveman-eval-measurement.md`; the scope-discipline sentence's own p=0.86 at n=30) is that textual
rule additions here have historically produced weak, hard-to-detect compliance, consistent with
`bin/heimdall-caveman`'s own documented "HONEST LIMIT" (a hook can inject text, never verify or
enforce that the model followed it). Predict the realistic outcome lands well short of the ceiling.

What should move, in order of confidence:

1. **Headers-per-response for hmd_ultra** (currently mean 0.57, concentrated in 3/30 prompts) —
   **highest-confidence prediction.** This is a binary, mechanically simple instruction (did the
   response contain `#`/`##` or not), not a graded judgment call like "how much detail is too
   much." Predict it drops toward upstream's 0.13, specifically on i=26/i=27/i=28-shaped prompts.
   If a re-measurement shows headers unchanged on those three, the header-ban clause did not work
   and should be the first thing revisited.
2. **The single worst-case per-prompt gap** (currently +621 on i=26) — predict it shrinks by at
   least 40-50%, driven by the header removal alone even before accounting for tighter bullets,
   since i=26's header/bullet divergence (7 headers/22 bullets vs 0/9) was the largest measured in
   the whole corpus.
3. **Mean and stdev move more than median** — predict mean improves from −20.7% toward roughly
   −13% to −17% (per the ceiling calc above, discounted for partial compliance) and stdev drops
   from 40.3% toward the 25-35% range, because the fix targets the right tail specifically. Predict
   the **median** moves much less (−11.1% toward maybe −8% to −11%, plausibly within noise) since
   the median-case prompt was never where the problem lived.
4. **Unrequested nested worked-examples** (the idempotency/CORS pattern, §4b) — predict this drops
   close to zero on re-measurement of the same two prompts, now that it has an explicit contrastive
   example; lower confidence than #1 because it requires a subtler judgment call (what counts as
   "unrequested") rather than a binary marker.
5. **Self-referential-narration and redundant-closing-recap clauses** — predict close to **no
   measurable effect on aggregate numbers** at n=30. Base rate in this snapshot was 1/30 (i=26
   only) for narration and roughly 1/30 (i=11) for clear redundant recap. Included because they are
   cheap, directionally correct, and target real quoted violations — not because there is
   quantitative evidence they move totals. A re-measurement showing zero change here would **not**
   falsify anything; a re-measurement showing headers (#1) unchanged **would**.
6. **What should NOT change** (an honest prediction names a null): code-block usage (already
   slightly lower for hmd than upstream, §3 — not touched by this proposal), the abbreviation-
   vocabulary counts in §4c (already at parity, not touched), and closing-question-offer behavior
   (already-killed hypothesis, §0/task briefing — not touched by this proposal; if it moves, that's
   a confound, not this change working).

## 10. Considered and rejected

1. **A hard numeric length/word cap.** Rejected: the measured waste is structural (headers,
   per-item examples), not "every answer is uniformly too long" — upstream's own i=26 answer is
   567 tokens of genuinely necessary content (7 real steps). A cap tuned to the ~150-word median
   response would truncate legitimately complex answers like i=26's, i=28's (1234 tokens on
   upstream's own side), violating the completeness-over-terseness principle rather than serving
   it. Capping *structure* (headers, per-item examples) targets the actual measured waste without
   this risk.
2. **Re-adding the multi-level intensity ladder.** Rejected outright — already implemented,
   measured, and reverted (measurement doc §8: p>0.3, one level regressed 24pts). Confirmed on
   re-read of upstream_skill.md that this is the one real structural difference (§5) — not
   resurrecting a tested-and-killed hypothesis just because it's the most visible difference.
3. **Touching closing "want more detail?" behavior.** Rejected — already disproven at n=30 per the
   task briefing; my own last-line scan (§0, both arms end with punchy takeaway or offer lines at
   similar rates) reconfirms it qualitatively. No clause in §8 touches closing offers specifically
   (only redundant *recap*, a different pattern, §4b).
4. **Expanding the abbreviation vocabulary** (more symbols, more shortened words). Deprioritized —
   §4c measured hmd_ultra already uses `w/`/`diff`/`config` at least as often as upstream. Rule
   text real estate spent here has low expected payoff; not included in §8.
5. **Editing hmd_full and hmd_lite in the same pass.** Out of scope for this task (framed
   specifically around ultra) even though full's header/nested-example behavior likely shows the
   same pattern and would be worth a follow-up measurement. Not touched here to avoid scope creep
   into files/behavior not asked for, and because full/lite's own token profile (§1: full already
   beats ultra head-to-head, −9.9% vs −11.1%) suggests the failure shape may differ enough to need
   its own read rather than a copy-paste of this fix.
6. **Literally prepending "Answer concisely."** to mirror upstream's double-stacked terse
   instruction (§6). Rejected in favor of the sharper, non-generic "Shortest correct answer wins..."
   sentence in §8 item 1 — duplicating a vague instruction already substantively covered by
   "Respond max terse" would itself be exactly the kind of filler this whole change exists to cut.
7. **Rewriting or deleting the existing scope-discipline sentence.** Rejected — it is
   substring-pinned (`test/heimdall-caveman.test.sh:147`) and, per §4b, is directionally right, just
   not specific enough for the nested-example sub-case. Preserved verbatim; new clauses appended
   instead of a rewrite, so the sibling agent's pinned test isn't broken out from under them.
8. **Optimizing purely for raw token count.** Rejected as a general philosophy per §7 — i=0 shows
   a token "win" that actually came from answering a narrower slice of the question, not tighter
   phrasing of equivalent content. §8's proposal is scoped only to the three manually-verified
   same-content-more-formatting cases (i=26, i=11, i=6), not a blanket "always shorter" instinct.

## 11. Reproduction

```
# Everything in this document, free, deterministic, no API key, no network call:
jq '[.arms.hmd_ultra[].output_tokens] | add' evals/caveman/snapshot.json
jq '[.arms.upstream_skill[].output_tokens] | add' evals/caveman/snapshot.json
bin/heimdall-caveman-eval report
bin/heimdall-caveman-eval report --json
bin/heimdall-caveman rules ultra   # current text, read-only

# Re-running the real measurement after the sibling agent applies §8 costs real quota
# (~$3.75-7.50 going by the two prior runs in the measurement doc) -- not run in this pass:
bin/heimdall-caveman-eval refresh --confirm-spend --model sonnet
```
