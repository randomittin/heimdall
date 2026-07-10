# team-checkpoint — Coverage Matrix

How each invariant in `INVARIANTS.md` is proven, and by what artifact. The gate is
`differential`: the published roster is diffed against an INDEPENDENTLY-authored reference
fold (`reference.py`, no `bin/lib/*` import) over identical seeded per-HAID inputs.

| Invariant | Proven by | Falsifier (mutant / assertion that goes RED) |
|---|---|---|
| INV-A no-free-form-body | `differential.py` fold diff + belt | `path-leak` mutant: an absolute path / newline-diff in a field; reference redacts, corrupted serves it → RED |
| INV-B no-secret-leak | belt (write aborts) + `no-secret-leak` mutant | plant a `ghp_…` PAT in goal text → write aborts, served omits it; corrupted serves it → RED |
| INV-C security-lane-never-shared | `security-lane-leak` mutant + `.gitignore` grep | a security-class record served / `excluded_security` dropped → RED; grep proves no `security-signals/` re-include |
| INV-D consent-off-shares-nothing | `consent-off` mutant + belt zero-byte check | a consent-off record in the served roster → RED; belt asserts zero bytes under `presence.json {"enabled":false}` |
| INV-E conflict-free-merge | belt two-HAID concurrent-publish | two branches each add a distinct `{slug}.json`; `git merge` clean, no conflict marker |
| INV-F team-isolation-holds | keystone re-run | `bin/falsify rr-multitenant-isolation --assert-score 1.0` stays 1.0 |
| INV-G roster-differential | `differential.py` golden + `dropped-teammate` mutant | corrupted roster drops/duplicates/misattributes a teammate → RED |

Load-bearing redundancy behaviours (beyond the six privacy invariants), proven in the belt
`test/heimdall-checkpoint-share.test.sh`:

| Behaviour | Falsifier |
|---|---|
| no-rewrite / no-redo | an hmd `precheck` REFUSES a surface another teammate actively holds (claim) or completed (checkpoint) → nonzero exit naming the holder |
| redundancy-handoff | a dropped teammate's `checkpoints/{slug}.json` is adopted: `resume` reaps the expired claim, re-claims the surfaces, prints the adopted goal/phase/HEAD, notes `decisions.md` |

## Falsifiability harness

    bin/oracle-select team-checkpoint          # resolves the gate command
    bin/falsify team-checkpoint --assert-score 1.0   # golden GREEN + every mutant KILLED
    evals/oracles/rr-multitenant-isolation/run.sh    # keystone stays 1.0

A P0 gate requires score 1.0: the golden passes AND every injected mutant is REJECTED. A
mutant that SURVIVES (gate stays green) proves the fold is blind to that defect class and
BLOCKS the build.

## Transport coverage — CP live-pointer is DESCOPED from Wave 1

Git is the source of truth for the durable, reviewable, redundant checkpoint record; it needs
zero new infra and satisfies every acceptance criterion above. The control-plane live-pointer
(a content-free HEAD+phase+% ref folded onto the existing signed presence beat) is DESCOPED
from Wave 1 — it is a pure liveness ergonomic that reuses presence's signed/consent/INV-1
machinery untouched, toggle-off by default, and adds NO team-safe content dependency on the
server being up. The pointer module (`bin/lib/checkpoint_pointer.py`) is content-free by
construction (HEAD sha + phase + coarse %). No new CP `/checkpoint` ingest surface is added.

## Independence (differential integrity)

`reference.py` imports NOTHING from `bin/lib/*` — every constant (the security taxonomy, the
secret shapes, the allowlist, the byte cap) is hand-reproduced from `INVARIANTS.md`, enforced
by an acceptance grep (`! grep -q 'checkpoint_share' reference.py`). The impl author and the
reference author are disjoint; `differential.py` (the neutral gate wiring) is authored by
neither and imports both, so oracle independence holds by construction.
