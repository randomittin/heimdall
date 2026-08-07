# Complex Path — Full Planning Pipeline

**Read this when complexity triage returns Complex** (new project, major feature,
multi-package, cross-cutting change), **or when you are wiring a correctness gate**
(oracle selection, gate-type ranking, falsifiability enforcement, reference
independence). Simple and Medium tasks never need this file — they run the inline
Simple/Medium paths in `agents/heimdall.md` §4.

This is the core hybrid planning+execution flow:

## Phase 1: Init
- Create `.planning/` dir in the project root (if missing)
- Update state: `heimdall-state set '.project.phase' '"planning"'`

## Phase 2: Discuss
- Analyze the codebase: read key files, understand patterns, identify constraints
- Surface assumptions — don't guess, verify
- Capture all context in `.planning/CONTEXT.md`:
  - Tech stack, existing patterns, conventions
  - External dependencies and their versions
  - Known constraints (performance budgets, API limits, etc.)
  - User's stated and implied requirements

## Phase 3: Plan
- Run `decompose "<task>" --output json` to get the initial task decomposition
- **Auto-wire the oracle gate.** Immediately after `decompose`, resolve the detected domain against the canonical oracle registry and wire its oracle as the gate of the final correctness wave — never let the impl agent invent its own success check:
  ```bash
  # decompose emits the domain; fall back to task-description signals if absent.
  # resolve the domain to its canonical external oracle: gate command + gate type.
  bin/oracle-select <domain>     # prints the gate command + gate type, exit 0 on a registry match
  ```
  - The registry lives at `evals/oracles/registry.json`; `bin/oracle-select <domain>` resolves a domain to its `gate_command` and `gate_type` (`differential | trace-diff | verdict | property | example`).
  - If `bin/oracle-select` matches a domain, that canonical oracle becomes a **mandatory wave gate** on the final correctness wave of the emitted plan. Pass the resolved gate command + gate type to the planner as a required field on that wave's task — the orchestrator wires the external oracle so the impl agent cannot substitute a self-authored check.
  - If no registry entry matches, the planner falls back to task-specific acceptance criteria — but a stateful or sequence-producing target left without a `differential`/`trace-diff` oracle is flagged for the gate-type enforcement in Phase 4.
- Feed the decompose output (and the wired oracle, if any) to the **planner agent** (architect) to create `.planning/PLAN-{phase}.md`
- The plan MUST contain:
  - **Waves**: groups of tasks that can run in parallel (wave 1 has no deps, wave 2 depends on wave 1, etc.)
  - **Tasks per wave**: specific, scoped units of work with clear file boundaries
  - **Acceptance criteria**: for each task AND for the overall plan — must be runnable (test commands, grep checks, build commands), not vague
  - **Skills assigned**: which skills each task's agent should load
  - **Agent type**: which agent handles each task (coder, design, test-runner, etc.)
- Dependency graph between waves is implicit in wave ordering — no cycles possible

## Phase 4: Verify Plan
Before executing, check the plan:
- All user requirements are covered by at least one task
- All acceptance criteria are concrete and runnable (not "works correctly" — instead "pytest tests/auth/ passes", "curl /api/health returns 200")
- No dependency cycles between tasks within the same wave
- No overlapping file scopes between parallel tasks in the same wave
- Token budget is realistic for the plan scope

**Oracle-gate enforcement (mandatory — reject the plan if any of these fail):**
- **Falsifiability.** Any plan whose final correctness wave uses a wired oracle gate MUST ship that gate's golden + mutant fixtures and prove a falsifiability score of `1.0` (golden passes AND every mutant is rejected). Verify with:
  ```bash
  bin/falsify <domain> --assert-score 1.0   # exit non-zero if golden fails OR any mutant survives
  ```
  A gate with no golden+mutant fixtures, or a falsifiability score < 1.0, **fails plan verification** — a green suite over a non-falsifiable gate is a false-green and is rejected. This is the structural kill for the tautological "test that cannot fail."
- **Gate-type ranking.** The planner applies, strongest first: `differential` (whole-output vs an independent reference) > `trace-diff` (per-step state vs a truth log) > `verdict` (external pass/fail signal) > `property` (local invariants) > `example` (hand-written cases). For any **stateful or sequence-producing target**, the final correctness wave MUST include a `differential` or `trace-diff` gate. A plan that gates such a target with only `property`/`example` checks **fails plan verification** — local per-element invariants are necessary but never sufficient (they pass the no-local-signal bug class: ordering races and whole-sequence invariants).
- **Concurrency targets.** Any target whose spec mentions concurrency/async/parallel MUST get a deterministic seeded-interleaving gate (forced variance across seeds), not a fixed-yield / `Promise.all`-over-synchronous dispatch that resolves in arrival order by construction. A plan lacking the seeded-interleaving gate for such a target **fails plan verification**.

At autonomy level 1 (Guided): present plan and wait for approval.
At autonomy level 2 (Checkpoint): present plan and proceed unless user intervenes.
At autonomy level 3 (Full Auto): proceed immediately.

## Phase 5: Execute (Wave-Based)
For each wave, in order:
1. **Fresh context per wave**: each wave-executor agent starts with ONLY the plan, context doc, and relevant source files — NOT accumulated state from prior waves. This prevents context bloat.
2. **Parallel within wave**: spawn one agent per task in the wave, all running concurrently
3. **Wait for wave completion**: all tasks in wave N must finish before wave N+1 starts
4. **Per-task verification**: after each task completes, run its acceptance criteria immediately
5. **Failure handling**: if a task fails, retry once with narrower scope. If still failing, pause the pipeline and escalate.

**Oracle independence — spawn the reference in a SEPARATE wave/agent (mandatory).** When a `differential` oracle is wired, the reference half MUST be authored independently of the implementation — by a different agent, in a separate wave, with disjoint context and file scope. A shared author means a shared spec misconception passes undetected in both halves and the diff falsely reports PASS. Enforcement:
- Spawn the **independent reference** as its OWN agent in a SEPARATE wave from the impl task — never the same agent or prompt that wrote the impl, and never with the impl's spec visible beyond the shared INVARIANTS ledger.
- Disjoint file scope: the reference lives in `evals/oracles/<domain>/reference/`, the impl in its own dir — enforced by the same-wave-file-disjointness rule.
- For external-dataset oracles (e.g. gameboy-doctor truth logs), independence is inherent — the dataset is the reference and no reference-authoring agent is needed.
- The reference must NOT import the implementation; structural no-impl-coupling is part of plan verification (Phase 4).

Agent spawn instructions for each task include:
- Specific scope and file boundaries
- Skills to invoke (explicit, not assumed)
- Relevant context files to read
- Constraints (what NOT to touch)
- Acceptance criteria to self-check before reporting done

### Dynamic Scaling

During wave execution, adjust parallelism based on task progress:
- If all agents are busy AND pending tasks exist → spawn additional agents (up to 10 total)
- If agents are idle with no pending tasks → don't spawn more
- If a wave completes faster than expected, immediately start the next wave (don't wait for a polling interval)

Monitor via dispatch queue status: if `pending > 0` and `running < 10`, scale up.

## Phase 6: Verify
- Spawn a **verifier agent** to check ALL acceptance criteria across all waves
- Verify requirement coverage: every original requirement maps to a passing check
- Run the full test suite, linter, and type checker
- Update `.planning/PLAN-{phase}.md` with verification results

## Phase 7: Ship
- Git commit with conventional commit message
- Update `.planning/` with completion status
- Summary to user: what shipped, what was verified, any caveats

---

# Goal-Driven Execution

Heimdall uses Claude Code's `/goal` command for autonomous execution with built-in verification. This replaces manual looping with native goal evaluation — a separate Haiku evaluator checks completion after each turn.

The goal is synthesized from the plan's acceptance criteria, so this applies once a
plan exists (Phase 3 above). Error recovery for a failed agent is NOT here — that
rule applies at every complexity level and stays inline in `agents/heimdall.md`.

## 6a. Setting the Goal

After the planner creates a plan with acceptance criteria (Phase 3), synthesize a goal condition:

1. Collect ALL acceptance criteria from `.planning/PLAN-{phase}.md`
2. Aggregate into a single goal condition string (max 4000 chars)
3. Focus on observable outcomes from conversation transcript (the evaluator has no filesystem access — it only reads what appears in the conversation)
4. Always include baseline checks:
   - "all tests pass"
   - "lint clean"
   - "build succeeds"
   - "no unfinished, skeleton, or dummy code in changed files"
5. Add domain-specific criteria from the plan

**Goal condition template:**
```
/goal <plan-specific criteria>, all tests pass, lint clean, build succeeds, no unfinished or skeleton code in changed files
```

**Example:**
```
/goal login API returns JWT on valid credentials, auth middleware rejects expired tokens, rate limiter blocks after 100 req/min, all tests pass, lint clean, build succeeds
```

6. Set the goal: invoke `/goal <condition>`
7. Track it: `heimdall-state goal-set "<condition>" "planner"`
8. Proceed with wave execution (Section 5)

## 6b. Goal Lifecycle

- **One goal per session.** When a new plan is created, set a new goal (replaces old).
- **Check status:** Bare `/goal` shows active condition and evaluator assessment.
- **Clear:** `/goal clear` when switching tasks or user wants manual control.
- **Restore:** On session resume (`--resume`), restore goal from `heimdall-state goal-get`.
- **Checkpoint:** `/hmd:save` persists active goal condition for cross-session restore.

## 6c. Two-Tier Verification

The Haiku evaluator (built into `/goal`) and the verifier agent serve complementary roles:

| Layer | Model | Access | Checks | Cost |
|-------|-------|--------|--------|------|
| `/goal` evaluator | Haiku | Conversation transcript only | "Does it look done from the conversation?" | Very low |
| Verifier agent | Opus | Full filesystem + commands | Runs actual acceptance criteria commands | Higher |

**Flow:**
1. Work proceeds through wave execution
2. After each turn, the `/goal` evaluator checks the transcript
3. If evaluator says "not done" → continue to next wave (or retry failed tasks)
4. If evaluator says "done" → spawn verifier agent for deep filesystem confirmation
5. If verifier passes → truly done, ship it
6. If verifier fails → evaluator was premature. Continue working.

This prevents premature completion claims. The Haiku evaluator is cheap enough to run every turn; the Opus verifier only runs when the evaluator is optimistic.

## 6d. When NOT to Set Per-Wave Goals

Only one goal active at a time. Do NOT set per-wave goals — this replaces the overall goal. Keep the top-level goal set for the entire plan. Wave-level verification uses acceptance criteria checks directly (non-goal-based). The `/goal` tracks overall plan completion.

## 6e. Fallback: Manual Loop

If `/goal` is unavailable (older Claude Code version <2.1.139), fall back to the manual loop:

```
while task_not_complete:
  1. ASSESS — Read heimdall-state.json, check what's done/left
  2. IDENTIFY — Determine next actions (which agents to spawn/continue)
  3. EXECUTE — Spawn agents, respecting current autonomy level
  4. QUALITY — After each sub-project completes:
     a. Run tests (spawn test-runner if needed)
     b. Run lint (spawn lint-quality)
     c. Check for conflicts in conflict_log
  5. UPDATE — Write results to heimdall-state.json
  6. CHECKPOINT — If autonomy level ≤ 2 and milestone reached:
     - Report progress to user
     - Show quality gate status
     - Wait for acknowledgment (level 1) or continue (level 2)
  7. BLOCKED? — If stuck:
     - Level 3: attempt self-resolution first
     - Levels 1-2: escalate to user with full context
```
