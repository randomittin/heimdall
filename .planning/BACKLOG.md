# BACKLOG

## 2026-10-14: deferred out of hmd 2.4.8

- [ ] ship.sh commits/checks/pushes the site pins in the release step (the operator requires the site committed and pushed in the same step as the release).
- [ ] A full ship publishes npm from the tag export, not the working tree.
- [ ] Narrow the kill guard to commands that could hit hmd's own processes.
- [ ] The push gate still allows (with a warning) a heimdall checkout with no heimdall-state.
- [ ] An aggregate-only relay counter of phone binds per week (no session id, IP or GitHub id), plus a DATA.md and store-privacy update.
- [ ] 496 of 531 suites still use bare mktemp and can leak on kill (adopt test/lib/private-tmp.sh); measured 2026-10-14 as test/*.test.sh files containing mktemp and not private-tmp (the earlier estimate was about 300).
- [ ] The Claude Code security-review pip bootstrap leaks pip-unpack-* dirs (not ours; report upstream).
- [ ] The session-login Keychain save blocks the bind for up to 40 s when the Keychain stalls.
- [ ] Suites still reach `security` under a sandboxed HOME: companion-cc-login-e2e, heimdall-ui-send-on-change, relay-client-enospc-recovery, app-upgrade-paired.
- [ ] `_write_device_record` (bin/heimdall-relay-client) emits an error every 15 s instead of once per outage.
- [ ] The hmdapp INBOX_CONSUMERS needs `wake` (hmdapp's job).
- [ ] The GTM homepage, privacy-page and site-changelog updates listed in docs/GTM-2.4.x.md.
- [ ] A repo that declares checks (`.heimdall/repo-checks.json`) and tracks `.planning/metrics.jsonl` (the rally layout: an hmd-initialised yarn project) cannot keep a clean-tree receipt: hmd keeps appending to the tracked file, so `bin/heimdall-repo-checks run` sees a tracked change before or after the checks (`git status --porcelain --untracked-files=no`, no exemption for hmd-owned paths), records `dirty: true` and the push gate blocks; `test/heimdall-push-gate-per-repo.test.sh` F4 gets a green receipt only by committing the churn first. Decide whether hmd-owned paths count as clean for the receipt, or whether managed repos stop tracking `metrics.jsonl`.
- [ ] The push gate (`bin/heimdall-precheck-bash`, `GP_RE`) does not arm on 11 ways of typing a push found in review, among them `bash --norc -c '...'` (a long option or `-o name` before `-c`), unquoted `eval git push`, a here-string (`bash <<< '...'`), a script piped into a shell (`echo '...' | bash`), process substitution (`bash <(...)`) and a variable as the command word (`$GIT push`), each confirmed unmatched against the matcher on 2026-10-15; only the native pre-push hook (core.hooksPath), where it is wired, gates them. Decide whether to widen the matcher or fail closed on a shell run over non-literal input.
- [ ] 2.5.0 (hmdapp list, hmdapp docs/superpowers/specs/2026-10-15-app-plan-reconcile.md; send after 2.4.8 ships): every item is a new hmd capability over the encrypted relay, none an HTTP endpoint. 1 `verdicts` block behind `verdict-v1`; 2 an allow command behind a new capability plus an audit record (who approved what, from which device); 3 `pause_all`/`resume_all`; 4 relay commands for reattack, start-task, rate-denial; 5 `approval_tier` with a fixed value set; 6 a denied push kind, keeping the two "finished" wordings stable; 7 optional per-device push rate limit for the watch; 8 later, one at a time: spend/budget status, goals, proposals/revert, Night Watch. Also `status-v1` (status block in the state frame).
- [ ] Carry into the 2.5.0 `status-v1`/`verdict-v1` design the review findings on the dropped app-v1 plan (docs/superpowers/plans/2026-10-15-app-v1-control-plane.md): golden fixtures need override points for machine state and a fixed `now`; a new remote switch needs entries in SWITCH_WORDS, the on-message chain and OPEN_SWITCHES/available(); `GATE_SWITCHES` must list a new gate switch; `test/lib/relay_contract_replay.py` must pin a fresh HEIMDALL_HOME; a denial `reason` must not carry free-text counterexamples; relay-diff guards must diff `main...HEAD`; `runhmd_schema` has no oneOf/anyOf.
- [ ] Five prompt-triggered auto-install plugins (`devops-toolkit`, `database-toolkit`, `seo`, `security-scanner`, `api-design`) are not in claude-plugins-official and fail loudly when triggered since 2.4.8 removed the wshobson fallback. Drop them from the trigger list or source them through the 3.1 overlay/consent model.
- [ ] The M0 exit check `git ls-files | grep -E '(^|/)\.heimdall/|heimdall-state\.json'` returns two root `.example` files tracked on purpose; decide whether to relocate them (issue_config.example_path, install-cp-endpoint and public-repo-no-secrets Proof B depend on the path).
- [ ] A fresh install's first Claude Code session starts a detached `heimdall-modules add headroom` (`uv tool install headroom-ai[all]`), measured at 4.47 GB within 150 s of install in a throwaway HOME (found by the install-stranger leak fix, 2026-10-19). Decide whether a fresh install should pull a multi-GB optional module without asking — it collides with the disk floor and the install-transparency stance.
- [ ] Suite closure soundness gaps (bin/lib/suite_closure.py schema 3), bounded only by the cache audit sample, the 7-day cap and cold x.y.0 receipts: a spaced `echo` word is treated as display text, so a function that echoes a path list consumed by `for f in $(fn)` loses those edges; a here-document written to a file with no `#!` is treated as a document; dispatcher functions reached by a computed name are not seen; a dispatcher injected through the environment is not followed. Static closure still re-runs ~500 suites for any edit to a widely sourced bin/lib file; the dynamic-tracing spike (docs/analysis/2026-10-20-dynamic-closure-spike.md) decides whether traced closures replace it.

## Link-safety leftovers (2026-10-20, after the 2.4.9 no-follow batch)
- `heimdall-checkpoint write` still READS `.heimdall/resume-notes.ndjson` through a link (read, not write: discloses a linked file into CHECKPOINT.md).
- `pmr_corpus._alarm` appends, and `purge` deletes, without the no-follow helper.
- Companion UI "save-checkpoint" labels every non-zero `write` exit "incomplete"; exit 4 (refused, unsafe path) needs its own label.
- `HEIMDALL_RELAY_CLIENT_BIN` (test override) lets the environment pick the program that receives the gh token. Same trust level as PATH, so not fixed alone; revisit if the env-trust model changes.
- (LOW, deferred 2026-10-21) Other SessionEnd writers follow links: `bin/heimdall-autocommit:145,148` (`.heimdall/receipts/unproven.log`), `bin/heimdall-reel:69-71,98,123,193,202` (`.planning/reels`), `bin/heimdall-context-sync:229-230,242,249` (reads into `hmd/context`), `bin/heimdall-checkpoint:431` (lists `.heimdall/cases/*` names). Route through `hmd_nofollow_write.py`.
- (2026-10-21) Suite closure schema 4 (835daa4e): heredoc-to-file edges, stripper quote state, file mode in hash, archived-receipt age/salt now fixed. Still open from the line-24 list: spaced echo words, no-shebang heredocs, computed dispatcher names, env-injected dispatcher. Deferred (MEDIUM): tool versions (bash/jq/python3/git) in the salt are read live, so a toolchain upgrade invalidates an archived cache-composed receipt; needs run-all.sh to record them.
- (MEDIUM, deferred 2026-10-21) `bin/lib/hmd_pair_optin.py` honours the test seam `HMD_TEST_CANONICAL_HOME` from the runtime env: a believed stand-in (0600 marker, outside any work tree) receives `off` writes instead of the real `~/.heimdall`. Reads still always consult the real home and its `off` wins. Replace the env seam with in-process injection or a build-time gate.

- [2026-11-12] sentinels/{sanity,security,doc-sync,spec-drift}.sh have no dispatcher after heimdall-watch+spawn deletion (637bcede): wire to a direct runner or delete.
- [2026-11-12] SessionEnd worker logs `heimdall-checkpoint write` rc 5 (deferred: sweep live) as "write failed"; treat rc 5 as deferred in hooks.json worker. `/hmd:save` (LLM path) not sweep-guarded.
- [2026-11-12] bin/heimdall-hooks and bin/lib/hmd_guardrail_enabled.sh still fall back to /tmp/.heimdall when HOME is unset (heimdall-guardrails no longer does, 0abd16dc): drop the fallback (a planted /tmp guardrails-off could switch off recommended guards).
- [2026-11-12] hmd_marketplace_add (first-run marketplace) is not recorded in skills.lock; INV-S6 covers plugin+skill lines only.
- [2026-11-12] discover-skills install of a raw owner/repo not in the manifest: consent gate's suggested lock row likely fails (skills_lock needs --kind); unverified. Also dead sed shim in test/discover-skills-bin-injection.test.sh:97-106.
- [2026-11-12] parallelism-check-bash has no guardrail off switch (T6.1): any check there changes the byte-identity trace in test/heimdall-precheck-bash.test.sh; put the switch inside bin/parallelism-tracker or widen that test's filter.
- [2026-11-12] launch nudge count (T7.1) parses `suggest`'s first line, which includes detected entries, so it says N recommended when some are detected-only (10 vs 9). Add a --json/--tier filter to suggest and count recommended only.

## Deferred findings (2026-11-12)

- [ ] MEDIUM: WORK_DIR defaults to PWD so every install writes PWD/.planning/skills.lock in arbitrary dirs, contradicting install-receipt.sh:107; fix: only record lock inside a git/hmd project (bin/discover-skills:144; review; release after v2.4.10)
- [ ] MEDIUM: no hook sources hmd_guardrail_enabled.sh, so 'hmd guardrails off <id>' reports switched off but has no effect; fix: wire into hooks or say not-yet-enforced (bin/lib/hmd_guardrail_enabled.sh:1; review; release after v2.4.10)
- [ ] LOW: --team mktemp task file (0600) left in /tmp if pane shell never runs the read line; fix: trap cleanup on launcher exit (bin/heimdall:--team; review; release after v2.4.10)
- [ ] LOW: hmd --skills install now captures git clone progress via hmd_skill_install; user sees no progress; fix: stream stderr (bin/heimdall:--skills; review; release after v2.4.10)
- [ ] LOW: checkpoint write exit 5 (deferred for sweep) reported by /hmd:continue as a generic failure; fix: map rc 5 to 'deferred during sweep' (bin/lib/hmd_continue.py:287; review; release after v2.4.10)
- [2026-11-12] skills consent tty menu header shows the manifest repo for a name even when a foreign repo was requested (stderr line names the real repo just before); build the header from the requested repo.
- [2026-11-12] (security review, MEDIUM) consent for a foreign repo under a manifest name: lock row ref/source also name the manifest repo; pass the requested repo to the gate (HMD_SKILLS_CONSENT_REPO) and use it in header + lock row.
- [2026-11-12] suite cache served 0 of 568 on three consecutive --failed runs ("568 changed or new") although only a few files changed between them; find what moves every closure hash (likely a hook-committed tracked file such as .planning/settings.json inside many closures) — the cache is not saving anything right now.
- [2026-11-23] bin/lib/agents_notif_index.pl parses task-notifications from any row (same loose pattern fixed in agents_open_scan.pl, 08515dda); only feeds the statusline count, but should trust harness rows only.
- [2026-11-23] companion_push.scrub leaves `PASSWORD=...` assignments unredacted; align with the redaction rules in agents_open_scan.pl.

## Deferred findings (2026-11-22)

- [ ] MEDIUM: req TTL restarts on every Stop (_HMD_SV_SINCE reset on USR1), so an active user who never idles 300s keeps the launcher running the gate (python+git+cc-selfheal) every 5s for the whole session; fix: anchor TTL at first request, not each poke (bin/lib/hmd_supervise.sh:286; review; release after v2.4.10)

## From 2026-11-22 use-case batch (MEDIUM/LOW)
- use-cases: journey 09 leaves a presence-keeper temp dir; add a presence-off marker in lib.sh `uc_sandbox`.
- use-cases: journey 09 goal-restore/agents-list/selectors and journey 11 printed-once/curl-log checks have no mutant rows.
- use-cases: move journey-local helpers (pty run, fake `claude agents --json`, curl double) into lib.sh once a 2nd journey needs them.
- repo-checks: `run-all` text match also warns on `npm-run-all` (false warning only).
- agent-templates.md Architect/Reviewer/Fixer templates and test-runner.md:40 still silent on use-case journeys; no guard suite pins the use-case wording in agent files.
- docs/split-repos.md Publish step 3 still shows hmd-skills v1.0.0.
- Two stale demo app copies (heimdall-demo-app/, packages/runheimdall/heimdall-demo-app/) hold the old pytest spec.
- hmd-statusline: 2 STALE fixtures (prefix-and-elements, viral-statusline) to rewrite or retire.
- HIGH-watch: Claude Code warns `plugin-agent-setting-deprecated` for hmd's plugin `settings.json` `agent: heimdall` ("will stop applying in a future release"). Move to a user-level `agent` key (backed up by lean T2.5) before it stops applying. Evidence: docs/analysis/2026-11-12-lean-agent-override.md.
- LOW: bin/heimdall-delivery-audit and bin/lib/hmd_plan_verify.py WOULD-BLOCK lines still mirror the sweep-only push gate (decision B accepts a use-case receipt); quality-gates.md and docs/ARCHITECTURE.md same.
- MEDIUM: install.sh leaves tracked bin/edit-tracker.c and bin/parallelism-tracker.c modified in the clone (found by lean T1.4 install baseline).
- LOW: hmd-statusline suite header/fixture copy differ from heimdall's cwd=/ fixture fix (3413b7e4); adopt statusline_sandbox payload rewrite at next pin bump.
- MEDIUM: run-all suite_timeout() needs arms heimdall-push-gate-per-repo=400, heimdall-app=600, app-pair-confirm=450 (solo 175/261/205 s vs 180 default; '# budget:' headers are not read). Salt change → cold sweep; ride the next release batch. Interim: --timeout 600.
- MEDIUM: hmd update dirty-tree guard (bin/heimdall:~3551) still reads an installed clone as dirty: .run-count/.unlock-* untracked, skill-restore/, install.sh chmod +x mode changes on bin/*.c. Fix: --untracked-files=no + ignore mode changes, or a runtime-state ignore list (found 2026-11-22, lean gitignore task).

## From lean-core review (2026-11-22, MEDIUM/LOW)
- MED lean_backup.py:135,58 restore overwrites any ANTHROPIC_BASE_URL/HEADROOM_*/hmd-matching hook, incl. user-owned ones added after the backup; scope to values hmd wrote.
- MED lean_backup.py:453 absent-at-backup files deleted on restore: module state created later is lost silently; warn or skip.
- MED install.sh:1448 failed lean apply on upgrade leaves old sparse patterns over new code; "keeping the full tree" message false; disable sparse on failure.
- MED install.sh:1465 a stopped --reset exits after fetch, skipping registration/hooks until next run.
- LOW hmd --reinstall wipe lands a previously-full user on lean (marker + skills-config deleted).
- LOW lean install omits skills/stacks and nothing writes packs/ yet: stack-pack finds no base packs until `hmd skills install stacks`.
- LOW route guard sees only the installer's env; --reset from another terminal edits settings env a routed session may use (documented).
- LOW docs/conversation-context.md referenced by heimdall/heimdall-lean prompts and SKILL.md no longer exists.
- First-launch checklist: picking a skill in a non-project folder writes <cwd>/.planning/skills.lock.
- MED headroom off --backup-dir copies whole settings.json (may hold tokens) into the lean backup with its own mode; chmod 0600 or copy only the hmd slice.
- [ ] MEDIUM test/no-auto-merge.test.sh fails on main (pre-existing, 8/9): unclassified hits in agents/heimdall-lean.md and skills/heimdall/references/lean-procedures.md:70 (lean-core). Found 2026-11-23.
- [ ] LOW bin/heimdall:5443 still says "Never retry same tier" — reword for the effort ladder (2026-11-23).
- [ ] LOW lean_context_parity counts gitignored untracked files (two empty Sept-21 *.tmp in skills/designmatch/.heimdall/ turned check red); measure tracked+unignored only (2026-11-23).
- [ ] LOW bin/designmatch on a lean install prints no `hmd skills install designmatch` hint (commands/designmatch.md is cut from lean by design) (2026-11-23).
- [ ] MEDIUM bin/lib/tier-table.json tier-level prices are stale for the 5.5 generation (sonnet $3/$15 vs $2/$10, opus $5/$25 vs $4/$20, haiku $1/$5 vs $0.10/$0.50; cache read 0.05x/0.025x). Every consumer of tier prices misreports cost; cost-forensics now uses model_prices instead (2026-11-24).
- [ ] MEDIUM (2026-11-24, security bot) evals/effort-ab/run.py sandbox profile is allow-default + deny file-write: no deny of mach-lookup (launchd/launchservicesd), appleevent-send or process-exec beyond the toolchain, so a child could reach outside via launchctl submit. Reads stay open except SECRET_PATHS: ~/Library/Keychains, ~/.claude, ~/.git-credentials, ~/.pypirc and browser profiles are readable. Fix: deny-default profile (or deny those services + paths), probe `launchctl submit`, eval-scoped API key, egress limited to the API host. Harness is manual-run on committed fixtures only.
- [ ] MEDIUM (2.4.12 review) bin/lib/hmd_read_dedup.py:71 detects only `compact_boundary`; a rewind or tool-result clearing without that marker leaves the stub claiming content is in context. Mitigated by the re-read valve (a read right after a stub gets full text). Fix: match any *compact* subtype or cleared-content marker (2026-11-24).
- [ ] MEDIUM (2.4.12 review) bin/heimdall-compact-window:311-319 `on` against a second settings path (CLAUDE_CONFIG_DIR changed) overwrites the first record/backup, so the first can't be undone. Fix: key the record by settings path (2026-11-24).
- [ ] LOW (2.4.12 review) bin/heimdall-compact-window:215 check-then-rename race (2026-11-24).
- [ ] LOW (2.4.12 review) tier-table model_prices rows and the autoCompactWindow key are not checked against a live source in any test (2026-11-24).
- [ ] LOW footprint --check red on pre-existing main-prompt overage (+826 B: main_prompt 68,211 vs 67,385) and lean-install bytes 15,707,300 vs 15,700,000; no test runs the check. Trim the prompt or re-baseline deliberately (2026-11-24).
- [ ] LOW evals/jev-ultrafast/{run.sh,bench.py} enter the runtime closure through the same bare run.sh name in bin/corpus; add to the closure POLICY like evals/effort-ab (2026-11-24).
