# Changelog

All notable changes to Heimdall (formerly superx) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Changelog status

This file was not maintained between the last curated entry below (from when the
project was still called superx) and the current plugin version. The version of
record is `.claude-plugin/plugin.json`, mirrored into `VERSION` and the README badge
by `bin/heimdall-render-version` -- it is deliberately not repeated here, because a
hand-typed version drifts on the next bump (test/version-pin-conformance.test.sh
exists for exactly that reason). No release notes for the gap have been
reconstructed, deliberately: writing them after the fact would be invention. The
real history is in git:

- `git log --oneline <tag-of-the-last-curated-entry-below>..HEAD`
- `bin/generate-changelog` (renders from commits, never hand-typed)
- `hmd weekly-log` (drafts only)

## [Unreleased]

### Changed
- **`/level` renamed to `/autonomy`** — the command that controls how much the agent does before asking is now `/hmd:autonomy` (with `/hmd:autonomy +` / `-` to cycle and `/hmd:autonomy <1|2|3>` to set). "Autonomy" names what it actually controls. Levels, semantics, and the on-disk config key (`.project.autonomy_level`) are unchanged — no existing user's saved setting resets on upgrade.

### Deprecated
- **`/hmd:level`** is kept as a deprecated alias for one release. It still works and prints a one-line "'/hmd:level' is now '/hmd:autonomy'" notice. It will be removed a couple of releases later.

## [2.4.4] - 2026-10-06 <!-- HEIMDALL:PIN:FROZEN -->

The companion-app release. hmd can now publish a live, end-to-end-encrypted view of a running session to the phone app through a hosted relay, take a short list of safe remote actions from it, and issue signed receipts for what its gates did.

### Added
- **Pair by session code** — `hmd app connect` defaults to the hosted relay and pairs by the 5-character session code the statusline shows. A bind by code reveals hmd's key in a plaintext `key_reveal`, seals nothing until the laptop approves the SAS check, and revokes and renews the window on reject, timeout or closed input. A revealed key is burned after an unapproved bind, `--code` needs https or loopback, and an identity can be revoked.
- **controls-v1** — the phone can drive an allowlisted set of controls: `hmd app controls on|off|status`, `POST /api/control`, an interrupt (stop) hook, remote toggles from the hooks registry, and fallback mode over every `heimdall-fallback` state (confirmation required for all but `off`).
- **view-v1** — the phone can ask for a sealed diff of one repo-relative path (worktree, staged or head; an untracked file shown whole). Path policy refuses `..`, absolute paths, deny-listed files and any symlink; secrets are masked per line; output is size-capped and rate-limited (20 requests per 60 s, `HMD_VIEW_RATE_LIMIT` to change it).
- **push-v1** — the phone registers its Expo push token (`register_push`, `unregister_push`, `app_state`; stored 0600 in `.heimdall/app/push.json`, at most 5, newest wins) and hmd's push sender notifies it on five triggers (question, approval, error, gate red, finished) with per-device policy, foreground suppression and rate caps. `HMD_PUSH=0` turns it off.
- **login-v1** — log Claude Code in from the phone: a PTY-driven `claude auth login`, the printed URL checked against an allowlist before it is published, the code typed from a sealed command and never logged, and the resulting account compared with the laptop's pin. Laptop switch: `hmd app remote-login on|off|status`.
- **Relay** — a Cloudflare Worker + Durable Object relay: E2E sealing (X25519, HKDF-SHA256, ChaCha20-Poly1305), zlib-compressed state frames, persisted client events, last-state replay to a newly accepted device socket, a `GET /health` probe answered by the Worker alone, and hmd's leg over a hibernatable WebSocket (stdlib RFC 6455 client in `bin/lib/hmd_relay_ws.py`). Deploys run the relay-ci gate, then a canary Worker that must report the deployed sha on `/health`, then production, and roll back if a check never passes.
- **`hmd attack`, `hmd prove`, `hmd receipt`** — `hmd attack <path>` runs the attack oracle battery behind a consent gate (non-TTY needs `--yes`) and prints a `runhmd.verdict/1` as JSON or a card; `hmd prove` answers "do all of this repo's gates pass, and was each shown to fail first?" (PROVEN or DENIED, never a pass on unreadable output); `hmd receipt verify|keygen|render|serve` handles Ed25519-signed `runhmd.receipt/1` receipts, and `attack --receipt` issues one. `npx runhmd <path>` runs `hmd attack <path>`, and `release/ship.sh` now publishes both npm wrappers.
- **`HMD_TEAM_NO_COMMIT=1`** (or the marker file `~/.heimdall/no-team-commit`) — `hmd team` keeps `.heimdall/team.json` current on disk but never stages or commits it, so a wip checkpoint's `git add -A` cannot sweep it into history.
- **`hmd ui`, `hmd app`, `hmd inbox`** — a local, token-gated companion web UI; `hmd app connect|status|disconnect|doctor` with Tailscale Funnel publishing; and an inbox that delivers phone messages into the session at tool boundaries and at the Stop hook (held up to 300 s while a companion is connected, released the moment the operator types).
- **Hooks registry** — every hook has an id and a fingerprint (`heimdall-hooks check` fails on drift), advisory hooks get a per-hook kill switch, and the gates that hold a line are locked and cannot be disabled. New guards: edits to linter, formatter and typechecker config are denied; a live tool-loop detector; `hmd settings-guard` for `ANTHROPIC_*` overrides persisted in Claude Code settings.

### Fixed
- **ENOSPC recovery** — the relay client no longer goes silent after the disk fills. Its diagnostics wrote to the full disk and raised out of the loops that report errors, ending the poller thread for good. A failing log sink now never raises and is never switched off: the outage is reported once when it starts and once on recovery, and sending resumes when space returns.
- `hmd <typo>` exits 2 with a did-you-mean suggestion instead of launching an autonomous agent on a lone unknown word.
- Relay hardening from the protocol audit: the session key is latched at the first device bind, the device sequence never advances on a decrypt failure, and stream reads are bounded per line and per stream.

### Security
- Audit pass over `hmd ui`, `hmd app` and the inbox: public-mode redaction of every string leaf, connection caps and a header timeout, per-IP auth backoff, the Funnel token kept off argv and logs, validated DNS names, no `eval` in the install path, and 0700/0600 permissions on inbox files.
- gitleaks now flags Stripe-shaped tokens regardless of entropy.

### Performance
- State is sent on change instead of on a poll, and `/api/state` is served from the SSE snapshot cache (1.5-3 s per poll down to tens of milliseconds). The chat publisher reads only the appended transcript bytes, and a statusline render launches python 2 times instead of 9-11.

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
