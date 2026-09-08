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
