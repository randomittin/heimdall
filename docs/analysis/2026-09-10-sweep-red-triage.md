# Sweep RED triage — 2026-09-10

## The two sweeps

| | HEAD | wall | verdict | load (1/5/15) |
|---|---|---|---|---|
| green | `0ec75714` | 1605s | 402/402, 9874 assertions | quiet box |
| red | `8c125ba0` | 7410s | 6 FAIL + 8 TIMEOUT, 10 assertions failed | 17.28 / 25.09 / 26.14 on 10 cores |

Same 402 suites, 4.6x slower. Eight of the fourteen died at the **unchanged**
182s default, in suites nothing had touched. `heimdall-statusline-perf-budget`
went 0/3 — a perf budget under 2.5x oversubscription.

**Conclusion: the red was substantially load-contaminated, not a code regression.**
A significant share of that load was the orchestrating Claude session itself plus
a `headroom` proxy — i.e. self-inflicted, and invisible in the receipt at the time.

## Unresolved (do not treat as closed)

`test/heimdall-fallback.test.sh` reported `139 passed, 1 failed` **twice** in the
red sweep (327s, then 158s on retry). Case 86's timing bound had **already** been
widened 5s -> 30s in `db29cd38`, and `git merge-base --is-ancestor db29cd38
8c125ba0` confirms the fix was live in the swept tree (`s < 30` present in that
blob). So either case 86 blew even a 30x margin under load ~25, or a different
assertion fails only under load. It does not reproduce solo: two solo runs gave
140/0 with case 86 explicitly passing at 1.01s.

One agent concluded from commit timestamps that case 86 *was* the failure and was
already fixed. That inference is **refuted** by the ancestry check above. It was
flagged as inference rather than witnessed failure, which is why it was catchable.

Next red sweep will name the failing assertion directly — see the evidence dir below.

## Landed this round

- ctx-meter context fence, 6th `PreToolUse` Agent fence (`bin/heimdall-precheck-agent`, 32/0)
- SessionStart ledger gate: a subagent inherits `CLAUDE_CODE_SESSION_ID`, so its own
  legitimate `startup` was wiping the parent's edit ledger. Now also gated on
  `CLAUDE_CODE_CHILD_SESSION`, fails safe (19/0)
- add/add doc collision resolved by keeping BOTH docs at distinct slugs
- case-86 wall-clock margin 5s -> 30s (real latent defect; not the red-sweep failure)
- measured timeout budgets 180 -> 450s for `heimdall-fallback` (194s solo) and
  `install-team-secret` (228s solo) — both already over the default with zero contention
- nested-suite de-duplication, 2 instances, the only 2 that exist:
  `heimdall-context-capsule` -> `heimdall-maintain-loop`, and
  `heimdall-agent-watchdog` -> `heimdall-agent-resume` (110s -> 29s; it had been
  TIMING OUT at 182s). Both gated behind `HEIMDALL_TEST_SLOW=1` with a loud `[SKIP]`;
  coverage preserved because both nested suites run standalone with their own verdicts
- **failing-suite evidence is now persisted**: non-green suites only, `.out` plus
  `.parallel.out`, an `INDEX.txt`, and the first `bad ` lines surfaced directly in the
  summary. A red sweep no longer costs another 7410s to diagnose
- **receipt now records load**: `load_start_{1m,5m,15m}`, `load_end_{1m,5m,15m}`,
  `cpu_count`. All 14 pre-existing keys unchanged in name and order; 7 appended.
  Verified against all 8 readers of `last-sweep.json` — none asserts an exact key
  set or does a byte comparison, so new sibling keys cannot break them

## Deferred — needs a QUIET box

1. **Timeout budgets for the 8 timed-out suites.** Any solo timing taken at load
   17-26 is not a solo timing. Setting `suite_timeout()` overrides from contaminated
   numbers would bake a wrong value in as a documented "measured" one. Re-measure at
   load < 6, then decide.
2. **A trustworthy full sweep.** The gate holds the push until a green receipt exists.
   Run it when the box is idle and no agent session is competing.
3. `heimdall-fallback`'s load-dependent assertion — answerable from the evidence dir
   on the next red.

## Process lesson

Three times this session an orchestrator check was itself the broken thing: a grep for
the wrong identifiers nearly booked a completed feature as missing. Verify the check
before trusting its verdict — a scarier answer is not a truer one.
