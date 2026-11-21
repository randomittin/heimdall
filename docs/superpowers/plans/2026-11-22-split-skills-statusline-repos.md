# Plan: split skills and statusline into their own repos

Operator ask (2026-11-22): "separate out the skills and also the statusline as separate repos".
Spec: `/Users/rj/Downloads/01-skills-separation.md` (bundled fallback, lockfile pins + content hash, parity/shadow gates, published packages). Related, NOT yet implemented: `docs/superpowers/plans/2026-11-12-3x-lean-core.md` (sparse-checkout lean profile, `skills_packs.py`, `bin/heimdall-pack-build`). Merged base: `skills.manifest.json`, `bin/lib/skills_*`, `hmd skills`.
Design gate: the spec plus the operator sentence are the approved design; no brainstorm. `bin/decompose` NOT run (turn limit; waves hand-built). Plan-verification reviewer NOT run (turn limit): coordinator should run it before dispatch.
Analysis only: nothing created, no repo made, nothing pushed. Measured on worktree @ main bb5035fb (git ls-files + wc -c, 2026-11-22). Anything marked UNMEASURED was not measured.

## 1. Inventory (measured)

### 1a. hmd-skills (`skills/`: 36 tracked files, 281,811 B total)

| Dir | Files | Bytes | Decision |
|---|---|---|---|
| `skills/stacks` (SKILL.md, README.md, 4 PACK.md) | 6 | 58,767 | MOVE |
| `skills/designmatch` (SKILL.md, scripts x6, assets/visual-qa.ts, references x2, package.json + lock) | 12 | 76,093 | MOVE |
| `skills/self-improve` | 1 | 10,133 | MOVE |
| `skills/system-health` | 1 | 7,443 | MOVE |
| `skills/mac-deep-clean` | 1 | 10,855 | MOVE |
| **hmd-skills total** | **21** | **163,291** | |
| `skills/heimdall` (SKILL.md + 14 references: planning-pipeline, quality-gates, definition-of-done, agent-templates, journal, statusline-ledger, use-case-tests ...) | 15 | 118,520 | STAY (see O-A) |

Why `skills/heimdall` stays by default: it is the orchestrator skill, `kind: bundled` "never installed" in `skills.manifest.json:419-431`, and every role agent plus hook text reads its references by path (`agents/{architect,coder,heimdall,planner,reviewer,test-runner,verifier}.md`, `bin/lib/hmd_sweep_advice.py`, `bin/lib/rule-inventory.sh`). Spec Stage 3: skills that depend on Heimdall internals stay `hmd-only`.

Helpers the moved skills use, owned by CORE and NOT moved (hooks call them at SessionStart, e.g. `heimdall-cleanup`, `stack-pack`): `bin/designmatch` (56,525 B) + `designmatch-behavioral-diff|regen-log|target` (sizes UNMEASURED), `bin/lib/design_path.py`, `bin/lib/designmatch_targets/`, `bin/heimdall-self-improve` (39,357), `bin/heimdall-sysmon` (28,689), `bin/heimdall-cleanup` (48,990), `bin/stack-pack` (3,704), `bin/stack-detect`, `commands/designmatch.md` (4,947), `commands/dream.md`. The skills repo ships a `HOST-CONTRACT.md` naming them, so a standalone install says which `hmd` commands it expects.
Registry code stays in core: `skills.manifest.json` (20,086), `bin/heimdall-skills`, `bin/lib/skills_*.py`, `skill_restore.py`, `skills_consent.sh`, `bin/skill-manager`. The registry is the consumer, not the content.

Reverse dependencies inside heimdall (grep, measured): `agents/{architect,coder,heimdall,planner,reviewer,test-runner,verifier}.md`; `bin/{designmatch,heimdall,heimdall-cleanup,heimdall-journal-hook,heimdall-self-improve,heimdall-status-json,heimdall-sysmon,stack-pack}`; `bin/lib/{hmd_sweep_advice.py,rule-inventory.sh,skills_render_doc.py}`; `commands/{designmatch,dream,maintain-check}.md`; `skills.manifest.json` (6 `bundled` entries + `ref: skills/<id>`); `.gitignore` (designmatch ignores, lines ~109-125); about 20 tests (`skills-*.test.sh`, `heimdall-designmatch-web`, `heimdall-sysmon`, `sys-cleanup`, `heimdall-self-improve`, `designmatch-regen`, `protocol-conformance`, ...). Because the mirror (section 3) keeps every moved file at its SAME path, none of these change.

### 1b. hmd-statusline

Entry points: Claude Code `statusLine` -> `hooks/statusline.sh` (1,172 B, a one-line `exec` into `bin/heimdall-statusline`; the marker `hooks/statusline.sh` is what `install.sh` `ensure_statusline_registered` and `bin/heimdall-statusline-register` match inside users' `settings.json`). Cursor `statusLine` -> `bin/heimdall-statusline` directly.

| Group | Files | Bytes |
|---|---|---|
| `hooks/statusline.sh`, `hooks/subagent-statusline.sh` | 2 | 2,775 |
| `bin/heimdall-statusline` 34,332; `-register` 10,398; `-register-cursor` 14,856; `heimdall-sigil` 1,772; `heimdall-sigil-png` 1,719 | 5 | 63,077 |
| `sentinels/` `hmd-statusline.py` 141,316; `hmd_sigil.py` 139,870; `hmd_gauge.py` 18,662; `hmd_sigil_png.py` 11,742; `subagent-statusline.py` 7,723; `hmd-subagent-statusline.sh` 2,782; `hmd-sigil.py` 1,646 | 7 | 323,741 |
| `sentinels/hmd_layout.py`, `hmd_termcaps.py`, `hmd_ledger.py`, `hmd_wall.py` (siblings loaded by path in `hmd-statusline.py:50-61`) | 4 | UNMEASURED |
| `conformance/statusline/` (INVARIANTS.md, 21 goldens, 4 fixtures) | 26 | UNMEASURED |
| `test/` suites: 23 `heimdall-statusline-*`, 10 `heimdall-sigil-*`, `heimdall-status-json`, `heimdall-init-cursor-statusline` | 35 | UNMEASURED |
| **Runtime (hooks + bin + sentinels)** | **18** | **>= 389,593** |

Finding: the static suite closure is useless as a boundary. `bin/heimdall-suite-closure deps` on a sigil suite returns 628 files (the whole of heimdall, through `bin/heimdall`); the first attempt over 35 suites did not finish and was stopped. The boundary below is hand-traced from `sentinels/hmd-statusline.py` and `bin/heimdall-statusline`, so treat it as grep-derived.

Not moved, stays core (the HOST side of a file contract): `bin/heimdall-status-json` (16,295; the WRITER of `.heimdall/statusline.json`, imports `hmd_ledger`/`hmd_sigil`), `bin/heimdall-face` (38,115; fallback line, also used by badge), `heimdall-ctx-meter`, `heimdall-agents`, `heimdall-identity`, `heimdall-presence`, `heimdall-tier`, `agent-pool`, `shared-memory`, `bin/lib/{hmd-python.sh,hmd_session_code.py,hmd_private_state.py,repo_roster.py}`. The renderer reaches them by path (`BIN_DIR`, `hmd-statusline.py:45,470,488,520,658,852`; `bin/heimdall-statusline:37-38,75,211,512`). They go in the statusline repo's `HOST-CONTRACT.md`, one line per entry point and the file it reads (`.heimdall/statusline.json`, `.roster-cache.json`, `agent-pool.json`, `shared-memory.db`).

Reverse dependencies (grep, measured): `hooks/hooks.json` (SessionStart runs `heimdall-statusline-register register`); `install.sh` (`ensure_statusline_registered` :307, `ensure_cursor_statusline_registered` :382, sigil render :909, steps :1367-1388, :1733-1737); `bin/heimdall` (`sigil)` arm :1801-1809, `status)` arm :2978-2989, uninstall markers :951/:1113-1130); sigil/layout/ledger consumers outside the HUD: `bin/{heimdall-board,heimdall-identity,heimdall-status-json,summary-card,falsify,heimdall-face}`, `bin/lib/{repo_roster,watch_data,watch_tui}.py`, `sentinels/{hmd-banner.sh,hmd-gate-anim.sh,hmd-ui.py}`; `bin/heimdall-doctor-install`; `.github/workflows/release-gate-suites.yml`. Hence sigil is a shared library, not only HUD code: the mirror keeps it at `sentinels/hmd_sigil.py` so all those callers stay untouched.

## 2. History carry-over (local, no network)

`git-filter-repo` is installed (`git filter-repo --version` answers). It needs a fresh clone, so the extract tool (T1.2) always works on `git clone --no-local` of heimdall, never in place. Heimdall: 5,320 commits, pack 29 MiB. Commits touching the paths (measured): `skills/` 77 (the 5 movable dirs: 26); statusline core files (`sentinels/hmd-statusline.py hmd_sigil.py hmd_gauge.py bin/heimdall-statusline`) 126; the rest of the statusline set UNMEASURED.

Layout rule: the new repos keep the SAME relative paths as heimdall (`skills/<id>/...`; `hooks/`, `bin/`, `sentinels/`, `conformance/statusline/`, `test/`). No `--path-rename`: this makes the mirror a plain path-for-path copy, lets `npx skills add <owner>/hmd-skills` find `skills/<id>/SKILL.md` (the layout the spec cites), and keeps a standalone clone runnable because the renderers locate siblings with `dirname $0`.

```bash
# skills (run from any dir; fresh clone each time)
git clone --no-local /Users/rj/Downloads/heimdall /Users/rj/Downloads/hmd-skills
cd /Users/rj/Downloads/hmd-skills
git filter-repo --force \
  --path skills/stacks --path skills/designmatch --path skills/self-improve \
  --path skills/system-health --path skills/mac-deep-clean
git filter-repo --force --invert-paths --path skills/designmatch/.heimdall   # runtime caches committed by a wip checkpoint (1acd792b)

# statusline
git clone --no-local /Users/rj/Downloads/heimdall /Users/rj/Downloads/hmd-statusline
cd /Users/rj/Downloads/hmd-statusline
git filter-repo --force \
  --path hooks/statusline.sh --path hooks/subagent-statusline.sh \
  --path bin/heimdall-statusline --path bin/heimdall-statusline-register --path bin/heimdall-statusline-register-cursor \
  --path bin/heimdall-sigil --path bin/heimdall-sigil-png \
  --path sentinels/hmd-statusline.py --path sentinels/hmd_sigil.py --path sentinels/hmd_gauge.py --path sentinels/hmd_sigil_png.py \
  --path sentinels/hmd-sigil.py --path sentinels/subagent-statusline.py --path sentinels/hmd-subagent-statusline.sh \
  --path sentinels/hmd_layout.py --path sentinels/hmd_termcaps.py --path sentinels/hmd_ledger.py --path sentinels/hmd_wall.py \
  --path conformance/statusline \
  --path-glob 'test/heimdall-statusline-*.test.sh' --path-glob 'test/heimdall-sigil-*.test.sh'
```
(the 11 host-integration suites of section 4 are added or dropped by the T2.2 path list; `git subtree split` is the fallback if filter-repo is unavailable, it carries only one directory so it cannot do the statusline set.) A secret scan of the result (`gitleaks detect` or `bin/heimdall-selfscan`) must be clean before the operator pushes: history is public once pushed. Renamed-away paths (the `.superx` era names) are not followed by `--path`: history older than the rename is lost for those files (UNMEASURED how much; open question O-D).

## 3. Consumption after the split (zero behaviour change)

Chosen: **path-identical vendored mirror + lockfile pin**, with an optional runtime pack for skills in a later cycle. Rejected: git submodule (install is `git clone --depth 1` without `--recurse-submodules`, `install.sh:1185`; lean sparse checkout and autoupdate would both need to learn submodules), and runtime-only fetch (breaks offline and the statusline's 2 s refresh budget).

1. **Source of truth moves.** Development, issues, tags and history live in `hmd-skills` / `hmd-statusline`. Heimdall keeps a copy of every moved file at the SAME path (this is the spec's "bundled fallback"). Nothing in hooks.json, install.sh, bin/heimdall, agents or tests changes, which is what makes the change zero-behaviour.
2. **`vendor/vendor.lock.json`** (new, tracked): per repo `{name, repo, tag, commit, tree_sha256, paths[]}`. `bin/heimdall-vendor sync <name>` copies the pinned tag's files into the mirror paths; `verify` recomputes the hash of the mirrored paths and fails on any drift in either direction (a hand edit in heimdall, or a tag moved upstream); `diff` shows it. A drift test makes a direct edit of a mirrored file in heimdall RED (it must go through the new repo). Same shape as the spec's `hmd-skills.lock` and the repo's own content-hash rows (`bin/lib/skills_lock.py`).
3. **Statusline: bundled only, no runtime fetch.** `hooks/statusline.sh` keeps its exact path and marker; `bin/heimdall-statusline` stays the exec target; `~/.claude/settings.json` `statusLine` and `~/.cursor/cli-config.json` need no migration and Cursor is untouched. Offline works because the code is in the install. Updates reach users the way they do today (heimdall release/autoupdate), after a lock bump. `bin/heimdall-status-json` (the writer) stays in heimdall so the `.heimdall/statusline.json` contract has its schema test on both sides.
4. **Skills: same mirror now; runtime pack later (next cycle, depends on lean-core T2.1 `skills_packs.py`).** Phase 2: `install.sh` / `bin/heimdall-autoupdate` fetch the lock-pinned tag of `hmd-skills` into `$HEIMDALL_HOME/packs/hmd-skills/<tag>/`, verify `tree_sha256`, record a row via `skills_lock.py`; the resolver prefers the pack if the hash matches, else the bundled copy, silently (INV-L5 of the lean-core plan). Stage 4 (drop bundled copies) only after two releases with zero fallbacks, per spec.
5. **Lean-core overlap, decision needed (O-C):** lean-core T2.2 builds `@runhmd/stacks` from `skills/stacks` and T2.4 sparse-adds paths. After this split the pack builder reads the `hmd-skills` repo (or the mirror, which is byte-equal) and "install" can mean "fetch the pack" instead of "sparse add". Recommendation: land this plan's phase 1 first; it changes no path, so lean-core tasks need no edit.

## 4. Tests and gates

Standalone (move with the repo, run in its own CI, renderer + fixtures only): of the 36 statusline suites, about 24 call only the renderer (grep: no host `bin/` entry point beyond `env`/`sh`): the 10 `sigil-*` less `heroes` and `render`, and `statusline-{agents-cache,cc-columns,cc-region-reserve,cols-detect,crossbranch,density,eyestrip,fullbleed,gauge,host-boundary,identity-flip,panel-floor,perf-budget,register-cursor,terminals,width}` plus `conformance/statusline/`. Treat the count as grep-derived (T0.1 records each suite's host calls before anything moves).
Stay in heimdall as integration tests (they need the host): `statusline-agent-tiers` (heimdall-tier), `statusline-cursor-payload` and `statusline-parity` (heimdall-ctx-meter), `statusline-member-age` (repo_roster), `statusline-rate-limit-persist` (heimdall-session-usage), `statusline-portability` (hooks/hooks.json), `statusline-update-notice` and `init-cursor-statusline` (bin/heimdall), `sigil-heroes` and `sigil-render` (`hmd sigil` arm), `heimdall-status-json` (writer, heimdall-gate-run). 11 suites. Skills: `skills-*` (13 registry/consent/lock suites), `heimdall-self-improve`, `heimdall-sysmon`, `sys-cleanup`, `heimdall-designmatch-web`, `designmatch-regen` all test core code or core bins, so they STAY; the skills repo gets new content checks only (below).
New in heimdall: `test/heimdall-vendor.test.sh` (verify/sync/diff + drift mutants), `test/vendor-parity.test.sh` (mirror tree equals recorded baseline byte for byte), `test/split-falsify.test.sh`.

Each new repo declares `.heimdall/repo-checks.json` (client-repo class, `skills/heimdall/references/use-case-tests.md`: lint + use-cases, no sweep, no `run-all.sh`):
- hmd-skills: `lint` = `bash scripts/lint-skills.sh` (frontmatter name/description present, SKILL.md under size cap, `bash -n` + `node --check` over scripts, no `.heimdall/` caches, `shellcheck` if installed); `use-cases` = `bash tests/use_cases/run.sh` (journeys: "stack-detect picks fastapi pack for a FastAPI repo" runs heimdall's `bin/stack-detect` from `$HMD_HOST_DIR`; "designmatch scripts render a canonical" skipped unless node present: stated, not faked).
- hmd-statusline: `lint` = `bash scripts/lint.sh` (`bash -n`, `python3 -m py_compile`, `shellcheck`, `ruff` if installed); `use-cases` = `bash tests/use_cases/run.sh` (journeys: "Claude Code JSON in, 4-row HUD out at 3 widths x 3 color tiers = the 21 goldens", "Cursor payload width honored", "offline, no python3 -> fallback line never errors", "register leaves a user's own statusLine alone"). The moved suites run via that script. Host-dependent journeys clone heimdall at the lock's pinned ref into a temp dir (`HMD_HOST_DIR`), real host, no mocks.
Heimdall push gate is unchanged (sweep class). Each new repo's push is graded by its own receipt (`bin/heimdall-repo-checks run`), per CLAUDE.md "Push gate".

### Oracle gate (final correctness wave)
Registry domain: none matches (`jq -r '.oracles|keys[]' evals/oracles/registry.json` NOT RUN here; names in the registry are LOB/GB-style, no statusline/skills domain): flagged so a reviewer can decide whether to add one. Wired: `gate_type: differential`, `independent: true`. Reference = whole-output record from the UNMODIFIED tree, recorded in wave 0 by `hmd:test-runner` (T0.1) before any implementation task exists: sha256 of every mirrored path + the full byte output of `bin/heimdall-statusline` for the 21 conformance fixtures and for the Cursor payload + `hmd sigil --test`. The mirror after the split must equal it as a whole. Falsifiable: `test/split-falsify.test.sh` (T4.1) must turn RED for: one byte changed in a mirrored file; lock `tree_sha256` flipped; a moved path dropped from the lock; `hooks/statusline.sh` renamed; golden changed. Golden green. Property checks (per-file hash) are supplementary only. No concurrency in this target.

## 5. Invariants and coverage (wave-0 artifact `.planning/split/INVARIANTS.md`, listed under Read first for every task after W0)
- INV-S1: every moved path exists in heimdall at the same path with the same bytes as the pinned tag; `heimdall-vendor verify` is exit 0.
- INV-S2: `hooks/statusline.sh` path and the substring `hooks/statusline.sh`, and `bin/heimdall-statusline` path, are unchanged (users' `settings.json` / Cursor config stay valid).
- INV-S3: rendered bytes for the recorded fixtures are identical before and after.
- INV-S4: no network at install or render time in phase 1.
- INV-S5: no file outside the moved set is edited by the split (`git diff --stat` names only `vendor/`, `bin/heimdall-vendor`, `bin/lib/vendor_lock.py`, tests, docs, deleted moved suites).
- INV-S6: history of each moved path is present in the new repo (`git log --oneline -- <path> | wc -l` equals the source count, except renamed-away history, open question O-D).
The ledger has no teeth without the differential gate above.

| Subsystem | In scope? | Oracle row | Expected |
|---|---|---|---|
| mirror equals baseline (skills 21 files, statusline 18+4+26 files) | yes | `test/vendor-parity.test.sh` | green |
| statusline render parity | yes | `test/split-falsify.test.sh` + goldens | green |
| runtime fetch of skills pack into `$HEIMDALL_HOME/packs` | descoped (next cycle) | none | n/a |
| removal of bundled copies | descoped (spec Stage 4) | none | n/a |
| `skills/heimdall`, designmatch/stack bins | descoped (stay core) | none | n/a |
| publishing (skills.sh, npm), signing | descoped | none | n/a |
| standalone statusline on a machine with no hmd | descoped, unmeasured fail-open | none | expected-red if tried |

## 6. Waves (each task <= 3 files; same-wave files disjoint; each test run once, own suite only)

### Wave 0: baseline, ledger, contract (no product code; local)
- **T0.1 baseline (INDEPENDENT reference).** `hmd:test-runner`, sonnet/default. Create `bin/lib/split_baseline.py`, `evals/split/baseline.json`, `test/split-baseline.test.sh`. Records sha256 + bytes for every path in sections 1a/1b, each statusline suite's host calls, and renderer output bytes for the fixtures. Skills: `superpowers:test-driven-development`. Patterns: `bin/lib/suite_closure.py` hashing, `test/fixtures/skills-baseline/golden.json`. Accept: `python3 -I bin/lib/split_baseline.py check` exits 0; `jq -e '.paths|length>=60' evals/split/baseline.json`. Verify: `bash test/split-baseline.test.sh` (mutant: edit one mirrored byte -> RED).
- **T0.2 ledger + coverage.** `hmd:docs-writer`. Create `.planning/split/INVARIANTS.md`, `.planning/split/COVERAGE.md` (text of section 5). Accept: `test $(grep -c '^- INV-S' .planning/split/INVARIANTS.md) -eq 6`. Verify: same.
- **T0.3 host contracts.** `hmd:docs-writer`. Create `docs/split/HOST-CONTRACT-statusline.md`, `docs/split/HOST-CONTRACT-skills.md` (every host entry point and file named in sections 1a/1b, each with `file:line`). Accept: `grep -q 'heimdall-identity' docs/split/HOST-CONTRACT-statusline.md && grep -q 'stack-detect' docs/split/HOST-CONTRACT-skills.md`. Verify: same.
Disjoint: yes.

### Wave 1: tools in heimdall, still unwired (depends W0)
- **T1.1 vendor tool.** `hmd:coder`, sonnet/default. Create `bin/heimdall-vendor` (`sync|verify|diff <name>|--all`, stdlib, `python3 -I`, atomic writes, refuses a tag whose hash differs from the lock), `bin/lib/vendor_lock.py`, `test/heimdall-vendor.test.sh`. Read first: INVARIANTS.md, `bin/lib/skills_lock.py:1-50` (strict JSON, no links, atomic rename), `bin/heimdall-suite-closure` (launcher shape). Accept: `test -x bin/heimdall-vendor`; `bin/heimdall-vendor verify --help | grep -q tree_sha256`. Verify: `bash test/heimdall-vendor.test.sh` (cases: clean verify 0; edited file 1; missing file 1; tampered lock 1; sync idempotent).
- **T1.2 extract tool.** `hmd:coder`, sonnet/default. Create `bin/heimdall-split-extract` (`skills|statusline --to DIR [--dry-run]`: fresh `git clone --no-local`, the section 2 `filter-repo` calls, refuses an existing DIR, never adds a remote, never pushes), `test/split-extract.test.sh`. Accept: `bin/heimdall-split-extract skills --dry-run | grep -q 'path skills/stacks'`. Verify: `bash test/split-extract.test.sh` (builds a temp source repo; asserts history count per path and that no remote exists).
Disjoint: yes (2 task-owned sets).

### Wave 2: build the two repos locally (depends W1; work is in the NEW repos, not heimdall)
- **T2.1 hmd-skills.** `hmd:coder`. Run `bin/heimdall-split-extract skills --to /Users/rj/Downloads/hmd-skills`; add `README.md`, `.heimdall/repo-checks.json`, `scripts/lint-skills.sh` (+ `tests/use_cases/run.sh`, `HOST-CONTRACT.md` copied from T0.3: one commit for the set of added root files, counted as one mechanical add). Accept: `test -f /Users/rj/Downloads/hmd-skills/skills/stacks/SKILL.md`; `jq -e '.checks|length==2' /Users/rj/Downloads/hmd-skills/.heimdall/repo-checks.json`; `bash /Users/rj/Downloads/hmd-skills/scripts/lint-skills.sh` exits 0. Verify: `cd /Users/rj/Downloads/hmd-skills && /Users/rj/Downloads/heimdall/bin/heimdall-repo-checks run`.
- **T2.2 hmd-statusline.** `hmd:coder`. Same shape: extract to `/Users/rj/Downloads/hmd-statusline`; add `README.md`, `.heimdall/repo-checks.json`, `scripts/lint.sh`, `tests/use_cases/run.sh`, `HOST-CONTRACT.md`. Accept as T2.1 with `test -x /Users/rj/Downloads/hmd-statusline/hooks/statusline.sh`. Verify: `cd /Users/rj/Downloads/hmd-statusline && /Users/rj/Downloads/heimdall/bin/heimdall-repo-checks run`.
- **T2.3 secret scan.** `hmd:reviewer` (opus/high): gitleaks / `bin/heimdall-selfscan` over both new repos' full history; BLOCKER/HIGH only. Accept: `gitleaks detect --source /Users/rj/Downloads/hmd-skills --no-banner` exits 0 (same for statusline; if gitleaks absent, say so and run `bin/heimdall-selfscan`).
Disjoint: three different directories.

### Wave 3: heimdall consumes the pin (depends W2)
- **T3.1 lock + parity.** `hmd:coder`. Create `vendor/vendor.lock.json` (repo URL `git@github.com:randomittin/hmd-skills.git`, local tag `v1.0.0` made in the new repo, commit sha and `tree_sha256` taken from the local repos; the URL is not live until O3), `test/vendor-parity.test.sh`; modify `.github/workflows/release-gate-suites.yml` ONLY to add the verify call (one step). Accept: `bin/heimdall-vendor verify --all` exits 0; `jq -e '.repos|length==2' vendor/vendor.lock.json`. Verify: `bash test/vendor-parity.test.sh`.
- **T3.2 remove moved suites.** `hmd:coder`. `git rm` of the 24 standalone statusline suites and `conformance/statusline/` (one mechanical deletion; the new repo already carries them with history, T0.1 baseline lists them); modify no other file. Accept: `! test -e test/heimdall-statusline-gauge.test.sh`; `test -e test/heimdall-statusline-parity.test.sh` (stays); `bin/heimdall-vendor verify --all` exits 0. Verify: `bash test/vendor-parity.test.sh` (conformance now lives in the new repo; the parity record is the baseline). Risk: any file listing suites (`test/run-all.sh` hints, `conformance/INDEX.json`, `release-gate-suites.yml`) must not name a deleted path: grep before delete, and do it only if T3.1 is merged. Order inside the wave: T3.2 after T3.1 (shares `release-gate-suites.yml` if it names suites), so make it Wave 3b.
Disjoint: W3a = T3.1; W3b = T3.2.

### Wave 4: gates and close-out (depends W3; authors differ from implementers)
- **T4.1 falsifiability.** `hmd:test-runner`. Create `test/split-falsify.test.sh`, `evals/split/mutants/` (patch files for the five mutants above). Verify: `bash test/split-falsify.test.sh` (asserts every mutant RED, golden GREEN, score 1.0).
- **T4.2 docs.** `hmd:docs-writer`. Create `docs/split-repos.md` (what moved, how to bump a pin: edit in the new repo -> tag -> `heimdall-vendor sync` -> commit; rollback = revert lock), modify `CHANGELOG.md` `[Unreleased]` only. Accept: `grep -q 'heimdall-vendor sync' docs/split-repos.md`; `grep -q 'hmd-statusline' CHANGELOG.md`.
Disjoint: yes.

### Wave 5: orchestrator only
One review of the release diff (BLOCKER/HIGH only), then RECOMMEND to the developer, immediately before the merge operation, ONE full sweep (`bash test/run-all.sh`; why: 24 suites left, the vendor gate and every suite reaching `sentinels/`/`bin/heimdall*` must still pass; cost: ~45-60 min cold, UNMEASURED cached; tokens ~910 if only the 40-line tail is read). Run only on the developer's yes. No bump, tag or push by an agent.

Dependency graph: W0 -> W1 -> W2 -> W3a -> W3b -> W4 -> W5; critical path T0.1 -> T1.1 -> T2.2 -> T3.1 -> T4.1. 12 tasks (> 10), so `.planning/waves.json` is required: NOT emitted here (turn limit); the coordinator or architect emits it from section 6 before dispatch.

## 7. Operator steps (agent never publishes)

Remote used by this repo: `origin git@github.com:randomittin/heimdall.git`; marketplace `randomittin/heimdall-marketplace`. `runhmd` on GitHub is a User (machine account, not an org; `gh api orgs/runhmd` is 404), so the owner is `randomittin`. `gh api repos/randomittin/hmd-skills` and `hmd-statusline` both return 404 today (names free). Commands, after W2/W3 are merged and the secret scan is clean:

```bash
# O1/O2: create + push (run in each local repo)
cd /Users/rj/Downloads/hmd-skills
gh repo create randomittin/hmd-skills --public --description "Heimdall skills: stacks, designmatch, self-improve, system-health, mac-deep-clean" --source=. --remote=origin --push
git tag -a v1.0.0 -m "hmd-skills 1.0.0" && git push origin v1.0.0
cd /Users/rj/Downloads/hmd-statusline
gh repo create randomittin/hmd-statusline --public --description "Heimdall statusline HUD and sigil renderer" --source=. --remote=origin --push
git tag -a v1.0.0 -m "hmd-statusline 1.0.0" && git push origin v1.0.0
# O3: confirm the lock's commit/tree match the pushed tags
cd /Users/rj/Downloads/heimdall && bin/heimdall-vendor verify --all
# O4: heimdall PR + merge (the developer decides on the sweep, section 6 W5)
```
O5 (optional, later): `skills.sh` listing of `randomittin/hmd-skills`, `npx skills add randomittin/hmd-skills@stacks` check. npm publish: none in this plan. `install.sh.minisig` re-sign is NOT needed in phase 1 (install.sh is untouched); phase 2 edits it (lean-core O2).

## 8. Risks

| Risk | P | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Statusline coupling to host bins (identity, presence, tier, shared-memory, session code) makes the repo not standalone | high | med | HOST-CONTRACT.md + host-dependent journeys clone heimdall; standalone-without-hmd descoped and marked expected-red | T0.3, T2.2 |
| Mirror drifts (someone edits a mirrored file in heimdall) | med | high | `heimdall-vendor verify` in `test/vendor-parity.test.sh` and the CI workflow; edit-in-new-repo documented | T1.1, T3.1, T4.2 |
| Sigil/layout/ledger shared with banner, board, ui, identity, status-json | high | high | path-identical mirror, none of those callers edited (INV-S5); `sigil-heroes`/`render`/`status-json` stay as integration suites | T3.1, T3.2 |
| History lost for pre-rename paths, committed runtime caches carried into public history | med | med | secret + cache scan before push; `--invert-paths skills/designmatch/.heimdall`; O-D | T2.3 |
| Static closure unusable (628 files), so a suite wrongly classed standalone fails after the move | med | med | T0.1 records each suite's host calls; the new repo's gate runs them against a cloned host | T0.1, T2.2 |
| Deleting suites breaks a suite list (`run-all.sh` hints, `conformance/INDEX.json`, workflow) | med | med | grep before delete, T3.2 after T3.1 | T3.2 |
| Overlap with lean-core (pack builder, sparse paths) | med | med | O-C; phase 1 changes no path | T3.1 |
| `statusLine` marker or Cursor path broken | low | high | INV-S2 + falsify mutant (rename `hooks/statusline.sh`) | T4.1 |
| Two sources of truth (lock says tag X, repo moved on) | med | med | lock pins commit + tree hash, verify recomputes both | T1.1 |

## 9. Red flags named
Static closure unusable as a boundary (measured 628 files); sigil and ledger libs are shared with core consumers; statusline renderer depends on ~10 host entry points; lean-core plan overlaps and is unimplemented; plan-verification reviewer not run (turn limit); `bin/decompose` not run; gate-type: no registry oracle (differential wired by hand, independent record in W0); T2.* tasks create files in other repos so their acceptance paths are absolute.

## Open questions as closed options (default first)
- O-A `skills/heimdall` (15 files, 118,520 B): (1) stays in core [default]; (2) moves too, as a 6th skill.
- O-B bin helpers (designmatch x4, self-improve, sysmon, cleanup, stack-pack): (1) stay core, listed in HOST-CONTRACT [default]; (2) designmatch bins move with the skill in a later cycle.
- O-C lean-core overlap: (1) split phase 1 first, lean-core reads the new repo/mirror [default]; (2) lean-core first, split after.
- O-D pre-rename history: (1) carry only what `--path` follows [default]; (2) add the old paths to the filter list (needs a list of past names, UNMEASURED).
- O-E repo owner/names: (1) `randomittin/hmd-skills`, `randomittin/hmd-statusline` [default]; (2) another owner or a new org.
- O-F statusline runtime fetch: (1) never, bundled only [default]; (2) opt-in pack like skills in a later cycle.

## OUT OF SCOPE
Creating GitHub repos, pushing, tagging, publishing to skills.sh/npm (operator steps); runtime fetch of a skills pack into `$HEIMDALL_HOME` and the resolver change (next cycle, needs lean-core `skills_packs.py`); removing bundled copies (spec Stage 4); signing, permission manifests, overlays, `hmd skills suggest`; moving `skills/heimdall`, the designmatch/self-improve/sysmon/cleanup bins, `bin/heimdall-face`, `heimdall-status-json`, or any host entry point; making the statusline run without hmd installed; editing `install.sh`, `hooks/hooks.json`, `bin/heimdall`, agents or `skills.manifest.json` in phase 1; statusline perf or visual changes; version bump, release, tag.
