---
name: maintain-check
description: Run one durable maintainer autopilot cycle — budget-gated, stop-guarded, checkpointed. Use --dry-run to preview without executing.
argument-hint: [--dry-run]
disable-model-invocation: true
---

# Maintainer Check Cycle

Run a single maintainer autopilot cycle. This is the command `/loop` or `/schedule`
calls repeatedly. The heavy lifting is NOT prose LLM steps — it is delegated to the
deterministic engine `bin/heimdall-maintain-loop`, which wraps the honest issue loop
(`bin/heimdall-issue-loop` → pick → orient → fix → GATE → attest → PR). The engine
owns the parts that must never drift: the token BUDGET CAP, the run-away STOP
conditions, the approval PARK, agent-pool BACKPRESSURE, and the machine-readable
CHECKPOINT receipt that lets a fresh session resume after death/compaction.

Your job here is thin: gate on enablement, run ONE cycle (or preview it), and report
the receipt. Do not re-implement scan/triage/fix in prose — the engine is authoritative.

## Pre-flight

1. Check maintainer is enabled:
```bash
heimdall-state get '.maintainer.enabled'
```
If `false`, respond: "Maintainer mode is off. Run `/hmd:maintain` to enable." and stop.

## Dry-Run Mode

If `$ARGUMENTS` contains `--dry-run`, DO NOT execute or mutate anything. Show the plan:

```bash
# What the next drain WOULD do — budget snapshot + queued issues in pick order +
# the action each would take (park for approval vs fix+gate+PR). Mutates nothing.
heimdall-maintain-loop plan --repo .

# The current queue buckets + in-flight machine states (read-only).
heimdall-issue-loop status --repo .
```

Render the preview from that JSON (issues found, per-issue WOULD-action, whether the
run would STOP on budget/empty-queue, and the release-queue state). Example shape:

```
DRY RUN — Maintainer Autopilot Preview
======================================
enabled: true   budget: 12,400 / 600,000 tokens (2%)   over: false

Queued (pick order):
  github:acme/api#45  High     → WOULD: fix + GATE + PR
  github:acme/api#42  Critical → WOULD: park for human approval (approval-wait)
  github:acme/api#38  Low      → WOULD: fix + GATE + PR

Would stop: (none — work remains)

No changes made. Run without --dry-run to execute.
```

## Execute One Cycle

Otherwise, run exactly ONE cycle through the engine. The engine checks the budget
BEFORE running (an over-cap or unreadable meter STOPS without spending), picks the
highest-priority issue, drives the full fix→GATE→attest→PR path, and appends the
autopilot header block to `.planning/CHECKPOINT.md`:

```bash
# --max 1 = one issue this cycle. --evidence supplies the runnable gate command(s)
# SI-2 executes (the repo's real test/acceptance command); their recorded real exit
# is the gate verdict (the cardinal rule — never a self-report). Pass the project's
# actual gate command here, e.g. --evidence "npm test" (repeatable).
heimdall-maintain-loop run --repo . --max 1 --evidence "<project gate command>"
```

The engine returns a JSON summary `{cycles, stop, tally, last, budget, heartbeat}`.
Possible `stop` values and what they mean:

| stop | meaning | what to do |
|------|---------|------------|
| `null` | paused with work remaining (e.g. --max reached) | re-arm next cycle |
| `budget` | token cap hit (or meter unreadable) | STOP — do not spend more |
| `empty-queue` | nothing pickable | idle until new issues arrive |
| `repeated-failure` | N consecutive gate failures on distinct issues | STOP — escalate to a human |
| `disabled` | maintainer is off | nothing ran |

A per-issue **approval-wait** park (severity ≥ critical, no recorded decision) does
NOT stop the loop — that issue is flagged for a human and the loop continues with the
others. Record a decision with `heimdall-state autopilot-approve <issue-id>` to let a
future cycle pick it up.

## Communicate

Report the one-line receipt (only if there was activity):

```bash
heimdall-maintain-loop heartbeat --repo .
# e.g. "autopilot: cycle 47 · 12 fixed · 2 flagged · 1 PR · budget 36% · last PASS gh-412"
```

- **Fixes / PRs**: quote the heartbeat (fixed / flagged / PR counts + last verdict).
- **Stopped**: name the `stop` reason and whether a human is needed (budget / repeated-failure).
- **Parked**: "Parked #<N> for human approval — decide with `heimdall-state autopilot-approve`."

If Slack skills are available and the user has opted in, post the heartbeat to the
configured channel.

## Self-Improvement — run it yourself

The maintainer can improve its OWN capability over time, not only fix issues. Run ONE bounded
self-improvement experiment through the `self-improve` skill / `bin/heimdall-self-improve` as a
deliberate step-back BETWEEN fix batches — never mid-fix:

```bash
# 1) surface testable hypotheses from the accumulated evidence.
#    --min-samples here filters which (task_type, model) cells are even worth a hypothesis;
#    it is NOT the keep-gate. The keep-gate is `experiment start --min-samples`.
#
#    That keep-gate does NOT default to the floor. Both subcommands default to
#    DEF_MIN_SAMPLES = 3 (bin/heimdall-self-improve). The floor of 20 lives in
#    MIN_SAMPLES_FLOOR (bin/heimdall-dream), which clamps upward — so it applies when you go
#    through `/dream`, and NOT when you call heimdall-self-improve directly, as this block
#    does. Pass 20 explicitly on the keep-gate or you are keeping a routing change on
#    3 observations, where a variant that is genuinely no better still clears a 0.10 delta
#    about 73% of the time. See skills/self-improve/SKILL.md.
heimdall-self-improve hypotheses --repo . --min-samples 3

# 2) evaluate any OPEN experiment whose variant has now accrued enough samples
#    (KEEP only on a measured delta; else it rolls the override back — the falsifier)
for exp in $(heimdall-self-improve status --repo . | jq -r '.open_experiments[]?'); do
  heimdall-self-improve experiment evaluate --id "$exp" --repo .
done
```

Then pick the single highest-value hypothesis and `experiment start` it (bounded — the next cycles
run the variant). An "improvement" persists ONLY with a measured pass-rate delta over its baseline;
otherwise the override is rolled back. See `skills/self-improve/SKILL.md` and
`docs/analysis/autoresearch-distilled.md`.

### Not implemented: the automatic every-Nth-cycle trigger

There is no automatic trigger. `self_improve` is not a key `heimdall-state init` creates, so
`heimdall-state get '.maintainer.self_improve.every'` returns the string `null` — which means a
`${EVERY:-10}` fallback never engages, and `[ "$EVERY" -gt 0 ]` fails with *"integer expression
expected"*. Any cycle-counting guard built on that key evaluates false on every cycle, forever.
`grep -rn self_improve bin/ hooks/ sentinels/ modules/` returns nothing: no code reads the key, and
nothing counts cycles toward it.

Self-improvement runs when you run it — from this section, from `/hmd:self-improve`, or overnight
via `/dream`.

For an OVERNIGHT pass that runs this loop **plus** a maintainer sweep and leaves a morning report
(`.planning/dream/YYYY-MM-DD.md`), use `/dream` (`commands/dream.md`) — shadow-first, never pushes.

## Resume / Re-arm

The engine writes a durable checkpoint every transition, so a brand-new session can
tell whether to keep going. On SessionStart the orchestrator consults:

```bash
heimdall-maintain-loop resume-hint --repo .
```

It prints the `/loop 30m /hmd:maintain-check` re-arm line ONLY when the checkpoint has
`stop: null` + maintainer enabled + budget remaining; otherwise it prints nothing (a
finished or over-budget run does not auto-resurrect). If running via `/loop`, this
cycle repeats at the configured interval until a terminal STOP.
