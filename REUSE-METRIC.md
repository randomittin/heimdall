# Reuse Metric (S-6 Component 1)

The reuse metric is the foundation of the S-6 generalization gate. It answers one
question, per task, with a number computed from real parsed source — never an
invented figure:

> **Did the new code build on what already existed in the repo, or did it write a
> parallel implementation of something the repo already had?**

A low reuse number is a *finding about the core*, not a failure to hide. The whole
point of S-6 is an honest verdict.

---

## Definition

```
reuse_pct = (count of changed/added code units that CALL, IMPORT, or EXTEND a
             symbol that already existed in the repo BEFORE the change)
            ÷ (total changed/added code units)
```

Computed per task, over the git diff the task produced.

- **Reuse** — a new code unit *depends on / invokes* pre-existing repo code
  (calls a function, imports a module/symbol, extends a class/component, renders
  an existing component) instead of writing a parallel implementation.
- **Reinvention** — a new code unit *duplicates a capability that already existed
  elsewhere in the repo*: it does not reuse, and its name/shape closely matches a
  pre-existing symbol it never references. The duplicated pre-existing symbol is
  recorded in `suspected_duplicates`.
- A unit that is **genuinely novel** (neither reuses nor duplicates anything) is
  counted in the denominator but in neither `units_reusing` nor
  `units_reinventing`. So `reuse_pct` is honest: novel work neither inflates nor
  is mistaken for reinvention.

---

## Granularity — what a "code unit" is

A **code unit** is a *named* definition introduced or modified by the diff. The
exact rules per language (implemented in `bin/lib/reuse_analyzer.py`):

| Language | Counted as a unit |
|----------|-------------------|
| JS / TS / JSX / TSX | `function` declarations; `const`/`let`/`var` bound to a function or arrow; `class` declarations; React components (a capitalized function/const returning JSX is still just a named function unit — JSX is not special-cased) |
| Python | every `def` and `class` at any nesting depth — parsed with the stdlib `ast`, so the granularity is exact, not regex-approximate |
| Shell (`.sh`, `.bash`) | `name()` and `function name` definitions |

Rules that apply across languages:

- **Anonymous / inline closures are not their own units** — they fold into the
  enclosing named unit.
- **Nested named definitions are their own units** (a nested `def`, an inner
  named function) — they each call/reuse independently.
- **A file with no named units but with added executable lines** is counted as
  one synthetic `<module:filename>` unit, so a diff that only adds top-level glue
  is still measured. A diff is never silently scored `0/0` when it added real
  code.

---

## Reuse and reinvention signals (how a unit is classified)

A unit is **reusing** if *any* of these resolve to a symbol that existed at the
pre-change base:

- it **calls** a function/method whose name is a pre-existing repo symbol,
- it **imports** a module/symbol and its body **actually references** that
  imported name (a top-of-file import alone does not credit a sibling unit that
  never touches it — this avoids inflating reuse),
- it **extends / instantiates / renders** a pre-existing class or component.

A unit is **reinventing** (and emits a `suspected_duplicates` entry) if it does
**not** reuse, **and** a pre-existing repo symbol has a name that is identical or
near-identical to the new unit's name (normalized equality, or a bounded
Levenshtein distance — ≤2 edits and ≤25% of the longer name, for names ≥4 chars),
**and** the new unit never references that symbol. That pre-existing symbol is the
suspected duplicate.

### The pre-change symbol table

Reuse is resolved against the repo **as it was before the change**. The analyzer
builds a symbol table from every tracked source file at the base commit
(`git ls-tree -r <base>`), collecting function/class/component names plus module
basenames (so an import of a pre-existing file resolves). A unit that references a
*sibling* unit added in the same changeset is **not** counted as reuse — that is
intra-changeset, not reuse of pre-existing repo code.

---

## Supported languages and fallback

| Stack | Support level |
|-------|---------------|
| JavaScript / TypeScript (`.js .jsx .mjs .cjs .ts .tsx`) | robust regex heuristic — function/const/class/component extraction, import/require/JSX resolution |
| Python (`.py`) | **exact** — real `ast` parse of defs/classes/calls/imports/bases |
| Shell (`.sh .bash`, extensionless shebang files) | function-definition + call + `source`/`.` resolution |

These are the stacks Heimdall and its targets use. **Any other language is
honestly unsupported**: its files are listed under `unsupported_files` and, if a
task touches *only* unsupported languages, the record carries
`reuse_pct: null` with `reason: "unsupported-language"`. The metric never reports
an invented percentage for a language it cannot actually parse. A Python file that
fails to `ast`-parse (a syntax error) is treated the same way — listed as
unsupported rather than guessed at.

---

## The emitted record

Every real `hmd "task"` run emits one JSON record at completion to
`.planning/reuse/<run-id>.json`, plus a one-line human summary on stderr.

```json
{
  "task": "add user endpoint + py handler",
  "units_total": 4,
  "units_reusing": 2,
  "units_reinventing": 1,
  "reuse_pct": 0.5,
  "reused_symbols": [
    { "symbol": "formatUser", "call_sites": 1 },
    { "symbol": "getUser",    "call_sites": 1 },
    { "symbol": "normalize",  "call_sites": 1 }
  ],
  "suspected_duplicates": [
    { "new_unit": "slugify", "duplicates": "slugify", "file": "api/users.js" }
  ],
  "languages": ["js", "py"]
}
```

Human summary:

```
reuse: 50% (2/4 units reuse pre-existing repo code; 1 reinventing; 1 suspected duplicate) — task='add user endpoint + py handler'
```

Required fields, always present: `task`, `units_total`, `units_reusing`,
`units_reinventing`, `reuse_pct`, `reused_symbols`, `suspected_duplicates`.

### Honest / degraded records

When analysis cannot produce a real percentage, the record still has every
required field, `reuse_pct: null`, and a `reason`:

| `reason` | Meaning |
|----------|---------|
| `no-changed-files` | the run produced no added/modified source files to measure |
| `no-code-units-in-diff` | files changed but none parsed to a code unit |
| `unsupported-language` | only unsupported-language files changed (lists `unsupported_files`) |
| `analyzer-error-rc-<n>` / `not-a-git-repo` / `json-job-not-found` | a `degraded: true` record emitted so the calling task is never aborted |

---

## Edge cases

- **New file vs. modified file** — both count; deletions do not (nothing to
  analyze). The analyzer reads the *after* side of each changed/added file (the
  working-tree contents, the staged blob with `--staged`, or the after-commit
  blob with `--range A..B`).
- **Untracked new files** — a real task writes new files that are not yet
  committed. The working-tree path folds in untracked-but-not-ignored files
  (`git ls-files --others --exclude-standard`) so newly authored code is
  measured.
- **Commits made during the run** — the per-run base is the HEAD snapshot taken
  *before* the task launched, so commits the task makes during the run are diffed
  against the pre-run state, not against themselves.
- **Renaming an existing symbol** — if the renamed unit still calls into
  pre-existing code it counts as reuse; if it re-implements and drops the call it
  surfaces as a suspected duplicate.
- **A unit redefining a pre-existing symbol of the same name without calling it**
  — flagged as reinvention even though the name is also in the changeset (a unit's
  own redefinition still registers).

---

## How it is wired

- **Standalone**: `bin/heimdall-reuse-metric --repo <dir> --base <ref>
  [--task <s>] [--print]`. Engine: `bin/lib/reuse_analyzer.py` (a pure function of
  `{changed_files, pre_symbols}` — it never shells out to git itself).
- **Per-run emission**: `bin/heimdall`'s `hmd "task"` completion handler snapshots
  HEAD before the run and calls the metric after the run returns. This is
  **fail-open**: emission never aborts or changes the task's exit status, and it
  can be disabled with `HEIMDALL_NO_REUSE_METRIC=1`. There is no SI-2 attestation
  record in the codebase yet (grepped for SI-2/attestation — none present), so the
  standalone JSON under `.planning/reuse/` is the record of truth; if SI-2 lands
  later, emit into it.
- **Test**: `test/reuse-metric.test.sh` proves reuse detection, reinvention +
  suspected-duplicate detection, JSON well-formedness, correct `reuse_pct` on a
  known mix, cross-language (JS + Python) coverage, and degraded safety on an
  unsupported language — all against real temp git repos and real diffs.

---

## Consumed by later S-6 waves

- **C2 (mini-git reuse test)** asserts `reuse_pct ≥ threshold` on a reuse-friendly
  controlled task.
- **C4 (halt-if-low-reuse rule)** halts/hard-warns when `reuse_pct < 30%`, listing
  the `suspected_duplicates` so a likely reinvention is inspected before it ships.

This component (C1) defines and emits the number. C2 and C4 build on the merged
record.
