# An alternative gate-execution architecture — snapshot-isolated continuous grading

Date: 2026-08-22 · Status: design proposal (analysis only — nothing implemented) · Author: architect agent, this session

Owner directive: "figure out an alternative for gates to run with a different approach than the current." This document evaluates the four approaches named in the brief, adds a fifth found by tracing *why* today's freeze protocol actually failed, and recommends a combination. It does not decompose into coder waves or Oracle-Gate wiring — the deliverable is the analysis and the recommendation; implementation is a future planning cycle gated on approval of §4.

Rebase check: `merge-base(HEAD, main)` = `27f8eb8c2cc25d4838741b28b2312c6b2d194600` = `main` tip. No rebase needed.

Interface boundary: a sibling task owns the bin's output shape (compact emit + evidence pointer) for whatever new gate-status command this leads to. This spec states the *contract* that command must satisfy (§3.4) and leaves its flags/format to that task.

---

## 0. Restating the problem with the evidence traced to source

`test/run-all.sh` (503 lines) is the single test runner: 348 suites, `--jobs` capped at 6, 670–2310s wall clock per sweep. CLAUDE.md mandates it run exactly once, immediately before the landing commit, over a frozen tree — enforced by `bin/heimdall-conformance`'s `gate-runs-once` / `gates-at-end` checks, which read the session transcript for `test/run-all.sh` invocations in Bash-command position.

Two of today's four sweeps were invalidated. Tracing both to their actual mechanism (not just the symptom):

**Invalidation 1 — concurrent agent edit mid-run.** A freeze protocol already exists: `test/run-all.sh:262–283` writes `${HEIMDALL_HOME:-$HOME/.heimdall}/.gate-in-flight` (pid + repo path) before running, and `bin/heimdall-wip-commit`'s `_gate_in_flight` check (lines 61–79) makes the mechanical WIP auto-checkpointer withhold its commit while that marker is live and owned by the current repo. **This only protects against Heimdall's own checkpointer moving HEAD/the index.** Nothing checks the marker before a `Write`/`Edit` tool call lands on disk — a second agent editing files directly, or a human, mutates the exact bytes the running suites are reading, with no gate in the loop at all. The freeze protocol closes the one race someone had already been bitten by; it does not close the general one. This is the load-bearing finding of this document: **the fix is not "freeze harder," it is "stop grading the tree that's still moving."**

**Invalidation 2 — log reaped from `/tmp`.** `test/run-all.sh:392` (`WORK="$(mktemp -d -t heimdall-run-all.XXXXXX)"`) and the evidence directory at line ~409 (`mktemp -d "${TMPDIR:-/tmp}/heimdall-run-all-evidence.XXXXXX"`) both live under the system scratch root, which macOS/other housekeeping can and did reap mid-sweep or before anyone read it. This is a pure durability bug, unrelated to the freeze question, and is fixable in isolation (§4 Phase 0).

**Consequence, restated precisely:** for most of a session there is no verdict that is both (a) recent and (b) trustworthy, so agents merge on per-suite spot checks — and two real regressions (`wall-presence-drain` 0/7, `heimdall-statusline-perf-budget`) were caught *only* by the final sweep. Note `wall-presence-drain`'s break came from a **different file** than the suite under test — direct evidence against any design that gates on the literal diff alone (Option 3).

A third finding, not in the brief, that changes the migration plan: **`bin/heimdall-conformance`'s gate detector is vacuously satisfied by zero gate runs.** `check_gate_runs_once` / `check_gates_at_end` both treat `gates=0` as `okline` (no dupes, no early-runs — there's nothing to flag). Any design where the landing commit *consults* a verdict instead of *invoking* `test/run-all.sh` directly will make the session transcript show zero `GATE` events, and the conformance tool will report clean — not because verification happened, but because its parser cannot see the new channel. **Any design that moves gate execution off the synchronous Bash-invocation path requires a companion change to the conformance detector, or that detector silently stops meaning anything.** This is called out as a required companion change in §5, owned separately — not implemented here.

---

## 1. Options evaluated

### 1.1 Content-hash incremental (skip suites whose inputs are unchanged)

Directly answers the invalidation-1 symptom (a concurrent edit would only re-trigger the suites touching the changed file, not all 348) — **if** the per-suite input set is derived correctly. It is not, defensibly, without instrumentation the repo does not have:

- Suites are bash scripts that `source` shared libs, shell out to other `bin/*` tools, read env vars, walk `evals/oracles/*` and `evals/corpus/*`, and in several cases (`selfscan.test.sh`, `install-stranger.test.sh`) touch the filesystem broadly (full git history scans, real installs). A hand-maintained manifest of "files suite X depends on" drifts the moment a suite's `source` list changes and nothing enforces the manifest stays honest — this is exactly the failure mode CLAUDE.md's whole oracle-falsifiability apparatus exists to prevent (a check that *looks* like coverage but silently isn't).
- The only defensible way to derive the input set is to **observe** it, not declare it — e.g. `dtrace`/`fs_usage` file-open tracing during a real run, replayed as a canary (a suite whose declared input set is deliberately probed with an unrelated touched file to confirm it still reruns). That is real engineering with its own falsifiability gate, not a config file.
- **False-green risk: HIGH if used as a skip authority.** A missed input (a suite that shells into a helper 3 layers down, or reads an environment variable nobody thought to hash) means the suite silently stays green across a real regression — the single worst outcome named in the brief.

**Verdict: reject as a skip mechanism for now.** Usable only as a **scheduling hint** (§2) — run recently-touched-input suites first for fast feedback, but the full 348 still execute on every graded sweep. That gets the "feels incremental" UX with zero false-green surface, because nothing is actually skipped.

### 1.2 Tiered (fast tier continuously, full sweep only pre-push)

Already implemented and already correct: `bin/heimdall-gate-run --phase pre-commit|pre-push` runs the stub-scan every commit and the oracle-falsifiability + corpus-regression gates at push, and `hooks/hooks.json`'s `git push` PreToolUse chain now defers to the native `.heimdall/hooks/pre-push` hook when it's wired (`core.hooksPath=.heimdall/hooks`) instead of re-running the same ~55.7s of oracle+corpus work twice. **This tiering is orthogonal to the 348-suite full sweep** — it never ran that sweep; it runs a small, fixed, fast set of correctness gates (stub scan, per-domain falsifiability, corpus regression). It is not an alternative to the full sweep, it is the thing that already runs *instead of* the full sweep at every commit/push, which is why the full sweep is reserved for the landing moment in the first place. **Keep as-is.** Nothing in this proposal touches it.

### 1.3 Affected-only from the diff

Cheapest to build, weakest against cross-cutting breakage — and today's own evidence proves the weakness rather than hypothesizing it: `wall-presence-drain` broke from a file outside its own diff. A dependency graph precise enough to catch that class of break is the same unsolved problem as §1.1's input-set derivation, with the same false-green ceiling. **Reject as the sole gate.** Acceptable only as an advisory, non-blocking, fast pre-edit smoke layer that never substitutes for the full sweep — i.e. exactly what the existing pre-commit stub-scan tier already is, so this doesn't buy anything new either.

### 1.4 Continuous background sweep with a live verdict

The right shape for the *cadence* problem (no current verdict for most of a session) but, run against the live working tree, it inherits invalidation-1 exactly: a background sweep reading the same files an agent is editing gets the identical false-invalidation the foreground sweep got today. **Needs §1.5 underneath it to be trustworthy.**

### 1.5 Snapshot-isolated grading (new — the structural fix)

Run the sweep against a **separate `git worktree` checked out at a specific commit**, never against the live working tree. Concretely: `git worktree add <scratch-path> <sha>` materializes an independent directory sharing the same object store (cheap — no full clone, just a checkout) but with its own inodes. A concurrent `Write`/`Edit` on the primary tree cannot perturb it — there is no shared mutable state left to race. This makes invalidation-1 **structurally impossible** rather than policy-prevented: the freeze marker becomes unnecessary for the sweep's own correctness (still useful for the WIP checkpointer, which does need to leave HEAD alone while a human/agent is mid-edit, for unrelated reasons — keep it).

- **Cost:** a `git worktree add`/checkout of this repo (mostly bash/text, no large binaries) is seconds, not the ~15–40 min of the sweep itself. Triggering it once per commit (not once per edit) keeps this cheap.
- **False-green risk: the risk moves from "graded a moving tree" to "graded a stale tree."** The verdict is *for a specific SHA*; a consumer must check that SHA against what's about to ship, exactly (§3.4), not "close enough." This is the fail-closed contract this document requires (§3).
- **Integration risk:** some suites may assume they run from the primary checkout path (`CLAUDE_PLUGIN_ROOT`, hardcoded `$HOME`-relative paths, macOS launchd/sandbox probes already classified `live` and skipped by default). Migration includes a canary phase (§4 Phase 1) that runs both the snapshot sweep and a normal sweep back-to-back and diffs the pass/fail sets before anything trusts the snapshot result alone.

---

## 2. Recommendation

Combine, in order of what each piece is actually for:

1. **Keep §1.2 (tiered pre-commit/pre-push) exactly as-is.** It already solves "fast feedback continuously."
2. **Adopt §1.5 (snapshot-isolated sweep) as the execution substrate.** Trigger a fresh worktree-graded full sweep on every commit to the branch under work (a post-commit hook, mirroring the existing `.heimdall/hooks/` mechanism), not on every edit. This is the piece that removes the freeze requirement structurally instead of policing it.
3. **Layer §1.4 (rolling verdict) on top of 2.** The landing commit doesn't *run* the sweep synchronously; it *consults* the most recent snapshot verdict, under the fail-closed contract in §3.4. If that verdict is missing, stale (wrong SHA), unreadable, or the daemon that should have produced it is dead — fall back to the exact current synchronous `test/run-all.sh` run. Never silently skip.
4. **Use §1.1 (content-hash) only as an in-sweep scheduling hint**, ordering suites so recently-touched-input ones report first — zero false-green surface because coverage is unchanged; it's a UX latency improvement, not a skip.
5. **Reject §1.3 as a gate.** Keep it exactly where it already lives (pre-commit stub-scan), never let it stand in for the full sweep.
6. **Fix the `/tmp` durability bug regardless of everything else** — it is cheap, isolated, and already caused one of today's two invalidations independent of any architecture change.

This is deliberately conservative in the direction the brief demands: "prefer rerunning unnecessarily over skipping wrongly." Nothing here removes a suite from ever running; §2.2–2.3 change *when and where* the 348 suites execute, not *whether* they do, and §2.4 never subtracts coverage — it only reorders it.

### 2.1 False-green risk matrix

| Option | False-green risk | Why | Adopted as |
|---|---|---|---|
| 1.1 content-hash skip | HIGH — undeclared/indirect input untracked by the manifest | scheduling hint only, never a skip authority |
| 1.2 tiered pre-commit/pre-push | none (already correct, unchanged) | kept as-is |
| 1.3 affected-only from diff | HIGH — proven today by `wall-presence-drain` breaking via a different file | rejected as a gate; stays advisory-only where it already is |
| 1.4 continuous background, live tree | HIGH if ungated by 1.5 — inherits invalidation-1 | adopted, but only *on top of* 1.5 |
| 1.5 snapshot-isolated grading | LOW, contingent on exact-SHA freshness check (§3.4) never "close enough" matching | adopted as the execution substrate |

---

## 3. Hard constraints carried into the design

- **Fail-closed, always.** An unreadable/missing/stale verdict resolves to "not verified," never to "pass." The landing consult step, on any ambiguity, falls back to running `test/run-all.sh` synchronously exactly as today — the new architecture is a fast path, never a new failure mode that produces a false pass.
- **Anti-vacuous floor unchanged.** The snapshot sweep still runs through `test/run-all.sh` (or its logic) unmodified, including the `--min 100` discovery floor and silent-red (`DISCREP`) detection. Nothing about grading in a worktree changes the runner's own honesty checks.
- **`HMD_SKIP=1`'s visible unproven-merge receipt is untouched.** This proposal changes where/when the gate runs, not the escape hatch's visibility contract.
- **§3.4 — the exact freshness contract a consult step must satisfy** (this is the interface sibling's bin work sits on top of):
  1. The verdict artifact must record the **exact SHA graded**, a timestamp, and per-suite pass/fail (superset of today's `.heimdall/verdict.json` shape, extended with `graded_sha` and `suite_count`).
  2. A consult is **PASS** only if `graded_sha` equals the commit about to ship (not an ancestor, not "no diff" by content-hash — exact SHA; content-hash equivalence reopens §1.1's derivation risk at the top level).
  3. Anything else — missing file, `graded_sha` mismatch, corrupt JSON, daemon process dead (liveness-checked the same way `_gate_in_flight` already checks pid liveness), suite count under the floor — resolves to **NON_VERIFIED**, and NON_VERIFIED triggers the synchronous fallback, never a silent pass.
  4. The consult step's own falsifiability must be proven the same way every other gate in this repo is: a new suite, `test/gate-rolling-verdict-freshness.test.sh`, asserting each of the five NON_VERIFIED conditions above independently produces a fallback (never a pass), plus one true-positive case — commit a known-bad mutant, consult *before* the daemon has re-graded it, and assert the consult does **not** report pass. This is the meta-gate's own golden/mutant proof, mirroring what `bin/falsify` already requires of every oracle domain.

---

## 4. Migration path (never leaves the repo ungated mid-transition)

**Phase 0 — ship today, no architecture change.**
Move `test/run-all.sh`'s `$WORK` and evidence directories from `${TMPDIR:-/tmp}` to a durable, git-ignored path under `.heimdall/gate-runs/<sha>-<timestamp>/` in the repo (not committed — add to `.gitignore` if not already covered). This fixes invalidation-2 outright and is a strict subset of current behavior: same runner, same guarantees, just a durable location. Zero risk to the existing gate contract.

**Phase 1 — stand up the snapshot substrate, run it in shadow.**
Add a post-commit hook (or extend `.heimdall/hooks/`) that triggers a `git worktree`-graded sweep after each commit, writing the extended verdict artifact from §3.4. For a canary period, this runs *alongside* the current synchronous pre-landing sweep — it does not replace it yet. Diff the two sweeps' pass/fail sets after every run; any suite that disagrees between snapshot-worktree and live-tree grading (path assumptions, `CLAUDE_PLUGIN_ROOT` issues, launchd/sandbox suites) is fixed or explicitly classified before Phase 2. The repo's actual gate — the synchronous full sweep before landing — is unchanged and un-relaxed during this whole phase.

**Phase 2 — the landing commit consults instead of running, fallback proven.**
Only after Phase 1's canary shows zero disagreement across a real sample of commits: change the landing-commit step to consult the rolling verdict under the exact §3.4 contract, with the synchronous run as the always-present fallback path (not removed — kept as the NON_VERIFIED escape valve permanently, not just during migration). Ship `test/gate-rolling-verdict-freshness.test.sh` (§3.4.4) as part of this phase, not before it — the fallback must be proven falsifiable before anything is allowed to depend on it.

**Phase 3 (optional, only if Phase 2's cadence still isn't fast enough) — scheduling hints.**
Add §1.1's content-hash ordering purely for suite-run order within a graded sweep. No coverage change, so no new gate to prove — this is pure latency-of-feedback polish and can be dropped without affecting correctness if it doesn't pull its weight.

At every phase boundary the repo has a currently-enforced, currently-correct gate: Phase 0 changes nothing about *what* gates; Phase 1 adds a shadow signal without touching the real gate; Phase 2 only cuts over once its own fallback is proven falsifiable; Phase 3 is pure ordering. There is no point in this sequence where "the gate" is undefined or weaker than it is today.

---

## 5. Required companion changes (flagged, not implemented here)

- **`bin/heimdall-conformance`'s `gate-runs-once`/`gates-at-end` checks are blind to a consult-based landing gate** (§0, third finding). Both currently treat zero `GATE` events as vacuously fine. Once Phase 2 lands, a session that only ever *consults* a rolling verdict will show zero `test/run-all.sh` Bash invocations and the conformance tool will report clean regardless of whether verification actually happened. This needs a new detection path (e.g. a `CONSULT` event class recognizing the new command in Bash-command position, checked for presence the same way `GATE` is today) — owned by whoever owns `bin/heimdall-conformance`, tracked as a blocking dependency of Phase 2, not Phase 1.
- **Sibling's bin output shape.** The consult command's compact-emit + evidence-pointer format is out of this document's scope by direction; §3.4 states the contract (exact-SHA freshness, NON_VERIFIED fallback, liveness check) that format must expose fields for. Coordinate before Phase 2's implementation task is planned.
- **Daemon/trigger mechanism for the post-commit snapshot sweep** (launchd job vs. a loop process vs. hook-spawned background job) is an implementation choice for the Phase 1 planning cycle, not fixed here.

---

## OUT OF SCOPE

- Implementing any of Phases 0–3 (this document is the design; a coder plan for Phase 0 alone is small enough to be its own follow-up planning cycle).
- Rewriting `bin/heimdall-conformance`'s detector (flagged in §5 as a dependency, not designed here).
- The sibling task's bin output-shape/CLI design (contract only, per direction).
- Changing `hooks/hooks.json`'s existing pre-push dedup logic (already correct, untouched).
- Any change to `HMD_SKIP=1` semantics or visibility.
- Migrating or re-triaging any currently-skipped `live`/credentialed suite classification.
- Performance tuning of individual suites' own runtime (`selfscan.test.sh`, `install-stranger.test.sh` overrides) — orthogonal to execution architecture.

## Risks & Mitigation

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Snapshot worktree suites disagree with live-tree suites (path/env assumptions) | med | high (false confidence in Phase 2) | Phase 1 shadow-run canary diffs every sweep before cutover | Phase 1 task |
| Conformance detector silently stops meaning anything once consult-based landing ships | high if unaddressed | high (silent loss of gate-runs-once/gates-at-end enforcement) | §5 companion change tracked as a hard Phase 2 dependency, not optional | Phase 2 task |
| Rolling verdict consulted at wrong SHA ("close enough" drift) | med | high (false green on the exact case this document exists to prevent) | §3.4 exact-SHA-only match, never content-hash equivalence at this layer | Phase 2 task |
| `/tmp` durability fix alone mistaken for "done" | low | med (Phase 1–3 never gets scheduled) | This document explicitly frames Phase 0 as necessary-but-not-sufficient | Phase 0 task |
| Content-hash scheduling hint (Phase 3) miscoded as a skip by a future editor | low | high (reintroduces §1.1's rejected false-green mode) | Phase 3 explicitly specified as ordering-only, zero coverage change, code-reviewed against that constraint | Phase 3 task |
