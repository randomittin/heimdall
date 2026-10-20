# Dynamic closure spike (2026-10-20)

Question: does tracing what a suite actually executes and reads give a much smaller closure than the static one
(`bin/lib/suite_closure.py`, branch `suite-cache-closure`, 79843d87), cheaply and soundly enough, on macOS without root?

Scope and honesty: a spike, stopped early on the coordinator's instruction. Anything not measured is marked
**UNMEASURED** and carries no estimate. Scratch scripts lived in the session scratchpad and are not committed. Everything ran
from a throwaway `git worktree add --detach` of main (3a0f2c0b), removed afterwards; the main checkout was not touched.

## 1. What was tried, and what worked

| Mechanism | Result |
|---|---|
| `sandbox-exec -p '(version 1)(trace "<file>")(allow default)'` | **Dead.** Profile accepted, command runs, the trace file is never created (tried under the scratchpad and `/tmp`). `(allow file-read* (with report))` is accepted but `/usr/bin/log show` shows nothing for it; `(deny ... (with report))` is rejected ("report modifier does not apply to deny action"). |
| `fs_usage` | **Dead without root** ("must be run as root"). |
| `dtrace` / `dtruss` | **Dead.** SIP is on: "DTrace requires additional privileges". |
| `DYLD_INSERT_LIBRARIES` interposer | UNMEASURED (not tried). `/bin/bash` and `/usr/bin/*` are system binaries, so it is expected to be stripped. That is an expectation, not a result. |
| `BASH_ENV` script (`be.sh`) | **Works** for `bash script`, `#!/usr/bin/env bash` and `bash -c`. It does **not** run for `#!/bin/sh` scripts (checked: no hook output). It cannot know the script path at source time (`$0` is `bash`), so script identity comes from a one-shot `DEBUG` trap reading `BASH_SOURCE[0]`. |
| `xtrace` with `BASH_XTRACEFD` | Not usable here. `/bin/bash` is 3.2.57 and no other bash is installed (`/opt/homebrew/bin/bash` absent). I did not test the variable on 3.2; the 4.1 introduction is from the bash documentation. Plain xtrace goes to stderr, which suites capture, so it was not attempted. |
| Shadow shell functions (`cat jq grep sed awk head tail cp mv diff ... python3 node git`, plus `source` and `.`) that log their expanded args to fd 63 | **Works**, near-zero cost (a `printf`, no fork). Records expanded arguments, which a static scan cannot see. |
| `sitecustomize.py` on `PYTHONPATH` with `sys.addaudithook` (open, import, exec, Popen, listdir) | **Works** (smoke-tested: repo opens were logged). |
| `NODE_OPTIONS=--require node-trace.js` patching `fs.*` | **Works** (smoke-tested). |
| PATH shim for `env` that re-injects the tracer variables across `env -i` | Written. End-to-end propagation across `env -i` is **UNMEASURED**: my one smoke check was inconclusive, so treat it as unproven. |
| PATH shim logging every repo binary | Not built. Script identity (`BASH_ENV`) covers the 188 `#!/usr/bin/env bash` scripts under `bin/` and the python audit hook the 36 `python3` ones. Not covered: the 2 `#!/bin/sh` scripts and the 2 compiled Mach-O tools (`bin/edit-tracker`, `bin/parallelism-tracker`). |

Net: the only no-root options are userland hooks inside the interpreters. They record arguments and interpreter-level
opens, not syscalls.

## 2. Measured numbers

### Static baseline (engine run at main, 3a0f2c0b, `hash-all` takes ~7 s for all 538)

- 538 suites; 2028 tracked nodes. Closure size: median 617, p90 710, max 2028 (a whole-tree suite).
- 496 of 538 suites reach `bin/heimdall`.
- Diff `7b5a0e49..main`: 126 files (119 excluding `.planning/`). Static re-run set = **505 of 538 (93.9%)**.
- 48 of those are suites whose own test file changed, so about 457 are pure dependency hits.
- A single edit to any one of the 9 changed `bin/lib/*` files (`hmd_session_code.py`, `install-receipt.sh`,
  `hmd_push_target.py`, `hmd_repo_receipt.py`, `hmd_session_login.py`, `hmd_ci_guard.py`, `hmd_disk_floor.sh`,
  `hmd_repo_checks.py`, `hmd_pair_optin.py`) selects **501 of 538** suites under the static closure.
- The engine ran without hints: `test/closure-hints.json` does not exist on main.

### Traced closures: suites selected

- A single `bin/lib` edit under traced closures: **UNMEASURED**.
- Diff `7b5a0e49..main` under traced closures (% of 538): **UNMEASURED**. I did not run the aggregator over the 12
  logs, only over one, so there is no honest extrapolation. The sample (n=12) is also too small and too hand-picked.

### Overhead (single runs, 12 suites, base vs traced)

Conditions: load average ~2.7 on 10 CPUs, a full sweep running on main, two batches in parallel, one run each. Seconds:

| suite | base | traced | | suite | base | traced |
|---|---|---|---|---|---|---|
| heimdall-team-autojoin (hub, closure 2028) | 3.58 | 3.05 | | issue-loop (node) | 4.63 | 3.53 |
| heimdall-presence-optout (env -i) | 3.88 | 5.49 | | paste-secret-filter | 2.63 | 2.46 |
| heimdall-identity (env -i) | 0.88 | 0.77 | | heimdall-sigil-cache | 0.07 | 0.08 |
| heimdall-statusline-density (env -i) | 2.18 | 2.38 | | heimdall-caveman | 0.98 | 1.04 |
| heimdall-cc-selfheal (env -i) | 3.24 | 3.37 | | heimdall-swarm-hud | 1.35 | 0.82 |
| heimdall-stub-scanner | 0.66 | 0.94 | | hmd-metrics (node) | 8.34 | 3.54 (red, excluded) |

Over the 11 comparable pairs: 24.08 s base vs 23.93 s traced. Per-suite deltas run from -39% to +42%, all inside machine
noise. **No overhead is distinguishable from noise; a controlled measurement is UNMEASURED.** Caveat: ten of the twelve
traced runs used the first `be.sh`, before the two fixes in section 4; only `team-autojoin` and `hmd-metrics` were re-run
on the final one.

### Fidelity: did tracing change the suites' verdicts?

- First `be.sh`: 2 of 12 suites went red under tracing (`heimdall-team-autojoin` rc 1, `hmd-metrics` rc 1; both with
  rc 127 `env: bash: No such file or directory`). Cause: my shadow functions changed what `command -v` prints (see section 4).
- After the fix: `team-autojoin` green again. `hmd-metrics` is still red under tracing (rc 1), cause not diagnosed.
- The other 10 were not re-run on the final `be.sh`, so "10/10 stay green" is UNMEASURED.

### Dependencies the traced run saw that static missed

- `heimdall-stub-scanner`: static closure is 2 files; the trace saw 3 file reads
  (`bin/lib/heimdall-stub-patterns.sh`, `hooks/hooks.json`, the suite). `bin/lib/heimdall-stub-patterns.sh` is **not in the
  static closure**: one real static miss, the only suite whose trace I analysed. Why the engine missed it is not
  investigated. Static-miss rate over the other 11 is **UNMEASURED**.
- Precision problem in the other direction: the same trace also logged directories `evals` and `fixtures` and 112 tokens
  equal to the repo root. These are scanner patterns and `git -C $REPO` / `cd $REPO` arguments, not reads. Argument-level
  tracing over-approximates (directory tokens would expand to 433 extra files if taken as dependencies) and needs
  per-command rules to tell a read from a mention.

## 3. Verdict: drop the idea as a narrowing or replacement layer

- **Do not replace the static closure.** Traces are arg-level, not syscall-level, so the closure would be unsound by
  construction. Blind spots, all confirmed by reading the mechanisms, none measured for frequency:
  - redirections (`< file`, `$(<file)`, `read < f`);
  - builtins (`[ -f ]`, `test`, `cd`, `[[ ]]`);
  - glob expansion;
  - absolute-path commands, which bypass the shadow functions (`/usr/bin/python3` appears 35 times, `/bin/python3` 9 times, in `test/*.test.sh`);
  - `#!/bin/sh` scripts (no `BASH_ENV`);
  - `env -i` children (48 suites use `env -i`, 3 `test/lib` files too; propagation via the shim is unproven);
  - the 2 compiled tools and any suite that overrides `PYTHONPATH` or `NODE_OPTIONS`.
- **Do not use it as a narrowing layer.** Narrowing removes re-runs, so every blind spot becomes a missed regression,
  which is the unsafe direction for a cache whose job is "never re-run less often than it should". The 7-day age limit and
  audit sample only bound this, they do not detect it.
- **No evidence it would even help.** The size of a traced closure is UNMEASURED, and the one suite analysed (stub-scanner)
  shows a trace gets noisy for the opposite reason (mentions counted as reads).
- **The one useful finding is the other direction:** a traced run is a cheap *detector of static misses* (stub-scanner).
  If kept at all, use it as a union-only audit during a normal sweep (record, report any traced repo file outside the
  static closure, add it to `closure-hints.json`), never to shrink a closure. It would need the section 4 fixes first.
- **Splitting the hub is where the size win is, but this spike did not measure it.** The only numbers: 496/538 suites
  reach `bin/heimdall`, and a single `bin/lib` edit selects 501. Which hub edges to break, and what each break would save,
  is **UNMEASURED**.

## 4. Blockers and defects hit

1. **`exec` + `2>/dev/null` silently redirects the shell's stderr for good.** `exec 63>>"$HMD_TR_LOG" 2>/dev/null || return 0`
   in `be.sh` is an exec with only redirections, so the `2>/dev/null` is permanent. It both emptied the log and would have
   hidden every suite's stderr. Fixed as `{ exec 63>>"$HMD_TR_LOG"; } 2>/dev/null || return 0`. Any in-shell tracer for this
   repo must avoid this.
2. **Relative log path.** The harness gave `HMD_TR_LOG` as a relative path and the suite `cd`s elsewhere, so the log
   was empty. Fixed with an absolute path.
3. **Shadowing commands with functions changes `command -v`.** Suites build restricted PATHs from `command -v jq|bash|...`;
   a function makes that print the bare name, so the sandbox PATH lacked the tool (rc 127). Two of 12 suites red.
   Mitigation applied (a `command` wrapper that answers `-v` with `type -P`, and no shadows for `bash`/`sh`) fixed one;
   the other (`hmd-metrics`) still fails, cause unknown. This is an inherent fidelity risk of the function approach.
4. **Bash 3.2 only**: no `BASH_XTRACEFD`, so no side-channel xtrace; `BASH_ENV` is ignored by `/bin/sh`.
5. **`DEBUG` trap first-fire** logs `be.sh` itself unless filtered (filtered by path).
6. **Shared state:** the traced run depends on the suite not resetting `BASH_ENV`, `PYTHONPATH`, `NODE_OPTIONS` or `PATH`.
   A suite's own `PATH=` replaces the shim directory. How many do: UNMEASURED.
7. **`docs/analysis/` is gitignored** (existing files there are tracked by force-add); this doc was committed with `git add -f`.

## UNMEASURED (not estimated)

Traced re-run % for the diff; traced selection for a single `bin/lib` edit; traced-closure sizes beyond stub-scanner;
static miss rate beyond 1 of 1 analysed; controlled tracing overhead; whether the `env -i` shim propagates the tracer;
the cause of the `hmd-metrics` red under tracing; whether the other 10 stay green on the final `be.sh`;
`DYLD_INSERT_LIBRARIES`; which hub edges to cut and the saving.
