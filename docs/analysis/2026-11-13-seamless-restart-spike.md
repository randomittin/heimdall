# Seamless restart after updates: Wave 0 spike memo

Date 2026-11-13. Plan: `docs/superpowers/plans/2026-11-13-seamless-update-restart.md`, Task W0-spike (read: its Wave 0 section, the safe-point table G1-G7, the risk rows that name W0). Harness, kept as evidence: `test/fixtures/fake-claude/spike-pty.sh` (`W0_DIR=<scratch dir> bash test/fixtures/fake-claude/spike-pty.sh all`). Every number below comes from a run of it; raw per-run files lived in the scratch dir and are quoted here, not committed.

## Verdicts (one line per question; the greppable block)

Q1-SIGTERM-GRACEFUL: yes. In both TUIs SIGTERM runs claude's own shutdown: exit code 143 (a normal exit, not death by signal) 0.87-2.59 s after the signal, SessionEnd hook ran (reason "other"), transcript is valid JSONL with no truncated line and it GREW during shutdown (27->39, 37->39, 37->38 entries: the assistant reply and cost-state records are flushed by the signal path), sessions file deleted, terminal restored by claude itself. SIGHUP (exit 129, 1.52 s) and SIGINT (exit 0, 1.23 s) end the same way; `/exit` control: exit 0, reason prompt_input_exit. UNMEASURED: SIGTERM in the middle of a streaming turn (the gate never sends it there), SIGKILL.
Q2-TTY-MODES-LEFT: none. After SIGTERM, SIGHUP, SIGINT and `/exit`, in the fullscreen and the default TUI, no DEC private mode is left on (running: fullscreen 1000 1002 1003 1004 1006 1049 2004 2031, default 1004 2004 2031; all reset), cursor visible, kitty keyboard depth 0, modifyOtherKeys reset (`CSI > 4 m`); claude emits every reset itself and prints `Resume this session with: claude --model <m> --resume <id>`. termios after exit is cooked (`icanon isig iexten echo`), and `stty -g` is byte-identical across all 7 runs, but not identical to the fresh pty's pre-launch value (iflag 2800->2b02, lflag 43->5cb). Same final state under real `script -q`. So section 5's reset list is EMPTY. UNMEASURED: a kitty-keyboard-capable terminal (this pty answers DA1 only, like Apple_Terminal), a real Terminal.app window.
Q3-RESUME-RESTORES: conversation yes (all earlier turns are shown); last-used model yes (picker check mark on Haiku; an in-session `/model sonnet` that no turn had used yet was NOT restored); permission mode yes (a bare `--resume` of a `--permission-mode manual` session shows "manual mode on", a fresh session shows "auto mode on"); appended system prompt yes without re-passing (post-resume requests reuse api-request shapeHash 3c0e43ee61, whose recorded shape contains the marker instruction; the reply also ended ZEBRA-7, which alone is confounded by history); effort NO (started `--effort low`, resumed shows `medium`, the default); unsubmitted draft NO. UNMEASURED: session-only "allow for this session" permission grants (the Write went to the session scratchpad dir, which needs no permission, so the grant option was never offered), an in-session `/effort` switch (the slider dialog was cancelled), whether a flag re-passed on `--resume` overrides a restored appended system prompt.
Q4-STATUS-SIGNAL: `~/.claude/sessions/<pid>.json` is written by claude and deleted on graceful exit. Fields: pid, sessionId, cwd, startedAt, procStart, version, peerProtocol, peerFeatures[], kind ("interactive"), entrypoint ("cli"), pidDomain, asksForConvertedSkills, messagingSocketPath, name, nameSource, nameSince, status, updatedAt, statusUpdatedAt, waitingFor (only while waiting); no model field. status values observed: idle, busy, waiting (waitingFor "permission prompt" for a tool dialog, held 62 s until answered; "dialog open" for /effort and /model dialogs), shell. The first write (+0.8 s) has no status. The Stop hook runs while status is still busy (idle follows 0.1-1 s later); between back-to-back turns idle flashes for about 0.1 s. A `run_in_background` Bash job keeps status `shell` for its whole 30 s although Stop had fired; a background subagent keeps it busy/shell for its whole run: status is NOT idle in either case. Children of claude seen: `caffeinate -i -t 300` while busy, `/bin/zsh -c source ...` + the command for Bash jobs, hook runners (bash, perl), startup helpers (`ps aux | grep ...`, `gh auth token`) for under 1 s. UNMEASURED: `shell` for a user-typed `!cmd`, other waitingFor values.
Q5-TTY-ATIME: yes on macOS. atime of the pty slave moves to the keystroke time (0-50 ms later, nanosecond resolution) on every one of 8 keystrokes including 4 at 0.35 s spacing, and does NOT move on claude's own output (mtime does), on a resize redraw, or during 3 s idle. `stat -f %a` shows whole seconds, `%Fa` nanoseconds. UNMEASURED: Linux GNU `stat -c %X` (no Linux box), a real Terminal.app window (measured on a pty slave, same driver).
Q6-KEYSTROKES-REACH-CHILD: yes. With `claude ... &` then `wait` in a non-interactive bash, claude is in the foreground process group (pgid == tpgid) and still receives typed text (echoed in the TUI), Ctrl-C (first press shows "Press Ctrl-C again to exit") and a window resize (the redraw addresses row 30 of the new 30x100 size), although lsof shows its fd 0 is /dev/null (bash's default for async commands; claude must read the controlling terminal itself, inferred, the tty fd was not listed). With an explicit `<&0` fd 0 is the tty and the behaviour is identical. SIGINT sent to claude under the wrapper (`<&0` variant) ends it (the wrapper returned within 8 s) despite bash's ignore-SIGINT default for async children. UNMEASURED: two quick Ctrl-C exiting the child under the wrapper (test bug: second press came after the 2 s window), SIGINT for the plain `&` variant.
Q7-INSTALL-INPLACE: no. install.sh upgrades with `git fetch` + `git checkout --quiet FETCH_HEAD` (install.sh:1176-1177), installs fresh with `git clone` (1185-1192) and links the `hmd` entry with `rm -f` + `ln -s` (169-173). In a temp-repo experiment `git checkout` gave bin/heimdall a NEW inode (565434039 -> 565434393) and a running bash finished its old text cleanly (`V1-TAIL-AFTER-LOOP`, `V1-LAST-LINE`); the in-place `cp` control kept the inode and the running bash executed garbage (`line 3: byte: command not found`) before the v2 text; the write-temp-and-rename control gave a new inode and a clean finish. The hazard exists only for an in-place writer (cp, `>`), none is in install.sh; the planned mitigation stays as cheap insurance.
DECISION: proceed. SIGTERM to the launcher's own child is graceful and fully self-restoring (Q1, Q2), so the tmux `/exit` and notice-only fallbacks are not needed; `&` + `wait` keeps terminal input (Q6), so no foreground wrapper; status is not blind to background Bash or subagents (Q4) and G5 stays multi-signal anyway. Waves 2-3 may start, carrying the UNMEASURED register below as explicit W2/W4 checks.

## Decision table (the plan's three rows, evaluated)

| Plan condition | Evidence | Outcome |
|---|---|---|
| Q1 = no (SIGTERM unclean) -> apply the operator's Q4 option (tmux `/exit` / notice-only / pty owner) | Q1 = yes in 7/7 runs: flushed transcript, SessionEnd, termios and modes restored, exit <= 2.6 s | Not triggered. Keep SIGTERM; the Q4 operator question is moot |
| Q4 shows idle during background jobs -> G5 must rely on children/task files only | `shell` for the whole background Bash job; busy/shell for the whole background subagent | Not triggered. G5 stays as written (multi-signal); `status` is also a usable G4/G5 input |
| Q6 = no -> `wait`-less foreground child + signal-forwarding wrapper | keystrokes, Ctrl-C and resize all reach a `&` child (plain and `<&0`) | Not triggered. Keep `&` + `wait`; add `<&0` (see finding 1) |

## Method and environment

- Binary: real claude 2.1.323 (`~/.local/share/claude/versions/2.1.323`), macOS Darwin 27.0.0 arm64, TERM=xterm-256color, TERM_PROGRAM=Apple_Terminal (the operator's), 120x40 pty, haiku (`claude-haiku-5-5`) for every prompt, no model call on the default model.
- Pty: allocated by the harness with Python `os.openpty()` (the primitive `script(1)` and `expect(1)` use) instead of `script -q /dev/null`, because it owns the master: keystrokes, window size, signals, byte capture and tty stat. One run went through real `script -q` as a cross-check (Q2). The pty answers DA1 only (as Apple_Terminal does); claude's `CSI ? u` (kitty), `CSI > 0 q` (XTVERSION) and OSC 7501 queries got no answer.
- Isolation: scratch HOME (trimmed copy of `~/.claude.json`: onboarding done, only the scratch cwd trusted, `mcpServers` emptied; its own `settings.json` with 8 evidence hooks SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop, SessionEnd, `Bash(sleep *)` allowed, `tui: fullscreen` for the operator-mode runs), scratch cwd and TMPDIR, whitelisted env (no CLAUDE*/ANTHROPIC*/HMD* variables, no `ANTHROPIC_BASE_URL` proxy), `DISABLE_AUTOUPDATER=1`. Auth: `$HOME/Library/Keychains` linked to the real keychain directory so the binary's own `security` lookup finds its item; no credential was copied, read or printed. Without the link the session said "Not logged in".
- Safety: signals only to pids the harness forked (or a verified descendant); 18 throwaway sessions (probe 2, q5 1, q6 3, q1 7, q3 3, q4 1, script 1); at the end 0 processes carrying the harness environment were alive; the real `~/.claude/settings.json` was not touched (model key unchanged, mtime older than the first run). `/model x` "saved as your default" wrote to the scratch settings only.
- Limits: one machine, one terminal emulation, one claude version. Everything is a measurement of 2.1.323 and is undocumented behaviour; the plan's canary (W1) is the guard against drift.

## Evidence

### Q1 signals at turn end (fullscreen = `tui: fullscreen` + `CLAUDE_CODE_NO_FLICKER=1`, the operator's mode)

| run | TUI | how | status at signal | signal->exit | exit | SessionEnd reason | transcript entries before->after | modes left on |
|---|---|---|---|---|---|---|---|---|
| q1-term-race-fs | fullscreen | SIGTERM right after the Stop hook line | busy (Stop hook running) | 1.243 s | 143 | other | 27->39 | none |
| q1-term-settled-fs | fullscreen | SIGTERM 15 s after Stop | idle | 2.593 s | 143 | other | 37->39 | none |
| q1-hup-race-fs | fullscreen | SIGHUP right after Stop | busy | 1.521 s | 129 | other | 33->45 | none |
| q1-int-race-fs | fullscreen | SIGINT right after Stop | busy | 1.232 s | 0 | other | 26->39 | none |
| q1-exit-race-fs | fullscreen | `/exit` right after Stop | busy | 1.633 s | 0 | prompt_input_exit | 26->39 | none |
| q1-term-settled-def | default | SIGTERM 15 s after Stop | idle | 0.869 s | 143 | other | 37->38 | none |
| q1-exit-race-def | default | `/exit` right after Stop | busy | 1.713 s | 0 | prompt_input_exit | 27->42 | none |

Every transcript: 0 unparsable lines, ends with a newline. In the race runs the assistant entry was absent at signal time (types: no `assistant`) and present after exit (`assistant_texts: ["PONG"]`, plus `system`, `cost-state`): the transcript is written lazily and the signal path flushes it. Sessions file after exit: absent in all 7. Exit codes are not signal deaths: `waitpid` reported `exit code 143/129/0`, so a launcher's `wait` sees 143 after TERM, 129 after HUP, 0 after INT.

Last bytes after SIGTERM (fullscreen, race), escapes shown as text:

```
...\x1b[?25h\x1b]0;PONG reply test\x07\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1004l\x1b[?1049l\x1b[>4m\x1b[>4m\x1b[?2031l\x1b[?2004l\x1b(B\x0f\x1b[?1016l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b7\x1b[r\x1b8 ... \x1b]0;\x07\x1b[2mResume this session with:\x1b[22m\r\n\x1b[2mclaude --model haiku --resume 75887adc-0e5f-4808-956a-94c22fcc49ab\x1b[22m
```

Hook order, settled SIGTERM run: `SessionStart +0.6 s, UserPromptSubmit +3.3 s, Stop +4.3 s, SessionEnd +21.5 s` (signal sent about +19.4 s, 15 s settle after Stop); the sessions file went `idle` -> `busy` (+3.3 s) -> `idle` (+4.4 s) -> ABSENT (+19.5 s).

### Q2 terminal state

Modes on while running, from the captured stream: fullscreen `?1000 ?1002 ?1003 ?1004 ?1006 ?1049 ?2004 ?2031` (cursor toggled; `?1016` appears only in the exit reset), default `?1004 ?2004 ?2031`. After exit: `dec_final_on: []`, `dec_default_on_now_off: []`, `kitty_keyboard_depth: 0`, `xterm_modifyOtherKeys_last_params: "4"` (that is the reset `CSI > 4 m`), `last_sgr_params: "22"`. The exit sequence is emitted twice (TUI teardown, then process exit). Under real `script -q <typescript> claude` plus SIGTERM to claude: master capture and `script`'s typescript analyse identically (1696 bytes each, `dec_final_on: []`), wrapper exit 143.

`stty -a` while running: `lflags: -icanon -isig -iexten -echo ...`, `iflags: -istrip -icrnl -inlcr -igncr -ixon -ixoff ixany imaxbel -iutf8`. After exit (all 7 runs): `lflags: icanon isig iexten echo echoe -echok echoke -echonl echoctl`, `iflags: -istrip icrnl -inlcr -igncr ixon -ixoff ixany imaxbel -iutf8`. `stty -g` after, identical in all 7:

```
gfmt1:cflag=4b00:iflag=2b02:lflag=5cb:oflag=3:discard=f:dsusp=19:eof=4:eol=ff:eol2=ff:erase=7f:intr=3:kill=15:lnext=16:min=1:quit=1c:reprint=12:start=11:status=14:stop=13:susp=1a:time=0:werase=17:ispeed=9600:ospeed=9600
```

Before launch (fresh pty): `gfmt1:cflag=4b00:iflag=2800:lflag=43:oflag=3:...`. Claude restores a sane cooked state, not the exact pre-launch bits (note `-iutf8` afterwards; Terminal.app's own tty normally has `iutf8`), so the launcher's own `stty "$saved"` is still the right restore.

### Q3 resume (session: `--session-id`, `--permission-mode manual`, `--effort low`, `--append-system-prompt-file` with "Append the exact token ZEBRA-7 ..."; two haiku turns, `/model sonnet`, `/effort`, a typed draft `UNSUBMITTED-DRAFT-123`, then SIGTERM; resumed with a bare `claude --resume <id>`)

```
header after resume:   Claude Code v2.1.323   Haiku 5.5 · Claude Team
replayed conversation: ❯ Reply with the single word PONG.   ⏺ PONG ZEBRA-7
                       ❯ Use the Write tool to create the file w0-edit-1.txt ...  ⏺ DONE1 ZEBRA-7
                       ❯ /model sonnet   ⎿ Set model to Sonnet 5.5 and saved as your default for new sessions
footer after resume:   ⏸ manual mode on · ? for shortcuts · ← for agents      (fresh session: ⏵⏵ auto mode on (shift+tab to cycle))
/model picker:         5.  Haiku 5.5 ✔ ...      Esc -> "Kept model as Haiku 5.5"   (default row: Opus 5.5)
effort:                before kill "○ low · /effort"; after resume "◐ medium · /effort"; fresh default "◐ medium · /effort"
draft:                 visible before the kill; absent after resume (draft_restored false)
```

System prompt: the transcript holds ONE `api-request-shape` (line 17, hash 3c0e43ee61, contains the marker instruction and the tools). Every `repl_main_thread` request, including the ones after the resume (lines 87-102, first request `base=None`), carries `shapeHash=3c0e43ee61`; no second shape was recorded. The resume command line had no `--append-system-prompt-file`. Permission dialog: not reached (`Made 1 scratchpad edit`: the model wrote into the per-session scratchpad dir, `edit1_file_exists: false` in the cwd), so the "allow all edits during this session" grant was never created; the q4 Write did raise a dialog (see Q4) but was answered with Esc. Also seen: `/effort high` opens the slider dialog (it is not applied by typing the argument), each `/effort` Esc is recorded as a `Cancelled` local command in the transcript.

### Q4 sessions file and status timeline (one session, `--permission-mode manual`, haiku; t = seconds from spawn)

```
+0.5  status=idle             (first write at +0.8 s had no status/updatedAt/statusUpdatedAt)
+3.1  status=busy             prompt "Reply with exactly: PONG"          hooks: UserPromptSubmit +3.1, Stop +4.0
+4.1  status=idle             (0.1 s after the Stop hook line)
+4.7  status=busy             prompt "Use the Write tool to create w0-q4.txt ..."
+6.5  status=waiting waitingFor=permission prompt     hooks: PreToolUse +6.5, Notification +12.6
+68.9 status=idle             (held 62 s until the harness pressed Esc; the dialog regex missed it: ANSI-stripped text has no spaces)
+130.4 busy  prompt "Call the Bash tool with command 'sleep 30' and run_in_background ..."
+131.7 children: caffeinate -i -t 300, /bin/zsh -c source ..., sleep 30
+132.2 status=shell           (Stop hook +132.1; status stays shell for the whole 30 s job)
+161.4 status=busy -> +162.5 idle   (job finished, notification turn, then idle)
+170.0 busy  prompt "Call the Agent tool ... run_in_background true ..."   Stop +172.2, SubagentStop +173.6
+174.8 children: zsh -c source ..., sleep 25, caffeinate -i -t 300   (the subagent's Bash)
+176.3 status=shell / busy / shell ... no idle until +199.6   (busy never ended while the subagent ran)
+199.6 idle, +199.7 busy, +200.4 idle, +200.4 busy, +201.3 idle     (0.1 s idle flashes between notification turns)
+213.0 sessions file ABSENT, EXIT 0   (/exit)
```

All distinct status values: `busy, idle, shell, waiting`. Sessions file at idle (probe, fullscreen):

```
{"pid":70739,"sessionId":"8c038952-...","cwd":"<scratch cwd>","startedAt":1794556150519,"procStart":"Fri Nov 13 07:49:09 2026","version":"2.1.323","peerProtocol":1,"peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin","asksForConvertedSkills":null,"messagingSocketPath":"/tmp/cc-socks/70739.sock","name":"cwd-fa","nameSource":"derived","nameSince":1794556150519,"status":"idle","updatedAt":1794556150459,"statusUpdatedAt":1794556150459}
```

While a `/effort` dialog was open (probe, default TUI): `"status":"waiting",...,"waitingFor":"dialog open"` at +4.4 s. Startup child processes (first second): `(bash)`, `/bin/sh -c ps aux | grep -E "Visual Studio Code|Code Helper|Cursor Helper|Windsurf Helper|..."`, `ps aux`, `grep`, `gh auth token`, plus `<defunct>` zombies, gone by +1.3 s.

### Q5 tty atime (direct run, fullscreen; tty = pty slave; times in seconds)

| action | atime advanced | atime minus action time | mtime advanced | bytes claude wrote |
|---|---|---|---|---|
| 3 s idle, nothing sent | no | (5.9 s old) | no | 0 |
| keystroke `x` | yes | 0.000 | yes | 144 |
| keystroke backspace | yes | 0.005 | yes | 73 |
| rapid keystrokes 1-4, 0.35 s apart | yes, each | 0.005 / 0.004 / 0.004 / 0.002 | yes | 43 / 40 / 40 / 40 |
| keystroke Esc | yes | 0.050 | yes | 119 |
| resize 40x120 -> 30x100 (redraw, no input) | NO | (1.3 s old) | yes | 1286 |
| 3 s idle after resize | no | (3.3 s old) | no | 0 |

`stat -f '%a %Fa' /dev/ttys006` right after the keystrokes: `1794556362 1794556362.981443000`. The redraw after the resize addressed up to row 30 (`max_row_addressed: 30`), so SIGWINCH reached claude (same result as Q6).

### Q6 `claude &` + `wait` (`bash sup.sh claude --model haiku`, bash non-interactive, pgid == tpgid)

```
plain  (claude "$@" &):      lsof 0r CHR 3,2 /dev/null | 1u,2u /dev/ttys006      ps pid pgid tpgid stat: 32230 32224 32224 S+   (bash: 32224 32224 32224 Ss+)
fd0    (claude "$@" <&0 &):  lsof 0u,1u,2u /dev/ttys006                           ps: 58756 58755 58755 S+                     (bash: 58755 58755 58755 Ss+)
both:  keystrokes_echoed_in_tui true; Ctrl-C text: Press Ctrl-C again to exit; alive after first Ctrl-C true; resize redraw max_row_addressed 30 (1196 / 1186 bytes)
fd0-sigint: SIGINT to claude -> the wrapper returned within 8 s (its own exit status 0 is the trailing echo, not claude's); claude evidently replaces the inherited ignore with its own handler
```

The plain and fd0 runs ended by the harness killing their own process tree (exit 137 shown as SIGKILL): the planned "two quick Ctrl-C exit" step was a harness bug and is UNMEASURED.

### Q7 in-place rewrite (temp repo, `bin/heimdall` v1 loop script running under bash while v2 lands)

| update method | inode before -> after | running bash |
|---|---|---|
| `git fetch origin main` + `git checkout --quiet FETCH_HEAD` (install.sh) | 565434039 -> 565434393 (new) | finished v1 text: `v1 step 6`, `V1-TAIL-AFTER-LOOP`, `V1-LAST-LINE` |
| `cp` over in place (control) | 565434515 -> 565434515 (same) | `bin/heimdall: line 3: byte: command not found`, then `V2 only echo lines follow`, `V2-TAIL`, `V2-LAST-LINE` |
| write temp + `rename` over (control) | 565434758 -> 565434894 (new) | finished v1 text |

install.sh code read: upgrade `git -C "$PLUGIN_DIR" fetch --quiet origin "$REF"` and `git -C "$PLUGIN_DIR" checkout --quiet FETCH_HEAD` (1176-1177); fresh `git clone` (1185-1192, `rm -rf "$PLUGIN_DIR"` first on the fallback, 1187); `chmod +x "$PLUGIN_DIR/bin/"*` (1196, mode only); `link_entry` does `rm -f "$dst"` then `ln -s` (169-173), `cp` only as a last resort (178). `bin/heimdall-autoupdate:951` applies the verified install.sh with `setsid ... bash '$artifact'`. No in-place write to `bin/heimdall` exists on these paths.

## Findings that change the plan text (feed to W1-W4)

1. Section 2 step 1 / Q6: bash gives an async child `/dev/null` as stdin (lsof fd 0), claude still gets terminal input. Use `claude ... <&0 &`: measured identical, and keeps the child's stdin the tty as in a foreground launch.
2. Section 2 step 4 / 5: after TERM claude exits 143 within 2.6 s (the 20 s `HMD_RESTART_TERM_WAIT_S` has ample margin), deletes `~/.claude/sessions/<pid>.json` and fires SessionEnd with reason `other`; read `sessionId` before sending TERM (as the plan already does). The exit code is not a restart marker; `restarting.json` is.
3. Section 5: the observed reset list is empty, so `hmd_supervise.sh` emits no escape sequences after a graceful TERM; keep `stty "$saved"` (claude's restore is a sane cooked state, not the pre-launch bits).
4. Section 3 G3-G5 sources: `status` in {idle, busy, waiting(+waitingFor), shell}; require idle AND `now - statusUpdatedAt >= SETTLE` because idle flashes for 0.1 s between turns and the Stop hook runs while status is still busy; treat any unknown value or missing field as UNSAFE. G5 children allowlist must include `caffeinate -i -t 300` (child while busy), hook runners (bash/perl) and the sub-second startup helpers and zombies; real work shows as `/bin/zsh -c source ...` plus the command.
5. G6: atime works on macOS at nanosecond resolution; Linux unmeasured, so keep `signal-unreadable` -> UNSAFE when `stat` fails.
6. Section 6 risk row "session-only state": measured restored = conversation, last-used model, permission mode, appended system prompt; lost = effort, draft, a not-yet-used `/model` switch; unmeasured = "allow for this session" grants. The mitigation "re-pass `--model` read from the sessions file" is moot: that file has no model field and resume restores the last-used model.
7. Open for W2/W4: the plan re-execs the NEW launcher so the NEW preamble applies, but a bare resume restores the OLD appended system prompt. Whether a re-passed `--append-system-prompt-file` wins is UNMEASURED; test it before relying on new-preamble-on-resume.

## UNMEASURED register

- Q1: SIGTERM mid-turn; SIGKILL; claude 2.1.322 vs 2.1.323 behaviour.
- Q2: kitty-keyboard-capable terminals; a real Terminal.app window.
- Q3: session-only permission grants; in-session `/effort` switch; precedence of re-passed flags over restored state.
- Q4: `shell` for `!cmd`; waitingFor values beyond "permission prompt" and "dialog open".
- Q5: Linux GNU `stat -c %X`; real Terminal.app.
- Q6: two quick Ctrl-C exit under the wrapper; SIGINT for plain `&`. `spike-pty.sh` q6 now lists plain / plain-sigint / fd0 with a quick double Ctrl-C and a tty-fd listing; those edits were made after the q6 run quoted here (which used plain / fd0 / fd0-sigint) and have not been run.
