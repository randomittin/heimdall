# Hook-delivery spike: `TaskCompleted`/`TaskCreated` parent delivery, and `SubagentStop` on non-clean death

Task: brief-1787627102-864. Empirical spike, not a build task. No production files
changed; scope was an isolated scratch harness under `/tmp` plus this doc.

## Questions this was asked to resolve

1. Do `TaskCompleted`/`TaskCreated` hooks fire in the **parent** session, and does
   their output reach the parent's context?
2. Does `SubagentStop` fire at all on **non-clean** subagent termination (killed by
   quota/overload/context-limit/stall-watchdog) — or only on clean stop?

Both were previously open: a decompiled-strings investigation had shown
`SubagentStop`'s `additionalContext` targets the subagent, not the orchestrator, and
that `SessionStart` is the only proven orchestrator-delivery path but only fires at
next-session-start, not at moment of death. `bin/heimdall-metric-hook`'s own header
flags question 2 as unresolved in this exact codebase.

## Method

Built an isolated harness entirely under `/private/tmp/.../scratchpad/hookspike/`:
a shared `loghook.sh` that appends one ndjson record (timestamp, event, pid, ppid,
pgid, cwd, full raw hook stdin JSON) to `hooklog.ndjson`; a scratch `settings.json`
(never touching this repo's `hooks/hooks.json`) wiring `SessionStart`, `Stop`,
`SubagentStop`, `TaskCompleted`, `TaskCreated`, and `PreToolUse`/`PostToolUse` on
matchers `Task`/`Agent`/`Bash`, each pointed at `loghook.sh` with a distinct event
label. Nested, non-interactive `claude -p` sessions were launched against this
settings file (`--settings`, `--output-format stream-json --include-hook-events
--verbose --dangerously-skip-permissions --model sonnet --effort low
--max-budget-usd 1 --no-session-persistence`), each instructed to invoke exactly one
`general-purpose` subagent via the `Agent` tool.

Three runs, in order:

- **Run B (control)** — subagent runs `sleep 20` synchronously, replies `DONE`,
  parent replies `FINISHED`. Baseline for clean completion.
- **Run C (incidental)** — subagent was asked to run `sleep 240` and reply `DONE`;
  it chose `run_in_background: true` for its own Bash call (not instructed either
  way at that level — my prompt only pinned the outer `Agent` call to
  non-background). Kept as a secondary data point; see below.
- **Run D (the designed kill test)** — prompt made explicit at *both* levels
  (`Agent` call `run_in_background: false`, and the Bash command "do NOT pass
  run_in_background or any async/background option"). This produced a genuine
  foreground `sleep 240` OS process. I located it via `ps`, confirmed it directly
  (`args = "sleep 240"`, `etime = 00:40`), then ran `kill -9` on it myself and
  watched what happened.

Kill signal: **SIGKILL, deliberately, as the primary and only signal used.**
Reasons: (a) it's the closest single-signal analogue to a quota/OOM/stall-watchdog
death — uncatchable, no chance for cleanup code; (b) this repo has a prior finding
that untrapped SIGTERM doesn't reliably run bash `EXIT` traps on this host either,
so SIGTERM wouldn't have bought a materially cleaner signal for the same question;
(c) SIGKILL is the strongest form of the test — if `SubagentStop` still fires when
the target process gets zero opportunity to run any of its own code on the way out,
that proves the firing logic lives entirely in the parent/orchestrating process, not
in anything the dying process does. Given that stronger result, a second SIGTERM
run was judged not to add information proportional to its cost and was not run —
consistent with this task's explicit instruction to bias toward decisive action over
exhaustive investigation.

## Finding 1 (OBSERVED): `TaskCompleted`/`TaskCreated` never fired — in any run

Across all three runs (8 hook types registered, ~24 possible firing opportunities:
session start, a clean completion, a self-backgrounded still-running-at-stop case,
and an externally-SIGKILLed case):

```
$ grep -o '"event": "TaskCompleted"\|"event": "TaskCreated"' hooklog.ndjson | sort | uniq -c
(no output — zero matches)
```

No stderr warning about an unrecognized hook name was emitted in any of the three
runs (checked `runB.stderr.log`, `runC.stderr.log`, `runD.stderr.log`):

```
$ grep -i 'hook\|unrecognized\|unknown event\|warn' runB.stderr.log runC.stderr.log runD.stderr.log
(no output)
```

**OBSERVED:** these two hook names never fired, under this delivery mechanism
(a plain `Agent`/`Task`-tool `general-purpose` subagent), across clean, self-backgrounded,
and killed conditions.
**Could not determine:** whether `TaskCompleted`/`TaskCreated` are recognized hook
names at all in this Claude Code build. Silent non-firing is also exactly what
silent acceptance-and-ignoring of an unknown key would look like — the absence of a
validation error is weak evidence, not proof the names are real. I did not find a
condition that triggers them; I cannot rule out they require a different
subagent-dispatch mechanism (e.g. the separate-OS-process "agent team" mechanism
this orchestrator itself uses — see Finding 3) rather than the in-process Task tool
used here. **Question 1 is not resolved to a positive answer; it is resolved to a
clean, directly-tested negative under this specific mechanism.**

## Finding 2 (OBSERVED): `SubagentStop` DOES fire after an external SIGKILL, ~2s later

Run D, full ordered event sequence for session `55967613-c119-4133-979e-686701ead1e7`
(via `jq` over `hooklog.ndjson`):

```
03:29:27Z SessionStart
03:29:34Z PreToolUse_Task / PreToolUse_Agent   (run_in_background: false)
03:29:40Z PreToolUse_Bash  agent_id=a0183b532b4cf2409  cmd="bash -c 'sleep 240'"
03:30:30Z  <-- kill -9 62415 sent here (my own `date -u` read immediately after the kill command)
03:30:32Z SubagentStop     agent_id=a0183b532b4cf2409  last_msg="DONE"  background_tasks=[]
03:30:32Z PostToolUse_Task / PostToolUse_Agent
03:30:34Z Stop             last_msg="FINISHED2"
```

Process-tree proof the killed process really died, and died alone: immediately
after `kill -9 62415`, `ps -p 62415,62409,54453` showed only `54453` (the top-level
nested `claude` process) still alive — the leaf `sleep` (62415) and its parent shell
(62409, a distinct process group from the top-level session) were both already gone.
`54453` kept running and the whole nested session later exited 0 on its own, ~4s
after the kill.

Independent corroboration from the raw transcript (`runD.stdout.jsonl`), same
instant as the kill:

```
{"type":"tool_result","content":"Exit code 137","is_error":true,"tool_use_id":"toolu_01JguMdTUg7sgmeQGiQArpPq"}
...,"timestamp":"2026-08-25T03:30:30.093Z","tool_use_result":"Error: Exit code 137",...
```

137 = 128+9 = SIGKILL's exit code. This is the harness itself correctly detecting
and reporting the kill, at the exact tool-result level, at the same second I sent it.

**OBSERVED, directly, with quoted log lines: `SubagentStop` fires after a subagent's
foreground tool call is killed with an uncatchable signal from outside the process.**
It is not gated on the subagent's own code running any cleanup — it cannot be, since
SIGKILL admits none. **INFERRED from this** (not separately proven at the
source-code level, but the strongest single piece of evidence obtainable
black-box): the hook-firing logic lives in the parent/orchestrating process, which
detects the child's abnormal termination (however it does so internally — `waitpid`,
a closed pipe, etc.) and fires `SubagentStop` itself. This generalizes plausibly to
quota/overload/context-limit/stall-watchdog kills of the same shape (something
external terminating whatever the subagent's tool call was doing), since the
mechanism observed here does not depend on the killed process's cooperation.

### Important caveat: the payload does not expose that anything went wrong

`SubagentStop`'s own fields (`last_assistant_message: "DONE"`, `background_tasks: []`,
`stop_hook_active: false`) look **identical in shape** to a clean success — the
subagent, on receiving the `is_error:true` / `"Exit code 137"` tool_result, still
complied with its literal instruction ("once the Bash call returns, reply DONE") and
said DONE anyway. A consumer watching only the documented top-level `SubagentStop`
fields (`agent_type`, `last_assistant_message`, `session_id`, `transcript_path`,
`stop_hook_active` — per `bin/heimdall-metric-hook`) **cannot tell this death apart
from success** from those fields alone. The one avenue that does carry the evidence
is `agent_transcript_path` (present in the payload), which points at the subagent's
own transcript file containing the `is_error:true` tool_result — but that requires a
consumer to go read and parse that file; it is not summarized into any top-level
field. **This directly matters for anyone consuming `SubagentStop` for
retry/health decisions: presence of the hook firing is not evidence of success, and
absence of an explicit error field is not evidence of failure either — the payload
is silent on outcome by design (matches `heimdall-metric-hook`'s own comment that
`outcome` is deliberately left null).**

## Finding 3 (OBSERVED, architectural): the Task-tool subagent has no distinct OS process; every hook fires as a child of the single top-level CLI process

Across all three runs, for every single hook event (including `SubagentStop`, and
regardless of whether the event logically pertains to the top-level thread or to the
subagent), the hook-invocation shell's `ppid` was constant and equal to that run's
top-level `claude -p` process — never to any subagent-specific PID:

- Run B (`ppid` constant at `84241`): SessionStart, PreToolUse×2, SubagentStop,
  PostToolUse×2, Stop all show `ppid: 84241`.
- Run C (`ppid` constant at `84627`): same pattern.
- Run D (`ppid` implicitly `54453`, confirmed via the live `ps` tree at kill time:
  `54453 claude` ← `54447 bash` ← `54435 zsh`, with the Bash-tool's own leaf command
  spawned as a *separate* process-group child of `54453` — `62409 zsh` → `62415
  sleep` — not of any "subagent" PID, because there isn't one).

**OBSERVED:** the `Agent`/`Task`-tool `general-purpose` subagent mechanism used in
this spike is an in-process construct inside the single top-level CLI process. It is
distinguished only by an `agent_id` field in hook stdin payloads, not by a separate
OS process. The only OS-process boundary a subagent's work actually crosses is
whatever leaf command its own tool calls spawn (here, the `sleep 240` under a fresh
process group) — and that is what had to be targeted for an external kill, not "the
subagent" itself, because no such distinct, killable process exists in this
mechanism.

This is a **different mechanism** from the separate-OS-process "agent team" model
(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) that this orchestrator session itself
runs under for its own coder/reviewer/etc. subagents (confirmed separately, by this
agent's own PID/PPID inspection, to be genuinely separate OS processes connected via
a `CLAUDE_CODE_MESSAGING_SOCKET`). This spike did **not** test hook delivery under
that separate-process mechanism — only under the in-process Task-tool mechanism.
That is a real scope gap, named here rather than glossed over: **it remains open
whether `SubagentStop` fires the same way, or `TaskCompleted`/`TaskCreated` behave
any differently, when the "subagent" is a genuinely separate OS process (the agent-team
case this repo's own Heimdall orchestration actually uses) rather than an in-process
Task-tool call.** I did not build or tap the messaging socket to investigate this —
per the brief, that channel was to be observed only, not used.

## Secondary/incidental finding (Run C): a self-backgrounded task can outlive `SubagentStop`

Not the designed experiment (no external kill was involved — this happened because
the subagent chose `run_in_background: true` for its own Bash call, unprompted), but
real and worth recording. Full sequence for session `9aaa3539-8c49-4427-b48e-a34b58771a80`:

```
03:20:14Z PreToolUse_Agent/Task   run_in_background:false (outer call)
03:20:18Z PreToolUse_Bash  agent_id=a00dda9c5ce14ecfd  cmd="sleep 240" run_in_background:true
03:20:25Z SubagentStop     agent_id=a00dda9c5ce14ecfd  last_msg="DONE"
          background_tasks=[{"id":"bws24qgmh","type":"shell","status":"running","description":"sleep 240","command":"sleep 240"}]
03:20:25Z PostToolUse_Agent/Task
03:20:26Z Stop             last_msg="FINISHED"  background_tasks=[]
```

`SubagentStop` fired 7s after the background sleep was launched (240s from done),
with that task still explicitly reported `"status":"running"` inside the
`SubagentStop` payload itself. The parent's own `Stop` one second later shows
`background_tasks: []` — empty, not carrying the child's still-running task forward.
**OBSERVED:** `SubagentStop`'s payload includes a live `background_tasks` array that
can show a task still `"running"` at the moment the subagent stops.
**Could not determine** (out of scope for this spike, not chased further per the
decisiveness instruction): whether that orphaned background shell task keeps running
to completion, detached, after the subagent that launched it has stopped, or whether
it gets torn down — Run C's wrapper process exited 0 shortly after with no further
observation window, and the ~4-minute sleep had ample remaining time unaccounted
for. Flagging as a real open thread, not resolving it here.

## What remains open

1. Whether `TaskCompleted`/`TaskCreated` are real, recognized hook names in this
   Claude Code build at all, under any mechanism.
2. Whether the Finding 2/3 results (SubagentStop fires; no distinct subagent OS
   process) hold under the separate-OS-process "agent team" mechanism this repo's
   own orchestrator actually uses day to day, rather than the in-process Task tool
   used here.
3. Whether an orphaned background task launched by a subagent (Run C) is torn down
   or left running after that subagent's `SubagentStop` fires.

## Per the brief: not building on this

Question 2 came back positive (`SubagentStop` does fire on an external, uncatchable
kill), which is exactly the condition the brief said not to build past: "If you DO
find that `TaskCompleted` reaches the parent, do NOT build on it... Building is a
separate decision." `TaskCompleted` itself came back negative, but `SubagentStop`'s
positive result is the more actionable one here, so the same rule is applied to it.
Naming what it would enable, without building it: since `SubagentStop`'s hook
command is documented (and now, for the killed case, directly confirmed) to run in
the *parent* process (`bin/heimdall-metric-hook stop`, wired in this repo's real
`hooks/hooks.json`), and Finding 2 shows it fires promptly even when the subagent's
active work was killed rather than completed cleanly, this suggests the parent
*can* already be notified near-instantly of a subagent's non-clean death via the
hook already wired in production — the previously-unresolved question was only
whether it fires at all in that case, not whether it reaches the parent (it always
ran in the parent). This could, in principle, let `heimdall-agent-resume`-style
classification start from the moment of death rather than waiting for next
`SessionStart`. That is a design/build decision for someone else to make
deliberately — not a continuation of this spike.

## Cleanup proof

Process sweep, after all three runs concluded, for anything tied to the spike:

```
$ ps -eww -o pid,ppid,stat,comm,args | grep -i 'hookspike\|claude -p' | grep -v grep
(no output)
$ ps -eax -o pid,ppid,stat,comm | awk '$3 ~ /Z/'
(no output — no zombies)
```

The two pre-existing `sleep` processes noticed mid-spike (`ps` showed `41259` and
`37696`) were checked and confirmed to belong to this repo's own
`heimdall-presence keeper-loop` daemons (`ppid 24541`/`6840`, running since before
this spike started) — unrelated, not touched.

Worktree state, in this worktree (`/Users/rj/Downloads/heimdall/.claude/worktrees/agent-a163d82c69ec3d50a`):

```
$ git status --porcelain
(no output — clean)
$ git diff --stat -- hooks/hooks.json
(no output — untouched)
```

All experiment artifacts (settings.json, loghook.sh, prompt/run/poll scripts, ndjson
log, stdout/stderr captures, the scratch `project/` dir used as the nested sessions'
cwd) live only under
`/private/tmp/claude-501/-Users-rj-Downloads-heimdall/01313446-ae34-4e0c-9f91-4ef0bd66593c/scratchpad/hookspike/`
and were never referenced from, nor copied into, this repository.
