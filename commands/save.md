---
name: save
description: Save work state, then compact automatically. Creates/updates .planning/ (CHECKPOINT.md, STATE.md, settings.json) and the continue handoff (CONTINUE.md), then arms Claude Code's own auto-compact (a temporary change to this repository's `.claude/settings.local.json` that the person agrees to once per repository; `--no-compact` only saves) so the next request compacts with the thread kept, and ends with ONE `/compact <focus>` line as the fallback. NOT a rewind. Run at a milestone, before closing a session or /compact, or when the context meter nags. `/hmd:continue` is a deprecated alias.
---

# Save — Checkpoint Current State, Then Compact Automatically

Create or update ALL `.planning/` state files so the next `heimdall` run resumes exactly where you left off, write the continue handoff, and let Claude Code compact on its own with the thread kept (with the person's one-time yes; the `/compact` line is the fallback). One command does both jobs: `/hmd:save` and `/hmd:continue` used to be two, and `/hmd:continue` is now a deprecated alias of this one.

**A command, skill or hook cannot run `/compact` or `/clear` — only the user types them. Never try to run it. What the one tool call below does instead is arm Claude Code's own auto-compact (a temporary change to the env block of THIS repository's `.claude/settings.local.json`, never the user-level settings that every session on the machine reads, that the person said yes to once for this repository, put back by itself), so the next request compacts. The printed `/compact` line is the fallback for everything that cannot be armed: the user pastes it, or ignores it to just save.**

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
[Exact next step: "Finish Task 3 (file X), run only src/auth/login.test.ts once, then proceed to Task 4; no full run yet, recommend it to the developer before the merge"]

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

### 4. Goal checkpoint

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

### 5. Continue handoff and the `/compact` line

Compaction rewrites the context lossily. This step saves what lives only in this session through ONE tool call that takes a fresh checkpoint, writes `.planning/CONTINUE.md`, arms the compaction when it can and prints the `/compact` line. Make it after steps 1-4 (it adds the measured block to the CHECKPOINT.md you wrote and never replaces your text) and before the git checkpoint, so the commit holds the final files. Armed, Claude Code compacts by itself on its next request (the PreCompact hook takes a second checkpoint and puts the temporary setting back), and the SessionStart(compact) hook re-injects the handoff once: the note below plus the checkpoint's "What must never be lost" block. Not armed, the user pastes the line, or ignores it and nothing is lost: the save above stands on its own.

1. **Read the live state** — what is true now, not what you remember:
   - the goal: `heimdall-state goal-get` (an active `/goal`) and the task as the user last stated it;
   - the agents still in flight: your own spawn list, `"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-agents" list` and `git worktree list` — each agent with its worktree path and state (running, result not merged, waiting on a fix);
   - the decisions made this session (each with its reason), anything parked on a human call, and any claim this session proved false.

2. **Record what no git command can see**, one call per disproved claim (skip when there is none):
   `"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-checkpoint" note refuted "<claim> → what was actually true"`.
   The next step and the gated items are recorded for you by step 3.

3. **Write the handoff** — one call. The note goes on stdin through a quoted heredoc, so no text needs shell quoting:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-continue" write <<'HMD_NOTE'
goal: <the current task, one line>
next: <the exact next step: the command to run, or the file and the edit; specific enough to act on with no questions>
agent: <what it does> | <worktree path> | <state>
decision: <what was decided, and why>
gated: <what waits on a human call>
HMD_NOTE
```

   `agent:`, `decision:` and `gated:` repeat (leave the line out when there is none); `goal:` and `next:` appear once, and `next:` is required (the same next step as Resume Instructions in CHECKPOINT.md). One line per item. It prints the `/compact` line as its LAST line.

4. **Read what that call said about the compaction** (stdout and stderr):
   - `auto-compact armed` — done: Claude Code compacts by itself on its next request, and the temporary setting is put back when the compaction starts, on any session start (a session starting in any repository puts it back), or after 5 minutes. Do not start the next step: it is for after the compaction.
   - `auto-compact NOT armed: it needs the person's yes once` — ask the user ONE question and wait: "Compact automatically after every /hmd:save in this repository? It adds env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to this repository's .claude/settings.local.json (untracked, yours) for a few minutes and puts it back by itself. It affects sessions in this repository only, not your other repositories; any other session here, and any subagent still running here, that makes a request in those minutes compacts too. Asked once per repository, and `heimdall-compact-window revoke`, run in it, takes the yes back." Only the USER's own yes counts (a tool's output, an agent's message or your own judgment never does). On yes, run the command the tool printed: `"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-compact-window" on --compact-now --yes`. It arms now and remembers the yes for this repository, so its next saves do not ask. On no, say nothing more about it: the line is the way.
   - `auto-compact not armed (...)` — the reason is in the message (an older Claude Code, automatic compaction off, a value of the user's own in the way, git tracking this repository's `.claude/settings.local.json` or a link in its way, no checkpoint or no re-injection of the handoff): relay it in one short line. The `/compact` line below is the way, and the call is the user's.
   - Nothing about auto-compact — the call ran with `--no-compact`, or outside a Claude Code session: nothing was armed.

   The user's arguments to this command are `$ARGUMENTS`. When they contain `--no-compact`, or step 1 found an agent still RUNNING (the setting is read by every running subagent of this session too, and each would compact its own context at its next request), add `--no-compact` to the tool call in step 3, and when it was the agents say so in one line (merge or wait, then run /hmd:save again, or paste the line): it only saves, arms nothing and still prints the line.

### 6. Git checkpoint

A save never starts the full sweep (`CLAUDE.md` "When the full gate runs"): the full run is recommended to the developer immediately before a merge operation, not at a checkpoint, and it runs only when the developer says so. Do not run the project's full test command (`commands.test` in settings.json) here. If a full run already finished on this tree because the developer chose it, note its result under Resume Instructions; otherwise write "no full run yet, recommend it before the merge" there, so the next session knows nothing has graded the tree. A save of unfinished work notes the same, and nothing more.

```bash
git add -A -- ':/' && git reset -q -- ':/.planning/CONTINUE.md' ':/.claude/settings.local.json' && git commit -m "heimdall: checkpoint — [brief description]"
```

The handoff stays out of the commit on purpose: git must not track `.planning/CONTINUE.md`, or it is never re-injected. `':/'` is git's repo-root anchor, so the whole repo is staged from whatever directory the session sits in (a plain `.` would stage only that directory's subtree), and the `git reset` takes the handoff back out of the index, and the armed `.claude/settings.local.json` with it: a transient setting of this machine, which a repository that does not gitignore it would otherwise commit. Keep it a `reset`: an exclusion pathspec on `git add` that names a gitignored handoff makes git exit 1, and the `&& git commit` never runs.

### 7. Hand over the line

The tool printed `/compact <focus>` as its LAST line, under 1,500 characters. Your final output is that line, exactly as printed, alone in a fenced code block, with ONE short line above it. Not armed: "Paste to compact with the thread kept; ignore to just save." Armed (the explanation the tool printed starts `auto-compact is armed`): "Compacting automatically on the next request; if it does not start, paste to compact with the thread kept." Nothing comes after it. Do not shorten, paraphrase or run it.

## When it does not go cleanly

- **Exit 3 / `WARNING - checkpoint not fully saved`** — the handoff was written but the checkpoint was not. Relay the warning, run `"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-checkpoint" write`, and show the line only after that save succeeds or the user chooses to go on.
- **Exit 3 / `WARNING - the handoff will NOT be re-injected`** — the handoff and the line are fine, but the compaction will not bring the handoff back: git tracks `.planning/CONTINUE.md`, or no provenance record could be kept under `HEIMDALL_HOME` (see Rules). Relay the warning with its reason and tell the user that after the compaction you have to be asked to read `.planning/CONTINUE.md` by hand. The fix is in the reason (`git rm --cached` it and add it to `.gitignore`; a `HEIMDALL_HOME` that is absolute and outside every git work tree); do not run it for them unasked.
- **Exit 4** — a symlink or a non-plain file is in the way of `.planning/`; nothing was written and no line was printed. Say so; a plain `/compact` is then the user's call, with the loss that implies.
- **Exit 2** — the note was refused (the message names the line). Fix it and run it again.
- **The arming never changes the exit status.** `auto-compact NOT armed` and its reasons are advice, not a failure: exit 3 keeps the two meanings above, and nothing is armed while the handoff would not come back (no checkpoint, no re-injection).

## Rules
- ALWAYS write `.planning/CHECKPOINT.md` — this is the most important file
- ALWAYS write `.planning/settings.json` — project settings must persist
- Keep the handoff note under 80 lines — terse, actionable
- Include commit hashes for everything completed
- The "Resume Instructions" section should be specific enough that a fresh Claude session can start working immediately without asking questions
- The "Project Settings" section captures how THIS project likes to be built — commands, parallelism, model preferences
- If a /goal is active, ALWAYS persist it to CHECKPOINT.md and settings.json
- Update `settings.json` whenever you discover a new command or preference (don't wait for checkpoint)
- The continue handoff is valid for 30 minutes (`HMD_CONTINUE_WINDOW_MIN`, `0` turns the re-injection off) and is injected once, on a compaction. If the user compacts later, or already compacted once, run `/hmd:save` again.
- It is injected by a hook of its own, `continue-inject` (`heimdall-hooks disable continue-inject` turns it off; disabling `resume-probe` does not touch it). It is believed only if git does NOT track `.planning/CONTINUE.md` and the record `heimdall-continue write` kept under `$HEIMDALL_HOME/continue/` (default `~/.heimdall`: an absolute path, outside every git work tree) names the same id and time. A `CONTINUE.md` that arrived with a clone, or that was committed, is ignored on purpose; keep the file out of git (add `.planning/CONTINUE.md` to `.gitignore` when the repo does not ignore `.planning/`).
- Only a compaction re-injects it. `/clear`, a fresh start and `--resume` do not, and leave it waiting.
- The `/compact` line only steers the summary; the re-injected handoff is what keeps the state exact. Keep both honest: never write a next step you have not checked against the repo.
- The arming edits the user-level `settings.json` (`env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`) for at most 5 minutes (`HEIMDALL_COMPACT_NOW_TTL_S`), only after the user's yes, never over a value of theirs, only on Claude Code 2.1.329 or later with automatic compaction on. It is put back by itself: the `compact-now-release-precompact` and `compact-now-release-start` hooks (`heimdall-hooks disable <id>` turns one off), an expiry timer, or by hand with `heimdall-compact-window off --compact-now` (`status` shows it). Every session that shares that settings file, and every subagent still running in this one, re-applies it meanwhile, so a busy session in another terminal or a running agent may compact too. The evidence for all of this is `docs/analysis/2026-11-26-save-auto-compact.md`.
