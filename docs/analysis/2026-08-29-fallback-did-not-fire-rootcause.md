# Why the fallback did not switch to OmniRoute when credits ran out

Third occurrence. Measured 2026-08-29 ~22:40 IST, immediately after two agents
were killed by `session limit · resets 11:30pm`.

## The measurement

At the moment of failure:

    heimdall-session-usage status  -> verdict=crossed, five_hour=100.00%
    heimdall-fallback check        -> VERDICT: WAIT (rc=2)
    heimdall-fallback base-url     -> '' (empty)
    preflight [INFO] session_usage -> "under the pre-exhaustion threshold"

So the usage probe said CROSSED and the gate simultaneously said UNDER. Both
read the same binary. They disagreed because they read it at different times
against a MUTATING source.

## Root cause: the signal is a lagging snapshot, not a live reading

`heimdall-session-usage` does not query Anthropic. It reads
`~/.heimdall/rate-limits.json`, a file the STATUSLINE writes as a side effect of
being rendered (PHASE 2 "bridged from a live statusline render persisted to
disk"). Verified live: the file's `used_percentage` moved 100.0 -> 3.0 across a
few seconds, tracking the operator's `/login`, and `where` resolves to a
transcript from a PRIOR session id, not the running one.

Three consequences, all load-bearing:

1. **It updates only when the statusline renders.** A long agent-heavy stretch
   with no render leaves the figure stale for minutes. Exhaustion arrives faster
   than the signal.
2. **It is a different clock from the one that kills work.** The 429s came from
   a SESSION limit ("resets 11:30pm") and earlier a WEEKLY one. `five_hour` can
   read 3% while the session limit is fully spent -- the number that fires the
   gate is not the number that stops the work.
3. **It is per-render, not per-spawn.** Even a correct value can be minutes old
   at the moment a spawn needs the decision.

## Why the earlier fixes did not cover this

- Wave 1 routed the SUBPROCESS path per-spawn. Real, but the agents that died
  were IN-PROCESS Agent-tool spawns, which have no exec boundary to re-route.
- Wave 2 added the `seven_day` window. Real -- it was genuinely blind before --
  but it reads the SAME lagging file, so it inherits the same staleness, and it
  still does not observe the SESSION limit at all.

Neither is wrong; neither addresses a stale-snapshot signal.

## What would actually fix it

**React to the 429, do not predict it.** The only unambiguous, correctly-timed,
always-available exhaustion signal is the error itself. On an observed HTTP 429,
mark the gate crossed for a bounded TTL so the NEXT spawn routes. That cannot
save the request that failed -- state that plainly rather than implying it can --
but it converts a silent repeat failure into a single failure followed by
automatic recovery, which is what happened three times today and did not recover.

Prerequisite, currently missing: nothing in hmd observes a 429 from an
in-process Agent spawn. The harness reports it as a task-notification, not to a
hook. So the honest scope is: the subprocess path can react to its own 429s
(`bin/lib/hmd-claude-retry.sh` already sees them); the in-process path needs the
ORCHESTRATOR to record the failure, because only it sees the notification.

## Deliberately NOT proposed

Polling an Anthropic usage endpoint (no client-side API for it), or estimating
consumption from token counts (`.planning/metrics.jsonl` carries zero token
fields today -- see the metrics-instrumentation work). A fabricated estimate
driving a routing decision is worse than a stale one, because it would look
authoritative.
