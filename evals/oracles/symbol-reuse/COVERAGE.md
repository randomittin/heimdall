# symbol-reuse — Coverage Map

How the `symbol-reuse` differential oracle exercises each invariant in `INVARIANTS.md`, and what
each mutant proves. The gate is `differential`: impl (`redum.detect_symbol_reuse`, via synthesized
source) vs an independent reference fold, diffed on the blocked/advised/ok partition.

## Golden (`fixtures/golden/differential.json`)

Seed 1, 24 records, cycling the eight class templates so a SINGLE golden exercises every bucket:

| Class template        | Invariant | Bucket   |
|-----------------------|-----------|----------|
| `exact-function`      | SR-C      | blocked  |
| `exact-type`          | SR-D      | blocked  |
| `structural-type`     | SR-E      | advised  |
| `same-name-function`  | SR-F      | advised  |
| `const-redef`         | SR-G      | advised  |
| `unique`              | SR-H      | ok       |
| `optout-dup`          | SR-B      | ok       |
| `ignored-dup`         | SR-A      | dropped  |

The seeded sweep (`gate.sh --differential --seeds 200`, the registered `gate_command`) repeats
this over 200 seeds — same seed ⇒ byte-identical stream; impl and reference MUST agree on every
one. A false-RED on golden means the gate rejects its own correct output.

## Mutants (`fixtures/mutants/`) — each MUST turn the gate RED (killed)

| Mutant                  | Invariant | Defect injected                                                        |
|-------------------------|-----------|------------------------------------------------------------------------|
| `miss-exact-dup`        | SR-D      | exact type re-declaration served as `ok` instead of blocked            |
| `false-flag-unique`     | SR-H      | genuinely unique symbol wrongly flagged as an exact-function block      |
| `ignore-optout-broken`  | SR-B      | opt-out-marked deliberate copy hard-blocked instead of allowed          |
| `cross-file-dup-missed` | SR-C      | cross-file exact function dup missed (file-local index) → served as `ok`|

Each mutant is a self-contained `{stream, corrupted}` fixture: the gate recomputes the CORRECT
partition from the stream via the INDEPENDENT reference and diffs it against `corrupted`. A genuine
defect diverges → `status=fail` → KILLED. Run:

    bin/falsify symbol-reuse --assert-score 1.0

Expected: golden GREEN, 4/4 mutants KILLED, score 1.0000.

## What is NOT covered here (by design)

- **Edit-distance near-naming (SR-F near half).** The differential exercises SR-F via the
  deterministic same-name/different-signature axis. Levenshtein near-naming is covered by the
  detector's own unit suite (`test/redum-symbol-reuse.test.sh`), not the differential — the
  reference deliberately avoids re-implementing the edit-distance algorithm so it stays a genuinely
  independent, spec-only recompute.
- **The reuse percentage.** SI-2 owns the S-6 reuse metric; this oracle proves the classification
  partition, not the measurement.
- **Team-mode overlap.** redum's team lens (a teammate building the same surface) is proven by
  `test/redum-team-lens.test.sh` and the `team-checkpoint` oracle; this domain is code∪code only.

## Falsifiability integrity

- The reference imports NOTHING from `bin/lib/*` (independence): scan import lines only —
  `grep -nE '^(import|from)[[:space:]]' reference.py | grep -E 'redum|dedup|reuse_analyzer|bin/lib'`
  is empty.
- `differential.py` is the single source of diff-truth; `run.sh` and `gate.sh` are thin wrappers
  and `bin/falsify` orchestrates `run.sh` via the typed `report.json` seam (REPORT-CONTRACT.md).
