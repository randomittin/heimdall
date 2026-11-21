# HOST-CONTRACT: hmd-skills

The contract between the skills repo (`hmd-skills`: the five skills `stacks`, `designmatch`, `self-improve`, `system-health`, `mac-deep-clean`) and its host (`heimdall`, which keeps every host-side file named below). Task T0.3 of `docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md`, section 1a. T2.1 copies this file into the new repo as `HOST-CONTRACT.md`, so a standalone install says which `hmd` commands it expects.

Verified in heimdall `main` @ `100b4513` on 2026-11-22, read-only. Every line number below was found by grep in that tree. The plan's own numbers were re-checked; the ones that drifted are in section 6.

## Notation

- `path:N`, `path:N-M` and `path:N,M` name lines of that file in the tree above. The parenthesised `anchor` after a reference is literal text found on those lines. Re-check one with `sed -n 'Np' path | grep -F 'anchor'` (a range: `sed -n 'N,Mp'`).
- IDs: K-O = host command or file a moved skill names or relies on. X = the same, found in the tree but not listed in plan section 1a. K-I = host code that reads, runs or matches a moved path.
- The moved skills are Markdown plus `skills/designmatch/scripts/` and `skills/designmatch/assets/`. They call no host code themselves except through the commands a SKILL.md tells an agent or a user to run (section 2); the host reaches into them through the paths in section 3.

## Counts

| Kind | Count | IDs |
|---|---|---|
| Host entry points the plan lists as helpers of the moved skills (named in plan 1a) | 13 | K-O1 to K-O13 |
| Further reverse-dependency entry points named in plan 1a (`commands/maintain-check.md`) | 1 | K-O14 |
| Host commands the moved skills name that plan 1a does not list | 6 | X1-X6 |
| Host code with a path dependency on the moved files | 13 | K-I1 to K-I13 |
| Moved files | 21 (5 skills, 163,291 B) | section 1 |

## 1. The moved set (verified with `git ls-files`)

| Skill | Files | What |
|---|---|---|
| `skills/stacks` | 6 | `SKILL.md`, `README.md`, `fastapi/PACK.md`, `nextjs/PACK.md`, `react-native/PACK.md`, `spring-boot/PACK.md` |
| `skills/designmatch` | 12 | `SKILL.md`, `scripts/` (6: `emit-parity.js`, `fetch-canonical.js`, `iterate-screen.sh`, `render-canonical.js`, `render-web-candidate.js`, `visual-diff.js`), `assets/visual-qa.ts`, `references/` (2), `package.json`, `package-lock.json` |
| `skills/self-improve` | 1 | `SKILL.md` |
| `skills/system-health` | 1 | `SKILL.md` |
| `skills/mac-deep-clean` | 1 | `SKILL.md` |
| Total | 21 | 163,291 bytes (`wc -c` over the 21 tracked files) |

Staying in core (plan option O-A default, section 4): `skills/heimdall`, 15 tracked files.

## 2. Host entry points the moved skills name (K-O, X)

"Skill cites" are lines in the moved files; "Host definition" is where the host implements the interface the skill relies on.

| ID | Host entry point | Interface the skill relies on | Skill cites | Host definition |
|---|---|---|---|---|
| K-O1 | `bin/stack-detect` | `stack-detect [PATH]` prints `{"stacks":[...],"signals":[...]}`; no match prints `{"stacks":[],"signals":[]}`; a FastAPI repo yields `fastapi` | `skills/stacks/SKILL.md:15` (`bin/stack-detect [path]`), `skills/stacks/SKILL.md:50` (`bin/stack-detect .`), `skills/stacks/SKILL.md:56-57` (`{"stacks":[],"signals":[]}`), `skills/stacks/README.md:25` (`bin/stack-detect`), `skills/stacks/README.md:46` (`bin/stack-detect [path]`), `skills/stacks/README.md:92` (`bin/stack-detect`) | `bin/stack-detect:9` (`Usage: stack-detect [PATH]`), `bin/stack-detect:18` (`fastapi? fastapi`), `bin/stack-detect:23` (`Output JSON:`), `bin/stack-detect:24` (`No match:`) |
| K-O2 | `bin/stack-pack` | `detect`, `load`, `paths` with `[PATH]`; `load` prints pack paths, base packs first, then `.planning/skills/*.md`; base packs resolve at `<plugin>/skills/stacks/<id>/PACK.md` | `skills/stacks/SKILL.md:16` (`bin/stack-pack load [path]`), `skills/stacks/SKILL.md:33` (`bin/stack-pack load`), `skills/stacks/SKILL.md:52` (`bin/stack-pack load .`), `skills/stacks/README.md:55` (`bin/stack-pack load [path]`), `skills/stacks/README.md:83` (`bin/stack-pack detect`), `skills/stacks/README.md:86` (`bin/stack-pack load`) | `bin/stack-pack:23` (`PLUGIN_ROOT=`), `bin/stack-pack:50` (`DETECTOR="$BIN_DIR/stack-detect"`), `bin/stack-pack:90` (`skills/stacks/$stack/PACK.md`), `bin/stack-pack:100` (`REFINE_DIR=`); SessionStart runs `detect` into `.planning/detected-stack.json` at `hooks/hooks.json:244` (`stack-pack`) |
| K-O3 | `bin/designmatch` | the CLI the designmatch SKILL.md documents: `init`, `wire`, `fetch`, `port`, `port-all`, `iterate`, `action-types` | `skills/designmatch/SKILL.md:30` (`designmatch init`), `skills/designmatch/SKILL.md:47-52` (`designmatch wire`, `designmatch iterate`), `skills/designmatch/SKILL.md:63` (`designmatch port`), `skills/designmatch/SKILL.md:72` (`designmatch iterate`), `skills/designmatch/SKILL.md:76` (`designmatch fetch`) | `bin/designmatch:4-22` (`Subcommands:`), `bin/designmatch:71` (`designmatch port-all`), `bin/designmatch:79` (`designmatch regen-gate`), `bin/designmatch:386` (`cmd_fetch() {`), `bin/designmatch:447` (`cmd_port_all() {`) |
| K-O4 | `bin/designmatch-regen-log` | hash-log helper of `bin/designmatch`; no moved file calls it | none (grep of `skills/designmatch/` for `bin/`: none) | `bin/designmatch:49` (`BIN_REGEN_LOG=`) |
| K-O5 | `bin/designmatch-behavioral-diff` | AST behavioural diff helper of `bin/designmatch`; no moved file calls it | none | `bin/designmatch:50` (`BIN_BEHAVIORAL_DIFF=`) |
| K-O6 | `bin/designmatch-target` | language-pluggable target seam helper of `bin/designmatch`; no moved file calls it | none | `bin/designmatch:51` (`BIN_TARGET=`), `bin/designmatch-target:34` (`designmatch_targets`) |
| K-O7 | `bin/lib/design_path.py` | engine of `bin/heimdall-frontdoor`'s design subcommand; builds the `designmatch init` or `designmatch wire` argv | none | `bin/heimdall-frontdoor:31` (`DP_LIB=`), `bin/lib/design_path.py:2` (`bin/heimdall-frontdoor`), `bin/lib/design_path.py:99` (`["designmatch", "init", source]`), `bin/lib/design_path.py:101` (`["designmatch", "wire"]`) |
| K-O8 | `bin/lib/designmatch_targets/` (`__init__.py`, `rn.py`, `web.py`) | target modules loaded by `bin/designmatch-target` | none | `bin/designmatch-target:34-35` (`designmatch_targets`), `bin/designmatch-target:57` (`import designmatch_targets as t`) |
| K-O9 | `bin/heimdall-self-improve` | `collect`, `hypotheses`, `experiment start`, `experiment evaluate`, `experiment rollback`, `status`; reads `.planning/metrics.jsonl`, reads and writes `routing-overrides.json`, appends `experiments.jsonl` | `skills/self-improve/SKILL.md:17` (`bin/heimdall-self-improve`), `skills/self-improve/SKILL.md:58` (`heimdall-self-improve collect`), `skills/self-improve/SKILL.md:90` (`heimdall-self-improve hypotheses`), `skills/self-improve/SKILL.md:116` (`heimdall-self-improve experiment start`), `skills/self-improve/SKILL.md:135` (`heimdall-self-improve experiment evaluate`), `skills/self-improve/SKILL.md:146` (`heimdall-self-improve status`), `skills/self-improve/SKILL.md:172` (`bin/heimdall-self-improve`) | `bin/heimdall-self-improve:30-37` (`heimdall-self-improve collect`), `bin/heimdall-self-improve:40-42` (`routing-overrides.json`) |
| K-O10 | `bin/heimdall-sysmon` | memory advisor: bare report, `--quiet`, `--json`, `--reap-hmd-orphans`; exit 0, 1 or 2 | `skills/system-health/SKILL.md:52` (`heimdall-sysmon`), `skills/system-health/SKILL.md:53` (`--quiet`), `skills/system-health/SKILL.md:54` (`--json`), `skills/system-health/SKILL.md:91` (`--reap-hmd-orphans`), `skills/system-health/SKILL.md:110` (`heimdall-sysmon --quiet`), `skills/mac-deep-clean/SKILL.md:167` (`heimdall-sysmon --reap-hmd-orphans`) | `bin/heimdall-sysmon:25-30` (`# USAGE`, `--reap-hmd-orphans`) |
| K-O11 | `bin/heimdall-cleanup` | unified health core: report (default), `--json`, `--apply`, `--advise`, `--deep` | `skills/system-health/SKILL.md:32` (`bin/heimdall-cleanup`), `skills/system-health/SKILL.md:37` (`heimdall-cleanup`), `skills/system-health/SKILL.md:39` (`--apply`), `skills/system-health/SKILL.md:40` (`--deep`), `skills/system-health/SKILL.md:78` (`--advise`), `skills/mac-deep-clean/SKILL.md:10` (`heimdall-cleanup --deep`) | `bin/heimdall-cleanup:30-50` (`SUBCOMMANDS`, `--advise`); run at SessionStart and SessionEnd by `hooks/hooks.json:244` (`heimdall-cleanup`) and `hooks/hooks.json:468` (`heimdall-cleanup`) |
| K-O12 | `commands/designmatch.md` | the slash command `/hmd:designmatch <url-or-path>` | `skills/designmatch/SKILL.md:40` (`/hmd:designmatch`) | `commands/designmatch.md:13` (`skills/designmatch/assets/visual-qa.ts`) |
| K-O13 | `commands/dream.md` | the `/dream` command that reuses the self-improve gate | `skills/self-improve/SKILL.md:37` (`commands/dream.md`) | `commands/dream.md:147` (`bin/heimdall-self-improve`) |
| K-O14 | `commands/maintain-check.md` | the maintainer check that cites the self-improve skill | `skills/self-improve/SKILL.md:35` (`commands/maintain-check.md`) | `commands/maintain-check.md:173` (`skills/self-improve/SKILL.md`) |
| X1 | `bin/heimdall-gc` | `heimdall-gc run`, the disk axis | `skills/system-health/SKILL.md:55` (`heimdall-gc run`), `skills/mac-deep-clean/SKILL.md:85` (`heimdall-gc run`) | present in `bin/`; run by `hooks/hooks.json:244` (`heimdall-gc`) |
| X2 | `bin/heimdall-reap-idle` | `heimdall-reap-idle --apply` | `skills/mac-deep-clean/SKILL.md:85` (`heimdall-reap-idle --apply`) | present in `bin/` |
| X3 | `bin/heimdall-metric` | producer of the `metric:"task"` records; `where --repo .` prints the corpus path | `skills/self-improve/SKILL.md:62` (`bin/heimdall-metric`), `skills/self-improve/SKILL.md:68` (`heimdall-metric where`) | present in `bin/` |
| X4 | `bin/heimdall-dream` | `MIN_SAMPLES_FLOOR` clamp for `/dream` | `skills/self-improve/SKILL.md:104` (`bin/heimdall-dream`) | present in `bin/` |
| X5 | `bin/heimdall-feedback` | files a GitHub issue with a measured finding | `skills/self-improve/SKILL.md:156` (`heimdall-feedback`) | present in `bin/` |
| X6 | `heimdall-state init` | creates the state file the skill says nothing in `bin/ hooks/ sentinels/ modules/` reads | `skills/self-improve/SKILL.md:33` (`heimdall-state init`) | called at SessionStart by `hooks/hooks.json:244` (`heimdall-state init`) |

Between the moved skills themselves (stays inside the pack): `skills/system-health/SKILL.md:13` (`skills/mac-deep-clean/`) points at `mac-deep-clean`.

## 3. Host code that reads, runs or matches the moved paths (K-I)

| ID | Host code | What it relies on | Site |
|---|---|---|---|
| K-I1 | `bin/designmatch` | the six scripts and the asset at `skills/designmatch/`; node deps checked inside `scripts/` | `bin/designmatch:35` (`SKILL_DIR="$PLUGIN_DIR/skills/designmatch"`), `bin/designmatch:36-43` (`emit-parity.js`), `bin/designmatch:1163` (`cd "$SKILL_DIR/scripts"`) |
| K-I2 | `bin/stack-pack` | pack files at `skills/stacks/<id>/PACK.md` under the plugin root | `bin/stack-pack:90` (`skills/stacks/$stack/PACK.md`), `bin/stack-pack:38` (`skills/stacks/<stack-id>/PACK.md`) |
| K-I3 | `bin/heimdall-cleanup` | probes for `skills/mac-deep-clean/SKILL.md` before naming the skill | `bin/heimdall-cleanup:122` (`skills/mac-deep-clean/SKILL.md`), `bin/heimdall-cleanup:124` (`hmd:mac-deep-clean`) |
| K-I4 | `bin/heimdall-sysmon` | the same probe | `bin/heimdall-sysmon:425` (`skills/mac-deep-clean/SKILL.md`), `bin/heimdall-sysmon:428` (`hmd:mac-deep-clean`) |
| K-I5 | `bin/heimdall-self-improve` | messages that name the skill file | `bin/heimdall-self-improve:9` (`skills/self-improve/SKILL.md`), `bin/heimdall-self-improve:91` (`skills/self-improve/SKILL.md`), `bin/heimdall-self-improve:153` (`skills/self-improve/SKILL.md`), `bin/heimdall-self-improve:510` (`skills/self-improve/SKILL.md`) |
| K-I6 | `commands/designmatch.md`, `commands/dream.md`, `commands/maintain-check.md` | the skill files by path | `commands/designmatch.md:13` (`skills/designmatch/assets/visual-qa.ts`), `commands/designmatch.md:96-97` (`skills/designmatch/references/anti-patterns.md`), `commands/dream.md:147` (`skills/self-improve/SKILL.md`), `commands/maintain-check.md:173` (`skills/self-improve/SKILL.md`), `commands/maintain-check.md:185` (`skills/self-improve/SKILL.md`) |
| K-I7 | `skills.manifest.json` (plan: "6 `bundled` entries"; one is `heimdall`, which stays) | one `bundled` entry per skill directory: `ref: skills/<id>` and a `legacy` pointer to `skills/<id>/SKILL.md` | `skills.manifest.json:435-437` (`"ref": "skills/designmatch"`), `skills.manifest.json:442` (`skills/designmatch/SKILL.md`), `skills.manifest.json:446-448` (`"ref": "skills/stacks"`), `skills.manifest.json:453` (`skills/stacks/SKILL.md`), `skills.manifest.json:457-459` (`"ref": "skills/self-improve"`), `skills.manifest.json:464` (`skills/self-improve/SKILL.md`), `skills.manifest.json:468-470` (`"ref": "skills/system-health"`), `skills.manifest.json:475` (`skills/system-health/SKILL.md`), `skills.manifest.json:479-481` (`"ref": "skills/mac-deep-clean"`), `skills.manifest.json:486` (`skills/mac-deep-clean/SKILL.md`) |
| K-I8 | `.gitignore` | designmatch runtime and npm artefacts under the moved dir | `.gitignore:51` (`skills/designmatch/.heimdall/`), `.gitignore:111` (`.designmatch/`), `.gitignore:123-125` (`skills/designmatch/scripts/node_modules/`) |
| K-I9 | `hooks/hooks.json` | SessionStart runs `stack-pack detect` and `heimdall-cleanup`; SessionEnd runs `heimdall-cleanup`; SessionStart runs `heimdall-dream-notice`. No entry of `hooks/hooks.json` names `heimdall-sysmon` (grep); `heimdall-cleanup` calls it | `hooks/hooks.json:244` (`stack-pack`), `hooks/hooks.json:276` (`heimdall-dream-notice`), `hooks/hooks.json:468` (`heimdall-cleanup`) |
| K-I10 | docs that name the paths | `skills/stacks/`, `skills/designmatch/SKILL.md` and the other SKILL.md paths | `README.md:137` (`skills/stacks/`), `packages/runheimdall/README.md:137` (`skills/stacks/`), `CONTRIBUTING.md:21` (`skills/stacks/<stack-id>/PACK.md`), `STACK_PACK_TEMPLATE.md:3` (`skills/stacks/<stack-id>/PACK.md`), `docs/INDEX.md:72-75` (`../skills/designmatch/SKILL.md`), `docs/INVENTORY.md:227` (`skills/stacks/`), `skills/heimdall/references/maintainer-guide.md:183` (`skills/self-improve/SKILL.md`), `skills/heimdall/references/stack-packs.md:30` (`skills/stacks/<id>/PACK.md`), `skills/heimdall/references/stack-packs.md:38` (`skills/stacks/README.md`), `CHANGELOG.md:163` (`skills/designmatch/.heimdall/`) |
| K-I11 | tests that name a moved path | fixtures and the path itself | `test/heimdall-designmatch-web.test.sh:49` (`skills/designmatch/scripts`), `test/heimdall-sysmon.test.sh:83-92` (`skills/mac-deep-clean`), `test/heimdall-sysmon.test.sh:147-152` (`skills/mac-deep-clean/SKILL.md`), `test/sys-cleanup.test.sh:234-244` (`skills/mac-deep-clean`), `test/sys-cleanup.test.sh:284` (`skills/mac-deep-clean`), `test/heimdall-nested-state-gitignore.test.sh:8` (`skills/designmatch/.heimdall`), `test/heimdall-nested-state-gitignore.test.sh:82-141` (`skills/designmatch/.heimdall/.roster-cache.json`), `test/cp-public-allowlist-serves.test.sh:57` (`skills/self-improve`), `test/heimdall-deployed-shape-check.test.sh:19` (`skills/self-improve/SKILL.md`) |
| K-I12 | tests that reach the moved skills through a bin or the manifest (no literal path) | the helper bins of K-O and the `skills/` directory listing | `test/heimdall-self-improve.test.sh:52` (`CLI="$ROOT/bin/heimdall-self-improve"`), `test/designmatch-regen.test.sh:49-52` (`DM="$REPO/bin/designmatch"`), `test/skills-manifest-transcription.test.sh:171-179` (`def bundled(self):`), `test/skills-manifest-transcription.test.sh:323-327` (`for name in src.bundled():`), `test/skills-manifest-transcription.test.sh:705` (`drop_entry(d, "stacks")`) |
| K-I13 | registry code that stays in core (the consumer, not the content) | the `bundled` kind and its `install: false` rule | `bin/lib/skills_manifest.py:29` (`KINDS = `), `bin/lib/skills_manifest.py:302-303` (`bundled entries ship in-tree: install must be false`), `bin/lib/skills_lock.py:79` (`"bundled"`), `bin/lib/skills_cli_install.py:255` (`"bundled"`), `bin/lib/skills_cli_read.py:154` (`"bundled"`), `bin/lib/skills_cli_read.py:249` (`"bundled"`); no `bundled` mention in `bin/heimdall-skills`, `bin/lib/skills_resolver.py`, `bin/lib/skills_config.py`, `bin/lib/skill_restore.py`, `bin/lib/skills_consent.sh`, `bin/skill-manager` (grep) |

## 4. Stays in core: `skills/heimdall` and the code that reads it (plan option O-A, default)

`skills/heimdall` (`SKILL.md` plus 14 references) is `kind: bundled`, "never installed", at `skills.manifest.json:424-431` (`"id": "heimdall"`, `skills/heimdall/SKILL.md`). The whole block is `skills.manifest.json:423-433` (`"id": "heimdall"`, `"tier": "bundled"`). Readers by path, none of which change:

| Reader | Site |
|---|---|
| `agents/architect.md` | `agents/architect.md:216,257,267` (`skills/heimdall/references`) |
| `agents/coder.md` | `agents/coder.md:66,159` (`skills/heimdall/references`) |
| `agents/heimdall.md` | `agents/heimdall.md:136,223,315,476,498,524,537,581,589,642,848,856,864` (`skills/heimdall/references`) |
| `agents/planner.md`, `agents/reviewer.md`, `agents/test-runner.md`, `agents/verifier.md` | `agents/planner.md:19` (`skills/heimdall/references`), `agents/reviewer.md:85` (`skills/heimdall/references`), `agents/test-runner.md:45` (`skills/heimdall/references`), `agents/verifier.md:29` (`skills/heimdall/references`) |
| `bin/heimdall`, `bin/heimdall-journal-hook`, `bin/heimdall-status-json` | `bin/heimdall:3130` (`skills/heimdall/SKILL.md`), `bin/heimdall-journal-hook:11` (`skills/heimdall/SKILL.md`), `bin/heimdall-status-json:55` (`skills/heimdall/references/statusline-ledger.md`) |
| `bin/lib/hmd_sweep_advice.py`, `bin/lib/rule-inventory.sh`, `bin/lib/skills_render_doc.py` | `bin/lib/hmd_sweep_advice.py:34` (`skills/heimdall/references/use-case-tests.md`), `bin/lib/rule-inventory.sh:268` (`RULE_ARTIFACT_REL=`), `bin/lib/skills_render_doc.py:9` (`plugin-autoinstall.md`) |
| `commands/dream.md` | `commands/dream.md:148` (`skills/heimdall/references/maintainer-guide.md`) |

## 5. Seams a standalone skills repo has to respect

- Layout: every moved file keeps its heimdall path (`skills/<id>/...`), so `bin/designmatch:35` and `bin/stack-pack:90` resolve unchanged and the manifest rows at `skills.manifest.json:435-486` stay true (plan section 2, layout rule).
- Host root: `bin/stack-pack` and `bin/designmatch` take the plugin root from `CLAUDE_PLUGIN_ROOT` or the parent of their own `bin/` (`bin/stack-pack:23`, `PLUGIN_ROOT=`; `bin/designmatch:34`, `PLUGIN_DIR=`). A use-case run in the skills repo points it at a clone of heimdall (`HMD_HOST_DIR`, plan T2.1).
- First journey named by the plan: "stack-detect picks the fastapi pack for a FastAPI repo": run `$HMD_HOST_DIR/bin/stack-detect <fixture>` and expect `fastapi` (`bin/stack-detect:18`, `fastapi? fastapi`), then `$HMD_HOST_DIR/bin/stack-pack load <fixture>` and expect a path ending in `skills/stacks/fastapi/PACK.md` (`bin/stack-pack:90`, `PACK.md`).
- The designmatch scripts need `node` and the npm dependencies checked at `bin/designmatch:1163` (`pixelmatch`); the plan's journey is skipped, stated, when node is absent.

## 6. Drift from the plan (section 1a, re-checked 2026-11-22)

| ID | Plan says | Tree says |
|---|---|---|
| D1 | `skills.manifest.json:419-431` for the `heimdall` bundled entry | `skills.manifest.json:423-433` (the entry was 4 lines further down once the manifest grew); `"id": "heimdall"` is `skills.manifest.json:424` |
| D2 | `.gitignore` designmatch ignores "lines ~109-125" | the relevant lines are `.gitignore:111` (`.designmatch/`) and `.gitignore:123-125`; `.gitignore:51` is a comment naming `skills/designmatch/.heimdall/` |
| D3 | "about 20 tests" depend on the moved skills (`skills-*.test.sh`, ...) | by literal moved path: 6 tests (K-I11); by bin or manifest: K-I12. The `skills-*` registry suites mostly name `skills/heimdall`, not a moved path; the tree has 24 `test/skills-*.test.sh` (plan section 4 says 13) |
| D4 | `bin/{designmatch,heimdall,heimdall-cleanup,heimdall-journal-hook,heimdall-self-improve,heimdall-status-json,heimdall-sysmon,stack-pack}` are reverse dependencies | `bin/designmatch`, `bin/heimdall-cleanup`, `bin/heimdall-self-improve`, `bin/heimdall-sysmon`, `bin/stack-pack` name a moved path (K-I1 to K-I5); `bin/heimdall`, `bin/heimdall-journal-hook`, `bin/heimdall-status-json` name only `skills/heimdall` (section 4) |
| D5 | `agents/{...}.md`, `bin/lib/{hmd_sweep_advice.py,rule-inventory.sh,skills_render_doc.py}` are reverse dependencies | they read `skills/heimdall/...` only (section 4), none name a moved path |
| D6 | `bin/lib/design_path.py` is a helper of the moved skills | it is the engine of `bin/heimdall-frontdoor` and only builds the `designmatch` argv (K-O7); the moved files do not call it |
| D7 | hooks call `heimdall-cleanup` and `stack-pack` at SessionStart | confirmed at `hooks/hooks.json:244`; `heimdall-cleanup` also runs at SessionEnd (`hooks/hooks.json:468`); no entry of `hooks/hooks.json` names `heimdall-sysmon` (grep) |
| D8 | not stated | `skills/stacks/SKILL.md:31` says the SessionStart hook runs `bin/stack-detect`; the hook runs `bin/stack-pack detect` (`hooks/hooks.json:244`), which calls `stack-detect` (`bin/stack-pack:50`). A doc imprecision, not a code defect |
| D9 | 21 moved files, 163,291 B, 15 staying files | confirmed (`git ls-files`, `wc -c`) |
