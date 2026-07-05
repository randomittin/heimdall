# Oracle-Gate System + Flagship Eval Suite

**Date:** 2026-06-11
**Status:** Proposed
**Spike evidence:** `evals/flagship/SPIKE-FINDINGS.md` (4-arm spike: exchange × {raw, superx}, emulator × {raw, superx}, opus held constant)

---

## Positioning (the defensible claim)

> **heimdall ships VERIFIED.** It brings and auto-wires the canonical *external* oracle for the domain, makes every gate falsifiable (proven able to go red before it is trusted green), and catches the bug class that emits *no local signal* — ordering races, whole-sequence invariants, and missing subsystems that sail straight through a naive green test suite.

It is **NOT** "superx writes code raw Claude Code can't." The spike disproves that claim, and we will not make it. See the honesty section below.

---

## The evidence, stated bluntly

We ran four arms. The model was **opus in all four** — the only variable is PROCESS, so any delta is attributable to scaffolding, not raw model capability.

| Arm | Code correctness | What shipped wrong | What caught it |
|---|---|---|---|
| **exchange-raw** | Logically correct matching engine first try; 0 logic bugs; 200-seed sweep clean | **False-green oracle**: a tautological `Promise.all`-over-sync-`submit` concurrency test that *cannot fail*, plus a reference matcher authored by the same agent (shared spec misconception invisible to the diff) | nothing — only post-hoc human review noticed the tautology |
| **exchange-superx** | Same engine quality; same latent bug *class* present | A real concurrency race (`await riskCheck` before the read-match-mutate critical section) | **whole-output differential oracle** at seed 1 idx 0, shrunk to a 7-order repro. Per-trade invariants (no-cross, qty-balance, net-zero, no-double-fill) ALL PASSED. Only the diff + **seeded variable-latency** harness surfaced it; the fixed-yield concurrency test passed too. |
| **emulator-raw** | 512-opcode LR35902 core **byte-exact** vs gameboy-doctor over tens of millions of trace lines; 10/11 blargg cpu_instrs PASS; 0 opcode/flag bugs (DAA, CB-prefix, 16-bit half-carry all correct) | 1 fail = descoped timer/interrupt subsystem, **no local signal** during build | the *provided* external oracle (gameboy-doctor + blargg), only at end-of-build |
| **emulator-superx** | Also 10/11, byte-exact, 0 opcode bugs; same single timer gap (descoped) | same timer gap, but **predicted** | per-instruction trace oracle pinpointed divergence to exact PC+opcode; flag ledger written before coding made impl transcribe-not-guess |

### The honest synthesis (this anchors everything below — do not soften it)

1. **Our original thesis was partly wrong.** "Silent bugs accumulate across long autonomous runs; raw CC breaks" **did not reproduce.** Opus one-shots the *code* on both targets. Raw and superx produced ~equivalently correct code — raw even emitted 512 opcodes byte-exact. We will **not** over-invest in context-decay machinery the evidence does not justify. (See "What we are NOT building.")
2. **The real delta is VERIFICATION, not generation.** heimdall's value is not "writes better code." It is:
   - **(a)** it KNOWS and AUTO-WIRES the canonical external oracle per domain (blargg + gameboy-doctor for emulators; independent reference-matcher + LOB replay for exchanges). A naive user gets "seems to work." heimdall gets a truth source.
   - **(b)** it builds oracles that can actually FAIL.
   - **(c)** it catches the bug class with NO LOCAL SIGNAL — ordering races, whole-sequence invariants, subsystem holes — that pass a naive green suite.
3. **The headline danger is FALSE-GREEN oracles** (the raw-exchange tautological test): the canonical failure mode of "let the LLM write its own tests." heimdall must *structurally* prevent it. This is the single most important property of the whole system.

---

## Upgrade priority table

| # | Upgrade | Priority | Proven by | One-line value |
|---|---|---|---|---|
| 1 | Oracle library + auto-wiring | **P0** | emulator (both arms passed *only because* the oracle was provided) | heimdall knows the canonical truth source per domain and wires it as a wave gate |
| 2 | Falsifiable-gate enforcement via mutation testing | **P0** | exchange-raw (false-green tautology) | no gate is trusted green until a known injected bug has made it go red |
| 3 | Differential / whole-output oracle as a first-class gate type | **P0** | exchange-superx (only the diff caught the race) | whole-output equality vs an independent reference beats local property checks |
| 4 | Oracle independence | **P1** | exchange-raw (shared-author blind spot) | reference authored by a *different* agent / external dataset, never the impl's prompt |
| 5 | Invariant ledger written BEFORE coding + re-injected per wave | **P1** | emulator-superx (transcribe-not-guess) | front-loaded semantics; *no teeth without the differential oracle* |
| 6 | Deterministic seeded interleaving / chaos harness | **P1** | exchange-superx (decisive) | forced variance, not fixed-yield — surfaces races a single dispatch order hides |
| 7 | Coverage matrix (declared scope/subsystem holes) | **P2** | both emulator arms (timer gap) | holes are *predicted upfront*, not *discovered* at end-of-build |

---

## Upgrade specifications

Each upgrade states: what it is, which spike arm proves its value, how it integrates with existing heimdall (`agents/heimdall.md` waves, `bin/benchmark`, `heimdall:verifier`, hooks), and a **runnable acceptance criterion**.

### Upgrade 1 — Oracle library + auto-wiring (P0)

**What.** A registry of canonical *external* oracles keyed by domain. Each entry declares: domain match signals, the oracle assets (reference dataset / truth log / reference implementation source), the gate command, and the gate type (differential | trace-diff | property | verdict). When the planner decomposes a task whose domain matches a registry entry, it MUST auto-select that oracle and wire it as the gate of the final correctness wave — never let the impl agent invent its own success check.

Registry location: `evals/oracles/registry.json`. Each domain gets a directory `evals/oracles/<domain>/` holding the oracle harness + a pointer to (not a copy of) large external truth data.

Seed entries (from the spike):
- `emulator-gb` → blargg cpu_instrs ROMs + gameboy-doctor truth traces; gate type `trace-diff` + `verdict`.
- `exchange-lob` → independent O(n²) reference matcher (DIFFERENT-agent authored) + deterministic LOB replay; gate type `differential`.
- `raytracer` (CALIBRATION only) → SSIM vs reference render; gate type `image-similarity`. Present to keep the flagship table honest (raw CC also passes it) — see flagship README.

**Proven by.** Emulator, both arms: each passed *only because* gameboy-doctor + blargg were the truth source. A naive user without that oracle ships "seems to work."

**Integration.**
- `agents/heimdall.md` Phase 3 (Plan): after `decompose`, the orchestrator queries the registry; if a domain matches, the matching oracle becomes a mandatory wave gate in the emitted plan.
- `agents/architect.md` / `agents/planner.md`: oracle selection is a required field on the final correctness wave's task.
- `bin/benchmark`: the flagship suite (deliverable 3) consumes the same registry — **one build, two uses** (benchmark receipts *and* in-loop wave gates read the same oracle definitions).
- `heimdall:verifier`: runs the wired oracle command as the task's `Verify:` step.

**Runnable acceptance criterion.**
```bash
# registry is valid JSON with the two flagship domains wired
jq -e '.oracles["emulator-gb"].gate_command and .oracles["exchange-lob"].gate_command' evals/oracles/registry.json
# a lookup CLI resolves a domain to its gate command (exit 0, prints a command)
bin/oracle-select exchange-lob | grep -q .
```

### Upgrade 2 — Falsifiable-gate enforcement via mutation testing (P0)

**What.** Before any gate is trusted green, prove it can go RED. Each gate ships its OWN self-contained fixtures inside its gate dir — it never touches a flagship implementation (building flagship impls is OUT OF SCOPE; the impl exists only at benchmark time). A gate proves its own falsifiability against fixtures:

- `evals/oracles/<domain>/fixtures/golden/` — a known-CORRECT minimal fixture the gate MUST pass. If the gate rejects golden, the gate is broken (over-strict / false-red).
- `evals/oracles/<domain>/fixtures/mutants/` — known-BAD fixtures, each an injected defect the gate MUST reject. A mutant that survives (gate stays green) is a **false-green gate** and is REJECTED — the build is BLOCKED until the gate is hardened.

`bin/falsify <domain>` runs the gate against the golden fixture (expect PASS) and against every mutant fixture (expect REJECT). A gate's **falsifiability score** = mutants rejected / mutants total, conditioned on golden passing. Required: **1.0** (golden passes AND every mutant rejected) for a P0 gate. This is the structural kill for the exchange-raw tautology, dogfooded inside the gate itself: the gate is proven able to go red on fixtures before it is ever pointed at the real impl.

Mutant fixtures per domain live in `evals/oracles/<domain>/fixtures/mutants/` (e.g. exchange: `lifo-tiebreak`, `drop-resting-remainder`, `fill-at-aggressor-price`, `queue-jump`, and the `tautological-concurrency` fixture — the raw-arm's `Promise.all`-over-synchronous-`submit` test that cannot fail. emulator: `force-h-zero`, `skip-f-mask`, `jr-off-by-one`). Each is a minimal self-contained input + the defect it encodes; `manifest.json` maps each mutant to the gate it must turn red.

**Proven by.** exchange-raw: the `Promise.all`-over-synchronous-`submit` concurrency test resolves in arrival order by construction — it is a tautology that passes even when real interleaving is broken. Mutation testing would have caught it: inject a queue-jump mutant, observe the gate still green → gate rejected.

**Integration.**
- New CLI `bin/falsify <domain>`: runs the gate against `fixtures/golden/` (asserts PASS), then against every fixture in `fixtures/mutants/` (asserts REJECT), reports the score. Exit non-zero if golden fails OR any mutant survives. Operates ONLY on the gate's shipped fixtures — never on a flagship impl.
- `agents/heimdall.md` Phase 4 (Verify Plan): a plan whose correctness gate ships no golden+mutant fixtures, or whose falsifiability score < 1.0, fails plan verification.
- Hook awareness: `bin/falsify` is a candidate for a pre-push quality gate alongside `heimdall-state check-quality-gates` (the `git push` Bash hook). A green test suite over a non-falsifiable gate must NOT satisfy the push gate.
- `heimdall:verifier`: before scoring a task PASS on its oracle, confirms `bin/falsify <domain>` reported 1.0 for that gate.

**Runnable acceptance criterion.**
```bash
# every flagship gate passes golden AND rejects every mutant fixture (score 1.0)
bin/falsify exchange-lob --assert-score 1.0
bin/falsify emulator-gb  --assert-score 1.0
# the tautological-concurrency mutant fixture exists (the raw-arm Promise.all-over-sync test)
test -f evals/oracles/exchange-lob/fixtures/mutants/tautological-concurrency
# running falsify against a surviving (tautological) mutant prints the exact reject contract
bin/falsify exchange-lob --mutant tautological-concurrency 2>&1 | grep -q 'REJECTED: mutant survived'
```

### Upgrade 3 — Differential / whole-output oracle as a first-class gate type (P0)

**What.** Promote *whole-output equality against an independent reference* to a first-class gate type, ranked ABOVE local property checks. A differential gate runs the implementation and an independent reference over an identical deterministic input stream and asserts the **entire output sequence** matches exactly — not merely that each output element is individually valid. Local property checks (per-trade invariants, per-instruction flag checks) are necessary but **not sufficient** and must never be the sole correctness gate for a stateful/sequenced target.

Gate-type ranking the planner applies (strongest first): `differential` (whole-output vs independent ref) > `trace-diff` (per-step state vs truth log) > `verdict` (external pass/fail signal) > `property` (local invariants) > `example` (hand-written cases).

**Proven by.** exchange-superx: per-trade invariants I1–I4 (no-cross, qty-balance, net-zero) AND no-double-fill (C1) **all passed**. The concurrency race was a *whole-sequence* property (C2: concurrent == serial replay). Only the differential oracle caught it — at trade index 0, `takerId=7` jumped ahead of `takerId=3`. A suite asserting only "trades are valid" would have shipped the bug.

**Integration.**
- `agents/architect.md` / `agents/planner.md`: for any stateful or sequence-producing target, the final correctness wave MUST include a `differential` or `trace-diff` gate; a plan with only `property` gates for such a target fails plan verification.
- `evals/oracles/<domain>/`: each differential oracle ships the reference + a deterministic seeded stream generator.
- `heimdall:verifier`: treats a `differential` PASS as the authoritative correctness signal; a green `property` suite alongside a missing/red `differential` gate is reported FAIL.

**Runnable acceptance criterion.**
```bash
# the exchange differential gate exists, runs both impl + independent ref over a seeded
# stream, and reports the first divergence index on mismatch
bin/oracle-select exchange-lob | grep -q 'differential'
# the gate distinguishes whole-output mismatch even when every element is locally valid
test -f evals/oracles/exchange-lob/differential.md
```

### Upgrade 4 — Oracle independence (P1)

**What.** The reference half of any differential oracle MUST be independent of the implementation: authored by a *different* agent (separate prompt, separate context) or sourced from an external dataset — never the same prompt/agent that wrote the impl. A shared author means a shared spec misconception passes undetected in both, and the diff says PASS while both are wrong.

Enforcement: the planner places impl and reference in **separate waves or separate agents with disjoint context**, and the spec of one must not be visible to the author of the other beyond the shared INVARIANTS ledger. For external-dataset oracles (gameboy-doctor truth logs), independence is inherent.

**Proven by.** exchange-raw: engine and reference were written by the same author in the same pass, sharing the same interpretation of (a) trade-at-maker-price, (b) market-remainder-dropped, (c) FIFO-by-arrival. A *specification* error in any would be present in BOTH and the diff would still say PASS. The diff catches implementation divergence, not shared misconception.

**Integration.**
- `agents/heimdall.md` Phase 3/5: when a differential oracle is wired, the reference task is spawned as a SEPARATE agent in a SEPARATE wave from the impl task — disjoint file scope (`evals/oracles/<domain>/reference/` vs the impl dir), enforced by the same-wave-file-disjointness rule.
- `agents/architect.md`: plan must show impl-author ≠ reference-author for any differential gate.

**Runnable acceptance criterion.**
```bash
# the reference lives in its own dir, separate from any impl, and the registry marks it independent
test -d evals/oracles/exchange-lob/reference
jq -e '.oracles["exchange-lob"].reference.independent == true' evals/oracles/registry.json
# STRUCTURAL independence: the reference must NOT import the implementation (no impl-coupling).
# A self-authored "independent" string proves nothing; this detects actual coupling.
! grep -rqE 'import.*(engine|impl)' evals/oracles/exchange-lob/reference/
```

### Upgrade 5 — Invariant ledger written BEFORE coding + re-injected per wave (P1)

**What.** Before any implementation wave, the architect writes a load-bearing INVARIANTS ledger (exact semantics, flag rules, edge cases — e.g. the LR35902 flag table, the LOB matching invariants I1–I4 / C1–C2). The ledger is re-injected into every implementation wave so the impl *transcribes* the spec rather than *guessing* it. **Explicit limitation: the ledger helps but has NO TEETH without the differential oracle** — a per-element invariant suite passes the exchange race. The ledger's value is making local correctness cheap and front-loading the hard semantics; the differential/trace oracle is what actually catches the no-local-signal class.

**Proven by.** emulator-superx: the flag-semantics ledger (DAA, ADD SP,e low-byte half-carry, INC/DEC C-preservation) written before coding made the implementation transcribe exact rules; DAA and 16-bit half-carry — the classic killers — passed first build. Contrast: it would NOT have caught the exchange race (C2 was IN the ledger up front, yet invisible to every per-trade check).

**Integration.**
- `agents/architect.md`: emit `INVARIANTS.md` as a wave-0 artifact for any target with non-trivial semantics; list it under "Read first" for every downstream impl task.
- `agents/heimdall.md` Phase 5: each wave-executor reads the ledger before writing code (the spike's "re-read INVARIANTS.md before each wave" discipline).
- Hook awareness: the ledger is committed to `.planning/` (human-readable, git-committed per CLAUDE.md rules).

**Runnable acceptance criterion.**
```bash
# the spike-proven ledger format is preserved for both flagship targets
test -f evals/oracles/exchange-lob/INVARIANTS.md
test -f evals/oracles/emulator-gb/INVARIANTS.md
# ledger encodes the killer semantics as checkable statements (not prose stubs)
grep -q 'DAA' evals/oracles/emulator-gb/INVARIANTS.md
grep -q 'no-cross' evals/oracles/exchange-lob/INVARIANTS.md
```

### Upgrade 6 — Deterministic seeded interleaving / chaos harness (P1)

**What.** For concurrent/async targets, the gate must FORCE variance — a deterministic seeded variable-latency scheduler that interleaves operations across many seeds — rather than a fixed-yield dispatch that resolves in arrival order by construction. The harness awaits a seeded variable-latency hook before each critical section, sweeps N seeds, and diffs the resulting whole-output sequence against the serial-replay reference (combines with Upgrade 3).

**Proven by.** exchange-superx: the race was caught by 200-seed variable-latency interleaving at seed 1; the naive fixed-yield concurrency test (the exact construction the raw arm shipped) passed. The single innocent `await riskCheck` before the read-match-mutate critical section scrambled price-time priority by I/O-latency race — invisible without forced variance.

**Integration.**
- `evals/oracles/exchange-lob/`: ships the seeded-latency scheduler as part of the differential gate harness.
- `agents/architect.md`: any target whose spec mentions concurrency/async/parallel MUST get a seeded-interleaving gate, not a `Promise.all` tautology. This is a plan-verification check.
- Mutant fixtures (Upgrade 2) include a `queue-jump` fixture AND the `tautological-concurrency` fixture to prove the interleaving gate is falsifiable (it must reject both).

**Runnable acceptance criterion.**
```bash
# the interleaving harness sweeps multiple seeds and is part of the exchange gate
test -f evals/oracles/exchange-lob/interleave.md
grep -q 'seed' evals/oracles/exchange-lob/interleave.md
# the queue-jump + tautological-concurrency mutant fixtures exist (rejected via falsify, Upgrade 2)
test -f evals/oracles/exchange-lob/fixtures/mutants/queue-jump
test -f evals/oracles/exchange-lob/fixtures/mutants/tautological-concurrency
```

### Upgrade 7 — Coverage matrix (P2)

**What.** Declare the target's subsystems and scope decisions UPFRONT in a coverage matrix: each subsystem marked in-scope / descoped, and for descoped items, which oracle row will (predictably) be red. Holes become *predicted*, not *discovered* at end-of-build.

**Proven by.** Both emulator arms shipped the same single failure — the descoped DIV/TIMA/TMA/TAC timer subsystem — and test 02-interrupts failed with NO local signal during build. superx-arm predicted it (descoped in the wave plan); raw-arm discovered it only at the single end-of-build oracle run. A coverage matrix turns "surprise red at the end" into "expected red, flagged on day zero."

**Integration.**
- `agents/architect.md`: every plan for a multi-subsystem target emits a coverage matrix; descoped rows map to expected-red oracle rows in the flagship status table.
- Flagship status table (deliverable 3): descoped subsystems render as a documented ❌ with a "descoped" annotation, not an unexplained failure.

**Runnable acceptance criterion.**
```bash
# the emulator coverage matrix exists and marks the timer subsystem descoped
test -f evals/oracles/emulator-gb/COVERAGE.md
grep -qi 'timer' evals/oracles/emulator-gb/COVERAGE.md
grep -qi 'descoped' evals/oracles/emulator-gb/COVERAGE.md
```

---

## What we are NOT building (and why)

The spike disproved the part of our thesis that would have justified this machinery. We are explicitly NOT building it.

| Not building | Why the evidence kills it |
|---|---|
| **Context-decay detection / long-run drift monitors** | "Silent bugs accumulate across long autonomous runs" did NOT reproduce. Opus built 512 byte-exact opcodes and a clean matching engine in one pass. There is no decay to detect on these targets. Building drift monitors would be solving a problem the evidence says we don't have. |
| **Per-token / per-turn correctness scoring** | Correctness never slipped at the instruction level (0 of 1.26M trace lines diverged in emulator test 01). Sampling correctness mid-run buys nothing the end oracle doesn't already give for free. |
| **"superx writes better code than raw CC" marketing** | False per the evidence. Raw and superx produced ~equivalently correct code. We claim VERIFICATION superiority only. |
| **Multi-model ensembling for generation** | The variable that mattered was process, not model — opus held constant across all arms. No generation-side ensembling is justified by this data. |
| **Heavy invariant-ledger tooling as a standalone product** | The ledger helps but has no teeth alone (it did not catch the exchange race). It is a cheap supporting artifact, not a headline feature. Do not over-engineer it. |

If future evidence on *different* targets (long-horizon, weakly-specified, or multi-day tasks) reproduces decay, revisit. Until then, this stays out.

---

## Integration summary (how it all lands in existing heimdall)

| Component | Change |
|---|---|
| `evals/oracles/registry.json` (new) | domain → oracle definition; single source consumed by both the wave gates and `bin/benchmark` |
| `bin/oracle-select` (new) | resolve a domain to its gate command + type |
| `bin/falsify` (new) | mutation-test a gate; assert falsifiability score |
| `agents/architect.md` / `agents/planner.md` | oracle selection + gate-type ranking + ledger emission + coverage matrix become required plan fields; plan-verification rejects property-only gates for stateful targets and non-falsifiable gates |
| `agents/heimdall.md` | Phase 3 auto-wires the registry oracle; Phase 4 enforces falsifiability + gate-type rules; Phase 5 spawns independent reference in a separate wave |
| `agents/verifier.md` | runs the wired oracle as the task's Verify step; requires `bin/falsify` score 1.0 before scoring a P0 gate PASS |
| `bin/benchmark` | flagship suite reads the same registry — one build, two uses |
| Hooks (`hooks/hooks.json`) | `bin/falsify` is a candidate pre-push gate alongside `heimdall-state check-quality-gates`; a green suite over a non-falsifiable gate must not pass push |
| `evals/flagship/` (new) | the launch flagship suite + spike findings (deliverable 3) |

---

## Acceptance criteria for the whole system (runnable)

```bash
# 1. Oracle registry wired for both flagship domains
jq -e '.oracles["emulator-gb"] and .oracles["exchange-lob"]' evals/oracles/registry.json
# 2. Every flagship gate is falsifiable (passes golden + rejects every mutant fixture, score 1.0)
bin/falsify exchange-lob --assert-score 1.0 && bin/falsify emulator-gb --assert-score 1.0
# 2b. The tautological-concurrency mutant fixture exists and is rejected (false-green regression guard)
test -f evals/oracles/exchange-lob/fixtures/mutants/tautological-concurrency
bin/falsify exchange-lob --mutant tautological-concurrency 2>&1 | grep -q 'REJECTED: mutant survived'
# 3. Differential gate is first-class for the stateful target
bin/oracle-select exchange-lob | grep -q differential
# 4. Reference is independent — registry flag AND structural no-impl-coupling check
jq -e '.oracles["exchange-lob"].reference.independent == true' evals/oracles/registry.json
! grep -rqE 'import.*(engine|impl)' evals/oracles/exchange-lob/reference/
# 5. Invariant ledgers preserved
test -f evals/oracles/exchange-lob/INVARIANTS.md && test -f evals/oracles/emulator-gb/INVARIANTS.md
# 6. Seeded interleaving gate present
grep -q seed evals/oracles/exchange-lob/interleave.md
# 7. Coverage matrix predicts the timer hole
grep -qi descoped evals/oracles/emulator-gb/COVERAGE.md
# 8. Flagship suite + spike findings preserved
test -f evals/flagship/README.md && test -f evals/flagship/SPIKE-FINDINGS.md
```

---

## OUT OF SCOPE

- Implementing the oracle harnesses, `bin/oracle-select`, `bin/falsify`, or any agent-file edits — that is the **plan's** job (`docs/superpowers/plans/2026-06-11-oracle-gate-plan.md`), a later wave. This spec is design only.
- Context-decay / long-run drift machinery (explicitly killed above).
- Ray-tracer as a launch flagship target — it is a CALIBRATION row only (raw CC also passes it), kept to make the table honest, not to demonstrate the delta.
- New domains beyond emulator + exchange in the launch registry. Additional oracle domains are follow-on cycles.
- Performance tuning of the oracle harnesses beyond "runs in CI within the existing benchmark time envelope."
- Modifying `bin/benchmark`'s measurement mechanics (token/wall/cost capture) — the flagship reuses them as-is.
- Multi-model ensembling, per-turn scoring, deployment/rollout of the eval suite to external users.
