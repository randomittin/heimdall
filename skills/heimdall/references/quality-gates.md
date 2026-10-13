# Quality Gates Specification

Every piece of work Heimdall produces passes through mandatory quality gates before reaching git.

## Gate 1: Tests Pass

**Requirement**: All tests in the project's test suite must pass.

**Checked by**: test-runner agent or `heimdall-state check-quality-gates`

**State key**: `.quality_gates.tests_passing`

**Protocol** (test once, at the end — `CLAUDE.md` "When the full gate runs"):
1. After any code change, the state is marked dirty: `heimdall-state mark-dirty`
2. Agents run only their own test file(s), once; nobody runs the full suite per change or per merge
3. ONCE, on the final frozen tree, immediately before the landing commit / push / demo / checkpoint, and only when no fix can still land: test runner executes the full test suite
4. If all pass: `heimdall-state mark-clean`
5. If any fail: tests_passing remains false, push is blocked

## Gate 2: Lint Clean

**Requirement**: Zero lint errors and zero formatting violations.

**Checked by**: lint-quality agent

**State key**: `.quality_gates.lint_clean`

**Protocol**:
1. Run project's configured linter (e.g., `npm run lint`)
2. Run project's formatter in check mode (e.g., `npm run prettier:check`)
3. If clean: `bin/heimdall-stop-lint` records the run (`.quality_gates.lint_last_run` plus `lint_clean`) at Stop. Never hand-set `lint_clean`: the push gate re-reads `lint_last_run` and rejects a missing, failing, incomplete, tool-error or stale (a covered file edited after the run) receipt, and `heimdall-state mark-clean` only sets it against a passing one
4. If violations, or a linter that could not run: lint_clean is false, push is blocked. Work merged from sub-agent worktrees is in no session's edit-tracker ledger, so the gate also requires the receipt to cover everything changed since the last push: run `bin/heimdall-stop-lint --since-push` (`bin/heimdall-precheck-bash` runs it for you when the evidence is missing, stale or uncovered; a large diff needs `--budget`, not a waiver). A broken linter blocks until fixed or explicitly waived: `HMD_LINT_WAIVER='<reason>' heimdall-state mark-clean` (recorded in `.quality_gates.lint_waiver_log`, voided by the next lint run)

## Gate 3: Conflict Reflection

**Requirement**: All conflicts in the conflict log have been reviewed and reflected upon.

**Checked by**: main Heimdall agent during `/hmd:reflect` or pre-push

**State key**: `.quality_gates.conflict_reflection_done`

**Protocol**:
1. Read all conflicts: `conflict-log unresolved`
2. For each unresolved conflict, re-evaluate the decision in current context
3. If resolution still sound: `conflict-log mark-reflected <index>`
4. If resolution needs change: update the code, then mark reflected
5. After all reviewed: `conflict-log reflect-all`

## Gate 4: Code Review

**Requirement**: All changes must be reviewed by the reviewer agent before push.

**Checked by**: reviewer agent

**Protocol**:
1. Spawn reviewer agent with current diff
2. Reviewer produces verdict: APPROVE / REQUEST CHANGES / BLOCK
3. CRITICAL issues must be fixed before push
4. WARNING issues should be addressed but don't block
5. Update state: `heimdall-state set '.quality_gates.last_review' '"<timestamp>"'`

## Gate 5: No Dirty State

**Requirement**: No pending changes that haven't been tested.

**State key**: `.quality_gates.dirty`

**Protocol**:
- Any Write/Edit tool use triggers `heimdall-state mark-dirty` via PostToolUse hook — but only in a repo that already has a `heimdall-state.json` (or a legacy `superx-state.json`). Without one the hook skips the call, so run `heimdall-state init` first or this gate never arms.
- Test runner clears dirty flag via `heimdall-state mark-clean`
- Push is blocked while dirty = true

## Pre-Push Verification

The PreToolUse hook on Bash intercepts `git push` commands and runs:
```bash
heimdall-state check-quality-gates
```

This exits with code 2 (blocking the push) if any gate fails. The error message tells the user which gates failed.

**Which gate runs is chosen per repository pushed** (2026-10-13), not by the session's cwd. The hook asks
`bin/lib/hmd_push_target.py` which repositories the command pushes (the cwd, a `-C <dir>` chain, `cd <dir> && ...`,
subshells, wrappers, `sh -c`; git itself names the git directory) and gives each the gate its class owes:

| Class | Marker | Gate |
|---|---|---|
| sweep | a commit has `test/run-all.sh` naming `last-sweep.json` (heimdall's own sweep regime; tracked code, never the receipt) | `heimdall-state check-quality-gates`, run inside that repo: unchanged, fail closed |
| repo-checks | a commit has `.heimdall/repo-checks.json`, the repo's own checks | passes ONLY on a green, current, clean-tree receipt of them bound to the commit, its tree and the declaration's committed bytes (`bin/heimdall-repo-checks run` writes it, `status` verifies it; one definition of the receipt in `bin/lib/hmd_repo_receipt.py`) **and only for the commit the push sends**: every refspec source git resolves (a bare push sends HEAD) must be the receipt's `head_sha`, and `--all`, `--mirror`, `--tags`, a wildcard or push configuration that picks the refs block; stale, red, dirty, missing, mismatched, malformed or invalid blocks and names the runner command |
| unmanaged | no inspected commit has either marker, git resolved the repo, and the command was understood exactly | one `WARNING` line on stderr; the push proceeds |

The class is read from the **commits** (HEAD, its upstream, `origin/HEAD`, `origin/<branch>`, whatever the push
names), never the work tree, and the strictest wins: an uncommitted marker edit changes nothing, and a pushed commit
that drops a marker cannot downgrade a repo whose upstream still has it. Any construct not modelled exactly (a dynamic
or conditional `cd`, `cd -`, a function, `source`, `alias`, a script piped to a shell, `find -exec`, `xargs` handing
over the subcommand, a builtin behind a wrapper that starts a process such as `env cd X`, `env` with an option, an
assignment to `HOME`/`CDPATH`/`PWD`/`OLDPWD`, an unknown git option or subcommand, an unmodelled `GIT_*` variable, a
marker that cannot be inspected) makes the command uncertain, and then EVERY repo involved gets the **sweep** class:
never a warning. Every error path is strict too (git failing, timing out or printing something unexpected, a resolver
that crashes, a corrupt receipt or declaration); the test forces each one. The secret scan, self-scan, oracle and
corpus stages are not part of this rule and are not relaxed. The repo-checks receipt
is a cooperating-agent control, not a security boundary against someone who can write it, exactly like
`last-sweep.json`. See `CLAUDE.md` "Push gate" and `test/heimdall-push-gate-per-repo.test.sh`.

## Manual Override

At autonomy level 3, if the user explicitly says "push anyway" or "force push", the main agent can bypass gates by running:
```bash
heimdall-state mark-clean
git push ...
```

This should be logged as a communication event in heimdall-state.json.
