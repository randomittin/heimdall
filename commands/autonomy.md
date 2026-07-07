---
name: autonomy
description: Set Heimdall autonomy (1=Guided, 2=Checkpoint, 3=Full Auto) — how much the agent does before asking. Use with a number, +/- to cycle, or no argument to show current.
argument-hint: <1|2|3|+|->
disable-model-invocation: true
---

# Set Autonomy

Set how much Heimdall does on its own before pausing for you.

## Valid settings:
- **1 (Guided)**: Asks before every action. You approve each step. Nothing runs unreviewed.
- **2 (Checkpoint)**: Runs on its own, pausing at major milestones for a look before continuing.
- **3 (Full Auto)**: Runs until the work is complete; only stops if blocked or a gate fails.

## Instructions:

1. Parse `$ARGUMENTS`:
   - If **empty or missing**: Show current setting from `heimdall-state get '.project.autonomy_level'` and the descriptions above. Done.
   - If **`+`**: Read current setting, increment by 1 (wrap 3→1). Use the result as the new setting.
   - If **`-`**: Read current setting, decrement by 1 (wrap 1→3). Use the result as the new setting.
   - If **1, 2, or 3**: Use directly as the new setting.
   - If **anything else**: Show valid options and ask the user to choose.

2. Update the state file (the on-disk key stays `.project.autonomy_level` — do not rename it):
```bash
heimdall-state set '.project.autonomy_level' '<new_level>'
```

3. Confirm with a compact status line:
   - `◀ 1 Guided` / `◀ 2 Checkpoint ▶` / `3 Full Auto ▶`
   - Show the active setting highlighted, with arrows indicating cycle direction

4. If changing from a lower to higher setting, add: "More autonomous now. `/hmd:autonomy -` to step back."

5. If changing from a higher to lower setting, add: "More checkpoints now. `/hmd:autonomy +` to step up."

## Quick cycling

Since Claude Code keybindings only support built-in actions (no custom action registration), the fastest way to cycle is:
- `/hmd:autonomy +` — next setting (1→2→3→1)
- `/hmd:autonomy -` — previous setting (3→2→1→3)

This is the Heimdall equivalent of the effort slider. Users can type `/a` + tab-complete to `/hmd:autonomy` and then `+` or `-`.

> `/hmd:level` still works as a deprecated alias for one release, but `/hmd:autonomy` is the name going forward.
