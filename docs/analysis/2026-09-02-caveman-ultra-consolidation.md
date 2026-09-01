# 2026-09-02 — caveman ultra consolidation: trim constraint count, not add to it

Task: `brief-1788288808-43945`. Owner directive: "improve ultra on all grounds --
take best practises from headroom, rtk and others as well." Scope: `bin/heimdall-
caveman`'s `_rules_ultra` function only (`_rules_lite`/`_rules_full` untouched,
byte-identical), `test/heimdall-caveman.test.sh`, this doc.

## 0. What this pass is answering, and why it is NOT another content patch

The 2026-09-01 ultra-parity fix (`docs/analysis/2026-09-01-caveman-ultra-parity-
research.md`) added five negative constraints to close a token-parity gap vs
`upstream_skill`, and it worked on the metric it targeted: hmd_ultra's median
tokens beat upstream (330 vs 359, up from -11.1%). But
`docs/analysis/2026-08-30-caveman-eval-measurement.md` §9 (landed on `main` as
commit `fb1b17a` while this task was in flight) measured a cost from that same
patch: tokens-per-visible-word rose 2.88 → 3.54 while an untouched control held
flat — i.e. the added negative constraints plausibly bought visible brevity by
spending hidden (thinking) tokens, which are billed identically whether
displayed or not.

§9 also closes off the direct way to check that hypothesis: the Anthropic usage
object has no separate thinking/reasoning field (`input_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens` only;
extended thinking is billed the same whether displayed or not), so "how many of
these tokens were thinking" can never be measured directly on this harness — only
inferred via the tokens-per-visible-word proxy. §9 states the resulting design
rule plainly, now backed by two independent findings (the rejected intensity-
ladder hypothesis, and this one): **prefer fewer constraints covering more
ground over more negative rules.** This pass is that rule applied to `_rules_
ultra` itself — it does not add a sixth ban; it looks for duplication and
mergeable clauses in what is already there.

## 1. Constraint count — the headline number

Methodology (stated up front so the count is checkable, not asserted): a
**constraint** is one independently-violable instructable clause in the rule
text — an enumerated drop-category, a formatting rule, a ban, a persistence
behavior, a carve-out trigger. Pedagogical illustrations (the `Pattern:`
template, the `Not:`/`Yes:` contrastive pairs, the three worked Q→A examples)
are excluded — they demonstrate existing rules, they don't state new ones. Two
counts are reported because they answer different questions:

- **Literal statements** — every clause counted where it appears, including a
  concept restated in a second location. This is the number that tracks actual
  token cost of the text, since a duplicate restatement costs tokens even though
  it adds no new ground.
- **Distinct concepts** — the same clauses with restatements deduplicated. This
  is the number that tracks actual rule-surface size.

| | Rules¶ | Persistence | Boundaries | Auto-Clarity | This-level (dup) | **Total** |
|---|---|---|---|---|---|---|
| OLD literal | 17 | 5 | 3 | 5 | 4 | **34** |
| NEW literal | 15 | 5 | 2 | 5 | 0 | **27** |
| OLD distinct | 17 | 5 | 2 | 5 | 0 | **29** |
| NEW distinct | 15 | 5 | 2 | 5 | 0 | **27** |

**Literal statements: 34 → 27 (−7, −20.6%). Distinct concepts: 29 → 27 (−2,
−6.9%).** Both fell; neither rose. Reported both ways rather than picking the
more flattering one: the bigger number (−20.6%) is duplication removed (real
token cost, zero ground lost); the smaller number (−6.9%) is the actual rule-
surface reduction, which is real but modest — it comes entirely from merging
three clauses into one (below). No new constraint was added anywhere in this
pass, so "went up" does not apply here, but the honest headline is the smaller
number, not the larger one — the larger one flatters by definition, since it
was designed to shrink.

Where the three cuts came from:
1. **Deleted the vestigial `## This level (ultra)` section** — four facts
   (Abbreviate, strip-conjunctions, arrows-for-causality, one-word) already
   stated once in the `## Rules` paragraph above it, restated verbatim. A
   leftover from when caveman had multiple levels needing per-level
   disambiguation inside a shared template; collapsed to one settable level on
   2026-09-01 (this repo's own `CLAUDE.md`), the section had nothing left to
   disambiguate. Zero distinct concepts lost — it was 100% duplicate.
2. **Merged three clauses into one**: `Technical terms exact. Code blocks
   unchanged. Errors quoted exact.` → `Compress form, never substance:
   technical terms/code/errors stay exact.` This is the only cut that actually
   shrinks the distinct-concept count (3 → 1), because the three were always
   one idea (verbatim content must survive compression) stated three times.
3. **Dropped the duplicate exit-trigger in `## Boundaries`**: `"stop caveman"
   or "normal mode": revert.` was a second statement of the same concept
   `## Persistence` already states once (`Off only: "stop caveman" / "normal
   mode".`). Boundaries now just states its own two distinct facts (write code
   normally, level persists until changed).

A fourth change carries no constraint-count weight but is worth naming because
it removes a smaller instance of the *same* vestige as cut 1: each worked
example's per-line `ultra: "..."` label was dropped (`Example — "Q"\nultra:
"A".` → `Example — "Q" → "A".`) — another leftover level-disambiguator from the
pre-collapse multi-level template, now redundant since there is one level.
Reformatting to one line via `→` also makes the Rules section's example
formatting internally consistent (the `Not:`/`Yes:` pairs already used a bare
label with no level name) and dogfoods the arrow-for-causality / flat-fragment
rules the text itself teaches.

## 2. Byte count

`_rules_ultra`'s heredoc body, measured both by extracting the exact source
line range and independently via the live CLI's actual stdout (`bin/heimdall-
caveman rules ultra 2>/dev/null | wc -c`) — both methods agreed at each point:

- **Before: 2990 bytes.** (Post-2026-09-01-patch state, i.e. what was actually
  live in this file when this task started — verified against the file, not
  assumed.)
- **After: 2668 bytes.**
- **Delta: −322 bytes (−10.8%).**

The brief's reference figure of "~1839 bytes" does not match either number
above; it appears to describe a PRE-2026-09-01-patch snapshot (before the
header-ban/self-narration-ban/redundant-recap-ban content existed at all), not
the immediate prior state of this file. Noting the discrepancy rather than
silently reconciling it: this pass's 2990-byte starting point is the one
independently verified against the live file at session start, and is the
correct "before" for this diff. Byte count was never pushed down toward 1839 by
cutting the 2026-09-01 patch's validated content (see §4, item 3) — the
reduction here comes entirely from removing duplication and merging clauses,
which is a smaller but real number, and preserves the patch's proven win (the
same 5 pinned clauses / their reworded equivalents are all still present and
covered by tests).

## 3. Practices taken from RTK / headroom / elsewhere — and what did not cross

The brief's framing is the right one and is preserved here deliberately:
caveman/ultra is an **instruction layer** — text in a system/tool prompt that
shapes what the model chooses to write. RTK is a **tool-output-compression
layer** — a PreToolUse hook plus a Rust binary that filters/truncates/dedupes
bytes a bash command already produced, before they reach the model as an
observation. Headroom is a **wire-proxy layer** — it compresses HTTP request/
response bodies in transit between client and provider. All three layers can
share a *principle*; none of RTK's or headroom's *mechanisms* can run on model-
generated prose, because by the time ultra's rules apply, there is no
intercepted byte stream to rewrite — there is only an instruction hoping to
change what gets generated in the first place.

**From RTK** (`docs/analysis/rtk-incorporation-assessment-2026-08-22.md`):
- *Crossed, as a principle:* RTK's disqualifying finding was silent, proven
  corruption of meaning-bearing output — duplicated filenames in `git diff
  --name-only`, a dropped final entry in `git status --porcelain` from a
  stripped trailing newline, exit-code masking on diffs. The lesson —
  compression must never silently alter content something downstream actually
  parses or relies on verbatim — is exactly what "Compress form, never
  substance: technical terms/code/errors stay exact" now states for ultra's own
  compression target (the model's own word choice, not a bash command's
  stdout). Same principle, different substrate: RTK protects bytes a *machine*
  parses; ultra protects content a *reader* needs verbatim.
- *Crossed, as a principle, not a mechanism:* one of RTK's four strategies is
  "dedupe repeats." It directly motivated auditing `_rules_ultra` for its own
  internal duplication (finding cuts 1 and 3 above). RTK's actual dedupe
  mechanism runs algorithmically over tool-output bytes after a command
  executes; the ultra dedup here was manual, at authoring time, over an
  instruction document — there is no runtime step where a duplicate sentence in
  a system prompt gets caught and stripped the way a repeated log line would be.
- *Did not cross:* the PreToolUse hook and Rust binary themselves. There is no
  equivalent interception point in the ultra pipeline — model output isn't
  observed and rewritten post-hoc the way a bash command's stdout is; it's
  requested to be terse up front via instruction, with no enforcement layer
  behind it (this is also why `hmd caveman-audit` measures compliance rather
  than gates it).

**From headroom** (`modules/headroom/manifest.json`):
- *Crossed, as a principle:* headroom's tagline, "Generation may run
  compressed; judgment never does," is a structural split between what's safe
  to compress and what must stay exact. Ultra's "Compress form, never
  substance" is the same split applied one layer up: compress the model's
  *verbosity* (articles, filler, hedging, restatement) but never its
  *substance* (technical terms, code, quoted errors) — headroom decides this
  per request/response on the wire; ultra decides it per clause within one
  response.
- *Did not cross:* the proxy mechanism itself (a process sitting between client
  and provider, rewriting HTTP bodies) and the storage codec half (not
  currently satisfiable — headroom-ai 0.35.0 has no reversible decode, per the
  existing headroom assessment). Neither has an analog for a system prompt.

**From upstream `caveman` skill** (`evals/caveman/upstream_skill.md`): same
layer as hmd's own rules, already verified (pre-dating this task) to contain no
instruction hmd lacks. No new finding this pass; reconfirmed while reading
adjacent content, not re-litigated.

**Not from an external source — from this repo's own measurement trail**
(`docs/analysis/2026-08-30-...` §8 rejected-ladder finding +
`2026-08-30-...` §9 thinking-tokens finding): the standing rule "fewer
constraints covering more ground, not more negative rules" is same-layer,
evidence-based, and is what actually drove *how* this pass was done — merge and
delete, don't add. It is named here because the brief asked what shaped the
approach, not because it's a cross-layer transfer.

## 4. Falsifiable prediction — and its limit

**Prediction:** on the next n=30 real-eval run (same harness and prompt set as
the 2026-09-01 research doc), hmd_ultra's tokens-per-visible-word ratio should
fall from 3.54 toward a lower range (roughly 2.9–3.2 — meaningfully down, not
necessarily back to the pre-patch 2.88) while the median-tokens-vs-upstream
result holds at parity or better than the current +8.5%. That combination would
support the hypothesis that constraint *count* (not the specific wording of any
one clause) contributes to the hidden-token cost §9 measured.

**Its limit, stated per the coordinator's instruction:** this can only be
tested via the tokens-per-visible-word proxy, never by directly measuring
thinking tokens — §9 established that `output_tokens` has no separable
thinking/reasoning field in Anthropic's usage object, by design, regardless of
sampling. If the ratio does NOT fall (stays ≥ ~3.5), that falsifies "constraint
count drives the cost" specifically, and would point instead at one particular
clause (most likely the per-item-example ban, see §5) rather than the count.
Either outcome is informative; neither outcome is a thinking-token measurement,
and none is possible on this harness.

No paid measurement was run to produce this prediction — none was authorized
for this task, and the coordinator confirmed the standing budget note (~$43
already spent this session). One measurement is scheduled by the coordinator
after this report.

## 5. Deliberately rejected / deferred

- **Reverting or narrowing the per-item-example ban** despite its measured
  collateral: fenced-code-block frequency fell 0.33 → 0.03 in the same run that
  measured the tokens-per-visible-word rise. Judgment call: this read as a
  correct downstream consequence of a validated fix, not a bug — the ban
  specifically targets gratuitous *per-item* code samples in multi-cause
  answers (the measured 38%-of-deficit DB-migration-rollback case), and a
  single code block the user actually asked for remains fully protected by
  "Compress form, never substance" (code blocks unchanged). Not reverted; named
  here as a follow-up hypothesis rather than silently dropped, per the brief's
  explicit invitation to make this call and say which way it went.
- **Not re-adding the Intensity Ladder** — already implemented, measured, and
  rejected on 2026-08-31 (`2026-08-30-caveman-eval-measurement.md` §8: hmd_full
  regressed 24pts, hmd_ultra flat, net no improvement). §9 reinforces the same
  conclusion from a different angle (added constraint density plausibly costs
  hidden tokens); re-raising it was never on the table for this pass.
- **Not pushing byte count down to the brief's ~1839 reference** by gutting the
  2026-09-01 patch's validated content — see §2. The reduction here is real but
  smaller, and preserves a proven win rather than trading it for a bigger-
  looking number.
- **No new test-assertion idiom invented.** The original plan was an
  exact-occurrence-count assertion (e.g. "Abbreviate appears exactly once");
  `test/heimdall-caveman.test.sh` has no existing exemplar for counting
  occurrences anywhere in the file (only `case "$x" in *"..."*) ok/bad` presence
  checks, throughout). Redesigned the four new assertions as presence/absence
  checks using that exact existing idiom instead — e.g. asserting the *absence*
  of `"## This level"` and of the old Boundaries restatement, rather than
  counting. Same coverage, zero invented pattern.
- **`_rules_lite` / `_rules_full` / `bin/heimdall-caveman-eval` / anything else
  under `docs/analysis/*`**: out of scope per the brief, untouched. Verified via
  `git diff --stat` that only `bin/heimdall-caveman` and `test/heimdall-
  caveman.test.sh` changed, and via full diff inspection that the changed hunks
  in `bin/heimdall-caveman` are confined to the `_rules_ultra` comment and body.

## 6. Verification evidence

- `bash -n bin/heimdall-caveman` → syntax OK.
- `bash test/heimdall-caveman.test.sh` → `RESULT: 92 passed, 0 failed` (was 88
  before this pass; +4 new assertions, 0 removed, 1 updated in place for the
  reworded header-ban substring). Zero `FAIL` lines on a fresh run; exit code 0.
- `bin/heimdall caveman rules` (stdout only, `2>/dev/null`) renders the new text
  cleanly, starting `HMD OUTPUT COMPRESSION — level: ultra ...` — no diagnostic
  bleed onto stdout (the plugin-divergence warning, when present, is stderr
  only, as designed and as covered by the existing "stdout stays a clean
  'ultra'" test case).
- `bin/heimdall-deadcode --why heimdall-caveman` → `REACHABLE bin/heimdall-
  caveman <- bin/heimdall [REACHABLE] <- <entry-point>`.
- `git diff --stat` confined to `bin/heimdall-caveman` (31 insertions, 31
  deletions — git's line-matching only shows lines that actually differ; most
  of the surrounding text, including all three worked examples' content and
  both contrastive pairs, is byte-identical and correctly not shown as changed)
  and `test/heimdall-caveman.test.sh`.
