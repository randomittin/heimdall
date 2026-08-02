# Heimdall S-6 Component 3 — Popular-10 Cold Generalization Run

**Proposal for sign-off. Status: NOT YET RUN. Zero tokens spent. Read-only research + design.**

This document proposes the 10 repos, the 10 reuse-friendly tasks, the pre-committed
interpretation bands, the spend staging, and the measurement risks for the S-6 C3
breadth proof. **Nothing here runs until RJ signs off on repos + tasks + bands.**

> The deliverable of C3 is an **honest reuse-% distribution and a working-output
> rate across 10 cold OSS repos** — not a green check. A low or uneven result is a
> *finding that redirects the roadmap*, not a number to massage. See §3.

---

## 0. Grounding: what the reuse metric can actually measure today

This is the single most important constraint on repo selection, and it is a fact
about the current code, not a preference:

`bin/lib/reuse_analyzer.py` robustly parses **exactly three stacks**:

| Stack | Support | Source of truth |
|-------|---------|-----------------|
| JS / TS / JSX / TSX (`.js .jsx .mjs .cjs .ts .tsx`) | robust regex heuristic | `JS_TS_EXT`, `reuse_analyzer.py:55` |
| Python (`.py`) | **exact** (`ast` parse) | `PY_EXT`, `reuse_analyzer.py:56` |
| Shell (`.sh .bash`, shebang) | function/source resolution | `SH_EXT`, `reuse_analyzer.py:57` |

**Every other language** (Go, Rust, Ruby, Java, C, …) is listed under
`unsupported_files` and the record carries `reuse_pct: null`,
`reason: "unsupported-language"` (`reuse_analyzer.py:512`). The metric **never
invents a percentage for a language it cannot parse** — that is by design and is
the honest behavior.

A tree-sitter AST + tiktoken analyzer upgrade is **in-flight** (async agent launched
2026-06-17 09:15, not merged to `main` as of this proposal — `grep -c '\.go|\.rs'
reuse_analyzer.py` = 0). If that upgrade lands before the C3 sweep, the Go/Rust
probes below graduate from working-output-only to fully reuse-measured. **This
proposal is written against `main` as it stands today** and flags every place the
upgrade would change the picture.

### Design consequence (the core tension, resolved)

The spec asks for "varied languages/stacks". The analyzer can only *measure reuse*
on three of them. Picking 10 Go/Rust repos would yield a distribution of mostly
`null` — a non-result. So the 10 are deliberately split:

- **8 reuse-measured repos** — 5 JS + 3 Python — these produce a **real `reuse_pct`**
  and are the spine of the C3 verdict.
- **2 working-output-only probes** — Go (`cobra`) and Rust (`anyhow`), the "varied
  stack" representatives. For this pair the honest expectation is `reuse_pct: null`
  *today* (unsupported language); they still produce a runnable **working-output**
  signal (their test suite passes or fails), which is itself a generalization data
  point. They are flagged `reuse_measured: false` in the JSON so they are **excluded
  from the reuse-% median** and counted only in the working-output rate. This is the
  honest split, not a fudge.

The C3 verdict's reuse-% median is computed over the **8 reuse-measured repos only**
(7 if any one fails wave-0 preflight). The working-output rate is computed over **all
10**. Both numbers are reported; neither is allowed to borrow strength from the
other.

---

## 1. The 10 candidate repos

Selection criteria, all required: small (cloneable + buildable in minutes),
popular (real-world relevance), **permissively licensed** (MIT / Apache-2.0 / BSD —
cited below), an **existing test suite or build** (so "working output" is runnable
evidence, not self-report), and a **multi-module shape with reusable internals** (so
a reuse-friendly task is even possible — a single-file util has nothing to reuse).

> **License note:** licenses below are cited from each project's well-known,
> long-stable licensing. The runner harness MUST, as wave-0 of the sweep, re-verify
> the `LICENSE` file of the pinned commit before any task runs (acceptance check
> `license-verify` in the JSON). A license that has changed since this proposal
> **drops that repo and is replaced from the bench (§1.1)** — we do not run a task
> against a repo whose permissive license we have not re-confirmed at the pinned SHA.

### Reuse-measured spine (8 — 5 JS + 3 Python)

| # | Repo | Lang | License | ~Size | Why it is a good generalization probe |
|---|------|------|---------|-------|----------------------------------------|
| 1 | **sindresorhus/slugify** (github.com/sindresorhus/slugify) | JS (ESM) | MIT | ~300 LOC + AVA | Tiny single-purpose util with a clear internal `slugify` core + a built-up `replacements` map. An "add an option" task obviously extends the existing core. AVA suite = runnable truth. *(dry-run repo)* |
| 2 | **sindresorhus/p-map** (github.com/sindresorhus/p-map) | JS (ESM) | MIT | ~200 LOC + AVA | Concurrency util exporting `pMap` + `pMapSkip`. A variant task must reuse the existing iterator/concurrency machinery, not rewrite it. Probes whether `hmd` reuses async control flow vs reinventing it. |
| 3 | **chalk/wrap-ansi** (github.com/chalk/wrap-ansi) | JS | MIT | ~200 LOC + AVA | Depends on `string-width`/`ansi-styles`; internal `wordLengths`/`wrapWord` helpers. A wrapping-option task reuses the existing tokenizer. |
| 4 | **tj/commander.js** (github.com/tj/commander.js) | JS | MIT | ~2.5k LOC + Jest | Canonical CLI; `Command`/`Option`/`Argument` classes. A small option-parsing feature must extend `Option`/delegate to existing `Command` methods. Deliberately **sprawling** — tests reuse when the surface is big (contrast with the tiny utils). |
| 5 | **sindresorhus/yocto-queue** (github.com/sindresorhus/yocto-queue) | JS (ESM) | MIT | ~80 LOC + AVA | Tiny linked-list `Queue` (`enqueue`/`dequeue`/`#head`). A `peek()` task must reuse the existing head-node tracking, not re-implement the list. |
| 6 | **kennethreitz/records** (github.com/kennethreitz/records) | Python | ISC (BSD-equiv permissive) | ~600 LOC + pytest | `Record`/`RecordCollection`/`Database` classes — textbook reuse target. An export-format task must call existing `Record.as_dict()` / `RecordCollection` iteration. *(dry-run repo)* |
| 7 | **psf/cachecontrol** (github.com/psf/cachecontrol) | Python | Apache-2.0 | ~1.5k LOC + pytest | `CacheController` + `BaseCache` + adapters. An add-a-backend task subclasses `BaseCache` — extension is the *correct* solution, an ideal reuse probe. |
| 8 | **jmespath/jmespath.py** (github.com/jmespath/jmespath.py) | Python | MIT | ~1k LOC + pytest | `Lexer`/`Parser`/`TreeInterpreter` + a `functions.py` registry. An add-a-builtin task reuses the `@signature` decorator + function registry — a precise reuse target with a compliance suite. |

### Working-output-only probes (2 — varied stack, reuse `null` today)

| # | Repo | Lang | License | ~Size | Why included / honest expectation |
|---|------|------|---------|-------|------------------------------------|
| 9 | **spf13/cobra** (github.com/spf13/cobra) | **Go** | Apache-2.0 | large | The "varied stack" representative. **`reuse_pct: null` today** (Go unsupported). Still yields a working-output signal: `go test ./...`. Graduates to reuse-measured iff the tree-sitter upgrade lands first. Flagged `reuse_measured:false`. |
| 10 | **dtolnay/anyhow** (github.com/dtolnay/anyhow) | **Rust** | MIT OR Apache-2.0 | ~2k LOC + cargo tests | Rust representative. **`reuse_pct: null` today** (Rust unsupported). Working-output via `cargo test`. Small enough to build fast. Flagged `reuse_measured:false`. *(Bigger Rust CLIs — ripgrep, clap, cargo — were rejected as too large/slow to build inside the per-task budget.)* |

### 1.1 Bench (drop-in replacements if a license re-check fails or a repo won't build at the pinned SHA)

- JS: `chalk/ansi-styles` (MIT)
- Python: `pallets/click` (BSD-3-Clause), `psf/requests` (Apache-2.0, larger)
- Shell: `nvm-sh/nvm` (MIT) — adds a measured-Shell data point if a JS repo drops

> **Final running set = the 8 reuse-measured spine + cobra + anyhow
> (working-output-only) = 10.** The "varied stacks" requirement is met:
> JS (5), Python (3), Go (1), Rust (1). Domains vary: string util, async-control
> util, terminal-rendering util, queue util, DB-records lib, HTTP-cache lib,
> query-language interpreter, CLI framework (×2 incl. Go), error lib (Rust). Not 10
> of the same kind.

---

## 2. The 10 tasks — each C2-shaped, with reused symbols + runnable acceptance

**The crux (per planning guidance):** every task is one a maintainer might actually
assign, where the *obvious* competent-dev solution is to **call / extend existing
repo symbols** — never greenfield (greenfield trivially scores low and teaches
nothing). For each: the exact prompt for `hmd`, the named existing symbols the
correct solution should reuse, and a **runnable acceptance check** (their suite / a
build / a specific assertion) — never self-report.

> Acceptance for working-output is **runnable evidence per R7**: the harness runs
> the repo's own test/build command at the pinned SHA on a clean checkout BEFORE
> the task (baseline must be green), then again AFTER `hmd`'s diff. Working-output =
> baseline-green → still-green (no regression) AND the new behavior's targeted
> assertion passes.

> **v2 (post-audit):** 6 of these 10 tasks were swapped after two adversarial audits
> flagged them as degenerate/gimme (the no-SHA-pin root cause let depth-1 clones drift
> to HEAD where some of the original features had already shipped). Every task below is
> SHA-pinned and was validated at its pinned commit: the NEW symbol it adds is absent
> and the named REUSE TARGET is present. See **§8 Post-audit revision (v2)**. The
> machine-readable manifest (`…-C3-repos.json`) carries the SHAs and per-repo
> `validation_at_sha` evidence. Swapped: slugify, wrap-ansi, yocto-queue, commander,
> records, anyhow. Kept (tightened): jmespath, cobra. Kept as-is: p-map, cachecontrol.

| # | Repo | pinned SHA | `hmd` task prompt | Existing symbols the correct solution reuses | Runnable acceptance check |
|---|------|-----------|-------------------|----------------------------------------------|---------------------------|
| 1 | slugify | `7c318bd` | "Add a `maxLength` option to `slugify` that truncates the final slug to at most N characters without leaving a trailing separator." | the `slugify()` pipeline + `removeMootSeparators(string, separator)` | `npm test` (xo+ava) green AND added AVA case `slugify('foo bar baz', {maxLength:7}) === 'foo-bar'` |
| 2 | p-map | `65aaa8f` | "Add a `pMapValues` helper that maps over an object's values with the same concurrency control as pMap and returns a new object." | `pMap` itself (must call it, not reimplement the concurrency loop), `pMapSkip` | `npm test` green AND added case: `pMapValues({a:1,b:2}, async v=>v*2, {concurrency:1})` resolves `{a:2,b:4}` |
| 3 | wrap-ansi | `f72a834` | "Add an `ellipsis: true` option that, in hard-wrap mode, replaces the wrapped overflow of a long word with a single trailing `…` on the first row instead of breaking it across rows." | `wrapWord(rows, word, columns)` + `stringWidth` | `npm test` green AND a case asserting a too-long word under `{hard:true, ellipsis:true}` ends in `…` at column width with ANSI intact |
| 4 | commander.js | `ba6d13d` | "Add a `Command#requiredOptionWithDefault(flags, description, defaultValue)` registering a mandatory option satisfied if either the user supplies it OR the default applies, validated during parse." | `_optionEx` / `createOption` / `makeOptionMandatory` + `_checkForMissingMandatoryOptions` | **`node --test`** green AND added `tests/*.test.js` asserting accepted-when-only-default-present + errors-when-neither |
| 5 | yocto-queue | `b07eac0` | "Add a `dequeueMany(count)` method that removes and returns up to `count` values from the head as an array, reusing existing dequeue semantics and keeping `size` consistent." | `dequeue()`, `#head`/`#size` | `npm test` (ava+tsd) green AND AVA case: enqueue a,b,c → `dequeueMany(2)` deep-equals `['a','b']`, `size===1`, `peek()==='c'` |
| 6 | records | `ea42736` | "Add a `RecordCollection.distinct(*columns)` returning a new `RecordCollection` of rows unique on the given column values, reusing existing row access." | `Record.__getitem__`/`Record.keys`, `__iter__`/`all()`, re-wrap `RecordCollection(iter(rows))` | `pip install -e . && pytest` green AND test: `Database(...).query('select 1 as a union all select 1 as a').distinct('a')` yields one row |
| 7 | cachecontrol | `495b215` | "Add an in-memory LRU cache backend with a max-entries cap by subclassing the existing base cache." | `BaseCache` (must subclass), the `DictCache` pattern, controller wiring | `pytest` green AND added test: the LRU backend evicts past the cap and satisfies the `BaseCache` interface (get/set/delete) |
| 8 | jmespath.py | `2812594` | "Add a built-in `to_upper` so that the JMESPath expression `to_upper(@)` returns the uppercased form of a string argument." *(reworded: behavior only — no longer names the function-registry mechanism)* | the `@signature` decorator + the function-registration machinery (`Functions`, `TreeInterpreter`) — discovery is part of the probe | `pytest` green AND added case: `search('to_upper(@)', 'abc') == 'ABC'` |
| 9 | cobra (Go) | `ad460ea` | "Add a `Command.AliasFor(name)` helper that returns the canonical command an alias resolves to, reusing the existing alias lookup." | existing `Command.Find` / `Aliases` fields | `go test ./...` green AND added Go test: a root command with one **direct child** whose `Aliases` include `co` → `AliasFor('co')` returns that child *(single-level alias only — no nested subcommands)*. **reuse_pct null today.** |
| 10 | anyhow (Rust) | `841522b` | "Add `Context::context_with_code<C>(self, code: i32, context: C)` attaching a numeric code + message, reusing the existing context-attachment machinery so the message still appears via `{:#}` and the chain is walkable via `Error::chain`." | `Error::context` / `ContextError` plumbing | `cargo test` green AND test asserts `format!("{:#}", err)` contains the message AND `err.chain().count()` increased. **reuse_pct null today.** |

> **Why these are reuse-friendly *and* realistic (the planning crux):** each adds a
> small, plausible feature whose correct shape is "thread through / subclass / call
> the thing that already exists." A `pMapValues` that reimplements concurrency, an
> LRU that doesn't subclass `BaseCache`, a `to_upper` that bypasses the registry —
> each is a *worse* solution a maintainer would reject in review. So a low reuse_pct
> here is a genuine signal that `hmd` reinvented when reuse was the obviously-correct
> path — exactly what C3 is meant to measure.

> **Falsifiability of the reuse signal:** the C2 fixture (`test/reuse-mini-git.test.sh`)
> already proves the metric distinguishes a reuse solution (≥0.60) from a
> reinvention solution (<0.30) on a controlled diff. C3 is the *cold breadth*
> extension of that proven instrument; we are not asked to re-prove the metric, only
> to apply it. (The metric's own falsification lives in C2 and `reuse-metric.test.sh`.)

---

## 3. Pre-committed interpretation bands (decided BEFORE any results)

These thresholds are committed **now**, before a single token is spent, so the
verdict cannot be rationalized after seeing the numbers. Two axes are graded
jointly: **median reuse_pct over the 8 reuse-measured repos** and **working-output
rate over all 10**.

| Verdict | Median reuse (8 measured) | Working-output rate (10) | Distribution shape | Meaning & action |
|---------|---------------------------|--------------------------|--------------------|------------------|
| **GENERALIZES** → proceed to features (F2–F6) | **≥ 0.45** | **≥ 7/10** | no measured repo < 0.20; ≥4 of 8 ≥ 0.40 | Reuse is real and broad on cold repos; the core thesis holds. Forward features unlock. |
| **MIXED** → core needs targeted work | **0.30 – 0.44** | **5/10 – 6/10** | OR a bimodal split (tiny-util repos high, sprawling repos low) | Reuse works on simple surfaces but degrades on sprawl or specific stacks. **Do targeted work on the weak cell (likely: large-repo symbol discovery) before features.** Not a stop, a redirect. |
| **CORE GAP** → redirect roadmap, fix reuse first | **< 0.30** | **< 5/10** | OR ≥3 measured repos producing `suspected_duplicates` for the named target symbol | The core reinvents on cold repos — the central S-6 risk. **Halt feature work; the roadmap becomes "make cold-repo reuse real."** This is the highest-value finding C3 can produce. |

### Justification of each threshold

- **GENERALIZES median ≥ 0.45.** C2's *controlled, maximally-friendly* task scores
  ~1.0 and its floor is 0.60. Cold repos are harder (real symbol discovery, larger
  surface, no curation), so demanding 0.60 cold would be miscalibrated. 0.45 means
  "on a task we *engineered* to be reuse-friendly, the median cold solution reuses
  pre-existing code in nearly half its new units" — a defensible bar for "the core
  reuses in the wild." The `no measured repo < 0.20` guard prevents one strong
  outlier from carrying a weak field.
- **MIXED 0.30–0.44.** 0.30 is exactly C4's halt floor — below it, `hmd` itself
  would hard-warn "likely reinventing." So a median in [0.30, 0.45) means "above the
  self-halt line but below confident generalization": the tool isn't reinventing on
  average, but isn't reliably reusing either. The bimodal clause catches the most
  likely real outcome (utils good, sprawl bad) and names the fix target.
- **CORE GAP < 0.30.** A cold median under the self-halt floor means the median cold
  task would *trip Heimdall's own low-reuse halt*. That is, by the product's own
  dogfooded definition, reinvention. Shipping forward features on that base is
  building on the unproven core S-6 exists to test. The `suspected_duplicates ≥3`
  clause is an independent corroborator: if the metric is actively naming the
  pre-existing symbol the solution duplicated, that is direct evidence of
  reinvention, not just low reuse.
- **Working-output gate (≥7/10) is independent of reuse** and can veto: a high
  reuse median with low working-output (code that reuses but doesn't *run*) is still
  not generalization. Both axes must clear for GENERALIZES.

### A low result is a FINDING, not a failure

Stated explicitly and committed: **if C3 lands in MIXED or CORE GAP, that is the
deliverable working as designed.** It productively redirects the roadmap away from
F2–F6 polish and onto the proven-weak cell of the core. Per the S-6 spec: "a failed
S-6 is more valuable than a faked pass." We do not massage, re-pick easier repos
post-hoc, or move the bands after seeing numbers. The bands above are frozen at
sign-off.

---

## 4. Spend staging + hard cap

**The cap is a ceiling, not a target. Fail-closed.**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **Hard total cap** | **600,000 tokens** across all 10 | The S-6 spec's suggested ceiling. Fail-closed: the harness aborts the sweep the instant cumulative spend crosses 600k, leaving completed-repo records intact. |
| **Per-task budget (provisional)** | **~60,000 tokens** | 600k / 10. **Provisional** — the dry run replaces this with a measured figure. |
| **Per-task hard kill** | **90,000 tokens** | 1.5× provisional. A single repo cannot consume the field's budget; it is killed and recorded as `incomplete: budget`. |

### DRY-RUN-FIRST protocol (mandatory gate before the full sweep)

```
Stage A — DRY RUN (1–2 repos):  run repo #1 (slugify) + #5 (records).
          These are the smallest measured JS + Python repos → cheapest, fastest,
          and they exercise both measured-language paths.
          MEASURE: real tokens/task, wall-clock, baseline-green confirmation,
          and that a reuse record actually emits with a non-null reuse_pct.
          Then STOP. Emit a Stage-A report (2 records + measured cost-per-task).

Stage B — RJ APPROVES against measured cost. RJ sees:
          "Dry run: slugify=X tok, records=Y tok. Extrapolated full-10 ≈ Z tok
           vs 600k cap. Proceed? / adjust set? / abort?"
          No Stage B without explicit RJ go.

Stage C — FULL SWEEP (remaining 8) only on RJ approval, under the 600k cap,
          fail-closed, per-task hard-kill at 90k. Emit all 10 records +
          the distribution + working-output rate + the §3 verdict.
```

The dry run exists precisely so the 600k figure is **validated against reality**
before the bulk spend, not assumed. If Stage A shows per-task cost would blow the
cap (e.g. cobra/anyhow builds are token-heavy), the working-output-only probes are
the first to drop — they are the lowest-information cells (reuse `null` today).

---

## 5. Risks & biases — what could make C3 misleading

Honest about the measurement's limits. Each risk has a concrete mitigation.

| Risk | Prob | Impact | How it biases the number | Mitigation |
|------|------|--------|--------------------------|------------|
| **Language-coverage bias** — analyzer parses only JS/TS/Py/Shell; Go/Rust → `null` | high (today) | high | The reuse median is computed over the 8 measured repos, none Go/Rust. The "varied stack" claim is *working-output only* for 2 cells. Could overstate generalization (we only measure reuse where we *can* measure it). | Reuse median explicitly scoped to `reuse_measured:true` repos; Go/Rust flagged + excluded from median; loud note that tree-sitter upgrade changes this. Never report a blended median that hides the null cells. |
| **Task-too-easy bias** — tasks engineered reuse-friendly inflate reuse_pct | med | high | A high median may reflect *task curation*, not core strength. | Bands calibrated DOWN from C2's friendly 0.60 to 0.45 to account for engineered-friendliness; the `commander.js` sprawl repo + the working-output gate counter pure-curation reads; report per-repo, not just median, so curation is visible. |
| **Task-too-hard / underspecified** — `hmd` can't find the symbol on a big repo | med | med | Large-repo tasks (commander, cobra) score artificially low → false CORE-GAP. | Tasks name the *area* not the symbol (realistic), but acceptance is a precise assertion; per-task records show whether it failed at discovery vs reuse. Bimodal MIXED band explicitly anticipates large-repo degradation as a *redirect target*, not a verdict-killer. |
| **Heuristic over-credit (JS)** — JS reuse is regex, not AST; a call to a name that *also* exists locally is credited as reuse (documented limit, see C2 reinvention note) | med | med | Could *over*-count reuse on JS repos (false high). | Cross-check: any reuse-credited unit that also appears in `suspected_duplicates` is flagged for manual spot-check on the JS repos; Python (`ast`, exact) repos anchor the median against over-credit. If tree-sitter lands, JS becomes AST-exact too. |
| **Heuristic under-credit** — reuse via an import the body references indirectly, or via inheritance the regex misses | med | med | Could *under*-count reuse (false low → false CORE-GAP). | Manual spot-check the lowest-scoring measured repo before declaring CORE-GAP; never auto-verdict CORE-GAP without eyeballing the diff vs the record. |
| **Repo already maximally-utils'd vs sprawling** — a repo where everything is already a helper trivially yields high reuse; a flat repo yields low | med | low | Distribution shape reflects *repo architecture*, not core skill. | Deliberately mixed the field (tiny utils + sprawling commander/cobra) so shape is interpretable; §3 reads the *shape*, not just the median. |
| **License drift since proposal** | low | med | A repo's license changed → can't legally run | Wave-0 `license-verify` re-checks `LICENSE` at pinned SHA; failure → drop + bench replacement (§1.1). |
| **Baseline not green at pinned SHA** — repo's own suite flaky/broken | low | med | "Working output" check is meaningless if baseline was already red | Harness asserts baseline-green BEFORE the task; a repo that can't go green at HEAD is dropped + bench-replaced (no task run against a red baseline). |
| **Spend overrun** | low (capped) | med | — | 600k hard cap fail-closed + 90k per-task kill + dry-run-validated estimate. |

### Honest summary of the measurement's limits

C3 measures **reuse where the analyzer can parse it (JS/TS/Py/Shell) on tasks we
engineered to be reuse-friendly**, plus a **working-output signal on all 10
including 2 stacks we can't yet measure reuse for**. It does **not** prove reuse on
Go/Rust today, does **not** eliminate JS regex over/under-credit, and its reuse
median is over 8 curated-friendly tasks. The bands are calibrated for exactly those
limits. The number it produces is real and computed from parsed source — but its
*scope* is the scope above, and the report will say so plainly.

---

## 6. What I'm bracing for

Going in wanting the **true** number, not a flattering one. My honest prior: the
field lands **MIXED, bimodal** — the tiny single-purpose utils (slugify, p-map,
wrap-ansi, jmespath) score well (0.4–0.7) because their surface is small and the
reuse target is unmissable, while the sprawling repos (commander.js, and cobra/anyhow
if measurable) score low or `null` because cold symbol-discovery over a large surface
is the genuinely hard part of reuse — finding the *right* existing thing to call in a
2.5k-LOC repo is a different skill than calling an obvious helper in a 200-LOC one. If
that's the shape, the finding is precise and actionable: **the core reuses fine when
the target is obvious and degrades when discovery is hard** — which points the roadmap
at symbol-discovery/retrieval, not generic "improve reuse." I am equally prepared for
CORE GAP (cold median under 0.30, the median task tripping Heimdall's own halt), in
which case feature work stops and the roadmap becomes "make cold reuse real" — and I'd
rather surface that now, pre-launch, than ship features on an unproven core.

---

## 7. Sign-off required BEFORE the dry run

**RJ must approve, before any token is spent:**
1. **The 10 repos** (§1) — including the 7-measured / 2-probe split and the Go/Rust
   `reuse_pct: null`-today honesty.
2. **The 10 tasks** (§2) — C2-shaped, reused-symbols, runnable acceptance checks.
3. **The interpretation bands** (§3) — frozen at sign-off, not movable post-result.
4. **The spend staging** (§4) — dry-run-first, 600k fail-closed cap.

Then: **Stage A dry run (slugify + records) → measured cost report → RJ Stage-B
approval → full sweep.** Not before.

The machine-readable repo+task+acceptance set for the runner harness is at
`docs/superpowers/specs/heimdall-S6-C3-repos.json` (consumed only after sign-off).

---

## 8. Post-audit revision (v2) — honest record of what changed and why

This proposal was revised after **two independent adversarial audits** of the v1 task
set. Both converged on the same conclusion: **6 of the 10 tasks were degenerate or
gimme** — i.e. not real reuse probes — and the underlying cause was structural, not
per-task carelessness.

### 8.1 Root cause: no SHA-pinning

v1 named only repo URLs. The sweep clones `--depth 1`, which resolves to **whatever
`HEAD` is at clone time**. Between proposal-writing and the audit, several of the v1
"add this feature" targets had **already shipped upstream** — so cloning HEAD turned a
real "add X" task into a no-op (X already exists → the "correct solution" is to write
nothing, or the acceptance assertion passes against pre-existing code). A task whose
feature already exists at the cloned commit measures nothing about reuse. This is the
systemic defect: **an unpinned manifest does not describe a fixed, auditable task** —
it describes a moving target.

**Fix (systemic):** every repo in the manifest now carries a full-40-char `"sha"`
field, resolved `2026-06-17` via `git ls-remote <url> HEAD`. The sweep MUST
`clone --depth 1` then `git fetch --depth 1 origin <sha> && git checkout <sha>` so the
audited state is frozen. A `sha_pinning` block documents the protocol; `wave0_preflight`
gains a `sha_checkout` step that aborts a repo if its pinned SHA is unreachable.
*(Runner note: `bin/heimdall-s6-sweep` consumes the manifest; if it does not yet honor
the `sha` field, wiring it in is a follow-up — but the field is captured now so the
audited state is fixed regardless.)*

The 10 pinned SHAs:

| Repo | SHA |
|------|-----|
| slugify | `7c318bd1aa4b4affab29761f15a9604323fe2a3b` |
| p-map | `65aaa8f4d7e757a5254a146c4c39403efa9e2139` |
| wrap-ansi | `f72a8343d4841433930786ae951b240a81bfd3a9` |
| records | `ea4273695cee6da42edf1cb294d1f2a4505470fc` |
| cachecontrol | `495b215d25568432aeb983c31f696447a777b4b5` |
| jmespath.py | `2812594e69d43098ef60f81f4efc404c071b0418` |
| commander.js | `ba6d13ddb4243e5913367734f8c159089ffe7834` |
| yocto-queue | `b07eac099753833b29d06c614149904445739776` |
| cobra | `ad460ea8f249db69c943a365fb84f3a59042d54e` |
| anyhow | `841522b2aa09732fecee40804440d2c35c68c480` |

### 8.2 The 6 swapped tasks (degenerate/gimme → audited (a)-shaped probe)

Each replacement is the reviewers' exact (a)-shaped spec, adjusted only to the manifest
schema (`task_prompt`, `reused_symbols_expected`, `acceptance_cmd`). Each was **validated
at its pinned SHA**: the NEW symbol is absent (so it is a real task) AND the named REUSE
TARGET is present (so reuse is possible). Evidence lives per-repo in the manifest's
`validation_at_sha`.

| Repo | v1 task (why degenerate) | v2 task | New-symbol ABSENT @ SHA | Reuse-target PRESENT @ SHA |
|------|--------------------------|---------|-------------------------|----------------------------|
| slugify | `preserveTrailingDash` — trivial flag, no real pipeline reuse | `maxLength` truncation w/o trailing separator | `grep maxLength index.js` empty | `removeMootSeparators` @ `index.js:15,98`; `slugify()` @ `:46` |
| wrap-ansi | `trim:false` — trivial passthrough | hard-wrap `ellipsis:true` (`…` instead of breaking the word) | `grep -i ellipsis index.js` empty | `wrapWord(rows,word,columns)` @ `:390+`; `stringWidth` @ `:1,242` |
| yocto-queue | `peek()` — one-liner read of `#head` | `dequeueMany(count)` reusing `dequeue()` semantics + size consistency | `grep dequeueMany index.js` empty | `dequeue()` @ `:38`; `#head` @ `:16`; `#size` @ `:18` |
| commander.js | `.mandatoryOption` alias — pure synonym of `requiredOption` | `requiredOptionWithDefault` (mandatory satisfied by user-supplied OR default, parse-validated) | `grep requiredOptionWithDefault lib/*.js` empty | `_optionEx` @ `command.js:732,780`; `createOption` @ `:579`; `makeOptionMandatory`; `_checkForMissingMandatoryOptions` @ `:1237,1598` |
| records | `.as_csv()` — serialize-rows, weak reuse signal | `RecordCollection.distinct(*columns)` re-wrapping a `RecordCollection` | `grep 'def distinct' records.py` empty | `Record.__getitem__` @ `:48`; `Record.keys` @ `:37`; `__iter__` @ `:118`; `all` @ `:195`; `class RecordCollection` @ `:107` |
| anyhow | `Context::with_note` — static-string attach, thin | `Context::context_with_code(code, context)` reusing context plumbing; message via `{:#}`, walkable via `chain()` | `grep -rn 'context_with_code\|with_code' src/` empty | `fn context` @ `context.rs:46,91`; `ContextError` @ `:1,115`; `Error::chain` @ `error.rs:441` |

**No replacement landed on a second degenerate task** — every new symbol was confirmed
absent at its pinned SHA before acceptance.

**Runner correction (commander):** the reviewers asked to "fix the runner field" from
Jest to `node --test`. At the pinned SHA `ba6d13d` the `package.json` `test` script is
**already** `node --test && npm run check:type:ts` — the v1 "Jest" label was itself an
artifact of a drifted clone. The v2 `acceptance_cmd` uses `node --test` (no field needed
fixing; the SHA-pin makes the runner deterministic).

### 8.3 The 4 kept tasks (2 tightened)

- **p-map**, **cachecontrol** — kept verbatim; the audits flagged no issue.
- **jmespath** — *tightened*: prompt reworded to describe only the user-facing behavior
  (`to_upper(@)` uppercases its string argument). It **no longer names the "function
  registry"** mechanism, so symbol discovery (finding `@signature` + the registration
  machinery) is part of the probe rather than spoon-fed. Acceptance unchanged.
- **cobra** — *tightened*: acceptance pinned to a **single-level alias** (a root command
  with one direct child whose `Aliases` include `co` → `AliasFor('co')` returns that
  child), removing the nested-subcommand ambiguity the reviewers flagged.

### 8.4 What did NOT change

- **Interpretation bands (§3) are unchanged and remain frozen** at the original sign-off
  (`locked_unchanged_in_v2: true` in the manifest). The audit corrected the *tasks*, not
  the *grading*; moving the bands in response to a task fix would defeat their purpose.
- The 10 repos, the 8-measured/2-probe split, the Go/Rust `reuse_pct: null`-today
  honesty, the spend staging, and the dry-run-first protocol are all unchanged.
- `yocto-queue` is in the running set and was therefore removed from `bench_replacements`
  (it cannot be both a running probe and its own bench fallback).

The deliverable remains an **honest reuse-% distribution + working-output rate over 10
cold repos**. v2 makes that measurement trustworthy by ensuring all 10 tasks are real
(non-degenerate) probes against frozen commits — not moving targets that may already
contain the feature.

---

## OUT OF SCOPE

- **Running anything.** This is a proposal; no clone, no `hmd`, no token spend.
- **Building the C3 runner harness** — the harness that consumes the JSON is a
  separate post-sign-off plan; this doc specifies its inputs, not its code.
- **Extending the reuse analyzer to Go/Rust** — the tree-sitter upgrade is a
  separate in-flight track; C3 is written against `main` today and merely *flags*
  where that upgrade would change the measured set.
- **Changing the reuse metric definition or the C2/C4 thresholds** — C1/C2/C4 are
  merged and frozen; C3 consumes them as-is.
- **Release/tag machinery** — S-6 is measurement, not a release (per spec boundary).
- **Forward features F2–F6** — gated behind the C3 verdict; out of scope until C3
  returns GENERALIZES.
- **Re-proving the reuse metric itself** — its falsification lives in
  `test/reuse-mini-git.test.sh` + `test/reuse-metric.test.sh`; C3 applies the proven
  instrument, it does not re-validate it.
