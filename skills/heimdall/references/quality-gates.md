# Quality Gates Specification

Every piece of work Heimdall produces passes through mandatory quality gates before reaching git.

## Gate 1: Tests Pass

**Requirement**: All tests in the project's test suite must pass.

**Checked by**: test-runner agent or `heimdall-state check-quality-gates`

**State key**: `.quality_gates.tests_passing`

**Protocol**:
1. After any code change, the state is marked dirty: `heimdall-state mark-dirty`
2. Test runner executes the full test suite
3. If all pass: `heimdall-state mark-clean`
4. If any fail: tests_passing remains false, push is blocked

## Gate 2: Lint Clean

**Requirement**: Zero lint errors and zero formatting violations.

**Checked by**: lint-quality agent

**State key**: `.quality_gates.lint_clean`

**Protocol**:
1. Run project's configured linter (e.g., `npm run lint`)
2. Run project's formatter in check mode (e.g., `npm run prettier:check`)
3. If clean: `heimdall-state set '.quality_gates.lint_clean' 'true'`
4. If violations: lint_clean remains false, push is blocked

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

## Manual Override

At autonomy level 3, if the user explicitly says "push anyway" or "force push", the main agent can bypass gates by running:
```bash
heimdall-state mark-clean
git push ...
```

This should be logged as a communication event in heimdall-state.json.
