---
name: level
description: Deprecated alias for /hmd:autonomy. Sets Heimdall autonomy (1=Guided, 2=Checkpoint, 3=Full Auto). Still works; prints a one-line rename notice.
argument-hint: <1|2|3|+|->
disable-model-invocation: true
---

# Set Autonomy (deprecated alias of /hmd:autonomy)

`/hmd:level` was renamed to `/hmd:autonomy`. This alias still works for one release so muscle memory doesn't break; it will be removed a couple of releases later.

## Instructions:

1. **First, print exactly this one-line notice:**
   `'/hmd:level' is now '/hmd:autonomy' — same behavior. Please switch.`

2. Then behave identically to `/hmd:autonomy $ARGUMENTS`. Parse `$ARGUMENTS`:
   - If **empty or missing**: Show current setting from `heimdall-state get '.project.autonomy_level'` and the descriptions below. Done.
   - If **`+`**: Read current setting, increment by 1 (wrap 3→1). Use the result as the new setting.
   - If **`-`**: Read current setting, decrement by 1 (wrap 1→3). Use the result as the new setting.
   - If **1, 2, or 3**: Use directly as the new setting.
   - If **anything else**: Show valid options and ask the user to choose.

3. Update the state file (the on-disk key stays `.project.autonomy_level` — do not rename it):
```bash
heimdall-state set '.project.autonomy_level' '<new_level>'
```

4. Confirm with a compact status line:
   - `◀ 1 Guided` / `◀ 2 Checkpoint ▶` / `3 Full Auto ▶`
   - Show the active setting highlighted, with arrows indicating cycle direction

## Valid settings:
- **1 (Guided)**: Asks before every action.
- **2 (Checkpoint)**: Runs on its own, pauses at major milestones.
- **3 (Full Auto)**: Runs until complete; only stops if blocked.

Going forward, use `/hmd:autonomy` (and `/hmd:autonomy +` / `-` to cycle).
