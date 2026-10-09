# Changelog

All notable changes to Heimdall (formerly superx) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Changelog status

This file was not maintained between the last curated entry below (from when the
project was still called superx) and the current plugin version. The version of
record is `.claude-plugin/plugin.json`, mirrored into `VERSION` and the README badge
by `bin/heimdall-render-version` -- it is deliberately not repeated here, because a
hand-typed version drifts on the next bump (test/version-pin-conformance.test.sh
exists for exactly that reason). No release notes for the gap have been
reconstructed, deliberately: writing them after the fact would be invention. The
real history is in git:

- `git log --oneline <tag-of-the-last-curated-entry-below>..HEAD`
- `bin/generate-changelog` (renders from commits, never hand-typed)
- `hmd weekly-log` (drafts only)

## [Unreleased]

### Added
- **attach-v1** — the phone can attach a picture to a message (JPEG or PNG, at most 2 MiB, up to four a message): `attach-begin`, 256 KiB `attach-chunk`s and `attach-commit`, over the relay only. hmd checks the declared size and sha256 and the magic bytes, rewrites the file by a strict byte-level whitelist (no Exif, GPS, XMP, IPTC, comment or thumbnail; nothing it cannot parse is kept), stores it 0600 as `<repo>/.heimdall/app/attachments/<id>.jpg|png` (the 20 newest, none past 24 hours) and queues ONE inbox record naming its path, which the inbox delivery hands the session behind its provenance marker so Claude can `Read` it. Listed in the state frames' caps; the shipped app does not list it in its own resync, so hmd does not require that. `hmd app controls off` refuses it `controls-off`; `HMD_ATTACH=0` stops listing it and answers `not-implemented`. `bin/lib/companion_attach.py`, `test/companion-attach.test.sh`.

- **Code-only pairing** — typing the session code on a phone signed in to the same GitHub account as the laptop's `gh` pairs at once: no 6-digit number on either side, no y/N, also with `hmd app connect --bg` and with no terminal. The claim must name this laptop's own GitHub login (otherwise it is refused and nothing is revealed), no SAS is computed, shown or logged, and past that the relay is trusted to deliver the right keys. `hmd app connect --confirm` restores the compare (it needs a terminal; exit 64 without one or with `--bg`); `--no-confirm` is now the default and stays accepted. The exit-64 `--bg` refusal and the "no terminal to confirm" drop are gone.
- **One session code, always available** — the statusline, `hmd ui`'s `/api/state`, `bin/lib/hmd_app_code.py` and `hmd app` derive the code through one function (`resolve_session_code`), fed by the live session the SessionStart hook records in `.heimdall/app/session.json`. The code is now keyed by a per-machine random seed (`$HEIMDALL_HOME/session-code.key`, 0600), so it cannot be computed from a repo path or a session id. `hmd app pair-window --session SID` (run by the SessionStart/SessionEnd hooks `pair-window-start` / `pair-window-stop`) keeps that code registered with the relay for the whole session, with no terminal; `hmd hooks disable pair-window-start` opts out, `HMD_PAIR_WINDOW=0` turns it off. A pairing leaves a notice in the Claude session's inbox and a `📱 <device> paired via code` note on the statusline. Session and pairing state is written and read without following links (`bin/lib/hmd_private_state.py`).
- **One code per repo, and a pair window that outlives any one session** — the code every surface shows is now the code of the REPO (per-machine seed `$HEIMDALL_HOME/session-code.key` + the repo's real path), not of a Claude Code session id: the statusline, `hmd ui`'s `/api/state`, `bin/lib/hmd_app_code.py`, `hmd app connect` and the pair window print the same five characters in every session, with or without a session record (the statusline keys on `workspace.project_dir`, so a `cd` into a subdirectory does not change it; a render still never creates the seed). The pair window is the repo's too (`.heimdall/app/pair-window.json`; sessions are recorded one file each under `.heimdall/app/sessions/`): every SessionStart (start, resume, /clear, compact) opens it if it is not open, a session ending closes it only when no other live session of the repo and no running `hmd app connect` client needs it, a Claude killed without a SessionEnd ends it, and the idle stop (`HMD_PAIR_WINDOW_IDLE_H`) counts activity across all the repo's sessions. The relay keeps a registration 360 s, so the window renews about every 350 s (`HMD_PAIR_WINDOW_RENEW_MIN_S` floor 300 s, `HMD_PAIR_WINDOW_RENEW_LEAD_S` 10 s ahead) and the code stays claimable; `hmd app connect` no longer says "Valid for 10 min".

### Changed
- **An unpaired `hmd app connect` keeps its code claimable** — `hmd app connect --bg` with no phone paired ended after about 12 minutes and its session code then answered 404: the relay client was launched with its defaults (renew 1.5 s after each lapse, a fixed 10-minute cap on offering the code), so the third renewal was refused (`code_window_closed reason=expired`), the last session lapsed unpaired and the relay's purge (`session_ended pairing-expired`) ended a client with no window open. Only the pair window's supervisor had the 300 s floor, 10 s lead and 24 h cap. `connect` now launches its client with the same schedule (code renewed about every 350 s, before the relay's 360 s lapse), the cap is `HMD_PAIR_WINDOW_IDLE_H` (default 4 h) instead of 10 minutes, and a renewal the relay cannot take at the moment (unreachable, 429, 5xx, a refused `/pair/init`) is retried 30 s on (`HMD_RELAY_CODE_RENEW_RETRY_S`) instead of closing the window for good. Tests: `test/app-pair-confirm.test.sh` (U1–U3).
- **The pair window sends your GitHub token far less often** — a window with no terminal re-registered its code with the relay (the laptop's `gh` token is in that request) each time the relay's 60 s registration lapsed: about once a minute for the whole life of every session. It now registers no more often than every 5 minutes (`HMD_PAIR_WINDOW_RENEW_MIN_S`), ahead of the lapse when the relay keeps a registration longer than that, and stops for good after 4 hours (`HMD_PAIR_WINDOW_IDLE_H`, `0` = never) with no phone paired and no activity in the session (the transcript the SessionStart hook hands it); a new session or `hmd app connect` opens it again. Against the relay's 60 s the code is claimable for the minute after each registration and not in between; `HMD_PAIR_WINDOW_RENEW_MIN_S=30` keeps it claimable nearly always at the cost of the token going out about every 50 s. `hmd app connect` still renews every minute while it runs. The token still travels only on a pipe.
- **`/level` renamed to `/autonomy`** — the command that controls how much the agent does before asking is now `/hmd:autonomy` (with `/hmd:autonomy +` / `-` to cycle and `/hmd:autonomy <1|2|3>` to set). "Autonomy" names what it actually controls. Levels, semantics, and the on-disk config key (`.project.autonomy_level`) are unchanged — no existing user's saved setting resets on upgrade.

### Deprecated
- **`/hmd:level`** is kept as a deprecated alias for one release. It still works and prints a one-line "'/hmd:level' is now '/hmd:autonomy'" notice. It will be removed a couple of releases later.

## [2.4.4] - 2026-10-06 <!-- HEIMDALL:PIN:FROZEN -->

The companion-app release. hmd can now publish a live, end-to-end-encrypted view of a running session to the phone app through a hosted relay, take a short list of safe remote actions from it, and issue signed receipts for what its gates did.

### Added
- **Pair by session code** — `hmd app connect` defaults to the hosted relay and pairs by the 5-character session code the statusline shows. A bind by code reveals hmd's key in a plaintext `key_reveal`, seals nothing until the laptop approves the SAS check, and revokes and renews the window on reject, timeout or closed input. A revealed key is burned after an unapproved bind, `--code` needs https or loopback, and an identity can be revoked.
- **controls-v1** — the phone can drive an allowlisted set of controls: `hmd app controls on|off|status`, `POST /api/control`, an interrupt (stop) hook, remote toggles from the hooks registry, and fallback mode over every `heimdall-fallback` state (confirmation required for all but `off`).
- **view-v1** — the phone can ask for a sealed diff of one repo-relative path (worktree, staged or head; an untracked file shown whole). Path policy refuses `..`, absolute paths, deny-listed files and any symlink; secrets are masked per line; output is size-capped and rate-limited (20 requests per 60 s, `HMD_VIEW_RATE_LIMIT` to change it).
- **push-v1** — the phone registers its Expo push token (`register_push`, `unregister_push`, `app_state`; stored 0600 in `.heimdall/app/push.json`, at most 5, newest wins) and hmd's push sender notifies it on five triggers (question, approval, error, gate red, finished) with per-device policy, foreground suppression and rate caps. `HMD_PUSH=0` turns it off.
- **login-v1** — log Claude Code in from the phone: a PTY-driven `claude auth login`, the printed URL checked against an allowlist before it is published, the code typed from a sealed command and never logged, and the resulting account compared with the laptop's pin. Laptop switch: `hmd app remote-login on|off|status`.
- **Relay** — a Cloudflare Worker + Durable Object relay: E2E sealing (X25519, HKDF-SHA256, ChaCha20-Poly1305), zlib-compressed state frames, persisted client events, last-state replay to a newly accepted device socket, a `GET /health` probe answered by the Worker alone, and hmd's leg over a hibernatable WebSocket (stdlib RFC 6455 client in `bin/lib/hmd_relay_ws.py`). Deploys run the relay-ci gate, then a canary Worker that must report the deployed sha on `/health`, then production, and roll back if a check never passes.
- **`hmd attack`, `hmd prove`, `hmd receipt`** — `hmd attack <path>` runs the attack oracle battery behind a consent gate (non-TTY needs `--yes`) and prints a `runhmd.verdict/1` as JSON or a card; `hmd prove` answers "do all of this repo's gates pass, and was each shown to fail first?" (PROVEN or DENIED, never a pass on unreadable output); `hmd receipt verify|keygen|render|serve` handles Ed25519-signed `runhmd.receipt/1` receipts, and `attack --receipt` issues one. `npx runhmd <path>` runs `hmd attack <path>`, and `release/ship.sh` now publishes both npm wrappers.
- **`HMD_TEAM_NO_COMMIT=1`** (or the marker file `~/.heimdall/no-team-commit`) — `hmd team` keeps `.heimdall/team.json` current on disk but never stages or commits it, so a wip checkpoint's `git add -A` cannot sweep it into history.
- **`hmd ui`, `hmd app`, `hmd inbox`** — a local, token-gated companion web UI; `hmd app connect|status|disconnect|doctor` with Tailscale Funnel publishing; and an inbox that delivers phone messages into the session at tool boundaries and at the Stop hook (held up to 300 s while a companion is connected, released the moment the operator types).
- **Hooks registry** — every hook has an id and a fingerprint (`heimdall-hooks check` fails on drift), advisory hooks get a per-hook kill switch, and the gates that hold a line are locked and cannot be disabled. New guards: edits to linter, formatter and typechecker config are denied; a live tool-loop detector; `hmd settings-guard` for `ANTHROPIC_*` overrides persisted in Claude Code settings.
- **view-v1 transcript and pr** — besides diffs, the phone can ask for the last turns of the session or of one roster agent (`kind: transcript`, `tail` 1 to 500, default 200) and for the pull request of the checkout's current branch (`kind: pr`: number, title, state, draft flag, checks and reviews, read with `gh pr view`; refused `not-found` when `gh` is missing or describes none). A tool call is shown as its name, outcome and first output line, with no output at all when it names a deny-listed path; every string is secret-masked and size-capped before it is sealed, under the same rate limit. `reel` is still refused `not-implemented`.
- **CP2: safeguards for the phone's `expand` actions** — every control action carries a class tag (`read`, `safe-write`, `risky-write`, `expand`). The reserved `expand` actions `launch-session` and `pr-merge` are refused `not-allowed` unless their laptop switch is on (`hmd app remote-launch on|off|status`, `hmd app remote-merge on|off|status`; `on` needs a terminal, so an agent's shell, a script or the phone cannot turn it on) and the repo is on the allowlist (`hmd app launch-allow <repo-path> [--merge]`, `--remove <id>`, `--list`; the phone sees an id and a label, never a path, the path is re-resolved on every use, and only a repo added with `--merge` can be merged). The gate ships ahead of the actions: with everything on, both still answer `not-implemented`. Every expand attempt, refused ones included, is audited twice (`controls-audit.jsonl` and a `remote-action` line in `relay-events.jsonl`) and refused if it cannot be audited. `state.remote_actions` and `state.launch` are added to the state frame and `hmd ui` gets a Remote actions card.
- **`coop` fallback from the phone** — the controls-v1 `fallback-mode` control covers `coop` as well as `off`, `auto` and `switch`; `auto`, `switch` and `coop` need `confirm: true`. `coop` routes only the subagent roles on the laptop's allowlist and never the main agent, the phone moves the state word and nothing else, and an empty allowlist routes nothing: the allowlist (`heimdall-fallback coop add|remove`) is edited at the laptop alone.
- **Phone deny, on by default (A4)** — while a phone is paired through `hmd app connect`, the `phone-deny` PreToolUse hook (`bin/heimdall-phone-deny`) holds a risky shell command (a push, a delete, a publish or deploy, a network call that changes something, `sudo`, a system change) or a write outside the repo for up to `HMD_PHONE_DENY_WINDOW_S` seconds (default 10, 1 to 120) so the phone can `deny` it, or `stop` the turn, over the sealed relay. Deny-only: the phone can only reduce what runs, there is no allow, and approving from the phone stays unsupported. With no phone connected, no reply, an unattended session (`claude -p`, an hmd sub-session) or any error the hook does nothing and Claude Code's own permission flow decides as it always did; with no phone connected it costs one file test per tool call. The phone is shown the tool and a secret-scrubbed summary of at most 200 characters (in `approvals`, sealed end to end); a push says only that a tool is waiting, never the command. Switch it off with `HMD_PHONE_DENY=0` (also `false`, `no`, `off`) or `hmd hooks disable phone-deny`; unset, empty or any other value leaves it on.
- **Custom dashboards (dash-v1)** — the phone describes a panel in words and hmd on this laptop builds a read-only data panel for it over your own connectors; nothing runs until you confirm it here. Off by default behind `hmd app remote-dashboards on|off|status` (`on` needs a terminal). `hmd dash pending|ls|show|confirm|decline`, `hmd dash connector add|ls|rm` and `hmd dash run` drive it from the laptop (`confirm` and `connector add` need a terminal; the relay client starts the `run` producer loop itself while the switch is on). Read-only is enforced in layers: one checked `SELECT` per tile, a read-only sqlite or postgres session, credentials held only as an environment-variable name, and a tile runs only when its fingerprint matches the one you confirmed (an import is always confirmed again). The same tiles show read-only in `hmd ui`, which gained no new control and no new POST route.
- **Quick asks (ask-v1)** — a short question about the dashboard numbers, asked from the phone or its watch and answered in two lines from the tiles' current values. Read-only: no producer runs, nothing is queried and the coding agent is never reached. A model only picks which live number tile, and which of value, change or compare, the question is about, from tile ids, titles and intents, and is never shown their values; the answer text is composed in code, with `(stale)` added when a panel is past its refresh window. Off by default behind `hmd app remote-asks on|off|status` (needs remote dashboards on; `on` needs a terminal); limited to 6 asks a minute and 60 a day.
- **Tile alerts (dash-alert-v1, push-tile-alert-v1)** — the phone sets "tell me when this number crosses X" on a number tile (`lt`, `le`, `gt` or `ge`, with an optional hold time up to an hour); the laptop evaluates it after every producer run and pushes a new `tile_alert` kind on the false-to-true crossing only, at most 6 a day per alert and 10 alerts per project. A sleeping laptop evaluates nothing and the phone says so. Off by default behind `hmd app remote-alerts on|off|status` (needs remote dashboards on and a push registration; `on` needs a terminal).
- **Daily digest (push-digest-v1)** — the phone sets a time (`set-digest`: HH:MM plus its UTC offset, up to 3 tiles) and hmd sends one `digest` push a day on its first activity at or after that time: at most 4 lines, `Finished N · Verdicts N · Alerts N` and, only if you opted in, the listed tiles' values. A laptop asleep at that time sends it on its next activity, and a day with nothing to say is skipped. It rides the dashboards switch and needs a registered push device (`HMD_PUSH=0` refuses it).
- **Push-kind registry** — a push kind is added from its own module with `register_kind` instead of by editing the sender's tables. A registered kind is opt-in (never in a device's default set), is served from a 0600 spool by the process that holds the sender lock, and its capability is advertised to the phone only while it is registered. `tile_alert` and `digest` use it; the built-in kinds are unchanged.
- **`hmd modules supervise headroom install|uninstall|status`** — opt-in launchd supervision (macOS) for the local Headroom proxy: it writes `~/Library/LaunchAgents/dev.runheimdall.headroom.plist` with `KeepAlive` and a 5 s `ThrottleInterval`, and checks the plist with `plutil -lint` before it can replace anything. The agent is written but not loaded while something already answers on the proxy port, so it never starts a second proxy over a live one. Nothing installs it unless you ask, and `hmd modules remove headroom` removes it with the module.
- **Hosted receipts Worker (not deployed)** — `receipts-worker/` is a Cloudflare Worker for hosting `runhmd.receipt/1` receipts: it verifies a posted receipt, stores it, and serves a page and a card for it, with rate limiting and throttling. Cross-language test vectors replay the same receipts through the Python signer and the Worker, and a CI workflow runs typecheck, vitest and the Python contract replay on pull requests that touch it. Nothing is deployed: its README lists the operator steps and states that none has been run.
- **`hmd demo --offline [--json]`** — an agent writes a bug, `hmd attack` DENIES it, the fix diff is shown and the fixed code is PROVEN, all on the real attack engine over a bundled `buggy-webhook` and `clean-sample` pair, needing no network and scaffolding nothing; `--json` prints `runhmd.demo/1`. It is never scripted: a buggy fixture the engine does not DENY, a missing fixture or an engine fault exits 5.
- **Zero-footprint `runhmd`** — `npx runhmd attack` and `demo --offline` run with `HOME`, `TMPDIR` and the overrides that bypass `HOME` (`HEIMDALL_HOME`, `CLAUDE_CONFIG_DIR`, `HEIMDALL_LAUNCH_AGENTS_DIR`, `HEIMDALL_TEAM_DIR`) moved into one temp directory that is removed on every exit path; if the pinned installer is needed it installs there, with the LaunchAgent schedule and Python bytecode off. `test/zero-footprint.test.sh` checks that the home, the repo and the install are untouched and that no network connection is made (under a macOS sandbox that kills any socket or DNS call).
- **Adapter contract and `hmd attack --diff`** — `docs/ADAPTERS.md` defines `runhmd.adapter/1` (how a source of agent work becomes a task, events and a claim, with an error taxonomy and numbered rules), and `python3 -m adapters.conformance --adapter <name>` is its executable form, judging each rule from the contract without importing any adapter. The first adapter, `adapters/gitdiff.py`, claims a patch, a patch file or a head ref; `hmd attack --diff <patch-file | BASE..HEAD | BASE...HEAD | ->` applies that change to its base in a private copy of the repo and attacks the copy (`-` reads the patch from stdin and needs `--yes`). The verdict records `target.kind` `diff` and a repro command that carries `--diff`. Claude, Codex and Gemini adapters are a later wave.
- **`hmd metrics [--json] [--evidence]` and `hmd weekly-review --week N [--json]`** — `hmd metrics` prints the eight launch numbers (false-green rate, catch rate, denial precision, real bugs caught, dollars per proven PR and per real bug, active developers, weekly active partner teams) from local data only: a number is `null` (a count 0) when its source is absent, never estimated, and with `--json` the `--evidence` flag adds the counts each one came from. `hmd weekly-review` prints the weekly review template with its Numbers block filled from the same data; the two lines with no local source stay blank for a person.
- **Release manifest** — `release/sync-release.sh` writes `release-manifest.json` (`tag`, `install_sha256`, `install_url`, `minisig_url`) into the ignored `.heimdall/release/` directory, and `release/ship.sh` attaches it to the GitHub Release next to `install.sh.minisig` (it warns when the file is missing and fails when the upload or its readback fails).

### Changed
- **Agents prepare releases and deploys, they do not run them** — the maintainer guide, the incident-responder agent and the maintain-cycle summary in `agents/heimdall.md` no longer tell an agent to tag, release or deploy: it prepares the branch, PR, changelog and the exact command, then stops, and the operator runs it. `test/no-auto-merge.test.sh` enforces this, and its self-test plants the old wording back and requires red.
- **README, NAMING.md, PARKED.md** — the README is cut to under 150 lines, with the install disclosure in `docs/INSTALL.md` and the architecture and capability detail in `docs/ARCHITECTURE.md`. `NAMING.md` is the canonical list of product, command and engine names (`test/naming.test.sh` checks every `hmd <sub>` and `bin/<file>` it names against the code), and `PARKED.md` lists what is deliberately not being built now.
- **shellcheck** — 38 shell scripts now pass shellcheck at its default severity with zero findings: `bin/heimdall`, `bin/heimdall-app`, `bin/heimdall-wrap`, `bin/heimdall-demo`, `bin/heimdall-dash`, `bin/heimdall-wip-commit`, `bin/lib/hmd-headroom-chain.sh`, `release/ship.sh`, `test/run-all.sh` and 29 test suites. The other shell scripts changed in this release have not had that pass.
- **Stop-lint gate scoped to warnings** — `bin/heimdall-stop-lint` ran `shellcheck -f gcc` at shellcheck's default severity, so info and style notes (quoting, `sed` versus parameter expansion) counted as findings and set `lint_clean` false, a bar stricter than the gate's own definition, "Lint clean (zero warnings)". It now runs `shellcheck -S warning`: a file with only info or style notes is clean, a file with a warning is not. `HMD_STOP_LINT_SEVERITY=error|warning|info|style` moves the bar (`info` and `style` opt in to the stricter runs; an unknown value falls back to `warning` with one stderr line) and the receipt records it as `lint_last_run.shellcheck_severity`. `bash -n` and the Python `ast` check are unchanged. Cleaning up the existing info and style notes is deferred to 2.4.5.

### Fixed
- **ENOSPC recovery** — the relay client no longer goes silent after the disk fills. Its diagnostics wrote to the full disk and raised out of the loops that report errors, ending the poller thread for good. A failing log sink now never raises and is never switched off: the outage is reported once when it starts and once on recovery, and sending resumes when space returns.
- `hmd <typo>` exits 2 with a did-you-mean suggestion instead of launching an autonomous agent on a lone unknown word.
- Relay hardening from the protocol audit: the session key is latched at the first device bind, the device sequence never advances on a decrypt failure, and stream reads are bounded per line and per stream.
- **Headroom proxy fail-safe** — the loopback proxy on `127.0.0.1:8787` exited on a signal, nothing restarted it for 16 minutes, and every session pinned to it failed with `ECONNREFUSED`. Launch now routes or goes direct from a 1-second liveness probe (dead, silent or answering) instead of trusting a stale pin: a hung listener is declined in about a second, a declined launch drops an inherited `ANTHROPIC_BASE_URL` only when it is hmd's own loopback URL (an operator's own URL is never touched) and says so on one stderr line, and an unsupervised proxy leads its own process group so one terminal's Ctrl-C cannot take the shared proxy down. Only a plain session may go direct, with a stderr warning: a judge or fallback launch (`HMD_JUDGMENT` set, or `HMD_HEADROOM_REQUIRED=1`) whose proxy is wanted but down now exits 3 before any tool starts, naming the process that holds the port.
- **Relay status writes no longer race** — the relay client staged every write of its status file in one per-process temp file while its state loop, stream thread and connect threads wrote concurrently, which raised spurious `status write failed` events and could publish a torn or empty `relay.json`. Each write now stages in its own temp file under a status lock, and the other writers that run on threads (the controls stop marker, the Claude Code login config, the remote switches, the control-plane local backend) got the same fix.
- **Inbox lost-message race** — `hmd inbox` delivery's inline pop renamed the inbox file away even when it was empty, so a writer that took no lock and was descheduled between creating the file and writing to it landed its line in the file that had just been moved, and the message was in neither the inbox nor the archive. An empty inbox is now left in place, as the python pop already did; `test/heimdall-inbox-lockless-writer.test.sh` holds the write a full second after the create to make the case deterministic.
- **`hmd ui` listen backlog** — the server inherited the default listen backlog of 5, so a burst of simultaneous event-stream connections could be refused at the TCP layer before the connection cap (a 503 with `Retry-After`) ever answered. The backlog is now sized to the connection cap.

### Security
- Audit pass over `hmd ui`, `hmd app` and the inbox: public-mode redaction of every string leaf, connection caps and a header timeout, per-IP auth backoff, the Funnel token kept off argv and logs, validated DNS names, no `eval` in the install path, and 0700/0600 permissions on inbox files.
- gitleaks now flags Stripe-shaped tokens regardless of entropy.

### Performance
- State is sent on change instead of on a poll, and `/api/state` is served from the SSE snapshot cache (1.5-3 s per poll down to tens of milliseconds). The chat publisher reads only the appended transcript bytes, and a statusline render launches python 2 times instead of 9-11.

## [1.1.0] - 2026-04-19

superx can now run **10 agents in parallel** instead of 3 — background agents bypass Claude Code's per-turn limit, so a 10-task wave all runs simultaneously.

superx can now **route tasks to the right model automatically** — lint goes to Haiku (cheap + fast), docs go to Sonnet, and all code goes to Opus at high effort. If a task fails on a cheaper model, superx can now **auto-escalate** to the next tier (Haiku → Sonnet → Opus) instead of just failing.

superx can now **skip the LLM entirely** for deterministic operations — format, lint-fix, sort imports, rename files. These run as direct bash commands. Zero tokens spent.

superx can now **detect stalled agents** and nudge them — if an agent goes silent for 60 seconds, it gets a continuation prompt. And agents can now **never claim they're done** until acceptance criteria actually pass ("close enough" is blocked).

superx can now **verify claims against reality** — the verifier factchecks actual files on disk vs what the agent said it created. If a task claims "Created src/api.ts" but the file doesn't exist, it fails. Each task gets a **truth score (0.0-1.0)** and the phase fails if the average drops below 0.8.

superx can now **resolve conflicts between parallel agents** — when 10 agents produce competing changes, the version that passes more acceptance criteria wins (Byzantine consensus).

superx can now **switch governance modes** — Hierarchical (default, top-down control), Democratic (spawn competing proposals, pick the best), or Emergency (skip planning, incident-responder takes over, fix first).

superx can now **learn from your project** — after complex tasks, it extracts reusable patterns to `.planning/skills/` (trigger + steps + why). On future tasks, it **searches past patterns first** and applies proven solutions. Patterns with < 50% success rate get archived automatically.

superx can now **optimize its own cost** — after every 10 tasks, it analyzes which model tier succeeds for which task types and adjusts defaults. If Haiku always fails on your React components but works for your Python scripts, it learns that.

superx can now **spawn tmux worker teams** — `superx --team 5 "task"` launches 5 real parallel Claude instances in tmux panes, bypassing all API concurrency limits.

superx can now **detect magic keywords** in your prompts — "ultrawork" triggers maximum parallelism, "quick" skips planning, "secure" runs security-first, "incident" activates emergency mode, "plan" stops before execution, "ship" does end-to-end delivery.

superx can now **show its status** in Claude Code's status bar — current phase, task progress, dispatch queue depth. All visible at a glance.

superx can now **steal work between waves** — if an agent finishes early, it grabs dependency-free tasks from the next wave instead of sitting idle.

superx can now **preview merges safely** — before committing parallel work, it runs `git merge-tree` to detect conflicts without mutating. No more blind merges.

superx can now **show you exactly what changed** on `--update` — commit messages, file diffs, insertion/deletion counts. And on every launch, it **checks for updates** (once per hour) and tells you if you're behind.

### New Agents
- **security-auditor** (Opus/max) — OWASP Top 10, dependency audit, secrets scan, auth/authz review
- **database-architect** (Opus/high) — schema design, migrations, query optimization, N+1 detection
- **incident-responder** (Opus/max) — triage → diagnose → mitigate → fix → blameless postmortem

### New CLI
- `superx --team N "task"` — tmux parallel workers
- `superx --uninstall` — with sad goodbye animation
- `superx --auto` — safer alternative to skip-permissions

### New Files
- `bin/lib/dispatch.sh` — file-based task queue (JSONL + directory locks, survives crashes)
- `hooks/statusline.sh` — HUD for Claude Code status bar
- `agents/security-auditor.md`, `agents/database-architect.md`, `agents/incident-responder.md`

### Companion Plugins
- **caveman** at ultra mode (~75% token savings)
- **superpowers** for brainstorming + debugging

### Inspired By
Cherry-picked 24 features from:
- [ruflo](https://github.com/ruvnet/ruflo) — model routing, work-stealing, SONA learning, Tier 0 routing, Byzantine consensus
- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) — idle nudging, sentinel gate, continuation enforcement, file-based dispatch, tmux teams, skill extraction, magic keywords, HUD statusline
- [wshobson/agents](https://github.com/wshobson/agents) — security-auditor, database-architect, incident-responder

---

## [1.0.0] - 2026-04-10

First marketplace-ready release. Pixel dashboard is feature-complete and the orchestration loop has been simplified to a clean single-phase state machine.

### Added
- **Pixel-art dashboard** (`ui/server.py` + `ui/static/`) — local Python HTTP+SSE server with a real-time isometric city map of your project, war room of agents, streaming logs panel, and timeline view of every decision.
- **Single-phase state machine** — `idle → running → awaiting_user_input → running → idle`. Replaces the old three-phase refining/planning/executing pipeline that was forcing approval gates whether you needed them or not.
- **Question-mark protocol** — every prompt sent to Claude is prefixed with an INPUT PROTOCOL instruction. Claude only stops to ask when it actually needs input; the dashboard detects the trailing `?` and opens an awaiting-input panel.
- **Awaiting-input panel** — orange-tinted panel showing the question, auto-detected option buttons (parses `(A)`, `(B)`, `(C)`, `(D)` patterns), yes/no detection for confirmation questions, and a free-form textarea + SEND button.
- **Conversation continuity** — user replies use `claude --resume <session_id>` so Claude has full prior turn in context. Session id captured from stream-json's `system / init` message.
- **Map features** — drag-to-pan, zoom +/-, day/dawn/dusk/night theme toggle, fullscreen mode, building hover tooltips, agent sprite animation over their working buildings, road/joint alignment, custom pixel cursor.
- **History drawer** — every session archived with a smart auto-generated title from the task prompt; rename, browse, or replay any past run. Hover any session card and click the pencil icon to rename inline.
- **Auto-checkpointing** — background `git add -A && git commit` every 5 file writes during long runs, plus a recovery checkpoint so a crash never loses work.
- **Resume bar** — restores the last interrupted task on server start, with a one-click RESUME button.
- **GitHub integration** — one-click commit + push from inside the dashboard with SSH remote auto-detection.
- **Token budgets** — set a budget per session and get warned at 80% via `superx-state set-budget`.
- **Image attachments** — drag-and-drop or paste images into the prompt; they're saved to a temp dir and Claude reads them via the Read tool.
- **Smart timeline grouping** — collapses repetitive tool calls from the same agent into a rolling window so the timeline stays readable on long runs.
- **Markdown rendering** with expand/collapse for long messages.
- **Day/night theming** for the entire dashboard, including the isometric city.
- **Terminal log dedup** via djb2 hash so re-posts from server reconnects don't double up.

### Changed
- Bumped to v1.0.0 with full marketplace metadata in `.claude-plugin/plugin.json` (homepage, repository, keywords, categories, engines).
- README rewritten with dashboard-first quick start, troubleshooting section, and architecture diagram.
- All multi-phase orchestration code (`start_planning`, `execute_approved_plan`, `revise_refinement`, `revise_plan`, `handle_approve`, `handle_revise`) removed in favor of the single-phase flow.
- `.gitignore` strengthened — explicitly excludes all runtime state files (`superx-state.json`, `superx-session.json`, `superx-history.json`, `superx-checkpoint.json`, `superx-github.json`, `superx-workspace/`) and user-generated docs.

### Fixed
- Approval UI no longer disappears after refining/planning completes (was a race between `prompt_refined` and `process exited` events).
- Session restore correctly shows awaiting-input state after a refresh (was tied to `pending_prompts` global which was only set during revise flow).
- SSE replay on reconnect — clients that connect after `awaiting_user_input` already fired now receive the event immediately so the panel opens correctly.
- Stale checkpoint resurrection prevented — `_auto_checkpoint_git` background thread no longer rewrites a cleared checkpoint after task completion.
- `start_claude` clears any leftover checkpoint before writing its own, so a new task never inherits state from a previous one.
- Translucent night-overlay box on the map fixed by moving the overlay outside the zoom transform.
- Road tile alignment with cumulative `(r+c)*4` y-shift correction so road segments and joints connect seamlessly.
- Building/filler/car positions use the same grid correction as roads for consistency.

## [0.2.0] - 2026-04-06

### Added
- Design agent (`agents/design.md`) for UI/UX work with design-for-ai skill integration.
- `/superx:maintain-check` command — runs one full maintenance cycle (scan → triage → fix → release).
- `/superx:level +/-` cycling — quick autonomy level switching without remembering numbers.
- Guided maintainer activation wizard — one-command setup for issue sources, frequency, Slack notifications.
- Plugin marketplace authenticity checking (was stubbed, now validates registry + manifest + GitHub signals).
- Slack skill integration in orchestrator for team communication.
- `.gitignore` for clean repo hygiene.
- Development setup and local testing instructions in README.
- Test framework auto-detection in test-runner agent (jest, pytest, cargo, go, make).
- Dependency validation in conflict-log script.

### Changed
- `/superx:maintain` upgraded from simple toggle to guided setup wizard with first-check-on-activation.
- Maintainer mode now supports configurable issue sources (GitHub, logs, Sentry/Elastic).
- Resolved all 4 open design questions in spec (skill detection, state sync, cron, keybindings).
- Updated LICENSE copyright holder.

### Fixed
- SKILL.md spec paths now use relative paths from plugin root.
- detect-skills now has --help/usage documentation.

## [0.1.0] - 2026-04-06

### Added
- Initial plugin scaffold with `.claude-plugin/plugin.json`.
- Main orchestrator agent (`agents/superx.md`) with CTO-level orchestration loop.
- Specialized subagents: architect, coder, test-runner, lint-quality, docs-writer, reviewer.
- Launcher script (`bin/superx`) for one-command startup.
- State management CLI (`bin/superx-state`) with full CRUD on `superx-state.json`.
- Skill detection helper (`bin/detect-skills`).
- Conflict logging helper (`bin/conflict-log`).
- Publisher authenticity checker (`bin/authenticity-check`).
- Quality gate hooks (PreToolUse blocks push if gates fail, PostToolUse marks dirty state).
- Slash commands: `/superx:level`, `/superx:status`, `/superx:maintain`, `/superx:reflect`.
- Main skill with reference documentation (agent templates, quality gates, maintainer guide, communication templates).
- Full design specification in `docs/`.
- Agent teams support via experimental feature flag.
