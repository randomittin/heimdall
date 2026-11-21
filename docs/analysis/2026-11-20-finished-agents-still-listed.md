# Finished agents that stay listed as running

Date: 2026-11-20
Source: one long Heimdall session on the Fret repo (session `6d117238-87af-479a-8028-245c26e2495f`, 2026-10-25 to 2026-11-20, Claude Code 2.1.325).
Method: counts taken from the session transcript and the process table. Nothing here is estimated unless it says so.

## Summary

Agents that have delivered their result keep showing as "running" in the agent list, sometimes for hours, until the orchestrator stops them by hand. The owner noticed this several times in one session and had to ask for a clean-up each time.

The rows themselves cost almost nothing in memory: a finished agent has no process of its own. The real costs are elsewhere:

1. **Disk.** The session's subagent transcripts take 8.7 GB.
2. **Attention.** A finished row looks the same as a stuck one, so the owner cannot tell which agents need action.
3. **Turns.** Finished agents notify again, and each notice costs an orchestrator turn.

The rule in the Heimdall prompt that is meant to prevent this (§4d, "close idle agents") cannot work as written, because the signal it waits for never arrives for the kind of agent this session spawns.

## What was measured

| Fact | Value |
|---|---|
| Subagent transcripts on disk for this session | 2,051 files, 8.7 GB |
| Largest single subagent transcript | 582 MB (median 1.65 MB) |
| Main session transcript | 283 MB |
| Session process memory (RSS) | about 595 MB, one process |
| Separate OS processes belonging to finished agents | 0 |
| Agent spawns made by the orchestrator | 1,510 (896 general-purpose, 406 `hmd:coder`), none with `name:` |
| `idle_notification` messages received in the whole session | 0 |
| Distinct completion notices received | 4,378, of which 2,029 "finished" and 1,485 "waiting on its own background work" |
| Agents that sent more than one "finished" notice | 152 (one sent 32) |
| `TaskStop` calls on agents | 238: 163 succeeded, 75 failed |
| Failed stops: "No task found with ID" | 62 |
| Failed stops: "is not running (status: completed)" | 13 |
| Successful stops of an agent that had already reported "finished" | 5, between 2.5 and 3.0 hours after the finish notice |

The transcript stores each notice in several row types, so the notice counts were de-duplicated by agent, summary and duration. Treat them as close, not exact.

## The instance on 2026-11-20

The owner said agents had been running for over three hours and looked stuck. What was actually there:

- **Three finished agents still listed as running.** "Pill overlap + private-tab journey", "Two red Jev-patch UI tests" and "Flipkart inner pages not converting" had all reported their results, and their work was already merged. The only evidence they were still listed was the error text of a `TaskStop` on a different id, which printed them under "Running background agents". Stopping each one succeeded.
- **Two finished shells still listed as running.** Their output files were last written on 18 Nov 15:30 and 19 Nov 14:52. One had printed `exit=0`. No process existed for either. They were stopped on 20 Nov, roughly 42 and 18 hours after they ended. They belonged to an earlier session id and were carried across a resume.
- **One agent that really was idle.** The speed agent ran 7.5 hours in total (`duration_ms` 26,887,986) and wrote nothing between about 02:39 and 06:33, waiting for a build slot. This is a different problem (an agent waiting without a time limit), but from the outside it looked the same as the three finished ones.
- **A false "hung" flag.** The SessionStart hook reported that same speed agent as "[hung] INTERRUPTED" while it was making tool calls seconds earlier.
- **The sweep saw nothing.** `heimdall-agents orphans` printed "no orphaned, parked or wedged subagents" while the three finished agents above were still listed.

## Why it happens

These are the causes the evidence supports. The first two are read directly from harness messages; the third is an inference.

1. **A finished background agent stays resumable.** Every completion notice carries this note: "A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once." So "finished" is not an end state for the harness; the agent stays addressable, and by this session's evidence it can also stay in the running list.
2. **The §4d trigger never fires.** §4d says to call `TaskStop` when an `idle_notification` arrives. That message is sent for named teammates. This session spawned 1,510 agents, none named, and received zero `idle_notification` messages. The rule has nothing to react to, so closing depends on the orchestrator remembering.
3. **Compaction and resume lose track (inferred).** After a compaction the status block listed the three agents as "completed", yet the harness still held them as running. The orchestrator read "completed" and reasonably did nothing. The two stale shells came from a previous session id, which points the same way: the list survives a resume, the knowledge that the work is done does not.

## Why stopping by hand is unreliable

- 75 of 238 agent stops failed. 62 failed with "No task found", meaning the orchestrator was stopping something already gone; 13 failed because the agent was already completed. The orchestrator cannot tell in advance which state an id is in.
- There is no tool that lists what the harness considers running. The list only appears inside the error text of a failed `TaskStop`. Seventy such lists were seen in this session; that side effect was the only inventory available.
- `TaskStop` reaches only agents the calling session spawned, so rows left by a dead session cannot be closed this way.

## What it costs

- **Memory: small.** Finished agents have no processes. The session is one process at about 595 MB, and it is not possible from outside to say how much of that is held for finished agents. A claim that finished agents "occupy memory" is not supported by these measurements.
- **Disk: 8.7 GB.** This is the real space cost, and it grows with every spawn whether or not the row is closed. Stopping an agent does not remove its transcript. A few agents account for a large share (five transcripts are over 425 MB each); these are long agents that polled in a loop.
- **Turns.** 152 agents sent more than one "finished" notice. Each notice wakes the orchestrator for a turn that usually only says "still nothing new".
- **Trust.** The owner asked three times in one day whether things were stuck. Each time the honest answer needed a process listing and a transcript read to separate "finished but listed", "waiting" and "working".

## Recommendations

In order of value for effort:

1. **Stop on the finish notice, not on idle.** Change §4d: when a completion notice says "finished" (not "waiting on its own background work"), call `TaskStop` on that id in the same turn, unless the agent is being kept for a follow-up. This uses a signal that does arrive.
2. **Make it mechanical.** Prose rules in this repo have a poor record. A `SubagentStop` or notification hook can record each finished id in a small file, and a `UserPromptSubmit` or `Stop` hook can print the ids that finished and were never stopped. That gives the orchestrator a list instead of relying on memory.
3. **Fix the sweep.** `heimdall-agents orphans` should report agents that have a finish notice and no stop, and background shells whose process is gone. Today it reports neither.
4. **Carry the list across compaction and resume.** Write the open-agent list into the checkpoint, and on resume compare it with what the harness reports, so "completed" in a summary is not taken as "closed".
5. **Give waiting agents a time limit.** An agent waiting for a build slot should give up and report after a fixed time (for example 30 minutes) instead of waiting for hours. This is what made the speed agent look stuck.
6. **Fix the "hung" check.** The SessionStart hook should look at the time of the agent's last tool call before calling it hung.
7. **Prune subagent transcripts.** Add a clean-up that removes or compresses subagent transcripts of finished agents after a set age. This is the only item that recovers real space. Keep it opt-in: the transcripts are also the only record of what an agent did.
8. **Ask the harness for an inventory.** A way to list running tasks without provoking an error would remove the guesswork behind the 75 failed stops. This one is a request to Claude Code, not something Heimdall can add.

## Not established

- Whether the three finished agents were listed because of the resume, the compaction, or simply because nothing ever stopped them. The evidence fits all three.
- How much of the 595 MB session memory is retained for finished agents.
- How long each of the 2,029 finished agents stayed listed. Only five have both a finish notice and a later successful stop that could be matched; the rest were either never stopped or had already gone by the time a stop was tried.
