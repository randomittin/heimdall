# Maintainer Mode Guide

Maintainer mode turns Heimdall into an autonomous repo maintainer that triages issues, fixes bugs, and manages releases.

## Activation

```
/hmd:maintain
```

This runs a guided setup wizard that:
1. Verifies GitHub CLI is authenticated
2. Configures issue sources (GitHub, logs, error tracking)
3. Sets monitoring frequency (15m / 30m / 1h / on-demand)
4. Optionally configures Slack notifications
5. Enables maintainer mode and runs the first check immediately

For subsequent activations, `/hmd:maintain` remembers your configuration.

## Continuous Monitoring

After activation, keep the monitor running with:
```
/loop 30m /hmd:maintain-check
```

Or for persistent monitoring that survives session restarts:
```
/schedule maintain-check --cron "*/30 * * * *" --command "/hmd:maintain-check"
```

Each `/hmd:maintain-check` invocation runs one full cycle: scan → triage → fix → release.

## Issue Ingestion

### Sources

1. **GitHub Issues** (primary): `gh issue list --state open --json number,title,body,labels,createdAt`
2. **Direct reports**: User mentions issues in conversation

Not implemented: log-file and error-tracker ingestion. `maintainer.log_paths` and
`maintainer.error_tracking` exist as state keys — `bin/heimdall-state:357` adds them on migration —
but nothing reads either one. No code parses log files for ERROR/FATAL, and no code talks to Sentry
or Elastic. Point the maintainer at those sources by hand, or file them as GitHub issues.

## Triage Workflow

```
Issue detected
  → Classify severity
  → Classify confidence
  → Route to appropriate handler
```

### Severity Classification

| Severity | Criteria | Response Time |
|----------|----------|---------------|
| **Critical** | Service down, data loss, security breach | Immediate |
| **High** | Major feature broken, significant UX issue | Within session |
| **Medium** | Minor feature issue, non-blocking bug | Next batch |
| **Low** | Typo, cosmetic, minor improvement | Batch with patch |

### Confidence Classification

| Confidence | Criteria | Action |
|------------|----------|--------|
| **High** | Clear root cause, straightforward fix | Auto-fix |
| **Medium** | Likely cause, needs investigation | Investigate then fix |
| **Low** | Unclear, multiple possibilities | Escalate to human |

### Routing Matrix

| Severity × Confidence | Action |
|----------------------|--------|
| Any × Low | Escalate with context |
| Critical × Any | Alert + hotfix agent + human approval |
| High × High | Auto-fix + PR + request review |
| High × Medium | Investigate + fix + PR |
| Medium × High | Auto-fix, batch into patch release |
| Medium × Medium | Investigate, add to release queue |
| Low × High | Auto-fix, batch into patch release |
| Low × Medium | Add to release queue |

## Auto-Fix Protocol

1. Create feature branch: `fix/<issue-number>-<short-description>`
2. Spawn coder agent with issue context
3. Run test suite via test-runner agent
4. Run lint via lint-quality agent
5. Run review via reviewer agent
6. Create PR with:
   - Issue reference: "Fixes #<number>"
   - What changed and why
   - Test coverage summary
7. If all quality gates pass and severity ≤ medium:
   - Add to `maintainer.release_queue`
8. If critical or high:
   - Request human review

## Batched Patch Releases

Group related small fixes into patch releases:

1. Collect fixes from `maintainer.release_queue`
2. Ensure all tests pass together
3. Bump version (patch for fixes, minor for features)
4. Generate changelog from commit messages
5. Create release tag + GitHub release
6. Clear the release queue

## Self-Improvement (run between fix batches)

Maintainer mode is not only reactive — it improves its OWN capability over time. Step back between
batches of fixes and run ONE bounded self-improvement experiment through the `self-improve` skill
(`bin/heimdall-self-improve`). Nothing schedules this: there is no automatic every-Nth-cycle
trigger, and no code counts cycles toward one — see *Not implemented: the automatic
every-Nth-cycle trigger* in `commands/maintain-check.md`. The steps:

1. **Collect** the comparable scalar — first-attempt AC pass-rate per `(task_type, model)` — from
   `.planning/metrics.jsonl` + queue dead/done stats.
2. **Hypothesize** — escalate a failing tier, cheapen a flawless one, or flag a recurring
   dead-reason cluster for a pre-check / new `.planning/skills/*.md` pattern.
3. **Experiment (bounded)** — apply a routing-override variant to `.planning/routing-overrides.json`;
   the next cycles run the variant. Note that nothing reads that file yet, so the override records
   the finding rather than changing which model gets spawned — apply a kept override by hand.
4. **Evaluate (measured)** — KEEP the override only if a measured pass-rate delta beats the baseline
   on enough samples; otherwise **roll it back**. Validated wins land as routing overrides, new
   `.planning/skills/*.md` patterns, or a `heimdall-feedback` ISSUE suggesting a repo-level fix.

This is [karpathy/autoresearch](https://github.com/karpathy/autoresearch) applied to Heimdall's own
routing — falsifiability over vibes. Details: `skills/self-improve/SKILL.md`,
`docs/analysis/autoresearch-distilled.md`. Invoked on demand via `/hmd:self-improve`, or as the
documented step-back inside a `/hmd:maintain-check` run.

### Overnight: `/dream`

For an off-hours pass, `/dream` (`commands/dream.md`, `bin/heimdall-dream`) runs this self-improve
loop **and** a maintainer sweep together, then leaves a **morning report** at
`.planning/dream/YYYY-MM-DD.md` — suggested changes, issues raised with proposed fixes, and kept
(measured) improvements. It is **shadow-first**: risky routing changes are surfaced for review, not
auto-applied; only the keep-gate's measured, reversible wins persist. It never pushes or merges.
Schedule it with `/schedule "/dream --overnight" --cron "0 3 * * *"`.

## Communication

Maintainer mode communicates progress naturally:

- **Issue found**: "Spotted a null pointer in the auth middleware. Investigating."
- **Fix in progress**: "Root cause found — expired token handling was missing a check. Writing fix with tests."
- **Fix ready**: "Fixed in PR #47. Tests pass. Ready for v1.2.4."
- **Needs help**: "Stuck on #23 — the expected behavior isn't clear from the issue. Can you clarify?"

## State Tracking

All maintainer activity is tracked in heimdall-state.json under the `maintainer` key:

```json
{
  "maintainer": {
    "enabled": true,
    "issue_sources": ["github"],
    "pending_fixes": [
      {"issue": 23, "status": "investigating", "agent_id": "agent-001"}
    ],
    "release_queue": [
      {"issue": 45, "pr": 47, "severity": "low"}
    ]
  }
}
```
