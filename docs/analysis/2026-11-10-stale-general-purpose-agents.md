# Stale long-running agents — root cause (2026-11-10)

Operator report: general-purpose agents get stuck and go stale after 1–2 h.

## Data
All subagent transcripts on this machine: `~/.claude/projects/*/*/subagents/agent-*.jsonl` + `.meta.json`
(2102 agents). Scripts: session scratchpad `agentscan.py`, `stall.py`, `busy.py`, `bashprof.py`.

| type | n | wall > 1 h | median wall |
|---|---|---|---|
| hmd:coder | 1030 | 217 | 26.9 min |
| general-purpose | 695 | 144 | 18.7 min |
| hmd:security-auditor | 109 | 43 | 31.6 min |

## What it is NOT
- **Not hangs.** Gaps ≥ 15 min where the agent waits on a tool or the API: general-purpose 7/695, hmd:coder 18/1030.
- **Not the big idle gaps.** Most gaps > 20 min come AFTER the agent finished its turn and sit until a later
  `SendMessage` resumes it (session limits, coordinator follow-ups). Wall time counts those; work does not.

## What it IS: the agent waits inside its own shell
Agents active > 1 h vs < 20 min (medians):

| | general-purpose long | short | hmd:coder long | short |
|---|---|---|---|---|
| seconds inside Bash calls | 4379 | 187 | 3143 | 94 |
| most-repeated command | 14× | 3× | 14× | 6× |
| peak context tokens | 169k | 91k | 549k | 230k |

Bash calls ≥ 2 min, split by shape:

| | poll loop | long command |
|---|---|---|
| general-purpose | 1355 calls, **167.8 h**, 266 agents | 986 calls, 92.5 h, 374 agents |
| hmd:coder | 940 calls, 113.6 h, 246 agents | 984 calls, 102.9 h, 293 agents |

Poll loop = `until grep -q DONE f; do sleep 30; done`, `for i in $(seq 1 58); do grep …; sleep …`,
`perl -e 'alarm 595; sleep 595'`, `pgrep … && sleep`. They wait in the FOREGROUND for a job the agent
itself put in the background, so the agent is blocked, burns its turns re-polling (each loop is cut at the
10-min Bash cap and re-issued: the 14× repeat), and its context grows with every poll result until it
reaches the turn cap or goes stale. 20050 of 24256 general-purpose Bash calls set no `timeout`.
Project share of > 5 min Bash time (general-purpose): fret 200.6 h, tvclean 3.9 h, routine 0.3 h.

Claude Code already blocks a bare foreground `sleep`; a sleep INSIDE a loop is not blocked.

## Root cause, ranked
1. **Foreground poll loops** waiting for background work (167.8 h gp, 113.6 h coder). The right tool is
   `run_in_background` + the completion notification, or the Monitor tool — the agent is told nothing about
   this; general-purpose gets no hmd agent rules at all.
2. **Long single commands without a bound** (92.5 h gp): sim/xcodebuild/test runs in the foreground.
3. UNMEASURED: single calls > 10 min (e.g. a 4.6 h `sim.sh delete`) exceed the Bash cap; likely the
   machine slept or the process was suspended. Not attributed.

## What hmd does today
- No Bash-hook guard against wait loops (`bin/heimdall-precheck-bash` has none).
- `bin/heimdall-precheck-agent` already rewrites spawns (`updatedInput`) but never touches general-purpose.
- No watchdog that sees "agent N min inside one Bash poll".

## Fix (mechanical)
1. **Bash hook: deny foreground wait loops** (`bin/lib/hmd_wait_guard.py`, kill-guard lexer): a loop
   (`until`/`while`/`for`) whose body sleeps, `perl … alarm N; sleep`, `sleep ≥ 60`, `tail -f`, a `pgrep`
   wait. Deny message: run the job with `run_in_background` and wait for its notification (or Monitor).
   Allow inside `run_in_background` calls. Override `HMD_WAIT_ALLOW=1`. Fail open.
   Acceptance: `test/wait-guard.test.sh` covers every loop shape above (taken from these transcripts) → deny;
   echo/grep that only mentions them → allow; background → allow.
2. **Agent hook: general-purpose gets hmd's agent rules** via `updatedInput`: append the no-poll/background
   rule, bounded Bash, commit-early. Acceptance: hook test asserts the appended block for general-purpose and
   no change for hmd:* agents.
3. **Re-measure** with these scripts one week after shipping: poll-loop hours per agent must drop.
