# Changelog

All notable changes to superx will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **`/level` renamed to `/autonomy`** — the command that controls how much the agent does before asking is now `/hmd:autonomy` (with `/hmd:autonomy +` / `-` to cycle and `/hmd:autonomy <1|2|3>` to set). "Autonomy" names what it actually controls. Levels, semantics, and the on-disk config key (`.project.autonomy_level`) are unchanged — no existing user's saved setting resets on upgrade.

### Deprecated
- **`/hmd:level`** is kept as a deprecated alias for one release. It still works and prints a one-line "'/hmd:level' is now '/hmd:autonomy'" notice. It will be removed a couple of releases later.

## [1.1.0] - 2026-04-19

superx can now run **10 agents in parallel** instead of 3 — background agents bypass Claude Code's per-turn limit, so a 10-task wave all runs simultaneously.

superx can now **route tasks to the right model automatically** — lint goes to Haiku (cheap + fast), docs go to Sonnet, and all code goes to Opus at high effort. If a task fails on a cheaper model, superx can now **auto-escalate** to the next tier (Haiku → Sonnet → Opus) instead of just failing.

superx can now **skip the LLM entirely** for deterministic operations — format, lint-fix, sort imports, rename files. These run as direct bash commands. Zero tokens spent.

superx can now **detect stalled agents** and nudge them — if an agent goes silent for 60 seconds, it gets a continuation prompt. And agents can now **never claim they're done** until acceptance criteria actually pass ("close enough" is blocked).

superx can now **verify claims against reality** — the verifier factchecks actual files on disk vs what the agent said it created. If a task claims "Created src/api.ts" but the file doesn't exist, it fails. Each task gets a **truth score (0.0-1.0)** and the phase fails if the average drops below 0.8.

superx can now **resolve conflicts between parallel agents** — when 10 agents produce competing changes, the version that passes more acceptance criteria wins (Byzantine consensus).

superx can now **switch governance modes** — Hierarchical (default, top-down control), Democratic (spawn competing proposals, pick the best), or Emergency (skip planning, incident-responder takes over, fix first).

superx can now **learn from your project** — after complex tasks, it extracts reusable patterns to `.planning/skills/` (trigger + steps + why). On future tasks, it **searches past patterns first** and applies proven solutions. Patterns with < 50% success rate get archived automatically.

superx can now **optimize its own cost** — after every 10 tasks, it analyzes which model tier succeeds for which task types and adjusts defaults. If Haiku always fails on your React components but works for your Python scripts, it learns that.

superx can now **spawn tmux worker teams** — `superx --team 5 "task"` launches 5 real parallel Claude instances in tmux panes, bypassing all API concurrency limits.

superx can now **detect magic keywords** in your prompts — "ultrawork" triggers maximum parallelism, "quick" skips planning, "secure" runs security-first, "incident" activates emergency mode, "plan" stops before execution, "ship" does end-to-end delivery.

superx can now **show its status** in Claude Code's status bar — current phase, task progress, dispatch queue depth. All visible at a glance.

superx can now **steal work between waves** — if an agent finishes early, it grabs dependency-free tasks from the next wave instead of sitting idle.

superx can now **preview merges safely** — before committing parallel work, it runs `git merge-tree` to detect conflicts without mutating. No more blind merges.

superx can now **show you exactly what changed** on `--update` — commit messages, file diffs, insertion/deletion counts. And on every launch, it **checks for updates** (once per hour) and tells you if you're behind.

### New Agents
- **security-auditor** (Opus/max) — OWASP Top 10, dependency audit, secrets scan, auth/authz review
- **database-architect** (Opus/high) — schema design, migrations, query optimization, N+1 detection
- **incident-responder** (Opus/max) — triage → diagnose → mitigate → fix → blameless postmortem

### New CLI
- `superx --team N "task"` — tmux parallel workers
- `superx --uninstall` — with sad goodbye animation
- `superx --auto` — safer alternative to skip-permissions

### New Files
- `bin/lib/dispatch.sh` — file-based task queue (JSONL + directory locks, survives crashes)
- `hooks/statusline.sh` — HUD for Claude Code status bar
- `agents/security-auditor.md`, `agents/database-architect.md`, `agents/incident-responder.md`

### Companion Plugins
- **caveman** at ultra mode (~75% token savings)
- **claude-mem** for persistent cross-session memory
- **superpowers** for brainstorming + debugging

### Inspired By
Cherry-picked 24 features from:
- [ruflo](https://github.com/ruvnet/ruflo) — model routing, work-stealing, SONA learning, Tier 0 routing, Byzantine consensus
- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) — idle nudging, sentinel gate, continuation enforcement, file-based dispatch, tmux teams, skill extraction, magic keywords, HUD statusline
- [wshobson/agents](https://github.com/wshobson/agents) — security-auditor, database-architect, incident-responder

---

## [1.0.0] - 2026-04-10

First marketplace-ready release. Pixel dashboard is feature-complete and the orchestration loop has been simplified to a clean single-phase state machine.

### Added
- **Pixel-art dashboard** (`ui/server.py` + `ui/static/`) — local Python HTTP+SSE server with a real-time isometric city map of your project, war room of agents, streaming logs panel, and timeline view of every decision.
- **Single-phase state machine** — `idle → running → awaiting_user_input → running → idle`. Replaces the old three-phase refining/planning/executing pipeline that was forcing approval gates whether you needed them or not.
- **Question-mark protocol** — every prompt sent to Claude is prefixed with an INPUT PROTOCOL instruction. Claude only stops to ask when it actually needs input; the dashboard detects the trailing `?` and opens an awaiting-input panel.
- **Awaiting-input panel** — orange-tinted panel showing the question, auto-detected option buttons (parses `(A)`, `(B)`, `(C)`, `(D)` patterns), yes/no detection for confirmation questions, and a free-form textarea + SEND button.
- **Conversation continuity** — user replies use `claude --resume <session_id>` so Claude has full prior turn in context. Session id captured from stream-json's `system / init` message.
- **Map features** — drag-to-pan, zoom +/-, day/dawn/dusk/night theme toggle, fullscreen mode, building hover tooltips, agent sprite animation over their working buildings, road/joint alignment, custom pixel cursor.
- **History drawer** — every session archived with a smart auto-generated title from the task prompt; rename, browse, or replay any past run. Hover any session card and click the pencil icon to rename inline.
- **Auto-checkpointing** — background `git add -A && git commit` every 5 file writes during long runs, plus a recovery checkpoint so a crash never loses work.
- **Resume bar** — restores the last interrupted task on server start, with a one-click RESUME button.
- **GitHub integration** — one-click commit + push from inside the dashboard with SSH remote auto-detection.
- **Token budgets** — set a budget per session and get warned at 80% via `superx-state set-budget`.
- **Image attachments** — drag-and-drop or paste images into the prompt; they're saved to a temp dir and Claude reads them via the Read tool.
- **Smart timeline grouping** — collapses repetitive tool calls from the same agent into a rolling window so the timeline stays readable on long runs.
- **Markdown rendering** with expand/collapse for long messages.
- **Day/night theming** for the entire dashboard, including the isometric city.
- **Terminal log dedup** via djb2 hash so re-posts from server reconnects don't double up.

### Changed
- Bumped to v1.0.0 with full marketplace metadata in `.claude-plugin/plugin.json` (homepage, repository, keywords, categories, engines).
- README rewritten with dashboard-first quick start, troubleshooting section, and architecture diagram.
- All multi-phase orchestration code (`start_planning`, `execute_approved_plan`, `revise_refinement`, `revise_plan`, `handle_approve`, `handle_revise`) removed in favor of the single-phase flow.
- `.gitignore` strengthened — explicitly excludes all runtime state files (`superx-state.json`, `superx-session.json`, `superx-history.json`, `superx-checkpoint.json`, `superx-github.json`, `superx-workspace/`) and user-generated docs.

### Fixed
- Approval UI no longer disappears after refining/planning completes (was a race between `prompt_refined` and `process exited` events).
- Session restore correctly shows awaiting-input state after a refresh (was tied to `pending_prompts` global which was only set during revise flow).
- SSE replay on reconnect — clients that connect after `awaiting_user_input` already fired now receive the event immediately so the panel opens correctly.
- Stale checkpoint resurrection prevented — `_auto_checkpoint_git` background thread no longer rewrites a cleared checkpoint after task completion.
- `start_claude` clears any leftover checkpoint before writing its own, so a new task never inherits state from a previous one.
- Translucent night-overlay box on the map fixed by moving the overlay outside the zoom transform.
- Road tile alignment with cumulative `(r+c)*4` y-shift correction so road segments and joints connect seamlessly.
- Building/filler/car positions use the same grid correction as roads for consistency.

## [0.2.0] - 2026-04-06

### Added
- Design agent (`agents/design.md`) for UI/UX work with design-for-ai skill integration.
- `/superx:maintain-check` command — runs one full maintenance cycle (scan → triage → fix → release).
- `/superx:level +/-` cycling — quick autonomy level switching without remembering numbers.
- Guided maintainer activation wizard — one-command setup for issue sources, frequency, Slack notifications.
- Plugin marketplace authenticity checking (was stubbed, now validates registry + manifest + GitHub signals).
- Slack skill integration in orchestrator for team communication.
- `.gitignore` for clean repo hygiene.
- Development setup and local testing instructions in README.
- Test framework auto-detection in test-runner agent (jest, pytest, cargo, go, make).
- Dependency validation in conflict-log script.

### Changed
- `/superx:maintain` upgraded from simple toggle to guided setup wizard with first-check-on-activation.
- Maintainer mode now supports configurable issue sources (GitHub, logs, Sentry/Elastic).
- Resolved all 4 open design questions in spec (skill detection, state sync, cron, keybindings).
- Updated LICENSE copyright holder.

### Fixed
- SKILL.md spec paths now use relative paths from plugin root.
- detect-skills now has --help/usage documentation.

## [0.1.0] - 2026-04-06

### Added
- Initial plugin scaffold with `.claude-plugin/plugin.json`.
- Main orchestrator agent (`agents/superx.md`) with CTO-level orchestration loop.
- Specialized subagents: architect, coder, test-runner, lint-quality, docs-writer, reviewer.
- Launcher script (`bin/superx`) for one-command startup.
- State management CLI (`bin/superx-state`) with full CRUD on `superx-state.json`.
- Skill detection helper (`bin/detect-skills`).
- Conflict logging helper (`bin/conflict-log`).
- Publisher authenticity checker (`bin/authenticity-check`).
- Quality gate hooks (PreToolUse blocks push if gates fail, PostToolUse marks dirty state).
- Slash commands: `/superx:level`, `/superx:status`, `/superx:maintain`, `/superx:reflect`.
- Main skill with reference documentation (agent templates, quality gates, maintainer guide, communication templates).
- Full design specification in `docs/`.
- Agent teams support via experimental feature flag.
