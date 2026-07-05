# Single-phase flow with question-mark awaited input

**Date:** 2026-04-10
**Status:** Implemented

## Problem

The dashboard ran every task through three mandatory phases — refining, planning, executing — each with an approval gate. The state machine was:
`idle → refining → (approve) → planning → (approve) → executing → idle`

This caused a string of bugs where the approval UI never appeared after a phase finished, the system looped on stale checkpoints, and refined-prompt rewrites were mistaken for completed tasks. The root cause was that there was no explicit "awaiting approval" sub-state — the server's `current_phase` covered both "actively refining" and "refining done, waiting on user", and the frontend had to guess from a flag soup of `running`, `pending_plan`, and SSE event timing. Anything that disrupted SSE delivery (refresh, race, slow git commit) broke the flow.

The user also wanted the simpler original behavior: don't force a refine/plan/execute pipeline at all; just run Claude end-to-end and only ask the user for input when Claude actually has a question.

## Design

### State machine

```
idle ──submit prompt──> running ──stream ends, no `?`──> idle
                          │
                          └──stream ends with `?`──> awaiting_user_input ──user reply──> running
```

Three phases, no implicit transitions. The phase is the source of truth. The frontend renders UI based on phase alone — no timing-sensitive event interpretation.

### Question detection

After `proc.wait()`, the server inspects the last assistant text block from the stream. It strips trailing whitespace and closing markdown punctuation (`*_`)]}>`) and checks whether the last character is `?`. If yes → `awaiting_user_input`. If no → `idle`.

For this to work, the Claude subprocess must reliably end its response with a question mark when it needs user input. The server prepends an `INPUT PROTOCOL` instruction to every prompt explaining this convention. The instruction lives in the prompt itself (not CLAUDE.md) so it works regardless of `cwd`.

### Session resumption

When the user replies in `awaiting_user_input`, the server runs `claude --resume <session_id>` so Claude has the full prior conversation in context. The session id is captured from the stream-json `system` message of `subtype: "init"` and stored in the `claude_session_id` global. If no session id was captured (edge case), the reply is treated as a fresh task.

All other CLI flags are preserved on resume:
- `--dangerously-skip-permissions`
- `--plugin-dir <heimdall>`
- `--output-format stream-json`
- `--verbose`

So agent spawning, skill use, and dangerous-write capabilities are unchanged across the user-reply boundary.

### Persistence

- **Session file** (`superx-session.json`) — stores phase, claude_session_id, timeline, terminal. On startup, restores `awaiting_user_input` if that's where we were; never restores `running` (the subprocess is gone).
- **Checkpoint file** (`superx-checkpoint.json`) — only written when `phase == "running"`. Holds `original_prompt`, `claude_session_id`, `cwd` for crash recovery. Cleared on every transition out of running. The race-condition mitigations from the previous fix (don't resave from a slow git thread, clear at task start) stay in place.

### Frontend behavior

- **Default state:** prompt bar at the bottom takes a new task.
- **Awaiting state:** prompt bar tints orange, placeholder changes to "Claude is asking — type your reply...", a hint box above shows the tail of Claude's question. Submitting POSTs to `/api/reply` instead of `/api/prompt`.
- **The approval panel UI is gone entirely.** No approve/revise buttons.
- **SSE replay on reconnect:** if the server is currently in `awaiting_user_input`, the SSE handshake replays the `awaiting_user_input` event so a refreshed client immediately sees the awaiting UI.

### Removed code

- `start_planning`, `execute_approved_plan`, `revise_refinement`, `revise_plan`
- `handle_approve`, `handle_revise` endpoints
- `refine_prompt` / `plan_prompt` / `exec_prompt` wrapper strings
- `pending_prompts`, `refined_prompt_text` globals
- Frontend: `showPlanApproval`, `setupPlanApproval`, `detectAndShowOptions`, `sendOptionChoice`, plan-approval CSS, `#plan-approval` HTML, plan-attach-input
- Multi-phase resume (`refining`/`planning`/`executing`) — replaced with single-phase resume

### What stays

- Streaming output to the logs panel (unchanged)
- Timeline events with markdown rendering
- Map/dashboard/war-room/sprite/hover features
- History drawer + rename
- Auto-checkpoint git commits during long runs
- Resume bar for crash recovery
- Stop button (kills current run, clears state)
- Session persistence + restore on refresh

## Files touched

- `ui/server.py` — state machine rewrite
- `ui/static/app.js` — remove approval handlers, add awaiting UI
- `ui/static/index.html` — remove plan-approval block
- `ui/static/style.css` — remove `.plan-approval`, add `.prompt-bar.awaiting` + `.awaiting-hint`
