# Native symbol graph vs external code-review-graph — Q3 & Q4

Scope: two questions only. Q3 measures whether Tree-sitter multi-language breadth
is needed soon. Q4 judges whether the printed `LIMITATIONS` caveat is sufficient
for gate-feeding use, or whether sampling-falsification is additionally required.

## Q3 — Is Tree-sitter multi-language breadth needed SOON?

**Verdict: NO. 98.42% of code files / 99.64% of code bytes are already indexed by the
native graph. The unresolved remainder is 12 files, 42 KB, and 10 of those 12 are test
fixtures or two small C helpers — zero production call-graph value.**

### What the native graph indexes

`bin/lib/symbolgraph.py:63-77`:

```python
EXT_LANG = {".py": "python", ".sh": "shell", ".bash": "shell",
            ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript"}
SHEBANG_LANG = (("python","python"),("bash","shell"),("zsh","shell"),
                ("sh","shell"),("node","javascript"))
```

Extensionless executables (the whole `bin/` and `hooks/` CLI surface) are classified by
shebang, so they are indexed, not missed.

### Counting method (so a reader can judge it)

- File set = `git ls-files` — this **excludes everything gitignored**, i.e. `node_modules/`,
  `dist/`, `.venv/`, build output, and `.worktrees/`. Nothing vendored is counted.
- Additionally filtered by the graph's own `SKIP_DIRS` (`symbolgraph.py:57-61`:
  `node_modules, dist, build, target, vendor, .venv, .next, coverage, …`) so the census
  and the indexer agree on what "the project" is. 2 tracked files fell in those dirs.
- "Code" = a file whose extension is in a fixed source-extension set (py/sh/js/mjs/cjs/
  ts/tsx/jsx/c/h/go/rs/rb/java/swift/kt/php/pl/lua/sql/cpp/…) **or** an extensionless file
  with a shebang. Markdown, JSON, txt, PNG, fixtures-with-no-extension are not code and
  are excluded from both numerator and denominator.
- Bytes = `os.path.getsize` on the working tree. Symlinks excluded.
- Script: reproducible, imported `EXT_LANG`/`SKIP_DIRS`/`SHEBANG_LANG` directly from
  `bin/lib/symbolgraph.py` rather than re-typing them, so it cannot drift from the indexer.

### Measured mix

```
== INDEXED (native symbol graph) ==
 shell         552 files   8,275,608 bytes
 python        149 files   3,286,649 bytes
 javascript     48 files     164,627 bytes
== WOULD RESOLVE AS <UNRESOLVED> ==
 .c              2 files      20,169 bytes
 .ts             3 files      10,768 bytes
 .jsx            4 files       7,668 bytes
 .tsx            3 files       3,436 bytes
TOTAL code       761 files  11,768,925 bytes
INDEXED     98.42% files   99.64% bytes
UNRESOLVED   1.58% files    0.36% bytes
```

The 12 unresolved files, enumerated (`git ls-files | grep -E '\.(ts|tsx|jsx|c)$'`):

| File | Nature |
|---|---|
| `bin/edit-tracker.c`, `bin/parallelism-tracker.c` | 2 small C hook helpers, compiled, no call graph into the shell/python surface |
| `skills/designmatch/assets/visual-qa.ts` | 1 skill asset |
| `test/fixtures/designmatch/*.jsx/.tsx` (5) | **test fixtures** — deliberately fake input to designmatch |
| `test/fixtures/redum/**/*.ts/.tsx` (4) | **test fixtures** — synthetic RN app for the redum reuse tests |

So of 12 unresolved files, **9 are test fixtures** (input data, not repo code paths),
2 are C hook helpers, 1 is a skill asset. Production code that an `impact` query would
need to traverse and could not: effectively zero.

### Is there a near-term plan implying other languages?

Searched `.planning/*.md`, `docs/`, `docs/superpowers/specs/`, and the last 80 commits
for `typescript|rust|golang|java|ruby|c++`. **No roadmap item, spec, or commit proposes
moving this repo's implementation to another language.** The repo is shell+python by
construction (a git-native CLI with git hooks); that is not drifting.

### The decisive point: the breadth is already in-repo

The external module's only distinct claimed property is Tree-sitter multi-language
parsing — and this repo **already ships it**, twice over:

- `bin/lib/symbolgraph.py:82` — `BACKEND_LABEL["javascript"] = "tree-sitter"`. The
  native graph's JS backend *is* tree-sitter, delegated at `symbolgraph.py:547-567`.
- `bin/lib/treesitter_ast.py:56` — `LANGS = ("javascript","typescript","tsx","python","go","rust")`,
  the shared substrate behind `bin/heimdall-ast`. Confirmed independently at
  `docs/analysis/token-efficiency-field-review.md:110`: "hmd already ships
  `bin/heimdall-ast` (real tree-sitter structural extraction for JS/TS/TSX/Python/Go/Rust)".

If TypeScript/Go/Rust breadth is ever needed in the *graph*, the cheap move is wiring
the existing `treesitter_ast` substrate into `symbolgraph.EXT_LANG` — the grammars,
the provider fallback, and the degrade-honestly path are already written and tested.
Adopting an external module to obtain a capability the repo already vendors is a
strict regression: new dependency surface, zero new capability.

**Answer to the owner's bar ("adopt only if that breadth is actually needed soon"):
not needed soon, and not needed later by this route.**

## Q4 — The gate-side sampling-falsifier guard

_(pending — answered after Q3)_

### 1. What the guard actually IS

**There is no mechanism named "sampling-falsifier guard" in this repo.** No file, function,
flag, or doc uses the word "sampling" in that sense:

    $ grep -rn "sampling" --include='*.sh' --include='*.py' --include='*.md' --include='*.json' . | grep -v node_modules
    (no output)

The only near-hit is `.planning/LOG-FINDINGS.md:135`, about SONA routing-override sample
counts — unrelated to graphs or gates. Stating this plainly rather than inventing a
mechanism to fit the name.

The nearest **real** machinery is three separate things that partially cover the intent:

**(a) `bin/falsify` — the falsifiability harness.** This is the repo's actual anti-false-green
keystone (`bin/falsify:2-16`): it runs a gate against `fixtures/golden/` (must be GREEN, else
false-RED) and against each `fixtures/mutants/` entry (must go RED, else the mutant SURVIVED
= the gate is non-falsifiable for that defect). Score = killed/total; a P0 gate requires
`--assert-score 1.0`. It even carries a **false-green regression guard** concept
(`bin/falsify:32-49`) for mutants that are tautological *gate constructions* rather than
defect inputs.

**Critical scoping fact:** falsify grades a gate's ability to detect corrupted **outputs**
against **shipped fixtures**. It has no notion of sampling the live repo. And the one
registry domain that sounds graph-adjacent, `symbol-reuse`
(`evals/oracles/registry.json`, `gate_type: differential`), does **not** consume the symbol
graph at all — grep for `graph|symbolgraph` across `evals/oracles/symbol-reuse/*.py` and
`*.sh` returns nothing; it ships its own independent `reference.py`.

**(b) The self-printed `LIMITATIONS` tuple — `bin/lib/symbolgraph.py:90-102`.** Ten lines
naming the blind spots: dynamic dispatch, string-built/eval'd calls, shell indirection,
runtime plugin loading, cross-language calls, callers outside the repo, plus the `~`
(low-confidence) and `?` (ambiguous namesake) edge markers. The comment above it
(`symbolgraph.py:88-89`) states the design intent: *"Printed BY `impact` ITSELF, not just in
docs — the agent deciding whether a change is safe is the one who has to read this."*
It is rendered by `bin/lib/symbolgraph_cli.py:52` and exported as the `limitations` key in
JSON (`symbolgraph.py:674`).

**(c) The anti-drift test — `test/brief-graph-wiring.test.sh:235-249`.** Two assertions: the
brief's caller list must carry a non-exhaustiveness caveat, and that caveat must be *the
graph's own* `limitations[0]` string, fetched live via
`bin/heimdall-graph callers ... --json | jq -r '.limitations[0]'` and matched with `grep -qF`.
A reworded caveat upstream fails a test instead of silently drifting.

That is the whole guard surface. (a) is a real falsifier but is not wired to the graph;
(b) and (c) are a **caveat and a caveat-integrity check** — not falsification.

### 2. Is it sufficient?

**Verdict: sufficient today, and structurally insufficient the moment the graph feeds a gate.**
Both halves matter, because the owner's directive is conditional — *"applies to whichever
graph feeds gates."*

**Why sufficient today: the precondition is not met — no gate consumes the graph.**

    $ grep -rln "symbolgraph\|heimdall-graph" bin/ test/ hooks/ sentinels/ skills/
    bin/heimdall-brief          bin/heimdall-graph
    bin/lib/symbolgraph_cli.py  bin/lib/symbolgraph.py
    test/brief-graph-wiring.test.sh  test/symbol-graph.test.sh
    skills/heimdall/references/agent-templates.md

Every consumer is either the graph itself, its own tests, or `heimdall-brief` — an **advisory
brief read by an agent**. For a reader-facing surface a caveat is exactly the right
instrument, and (c) makes it tamper-evident.

The sharpest confirming evidence: `test/bin-reachability-gate.test.sh` is the one gate in the
repo that reasons about *"does anything call this?"* — precisely a graph question — and it
does **not** use the graph. It shells out to `grep -lE` over the tree
(`bin-reachability-gate.test.sh:106-109`), and its own comments record a past miss from using
`grep -F` instead of `-E` (line 250). Whether by design or accident, no gate is currently
staked on graph recall.

**Why insufficient the instant that changes:**

1. **A caveat has a reader; a gate does not.** `LIMITATIONS` is a message to a human or an
   agent who can widen the search after reading it. A gate's output is an exit code. Nothing
   in `symbolgraph.py` degrades, abstains, or raises when it enters a blind spot — it emits
   the caveat *alongside* a confident-looking caller list and exits 0. A gate consuming that
   sees "no callers found" and greens. **An empty result and a blind result are byte-identical
   at the exit-code layer**, which is exactly the false-green class this repo exists to prevent.
2. **The blind spots are the majority case, not a tail.** Per the Q3 answer above: the graph
   indexes py/sh/js only, and 552 of 749 shell files carry the weakest extractor. Shell
   indirection (`$cmd`, `eval`, `${fn:-default}`, command-name arrays) and cross-language
   sh->py calls are *listed blind spots* — and shell is the bulk of this codebase. The miss
   rate would not be a rare edge; it would be the modal path.
3. **Falsify cannot cover it as built.** `bin/falsify` proves a gate detects corrupted
   *outputs* from shipped fixtures. Graph incompleteness is not a corrupted output — it is a
   **missing input**. No mutant in any `fixtures/mutants/` dir can simulate an edge the
   indexer never emitted, because the fixture *is* the indexer's output. The defect lives
   upstream of the seam falsify operates on.

**What would have to be built.** A graph feeding a gate needs a **recall floor with a
fail-closed default**, not a caveat. Four concrete pieces:

- **A second-source recall sampler.** Draw N real call sites from the live repo via a method
  *independent* of `symbolgraph.py` (grep/`astgrep_match.py`, and the tree-sitter substrate
  named in Q3), then assert the graph contains each sampled edge. Emit a recall point estimate
  with a confidence interval. This is the literal "sampling" half — it does not exist today,
  and it must sample the repo rather than a fixture, or it re-inherits the indexer's own
  blindness.
- **Blind-spot mutants.** Fixtures deliberately containing one edge of each `LIMITATIONS`
  class (dynamic dispatch, `$cmd` indirection, sh->py cross-language, glob-and-source plugin
  load). Required outcome per fixture: the graph finds the edge **or** the gate ABSTAINS.
  Silently returning "no callers" must count as a SURVIVED mutant.
- **Abstention as a first-class gate verdict.** When a query's target sits in a file served by
  the weak shell extractor, or the neighborhood contains a blind-spot construct, the gate must
  return UNKNOWN/HOLD (nonzero), never PASS. Fail-closed. Without this, every other piece is
  advisory again.
- **Registry wiring.** A `symbol-graph-recall` domain in `evals/oracles/registry.json` with
  its own `run.sh` writing the typed `report.json` (`evals/oracles/REPORT-CONTRACT.md`), graded
  by `bin/falsify symbol-graph-recall --assert-score 1.0`, with a reference authored by a
  separate agent (`independent: true`), matching the pattern `symbol-reuse` already follows.

**Bottom line:** printing a limitations caveat is *not* a substitute for sampling-falsification;
it is honest documentation of a known-incomplete instrument. It is adequate while the
instrument only informs a reader. It becomes a false-green generator the day a gate reads its
exit code — and given 552/749 shell files on the weakest extractor, that failure would be
common, not exotic. **Do not wire the graph into any gate until the recall floor and the
abstain path exist.**

_Uncertainty stated: consumer enumeration is a grep over `bin/ test/ hooks/ sentinels/ skills/`
at HEAD (worktrees under `.claude/worktrees/` excluded as copies). A consumer reaching the
graph through a variable-built command name would itself be invisible to that grep — the same
shell-indirection blind spot under discussion._
