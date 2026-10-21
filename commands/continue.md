---
name: continue
description: Compact without losing the thread. Saves a fresh checkpoint, writes a continue handoff (goal, exact next step, in-flight agents with worktrees, decisions made, gated items) and prints ONE ready-to-paste `/compact <focus>` line; once you paste it, the SessionStart(compact) hook re-injects the handoff, so work goes on with full context. Use before /compact, when the context meter nags, or before stopping mid-task. No command can run /compact itself: you paste the line.
---

# /hmd:continue — /compact and /continue in one move

Compaction rewrites the context lossily. This command makes it lossless: it saves everything that lives only in this session, then hands the user ONE line to paste.

**A command, skill or hook cannot run `/compact` or `/clear` — only the user types them. Never try to run it: print the line, the user pastes it.**

What happens next, without anyone typing anything else: Claude Code compacts (the PreCompact hook takes a second checkpoint), and the SessionStart(compact) hook re-injects the handoff once — the note below plus the checkpoint's "What must never be lost" block — as context in the compacted session. `/hmd:save` is the end-of-session save; this is the mid-session pivot.

## Steps

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

   `agent:`, `decision:` and `gated:` repeat (leave the line out when there is none); `goal:` and `next:` appear once, and `next:` is required. One line per item. It takes a fresh checkpoint (`heimdall-checkpoint write`), writes `.planning/CONTINUE.md` and prints the line.

4. **Hand over the line.** The tool prints `/compact <focus>` as its LAST line, under 1,500 characters. Show it exactly as printed, alone in a fenced code block, and say: "Paste this as your next message. After the compaction the handoff comes back by itself, once, if it happens within 30 minutes." Do not shorten, paraphrase or run it.

## When it does not go cleanly

- **Exit 3 / `WARNING - checkpoint not fully saved`** — the handoff was written but the checkpoint was not. Relay the warning, run `"${CLAUDE_PLUGIN_ROOT}/bin/heimdall-checkpoint" write`, and show the line only after that save succeeds or the user chooses to go on.
- **Exit 3 / `WARNING - the handoff will NOT be re-injected`** — the handoff and the line are fine, but the compaction will not bring the handoff back: git tracks `.planning/CONTINUE.md`, or no provenance record could be kept under `HEIMDALL_HOME` (see Rules). Relay the warning with its reason and tell the user that after the compaction you have to be asked to read `.planning/CONTINUE.md` by hand. The fix is in the reason (`git rm --cached` it and add it to `.gitignore`; a `HEIMDALL_HOME` that is absolute and outside every git work tree); do not run it for them unasked.
- **Exit 4** — a symlink or a non-plain file is in the way of `.planning/`; nothing was written and no line was printed. Say so; a plain `/compact` is then the user's call, with the loss that implies.
- **Exit 2** — the note was refused (the message names the line). Fix it and run it again.

## Rules

- The handoff is valid for 30 minutes (`HMD_CONTINUE_WINDOW_MIN`, `0` turns the re-injection off) and is injected once, on a compaction. If the user compacts later, or already compacted once, run this again.
- It is injected by a hook of its own, `continue-inject` (`heimdall-hooks disable continue-inject` turns it off; disabling `resume-probe` does not touch it). It is believed only if git does NOT track `.planning/CONTINUE.md` and the record this command kept under `$HEIMDALL_HOME/continue/` (default `~/.heimdall`: an absolute path, outside every git work tree) names the same id and time. A `CONTINUE.md` that arrived with a clone, or that was committed, is ignored on purpose; keep the file out of git (add `.planning/CONTINUE.md` to `.gitignore` when the repo does not ignore `.planning/`).
- Only a compaction re-injects it. `/clear`, a fresh start and `--resume` do not, and leave it waiting.
- The `/compact` line only steers the summary; the re-injected handoff is what keeps the state exact. Keep both honest: never write a next step you have not checked against the repo.
- Do not run the full sweep for this; a pivot is not a landing.
