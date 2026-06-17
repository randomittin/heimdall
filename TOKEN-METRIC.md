# Token Metric — the model-token accounting substrate (`bin/heimdall-tokens`)

The token metric answers one question per `hmd`/`claude` run, with numbers
**measured** from the run's own data — never invented:

> **How many model tokens did this run actually consume, broken down by kind?**

It is the *tiktoken-substrate* from the tooling spec: the real model-token usage of
a run, GENERAL by design. It is consumed by:

- the **S-6 C3 sweep** now (`bin/heimdall-s6-sweep` `do_spend` — the cap source),
- **P3** later, and
- the **~75%-savings claim** (the canonical figure behind the headline).

It is **NOT** a C3-only hack.

---

## The two no-API-key sources (confirmed under Max auth)

A real API key is **not** required. Per-run token usage is available from two
places, both of which `heimdall-tokens` reads:

1. **Session transcript JSONL** — the authoritative source for the FULL
   orchestrator `hmd` path (which writes plain stdout, no JSON). Every assistant
   turn in `~/.claude/projects/<cwd-slug>/<session_id>.jsonl` carries:

   ```
   message.usage{input_tokens, output_tokens,
                 cache_creation_input_tokens, cache_read_input_tokens}
   ```

   `heimdall-tokens session <jsonl>` (or `session --cwd <dir>` to resolve the
   newest transcript for that cwd's slug) sums every assistant turn.

2. **`claude -p --output-format json` blob** — the single-shot path. Carries a
   top-level `.usage{...}` + `.total_cost_usd`. `heimdall-tokens json <file-or-->`
   extracts the same record.

`ccusage` is **not** a dependency (not installed). `bin/heimdall-ledger` is the
coordination ledger — **not** tokens — and is not used as the spend source.

The cwd-slug is derived as: **every non-alphanumeric character of the absolute
cwd path replaced with `-`** (so `/Users/rj/Downloads/heimdall` →
`-Users-rj-Downloads-heimdall`; a `.worktrees` segment yields `--worktrees`
because both the `.` and the `/` map to `-`). Verified against the real
`~/.claude/projects/` directory naming.

---

## Definition

Both modes emit one JSON record:

```json
{
  "input_tokens":           <int>,
  "output_tokens":          <int>,
  "cache_creation_tokens":  <int>,
  "cache_read_tokens":      <int>,
  "total_tokens":           <int>,   // = input + output + cache_creation + cache_read
  "turns":                  <int>,   // assistant turns summed (session mode)
  "session_id":             <str|null>,
  "total_cost_usd":         <float|null>,
  "note":                   <str>,   // present when cost is null (honesty note)
  "error":                  <str>    // present only on a degraded record
}
```

```
total_tokens = input_tokens + output_tokens
             + cache_creation_tokens + cache_read_tokens
```

This is **full consumption** — every token the model processed, including cache
traffic — and is therefore **conservative** (it can only over-count spend, never
hide it).

---

## The pinned definition (awaiting RJ's final confirm)

Per the orchestrator's pinned definition, **CONFIRM pending RJ**:

- **The 600k sweep cap is enforced on `total_tokens`**
  (`input + output + cache_creation + cache_read` — full consumption,
  conservative). The sweep's hard cap fail-closes on this exact figure.
- **The comparable headline "spend-per-task" is `total_cost_usd`.**

> ⚠️ **METRIC DEFINITION AWAITS RJ'S FINAL CONFIRM**: cap-on-`total_tokens`
> (implemented here, conservative) **vs** cap-on-`total_cost_usd`. Both figures
> are reported, so flipping the cap source is a one-line change and nothing is
> hidden in the meantime.

Every component is reported in the record so **nothing is hidden** regardless of
which figure becomes the headline.

---

## The cache-dominance caveat

In practice **`cache_read_tokens` dominates** `total_tokens` by a wide margin: an
`hmd` run re-reads a large cached prompt prefix on nearly every turn, so cache-read
traffic vastly exceeds fresh input/output tokens.

Consequences, stated plainly so the number is never mis-read:

- A large `total_tokens` is **expected** and is mostly cache-read — it is *not*
  evidence of a runaway run.
- Because cached input is billed at a steep discount, `total_cost_usd` does **not**
  scale linearly with `total_tokens`. The two figures answer different questions:
  `total_tokens` bounds *consumption* (the conservative cap); `total_cost_usd`
  bounds *dollars* (the headline). **Report and compare them separately.**
- Any "~75% savings" claim must state which figure it is measured on. Savings on
  `total_cost_usd` (dollars) and savings on `total_tokens` (consumption) are
  different numbers; conflating them is the trap this caveat exists to prevent.

---

## Honesty & fail-open contract

- **Tokens are always measured**, never fabricated. A bad/missing value in the
  source counts as 0; it is never invented.
- **Cost is summed only from per-turn cost fields actually present** in the data.
  When the source carries no cost (the typical transcript), `total_cost_usd` is
  `null` + a `note` — **never** a derived-from-a-price-table guess. (The single-
  shot `json` path *does* carry an authoritative `total_cost_usd`, which is used
  verbatim.)
- **Fail-open**: a missing or malformed transcript yields a *degraded* record
  (all zeros + an `error` note) and exit 0. The consumer (the sweep) must fail
  open like the rest of the pipeline — the meter never aborts a run.

---

## Usage

```sh
# sum a session transcript
heimdall-tokens session ~/.claude/projects/<slug>/<session_id>.jsonl

# resolve + sum the newest transcript for a run's cwd
heimdall-tokens session --cwd /path/to/repo [--since <epoch>] \
                        [--projects-root ~/.claude/projects]

# parse a `claude --output-format json` blob (file or stdin)
claude -p --output-format json "..." | heimdall-tokens json -
heimdall-tokens json result.json
```

Wired into `bin/heimdall-s6-sweep` `do_spend`: after `do_hmd` runs in the repo
dir, the runner resolves that run's session transcript (`heimdall-tokens session
--cwd <repo_dir>`), uses `total_tokens` as the fail-closed cap figure, and records
the full breakdown (`token_usage`) in the per-repo result JSON for provenance — so
the sweep report shows **real measured spend, not 0**.

Self-tested deterministically on synthetic fixtures: `test/heimdall-tokens.test.sh`
(9 assertions) and the `(k)/(k2)/(l)` assertions in `test/s6-sweep.test.sh`.
