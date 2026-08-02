# Heimdall S-6 — Generalization Proofs (hand-to-`hmd` spec)

**Status:** the consequential gate. Everything shipped so far proves Heimdall *installs* and *runs its own canned demo* cleanly. S-6 proves the only thing that actually matters: that it produces **real, measurable reuse and working output on codebases that aren't the demo.** Until S-6 passes, all install/demo/watchman polish is polish on an unproven core. Do this before any forward feature (F2–F6).

---

## What & why

Prove generalization with three artifacts that build on each other:
1. a **reuse metric** that is defined precisely and emitted per run,
2. a **mini-git reuse test** (controlled — a task that *should* reuse existing code),
3. a **popular-10 cold run** (breadth — real OSS repos, cold),
plus a **halt-if-low-reuse rule** that makes the tool refuse to proceed when it's likely reinventing (dogfooding "nothing ships unproven").

The output is **honest numbers**, not a green checkmark. If reuse is low across the popular-10, that is a FINDING about the core — surface it, do not hide or fake it. A failed S-6 is more valuable than a faked pass: it tells you exactly where the product needs work before launch.

---

## Component 1 — Define & emit the reuse metric (build first)

The whole gate is meaningless without a defensible definition. Define **reuse** precisely and emit it as structured data per run (this is SI-2-adjacent — the commit-time attestation record from the forward-capabilities spec; if SI-2 exists, emit into it).

**Definition to implement (adjust only with a written rationale):**
> Reuse % = (count of changed/added code units that *call, import, or extend an existing module/function/component/pattern already in the repo*) ÷ (total changed/added code units), per task.

- A "code unit" = a function, component, or meaningful block (define the granularity in code and document it).
- **Reuse** = the new code depends on or invokes pre-existing repo code rather than writing a parallel implementation of something that already exists.
- **Reinvention** = the new code duplicates capability that already existed elsewhere in the repo.
- Emit per run: `{ task, units_total, units_reusing, units_reinventing, reuse_pct, reused_symbols: [...], suspected_duplicates: [...] }` to a machine-readable record (JSON), plus a one-line human summary.

**Acceptance (C1):** every `hmd "task"` run emits the reuse record; the metric is documented (definition + granularity + edge cases) in `conventions.md` or a dedicated `REUSE-METRIC.md`; the suspected-duplicates list is populated when the agent writes something that overlaps existing code.

---

## Component 2 — Mini-git reuse test (controlled proof)

Construct (or pick) a **small multi-module repo** where the correct solution to a task *obviously* requires reusing existing code — e.g. a repo with a `utils/format.js`, a `db/client.js`, and an existing `User` model, then a task ("add an endpoint that returns a formatted user") that a competent dev would solve by *calling the existing utils/model*, not rewriting them.

- Run the task via `hmd "task"` against this repo.
- Measure reuse % via Component 1.
- **Acceptance (C2):** reuse ≥ a stated threshold (start at **≥ 60%** for a task this reuse-friendly; justify if you change it). The agent must call the existing `format`/`db`/`User`, not reinvent them. If it reinvents, that's a real finding — report the reuse % and *what* it duplicated.

Make this a **permanent harness fixture** (`test/reuse-mini-git.test.sh` or fold into the conformance suite) so reuse regressions fail loudly later.

---

## Component 3 — Popular-10 cold run (breadth proof)

Pick **10 small, popular, permissively-licensed OSS repos** (varied languages/stacks — not 10 of the same kind). For each: cold-clone, give a **representative, realistic task** (a small feature or fix that a maintainer might assign), run via `hmd "task"`, and capture:
- reuse % (Component 1),
- whether it produced **working output** (tests pass / builds / acceptance criteria met — runnable evidence, not self-report),
- token spend.

**This is spend-gated.** Real model calls cost tokens — bound the total budget explicitly (suggest a hard cap, e.g. ~600k tokens across all 10, fail-closed if exceeded). Do NOT run all 10 unattended without the cap. Stage it so RJ approves the spend before the full sweep (a dry-run on 1–2 repos first, then the full 10 on approval).

**Acceptance (C3):** a reuse-% distribution across the 10 + a working-output rate (e.g. "7/10 produced passing tests, median reuse 48%"). Report the distribution honestly. Low/uneven reuse = the core finding to act on, not a number to massage.

---

## Component 4 — Halt-if-low-reuse rule (dogfood the thesis)

If a run's measured reuse < **30%**, the run **HALTS** (or hard-warns and requires explicit `--force`) with an honest signal: *"Low reuse (X%) — likely reinventing existing code: [suspected duplicates]. Inspect before proceeding."*

- This makes Heimdall refuse to silently ship reinvention — the literal embodiment of "nothing ships unproven."
- **Acceptance (C4):** the halt fires correctly on a deliberately reuse-hostile run (one where the agent reinvents); does NOT fire on the C2 reuse-friendly run; the threshold + behavior are documented; a harness assertion proves both the fire and the no-fire cases.

---

## Boundaries

- **Spend cap is non-negotiable** — Component 3 burns real tokens. Hard budget, fail-closed, RJ approves before the full sweep.
- **Never fake a pass.** If reuse is low, report it. The whole point of S-6 is an honest verdict on the core.
- Don't build forward features (F2–F6) inside this — S-6 is the gate that *precedes* them.
- Don't touch the release/tag machinery; this is measurement + a halt rule, not a release.

## Delegation

- C1 (metric definition + emission) is the foundation — one focused agent, build first, merge, verify the record emits on a real run.
- C2 (mini-git fixture) + C4 (halt rule) can follow on the merged C1 — they consume the metric.
- C3 (popular-10) is the spend-gated sweep — stage as dry-1-or-2 → RJ approves → full-10. Verify working-output claims from runnable evidence per R7 (don't trust agent self-report; check tests actually pass).

## Handoff

Build C1→C2→C4, prove each with harness assertions, then run C3 staged behind the spend cap. **Report the real reuse numbers** (mini-git %, popular-10 distribution, working-output rate). Tell me the verdict — does it generalize, and where's the weakest reuse? That verdict, not a green check, is the deliverable. If it passes, S-6 is cleared and the forward features unlock. If it doesn't, the numbers tell you exactly what to fix in the core before launch.
