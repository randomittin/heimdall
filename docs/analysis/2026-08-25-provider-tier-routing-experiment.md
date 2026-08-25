# Provider-tier routing experiment — design

**Date:** 2026-08-25 · **Repo:** `/Users/rj/Downloads/heimdall`, `main` @ `889c39c` (worktree was
already current when checked — no fast-forward was needed; see Method).
**Ask:** design (do not implement, do not run) an empirical answer to "does third-party-backed
coding meet hmd's own quality bar," reusing the existing `bin/heimdall-self-improve` harness.
**Scope:** design + one document. No routing change, no OmniRoute install/run, no edits to
`bin/heimdall-self-improve`, `bin/heimdall-metric`, `bin/heimdall-model-resolve`,
`.planning/settings.json`, or `CLAUDE.md`.

## Verdict in brief

The harness exists, is well-designed, and needs exactly one additive schema field
(`provider`, alongside the existing `model` tier) to be honest about what this experiment
measures — described in §2, not implemented here. But the harness is currently **unfed**: the
comparable scalar it needs (first-try AC pass-rate) has been recorded for `task_type:"code"`
exactly **3 times, ever, in a single burst on 2026-08-11**, and **zero times since**, despite two
weeks of real work happening in the repo. Before any provider question can be answered, the
orchestrator has to actually start calling `heimdall-metric task --outcome pass|fail` after real
code tasks — that gap, not the provider dimension, is the load-bearing blocker on sample economics
(§3). Separately, and independent of this design: the two most recent OmniRoute assessments in this
same `docs/analysis/` directory (2026-08-23, 2026-08-25) already returned **NO** and
**NO-GO-to-ship-today** respectively for the transport this proposal would need — see §7. This
design proceeds anyway, provider-agnostically, because the measurement methodology is what was
asked for and is not moot just because one candidate transport is currently blocked.

**Method note, per the brief's instructions:** every claim below is marked READ (found verbatim in
a file, or produced by a command I ran) or INFERRED (a conclusion I drew from READ facts). No
number below is asserted without the command that produced it.

---

## 0. Fast-forward check

READ: `git status` shows the working tree on `main` at `889c39c`, ahead of `origin/main` by 236
unpushed local commits, zero divergence from any other local ref. `git worktree list` shows ~55
`.claude/worktrees/agent-*` trees, all at older, divergent SHAs — those are per-agent worktrees for
other in-flight work, not the base I was asked to check. This worktree (the primary repo
directory) was already at the tip of local `main`; there was nothing to fast-forward. Flagging this
plainly rather than running a no-op `git pull` and claiming I "did" a fast-forward.

---

## 1. What is the quality metric?

**READ, `bin/heimdall-metric` (lines 14–33) and `skills/self-improve/SKILL.md` (lines 51–82):**
`outcome` — first-try pass/fail against acceptance criteria, at the tier that ran the task — is
already the recorded, documented comparable scalar ("Heimdall's `val_bpb`", the skill's own words).
It is separate from `final` (the eventual verdict after retries), specifically so "we got there
eventually" cannot launder a bad routing decision. **This is the right comparable. Do not invent a
new metric.**

Two refinements the existing design already implies, worth stating explicitly for this experiment:

- **Where a registry oracle exists, `--outcome` should be sourced from it, not from the coder's own
  self-report.** READ, `.planning/settings.json` → `commands`: `alarm_falsify_exchange` (`bin/falsify
  exchange-lob --assert-score 1.0`), `alarm_falsify_emulator`, `isolation_oracle`, `ship_check` are
  all external, differential/verdict-type gates already wired in this repo (per
  `evals/oracles/REPORT-CONTRACT.md`, READ via `bin/falsify`'s own header comment: falsify reads a
  typed `report.json` written by the domain's own `run.sh`, never scrapes stdout, and the gate
  itself — not the impl — is the source of diff-truth). For any experiment task that touches an
  oracle-covered domain, `--outcome` should be the oracle's exit status, not a self-declared
  DONE/DONE_WITH_CONCERNS token.
- **For everything else, `--outcome` must come from an independent verifier/reviewer, never the
  coder that wrote the code.** This is already `bin/heimdall-self-improve`'s own stated invariant
  (READ, module docstring line 26–27): *"The evaluator is the recorded task OUTCOMES (from the real
  gate), never a self-report — the routing change being tested cannot grade its own homework."*
  That is the exact same principle this repo's own Oracle-Gate Protocol enforces on plan-verification
  (impl-authored reference rejection). A provider-swap experiment inherits it unchanged: a
  third-party-produced diff graded by the same third-party call, or even by an Anthropic call that
  merely reads the third party's own claim of success, is not evidence.

No new metric is needed. What is needed is for `--outcome` to actually get called (§3) and for the
cell key to distinguish provider (§2).

---

## 2. Does the harness need a provider dimension? (describe, do not implement)

**READ, `bin/heimdall-metric` lines 87, 233–235:** `model` is membership-validated against
`TIERS = ("haiku", "sonnet", "opus")` — a fixed 3-rung ladder. **READ, `bin/heimdall-self-improve`
lines 280–292, 329–352:** `_escalate`/`_cheapen` walk that exact ladder, and `_policy_violation`
refuses any `--model` value outside it (*"never write a full pinned model id into an operational
spawn; the tier alias is the contract"*) and separately refuses moving `review`/`security`
(`_ADJUDICATION_TASK_TYPES`) off `opus`.

**Consequence: `model` cannot be overloaded to also carry provider.** Putting `"mistral"` in the
`--model` slot would either be rejected outright by the existing validation, or — if that validation
were loosened — would silently defeat the exact "tier alias is the contract" and
opus-for-adjudication guards this file already enforces. Both are worse than adding a field.

**The smallest honest change:** a new, orthogonal `provider` field on the metric record
(`bin/heimdall-metric`), slug-validated against an explicit small allowlist (e.g.
`anthropic|<vetted-name>`), **defaulting to `"anthropic"` when absent** — which is not a guess, it
is a statement of fact: every record this repo has ever emitted was in fact served by Anthropic,
so back-filling old records with that value is lossless, not inferred.

Downstream, in `bin/heimdall-self-improve`, the aggregation key changes from the 2-tuple
`(task_type, model)` to the 3-tuple `(task_type, model, provider)`. This is **not** a
backward-compatible, additive change — it is a breaking change to every function that destructures
that tuple:

- `_aggregate()` (the key itself — line 250: `key = (r["task_type"], r["model"])`)
- `cmd_collect()` (sorts `agg.values()` by `(task_type, model)`, line 361)
- `cmd_hypotheses()` (iterates `agg.items()` as `(tt, model), cell`, line 409)
- `_find_hypothesis()` / `cmd_experiment_start()` / `cmd_experiment_evaluate()` (the last one
  matches variant records by `r["task_type"] == subject and r["model"] == variant_model`, line
  640–641 — this would need `and r.get("provider", "anthropic") == variant_provider` added, or an
  Anthropic-served and a third-party-served "sonnet" record would silently pool into one bucket,
  which is exactly the confound this whole question exists to rule out)

**Two things must NOT change:** the tier-ladder logic (`_escalate`/`_cheapen`, walking
`_TIER_ORDER`) must stay provider-blind and same-provider-only — there is no natural "cheaper" or
"stronger" ordering *across* providers the way there is across haiku→sonnet→opus, so a
cross-provider swap must never be auto-generated by `cmd_hypotheses` the way a tier escalation is;
it must only ever be started via the existing explicit `--from` override path (already how
`cmd_experiment_start` supports "advanced / non-routing carriers," READ line 553–557). Second,
`_policy_violation`'s adjudication guard must be extended to refuse `review`/`security` moving off
**both** `opus` *and* `provider="anthropic"` simultaneously — today it only checks the tier. Both of
these are described here as required companion changes to ship the field correctly; neither is
implemented in this pass.

**Does this break existing ledger readers?** Yes, mechanically, at the three call sites named above
— but the breakage is bounded to `bin/heimdall-self-improve`'s own internal key shape (no new
files, no schema-version bump needed since `provider` is additive-with-a-safe-default at the
`heimdall-metric` producer layer). The alternative — leaving the key at 2-tuple and treating
`provider` as a filter applied only sometimes — was considered and rejected: it would let an
Anthropic-served and a third-party-served "sonnet, code" observation share one pass-rate silently,
which defeats the entire point of Q2.

---

## 3. Sample economics — the real, measured answer

**READ, `skills/self-improve/SKILL.md` lines 19–25 and 102–105, `bin/heimdall-dream` line 101:** the
20-observation floor is real. It is **not** the CLI's own coded default (`DEF_MIN_SAMPLES = 3`,
READ `bin/heimdall-self-improve` line 66) — the skill explicitly calls that default "a historical
default and far too low for a proportion" and instructs a human to pass `--min-samples 20` by hand;
`bin/heimdall-dream` hard-clamps to `MIN_SAMPLES_FLOOR = 20` and will not let a caller argue it
down. The stated reason (READ, SKILL.md line 22–23): *"at 3 samples, a routing variant that is
genuinely no better still clears a 0.10 delta about 73% of the time."* — matches the brief's
paraphrase exactly.

**Correction to the brief's own citation:** I grepped `skills/heimdall/references/planning-pipeline.md`
for `self-improve`, `routing-experiment`, `hypothes*`, and the "20-observation" language — **zero
matches.** That file exists but does not define this harness. The harness actually lives in
`bin/heimdall-self-improve` + `skills/self-improve/SKILL.md` + `bin/heimdall-dream`, all READ and
cited above. Noting this per the brief's own instruction to verify rather than trust a citation.

**The measured split, run fresh against current `main` (`889c39c`), not assumed from the brief's
~86%/14%:**

```
grep -c '"metric":"task"' .planning/metrics.jsonl                              → 42
grep '"metric":"task"' .planning/metrics.jsonl | grep -o '"model":"[a-z]*"' \
  | sort | uniq -c                                                             → 39 sonnet, 3 opus
```

That is **92.9% sonnet / 7.1% opus** of all model-tagged `task` records today — not 86%/14%. The
86/14 figure is real, but it is `docs/analysis/2026-08-23-omniroute-assessment.md`'s own snapshot
from **two days ago** (19 sonnet / 3 opus of 22 records, READ from that file directly) — the corpus
has grown by 20 more records since, almost all `sonnet`, which pushed the share up further. Both
numbers are honest measurements of the same file at different times; the brief's number is simply
stale by 48 hours. This is the number I actually obtained; I am not reporting the brief's number as
current.

**The number that actually matters for this design is much smaller and much more important:**

```
grep '"metric":"task"' .planning/metrics.jsonl | grep -o '"task_type":[a-z"_]*' \
  | sort | uniq -c
  → 36 null, 3 code, 1 review, 1 docs, 1 design
```

Of the 42 total records, only **6** carry a real (non-null) `task_type` at all. Of those 6, only
**5** carry a scored (non-null) `outcome` — and **all 5 share the identical timestamp window
`2026-08-11T06:24:13Z` → `2026-08-11T09:38:56Z`**, all `"source":"orchestrator"`. **Zero** additional
scored `task_type:"code"` records exist anywhere in the 14 days between 2026-08-11 and today
(2026-08-25), despite **37** `"source":"subagentstop"` records firing in that same window — the
mechanical `SubagentStop` bridge (`bin/heimdall-metric-hook`) fires reliably, but by design (READ,
that file's own header, and its 2026-08-23 removal-of-`outcome` note) it can **never** populate
`outcome`, because SubagentStop's payload carries no pass/fail signal at all. Only the
prose-instructed orchestrator path (`agents/heimdall.md` lines 309–316: *"After EVERY completed
task, run `bin/heimdall-metric`"*) can supply a scored `outcome`, and — measured, not assumed — it
has done so exactly once, in one burst, on the day the feature shipped, and not once since.

**This is independently corroborated by the repo's own code comment**, not just my read of the
data: `bin/heimdall-metric-hook`'s header states, verbatim, *"130 parallelism-tracker records vs 5
heimdall-metric records over the same 83-day window... `bin/heimdall-dream` has never fired once:
'task-outcome records seen: 5' sits under its own 20-per-(task_type,model) sample floor."* That "5"
is the same five records I found. The gap is not new information — it is a known, documented,
unfixed condition of this repo, and it is the actual bottleneck on this proposal, not the sample
floor's size.

**Answer to "how long in real task volume":**

- **At the current organic rate (0 new scored `code` observations / 14 days), there is no
  finite answer — the harness cannot produce a verdict at all, for any routing question, provider
  or tier, until the orchestrator's `--outcome` call is actually exercised consistently.** This is
  the single most important finding in this document, and per the brief's own instruction, I am
  stating it plainly rather than papering over it with an optimistic projection.
- **If that gap were fixed today** (out of scope for me to implement — it would mean touching
  `agents/heimdall.md`'s enforcement or wiring a mechanical `--outcome` source, neither of which I
  own here), a rough, explicitly-labeled **INFERRED** order-of-magnitude proxy: `git log --since
  "14 days ago" --oneline --merges | wc -l` → **85** merged sub-agent-branch task commits in 14
  days (≈6/day, all task types combined — lint, docs, code, review, design, etc., not "code" only,
  and this counts landed work, not AC-scored outcomes). If "code" is even a modest fraction of that
  daily volume, reaching one cell's 20-sample floor is plausibly **single-digit days to ~2 weeks**
  of calendar time once instrumentation is live — but this is a volume proxy, not a substitute
  measurement, and I am not presenting it as the answer to the actual question.
- **This design recommends two concurrent cells, not one** (see §5): a live Anthropic-sonnet
  `code` baseline running the *same* calendar window as the third-party variant, not the stale
  2026-08-11 snapshot as baseline. That doubles the real requirement to **40** scored observations
  split across two buckets, ideally interleaved to avoid a time-based confound (e.g., a harder
  batch of work landing disproportionately in one window). **Honest summary: this is a multi-week
  commitment at best, and an indefinite one at today's actual instrumentation rate — not a
  single-session or single-sprint trial.**

---

## 4. What must NOT be included — the adjudication firewall

**Hard constraint, non-negotiable in this design:** `opus` stays the model AND `anthropic` stays
the provider for `reviewer`, `verifier`, and `security-auditor` roles, for the entire duration of
any provider-routing trial, with zero exceptions and zero "just this once for comparison" carve-outs.

Two independent reasons this repo already enforces, both READ:

- **Agents/heimdall.md, line 263:** *"Opus is the default for anything that writes or reviews
  code. Heimdall must be amazing at code — never compromise quality to save tokens on coding
  tasks."* (Flagging precisely: the delta brief attributed this sentence to `CLAUDE.md`; I grepped
  `CLAUDE.md` for "amazing", "compromise", and "save tokens" and got zero matches. The sentence is
  real, but it lives in `agents/heimdall.md`, not `CLAUDE.md` — correcting the citation rather than
  asserting a location I didn't verify.)
- **`bin/heimdall-self-improve`'s own `_policy_violation()`, lines 295–352:** already refuses any
  routing override that would move `task_type` `review` or `security` off `opus` — the code
  comment states the rationale explicitly: *"a flawless opus review record is opus doing its job
  correctly, not evidence a cheaper tier can replace it."* The identical logic applies to a
  provider swap: a flawless Anthropic-opus review record is not evidence a third-party-served
  review would hold, and this experiment must never test that claim, because if the judge is also
  swapped, **the experiment grades itself and the result is worthless.**

Concretely: the reviewer/verifier that grades whether a third-party-produced diff passes acceptance
criteria must be an Anthropic-opus call, sourced from a Claude Code hook or subagent already
independent of whichever agent produced the code under test (same disjoint-authorship requirement
this architect role already applies to `differential` oracle references). No exception, no
downgrade, for the life of the trial.

---

## 5. The standing-directive conflict — stated, not resolved

**The conflict, stated plainly:** `agents/heimdall.md` line 263 says Heimdall must never compromise
code quality to save tokens; this proposal's entire premise is routing coding work to a
provider chosen because it is cheaper or more available, not because it is measured better. These
are in direct tension by construction — routing FOR cost/access reasons is not routing FOR quality,
and the directive as written treats any quality trade-off, however small, as impermissible. I am
not resolving this for or against the proposal here; I am defining, in advance, what result
decides it either way.

**Pre-committed decision rule (written before any variant data exists):**

**AMEND the directive** (permit a named, allowlisted, ZDR-cleared provider for `task_type:"code"`,
outside adjudication roles) **if and only if all three hold, measured over two concurrent cells
each at ≥20 scored samples:**

1. `variant_pass_rate (thirdparty, code) >= baseline_pass_rate (anthropic, code)` — **strict
   non-inferiority, zero tolerance for degradation.** This deliberately does **not** reuse
   `heimdall-self-improve`'s default framing of "keep iff delta ≥ +0.10" (READ, `DEF_MIN_DELTA =
   0.10`, and the SKILL.md worked example's `--min-delta 0.15`) — that threshold is calibrated to
   answer "did this get *better*," which is the wrong question here. This proposal's actual claim
   is "as good, just cheaper or more available," so the correct falsifier is a **non-inferiority**
   bar (`--min-delta 0.0` when this is actually run via `experiment evaluate`), not an improvement
   bar. Reusing the +0.10 improvement threshold for a cost/access trade would be too permissive in
   the wrong direction — it would let quality *degrade* by up to 10 points and still read as
   "keep" under the stock framing, which is exactly what the "never compromise" directive forbids.
2. **Zero** kill-criterion trips (§6) occurred anywhere in the trial window.
3. The provider used had an independently verified no-training/no-retention (ZDR-equivalent)
   guarantee **on file before the trial started** — pre-registered, not discovered after the fact.

**ABANDON the proposal** (revert any override; do not retry a different provider without new facts)
if any of:

1. Measured `variant_pass_rate < baseline_pass_rate` at the 20-sample floor.
2. Any single kill-criterion trip (§6) — including any one where degradation isn't even the reason.
3. The 20-sample floor per cell is not reached within a pre-agreed calendar bound (this document
   proposes **60 days**, given §3's measured finding that the organic rate today is zero) — an
   experiment that can never produce a verdict is itself a reason to stop carrying it forward, not
   a reason to lower the floor.

Writing this rule now, before data exists, is the entire point: it prevents "it degraded quality a
little but saved a lot of cost" or "it never got 20 samples but it *felt* fine" from being
rationalized after the fact in either direction.

---

## 6. Kill criteria — including single-observation aborts

Most of this experiment's verdict comes from the 20-sample gate above. Some outcomes are severe
enough that waiting for a sample floor is itself the wrong call. Any ONE of the following, at any
point, aborts the trial immediately, rolls back the override (mirroring the existing
`experiment rollback` path), and forecloses "just try a different third-party provider" without a
fresh design pass:

1. **A security-relevant defect from a third-party-routed code task reaches a merged PR** — i.e.
   escapes the independent Anthropic-opus review firewall in §4. One occurrence, full stop.
2. **A stub/placeholder/mock/TODO pattern that `heimdall`'s own Zero Tolerance content-scan hook
   would ordinarily block reaches a commit anyway** — this would mean the provider's output shape
   evades detection tuned against Anthropic-shaped completions, a blind spot in the safety net
   itself, not just a quality miss.
3. **Tier-1 OAuth-subscription-reuse fires even once.** READ, `docs/analysis/2026-08-25-omniroute-fallback-transport.md`
   §4a: no config flag disabling OmniRoute's "Tier 1 Subscription (Claude Code, Codex, Copilot)"
   cascade step was found in that pass. If this experiment's transport is ever OmniRoute-shaped, one
   observed instance of a request riding the operator's own Claude Code subscription auth to serve
   third-party-routed traffic is an immediate, non-negotiable abort — that is a ToS exposure on the
   account itself, not a quality question this harness is built to measure.
4. **The provider in use turns out not to hold a verified no-training/no-retention guarantee** —
   this is a pre-flight gate per §5.3, but if it is discovered mid-trial rather than caught before
   start, treat discovery as an immediate kill, not a "finish the batch first."

None of these wait for 20 samples. A single occurrence of any of the four is sufficient and the
correct threshold is one, not twenty — the 20-sample floor exists to protect against noise in a
*pass-rate proportion*; it was never meant to average away a security incident or a ToS breach.

---

## 7. Context that makes this design currently non-actionable (read, not assumed)

Two prior analyses already exist in this exact directory and directly bear on whether there is
anything to route to today:

- **`docs/analysis/2026-08-23-omniroute-assessment.md`** — verdict **NO** on OmniRoute for
  cost-based task routing. Disqualifier 1 (data handling) fails hard: OmniRoute's own docs mark the
  ToS-conflict flag on 19+ free-tier providers as *"advisory, not a routing gate."*
- **`docs/analysis/2026-08-25-omniroute-fallback-transport.md`** (same day as this document) —
  verdict **GO-WITH-CAVEATS on transport mechanics, NO-GO on shipping today**, for a *narrower*
  exhaustion-fallback use case (not cost routing). Blocking finding #1: no config was found that
  disables Tier-1 OAuth-subscription-reuse. Blocking finding #2: neither Mistral nor LLM7 (the two
  backends named as actually used in practice) preserve Anthropic prompt-cache breakpoints when
  routed through OmniRoute's OpenAI-shaped translation layer — a structural loss of the 0.1×
  cache-read pricing this repo's own cost forensics identifies as the thing holding spend down
  today. Blocking finding #3: neither backend has a verified ZDR-equivalent guarantee.

**What this means for the design above:** every gate in §5 and §6 that references "a named,
allowlisted, ZDR-cleared provider" is currently an empty set for OmniRoute specifically — Mistral is
described in the 2026-08-25 doc as "structurally the cleaner of the two" but still UNVERIFIED on
training/retention, and both assessments are independent of, and unaffected by, the design in this
document. **This design is not moot** — it specifies how to measure the question *if and when* a
provider ever clears the existing gates those two documents already apply — but it should not be
read as license to start the experiment against either backend named in those docs today. Whether
third-party transport works at all remains a separate, already-in-progress question this document
does not reopen.

**One more repo-governance note, READ from `.planning/settings.json` → `hard_constraints`:** *"no
new orchestration features (gates/corpus/router/bench/reach only)."* A provider-routing capability
is plausibly a "router" feature under that allowlist, but that determination belongs to whoever
owns that constraint, not to this design document.

---

## Sources

- `git status`, `git log`, `git worktree list` (this session, `main` @ `889c39c`)
- `bin/heimdall-model-resolve` (full file, tier-alias resolution + non-ZDR fable gate)
- `.planning/settings.json` (`model_routing`, `commands`, `hard_constraints` keys)
- `.planning/metrics.jsonl` (599 lines; `grep -c`/`grep -o`/`uniq -c` counts run directly, this
  session, against current `main`)
- `bin/heimdall-metric` (full file — schema, `_build()`, `TIERS`/`OUTCOMES` validation)
- `bin/heimdall-metric-hook` (header comment — the "130 vs 5" self-documented instrumentation gap)
- `bin/heimdall-self-improve` (full file — `_aggregate`, `_policy_violation`, `cmd_experiment_*`,
  `DEF_MIN_SAMPLES`/`DEF_MIN_DELTA`)
- `bin/heimdall-dream` (`MIN_SAMPLES_FLOOR = 20`, grepped)
- `skills/self-improve/SKILL.md` (full file — the 73%-false-positive rationale, the `--min-samples
  20` instruction, the loop's five steps)
- `skills/heimdall/references/planning-pipeline.md` (grepped for `self-improve`/floor language —
  zero matches; cited in §3 as a correction to the brief)
- `agents/heimdall.md` (lines 245–316 — model routing table, the "amazing at code" sentence, the
  Pattern Learning instruction)
- `bin/falsify`, `bin/corpus` (header comments — oracle-gate contract, `report.json` structure)
- `docs/analysis/2026-08-23-omniroute-assessment.md` (full file — cost-routing verdict, cited 86/14
  snapshot)
- `docs/analysis/2026-08-25-omniroute-fallback-transport.md` (full file — transport verdict, Tier-1
  and cache-control findings)
- `CLAUDE.md` (grepped for "amazing"/"compromise"/"save tokens" — zero matches, cited in §4 as a
  citation correction)

## OUT OF SCOPE

- Implementing the `provider` field on `bin/heimdall-metric` or the 3-tuple key change on
  `bin/heimdall-self-improve` (§2 describes; does not implement)
- Fixing the instrumentation gap in §3 (getting the orchestrator to actually call
  `heimdall-metric task --outcome` consistently) — named as a prerequisite, not built here
- Re-litigating or re-running either OmniRoute assessment (§7) — both stand as written
- Selecting, vetting, or onboarding any specific third-party provider (Mistral, LLM7, or any other)
  — §5.3's ZDR-equivalent-guarantee gate is a precondition this document does not clear for anyone
- Any change to `bin/heimdall-model-resolve`, `.planning/settings.json`, `CLAUDE.md`, or
  `agents/heimdall.md`
- Running the experiment itself, in any form, against any provider
- Resolving the "router feature vs orchestration-feature-freeze" governance question in §7's last
  note

## Risks & Mitigation

| Risk | Probability | Impact | Mitigation | Owner |
|---|---|---|---|---|
| Instrumentation gap (§3) never gets fixed, so the 20-sample floor is permanently unreachable | high | high | Pre-committed 60-day timeout in §5 converts "no data forever" into an explicit ABANDON, not an indefinitely-open question | whoever owns `agents/heimdall.md` Pattern Learning enforcement |
| Provider-dimension schema change (§2) shipped without updating all three call sites, silently pooling Anthropic and third-party records into one cell | med | high | §2 names the exact three functions that must change together; any implementer must update `_aggregate`, `cmd_hypotheses`, and `cmd_experiment_evaluate` in the same change, never one alone | implementer of §2, at a future date |
| Judge (reviewer/verifier/security-auditor) accidentally routed to the variant provider during a trial, self-grading the experiment | low | high | §4's firewall is stated as a hard, zero-exception constraint; any experiment-start tooling built later must refuse (mirroring `_policy_violation`'s existing refusal for tier) rather than warn | whoever builds the §2 companion `_policy_violation` extension |
| Non-inferiority bar (§5) gets silently swapped for the harness's default +0.10 improvement bar because that's what `experiment start`'s example shows | med | high | §5 states explicitly why `--min-delta 0.0` is required here, not the SKILL.md default of 0.10–0.15 | whoever runs `experiment start` for this specific hypothesis |
| A kill-criterion trip (§6) gets treated as "one bad sample, average it out" instead of an immediate abort | low | high | §6 states plainly that these four conditions require n=1, not n=20, and lists them separately from the sample-floor gate | whoever operates the trial |
