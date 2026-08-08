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
