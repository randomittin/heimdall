# /hmd:save auto-compact: what Claude Code lets us trigger (STEP 0 evidence, 2026-11-26)

Question: after `/hmd:save` writes the handoff, can compaction start without the user pasting `/compact <focus>`? Today
`commands/save.md` says "A command, skill or hook cannot run `/compact` or `/clear`". This note checks that claim against the
installed Claude Code and its documentation, candidate by candidate, before any code is written.

## Method

- Installed builds: `~/.local/share/claude/versions/{2.1.326,2.1.330,2.1.331,2.1.332}` (native Mach-O, Bun-compiled, JS embedded).
  `claude` on PATH is a symlink to 2.1.332. The session that asked for this note RUNS 2.1.330: its Bash tool env carries
  `CLAUDE_CODE_EXECPATH=~/.local/share/claude/versions/2.1.330` and `CLAUDE_CODE_SESSION_ID`. Version skew between PATH and the
  running session is therefore real, and any version gate must read `CLAUDE_CODE_EXECPATH`, not `claude --version`.
- Bundle evidence: `strings -a -n 12 <binary>`, then byte-offset reads of the minified JS (2.1.332 offsets quoted as `@N`). Minified
  identifiers (`bes`, `XZ`, `qG`, `IUn`, ...) are build-specific; the stable anchors are the named methods and log strings.
- Docs fetched 2026-11-26 from `https://code.claude.com/docs/en/<page>.md`: hooks, settings, settings-reference, model-config,
  env-vars, skills, commands, context-window, plugins/mods/{overview,api,reference,events}.
- No live end-to-end probe was run (it needs the account's credentials and would have to edit a real settings file). The verdicts
  below are bundle- and docs-level; the test plan covers the tool's side with a temp `CLAUDE_CONFIG_DIR`.

## Verdicts

| # | Candidate | Verdict |
|---|-----------|---------|
| a1 | A settings-hook output field (`decision`, `continue`, a `compact` field) that requests compaction | NOT LIVE: does not exist |
| a2 | A command or tool the model can call to run `/compact` | NOT LIVE: documented as unavailable |
| a3 | The mods API `$.session.compact({ instructions })` | LIVE in the bundle, but only reachable from a mod; not used |
| b  | Mid-session edit of `autoCompactWindow` | NOT LIVE: the key is snapshotted at session start |
| b' | Mid-session edit of the settings `env` block: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | LIVE (bundle); chosen |

### a1. Hook output fields: none requests compaction

- The bundle's hook JSON output schema (`@20333837`) is `{ continue, suppressOutput, stopReason, decision: "approve"|"block",
  systemMessage, terminalSequence, reason, hookSpecificOutput }` where `hookSpecificOutput` is a union of per-event shapes
  (PermissionRequest, CwdChanged, FileChanged, MessageDisplay, Elicitation, ElicitationResult, WorktreeCreate, ...). No member
  asks the host to compact.
- Hooks reference, "Decision control": `PreCompact` can only BLOCK a compaction (`decision: "block"` or exit 2) and "Claude Code
  discards a PreCompact hook's `systemMessage` and `continue` fields"; `UserPromptSubmit` "can't replace the prompt; it only
  injects `additionalContext`"; `SessionStart`'s `initialUserMessage` is "the first user message of the session, in non-interactive
  mode with the `-p` flag". None of these starts a compaction in a running interactive session.

### a2. `/compact` is not model-invocable

Skills page: "A few built-in commands are also available through the Skill tool, including `/init` and `/security-review`. Other
built-in commands such as `/compact` aren't." So `commands/save.md` cannot ask the model to run it.

### a3. Mods API: live, out of reach for `/hmd:save`

- Docs: the mods reference lists `compact` among the `$.session` methods, and a `session.compact` hook event ("The conversation is
  about to be compacted", a hook may return `{ skip: reason }`).
- Bundle: the `$.session` builder has `compact:(o)=>... t("session.compact", {instructions})` (`@22795276`, error text `$.session.compact
  takes { instructions } (a string) or nothing`), and the op table marks `"session.compact":"host"` (`@26848248`). The error string is
  present in all four installed builds, 2.1.326 through 2.1.332.
- It is callable only from JavaScript that runs INSIDE Claude Code as a mod (a plugin component with the user's permissions and
  its own trust model). `/hmd:save` runs a Bash command and a Python tool; neither can reach it, and the heimdall plugin ships no
  mod (`.claude-plugin/` holds `plugin.json` and `marketplace.json` only). Shipping one is a new runtime artifact with an
  unrelated install and trust story, and no way for the Python side to know whether it is loaded. Recorded as a future route:
  it would have no settings side effect and would target exactly one session.

### b. `autoCompactWindow` does not hot-reload

The settings page says Claude Code "watches your settings files and reloads them ... most edits", and its list of keys read once
(`model`, `effortLevel`, `modelSettings`) is "the ones you're most likely to edit". The bundle shows `autoCompactWindow` is also
read once:

- The value the threshold uses is `appState.autoCompactWindow` (`options.autoCompactWindow` is copied from it, `@54003053`),
  a `{ default, byModel }` snapshot of the settings made by `IUn()` (`@31003286`) when the session starts.
- It is refreshed only by: `/autocompact` (`sWt` writes `userSettings`, then emits `apply_flag_settings {autoCompactWindow:null}`,
  and `Oat` calls `IUn()`, `@47011194` and `@48156451`), `claim_session` (`rereadAutoCompactWindows`, `@75869531`), and the
  headless runner when project settings load at start (`vN`: `countsAsStart && source==="projectSettings"`, `@55121549`).
- The interactive settings-changed handler (`Hio`, `@41077525`, called at `@42401285`) updates `settings` and
  `toolPermissionContext` only. The bundle's own changelog (2.1.329) confirms the snapshot model: "Fixed sessions started from a
  pre-warmed process ignoring the `autoCompactWindow` setting in the project's `.claude/settings.json`".
- Precedence also works against it: `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then `--autocompact`, then a per-model
  `modelSettings.<model>.autoCompactWindow`, all beat the top-level key.

An edit to the key after launch changes nothing in the running session, so the brief's candidate (b) as worded is not live.

### b'. The settings `env` block IS re-applied mid-session

- The state-diff handler (`@39889206`): `if (e.settings !== n.settings) { ... if (e.settings.env !== n.settings.env || Ona()) bes(),
  s?.notifyAutocompactInputsChanged() }`, with the error text `Failed to apply settings change (clear auth caches / re-apply env)`.
  `bes()` calls `T1()`, which is `R.applyConfigEnvironmentVariables()` (`@23075016`): it walks every settings source and re-assigns its
  `env` entries into `process.env` (`Object.assign(process.env, F)` for the sources the person controls, a repository-aware path for
  project sources; `@23072810`), then `xna()`.
- `xna()` is `putBackUnsuppliedAutoCompactEnv()` (`@23061924`): when `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in `process.env` was supplied by
  settings and no settings source supplies it any more, it is put back to its startup value or deleted. The bundle's changelog
  (2.1.329): "Fixed `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` staying in effect in a running session after it is removed from settings.json".
- The threshold reads the variable on EVERY evaluation: `XZ(e,n)` parses `process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` into
  `testPctOverride` (`@31010491`), and `qG(w, o) = Math.min(Math.floor(w * (pct / 100)), w - buffer)` for `0 < pct <= 100`
  (`@31002214`), so the variable can only LOWER the threshold. `ak(model, window) = qG(xse(model, window), XZ(model, window))` is the
  trigger the query loop compares the context size against before each request.
- `_m()` reads `autoCompactEnabled` live (`@28729461`); with it off, or `DISABLE_AUTO_COMPACT` / `DISABLE_COMPACT` set, no automatic
  compaction runs and this route cannot fire.
- Docs agree on the variable ("Set the percentage (1-100) of the auto-compact window at which auto-compaction triggers ... the variable
  can't raise the threshold").

Builds that carry the put-back (`putBackUnsuppliedAutoCompactEnv` string count in the binary; `testPctOverride` and the re-apply
error text are in all four):

| build | put-back | re-apply on settings change | `testPctOverride` |
|-------|----------|-----------------------------|-------------------|
| 2.1.326 | absent | present | present |
| 2.1.330 (the running one) | present | present | present |
| 2.1.331 | present | present | present |
| 2.1.332 | present | present | present |

The changelog places the fix in 2.1.329. A build before it re-applies the variable but never takes it back, so an armed value would
stay in force until restart (compaction at every request). The gate is therefore: arm only when the running build is 2.1.329 or
later, read from `CLAUDE_CODE_EXECPATH`; otherwise print the paste line as before.

## Chosen mechanism and what it requires

> Amended by the review follow-up at the end of this note: the arming goes to the project's `.claude/settings.local.json`, not the user-level file
> (a user-level arming reaches every session on the machine).

`env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in the user-level `settings.json`, set for a short time through the existing
`heimdall-compact-window` backup, record and consent machinery:

1. `/hmd:save` writes the handoff as today, then arms the override. The first request after Claude Code reloads the file compacts.
2. The PreCompact hook (compaction is starting, so the override has done its job and must not outlive it, or the smaller context
   would compact again), any SessionStart, and an expiry check on UserPromptSubmit and Stop (`release-expired`, built in the last section) put the user's file back exactly.
3. The printed `/compact` line stays as the fallback: no consent yet, an older build, auto-compact turned off, a value of the
   person's own in the way, an unusable settings file.

## Risks to carry into the implementation and the report

- The user-level file is shared: every session on the same `CLAUDE_CONFIG_DIR` re-applies the override while it is armed, so
  another session that makes a request in that window compacts too. The window is kept short (release at the first PreCompact
  anywhere, a few minutes of expiry at most), but it is not zero.
- Reload latency (the watcher plus the ConfigChange hook gate) means the compaction can land on the first request after the save turn,
  not inside it. Either way the user pastes nothing.
- No live end-to-end run was done. If a build ever stops honouring the override, the armed state expires and the paste line still works.

## Review follow-up (2026-11-26): arm the project's `.claude/settings.local.json`, never the user file

The review of the first implementation found a HIGH: `on --compact-now` armed the override in the USER-level `settings.json`, so every Claude Code
session on the machine, in any repo, compacted for up to 5 minutes. The reading above says the env re-apply "walks every settings source"; this
section checks whether the project-level local file (`<project>/.claude/settings.local.json`: untracked, the person's own) is applied mid-session
and ungated, so the arming can be confined to the one repository.

Method: the RUNNING build, 2.1.330 (`CLAUDE_CODE_EXECPATH`; offsets `@N` below are in that binary), byte-offset reads of the embedded JS through a
pattern search over the mapped file (no strings dump was written to disk). No live end-to-end probe (it needs the account and a real settings edit).

**Verdict: LIVE, and not gated for an ordinary interactive session.** A project source takes the same re-apply path as the user file.

| # | Question | Finding (2.1.330) |
|---|----------|-------------------|
| 1 | Is the file watched? | Yes. The settings change detector builds its watch list from every source but `flagSettings` (`pt`, `@293907172`: `for(let p of Ts){if(p==="flagSettings")continue;let h=_n(p);...if(p==="projectSettings"\|\|p==="localSettings")O.add(h)}`), plus the launch-directory local file (`A_()`, row 6); `we(path)` (`@293909486`) maps a path back to `localSettings`. A directory that does not exist yet is watched through its parent until it appears (`pendingDirs`, "Settings directory ... appeared; watching it"), so a `.claude/` made by the arming is picked up. |
| 2 | Does a change reload? | Yes, behind the ConfigChange hook gate: "Detected change to <file>", then `Oe(source, file)` (a hook may block it: "ConfigChange hook blocked change to <file>"), then the source is reloaded (`@293904534`). |
| 3 | Is the new env applied to the running process? | Yes. The state-diff handler (`@310186160`): `if(e.settings!==o.settings){...if(e.settings.env!==o.settings.env\|\|Bji())zGo(),...}`. `zGo` (`@310167297`) runs `w1()`, the full `applyConfigEnvironmentVariables` (`@293433294`): `for(let L of Ko())` over the enabled sources, each through `filterSettingsEnv`, then `Object.assign(process.env, ...)`. `Qee(L)` is `new Set(["projectSettings","localSettings"]).has(L)` (`@288742900`): for those two the assignment is bracketed by the repository marker (`zQi`), which only keeps the value out of CHILD process environments; the variable is still set in the agent's own `process.env`, which is where the threshold reads it (b'). |
| 4 | Does the project-scope filter drop it? | No. `ot`, the project-scope pass, drops a key only when `HTr(name)` holds: a member of the 204-name set `_ks` (`@293393331`) or a prefix in `Qe` (`["CLAUDE_AX_"]` in this build). Neither names `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (the set holds no `AUTOCOMPACT` or `AUTO_COMPACT` name). The variable is in the SAFE set `A_` (`@288755456`; `ROe(name) = A_.has(NAME) \|\| ...`, `@288763775`), the list the pre-trust pass `applySafeConfigEnvironmentVariables` (`@293430591`) applies. |
| 5 | Trust gating | The mid-session re-apply is skipped unless the folder's trust dialog was accepted: `zGo(o=Yi)` returns when `!o()`, and `Yi` (`@291694837`) is `trustAccepted` or the persisted `projects[<root>].hasTrustDialogAccepted` of the folder or a parent. An interactive session cannot run in a folder whose dialog was not accepted, so this holds for the cases that matter; in a folder that was not trusted the arming would silently do nothing and the expiry timer would clean it up. The "short list of variables only" cut (`asFromAFolderNobodyTrusted`) applies only to a served folder or a non-interactive run with `--ignore-persisted-trust` (`aut`, `@289847872`), not to a terminal session. |
| 6 | Which file is `localSettings`? | `<root>/.claude/settings.local.json` with `root` = the launch's local-settings store root, else `projectConfigDir`, else `bB(cwd, canonicalGitRoot)`: the canonical git root of the launch directory when the ownership probe passes (root, `.git` and `.claude` owned by the same user), else the launch directory (`PKn`, `@289728910`). When the launch directory differs from that root, `<launch dir>/.claude/settings.local.json` is read as well (`Uo`, `oOe`). So the file at the git toplevel is read by a session started at the root or in a subdirectory of it. |
| 7 | A tracked or linked file | Claude Code classifies the file itself (`lN`, `uN`, `Py`, near `@291697590`): a symlink at `.claude` or at the file, a `.claude/.git`, or an lstat error other than ENOENT counts as `tracked`; otherwise `git ls-files --error-unmatch -- ':(icase).claude/settings.local.json'` (2 s): exit 0 is `tracked_in_index`, 1 `untracked`, 128 "not a git repository" `indeterminate`, anything else `tracked`. A tracked file is the repository's text, not the person's; what Claude Code does differently for it was not traced, and hmd does not write to one in any case. |
| 8 | Take-back | As in b': `putBackUnsuppliedAutoCompactEnv` (`@293423208`) walks every source (`Ko().map(keptSettingsEnv ...)`) and puts the variable back to its startup value, or removes it, once no source supplies it. When a source that supplied it reports settings errors (`QT(source).some(rF)`, the predicate was not traced) the put-back is deferred (`autoCompactPutBackOwed`) and re-tried on the next change. |

### Decision

1. `on --compact-now` arms ONLY `<project>/.claude/settings.local.json`. `<project>` is `$CLAUDE_PROJECT_DIR` (set for hooks; this session's Bash tool
   environment does not carry it), else the git toplevel of the cwd. The user-level file is never written for the trigger.
2. It is refused (exit 5, nothing written, the printed `/compact` line stays the way) when git tracks the file or cannot say, when `.claude` or the file
   is a symlink or not a plain regular file, or when no project can be found: the classes Claude Code itself calls `tracked` (row 7).
3. The records already hold `settings` per path, so release, the expiry timer and `status` work per file, and a `release` run from any directory finds
   every armed file.
4. The person's yes is per repository: the consent stamp is keyed by the project root, so a yes given in one repository arms no other.
5. `--tokens` and `--bash-cap` stay user-level: they are settings keys, not env entries, and the project file is not theirs to take.
6. `commands/save.md` says the arming affects sessions in this repository only, and, when the arming was released before the compaction began (another
   session starting, the expiry), tells the person to paste the line.

Residual risks, carried into the report: another session in the SAME repository still compacts while the file is armed (and so does a subagent of this
session); a session whose settings root is another directory (a different launch directory, a worktree started elsewhere) does not read the file, so
the arming does nothing and the paste line is still printed; the folder's trust must have been accepted and no ConfigChange hook may block the reload;
whether `--setting-sources` can leave `local` out of `Ko()` was not traced; no live end-to-end run was done.

## Follow-up (2026-11-27): the expiry check closes the last gap

Release used to happen on four paths only: the PreCompact hook, any SessionStart, the detached 300 s `watch` timer, and `off`. The gap: when the timer dies
(its process killed, a logout) and no session starts, an arming whose compaction never came stays in the project's file, and every request of every session in
that repository compacts until one of the other three paths runs. The expiry check that step 2 of "Chosen mechanism" named is now built, and the gap is closed.

- `bin/heimdall-compact-window release-expired` puts back every arming whose `expires_at` has passed, through the same `undo` path as `release` (text-exact, from
  the backup and the record; a value the person changed meanwhile is left and its record cleared), and no other: an arming still inside its time stays, so the Stop
  hook that ends the very turn `/hmd:save` armed in does not undo it. A record that gives no usable expiry counts as over (putting the file back is the safe way to be
  wrong; the paste line is the fallback), and a record that is not JSON is skipped, as `release` skips it.
- Two hooks, appended last in their events so no existing index moves: `compact-now-expiry-prompt` on UserPromptSubmit (it runs before the prompt's request goes out)
  and `compact-now-expiry-stop` on Stop (the end of every turn). Each is advisory, gated by `hmd_hook_enabled` on its own id (`heimdall-hooks disable <id>`), has a
  10 s timeout and starts with one `ls` of the record glob, so while nothing is armed it costs one process. Armed, it runs the tool: no network, no `git`, no
  version probe (`running_build` is asked only by `on`), one attempt per arming (the next prompt or turn end is the retry, so a record that cannot be used does
  not add a sleep to each of them), nothing on stdout (a UserPromptSubmit hook's stdout reaches the model), exit 0 always, one line on stderr for what could not be
  done, a missing tool included.
- The bound that remains: an arming is put back at the first prompt or turn end after its `expires_at`. Nothing runs between the requests of one turn, so a turn
  that outlives the arming can still make requests that compact until it ends; a turn that starts without a prompt (a background agent finishing) can make one
  request before its Stop hook runs. Idle time costs nothing: no prompt, no request.
- Proof: `test/compact-window.test.sh`, section S11 (the verb on an expired and an unexpired arming, from outside any project, per arming across two projects, a
  re-arm, a record with no usable expiry, a value the person changed, a record that is not JSON, one that cannot be used; then the real hook commands from
  `hooks.json`, each on its own switch, with a stale plugin root).
