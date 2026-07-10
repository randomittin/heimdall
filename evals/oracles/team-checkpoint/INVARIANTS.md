# team-checkpoint — Invariant Ledger

**Domain:** `team-checkpoint` · **gate_type:** `differential` · **Status:** authored BEFORE code (Wave 0 artifact)
**Feature:** Shared Team Checkpoints (TEAM MODE P4) — `docs/superpowers/plans/2026-07-10-shared-team-checkpoints.md`

This ledger pins the falsifiable invariants of the shared-checkpoint store + its roster
fold. It is the SINGLE source of truth the independent differential reference
(`reference.py`) is authored from — the reference imports NOTHING from `bin/lib/*`; every
constant and rule below is hand-reproduced there, so the reference shares no code path with
the implementation under test (`bin/lib/checkpoint_share.py`). Re-read this before touching
the engine, the CLI, the reference, or the gate.

---

## 0. What a shared checkpoint IS

A teammate's session publishes ONE git-committed, per-HAID record at
`.planning/ledger/checkpoints/{haid-slug}.json` — the additive P4 sibling of the P1
activity / P2 verdicts / P3 collision stores. One writer per file → conflict-free git
merges. Every teammate holds the full `checkpoints/` dir after a `git pull`, so a dropped
teammate's last snapshot survives their machine loss with zero server dependency (the
redundancy property).

The record is an **allowlist** — a field not on the SHARED list is not shared, by
construction. It carries WHO is working on WHAT and HOW FAR, never the machine-local detail
that would leak a secret, a path, a seed, or a security incident.

---

## 1. The SHARED allowlist (team-safe fields)

| Field | Meaning | Guard |
|---|---|---|
| `haid` | public HAID name (already in `claims/`) | coded token |
| `human` | handle only | coded token |
| `branch` | git branch NAME only | coded token |
| `head_sha` | short HEAD commit ref (already public in the repo) | coded token |
| `phase` | STATE.md phase, e.g. `wave-2/build` | coded token (a single `/` allowed) |
| `progress_pct` | integer 0–100, coarse | int, clamped |
| `active_goal` | SCRUBBED goal condition text (prose allowed) | goal-safe scrub |
| `claimed_surfaces` | mirror of `claims/{slug}.json` globs (already public) | relative-glob only |
| `task_ref` | high-level task label (prose allowed) | goal-safe scrub |
| `updated_at` | UTC ISO-8601 timestamp | coded token |
| `resumable` | bool: is there enough here to hand off | bool |

## 2. The LOCAL-ONLY set (NEVER shared — no allowlist entry ⇒ dropped)

- Absolute machine paths (`/Users/...`, `/home/...`, `~/...`, `C:\...`) → rewritten
  repo-relative or replaced with `[path-redacted]`.
- Per-machine haid **seed** / Ed25519 private key (`*.seed`) — never read by the builder.
- Raw team secret (`team.json`) — never read by the builder.
- **Uncommitted diff CONTENT** (the CHECKPOINT.md "Uncommitted changes" fenced block) —
  file NAMES may appear via `claimed_surfaces`; the diff BODY never. Enforced structurally
  (the builder never reads the diff body) AND by the no-free-form-body guard (§4 INV-A).
- Any env / credential store value.
- **The security-signals lane** (`.planning/security-signals/`) and any field whose value
  matches the security classifier (§5) — DROPPED, and (a genuine incident) routed local-only.

---

## 3. The load-bearing INVARIANTS (each a RED-without-fix falsifier)

### INV-A — no-free-form-body (zero-content discipline)
No leaf of the published record carries a free-form body/diff: no newline (a fenced diff
spans lines), no value over the byte cap, no absolute machine path. Prose goals and relative
surface globs are legitimate (unlike a PMR zero-content record), so this does NOT reject
multi-word text or a relative `/`; it rejects the leak SHAPES a checkpoint must never carry.
*Falsifier:* a record whose `active_goal` contains an embedded absolute path or a newline-
bearing diff → published record diverges from the reference (reference redacts/rejects it).

### INV-B — no-secret-leak (secret-scan fail-closed)
Every string field passes the secret gate (telemetry `_SECRET_PATTERNS` / `_ASSIGNED_OPAQUE`
+ gitleaks belt) BEFORE the record is written. A finding aborts the write (exit 1, NOTHING
written), exactly like `heimdall-context-capsule`. In the fold, a record carrying a secret is
NOT served (the reference drops it).
*Falsifier:* plant a PAT-shaped token (`ghp_…`) in goal text → the write aborts and the
served roster omits it; a corrupted impl that serves it diverges → RED.

### INV-C — security-lane-never-shared
A record classified security-sensitive (§5) NEVER enters the published roster, at any team
count; it is EXCLUDED and counted opaquely (`excluded_security`). The `.gitignore` carries NO
re-include for `.planning/security-signals/` (double-guarded: classifier drop + no re-include).
*Falsifier:* a goal/phase/task matching a security class → the served set omits it and
`excluded_security` increments; a corrupted impl that serves it (or drops the count) diverges → RED.

### INV-D — consent-off-shares-nothing
Consent OFF (`<repo>/.heimdall/presence.json {"enabled": false}` or global
`~/.heimdall/presence-off`) ⇒ the publish writes ZERO bytes to `checkpoints/` and folds to
nothing shared, a hard no-op a hook/cron cannot leak around (exit 0).
*Falsifier:* a consent-off record that nonetheless appears in the served roster diverges from
the reference (which honors consent-off by skipping) → RED.

### INV-E — conflict-free-merge
One file per HAID (`{slug}.json`) ⇒ two teammates publishing their own checkpoints never
touch the same path ⇒ a `git merge` of two divergent branches (each adding a distinct HAID
file) is clean, no conflict marker.
*Falsifier:* two HAIDs publish concurrently onto two branches; merging them MUST produce two
distinct files and zero conflict markers. A single shared blob would collide.

### INV-F — team-isolation-holds (the keystone, unchanged)
The private team repo IS the git boundary — a non-member has no checkout and sees nothing.
The CP live-pointer (descoped from Wave 1) rides the existing signed, team_id-scoped presence
beat (INV-1: server hashes the team secret to `team_id`; the client never asserts it). The
pre-existing `rr-multitenant-isolation` keystone MUST stay score 1.0.
*Falsifier:* a cross-team read of another `team_id`'s pointer is DENIED — `bin/falsify
rr-multitenant-isolation --assert-score 1.0` stays 1.0.

### INV-G — roster-differential (the whole-aggregate proof)
The published roster equals an INDEPENDENT recompute over the per-HAID records: for every
seeded fixture the impl fold and the reference fold agree on the served bucket set (keyed by
HAID) AND the `excluded_security` count. A per-record property check passes a whole-aggregate
bug (a dropped / duplicated / misattributed teammate); the differential recompute catches
that class. This is why `gate_type` is `differential`, not `property`.
*Falsifier:* a corrupted roster that drops, duplicates, or misattributes a teammate row
diverges from the reference fold → RED.

---

## 4. Redundancy & handoff (tied to the ledger claims)

- **No-rewrite / no-redo (R1 extended cross-teammate).** Before an hmd starts work on a
  surface it reads teammates' shared checkpoints + active claims and REFUSES to rewrite/redo
  a surface another teammate ACTIVELY holds (claim) or recently COMPLETED (their checkpoint
  at progress 100 / a done phase covering that surface). A collision → block + name the
  holder. This extends the `heimdall-claim` no-stomp guarantee across shared state.
- **Redundancy handoff.** A dropped teammate's claim TTL-expires (`heimdall-claim reap`).
  Another instance reads their last `checkpoints/{slug}.json`, adopts goal/phase/HEAD, re-
  claims the freed surfaces under its own HAID, and appends an `A → B resumed` note to
  `decisions.md`. Refuse to stomp a LIVE teammate (claim still active) unless `--force`.

---

## 5. The security classifier (reused taxonomy)

A field is security-sensitive when its value matches the class set (hand-copied from
`issue_corpus._SECURITY_CLASSES`, the approved taxonomy):

    auth · crypto · secret · injection · deanon · isolation · incident

Matching goal/phase/task text → the field is DROPPED; a genuine incident routes to the
local-only `.planning/security-signals/` lane (never re-included in `.gitignore`).

---

## 6. Boundary mechanism (reuse, don't rebuild)

1. **Allowlist assembly** — the builder emits only the SHARED keys (§1).
2. **Path strip** — absolute paths rewritten repo-relative; anything still absolute →
   `[path-redacted]`.
3. **`telemetry._scrub` / `_SECRET_PATTERNS` / `_ASSIGNED_OPAQUE`** — every string field
   passes the no-secret-by-construction gate.
4. **`assert_zero_content`** (checkpoint-tuned no-free-form-body guard, §3 INV-A).
5. **Security classifier** (§5) — drop/route matching fields.
6. **`bin/secret-scan` (gitleaks) FAIL-CLOSED** — the assembled record is scanned before
   write; a finding aborts the write (exit 1, nothing written).

The differential reference reproduces steps 1–5 independently (step 6 is an environmental
belt) so the roster fold is proven equal to a spec-only recompute.
