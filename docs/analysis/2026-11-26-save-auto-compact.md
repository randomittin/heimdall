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

`env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in the user-level `settings.json`, set for a short time through the existing
`heimdall-compact-window` backup, record and consent machinery:

1. `/hmd:save` writes the handoff as today, then arms the override. The first request after Claude Code reloads the file compacts.
2. The PreCompact hook (compaction is starting, so the override has done its job and must not outlive it, or the smaller context
   would compact again), any SessionStart, and an expiry check on UserPromptSubmit and Stop put the user's file back exactly.
3. The printed `/compact` line stays as the fallback: no consent yet, an older build, auto-compact turned off, a value of the
   person's own in the way, an unusable settings file.

## Risks to carry into the implementation and the report

- The user-level file is shared: every session on the same `CLAUDE_CONFIG_DIR` re-applies the override while it is armed, so
  another session that makes a request in that window compacts too. The window is kept short (release at the first PreCompact
  anywhere, a few minutes of expiry at most), but it is not zero.
- Reload latency (the watcher plus the ConfigChange hook gate) means the compaction can land on the first request after the save turn,
  not inside it. Either way the user pastes nothing.
- No live end-to-end run was done. If a build ever stops honouring the override, the armed state expires and the paste line still works.
