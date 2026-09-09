# Stranded agent work — inventory and triage (2026-09-07)

## Why this exists

`bin/heimdall-reap-idle --apply` refused to remove 61 worktrees because their
branches hold commits not on `main`. That refusal is correct and is the reason
the work below still exists. Investigating it found that the refusal was
protecting REAL, unlanded production code — not leftover noise.

The mechanism: 196 agent stalls were measured in a single session. The
agent-watchdog snapshots a dying agent's tree (`wip: preserve interrupted agent
work`), and finished agents that hit a turn limit commit their own work. In both
cases the branch survives; nothing lands it. Merging is the orchestrator's job
and it was not done.

## Measured classification (44 branches ahead of `main`)

| bucket | count | meaning |
|---|---|---|
| SUPERSEDED | 4 | non-`.planning` content already on `main` by another route; nothing missing |
| WIP-ONLY | 21 | watchdog snapshots with no conventional commit — mid-edit trees, may never have been valid |
| REAL, UNLANDED | 37 | at least one `feat:`/`fix:`/`test:`/`docs:` commit whose code differs from `main` |

(Buckets overlap slightly: a branch can carry both wip snapshots and a real commit.)

## Landed from this triage

- `acba3bff2` — `feat(fallback): lower auto exhaustion threshold 95% -> 90%`,
  6 files. **This was an explicit operator directive** ("changing auto in omni
  fallback to work when limits are 90% consumed... remaining 10% solely for
  orchestration") that had been implemented and then stranded on a dead agent's
  branch for days. Verified after landing: `DEFAULT_THRESHOLD_PCT = 90.0`,
  heimdall-session-usage 58/0, heimdall-fallback 140/0.

## Attempted and CONFLICTED — left unmerged, need judgement

All three are real omni fixes that conflict with work landed since. Merges were
aborted; the tree was verified clean afterwards. They are NOT lost — the branches
are intact and protected from reaping.

| branch | change | conflicts in |
|---|---|---|
| `a1e27af08` | `feat(fallback): route claude -p fix attempts to OmniRoute on genuine exhaustion` | `bin/lib/issue_loop.py`, `test/issue-loop-claude-fix-fallback.test.sh` |
| `a6498c769` | `fix(issue-loop): route _run_claude_fix through the overload retry wrapper` | `bin/lib/issue_loop.py` |
| `a63d468e3` | `fix(heimdall-fallback): stop no_delegated_sidecar failing closed on pre-migration config` | `bin/heimdall-fallback`, `test/heimdall-fallback.test.sh` |

Two of the three touch `bin/lib/issue_loop.py` and overlap each other, so they
want resolving together, by someone who can read both intents — not by a
mechanical merge. Resolving a conflict by guessing intent is how a subtle
routing bug ships.

## Not triaged individually

The remaining ~33 REAL/WIP branches were not opened one by one. Sampled subjects
include `feat(pressure): add heimdall-529-scan`, `fix(team): forward tty
decision to invite's secret-print guard`, `fix(test): stop guessing
heimdall-route's fixture ports from PID`. Each needs the same
merge-then-test-then-keep-or-abort treatment.

## The systemic fix, not done here

Nothing currently notices that a finished agent's branch was never merged. The
watchdog preserves work and `reap-idle` refuses to delete it, but no component
says "this branch has a conventional commit that is not on main." A gate or a
`hmd agents unmerged` report would turn this from an archaeology exercise into a
one-line check. Recorded as the actual defect behind this inventory.

---

## CORRECTION (2026-09-08): the three "conflicted" branches were already landed

The three branches listed above as real omni fixes needing joint resolution were
re-examined by direct code comparison and ancestry check. **All three are already
satisfied on `main`.** The earlier framing — mine — was wrong: a merge conflict was
read as evidence of unlanded work, when in every case it was evidence of the SAME
work having landed via a different commit path and then evolved further.

| branch | verdict | evidence |
|---|---|---|
| `a1e27af08` | already satisfied | `git diff main <branch> -- bin/lib/issue_loop.py` is **2 lines**, both a stale comment naming the retired `on` state. Main already carries the full `_omniroute_route_overlay` / `_fallback_gate_check` / `_record_fallback_metric` machinery, evolved onto the `off/auto/switch/coop` model. |
| `a6498c769` | already satisfied | Its real content is in wip commit `6662f718`; diffed in isolation against main → identical `_CLAUDE_RETRY_WRAPPER`, identical argv construction, identical `HEIMDALL_CLAUDE_BIN`→`HMD_CLAUDE_BIN` resolution order, identical `overloaded:True` outcome shape. |
| `a63d468e3` | already satisfied, via `288a460e` | Neither of the branch's own commits is an ancestor of `main`, but `288a460e` (same author, 2 minutes later) IS — the same sidecar fix re-landed by another route. Current `no_delegated_sidecar` (bin/heimdall-fallback:1334-1414) implements exactly it, and tests 34c/34d cover the scenario. |

### The part that would have been a regression

`a63d468e3` also carries the `on` routing state and its `_tier_routes_under_on`
helper. `on` was **deliberately retired by owner directive** — main's own test suite
says so in a comment. Merging that branch to "recover stranded work" would have
re-litigated a retired state. This is the concrete case the resolution brief was
warned about: a redundant merge that reintroduces an older approach is worse than
leaving a branch alone.

### What this changes about the inventory above

The "37 REAL, UNLANDED" count is an UPPER BOUND, not a finding. It was computed
from `git diff main...<branch>` being non-empty on non-`.planning` paths — which
is true both for genuinely unlanded work AND for work that landed by another path
and then diverged. Three of three sampled turned out to be the latter.

So the real defect is narrower than first stated, and also more interesting: the
`acba3bff2` threshold branch WAS genuinely unlanded (verified by landing it and
watching `DEFAULT_THRESHOLD_PCT` change from 95.0 to 90.0), so the class is real —
but its incidence is unknown and lower than 37. Any detector for this must classify
by CONTENT reachability, never by "ahead of main", or it will cry wolf 37 times.

---

## CORRECTION (2026-09-09): DELTA BRIEF triage of the 19 branches live at brief-writing time

`bin/heimdall unconnected` FACE A, re-run fresh for this task, reported 19 REAL
branches (not the 21 the brief cited — churn between brief-writing and task-start
in a heavily concurrent multi-agent session, not a discrepancy worth chasing).
All 19 were carried through the strict bar this doc's own 2026-09-08 correction
established: name a specific symbol/constant/test that exists on the branch and
does NOT exist anywhere on `main`, or classify it already-landed and move on.

**Outcome: 2 landed, 1 conflicted (needs a human), 2 blocked by file ownership
(not content), 14 already-landed.** No branch was merged "to recover" work that
turned out to already be present — the single conflict was aborted, not
guessed through, per the same rule this doc already learned the hard way on
2026-09-08.

### Landed (2)

| branch | named missing symbol | test evidence |
|---|---|---|
| `heimdall/issue-2-mcp-path` | `test/heimdall-ledger-mcp-path.test.sh` absent from main entirely (`git show main:<path>` → "fatal: path does not exist"); `PROTOCOL.md`'s MCP registration snippet still used the bare-relative `"command": "bin/heimdall-ledger-mcp"` form, never rewritten to `${CLAUDE_PLUGIN_ROOT}` | `bash test/heimdall-ledger-mcp-path.test.sh` → **5 passed, 0 failed** |
| `worktree-agent-aea7bcce848550497` | Bold lead line `**Every PR ships the runnable evidence that the fix passes.**` absent from both `README.md` and `packages/runheimdall/README.md` — main still led with the older "A cloud bot that fixes your GitHub issues..." framing | `bash test/version-drift.test.sh` → **17 passed, 0 failed**; `bash test/version-unified.test.sh` → **5 passed, 0 failed** |

Both merged via `git merge --no-ff` on this task's own worktree branch
(`worktree-agent-aa794acff37a0f0b5`) — see "Why the count below goes UP, not
down" for why that matters.

### Conflicted — needs a human (1)

| branch | what happened |
|---|---|
| `worktree-agent-a50ceab7aee88d327` | `git merge --no-ff` → **CONFLICT (add/add)** on `docs/analysis/2026-08-25-omniroute-install.md`. Main independently carries a *different* document at the exact same path/date-slug (a security-auditor's password-rotation finding); the branch's document (a companion install/setup note, same date, different author-intent) is a genuinely separate write. `git grep` across every tracked file on `main` for the branch's most distinctive sentence ("byte-for-byte the tree at d82b68274c75c14d258b4898a34edc25d9712b87") returned zero hits — the branch's content is real and missing, but it collides on filename with unrelated already-landed work. Merge aborted immediately (`git merge --abort`), tree left clean. Needs a human to decide: rename one doc, fold the install-method content into the existing audit doc, or drop it — not a call this triage makes by guessing intent. |

### Blocked by file ownership, not content (2)

| branch | protected path touched | content status (informational only — not why it was skipped) |
|---|---|---|
| `readme-launch` | `agents/heimdall.md` | Also already superseded in part — main's `CONTRIBUTING.md` still has the bare `STACK_PACK_TEMPLATE.md` link this branch fixes to `docs/STACK_PACK_TEMPLATE.md`, but the branch is a much larger repo-reorg commit (moves several root docs under `docs/`) bundled with the protected file, so the whole branch was left untouched rather than partially cherry-picked. |
| `worktree-agent-af524f206c6e9a4ee` | `hooks/hooks.json` | Independently already-landed anyway — main's `hooks/hooks.json` (line 236) already wires the identical `heimdall-metric-reminder.sh` Stop-hook command this branch adds. Skipping it cost nothing. |

### Already-landed (14)

| branch | named check that came back "already present" on main |
|---|---|
| `worktree-agent-a463e86ae051b30d9` | `bin/lib/hmd_api_backend.py` and `bin/hmd-exec`'s 7 references to it already match; `test/hmd-exec.test.sh` and `test/hmd-api-backend.test.sh` both already exist |
| `worktree-agent-a4e96ac9e47e95e45` | `bin/heimdall-autoupdate` already has `MODULES_REGISTRY` and `reconcile_modules()` |
| `worktree-agent-a4f3523dc656310d5` | main's `DEFAULT_THRESHOLD_PCT = 90.0` (post-`acba3bff2`); branch's `95.0` is the pre-correction value — superseded, not missing |
| `worktree-agent-a5bbcf5f39ada9ac4` | `bin/heimdall-seed-demo-wall` header matches; `launch-docs/assets/provenance.json` already lists `wall-fallback.gif` |
| `worktree-agent-a658af5d76bdfc2d1` | main's `_session_pre_exhaustion_verdict` (line 1048) / `_verdict` (line 1492) implement the identical WAIT/ROUTE decision table, PHASE 3-5 richer (3-tuple return, `windows_seen` metadata) — read both function bodies directly to rule out regression before classifying, per this doc's own routing-code caution |
| `worktree-agent-a7ce3273975db393d` | main's `bin/heimdall-agent-resume` already has the corrected "wrong, corrected below" header text; `test/heimdall-agent-resume-pressure.test.sh` already has the "THE STRONG CASE" section (line 271) |
| `worktree-agent-a9b8cff7a0e78e43d` | main's `commands/fallback.md` (355 lines) documents a strictly later state than the branch: `arm` subcommand exists, the `on` state is documented as removed — the branch predates both changes |
| `worktree-agent-aab9517a68ac85321` | the literal origin commit of `bin/heimdall-fallback` (`new file mode`, `feat(fallback): add heimdall-fallback quota-exhaustion policy gate`); its own distinctive header phrase ("mirrors bin/heimdall-quota-advisor's own header") still verbatim on main, which has since evolved through every other generation in this table |
| `worktree-agent-aba9f5e0e568348c1` | main's `bin/heimdall-agents` already has the "MEASURED evidence" / `in_process_teammate` mailbox-detection logic (pgrep-based, lines 458/551) |
| `worktree-agent-adf9dce1afdf8edf3` | main's `BUILTIN_TOS_FLAGGED_PROVIDERS = frozenset()` (line 522) — exact match, empty-by-design |
| `worktree-agent-ae58aa1eb9d3d93c7` | `docs/analysis/2026-08-25-headroom-inpath-measurement.md` exists on main, opening section byte-identical to the branch's |
| `worktree-agent-ae95b671a993d5170` | main's `bin/heimdall-modules` already has `declared_waiver_json()` (line 268, plus two call sites) |
| `worktree-agent-aebc508075abe7eff` | main already cites `docs/analysis/2026-08-25-omniroute-credential-isolation.md` sections S3/S5/S6 by name, more granular than the branch's own positive-verification rewrite |
| `worktree-agent-aee583bb0c20a831e` | main's `test/heimdall-route.test.sh` already has "Ports are OS-assigned, not PID-derived"; `test/heimdall-watch.test.sh` already uses `"$WORK/wt_pyc.txt"` instead of a hardcoded `/tmp` path |

### Why the final re-run shows 21, not 17 — and why that is NOT this task's doing

Final `bin/heimdall unconnected` re-run, captured after both merges, the abort,
and this doc's own commit: **FACE A real/gating count = 21** (self-consistent —
header count and the printed list both say 21). Naive arithmetic would predict
17 (19 minus the 2 landed). The actual number is higher, for two reasons, both
verified directly rather than assumed:

1. **The 2 landed branches still each appear in the list, individually** —
   `heimdall/issue-2-mcp-path` and `worktree-agent-aea7bcce848550497` are still
   printed as "N commit(s) ahead of main". Expected: merging branch A into this
   task's staging branch does not change branch A's *own* ref — it is still,
   correctly, N commits ahead of the real `main`. It stops appearing only once
   `main` itself is fast-forwarded past it (see handoff command below).
2. **Two branches with zero connection to this task's 19-branch worklist
   appeared during the run and are now in the list**: `truth-pass` (3 commits
   ahead) and `worktree-agent-ae8ca838ea1f29ff8` (2 commits ahead). Neither was
   part of the brief's original 19, neither was touched, neither was evaluated
   — they are concurrent work from other agents in this same multi-agent
   session, landing in the shared local-branch namespace this scanner reads.
   19 (original) + 2 (unrelated arrivals) = 21. This is the exact "concurrent
   multi-agent churn" the brief itself already named as the reason its own
   145 -> 21 -> 19 count moved between brief-writing and task-start; it kept
   moving during task execution too, for the same reason.

**This task's own staging branch, `worktree-agent-aa794acff37a0f0b5`, does NOT
appear in the real/gating 21 at all** — verified directly against the raw
output, not inferred. It appears instead under WIP-ONLY (5 commits ahead,
informational, "does not gate"), alongside every other currently-checked-out
agent worktree in this session. Read literally: the scanner does not treat a
live, in-progress worktree's own ref as a gating "unlanded branch" candidate —
so the two merges landed here added zero to the gating count. An earlier draft
of this section, written before this final measurement, predicted a +1 for
exactly that reason (this branch joining the gating list); the actual data
contradicts that prediction, so the prediction is corrected here rather than
left in place — the number that matters is the one measured, not the one
guessed in advance.

All 19 branches from this task's worklist are still present in the final scan,
individually checked by name — none dropped, none newly conflicting, none
reclassified by the churn. Verdicts in the tables above stand as measured.

`git merge-base --is-ancestor main worktree-agent-aa794acff37a0f0b5` confirms a
clean fast-forward is available. The one remaining mechanical step — outside
this task's own sandbox, since git refuses to update a branch checked out in
another worktree — is, from the primary checkout:

```
cd /Users/rj/Downloads/heimdall
git merge --ff-only worktree-agent-aa794acff37a0f0b5
```

Projected (not measured — this task cannot perform the fast-forward itself)
effect: the 2 landed branches flip from real to clean once `main` reaches them.
The other 19 real-list entries are untouched by that step either way — 14
already-landed (content-safe, but not byte-identical to main, so this
mechanical tool will keep flagging them regardless of any fast-forward — the
same "cry wolf" limitation the 2026-09-08 correction named, now reconfirmed
against 14 more data points), 1 genuinely conflicted, 2 blocked on file
ownership alone. Zero of those 17 are a case of real work sitting unrecovered
for no reason. `truth-pass` and `worktree-agent-ae8ca838ea1f29ff8` remain
out of scope for this task and were left for whoever picks up the backlog next.

