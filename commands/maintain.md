---
name: maintain
description: Run automated maintenance — seeker finds bugs from pod logs and raises GitHub issues, fixer picks them up and creates PRs. Can run as a one-shot or scheduled via /routine.
---

# Maintain — Automated Bug Detection & Fix Pipeline

Two-phase maintenance: **seek** then **fix**.

## Usage

`/hmd:maintain` — run once (seek + fix)
`/hmd:maintain seek` — only find bugs, raise issues
`/hmd:maintain fix` — only fix existing issues
`/hmd:maintain auto` — schedule recurring via /routine

## Connectors — GitHub issues are the DEFAULT trigger

The queue is connector-fed. **GitHub issues are the default connector and trigger**:
`issue_queue` already normalizes them into the queue that the fixer drains. Every
other source is an *additional* connector that files issues into the SAME queue —
they do not replace GitHub issues, they feed alongside them:

- **GitHub issues** (default) — a human or a bot opens an issue; it is normalized
  and picked by the loop. This is the primary path.
- **k8s / gcloud / Sentry logs** (additional) — the seeker pulls logs, finds
  errors, and FILES them as issues into the same queue (labeled `bug,seeker`).
  The log-based seeker is one pluggable connector, not the only entry point.

Connectors stay pluggable: adding or removing a log source never orphans the
others, and the fixer path downstream is identical regardless of which connector
filed the issue.

## Phase 1: Seek

Spawn a **seeker agent** (the log-based connector) to:
1. Pull logs from Kubernetes pods (or local logs, docker, cloud)
2. Analyze for errors, crashes, anomalies
3. Deduplicate by stack trace signature
4. File GitHub issues with full context (labeled "bug,seeker") — into the same
   queue that human-opened GitHub issues land in.

## Phase 2: Fix

Spawn a **fixer agent** to:
1. Pick open issues from the queue (default connector: `gh issue list --label bug
   --state open`, normalized by `issue_queue`).
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
/routine "run /hmd:maintain" --every 6h
```

Or manually schedule:
```
/schedule "/hmd:maintain" --cron "0 */6 * * *"
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
