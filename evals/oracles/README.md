# Oracle Registry

`registry.json` is the catalog of **oracles** — independent correctness checks that gate generated work for high-stakes domains. An oracle answers "is this implementation actually correct?" using a reference the implementing agent never sees, instead of trusting the implementer's own tests.

The planner reads this registry to auto-select an oracle for an incoming task (see [Planner auto-selection](#planner-domain_signals-auto-selection)). Each selected oracle exposes a single `gate_command` that the gate harness runs to produce a pass/fail verdict.

## Top-level schema

| Field | Type | Meaning |
|-------|------|---------|
| `version` | string | Semver of the registry schema. Bump on any breaking field change. |
| `gate_type_ranking` | string[] | Gate types ordered **strongest → weakest**. Used to break ties when more than one oracle matches a task: prefer the entry whose `gate_type` ranks earliest. |
| `oracles` | object | Map of oracle id → oracle entry. The id (key) is the stable handle used by the planner and gate harness. |

### `gate_type_ranking`

```
differential  >  trace-diff  >  verdict  >  property  >  example
```

Stronger gates catch more classes of bug with fewer false passes. When a task's `domain_signals` match multiple oracles, the planner picks the match with the strongest gate type.

## Per-oracle entry schema

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `gate_type` | enum | yes | One of `gate_type_ranking`. Defines the verification strategy (see [Gate-type semantics](#gate-type-semantics)). |
| `description` | string | yes | Human-readable summary of what the oracle verifies and how. |
| `domain_signals` | string[] | yes | Tokens / glob patterns / phrases that, when present in a task prompt or its file set, mark this oracle as a candidate. Drives auto-selection. |
| `assets` | object[] | yes | Reference material the gate depends on. Each asset has `name`, `kind`, `purpose`, and a locator (`url` + `fetch` for external, or `dir` for in-repo). External datasets are **pointers only** — raw ROM/image/log bytes are never copied into this repo. |
| `gate_command` | string | yes | The exact command the harness runs to gate an implementation. Always points at the oracle's `gate.sh` harness (built in Wave 2), never a generic runner. May carry flags (e.g. `--differential`, `--seeds`, `--ssim-threshold`). |
| `reference` | object | yes | Provenance of the truth source. `independent` (bool) must be `true` — the reference must not share code or authorship path with the implementation under test. `kind` describes its origin (`external-dataset`, `separate-agent`, …). Optional `dir` points at an in-repo reference. |
| `calibration_only` | bool | no | When `true`, the oracle is used to calibrate/validate the gate harness itself, **not** to gate shipped work. Defaults to absent (false). |

### `assets[]` locator conventions

| `kind` | Locator | Notes |
|--------|---------|-------|
| `external-dataset` | `url` + `fetch` | Cloned/fetched on demand. Never vendored. |
| `separate-agent` | `dir` | Independently authored reference implementation living in-repo. |
| `in-repo-dataset` | `dir` | Deterministic fixtures / golden artifacts committed in-repo. |

## Gate-type semantics

- **differential** — Run the same inputs through the implementation **and** an independent reference implementation; the gate passes only if every observable output (results, state, event stream) matches across all inputs/seeds. Strongest: any divergence is a failure. Example: `exchange-lob` replays seeded order flow through both the optimized engine and a naive O(n²) matcher.
- **trace-diff** — Compare the implementation's emitted execution trace line-for-line against a known-correct reference trace. Catches divergence at the step where it first occurs. Example: `emulator-gb` diffs per-instruction CPU state against gameboy-doctor truth logs and asserts Blargg pass markers.
- **verdict** — Score the implementation's output against a reference using a metric + threshold, yielding a single pass/fail verdict. Tolerates bounded, non-exact differences (e.g. scoring a render against a golden image via SSIM ≥ 0.99). **No oracle currently registers this type** — it stays in the ranking so a future metric-scored gate slots in at the right strength.
- **property** — Assert invariants/properties that any correct implementation must satisfy (e.g. conservation laws, idempotence, monotonicity) across generated inputs. No full reference output required.
- **example** — Assert against a fixed set of input→expected-output examples. Weakest: only covers the enumerated cases.

## Registered oracles

| id | gate_type | domain | reference kind |
|----|-----------|--------|----------------|
| `emulator-gb` | trace-diff | Game Boy / LR35902 emulation | external-dataset (Blargg ROMs + gameboy-doctor traces) |
| `exchange-lob` | differential | limit-order-book matching engine | separate-agent (independent O(n²) matcher) |
| `issue-collection` | differential | anonymized issue-collection k-anon aggregate | separate-agent (independent reference aggregator) |
| `ponytail-underdelivery` | example | write-time under-delivery guard (`roman(n)`) | in-repo-dataset (fixed 16-case acceptance table + 3 mutants) |
| `rr-multitenant-isolation` | example | multi-tenant cross-tenant denial | in-repo-dataset (fixed 25-case all-DENY table + 23 mutants) |
| `symbol-reuse` | differential | cross-project symbol reuse | separate-agent (independent reference fold) |
| `team-checkpoint` | differential | shared team-checkpoint roster | separate-agent (independent reference fold) |
| `team-copilot` | differential | team co-piloting (redum team lens) | separate-agent (independent reference fold) |
| `triage-coord` | differential | team issue-triage claim coordination | separate-agent (independent reference fold) |

This table is **gate-checked, not hand-maintained**: `bash test/oracle-registry-integrity.test.sh` fails if it drifts from `registry.json` (missing row, phantom row, or mismatched `gate_type`), and also fails if any entry's `gate_command` points at a path that does not exist.

## Planner `domain_signals` auto-selection

When a task arrives, the planner selects a gating oracle without manual configuration:

1. **Gather task text** — combine the task prompt with the names/extensions of its file set into a single haystack.
2. **Match signals** — for each oracle, test every entry in its `domain_signals` against the haystack. Glob patterns (`*.gb`) match file names; phrases (`price-time priority`) and tokens (`opcode`) match the prompt text (case-insensitive). An oracle is a **candidate** if any signal matches.
3. **Rank candidates** — if more than one oracle is a candidate, order them by `gate_type` position in `gate_type_ranking` (earliest = strongest) and pick the strongest. Break further ties by number of matched signals, then by id.
4. **Skip calibration-only** — oracles with `calibration_only: true` are never selected to gate shipped work; they only run when explicitly calibrating the harness.
5. **Gate** — run the chosen oracle's `gate_command`. Its exit status is the verdict the planner enforces before the work is accepted.

If no oracle matches, the task falls back to the standard (non-oracle) quality gates.
