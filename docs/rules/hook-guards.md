# CI waste guard, wait guard and sweep advice: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

## CI waste guard: never pay to re-roll a flaky result (2026-10-19)
In a client repo an hmd agent worked around a flaky test by pushing an EMPTY commit to retrigger CI and by
re-running the workflow twice: every attempt spent GitHub Actions minutes and the flake was still there.
Operator rule: *a flaky failure is a defect: fix it or report it, never re-roll CI.* The Bash hook
(`bin/heimdall-precheck-bash`, FIRST in its chain, so a refused command never reaches git-guard or the
secret scan) now denies, through `bin/lib/hmd_ci_guard.py`:

- **Empty commits.** `git commit --allow-empty`, wherever the flag sits among the commit's options and
  behind any of git's global options (`-C d`, `-c k=v`, `--git-dir`, ...). `--allow-empty-message`,
  `--no-allow-empty`, and a `-m` value or a path that merely spells the flag are not it.
- **CI re-runs and re-dispatches.** `gh run rerun` (any flags: `--failed`, `--job`, `-R`),
  `gh workflow run`, and a `gh api` POST (`-X POST`, `--method POST`, the POST gh makes by itself once
  `-f`, `-F`, `--field`, `--raw-field` or `--input` gives it a body, or a method that cannot be told) to an
  endpoint ending `/rerun`, `/rerun-failed-jobs`, `/dispatches` or `/rerequest`.
  `gh run list|view|watch|download|cancel`, `gh workflow list|view|enable|disable` and a GET of those
  endpoints stay allowed.
- **Read like a shell, never by grepping text.** The helper reuses the kill guard's lexer
  (`bin/lib/hmd_kill_guard.py`: quotes, `env`/`nice`/`timeout`/`sudo`/`xargs`, chains, pipes, subshells,
  loops, `sh -c`, `eval`, heredocs fed to a shell) and the git option table of
  `bin/lib/hmd_push_target.py`, so text that only MENTIONS a form (echo, grep, a commit message or its
  heredoc, a gh field value) is not a form. A pre-filter starts python only for a command that mentions
  `allow-empty`, `rerun`, `rerequest`, `dispatches` or `workflow ... run`; every other command pays one
  `tr` and one `case`.
- **Operator override: `HMD_CI_RERUN_ALLOW=1`**, set in the environment Claude Code runs in. The hook reads
  ITS OWN environment, so an inline `HMD_CI_RERUN_ALLOW=1 git commit --allow-empty ...` reaches git but not
  the hook that has already said no (the same as `HMD_MIN_FREE_PCT`); only exactly `1` lifts it, and nothing
  of the guard runs then.
- **Fails OPEN, on purpose.** A cost guard, not a security gate: the disk floor's convention, not the kill
  guard's. A helper that is missing, crashes or times out (`HMD_CI_GUARD_TIMEOUT_S`, default 5), or a
  command it cannot read (an unbalanced quote, an expanded heredoc, nesting past 8), is one line on stderr
  and an allow; a form it DID read wins over what it could not. Best effort, said plainly: git and gh are the
  two tools it reads (curl against the API, a git or gh alias, a script on disk are not), and like the push gate's
  receipt it is a cooperating-agent control, not a security boundary.
- **What to do instead** (also in `skills/heimdall/references/definition-of-done.md`, `agents/coder.md` and
  `agents/fixer.md`): fix the flake (a test must not depend on the wall-clock speed of a shared runner:
  count steps, not seconds, or mark it local-only) or report it. Proof: `test/ci-waste-guard.test.sh`.

## Wait guard: never wait in the foreground for your own job (2026-11-10)
General-purpose and hmd:coder agents "went stale after 1-2 h". They were not hung: they sat inside their own shell.
Across all 2102 subagent transcripts (`docs/analysis/2026-11-10-stale-general-purpose-agents.md`) foreground poll loops
(`until grep -q DONE f; do sleep 30; done`, `perl -e 'alarm 595; sleep 595'`, `while pgrep -f job; do sleep 5; done`)
took 167.8 h of general-purpose and 113.6 h of hmd:coder Bash time: a loop waiting for a job the agent itself put in the
background, cut at the 10-minute Bash cap and re-issued, its context growing with every poll until the turn cap or a stall.
The Bash hook (`bin/heimdall-precheck-bash`, after the CI waste guard, the disk floor and the sweep guard) now denies,
through `bin/lib/hmd_wait_guard.py`:

- **A loop that sleeps.** `until`/`while`/`for` whose condition or body runs `sleep` (any duration), also behind
  `env`/`timeout`/`nohup`, in a substitution, `sh -c` or `eval`. **A process poll:** a `while`/`until` whose condition is
  `pgrep` or `kill -0`, with a sleep or without.
- **A long sleep.** A standalone `sleep` of 60 s or more (`1m`, `infinity`), or an interpreter one-liner that sleeps with
  an alarm or for 60 s or more (`perl -e 'alarm 595; sleep 595'`). **`tail -f` / `tail -F`** (and `--follow`).
- **Allowed.** Any call with `run_in_background: true` (read from the payload's `tool_input`), text that only MENTIONS a
  form (echo, grep, a commit message or its heredoc), `sleep` under 60 s outside a loop, loops without `sleep`, `tail`
  without a follow flag.
- **What to do instead.** Run the job with `run_in_background` and wait for its completion notification (or the Monitor
  tool); bound a long command with the Bash `timeout`. Never poll your own job.
- **Operator override: `HMD_WAIT_ALLOW=1`**, set in the environment Claude Code runs in. The hook reads ITS OWN
  environment, so an inline prefix reaches the command, not the hook that has already said no; only exactly `1` lifts it.
- **Fails OPEN, on purpose.** A cost guard, not a security gate (the CI waste guard's convention): a helper that is
  missing, crashes or times out (`HMD_WAIT_GUARD_TIMEOUT_S`, default 5), or a command it cannot read, is one line on
  stderr and an allow. Best effort, said plainly: a wait inside a script file or a python loop is not read, and a loop
  sent to the background with `&` is held like any other (use `run_in_background`). Proof: `test/wait-guard.test.sh`.

## Sweep advice: a full test run is recommended at the final merge, never before (2026-11-12, refined 2026-11-22)
Operator directive, 2026-11-12: *full test runs should be recommended to devs along with explanation and token usage, and always suggested just before merge operations and not before.* Refined 2026-11-22: *only do the full sweep before final merge and not on every merge.* The sweep guard says when a full run is pointless; this says when one is worth it, and it speaks at exactly one moment: the FINAL merge. `bin/heimdall-precheck-bash` asks `bin/lib/hmd_sweep_advice.py`, for a command that mentions merge, push or pull (and git or gh), whether the command IS the final merge: a pull request merge, a pull on the default branch (never a rebasing one), or a push to the default branch (main, master, or what origin/HEAD names). A local `git merge` of refs is NOT: integrating agent worktree branches that way is a step inside a batch and gets no advice, and the push that sends the batch to the default branch is the one that does. Text that only mentions one (echo, grep, a commit message), a merge-base and a push of another branch are not either, and nothing else ever triggers it.

- **What it prints** (hook JSON on exit 0: `systemMessage` for the developer, `hookSpecificOutput.additionalContext` so the agent relays it, never a `permissionDecision`): *Why* (commits and files changed since the last green record, the hooks' own journal and ledger records not counted, or "no green record yet" and the reason), *Run* (`bash test/use-cases/run.sh` for heimdall's own regime: since 2026-11-22 a push stands on the use-case journey receipt, so that is the run recommended, and the full sweep is named only on a `Release:` line as a release's bar, never recommended for a push, whatever a red or running sweep says; `bin/heimdall-repo-checks run` for a repo that declares `.heimdall/repo-checks.json`; lint plus the use-case suite, `skills/heimdall/references/use-case-tests.md`, for any other repo), *Cost* (journeys and mutants, or suites or checks, the last measured wall clock from the receipt (about 6 minutes for the journeys when none is on record), and tokens as labelled estimates: none when the developer runs it in a terminal, a 40-line summary tail times 91 B over 4 when an agent runs it in the background and reads only that, the whole output of (suites + 40) rows times 91 B over 4 when an agent reads all of it) and *Your call*: run it now, or merge without it. A commit the records already prove green gets one line, "already proven green ... nothing to run", and no recommendation.
- **It never blocks, and it speaks last.** The advice is computed after every other gate has let the command through and is the one JSON object on stdout, so a command a gate denies prints only its deny; the parallelism tracker's own output goes to stderr while advice is printed.
- **Silence it.** `HMD_SWEEP_ADVICE=off` (also `0`, `false`, `no`) in the environment Claude Code runs in (read from the hook's OWN environment: an inline prefix reaches the command, not the hook), or `hmd guardrails off sweep-advice` (id `sweep-advice`, a recommended row of `guardrails.manifest.json`; only the lib's exit 1 means off). **Fails open**: a helper that is missing, crashes or times out (`HMD_SWEEP_ADVICE_TIMEOUT_S`, default 8), or a command it cannot read, is one stderr line at most. Best effort, a cost and discipline nudge, not a security boundary. Proof: `test/sweep-advice.test.sh`.
