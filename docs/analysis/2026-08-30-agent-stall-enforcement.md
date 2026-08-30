# Agent stall enforcement — what landed, and what it does NOT cover

Measured cause breakdown across this session's transcripts:

    quota 202 | STALL 196 | turn_limit 40 | api_error 2

STALL is within noise of quota as the biggest killer, and unlike quota it is
ours to fix. The recurring shape: an agent reads for 10-30 minutes, produces
ZERO files and ZERO commits, then dies to a 600s stream-watchdog or a 50-turn
cap, losing its entire investigation.

## What existed, and why it was not enough

`bin/heimdall-agent-resume` REPORTS interrupted subagents -- which stopped, what
they were doing, worktree path, committed vs uncommitted, plus a ready resume
payload. Its own header states the boundary: it reports, it never acts. So
recovery depended on the orchestrator NOTICING and acting by hand. That worked
about five times today and failed the rest. A recovery path that depends on
someone remembering is not a recovery path.

## What landed

`bin/heimdall-agent-watchdog run` -- the enforcement layer. Per run, in order:
DETECT (reusing agent-resume's own report, not a second detector), PRESERVE
(commit uncommitted work in the stalled agent's OWN worktree), then CLASSIFY:
quota -> `do_not_retry` with the reset time; stall/turn_limit -> resumable, emit
the SendMessage payload; unknown -> surfaced, never auto-retried.

Verified live against the real session: 38/0 suite, and a real run correctly
classified every quota-killed agent as `do_not_retry`. That matters -- auto-
retrying a quota kill is what cascaded five agent deaths in one shot today.

## HONEST LIMITS -- read before relying on it

1. **It only preserves worktrees of agents in the INTERRUPTED list.** Measured:
   a dirty worktree from an unrelated/older session (`agent-a0091ebd...`) was
   skipped with `preserve: clean -> no commit needed`. That is correct scoping,
   not a bug -- it must never commit into a worktree it does not own -- but it
   means stale dirty worktrees still need `bin/heimdall-reap-idle` or a human.
2. **It is invoked, not automatic.** Something must RUN it after an agent stops.
   Whether a `SubagentStop` hook can carry the preserve step automatically is
   NOT VERIFIED; until it is, this has the same dependency-on-discipline that
   made the original problem, only now the action is one command instead of a
   judgement call.
3. **It cannot prevent a stall**, only recover from one. Prevention is a prompt
   discipline: scope briefs to named sections, and require write-and-commit
   within the first few tool calls. Measured this session: agents told to
   "write first, read second" produced work; agents handed a 500-line plan and
   told to read broadly stalled -- three times on one task.

## MEASURED GAP — found by using it, 2026-08-30

First real use failed. A metrics agent (`a72d1c43`) stopped at its 50-turn limit
with 1 uncommitted file. `hmd agents rescue` did NOT see it; the work was
preserved by hand, exactly as before.

Cause: the watchdog reuses `heimdall-agent-resume`'s report, which lists only
agents recorded as INTERRUPTED. A 50-turn-limit stop is not recorded there, so
the watchdog is blind to it — and turn-limit is one of the most common
recoverable stops (40 this session, and unlike quota it is always safe to
resume).

So the tool currently covers the case that must NOT be auto-retried (quota) and
misses a common case that SHOULD be (turn limit). That is backwards.

Fix direction: detection must not depend solely on the interrupted-list. A
worktree under `.claude/worktrees/agent-*` with uncommitted changes and no live
process is sufficient evidence to PRESERVE, whatever the recorded stop reason —
preservation is additive and safe, so it should use the broadest signal
available. Classification can stay narrow.

Recorded rather than fixed in the same breath: the tool shipped claiming a
capability that its first real invocation did not deliver, and that is the more
important finding.
