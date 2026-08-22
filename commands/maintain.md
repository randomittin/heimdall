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
too, filtered on label `maintainer`, not `bug,seeker`. **A seeker-filed issue is
not automatically picked up by that engine** — see `commands/maintain-check.md`
for the gap and the manual workaround. The two pipelines are independent; running
this one does not feed the other.

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

Spawn a **seeker agent** (the log-based connector) to:
1. Pull logs from Kubernetes pods (or local logs, docker, cloud)
2. Analyze for errors, crashes, anomalies
3. Deduplicate by stack trace signature
4. File GitHub issues with full context (labeled "bug,seeker") — into the same
   queue that human-opened GitHub issues land in.

## Phase 2: Fix

Spawn a **fixer agent** to:
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
