# Project Conventions (managed by heimdall)

Long form of the rules below (history, mechanics, proofs), moved verbatim: `docs/rules/README.md`.

## Parallelism (MANDATORY)
- 2+ independent tool calls → ONE message (batch Read, Write, Edit, Bash); NEVER read file → read next file → read next file
- 2+ independent tasks → spawn ALL agents in ONE message, `run_in_background: true`; 2+ independent files → one agent per file, ALL together; NEVER spawn agent → wait → spawn another for independent work
- NEVER pass `name:` to Agent unless you will `SendMessage` it: a named agent is mailbox-resident, never self-terminates, never returns a result. Identify a spawn via `description:` (R13)
- The `PreToolUse` `Agent` hook WARNS on `name:` (stderr, exit 0), never blocks. Name one → you own it: collect via `SendMessage`, close with `TaskStop`, sweep leaks with `bin/heimdall-agents orphans`

## Rules
- All code, configs, docs go in this project directory
- Planning state lives in `.planning/` (human-readable, git-committed)
- Each completed task = one atomic git commit
- Acceptance criteria must be runnable (grep, curl, test commands)

## Commit attribution
Every commit produced through hmd carries (hmd is the constant identity):

    Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>

The model's own `Co-Authored-By` (any `@anthropic.com`) is stripped, not kept alongside (owner directive 2026-08-20). It is a TRAILER: author/committer stay human (the identity gate; "a human always gates the merge"). The generated `prepare-commit-msg` hook (`.heimdall/hooks/prepare-commit-msg`) strips model trailers and the retired `hmd@runheimdall.dev` one, appends the hmd trailer if absent, runs even under `--no-verify`, is idempotent, fails OPEN. `runhmd` is a real GitHub account (id `318965969`): its noreply form links with an avatar. Proof `test/prepare-commit-msg-trailer.test.sh`.

## Quality Gates (enforced before git push)
- All tests passing
- Lint clean (zero warnings)
- Code review completed
- No untested changes
- Canonical checklist agents cross-check: `skills/heimdall/references/definition-of-done.md`

## Hook guards
Disk floor, sweep guard, CI waste guard, wait guard, sweep advice: PreToolUse hooks that FAIL OPEN (helper missing, crash, timeout, unreadable command = one stderr line + allow); cost guards, not security boundaries. Operator overrides go in the environment Claude Code runs in (a hook reads its OWN environment; an inline prefix reaches the command, not the hook); `*_ALLOW` lifts only on exactly `1`.

## When the full gate runs — never started by an agent
Test once, at the end (operator 2026-10-08: avoid over-testing the same stuff). Operator 2026-11-12, verbatim: *"full test runs should be recommended to devs along with explanation and token usage -- plus should always be suggested just before merge operations and not before."* 2026-11-22: *"only do the full sweep before final merge and not on every merge."*
- **Your own suite only, once.** Run `bash test/<one>.test.sh` for ONLY the test file(s) you add or edit, ONCE, after ALL changes are written: no neighbouring/"regression" suites, no baseline sweep. Once = once per tree state (the TDD RED run and a break-it-go-RED check run different trees). A failure plausibly caused by machine load gets ONE solo re-run, then it is real: fix or report. Regressions elsewhere belong to the merge-time run, if the developer chooses one.
- **Never start the full sweep** (`bash test/run-all.sh`, 45-60 min cold): not after a branch merge or an edit, at a checkpoint, `/hmd:save`, demo or session start, or "to be safe". The orchestrator RECOMMENDS it (why, command, cost) at exactly one moment, immediately before the FINAL merge (push to the default branch, PR merge, pull into it), on the frozen tree (a verdict over a moving tree is not a verdict), never while a fix can still land; it runs only when the developer says so in that session (silence is a no). A local `git merge` of agent branches is integration, not the final merge. Procedure: `agents/heimdall.md` §6c.
- **Heimdall's own repo (operator decision 2026-11-22, "B")**: recommend `bash test/use-cases/run.sh`; its green receipt (`.heimdall/receipts/use-cases.json`, `bin/lib/hmd_use_case_receipt.py`) stands in for the full sweep at a push. The full sweep is for releases.
- **Batch before you sweep (operator directive 2026-10-11).** Collect every pending agent result and
  merge them ALL, so ONE recommendation covers the batch and ONE sweep grades it; never merge between a green sweep and its push; never start a second sweep while one runs
  (merging agent fixes one at a time staled the last green receipt every time). The orchestrator re-runs no suite per merge.
- **After a red**: fix, commit, `bash test/run-all.sh --failed`; never a second full sweep.
- **Disk floor (operator directive 2026-10-14), enforced by hooks**: agent spawns and runs of `*.test.sh`/`test/run-all.sh` are DENIED below `HMD_MIN_FREE_PCT` free disk (default 10; 0 = off); `test/run-all.sh` also refuses to start below `HMD_TEST_MIN_FREE_GB` (default 5). One definition: `bin/lib/hmd_disk_floor.sh`. Proof `test/disk-floor.test.sh`.
- **The `git push` hook stack is unchanged and stays**: a fail-closed backstop, not a duplicate of this rule.
- **Machine-enforced in part**: `bin/heimdall-conformance` fails `gate-runs-once`, `gates-at-end`, `sweep-staled-by-merge`, `sweeps-overlap` on the session transcript, and is authoritative over this text.
Full text (quiet gate, cache, run order, measured cases): `docs/rules/full-gate.md`.

## Release convergence: one review, one sweep, then ship
Operator 2026-10-21: *fix the too-much-testing and reiterating loop; deliver well, not over-tested.*
- **One review round per release**, of the release diff, after the batch is merged and before the sweep. Fixes are proven by their own RED→GREEN test, never re-reviewed.
- **Only BLOCKER/HIGH block a release.** MEDIUM/LOW → `.planning/BACKLOG.md`, riding the next release. A finding born of this release's own fix, or from a background security review, is triaged the same way (HIGH → fix in this batch). Never chain an agent per finding; scope a fix agent to its finding (no "while you're there" exploration, no new candidate-defect lists unless asked).
- **One sweep, last, the developer's call**: land every fix, recommend ONE full sweep on the frozen tree (the release script still needs its receipt), run it on their yes, ship. A red suite after it: fix, commit, `run-all.sh --failed`. Green, reviewed once and HIGH-free ships.
- **Sweep guard** (hook): `bin/heimdall-precheck-bash` DENIES a FULL `test/run-all.sh` (no `--failed`/`--since-green`/`--filter`/`--dry-run`) while a sweep runs, after a red/aborted last receipt at HEAD or an ancestor, or when a green full receipt already covers HEAD. Override `HMD_SWEEP_ALLOW=1`. Lib `bin/lib/hmd_sweep_guard.py`; proof `test/sweep-guard.test.sh`.

## Pre-commit vs pre-push
- The stub-scan and the oracle-falsifiability + corpus-regression gates stay at pre-commit ON PURPOSE, not an oversight to "fix" by moving them to push: agents commit with `--no-verify`, so the native hook serves a human or non-Claude-Code tool committing directly, and the stub-scan is near-free exactly at that moment.
- The PreToolUse `git push` chain defers, loudly, to the native `.heimdall/hooks/pre-push` when `core.hooksPath` = `.heimdall/hooks` and it is executable, so those gates run once per push, not twice; unwired, the inline check still runs. `HMD_SKIP=1` is the native hook's OWN bypass and never reaches the PreToolUse layer: the dedup excludes it on purpose. Proof `test/pre-push-gate-dedup.test.sh`.

## Push gate: each repo's own checks, not heimdall's
Operator rule, verbatim: *run each repo's own checks, not heimdall's; a repo with its own record of passing checks passes on that record; a repo hmd doesn't manage gets a warning but isn't blocked; don't drop the gate altogether.* `bin/heimdall-precheck-bash` picks the gate per repo pushed (`bin/lib/hmd_push_target.py` asks git which repo; the class is read from the COMMITS, strictest wins): (a) `test/run-all.sh` naming `last-sweep.json` (heimdall's own regime): `heimdall-state check-quality-gates` needs a green full-equivalent sweep receipt or a green use-case journey receipt for HEAD; (b) `.heimdall/repo-checks.json`: `bin/heimdall-repo-checks run` writes the receipt, and the gate passes ONLY on a green one bound to the commit, tree and declaration of EVERY commit the push sends; (c) neither: one `WARNING` on stderr, exit 0. (d) a push whose repository cannot be placed (a variable, substitution or glob in `-C`/`--git-dir`/`--work-tree`, a dynamic `cd`): denied (`cannot place this push`); write the directory out, one command per repo. Fail closed: anything not modelled exactly, a resolver timeout or crash and any error path give the strict class or a block, never the warning. A cooperating-agent control, not a security boundary. Detail, proofs: `docs/rules/push-gates.md`.

## CI waste guard (2026-10-19)
Operator rule: *a flaky failure is a defect: fix it or report it, never re-roll CI.* The Bash hook (`bin/heimdall-precheck-bash`, FIRST in its chain) denies, via `bin/lib/hmd_ci_guard.py`: `git commit --allow-empty`; `gh run rerun` (any flags), `gh workflow run`, and a `gh api` POST (explicit, or implied by a body flag) to an endpoint ending `/rerun`, `/rerun-failed-jobs`, `/dispatches` or `/rerequest`. Read-only gh (list, view, watch, download, cancel, GETs) stays allowed; text that merely mentions a form is not one. Override `HMD_CI_RERUN_ALLOW=1`. Instead: fix the flake (a test must not depend on the wall-clock speed of a shared runner: count steps, not seconds, or mark it local-only) or report it. Proof `test/ci-waste-guard.test.sh`.

## Wait guard (2026-11-10)
Agents "went stale after 1-2 h" in foreground poll loops on jobs they had backgrounded themselves. The Bash hook denies, via `bin/lib/hmd_wait_guard.py`: a loop (`until`/`while`/`for`, also in `sh -c`/`eval`) whose condition or body runs `sleep`; a `while`/`until` polling `pgrep` or `kill -0`; a standalone `sleep` or an interpreter one-liner alarm of 60 s or more; `tail -f`/`-F`/`--follow`. Allowed: any call with `run_in_background: true`, text that merely mentions a form, `sleep` under 60 s outside a loop. Instead: run the job with `run_in_background` and wait for its completion notification; bound a long command with the Bash `timeout`; never poll your own job. Override `HMD_WAIT_ALLOW=1`. Proof `test/wait-guard.test.sh`.

## Sweep advice
`bin/heimdall-precheck-bash` asks `bin/lib/hmd_sweep_advice.py` whether a merge/push/pull command IS the final merge (a PR merge, a pull or push on the default branch; never a local `git merge` of refs or a push of another branch). If so it prints why / run / cost / your call: never a deny, and last, after every other gate. Silence: `HMD_SWEEP_ADVICE=off` or `hmd guardrails off sweep-advice`. Proof `test/sweep-advice.test.sh`.

## Model routing (2026-08-11)
- **Main Claude Code agent: never pinned.** It runs on the user's own default; hmd does not hardcode opus — or anything else — for the main agent.
- **Default coding tier: `sonnet`.** The bare alias, so Claude Code resolves the current generation.
- **opus is retained only for adjudication**: `reviewer`, `verifier`, `security-auditor`. Judging work is where the extra capability pays for itself.
- **Fable 5 is escalation-only** — for a task *looping on bad output*, after sonnet and opus have both failed at the same step. It is not a routing default. It is NOT ZDR (30-day retention), so client repos need `repo-policy allow_non_zdr_models`.
- Never write a full pinned model id into an operational spawn. The tier alias is the contract; `HEIMDALL_MODEL_<TIER>=<full-id>` exists solely for bench reproducibility.

## Code Quality — Zero Tolerance
- NEVER write stub, dummy, placeholder, shim, mock, TODO, or skeleton code
- Every line must be real, working, production-ready
- No `// TODO: implement`, no `pass`, no empty function bodies, no fake data
- If you cannot implement something fully, say so — do not fake it

## Style
- Follow existing patterns in the codebase
- Prefer small, focused files over large monoliths
- Name things clearly — a reader should understand without context

## Edit Verification
- All Write/Edit ops auto-logged by `edit-tracker` (PostToolUse hook); `edit-tracker summary|paths` list what was edited
- `verify-edits` checks all session edits (file existence, stub detection, git diff): `--quick`, `--diff`, `--json`; SessionEnd auto-runs `--quick`

## Token Efficiency
- Caveman compression active: terse output, abbreviations, arrows for causality
- The LEVEL is owned by hmd (`bin/heimdall-caveman`, `hmd caveman get|set|rules`), not the external caveman plugin: one settable level, `ultra`; hmd's stored `$HEIMDALL_HOME/caveman-level` is authoritative. A hook can only inject instruction text, never prove compliance; `hmd caveman-audit <session.jsonl>` measures, never gates
- Drop articles, filler, hedging — code and paths stay exact
