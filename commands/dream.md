---
name: dream
description: Overnight autoresearch + maintainer sweep that surfaces a MORNING REPORT — suggested changes, issues raised with fixes, and kept improvements. Shadow-first; never auto-pushes. Runs on-demand or scheduled for off-hours.
argument-hint: [--start-experiment] [--overnight]
disable-model-invocation: true
---

# /dream — sleep on it, wake to a report

`/dream` is Heimdall's OVERNIGHT self-improvement + maintainer pass. It does the deep
work while you're away and leaves a **morning report** (a *dream journal*) to review —
it does **not** auto-apply risky changes. Think of it as "sleep on the codebase and
tell me what you learned." (There is no `/sleep` command — `/dream` is the canonical
name. The underlying capability stays available as `/hmd:self-improve`.)

The heavy lifting is delegated to the deterministic orchestrator `bin/heimdall-dream`,
which REUSES the existing pieces — it invents no new keep/rollback logic:

- **autoresearch / self-improve** (`bin/heimdall-self-improve`) — form routing/planning
  hypotheses from real metrics + queue evidence, and TEST them with the falsifiable
  keep-or-rollback gate. An improvement persists ONLY on a measured delta over baseline.
- **maintainer sweep** (seeker) — raise issues found (recurring dead-reason clusters +
  the live issue queue) WITH proposed fixes, as candidates for a human.

## Invariants (never weakened)

- **Shadow-first** — routing/planning suggestions are SURFACED for morning review, not
  auto-applied. Only the self-improve keep-gate (safe, measured, reversible) may persist
  a change overnight; everything else is a suggestion.
- **Agent-never-pushes** — `/dream` runs no `git push`, no `gh pr`, no merge. It writes a
  local report; you review and apply in the morning.
- **Real, not fabricated** — every line of the report is sourced from actual self-improve
  output + real queue state. With NO evidence yet (empty `metrics.jsonl`) the report says
  *"Nothing to suggest"* honestly rather than inventing work.

## Run it

On-demand (runs the loop now, writes today's report):

```bash
# surface-only (default) — shadow-first: suggest routing changes, don't apply them.
heimdall-dream --repo . run --json

# also START one bounded, reversible experiment (safe per the keep-gate: unvalidated,
# snapshotted, auto-rolled-back next cycle if it does not beat baseline):
heimdall-dream --repo . run --overnight --start-experiment --json
```

`--overnight` is the same run tagged `mode: overnight` (used when a schedule fires it);
`$ARGUMENTS` may pass `--start-experiment` to let the loop start one bounded experiment.

The orchestrator returns a JSON summary
`{date, report_path, mode, honest_empty, pushed:false, counts:{...}}` and writes the
report to:

```
.planning/dream/YYYY-MM-DD.md
```

Find the path any time with `heimdall-dream --repo . where`.

## The morning report (three sections)

1. **Suggested changes** — routing/planning hypotheses with the measured baseline
   (pass-rate over N samples) and expected delta. Apply after review with
   `heimdall-self-improve experiment start --hypothesis <id>`. If `--start-experiment`
   was passed, the one bounded experiment started this run is noted as *pending validation*.
2. **Issues raised & proposed fixes** — recurring dead-reason clusters (each with a
   proposed pre-check / `.planning/skills/*.md` pattern, or a `heimdall-feedback` repo
   issue) plus the live issue-queue state (queued / flagged / in-flight). Flagged issues
   are called out for human triage; the fixer only ever opens a PR via
   `heimdall-issue-pr open`.
3. **Improvements kept** — measured wins from the keep-gate this run (KEPT experiments
   with their delta) and the active validated overrides. Rolled-back experiments are
   listed too, for transparency.

## Report it to the user

- **Signal found**: quote the summary line — "N suggested, M issues, K kept" — and point
  to `.planning/dream/<date>.md`. Surface the top suggested change and any kept win.
- **Honest-empty**: say so plainly — "Dream ran; no task-outcome evidence yet, nothing to
  suggest. Report at `.planning/dream/<date>.md`." Do not manufacture findings.
- Never claim anything was pushed or merged — it was not.

## Schedule it for off-hours (reuse the existing scheduler)

`/dream` does not build its own scheduler — it rides the existing `/schedule` (cron
cloud routine), `/routine`, or `/loop`:

```bash
# nightly at 03:00 via the cron cloud routine (survives session restarts):
/schedule "/dream --overnight" --cron "0 3 * * *"

# or via /routine:
/routine "run /dream --overnight" --every 24h
```

On-demand `/dream` works any time — it runs the loop now and writes that day's report.

## Reference

- Orchestrator: `bin/heimdall-dream` (stdlib python3; `-h` for usage).
- Reused gate: `bin/heimdall-self-improve` + `skills/self-improve/SKILL.md`.
- Maintainer sweep: `commands/maintain.md`, `skills/heimdall/references/maintainer-guide.md`.
- Acceptance: `test/heimdall-dream.test.sh` (hermetic; proves the three sections, the
  reused keep-gate, honest-empty, shadow-first, and agent-never-pushes).
