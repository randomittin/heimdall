# Graph overlap analysis: Q1 / Q2

Scope: overlap check between the in-house native symbol graph and the external
`code-review-graph` module. Not a defense of the in-house tool.

Method note: budget-constrained. The tool was used on itself (`outline` before
`Read`) and `symbolgraph.py` was never read in full — only the spans that answer
the question. Claims are cited `file:line` or by command+output; anything else is
marked UNVERIFIED.

---

## Q1 — Does the native symbol graph cover generation-side scoping?

**Verdict: yes, it is wired and falsifiably tested — but it scopes by POINTER,
not by BODY, and its language coverage is py/sh/js only.**

### The wiring exists and is real

Generation-side scoping is not a property of `heimdall-graph` itself. The graph
CLI (`bin/heimdall-graph:12-19`) exposes only *query* verbs — `def`, `refs`,
`callers`, `callees`, `impact`, `outline`, `index`, `status`. None of those
compose a spawn context.

The composer is a separate binary: **`bin/heimdall-brief`**, which states the
mechanism outright at `bin/heimdall-brief:4-8`:

> A spawned agent's brief = task spec + the few symbols/files it actually
> references, resolved to spans + blast radius ... NEVER the plan, NEVER prior
> conversation ... The brief is the on-the-wire context a delta-spawn gets.

It calls the graph directly — `graph_q def` (`bin/heimdall-brief:150`),
`graph_q callers` (`:168`), `graph_q outline` (`:206`) — via
`GRAPH_BIN="${HEIMDALL_GRAPH_BIN:-$SOURCE_DIR/heimdall-graph}"` (`:96`). So the
answer to "does it cover generation-side scoping" is yes: that is precisely what
`heimdall-brief` is for, and the graph is its resolver.

Two design decisions here are stronger than typical:

- **Single source of truth.** Symbols resolve from the live index, not from a
  hand-maintained `symbols.json`; when both answer, the graph wins and the
  collision is *announced*, not silently resolved (`bin/heimdall-brief:10-18`,
  implemented at `:163-166`).
- **Fail closed, fail loud.** An unresolved ref marks the whole brief INCOMPLETE
  and exits 1; an unreachable resolver is a distinct exit 3 NON_VERIFIED, never
  downgraded to "absent" (`bin/heimdall-brief:20-24`, `:47-48`). A brief that
  quietly drops context is the false-green generator this avoids.

### It is tested, and the tests are falsifiable

`test/brief-graph-wiring.test.sh` covers the generation path with paired
negative cases, not just happy paths (assertion labels, lines 82-278):

- `(a)` code symbol resolves to a real `file:span` from the graph, not the alias
- `(b)` FALSIFIABLE: delete the definition → brief refuses, exit 1, says UNRESOLVED
- `(d)` `--files` emits an outline symbol list, and `brief carries spans only —
  no file body leaked in` (`:138`)
- `(e)` FALSIFIABLE: unknown file → refuses, exit 1
- `(h)` unreachable graph → exit 3 NON_VERIFIED, distinct from resolved absence
- `(k)` byte budget: `brief ${brief_bytes}B vs raw file ${raw}B — mechanism
  actually saves` (`:223`) — the savings claim is itself asserted, not assumed
- `(l)` the spawn path is asserted to route through the brief, with a
  FALSIFIABLE mutant (`:278`) proving the routing check can go dark

That `(k)` and `(l)` exist matters: the mechanism's *value* and its *actually
being on the spawn path* are both gated, which is the part most tools skip.

### Measured compression

    $ bin/heimdall-graph index
    # repo  files  symbols  edges   freshness
    /Users/rj/Downloads/heimdall  749  5998  71746  built

    $ wc -c < bin/lib/symbolgraph.py                                 -> 34741
    $ bin/heimdall-graph outline bin/lib/symbolgraph.py --limit 0 | wc -c -> 1209

28.7x on that file. Consistent with the 93,166 B / 1,323 B figure in the brief.

### Where it is weaker than it looks

These are the honest gaps, and two of them bite.

**1. Scoping is by pointer, not by body — savings depend on agent compliance.**
The brief emits spans (`  name = file:a-b (kind, lang)`,
`bin/heimdall-brief:160`) and outline rows (`:210`), explicitly *never* file
bodies — test `(d)` asserts the absence of bodies as a feature
(`bin/heimdall-brief:200` header: "files (outlines, never bodies)"). Nothing in
`symbolgraph.py`'s query surface extracts symbol source text: the query
functions are `q_def`, `q_refs`, `q_callers`, `q_callees`, `q_impact`,
`q_outline` (outline of `bin/lib/symbolgraph.py`, spans 807-948) — all return
metadata rows. So the agent receives *directions to* the code, and must still
issue a Read to get it. The mechanism therefore reduces context only if the
agent honors "read one span instead of the file". Whether any hook *enforces*
span-scoped reads is **UNVERIFIED** — I did not audit the hook set for this.
Contrast: a body-inlining packer makes the saving structural rather than
advisory. This is a deliberate design choice (it keeps the brief honest about
provenance), but it is a real difference from "composing context from symbols".

**2. Language coverage is the binding constraint, and it fails hard.**

    EXT_LANG = { ".py", ".sh"/".bash", ".js"/".mjs"/".cjs" }   bin/lib/symbolgraph.py:63-67

No TypeScript, Go, Rust, Java, C/C++, Ruby, or JSON/Markdown. And a file the
index does not know is not degraded gracefully at the generation side — it is
exit 4 → `<UNRESOLVED>` → `brief_core_missing "file $f — not in the symbol index
(wrong path, or an unindexed language)"` → brief INCOMPLETE, exit 1
(`bin/heimdall-brief:213-216`). On a TypeScript repo, generation-side scoping
does not merely lose fidelity, it **refuses**. Failing loud is the correct
posture, but the practical effect is that this mechanism is unavailable outside
py/sh/js.

**3. The largest language slice has the weakest extractor.**

    lang  javascript   48  tree-sitter
    lang  python      149  python-ast (exact for static calls)
    lang  shell       552  quote/heredoc state machine + command-position classifier (heuristic)

552 of 749 indexed files are shell, and shell edges are self-labelled heuristic
(`BACKEND_LABEL`, `bin/lib/symbolgraph.py:79-83`; extractors `_sh_defs` 475-495,
`_sh_edges` 516-544). Low-confidence edges are marked `~` and ambiguity `?`, and
those markers ride through into the brief unstripped
(`bin/heimdall-brief:44-45`, emitted at `:172`) — which is the right handling,
but it means the majority of this repo's blast-radius data is heuristic.

**4. `callers` is non-exhaustive by construction, and says so.** The brief
carries the graph's own caveat *verbatim* rather than a paraphrase, precisely so
a local copy cannot drift (`bin/heimdall-brief:175-182`, emitted `:192-195`).
Correct handling of a real limitation, but the limitation stands: dynamic
dispatch, `eval`, shell indirection, and cross-language calls are invisible
(`bin/heimdall-graph:29-31`).

**5. The JS path is optional and degrades to nothing.** `_load_treesitter`
(`bin/lib/symbolgraph.py:549-568`) returns `(None, reason)` if
`treesitter_ast.py` is missing, the import fails, grammars are not installed, or
the javascript grammar specifically is absent. JS symbols then simply do not
exist in the index — and per gap 2, a JS file passed to `--files` in that state
makes the brief refuse.

### Q1 bottom line

Covered, and covered better than the question implies — the composer exists
(`heimdall-brief`), is on the spawn path, and its value claim is itself under
test. The two things it does *not* do: inline symbol bodies (scoping is
advisory at the point of consumption), and work at all outside python/shell/js.

---

## Q2 — What does the external `code-review-graph` module add beyond that?

PENDING.
