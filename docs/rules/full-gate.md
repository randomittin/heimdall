# When the full gate runs: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

## When the full gate runs — recommended to the developer just before the final merge, never started by an agent
Test once, at the end — operator directive 2026-10-08: avoid over-testing the same
stuff; save testing for the end. Refined by the operator on 2026-11-12, verbatim: *"full
test runs should be recommended to devs along with explanation and token usage -- plus
should always be suggested just before merge operations and not before."* And on
2026-11-22, verbatim: *"only do the full sweep before final merge and not on every
merge."* So the full sweep (`bash test/run-all.sh`, ~524 suites, ~45-60 min cold) is a
RECOMMENDATION to the developer, made at exactly one moment: immediately before the FINAL
merge, on the final frozen tree. "Merge operation" in these docs means that: a push to the
default branch, a PR merge or a pull into the default branch. Integrating agent worktree
branches into a local branch with a local `git merge` is a step inside a batch, not the
final merge, and gets no recommendation. The developer decides. An agent NEVER starts it on its own initiative: not after an agent's
branch is merged, not before a checkpoint, a `/hmd:save` or a demo, not at session start,
not after each file edit, not at mid-work checkpoints (`wip:` auto-commits, a save of
unfinished work), not "to be safe", not "whenever it feels done". It runs only when the
developer says so in that session, and silence is a no. During work the rule is unchanged:
only the tests of the files you touched, once. One run covers a whole batch of merges
while the tree stays unedited. Running it more often costs half an hour a pop
and — worse — grades a tree that is still being edited, which attributes a verdict to a
state of the code that never existed.

**Heimdall's own repo: a push stands on the use-case journey receipt, the full sweep is for releases
(operator decision 2026-11-22, "B").** What is recommended immediately before the final merge in THIS
repo is `bash test/use-cases/run.sh` (the 11 journeys and their mutants, ~6 min), not the sweep. A
green FULL run of it (no `--only`, no `--no-mutants`; every journey passed, every mutant killed) on a
clean, committed tree writes `.heimdall/receipts/use-cases.json` (`bin/lib/hmd_use_case_receipt.py` is
its one definition: commit, tree, counts, time), and `heimdall-state check-quality-gates` takes that
receipt for HEAD IN PLACE of a green full-equivalent sweep receipt: either record passes a push, and
the hooks' own journal and ledger commits after the run do not stale it. The full sweep
(`bash test/run-all.sh`, with everything below about the cache, `--failed`, the freeze and the quiet
gate) is required only for a release: the release script still demands its full-equivalent receipt,
unchanged, and the sweep is what is recommended to the developer immediately before a release. Every
rule below about who may start a run, when it is recommended and how its output is read applies to both.

- **What the developer is shown (the recommendation).** Three things, every time: why (what
  the run proves for this merge), the command (`bash test/run-all.sh`; `--failed` after a
  red) and the cost: wall time (~45-60 min cold; a cached run costs what the change reaches)
  and tokens (an estimate: an agent that reads only the summary spends few, one that streams
  the per-suite output spends many). `bin/lib/hmd_sweep_advice.py` prints it when the final
  merge is about to run (a push to the default branch, a PR merge, a pull into it; never a
  local `git merge`); it only advises, never denies, and `HMD_SWEEP_ADVICE=off` in the
  environment Claude Code runs in turns it off. An orchestrator does not rely on it: it puts
  the same three things to the developer itself, right before the final merge, and waits.
  Not before: a recommendation at a checkpoint, a save, a demo or mid-work is noise the
  developer learns to ignore.
- **When the developer says yes.** Run it ONCE, on the frozen tree, in the background
  (`run_in_background`; wait for the completion notification, never a poll loop: "Wait guard"
  below) with nothing editing, and read only its summary: the lines after the dashed rule at
  the end (the pass/fail counts and `sweep kind`) and, on a red, the names in the receipt's
  `non_green_suites`, never the per-suite stream. The mechanics below (freeze, quiet gate,
  disk floor, cache, `--failed`) apply to a run once it is chosen.
- **Freeze the tree first.** `run-all.sh` reads the working tree as it finds it. No
  edits, and no agents editing, while it runs. A verdict over a moving tree is not a
  verdict.
- **Quiet gate (`--wait-quiet`, opt-in).** Use it on a shared, busy machine to start
  the sweep on a settled box. It is relative and bounded: it waits until the 15-min load
  average is below `HMD_QUIET_FACTOR` (default 1.5) × CPU count on 3 consecutive 30 s
  checks, and gives up after `HMD_QUIET_MAX_WAIT_S` (default 1200 s). Do not use an
  absolute load threshold to block a sweep; it can stay high for hours and defer the run
  forever. On a shared busy machine, lower `--jobs` instead of waiting. When the bound
  passes, the sweep runs anyway with half the jobs and `HMD_TEST_REDUCED_PARALLELISM=1`.
- **Disk floor — 10% free, enforced by hooks (operator directive 2026-10-14).**
  Agent spawns, test runs and single test files all stop below a floor of free disk: a
  full disk fails in ways that look like bugs, and the dev machine was at 7.1% free
  (16.4 GB of 228 GB) while agents ran suites that write fixtures, clones and temp data.
  One definition, `bin/lib/hmd_disk_floor.sh`: the free percent of the volume holding
  TMPDIR and of the one holding the repo (`df -Pk`, Available ÷ size — not df's own
  Capacity column, which on APFS leaves out every other volume of the container),
  against `HMD_MIN_FREE_PCT` (default 10; the operator runs 7 for now; 0 turns it off; a
  typo such as `7%` is the default, said on stderr, never a silent off). Three
  enforcement points: **(1)** the Agent hook (`bin/heimdall-precheck-agent`) DENIES a
  spawn, ahead of the in-process cap so a refused spawn stakes no lease; **(2)** the Bash
  hook (`bin/heimdall-precheck-bash`) DENIES a command that RUNS a `*.test.sh` or
  `test/run-all.sh` (`bash test/x.test.sh`, `./test/x.test.sh`, `cd d && bash x.test.sh`,
  an env prefix, `time`/`timeout`, `sh -c` — never `bash -n`, `cat`, `grep`, `git add` or a
  commit message that only mentions one): one central check, no test file edited;
  **(3)** `test/run-all.sh` REFUSES to start (exit 5, nothing left behind) beside its
  absolute floor `HMD_TEST_MIN_FREE_GB` (default 5; whichever is stricter refuses), and
  asks again before every suite and every solo re-run: once a floor is crossed mid-sweep
  it launches nothing more, the unstarted suites are `REFUSED` (a table row,
  `suites_refused` and `disk_floor` in the receipt, and in `non_green_suites` so the next
  incremental sweep carries them forward) and the run is red (exit 1) — a sweep cut short
  never reads as a sweep that passed. Set the override in the environment Claude Code
  runs in: a hook reads its own environment, so an inline `HMD_MIN_FREE_PCT=5 bash
  test/x.test.sh` reaches the test but not the hook that has already said no. A df that
  cannot answer warns and allows — this is a resource guard, not a security gate. A suite
  that drives the REAL spawn hook pins `HMD_MIN_FREE_PCT=0` (as `agent-name-gate` pins
  `HMD_CTX_GATE_OFF=1`) so it never depends on the disk it runs on. `bin/heimdall-disk-floor
  check` shows where you stand. Proof: `test/disk-floor.test.sh`.
- **Recommend it, and start a chosen run, only when no follow-up fix is still possible.** A
  sweep begun while a reviewer, verifier or agent can still hand back a change is spent the
  moment that change lands: its receipt is stale and every suite that change reaches runs
  again.
- **Batch before you sweep (operator directive 2026-10-11).** Collect every pending
  agent result and merge them ALL, so ONE recommendation covers the batch and, on the
  developer's yes, ONE sweep grades it. Never merge anything between a
  green sweep and its push. If new work arrives after a sweep started, queue it for
  the next batch instead of merging. A failing suite gets fixed, and the fix rides the
  next batch (`--failed`, below); a small follow-up batch costs what it reaches, since the
  sweep is cached (below). Never start a second sweep while one runs. Measured 2026-10-11:
  ~9 full sweeps (~70 min each) in one day — merging agent fixes one at a time staled the
  last green receipt every time, two sweeps overlapped, one wait sat for hours on an
  absolute load threshold, and whole sweeps were re-run to tell load flakes from real
  failures (re-run the one failing suite solo instead).
- **The sweep is cached: it re-runs what a change can reach (2026-10-20).** `bash
  test/run-all.sh` serves a suite from `.heimdall/receipts/suite-cache/` (a `CACHED` row,
  counted green) while its closure hash (every tracked file it can read, found statically
  by `bin/heimdall-suite-closure`) and the runner salt (`run-all.sh` minus comments, its
  guard libs, the engine, tool versions) are unchanged and the entry is under 7 days old.
  max(20, 10%) of the hits re-run anyway (seeded by HEAD and the salt); an audited suite
  that fails with an unchanged closure is `CLOSURE UNSOUND`: red run, cache purged. Each
  green is stored the moment it finishes, so a red, stopped or cancelled run keeps what it
  proved. A suite red under parallel load but green on its solo re-run (`FLAKY-UNDER-LOAD`)
  is stored too, since the solo run is already its verdict for the exit code, the gate and
  the release script: a cold sweep whose only blemishes are such suites stays cold and
  full-equivalent (a minor release is reachable on a loaded host), and each flake stays in
  the receipt (`flaky_under_load`) and the summary; a suite red in both runs is red and
  stores nothing. The receipt stays `kind:"full"` plus a `cache` block and `full_equivalent`; the
  push gate and the release script re-derive it (`bin/heimdall-suite-closure
  verify-receipt`), never on the flag's word. `--cold` (or `HMD_COLD=1`) ignores the cache
  and runs every suite: an x.y.0 release needs that cold receipt, a patch release takes a
  cache-composed one, and the first sweep after a runner change is cold by itself.
  `--no-cache` skips it (legacy receipt). It is also off, said on the `cache:` line, for a
  dirty tree, `--filter` and an incremental `--since-green` (the older textual selection,
  still there; the cache is what follow-up batches use).
- **After a red: `--failed`, never a second full sweep.** Fix, commit (a dirty tree turns
  the cache off and `--failed` refuses, exit 2), then `bash test/run-all.sh --failed`: it
  re-runs the last receipt's non-green suites, every suite whose closure the fix moved and
  the audit sample, serves the rest from the cache, and composes a gate-grade receipt
  (`amended_from`, `amended`). A test-only fix re-runs that suite and the sample, not the
  sweep. Not combinable with `--cold`, `--no-cache`, `--since-green` or `--filter`.
- **Order, `--fail-fast`, keep-awake.** Suites start failed-last-time first, then
  changed-closure, then new, then slowest-first. `--fail-fast` stops starting suites once
  a red is confirmed by its solo re-run, so a red shows in minutes, not at the end; a run
  it stops early writes `kind:"aborted"`, which the push gate and the release script refuse
  by name, so after one: fix, commit, `--failed`. On macOS the runner holds `caffeinate -i
  -w <its pid>` for the whole sweep, so the machine cannot idle to sleep mid-run
  (`HMD_NO_CAFFEINATE=1` opts out).
- **Per-suite runs: your own suite only, once.** An agent runs
  `bash test/<one>.test.sh` for ONLY the test file(s) it adds or edits, ONCE, after
  ALL its changes are written — no neighbouring or "regression" suites, no baseline
  sweep. Once means once per state of the tree: a re-run needs an edit that targets
  the failure (the TDD RED run and a break-it-and-watch-it-go-RED check each run a
  different tree), while a second run of an unchanged tree is the waste. A failure
  plausibly caused by machine load (timeout, port clash, agents running alongside)
  gets ONE solo re-run, then it is real: fix it or report it. Regressions elsewhere
  are for the merge-time full run, if the developer chooses one.
- **The orchestrator does not re-run suites per merge, and does not start the sweep
  itself.** It takes each agent's reported run as given, integrates (a local `git merge`
  of each agent branch: no recommendation, no run) and, immediately before the final
  merge, recommends the one full run to the developer; only the developer's yes starts it.
- **Measured, 2026-10-08 chat-replies wave:** three coder agents hit their 50-turn
  limit mid-regression after running 10–25 neighbouring suites each, one suite was
  re-run three times under load, and the orchestrator re-ran the same suites after
  merging, then cancelled a full sweep when fixes landed.
- **The `git push` hook stack is unchanged and stays.** It is a fail-closed backstop,
  not a duplicate of this rule: the merge-time recommendation is the developer's call,
  the pre-push gate is the machine's guarantee. In this repo a push still needs a green
  receipt, a use-case journey receipt or a full-equivalent sweep receipt, so a developer who
  declined the run meets that gate at the push.
- **Already machine-enforced, in part.** `bin/heimdall-conformance` reads the session
  transcript and fails `gate-runs-once` (two full-gate runs with no edit between them)
  and `gates-at-end` (the first full-gate run must come AFTER real work). It also fails
  `sweep-staled-by-merge` (a green sweep, then a merge or commit of real work before
  the push, then another sweep) and `sweeps-overlap` (two full-gate runs whose
  start/end intervals overlap). Those grade the runs that happen: they read tool calls,
  not the developer's yes, so "an agent starts no full run unasked" is held by this text
  and the merge-time advice (which recommends and never blocks), not by a check. This
  section is the human-readable statement of the rules the enforcer does check — if the
  two ever disagree, the enforcer is authoritative and this text is the bug.
