# Seamless restart after updates — plan

Date: 2026-11-13. Status: PLAN (no code). Operator ask (2026-11-13): "on autoupdate the restart should be automatic without any impact on the run".

Design gate note: no approved spec exists for this; this document is the design + plan in one. Section "Open questions" lists the 5 closed-option decisions the operator must make before Wave 2. Waves 0 and 1 are safe to start without them.

## 1. Findings (read-only investigation, 2026-11-13)

| # | Fact | Evidence |
|---|---|---|
| F1 | The interactive launch is a CHILD, not an exec: bare `claude --agent heimdall $PERMISSION_FLAG $MODEL_FLAG --plugin-dir ... --append-system-prompt-file ...` is the last statement of `bin/heimdall`; the launcher stays alive, its `EXIT` trap (`_heimdall_launch_cleanup`) restores skills and re-exits with claude's status. `--resume` is the same shape with `claude --continue`. | `bin/heimdall:5483-5510`, `3664-3735`, `3613-3633` |
| F2 | There is NO wrapper loop today. The only `exec`s of claude are `heimdall-wrap launch` -> `exec bin/heimdall` (`bin/heimdall:3366`, `bin/heimdall-wrap:323`) and the `claude` shim (`exec "$HMD_REAL"`, `bin/heimdall-wrap:460-475`), neither supervises. `--team` panes TYPE `claude --agent heimdall ...` into tmux shells (`bin/heimdall:3763-3772`): no launcher above them. `-p` goes through `capture_and_emit_usage` (`bin/heimdall:5440`). | same |
| F3 | The pin notice already knows running vs newest: `_claude_ancestor` + `_running_version` (lsof) vs `_newest_installed` (`ls versions | sort -V`). Message printed at SessionStart only. | `bin/heimdall-cc-selfheal:326-366` |
| F4 | `bin/heimdall-autoupdate` applies the hmd update by re-running the signed installer DETACHED; "takes effect the NEXT time hmd launches". Installed version = `git describe` or `.claude-plugin/plugin.json`. | `bin/heimdall-autoupdate:1-20,178-200` |
| F5 | `--continue`/`/hmd:continue` handoff: `heimdall-continue inject` is SessionStart with matcher `compact` ONLY, provenance-checked (untracked file + per-user record), one-shot. It does NOT fire on `--resume`. A resumed session keeps its own conversation, so it needs no handoff; the handoff is only a FALLBACK when resume fails. | `bin/lib/hmd_continue.py:1-50`, `hooks/hooks.json:333` |
| F6 | `~/.claude/sessions/<claude-pid>.json` (observed 2026-11-13, written by Claude Code itself, undocumented) carries `pid`, `sessionId`, `version` (the RUNNING binary, e.g. 2.1.322 vs 2.1.323), `kind` (`interactive`/`bg`), and `status` in {`idle`,`busy`,`waiting`(+`waitingFor`),`shell`} with `statusUpdatedAt`. This is the best idle signal and also the best session-id source (follows `/clear`). UNVERIFIED stability: schema is not in the public docs; Wave 0 must pin the values and the fallback. | `ls ~/.claude/sessions`, read of 4 live files |
| F7 | Claude Code (2.1.323 here) offers: `--resume <id>`, `--continue`, `--fork-session`, `--bg` (+ `claude attach|logs|stop|rm|agents`), `--remote-control`. `claude --bg --resume <id>` "continues that session in the background under the same ID". Hook docs (https://code.claude.com/docs/en/hooks, fetched 2026-11-13, page truncated at 100k chars) document `continue:false` (stops processing, does NOT exit), SessionEnd reasons `clear|resume|logout|prompt_input_exit|other`, and NO hook-driven exit and NO signal behavior. So "what exits claude?" is not answerable from docs: it is Wave 0's first question. | `claude --help`; WebFetch |
| F8 | Idle/busy-work signals that exist: Stop hook (turn ended, payload has `session_id`, `transcript_path`, `last_assistant_message`); `bin/heimdall-agents count` (live+working subagents, `bin/heimdall-agents:1029`); `receipts/sweep.lock` live pid (`bin/lib/hmd_sweep_guard.py:271`); harness task `.output` files under the session `tasks/` dir (used by heimdall-agents). Parked `name:` mailbox teammates are in-process coroutines that never finish (header of `bin/heimdall-agents`). | read |
| F9 | Another agent is wiring `claude attach` into `--resume`. This plan does not touch the attach logic; it reuses the shared launch call site (see W3 merge-order rule). | task brief |

## 2. Mechanism (decision)

**Supervised child + marker + relaunch-by-re-exec of the launcher.**

1. `bin/heimdall` interactive (and `--resume`) paths call one shared function `hmd_supervised_claude` (new `bin/lib/hmd_supervise.sh`, sourced) instead of the bare `claude ...` line. It starts claude in the background (`claude ... &`), stores `CLAUDE_PID`, `export HMD_LAUNCHER_PID=$$ HMD_RESTART_DIR=$HMD_HOME/restart/$$`, and loops on `wait "$CLAUDE_PID"` (re-waiting after a trapped signal). TTY: claude is a background job of a script, so it must stay in the foreground process group: do NOT use `&` job-control tricks that move it; use `set +m` default (non-interactive shell has no job control, child shares the launcher's pgrp and tty, so it keeps terminal input). Wave 0 verifies keystrokes still reach claude.
2. **Request (hook side).** A new `Stop` hook entry runs `bin/heimdall-restart-request`. It exits 0 immediately unless `HMD_LAUNCHER_PID` is set AND `heimdall-update-pending` reports a pending update. Then it atomically writes `$HMD_RESTART_DIR/req.json` `{session_id, claude_pid, stop_ts, pending:{claude:[a,b],hmd:[a,b]}}` and `kill -USR1 $HMD_LAUNCHER_PID`. The hook NEVER ends anything and NEVER blocks the turn (no `decision`, no `continue:false`).
3. **Decision (launcher side).** The launcher's `USR1` trap (and a 5 s poll while a req exists and is not yet satisfied) runs `bin/heimdall-restart-gate` (section 3). Gate runs twice, 3 s apart; both must say SAFE. If UNSAFE: leave req.json, keep polling, expire it after `HMD_RESTART_REQ_TTL_S` (default 7200). Never an error, never output.
4. **End.** On SAFE: read `sessionId` from `~/.claude/sessions/$CLAUDE_PID.json` (fallback: `session_id` in req.json), run `bin/heimdall-checkpoint write` (existing writer; safety net for the fallback path), write `$HMD_RESTART_DIR/restarting.json` `{claude_pid, session_id, from, to}`, then `kill -TERM $CLAUDE_PID`. Wait up to `HMD_RESTART_TERM_WAIT_S` (default 20). If claude is still alive: DELETE restarting.json, log, give up on this request (session untouched, retry only after a NEW Stop). **Never SIGKILL, never `kill` any pid other than the launcher's own child.**
5. **Relaunch.** When the child exits: if restarting.json exists AND its `claude_pid` equals the exited child AND not `HMD_AUTO_RESTART=off` -> restore terminal (section 5), run the launch cleanup WITHOUT exiting, print ONE line `[heimdall] updated claude 2.1.319->2.1.322, hmd 2.4.1->2.4.2 - resumed` (only the halves that changed), then `exec "$HEIMDALL_SELF" "${ORIG_ARGV[@]}"` with env `HMD_RESUME_SESSION_ID=<sid> HMD_RESTART_COUNT=n+1 HMD_RESTARTED_FROM=<a>-><b> HEIMDALL_NO_INTRO=1`. Re-execing the NEW launcher (not replaying old argv) is deliberate: the point of an hmd update is new preamble, new model routing, new hooks; replaying the old flags would pin the old launcher's decisions. The re-entered launcher's interactive branch, seeing `HMD_RESUME_SESSION_ID`, adds `--resume "$sid"` (the `--continue` flag stays as is for `hmd --resume`). Otherwise (no marker, or `claude_pid` mismatch) the child exited on its own (user `/exit`, crash, `-p`): exit with claude's status exactly as today.
6. **Resume failure fallback** (resume returns within 5 s with non-zero, e.g. "No conversation found"): relaunch once with `--continue`; if that also fails within 5 s, plain fresh launch whose preamble says "read .planning/CHECKPOINT.md (written seconds ago) and continue"; print `[heimdall] resume failed (<reason>); restarted from checkpoint`. Max 1 auto-restart per pending target version and none within 600 s of the previous one (loop guard, `HMD_RESTART_COUNT`/stamp in `$HMD_HOME/restart/last.json`).

**Why not the alternatives** (each recorded so the operator can overrule):
- Type `/exit` into the pty (expect/`script`/tmux send-keys): races a half-typed prompt, needs a pty owner or tmux; rejected as the default. Kept only as the Wave 0 fallback for tmux panes if SIGTERM proves unclean.
- `claude --bg` / daemon-held sessions + attach: would let the session outlive the terminal, but changes the whole run model and is owned by the attach agent; revisit after that lands (open question Q5).
- Hook returns `continue:false`: documented to stop processing, not to exit; would only freeze the session.
- `/reload-plugins` for hmd-only updates: a slash command only the user can type (same limit as `/compact`, see `bin/lib/hmd_continue.py:4`).
- Exec claude directly and rely on a second process: today's code runs claude as a child already, so no change of process model is needed.

## 3. Safe point (all must hold, evaluated by `bin/lib/hmd_restart_gate.py`, exit 0 = SAFE, 1 = UNSAFE with a one-token reason on stdout)

| # | Condition | Source | Default |
|---|---|---|---|
| G1 | Opt-out absent: `HMD_AUTO_RESTART` != `off` and no `$HMD_HOME/no-auto-restart` | env/file | on |
| G2 | Interactive launch: launcher had a TTY on stdin+stdout, not `-p`, not `--team`, not the shim/Cursor/other tools | launcher exports `HMD_SUPERVISED=1` only on that path | n/a |
| G3 | Update pending AND fully landed: `heimdall-update-pending` exits 0; no installer running (`pgrep -f 'heimdall.*install.sh'` empty); newest `versions/<v>` binary mtime older than 30 s | cc-selfheal + autoupdate | n/a |
| G4 | Turn ended: sessions file `status == idle` AND `now - statusUpdatedAt >= HMD_RESTART_SETTLE_S` AND the last Stop in req.json is newer than the last UserPromptSubmit | F6 + hook payloads | 15 s |
| G5 | No live background work: `heimdall-agents count` == 0; no live pid in `<repo>/.heimdall/receipts/sweep.lock` (reuse `hmd_sweep_guard.py` reader); no non-finished harness task `.output` newer than 60 s; no child of the claude pid except an allowlist (MCP servers, hook runners). Parked mailbox teammates do NOT block (they are dead weight, `bin/heimdall-agents` header) but are named in the printed line | F8 | n/a |
| G6 | User quiet: `now - atime(tty) >= HMD_RESTART_QUIET_S` (tty atime = last keystroke read; UNVERIFIED, Wave 0 W0-Q5). Any keystroke inside the window sets a per-session defer until `atime + QUIET` (the "defer" the operator asked for); `hmd restart defer [minutes]` sets one by hand, `hmd restart now` skips G6 only | tty stat | 300 s (Q2) |
| G7 | Loop guards: <= 1 restart per target version; >= 600 s since the previous; session older than 60 s | `last.json` | n/a |
| G8 | No unsaved-work hazard visible to git: not mid-rebase/merge (`.git/rebase-*`, `MERGE_HEAD`) in the session cwd | git dir | n/a |

Gate is pure: arguments/env/`HMD_RESTART_*` seams in, verdict out. It runs no model, writes nothing, never touches a process.

If any signal is missing or unreadable (sessions file absent, `lsof`/`stat` fails) the gate answers UNSAFE (`signal-unreadable`): failing to restart costs the old behavior (a pin notice), failing to be safe costs the operator's run.

## 4. Cases

| Case | Behavior |
|---|---|
| Headless `-p` / `capture_and_emit_usage` / non-TTY / CI | `HMD_SUPERVISED` never set; request tool exits 0; no restart, ever. Test asserts the `-p` argv has no supervisor and the hook is a no-op without `HMD_LAUNCHER_PID`. |
| tmux (solo `hmd` in a pane) | Works: launcher is the pane's foreground process, relaunch happens in the same pane. |
| `--team` panes | No-op: panes type `claude ...` directly, no launcher above. Pin notice only. (Routing panes through `hmd` is out of scope.) |
| Cursor / codex / gemini / aider (`heimdall-wrap` non-claude tools) | No-op: the supervisor lives only in the claude branch of `bin/heimdall`. |
| Windows | N/A: bash-only toolchain; gate G2 never true. |
| `hmd --resume` | Same function; its `--continue` becomes `--resume <sid>` only on an auto-restart (env var set), otherwise unchanged. |
| User `/exit` at the moment we TERM | `kill` returns ESRCH or exit happens first without marker match -> normal exit, no relaunch. |
| Update lands while claude is mid-turn | Nothing happens until the next Stop; req.json carries the pending versions, re-read by the gate each time. |
| Second update lands after a restart | New target version, so G7 allows one more. |

## 5. Terminal state restore

Launcher saves `stty -g` at supervisor start. After ANY child exit that is followed by a relaunch: `stty "$saved"`, then emit the reset sequence for modes a TUI can leave on (`ESC[?25h` cursor, `ESC[?2004l` bracketed paste, `ESC[?1000l ESC[?1002l ESC[?1006l` mouse, `ESC[?1004l` focus, `ESC[<u` kitty keyboard pop). Which of these claude actually leaves after SIGTERM is measured in Wave 0 (W0-Q2); the final list in `hmd_supervise.sh` is exactly what Wave 0 observed, no more. Only emitted when stdout is a TTY.

## 6. Risks

| Risk | Prob | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| SIGTERM is not a graceful exit for claude (loses transcript flush, leaves TUI modes) | med | high | Wave 0 measures; if not graceful the plan degrades to tmux-only `/exit` send-keys or notice-only (decision table in W0 memo) and Waves 2-3 do not start | W0-spike |
| `bin/heimdall` is overwritten in place by the installer while the old launcher bash is still reading it (bash reads scripts by offset): garbage executed after the supervised call returns | med | high | The supervised path never returns into old script text: it ends in `exec`/`exit` inside the same compound command (parsed as one unit); `hmd_supervise.sh` is sourced fully before the child starts. Test rewrites `bin/heimdall` in place while fake claude runs and asserts clean relaunch | W2-supervisor, W3-launcher |
| Session-only state is lost on resume: "allow for this session" permission grants, `/model` and effort switches, unsubmitted prompt draft, scrollback | med | med | W0 measures what `--resume` restores; launcher re-passes `--model` read from the sessions file when it differs from default; the QUIET window (G6) makes a draft unlikely; document the rest in `docs/seamless-restart.md` and print it in `hmd restart status` | W0-spike, W3-launcher |
| Prompt cache is cold after restart: first turn re-reads the whole context at full price | high | med | Default QUIET window equals the 5-minute cache TTL so the cache is already expired when restarting at idle (Q2 recommends this); documented | W1-gate |
| `~/.claude/sessions/*.json` schema is undocumented and may change | med | high | Gate fails closed to UNSAFE on any missing field or unknown `status`; `version` is cross-checked against lsof (cc-selfheal's existing method); W0 pins observed values; a canary test in W1 fails loudly if fields disappear (reads a live file only when `HMD_RESTART_LIVE_CANARY=1`) | W1-gate |
| Background Bash `run_in_background` jobs and in-process subagents may not show as non-idle | med | high | W0-Q4 measures both; G5 is multi-signal (heimdall-agents, task files, children of claude pid) so one blind spot does not restart a busy session | W0-spike, W1-gate |
| Race: keystroke / new turn / child exit / sweep start vs the decision | med | high | Two gate evaluations 3 s apart; TERM only to own child; seeded variable-latency interleaving sweep (section 8) with the never-restart-when-unsafe invariant | W4-e2e |
| Restart loop (updater keeps bumping, or resume keeps failing) | low | high | G7 + fallback chain terminates in a plain launch; `HMD_RESTART_COUNT` cap 3 per launcher lifetime | W2-supervisor |
| Another agent changes the `--resume` branch of `bin/heimdall` (attach) at the same time | high | med | Only two call sites change; W3 starts from the main that contains the attach work and re-reads lines first; if attach is unmerged W3 waits | W3-launcher |
| hook registry / lean-core checks reject the new hook | low | med | Register in `hooks/hooks.metadata.json` in the same task; named test checks both files | W2-hook |

## 7. Open questions for the operator (closed options)

**DECIDED 2026-11-22** (operator: "your call on auto restart"): Q1 = (a) ON by default for every interactive `hmd` session, opt out `HMD_AUTO_RESTART=off`; Q2 = (b) 300 s; Q3 = (a) parked mailbox teammates do not block, they are listed in the printed line; Q4 = moot, W0 measured SIGTERM graceful (proceed); Q5 = (a) out of scope for this plan, supervised foreground sessions only, revisit after `hmd --resume` attach (58447ffc) has run in practice. Note from W1: the launcher records `--launcher-start-hmd` from `.claude-plugin/plugin.json` (not describe-first), matching `bin/lib/hmd_update_pending.py`.

- **Q1 default**: (a) ON by default for every interactive `hmd` session, opt out with `HMD_AUTO_RESTART=off` [recommended: you asked for automatic]; (b) OFF until a one-time `hmd restart enable`; (c) ON only for claude-binary updates, hmd-only updates still wait for a manual restart.
- **Q2 quiet window before restart**: (a) 90 s; (b) 300 s = prompt-cache TTL, restart costs no extra tokens [recommended]; (c) 3600 s.
- **Q3 parked mailbox teammates** (named agents that never finish): (a) do not block a restart, list them in the printed line [recommended]; (b) block while any exist (then restarts would effectively never happen in heimdall sessions).
- **Q4 if W0 shows SIGTERM is unclean**: (a) tmux-only `/exit` via send-keys, notice-only elsewhere [recommended]; (b) notice-only everywhere (feature dropped); (c) pty-owning launcher (`script`/own pty) typing `/exit`, larger build.
- **Q5 `claude --bg` sessions** (attach agent's area): (a) out of scope here, supervised foreground only [recommended]; (b) after attach lands, allow background-hosted sessions to restart via `claude --bg --resume <id>`.

## 8. Test plan (falsifiable)

No registry oracle fits (`jq -r '.oracles|keys[]' evals/oracles/registry.json` lists attack, emulator-gb, exchange-lob, issue-collection, ponytail-underdelivery, rr-multitenant-isolation, symbol-reuse, team-checkpoint, team-copilot, triage-coord). FLAG for a reviewer: this is a stateful, concurrent process-lifecycle target; propose adding domain `launcher-supervise` after this ships. Until then the gate is:

- **Oracle gate:** domain `none-in-registry`; gate_type `trace-diff` (per-step recorded argv/env/signal log vs an expected trace file) plus a seeded `property` sweep for the race invariants; `independent: true`: the fake claude, the expected traces and the mutant list are authored in Wave 1 task `W1-oracle` from THIS plan's section 2/3 only, by a different agent than the Wave 2 supervisor/hook authors (separate wave, disjoint files).
- **Fake claude** (`test/fixtures/fake-claude/fake-claude.sh`): records every start as one JSON line `{ts,argv,env(HMD_*,PATH subset),pid,tty}` to `$FAKE_CLAUDE_LOG`; serves `~/.claude/sessions/<pid>.json` under a temp HOME with `status`/`sessionId`/`version` driven by a script file; on SIGTERM logs `{signal:"TERM"}` and exits per `FAKE_CLAUDE_TERM=graceful|ignore|slow`; exits on a `/exit` line in its control FIFO; can emit a Stop-hook call by running the real hook script against the real launcher env. No network, no real claude, never kills a real process (the supervisor under test only ever signals the fake it started).
- **Seeded interleaving** (rule 4 of the oracle protocol): `test/seamless-restart-e2e.test.sh` runs 50 seeds; each seed draws variable latencies for {Stop, keystroke (tty atime bump), sweep.lock appear, user `/exit`, second Stop, installer finishing} and asserts: (I1) TERM is never sent while the scripted status was non-idle or a background signal was live within the last gate evaluation; (I2) at most one relaunch per target version; (I3) every relaunch carries `--resume <the sessionId in effect at TERM time>`; (I4) launcher exit status equals the last child's; (I5) no pid other than the fake was signalled (the harness wraps `kill`); (I6) the one-line message printed exactly once per relaunch.
- **Falsifiability:** the same file runs a MUTANT matrix, each mutant a one-line `sed` of the real `bin/lib/hmd_supervise.sh` / `hmd_restart_gate.py` in a temp copy, and asserts the suite goes RED for every one: M1 skip gate G4 (restart while busy), M2 skip G5 (restart with a live agent), M3 ignore the keystroke window, M4 relaunch without `--resume`, M5 relaunch with the stale session id, M6 SIGKILL after timeout, M7 relaunch when no marker (user `/exit`), M8 supervise the `-p` path, M9 drop terminal restore, M10 allow second restart for same version. Pass = golden green AND 10/10 mutants red (score 1.0). Same shape as `bin/falsify <domain> --assert-score 1.0`, run locally by the test because no domain is registered.
- Per-task criteria name only the task's own test; no unit-suite sweep per task.

### Coverage matrix

| Subsystem | In scope | Oracle row | Expected |
|---|---|---|---|
| Gate (G1-G8) | yes | `test/restart-gate.test.sh`, mutants M1-M3 | green |
| Claude + hmd update detection | yes | `test/update-pending.test.sh` | green |
| Supervisor / end / relaunch | yes | `test/supervise-restart.test.sh`, e2e I1-I6 | green |
| Hook request side | yes | `test/restart-request-hook.test.sh` | green |
| Launcher call sites + CLI | yes | `test/launcher-supervised.test.sh` | green |
| Real claude SIGTERM/resume behavior | W0 only (measured, not CI) | W0 memo verdict lines | recorded |
| `--team` panes | descoped | `test/launcher-supervised.test.sh` case "team-pane-noop" | expected no-restart (asserted, green) |
| Cursor/other tools, Windows | descoped | `test/launcher-supervised.test.sh` case "non-claude-noop" | expected no-restart |
| Background-hosted (`--bg`) sessions | descoped (Q5) | none | not exercised |

## 9. Waves

Base: every task starts from a worktree fast-forwarded to main. Same-wave tasks touch disjoint files (checked below). Each task: <= 3-4 files, its own named test run ONCE after its edits.

### Wave 0 (spike, 1 task, gates Waves 2+)

#### Task W0-spike
- **Wave:** 0. **Dependencies:** none. **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `bin/heimdall:5483-5510`, `bin/heimdall-cc-selfheal:326-366`, `bin/lib/hmd_continue.py:1-50`, this plan sections 2, 3, 5.
- **Files:** Create: `docs/analysis/2026-11-13-seamless-restart-spike.md`, `test/fixtures/fake-claude/spike-pty.sh` (throwaway-pty harness, kept as evidence). No other file.
- **Skills:** `superpowers:systematic-debugging`.
- **What to do:** in a temp HOME and a temp cwd, start ONE throwaway interactive `claude` (its own process, started by the harness under `script -q /dev/null`, one trivial prompt, never an existing session, never kill anything the harness did not start) and measure, writing one verdict line per question to the memo exactly in the format `Q<n>-<NAME>: <value>`:
  - Q1 `SIGTERM-GRACEFUL`: does SIGTERM make claude exit with its transcript intact, SessionEnd hooks run, exit code, within how many seconds; compare SIGHUP and SIGINT.
  - Q2 `TTY-MODES-LEFT`: `stty -a` before/after and the escape modes still on after exit (capture with `script`), so section 5's list is exact.
  - Q3 `RESUME-RESTORES`: after `claude --resume <sessionId>`: conversation visible? session-only permission grants, `/model`, effort, `--append-system-prompt-file` content (must be re-passed?) preserved? unsubmitted draft preserved?
  - Q4 `STATUS-SIGNAL`: values of `~/.claude/sessions/<pid>.json` `status` during idle, a running prompt, a permission prompt, a `run_in_background` Bash job, a running subagent; does `status` stay non-idle for the last two?
  - Q5 `TTY-ATIME`: does `stat -f %a <tty>` advance on a keystroke and not on claude's own output (macOS and, if a Linux box is available, GNU `stat -c %X`)?
  - Q6 `KEYSTROKES-REACH-CHILD`: with claude started as a background job of a bash script that then `wait`s, do keystrokes, Ctrl-C and window resize reach claude?
  - Q7 `INSTALL-INPLACE`: does `install.sh` / `git` rewrite `bin/heimdall` in place (same inode) or by rename? (read-only: inspect install.sh code and run the harness's own temp git repo experiment; do not run the installer.)
  - Memo ends with a decision table: if Q1 = no -> apply Q4 option the operator chose; if Q4 shows idle during background jobs -> G5 must rely on children/task files only; if Q6 = no -> use `wait`-less foreground child with a signal-forwarding wrapper instead of background `&`.
- **Acceptance criteria:**
  - [ ] `test -s docs/analysis/2026-11-13-seamless-restart-spike.md`
  - [ ] `for q in 1 2 3 4 5 6 7; do grep -qE "^Q${q}-[A-Z-]+: " docs/analysis/2026-11-13-seamless-restart-spike.md || exit 1; done`
  - [ ] `grep -q '^DECISION: ' docs/analysis/2026-11-13-seamless-restart-spike.md`
  - [ ] `bash -n test/fixtures/fake-claude/spike-pty.sh`
- **Verify:** the four commands above, all exit 0.
- **Done when:** the memo answers Q1-Q7 with measured values and a DECISION line.
- **Risks:** spends model tokens (one short interactive prompt); mitigation: one prompt, haiku via `--model haiku`, harness aborts after 120 s.

### Wave 1 (4 parallel tasks, no operator decision needed except Q2 default)

Disjointness: A = `bin/lib/hmd_restart_gate.py`, `bin/heimdall-restart-gate`, `test/restart-gate.test.sh`. B = `bin/heimdall-cc-selfheal`, `test/update-pending.test.sh`. C = `bin/lib/hmd_update_pending.py`, `bin/heimdall-update-pending`, `test/hmd-update-pending.test.sh`. D = `test/fixtures/fake-claude/fake-claude.sh`, `test/fixtures/fake-claude/expected/*.trace`, `test/fixtures/fake-claude/mutants.list`. No overlap.

#### Task W1-gate
- **Wave:** 1. **Dependencies:** W0-spike (only for the final value of G5/G6 sources; the pure logic does not depend on it). **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** this plan section 3; `bin/lib/hmd_sweep_guard.py:260-290`; `bin/lib/hmd_ci_guard.py` (house style for a python hook helper called from bash); `bin/heimdall-agents:1029-1053`; the W0 memo.
- **Files:** Create: `bin/lib/hmd_restart_gate.py`, `bin/heimdall-restart-gate` (3-line launcher exec'ing `python3 -I -S`, pattern `bin/heimdall-continue:8-14`), `test/restart-gate.test.sh`.
- **Skills:** `superpowers:test-driven-development`.
- **Patterns:** `bin/heimdall-continue` (wrapper), `bin/lib/hmd_sweep_guard.py` (fail-open/fail-closed commentary and env seams `HMD_*`).
- **Spec:** CLI `heimdall-restart-gate [--req FILE] [--now] [--json]`; reads env seams `HMD_RESTART_SESSIONS_DIR`, `HMD_RESTART_TTY`, `HMD_RESTART_AGENTS_CMD`, `HMD_RESTART_PENDING_CMD`, `HMD_RESTART_QUIET_S`, `HMD_RESTART_SETTLE_S`, `HMD_RESTART_NOW` (epoch for tests); prints `SAFE` or `UNSAFE <reason-token>` where token is one of `opt-out|not-supervised|no-update|install-running|binary-fresh|not-idle|settling|agents-live|sweep-running|task-live|user-active|loop-guard|git-midop|signal-unreadable`; exit 0 only for SAFE. Evaluates G1-G8 in that order.
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-restart-gate && bash -n bin/heimdall-restart-gate`
  - [ ] `python3 -I -m py_compile bin/lib/hmd_restart_gate.py`
  - [ ] `bash test/restart-gate.test.sh` exits 0 (one case per reason token: SAFE case plus 14 UNSAFE cases, each flips exactly one input of the SAFE fixture; plus `signal-unreadable` for a missing sessions file and for an unknown `status` value)
  - [ ] `grep -q 'signal-unreadable' bin/lib/hmd_restart_gate.py`
  - [ ] `! grep -n 'kill\|SIGTERM\|os.kill' bin/lib/hmd_restart_gate.py` (the gate never touches a process)
- **Verify:** `bash test/restart-gate.test.sh`
- **Done when:** gate returns the right verdict for every single-input flip and fails closed on unreadable signals.
- **Risks & Mitigation:** gate too strict so restart never fires -> test includes the all-clear SAFE fixture; sessions schema drift -> fail-closed + canary env.

#### Task W1-cc-pending
- **Wave:** 1. **Dependencies:** none. **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `bin/heimdall-cc-selfheal:326-380`, `test/heimdall-cc-selfheal.test.sh:1-60` (fake-recorder pattern).
- **Files:** Modify: `bin/heimdall-cc-selfheal` (new subcommand `pending [--pid P]` in the `case` at the end, and `cmd_pin_notice` text when auto restart is on). Create: `test/update-pending.test.sh`.
- **Skills:** `superpowers:test-driven-development`.
- **Spec:** `heimdall-cc-selfheal pending --pid P` prints `claude <running> <newest>` and exits 0 when `running < newest` (same `sort -V` rule as `cmd_pin_notice`), prints nothing and exits 1 otherwise or when anything is unreadable. Running version source order: `~/.claude/sessions/P.json` `.version`, then `_running_version` (lsof). When `HMD_AUTO_RESTART` is not `off` and `HMD_SUPERVISED=1`, `cmd_pin_notice` prints `[heimdall] claude A is pinned by this session; B is installed - restarting automatically at the next idle moment (HMD_AUTO_RESTART=off to disable)` instead of the "restart to adopt it" line.
- **Acceptance criteria:**
  - [ ] `bash -n bin/heimdall-cc-selfheal`
  - [ ] `grep -q 'pending)' bin/heimdall-cc-selfheal`
  - [ ] `bash test/update-pending.test.sh` exits 0 (cases: behind, equal, ahead, unreadable sessions file, lsof fallback, notice text with and without `HMD_SUPERVISED`)
- **Verify:** `bash test/update-pending.test.sh`
- **Done when:** one machine-readable command answers "is a newer claude installed than this session runs".
- **Risks:** existing `pin-notice` tests pin the old wording -> new wording only when `HMD_SUPERVISED=1`, old text byte-identical otherwise (test asserts this).

#### Task W1-hmd-pending
- **Wave:** 1. **Dependencies:** none (invokes `heimdall-cc-selfheal pending` by contract, overridable by `HMD_UPDATE_CC_PENDING_CMD`). **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `bin/heimdall-autoupdate:170-215` (`installed_version`, `norm_semver`), `bin/heimdall-continue:8-14`.
- **Files:** Create: `bin/lib/hmd_update_pending.py`, `bin/heimdall-update-pending`, `test/hmd-update-pending.test.sh`.
- **Spec:** `heimdall-update-pending --launcher-start-hmd X.Y.Z [--pid P]` prints up to two lines `claude A B` and `hmd A B`, exits 0 if at least one line printed. hmd half: version at launcher start (passed in; the launcher records it from the same source as `installed_version`, plugin.json `.version` fallback) vs the version now on disk (same function, same precedence, not re-implemented: the python reads `.claude-plugin/plugin.json` and `git describe` in that order matching `installed_version`; a differing result of the two sources is an error and prints nothing). `--json` prints the same as an object. Fail-closed: any unreadable input -> exit 1, no output.
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-update-pending && bash -n bin/heimdall-update-pending`
  - [ ] `python3 -I -m py_compile bin/lib/hmd_update_pending.py`
  - [ ] `bash test/hmd-update-pending.test.sh` exits 0 (cases: hmd newer, hmd same, hmd downgraded (not pending), claude-only, both, plugin.json missing, git describe vs manifest disagree)
- **Verify:** `bash test/hmd-update-pending.test.sh`
- **Done when:** one command reports every pending half, from the two canonical version sources, without re-deriving them differently.
- **Risks:** drift from `installed_version` -> test greps both for the same precedence order and a fixture exercises each source.

#### Task W1-oracle
- **Wave:** 1. **Dependencies:** none. **Agent:** `hmd:coder` (a DIFFERENT agent instance than W2-supervisor and W2-hook; reference authorship is independent). **Model + effort:** `sonnet` + `default`.
- **Read first:** this plan sections 2, 3, 8 ONLY (do not read any W2 code; it does not exist yet).
- **Files:** Create: `test/fixtures/fake-claude/fake-claude.sh`, `test/fixtures/fake-claude/expected/restart-happy.trace`, `test/fixtures/fake-claude/expected/restart-deferred.trace`, `test/fixtures/fake-claude/mutants.list` (M1-M10 of section 8, one `file<TAB>sed-expression<TAB>name` per line). Evaluate whether 3 expected traces fit; the limit for this task is 5 files (fixtures, `evals/`-style data skip the stub scan).
- **Spec:** `fake-claude.sh` as in section 8: records start JSON lines, serves `sessions/<pid>.json` from a script, honors `FAKE_CLAUDE_TERM`, exits on FIFO `/exit`, never forks a real claude, refuses to run unless `HMD_FAKE_CLAUDE=1`. Trace format: one event per line `START argv=... resume=<sid|none> | SIGNAL TERM | EXIT rc=N | PRINT <line>`, written from the section 2 sequence, not from any implementation.
- **Acceptance criteria:**
  - [ ] `bash -n test/fixtures/fake-claude/fake-claude.sh`
  - [ ] `HMD_FAKE_CLAUDE=1 FAKE_CLAUDE_LOG=$(mktemp) bash test/fixtures/fake-claude/fake-claude.sh --exit-now; test $? -eq 0`
  - [ ] `test "$(wc -l < test/fixtures/fake-claude/mutants.list)" -eq 10`
  - [ ] `grep -c '^START ' test/fixtures/fake-claude/expected/restart-happy.trace | grep -qx 2`
  - [ ] `! HMD_FAKE_CLAUDE= bash test/fixtures/fake-claude/fake-claude.sh >/dev/null 2>&1`
- **Verify:** the five commands above.
- **Done when:** a test double and expected traces exist that were written without sight of the implementation.
- **Risks:** fake drifts from real claude -> W0 measurements (sessions file schema, TERM behavior) are copied into the fake's header and cited.

### Wave 2 (2 parallel tasks; needs Q1, Q2, Q4 answered and W0 DECISION = proceed)

Disjointness: E = `bin/lib/hmd_supervise.sh`, `test/supervise-restart.test.sh`. F = `bin/heimdall-restart-request`, `hooks/hooks.json`, `hooks/hooks.metadata.json`, `test/restart-request-hook.test.sh`. No overlap.

#### Task W2-supervisor
- **Wave:** 2. **Dependencies:** W1-gate, W1-hmd-pending, W1-oracle, W0-spike. **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `bin/heimdall:3613-3660` (cleanup trap), `bin/heimdall:5483-5510`; W0 memo; `test/fixtures/fake-claude/fake-claude.sh`; `test/fixtures/fake-claude/expected/*.trace`; section 2 and 5 of this plan.
- **Files:** Create: `bin/lib/hmd_supervise.sh`, `test/supervise-restart.test.sh`. (Library only: it is sourced by W3, so it cannot collide with the attach agent's edits to `bin/heimdall`.)
- **Skills:** `superpowers:test-driven-development`.
- **Spec:** function `hmd_supervised_claude <claude args...>` implementing section 2 steps 1, 3, 4, 5, 6 and section 5; no top-level side effects on `source`; fully defined before the child starts; uses only the gate, `heimdall-update-pending` and `heimdall-checkpoint` through env-overridable command variables (`HMD_RESTART_GATE_CMD`, `HMD_UPDATE_PENDING_CMD`, `HMD_CHECKPOINT_CMD`, `HMD_CLAUDE_BIN` default `claude`); `HMD_AUTO_RESTART=off` -> behaves exactly as `claude "$@"; return $?` (no background, no trap). Signals only `$CLAUDE_PID`. Status of the function = the last child's status.
- **Acceptance criteria:**
  - [ ] `bash -n bin/lib/hmd_supervise.sh && ! grep -nE 'kill -(9|KILL)|kill -s (9|KILL)|pkill|killall' bin/lib/hmd_supervise.sh`
  - [ ] `grep -q 'hmd_supervised_claude()' bin/lib/hmd_supervise.sh`
  - [ ] `bash test/supervise-restart.test.sh` exits 0 and its output contains `golden: restart-happy trace matches` and `golden: restart-deferred trace matches` and `term-ignored: session kept, no relaunch` and `user-exit: no relaunch` and `off: byte-identical argv to bare claude`
  - [ ] `bash test/supervise-restart.test.sh` includes the in-place rewrite case: output contains `inplace-rewrite: relaunch clean`
- **Verify:** `bash test/supervise-restart.test.sh`
- **Done when:** with the fake claude, an update request leads to exactly one TERM at the safe point, one relaunch with `--resume <sid>`, and every refusal path leaves the session alone.
- **Risks & Mitigation:** see section 6 rows "SIGTERM not graceful", "in place overwrite", "restart loop".

#### Task W2-hook
- **Wave:** 2. **Dependencies:** W1-hmd-pending, W1-oracle. **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `hooks/hooks.json:361-420` (Stop entries and the `hook-enabled.sh` gating idiom), `hooks/hooks.metadata.json:1-30`, `bin/heimdall-continue:1-14`.
- **Files:** Create: `bin/heimdall-restart-request`, `test/restart-request-hook.test.sh`. Modify: `hooks/hooks.json` (one new object appended to the `Stop` array), `hooks/hooks.metadata.json` (entry `seamless-restart`).
- **Skills:** `superpowers:test-driven-development`.
- **Spec:** `heimdall-restart-request` reads the Stop payload on stdin (`session_id`, `stop_hook_active`), exits 0 with no stdout in all of: `HMD_LAUNCHER_PID` unset, `HMD_AUTO_RESTART=off`, `stop_hook_active` true, `heimdall-update-pending` exit 1, `kill -0 $HMD_LAUNCHER_PID` fails. Otherwise writes `req.json` atomically (temp + mv, 0600, in a 0700 `$HMD_RESTART_DIR`) and sends `USR1` to `$HMD_LAUNCHER_PID`. Always exit 0, wrapped in `perl -e 'alarm 5; exec @ARGV'` like the sibling Stop hooks; hook entry is gated by `hmd_hook_enabled seamless-restart` so `heimdall-hooks disable seamless-restart` turns it off.
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-restart-request && bash -n bin/heimdall-restart-request`
  - [ ] `jq -e '[.hooks.Stop[].hooks[].command] | map(select(contains("heimdall-restart-request"))) | length == 1' hooks/hooks.json`
  - [ ] `jq -e 'tostring | contains("seamless-restart")' hooks/hooks.metadata.json`
  - [ ] `bash test/restart-request-hook.test.sh` exits 0 (each no-op condition above, the happy path writes req.json and the recorded signal is USR1 to the fake launcher pid, hook exit status 0 and empty stdout in every case)
- **Verify:** `bash test/restart-request-hook.test.sh`
- **Done when:** the Stop hook only ever asks, atomically and quietly, and cannot affect a turn.
- **Risks:** new Stop hook slows every turn -> the first statements are `[ -n "${HMD_LAUNCHER_PID:-}" ] || exit 0` before any fork (test measures zero child processes in the unset case).

### Wave 3 (1 task)

#### Task W3-launcher
- **Wave:** 3. **Dependencies:** W2-supervisor, W2-hook, and the attach agent's `--resume` work merged to main (if not merged: wait, do not rebase onto an unmerged branch). **Agent:** `hmd:coder`. **Model + effort:** `sonnet` + `default`.
- **Read first:** `bin/heimdall:3613-3735`, `bin/heimdall:5483-5510` (re-read both on the current main; line numbers will have moved), `bin/lib/hmd_supervise.sh`, `bin/heimdall-wrap:262-335`.
- **Files:** Modify: `bin/heimdall` (source `bin/lib/hmd_supervise.sh`; replace the bare `claude ...` of the interactive branch and of `--resume` with `hmd_supervised_claude ...`; export `HMD_SUPERVISED=1 HMD_LAUNCHER_PID=$$ HMD_RESTART_DIR` only when stdin and stdout are TTYs and the branch is the interactive or `--resume` one; record `ORIG_ARGV`; consume `HMD_RESUME_SESSION_ID` to pass `--resume`; add `restart` verb dispatch). Create: `bin/heimdall-restart` (verbs `status`, `defer [minutes]`, `now`, `off`, `on`: writes only files under `$HMD_HOME/restart/` and `$HMD_HOME/no-auto-restart`), `test/launcher-supervised.test.sh`.
- **Skills:** `superpowers:test-driven-development`.
- **Acceptance criteria:**
  - [ ] `bash -n bin/heimdall && bash -n bin/heimdall-restart`
  - [ ] `grep -c 'hmd_supervised_claude' bin/heimdall | grep -qx 2` (exactly the two call sites)
  - [ ] `! sed -n '/^# --team N/,/^# --help/p' bin/heimdall | grep -q hmd_supervised_claude` (team path untouched)
  - [ ] `bash test/launcher-supervised.test.sh` exits 0 and prints `interactive: supervised`, `resume: supervised`, `print-mode: unsupervised`, `non-tty: unsupervised`, `team-pane-noop`, `non-claude-noop`, `exit-status: claude's rc preserved`, `no code after supervised call`
  - [ ] `grep -q "_heimdall_launch_cleanup" bin/heimdall` exits 0 (trap body kept; neighbouring suites such as `heimdall-unknown-command` are the final sweep's job, not run here)
- **Verify:** `bash test/launcher-supervised.test.sh`
- **Done when:** a real `hmd` launch with `HMD_CLAUDE_BIN`/PATH pointing at the fake supervises and relaunches; every unsupervised path is byte-identical to before.
- **Risks:** attach agent conflict (section 6) and trap/exit-status invariant of `bin/heimdall:3613-3633` (test asserts the status case).

### Wave 4 (1 task + one review)

#### Task W4-e2e
- **Wave:** 4. **Dependencies:** W3-launcher. **Agent:** `hmd:coder`, then `hmd:reviewer` (`opus` + `high`) one round on the whole diff. **Model + effort:** `sonnet` + `default`.
- **Read first:** this plan section 8, `test/fixtures/fake-claude/*`, `bin/lib/hmd_supervise.sh`, `bin/heimdall-restart-gate`.
- **Files:** Create: `test/seamless-restart-e2e.test.sh`, `docs/seamless-restart.md`. Modify: `skills/heimdall/references/definition-of-done.md` ONLY IF it lists user-journey scenarios per feature (read first; skip the edit otherwise).
- **Spec:** the e2e drives the REAL `bin/heimdall` with `PATH` first-entry = a temp dir whose `claude` is the fake, real hook script, real gate, a temp HOME; implements the 50-seed interleaving sweep, invariants I1-I6 and the mutant matrix M1-M10 of section 8 (from `test/fixtures/fake-claude/mutants.list`, authored in W1); the user-journey scenario "operator working, update lands, goes idle, comes back to the same conversation with one line printed" is the first case. `docs/seamless-restart.md` documents opt-out, `hmd restart` verbs, what resume does not restore (from W0 Q3), and the safe point table.
- **Acceptance criteria:**
  - [ ] `bash test/seamless-restart-e2e.test.sh` exits 0 and prints `seeds: 50/50 invariants hold` and `mutants: 10/10 red` and `journey: resumed same session id`
  - [ ] `grep -q 'HMD_AUTO_RESTART' docs/seamless-restart.md`
  - [ ] `grep -q 'seamless' docs/seamless-restart.md`
- **Oracle gate:** domain none in registry (flagged, section 8); `gate_type` trace-diff + seeded property sweep; command `bash test/seamless-restart-e2e.test.sh`; `independent: true`, reference = W1-oracle author (separate agent, Wave 1, disjoint files from W2/W3 impl).
- **Verify:** `bash test/seamless-restart-e2e.test.sh`
- **Done when:** golden green, 50/50 seeds clean, 10/10 mutants red.
- **Risks:** flaky timing under machine load -> the harness uses a virtual clock (`HMD_RESTART_NOW`, fake `statusUpdatedAt`) and counts steps not seconds; one solo re-run allowed.

## 10. Red flags

- Spike W0 may invalidate the SIGTERM mechanism: that is why Waves 2-3 are gated on its DECISION line, not on schedule.
- Acceptance criterion in W3 mentions a negated test run; it is a grep, not a suite run, on purpose.
- No registry oracle: flagged, compensated by independent-author fixtures plus mutants; a reviewer should decide whether to register `launcher-supervise`.
- Plan verification via `hmd:reviewer` was NOT run by the architect that wrote this (the spawn tool was unavailable in this context); run it before dispatch.
- No waves.json: 10 tasks, no wave over 10 (the emit rule triggers at 11+).

## 11. Final step (recommendation, not an action)

On the frozen tree after Wave 4 and the single review round, immediately before the merge, RECOMMEND the one full sweep: `bash test/run-all.sh` (in heimdall's own repo; cache-aware, ~48 min last measured, ~568 suites) and say why: the plan edits `bin/heimdall` (hub file read by many suites), `hooks/hooks.json`, `hooks/hooks.metadata.json` and `bin/heimdall-cc-selfheal`. The developer decides; no agent starts it unasked. The push gate needs the green receipt that run leaves.

## OUT OF SCOPE

- Restarting `--team` tmux panes, Cursor/codex/gemini/aider sessions, Windows.
- `claude --bg` / daemon-hosted session restarts and the attach-into-`--resume` work (owned by another agent).
- Changing how the hmd installer applies updates or how Claude Code updates itself; no new update source.
- Typing slash commands into a session (`/exit`, `/reload-plugins`, `/compact`) except the Q4-(a) tmux fallback if the operator picks it.
- Preserving session-only state that `--resume` does not restore (reported, not fixed).
- A statusline indicator for "restart pending"; telemetry of restarts; a registry oracle domain for launcher supervision.
- Performance tuning, docs beyond `docs/seamless-restart.md`, migration of unrelated launcher code, deployment/rollout.
