# Cost Forensics Tool — 2026-09-07

Every token/cost analysis this project has produced up to this point
(`token-spend-forensics.md`, `2026-09-02-input-context-cost.md`, and their
siblings) is **n=1**: one repo, one operator, one machine, one ad-hoc script
run by hand against a hardcoded transcript-root glob. A stranger reading any
of those docs has no way to reproduce the analysis on their own Claude Code
history — the script assumes this repo's directory layout and this operator's
own known figures as ground truth.

`bin/heimdall-cost-forensics` productionizes that class of analysis into a
zero-config tool any Claude Code user can run against **their own** local
session transcripts. This doc describes the tool, its methodology, and an
honest read-only sanity check of its output against this repo's own
previously-published figures.

## What it computes

Given a set of transcript roots (default: `~/.claude/projects`, i.e. every
project on the machine — not one hardcoded repo), the tool:

1. Sums input / cache-read / cache-create (5m + 1h TTL) / output tokens, and
   their **dollar shares** — not just token shares. Token share overstates
   cache-read's true cost weight (billed at 0.1× input) and understates
   cache-create's (billed at 1.25–2.0× input); see "Pricing source" below.
2. Reports mean/p50/p90/p99 context size per request and mean cost/request
   at that context.
3. Ranks cost levers (the token fields, ranked by their own dollar
   contribution) for the specific corpus scanned.
4. Attempts the same high-vs-low-context comparison that produced this
   repo's own "6.17× cheaper per request" finding — gated by sparse-data
   guards (below) so it never reports a ratio built on noise.

## Methodology

- **Dedup by `message.id`.** One API request is serialized as multiple JSONL
  lines (one per content block: `thinking`/`text`/each `tool_use`), and every
  line repeats the identical `message.usage` object. Summing every
  usage-bearing line — which `bin/heimdall-tokens:290`'s `sum_session` does —
  overstates every total by roughly the block-count-per-request factor (this
  repo has directly measured that inflation at ~2.3× on a sampled file; see
  `token-spend-forensics.md`'s "Method" section). `heimdall-cost-forensics`
  instead follows `token-spend-forensics.py:iter_requests`'s pattern: one
  counted request per distinct `message.id`, deduped per source file.
- **Per-model, per-field exact pricing**, never a blended/approximate rate.
  Every model on the current Claude lineup prices output at exactly 5× its
  own input price, cache-read at 0.1×, cache-write at 1.25× (5m TTL) or 2.0×
  (1h TTL) — see `2026-09-02-input-context-cost.md` §1.2 for the full table
  this tool's `PRICING` dict is sourced from. The tool applies each request's
  *own* model's rates to that request's own tokens and accumulates exact
  per-field dollars, rather than assuming one model for the whole corpus (the
  simplification `token-spend-forensics.md` explicitly notes it took: "Prices
  are Anthropic first-party list prices, applied uniformly at the Opus 5
  tier").
- **Cache-creation fallback.** `usage.cache_creation.ephemeral_5m_input_tokens`
  / `ephemeral_1h_input_tokens` is preferred; when a record carries only the
  flat legacy `cache_creation_input_tokens` field (no nested breakdown), the
  tool assumes 5m-TTL pricing and flags the tokens as `fallback`, rather than
  silently dropping that spend the way a nested-only reader would.

## Pricing source

`claude-api` skill pricing table, cached 2026-06-24: input/output/cache-read/
cache-write-5m/cache-write-1h rates per model, keyed by bare model id (a
trailing `-YYYYMMDD` dated-snapshot suffix is stripped before lookup). If a
model's rate is unknown or partially unknown (e.g. Claude Mythos 5.1's
cache-read rate was unconfirmed at launch), the tool prints the token
breakdown for that model and states plainly that dollar figures need a rate
table — it never invents a price. Tested directly: `test/heimdall-cost-
forensics.test.sh` §6 (fully unknown model) and §7 (known model, one
partially-unknown field).

## Privacy guarantee, and how it's tested

The tool reads only `message.id`, `message.model`, `message.usage`, and the
record timestamp. It never reads or prints `message.content`, tool
inputs/outputs, file contents, or any other prompt/transcript text. It never
sends anything anywhere (no network calls anywhere in the tool), never
requires a key, and never writes outside a path the caller names (stdout, or
a caller-redirected file).

This is proven, not just asserted: `test/heimdall-cost-forensics.test.sh` §3
plants a distinctive secret-looking string
(`SECRET_TOKEN_DO_NOT_LEAK_xyz789`) inside a `thinking` block of a synthetic
fixture transcript, then §4 runs the tool against that fixture in both text
and `--json` modes and asserts the string is absent from stdout, stderr, and
the JSON output file in every mode.

## Honest degradation on sparse data

This repo has already been burned by an n=10 figure that turned out to be
sampling noise (`test/heimdall-caveman-eval.test.sh`; commit `fb8bd95` grew
that corpus from n=10 to n=30 after measuring 20–46% stdev at n=10). The
high-vs-low-context regime comparison applies the same caution, gated by
three sequential guards, each surfacing its own honest reason string rather
than a number built on too little data:

1. Fewer than `--min-requests` (default 30) distinct requests total → "not
   enough data," full stop.
2. Quartile groups (bottom/top) smaller than 5 requests each → "quartile
   groups too small."
3. High-context group's mean context is less than 2.0× the low-context
   group's mean → "spread too small to be a meaningful regime comparison."

Only past all three does it report a ratio. Tested directly: `test/heimdall-
cost-forensics.test.sh` §5 proves both the pass case (40-request fixture,
5× engineered spread) and, in the same section, that raising
`--min-requests` above the fixture's request count flips the same data back
to "not available" — proving the flag is load-bearing, not merely accepted.

## Wiring and reachability

Wired into the `bin/heimdall` dispatcher as `hmd cost-forensics`, following
the existing `caveman-audit` case-arm pattern (`bin/heimdall`, case arm
`cost-forensics)`). Named `heimdall-cost-forensics` rather than the more
obvious `heimdall-cost-report` to avoid colliding with the existing
`bin/heimdall-cost-report` (an unrelated tool governing hmd's own GCP infra
spend, not Claude API token spend).

Confirmed reachable, not dead-on-arrival — a fate this repo has recorded for
six other tools before this one:

```
$ bin/heimdall-deadcode --why heimdall-cost-forensics
REACHABLE  bin/heimdall-cost-forensics <- bin/heimdall [REACHABLE] <- <entry-point>
```

## Test coverage

`test/heimdall-cost-forensics.test.sh`, hermetic (all fixtures synthesized
under `mktemp -d`, the operator's own real transcript history is never read
by the test): **54 assertions, 0 failures.**

```
RESULT: 54 passed, 0 failed
```

Sections: `--help` text asserts the privacy/pricing claims are actually
printed (§1); an empty root produces an honest empty result, not an error
(§2); a known fixture with hand-computable totals proves exact dedup +
fallback-field + per-field-dollar arithmetic (§3); the secret-string privacy
proof (§4); a 40-request fixture proves the regime comparison's arithmetic
and its `--min-requests` gate (§5); a fully-unknown model degrades honestly
(§6); a known model with one partially-unknown price field degrades
honestly on just that field (§7); `--root` / `HMD_COST_FORENSICS_ROOT`
precedence, proving the env var can't leak the operator's real default root
into a test (§8); CLI error handling (§9).

## Real-transcript sanity check (read-only, this repo's own history)

Run read-only against this repo's own main-checkout transcript directory —
a single literal path, no glob, no shell array:

```
$ bin/heimdall-cost-forensics --root /Users/rj/.claude/projects/-Users-rj-Downloads-heimdall --json
```

Scope: 840 transcript files (132 at the top level, the rest in nested
per-session subdirectories — reconciled against `find ... -name '*.jsonl' |
wc -l`), 835 contributing sessions, 35,963 deduped requests, spanning
2026-07-16 through 2026-09-06. This is the **main checkout's own transcript
directory only** — it deliberately excludes the ~190 `--claude-worktrees-
agent-*` sibling directories (one per isolated subagent worktree) to keep
this a single, plain, literal `--root` argument rather than a shell
glob/array (a worktree-isolation sandbox in this session rejects git-adjacent
commands built from runtime-computed arguments, so a hand-enumerated
multi-root invocation was avoided rather than fought). `token-spend-
forensics.md`'s $1,103.05 figure, for contrast, scanned the main dir **plus**
141 worktree-agent dirs over a narrower 2026-07-14→2026-08-07 window — so the
totals below are not a like-for-like $ comparison, only a like-for-like
**shape** comparison (cost shares, which `2026-09-02-input-context-cost.md`
§1.2 establishes are model-mix-independent).

| Finding | This run (main checkout, 07-16→09-06, n=35,963) | Prior doc | Agreement |
|---|---|---|---|
| Cache-read is the largest single dollar-share field | **51.51%** ($2,276.37 of $4,419.58) | 46.10–56.29% (`2026-09-02-input-context-cost.md` §1.3, TTL-sensitivity range) | **Yes** — lands inside the prior range |
| Combined cache read+create dominates cost | **94.62%** ($4,181.78 of $4,419.58) | 93.17–94.41% (same doc, same TTL range) | **Yes** — within 0.2 points of the top of the prior range |
| Output is a small single-digit cost share | **4.86%** ($214.73) | 7.9% (`token-spend-forensics.md`, 234-session corpus) / 6.64% or 5.44% (`2026-09-02-input-context-cost.md`, TTL-dependent) | **Same order of magnitude**, this run's figure is somewhat lower — expected, given a different window and a much wider model mix (7 models here vs. a 3-model near-uniform-priced blend there) |
| High-context requests cost several-fold more per request than low-context ones | **5.19×** (quartile method: top-quartile mean context 365,562 → $0.2965/req, n=8,990; bottom-quartile mean context 49,792 → $0.0572/req, n=8,745) | **6.17×** (`token-spend-forensics.md`: two specific days, 731,707 vs 118,678 mean context, all-request comparison, not quartiles) | **Same class of finding, same order of magnitude** — different methodology (whole-corpus quartiles vs. two hand-picked days) explains the numeric gap; neither is "the" definitive ratio, both say the same thing: operating at high context costs several times more per request |

**One correction to the record, found while sourcing this comparison**: an
earlier draft of this doc's brief cited "output = 0.22% of spend" as a known
figure to reproduce. That number does not exist in either
`token-spend-forensics.md` or `2026-09-02-input-context-cost.md`. It traces
to `docs/analysis/2026-08-22-reasoning-bank-wiring-decision.md:51`
(`0.2225%`), which measures a completely unrelated quantity — an unwired
reasoning-bank mechanism's call volume as a percentage of average session
tokens, not output's share of dollar spend. The verified output-cost-share
figures are 7.9% / 6.64% / 5.44%, per the table above; this run's 4.86% is
compared against those, not against the unrelated 0.2225% figure.

**Verdict**: the tool reproduces this repo's own previously-published
findings' **shape** — cache-read (and combined cache read+create) dominant,
output a small single-digit share, high-context operating points several-
fold more expensive per request — on an independently-scoped run (different
window, different root set, exact per-model pricing instead of a uniform
Opus-5 approximation, 7 distinct models instead of 3). It does not reproduce
exact dollar totals, because the scope genuinely differs — that is the
expected, honest outcome of a portability check, not a discrepancy to
explain away.

## Deviations from the original brief

- Tool named `heimdall-cost-forensics`, not the suggested
  `heimdall-cost-report` — collision avoidance, see "Wiring and
  reachability" above.

Related: [`token-spend-forensics.md`](token-spend-forensics.md),
[`2026-09-02-input-context-cost.md`](2026-09-02-input-context-cost.md).

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
