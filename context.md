# hmd/context — rolling session summary

> Read-only session state for a fresh machine / cloud job to RESUME from.

> Secret-scanned before every push. Orphan branch — never merged into main.

repo: randomittin/heimdall

generated_ts: 1791376206 (2026-10-07T12:30:06 UTC)

## What was being attempted
Landed

## Active goal
none

## .planning/CHECKPOINT.md (where we left off)
[...trimmed to the last 150 lines...]
**3. Branch triage — 7 of 8 stranded branches DROPPED**, verified by tree comparison not by
subject line. Three were byte-identical to main; three would have REVERTED main to older
designs (one would have deleted the very never-reap guard its subject claimed to add).
Only Headroom A/B was real → merged. **Nothing deleted: 2 of those worktrees hold live
agent-memory.**

## Landed
- `bin/heimdall-ctx-meter` — the $369.50 fix, enforced. Silent <150K; ceiling 150K;
  cliff-near 700K; emergency 800K (the measured quintile boundary where cache-write goes
  13,320→42,183). Unreadable = NON_VERIFIED, never OK. Statusline publishes (the only place
  Claude Code exposes context size — no hook receives it), `UserPromptSubmit` reads, notice
  to **stderr** so the warning never costs context. Its suite was mutation-tested and one
  mutant SURVIVED (notice moved to stdout) — the frequent paths were unproven; fixed, 68/0.
- `bin/heimdall-graph` — def/refs/callers/callees/impact/outline. 93,166 B raw vs 1,323 B
  outline = 70x. **Recovered from a truncated worktree: work complete and green, only the
  commit step lost.**
- `heimdall-brief` joined to the graph and actually routed (it was dead code since 17 Jun).
  1.60x on the prompt, 28.7x downstream.
- Two fail-OPEN holes closed in the brief path (a second assembler that never failed +
  an unvalidated invariants ref). **Mutant proof run by me after that agent truncated:**
  no-op the accumulator → (b3)(b4) RED with rc=0 where refusal required; restore → 31/0.
- SessionStart hook advisories cut to one line each.
- Checkpoint depth fixed. **bash 3.2 bug: `printf '- **Branch:** %s\n'` parsed the leading
  `-` as a flag — EVERY checkpoint ever written on this machine silently lost Branch, HEAD,
  Phase, goal and dirty-count.** That is why resuming felt like starting over.

## Open
- 30+ commits unpushed — **push stays with RJ, agent never pushes.**
- 5 parallel-flaky suites (above).
- `sentinels/lib/brief.sh` capsule store still empty → `--capsules` wired but unexercised.
- Reachability gate RULE B loophole: a dead chain citing itself reads as reachable.
- `launch-docs/log-compression-and-gates.md` markers still unresolved.

---

# Session record — 2026-08-08 (directives D1–D5 + two specs)

## REFUTED THIS SESSION (spec 1.4: the most expensive knowledge to re-derive)

1. **"The $57.73 Stop hook is a wrong-tier bug; export SECURITY_REVIEW_MODEL=haiku."**
   REFUTED, and it was MY claim to RJ. Wrong hook (the spend is the PostToolUse *agentic*
   commit/push review, `SG_AGENTIC_MODEL`; the Stop hook posts over raw HTTP, writes no
   transcript, contributed $0.00) and wrong direction (it downgrades a real vulnerability
   reviewer). Setting the var also suppresses the plugin's fallback, so a typo silences the
   reviewer. **The tier stays opus; the line is irreducible.** Honest saving on that surface
   is ~$8–14/window via `MAX_STOP_HOOK_FIRINGS`. Memo:
   `docs/analysis/2026-08-08-security-review-tier-decision.md`. Pinned by
   `test/security-review-tier.test.sh` 13/0. Commit `047d61a`.

2. **Compaction spec B1: "the SessionStart:compact index is the prime suspect, 10–18KB."**
   REFUTED. Measured **6,601 B/compact** — ~a third of the low estimate, and FIFTH behind
   `agent_listing_delta` (16,295 B), `compact_summary` (15,061), `attach:file` (10,108) and
   `hook:SessionStart` (9,311). The real lever is **STANDING overhead ~55,247 tok = ~76% of
   baseline** (spec item B4, listed fourth → moves to first). The largest single re-injection,
   `attach:agent_listing_delta`, is not in the spec at all.

3. **Compaction spec B2: "graph-first reading for the orchestrator."** REFUTED as a priority.
   `tool:Read` is **0.8%** of per-turn additions. The graph's measured 28.7× win is
   generation-side (spawn briefs), not orchestrator context control.

4. **"Compact every ~2 turns."** Corrected, not refuted: true in PROMPTS (1–5 human prompts
   between compacts) but the mechanism is **42–80 API requests per compact window**. Median
   turn is 989 tokens — already small. Writing less per turn fixes nothing.

CONFIRMED: B3 (envelope handbacks) — the agent-orchestration family is **14.4%** of per-turn
additions and is the one term that grows with parallelism. B5 reinforced: do NOT raise the
threshold; the 984K–1M regime is where the cache-write cliff lives.
Findings: `docs/analysis/compaction-arithmetic-findings.md` (commit `5f44c48`).

## THE SESSION'S DOMINANT FINDING

**Dead-on-arrival is the DEFAULT outcome of a build task, not a rare slip.** Building the
consumer audit produced THREE unwired subsystems in one session: `heimdall-sla` (no
consumer), `heimdall-tier` (no `tier)` dispatch arm), and the liveness manifest declaring
seven subsystems that record nothing. An agent told to "build X" delivers X wired to
nothing, because its acceptance criteria are about X. **Spawn instructions must name the
consumer as a deliverable, as a separate committed unit.**

Second-order: **agents that batch their commit to the end lose everything.** Five of eight
agents this session truncated; those that committed per unit lost nothing, and every
salvage was done from the worktree via git, never from the agent's report.

## LANDED (all local, nothing pushed — push stays with RJ)

`c15ac48` ctx-meter · `db410b2` symbol graph · `a2982b4` brief · `f36aa1b` forensics ·
SLA (33/0, mutation-proven) · `047d61a` tier refutation (13/0) · `4269b2d` liveness
(26/1, red is load-bearing) · `bd7e84b` consumer audit (14/3, all three real) ·
`9b72263` compaction harness (32/0) · `5f44c48` findings · `519dbbc` tier table +
wiring (29/0, 47/0) · graph overlap Q1–Q4 complete (`c5d6a44`, `01f0063`, `9733a32`,
`5d1fc99`).

## OPEN

- Resume-probe suite: `checkpoint-completeness` 42/0; `resume-probe` hung past 240s under
  4-agent git contention — re-running. **Do not claim the probe green until it is.**
- `heimdall-conformance` shipped with NO suite (its author truncated); agent writing one.
- Dead-chain reachability still CLEARS (falsifier written and failing) — agent on it.
- Q4 verdict: the sampling-falsifier guard **does not exist**; sufficient today only because
  no gate consumes the graph. If one ever does, `symbolgraph.py` never abstains — "no callers"
  and "blind here" are byte-identical at exit 0, over 552/749 shell files.
- **Full gate has NOT been run this session** (1374s) — runs once, at the end.

---

# Session 2026-08-08 (second half) — merges, and five of my own claims refuted

## Claims I made that were REFUTED (this is the list that must never be lost)

| My claim | What was measured | Who refuted it |
|---|---|---|
| resume-probe suite HANGS, via heimdall-checkpoint re-entering it | It never hung. Ran 72s and 106s. heimdall-checkpoint never invokes that suite. The "copy of itself" in `ps` is a command-substitution subshell — a fork keeps its parent's argv. It printed nothing for ~100s, which is indistinguishable from a hang, and under 4 agents crossed the 240s budget I killed it at. | probe-fix agent |
| `bin/lib/reachability.sh` used a flat "something mentions it" rule | The ENGINE was already correct — seeds at live entry points, propagates transitively. The flat rule lived in the TEST's own duplicate detector. `heimdall-deadcode:18`'s claim the engine was "shared verbatim" with the test was aspirational; true only now. | dead-chain agent |
| The 9 allowlist entries are STALE — remove them | All 9 are genuinely dead. They only read "wired" under the flat rule, because dead libraries were vouching for them. Removing them would have converted 9 acknowledged-dead tools into 9 surprise failures. Agent refused the instruction and was right. | dead-chain agent |
| (earlier) B1 index injection is "the prime suspect, 10-18KB" | 6,601 B/compact — fifth largest, a third of the low estimate. | compaction measurement |
| (earlier) B2 graph-first orchestrator reading is a headline | `tool:Read` = 0.8% of per-turn additions. Graph value is generation-side, not orchestrator-side. | compaction measurement |

**Pattern: every one of these was refuted by measurement, not argument.** An agent told to
implement a wrong brief should refute it. Three did. That is the behaviour to keep.

## ONE root cause, three symptoms — closed
`evals/oracles/changelog-bash32/run.test.sh` was not hermetic w.r.t. `GIT_DIR`/`GIT_INDEX_FILE`,
which git EXPORTS into every hook. Fixture repos resolved to the REAL repo. It produced:
 1. a false-RED pre-commit gate blocking every commit -> trained agents into `HMD_SKIP=1`;
 2. `core.bare=true` set on the main checkout -> `git status` failed repo-wide with
    "must be run in a work tree"; every git-based gate would have failed silently;
 3. the repo's git identity rewritten to `test@heimdall.dev`.
Fixed + pinned by `test/oracle-hermeticity.test.sh` (8/0) which reproduces the damage on a
DECOY repo and asserts byte-identity after. Real repo verified: RJ / rj@runheimdall.dev,
core.bare=false. NINE test suites had the same `git init --bare "$UNCHECKED_VAR"` shape;
all guarded, pinned by `test/repo-never-left-bare.test.sh` (7/0, mutation proofs both ways).
**OWED: the class survey of other `evals/oracles/*/run.test.sh` was never finished** — that
agent died mid-investigation having just flagged a suspicious `verdict: pass with zero
per-gate entries`, which is a vacuous-pass smell.

## Merged to main this session
2d4f964 reachability engine · e1145f6 autoupdate receipt · 80eae20 conformance suite 64/0
· de725b7 resume probe ARMED 59/0 · 3776f64 inventory can't vouch for absent falsifier
· a932d7a all 7 subsystems record reachability · 9e02427 git-init leak guard
· ebf3d3a salvaged guard lines · 0acf0b9 declaration-surface fix 23/2

## Open, needing RJ
- **HELD: `worktree-agent-a3a9010888d1f387f`** — agents/heimdall.md 59,364 B -> 38,494 B,
  the system prompt of EVERY session. This is measured item B4, the #1 lever (~76% of
  post-compact baseline is standing overhead). Asked twice, no answer yet. NOT merged.
- Inventory is RED on the real repo by design: checked=8 -> checked=5, non_verified=3,
  exit 3. 8 of 21 enforcer files missing. No stubs written — a passing stub is worse than
  an absent file.
- 2 true dead bins remain: `heimdall-conformance`, `heimdall-sla`. Not exempted on purpose.
- Spend limit was hit mid-session; 3 agents were killed. All their work was recovered from
  worktrees. Two had produced nothing not already on main.

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
5d5e9857 journal: [COMMUNICATION] journal: [COMMUNICATION] journal: [COMMUNICATION] chore(release): v2.4.4
8121aec7 journal: [COMMUNICATION] journal: [COMMUNICATION] chore(release): v2.4.4
63440f49 journal: [COMMUNICATION] chore(release): v2.4.4
a0a86858 chore(release): v2.4.4
7ef0aa25 journal: [COMMUNICATION] journal: session entries before 2.4.4 ship
093b2bd7 journal: session entries before 2.4.4 ship
d7662a8b test(cc-selfheal): make the drain tripwire say what to check
7135e27b fix(test): cc-selfheal suite drains each detached repair before reading or resetting state
d515a0a4 chore(test): start cc-selfheal sweep-hermeticity investigation
296569eb Merge branch 'worktree-agent-a29ccddfff1a63e72'
4de63856 journal: [COMMUNICATION] journal: [COMMUNICATION] Merge branch 'worktree-agent-ac8e52f3ea1f32f85'
3a96bcd4 docs(data): disclose phone companion relay, Expo push and pair-by-code; scope README S1
e968439f journal: [COMMUNICATION] Merge branch 'worktree-agent-ac8e52f3ea1f32f85'
a2cd28a2 Merge branch 'worktree-agent-ac8e52f3ea1f32f85'
e93c0d76 journal: session entries
3810a349 fix(relay-client): a refused foreign device_bound keeps the paired phone's caps
3d9e6d3f chore(data-md): start companion-relay/push/pair truth-gap pass
0083e629 Merge branch 'worktree-agent-abc3ab10a6ee2847a'
d4039e21 journal: [COMMUNICATION] journal: [COMMUNICATION] Merge branch 'worktree-agent-ac8e52f3ea1f32f85'
0a16bd7d feat(phone-deny): A4 phone deny is on by default; HMD_PHONE_DENY=0 or hmd hooks disable phone-deny turns it off
