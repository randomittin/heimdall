# team-copilot — INVARIANTS (the REDUM TEAM-LENS arm)

The unified `team-copilot` differential oracle proves the team co-piloting read-model. This
file specifies the **redum team-lens** invariants — the code∪work BRIDGE that folds OTHER
teammates' live claims + shared checkpoints into F3 Redum's reuse surfacing. The independent
reference (`reference.py`) reproduces every rule below from scratch; the impl under test is
`bin/lib/redum.py`'s team lens (`factor_for_task(team_lens=True)` + `gate_attestation(team_lens=True)`).

> Other co-piloting tracks (triage claim-gating, ponytail debloat) contribute their own cases to
> the SAME unified domain; this file is the redum-lens section. Entries here are additive — a
> parallel agent's invariants for another track coexist.

## The comparable partition (RT-PART)

The differential unit is the **team-candidate roster**: a sorted list of rows

    [surface, haid, human, class, adoptable]

`class ∈ {teammate-in-flight, adoptable-dropped, completed}`. The gate folds an identical seeded
teammate work-state stream through the REAL redum lens (over a real on-disk claim+checkpoint
ledger) AND the reference, normalizes both to this partition, and asserts they are identical
across all seeds. A per-record property check ("each surfaced candidate is a valid claim") passes
a whole-aggregate bug; the whole-partition differential catches it — hence `gate_type: differential`.

## The read-model (one model, two guarantees — the code∪work bridge)

ONE read of "what are my teammates working on" powers BOTH:

- **duplicate-effort PREVENTION** — a surface under a teammate's ACTIVE claim is surfaced as a
  reuse candidate: *coordinate/reuse, do NOT reinvent*.
- **dropped-work RECOVERY** — a surface in a teammate's SHARED checkpoint whose claim has DROPPED
  (TTL-reaped) but whose checkpoint SURVIVES (git-committed, redundant) is surfaced as adoptable:
  *adopt/resume, do NOT redo*. This ties the reap→adopt path of shared-checkpoints into redum.

## Invariants

- **RT-ISO (team isolation — the keystone).** The lens reads ONLY the resolved planning dir
  (`HEIMDALL_PLANNING_DIR`, else `<git-root>/.planning`) via `checkpoint_share`. A DIFFERENT
  team's ledger is a DIFFERENT dir and is NEVER read. A cross-team surface MUST NOT appear in the
  roster. `rr-multitenant-isolation` MUST stay 1.0.
- **RT-CLASS (classification — both bridge halves).** For a relevant teammate surface:
  checkpoint completed (`progress_pct>=100` or a done/merged/complete/shipped/landed phase) →
  `completed`; else an ACTIVE (non-TTL-expired) claim → `teammate-in-flight`; else a surviving
  checkpoint with a dropped claim → `adoptable-dropped` (`adoptable=true`). A claim is ACTIVE
  while `now < heartbeat + ttl_minutes` (the heimdall-claim rule).
- **RT-DROP (no dropped/duplicated teammate).** Every relevant teammate surface appears exactly
  once, keyed by (surface, haid). A whole missing/duplicated row is a divergence.
- **RT-LEAK (no content leak).** A candidate row carries ONLY scrubbed roster fields
  (surface/haid/human/class/adoptable) — NEVER a teammate's free-form `active_goal`/`task_ref`
  prose. The lens builds its own advice string from handle+surface, never from teammate prose.
- **RT-GHOST (no ghost surfaces).** A TTL-expired claim with NO surviving checkpoint is gone —
  nothing to reuse or adopt — and MUST be skipped.
- **RT-REL (task relevance).** A teammate surface is surfaced only when the task names its symbol
  or a distinctive path segment (token length ≥ 3). Exercised by the unit test; the differential
  makes every generated surface relevant so it isolates the classification aggregate.

## The WARN-vs-BLOCK boundary (commit gate)

`gate_attestation`'s team signal is **WARN-ONLY**: a teammate's parallel work is a P3 collision,
not a same-thing-MADE redum duplicate. It is emitted AFTER the verdict is fixed and is always
`level: "warn"` — it can NEVER escalate the verdict and NEVER blocks (never exit-3). The LOCAL
same-repo residual-duplicate gate is UNCHANGED: a genuine repo-internal duplicate still produces
`verdict: "block"` under `policy=block` (the hard gate, preserved). Solo path (team lens OFF) is
byte-identical to before: no `team_candidates` / `team_signals` keys.

## Independence

`reference.py` imports NOTHING from `bin/lib/*` — every rule above is hand-reproduced. Enforced by
`! grep -Eq 'import redum|import checkpoint_share' reference.py`. `differential.py` (neutral wiring)
imports BOTH the impl and the reference and diffs them.
