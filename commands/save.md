---
name: save
description: Save current work state for next session. Creates/updates .planning/ files (CHECKPOINT.md, STATE.md, settings.json) so Heimdall resumes with full context. NOT a rewind — saves forward progress. Run before closing a session or at any milestone.
---

# Save — Checkpoint Current State

Create or update ALL `.planning/` state files so the next `heimdall` run resumes exactly where you left off.

## What to save

Read the current state of the project and write/update these files:

### 1. `.planning/STATE.md`
Update with:
- **Current phase**: what phase are we in (planning, executing wave N, verifying, idle)
- **What's done**: list completed tasks/features with commit hashes
- **What's in progress**: currently active work
- **What's next**: queued tasks not yet started
- **Blockers**: anything preventing progress
- **Decisions made**: key architectural/design decisions from this session
- **Key files changed**: list of files modified in this session

### 2. `.planning/CHECKPOINT.md` (the handoff note — most important file)
Write a concise handoff note that another Claude session can read and immediately continue:

```markdown
# Checkpoint — [timestamp]

## TL;DR
[One sentence: what was the task, how far did we get]

## Completed
- [x] Task 1 (commit abc1234)
- [x] Task 2 (commit def5678)

## In Progress
- [ ] Task 3 — started, file X partially edited

## Not Started
- [ ] Task 4
- [ ] Task 5

## Resume Instructions
[Exact next step: "Run tests in src/auth/, fix any failures, then proceed to Task 4"]

## Key Context
- [Decision 1: chose X over Y because Z]
- [File A imports from File B — don't break this]
- [User wants: specific preference]

## Tech Stack & Patterns
- [Stack: React 18 + TypeScript + Vite, etc.]
- [Pattern: services use singleton pattern, components use compound pattern]
- [Constraint: must support Node 18+, no ESM-only deps]

## Project Settings
- Parallelism: [max 10 / max 5 / sequential — what worked for this project]
- Model routing: [any overrides from defaults, e.g. "sonnet works fine for React components here"]
- Governance: [hierarchical / democratic / emergency last used]
- Test command: [exact command, e.g. "npm test", "pytest tests/", "cargo test"]
- Lint command: [exact command, e.g. "npx eslint src/", "ruff check ."]
- Build command: [exact command, e.g. "npm run build", "cargo build"]
- Deploy command: [if known]
- Directories to avoid: [e.g. "vendor/, generated/, dist/"]
- User preferences: [e.g. "prefers tabs over spaces", "wants detailed commit messages", "hates emojis in code"]
```

### 3. `.planning/settings.json` (project-specific Heimdall config)
Write or update project-specific execution settings:

```json
{
  "parallelism": {
    "max_agents": 10,
    "min_agents_for_parallel": 2,
    "notes": "React components safe to parallelize, DB migrations must be sequential"
  },
  "model_routing": {
    "default_code": "sonnet",
    "_note": "No key here is mechanically enforced. default_code is advisory: this whole file is injected verbatim into every launch's preamble (bin/heimdall:3176, load_checkpoint_context()), and the orchestrator is expected to use default_code as the default tier when IT spawns delegated coding subagents. It never reaches the main Claude Code agent's own launch — select_model() in bin/heimdall no longer reads this file at all, so the main agent stays unconditionally unpinned (CLAUDE.md 'Model routing': never pinned, runs on the operator's own /model default) no matter what this key says. Add default_effort or per-glob tier overrides if you like — same rule: a note to the orchestrator, never a setting."
  },
  "commands": {
    "test": "npm test",
    "lint": "npx eslint src/ --fix",
    "build": "npm run build",
    "typecheck": "npx tsc --noEmit"
  },
  "governance": "hierarchical",
  "avoid_dirs": ["node_modules", "dist", ".next", "vendor"],
  "user_preferences": []
}
```

The whole file is injected verbatim into the preamble on every `heimdall` launch, alongside CHECKPOINT.md (`bin/heimdall:3176`, `load_checkpoint_context()`). Claude doesn't need to "discover" test/lint/build commands — they're there from the first run.

What "injected" does and does not mean: no key in this file changes behaviour mechanically. `model_routing.default_code` used to pick the main agent's own launch model at `bin/heimdall:3918` when set — removed 2026-08-18, because that pinned the main agent exactly the way CLAUDE.md's "Model routing" directive forbids, merely gated behind an opt-in file instead of unconditional; no code path ever applied it to a delegated coding subagent spawn, so pinning this launch was its entire real effect, not a documented alternate use. The main agent now runs unpinned on the operator's own Claude Code default regardless of this file's contents. Everything in the file, default_code included, is text the orchestrator reads and is expected to honour when IT spawns delegated subagents — same as the commands, parallelism numbers, governance, avoid_dirs, preferences. That is an instruction to a model, not an enforced setting, so verify it was honoured rather than assuming the file made it so.

### 4. Git checkpoint
```bash
git add -A && git commit -m "heimdall: checkpoint — [brief description]"
```

### 5. Goal checkpoint

If a `/goal` is currently active, save it for next session restoration:

1. Check current goal: `heimdall-state goal-get`
2. If a goal is active (not "none"), include in CHECKPOINT.md under a new section:

```markdown
## Active Goal
Condition: <the goal condition string>
Source: <planner|launcher|manual>

On resume, restore with: `/goal <condition>`
```

3. Also persist in `.planning/settings.json` under a `goal` key:
```json
{
  "goal": {
    "condition": "<the condition string>",
    "source": "planner"
  }
}
```

## Rules
- ALWAYS write `.planning/CHECKPOINT.md` — this is the most important file
- ALWAYS write `.planning/settings.json` — project settings must persist
- Keep the handoff note under 80 lines — terse, actionable
- Include commit hashes for everything completed
- The "Resume Instructions" section should be specific enough that a fresh Claude session can start working immediately without asking questions
- The "Project Settings" section captures how THIS project likes to be built — commands, parallelism, model preferences
- If a /goal is active, ALWAYS persist it to CHECKPOINT.md and settings.json
- Update `settings.json` whenever you discover a new command or preference (don't wait for checkpoint)
