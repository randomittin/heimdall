---
name: maintain
description: Run automated maintenance — seeker finds bugs from pod logs and raises GitHub issues, fixer picks them up and creates PRs. Can run as a one-shot or scheduled via /schedule.
---

# Maintain — Automated Bug Detection & Fix Pipeline

Two-phase maintenance: **seek** then **fix**.

## Usage

`/hmd:maintain` — run once (seek + fix)
`/hmd:maintain seek` — only find bugs, raise issues
`/hmd:maintain fix` — only fix existing issues
`/hmd:maintain auto` — schedule recurring via /schedule

## This pipeline vs the engine-driven autopilot

This file describes the **prose** seek/fix pipeline: two agents (seeker, fixer)
making direct `gh` CLI calls. It does **not** use `bin/heimdall-issue-queue` or
`bin/lib/connectors/` — the seeker files issues straight to GitHub with `gh issue
create`, and the fixer lists them straight back with `gh issue list --label bug
--state open`. The shared `bug` label is the only "queue": whatever carries it is
in scope for the next fixer pass, oldest first.

A **separate**, engine-driven autopilot (`/hmd:maintain-check`, backed by
`bin/heimdall-maintain-loop` → `bin/heimdall-issue-loop`) uses the real
normalized, prioritized, multi-source queue (`bin/heimdall-issue-queue`, piece b
of the issue-resolution-loop design) — but its own GitHub sync
(`sync_queue_from_github` in `bin/lib/maintain_loop.py`) talks to `gh` directly
too, filtered on label `maintainer`. **The seeker now applies that label**
(`bug,seeker,maintainer` — see `agents/seeker.md`), so a seeker-filed issue IS
ingested by the engine. Until 2026-08-23 it was not: seeker filed `bug,seeker`
and the engine requested `maintainer`, and `gh`'s `--label` filter is a
superset/AND match rather than an OR, so the two sets never intersected and the
seek-then-fix loop had never once run end to end.

The two pipelines remain independent in every other respect — this prose one
discovers via its own `gh issue list`, and running it does not drive the engine.

## Connectors — pluggable, but not in THIS pipeline

`bin/lib/connectors/` (github/slack/email/corpus) + `bin/heimdall-issue-queue`
are real and working — proven by direct execution, not just by reading the
source — but they back the *engine* autopilot above, not the prose pipeline in
this file. To feed a non-GitHub source into that engine's queue by hand:

```bash
heimdall-connector fetch <source> --config issue-loop.config.json > raw.json
heimdall-issue-queue ingest --source <source> --raw @raw.json
```

Any configured, credentialed source (slack, email, corpus) works this way; an
unconfigured one degrades to `fetch` returning `[]`, never a crash.

## Phase 1: Seek

```
Agent(subagent_type: "hmd:seeker", description: "scan logs, file bug issues", run_in_background: true)
```

`hmd:seeker` (the log-based connector):
1. Pull logs from Kubernetes pods (or local logs, docker, cloud)
2. Analyze for errors, crashes, anomalies
3. Deduplicate by stack trace signature
4. File GitHub issues with full context (labeled "bug,seeker") — into the same
   queue that human-opened GitHub issues land in.

## Phase 2: Fix

```
Agent(subagent_type: "hmd:fixer", description: "pick oldest open bug issue, fix, PR", run_in_background: true)
```

`hmd:fixer`:
1. Pick open issues directly from GitHub: `gh issue list --label bug --state
   open` (no `issue_queue` involved — see "This pipeline vs the engine-driven
   autopilot" above).
2. For each issue (oldest first):
   - Create a `heimdall/*` fix branch from main
   - Implement the minimal fix
   - Attest (SI-2) — evidence = recorded real exits; a proof-less fix is un-PR-able
   - **Open the PR ONLY via `bin/heimdall-issue-pr open`** (routed through the
     scoped bot token) — the fixer NEVER pushes a branch or opens a PR by hand,
     NEVER pushes to main, NEVER merges. Autonomy ends at PR-open; a human merges.
3. Move to next issue

Multiple unrelated issues queued: spawn one `hmd:fixer` per issue, each
`run_in_background: true` and `isolation: worktree`, so fix branches don't
collide (`agents/fixer.md` "Parallelism — MANDATORY").

Note: the separate engine-driven autopilot (`/hmd:maintain-check`) does NOT spawn
`hmd:fixer` — its own `bin/lib/issue_loop.py` drives a headless `claude -p` fix
step directly (`default_fix_runner` / `_run_claude_fix`). The two "fix a bug"
implementations are not unified; `hmd:fixer` only runs via this manual command.

## Phase 3: Auto (scheduled)

Set up recurring maintenance:
```
/schedule "/hmd:maintain" --cron "0 */6 * * *"
```

Or every 6h inside a live session:
```
/loop 6h /hmd:maintain
```

This runs seeker first, waits for issues to be created, then runs fixer on the new + existing issues.

## Rules
- Seeker checks for duplicate issues before creating
- Fixer creates one `heimdall/*` branch + one PR per issue, opened ONLY via the
  scoped bot token (`bin/heimdall-issue-pr open`) — never by pushing or opening a
  PR by hand
- Fixer never modifies main directly, never pushes to main, never merges
- A proof-less fix (`evidence.all_passed != true`) is un-PR-able
- If a fix is unclear, fixer comments on the issue instead
- All PRs need human review before merge (the human merge is the only path to
  resolution / write-back)
