# RTK (`rtk-ai/rtk`) — incorporation assessment

**Date:** 2026-08-22
**Question:** should hmd incorporate RTK for token saving?
**Verdict:** **DECLINE as auto-on.** Narrow opt-in pilot defensible; see §7.

Evidence labels used throughout: **[DOC]** = upstream documents it, **[MEAS]** = measured
here on this machine, **[INF]** = inferred/estimated from measured inputs.

---

## 1. What it actually is

**[DOC]** A `PreToolUse` hook + a single static Rust binary. The hook rewrites the agent's
Bash command (`git status` → `rtk git status`); `rtk` then executes the real command, filters
its **stdout**, and returns the compressed bytes as the tool result. Nothing else changes.

- Layer: **tool-output compressor**. Not a wire proxy, not a context builder, not a
  tokenizer, not retrieval. It never sees or edits the request body.
- Requires: the `rtk` binary (7.9 MB static, arm64 darwin) + `jq`. No daemon, no model
  files, no network on the hot path.
- Telemetry is **opt-in, off by default** (`docs/TELEMETRY.md`, entity "RTK AI Labs").
- Hook fails **open** — exits 0 if `jq`, `rtk`, or a new-enough `rtk` is missing
  (`hooks/claude/rtk-rewrite.sh`).
- Four strategies **[DOC]**: filter noise, group similar items, truncate, dedupe repeats.
- Exit protocol **[DOC]** (`hooks/claude/rtk-rewrite.sh`): `0` rewrite+auto-allow,
  `1` no equivalent, `2` deny rule, `3` rewrite but let Claude Code prompt the user.

Upstream is **unusually honest** about savings — `docs/guide/resources/savings-explained.md`
states outright that bash-output reduction "is not the same as cutting your bill by 90%",
walks the dilution chain, and admits token counts are `bytes/4` estimates with no tokenizer.
That is the opposite of the headroom/caveman pattern, and it earns credibility.

## 2. Popularity claim — verified, it is real

**[MEAS]** `gh api repos/rtk-ai/rtk`:

| Metric | Value |
|---|---|
| Stars | **76,984** |
| Forks | 4,838 |
| Watchers | 206 |
| Language / licence | Rust / **Apache-2.0** |
| Created | 2026-01-22 (7 months old) |
| Last commit | **2026-08-20** (`develop`) |
| Releases | **281** (v0.45.0 on 2026-08-07, rc builds through 2026-08-20) |

The "super popular" claim is **accurate and not inflated**. Release cadence is near-daily,
maintainer (`KuSh`) is merging PRs continuously, 552 PRs merged.

**Health caveat [MEAS]:** 982 open issues vs 451 closed (**31.5% close ratio**), plus
~1,000 open PRs (the API's `open_issues_count: 1986` counts both). The backlog is growing
faster than it is being drained.

## 3. Overlap with hmd — none. Genuinely a different layer.

| hmd tool | Operates on |
|---|---|
| `heimdall-brief`, `heimdall-capsule`, `heimdall-task-result`, `heimdall-graph`, `heimdall-comprehend` | what **hmd itself authors** into context |
| RTK | what **external commands return** |

hmd has **nothing** at RTK's layer. This is the honest answer: no duplication, no
redundancy. RTK is complementary in principle.

One adjacency worth noting **[MEAS]**: `Read` tool output is 14.03% of token flow, which is
the layer `heimdall-brief`/`heimdall-graph` attack — and RTK's `read` filter is precisely
the one that delivers 0% (§5).

## 4. Does it touch the cached prefix? No — and this is the important finding.

**[MEAS]** across 2,138 local transcripts / 155,051 assistant messages:

| | tokens |
|---|---|
| cache read | 18,029,003,337 |
| cache creation | 1,544,734,332 |
| plain input | 16,147,856 |
| output | 97,234,194 |

**cache-read = 92.03% of input flow** — the 91.6% figure in the brief is confirmed
(slightly higher now).

**[INF, structural]** RTK **cannot** bust the cache. It never touches `tools`, `system`, or
any existing `messages` entry. It only changes the bytes of a **tool_result appended at the
tail**. The prefix up to that point is byte-identical, so the cache hit is preserved.

This is the **opposite** of headroom (upstream #2438, "proxy defeats prompt caching, 2-7x
cost increase"). Better still: RTK reduces the rate at which the prefix *grows*, so it
shrinks both future `cache_read` and future `cache_creation`.

**So RTK is not attacking the same 4% everyone else attacked.** To size what it *is*
attacking, I computed the **cache-weighted** share — for each turn, the cumulative tool
output already sitting in the replayed prefix, summed over all turns, over total replayed
input (19.59B tokens):

| Source | share of all replayed input tokens |
|---|---|
| **Bash tool output** | **22.36%** |
| Read tool output | 14.03% |
| Agent | 2.91% |
| all tools | 40.28% |

Bash output is the **single largest identifiable category of hmd's token flow.** That is a
real ceiling, roughly 45x higher than the naive "bash is a few percent" intuition — because
every byte written at turn N is re-read on every subsequent turn.

## 5. But the realizable fraction is small — measured, not assumed

I ran the **real v0.45.0 binary** against my **actual** corpus of 51,960 distinct bash
commands (66.86 MB of output, 55,852 calls), counting exit 0 **and** exit 3 as covered.

**[MEAS] Coverage: 35.61% of bash bytes** (35.51% of calls). Exit 1 (no rewrite) = 64.39%.
Largest uncovered: `sed -n` 10.07%, bare `grep -n` 5.60%, `bash <script>` and heredocs.

**[MEAS] Composition of covered bytes:** grep 31.2%, **read (`cat`/`head`) 26.0%**, ls 13.3%,
git log 5.8%, git diff 5.7%, wc 3.7%, remainder small.

**[MEAS] Actual compression, measured per family in this repo:**

| family | measured cut |
|---|---|
| grep (large output) | 95.1% |
| grep (medium / single-file) | 22.4% / 0.0% |
| **`rtk read` (= `cat`) — default level** | **0.0%** |
| ls | 46.7–64.9% |
| git log | 74.7% |
| git diff | 51.9% |
| git status | 61.5% |
| git show --stat | 0.0% |
| wc | 31.2% |

**The `read` finding is significant.** `rtk read` defaults to `--level none` (full content),
and the hook emits **no** `-l` flag (`cat x.py` → `rtk read x.py`). So the single
second-largest covered family — **26% of covered bytes — yields exactly zero** in the
shipped auto-on configuration. On bash scripts it yields 0% at *every* level, and
`aggressive` made output 0.8% *larger*.

**[MEAS/INF] Byte-weighted reduction on covered bytes ≈ 47.1%** → bash bytes cut 16.77% →
**input tokens −3.75%.**

### Cost translation

Pricing from the `claude-api` skill (Opus 5 / 4.8 / 4.7 $5/$25 per MTok, Sonnet 5 $3/$15,
Haiku 4.5 $1/$5; cache read 0.1x, 5m cache write 1.25x). Measured model mix is
Opus-dominated (opus-5 71.2%, opus-4-8 17.7%, sonnet-5 8.6%).

**[INF]** Lifetime spend on this corpus: input-side **$17,904.84**, output-side $2,305.60,
**total $20,210.44** (88.6% input) — consistent with the $19,938.47 in the brief.

| scenario | input tokens | saving | % of spend |
|---|---|---|---|
| **as-shipped** (`read` = none) | −3.75% | **$671** | **3.32%** |
| tuned (`read` = aggressive) | −4.99% | $893 | 4.42% |
| safe subset (no pipes, no machine-bound) | −1.56% | $280 | 1.38% |

### Against the bar

| tool | measured saving |
|---|---|
| headroom | 0.3009% |
| caveman | 0.49% |
| claude-mem | 0 (never invoked) |
| **RTK (projected, as-shipped)** | **3.32%** |

RTK is **~11x headroom and ~7x caveman** — the first of the four that is not a rounding
error, and the only one that is structurally cache-safe. It is also **not 60–90%**. The
headline is a bash-output-byte ratio, which upstream states plainly; the session-level
number is single-digit.

## 6. The disqualifier: silent, proven output corruption

This is why the verdict is decline, and it is not speculative — I reproduced it byte-exactly
in a scratch repo with v0.45.0.

**[MEAS] `git diff --name-only`** — 1 changed file:

```
raw: f1.txt\n                      (7 bytes, wc -l = 1)
rtk: f1.txt\n\nf1.txt\n\n          (16 bytes, wc -l = 4)
```

The filename is **duplicated** and blank lines injected. `wc -l` returns **4 instead of 1**.

**[MEAS] `git status --porcelain`** — RTK **strips the trailing newline** (24 → 23 bytes).
Proven consequence:

```
raw while-read loop:  2 iterations
rtk while-read loop:  1 iteration     <- last entry silently dropped
```

`while read -r` returns non-zero on EOF without a delimiter, so **the final entry vanishes
with no error**.

**[MEAS] Also found:** an invalid `-l` value falls through to `/usr/bin/read` and **hangs**
on stdin (my call timed out at 120s).

**[DOC] Upstream corroborates this as a class, not a one-off** — open issues:
#3558 (hook rewrites piped commands, compressed output feeds downstream parsers, silently
wrong), #2487 (compacts machine-bound git output `--porcelain`/`--name-only`, silently
corrupting), #1282 (silent corruption when stdout piped/redirected), #2811 (`rtk diff`
reports "Files are identical", exit 0, when changed lines share a word), #3267 (diff
rewritten to success verdict, **exit code masked**), #3459 (`git log` silently hides merge
commits), #3338 (`grep -o` discards all output, exits 0), #3508 (`gain` over-reports
savings **~184x**).

Keyword counts on open issues **[MEAS]**: "wrong output" 129, "incorrect" 80, "missing
lines" 55, "corrupt" 44, "data loss" 24, "hang" 15.

### Exposure, measured on my own corpus

| | share of all bash calls |
|---|---|
| machine-bound commands (`--porcelain`, `--name-only`, `--format=%`, `--stat`, `-z`) that RTK **rewrites** | **3.70%** (2,065 calls) |
| calls containing a pipe that RTK rewrites | **18.37%** |
| calls containing a pipe at all | 61.72% |

**Blast radius [MEAS]:** 47 hmd files parse `--porcelain`/`--name-only`, with 28 occurrences
of `git status --porcelain` and 12+ of `git diff --name-only` — including
`bin/heimdall-autocommit`, `bin/bloat-gate`, `bin/heimdall-live-verify`,
`bin/heimdall-conformance`, `bin/heimdall-checkpoint`.

**Mitigating [INF]:** the hook rewrites only the **top-level** Bash tool call. Commands
*inside* an hmd script are not rewritten (`bash bin/bloat-gate` → exit 1, no rewrite), so
hmd's internal script logic is **safe**. The exposure is the agent issuing these directly
and reasoning on the result — 3.70% of calls, provably corrupting.

**Partly mitigating [MEAS]:** truncation is **transparent and recoverable** — RTK emits
explicit markers (`+62 more in <file> [see remaining: tail -n +23 "<tee log>"]`). Good
design. But it cuts the other way too: if the agent follows the recovery path it re-reads
the elided bytes, erasing the saving and adding a round-trip.

This lands badly here specifically because hmd's entire thesis is **fail-closed gates**.
Exit-code masking (#3267) and false-success verdicts (#2811) turn a gate into a
rubber stamp, silently. A gate reading a corrupted diff is worse than no gate.

## 7. Verdict

**DECLINE as auto-on.**

The benefit is real, honestly documented, structurally cache-safe, and the best of the four
audited — **3.32% of spend, ~$671 lifetime, 11x headroom**. It attacks a layer hmd has
nothing for (22.36% of token flow). That is a genuine finding and RTK is a better-engineered
project than the previous three.

It still loses on the trade:

1. **Benefit is single-digit; risk is silent.** 3.32% of spend against altered pipeline
   semantics on 18.37% of bash calls and provable corruption on 3.70%.
2. **Configuring away the risk removes most of the benefit.** The safe subset (no pipes, no
   machine-bound flags) is **1.38% of spend / $280 lifetime** — the same order as caveman,
   which was removed. Not worth a new binary dependency class.
3. **The largest safe win is already zero.** `read`/`cat` is 26% of covered bytes and
   returns 0% as shipped.
4. **Upstream backlog is 982 open issues at a 31.5% close ratio**, concentrated in exactly
   the correctness class that matters here.

### Conditional pilot that would be defensible

Opt-in, non-default, and **only** if all of these hold:
- Deny-list every machine-bound flag (`--porcelain`, `--name-only`, `--format=%`,
  `--pretty=`, `--numstat`, `--stat`, `-z`) and **every command containing a pipe or
  redirect** — upstream #1282's own suggested `isatty` passthrough is the right shape.
- Allowlist only human-read families: `grep`, `ls`, `git log`, `git status` (bare),
  `git diff` (bare).
- Wire `read -l aggressive` only for real source files, never bash.
- Never inside `test/`, `bin/`, or any gate path.

Expected value of that configuration: ~1.4–2% of spend. State that up front so it is not
re-litigated as "60–90%".

### What to measure to overturn this

A controlled A/B, since the remaining unknown is behavioural, not arithmetic:

1. **N ≥ 40 matched task pairs**, RTK on vs off, same prompts, same model tier.
2. **Primary metric:** total `cache_read + cache_creation + input` tokens per completed
   task — not bash bytes, not `rtk gain` (which over-reports ~184x per #3508).
3. **Guard metric (the real question): task correctness and turn count.** Measure re-run
   rate — how often the agent re-issues a command or follows a tee-recovery pointer. If
   RTK's elision costs an extra round-trip more than ~8% of the time, the token saving is
   erased by the retry.
4. **Hard gate:** zero tolerance on gate outcomes. Run `bash test/run-all.sh` under both
   arms and diff pass/fail per suite. Any divergence fails the pilot outright.
5. **Falsifiable kill criterion, set before running:** if measured input-token reduction
   is < 2.5%, or any gate outcome diverges, drop it.

## 8. Flags requested

- **Language/runtime cost:** new dependency **class** — a 7.9 MB static Rust binary per
  platform (5 tarballs), vs hmd's current bash + stdlib python. Distribution via brew /
  `install.sh` / cargo. **`jq` is *not* new** — hmd already invokes it in 79 files. The
  hook fails open, so a missing binary degrades silently rather than breaking sessions.
- **Licence:** RTK **Apache-2.0**, hmd **MIT**. Compatible for a depend-on-binary
  integration; no contamination, since hmd would install and invoke the binary rather than
  vendor its source. Vendoring would require honoring Apache-2.0 attribution/NOTICE.
- **Can it be auto-on?** **Mechanically yes** — `rtk init -g` installs one global
  PreToolUse hook, rewrites transparently, needs no per-invocation management. It satisfies
  "one-time setup pain, never manage invocation" better than any of the prior three. The
  friction is exit-3 "ask" rules, which cover **22.26% of covered bytes** and raise a
  permission prompt each time unless allowlisted. **But auto-on is exactly the mode that
  is unsafe here** (§6) — the capability to be auto-on is not the same as it being wise.

---

### Reproduction

Scripts used for the measurements in §4–6 live in this session's scratchpad
(`measure.py`, `weighted.py`, `cover2.py`, `cover3.py`, `models.py`). Corpus:
`~/.claude/projects` — 2,138 `.jsonl` transcripts, 1.4 GB. Binary under test: `rtk 0.45.0`
(`rtk-aarch64-apple-darwin.tar.gz`, release v0.45.0). No hmd code was modified for this
assessment.
