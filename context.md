# hmd/context — rolling session summary

> Read-only session state for a fresh machine / cloud job to RESUME from.

> Secret-scanned before every push. Orphan branch — never merged into main.

repo: randomittin/heimdall

generated_ts: 1785869326 (2026-08-04T18:48:46 UTC)

## What was being attempted
Auto-checkpoint — 2026-08-04T17:59:08Z

## Active goal
none

## .planning/CHECKPOINT.md (where we left off)
<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-08-04T17:59:08Z

> Written automatically at session end (mechanical, no LLM). Run `/hmd:save`
> for a richer human/LLM-authored handoff — it enriches this same file.

### Recent commits
- deeba30 merge: isolate headroom-module from the machine's install state
- 9cad9a9 merge: show away teammates as offline instead of erasing them
- 98497d0 test(headroom): isolate the suite from the machine's install state
- 11692a2 fix(wall): keep /roster-team online-only; document the 7-day window
- 3bf6ebb feat(wall): render away teammates as UNMISTAKABLY offline
- a6002a7 Merge branch 'main' into worktree-agent-a6b198e70de4da905
- 704fb73 feat(wall): 7-day offline window — server roster + ledger filter
- 37a8d27 merge: say plainly that the storage-codec half never engages
- 74d7f8b fix(headroom): the storage-codec half is unreachable via the documented install
- f94442f fix(headroom): narrow the storage-codec reach claim to what is actually wired

### Resume
Read this file, then `heimdall` to resume. If a goal is set above, restore it with `/goal <condition>`.
<!-- heimdall-auto-checkpoint:end -->

# Checkpoint — 2026-08-04

## Why this file got rewritten
The 2026-08-03 checkpoint recorded commits but NOT the work order, NOT which items were
awaiting RJ's approval, and NOT the open decisions. Cost: this session had to grep the raw
transcript JSONL to recover the V2/V11 specs. **A checkpoint that lists commits is a git
log with extra steps.** What belongs here is what exists ONLY in conversation: work orders,
approvals, gated decisions, and findings whose evidence is a measurement, not a file.

---

## VIRALITY WORK ORDER (V1–V12) — reproduced so it never needs recovering again
Full text is in the 2026-08-03 transcript.

| # | Item | Status |
|---|---|---|
Audited 2026-08-04 (read-only, pinned to `801ef7a`). **The original work order text is NOT
in this repo and is not recoverable from this machine** — `heimdall-path-to-viral.md` does
not exist, and the transcript store has no copy. V3/V7/V9/V10 names below are
RECONSTRUCTIONS, not ground truth. Supply the work order or V10 stays unauditable.

| # | Item | Verdict | Evidence |
|---|---|---|---|
| V1 | Fenced Heimdall block into target AGENTS.md | DONE | `edc1fab`+`139b8b9`; agents-md-injection 26/0, coexist 28/0 |
| V2 | Positioning flip to verification-forward | **DONE** (`2e0de31`) | landed AFTER the audit pin — the audit's "NOT STARTED" is stale. truth-pass 9/0, version-drift 17/0, npm-drift 1/0 |
| V3 | Complementary-comparison page + FAQ row | PARTIAL | site `b7492e8`+`b943cfa` built & committed but **UNPUSHED → not live**; `launch-docs/log-runner-and-gate.md` stale (3 UNVERIFIED the HTML already resolved) |
| V4 | Install optionality + Docker sandbox path | DONE, one path unexercised | `Dockerfile.install` real; version-pin-conformance 7/0. **Image has never been built** — no docker here, zero tests reference it |
| V5 | Render marked version pins from plugin.json | DONE | `a47f65f`+`17ad2f2`; 7/0, 63 PIN markers, 13 red mutants + 5 green inverses |
| V6 | Weekly changelog generator | DONE, **not routed** | `0e36d46`; weekly-log-consent 38/0. No `hmd weekly-log` route — absolute path only |
| V7 | rules-propose (commit says so; checkpoint name disputed) | DONE as scoped | `1ef3e0c`; rules-propose 33/0. Self-declares it implements the FIRST half of corpus SCHEMA §4 and none of the second |
| V8 | Badge offer + clip verification | DONE | `44acade`+`a4307f6`; badge-auto-offer 37/0 |
| V9 | Measurability before launch (name unconfirmed) | PARTIAL | cp-funnel-walk 13/0 but **local-proven only** — CP redeploy outstanding, so the funnel records NOTHING in production |
| V10 | unknown | **CANNOT-DETERMINE** | no V10-tagged commit anywhere; no artifact attributable with evidence |
| V11 | ACP adapter scoping | DONE (`801ef7a`) | 126 lines, 12 cited URLs, 2 UNVERIFIED. Recommends DON'T BUILD. Approved by RJ 2026-08-04 |
| V12 | Demo-team seeding for the live wall embed | PARTIAL — **own gate RED** | `011b961`+`9310485` exist ONLY on `worktree-agent-a5bbcf5f39ada9ac4`, NOT on main; site side uncommitted; demo-wall-honesty 16/12 |

**V12's 12 failures are one root cause + one false alarm** (both confirmed): the test's node
DOM double omits `document.documentElement`, so the inline script dies at `syncIcon()`,
`render.json` is never written, and 10 downstream checks read an absent file. H1's "assets
differ" is false — both hash `44a6978745a0da1b268d86fba4c547ae970860af557c3bce89f217a657bca7c6`.
Snapshot of the at-risk uncommitted V12 work: `/tmp/v12-snapshot/`.

**Unresolved launch-collateral markers (measured, not remembered):** SHOW-HN-DRAFT.md 16
RECEIPT lines · log-compression-and-gates.md **13** RECEIPT + 3 UNVERIFIED + 1 TODO (the
"19" previously recorded counted a mixed set — 13 is the honest figure) ·
HEADROOM-COMPANION-ASK.md 5 UNVERIFIED · log-runner-and-gate.md 3 UNVERIFIED. None
publishable; each file states its own block internally.

**V2 (verbatim):** site H1 → verification-forward lead; cloud bot demoted to the feature
row; same flip in README line 3 ordering. *Gate: no claim text changes, only ORDER/emphasis
— the claims falsifier must pass untouched.* Rationale on file: the overnight-bot category
has an 83k-star incumbent; the verification category has none. The work order said "pushes
site (authorized)" — **SUPERSEDED**: RJ said 2026-08-04 he does the commit with the release.
Agent does not push.

**V11 (verbatim):** read the ACP spec + Agent Canvas's agent-server surface; produce a
1-page feasibility doc — what an hmd ACP adapter exposes (gate_check/verdict/wall), effort
estimate, where it slots vs MCP Layer 1. No build until RJ reads it. *Gate: the doc cites
the actual protocol spec, not memory.*

---

## Landed this session
| sha | what |
|---|---|
| `92e94fa` | `hmd update` reconciles an old install against the default module set (35/0; falsified 32/3) |
| `4ec87bb` | bare `hmd update` dispatches — advertised but never routed, fell through to a splash banner that exits 0 (6/0; falsified 5/1) |
| `087891d` | per-module consent waiver — class contract byte-unchanged, every other traffic-proxy module still asks (65/0) |
| `2cfbeb9` | local rewriting proxy kept off the signed CP path (44/0; falsified 25/19) |

## THE OPEN DEFECT — blocks the release
`hmd modules add headroom` prints `Installed "headroom" at pin 0.33.0` while `uv tool list`
reports `No tools installed`. `installs_via.kind: "upstream"` is validated (~line 427 of
bin/heimdall-modules) and recorded into DIGEST_JSON (~line 777) but **never executed**.
Headroom does NOT arrive via `hmd --update` — only its registration does, under a success
message. Fix agent in flight.

## Findings whose evidence is a measurement (not recoverable by reading the tree)
- **The inverted invariant.** `no-signed-traffic-routing` passed when it found NO proxy vars
  in the CP binaries — but that absence is exactly when curl inherits an ambient one.
  Measured: CP `/readyz` = 200 clean, 000 under a dead ambient `HTTPS_PROXY`, invariant
  printing `BYPASS-OK` throughout. Fixed in `2cfbeb9`.
- **Why not blanket `--noproxy '*'`:** a corporate CONNECT proxy tunnels TLS end-to-end,
  cannot rewrite signed bytes, and is the ONLY egress in locked-down estates. Only a LOCAL
  REWRITING proxy must be excluded. This is why the fix is narrow — do not "simplify" it.
- **`test/cp-signed-no-rewriting-proxy.test.sh` is network-dependent.** Probes the live CP
  and fails closed, so a blip reads red (observed once: 43/1, then 44/0 twice). Correct
  behaviour; means it cannot gate a push without guaranteed egress.
- **The board eats uncommitted work.** `test/run-all.sh` falsifiers `git checkout --` the
  files they mutate, silently destroying uncommitted changes. Cost an hour debugging a
  "broken" agent whose file had been reverted under it.
  → `.claude/agent-memory/hmd-heimdall/feedback_board_wipes_uncommitted.md`
- **Agents truncate at ~106–196k tokens** — SIX today. The ones told to commit early kept
  their work. `SendMessage` resume-from-transcript works and beats respawning.
- **The reaper deletes "merged" worktrees that hold uncommitted work.** It removed the
  docs-rewrite worktree; only a patch taken minutes earlier survived.

## Held back deliberately
- `/tmp/docs-rewrite.patch` (34KB, applies clean) — README/DATA/install.sh rewrite. Claims
  Headroom ships as part of hmd (FALSE until the fetch fix lands) and that the CP invariant
  is re-checked live (only true as of `2cfbeb9`). Its worktree was reaped; **this patch is
  the only copy.**
- Launch collateral carries unresolved `[RECEIPT:]` markers — SHOW-HN-DRAFT.md (16) and
  log-compression-and-gates.md (19) at last count. Not publishable while they stand.

## RJ-ONLY
- 193+ unpushed commits. The agent never pushes.
- `sudo xcrun simctl runtime delete 7A7EA18E-070C-4209-8C20-A90FFADC3AF5` — iOS 18.6, zero
  devices, the only mounted runtime volume (~8G disk + unwires memory). sudo cannot read a
  password from the agent's shell.
- Control-plane redeploy · A1 check 4 (production write) · A2 wall recording.
- **Headroom live install NOT approved.** Needed to convert gates-read-raw from mock-proven
  to live-proven. No longer disk-blocked (16Gi free).

## Resume
1. Land the upstream-fetch fix; re-verify `add` reports ABSENT when nothing installed.
2. Land V2 + V11 when their agents report; reconcile V2's README edit with the held patch.
3. Trust the V1–V12 audit table over any "unconfirmed" row above.

## .planning/STATE.md (current state)
# Heimdall — STATE (2026-08-03)

## Current phase
**Gate-integrity remediation, complete.** Worked the agent-doable half of `heimdall-path-to-viral.md`;
the work turned into a false-green hunt when the first full test-board run exposed 8 red suites (7 unknown)
and the pre-push chain was found to be silently no-opping. 66 commits on `main`, **unpushed**. Agent never pushes.

## What's done
See `.planning/CHECKPOINT.md` for the annotated list with commit hashes. Headlines:
- `echo|jq` payload corruption disabled the entire pre-push chain (215/312 hook invocations). Fixed + class-guarded.
- 5 gates proven vacuous by plant-and-check; secrets gate passed over zero files; all fixed.
- Install one-liner was dead on both READMEs (wrong digest, then wrong ref). Fixed, verified end-to-end.
- A live false privacy claim on the marketing site, in 3 places. Fixed and pushed (site repo `243103b`).
- Single test runner built; all 8 red suites now green; 13 unparsed suites now report counts.
- D11 funnel built server-side with zero new client egress; D12 posts live; A1 receipt committed.

## What's in progress
- `bin/heimdall-selfscan` tree-mode blind spot — staged in `.claude/worktrees/agent-a0e437c9bb4108256`, not landed
  (agent truncated mid-fix with a known-broken assertion in its own test).
- Full board re-run writing to `/tmp/board2.log`.

## What's next
Nothing agent-doable of consequence. The remaining launch-plan items are RJ-credentialed:
session restart, control-plane redeploy, A1 check 4, A2 recording, push, submissions, posting.

## Blockers
- Today's hook fixes are inactive until the session restarts (hook config loads at session start).
- The D11 funnel records nothing until the control plane is redeployed.
- B6 hero is blocked on A2, which needs a non-empty team wall + `asciinema`/`agg` installed.

## Decisions made
- **R13**: Agent spawns are UNNAMED by default. `name:` makes a mailbox-resident agent that never returns
  (measured 0/43 named completed vs 59/66 unnamed).
- **D11 amended to 5 stages.** The 8-stage version cannot ship without amending a signed constitution-level claim
  in IDENTITY.md; K-factor's numerator and denominator are both in the free tier, so the rationale survives.
- **Fail closed everywhere.** An unreachable verifier renders NON_VERIFIED, never OPEN. An empty scan fails loudly.
- **Allowlist secrets by SHA, never by path** — a path entry blinds the gate to a future real credential.
- **Quality gate blocks on a real FAIL verdict only**; absent state warns loudly but proceeds (auto-init would
  block every fresh clone and train users onto `--no-verify`).
- **`?src=copy` removed rather than surfaced** — disclosing it destroys the metric it collects.

## Key files changed
`hooks/hooks.json` · `bin/heimdall` · `bin/verify-edits` · `bin/edit-tracker.c` · `bin/summary-card` ·
`bin/heimdall-selfscan` · `bin/bloat-gate` · `bin/heimdall-live-verify` · `bin/lib/cp_funnel.py` ·
`bin/lib/crontab-safe.sh` · `deploy/cloud-run/check-public-surface.sh` · `evals/oracles/registry.json` ·
`README.md` · `packages/runheimdall/README.md` · `test/run-all.sh` + ~30 suites.

## git log --oneline -20
eb61741 feat(roster): the wall knows everyone on the repo, not just who is beating
caebaad merge: make three gates report what actually happened
9c1a217 merge: stop printing "digest-verify" where no digest is verified
f0b823f fix(gates): make three gates report what actually happened
ee943aa fix(modules): stop printing "digest-verify" where no digest is verified
98364a3 feat(roster): salvage repo-roster data layer (module + suite + fixture)
a6f524c merge: name the binding constraint, and stop the codec seam misreporting itself
9744d1d docs(headroom): name the BINDING constraint on the storage-codec half
b9640cb docs(analysis): finish line-number citation corrections
167e36a docs(analysis): correct two line-number citations in the red-team audit
10cea10 docs(analysis): HN red-team pre-launch audit — 13 findings, 7 must-fix
e53feaa fix(memory-codec): register_backend("headroom") was a silent no-op
d48b307 docs(analysis): HN red-team interim findings
b4c5223 docs(analysis): start HN red-team audit
30a8073 heimdall: session-end checkpoint (1 files)
deeba30 merge: isolate headroom-module from the machine's install state
9cad9a9 merge: show away teammates as offline instead of erasing them
98497d0 test(headroom): isolate the suite from the machine's install state
11692a2 fix(wall): keep /roster-team online-only; document the 7-day window
3bf6ebb feat(wall): render away teammates as UNMISTAKABLY offline
