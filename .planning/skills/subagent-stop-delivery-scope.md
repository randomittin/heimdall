# subagent-stop-delivery-scope — SubagentStop cannot notify a live orchestrator

A negative-result lesson from a 2026-08-24/25 investigation into whether a `SubagentStop`
hook could deliver a dying subagent's retryable-cause classification to the ORCHESTRATOR's
own context at the instant of death — the natural next thing to try once
`bin/heimdall-agent-resume` had already shipped its own "cannot itself retry anything"
ceiling (see that file's header). The answer is NO, checked against the platform's own
compiled behavior, not just its docs. Recorded here so the investigation is never re-run:
the verdict is settled, not provisional. The signpost pointing here lives in
`bin/heimdall-agent-resume`'s header, next to the ceiling statement that motivates trying
this in the first place.

## Trigger

You are about to add (or are evaluating adding) a hook whose GOAL is to notify the
ORCHESTRATOR — not the dying subagent itself — about that subagent's termination cause,
retryability, or any other state, at or near the instant of death. This includes reaching
for `SubagentStop` directly, or reaching for `TeammateIdle` as a substitute once
`SubagentStop` looks unpromising.

## Steps

1. Stop — this doesn't work, and it has already been checked mechanically, not just read
   about. Read `bin/heimdall-agent-resume`'s header before writing a line of hook code.
2. Don't re-run the investigation on faith alone, but don't take it on faith either: the
   check is cheap. Decompile the running CLI binary (`strings -a "$(command -v claude)"` or
   the installed binary path) and grep for the per-event hook doc-comment text. The
   platform's own words describe different delivery targets: `Stop`'s `additionalContext` is
   "delivered to the model; the conversation continues" (orchestrator-facing); `SubagentStop`'s
   is "delivered to the subagent; the subagent continues" (dies with the subagent). Then
   confirm `HOOK_EVENT_REGISTRY` maps both event names to the SAME handler function —
   `SubagentStop` is `Stop`-for-a-subagent, not a distinct orchestrator channel.
3. Don't reach for `TeammateIdle` as the workaround — it is scoped to agent-teams
   membership, not generic `Task`-tool spawns, so it doesn't cover the common case either.
4. If instant-of-death delivery to the orchestrator is the actual requirement, there is no
   hook that provides it today. Say that plainly instead of shipping something that looks
   like it works but silently never fires where you think it does.
5. Reach for `SessionStart` instead, if next-session-start timing is acceptable — it is the
   one proven path (see Why). This repo already ships it: `heimdall-quota-resume`'s
   `resume-hint` SessionStart hook calls `bin/heimdall-agent-resume resume-hint`, surfacing an
   "N INTERRUPTED SUBAGENT(S) found" summary in the orchestrator's own context — measured cost
   24.6ms / 23.3ms / 24.5ms across 3 samples.
6. Re-verify rather than assume-stable if the platform version has moved far from CLI
   2.1.220, the version the binary evidence below was gathered on. This lesson was last
   confirmed current under a session pinning 2.1.241 — a small gap, judged low-risk because
   hook delivery-scoping is core platform plumbing, but it is a real, stated version gap, not
   a proven-stable-forever fact.
7. Do not silently resolve the two open questions below by assumption just because this
   verdict reads as settled — they are independently unresolved and were never part of it.

## Why

Claude Code's hook events are scoped by delivery target, not merely by name similarity to
`Stop`. Decompiling the Claude Code CLI binary (v2.1.220) via `strings -a` surfaces the
platform's own per-event doc-comment text verbatim: `Stop`'s `additionalContext` is
documented as "delivered to the model; the conversation continues" — the orchestrator's own
context, mid-session — while `SubagentStop`'s is documented as "delivered to the subagent;
the subagent continues." The subagent is, definitionally, the thing that just died or is
finishing; there is no path from that text back to a live orchestrator. Structurally, this
isn't a doc-comment oversight: the binary's `HOOK_EVENT_REGISTRY` maps `Stop` and
`SubagentStop` to the SAME internal handler function. `SubagentStop` is not a sibling event
with independent semantics — it is `Stop`, parameterized for "the thing that stopped is a
subagent," and `Stop`-shaped hooks are inherently scoped to the thing that stopped.

The one channel proven to reach the orchestrator is `SessionStart` — observed live in this
repo, not just documented: `heimdall-quota-resume`'s `resume-hint` SessionStart hook calls
`bin/heimdall-agent-resume resume-hint`, and its interrupted-subagent summary lands in the
orchestrator's own context at the next session start (measured 24.6ms / 23.3ms / 24.5ms
across 3 samples — negligible cost). The gap it cannot close is timing: "next session start"
is not "the instant of death," so anything that genuinely needs the latter has no
implementation today.

A `claude-code-guide` consult against current public docs returned "cannot confirm either
way" — the public docs are silent on delivery scope, not contradicting the binary evidence,
and the consult itself deferred to the binary as more authoritative. Treat the binary's own
doc-comment text, not the public docs' silence, as the standing evidence here.

## Open, unresolved — do not treat as settled by this verdict

- Whether `TaskCompleted` / `TaskCreated` deliver to the PARENT session at all — undocumented,
  never spiked.
- Whether `SubagentStop` even fires reliably on a NON-CLEAN termination (a quota-kill,
  overload-kill, or context-limit-kill) versus a clean stop only — flagged unresolved by this
  repo's own `bin/heimdall-metric-hook` header ("also undocumented whether SubagentStop even
  fires reliably when a subagent is killed by a quota/turn limit rather than finishing
  cleanly"), independently of this investigation.

## Outcome

No code behavior changed. `bin/heimdall-agent-resume` gained a documentation-only signpost
section; this file is the reusable lesson it points to. `bash test/heimdall-agent-resume.test.sh`
(62 passed) and `bash test/heimdall-agent-resume-pressure.test.sh` (24 passed) both unchanged
by the comment-only edit.
