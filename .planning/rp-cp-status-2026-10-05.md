# RP / CP status matrix -- 2026-10-05

Sources: `hmdapp/docs/HANDOFF-TO-HEIMDALL-runhmd-plan.md` (RP1-RP13), `hmdapp/docs/HANDOFF-TO-HEIMDALL-cursor-parity.md` (CP1-CP9).
Method: `git log main --grep`, `git ls-tree main` for every file/test the ask names, and per-suite runs on main
(no full sweep). Main tip moves under concurrent journal/merge commits; evidence is by file + commit, not by tip SHA.
Suites run 2026-10-05 (all exit 0): hmd-attack 135/0, hmd-prove 103/0, runhmd-receipt 420/0, false-green-benchmark 67/0,
runhmd-wrapper 76/0, heimdall-controls 90/0, companion-view 86/0. `bin/falsify attack --assert-score 1.0` -> 7/7 = 1.0000.
`hmd attack fixtures/attack/buggy-webhook --json --yes` -> DENIED, 1 finding; `clean-sample` -> PROVEN; `hmd attack . </dev/null` -> exit 3.
`hmd prove` was NOT executed end to end here (full gate sweep is the expensive path, needs `--yes`); its evidence is its suite.

## Matrix

| Ask | State | Evidence | Gap |
|---|---|---|---|
| RP1 `hmd attack` | DONE | `bin/heimdall-attack`, `bin/lib/runhmd_attack.py` (flags --diff --batch --out --card --json --yes --max-usd --no-network --no-upload --receipt), `evals/oracles/attack/` (golden + 6 mutants, ref author separate), `fixtures/attack/{buggy-webhook,clean-sample}`, `test/hmd-attack.test.sh`; commits 2df6cb38, cf3d490b, 3cb4fade | `<pr-url>` target not verified here; adapter breadth is RP9 |
| RP2 `hmd prove` | DONE | `bin/heimdall-prove`, `bin/lib/runhmd_prove.py`, `test/hmd-prove.test.sh`; commit 9eb2befb | none known |
| RP3 receipts | PARTIAL (local half done) | `bin/heimdall-receipt` (verify/keygen/render/serve), `bin/lib/runhmd_receipt*.py`, `docs/schemas/runhmd.receipt.v1.json`, `docs/RECEIPTS.md`, `test/runhmd-receipt.test.sh`; commits cfe55424, 61bf84df, 5e9941c7 | Hosted service NOT built (RECEIPTS.md:81): `POST /api/receipts`, `GET /r/<id>/card.png`, `POST /r/<id>/f/<fid>/rate`, "request cloud access" CTA. No Worker. |
| RP4 benchmark harness | DONE (harness); Study A NOT RUN | `bin/benchmark` false-green suite, `evals/benchmark/false-green/` (PREREG.md, PREREG.lock.json, 1 task, results/{design-set,judge-calibration}.jsonl, ENV.json), `evals/benchmark/reproduce.sh`, `test/false-green-benchmark.test.sh`; commits a902ae09, 97911707, bfc6ff95 | Signed tag `benchmark-prereg-v1` does NOT exist (`git tag -l` empty). Only 1 task (spec headline needs >=30 tasks, >=2 agents). Layout deviates from spec (`evals/benchmark/false-green/`, documented in PREREG s3). Study B rows exist; no Study A number. |
| RP5 precision programme | NOT STARTED | no `hmd rate`/`hmd precision`, no `ratings.jsonl`/`gates-state.json` anywhere in bin/ or skills/ | all |
| RP6 cost visibility | PARTIAL (attack cap only) | `--max-usd` + exit 4 + `budget_cap` doc in `runhmd_attack.py:45,93`; `bin/heimdall-cost-report`, `heimdall-cost-model-refresh` exist | no `hmd cost`, no `.runhmd.yml` budget, no `hmd night plan` (no `hmd night` at all), `receipt.cost_usd` not from real accounting |
| RP7 zero-install + `demo --offline` | PARTIAL | `packages/runhmd/` (bin/runhmd.js, package.json v2.4.3, subcommands.txt), `test/runhmd-wrapper.test.sh` 76/0; commit 94f22259 | `test/zero-footprint.test.sh` absent; `bin/heimdall-demo` has no `--offline`; npm publish/claim state unverified |
| RP8 GitHub App backend | NOT STARTED | only `bin/heimdall-gh-app-token` (token mint) + `relay/` Worker pattern; no webhook receiver, no `.runhmd.yml`, no renderer, none of the 3 named tests | all |
| RP9 adapter interface | NOT STARTED | no `docs/ADAPTERS.md`, no `adapters/`; only `hmd attack --diff` (gitdiff fallback, RP1) and the 2026-08-25 design doc | contract, claude/codex/gemini adapters, independent conformance suite |
| RP10 hygiene bundle | NOT STARTED | absent: `NAMING.md`, `PARKED.md`, `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, `test/no-auto-merge.test.sh`, `hmd metrics`/`weekly-review` (a `metrics)` arm exists at `bin/heimdall:2366` but with different semantics -- verify before reuse); `README.md` is 468 lines (need <150); `release/sync-release.sh` emits no `release-manifest.json` | all 7 sub-items |
| RP11 mobile verdict state/events/commands | NOT STARTED | no `verdicts`/`morning_report` state key, no `verdict-v1` cap, no `denied`/`pr_ready`/`morning_report` push kinds (`companion_push.py:104` KINDS lacks them), no sealed verbs rate/reattack/fix_request/pr_decision/task_new | all; depends on RP3 + RP5 |
| RP12 entitlement + invite | NOT STARTED | no `hmd entitlement`, no `invites.jsonl` | all; depends on RP3 |
| RP13 mobile security model | NOT STARTED | no `docs/REMOTE-COMMAND-SCOPES.md`, no `test/remote-scopes.test.sh`, no `audit.jsonl`/`audit_list`, no `HMD_REMOTE_SEND`. (`! grep shell=True` in relay client already holds. CP1's `controls-audit.jsonl` is a different file/schema.) | all; depends on RP11 verbs |
| CP1 controls module | DONE (with one carve-out) | `bin/lib/companion_ui_controls.py` (`ALLOWED_ACTIONS`, interrupt/save-checkpoint/hook-toggle + fallback-mode), `controls-v1` in `bin/heimdall-relay-client`, `state.controls`, `hmd app controls`, `test/heimdall-controls{,-relay}.test.sh`; merge 4b029417 (abf53e18, aa3c14ca, 700078a0, bea828a2) | CP1 addition 2 absent: no `read/safe-write/risky-write/expand` class tags, no `launch-stop` kill-switch exemption (grep count 0). Fold into CP2. |
| CP2 shared safeguards | NOT STARTED | no `hmd app remote-launch/remote-merge/launch-allow` (`bin/heimdall-app` dispatch ends at connect/identity/status/disconnect/doctor/remote-login/controls/push-test), no `remote_actions` state key, no `test/heimdall-remote-switches.test.sh` | all |
| CP3 keep-awake | NOT STARTED | no `keep_awake`/`keep-awake` in bin/heimdall-app or relay client; no test | all |
| CP4 per-device revoke/listing | NOT STARTED | no `hmd app devices`, no `state.devices`, no `test/heimdall-devices.test.sh`. `hmd app identity revoke` exists (different: identity, not device) | all; relay-side device-scoped revoke lives in hmdapp (fallback to whole-session allowed by spec) |
| CP5 `view-v1` | PARTIAL (diff only) | `bin/lib/companion_view.py` (`SERVED = ("diff",)`, line 70; transcript/reel/pr answer `not-implemented`), `view-v1` in relay client, `test/companion-view.test.sh` 86/0; merge 7cdcd86c (5fb3e7ca, aed9068a, d6028698, 2163d911) | transcript, reel, pr kinds; `test/heimdall-views.test.sh` (spec name) absent -- suite is named `companion-view` instead |
| CP6 `attach-v1` | NOT STARTED | no code, no test | all |
| CP7 `launch-session` | NOT STARTED | no code, no test | all; hard-blocked on CP2 |
| CP8 `pr-merge` | NOT STARTED | no code, no test | all; blocked on CP2 + CP5 `pr` kind |
| CP9 `review_ready` + Live Activities | NOT STARTED | `companion_push.py:104` KINDS = question, approval, error, gate_red, finished, test; no `liveactivity` | all |

Tally: DONE RP1, RP2, RP4*, CP1 (4); PARTIAL RP3, RP6, RP7, CP5 (4); NOT STARTED RP5, RP8, RP9, RP10, RP11, RP12, RP13, CP2, CP3, CP4, CP6, CP7, CP8, CP9 (14).
(*RP4 harness done; the headline Study A is not.)

Spec-name drift to report back in the handback: RP4 layout, CP5 test name. Neither breaks a contract.

## Not-started items: acceptance, size, deps, operator needs

Acceptance commands are the ones in the handoffs, abbreviated; the handoff text is authoritative.

| Ask | Acceptance (key) | Size | Depends on | Operator credentials / actions |
|---|---|---|---|---|
| RP3-hosted (remainder) | `curl -fsS $BASE/r/<id>.json \| jq -e '.schema=="runhmd.receipt/1"'`; card.png content-type; public card of private repo omits `minimal_input`; tamper -> `hmd receipt verify` non-zero | L | RP3 local half (done) | Deploy: Cloudflare account, `runhmd.dev` route, production signing key custody. Code + miniflare tests need none. |
| RP5 | 7/10 ratings -> `hmd precision --json \| jq -e '.gates[0].disabled==true'`; re-enable test; `hmd rate f-1 false --json \| jq -e .ok` | M | RP3 (receipt rate endpoint) | none |
| RP6 (remainder) | `hmd cost --json \| jq -e '.usd_per_proven_pr!=undefined'`; cap 0.01 fixture -> exit 4; `hmd night plan` refuses without `--budget` | M | RP3 (cost_usd in receipt) | none |
| RP7 (remainder) | `test/zero-footprint.test.sh`; `hmd demo --offline --json \| jq -e '.sequence==["DENIED","PROVEN"]'`; `npx --yes runhmd@latest --version` | M | RP1 | Claim + publish npm name `runhmd` (npm login, 2FA). Test + demo need none. |
| RP8 | `test/gh-app-webhook.test.sh` (bad sig -> 401), `test/pr-comment.golden.sh`, `hmd config check` 0/2, `test/gh-app-cap.test.sh` | L | RP1, RP3, RP6 (cap), RP9 (nice) | Register the GitHub App in GitHub UI (manifest supplied by heimdall); webhook secret; Worker deploy. Code needs none. |
| RP9 | `python3 -m adapters.conformance --adapter claude\|codex\|gemini\|gitdiff` each exit 0; conformance authored in a separate wave from adapters | M-L | RP1 | none (gemini adapter may need a Gemini CLI/key to exercise live; conformance can use recorded fixtures) |
| RP10 | `test -f NAMING.md PARKED.md docs/INSTALL.md`; release-manifest curl; `hmd metrics --json \| jq -e 'has("false_green_rate")'`; `bash test/no-auto-merge.test.sh`; README < 150 lines | M | RP1 (README section), otherwise none | Publishing the manifest as a release asset = GitHub release, human step. Site-side CI check is in the site repo. |
| RP11 | `test/heimdall-verdicts-state.test.sh`, `test/heimdall-push-denied.test.sh`, refusal codes bad-params/not-entitled/budget-cap/not-allowed | L | RP3, RP5, RP6, RP12 (task_new entitlement), operator ruling MB-Q1 (pr_decision approve) | Ruling MB-Q1; hmdapp work is blocked on this |
| RP12 | `hmd entitlement grant t-1 cloud --json \| jq -e .cloud`; request without true-positive finding rejected | S-M | RP3, RP5 (true_positive label) | Operator grants (`hmd entitlement grant`) at runtime; cohort cap default 5 |
| RP13 | `test/remote-scopes.test.sh`, `test/audit-log.test.sh`, `! grep -n "subprocess.*shell=True" bin/heimdall-relay-client` | M | RP11 verbs, CP1 | Decision on `HMD_REMOTE_SEND` default; engage the external reviewer (not heimdall's job) |
| CP2 | `test/heimdall-remote-switches.test.sh` (non-TTY `on` refused; no ALLOWED action writes switch files; symlink swap -> not-allowed; audit line in both logs) + 3 named mutants | M | CP1 (done) | Operator flips `hmd app remote-launch/remote-merge on` at a TTY later; build needs none |
| CP3 | `test/heimdall-keep-awake.test.sh` (stub caffeinate argv `-i -w <pid>`) ; `grep -q keep_awake bin/heimdall-app` | XS | none (spec order after CP2 is soft) | none |
| CP4 | `test/heimdall-devices.test.sh` (fake relay; no key material in `state.devices`) | M | CP1; relay device-scoped revoke is hmdapp-side, fallback allowed | none |
| CP6 | `test/heimdall-attach.test.sh` (magic, sha, EXIF strip, 0700/0600, TTL, 4 mutants) | L | CP1, CP2 (kill-switch plumbing); needs an imaging lib decision (spec: refuse `bad-mime` if none) | none |
| CP7 | `test/heimdall-launch.test.sh` (stub tmux/claude; main checkout unchanged; 5 mutants) | L | CP2 (hard), CP5 | opus-high review sign-off before ship; default stays off. Pairing choice (reuse binding vs fresh code) is an open question to the operator. |
| CP8 | `test/heimdall-prmerge.test.sh` (fake gh; head/receipt/gate checks; 4 mutants); amend CONTRACT 7.4 class 18 | M | CP2, CP5 `pr` kind | `gh` auth on the laptop (already the case); operator turns `remote-merge on` + allowlist `--merge` |
| CP9 | `grep -q review_ready bin/lib/companion_push.py`; flip/debounce/receipt-gate cases; 337 existing push checks + 16 mutants stay green | L | none hard (CP2 not required); Live Activities need APNs | Project-owned APNs key (`hmd app push apns-key <path>`) -- operator-run. `review_ready` alone needs none: ship it first, Live Activities second. |

## Operator-gated items (cannot finish without a human)

1. RP4 Study A: authorise paid model calls + budget; create the SIGNED tag `benchmark-prereg-v1` before the first Study A row (requires the operator's signing key; the repo test re-proves ordering from history). Grow the task set beyond 1 task first.
2. RP3 hosted: Cloudflare deploy, domain, production signing key.
3. RP7: npm name claim + publish.
4. RP8: GitHub App registration + secrets.
5. CP9 Live Activities: APNs key. RP13: external reviewer. RP11: ruling MB-Q1.
6. RP10: publishing the release manifest asset (human merge/release boundary).

## Proposed next wave (6 parallel, file-disjoint)

Same-wave disjointness check: RP10 is the only task allowed to edit `bin/heimdall` (dispatch). RP7 edits `packages/runhmd/`, `bin/heimdall-demo` (the `demo)` arm already exists at `bin/heimdall:1717`, so no dispatch edit). CP2 owns `bin/lib/companion_ui_controls.py`, `bin/heimdall-app`, `sentinels/hmd-ui.py`. CP5-rest owns `bin/lib/companion_view.py` and its suite. RP9-conformance owns a new `adapters/conformance/` tree and `docs/ADAPTERS.md`. RP3-hosted owns a new top-level directory (not `relay/`).

| # | Task | Why now | Size | Agent |
|---|---|---|---|---|
| 1 | RP3-hosted: receipt Worker (POST /api/receipts, /r/<id>, .json, card.png, rate, CTA) with miniflare tests; no deploy | Critical path: blocks RP5, RP6, RP8, RP11, RP12 | L | `hmd:coder` sonnet |
| 2 | RP10 hygiene (NAMING, PARKED, docs/INSTALL+ARCHITECTURE split, README <150, release-manifest in `sync-release.sh`, `hmd metrics --json`, `test/no-auto-merge.test.sh`) | Plan priority 4; also the owner of the `bin/heimdall` dispatch edit this wave. Check the existing `metrics)` arm first | M | `hmd:coder` sonnet (+ `hmd:docs-writer` for the prose split) |
| 3 | RP7 remainder: `test/zero-footprint.test.sh`, `hmd demo --offline` | Cheap, unblocks the "npx runhmd attack" trial path | M | `hmd:coder` sonnet |
| 4 | CP2 shared safeguards + CP1 carve-out (class tags, `launch-stop` exemption) | Gates CP6/CP7/CP8 | M | `hmd:coder` sonnet; opus-high review (security-relevant switches) |
| 5 | CP5 remainder: transcript, reel, pr kinds | CP8 needs the `pr` kind; sibling of finished diff work | L | `hmd:coder` sonnet |
| 6 | RP9 step 1: `docs/ADAPTERS.md` + independent conformance suite + `gitdiff` adapter wired to `hmd attack --diff` | Conformance must be authored in its own wave, before claude/codex/gemini adapters | M | `hmd:coder` sonnet (author != later adapter author) |

Held for the wave after: CP3 (XS, but touches `bin/heimdall-app` like CP2; fold into the following wave), CP4 (same file), CP9 `review_ready` (touches `companion_push.py` only; a strong candidate to swap in if a slot opens, no hard deps), RP5, RP6 (both need `bin/heimdall` dispatch and RP3), RP12, RP11, RP13, CP6, CP7, CP8, RP8, and RP9 claude/codex/gemini adapters. Each new gate ships golden + mutants and `bin/falsify <domain> --assert-score 1.0`; no sequence-producing gate may be property-only.

## Red flags

- RP4's headline rests on 1 task and 0 agent runs; Study B numbers must never be quoted as agent false-green rates (PREREG s1 already binds this).
- The signed prereg tag is missing; if Study A rows are ever generated first, the repo's ordering test fails by design.
- `bin/heimdall` dispatch is a shared write point for RP5/6/10/12; serialise across waves or have one task own it per wave.
- RP3 "DONE" in someone's notes would overclaim: only the local half exists (docs/RECEIPTS.md:81 says so itself).

## OUT OF SCOPE

This file is a status snapshot only. It does not implement any item, edit the hmdapp handoffs, write the handback to `docs/HANDBACK-FROM-HEIMDALL-runhmd-plan.md`, run the full gate sweep, deploy or publish anything, or decide the operator rulings listed above.
