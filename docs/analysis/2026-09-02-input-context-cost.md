# Input Context Cost — 2026-09-02

Scope: this session (main transcript, 6,507 API calls), per orchestrator instruction.
Given top-line figures (tokens) are taken as authoritative and NOT re-derived, per
explicit instruction. What follows sanity-checks the method, reframes it in dollars,
and ranks levers by measured (not guessed) expected saving.

Labels used throughout: **MEAS** = directly measured this session or in a cited prior
doc. **DERIVED** = arithmetic on MEAS numbers (shown in full). **INF** = inference /
unmeasured, flagged as such, never presented as a number.

## 0. Given figures (orchestrator, not re-derived)

```
input (fresh):        848,317
cache READ:       2,504,889,304
cache CREATE:       131,272,661
output:               5,911,035
TOTAL:            2,642,921,317
```

tool_result blocks in-session: 2,765 blocks, 1,607,816 chars (~402K tokens @ 4
chars/token), mean 581 chars, one block over 20K chars.

---

## 1. Does the 94.8% framing survive a cost-weighted recheck?

**Short answer: no, not as stated — cache-read's DOLLAR share is ~56%, not 94.8%. But
the orchestrator's underlying claim ("context handling, not output, dominates cost")
survives and strengthens, because cache-CREATE turns out to carry a second, larger-than-
expected dollar share that the token-share view hides entirely.**

### 1.1 Is cache-read genuinely billed, and at what rate?

Yes. Per the `claude-api` skill's `shared/prompt-caching.md` (this repo's canonical
pricing reference): cache reads are billed at **0.1× the model's input-token price**
(a 90% discount vs. fresh input), not free. Cache writes are billed at a **premium**:
1.25× input price for a 5-minute TTL breakpoint, 2.0× for a 1-hour TTL breakpoint.
Output is billed at the model's separate (always higher) output rate.

So the four usage fields do NOT share one price — treating "2.5B cache-read tokens" and
"5.9M output tokens" as comparable units (as a raw token-share table implicitly does)
misprices the read column by 10× and the create column by 1.25–2×. A token-count-only
framing overstates the cache-read column's true cost weight and understates create's.

### 1.2 The fact that makes cost-SHARE model-mix-independent

Checked every currently-priced Claude model in the `claude-api` skill's canonical
table:

| Model | Input | Output | Ratio |
|---|---|---|---|
| Opus 5 / 4.8 / 4.7 | $5/MTok | $25/MTok | 5.0× |
| Sonnet 5 | $2/MTok | $10/MTok | 5.0× |
| Sonnet 4.6 | $3/MTok | $15/MTok | 5.0× |
| Haiku 4.5 | $1/MTok | $5/MTok | 5.0× |
| Fable 5 | $10/MTok | $50/MTok | 5.0× |

Every current model prices output at **exactly 5× its own input price**, and the cache
multipliers (0.1× read, 1.25×/2.0× create) are stated as multipliers of "the model's own
input price," not fixed dollar amounts. That means the four usage fields' **cost SHARE**
(not absolute dollar total) is invariant to which model(s) actually served the session —
it depends only on the token counts and the 0.1/1.25/2.0/5.0 multiplier structure, which
is uniform across the whole current model lineup. This is why §1.3 can state exact cost
shares without knowing the session's real per-request model mix, while §1.3's absolute
dollar total still needs a mix assumption (bounded with a range).

**Correction to a source doc found while verifying this table**: the RTK assessment doc
(`docs/analysis/rtk-incorporation-assessment-2026-08-22.md:143`) states "Sonnet 5 $3/$15"
— that is Sonnet 4.6's rate, not Sonnet 5's ($2/$10 per the same skill's current table).
This doc uses the `claude-api` skill's table as authoritative; the RTK doc's dollar
figures that depend on this rate should be treated as using a ~1.5× stale/conflated
Sonnet price. It does not appear to change that doc's own headline conclusions (see §3),
but is flagged here for the record.

### 1.3 Dollar arithmetic

Apply the multipliers to the given token counts, expressed as "equivalent fresh-input
tokens" (each field × its own multiplier relative to input price; output uses the 5×
ratio directly), at the 5-minute-TTL assumption (dominant case — most cache writes in an
active session are turn-boundary, not long-idle):

| Field | Tokens (given) | Multiplier | Input-equivalent tokens | Cost share |
|---|---|---|---|---|
| fresh input | 848,317 | 1.0× | 848,317 | **0.19%** |
| cache READ | 2,504,889,304 | 0.1× | 250,488,930 | **56.29%** |
| cache CREATE (5m) | 131,272,661 | 1.25× | 164,090,826 | **36.88%** |
| output | 5,911,035 | 5.0× | 29,555,175 | **6.64%** |
| **TOTAL** | 2,642,921,317 | — | **444,983,249** | **100%** |

(Sanity check on the precise, pre-rounding values: 848,317 + 250,488,930.4 +
164,090,826.25 + 29,555,175 = 444,983,248.65 → 444,983,249. The whole-number cells
shown in the table above are each rounded independently, so summing THOSE rounded
integers gives 444,983,248, one less than the rounded total — a display-rounding
artifact, not an arithmetic error.)

**Cache-read's DOLLAR share is 56.29%, not 94.8%.** The 94.8% figure is a real, correctly
computed TOKEN share — it is just not a cost share, because it ignores the 0.1×/1.25×/
5.0× price structure entirely. Read alone is a majority of cost, not 94.8% of it.

**But read+create together are ~93.17% of cost** — barely below the original 94.8% token
figure, for an unrelated reason: create is only 4.97% of tokens but 36.88% of dollars
(a 7.4× amplification from its 1.25× write premium plus its comparatively small token
denominator). The two effects (read's cost getting cut 10×, create's cost getting
inflated 7.4×) land the COMBINED context-handling share (read+create) within 1.6 points
of the original claim, but redistribute which piece of context-handling actually drives
that number. This is the correction that matters: **cache CREATE, not cache READ, is
the fastest-growing lever to look at next** (see §5, and the open question in §2.2).

**TTL sensitivity** — re-run at 1-hour-TTL multiplier (2.0× instead of 1.25× for create;
plausible if the session used long-idle breakpoints anywhere):

| Field | Multiplier | Cost share (1h TTL) |
|---|---|---|
| fresh input | 1.0× | 0.156% |
| cache READ | 0.1× | 46.10% |
| cache CREATE (1h) | 2.0× | 48.31% |
| output | 5.0× | 5.44% |

Combined read+create: 94.41% (1h) vs. 93.17% (5m). **The combined figure is stable
(93.2–94.4%) regardless of which TTL was actually used** — this is the one number from
the original framing that survives essentially intact. The split between the two is not
stable (56/37 at 5m vs. 46/48 at 1h) and matters for lever-targeting (§5).

**Absolute dollar total** — the cost SHARE above is model-mix-independent (§1.2), but an
absolute dollar figure needs a mix assumption:

| Assumption | $/MTok basis | Total (5m TTL) |
|---|---|---|
| Pure Sonnet 5 ($2/$10) | input $2, output $10 | **$889.97** |
| Pure Opus-tier ($5/$25) | input $5, output $25 | **$2,224.92** |
| Blended (RTK doc's own machine-mix: opus-5 71.2%, opus-4-8 17.7%, sonnet-5 8.6%, `rtk-incorporation-assessment-2026-08-22.md:145`) | $4.617/MTok-in equiv. (weighted, un-normalized on the stated 97.5%; 2.5% residual unallocated in the source and immaterial here) | **~$2,054.49** |

(Method: total-input-equivalent-tokens × $/MTok-in ÷ 1,000,000, since every field above
was already expressed as an input-equivalent token count; output-equivalent tokens
already folded in via the 5× step in §1.3's table, so the same $/MTok-in figure applies
to the whole 444,983,249 input-equivalent total.)

**Illustrative no-caching counterfactual** (same total real+equivalent work, but every
cache read/create byte re-billed as a plain fresh-input token instead, at the blended
rate): 2,504,889,304 + 131,272,661 + 848,317 = 2,637,010,282 tokens at fresh-input price,
plus 5,911,035 output tokens at output price ≈ **$12,311**. Caching (even with create's
premium) is already banking roughly an **83% reduction (~6×)** vs. that counterfactual.
This is the frame that makes "cache smart, don't just cache less" the right instinct —
see §5.

### 1.4 Real cross-check (this session's own main transcript, independently measured)

Wrote and ran `evals/context-cost/measure_context_slices.py` (streaming, O(1) memory,
message.id-deduped per the method in `docs/analysis/token-spend-forensics.md`) against
this session's own 35MB main-thread transcript (NOT the ~325MB of subagent transcripts —
deliberately excluded per the "bounded reads" constraint and the prior context-thrashing
incident on an adjacent topic this segment):

```
input_tokens                          298,882  ( 0.022%)
cache_read_input_tokens         1,278,679,473  (95.722%)
cache_creation_input_tokens        54,474,346  ( 4.078%)
output_tokens                       2,373,777  ( 0.178%)
total                            1,335,826,478
```

`tool_result` blocks: 2,779 / 1,593,710 chars — within ~1% of the given 2,765 /
1,607,816 (full session), strong evidence tool-result content is concentrated in the
main thread and that this script is measuring the same artifact the orchestrator's
figures came from. `thinking`-block content is `""` in every case (signature-only
persistence — confirmed by design, not a parse bug; see script comment at
`measure_context_slices.py:99-108`).

Main-thread-only total (1,335,826,478) is ~50.5% of the given full-session total
(2,642,921,317) — consistent with the excluded ~325MB of subagent transcripts carrying
the other ~49.5%, not a contradiction. Token-share ratios match closely (95.72% vs.
94.78% cache-read share) — corroborates the given figures' shape on a real, independent,
bounded subset.

### 1.5 Verdict on the 94.8% framing

**Does NOT survive unchanged as a dollar claim.** Cache-read alone is ~56% of cost, not
94.8%. **The orchestrator's bottom line DOES survive**: context-handling (read+create
combined) is ~93–94% of cost either way, TTL assumption barely moves it. What changes is
WHICH lever inside "context handling" deserves attention — cache-CREATE (36.88% of $,
only 4.97% of tokens) is now a first-class target, not a rounding error, and every prior
framing that looked only at token share had it invisible.

---

## 2. Addressable slice: what fraction of the 93% is anything can plausibly touch

### 2.1 Tool results — RTK's honest ceiling

Raw tool_result content: ~402K tokens (given figure), confirmed independently at 1,593,
710 chars / ~398K tokens (§1.4). As a share of the two denominators that matter:

- of cache-READ tokens (2,504,889,304): **0.0161%**
- of the whole session (2,642,921,317): **0.0152%**

Stated plainly, as instructed even though unflattering: **the raw tool-result content
RTK could touch is on the order of one-sixth of one-tenth of one percent of total
tokens.** This is not a typo — tool results are genuinely small relative to the cache
that gets replayed around them.

The gap between "0.015% of raw content" and RTK's own claimed 1.4–3.3% realized-dollar
ceiling (`docs/analysis/rtk-incorporation-assessment-2026-08-22.md`, §6–7) is real and
explainable, not a contradiction: raw tool-result BYTES are what RTK compresses once, but
those bytes then sit in the cached prefix and get **read back on every subsequent turn**
for the rest of the session (or until the cache breakpoint rolls). RTK's own measured
per-tool share of REPLAYED input (not raw output) on a larger corpus: Bash 22.36%, Read
14.03%, all tools combined 40.28% of replayed input. The realized ceiling is a compounding
effect of replay count, not the one-shot size of the tool output.

**Honest ceiling stated as a ratio**: RTK addresses 100% of the ~0.015% raw-content
slice, whose REPLAY-compounded value is measured (by the RTK doc itself, on its own
larger corpus, dollar-costed) at **1.4% (safe-subset config) to 3.3% (as-shipped
config)** of total spend. That is the number to carry forward to §5, not the 0.015% raw
figure — but 0.015% is the honest floor that explains why the ceiling isn't larger than
low single digits no matter how aggressively tool output is rewritten.

### 2.2 Fixed scaffolding (system prompt, tool schemas, CLAUDE.md, skills, agent defs)

Not measurable from a transcript artifact directly — Claude Code does not re-serialize
this block into the JSONL per line (confirmed while building the measurement script;
documented in its own header and NOT-measurable section,
`evals/context-cost/measure_context_slices.py:15-20,145-152`).

Best same-repo proxy: `docs/analysis/compaction-arithmetic-findings.md` measured, across
100 sessions / 3,072 requests / 8 compacts, a mean post-compact baseline of 72,666
tokens, of which **~55,247 tokens (~76%) is "STANDING overhead"** (system preamble, tool
defs, CLAUDE.md stack, skills prose) — ranked #1 lever in that doc's own baseline
breakdown, ahead of `agent_listing_delta`, `compact_summary`, `attach:file`, and both
`hook:SessionStart` variants.

Direct dollar value of trimming it is measured LOW: `docs/analysis/token-spend-
forensics.md` (independent 234-session/3,830-request corpus) computed carrying cost at
~$51.53 (4.7% of that corpus's spend) for a median 35,174-token preamble reread 2,930
times, and explicitly states "Trimming 10K off the stack saves ~$14.65... **Low
priority**" — because it's already cache-discounted at 0.1× and the absolute token count
is small relative to conversation-history growth.

**INF, explicitly flagged as unmeasured**: a smaller standing baseline plausibly reduces
compaction FREQUENCY (fewer tokens to re-establish before hitting a context-window
threshold), which would reduce the count of expensive cache-CREATE events — and §1.3
just established create carries a disproportionate 36.88%-of-$-for-4.97%-of-tokens
weight. This second-order effect is NOT quantified anywhere in the corpus reviewed and
is called out here as an open research question, not a claimed saving.

### 2.3 Conversation history growth — the slice NOT closed this session

This is the largest remaining slice and the least precisely measured for THIS specific
session. The given full-session total (2,642,921,317) minus the measured main-thread-
only total (1,335,826,478) leaves ~1,307,094,839 tokens (≈49.5%) attributable to the
~325MB of subagent transcripts this analysis deliberately did not scan, per the bounded-
reads constraint. `evals/context-cost/measure_context_slices.py` is built to close this
gap (accepts multiple transcript paths, streams each in O(1) memory) but was not run
against the subagent tree this session — that remains open, flagged rather than
estimated.

### 2.4 Net addressable-slice picture

| Slice | Size | Directly addressable by | Ceiling (stated as ratio) |
|---|---|---|---|
| Tool-result raw content | ~0.015% of tokens | RTK | 1.4–3.3% of $ (replay-compounded, MEAS by RTK doc) |
| Fixed scaffolding | ~76% of a 72,666-tok baseline | prompt/skill trimming | ~$14.65/10K tok direct (MEAS, low), compaction-frequency effect (INF, unquantified) |
| Conversation history growth | ~49.5% of this session's tokens (INF, unscanned) | context/compaction discipline | 33.5% / $369.50 recoverable on a real measured session (`token-spend-forensics.md` #1) |
| Cache-CREATE concentration | 36.88% of $ / 4.97% of tokens | fewer/cheaper cache-write events | unquantified, flagged §5 |

---

## 3. RTK pilot design (per its own §7 spec — not re-invented here)

Per `docs/analysis/rtk-incorporation-assessment-2026-08-22.md` §7, reused verbatim, no
installation or enablement performed:

**Mechanism**: `PreToolUse` hook + static Rust binary. Rewrites bash tool CALLS and
filters/compresses STDOUT only — tail-only, never touches the cached prefix. Structurally
cache-safe by construction (contrast with headroom, §4).

**Scope gating (deny-list first)**:
- Deny: machine-bound flags, pipes, redirects — never rewritten.
- Allow: `grep`, `ls`, `git log`, `git status` (bare), `git diff` (bare).
- `--aggressive` read-mode: source files only, never test paths, never `bin/` gate
  scripts.

**Opt-in mechanism**: module-manifest pattern, following `modules/headroom/manifest.json`
as the exemplar already in this repo (pattern-discipline citation per this agent's own
protocol) — a per-module manifest flag, not a global default-on switch.

**Measurement plan**:
- A/B, N≥40 matched task pairs (same task class, arm = RTK on/off).
- Primary metric: total (cache_read + cache_creation + input) tokens per completed task
  — measurable via the existing `bin/heimdall-session-usage` tool, no new instrumentation
  needed.
- Hard gate: `test/run-all.sh` green on BOTH arms; any divergence between arms fails the
  pilot outright regardless of token savings.
- Pre-registered kill criterion (set BEFORE running, so a disappointing result can't be
  rationalized after the fact): **<2.5% input-token reduction, OR any gate divergence
  → drop.** This sits inside the 1.4–3.3% ceiling already measured (§2.1) — meaning the
  pilot's own pre-registered bar is realistic, not aspirational, but also leaves little
  room: a result at the low end of the ceiling (1.4%) fails the kill criterion outright.

**What would make it a KEEP**: ≥2.5% reduction, zero gate divergence across all 40+
pairs, holds across at least two task classes (not just one lucky sample).

No binary was installed, no flag enabled, no cost incurred, per the hard constraint.

---

## 4. Headroom re-assessment against the new (2.64B-token) denominator

Headroom is a wire/traffic proxy compressing REQUEST bodies before they reach the
provider — mechanically different from RTK: it sits in-path on every request, not just
on bash stdout, and is NOT cache-safe by default (requires three protective "frozen
prefix" layers — `compute_frozen_count`, `_restore_frozen_prefix`,
`_strict_previous_turn_frozen_config` — specifically to avoid busting the cache it would
otherwise corrupt).

Checked whether the prior rejection was an artifact of a small measurement denominator —
**it was not**. Three independently-dated measurements, same mechanism
(`modules/headroom/manifest.json`), all already at billion-token scale:

| Date | Doc | Result |
|---|---|---|
| 2026-08-19 | `docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md` | 405× gap (cache savings vs. compression savings) |
| 2026-08-23 | `docs/analysis/2026-08-23-token-stack-remeasure.md` | 350× gap; headroom's own lifetime compression-savings = 0.331% of total input tokens |
| 2026-08-25 | `docs/analysis/2026-08-25-headroom-inpath-measurement.md` | 337× gap |

These three denominators were already 1.7–3.5B tokens each — same order of magnitude as
this session's own 2.64B-token total, not a "small n" problem being corrected by a bigger
sample now. The new session-level denominator **corroborates** the prior finding rather
than changing it: three separate measurement dates, a stable ~340–405× gap, converging
independently.

Headroom's realized share of this session, by the same method used for RTK in §2.1 (its
own lifetime-measured range, not re-derived): **0.271–0.558%** of spend.

**Verdict: rejection stands.** No new evidence moves this. Not proposed for pilot.

---

## 5. Ranked levers — the deliverable

Ranked by MEASURED (not guessed) expected saving where available; INF-flagged rows are
explicitly not ranked against MEAS rows by number, only placed directionally.

| Rank | Lever | Type | Expected saving | Status |
|---|---|---|---|---|
| 1 | **Context/compaction discipline** — cap working-set size, avoid multi-day sessions rereading a stale ~1M-token context 2,000+ times | MEAS | 33.5% / $369.50 recoverable, on one real measured 15-day session (`token-spend-forensics.md` #1) | Recommend — highest measured lever by an order of magnitude over everything below |
| 2 | **Cache-CREATE concentration** — 36.88% of $ for only 4.97% of tokens (§1.3); candidate mechanisms: concurrent-spawn cache fragmentation, compaction-triggered baseline resets | INF (share MEAS, mechanism not) | Unquantified — flagged as the top open research priority this doc surfaces | Investigate — this is the single biggest reframing this doc contributes vs. the original token-share view |
| 3 | **RTK pilot** (tool-result rewriting) | MEAS (ceiling, from RTK's own doc) | 1.4–3.3% of spend | Pilot per §3 design; pre-registered kill criterion already sits near the low end of this range |
| 4 | **Read-only research subagent delegation** — keep as-is | MEAS | 6.8% of a comparison corpus's spend, but explicitly labeled "correct delegation... keeps #1 from being worse" | Keep, do NOT reduce fan-out (corrects this analysis's own earlier working hypothesis — see below) |
| 5 | **Headroom** (wire-proxy compression) | MEAS | 0.271–0.558% of spend, stable across 3 independent dates | Reject — confirmed, not revisited by new denominator (§4) |
| 6 | **Caveman/ultra output compression** | MEAS | 0.49% measured (own corpus); ~0.05% per orchestrator's token-share napkin math; ~1.48% under this doc's cost-corrected (5× output multiplier) reframing | Low priority — three independent estimates triangulate to "small but not zero"; output is only 6.64% of cost total (§1.3), capping any output-side lever's ceiling regardless of technique |
| 7 | **claude-mem** | MEAS | 0% — one invocation in the entire reviewed corpus | Not worth maintaining at current usage |
| 8 | **Auto-generated skills** | MEAS | 0% — zero recorded invocations, ever | Not worth maintaining at current usage |
| 9 | **Standing-overhead/scaffolding trim** (system prompt, tool defs, CLAUDE.md, skills) | MEAS (direct) + INF (indirect) | ~$14.65 saved per 10K tokens trimmed, direct — "low priority" per source doc; possible unmeasured compaction-frequency second-order saving, unquantified | Low priority on direct value; the indirect path (if real) would show up as more of lever #1, not as its own line |
| 10 | **Output/effort tuning** (budgets, thinking effort, model choice) | DERIVED ceiling | ≤6.64% of cost total is the hard ceiling for ANY output-side lever (§1.3) — largely already applied per repo's model-routing convention | Mostly already applied — diminishing room left |
| 11 | **Cache TTL choice (5m vs 1h breakpoints)** | DERIVED | Combined read+create share moves only 93.17%→94.41% across the full TTL range (§1.3) — not independently actionable as a lever, more a byproduct of turn cadence | Not a standalone lever |
| 12 | **Fresh-input hygiene** (reducing the one truly "always full price" field) | DERIVED | 0.19% ceiling (§1.3) — smallest of the four usage fields by cost share | Negligible, not worth engineering effort |

**Explicit correction of this analysis's own earlier working hypothesis**: mid-analysis,
before locating `token-spend-forensics.md`'s row 5, this doc's author was forming a
hypothesis that REDUCING subagent fan-out might be a valuable lever (reasoning: more
concurrent spawns → more concurrent cache-writes → more create-side cost). The measured
evidence directly contradicts this instinct — subagent delegation is inherent, correct,
and is specifically what keeps lever #1 (uncontrolled main-thread context growth) from
being worse. This is presented as a corrected hypothesis, not a claim.

---

## Answers to the four questions the orchestrator asked to have addressed

1. **Does the 94.8% framing survive a cost-weighted recheck?** No, not as a cache-read-
   alone dollar share — that number is ~56.29% (5m TTL) once the real 0.1×/1.25×/5.0×
   multiplier structure is applied (§1.3). The underlying claim it was shorthand for
   ("context-handling dominates cost, not output") DOES survive: combined read+create is
   93.17–94.41% of cost depending on TTL assumption, output is capped at 6.64% either
   way. What changes materially is the internal split — cache-CREATE turns out to be a
   much bigger piece of the pie (36.88% of $ from 4.97% of tokens) than the original
   framing could see, and is now the top open research question this doc surfaces
   (§5, rank 2).

2. **RTK's honest ceiling**: raw addressable content is ~0.015% of total tokens (§2.1) —
   stated plainly as instructed, unflattering as it is. The REALIZED, replay-compounded,
   dollar-costed ceiling (RTK's own measurement, on its own corpus) is 1.4–3.3% of spend.
   That 1.4–3.3% range, not the 0.015% raw figure, is the number carried into the pilot
   design (§3) and the lever ranking (§5, rank 3).

3. **Headroom's verdict against the new denominator**: rejection stands, unchanged. The
   new ~2.64B-token denominator is the same order of magnitude as the three prior
   independently-dated measurements (1.7–3.5B tokens each, spanning 08-19 to 08-25) — it
   corroborates the stable ~340–405× gap rather than revealing it as a small-sample
   artifact. Realized share: 0.271–0.558% of spend (§4).

4. **Ranked levers** (full table, §5): context/compaction discipline ranks first by a
   wide, MEASURED margin (33.5% / $369.50 recoverable on a real session) — an order of
   magnitude above every other lever considered, including RTK. Cache-CREATE
   concentration is flagged as the single most important NEW finding this doc
   contributes (36.88% of $ for 4.97% of tokens) and is ranked as the top open research
   priority precisely because it is currently unquantified as a mechanism, not because
   its share is small. RTK pilots at 1.4–3.3%. Subagent fan-out is corrected from a
   tentative "reduce it" hypothesis to a measured "keep it, it's what prevents #1 from
   being worse." Headroom is rejected. Caveman/output-side levers are capped low by the
   6.64% output cost ceiling regardless of technique.

---

## §7 — The #1 lever was already built, already firing, and ignored (2026-09-03)

§5 ranks context/compaction discipline first: **33.5%, $369.50 measured-recoverable**,
an order of magnitude above every tool option combined. The obvious next question is
"what should we build?" The answer is NOTHING — it already exists and it already works.

`bin/heimdall-ctx-meter` is wired at `UserPromptSubmit[1]` and fires correctly.
Run against this very session, as the hook invokes it:

```
[heimdall] CONTEXT 422,199 tokens — past the 150,000 ceiling. Checkpoint and
           restart: run /hmd:save, then start a fresh session.
[heimdall]     $0.366/req at 731K context vs $0.0593/req at 118K — 6.17x.
               A restart re-pays ~35K of preamble (~$0.02); staying here cost
               $369.50 over one session.
```

It fired on every prompt of this session. Context still reached 422,199 tokens —
2.8x the ceiling — and the session continued for a full day past it.

**So the gap is not detection. It is that the orchestrator kept working.** The meter
is advisory: it prints, and nothing stops the turn. This is the identical class of
defect this session catalogued three other times — the caveman instruction that was
injected every turn while 3.25% filler survived; `heimdall-metric --type`, mandated in
CLAUDE.md with ~895 of 900 rows missing it; and the "report once when all agents
finish" rule sitting in the orchestrator's own persistent memory while it narrated
after nearly every completion. An instruction with no read-back does not bind, and an
advisory warning is an instruction with no read-back.

### Why this one is worth more than the others

The three cases above cost tokens. This one costs **$369.50 per occurrence**, measured
on this repo, by the owner's own two days of identical working style:

```
2026-08-05 · 476 reqs · 731,707 mean ctx -> $0.366  / request
2026-08-07 · 153 reqs · 118,678 mean ctx -> $0.0593 / request   = 6.17x cheaper
```

It is also the cheapest to fix: a restart re-pays ~35K of preamble, about $0.02.
The ratio between the cost of compliance and the cost of non-compliance is roughly
18,000:1, and the session still ran past it.

### What would actually bind

Unresolved, and stated as a question rather than a plan, because this document should
not repeat the mistake of proposing an unenforceable fix for an unenforceable fix:

- A `UserPromptSubmit` hook CAN return a blocking decision, not merely text. Whether it
  SHOULD hard-block a turn at the ceiling is a judgement call with a real failure mode —
  a wrongly-tuned block would strand an operator mid-task with no override.
- The honest interim: the ceiling is the OPERATOR's to enforce, and the meter's job is
  to make ignoring it a conscious act rather than an oversight. It does that correctly.

### The measurement this session is

Every number in §1-§5 was produced by a session that was itself the worst case in the
corpus. The 2.64B cache-read total, the $2,054.49, and the 422K context above are the
same event described three ways. That is not a caveat to the analysis — it is the
strongest single data point in it.
