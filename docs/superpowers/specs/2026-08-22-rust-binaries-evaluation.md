# Would switching hmd's binaries to Rust be better for execution?

**Status:** evaluation complete — recommendation below. No implementation in this doc or this task.
**Author:** hmd-architect · **Date:** 2026-08-22
**Scope:** answer the owner's question with measured numbers; identify the narrow set of
genuine Rust-shaped candidates if any; name the architectural fixes that outrank a rewrite.

## Answer, up front

**No — not a binary rewrite.** Every measured bottleneck in the current hot path is
process-launch/fork-fan-out or architecture (sync work on a render path, a no-op timeout
guard, a shim bypass), none of it CPU-bound Python/bash compute. Rust does not touch the
first two classes; the fourth class (real compute) exists in exactly one place in this
codebase (`bin/lib/symbolgraph.py`'s AST walk) and the codebase has *already* reached for
the correct fix there — delegate to a compiled native library (tree-sitter) via bindings —
without a language rewrite. That is the general pattern this spec recommends extending, not
replacing.

## 1. Where does time actually go? (measured, this session)

### 1a. Process-launch floor (n=10-20 each, this machine)

| Operation | Median | What it measures |
|---|---|---|
| `/usr/bin/true` | 1.56 ms | (a) bare fork+exec floor |
| `bash -c ':'` | 2.28 ms | (a) + shell init |
| `jq -n '{}'` | 3.76 ms | (a) + jq's own startup |
| `git rev-parse --show-toplevel` | 4.01 ms | (a) + git's own startup |
| `python3 -c pass` (direct binary, no shim) | 16.58-30.7 ms | (a) + (b) interpreter startup |
| `python3 -c pass` (via `~/.pyenv/shims/python3`) | 61.36 ms | (a) + (b) + shim dispatch overhead |

Every compiled tool here (`true`, `bash`, `jq`, `git`) already launches in under 5 ms — this
is the floor Rust would launch at too. A Rust binary's own fork+exec+dynamic-link cost is in
the same 1-5 ms band as these existing C binaries; it is not competing against Python's
16-60 ms, it is competing against `true`'s 1.56 ms, and the delta a rewrite could claw back
per launch is single-digit milliseconds, not the 45 ms the shim defect costs today.

### 1b. The real hot path: `bin/heimdall-statusline`, cProfile'd on the real fixture

```
$ COLUMNS=120 python3 -m cProfile -s cumulative sentinels/hmd-statusline.py \
    < test/fixtures/cursor-real-payload.json
         24724 function calls (24232 primitive calls) in 0.213 seconds
   ncalls  tottime  percall  cumtime  percall filename:lineno(function)
     29/1    0.000    0.000    0.213    0.213 {built-in method builtins.exec}
        1    0.000    0.000    0.213    0.213 hmd-statusline.py:1(<module>)
        1    0.000    0.000    0.198    0.198 hmd-statusline.py:1875(main)
        2    0.000    0.000    0.191    0.095 subprocess.py:506(run)
        2    0.000    0.000    0.189    0.094 subprocess.py:1165(communicate)
        4    0.188    0.047    0.188    0.047 {method 'poll' of 'select.poll' objects}
        1    0.000    0.000    0.099    0.099 hmd_ledger.py:406(read_status)
        1    0.000    0.000    0.093    0.093 hmd-statusline.py:394(identity)
```

**191 of 213 ms (90%) is the Python process blocked in `select.poll()` waiting on two
forked child processes** — `subprocess.run` for `bin/heimdall-identity --json` and for
`git status --porcelain`. `tottime` (time spent *in* the Python interpreter's own bytecode,
as opposed to waiting on a child) is effectively zero everywhere in this trace. There is no
compute here for a faster language to accelerate — the CPU is idle, waiting on other
processes' own startup.

End-to-end wall time, 10 samples of the real `bin/heimdall-statusline` entrypoint:
`426.7, 248.9, 234.5, 209.1, 194.9, 188.7, 190.1, 190.6, 196.6, 224.2` ms — median ≈ 200 ms,
consistent with the owner's stated 0.22 s baseline.

### 1c. Following the fork chain down: `bin/heimdall-identity --json`

```
$ time bin/heimdall-identity --json     # 5 runs: 102.9, 105.0, 104.9, 98.7, 99.0 ms
```

This repo has no `.heimdall/identity.json`, so `resolve_seed`/`resolve_handle` fall through
to `heimdall-haid current`:

```
$ time bin/heimdall-haid current        # 5 runs: 62.5, 65.9, 57.3, 53.0, 45.4 ms
$ bash -x bin/heimdall-haid current 2>&1 >/dev/null | grep -E '(jq |git |scutil|shasum)'
  shasum -a 256
  scutil --get LocalHostName
  git -C /Users/rj/Downloads/heimdall rev-parse --show-toplevel
  git -C /Users/rj/Downloads/heimdall config user.email
```

**Four external forks for one identity resolution**, none of them Python or bash compute —
`scutil` (macOS SystemConfiguration query) and `shasum` (a Perl script on macOS) are the
two slowest, and both could be replaced by direct syscalls/library calls
(`gethostname(3)`, a hash crate or `hashlib.sha256`) with **zero forks**. That elimination
is real and would save most of this 45-65 ms — but it is a "stop shelling out for things you
can call as a library" fix, available to *any* language with FFI or a stdlib hash function.
Python already has `socket.gethostname()` and `hashlib` built in; this fix costs a rewrite
of one ~200-line bash function, not a language migration.

### 1d. The other flagged case: `heimdall-agents count` (background-cached path)

```
$ time bin/heimdall-agents count        # 3 runs: 394.7, 355.5, 404.2 ms
```
Corpus on this machine: 1.4 GB / 2,145 transcript `.jsonl` files under
`~/.claude/projects/`. The scan (`bin/heimdall-agents:386-398`) is deliberately
`grep -hF '<task-notification>' ... | perl -ne '...'` — comment on that line: *"parsed
straight off the raw JSONL with grep+perl — no jq — because these transcripts reach 16MB
and this runs on the statusline path."* `grep` and `perl`'s regex engine are already
compiled C. The ceiling on a Rust rewrite of this specific scan is bounded by disk I/O
throughput on files already-compiled tools stream at close to raw read speed, not by any
per-byte interpreter tax — there is little headroom left for a rewrite to claim. The actual
fix already shipped (per the owner's evidence #2) was architectural: move the scan off the
synchronous render path into a cached background refresh (1.65 s → 0.25 s on the render
path itself). That is the correct lever here, already pulled.

### 1e. The one place real CPU-bound compute exists: `bin/lib/symbolgraph.py`

```
$ time python3 bin/lib/symbolgraph_cli.py index . 0 1
cold index build: 3634.4 ms
warm re-run:       3032.9 ms      # `index` forces force=True — always a full rebuild
```
952 LOC, uses Python's `ast` module to walk every file's parse tree (`ast.parse`,
`ast.FunctionDef`/`ClassDef`/`Call`/`Name`/`Attribute` node walks —
`bin/lib/symbolgraph.py:38-268`) over this repo's 5,096 `.py`/`.js` files. This is genuine
CPU time inside the interpreter, not fork-wait — the only spot in this audit where that is
true. **The codebase has already solved this correctly**: for JavaScript,
`bin/lib/symbolgraph.py:31-32` delegates to `bin/lib/treesitter_ast.py`, which binds the
compiled `tree-sitter` parsing library (`pip3 show tree-sitter` → "Python bindings to the
Tree-sitter parsing library", C core) instead of hand-rolling a JS parser in Python. The
existing, working pattern for "this needs to be fast because it's real compute" is *bind a
native library from the orchestrating language*, not *rewrite the orchestrator*.

## 2. Distribution cost of a Rust rewrite

Current model: `curl -fsSL <pinned-commit-url>/install.sh | shasum -a 256` (README.md:80,94)
— a bash script, editable in place, no build step, works identically on whatever `bash` +
`python3`/`jq`/`git` the target machine already has. `hooks/hooks.json` (181 lines, 40
`"command"` entries) wires every hook as a shell one-liner resolved at hook-fire time via
`"${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel...)}/bin/<script>"` — no linking, no
target triple, no artifact to have pre-built for the machine the hook fires on.

Switching any of these to Rust binaries requires, for every one of them:
- a build pipeline (cargo, cross-compilation for macOS arm64 + x64 + Linux — this repo's
  CI has none of this today; `rustc`/`cargo` exist only in the *operator's* `~/.cargo`, not
  in the repo's toolchain)
- versioned release artifacts per platform, and a way to select/verify the right one at
  install time (the current `install.sh` + minisig model would need to grow a
  binary-fetch-and-verify step per architecture)
- a compile step between an edit and a test run — today, editing `bin/heimdall-statusline`
  and re-running `test/heimdall-statusline-perf-budget.test.sh` is instant; a Rust
  equivalent adds a `cargo build` in that loop, for every one of 179 executables if this
  went wholesale
- the hook model (`hooks/hooks.json`'s `"command"` strings) still shells out to *something*
  either way — a Rust binary invoked from a hook pays the same fork+exec the bash script
  pays today (§1a: ~1-5 ms either way), so hooks gain nothing from the binary being Rust
  vs. bash, only from what's *inside* it doing less forking of its own.

This directly costs the repo's own stated goals: "no build step, editable in place,
`curl | bash` installable... one-time setup pain" — a Rust migration is the opposite of all
three for whatever surface it covers.

## 3. Genuine Rust-shaped candidates (specific, short)

- **`bin/lib/symbolgraph.py`'s Python-side AST walk** (the `ast.parse` + node-walk in
  `bin/lib/symbolgraph.py:215-268`) is the one place this audit found real CPU-bound work
  at meaningful scale (3.6 s cold over 5,096 files). But the pattern already in this file
  for the *other* language (JS → tree-sitter) is the answer: bind a compiled parser
  (tree-sitter already has a Python `.py` grammar) rather than rewrite the CLI wrapper
  around it in Rust. This buys the speedup without touching distribution, install, or the
  179 other executables.
- **`bin/heimdall-comprehend` / anywhere else that shells out to `symbolgraph_cli.py`** —
  same conclusion; it wraps the same engine, gains the same way.
- **No other candidate identified.** Every other profiled path in this audit (statusline,
  identity, agent-count) is fork/IO-bound, not compute-bound — a faster language changes
  none of it, per §1b-1d.

That is "none, or 1-2 compute-bound helpers" from the owner's framing, landing on 1: the
symbolgraph AST engine, and even there the recommended fix is "bind a native parser
library," not "rewrite the wrapper in Rust."

## 4. Migration risk (quantified)

- 179 executables in `bin/` (measured this session: `find bin -maxdepth 1 -type f`), 65,124
  total LOC, 160 bash / 15 python / 4 other by shebang.
- 350 test suites under `test/*.test.sh` (measured this session; owner's baseline cited 348
  — consistent, small drift from same-day work).
- `test/run-all.sh` (320+ suites, ~1600s per the CLAUDE.md-documented full sweep) plus the
  push-time gate stack (`bin/heimdall-gate-run --phase pre-push`) all assume the current
  process shapes: stdin/stdout JSON contracts, exit codes, `$COLUMNS`/env-var signaling,
  `.heimdall/*.json` file formats read by both bash (`jq`) and Python (`json.load`) call
  sites today. A Rust binary re-implementing any one of these has to reproduce every
  byte-for-byte contract the existing suite locks — e.g.
  `test/heimdall-statusline-parity.test.sh` explicitly fails "the moment the two wrapped
  paths disagree on a byte."
- This is a system whose stated thesis (per this repo's own CLAUDE.md) is that AI-generated
  code should get *simpler*, gated by deterministic hooks, not rebuilt wholesale. A
  multi-month Rust port of 179 files against 350 suites is the highest-risk way to spend
  that effort: every ported file is a chance to silently drop a fallback branch, an env-var
  fallback, or an edge case the bash/python version handles only because someone hit it in
  production and patched it in place (e.g. the pyenv-shim bypass, the double-fork
  memoization, the perl-alarm timeout fix — all three are exactly the kind of
  "small patch to existing running code" this repo's own CLAUDE.md documents as how these
  got fixed, none of which required or would have been faster to fix as a rewrite).

## 5. The evidence that already answered this before the question was asked

Per the owner's brief, every perf win landed this session was a shell/architecture fix, and
this audit's own measurements corroborate the same pattern one layer deeper (§1c, §1d):
process-launch and fork fan-out dominate, not language-level compute. **A Rust rewrite
would have carried every one of those four defects across unchanged** — a pyenv shim bypass
is a PATH/dispatch problem regardless of what language calls `python3`; a no-op `timeout`
guard is a "the tool I assumed exists doesn't exist on this OS" problem; a synchronous
73-transcript parse is a "this runs on the wrong side of the render deadline" problem; a
dead `[ ! -t 0 ]` guard is a control-flow bug. None of the four is "the language was too
slow."

## 6. Recommendation: keep bash+python, fix architecture — named, ranked

1. **Eliminate the remaining forks in the identity chain** (§1c): replace
   `heimdall-haid`'s `scutil --get LocalHostName` and `shasum -a 256` calls with
   `socket.gethostname()`/`hashlib.sha256()` equivalents (or bash's own `hostname` builtin
   path where already available) — cuts ~30-40 ms off every cold identity resolution, in
   the same language, no build step, testable in the existing suite immediately.
2. **Cache identity resolution to disk, not just process-locally**: `heimdall-identity`
   already memoizes `heimdall-haid current` *within* one invocation
   (`bin/heimdall-identity:88-96`), but this repo has no `.heimdall/identity.json`, so every
   fresh statusline render re-forks the whole chain. Writing the resolved identity once
   (as `--set` already supports) and reading it thereafter turns the §1b "90% of render
   time is two subprocess waits" figure into near-zero for the identity half.
3. **Audit the remaining ~40 `hooks.json` command strings for the same shim/timeout/dead-
   guard defect class** that produced this session's four fixes — the evidence says the
   next win is in that pattern, not in a language swap. A short, mechanical grep-and-review
   pass (`grep -c '"command"' hooks/hooks.json` → 40 sites) is bounded, cheap, and matches
   the defect class actually observed.

## OUT OF SCOPE

- No code changes in this task — evaluation and spec only, per the brief.
- No decision on any *specific* future symbolgraph/tree-sitter-for-Python change — that is
  a follow-on design if the owner wants to pursue item 1-2 lists above; this spec only
  identifies it as the one legitimate compute-bound candidate.
- No audit of every one of the 179 `bin/` executables individually — this spec profiles the
  hot/flagged paths named in the brief (statusline, identity, agent-count, symbolgraph) as
  representative samples, not an exhaustive per-file review.
- No CI/build-pipeline design for a hypothetical partial Rust adoption — moot given the "no"
  recommendation; would only become relevant if the owner overrides this recommendation.
- No re-litigation of the four fixes already shipped this session — cited as evidence only.

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Owner overrides "no" and orders a partial Rust port anyway | low | high | Scope it to exactly the symbolgraph engine (§3), never the orchestrating 178 other scripts; require the same byte-for-byte parity test pattern `heimdall-statusline-parity.test.sh` already uses | future task, not this spec |
| Identity disk-cache (item 2) goes stale (host/user changes, cached file never invalidated) | med | low | `--set` already exists for explicit rewrite; add a repo-state stamp to the cache file mirroring `symbolgraph.py`'s own "cache carries a repo-state stamp, rebuilt on mismatch" pattern (`bin/lib/symbolgraph.py:19`) | item 2 owner |
| `scutil`/`shasum` removal (item 1) changes hostname/hash output on some macOS version this wasn't tested against | low | med | Land behind the existing "best-effort, never raises" fallback chain already in `heimdall-haid`/`heimdall-identity` — degrade to current forking behavior on any mismatch, never hard-fail | item 1 owner |
