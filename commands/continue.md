---
name: continue
description: Deprecated alias for /hmd:save, which now also writes the continue handoff and prints the one /compact line. Still works; prints a one-line rename notice.
disable-model-invocation: true
---

# Continue (deprecated alias of /hmd:save)

`/hmd:continue` was merged into `/hmd:save`: one command now saves the checkpoint, writes the continue handoff and ends on the `/compact <focus>` line to paste. This alias still works for one release so muscle memory doesn't break; it will be removed a couple of releases later.

## Instructions:

1. **First, print exactly this one-line notice:**
   `'/hmd:continue' is now '/hmd:save' — same behavior. Please switch.`

2. Then do exactly what `/hmd:save` does: run `/hmd:save`, or follow `commands/save.md` step by step, through to its last output, the `/compact` line. This file has no steps and no tool call of its own, so one code path writes CHECKPOINT.md and CONTINUE.md.

Going forward, use `/hmd:save`.
