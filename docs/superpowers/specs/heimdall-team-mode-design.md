# Heimdall Team Mode — STEP-0 Inventory + SI-3 Status + P1/P2/P3 Design Dossier

**Status:** READ-ONLY design. No code. The build is the **DELTA** over an already-built
coordination substrate. Authoritative spec: `/Users/rj/Downloads/heimdall-team-mode-FINAL-spec.md`.
Model: 8 devs, each running `hmd`, one shared repo. No server; git is the shared state.

---

## STEP 0 — Inventory (audited from the actual binaries, R7)

| Binary | What it does TODAY | What P1/P2/P3 NEEDS | The DELTA |
|---|---|---|---|
| `bin/heimdall-haid` | HAID identity `haid:{human}.{machine}-{hash4}[/role]` + registry `.planning/ledger/agents.json` `{human,role,tool,tool_version,first_seen,last_heartbeat,status}`. register/heartbeat/revoke/check. Git-tracked. | P1 dev-identity + per-instance heartbeat. | **Exists-as-needed.** Identity + heartbeat + TTL-derivation backbone already there. Zero change. |
| `bin/heimdall-ledger` (+ `-mcp`) | TOKEN ledger only — `ledger.jsonl` per-role token cost + baselines/delta. NOT a coordination ledger. | P1 coordination RECORD (task+files+agents). P2 gate verdicts. | **Needs-delta (naming trap).** This is the token-frugal ledger, NOT the coordination record. The coordination record is the **claims dir** + a NEW per-dev `activity` record. Do not overload this binary. |
| `bin/heimdall-claim` | File/dir/symbol CLAIMING. Per-instance file `claims/{haid-slug}.json` `{haid,human,claimed_surfaces[],task_ref,claimed_at,ttl_minutes,heartbeat}`. Overlap detection (file+symbol), TTL reap, collision exit 3. Git-tracked, one-writer-per-file. | P1 files-touched + overlap WARNING + TTL. | **Exists-as-needed (re-aimed).** Schema, overlap engine, TTL/reap, heartbeat ALL present. P1's overlap warning = `claim check` run informationally (no exit-3 block). Surfaces field = files/dirs touched. |
| `bin/heimdall-who` | Read-only view over `agents.json`: HAID, human, role, status, derived stale (>1800s). NEVER writes. | P1 `hmd who`/`hmd team` "who's-working-where". | **Needs-delta (extend view).** Folds identity+liveness today; header even forward-refs T-2 claim/commit counts. Extend to JOIN agents × claims × the new activity record → "Sarah → auth/ (login refactor), Raj → payments/ (3 agents)". |
| `bin/heimdall-state` | `heimdall-state.json` quality-gate + conflict-log host. Single-instance. | (none direct) | Exists; untouched by P1-P3. |
| `bin/shared-memory` | SQLite WAL local KV/locks/pubsub in `~/.heimdall/`. **Machine-local, NOT git-shared.** | (none — wrong substrate) | **Out of scope.** Cross-machine sharing must be git, not this. Do NOT route team state here. |
| `bin/conflict-log` | Logs skill-vs-skill conflicts into `heimdall-state.json`. Not branch collisions. | P3 wants conflict surface. | **Needs-delta (distinct concern).** This is skill conflicts, not code collisions. P3's collision log is a NEW git-tracked store (`ledger/collisions/`), not this. |
| `bin/parallelism-tracker` | C-compiled agent-spawn parallelism telemetry. | (none direct) | Exists; untouched. |
| `bin/heimdall-resolve` | SYMBOL-TABLE resolver (`F12→path`, plan-time compression). **NOT a merge resolver.** | P3 "extends heimdall-resolve". | **Needs-delta (naming trap).** Spec assumed this is a merge/collision resolver — it is NOT. P3's collision-resolver is effectively NEW, built on `heimdall-attest` contracts + a branch reader, not on this. |
| `bin/heimdall-attest` (SI-2) | Per-commit record `{claims,contracts,evidence,reuse,risk}` with REAL exit codes. Store `.heimdall/attestations/` (**gitignored**). | P2 gate verdicts/receipts. P3 contracts diff. | **Exists-as-needed as SOURCE; needs a PUBLISH delta.** Verdicts exist but in a gitignored store → P2 must REPUBLISH a secret-free verdict summary into the git-tracked ledger so siblings can read it. |

**Verdict:** the substrate is ~70% present. The two big traps are NAMING: `heimdall-ledger`
is tokens (not coordination) and `heimdall-resolve` is symbols (not merge). The real
coordination record is `claims/` + a NEW `activity/` record; the gate surface republishes
SI-2 out of its gitignored store.

---

## SI-3 STATUS — **PENDING (not built).**

No `bin/*` branch-context reader, no `lib/*branch*`, zero `own-branch`/`branch-context`
grep hits in the substrate (one stray in `heimdall-face-test`, unrelated). SI-1 (per-dev
context) and SI-2 (`heimdall-attest`) ARE built. **SI-3 is the substrate P3 (collision)
queries — it MUST be built before P3 and sequenced as P3's wave-0 dependency.** P1/P2 do
NOT read SI-3 (they run on `agents.json` + `claims/` + the activity record), so SI-3 can be
built in parallel with the P1/P2 waves and only gates P3.

---

## P1 RECORD SCHEMA (git-backed, gitleaks-clean — TM-1: branch topology IS the data)

New per-dev file `.planning/ledger/activity/{haid-slug}.json` (one-writer-per-file →
conflict-free git merge, same pattern as `claims/`). Identity+files+task ONLY — never code/secrets:

```json
{ "haid": "haid:sarah.mbp-7f3a", "human": "sarah", "active_task": "login refactor",
  "files_touched": ["auth/**", "auth/login.ts#handleLogin"], "agents_running": 3,
  "branch": "feat/auth-login", "heartbeat": "2026-06-24T10:40:00Z", "ttl_minutes": 30 }
```

Liveness reuses HAID heartbeat + claim TTL/reap verbatim. `files_touched` mirrors claim
surfaces, so overlap = existing `surfaces_overlap` engine run **informationally** (warn, never exit-3).

---

## DISJOINT FILE-SETS (parallel-safe)

- **P1** — `bin/heimdall-activity` (NEW publish/read of activity record + TTL reap) · extend
  `bin/heimdall-who` (add `team` view JOINing agents×claims×activity + overlap warning) ·
  `.planning/ledger/activity/` (NEW store, git-tracked) · `tests/team-mode/p1-*.bats`.
- **P2** — `bin/heimdall-gate-surface` (NEW: republish SI-2 verdict→git ledger, secret-free) ·
  `.planning/ledger/verdicts/{haid-slug}.json` (NEW store) · `bin/heimdall-who` GATES column
  (sequence AFTER P1's who-edit, same file → different wave) · `tests/team-mode/p2-*.bats`.
- **P3** — `bin/heimdall-branch-context` (NEW = SI-3, wave-0) · `bin/heimdall-collision`
  (NEW: same-target-CHANGED detect, reads SI-3 + attest contracts, surface>auto-merge) ·
  `.planning/ledger/collisions/` (NEW store) · `tests/team-mode/p3-*.bats`.

**Integration gate (all three):** a REAL two-`hmd` flow on one repo — instance A publishes
activity+verdict → instance B reads → B sees A's task/files/verdict → overlap warns →
(P3) planted same-target change on two branches detected+surfaced. Not unit-only.

---

## P2/P3 CONTRACT (priority order; P1 full above)

- **P2 Gate surface:** extends P1's record. `heimdall-gate-surface publish` reads the
  gitignored SI-2 attestation, extracts `{evidence exit codes, gate verdict, receipt id}`,
  scrubs through telemetry's `_scrub` discipline, writes a secret-free verdict to the
  git-tracked `verdicts/` store. `hmd team --gates` → "Sarah: PROVEN ✓ (12 gates) · Raj:
  BLOCKED ⛔ (secret-scan cards.ts:5)". Honest — real exit codes, no fabricated status.
- **P3 Collision-resolver (F4, same-target-CHANGED ≠ Redum same-thing-MADE):** wave-0 builds
  SI-3 (own-branch-first branch reader). `heimdall-collision` queries SI-3 + each branch's
  attestation `contracts` to find two branches changing the same function/file/symbol.
  SURFACE > auto-merge: resolve safe textual, FLAG risky semantic for human. Extends NOTHING
  named "resolve" (that's the symbol table) — built fresh on attest contracts + SI-3.

## P4 (DEFERRED — F6/TM-2+3, high-level only)
Multi-writer SI-1 checkpoint + crash/partial-state reconciliation. Team-mode-gated, solo
sacrosanct. Build AFTER P1-P3 ship to the 8 devs and telemetry shows real collide/crash data.

---

## OUT OF SCOPE
- `shared-memory` (machine-local SQLite) as a team substrate — git only.
- `heimdall-state`/`parallelism-tracker`/`conflict-log` behavior changes.
- P4 reconciliation implementation (deferred until usage data).
- Any non-git/server coordination. Any blocking gate in P1/P2 (informational only).
- Solo-path changes — solo/feature-off must be byte-identical to today.

---

## RISKS

| Risk | Prob | Impact | Mitigation | Owner |
|---|---|---|---|---|
| Naming trap: `heimdall-ledger`=tokens, `heimdall-resolve`=symbols mis-extended | high | high | NEW `activity`/`collision` binaries; never overload the misnamed pair | P1, P3 |
| SI-2 verdicts gitignored → siblings can't read | high | high | P2 republishes secret-free summary into git-tracked `verdicts/` | P2 |
| Secret leak into git-tracked record | low | high | reuse telemetry `_scrub` + gitleaks gate on every new store | P1, P2 |
| P3 built before SI-3 exists | med | high | sequence SI-3 as P3 wave-0 dependency | P3 |
| Coordination bug ships green (subtle) | med | high | REAL two-`hmd` integration gate, not unit-only | all |
