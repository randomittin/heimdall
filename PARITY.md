# PARITY.md — superx to heimdall feature-surface parity matrix

**Extraction date:** 2026-06-13
**Source tag (superx baseline):** `v1.1.0`
**Classified against:** current `main` (worktree `parity/p1-matrix`, branched off `main` @ `4a52ba7`)

## Source-tag choice + reasoning

Two tags exist: `v1.0.0` and `v1.1.0`. Both have manifest `name: "superx"`
(`git show v1.0.0:.claude-plugin/plugin.json`, `git show v1.1.0:.claude-plugin/plugin.json`)
— i.e. **both tags are PRE-rename** (neither is named heimdall). v1.1.0 is the
**later and strictly larger** superx surface: it adds `bin/superx-state` subcommands
(`add-tokens`, `set-budget`, `budget`, `migrate`, `status`), `bin/conflict-log`,
`bin/authenticity-check`, `bin/generate-changelog`, the autonomy-level/maintainer
command set, and keywords `caveman`, `token-compression`, `cross-session-memory`,
`autonomous-maintenance`. v1.0.0 is a strict subset.

The plan defines "last superx tag" as the surface representing superx **before/at the
rename**. v1.1.0 is the **last** (highest) superx-named tag and the richest superx
surface that ever shipped under that name, so it is the correct baseline. All extraction
below is mechanical from `git show v1.1.0:<path>` / `git ls-tree -r v1.1.0`.

**FINDING (tag):** The true pre-rename baseline = v1.1.0 (confirmed superx-named, not
post-rename). No post-rename tag exists yet; current heimdall is **untagged HEAD**.
The heimdall surface is therefore "main" not "a tag". This is expected, not a defect.

## Totals per status

| Status | Count |
|---|---|
| kept | 22 |
| renamed | 25 |
| improved | 19 |
| intentionally dropped | 6 |
| findings (unclassifiable) | 2 |
| **total items** | **74** |

> Update 2026-06-13: finding #3 (`CLAUDE_CODE_NO_FLICKER`) was a P1 extraction error — the export IS present (`bin/heimdall:211`). Reclassified `kept` (21→22); findings 3→2. Findings #4/#5 fixed on branch `fix/parity-findings` (held off main until RJ's current-state push). #1 (no post-rename tag) resolves as v2.0.0 at tag time; #2 (dashboard sub-feature parity) deferred to RJ post-re-test.

(Plus: heimdall adds a large NEW surface — oracle gates, corpus, falsify, secret-scan,
selfscan, bloat-gate, parallel-gate, blackboard/ledger, watchman renderers, designmatch,
stack-packs, ~30 new bins, 5 sentinels. Those are NET-NEW and out of scope for a
*parity* (superx to heimdall) matrix except where they replace a superx item; noted in
Notes. They are why the heimdall tree is ~5x the v1.1.0 tree.)

---

## Commands (CLI subcommands / flags of bin/superx to bin/heimdall)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Command | `superx "<task>"` | Run task end-to-end, non-interactive `claude -p` w/ preamble | renamed (`superx` to `heimdall`/`hmd`) | `heimdall "<task>"` / `hmd "<task>"` | `bin/heimdall`; `bin/hmd` execs `heimdall` (hardlinked at install) |
| Command | `superx` (no args) | Interactive `claude --agent superx` | renamed (`--agent superx` to `--agent heimdall`) | `heimdall` interactive | `bin/heimdall` |
| Command | `superx --resume` / `-r` | `claude --continue`, load `.planning/STATE.md` + `superx-state.json` | improved (checkpoint restore) | `--resume`/`-r` reads `.planning/CHECKPOINT.md` + state | `bin/heimdall:695` |
| Command | `superx --dashboard` | Launch python pixel web dashboard at :8080 | intentionally dropped (web UI removed) | no `--dashboard` flag | replaced by terminal watchman renderers `heimdall-city`/`heimdall-face`/`heimdall-reel`; see Statusline/Findings |
| Command | `superx --update` | git ff-only pull plugin, show changes | kept | `heimdall --update` | `bin/heimdall:473` |
| Command | `superx --setup` | re-run companion-plugin setup | kept | `heimdall --setup` | `bin/heimdall:685` |
| Command | `superx --team N "task"` | Spawn N claude workers in tmux | kept | `heimdall --team N` | `bin/heimdall:769` |
| Command | `superx --uninstall` | Remove ~/.superx, PATH, optional plugins | improved (guarded `_heimdall_remove_plugin`, no unguarded rm) | `heimdall --uninstall` | `bin/heimdall:599` |
| Command | `superx --auto` | `--permission-mode auto` instead of skip-perms | kept | `heimdall --auto` | `bin/heimdall:846` |
| Command | `superx --help` / `-h` | Usage text | kept | `heimdall --help`/`-h`/`help` subcmd | `bin/heimdall:811` |
| Command | (none at tag) | — | improved (new) | `heimdall version`/`-v`, `demo`, `guard install` | net-new subcommands `bin/heimdall:332` |

## Flags (bin/superx to bin/heimdall)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Flag | `--dangerously-skip-permissions` (default) | Full autonomy default | kept | default `PERMISSION_FLAG` | `bin/heimdall` |
| Flag | `--auto` | safer permission-mode | kept | kept | — |
| Flag | (none) | — | improved (new) | `--reinstall`/`--fix` | repair install `bin/heimdall:580` |
| Flag | (none) | — | improved (new) | `--skip-checkpoint`/`--fresh` | skip checkpoint restore `bin/heimdall:850` |
| Flag | (none) | — | improved (new) | `--no-goal` / goal system | goal-condition autonomy `bin/heimdall:855` |
| Flag | (none) | — | improved (new) | `--no-autocommit` / `--autocommit` | autocommit toggle `bin/heimdall:861` |
| Flag | (none) | — | improved (new) | `--skills` | skill mgmt entry `bin/heimdall:874` |

## Agents (agents/*.md)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Agent | `superx` (orchestrator) | CTO-level main agent | renamed (`superx` to `heimdall`) | `agents/heimdall.md` | settings.json `agent: heimdall` |
| Agent | `architect` | system design | kept | `agents/architect.md` | — |
| Agent | `coder` | feature impl | kept | `agents/coder.md` | — |
| Agent | `database-architect` | schema design | kept | kept | — |
| Agent | `design` | UI/design | kept | kept | — |
| Agent | `docs-writer` | docs | kept | kept | — |
| Agent | `incident-responder` | incident handling | kept | kept | — |
| Agent | `lint-quality` | lint gate | kept | kept | — |
| Agent | `planner` | wave-grouped plans | kept | kept | — |
| Agent | `reviewer` | code review verdict | kept | kept | — |
| Agent | `security-auditor` | security audit | kept | kept | — |
| Agent | `test-runner` | run tests | kept | kept | — |
| Agent | `verifier` | verification | kept | kept | — |
| Agent | `wave-executor` | per-wave parallel exec | kept | kept | — |
| Agent | (none) | — | improved (new) | `agents/fixer.md` | net-new |
| Agent | (none) | — | improved (new) | `agents/seeker.md` | net-new |

## Gates

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Gate | Tests pass | `.quality_gates.tests_passing`, mark-dirty/clean | kept | same, `heimdall-state` | `skills/heimdall/references/quality-gates.md` |
| Gate | Lint clean | `.quality_gates.lint_clean` | kept | kept | — |
| Gate | Conflict reflection | `conflict-log` reviewed before push | kept | kept (`bin/conflict-log`) | — |
| Gate | Code review | reviewer APPROVE/BLOCK | kept | kept | — |
| Gate | No dirty state | `.quality_gates.dirty`, push blocked | kept | kept | — |
| Gate | Pre-push: `check-quality-gates` | PreToolUse Bash hook on `git push`, exit 2 | improved (stacked w/ secret/selfscan/oracle/corpus) | same call + 4 new gates in same hook | `hooks/hooks.json` PreToolUse |
| Gate | (none) | — | improved (new) | secret-scan (pre-commit + pre-push, gitleaks) | net-new `bin/secret-scan` |
| Gate | (none) | — | improved (new) | heimdall-selfscan (full-history gitleaks + identity allowlist) | net-new `bin/heimdall-selfscan`, native `hooks/git/pre-push` |
| Gate | (none) | — | improved (new) | oracle gates / falsify (`--assert-score 1.0`) | net-new `bin/falsify`, `evals/oracles/*` |
| Gate | (none) | — | improved (new) | corpus regression gate | net-new `bin/corpus`, `evals/corpus/INDEX.json` |
| Gate | (none) | — | improved (new) | bloat-gate, parallel-gate, placeholder-code PreToolUse block | net-new `bin/bloat-gate`, `bin/parallel-gate`, Write/Edit hook |

## Hooks (hooks/hooks.json + git hooks)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Hook | PreToolUse Bash to quality-gates on `git push` | `superx-state check-quality-gates` | renamed + improved | `heimdall-state check-quality-gates` + secret/selfscan/oracle/corpus + parallelism-tracker | `hooks/hooks.json` |
| Hook | PostToolUse Write/Edit to mark-dirty + auto-checkpoint at >=5 files | `superx-state mark-dirty`; auto-commit `superx: auto-checkpoint` | renamed + improved | `heimdall-state mark-dirty` (superx-state fallback); edit-tracker log; `.heimdall-no-autocommit` opt-out; `heimdall: auto-checkpoint` | `hooks/hooks.json` |
| Hook | SessionStart to init state + announce STATE.md | init `superx-state`; echo resume hint | renamed + improved | init `heimdall-state` (superx fallback); build trackers; stack-pack detect to `detected-stack.json`; CHECKPOINT.md hint | `hooks/hooks.json` |
| Hook | SessionEnd to commit if dirty | auto-commit `superx: session-end checkpoint` | renamed + improved | `heimdall: session-end checkpoint`; + parallelism grade, verify-edits, reel record, summary-card | `hooks/hooks.json` |
| Hook | (none) UserPromptSubmit | — | improved (new) | `parallel-gate` on prompt submit | `hooks/hooks.json` |
| Hook | (none) PreToolUse Read/Grep/Glob/Agent | — | improved (new) | parallelism-tracker check | `hooks/hooks.json` |
| Hook | (none) PostToolUse Bash | — | improved (new) | corpus-capture on failing oracle report | `hooks/hooks.json` |
| Hook | (none) git pre-push | — | improved (new) | native `hooks/git/pre-push` wired via `hmd guard install` | `hooks/git/pre-push` |

## Env vars

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Env | `SUPERX_STATE_FILE` | override state file path (default `superx-state.json`) | renamed (`SUPERX_STATE_FILE` to `HEIMDALL_STATE_FILE`) | `HEIMDALL_STATE_FILE`, **with SUPERX_STATE_FILE back-compat fallback** | `bin/heimdall-state`, `bin/conflict-log` |
| Env | `SUPERX_PORT` | dashboard port (default 8080) | intentionally dropped (web dashboard removed) | not read | no python web server in heimdall |
| Env | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | set in theme + settings.json | kept | kept | `settings.json`, `bin/heimdall` |
| Env | `COLORTERM` / `TERM` | truecolor detection for banner/statusline | kept | kept | `bin/heimdall`, `hooks/statusline.sh` |
| Env | `CLAUDE_CODE_NO_FLICKER=1` | flicker-free render | kept | exported by `apply_heimdall_theme` (`bin/heimdall:211`) | P1 extraction error corrected — see Findings #3 (RESOLVED) |
| Env | (none) | — | improved (new) | `CLAUDE_PLUGIN_ROOT` (hook self-location), `ANTHROPIC_API_KEY`, `MODEL_FLAG`/`MODEL_NAME`, `GOAL_CONDITION`/`GOAL_PROMPT`, `USE_GOAL`, `SKIP_CHECKPOINT`, `SECRET_SCAN_REQUIRE` | net-new `bin/heimdall`, `hooks/hooks.json`, `bin/secret-scan` |

## Config keys (settings.json + state json)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Config | settings.json `agent` | `"superx"` | renamed | `"heimdall"` | `settings.json` |
| Config | settings.json `env` | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | kept | kept | — |
| Config | settings.json `statusline.command` | `bash $PLUGIN_DIR/hooks/statusline.sh .` | kept | kept | — |
| Config | state `.quality_gates.{tests_passing,lint_clean,dirty,conflict_reflection_done,last_review}` | quality gate flags | kept | kept (read by statusline + check-quality-gates) | `bin/heimdall-state`, `hooks/statusline.sh` |
| Config | state `.budget.{total_tokens,token_limit}` | token budget; warn at 80% | kept | kept (rendered as bar in statusline) | `bin/heimdall-state budget`/`set-budget`/`add-tokens` |
| Config | state `.agent_history` | track agents | kept | kept (`add-agent`) | `bin/heimdall-state` |
| Config | state `.conflict_log` | skill conflicts | kept | kept (`add-conflict`) | `bin/heimdall-state`, `bin/conflict-log` |
| Config | state `.goal.condition` | — (not at tag) | improved (new) | `goal-set`/`goal-get`/`goal-clear`, rendered in statusline | net-new `bin/heimdall-state` |
| Config | `.planning/detected-stack.json` | — (not at tag) | improved (new) | written by SessionStart stack-pack detect | net-new |

## State / CLI helper subcommands (bin/superx-state to bin/heimdall-state)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Command | `superx-state` (binary) | CRUD on superx-state.json | renamed (`superx-state` to `heimdall-state`) | `bin/heimdall-state` (+ `migrate` converts superx-state.json) | — |
| Subcmd | `init get set add-conflict check-quality-gates mark-dirty mark-clean add-agent add-tokens set-budget budget migrate status` | full subcommand set | kept (all 13) | identical set, same names | `bin/heimdall-state:395-410` |
| Subcmd | (none) | — | improved (new) | `goal-set goal-clear goal-get` | net-new |
| Command | `superx-ui` | launch ui/server.py dashboard | intentionally dropped (web UI removed) | no `heimdall-ui`; `bin/superx-ui` deleted | replaced by `heimdall-city`/`heimdall-face`/`heimdall-reel` |
| Command | `authenticity-check <npm/github/plugin>` | publisher trust score 0-100 | kept | `bin/authenticity-check` (unchanged name) | — |
| Command | `conflict-log <add/list/unresolved/mark-reflected/reflect-all>` | conflict CRUD on state | improved (HEIMDALL_STATE_FILE w/ superx fallback) | `bin/conflict-log` | — |
| Command | `detect-skills` | scan installed skills to JSON | kept | `bin/detect-skills` (+ new `bin/discover-skills`, `bin/skill-manager`) | — |
| Command | `generate-changelog [--since][--version][--append]` | conventional-commit changelog | kept | `bin/generate-changelog`, flags identical | — |
| Lib | `bin/lib/dispatch.sh` | JSONL task queue, mkdir locks | kept | `bin/lib/dispatch.sh` | — |
| Lib | `bin/lib/planning.sh` | `.planning/` state mgmt | kept | `bin/lib/planning.sh` (+ new `bin/lib/protocol.sh`) | — |

## Slash commands (commands/*.md, namespace /superx:* to /hmd:*)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Slash | `/superx:level <1/2/3/+/->` | set/cycle autonomy level | renamed (`/superx:level` to `/hmd:level`) | `commands/level.md` | namespace = plugin name (heimdall/hmd) |
| Slash | `/superx:status` | show state + gates | renamed to `/hmd:status` | `commands/status.md` | — |
| Slash | `/superx:maintain [on/off/status]` | maintainer mode | renamed to `/hmd:maintain` | `commands/maintain.md` | — |
| Slash | `/superx:maintain-check [--dry-run]` | one maintenance cycle | renamed to `/hmd:maintain-check` | `commands/maintain-check.md` | — |
| Slash | `/superx:reflect` | conflict reflection pass | renamed to `/hmd:reflect` | `commands/reflect.md` | — |
| Slash | (none) | — | improved (new) | `/hmd:save autocommit bench debloat demo designmatch report-bug` | net-new commands |

## Files read/written

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| File | `superx-state.json` (+ `.lock`) | primary state file, mkdir lock | renamed (`superx-state.json` to `heimdall-state.json`) | `heimdall-state.json`; reads/migrates `superx-state.json`; hooks check both | back-compat retained |
| File | `.planning/STATE.md` | living memory, YAML frontmatter | kept | kept | `bin/lib/planning.sh`, statusline |
| File | `.planning/PROJECT.md REQUIREMENTS.md CONTEXT.md PLAN-{phase}.md SUMMARY-{phase}.md` | planning docs | kept | kept | `bin/lib/planning.sh` |
| File | `.planning/dispatch/queue.jsonl` | task queue | kept | kept | `bin/lib/dispatch.sh`, statusline |
| File | `evals/evals.json` | eval suite (`skill_name: superx`, 3 evals) | renamed + improved | `evals/evals.json` + large `evals/{oracles,corpus,flagship,benchmark}/` tree | net-new eval infra |
| File | `.setup-done` marker | first-run companion-plugin marker | kept | kept (SETUP_MARKER) | `bin/heimdall` |
| File | `superx-github.json` | dashboard project/URL config | intentionally dropped (dashboard removed) | not written | — |
| File | (none) | — | improved (new) | `.planning/CHECKPOINT.md`, `.planning/detected-stack.json`, `.planning/ledger/*`, `.planning/bloat.json`, `evals/oracles/*/report.json` | net-new |

## Statusline elements (hooks/statusline.sh)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Statusline | `[SUPERX]` prefix | static tag | renamed (`[SUPERX]` to `[HEIMDALL]`) | `[HEIMDALL]` | `hooks/statusline.sh` |
| Statusline | phase | from STATE.md `current_phase` | kept | kept | — |
| Statusline | wave/tasks `N/total` | from PLAN/SUMMARY grep | kept | kept | — |
| Statusline | dispatch `Xrun/Yq` | from queue.jsonl | kept | kept | — |
| Statusline | (none) | — | improved (new) | token budget bar (5-cell, color by pressure), gate glyphs (t/l/dirty), goal marker, watchman face eyes | reads heimdall-state.json + heimdall-face |
| Statusline (pixel web) | isometric city map, war room, streaming logs, day/night theme, history drawer, status badges (IDLE/RUNNING/AWAITING INPUT/ERROR), map controls | python web dashboard `ui/server.py` + `ui/static/*` | intentionally dropped (web UI removed), reimagined | terminal watchman: `heimdall-city` (skyline TUI), `heimdall-face` (close-up), `heimdall-reel` (replay) | rendered ENTIRELY shell/ANSI, zero context cost — design law; see Findings |

## Documented behaviors (README/docs/commands at tag)

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Behavior | Hybrid planning pipeline (complexity-aware routing) | simple to direct, medium/complex to plan/exec/verify | kept | kept | `agents/heimdall.md`, README |
| Behavior | Wave-based parallel execution, fresh 200K ctx per wave | dependency waves, no context rot | kept | kept | — |
| Behavior | Question-mark protocol (end w/ `?` when input needed) | preamble INPUT rule | kept | kept | preamble in `bin/heimdall` |
| Behavior | Model routing haiku/sonnet/opus | MODEL ROUTING preamble | kept | kept (preamble `bin/heimdall:1105`) | — |
| Behavior | Continuation: never exit w/ tasks remaining | preamble CONTINUATION | improved (adds `/hmd:save` cadence) | `bin/heimdall:1112` | — |
| Behavior | Acceptance criteria as runnable gates | blocking, 2 fix attempts then BLOCKED | kept | kept | — |
| Behavior | Autonomy levels 1/2/3 (Guided/Checkpoint/Full Auto) | `/superx:level` | renamed (`/hmd:level`) | `commands/level.md` | — |
| Behavior | Maintainer mode (triage/fix/test/batch release) | severity x confidence matrix | kept | kept | `commands/maintain*.md` |
| Behavior | Token budgets, warn at 80% | budget cmds | improved (statusline bar) | kept + visualized | — |
| Behavior | Companion plugins auto-install (caveman, superpowers, claude-mem) | first_run_setup | kept | kept (`first_run_setup` in `bin/heimdall:172`) | superx-marketplace add renamed to heimdall-marketplace (bin/heimdall:195-197) |
| Behavior | Companion marketplace self-registration | `claude plugins marketplace add randomittin/superx-marketplace` | renamed (`superx-marketplace` to `heimdall-marketplace`) | `randomittin/heimdall-marketplace` | `bin/heimdall:195-197`; uninstall removes it too (`bin/heimdall:666`) |
| Behavior | GitHub one-click commit+push from dashboard | dashboard feature | intentionally dropped (dashboard removed) | n/a | — |
| Behavior | Recovery / resume from errors | `--resume` + STATE.md | improved (CHECKPOINT.md) | `bin/heimdall:695` | — |
| Behavior | Safer alt to skip-permissions (`--auto`) | permission-mode auto | kept | kept | — |
| Behavior | Project memory via CLAUDE.md auto-write | `ensure_project_claude_md` | kept | kept (`ensure_*_claude_md`) | text now "managed by heimdall" |

## Token / efficiency surface

| Class | Item | Superx behavior (at v1.1.0) | Status | Heimdall now | Notes |
|---|---|---|---|---|---|
| Token | caveman companion auto-install | install caveman@caveman marketplace | kept | kept (`bin/heimdall:172` first_run_setup) | ~65-75% savings claim retained |
| Token | CAVEMAN ULTRA preamble (max compression every response) | full preamble block: drop articles/filler/hedging, fragments, abbrev list, arrows for causality, exact code/paths, drop for security/irreversible | kept | identical block `bin/heimdall:1183-1184` | verbatim port |
| Token | CLAUDE.md "Token Efficiency / Caveman ultra mode active" section | auto-written project CLAUDE.md | kept | kept `bin/heimdall:256-258` | — |
| Token | Terse system preamble (caveman style) | PREAMBLE var in non-interactive launch | kept + improved | preamble externalized to `$PREAMBLE_FILE`, richer routing | `bin/heimdall` |
| Token | claude-mem persistent memory (cross-session, no repeat context) | first_run_setup `npx claude-mem install` | kept | kept | — |
| Token | fresh context per wave (context hygiene) | 200K window per wave, no prior-wave garbage | kept | kept | — |
| Token | banner claim "caveman ultra ~75% tokens saved" | print_banner line | kept | kept `bin/heimdall:310` | — |
| Token | (none) | — | improved (new) | watchman renderers are "zero context cost" (shell/ANSI only, never model) — explicit token-hygiene design law; `bin/debloat`/bloat-gate trims output | net-new efficiency mechanism |

---

## Findings — unclassifiable

1. **No post-rename tag exists.** Both `v1.0.0` and `v1.1.0` are manifest-name
   `"superx"`. Current heimdall is **untagged `main`** (HEAD `4a52ba7`). Parity is
   therefore measured tag-to-HEAD, not tag-to-tag. Whether heimdall intends to re-tag
   (e.g. v2.0.0) is unknown from the tree. Ambiguous: the "current heimdall surface"
   is a moving target until a heimdall tag is cut.

2. **Pixel web dashboard — dropped vs. reimagined is genuinely ambiguous.** superx
   v1.1.0 shipped a substantial python web dashboard (`ui/server.py`, `ui/static/*`
   incl. isometric tiles, `app.js`, `map.js`, `sprites.js`, `terminal.js`) with
   documented status badges, map controls, war room, day/night theme, history drawer,
   and GitHub one-click push. Heimdall deletes the entire `ui/` tree and `bin/superx-ui`
   and substitutes terminal renderers (`heimdall-city`, `heimdall-face`, `heimdall-reel`).
   The intent overlaps (live observability) but the surface, dependencies, and many
   sub-features (GitHub push button, map controls, web :8080) have **no 1:1 heimdall
   equivalent**. I classified the umbrella as "intentionally dropped (web UI), reimagined
   as terminal", but the *individual* web sub-features (status-badge taxonomy, map
   controls, history drawer, GitHub push) cannot each be cleanly mapped — they may be
   dropped, may be partially covered by the TUI. Ambiguous: per-sub-feature parity of
   the dashboard.

3. ~~**`CLAUDE_CODE_NO_FLICKER=1` not set by heimdall theme.**~~ **RESOLVED — extraction
   error, NOT a regression.** Re-verification (git blame `bin/heimdall:211`) shows
   `apply_heimdall_theme` DOES export `CLAUDE_CODE_NO_FLICKER=1`, at the same 3rd-export
   position as the superx baseline; carried through the rename (commit 13c19d6a → b37a5bc),
   never dropped. P1 missed line 211. Status is therefore `kept`, not a finding. Row 132
   above is stale — correct it to `kept`.
