# Seamless restart after an update

When an update of Claude Code or of hmd lands while an interactive `hmd` session is running, the session restarts itself at the first quiet moment and
comes back on the new version, in the same conversation, with one line printed. You do not type anything and nothing of the run is lost that a resume keeps.

    [heimdall] updated claude 2.1.322->2.1.323, hmd 2.4.1->2.4.2 - resumed

Only the halves that changed are named. Plan and measurements: `docs/superpowers/plans/2026-11-13-seamless-update-restart.md`,
`docs/analysis/2026-11-13-seamless-restart-spike.md`. Proof: `bash test/seamless-restart-e2e.test.sh` (below).

## The decided defaults (2026-11-22)

| Question | Decision |
|---|---|
| On or off | **On by default** for every interactive `hmd` session. Opt out with `HMD_AUTO_RESTART=off` in the environment (any case), with `hmd restart off`, or by creating `$HEIMDALL_HOME/no-auto-restart`. |
| Quiet window | **300 s** without a keystroke: the lifetime of the prompt cache, so the restart costs no extra tokens. `hmd restart defer [minutes]` pushes it out by hand, `hmd restart now` skips it once. |
| Parked agents | Parked mailbox teammates (named agents that never finish) **do not block** a restart. They are in-process, a restart is what clears them, and the printed line names them (`(parked agents ended: ...)`). Agents that are working do block it. |
| `claude --bg` | **Out of scope.** Only supervised foreground sessions restart. Revisit after `hmd --resume` attach has run in practice. |

## How it works

1. `bin/heimdall` runs claude as a supervised child (`bin/lib/hmd_supervise.sh`), only when stdin and stdout are a terminal and the launch is the interactive
   one or `hmd --resume`.
2. The `Stop` hook `bin/heimdall-restart-request` (switch: `heimdall-hooks disable seamless-restart`) asks, at the end of every turn, whether a newer claude or hmd
   is installed than this session started with. If so it writes `req.json` into the launcher's private directory and sends the launcher one `USR1`. It only
   asks: it never ends anything and never blocks a turn.
3. The launcher asks `bin/heimdall-restart-gate` twice, a few seconds apart. Both answers must be `SAFE`; otherwise the request waits (and expires after two
   hours, a new turn makes a new one).
4. On the second `SAFE` it writes a checkpoint, notes the session id **in effect at that moment** (a `/clear` changes it), and sends claude exactly one
   `SIGTERM`: claude exits by itself, restores its own terminal and flushes its transcript. Never a `SIGKILL`, never a signal to any other process.
5. The launcher restores the terminal, prints the one line and re-execs the NEW launcher (new preamble, new routing, new hooks) with `--resume <session id>`. The
   re-entered launcher prints nothing else (no banner, no loaded-state or model line, no nudge; the supervisor marks the exec with `HMD_RELAUNCHED`, which the launcher
   believes only beside its own pid, reads once and removes), so a restart leaves one line on the screen.

## The safe point

| Gate | Holds when | Reason token when it does not |
|---|---|---|
| G1 | `HMD_AUTO_RESTART` is not `off` and `$HEIMDALL_HOME/no-auto-restart` is absent | `opt-out` |
| G2 | the launch is supervised (a terminal, not `-p`, not a pipe, not a `--team` pane) | `not-supervised` |
| G3 | an update is pending and has fully landed: `heimdall-update-pending` reports it, no installer is running, the newest claude binary is at least 30 s old | `no-update`, `install-running`, `binary-fresh` |
| G4 | the turn ended: the session file says `idle`, has said so for 15 s, and the idle began right after the last Stop | `not-idle`, `settling` |
| G5 | no background work: no live subagent, no running sweep, no recent harness task output, no child of claude that is not infrastructure | `agents-live`, `sweep-running`, `task-live` |
| G6 | the keyboard is quiet for 300 s and no `hmd restart defer` is running | `user-active` |
| G7 | the session is at least 60 s old, the previous restart at least 600 s ago, and that restart did not already go to these versions | `loop-guard` |
| G8 | no rebase or merge is in progress in the session's repository | `git-midop` |

Anything the gate cannot read (the session file, the tty, a helper that hangs) is `signal-unreadable` and counts as unsafe: a restart that does not happen costs the
old behaviour (a notice that the session is pinned), a restart at the wrong moment costs your run.

## `hmd restart`

| Verb | Does |
|---|---|
| `hmd restart status` | whether auto restart is on, any deferral, the waiting request, and what a resume does not bring back |
| `hmd restart defer [minutes]` | no restart before then (an hour by default, `0` clears, at most a week) |
| `hmd restart now` | skip the quiet window for a request that is waiting; every other gate still applies |
| `hmd restart off` / `on` | write or remove `$HEIMDALL_HOME/no-auto-restart` |

The verbs write files under `$HEIMDALL_HOME/restart/` and signal nothing.

## What a resume does not restore

Measured on claude 2.1.323 (the spike memo, question Q3). Restored: the conversation, the last model a turn used, the permission mode and the appended system
prompt (hmd's preamble). Not restored: the effort level (it falls back to the default), an unsubmitted draft in the prompt, and a `/model` switch that no turn had
used yet. Session-only "allow for this session" permission grants were not measured: assume they are asked for again. The quiet window makes a draft unlikely.
The first turn after a restart reads the whole context at full price; at 300 s of quiet the prompt cache has expired anyway.

## When it does not restart

- Print mode (`-p`, `hmd <task>`), a non-terminal launch, `hmd --team` panes, `heimdall-wrap` tools other than claude, and anything started by hand with
  `claude`: no supervisor, no restart, ever.
- Claude ignores the `SIGTERM` for 20 s: the request is dropped and the session is left alone until the next turn asks again. If it was only slow to shut down and exits 143 after
  that, the session is still resumed (the TERM was ours; there is never a `SIGKILL`); any other late exit is yours.
- The update did not take (claude still reports the old version after the restart): one restart per target version, so it does not loop. At most three
  restarts per launcher lifetime.
- The resume fails within 5 s: the launcher tries `--continue`, then a fresh launch that reads the checkpoint written seconds earlier, printing one line each.
- You quit (`/exit`) at the moment of the restart: a normal exit, nothing is relaunched.

## The proof: `test/seamless-restart-e2e.test.sh`

It drives the real `bin/heimdall` on a pty with the real Stop hook, gate and update check; only claude (`test/fixtures/fake-claude`), the process table and the
checkpoint writer are faked. The clock is virtual (the gate's `HMD_RESTART_NOW` plus a skew added in whole steps, so five minutes of quiet is one step) and
every assertion counts events, never seconds.

- **journey**: an operator is typing, an update lands, they go idle, the restart comes at the first quiet moment and the same session id is back, one line printed.
- **golden traces**: the oracle's restart-happy, restart-deferred and restart-loop-guard traces, plus term-ignored and print-mode.
- **50 seeded interleavings** of Stop, keystroke, live child, sweep, live agents, installer, `/clear`, `/exit` and time passing, with the invariants: the TERM follows
  two SAFE answers and none was given while busy, with live work or inside the quiet window (I1); at most one relaunch per target version (I2); every relaunch is
  `--resume <the session id at TERM time>` (I3); the launcher's status is the last child's (I4); only the fake claude gets a TERM and only the launcher a USR1 (I5);
  the line is printed once per relaunch (I6). The user's `/exit` is typed once the launcher has nothing left to decide (all but every fifth seed, which quits at a
  wall-clock time, the race with the TERM), so a loaded machine cannot make the user quit before the decision is made.
- **10 mutants** (`test/fixtures/fake-claude/mutants.list`), each a one-line `sed` of a copy of the real file: restart while busy, with live work, inside the quiet
  window, without `--resume`, with a stale session id, with `SIGKILL`, without the marker, on the `-p` path, without the terminal restore, and twice for one version.
  All ten must go red.
