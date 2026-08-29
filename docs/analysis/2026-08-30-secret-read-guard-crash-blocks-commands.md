# secret-read-guard crashed and blocked a legitimate command

Observed 2026-08-30 by the orchestrator, on itself.

## What happened

A routine Bash call (git log + grep + a python json read) was refused by the
PreToolUse chain:

    PreToolUse:Bash hook error: [... exec "$G"]: No stderr output

"No stderr output" is the tell. A deliberate deny prints a BIFROST message and a
JSON `{"error": ...}` payload. This printed nothing, so the guard did not decide
to block — it FAILED, and the harness treated a non-zero exit as a block.

## Why this matters

`bin/secret-read-guard`'s own header states the intended split:
  - the SECURITY question fails CLOSED (cannot classify -> block);
  - the guard's OWN PLUMBING fails OPEN, because "a hook that wedges every tool
    call on its own bug is a worse outcome than one blind spot".

The second half did not hold here. A plumbing failure reached the harness as a
refusal, with no message explaining why. That is the worst shape a guard can
fail in: invisible, and blocking legitimate work.

## Not reproducible from the parts

Each component of the command, replayed individually through the guard, exits 0:
grep over bin/agent-pool, a literal `~/.heimdall/agent-pool.json` string, and the
git merge. So the trigger is something about the COMBINED payload — plausibly
quoting/escaping of a multi-line command containing nested `$( )` and embedded
quotes reaching jq, or a crash in the Bash-command parsing path. NOT VERIFIED —
recorded as an open question rather than guessed at.

## Required fix

The guard must never exit non-zero for a non-security reason. Wrap the whole
body so any unexpected error path exits 0 (allow) and, if it wants to be loud,
says so on stderr. A deny must ALWAYS carry its explanatory payload; a silent
non-zero exit should be impossible by construction.

Until then the guard can intermittently refuse legitimate commands with no
explanation, which is how a security control gets disabled wholesale.
