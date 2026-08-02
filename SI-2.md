# SI-2 — Commit-Time Attestation Record

SI-2 is the **shared substrate** Heimdall emits **once per commit/task**. It is a
single structured record describing what a change did, what it touched, and
whether it is proven — computed one time so that every downstream feature reads it
instead of re-analyzing the diff.

```
            ┌──────────────────────────────┐
   diff ──▶ │  heimdall-attest emit         │ ──▶  .heimdall/attestations/<id>.json
            │  (attestation.py builder)     │           │
            └──────────────────────────────┘            │  one emission, many readers
                                                         ▼
            F2 Checker · F3 Redum · F4 Collision · F5 Debloat · F6 Team-mode
                       (each READS the record; none re-analyzes the diff)
```

One emission, many readers: F2–F6 consume this record. They never re-walk the
diff, never re-run the reuse analysis, never re-extract symbols — the cost is paid
once at emit time and amortized across every consumer.

---

## The record schema — `{ claims, contracts, evidence, reuse, risk }`

Schema version: **`si-2.1`** (the top-level `schema` field). Every record also
carries `task`, `commit` (the sha / branch / run-id it attests), and `engine`.

The builder is [`bin/lib/attestation.py`](bin/lib/attestation.py); the thin CLI is
[`bin/heimdall-attest`](bin/heimdall-attest).

### 1. `claims` — what the change asserts it does (derived from the diff)

Derived from the diff, **not** the agent's prose. For each changed file: its path,
git status letter (`A`/`M`/`R`), language, and the **named code units**
(functions / classes / components / shell functions) it introduces or touches,
plus a one-line structured summary.

```json
"claims": {
  "summary": "changes 1 file(s) (1 added, 0 modified, 0 renamed) introducing/touching 1 named unit(s)",
  "files": [
    { "path": "api/users.js", "status": "A", "lang": "js", "units": ["userEndpoint"] }
  ],
  "file_count": 1,
  "unit_count": 1
}
```

A source file that cannot be parsed for units is marked `"units_partial": true`
(honest, not silently dropped).

### 2. `contracts` — the exported/public surface added or changed

The interfaces a change adds or must honor: the **exported / public symbols**,
with their kind, language, span, and an `exported` flag. Resolved from
**tree-sitter symbols** (richer, AST-accurate) with a heuristic-extractor
fallback. `surface` is the flat list of the public ones; `by_file` is the
per-file breakdown.

```json
"contracts": {
  "summary": "1 public symbol(s) across 1 source file(s)",
  "surface": [ { "path": "api/users.js", "name": "userEndpoint", "kind": "function" } ],
  "by_file": [
    { "path": "api/users.js",
      "symbols": [ { "name": "userEndpoint", "kind": "function", "lang": "js",
                     "span": [2, 2], "exported": true } ] }
  ]
}
```

### 3. `evidence` — RUNNABLE proof (real exit codes, never self-report)

This is the field that makes the record trustworthy. `evidence` records the
acceptance / test / build commands the **emitter actually executed** and their
**real exit codes** — never the agent's self-assessment. Each check is
`{ cmd, exit, ok, kind, stdout_tail }`, where `ok` is *derived* from the exit
code (`ok == (exit == 0)`), so a check can never claim success the run did not
produce.

```json
"evidence": {
  "checks": [
    { "cmd": "npm test", "exit": 0, "ok": true,  "kind": "evidence", "stdout_tail": "…" },
    { "cmd": "npm run build", "exit": 7, "ok": false, "kind": "evidence", "stdout_tail": "…" }
  ],
  "ran": 2,
  "all_passed": false
}
```

A failing command does **not** abort emission — its non-zero exit is recorded and
surfaced as a `risk`. An empty evidence list yields an honest
`"reason": "no-evidence-commands-supplied"` block (itself a `no-evidence` risk),
never a fabricated pass.

Evidence is supplied to the emitter with repeatable `--evidence <cmd>` flags (each
is executed in the repo), or pre-run as `--evidence-json <file>` (`[{cmd,exit,…}]`,
skips re-running).

### 4. `reuse` — THE S-6 reuse record (unified, AST-based)

`reuse` **is** the S-6 reuse metric, produced by the unified reuse analyzer
[`bin/lib/reuse_analyzer.py`](bin/lib/reuse_analyzer.py) — the *same* analyzer that
powers `heimdall-reuse-metric` and the S-6 halt gate. Reuse is measured **once**,
on a tree-sitter AST substrate (heuristic regex fallback when the AST backend is
unavailable), and the record records which backend produced the numbers via the
`engine` field.

`reuse_pct = units_reusing / units_total`: of the named units the change adds, how
many call a symbol that already existed in the repo (reuse) versus reinventing it.

```json
"reuse": {
  "task": "feat: add userEndpoint reusing formatUser",
  "units_total": 1,
  "units_reusing": 1,
  "units_reinventing": 0,
  "reuse_pct": 1.0,
  "reused_symbols": [ { "symbol": "formatUser", "call_sites": 1 } ],
  "suspected_duplicates": [],
  "engine": "treesitter"
}
```

- `reused_symbols` — pre-existing repo symbols the change calls, with call-site counts.
- `suspected_duplicates` — new units that re-declare a pre-existing capability
  (`{ new_unit, duplicates, file }`), i.e. reinvention.
- `engine` — `treesitter` when the AST backend loads, `heuristic` on fallback.
  The two backends are held to the **same verdict**: `test/reuse-mini-git.test.sh`
  and `test/si-2-attest.test.sh` both assert AST/heuristic agreement on the
  reuse classification, so swapping the detection substrate does not change the
  metric's behavior.

The reuse **definition, scoping and verdict are engine-independent** — only the
symbol/reference detection differs between the AST and heuristic backends.

### 5. `risk` — reviewer-facing flags (derived from the other four fields)

Derived from the already-built fields, never re-analyzed. Each flag is
`{ level, code, detail }` (`level` ∈ `info | warn | high`), plus an `overall`
rollup (`none | info | warn | high`) so a reader can branch on one field. `flags`
is always a list (possibly empty).

```json
"risk": {
  "overall": "high",
  "flags": [
    { "level": "high", "code": "evidence-failed",
      "detail": "evidence command(s) did not pass: npm run build" }
  ]
}
```

Flag codes: `low-reuse` (`reuse_pct` below the `0.30` floor),
`suspected-duplicates`, `large-public-surface` (≥ 12 public symbols at once),
`no-evidence`, `evidence-failed`, `partial-analysis`.

---

## Degrade gracefully — a PARTIAL record, never a block

A commit must **never** be blocked by an attestation failure. If any sub-analysis
cannot complete (an unparseable file, an unsupported language for reuse, an
analyzer error), the affected field carries an honest `partial`/`reason` and the
top-level record gains `"partial": true` with a `"partial_reasons"` list. For an
unsupported-language diff, `reuse_pct` is **`null`** (honest) rather than a
fabricated number. `heimdall-attest emit` **always exits 0** on analysis failure —
it writes an honest partial record instead of failing.

---

## Interface

### Emit — `heimdall-attest emit [options]`

Writes one record to `.heimdall/attestations/<id>.json` and prints a one-line
human summary to stderr.

| Option | Meaning | Default |
| --- | --- | --- |
| `--repo <dir>` | repo to attest | cwd |
| `--base <ref>` | the BEFORE commit/ref | `HEAD` |
| `--range <A>..<B>` | attest an explicit commit range (base=A, after=B) | — |
| `--staged` | attest staged changes (`--cached`) vs base | — |
| `--task <str>` | task label | derived from `git log` |
| `--id <id>` | record id / output stem | `<commit>` or `<runid>` |
| `--engine <name>` | reuse engine `auto`\|`treesitter`\|`heuristic` | `auto` |
| `--evidence <cmd>` | a runnable proof command (repeatable; each is EXECUTED, its real exit recorded) | — |
| `--evidence-json <file>` | pre-run evidence as `[{cmd,exit,…}]` (skips running) | — |
| `--print` | also print the record JSON to stdout | — |
| `--quiet` | suppress the one-line human summary on stderr | — |

The id resolves to the after/base **commit sha** for a committed/range diff, or a
`timestamp-pid` run-id for an uncommitted working tree.

### Readers — emit once, read many

| Command | Meaning |
| --- | --- |
| `heimdall-attest get <id> [--repo <dir>]` | print the record for an id |
| `heimdall-attest list [--repo <dir>]` | list stored attestation ids (newest first) |
| `heimdall-attest path <id> [--repo <dir>]` | print the on-disk path for an id |

`get <id>` round-trips an emitted record byte-for-byte. A committed change is
gettable by its **short commit sha** (the record's `commit` field self-identifies
it). F2–F6 are all readers over this same API — they call `get` (or read the
on-disk JSON), never the emitter.

### Exit status

| Code | Meaning |
| --- | --- |
| `0` | record emitted / read (**including** honest PARTIAL records) |
| `2` | usage error |
| `3` | `get`/`path`: no record for that id |

`emit` never exits non-zero on an analysis failure — a PARTIAL record is written so
a commit is never blocked (degrade-gracefully, like the S-6 gate).

---

## Where records are stored

```
${HEIMDALL_HOME:-<repo>/.heimdall}/attestations/<id>.json
```

The store is **gitignored runtime state** (`.gitignore` ignores `.heimdall/` and
`.heimdall/attestations/`), so attestations never pollute the tree. Set
`HEIMDALL_HOME` to relocate the store (used by the test harness to keep records
inside a temp repo).

---

## Acceptance

`test/si-2-attest.test.sh` proves the contract above against the **real** emitter
on a **real** temp git repo, with **no model spend** and **no token cost**
(deterministic reference diffs, CI-free):

1. a call-existing-symbol diff emits a record with **all five fields** populated;
2. `reuse` carries the S-6 shape + `engine` tag, `reuse_pct > 0`, the reused
   symbol named;
3. `evidence` records **real exit codes** (a passing and a failing command), each
   exit-coded — not a prose claim;
4. `claims`/`contracts` are derived from the diff; `risk` is present;
5. the readers API round-trips (`emit → get` returns the same record; commit-sha
   gettable by short sha; `list` surfaces the ids);
6. an unsupported-language diff still emits a record with `reuse_pct: null` and
   exits 0 (graceful partial, never blocks);
7. tree-sitter and heuristic engines reach the same reuse verdict.

The AST/heuristic engine agreement asserted in `test/reuse-mini-git.test.sh` (and
mirrored here) stays green — the reuse substrate swap is behavior-preserving.
