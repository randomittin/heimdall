# Heimdall conventions — process distillations

Lessons that survived an incident, written as enforceable rules. Each one exists
because skipping it produced (or nearly produced) a false-green. Append-only.

## R5 — no hand-derived reference byte is trusted until externally anchored

A reference value (a golden trace byte, an expected trade, any "this is the
correct answer" datum) is NOT trusted until it has been anchored to an EXTERNAL
source — Pan Docs, gameboy-doctor output, an independent reference matcher —
that is independent both of the author and of this repo's other fixtures.

**Why:** the R-1 H-flag defect. The emulator golden shipped `F:10` where `F:20`
was correct (post `AND A`: H is bit 5 = `0x20`, C is bit 4 = `0x10`; AND sets H
and clears C, so the golden had the two bits inverted). It survived every
in-repo check: self-verify 11/11, mutation-proof 9/9, corpus 100%. All of those
were authored by the same hand against the same wrong reference, so they shared
its blind spot by construction — a same-author cross-check can only confirm
internal consistency, never external correctness. The defect was caught only by
an external adversarial review that anchored the byte to Pan Docs.

**How to apply:** before pinning any reference datum, cite the external anchor
(`AND` flag rule "Z 0 1 0" in Pan Docs; a gameboy-doctor truth log; the
reference matcher's output). Same-family agreement counts (11/11, 9/9, 100%) are
necessary but NOT sufficient — they prove consistency, not correctness. Record
the anchor in the fixture's provenance. See [[R6]] for the complementary rule
that the checks themselves must be falsifiable.

## R6 — golden checks must be capable of failing

Every "must pass" check gets a corrupt-and-confirm test: deliberately break the
thing it validates and confirm the check goes RED. No X-vs-X comparisons — a
check that diffs a value against itself can never fail and therefore proves
nothing.

**Why:** a gate that diffs the golden against its own default truth (no explicit
independent reference) is comparing X to X — it is green by tautology, and "the
gate is not over-strict" has never actually been demonstrated. The same failure
mode at corpus level: if expectations are regenerated in the same breath as the
reference they pin, the corpus stays green through a reference change that should
have broken it. The R-1 corpus dip (9/9 → 7/9 → 9/9) is the positive proof: the
corpus genuinely went RED the instant the golden was corrected and before the
pins were replayed — that dip is what makes the recovered 100% trustworthy.

**How to apply:**
- Each oracle ships a `run.test.sh` whose cases include at least one
  corrupt-and-confirm: feed the gate a deliberately corrupted golden and assert
  it reports `status=fail` (e.g. `evals/oracles/emulator-gb/run.test.sh`).
- A reference fix MUST make the corpus dip RED before it recovers; record the dip
  publicly (CORPUS-STATUS.md dip-log). A corpus that never went red during a
  reference fix means the expectations were regenerated in the same breath as the
  reference — stop and investigate.
- Re-pin expected verdicts by REPLAYING the input through the gate's `run.sh` and
  capturing its structured output — never hand-write a pinpoint (SCHEMA.md law).

See [[R5]] for the complementary rule that the reference itself must be
externally anchored.

## R1 — parallel agents never share an output directory
Two agents writing the same dir (e.g. `evals/corpus/`) collide: add/add merges, one set silently wins.
**Why:** H-8 build — two parallel agents both seeded `evals/corpus/`, runner scored 0/9 on the schema mismatch.
**How to apply:** planner assigns each parallel agent a DISJOINT sub-path (or, once the ledger lands, each claims its surfaces). Same-dir work is sequenced, never parallelized. This is the `claimed_surfaces` failure class, dogfooded before the ledger existed.

## R2 — never delete a worktree branch before its merge lands
**Why:** a fix branch was deleted mid-merge-conflict; the commit went dangling, recovered only via reflog sha.
**How to apply:** confirm the merge commit is reachable from main (no conflict in progress) BEFORE `git worktree remove` / `git branch -D`. Resolve conflicts first; never clean up mid-conflict.

## R3 — worktree agents must commit in-worktree
Spawned coders auto-isolate into git worktrees; uncommitted files are destroyed on cleanup.
**How to apply:** every spawned agent commits in its worktree; the orchestrator integrates by merging the branch — never by expecting files on main.

## R4 — schema/reference changes propagate in one commit and must show the dip
**Why:** a contract change with untouched expectations that stays green = the change didn't really happen (tautology).
**How to apply:** update every consumer (gates, falsify, corpus, expected fixtures, docs) in the SAME commit; run the corpus between reference-fix and re-pin to capture the RED dip; record it in CORPUS-STATUS.md dip-log. (R6 generalizes this.)

## Corpus calibration — 100% over a static corpus is just a badge
**Why:** a corpus at 9/9 forever has stopped teaching. Value = cases that FAIL when gates regress + intake of genuinely hard field/community cases.
**How to apply:** as field-capture starts, a catch-rate dip that gets fixed is the curve working — never an embarrassment to hide. The impressive artifact is a high rate over a GROWING, hardening corpus. Never game the number by keeping the corpus easy.

## R7 — cap spawned-task size; checkpoint commits mid-task
**Why:** three agents in one session (H-3, R-3.2, wave-2b) exhausted their budget (~140-165k tokens) on multi-part tasks and died BEFORE committing/reporting — work survived only because worktrees were inspected by hand before cleanup.
**How to apply:** a spawned task covers at most ~3 remediation-items or 2 domains; anything larger is split into sequenced spawns. Agents commit a checkpoint after each completed sub-item, not only at the end. The spawn framework's per-spawn token budget + partial-report flag exists for exactly this — use it once wired.

## Corpus diversification — v0.3 floor (RJ rule)
By corpus v0.3, a minimum share (target ≥1/3) of cases must originate from NEW tasks — third-domain oracles (mini-git), the popular-surface 10, field capture — not mutants of the founding two fixtures. Deepening only on founding fixtures = memorizing, not generalizing.

> **Launch-3 evidence tags:** R1 (parallel-agent output-dir collision — the `claimed_surfaces` failure class demonstrated on our own build) and R7 (budget-exhausted agents dying uncommitted — the spawn-budget/partial-report failure class) are both first-party incidents the team-lane ledger + spawn framework exist to prevent. Cite both in the Launch-3 write-up: "the days our own agents collided and died silently, and what we built so yours don't."

## R8 — gitleaks runs as a standing pre-commit gate (and a hard pre-push gate)
gitleaks runs as a standing pre-commit gate (and a hard pre-push gate), not just an ad-hoc scan — secrets are blocked at the moment of commit, before they can enter history. A one-time full-history scrub cleans the past; this gate prevents recurrence.
**Why:** a credential reached history during a near-miss (SECURITY-REMEDIATION.md Step 6.2). Scrubbing history removes the leaked secret but does nothing to stop the next one; the only durable fix is a guard at the moment a secret would be recorded.
**How to apply:** `bin/secret-scan` runs via the PreToolUse Bash hook on `git commit`, scanning the STAGED diff (`gitleaks git --staged`, falling back to `gitleaks protect --staged`, then `gitleaks stdin`). A finding blocks the commit (exit 2). At commit time a missing gitleaks WARNS-but-allows (a missing scanner must not brick every commit); at push time it is a HARD block (`--require`) — pre-push is the last line, so gitleaks-absent OR any finding refuses the push, alongside the existing falsify/corpus gates.

## R9 — set the clean commit identity before the first commit
Configure `git config user.email` / `user.name` to the project's canonical identity at project start, BEFORE any commit. A rename or history-scrub fixes the past once; commits made afterward with a stale identity (e.g. a former-employer email) silently re-introduce the fingerprint into history and get pushed.
**Why:** post-rename, ~20 session commits authored with the old `@company` email were pushed to the clean public remote — gitleaks stayed 0 (no secret) but the identity leak required a second history rewrite + force-push to undo.
**How to apply:** (1) set the canonical commit identity in the repo at setup; (2) post-push verification of a public repo is BOTH `gitleaks detect --log-opts=--all` AND `git log --all --format='%ae|%ce' | sort -u` — gitleaks alone does not catch an identity fingerprint. (3) After any history rewrite, re-sync local tags (`git tag -d … && git fetch --tags`) — `reset --hard` does not move existing tags, leaving them pointed at pre-rewrite commits.

## R10 — gitleaks self-scan over Heimdall's OWN full history is a blocking pre-push gate
gitleaks self-scan over Heimdall's OWN full history is a blocking pre-push gate. Agents commit `--no-verify` (bypassing the pre-commit secret-scan), so the pre-push history self-scan is the real net against a secret entering the repo. The tool that proves your code holds itself to the same bar — it scans its own history before every push.
**Why:** a planted demo secret got committed to this repo's history precisely because agents commit `--no-verify`, which skips the PreToolUse pre-commit secret-scan ([[R8]]). The staged-diff gate cannot fire on a `--no-verify` commit; only a gate that scans the FULL history (independent of how a commit was authored) is a real backstop. The secret-scan gate guarded user demos and the push range, but never this repo's own complete history — `bin/heimdall-selfscan` closes that hole permanently.
**How to apply:** `bin/heimdall-selfscan` runs `gitleaks detect --source . --log-opts="--all"` over the entire history, wired into the PreToolUse `git push` chain alongside falsify/corpus/secret-scan. A finding anywhere in history OR gitleaks-absent is a HARD block (exit 2) — a verification tool that cannot scan its own history must not certify a push. No `.gitleaksignore`, no allowlist: the history must scan clean NATIVELY; to clear a finding, scrub the history (git filter-repo / BFG), never suppress it. This is distinct from [[R8]]'s `bin/secret-scan`, which scans the staged diff at commit time and the push range — selfscan scans full HISTORY.

## R11 — a skipped test is a finding; a missing test is a finding
A skipped OR absent test for an observable behavior is NOT a green — it is a finding, tracked in `.planning/SKIP-REGISTER.md` with reason + risk + close condition. Prefer making the test runnable in the real environment over skipping it.
**Why:** two live bugs on this project hid behind skips/absence. (1) `generate-changelog`'s behavioral test was skipped ("no bash≥4 on machine"); forcing it to run (bash-3.2-safe rewrite, finding #5) surfaced 3 latent bugs — a GROUPS/GIDs array-name collision leaking bare GIDs into output, the oldest commit silently dropped (no trailing newline from `git --pretty=format:`), and `--append` broken under BSD awk. (2) The full-history secret self-scan did not exist ([[R10]]'s gap); that ABSENCE let a planted credential reach a commit. In both, the skip/absence WAS the bug's hiding place.
**How to apply:** when any test is skipped or doesn't exist, add a SKIP-REGISTER row immediately (reason, risk, close condition). At verification: an OPEN row with risk ≥ MEDIUM blocks; LOW rows are logged + surfaced to RJ; an unexplained skip fails the gate. Closing a skip means making the real test run, not deleting the row. Complements [[R6]] (checks must be able to fail) — R6 says a check that can't go red proves nothing; R11 says a check that didn't run proves nothing.

## R12 — never `eval` a free-prose / human-authored field; run DEFINED commands via `bash -c`
A field that holds a human-readable acceptance DESCRIPTION (prose like `npm test green AND slugify(x) === 'y'`) must never reach `eval`. Acceptance must be expressed as DEFINED, runnable commands (a `baseline_cmd` for the regression suite + an `assertion_cmd` for the behavior, each exit-0-iff-correct), executed via `bash -c "$cmd"` — the same contract as a Makefile target, not arbitrary prose interpreted as shell.
**Why:** S-6 C3 Defect 2 — `bin/heimdall-s6-sweep` did `eval "$acc"` on a prose `acceptance_cmd`. The prose contained `(` → shell syntax error → the run recorded a bogus working-output FAIL that was a RUNNER error masquerading as a real test result (a false signal, the worst kind). The fix split the field into two runnable commands and runs them via `bash -c`; the manifest adapter now carries `baseline_cmd`/`assertion_cmd` and the runner requires BOTH (fail-closed like the sha pin), gating `working_output.pass = baseline_pass && assertion_pass`.
**How to apply:** keep acceptance as runnable command fields, never prose; run them with `bash -c "$defined_cmd"`, never `eval`. KNOWN-PATTERN for `bin/heimdall-landmine-lint`: a generic `eval "$<var>"` detector was considered and DEFERRED — distinguishing a dangerous prose-eval from a legitimate eval of an internally-constructed command is not cheap to do at low false-positive rate (the linter's classes 2/5 are already high-confidence-only by the "a noisy linter gets disabled" rule). Until a high-confidence shape is found, this convention (no eval of human-authored fields; commands run via `bash -c`) is the guard, enforced in review, not by the linter.

## R13 — Agent spawns are UNNAMED by default; `name:` makes a resident agent that never returns
Passing `name:` to the Agent tool switches the harness into persistent MAILBOX mode — the tool_result says verbatim "The agent is now running and will receive instructions via mailbox." A mailbox agent never self-terminates and never emits a `task-notification`, so the orchestrator that spawned it waits forever for a result that will never arrive; it sits in FleetView as `idle` until the whole session dies.
**Why:** one real session transcript (`~/.claude/projects/-Users-rj-Downloads-code-SuperSmartVerify/d3d7b27a-*.jsonl`), 109 Agent-tool spawns: spawns passing `name:` → **0 of 43** ever emitted a `task-notification` (never completed); spawns with no `name:` → **59 of 66** completed normally. 43 leaked agents in a single session, each with an orchestrator blocked on a result that could not arrive.
**How to apply:** default to UNNAMED spawns — they self-terminate and deliver their result via `task-notification`. Pass `name:` ONLY when you will actually `SendMessage` that agent AND you accept that it stays resident for the whole session (a genuinely long-lived conversational agent). To identify a spawn's work, put the identifier in `description:`, never in `name:`. Complements [[R7]]: R7 covers agents that die before reporting; R13 covers agents that never die and therefore never report.
