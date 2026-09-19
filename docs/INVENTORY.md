# Heimdall (hmd) — inventory of the current version

Point-in-time catalogue of everything that ships in this tree, what each part does, and how it is proven. Written 2026-09-19 for the repo owner. Every count and claim below is derived from a command shown next to it; re-run the command to refresh the number. Paths are repo-relative.

**Version of record.** This document never hand-types a version — `test/version-pin-conformance.test.sh` fails any doc that does. The single source is `.claude-plugin/plugin.json`:

```bash
jq -r .version .claude-plugin/plugin.json      # the version this inventory describes
git rev-parse --short HEAD                     # the commit it was written against (3f9ba8e9 at writing)
```

---

## 1. What hmd is

README.md, first sentence: **"Heimdall makes your coding agent's work pass a test it didn't write — and proves that test can fail — before the push lands."** A Claude Code plugin (`.claude-plugin/plugin.json`, name `hmd`, display name Heimdall, MIT) and a plain git pre-push hook, so the gate holds in any repo and also gates Cursor CLI. Tagline (IDENTITY.md): *Nothing ships unproven.*

| Fact | Command |
|---|---|
| Plugin manifest name / display name | `jq -r '.name, .displayName' .claude-plugin/plugin.json` → `hmd`, `Heimdall` |
| Marketplace entry | `jq -r '.plugins[0].name' .claude-plugin/marketplace.json` → `hmd` |
| Canonical domain | `grep canonical IDENTITY.md` → `runheimdall.dev` |
| Executables in `bin/` | `find bin -maxdepth 1 -type f -perm +111 \| wc -l` → 212 (215 files; `ls bin \| wc -l` → 217 incl. `lib/`, `__pycache__`) |
| Python libraries in `bin/lib/` | `ls bin/lib/*.py \| wc -l` → 110 (of which `ls bin/lib/cp_*.py \| wc -l` → 47 control-plane) |
| Hooks in the registry | `bin/heimdall-hooks list --json \| jq length` → 36 |
| Agents / commands / skills | `ls agents/*.md \| wc -l` → 16 · `ls commands/*.md \| wc -l` → 19 · `ls skills/*/SKILL.md \| wc -l` → 5 |
| Test suites | `ls test/*.test.sh \| wc -l` → 427 |
| Oracles registered | `jq -r '.oracles \| keys[]' evals/oracles/registry.json \| wc -l` → 9 |
| Corpus cases | `jq length evals/corpus/INDEX.json` → 13 |

---

## 2. The proof machinery (the product)

hmd's thesis is that a gate is not trusted green until it has been shown to go red. Every layer below exists to make that mechanical.

### 2.1 Gates — Layer 0, git-only

`bin/heimdall-init` (`hmd init`) installs `core.hooksPath=.heimdall/hooks` in any repo, chaining any pre-existing hooks, and writes four hooks:

| Hook | What it runs | Escape |
|---|---|---|
| `pre-commit` | `bin/heimdall-gate-run --phase pre-commit` — stub-scan of the staged diff (`bin/lib/heimdall-stub-patterns.sh`), staged secret scan (`bin/secret-scan`) | `HMD_SKIP=1` — logs an unproven-merge receipt to `.heimdall/receipts/unproven.log`, never silent |
| `pre-push` | `bin/heimdall-gate-run --phase pre-push` — `bin/falsify` per applicable oracle domain, `bin/corpus run`, `bin/heimdall-selfscan` | same |
| `post-commit` | fire-and-forget presence beat carrying the last verdict | never blocks |
| `prepare-commit-msg` | appends the hmd co-author trailer; fires even under `--no-verify` | fails open |

`bin/heimdall-gate-run` reduces the suite to one verdict — `pass` or `deny` — persisted to `<repo>/.heimdall/verdict.json`; `bin/heimdall-verdict` prints it; `bin/heimdall-stamp` renders the branded denial block (`⛔ HEIMDALL: YOU SHALL NOT MERGE — …`). It also writes `AGENTS.md`'s fenced HEIMDALL block so every coding agent (Cursor, Codex, Gemini CLI, Claude Code) reads "this repo is gated" at session start.

### 2.2 Falsify — the falsifiability harness

`bin/falsify <domain> [--assert-score 1.0]` plants every registered mutant into the golden implementation and requires the oracle gate to go red on each; a survived mutant prints `REJECTED` and fails the assert. The README's own network-free proof:

```bash
bin/falsify exchange-lob --assert-score 1.0   # 6/6 mutants killed (incl. 2 tautology guards)
bin/falsify emulator-gb  --assert-score 1.0   # 3/3 mutants killed
```

Scores of record: `evals/flagship/STATUS.md` ("Falsifiability scores" table). The flagship pair is `exchange-lob` (differential gate + seeded interleave; the C2 racy engine goes RED at seed 1 index 0, the locked engine stays GREEN across 200 seeds) and `emulator-gb` (trace-diff vs gameboy-doctor + Blargg verdicts). Kept-red rows (`02-interrupts` timer descoped) stay in the table on purpose.

### 2.3 Oracles — external graders

`evals/oracles/registry.json` catalogues 9 oracles; `evals/oracles/README.md` is the schema. Gate-type ranking: `differential > trace-diff > verdict > property > example`. Every `reference.independent` must be `true` — the reference never shares code or authorship with the implementation.

```bash
jq -r '.oracles | to_entries[] | "\(.key)\t\(.value.gate_type)"' evals/oracles/registry.json
```

| Oracle | Gate type | Domain |
|---|---|---|
| `emulator-gb` | trace-diff | Game Boy CPU; external Blargg ROMs + gameboy-doctor traces |
| `exchange-lob` | differential | limit-order-book matcher vs independent O(n²) reference |
| `issue-collection` | differential | anonymized issue k-anon aggregate |
| `ponytail-underdelivery` | example | write-time under-delivery guard |
| `rr-multitenant-isolation` | example | 25-case all-DENY cross-tenant table |
| `symbol-reuse` | differential | cross-project symbol reuse |
| `team-checkpoint`, `team-copilot`, `triage-coord` | differential | team-mode surfaces |

Also in `evals/oracles/`: `BLIND-VERIFICATION.md`, `REPORT-CONTRACT.md`, `changelog-bash32`. `bin/oracle-select` resolves a domain id to its gate command; the planner auto-selects by `domain_signals`.

### 2.4 Corpus — the regression flywheel

`evals/corpus/` holds 13 real shipped-failure cases (`jq length evals/corpus/INDEX.json`; `SCHEMA.md` is the law: pinpoints are captured by replay, never hand-written). `bin/corpus run` replays them through the same gates and appends a per-version catch-rate row to `evals/corpus/CORPUS-STATUS.md` (it mutates the tree — not in the read-only proof block). `bin/corpus-capture` (PostToolUse `corpus-capture` hook) files a failed oracle report into `evals/corpus/_candidates/`. Current: **13/13 caught** (`evals/flagship/STATUS.md`).

### 2.5 Selfscan — push integrity over hmd's own history

`bin/heimdall-selfscan`, invoked by both the native pre-push hook and the Claude Code PreToolUse push gate: (1) gitleaks over full history, all refs; (1b) gitleaks `--no-git` over the pushable working tree with an anti-vacuous floor; (2) every author/committer email on every ref must be in the allowlist (`bin/heimdall-check-identities` is the single source). Pre-commit dedup vs pre-push: `hooks/hooks.json` defers to the native hook when `core.hooksPath` is wired (`test/pre-push-gate-dedup.test.sh`).

### 2.6 Sweep and receipt

`bash test/run-all.sh` (~17 min) discovers suites by glob, runs each under a perl alarm in its own process group (macOS has no `timeout`), re-runs reds solo, detects silent reds (fail output + exit 0), diffs `git status` before/after, and writes `.heimdall/receipts/last-sweep.json`.

```bash
jq '{finished_at,head_sha,suites_total,suites_passed,suites_failed,assertions_passed,assertions_failed,duration_s,tree_clean}' .heimdall/receipts/last-sweep.json
```

Last receipt at writing: **412/412 suites, 10,127 assertions passed, 0 failed**, 1037 s, `tree_clean: true`, at `b43c4f4b`. Suites added since bring the on-disk count to 427. CLAUDE.md rule: the full sweep runs **once**, immediately before the landing commit; `bin/heimdall-conformance` fails `gate-runs-once` / `gates-at-end` on the transcript otherwise. Commit `b43c4f4b` made the receipt immune to hmd's own post-commit publishing dirtying the tree (`test/sweep-receipt-gate.test.sh`).

### 2.7 The judgment invariant

`bin/lib/hmd-gate-endpoint.sh`: *generation may run compressed; judgment may not.* Every verdict-producing execution runs via `hmd_gate_exec` with `ANTHROPIC_BASE_URL`, proxy pairs and the `HEADROOM_*` namespace scrubbed and the endpoint pinned to the real provider; credentials pass through untouched. `test/gate-judgment-uncompressed.test.sh` goes red if a gate request reaches a proxy.

---

## 3. Session lifecycle — the hook registry

`hooks/hooks.json` is wiring; `hooks/hooks.metadata.json` is the sidecar with ids, fingerprints and the locked flag. `bin/heimdall-hooks` (`list|check|disable|enable|regen`) is the CLI; `bin/lib/hook-enabled.sh` is the read-side kill switch prepended to every advisory command. Locked ids cannot be disabled from either side.

```bash
bin/heimdall-hooks list --json | jq -r '.[] | [.event, .id, (.locked|tostring), .matcher] | @tsv'
bin/heimdall-hooks list --json | jq -r '[.[]|select(.locked)]|length'     # 8 locked
jq -r '.hooks | to_entries[] | "\(.key)\t\(.value|length)"' hooks/hooks.json   # groups per event
```

Groups per event: UserPromptSubmit 4 · PreToolUse 7 · PostToolUse 4 · SessionStart 12 · SubagentStop 2 · Stop 4 · SessionEnd 2 · PreCompact 1 = **36**.

| Event | id | Locked | Matcher | Purpose |
|---|---|---|---|---|
| UserPromptSubmit | `parallel-gate` | no | * | Injects a delegation directive when a prompt looks multi-part (`bin/parallel-gate`) |
| UserPromptSubmit | `ctx-meter-notice` | no | * | Context-window meter notice (`bin/heimdall-ctx-meter`) |
| UserPromptSubmit | `secret-paste-filter` | **yes** | * | Refuses a prompt carrying a pasted credential; value vaulted locally under `{{HMD_SECRET_n}}` (`bin/heimdall-secret-filter`) |
| UserPromptSubmit | `caveman-level-context` | no | * | Adds the caveman compression level as additionalContext |
| PreToolUse | `bash-gate-chain` | **yes** | Bash | `bin/heimdall-precheck-bash`: git-guard stale-lock clear, commit secret scan, pre-push quality/secret/selfscan/oracle/corpus gates (exit 2 blocks) |
| PreToolUse | `parallelism-tracker-read` | no | Read\|Grep\|Glob | Counts reads for the parallelism grade |
| PreToolUse | `agent-precheck` | **yes** | Agent | Named-agent notice + brief-adoption gate that rewrites oversized spawn prompts; coop native-spawn fence (`bin/heimdall-precheck-agent`) |
| PreToolUse | `stub-gate` | **yes** | Write\|Edit | BIFROST stub gate: blocks unfinished-code shapes |
| PreToolUse | `edit-claim-prewarn` | no | Edit\|MultiEdit\|Write | Advisory collision pre-warning when a teammate holds a claim (`bin/heimdall-precheck-edit`) |
| PreToolUse | `secret-read-guard` | **yes** | Read\|Grep\|Glob\|Bash | Blocks reads of credential-bearing files before they enter model context |
| PreToolUse | `lintconfig-guard` | **yes** | Write\|Edit\|MultiEdit\|Bash | Denies edits to linter/formatter/typechecker config (`HMD_ALLOW_LINTCONFIG_EDIT=1` override) |
| PostToolUse | `corpus-capture` | no | Bash | Captures a failed oracle report into the corpus |
| PostToolUse | `edit-tracker` | **yes** | Write\|Edit\|MultiEdit\|NotebookEdit | Logs every edit, marks state dirty (arms the pre-push quality gate), autocommits at 5+ files; hosts the tool-loop detector |
| PostToolUse | `context-sync` | no | Write\|Edit | Throttled background `heimdall-context-sync` to the `hmd/context` orphan branch |
| PostToolUse | `journal-commit` | no | Bash | Journal entry when a Bash call landed a commit |
| SessionStart | `session-bootstrap` | no | * | Autoupdate check, statusline register, selfheal, tracker builds, state init, stack detect, team/presence beat, reap advice, checkpoint notice |
| SessionStart | `resume-probe` | no | * | `heimdall-resume-probe` when CHECKPOINT.md exists |
| SessionStart | `maintain-resume-hint` | no | * | maintainer loop resume hint |
| SessionStart | `quota-resume-hint` | no | * | quota-exhaustion resume hint |
| SessionStart | `dream-notice` | no | * | surfaces a failing nightly /dream |
| SessionStart | `presence-keeper-start` | no | * | starts the presence beat keeper |
| SessionStart | `presence-connect-prompt` | no | * | control-plane opt-in prompt |
| SessionStart | `ai-select` | no | * | offline coding-AI backend selection |
| SessionStart | `claude-mem-scrub` | **yes** | * | Restarts a claude-mem daemon running with a routing/fallback-credential-contaminated env (credential egress fix C-1) |
| SessionStart | `caveman-rules` | no | * | Prints caveman rules into context |
| SessionStart | `settings-guard` | no | * | Advisory: ANTHROPIC_* overrides persisted in a settings.json env block |
| SessionStart | `volatile-repo-guard` | no | * | Advisory: clone on volatile disk holding unpushed work |
| SubagentStop | `subagent-metric` | no | * | Records a task outcome for the finished subagent |
| SubagentStop | `subagent-429-detect` | no | * | Scans the subagent transcript for a 429; marks for fallback routing |
| Stop | `stop-metric-reminder` | no | * | Metric reminder at main-agent Stop |
| Stop | `stop-claim-check` | no | * | Detects a stale present-tense process-status claim (`bin/heimdall-claim-check`) |
| Stop | `stop-429-detect` | no | * | Scans the main transcript for a 429 |
| Stop | `stop-lint` | no | * | Batch-lints every path edited this session; records a real lint receipt (`bin/heimdall-stop-lint`) |
| SessionEnd | `presence-keeper-stop` | no | * | Stops this session's keeper |
| SessionEnd | `session-end-sweep` | no | * | Foreground, alarm-bounded: checkpoint write, then autocommit (the never-lose contract). Background: parallelism grade, `verify-edits --quick`, cleanup, reel, summary card, context-sync; then the farewell |
| PreCompact | `precompact-checkpoint` | no | * | Auto-checkpoint `.planning/CHECKPOINT.md` before compaction rewrites context (`bin/heimdall-precompact-checkpoint`) |

Per-hook kill switch: `bin/heimdall-hooks disable <id>` writes `$HEIMDALL_HOME/hooks-disabled`; exit 2 on a locked id. Fingerprint drift: `bin/heimdall-hooks check` exits 1 if `hooks.json` and the sidecar disagree.

---

## 4. Guards and fences

| Guard | Where | Mechanism | Override |
|---|---|---|---|
| **Adjudication fence** | `bin/lib/hmd-adjudication-set.sh` (single list) consumed by `bin/heimdall-precheck-agent` and `bin/lib/hmd-route-claude` | Roles that emit a verdict (reviewer, verifier, security-auditor…) may never run on a routed/degraded endpoint; in-process spawns are denied when `ANTHROPIC_BASE_URL` is the live fallback; headless spawns pin the real provider | none — a false green is the failure the project exists to prevent |
| **Coop fence** | `bin/heimdall-precheck-agent` ("coop native-spawn refusal fence") | In state `coop`, only allowlisted generation roles route; an in-process Agent spawn cannot actually route (inherits env), so a coop-listed role spawned natively is refused rather than silently unrouted | `heimdall-fallback coop add/remove/list`; judgment roles can never be added |
| **Stub gate** | `bin/lib/heimdall-stub-patterns.sh` → PreToolUse `stub-gate` + `heimdall-gate-run --phase pre-commit` | 5 code *shapes* (empty body, not-implemented throw, marker comment…) — never bare words | path exemptions for docs/data/fixtures |
| **Secret paste filter** | `bin/heimdall-secret-filter` (UserPromptSubmit, locked) | Two-stage grep prefilter + classifier; refuses the turn (`input_tokens: 0`), vaults the value locally under a reference | re-send with `{{HMD_SECRET_n}}` |
| **Secret read guard** | `bin/secret-read-guard` (PreToolUse, locked) | Filename deny-list (`.env`, `*.pem`, `*.key`, `id_rsa*`, `credentials.json`, AWS credentials, OmniRoute fallback files, `.heimdall/team.json`…) plus a 4 KB content sniff for a private-key marker; covers Read/Grep/Glob and Bash reader binaries | `HMD_ALLOW_SECRET_READ=1` or `=<glob>[:<glob>]`, always prints a stderr warning |
| **Secret scan** | `bin/secret-scan` | gitleaks over the staged diff at commit; `--require` at push makes scanner absence a hard block | none at push |
| **Settings guard** | `bin/heimdall-settings-guard check|fix` (SessionStart, advisory) | Finds `ANTHROPIC_BASE_URL` / `ANTHROPIC_MODEL` / `ANTHROPIC_AUTH_TOKEN` persisted in a Claude Code `settings.json` env block — invisible to `env \| grep` yet applied on every launch in every repo | `fix` removes them |
| **Volatile repo guard** | `bin/heimdall-volatile-repo-guard check|explain` (SessionStart, advisory) | Repo real path under `/tmp`, `/private/tmp`, `/var/tmp`, `/private/var/folders`, or a `Caches` dir AND unpushed commits | none needed — advisory |
| **Lintconfig guard** | `bin/heimdall-lintconfig-guard` (PreToolUse, locked) | Denies Write/Edit/MultiEdit of lint/format/typecheck config and Bash write idioms (`>`, `tee`, `sed -i`…) against them | `HMD_ALLOW_LINTCONFIG_EDIT=1` |
| **Git guard** | `bin/heimdall-git-guard` | Clears a proven-stale `.git/index.lock` before a git write | — |
| **Agent watchdog / reaper** | `bin/heimdall-agent-watchdog`, `bin/heimdall-reap-idle`, `bin/heimdall-agents` | Enforcement + reaping of stalled/idle Agent-tool subagents | — |
| **Claim check** | `bin/heimdall-claim-check` (Stop) | Flags a final message that asserts a process is running when it is not | — |
| **Judge fence on loopback** | `bin/lib/hmd-headroom-chain.sh` + adjudication set | A reviewer/verifier spawn is denied while the Headroom proxy is the ambient endpoint (see memory note "Judge fence trips on loopback") | by design |

---

## 5. Agents and model routing

`agents/*.md` — 16 role definitions loaded by path. Model tiers from frontmatter (`grep -H '^model:' agents/*.md`), policy from CLAUDE.md "Model routing":

| Agent | Model tier | Role |
|---|---|---|
| `heimdall` | inherit (never pinned) | CTO-level orchestrator; decomposes, spawns, gates |
| `architect` | sonnet | read-only architecture + PLAN/waves.json with runnable criteria |
| `planner` | sonnet | dependency-ordered waves with grep/command-verifiable criteria |
| `coder` | sonnet | end-to-end feature implementation in an isolated worktree |
| `wave-executor` | sonnet | runs one wave; verifies criteria; commits atomically |
| `design` | sonnet | UI/UX decisions, design systems, accessibility |
| `database-architect` | sonnet | schema, migrations, query optimization |
| `docs-writer` | sonnet | documentation kept in sync with code |
| `test-runner` | sonnet | writes and runs tests |
| `fixer` | sonnet | picks up `bug`/`seeker` issues → fix branch → PR |
| `seeker` | sonnet | pulls pod logs, raises GitHub issues with repro |
| `incident-responder` | sonnet | RCA, rollback, blameless postmortem |
| `lint-quality` | haiku | mechanical lint / static analysis |
| `reviewer` | **opus** | code review; mandatory before push |
| `verifier` | **opus** | runs every acceptance criterion; PASS/FAIL with evidence |
| `security-auditor` | **opus** | OWASP, threat model, secrets; orchestrator must spawn it |

Routing rules (CLAUDE.md): main agent never pinned; default coding tier is the bare alias `sonnet`; opus only for adjudication (reviewer, verifier, security-auditor); Fable is escalation-only and not ZDR (needs `repo-policy allow_non_zdr_models`); never write a full model id into an operational spawn (`HEIMDALL_MODEL_<TIER>` exists solely for bench reproducibility). `bin/heimdall-tier` declares/enforces/reports the tier; `bin/heimdall-model-resolve` maps tier → `--model` string; `bin/lib/tier-table.json` is the table.

Spawn discipline (CLAUDE.md "Parallelism"): batch independent calls; one agent per independent file; never pass `name:` unless you will `SendMessage` it (measured 0/43 named completed vs 59/66 unnamed) — `agent-precheck` warns on stderr.

---

## 6. Skills and commands

**Skills** (`skills/*/SKILL.md`, 5):

| Skill | Description (frontmatter, abridged) |
|---|---|
| `heimdall` | The orchestrator superskill: analyzes prompts, assigns skills, decomposes into sub-projects, spawns parallel agents, enforces gates, tracks token budget; maintainer mode. References: `skills/heimdall/references/` (agent-templates, communication-templates, definition-of-done, git-workflow, identity-and-ledger, image-triage, journal, maintainer-guide, planning-pipeline, plugin-autoinstall, quality-gates, stack-packs, statusline-ledger) |
| `designmatch` | Match a React Native screen to a Claude Design HTML canonical at ≥95% visual parity; Playwright canonical renderer, pixelmatch + SSIM diff harness |
| `self-improve` | karpathy/autoresearch ported to hmd's routing/planning: evidence → hypothesis → bounded experiment → keep only if it beats baseline |
| `stacks` | Stack-specific knowledge packs (`ls skills/stacks/` → fastapi, nextjs, react-native, spring-boot) loaded onto a role agent |
| `system-health` | Disk/memory cleanup advisor; catches hmd's own runaway presence keeper; hands off to mac-deep-clean |

**Commands** (`commands/*.md`, 19 — `docs/INDEX.md` still says 15):

`autocommit` · `autonomy` (1 Guided / 2 Checkpoint / 3 Full Auto) · `bench` · `debloat` · `demo` · `designmatch` · `dream` · `fallback` · `feedback` · `invite` · `level` (deprecated alias of autonomy) · `maintain-check` · `maintain` · `reflect` · `report-bug` · `save` · `status` · `switch-ai` · `team`.

```bash
for f in commands/*.md; do printf '%s\t' "$(basename $f .md)"; grep -m1 '^description:' "$f" | cut -c14-120; done
```

---

## 7. Routing and fallback

**Policy gate**: `bin/heimdall-fallback` (Python; `status|set|check|arm|base-url|token-file|model|where|coop`). Policy only — never transport. `check` exit code is the verdict: 0 ROUTE · 1 REFUSE · 2 WAIT.

States (`grep VALID_STATES bin/heimdall-fallback`): **`off`**, **`auto`**, **`switch`**, **`coop`**. `coop` routes only an explicit per-role allowlist of generation roles; judgment roles can never be added.

Preflight checks (`sed -n '1488,1835p' bin/heimdall-fallback | grep -oE '"[a-z_]+"' | sort -u`), all required, none short-circuiting:

| Check | What it verifies |
|---|---|
| `tier1_credential_absent` | no `claude` / `claude-web` row in OmniRoute's own SQLite `provider_connections`; unreadable DB is a FAIL |
| `anthropic_model_pinned` | `ANTHROPIC_MODEL` set with an explicit `provider/` prefix |
| `no_delegated_sidecar` | no CLIProxyAPI/Dario/fallback upstream proxy row |
| `target_provider_allowed`, `tos_flagged_providers` | provider allowlist; a claude-branded model served by a non-Anthropic provider is refused (`cb52e077`) |
| `operator_key` / `operator_key_env` | the operator's own key is configured — or a credential the gateway itself holds is accepted (`42457fde`) |
| `gateway_key_scope` | the gateway key's `allowed_connections` scope covers the route; expired/revoked/banned keys refuse (`591c6824`) |
| `connection_health` | refuse when OmniRoute already knows the connection is dead (`f51f7413`) |
| `endpoint_reachable`, `endpoint` | local reachability probe of `127.0.0.1:20128` |
| `coop_role_allowed`, `fallback_model`, `state` | state/role/model consistency |

```bash
bin/heimdall-fallback status --json | jq 'del(.checks)'   # secret-free; on this machine state=coop, would_preflight_pass=false
```

**Transport seams**: `bin/heimdall-route` (`hmd route claude|--url|--status`) sets `ANTHROPIC_BASE_URL` on one child; `bin/lib/hmd-route-claude` is the per-spawn gate for every headless spawner (fails open to the real binary, judgment always pinned); `bin/heimdall-quota-advisor` prints options for a human and never auto-switches; `bin/heimdall-429-mark` / `heimdall-529-scan` / `heimdall-pressure` record exhaustion and overload; `bin/heimdall-quota-resume` captures a quota-killed agent for resume.

**OmniRoute module** (`modules/omniroute/manifest.json`): third-party local LLM gateway, `default_included: false`, bound to `127.0.0.1:20128`, installed pinned by `bin/heimdall-omniroute-install` (clone, checkout exact pin, apply `patches/omniroute/*.patch`, `npm ci`, verified build). Opt-in only.

**Headroom module** (`modules/headroom/manifest.json`): local context-compression proxy + storage codec, `default_included: true`, `consent_waived: true` (disclosed, not asked). Nothing installs it for you; `hmd modules add headroom` runs `uv tool install` against PyPI with no digest verification (receipt records `verified: false`). Only `hmd wrap claude` / `hmd route claude` actually carry generation traffic through it. `bin/lib/module_preflight.sh` names the fix for every failed precondition. `bin/heimdall-modules` is the lifecycle (`add|remove|status|list`); `modules/_classes/` holds the four permission-class contracts (rule-pack, storage-codec, tool-adapter, traffic-proxy); `test/modules-lifecycle.test.sh` gates it.

---

## 8. Team mode

| Piece | Client | Server (`bin/lib/cp_*.py`) |
|---|---|---|
| Team secret | `bin/heimdall-team new|join|show` — one file `<repo>/.heimdall/team.json` (0600); `team_id = sha256("heimdall-team\0"+secret)[:32]`; tracked only when the repo is proven private | `cp_repoteam.py`, `cp_team_creds.py`, `cp_team_queue.py` |
| Invite | `bin/heimdall-invite` — one-liner with the team secret inlined into the env of a fetched-then-run installer; refuses non-TTY | `cp_enroll.py` binds HAID → team |
| Presence | `bin/heimdall-presence connect|sever|beat|roster|off|on [--no-files]|status|retire|keeper-start|keeper-stop|doctor` — signed Ed25519 heartbeat {project, handle, verdict, filename basename, activity_ts}; keeper every 20 s under a ~45 s TTL | `cp_presence.py` — one keyed record per (project, haid), last-write-wins, Firestore-backed |
| Wall / board | `bin/heimdall-board`, `sentinels/hmd_wall.py`, statusline team zone | `cp_dashboard.py`, `bin/heimdall-dashboard` (device-flow login) |
| Control plane | `bin/heimdall-control-plane`, `bin/heimdall-connect`, `bin/rr` (remote-run) | `cp_server.py` — stdlib http router; auth chokepoint (`cp_auth`), dispatch allowlist (`cp_allowlist`), audit (`cp_audit`), `register_route` seam; worker/jobrunner/scheduler/notify/approval/ratelimit/anomaly/iap/god/publicsurface/selfcheck |
| Funnel | `bin/lib/funnel.py` + `bin/heimdall-funnel` — local ndjson spool, stages `install → init → invite_sent → join → badge_added`; consent-gated, zero-content, secret-scanned, team key hashed | `cp_funnel.py` — server-derived stamps only: `team_grew` (1→2 write-once), enroll-by-day spool, first-verdict; no new client payload |
| Coordination ledger | `bin/heimdall-claim`, `heimdall-haid`, `heimdall-who`, `heimdall-task`, `heimdall-activity`, `heimdall-collision`, `heimdall-checkpoint-share`, `heimdall-gate-surface`; MCP via `bin/heimdall-ledger-mcp` (`read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`, `raise_conflict_pr`) | — |
| Ops | `OPERATORS.md` (enroll token, `HEIMDALL_ENROLL_OPEN=1` posture), `deploy/cloud-run/INDEX.md` (README, GO-LIVE, MAINTAINER, PUBLIC-RR runbooks), `deploy/gce/README-rr.md`, `deploy/github-app/` | `bin/heimdall-cp-inspect`, `heimdall-live-verify`, `heimdall-god` |

Default posture is **network-on**: presence beats to the public control plane from first session (auto-minted solo team). `hmd presence sever` = zero egress. Field-level contract: DATA.md.

---

## 9. Operator surfaces

| Surface | File | What it shows |
|---|---|---|
| Statusline HUD | `sentinels/hmd-statusline.py` (via `hooks/statusline.sh`; `bin/heimdall-statusline` is the CLI-agnostic renderer) | 4-row composite: hero sigil · identity/branch/verdict · context gauge with cost · gates row (secrets/tests/designmatch) · 5h/7d micro-gauges · team eye-strips; width tiers full/mid/narrow/tiny; modules `hmd_gauge`, `hmd_layout`, `hmd_sigil`, `hmd_ledger`; `bin/heimdall-status-json` is the producer; `bin/heimdall-statusline-register[-cursor]` wires it |
| Subagent statusline | `sentinels/hmd-subagent-statusline.sh`, `subagent-statusline.py` | per-subagent line |
| Banner | `sentinels/hmd-banner.sh` (`--share`) | wake animation; identity card |
| Farewell | `sentinels/hmd-farewell.sh` (SessionEnd, foreground, after checkpoint + autocommit) | resting watchman + receipt from real stats only (files edited, agents spawned, clean tree) + share line |
| Gate animation / event | `sentinels/hmd-gate-anim.sh`, `hmd-gate-event.sh` | verdict → HUD state |
| Face / city / clip / reel | `bin/heimdall-face`, `heimdall-city`, `heimdall-clip`, `heimdall-reel` | block-glyph eyes reacting to build state; TUI skyline; shareable card; asciinema→GIF reel (degrades to `.txt` endframe) |
| Sigil / badge | `bin/heimdall-sigil`, `heimdall-sigil-png`, `heimdall-identity`, `heimdall-badge` | deterministic per-identity sigil; shields-style "N proven merges" badge counted from `.heimdall/receipts/beats.log`, offline SVG |
| Demo | `bin/heimdall-demo` (`hmd demo [--run]`) | dry by default; first-run narrated wake-up + a planted credential caught by the real `bin/secret-scan` (deny → fix → pass) |
| Companion UI | `bin/heimdall-ui` (`hmd ui`) | loopback read-only web view (section 13) |
| Watch TUI | `bin/heimdall-watch-tui` (`hmd watch`), `bin/heimdall-watch` | live dashboard; sentinels on human commits |
| Sentinels (spec H-3) | `sentinels/bloat.sh`, `doc-sync.sh`, `sanity.sh`, `security.sh`, `spec-drift.sh` | harness sentinels run per wave / pre-push |
| Summary card | `bin/summary-card` | end-of-run card |

`hmd --help` (`bin/heimdall --help`) subcommands: run a task · interactive · `--resume` · `--auto` · `--no-goal` · `--skip-checkpoint` · `--no-autocommit`/`--autocommit` · `--skills` · `--update` · `--setup` · `--team N` · `--reinstall` · `--uninstall` · `team` · `invite` · `join` · `connect` · `presence` · `tier` · `status` · `weekly-log` · `sla` · `report-issue` · `authenticity-check` · `queue …` · `queue drain` · `settings-guard` · `volatile-repo-guard`. The `bin/heimdall` router also dispatches many more verbs (`init`, `wrap`, `route`, `modules`, `fallback`, `ui`, `demo`, `sigil`, `funnel`, `hooks`, `caveman`, `verdict`, …) that `--help` does not list — see section 14.

---

## 10. `bin/` inventory by group

Derived with: `for f in bin/*; do [ -f "$f" ] && printf '%s\t%s\n' "$(basename $f)" "$(sed -n '2,8p' "$f" | grep -m1 -E '^#[^!]' | cut -c1-150)"; done`. One line each; 212 executables.

### Entry points and dispatch
| Executable | Purpose |
|---|---|
| `hmd` | canonical short entry point; symlink target of `~/.local/bin/hmd` |
| `heimdall` | the router: launches Claude Code with `--plugin-dir`, `--agent heimdall`; dispatches every `hmd <verb>` |
| `hmd-exec` | single dispatcher for "run a headless coding task" (backend-agnostic) |
| `heimdall-ai-select` | detect/default/persist which offline coding-AI CLI backend hmd prefers |
| `heimdall-wrap` | `hmd wrap <tool>` / `unwrap`: Layer-0 hooks + AGENTS.md fence + presence, byte-for-byte reversible |
| `heimdall-route` | run a coding tool through the Headroom chain and change nothing else |
| `heimdall-init` | install the universal git core (Layer 0) in any repo |
| `heimdall-hooks-link` | make a linked worktree's relative `core.hooksPath` resolve |
| `session-fork` | spawn parallel Claude sessions for independent sub-tasks |
| `heimdall-spawn` | Background Spawn Framework orchestrator (spec H-3) |
| `agent-pool` | auto-scaling agent pool manager |
| `decompose` | break tasks into dependency-ordered parallel sub-tasks |

### Gates, verdicts, proof
| Executable | Purpose |
|---|---|
| `falsify` | the falsifiability harness (oracle-gate keystone) |
| `corpus` | H-8 case-corpus runner + per-version catch-rate scorer |
| `corpus-capture` | H-8 field-capture intake (data flywheel) |
| `oracle-select` | resolve an oracle domain id to its gate command |
| `heimdall-gate-run` | headless gate entrypoint for plain git hooks; persists `verdict.json` |
| `heimdall-gate` | contract-consuming adapter (Token-Frugal Protocol v2) |
| `heimdall-verdict` | print the repo's last gate result |
| `heimdall-stamp` | the branded hard-gate-block denial stamp |
| `heimdall-selfscan` | shared push-integrity gate: gitleaks history + tree, identity allowlist |
| `secret-scan` | gitleaks over staged changes |
| `secret-read-guard` | PreToolUse block of credential-bearing file reads |
| `heimdall-secret-filter` | UserPromptSubmit refusal + local vault for pasted credentials |
| `heimdall-check-identities` | single source of truth for the author/committer allowlist |
| `heimdall-precheck-bash` | the PreToolUse/Bash enforcement chain (extracted from hooks.json) |
| `heimdall-precheck-agent` | PreToolUse/Agent: named-agent notice, brief-adoption gate, coop fence |
| `heimdall-precheck-edit` | conflict pre-warning for a file about to be edited |
| `heimdall-lintconfig-guard` | refuse agent edits to lint/format/typecheck config |
| `heimdall-stop-lint` | run the project's real linter over this session's edits at Stop |
| `heimdall-settings-guard` | detect ANTHROPIC_* overrides persisted in settings.json |
| `heimdall-volatile-repo-guard` | detect a clone on OS-wipeable disk with unpushed work |
| `heimdall-git-guard` | clear a proven-stale `.git/index.lock` |
| `heimdall-landmine-lint` | strict-mode shell landmine detector (fails closed) |
| `heimdall-deployed-shape-check` | static preflight for workstation assumptions in deployed code |
| `heimdall-conformance` | executable checks for the rules already written down (gate-runs-once, gates-at-end…) |
| `heimdall-plan-verify` | closes the plan → execution → verification loop |
| `heimdall-delivery-audit` | makes an orchestrator's delivery claims falsifiable |
| `heimdall-claim-check` | Stop-hook false-process-status detector |
| `heimdall-unconnected` | the connection audit: finished work nobody merged |
| `heimdall-deadcode` | consumer audit: every bin/ executable must name what calls it |
| `verify-edits` | review all edits made this session (existence, stubs, diff) |
| `heimdall-live-verify` | read-only live verification of the multi-tenant isolation boundary |
| `bloat-gate` / `heimdall-debloat` | H-2 deterministic bloat engine; retroactive whole-repo bloat removal |
| `heimdall-check` / `heimdall-redum` | F2 duplicate-shape checker (commit-time); F3 redundancy solver |
| `heimdall-reuse-metric` | S-6 C1 reuse analyzer |
| `heimdall-attest` | SI-2 commit-time attestation record |

### Hooks, session state, checkpoints
| Executable | Purpose |
|---|---|
| `heimdall-hooks` | ids, fingerprints, per-hook kill switch for hooks.json |
| `parallel-gate` | UserPromptSubmit multi-part task detector |
| `edit-tracker` (+ `.c`) | PostToolUse edit ledger; autocommit trigger; tool-loop detector |
| `parallelism-tracker` (+ `.c`, `build-tracker.sh`) | counts solo turns; parallelism grade; loop detector (`HMD_LOOP_THRESHOLD`) |
| `heimdall-state` | CRUD on `heimdall-state.json` (quality gates, phase) |
| `heimdall-checkpoint` | mechanical, LLM-free auto-save of forward session state |
| `heimdall-precompact-checkpoint` | PreCompact entry point driving `heimdall-checkpoint` |
| `heimdall-autocommit` | shared mechanics for the two automatic checkpoint commits |
| `heimdall-wip-commit` | mechanical mid-task checkpoint commits |
| `heimdall-resume-brief` / `heimdall-resume-probe` | resume state for an orchestrator; the falsifier for the memory stack |
| `heimdall-portable-brief` | CHECKPOINT.md → portable brief |
| `heimdall-context-sync` | always-on sync to the `hmd/context` orphan branch |
| `heimdall-context-capsule` | the rr context handoff |
| `heimdall-journal` / `heimdall-journal-hook` | git-committed narrative log; PostToolUse trigger |
| `heimdall-ctx-meter` | context meter; makes runaway context impossible to miss |
| `heimdall-session-usage` | pre-exhaustion session-budget advisory |
| `heimdall-memory-budget` | memory-aware cap on further agent spawns |
| `heimdall-agents` / `heimdall-agent-watchdog` / `heimdall-reap-idle` / `heimdall-agent-resume` | subagent tracker+reaper; enforcement; idle reaper; per-agent resume reporting |
| `heimdall-gc` / `heimdall-cleanup` / `heimdall-sysmon` | resource-hygiene GC; unified system-health core; disk/memory advisor |
| `shared-memory` | SQLite shared memory for parallel agents |
| `heimdall-blackboard` | shared key-value facts (Protocol v2 mech 5) |
| `heimdall-scrub-claude-mem` | SessionStart C-1 fix: restart a contaminated claude-mem daemon |
| `heimdall-cc-selfheal` | auto-heal Claude Code's native auto-updater |
| `heimdall-autoupdate` | hmd keeps itself current in the background (signed releases, fail-closed) |
| `heimdall-doctor-install` | mandatory post-install validation gate |
| `heimdall-liveness` / `heimdall-sla` | liveness receipt for scheduled subsystems; 24h SLA on ⚠ observations |

### Token-frugal protocol, memory, comprehension
| Executable | Purpose |
|---|---|
| `heimdall-protocol` | umbrella for Token-Frugal Protocol v2 (H-4) |
| `heimdall-validate` / `heimdall-resolve` / `heimdall-capsule` / `heimdall-brief` / `heimdall-ledger` | mechanisms 1–6: typed-message validator, symbol resolver, context capsules, delta-brief builder, token ledger |
| `heimdall-task-result` | H-4 return path: an agent's finding becomes a capsule |
| `heimdall-graph` / `heimdall-ast` | symbol-graph navigation; tree-sitter AST substrate |
| `heimdall-comprehend` | SI-1 project-context comprehension capsule + orientation cache |
| `heimdall-branch-context` | SI-3 git-backed branch-context reader |
| `heimdall-memory` / `heimdall-vm-bench` | Verified-Memory CLI; its benchmark |
| `heimdall-md` / `heimdall-web` | document → markdown converter; dependency-light web fetch/crawl |
| `heimdall-tokens` / `heimdall-cost-forensics` | model-token accounting meter; portable token/cost forensics |
| `heimdall-caveman` / `-block` / `-compliance` / `-eval` | output-compression level owner (ultra-only); system-prompt block; filler-density audit; multi-arm eval |
| `heimdall-tier` / `heimdall-model-resolve` | declare/enforce/report model tier; tier → `--model` |
| `heimdall-persona` / `heimdall-frontdoor` | set-once coder/non-coder persona; directory-aware front door |

### Routing, fallback, modules
| Executable | Purpose |
|---|---|
| `heimdall-fallback` | quota-exhaustion fallback policy gate (section 7) |
| `heimdall-quota-advisor` / `heimdall-quota-resume` | honest never-auto-switching advisor; quota-kill capture + resume |
| `heimdall-429-mark` / `heimdall-529-scan` / `heimdall-pressure` | reactive exhaustion recorder; read-only overload scan; 529 control bit |
| `heimdall-modules` | module system core: install, wire, verify, remove |
| `heimdall-omniroute-install` | pinned, patched, fail-closed OmniRoute installer |
| `heimdall-headroom-ab` / `heimdall-ponytail-ab` | one-week Headroom A/B receipts; Ponytail lazy-ladder delta |

### Team, presence, control plane, cloud
| Executable | Purpose |
|---|---|
| `heimdall-team` / `heimdall-team-converge` | per-repo team secret manager; converge-forward migration onto one team_id |
| `heimdall-invite` | one-command teammate join |
| `heimdall-presence` / `heimdall-presence-doctor` | server-synced presence client; self-healing autoenroll |
| `heimdall-haid` / `heimdall-who` / `heimdall-identity` | Heimdall Agent Identifier registry; per-agent view; watchman identity/sigil seed |
| `heimdall-claim` / `heimdall-ledger-mcp` | collision-prevention claims; MCP interop server |
| `heimdall-activity` / `heimdall-collision` / `heimdall-task` / `heimdall-gate-surface` / `heimdall-checkpoint-share` | TEAM MODE P1–P4: activity record, same-target collision, task record, shared gate surface, shared checkpoints |
| `heimdall-board` / `heimdall-seed-demo-wall` | live team wall; seed bot identities into a public demo team |
| `heimdall-control-plane` / `heimdall-connect` / `heimdall-cp-inspect` / `heimdall-god` | thin CP CLI; lazy secret-safe credential connect; read-only Firestore inspector; owner-only god mode |
| `heimdall-dashboard` | local side of device-flow dashboard login |
| `heimdall-gh-app-token` | short-lived GitHub App installation token |
| `rr` | remote-run: hand a task to the cloud maintainer (VM or control-plane mode) |
| `heimdall-land` | land-to-shared-main flow |
| `heimdall-funnel` | launch-funnel control + emit CLI |
| `heimdall-telemetry` / `heimdall-telemetry-corpus` / `heimdall-holdout` / `heimdall-report` / `heimdall-metric` / `heimdall-metric-hook` / `heimdall-metric-compliance` | local telemetry surface; pre-merge corpus; A/B holdout; aggregate report; task-outcome emitter; SubagentStop bridge; read-back compliance |
| `heimdall-issue-config` / `-corpus` / `-loop` / `-pr` / `-queue` | issue-resolution loop pieces: credentials, anonymized collection, state machine, PR + human-approval gate, queue |
| `heimdall-cost-report` / `heimdall-cost-model-refresh` / `heimdall-registry-hygiene` | daily cost job + brake chain; weekly unit-cost re-validation; monthly registry TTL eviction |
| `heimdall-queue` / `heimdall-queue-mcp` / `heimdall-drain` | local continuous-intake work queue; MCP server; drainer |
| `heimdall-maintain-loop` | durable maintainer autopilot loop |
| `heimdall-dream` / `-runner` / `-schedule` / `-notice` / `-permission` / `-bundle` | overnight autoresearch + maintainer sweep; launchd entry; nightly schedule; failure notice; permission ask; code-signing identity |
| `heimdall-self-improve` | deliberate self-improvement loop |
| `heimdall-rules` | V7: cluster corpus DENIES into candidate rules |
| `heimdall-s6-manifest` / `heimdall-s6-sweep` | S-6 popular-10 cold generalization sweep |
| `heimdall-watch` / `heimdall-watch-tui` | sentinels on human commits; TUI dashboard |
| `heimdall-feedback` / `report-issue` | team feedback issue; plugin bug report |

### HUD, identity, share units
| Executable | Purpose |
|---|---|
| `heimdall-statusline` / `heimdall-statusline-register` / `-register-cursor` / `heimdall-status-json` | renderer; self-bootstrap for Claude Code and Cursor; ledger status producer |
| `heimdall-face` / `heimdall-face-test` / `heimdall-banner-test` | the Watchman eyes; wcwidth acceptance harnesses |
| `heimdall-city` / `heimdall-clip` / `heimdall-reel` / `summary-card` | skyline TUI; shareable card; run reel; end-of-run card |
| `heimdall-sigil` / `heimdall-sigil-png` / `heimdall-badge` | deterministic sigil; PNG render; proven-merges badge |
| `heimdall-demo` | first-five-minutes demo |
| `heimdall-ui` | `hmd ui` companion web UI |
| `heimdall-weekly-log` / `generate-changelog` / `heimdall-render-version` | weekly changelog draft; changelog from conventional commits; render every version surface from plugin.json |

### Skills, stacks, design
| Executable | Purpose |
|---|---|
| `skill-manager` / `detect-skills` / `discover-skills` / `authenticity-check` | plugin lifecycle; installed-skill scan; mid-session gap detection; publisher trust score |
| `stack-detect` / `stack-pack` | detect tech stack; resolve knowledge packs |
| `designmatch` / `-behavioral-diff` / `-regen-log` / `-target` | Claude Design ↔ React Native parity harness and its seams |
| `conflict-log` | skill-conflict log in heimdall-state.json |
| `heimdall-connector` | pluggable source-adapter seam |
| `heimdall-chat` | chat-ops Telegram verb core |
| `benchmark` / `heimdall-bench` | honest-receipts benchmark harness; reproduce the public table locally |

### `bin/lib/` (shared)
Shell: `hmd-gate-endpoint.sh` (judgment invariant), `hmd-adjudication-set.sh`, `hmd-route-claude`, `hmd-headroom-chain.sh`, `hmd-python.sh` (shim-avoiding interpreter resolver, cached, runs `-c pass` to validate), `hook-enabled.sh`, `heimdall-stub-patterns.sh`, `heimdall-verify.sh`, `heimdall-emit.sh`, `hmd-claude-mem-scrub.sh`, `hmd-claude-retry.sh`, `module_preflight.sh`, `session-liveness.sh`, `reachability.sh`, `real-home.sh`, `tcc-paths.sh`, `crontab-safe.sh`, `brief-core.sh`, `planning.sh`, `protocol.sh`, `dispatch.sh`, `select.sh`, `resume-contract.sh`, `rule-inventory.sh`, `cp-consent.sh`, `dream-data.sh`. Python: 47 `cp_*.py` control-plane modules (auth, allowlist, audit, enroll, presence, funnel, dashboard, jobrunner, jobstore, scheduler, worker, state/state_firestore, ratelimit, anomaly, approval, notify, iap, god, credforward, team_creds, team_queue, repoteam, publicsurface, registry_hygiene, cost_model, costjob, daily_budget, corpus/_aggregate/_synth, issue_*/ingest, maintainer_runner, selfcheck, diag, boot, config, nonce, session, handlers, server); `funnel.py`, `pmr_corpus.py`, `telemetry.py`, `run_telemetry.py`, `holdout.py`, `report.py`; `checker.py`, `redum.py`, `dedup.py`, `collision.py`, `symbolgraph*.py`, `treesitter_ast.py`, `astgrep_match.py`, `reuse_analyzer.py`; `verified_memory.py`, `vm_*.py`, `memory_codec.py`; `chat_*.py`; `issue_*.py`, `maintain_loop.py`, `work_queue.py`, `triage_handoff.py`, `land_consolidate.py`; `watch_data.py`, `watch_tui.py`, `watch_entry.py`; `paste_secret_filter.py`, `claude_cred.py`, `minisign_verify.py`, `attestation.py`; `designmatch_targets/`, `behavioral_diff.py`, `regen_log.py`, `design_path.py`; `web_fetch.py`, `md_convert.py`, `dream_data.py`, `persona_store.py`, `frontdoor.py`, `comprehension.py`, `branch_context.py`, `checkpoint_share.py`, `quota_stop.py`, `pressure_control.py`, `hmd_api_backend.py`, `hmd_plan_verify.py`, `repo_audit.py`, `repo_roster.py`, `connectors/`. Data: `tier-table.json`, `liveness-subsystems.conf`, `reachability-exemptions.tsv`.

---

## 11. Tests and evals

```bash
ls test/*.test.sh | wc -l                               # 427 suites
bash test/<one>.test.sh                                 # the normal loop — run constantly
bash test/run-all.sh                                    # the full sweep — ONCE, before the landing commit
jq .assertions_passed .heimdall/receipts/last-sweep.json
bash test/version-pin-conformance.test.sh --self-test   # corrupt-and-confirm proof of the version gate
bash test/truth-pass-claims.test.sh --self-test         # five mutants incl. the sibling-site sweep
```

Evals (`evals/`): `oracles/` (section 2.3) · `corpus/` (2.4) · `flagship/` (STATUS, MUTATION-PROOF, README) · `benchmark/` (honest-receipts harness: `run.sh`, `harness.sh`, `summarize.sh`, `model-pins.json`, `tasks/`) · `caveman/` (prompts, snapshot, upstream skill for the compression eval) · `context-cost/` (cache-transition and context-slice measurement) · `live-isolation/` (LATEST receipt of the multi-tenant boundary) · `ponytail-ab/` · `evals.json`.

Receipts: `.heimdall/receipts/last-sweep.json` (sweep), `beats.log` (gated commits, source of the badge count), `unproven.log` (every `HMD_SKIP=1` bypass), `<repo>/.heimdall/verdict.json` (last gate verdict).

---

## 12. Data posture and secrets

DATA.md is the contract; `test/truth-pass-claims.test.sh` keeps README/install.sh/npm mirror/site free of bare absolute privacy claims and asserts the scoped sentences are present verbatim.

Five data surfaces (`sed -n '8,16p' DATA.md`):

| Surface | Leaves the machine? | Default | Kill switch |
|---|---|---|---|
| Local gates (secret-scan, falsify, bloat, reuse, verify) | never | on | n/a |
| Team presence | yes — {handle, verdict, filename basename, activity_ts} scoped to the team; never code or contents | on (auto-solo team) | `hmd presence off` / `sever` |
| Telemetry / pre-merge corpus | not in this release — local spool only | local | `hmd telemetry off|purge` |
| Auto-update check | one unauthenticated GET to GitHub Releases | on (~24h) | `HEIMDALL_NO_AUTOUPDATE=1` |
| `rr` cloud maintainer | only when run: BYO credential (write-only), GitHub App installation id, the task text | off | don't run it |

What never leaves the machine, mechanically: file contents (presence sends basenames only, `--no-files` hides even those); pasted credentials (refused pre-transmission by `secret-paste-filter`); credential-bearing files (`secret-read-guard` deny-list + private-key sniff); judgment inputs never traverse a proxy (`hmd-gate-endpoint.sh`); the team secret is printed to a TTY only and never written by `hmd invite`. Gitleaks runs at commit (staged), at push (history + tree), and at release (`release/ship.sh` step 0). `SECURITY.md` sections: Headroom proxy disclosure, auto-commit, secret hygiene, release integrity.

Credential-egress hardening of record: `.planning/security/2026-08-29-credential-egress-audit.md` (findings C-1 → `claude-mem-scrub`, C-4/H-1 → `secret-read-guard`). `bin/heimdall-settings-guard`'s header documents the 2026-09-11 discovery of a routing base URL, model and auth token persisted in a `settings.json` env block — described there by shape only, no value.

---

## 13. In flight — companion UI (`hmd ui`)

Plan: `.planning/plans/PLAN-companion-ui.md` (847 lines) + `.planning/plans/companion-ui.waves.json`. Landed so far: `bin/heimdall-ui`, `sentinels/hmd-ui.py`, `sentinels/hmd-ui.html`, `test/heimdall-ui.test.sh` (Wave 1). `evals/oracles/companion-ui/` (Wave 0 invariant ledger) does not exist yet.

Decisions:
1. **Runtime** — python3-stdlib `ThreadingHTTPServer`, single file, pure `collect_state(root)`; zero build step.
2. **Transport** — SSE (`GET /api/events`) polling the same files `hmd_ledger.read_status` reads, digest-diff so idle emits nothing.
3. **Remote** — `hmd ui --remote user@host` = `ssh -N -L` port-forward to a remote `hmd ui`; zero new server code; no secret moves.
4. **Safe actions (Wave 2)** — exact allowlist: `save-checkpoint` (→ `heimdall-checkpoint write`), `view-receipt`, `hook-toggle` (advisory ids only), `open-reel`. Never: fallback/routing state, `git push|commit`, team.json/PKI/CP writes, locked hooks, any general file write.
5. **Auth** — loopback bind + per-launch random token (401) + Host-header allowlist (403); token appears only in the printed URL.
6. **Job panels (Wave 4)** — a job publishes closed-type descriptors under caps (`MAX_FILE_BYTES=65536`, `MAX_TITLE_CHARS=120`…), the renderer draws them, `source` is OUT (no iframe, no per-panel build).

Waves (`jq -c '.waves[] | {wave, tasks: [.tasks[].id]}' .planning/plans/companion-ui.waves.json`): 0 invariants · 1 server-core · 2 oracle-test · 3 actions · 4 remote · 5 panel-invariants · 6 panels · 7 panels-test. Status field is null on every wave — landing state is inferred from files on disk, not recorded in the plan.

---

## 14. Known gaps

From `docs/analysis/2026-09-19-go-live-virality-eval.md` (gitignored, local-only; 180 lines):

| Gap | Citation |
|---|---|
| Statusline "invite your team" tease does not exist — README and `bin/heimdall-invite:5-6` claim it; `sentinels/hmd-statusline.py` and `hmd_wall.py` contain zero `invite` strings | row B3 |
| Funnel unmeasured — hop 6 (`team_grew`) is stamped server-side but blind; no `invite_id` links invite → join → growth, so K cannot be computed | "Loop closure, honestly"; fix row 4 |
| Share unit is a `.txt` run card — 82/82 shareable artifacts on this machine are `.txt`; PNG renderers exist (`heimdall-sigil-png`, `summary-card`) but are not the farewell's share line | fix row 7 |
| First `hmd` installs third-party plugins (`superpowers`, two marketplaces) with no prompt | Sev-1, `bin/heimdall:1236-1262`; fix row 8 |
| 19 test suites hardcode the maintainer's personal clone path; `modules/omniroute/manifest.json:21` wording (now fixed in `8d0ed617`) | row B9; fix row 12 — `grep -rl '/Users/rj' test modules \| wc -l` |
| 12 SessionStart hooks, no timeouts, unmeasured startup tax | Sev-2; fix row 11 |
| `hmd --help` lists ~30 subcommands; the router dispatches many more that help does not show | section 9 above; eval "216 bin scripts" |
| `docs/INDEX.md` says 15 commands; `ls commands/*.md \| wc -l` → 19 | this inventory |

Other gaps this inventory surfaced: `.heimdall/receipts/last-sweep.json` describes 412 suites while 427 exist on disk (15 suites unswept since `b43c4f4b`); `evals/oracles/README.md` lists 6 oracles while `registry.json` has 9 (`team-checkpoint`, `team-copilot`, `triage-coord` undocumented there); the companion-UI waves.json carries no status per wave.

`docs/analysis/` is gitignored (`git check-ignore -v docs/analysis/…` → `.gitignore:35`) apart from 65 legacy tracked files (`git ls-files docs/analysis | wc -l`); 78 files on disk. Titles: `for f in docs/analysis/*.md; do grep -m1 '^# ' "$f"; done`.

---

## 15. Appendix — what changed on 2026-09-18/19

```bash
git log --since='2026-09-18' --format='%h %s' | grep -v -E 'wip|auto-checkpoint|journal|ledger'
```

**Fallback / OmniRoute**
- `cb52e077` fix(fallback): refuse a claude-branded model served by a non-Anthropic provider
- `f51f7413` feat(fallback): refuse when OmniRoute already knows the connection is dead (`connection_health`)
- `42457fde` feat(fallback): accept a credential the OmniRoute gateway holds itself (gateway-held credential path)
- `591c6824` feat(fallback): verify the gateway key's connection scope before routing (`gateway_key_scope`; expiry/revocation/ban checked in OmniRoute's own DB)
- (coop state and its native-spawn fence predate this window; `d147657b` touched `bin/heimdall-fallback` to clear a sweep tripwire)

**Guards**
- `84f33005` feat(guard): deny edits to linter/formatter/typechecker config (`heimdall-lintconfig-guard`)
- settings-guard and volatile-repo-guard: wired as SessionStart advisories in `a794a5c1`; `d147657b` fixed `test/heimdall-volatile-repo-guard.test.sh`

**Hooks registry, kill switch, PreCompact, stop-lint, loop detector, Bash-chain extraction**
- `a794a5c1` feat(hooks): registry with IDs, fingerprint drift check, per-hook kill switch; wire PreCompact, stop-lint, lintconfig-guard
- `f12152e6` feat(hooks): `heimdall-hooks list --json` — machine-readable registry view
- `5b6d0673` feat(lint): real batch lint at Stop over every path edited this session
- `f950922e` feat(hooks): live tool-loop detector, armed on Write/Edit
- `e281211d` refactor(hooks): move the 5,008-char Bash gate chain into `bin/heimdall-precheck-bash` (byte-identical behaviour proven by `test/heimdall-precheck-bash.test.sh`)

**SessionEnd checkpoint fixes**
- `3d618684` fix(hooks): SessionEnd writes the checkpoint synchronously again; housekeeping stays backgrounded
- `c482f8a5` fix(hooks): SessionEnd autocommit is synchronous too — a written-but-uncommitted checkpoint is lost with the worktree

**Python resolver**
- `e6a1e4bf` fix(python): resolver must RUN a cached interpreter, never trust `-x` (`bin/lib/hmd-python.sh`, `test/hmd-python.test.sh`)

**Sweep receipt**
- `b43c4f4b` fix(run-all): a sweep receipt cannot be dirtied by hmd's own post-commit publishing
- `d147657b` fix(tests): clear four full-sweep tripwires the ECC wave set off

**Secret scrub / rotation**
- No commit in this window carries a scrub/rotation subject (`git log --since=2026-09-17 -i --grep=rotat --grep=scrub`). The relevant shipped mechanisms are the locked `claude-mem-scrub` SessionStart hook (C-1) and `bin/heimdall-settings-guard`, whose header records that a persisted gateway auth token was found in a settings.json env block on 2026-09-11 and removed; no credential value appears anywhere in the tree or this document.

**Docs truth-fixes + README fold**
- `8d0ed617` docs: make five claims match the code they describe (CHANGELOG, CLAUDE.md, README, `bin/heimdall-caveman`, `modules/omniroute/manifest.json`, npm README)
- `5e9ae321` docs(readme): lead with the mechanism, one install line, and a 60-second proof (the numbers table with reproduce-it commands)
- `bb8a82da` docs(changelog): no hand-typed versions in the status note

**Companion UI plan**
- `.planning/plans/PLAN-companion-ui.md` — design only, deliberately uncommitted (operator instruction); Decisions 5 and 6 amended 2026-09-19 after the independent tester's contract findings. Wave 1 code (`bin/heimdall-ui`, `sentinels/hmd-ui.*`) is on disk.

**Analysis (gitignored)**
- `docs/analysis/2026-09-19-ecc-harness-gap-analysis.md` — the ranked gap list that drove PreCompact (#1), stop-lint (#2), Bash-chain extraction (#3), lintconfig-guard (#4)
- `docs/analysis/2026-09-19-go-live-virality-eval.md` — section 14 above
