---
name: switch-ai
description: Show or change which offline coding-AI CLI backend hmd prefers (Claude Code, Cursor CLI, ...). Use with a letter, backend id, or loose name, or no argument to show current + detected options.
argument-hint: [A|B|<backend-id>]
disable-model-invocation: true
---

# Switch AI Backend

hmd can be driven by more than one offline coding-AI CLI — Claude Code, Cursor CLI's `agent`/`cursor-agent`, and more as they're added. This command shows or changes which one hmd *prefers*.

## What this actually controls — read before switching

hmd is a Claude Code plugin: code loaded into a live Claude Code process. It cannot hot-swap itself into a cursor-agent process mid-session, and it cannot restart itself as a different CLI. `/switch-ai` cannot change what is hosting this session, right now — nothing can, short of you exiting and relaunching under a different CLI's own launcher (e.g. `cursor-agent` instead of `claude`). That is a restart, not something this command performs.

What it genuinely does change:
1. **The recorded preference** — persisted to `.planning/settings.json` under the `ai_backend` key. This governs which backend hmd's own sub-agent spawns prefer for delegated work when more than one is detected, effective immediately for new spawns.
2. **The default for your NEXT session** — the next time hmd starts a run, `heimdall-ai-select session-start` reads this recorded choice first and will not re-prompt or re-guess.

## Instructions

1. Parse `$ARGUMENTS`:
   - If **empty or missing**: show the current backend and the detected options, then stop — do not change anything.
     ```bash
     heimdall-ai-select current .
     heimdall-ai-select list --auth
     ```
     Present the current selection first, then the lettered list exactly as printed (e.g. `A) Claude Code [claude-code] (current host)`, `B) Cursor CLI (cursor-agent) [cursor-cli] — not logged in`).
   - Otherwise: treat `$ARGUMENTS` as a **letter** (`A`, `B`, ...), a **backend id** (`claude-code`, `cursor-cli`), or a **loose name** (`cursor`, `claude`) and pass it straight through — `heimdall-ai-select` resolves letter/id/loose-name itself and refuses anything not currently detected on `PATH`:
     ```bash
     heimdall-ai-select select "$ARGUMENTS" .
     ```
     Report its exit message verbatim, success or rejection — don't re-word it.

2. After a successful switch, restate the honesty split above in one line: the preference is saved now for delegated spawns and the next session; running THIS session under the new CLI still needs a restart with that CLI's own launcher.

3. If `heimdall-ai-select` is missing or not executable, say so plainly rather than fabricating a detection result.
