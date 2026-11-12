# Plan: 3.x M1 — skill registry, recommended defaults, guardrail tiers

Spec: `/Users/rj/Downloads/01-skills-separation.md` (§1 principles, §5 Stage 0-1, §12 addendum + 3.0.0 row). Handoff docs read: `/Users/rj/Downloads/goals.yaml` (human-owned; this plan never edits it), `/Users/rj/Downloads/CONTRACTS.md` (app<->control-plane contract, unrelated to this plan). `PLAN (1).md` does not exist.
Operator ask (2026-11-12): "start working on skill separation piece and default skills to be there as a recommendation; same goes for guardrails".
Design gate: the spec above is the approved design; no brainstorm run. `bin/decompose` run for the skeleton (generic: manifest, lock lib, tiers, consent lib); this plan enriches it with the repo inventory below and replaces its "skills tiers" idea (trust tiers for skills) with the two tier systems the operator actually asked for (skill `recommended` vs guardrail `core`/`recommended`).
Builds on `main` @ 63a1a82a. No version bump, no release, no tag: operator reviews `docs/GTM-2.4.x.md` first. CHANGELOG gets an `[Unreleased]` entry only.

## Interpretation (stated so the operator can correct it)

1. **3.0.0 scope (spec §12 row):** ONE `skills.manifest.json` for the three overlapping mechanisms (`heimdall-skills.json`, `skills-registry.json`, `skills/heimdall/references/plugin-autoinstall.md` + the code that implements it); a Skill Resolver that is a **pass-through** behind flag `skills.registry` (default **off**), proven by a differential parity test against behaviour recorded from the unmodified legacy code; a per-project lockfile `.planning/skills.lock` recording what was installed and **why**; `hmd skills list|why|lock|suggest` (+ `install`, `consent`).
2. **"Default skills as a recommendation":** no skill/plugin install is silent for a NEW install. The manifest marks the old auto-install set `recommended`; hmd surfaces it (first run, session nudge, `hmd skills suggest`) and installs only on consent (prompt), an explicit allowlist, or `--yes`. Every install lands in the lockfile. **Existing users are grandfathered**: same installs, same order, same receipts as today.
3. **"Same for guardrails":** every guardrail is inventoried into `guardrails.manifest.json` with tier `core` (security / correctness gates; fail-closed; **never switchable by any hmd command or config file**) or `recommended` (cost/discipline guards; on by default; listed; individually switchable by one per-operator file via `hmd guardrails list|why|off|on`). **Security gates never become optional.** Anything not positively classified is `core`.

### Deltas against the spec ladder (call out to operator)
- Spec puts the consent model in 3.1.0 and says 3.0.0 has "None" behaviour change. Operator ask pulls consent forward for NEW installs only. Consequence: `goals.yaml` `skills-registry-3-0` guard `install_surface_changed == false` no longer holds for new installs. Heimdall must PROPOSE the goals.yaml amendment as a PR; this plan does not edit it (open decision O1).
- Spec is written against v2.4.7. Repo is **2.4.10**. The 2.4.8 interim fixes already landed: no `|| true`, no third-party marketplace fallback, every install receipted (`bin/lib/install-receipt.sh`, `test/plugin-install-receipt.test.sh`). `git ls-files` shows no tracked `.heimdall/*` runtime state (only two `*.example` files). What is still missing is exactly the consent model (`install-receipt.sh:16-19` says so) and the one-source-of-truth.
- Spec's Stage 0 "skill-selection traces" (Jev) do not exist in this repo. The deterministic selection code is shell/python; "recorded behaviour" here = outputs of the legacy code over a committed input matrix, recorded BEFORE any new code (W0-W1).

---

## Stage 0 — Inventory (read from the tree at 63a1a82a; nothing executed except `bin/decompose`)

### A. Skill / plugin mappings (every row)

**A1. `heimdall-skills.json` (1476 B) — ACTIVATION map, not an install map.** Read by `bin/skill-manager:21` -> `bin/lib/skill_restore.py:201 needed_plugins()` (pause what the project does not need, restore at exit) and by `skill-manager status` (`bin/skill-manager:78`, a SECOND inline copy of the glob logic). Falls back to nonexistent `superx-skills.json` (`bin/skill-manager:21-22`).

| Bucket | Entries (plugin id) |
|---|---|
| `permanent` (2) | `caveman@caveman` (plugin retired in-house 2026-08-30 but still listed), `superpowers@claude-plugins-official` |
| `detection.frontend` | files `*.tsx *.jsx *.vue *.svelte *.css *.scss *.less tailwind.config.* postcss.config.* vite.config.*` -> `frontend-design@claude-plugins-official`, `design-for-ai@rtd` |
| `detection.playwright` | `playwright.config.* cypress.config.* *.spec.ts` -> `playwright@claude-plugins-official` |
| `detection.pr-workflow` | `.github/pull_request_template* .github/workflows/* .github/CODEOWNERS` -> `pr-review-toolkit@claude-plugins-official` |
| `detection.code-review` | `*.ts *.js *.py *.go *.rs *.java *.rb *.sh *.tsx *.jsx` -> `code-review@claude-plugins-official` |
| `detection.security` | `*.ts *.js *.py *.go *.rs *.java` -> `security-guidance@claude-plugins-official` |
| `detection.slack` | `.slack* slack.json slack-*.json` -> `slack@claude-plugins-official` |
| `detection.docs` | `CLAUDE.md AGENTS.md GEMINI.md` -> `claude-md-management@claude-plugins-official` |
| `on_demand` (3) | `skill-creator@`, `claude-code-setup@`, `ralph-loop@` (all `claude-plugins-official`) |

Glob semantics (must be preserved): per pattern, match at project top level, one level deep (`*/pat`), or `src/**/pat` (recursive); first hit wins per rule (`skill_restore.py:201-211`).

**A2. `skills-registry.json` (2782 B, v1.0.0) — GitHub-clone skills, keyword-matched.** Read by THREE readers: `bin/heimdall:4106 discover_skills` (keywords, `\b<kw>\b` on lowered prompt, python inline), `bin/discover-skills` (category match, `find_skills_for_domain`, `cmd_gaps`, `install_skill`), `bin/heimdall:3692` `--skills install` (name lookup).
9 skills: `ui-ux-pro-max` (nextlevelbuilder/ui-ux-pro-max-skill, design), `oh-my-mermaid` (oh-my-mermaid/oh-my-mermaid, documentation), `token-optimizer` (alexgreensh/token-optimizer, optimization), `context-mode` (mksglu/context-mode, optimization), `godogen` (htdt/godogen, gamedev), `claude-obsidian` (AgriciDaniel/claude-obsidian, knowledge), `claude-ads` (AgriciDaniel/claude-ads, marketing), `claude-seo` (AgriciDaniel/claude-seo, marketing), `get-shit-done` (gsd-build/get-shit-done, productivity). No ref, no pin: `hmd_skill_install` clones HEAD (`install-receipt.sh:hmd_skill_install`).

**A3. Prompt/file -> plugin auto-install (implemented in `bin/heimdall:4069 preinstall_plugins`; documented in `plugin-autoinstall.md` table).** All from `claude-plugins-official`. Emission order = code order:

| # | Plugin | Prompt ERE (grep -E on lowered prompt, unanchored substring) | File trigger (after prompt rules) |
|---|---|---|---|
| 1 | `frontend-design` | `react\|vue\|angular\|css\|responsive\|ui\|frontend\|component` | `package.json` containing react/vue/angular/svelte (BRE `\|`) |
| 2 | `devops-toolkit` | `docker\|k8s\|kubernetes\|deploy\|ci.?cd\|pipeline` | `Dockerfile` or `docker-compose.yml` |
| 3 | `database-toolkit` | `sql\|database\|schema\|migration\|prisma\|typeorm` | `prisma/schema.prisma` or `ormconfig.json` |
| 4 | `seo` | `seo\|meta.?tag\|sitemap\|robots.?txt` | - |
| 5 | `security-scanner` | `auth\|jwt\|oauth\|security\|owasp\|vulnerability` | - |
| 6 | `api-design` | `api\|openapi\|swagger\|rest\|graphql` | - |
| 7 | `slack` | `slack\|notification\|webhook` | - |
| 8 | `mcp-server-dev` | `mcp\|tool.?server\|model.?context` | - |

`plugin-autoinstall.md` additionally holds a mid-task signal table (9 rows, same 8 plugins) and the install rules; it is LLM-read prose (`agents/heimdall.md:136`) and is also mirrored as a hard-coded string in the launcher's injected prompt (`bin/heimdall:4806-4812`: React/Docker/SQL -> three `claude plugins install ...` lines + `discover-skills` instructions).

**A4. Hard-coded first-run installs (`bin/heimdall:1245 first_run_setup`, lines 1269-1303):** `superpowers@claude-plugins-official` (if absent), marketplace `heimdall-marketplace` (`randomittin/heimdall-marketplace`). `caveman` and `claude-mem` are NOT installed (retired; `install.sh:680,720` actively remove).

**A5. Listed marketplaces (`install-receipt.sh:hmd_marketplace_source`):** `claude-plugins-official` = `anthropics/claude-plugins-official`, `heimdall-marketplace` = `randomittin/heimdall-marketplace`. Whole allow-list; anything else is refused without invoking `claude`.

**A6. Bundled skills (`skills/*/SKILL.md`, 6):** `heimdall`, `designmatch` (own `package.json`), `stacks` (+ packs `fastapi nextjs react-native spring-boot` as `PACK.md`, detected by `bin/stack-detect`), `self-improve`, `system-health`, `mac-deep-clean`. In-tree, always present; the manifest lists them `tier: bundled`, never installed, never moved in M1.

**A7. Bootstrap (not a skill decision):** `install.sh:941 install_hmd_plugin` + `install.sh:1240` marketplace add for hmd itself. Receipted; stays outside the manifest and outside consent (the operator ran the installer).

**A8. Scan-only:** `bin/detect-skills` lists installed skills; no mapping.

### B. Install call sites (what the consent model must gate)

| # | Site | Trigger | Silent today? | Receipted? |
|---|---|---|---|---|
| B1 | `bin/heimdall:1273` `first_run_setup` superpowers | marker `$HEIMDALL_HOME/setup-done` absent (`bin/heimdall:79`) | yes | yes |
| B2 | `bin/heimdall:1296` marketplace add `heimdall-marketplace` | same | yes | yes |
| B3 | `bin/heimdall:4080` `preinstall_plugins` -> `hmd_install_known_plugin` | first run only (`bin/heimdall:4189`) | yes | yes |
| B4 | `bin/heimdall:4141` `discover_skills` -> `hmd_skill_install` | first run only (`bin/heimdall:4191`) | yes | yes |
| B5 | LLM instruction `agents/heimdall.md:136` + `plugin-autoinstall.md` + `bin/heimdall:4806-4812` | any session, mid-task | yes (agent runs `claude plugins install`) | agent-dependent |
| B6 | `bin/discover-skills:104` `install` (agents call it mid-session) | explicit command | n/a | yes |
| B7 | `bin/heimdall:3726` `--skills install` raw `git clone` | explicit user command | n/a | **no receipt** (gap; M1 routes it through the same helper) |
| B8 | `install.sh:945`, `:1240` | the installer itself | n/a | yes |

Only B1-B5 are "default installs". B3/B4 run on first run only, so for an existing user (marker present) the only live default-install path is B5 (agent prose) and `--setup` (`bin/heimdall:3416`).

### C. Hidden couplings and quirks that parity MUST preserve (record, do not fix)

1. Two copies of the detection glob logic: `skill_restore.py:201` and inline python in `skill-manager cmd_status`.
2. Three readers of `skills-registry.json` with three different matchers (word-boundary keyword; category; name).
3. `preinstall_plugins` prompt matching is **unanchored substring**: `ui` fires on "build"/"quick"/"guide", `api` on "rapid", `rest` on "forest"/"interest", `ci.?cd` on "cicd". Recorded as-is; fixing is a later, separate behaviour change.
4. `_try_install` checks the installed list captured ONCE at function start (`bin/heimdall:4071`), not after each install: one plugin can be attempted twice (prompt rule + file rule, e.g. `frontend-design`). Order and duplicates are part of the baseline.
5. `A || B && C` precedence in the Docker/Prisma file triggers is `(A||B)&&C`.
6. `permanent` still lists `caveman@caveman`; `detection.frontend` lists `design-for-ai@rtd`: two marketplaces (`caveman`, `rtd`) that are not in the A5 allow-list. They are activation-only (hmd never installs them). Manifest records `install: false`.
7. `skill-manager` set semantics: `needed_plugins` returns a set; parity compares sorted lists.
8. Tests that pin legacy files today: `test/plugin-install-receipt.test.sh` (copies `skills-registry.json`, runs real launcher; section C pins the 8 plugins), `test/skill-manager-restore.test.sh` (copies `heimdall-skills.json`), `test/heimdall-hmd-bootstrap.test.sh`. Legacy files therefore stay in the tree and stay authoritative while the flag is off.
9. Existing per-process operator overrides are env vars read from the hook's own environment (not config files). Same convention reused.

### D. Guardrail inventory

**D1. Hooks.** `hooks/hooks.json` has 50 matcher groups; `hooks/hooks.metadata.json` (sidecar, `bin/heimdall-hooks regen` is its only writer) already gives each an `id`, `fingerprint`, `locked`, `remote_toggle`. A per-hook kill switch **already exists**: `bin/heimdall-hooks disable|enable|list|check` + `$HEIMDALL_HOME/hooks-disabled` + `bin/lib/hook-enabled.sh` (fails toward enabled; locked ids always enabled even if the file is hand-edited). **M1 does not reinvent this.** `guardrails.manifest.json` maps `locked:true -> core`, `locked:false -> recommended` (guards) or `feature` (not a guardrail), and `hmd guardrails` delegates hook rows to `heimdall-hooks`.

| Tier | Hook ids (from `hooks.metadata.json`) |
|---|---|
| **core (8, locked)** | `secret-paste-filter`, `bash-gate-chain`, `agent-precheck`, `stub-gate`, `secret-read-guard`, `lintconfig-guard`, `edit-tracker`, `claude-mem-scrub` |
| recommended / `kind: guard` (advisory, non-locked) | `parallel-gate`, `parallelism-tracker-read`, `edit-claim-prewarn`, `phone-deny`, `settings-guard`, `volatile-repo-guard`, `stop-claim-check`, `stop-lint` |
| `kind: feature` (non-locked, not a guardrail; stays under `hmd hooks`) | the other 34: `ctx-meter-notice caveman-level-context inbox-deliver-prompt phone-control-prompt inbox-deliver-pretool phone-control-pretool corpus-capture context-sync journal-commit inbox-deliver-posttool phone-control-posttool session-bootstrap resume-probe maintain-resume-hint quota-resume-hint dream-notice presence-keeper-start presence-connect-prompt ai-select caveman-rules pair-window-start inbox-wake-register inbox-wake-arm-start continue-inject subagent-metric subagent-429-detect stop-metric-reminder stop-429-detect inbox-deliver-stop inbox-wake-arm-stop presence-keeper-stop session-end-sweep pair-window-stop precompact-checkpoint` |

M1 changes no existing `locked` decision (principle: the sidecar's operator-approved split stands).

**D2. Sub-guards inside locked hooks.** These are the real gap: the cost/discipline guards live INSIDE the locked `bash-gate-chain` / `agent-precheck`, so `heimdall-hooks` cannot touch them individually, and each has only a bespoke per-process env override.

| Guard id (new) | Where | Behaviour | Existing override (unchanged) | Proof suite | Tier |
|---|---|---|---|---|---|
| `ci-waste-guard` | `bin/heimdall-precheck-bash` delta 6, `bin/lib/hmd_ci_guard.py` | denies `--allow-empty`, `gh run rerun`, etc.; fails open | `HMD_CI_RERUN_ALLOW=1` | `test/ci-waste-guard.test.sh` | recommended |
| `disk-floor` | precheck-bash delta 5 + precheck-agent fence (`:90-123`), `bin/lib/hmd_disk_floor.sh` | denies test runs / spawns under 10% free; fails open | `HMD_MIN_FREE_PCT=<n>` (0 = off) | `test/disk-floor.test.sh` | recommended (hooks only; `run-all.sh` keeps its own absolute floor) |
| `sweep-guard` | precheck-bash delta 7, `bin/lib/hmd_sweep_guard.py` | denies redundant full sweeps; fails open | `HMD_SWEEP_ALLOW=1` | `test/sweep-guard.test.sh` | recommended |
| `wait-guard` | precheck-bash delta 8, `bin/lib/hmd_wait_guard.py` | denies foreground poll loops; fails open | `HMD_WAIT_ALLOW=1` | `test/wait-guard.test.sh` | recommended |
| `parallelism-check-bash` | tail of precheck-bash (`parallelism-tracker check Bash`) | advisory, `|| true` | - | `test/heimdall-precheck-bash.test.sh` | recommended |
| `named-agent-notice` | precheck-agent `:74` | stderr notice | `HEIMDALL_ALLOW_NAMED_AGENT=1` | agent-name tests | recommended |
| `context-gate` | precheck-agent `:496-590` | refuses spawn past ceiling at clean boundary | `HMD_CTX_GATE_OFF=1` | `test/agent-name-gate.test.sh` | recommended |
| `fix-chain-advisory` | precheck-agent `:592-635` | warning | `HMD_FIX_CHAIN_ALLOW=1` | `test/agent-fix-chain.test.sh` | recommended |
| `gp-agent-rules` | precheck-agent `:637-673` | general-purpose agent rules | `HMD_GP_RULES_OFF=1` | `test/gp-agent-rules.test.sh` | recommended |
| `kill-guard` | precheck-bash, `bin/lib/hmd_kill_guard.py`; fails CLOSED | denies pkill/killall by name | `HMD_KILL_GUARD=off` | `test/hmd-server-kill-guard.test.sh` | **core** (open decision O4) |
| `git-guard`, `commit-secret-scan`, `push-quality-gate`, `push-secret-scan`, `push-selfscan`, `oracle-falsifiability-gate`, `corpus-regression-gate` | precheck-bash | the push/commit gate stack | `HMD_SKIP` only moves the native hook dedup; no bypass | `test/heimdall-precheck-bash.test.sh`, `test/pre-push-gate-dedup.test.sh` | **core** |
| `brief-adoption-gate` | precheck-agent `:675` | rewrites oversized spawn prompts | `HEIMDALL_ALLOW_LONG_BRIEF=1`, word threshold env | brief tests | **core** (hook is locked) |
| `agent-concurrency-cap`, `adjudication-fallback-fence`, `coop-native-spawn-refusal` | precheck-agent `:125-494` | not classified in this pass | various | existing | **core, provisional** (rule: unclassified => core; open decision O5) |

**D3. Outside hooks.json (all core, inventoried for completeness):** native git hooks emitted by `bin/heimdall-init` (`.heimdall/hooks/pre-commit`, `pre-push`, `prepare-commit-msg`; the trailer one is bookkeeping, fails open), `bin/heimdall-lintconfig-guard` (operator override `HMD_ALLOW_LINTCONFIG_EDIT=1`), `bin/secret-read-guard`, `bin/heimdall-secret-filter`, `bin/heimdall-repo-checks` (push gate per-repo), `bin/heimdall-state check-quality-gates`, `bin/heimdall-selfscan`, `bin/falsify`, `bin/corpus`. `bin/heimdall-conformance` is an audit tool, not a runtime guard. `test/lib/run-all-guards.sh` (sweep preflight) shares the disk floor definition but is not a hook; it keeps its own knobs.

**Why core overrides stay env-only:** a core guard may keep today's documented per-process operator override (it already exists, it is read from the hook's own environment, an agent cannot reach it by typing it in a command). M1 adds NO persistent, file-based way to weaken a core guard.

---

## Target formats

Format choice: JSON, stdlib python parsers (no yaml dependency; repo already ships JSON configs and `bin/lib/*.py` stdlib modules). Schemas under `docs/schemas/` (precedent: `runhmd.receipt.v1.json`).

### `skills.manifest.json` (repo root; replaces the three mechanisms; envelope `skills-registry`)
```json
{
  "schema": 1,
  "marketplaces": {
    "claude-plugins-official": {"source": "anthropics/claude-plugins-official", "pin": null},
    "heimdall-marketplace":    {"source": "randomittin/heimdall-marketplace",   "pin": null}
  },
  "entries": [
    {
      "id": "frontend-design",
      "kind": "plugin",                      // plugin | github-skill | bundled
      "ref": "frontend-design@claude-plugins-official",
      "marketplace": "claude-plugins-official",
      "install": true,                       // false = activation-only (caveman@caveman, design-for-ai@rtd)
      "tier": "recommended",                 // bundled | recommended | detected | on_demand | community(reserved, never auto-suggested)
      "why": "UI/frontend work gets design guidance",
      "activate": {"permanent": false, "detect": ["frontend"]},
      "triggers": {
        "prompt_ere": "react|vue|angular|css|responsive|ui|frontend|component",
        "files": [{"path": "package.json", "contains_any": ["react","vue","angular","svelte"]}],
        "order": 1
      },
      "legacy": [{"mechanism": "heimdall-skills.json", "path": "detection.frontend"},
                 {"mechanism": "plugin-autoinstall.md", "path": "table row 1"},
                 {"mechanism": "bin/heimdall:preinstall_plugins", "path": "rule 1"}]
    }
  ],
  "detection_rules": {                       // verbatim from heimdall-skills.json: rule -> {files[], entries[]}
    "frontend": {"files": ["*.tsx","*.jsx"], "entries": ["frontend-design","design-for-ai"]}
  },
  "keyword_skills": []                       // github-skill entries carry keywords[], category, repo, description verbatim
}
```
Rules: every legacy mapping appears once with a `legacy[]` pointer; no entry without one in M1; prompt regexes are stored verbatim (ERE; Python `re` evaluates them, parity-tested); marketplaces table must equal `hmd_marketplace_source()` (tested).

### `guardrails.manifest.json` (repo root; sibling, NOT merged into the skills manifest)
Why sibling: `goals.yaml` gives the skills manifest to envelope `skills-registry` and anything under hooks/gates to envelope `verifier` ("always human; never auto"). One file would force every skill recommendation edit through the verifier envelope. The manifest is descriptive (like `hooks.metadata.json`); only W6 touches enforcement code.
```json
{
  "schema": 1,
  "guardrails": [
    {"id": "ci-waste-guard", "kind": "guard", "tier": "recommended", "layer": "precheck-bash",
     "hook": "bash-gate-chain", "fails": "open", "operator_env": "HMD_CI_RERUN_ALLOW=1",
     "proof": "test/ci-waste-guard.test.sh", "why": "never pay CI minutes to re-roll a flaky result"},
    {"id": "push-secret-scan", "kind": "guard", "tier": "core", "layer": "precheck-bash",
     "hook": "bash-gate-chain", "fails": "closed", "operator_env": null,
     "proof": "test/heimdall-precheck-bash.test.sh", "why": "no secret leaves in a push"},
    {"id": "stop-lint", "kind": "guard", "tier": "recommended", "layer": "hook", "hook": "stop-lint", "...": "..."}
  ]
}
```
Hook rows reference `hooks.metadata.json` ids. Drift test: every metadata id has exactly one row; `locked:true` => `tier:core`; every `operator_env` var name is grep-able in the named script; unknown/absent classification => core.

### `.planning/skills.lock` (per project, JSON, committed) and `$HEIMDALL_HOME/skills.lock` (machine scope)
```json
{
  "schema": 1,
  "manifest_sha256": "<sha256 of skills.manifest.json at write time>",
  "entries": [
    {"id": "frontend-design", "kind": "plugin", "ref": "frontend-design@claude-plugins-official",
     "state": "installed",                  // installed | suggested | declined | failed | adopted
     "version": "5.0.7", "source": "anthropics/claude-plugins-official", "pin": "none",
     "content_hash": null,                  // git skills: commit sha; plugins: null in M1 (CLI exposes no hash)
     "consent": "prompt",                   // auto-legacy | prompt | allowlist | yes-flag | explicit | n/a
     "at": "2026-11-12T10:00:00Z",
     "why": {"entry": "frontend-design", "rule": "prompt_ere", "evidence": "react", "via": "prompt-preinstall", "run": "<HMD_RUN_ID>"}}
  ]
}
```
Rules: append-only per (id, scope) except `state` transitions; `evidence` is the matched token or file path only, max 64 chars, **never prompt text** (the file is git-committed). Plugins and git skills are installed at user level, so the project lock records "this project triggered / needs it" and the machine lock holds first-run rows (superpowers, marketplace). `hmd skills why <id>` merges both. The install receipt (`~/.heimdall/receipts/installs-<run>.ndjson`) is unchanged and remains the per-run attempt log; the lock is the durable "what and why".

### Config `$HEIMDALL_HOME/skills-config.json` (per operator; follows the `HEIMDALL_HOME/*.json` convention)
`{"registry": "off", "consent": "ask", "allowlist": [], "grandfathered": false}`. Precedence: env `HMD_SKILLS_REGISTRY=on|off` / `HMD_SKILLS_CONSENT=ask|allowlist|auto` > file > default. Repo files can never set these (a cloned repo must not choose its operator's consent mode).
Grandfather rule, evaluated once on first run of the new code: setup marker present and no config file => write `consent: auto, grandfathered: true` (today's behaviour). Marker absent => `consent: ask`.

### Guardrail switch `$HEIMDALL_HOME/guardrails-off`
One id per line, per operator, never in the repo (same shape and location convention as `hooks-disabled`). Read by `bin/lib/hmd_guardrail_enabled.sh <id>`: returns 1 (disabled) iff listed AND the manifest says `recommended`; every other outcome (no file, no jq, bad manifest, core, unknown id) returns 0 = enabled. Fails toward enabled.

---

## Resolver design (pass-through)

`bin/lib/skills_resolver.py`, stdlib, read-only. It answers the questions the legacy code answers inline, from the manifest, in the same shape:

| Subcommand | Replaces | Output (byte-compatible with legacy) |
|---|---|---|
| `activate-set --manifest M --project D` | `skill_restore.needed_plugins` | sorted plugin ids (set semantics) |
| `status --manifest M --project D --settings S` | `skill-manager cmd_status` inline python | same text block |
| `preinstall --manifest M --prompt-file P --project D` | `preinstall_plugins` matching | plugin names, one per line, code order, duplicates kept |
| `keyword-match --manifest M --prompt-file P` | `discover_skills` inline python | `name\|repo` lines, registry order |
| `domain-skills --manifest M --domain X` / `gaps` / `detect-file` | `bin/discover-skills` readers | same lines |

Pass-through means: the resolver never installs. Call sites keep their install mechanics (`hmd_install_known_plugin`, `hmd_skill_install`, receipts). With `skills.registry=off` (default) call sites run the legacy inline code unchanged and never invoke the resolver. With `=on` they take the resolver's answer. Default-on and deletion/generation of the legacy files are the NEXT cycle (spec: after a week of clean parity); in M1 the three legacy mechanisms stay authoritative (goal metric `legacy_skill_mechanisms_authoritative` stays 3 until then; this plan does not claim otherwise).

### Parity test design (differential, independent reference)
- **Reference = legacy code run unmodified.** `test/lib/skills_baseline_record.sh` extracts the real functions (`sed -n '/^preinstall_plugins()/,/^}/p' bin/heimdall`, the pattern at `test/plugin-install-receipt.test.sh:178-181`), runs real `bin/skill-manager` and `bin/discover-skills` against fixture HOME/project dirs with PATH fakes for `claude`/`git` (pattern `test/plugin-install-receipt.test.sh:50-125`), and writes `test/fixtures/skills-baseline/golden.json` with a header of tool versions (grep/python).
- **Input matrix** (`inputs.json`, >= 150 cases): every alternation token of the 8 prompt regexes; the quirk probes of C3; negatives; multi-domain prompts (order + duplicate probes of C4); case variants; every keyword of the 9 registry skills with word-boundary edge cases (`tokenizer` must not match `token`); project fixtures for every file trigger and every detection rule at top level / one level deep / `src/**` / absent; settings.json `enabledPlugins` states; ext->domain and content-pattern probes for `discover-skills`; `gaps` with 0, some, all installed.
- **Gate:** `test/skills-resolver-parity.test.sh` asserts resolver output == golden for every case (whole-output equality, order and duplicates included; not per-element validity).
- **Independence:** recorder + golden (W0/W1) are authored by different agents than the resolver (W2) and the mutant suite (W3); golden is committed before the resolver exists (test asserts `git merge-base --is-ancestor`).
- **Falsifiable:** `test/skills-resolver-mutants.test.sh` copies the manifest and injects defects (drop a keyword, swap a plugin, change a regex alternation, drop a detection glob, reorder two rules, drop a `src/**` glob, change a marketplace) and requires the parity test to go RED for EVERY mutant while it is GREEN on the unmutated manifest (score 1.0).
- **Not tautological:** parity compares against recorded legacy output, never against the manifest it just read.

### Oracle gate (protocol fields)
- Registry domain: **none matches** (`jq -r '.oracles|keys[]' evals/oracles/registry.json`: attack, ponytail-underdelivery, rr-multitenant-isolation, team-copilot, team-checkpoint, issue-collection, emulator-gb, exchange-lob, symbol-reuse, triage-coord). Flag for reviewer: consider adding a `skills-selection-parity` domain next cycle; not added here (OUT OF SCOPE).
- `gate_type`: **differential** (recorded legacy output vs resolver, whole-output). Not stateful/concurrent: no seeded-interleaving requirement.
- `independent: true`; reference author = baseline recorder agent (T0.1, T1.2), distinct from resolver author (T2.1) and mutant author (T3.4), each in its own wave with disjoint files.
- Falsifiability: `bash test/skills-resolver-mutants.test.sh` (all mutants RED, score 1.0). `bin/falsify <domain>` is not applicable without a registry domain.
- Consent/grandfather gate (T5.1): differential of the install call log (fake `claude`/`git`) between marker-present run and the recorded legacy golden; marker-absent run must show zero install calls.

---

## Consent model (NEW installs only)

Modes (`skills-config.json` `consent`): `ask` (default for new installs), `allowlist`, `auto` (grandfathered, today's behaviour).

| Situation | `ask` | `allowlist` | `auto` |
|---|---|---|---|
| First run, interactive (tty) | ONE batch prompt (reuse `bin/lib/select.sh` `hmd_select`): list recommended set with source + why, choose all / select / none | listed ids install, others prompted | install as today |
| Non-interactive / mid-task / agent | do NOT install; lock row `state: suggested`; one stderr line "N recommended skills available: hmd skills suggest" | listed ids install, others suggested | install as today |
| `hmd skills install <id>` | tty: show plan, confirm. non-tty without `--yes`: exit 3 "consent required" (so an agent relays the question to the human) | same | install |
| `hmd skills install <id> --yes` | installs, `consent: yes-flag` | same | same |

Every install, whatever the path, writes the receipt (already) and a lock row with `consent` and `why`. Declines are recorded (`declined`) and not re-prompted until `hmd skills suggest --reset`.
Residual risk, said plainly: consent is **cooperative** for agent-typed raw `claude plugins install ...`; the Bash hook does not (in M1) deny it. The instruction text (T5.3) routes agents through `hmd skills install`, whose exit code carries the consent decision. A hook-level denial would be a new core guardrail in the verifier envelope: separate proposal.

## CLI surface

`hmd skills` (arm in `bin/heimdall`, pass-through to `bin/heimdall-skills`, same pattern as the `hooks)` arm at `bin/heimdall:2604-2617`). The existing `hmd --skills install|search|update|remove` (`bin/heimdall:3692`) keeps working; `--skills install` is routed through the receipted helper.

| Command | Behaviour |
|---|---|
| `hmd skills list [--json]` | manifest entries x state: tier, installed?, source, pin, consent, lock state; flags `registry`/`consent` mode |
| `hmd skills why <id>` | the lock row's `why` + the manifest entry's `legacy[]` + receipt lines; exit 1 if the id has no lock row and is installed (goal metric: 100% explained) |
| `hmd skills lock [--verify]` | (re)build the lock from `claude plugins list --json` + `~/.claude/skills` + receipts; pre-existing installs become `state: adopted`, `consent: auto-legacy`, `why.rule: adopted`; `--verify` reports drift (version/hash) without writing |
| `hmd skills suggest [--reset]` | manifest-driven in M1: `recommended` not installed + `detected` entries whose triggers fire in this project; prints, never installs. (Evidence/replay-ranked suggestions are 3.2.) |
| `hmd skills install <id\|--recommended> [--yes]` | the single consented install path |
| `hmd skills consent [ask\|allowlist\|auto]` / `allow <id>` | read/write `skills-config.json` |

`hmd guardrails list [--json] | why <id> | off <id> | on <id>`: `list` shows id, tier, kind, state (core: `always on`); `off` on a `core` id exits 2 with the reason and writes nothing; `off` on a hook row delegates to `heimdall-hooks disable`; `off` on a sub-guard writes `guardrails-off`.

## Guardrail tiers: enforcement rules (invariant ledger, wave-0 artifact — read first by every task)

**Skills**
- INV-S1 flag off => legacy code path runs; resolver is never invoked (call log).
- INV-S2 flag on => for every matrix input, resolver output == golden, byte for byte, order and duplicates included.
- INV-S3 golden is committed before the resolver and recorded from unmodified legacy code.
- INV-S4 every legacy mapping appears exactly once in the manifest with a `legacy[]` pointer; no manifest entry lacks one.
- INV-S5 `marketplaces` == `hmd_marketplace_source()`; an unlisted marketplace is never passed to `claude`.
- INV-S6 every `installed` receipt line has a lock row with `why`; `hmd skills why <id>` resolves 100% of lock rows.
- INV-S7 grandfathered (marker present, no config at first run) => `consent=auto` => install call log identical to legacy.
- INV-S8 new install (marker absent) => zero install calls before consent; deferred items are `suggested` rows.
- INV-S9 `community`-tier entries are never auto-suggested (none exist in M1).
- INV-S10 lock `evidence` is a matched token or path <= 64 chars; never prompt text.
- INV-S11 repo files cannot set `registry`/`consent`/`allowlist` (operator file or env only).

**Guardrails**
- INV-G1 no `hmd guardrails` command, no edit to `guardrails-off`, no env var introduced by M1 can disable a `core` guard. `hmd_guardrail_enabled` returns 0 for core regardless of file contents.
- INV-G2 default state (no `guardrails-off`) => every guard behaves exactly as today (existing suites unchanged and green).
- INV-G3 turning one `recommended` guard off changes only that guard.
- INV-G4 manifest covers 100% of `hooks.metadata.json` ids; `locked:true` => `core`; unclassified => `core`.
- INV-G5 every failure of the enabled-check (missing file/jq/manifest, parse error) => guard stays ENABLED.
- INV-G6 existing operator env overrides keep their exact semantics.
- INV-G7 `guardrails-off` is per operator under `$HEIMDALL_HOME`; a repository cannot disable a guard for its clones.
- INV-G8 `disk-floor` switch covers the Bash and Agent hooks only; `test/run-all.sh` keeps its own floor.

### Coverage matrix

| Subsystem | In scope? | Oracle row | Expected result |
|---|---|---|---|
| Prompt -> plugin selection (`preinstall_plugins`) | yes | parity: preinstall cases | green |
| Prompt -> github skill (`discover_skills`) | yes | parity: keyword cases | green |
| Activation set + `skill-manager status` | yes | parity: activate/status cases | green |
| `bin/discover-skills` detect/gaps/domain | yes | parity: discover cases | green |
| First-run installs (superpowers, marketplace) consent | yes | T5.1 call-log differential | green |
| Grandfathered existing user | yes | T5.1 marker-present vs golden | green |
| Mid-task LLM selection (`agents/heimdall.md`, mid-task table) | **descoped** (prose, not machine-comparable) | T5.3 render/consistency test only | expected: no behavioural oracle; residual risk R5 |
| `hmd --skills update/remove/search` | descoped (unchanged) | existing suites | unchanged |
| `install.sh` hmd bootstrap | descoped | `test/plugin-install-receipt.test.sh` F | unchanged |
| Stack packs, extraction to `@runhmd/*`, overlays, signing | descoped (3.1+) | - | n/a |
| Guard switches: ci-waste, disk-floor, sweep, wait, named-agent, ctx-gate, fix-chain, gp-rules, parallelism-check | yes | T6.1/T6.2 off-tests + existing proof suites | green |
| Core guards | yes (must stay on) | INV-G1 tests in T2.2, T3.6, T6.1 | green |
| precheck-agent concurrency cap / fallback fence / coop refusal | provisional core, no switch | existing suites | unchanged |

---

## Waves (disjoint file sets within each wave; each task <= 3 files, 1 concern)

Conventions for every task: Agent `hmd:coder`, model `sonnet` + `default` unless stated. Each task writes real code (no stubs/TODO), TDD: write its named test first, watch it RED, implement, run `bash test/<own>.test.sh` ONCE (own suite only; no neighbour suites; full sweep is the last step). Read first for all tasks: this plan sections "Stage 0" and "invariant ledger". Skills: `superpowers:test-driven-development`. House style exemplars: `bin/lib/skill_restore.py` (stdlib python module with docstring + `main(argv)`), `bin/lib/hook-enabled.sh` (sourceable fail-toward-enabled lib), `test/plugin-install-receipt.test.sh` (hermetic harness with PATH fakes, `ok`/`bad`, exit 0/1). Commit per task (atomic), message `<type>(skills): ...` / `(guardrails)`, hmd trailer added by the git hook. Tests are hermetic: throwaway HOME/HEIMDALL_HOME, fakes for `claude`/`git`, no network.

### Wave 0 — contracts and baseline recorder (5 parallel tasks, no behaviour change)

**T0.1 baseline-recorder** (independent reference author)
- Deps: none. Read first: `bin/heimdall:4069-4142`, `bin/skill-manager`, `bin/lib/skill_restore.py:201-250`, `bin/discover-skills`, `test/plugin-install-receipt.test.sh:50-200`.
- Files: Create `test/lib/skills_baseline_record.sh`, `test/fixtures/skills-baseline/inputs.json`, `test/skills-baseline-determinism.test.sh`.
- Spec: `record <out.json>` runs the unmodified legacy code over `inputs.json` (matrix as in "Parity test design") and writes normalised results: preinstall = ordered install attempts (from the fake `claude` call log), keyword-match = ordered `name|repo`, activate = sorted needed set + `skill-manager status` text, discover-skills outputs. Header records `grep --version`, `python3 --version`, `uname`.
- Acceptance: `test -x test/lib/skills_baseline_record.sh`; `python3 -c "import json;d=json.load(open('test/fixtures/skills-baseline/inputs.json'));assert sum(len(v) for v in d['cases'].values())>=150"`; `bash test/skills-baseline-determinism.test.sh` exits 0 (records twice into temp files, byte-identical; also asserts quirk probes present: a prompt containing "build" yields `frontend-design`, a prompt hitting both prompt and file rules yields a duplicate `frontend-design`).
- Verify: `bash test/skills-baseline-determinism.test.sh`. Done when: recorder deterministic over the legacy tree. Risk: platform grep drift -> header tool versions; golden only compared on same-major grep (T1.2 records the caveat).

**T0.2 skills-config**
- Deps: none. Read first: `bin/lib/hook-enabled.sh`, `bin/heimdall:79,119` (marker). Files: Create `bin/lib/skills_config.py`, `test/skills-config.test.sh`.
- Spec: `get <key>`, `set <key> <value>`, `init --marker-present|--marker-absent` (grandfather rule), precedence env > file > default, atomic write, mode 0600, unknown value -> stderr + default (never fatal), file never read from the repo.
- Acceptance: `python3 -I bin/lib/skills_config.py get registry` prints `off` on empty HEIMDALL_HOME (asserted in test); `HMD_SKILLS_REGISTRY=on` flips it; `init --marker-present` writes `consent auto, grandfathered true`; `init --marker-absent` writes `consent ask`; `bash test/skills-config.test.sh` exits 0 (includes INV-S11: a `skills-config.json` placed in a project dir is ignored).
- Verify: `bash test/skills-config.test.sh`.

**T0.3 skills-manifest-validator**
- Deps: none. Files: Create `bin/lib/skills_manifest.py`, `docs/schemas/skills.manifest.v1.json`, `test/skills-manifest-schema.test.sh`.
- Spec: `load()`, `validate()`, CLI `python3 -I bin/lib/skills_manifest.py validate FILE` (exit 0/1 + reasons). Fails closed on malformed input. Checks: schema=1; `tier` in enum; `install:true` => marketplace key exists in `marketplaces`; every entry has non-empty `legacy[]`; `prompt_ere` compiles; `community` entries must have `install:false`-or-explicit-consent flag.
- Acceptance: test builds a valid fixture (exit 0) and 8 corrupted copies, each exit 1 naming the reason; `grep -q '"schema"' docs/schemas/skills.manifest.v1.json`; `bash test/skills-manifest-schema.test.sh` exits 0.
- Verify: `bash test/skills-manifest-schema.test.sh`.

**T0.4 skills-lock-lib**
- Deps: none. Files: Create `bin/lib/skills_lock.py`, `docs/schemas/skills.lock.v1.json`, `test/skills-lock.test.sh`.
- Spec: `record --scope project|machine ...`, `read`, `verify`, atomic tmp+rename, deterministic key order, append-only per (id, scope) with state transitions, evidence length cap 64 + control chars stripped (INV-S10), concurrent writers safe (advisory lock, as `skill_restore.py` `locked()`), project path `<WORK_DIR>/.planning/skills.lock`, machine path `$HEIMDALL_HOME/skills.lock`, fail-open for callers via exit code only (never raises into a launcher).
- Acceptance: `bash test/skills-lock.test.sh` exits 0 covering: write+read roundtrip, 20 parallel `record` calls leave valid JSON, evidence of 500 chars is truncated to 64, a prompt-shaped string is never stored (api: `record` takes `--evidence` only), corrupted file -> exit 1 not traceback.
- Verify: `bash test/skills-lock.test.sh`.

**T0.5 guardrails-validator**
- Deps: none. Files: Create `bin/lib/guardrails_manifest.py`, `docs/schemas/guardrails.manifest.v1.json`, `test/guardrails-manifest-schema.test.sh`.
- Spec: `validate FILE [--hooks-metadata PATH]`: schema=1; tier enum `core|recommended`; `kind` enum `guard|feature`; `fails` is informational only. Reject rules: unknown tier; a row whose hook is `locked:true` with `tier:recommended`; duplicate ids; a `guard` with no `proof`.
- Acceptance: `bash test/guardrails-manifest-schema.test.sh` exits 0 (valid fixture + 6 corrupted copies each rejected with reason).
- Verify: `bash test/guardrails-manifest-schema.test.sh`.

### Wave 1 — transcription and golden (3 parallel tasks; deps: W0)

**T1.1 skills-manifest-transcription** (deps T0.3)
- Files: Create `skills.manifest.json`, `test/skills-manifest-transcription.test.sh`.
- Spec: transcribe A1-A6 verbatim (13 plugin ids from `heimdall-skills.json`, 8 preinstall rows with their EXACT ERE strings and file triggers and order, 9 github skills with keywords/category/repo/description, 2 first-run, 6 bundled). Tiers: first-run pair + the 8 preinstall plugins = `recommended`; detection-only plugins = `detected`; `on_demand` = `on_demand`; 9 github skills = `detected` (they were keyword-installed); `caveman@caveman` and `design-for-ai@rtd` = `install:false`. Do NOT edit any legacy file.
- Acceptance: `python3 -I bin/lib/skills_manifest.py validate skills.manifest.json` exits 0; `bash test/skills-manifest-transcription.test.sh` exits 0 (derives expected counts from the legacy files at test time: every plugin id of `heimdall-skills.json`, every `skills-registry.json` name/repo/keywords, every `case` row of `preinstall_plugins` appears exactly once; manifest `marketplaces` == `hmd_marketplace_source` case arms; `git diff --name-only` shows no legacy file changed).
- Verify: `bash test/skills-manifest-transcription.test.sh`. Risk: transcription drift -> the test reads the legacy files, not a copy of their contents.

**T1.2 golden-capture** (deps T0.1; different agent from T0.1 and from T2.1)
- Files: Create `test/fixtures/skills-baseline/golden.json`, `test/skills-baseline-golden.test.sh`.
- Spec: run `bash test/lib/skills_baseline_record.sh record test/fixtures/skills-baseline/golden.json` on the UNMODIFIED legacy tree (assert `git diff --quiet HEAD -- bin heimdall-skills.json skills-registry.json` first); commit golden. Test re-records into a temp file and requires equality with the committed golden (skips with a printed reason, not a pass, if grep major version differs from the header).
- Acceptance: `test -s test/fixtures/skills-baseline/golden.json`; `bash test/skills-baseline-golden.test.sh` exits 0.
- Verify: same. Done when: golden is a committed, reproducible record of legacy behaviour.

**T1.3 guardrails-manifest** (deps T0.5)
- Files: Create `guardrails.manifest.json`, `test/guardrails-manifest-drift.test.sh`.
- Spec: one row per D1 hook (50) and D2/D3 sub-guard, exactly the tiers in the Stage 0 tables (kill-guard core; agent cap/fallback/coop core provisional with `"provisional": true`). Test: validator passes; every `hooks.metadata.json` id has a row; `locked` => core; every `operator_env` variable appears in the named script (`grep -q`); every `proof` file exists.
- Acceptance: `python3 -I bin/lib/guardrails_manifest.py validate guardrails.manifest.json` exits 0; `bash test/guardrails-manifest-drift.test.sh` exits 0; `jq '[.guardrails[]|select(.tier=="core")]|length' guardrails.manifest.json` >= 8.
- Verify: `bash test/guardrails-manifest-drift.test.sh`.

### Wave 2 — resolver and guardrail read-side (2 parallel tasks; deps: W1)

**T2.1 skills-resolver** (deps T1.1, T1.2)
- Files: Create `bin/lib/skills_resolver.py`, `test/skills-resolver-parity.test.sh`.
- Spec: subcommands per "Resolver design". Matching rules copied from observed legacy semantics: prompt lowered; `preinstall` = `re.search` of the stored ERE (unanchored) in code order, then file triggers, duplicates kept; `keyword-match` = `\b`+`re.escape(kw)`+`\b`; `activate-set` = permanent + rules (top level, `*/pat`, `src/**/pat`, first hit per rule). `parity` test runs every golden case through the resolver and requires equality; accepts `--manifest PATH` (used by T3.4).
- Acceptance: `bash test/skills-resolver-parity.test.sh` exits 0; `git merge-base --is-ancestor $(git log --diff-filter=A --format=%H -1 -- test/fixtures/skills-baseline/golden.json) $(git log --diff-filter=A --format=%H -1 -- bin/lib/skills_resolver.py)` exits 0 (golden precedes resolver); `grep -c "claude plugins install" bin/lib/skills_resolver.py` prints 0 (never installs).
- Verify: `bash test/skills-resolver-parity.test.sh`. Risk: ERE vs Python re divergence -> parity matrix covers each alternation token.

**T2.2 guardrail-enabled-lib** (deps T1.3)
- Files: Create `bin/lib/hmd_guardrail_enabled.sh`, `test/guardrail-enabled.test.sh`.
- Spec: sourceable `hmd_guardrail_enabled <id>` modelled on `bin/lib/hook-enabled.sh`: returns 1 only if id listed in `$HEIMDALL_HOME/guardrails-off` AND `jq` shows `tier=="recommended"` for it in `guardrails.manifest.json` (path resolution identical to `_hmd_hook_metadata_path`: override env for tests, `CLAUDE_PLUGIN_ROOT`, own location; never the cwd repo). Everything else returns 0. Fast path: one `[ -f ]` when file absent.
- Acceptance: `bash test/guardrail-enabled.test.sh` exits 0 covering INV-G1 (core id in the file => still enabled), INV-G5 (no jq / bad manifest / missing manifest / unknown id => enabled), recommended id listed => disabled, no file => enabled, and a repo-local `guardrails-off` is ignored (INV-G7).
- Verify: `bash test/guardrail-enabled.test.sh`.

### Wave 3 — flag-gated wiring, mutants, consent lib, guardrails CLI (6 parallel tasks; deps: W2)

**T3.1 launcher-flag-wiring** (deps T2.1, T0.2)
- Files: Modify `bin/heimdall` (`preinstall_plugins` `:4069`, `discover_skills` `:4106` only); Create `test/skills-launcher-flag.test.sh`.
- Spec: at the top of each function, `if [ "$(python3 -I "$PLUGIN_DIR/bin/lib/skills_config.py" get registry 2>/dev/null)" = on ]` then take resolver output, else run the existing code verbatim (do not reformat it). Install mechanics (`hmd_install_known_plugin`, `hmd_skill_install`) untouched.
- Acceptance: `bash test/skills-launcher-flag.test.sh` exits 0: for every golden preinstall/keyword case, flag off and flag on produce identical fake-`claude`/`git` call logs (INV-S1/S2); flag off never executes `skills_resolver.py` (a PATH-fake python wrapper records invocations).
- Verify: same. Risk: touches the 5000-line launcher -> change confined to two function heads; `bash -n bin/heimdall`.

**T3.2 activation-flag-wiring** (deps T2.1, T0.2)
- Files: Modify `bin/skill-manager` (`cmd_status` inline python), `bin/lib/skill_restore.py` (`needed_plugins` call site `:217` only); Create `test/skills-activate-flag.test.sh`.
- Acceptance: `bash test/skills-activate-flag.test.sh` exits 0: activate/restore sets and `status` text identical off vs on across the golden activation cases; with flag off `skill_restore.py` behaves byte-identically (restore file format unchanged).
- Verify: same.

**T3.3 discover-skills-flag-wiring** (deps T2.1, T0.2)
- Files: Modify `bin/discover-skills` (`find_skills_for_domain`, `cmd_gaps`, `cmd_detect_file` readers); Create `test/skills-discover-flag.test.sh`.
- Acceptance: `bash test/skills-discover-flag.test.sh` exits 0 (detect-file / gaps / domain output identical off vs on over golden cases).
- Verify: same.

**T3.4 resolver-mutants** (independent agent; deps T2.1)
- Files: Create `test/skills-resolver-mutants.test.sh`.
- Spec: >= 8 mutants (list in "Parity test design"); for each, copy `skills.manifest.json`, apply the defect with python, run `bash test/skills-resolver-parity.test.sh --manifest <mutant>`, require non-zero; require the unmutated run to exit 0; print `falsifiability score N/N`.
- Acceptance: `bash test/skills-resolver-mutants.test.sh` exits 0 and its output contains `score 8/8` (or N/N for N >= 8): `bash test/skills-resolver-mutants.test.sh | grep -Eq 'score ([0-9]+)/\1'`.
- Verify: same. **This task plus T2.1 is the final correctness gate for the resolver (differential, independent, falsifiable).**

**T3.5 consent-gate-lib** (deps T0.2, T1.1)
- Files: Create `bin/lib/skills_consent.sh`, `test/skills-consent-gate.test.sh`.
- Spec: sourceable `hmd_skills_consent <id> <via>`; returns 0 = install now (mode auto, or allowlisted, or `HMD_SKILLS_YES=1`), 10 = defer (records `suggested` via `skills_lock.py`, prints one stderr line), 11 = user declined (records `declined`). Interactive prompt only when `[ -t 0 ] && [ -t 1 ]`, via `hmd_select` from `bin/lib/select.sh`. Fails toward DEFER on any internal error for a NEW install and toward INSTALL when `consent=auto` is grandfathered (never turns a legacy install into a defer).
- Acceptance: `bash test/skills-consent-gate.test.sh` exits 0: mode x via x tty matrix (tty simulated with `script -q` where available, else the `HMD_SKILLS_ASSUME` test seam documented in the lib header); allowlist hit/miss; declined recorded; unreadable config + grandfathered marker => install; unreadable config + no marker => defer.
- Verify: same.

**T3.6 guardrails-cli** (deps T1.3, T2.2)
- Files: Create `bin/heimdall-guardrails`, `test/heimdall-guardrails-cli.test.sh`.
- Spec: python3 CLI `list [--json] | why <id> | off <id> | on <id>`; reads `guardrails.manifest.json` + `hooks.metadata.json`; hook rows delegate to `bin/heimdall-hooks disable|enable`; sub-guard rows write/remove `$HEIMDALL_HOME/guardrails-off` atomically; `off` on `core` => exit 2, nothing written; unknown id => exit 1; `why` prints tier, rationale, fail mode, operator env, proof suite.
- Acceptance: `bash test/heimdall-guardrails-cli.test.sh` exits 0 (iterates EVERY core id from the manifest: `off` exits 2 and `guardrails-off`/`hooks-disabled` unchanged — INV-G1; `off ci-waste-guard` then `on` roundtrip; `off stop-lint` lands in `hooks-disabled`).
- Verify: same.

### Wave 4 — CLI modules, lock recording, doc renderer (4 parallel tasks; deps: W3)

**T4.1 skills-cli-read** (deps T0.4, T1.1)
- Files: Create `bin/lib/skills_cli_read.py` (`list`, `why`, `lock [--verify]`), `test/skills-cli-read.test.sh`.
- Acceptance: `bash test/skills-cli-read.test.sh` exits 0 (fake `claude plugins list --json`; adoption of pre-existing installs; `why` exits 1 for an installed id without a lock row; `why` resolves 100% of rows in a seeded lock; `lock --verify` names a drifted id).
- Verify: same.

**T4.2 skills-cli-install** (deps T0.2, T0.4, T3.5)
- Files: Create `bin/lib/skills_cli_install.py` (`suggest`, `install`, `consent`, `allow`), `test/skills-cli-install.test.sh`.
- Acceptance: `bash test/skills-cli-install.test.sh` exits 0 (suggest never installs: fake `claude` call log empty; `install <id>` non-tty no `--yes` => exit 3 and no call; with `--yes` => one install via the allow-listed marketplace only + receipt line + lock row `consent: yes-flag`; unlisted marketplace refused; `consent auto` persists; `suggest` output for a fixture project lists detected entries).
- Verify: same.

**T4.3 lock-recording-at-install-sites** (deps T0.4)
- Files: Modify `bin/lib/install-receipt.sh` (after a successful `hmd_plugin_install` / `hmd_skill_install`, call `skills_lock.py record` fail-open; `why` from optional env `HMD_INSTALL_WHY_RULE` / `HMD_INSTALL_WHY_EVIDENCE` set by callers; receipt line format byte-unchanged); Create `test/skills-lock-record.test.sh`.
- Acceptance: `bash test/skills-lock-record.test.sh` exits 0 (receipt line identical to today's for the same fake run; lock row appears with `via`, `version`, `source`; a failing lock write prints one stderr line and the install still returns its own status; INV-S6 count: receipt `ok` lines == lock `installed` rows).
- Verify: same. Risk: `test/plugin-install-receipt.test.sh` pins the receipt format -> receipt code path untouched, lock call appended; the sweep re-runs that suite.

**T4.4 autoinstall-doc-renderer** (deps T1.1)
- Files: Create `bin/lib/skills_render_doc.py`, `test/skills-doc-render.test.sh`.
- Spec: renders the auto-install table and mid-task signal table of `plugin-autoinstall.md` (and the three-line fragment of `bin/heimdall:4806-4812`) from the manifest, between `<!-- BEGIN GENERATED skills.manifest -->` markers, in both `ask` and `auto` flavours.
- Acceptance: `bash test/skills-doc-render.test.sh` exits 0 (renderer output for the current manifest reproduces the 8 table rows of today's `plugin-autoinstall.md` byte for byte; `--check FILE` exits 1 on a stale block).
- Verify: same.

### Wave 5 — consent at call sites, agent instructions (3 parallel tasks; deps: W4)

**T5.1 launcher-consent** (deps T3.1, T3.5, T4.3)
- Files: Modify `bin/heimdall` (`first_run_setup` `:1269-1303`, `preinstall_plugins._try_install`, `discover_skills` loop, injected prompt `:4806-4812`, grandfather `init` at launcher start); Create `test/skills-consent-launcher.test.sh`.
- Spec: each install call becomes `hmd_skills_consent <id> <via> && <existing install call>`; set `HMD_INSTALL_WHY_*` before the call; first-run interactive batch prompt; injected prompt tells the agent to run `hmd skills install <id>` instead of raw `claude plugins install`. Marker present at first run of new code => `skills_config.py init --marker-present`.
- Acceptance: `bash test/skills-consent-launcher.test.sh` exits 0: (a) marker present: fake call log for the golden prompt/project matrix == legacy golden (INV-S7); (b) marker absent, non-tty, `consent` default: zero `plugins install`/`git clone` calls, lock rows `suggested` (INV-S8); (c) `HMD_SKILLS_YES=1` or allowlisted id installs and records `consent`; (d) `--setup` on an existing user unchanged.
- Verify: same. Risk R1/R2.

**T5.2 discover-skills-consent** (deps T3.3, T3.5, T4.3)
- Files: Modify `bin/discover-skills` (`install_skill` only; also route `bin/heimdall:3726`-style raw clone through `hmd_skill_install` is T6.3's file, not here); Create `test/skills-consent-discover.test.sh`.
- Acceptance: `bash test/skills-consent-discover.test.sh` exits 0 (`install` under `ask` non-tty without yes => exit 3 and no clone; with `HMD_SKILLS_YES=1` or `consent auto` => clones + receipt + lock row).
- Verify: same.

**T5.3 agent-instructions-and-doc** (deps T4.2, T4.4)
- Files: Modify `skills/heimdall/references/plugin-autoinstall.md` (generated blocks + `hmd skills install` rule), `agents/heimdall.md` (`:136` pointer sentence only); Create `test/skills-autoinstall-doc.test.sh`.
- Acceptance: `bash test/skills-autoinstall-doc.test.sh` exits 0: `python3 -I bin/lib/skills_render_doc.py --check skills/heimdall/references/plugin-autoinstall.md` exits 0; `grep -c 'claude plugins install' skills/heimdall/references/plugin-autoinstall.md` has no occurrence outside the generated rows' install-command column; the doc says exit code 3 means "ask the user" (`grep -q 'consent required' ...`); `agents/heimdall.md` still points at the file (`grep -q 'plugin-autoinstall.md' agents/heimdall.md`).
- Verify: same. Residual risk R5 (LLM compliance not machine-verifiable).

### Wave 6 — guard switches (verifier envelope) and CLI wiring (3 parallel tasks; deps: W5 / W3)

**T6.1 precheck-bash-guard-switches** — `goals.yaml` envelope `verifier`: PROPOSE ONLY, explicit human approval before merge (O6). Model `opus` + `high` (hook/gate code).
- Deps: T2.2, T3.6. Files: Modify `bin/heimdall-precheck-bash` (only the `case` arms/guards for `ci-waste-guard`, `disk-floor`, `sweep-guard`, `wait-guard`, `parallelism-check-bash`; add one `hmd_guardrail_enabled <id>` check each next to the existing env-override `case`); Create `test/guardrail-off-bash.test.sh`.
- Spec: the check runs where the existing override runs (before the helper python); source the lib once, fail-open (lib missing => guard runs). Kill guard, secret scan, git-guard, push gates, oracle, corpus: NO change, NO switch.
- Acceptance: `bash test/guardrail-off-bash.test.sh` exits 0: default (no file) each of the 4 guards still denies its canonical bad command (INV-G2); with that guard's id in `guardrails-off` that command is allowed and the other 3 still deny (INV-G3); core ids in the file change nothing (INV-G1); `bash -n bin/heimdall-precheck-bash` exits 0; `git diff --stat bin/heimdall-precheck-bash` touches only those arms (reviewer checks).
- Verify: same. Risk R3.

**T6.2 precheck-agent-guard-switches** — verifier envelope, PROPOSE ONLY (O6). Model `opus` + `high`.
- Deps: T2.2, T3.6. Files: Modify `bin/heimdall-precheck-agent` (disk-floor fence `:90-123`, named-agent notice `:74`, context gate `:496-590`, fix-chain `:592-635`, gp rules `:637-673`); Create `test/guardrail-off-agent.test.sh`.
- Acceptance: `bash test/guardrail-off-agent.test.sh` exits 0 (same three properties as T6.1 for the five guards; concurrency cap, fallback fence, coop fence, brief-adoption gate untouched and still enforce with their ids in `guardrails-off`); `bash -n bin/heimdall-precheck-agent`.
- Verify: same.

**T6.3 cli-wiring** (deps T4.1, T4.2, T3.6)
- Files: Modify `bin/heimdall` (new `skills)` and `guardrails)` arms after the `hooks)` arm `:2604-2617`; route `--skills install` (`:3726`) through `hmd_skill_install` so it is receipted); Create `bin/heimdall-skills` (dispatcher to `skills_cli_read.py` / `skills_cli_install.py`; `help`/no-arg prints usage; never falls through to launching Claude); Create `test/heimdall-skills-dispatch.test.sh`.
- Acceptance: `bash test/heimdall-skills-dispatch.test.sh` exits 0 (`hmd skills --help`, `hmd skills list`, `hmd guardrails list` exit 0 and never start a Claude run — `claude` fake log empty; `hmd skills bogus` exit 2 with usage; the existing dispatch-name suggester still lists `skills` and `guardrails`; `hmd --skills install owner/repo` now writes a receipt line); `bash -n bin/heimdall`.
- Verify: same.

### Wave 7 — nudge and docs (2 parallel tasks; deps: W6)

**T7.1 session-nudge** (deps T6.3, T5.1)
- Files: Modify `bin/heimdall` (one banner line after setup: `N recommended skills not installed - hmd skills suggest`, only when `consent` != auto, N>0, at most once per day via a stamp in `$HEIMDALL_HOME`, silent when non-tty); Create `test/skills-session-nudge.test.sh`.
- Acceptance: `bash test/skills-session-nudge.test.sh` exits 0 (shown once per day; absent for grandfathered `auto`; absent when everything installed; never blocks launch).
- Verify: same. (No new hook: adding a hook = hooks.json change in the verifier envelope; the launcher banner avoids it.)

**T7.2 docs-and-changelog** (deps all)
- Files: Modify `docs/INVENTORY.md` (rows: `skills.manifest.json`, `guardrails.manifest.json`, `bin/lib/skills_*`, `bin/heimdall-skills`, `bin/heimdall-guardrails`, `hmd_guardrail_enabled.sh`), `docs/INSTALL.md` (short "recommended skills and consent" section), `CHANGELOG.md` (`## [Unreleased]` entry; create heading if absent; NO version bump).
- Acceptance: `grep -q 'skills.manifest.json' docs/INVENTORY.md`; `grep -q 'guardrails.manifest.json' docs/INVENTORY.md`; `grep -q 'hmd skills suggest' docs/INSTALL.md`; `grep -q '\[Unreleased\]' CHANGELOG.md`; `test "$(cat VERSION)" = "2.4.10"`; `jq -r .version .claude-plugin/plugin.json` still `2.4.10`; no sentence claims "no data collection"/"audited" (house truth rules, `test/truth-pass-claims.test.sh` runs in the sweep).
- Verify: the greps above. Done when: docs mention every new surface, version untouched.

### Wave 8 — review and the one sweep (orchestrator steps, not parallel coders)

**T8.1 single review round** (`hmd:reviewer`, `opus` + `high`): review the merged W0-W7 diff ONCE (CLAUDE.md "Release convergence"). Only BLOCKER/HIGH block; MEDIUM/LOW -> `.planning/BACKLOG.md`. Explicit checks: INV-G1 (no path weakens a core guard), INV-S7 (grandfather), INV-S10 (no prompt text in lock), W6 diff touches only the named arms.
**T8.2 full sweep** (orchestrator, after merging every wave and the review fixes, tree frozen): `bash test/run-all.sh` exactly once; red => fix, commit, `bash test/run-all.sh --failed`. Then wait for the operator's `docs/GTM-2.4.x.md` review; no tag, no `release/ship.sh`.

Parallelism per wave: W0 5, W1 3, W2 2, W3 6, W4 4, W5 3, W6 3, W7 2. Same-wave file disjointness checked: `bin/heimdall` is modified in W3 (T3.1), W5 (T5.1), W6 (T6.3), W7 (T7.1) — never twice in one wave; `bin/discover-skills` in W3 (T3.3) and W5 (T5.2); `bin/lib/skill_restore.py` only in W3 (T3.2).

---

## Risks and mitigations

| Risk | P | Impact | Mitigation | Owner |
|---|---|---|---|---|
| R1 Existing user's behaviour changes by accident (consent gate) | med | high | Grandfather rule + marker-present call-log differential vs legacy golden; gate fails toward INSTALL when grandfathered | T5.1, T3.5 |
| R2 `bin/heimdall` (5181 lines) edits collide or regress | med | high | each edit confined to named function heads, sequenced across waves, `bash -n`, own-suite proof | T3.1, T5.1, T6.3, T7.1 |
| R3 Guard switch accidentally weakens a core gate or changes default behaviour | low | high | `core` ignored by `hmd_guardrail_enabled`; fail toward enabled; default-state byte-identity via existing suites; W6 is verifier-envelope, propose-only, opus-authored, reviewed | T2.2, T6.1, T6.2, T8.1 |
| R4 Resolver/legacy divergence hidden by tautological test | med | high | golden recorded from unmodified legacy by a different agent before the resolver; mutant suite requires 8/8 RED | T0.1, T1.2, T3.4 |
| R5 LLM mid-task installs bypass consent (agent types raw `claude plugins install`) | med | med | instruction text + `hmd skills install` exit-3 contract; stated as cooperative; hook-level denial proposed separately | T5.3 |
| R6 ERE vs Python `re` / BSD vs GNU grep differences change matches | med | med | verbatim ERE + full alternation-token matrix + tool versions in golden header; golden test skips loudly on grep-major mismatch | T0.1, T1.2, T2.1 |
| R7 Lockfile leaks private prompt text into git | low | high | evidence = matched token/path only, <= 64 chars, API has no prompt field | T0.4 |
| R8 `goals.yaml` guard `install_surface_changed == false` contradicts consent change | high | med | surface to operator now (O1); propose amendment PR; do not edit goals.yaml | operator / T7.2 note |
| R9 Manifest drifts from `hooks.metadata.json` / `hmd_marketplace_source` | med | med | drift tests in T1.1, T1.3 run in the sweep | T1.1, T1.3 |
| R10 Plan too big for one cycle (30 tasks) | med | med | W0-W5 are independently shippable behind flag-off/grandfather; W6 (verifier envelope) can slip a cycle without breaking W0-W5 | orchestrator |

## Open decisions for the operator (need an answer before or during the matching wave)

- **O1** Amend `goals.yaml` `skills-registry-3-0` guard (`install_surface_changed == false`) for the new-install consent change? Heimdall proposes via PR only.
- **O2** Default allowlist for new installs: empty (all prompted once) vs the 8 `claude-plugins-official` plugins pre-allowed. Plan default: empty; spec 3.1 goal `verified_installs_still_silent` hints at the latter.
- **O3** First-run prompt default answer: Enter = all recommended (official-marketplace) / none. Plan default: none.
- **O4** `kill-guard` tier: plan = `core` (fails closed; keeps its existing `HMD_KILL_GUARD=off` env opt-out). Alternative: `recommended`.
- **O5** `agent-concurrency-cap`, `adjudication-fallback-fence`, `coop-native-spawn-refusal`: not read in depth for this pass; provisional `core`.
- **O6** W6 edits `bin/heimdall-precheck-*` (verifier envelope: explicit approval, "propose only"). Plan treats W6 as a PR for human approval, not auto-merge.
- **O7** `caveman@caveman` (retired) and `design-for-ai@rtd` are in `heimdall-skills.json` but outside the marketplace allow-list; M1 records them `install:false` and changes nothing. Remove in the default-on cycle?
- **O8** Wanted: a registry oracle domain `skills-selection-parity` (none matches today)? Deferred.

## Red flags checked

Prose acceptance criteria: none (each is a grep/test command). Property-only gate: none (differential). Impl-authored reference: avoided (3 agents, 3 waves). Same-wave overlap: none (checked above). Missing OUT OF SCOPE / unowned risks: no. Vague steps: tasks specify files, subcommands, and test cases. **Not done:** `.planning/waves.json` (30 tasks > 10) not emitted because the delivery brief asked for exactly one plan file; the dispatcher derives it from the task blocks above (agent `hmd:coder`, model/effort as stated, scope = the Files lines). **Not done:** the architect's fresh-context `hmd:reviewer` plan-verification pass (no Agent tool in this session); the orchestrator should run it before dispatch.

## OUT OF SCOPE

- Default-on of `skills.registry`, deleting or generating `heimdall-skills.json` / `skills-registry.json` / hand-written `plugin-autoinstall.md` (next cycle, after a week of clean parity).
- Extraction of any skill to `@runhmd/*` (3.1+), stack-pack package, overlays + hash pinning, signing, permission manifests, sandbox, injection scan, trust-tier enforcement, kill switch, public skill pages, community submissions.
- Evidence/trace/replay-ranked `hmd skills suggest` (3.2), `find-skills`/`npx skills` discovery backend wrapper, measured-lift ranking.
- Fixing the C3/C4 selection quirks (substring matches, duplicate attempts): recorded, not changed.
- Plugin version pinning (Claude CLI has no version flag; unchanged from `install-receipt.sh:23-28`), content hashes for plugins.
- A hook-level guard that denies raw `claude plugins install` (new core guardrail; separate proposal).
- Changing any existing `locked` decision in `hooks.metadata.json`; reclassifying hooks; any new hook in `hooks/hooks.json`; any change to `test/run-all.sh` or its disk floor.
- 2.4.8 hygiene leftovers not verified here (`plugin.json`/`marketplace.json` description wording); `goals.yaml` edits; `docs/GTM-2.4.x.md`; version bump, tag, release, npm, site.
- hmdapp / control-plane (`CONTRACTS.md`) work.
