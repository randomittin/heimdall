# INVARIANTS — Anonymized Issue Collection (`issue-collection` oracle domain)

**Authored:** 2026-07-09 (Wave 0, BEFORE any code) · **Governs:** the `issue_v1`
emit/ingest/aggregate/synth pipeline and its falsifier belt.

This is the **invariant ledger**. Each invariant is a *checkable statement* mapped
to a **named falsifier** — the RED-without-fix test that must fail if the invariant
is violated. The ledger is written before the implementation so the falsifiers
grade the design, not the other way round. Every downstream wave-1/2/3 task lists
this file under "Read first".

The issue path is an **additive sibling** of the pre-merge corpus (`pmr_corpus.py`,
`cp_corpus*.py`). It **reuses those privacy primitives by import, never by copy**:
`enabled` / `assert_zero_content` / `secret_scan_payload` / `team_id_hash` /
`repo_class_hash` / `corpus_home` / `_alarm` / `_h`. The #4 telemetry gate and the
#10 corpus gate stay **byte-for-byte green** — we add files, we do not edit the
gated modules.

---

## RJ's approved decisions (baked in — these govern where they differ from the plan)

1. **Signal fields.** Each issue carries only a **hashed error-signature** plus
   **coarse coded fields** (hmd version, OS class, failing-gate name, phase,
   command, coded severity) — **NO raw stack, NO code, NO paths, NO PII**.
   Additionally, k-anon is applied to the **signature bucket itself**: a rare
   error-signature is **suppressed until ≥ k distinct teams** have hit it, so a
   rare hash cannot re-identify a team before the threshold.
2. **Disposition — SHADOW-first.** Collected issues become `pending_review`
   candidates a maintainer promotes. This build does **NOT** auto-open GitHub
   issues.
3. **k-anon threshold.** **k ≥ 10** for the non-sensitive class (the corpus uses
   k ≥ 20; issues are rarer, so `ISSUE_K_ANONYMITY_MIN = 10`). The
   **security-sensitive lane is ALWAYS private regardless of k** — it never enters
   any public aggregate or synth candidate set, at any team count.

---

## Invariants

### INV-A — Zero-content signal (coded/hashed/bounded leaves only)
**Statement.** Every leaf of an `issue_v1` record is a coded token, a
non-reversible hash, a bounded coded enum, a boolean, or a number. It carries **no
filesystem path, no source line, no free text, no raw error message, no PII**. The
raw error text is reduced to a normalized `signature_hash` (domain-separated
sha256) before projection; the raw string is never stored or sent.
**Enforced by.** `pmr_corpus.assert_zero_content` on the projected record + the
closed-schema `rebuild_issue` (reads only pinned keys, DROPS unknown keys, re-runs
the guard). A planted path / source line / multi-word value → BLOCK + ALARM, never
spooled.
**Falsifier — `anonymization`.** Plant a path (`/etc/passwd:42 boom`) or source
line into an emitted event → the guard must BLOCK it. If the record lands in the
outbox → **RED**.

### INV-B — k-anon signature-bucket suppression (k ≥ 10 distinct teams)
**Statement.** A published/queryable aggregate bucket — keyed by
`(error_class, signature_hash, hmd_version, os_class, command|phase)` — is served
**only when ≥ `ISSUE_K_ANONYMITY_MIN` (= 10) distinct `team_id_hash`** have
contributed to it. A sub-threshold bucket (including a **rare error-signature seen
by fewer than 10 distinct teams**) emits a `{suppressed:true, reason:"k_anonymity",
teams:n}` marker and **never** the underlying metrics. This is stricter than the
corpus default of 20 only in *number* — the corpus's k ≥ 20 remains the reference;
issues use 10 because they are rarer and a 20-floor would starve the feed.
**Enforced by.** `issue_corpus.suppress_if_rare` / `meets_k_anon` (the primitive,
defined once in the local lib and imported by the aggregate). Distinct-team count,
never row count.
**Falsifier — `k-anon`.** A signature bucket backed by < 10 distinct teams that
surfaces real rates in the published aggregate → **RED**. The rare-signature case
(one team, one hash) must suppress.

### INV-C — Server-derived attribution (`team_id_hash` is never a body field)
**Statement.** The `team_id_hash` an issue is stored under is **server-derived at
ingest** from the authenticated HAID (`cp_auth.registered_team`), **never** read
from the request body. A client cannot attribute its issue to another team by
setting a body field; the server overwrites any client-supplied value.
**Enforced by.** `cp_issue_ingest` overwrites `team_id_hash` with the server handle
after `rebuild_issue` (which carries the client value only as a placeholder). No
registered team → **403 fail-closed** (no write).
**Falsifier — `isolation` / `signed-ingest`.** A push that sets `team_id_hash` in
the body and lands under that forged key, or a no-team push that stores a record →
**RED**. (Wave-2/3/4; ledgered here.)

### INV-D — Consent OFF ⇒ zero collection (no cron/hook can leak around it)
**Statement.** With consent OFF (`HEIMDALL_TELEMETRY=off|0|false|no|disabled` or
persisted `enabled=false`), `emit_issue` is a **pure no-op** — zero bytes written
to any outbox or private lane — **and** `corpus_send_enabled()` is False, so the
flusher sends nothing and any scheduled aggregate reads an **empty store**. A cron
or git-hook therefore **cannot leak around the OFF switch**: there is nothing in the
store to aggregate.
**Enforced by.** `pmr_corpus.enabled(home)` guards `emit_issue` before any
projection; the same master switch governs send (there is no separate issue
opt-out).
**Falsifier — `consent-off`.** With telemetry OFF, an emit that writes any byte
(outbox, private lane, or spool) → **RED**. Emit must return `{"emitted": false,
"reason": "disabled"}` and touch nothing.

### INV-E — Unsigned / forged ingest ⇒ 401 fail-closed
**Statement.** The `POST /issues` route is served **signed + gated** on the public
surface exactly like `/corpus`. An unsigned, forged, or revoked push is rejected at
the `cp_auth` chokepoint **before** the route body runs (**401**), storing nothing.
**Enforced by.** The shared `cp_auth` / public-surface chokepoint; `cp_issue_ingest`
never trusts an unauthenticated caller.
**Falsifier — `signed-ingest`.** An unsigned/forged push that stores a record →
**RED** (fail-closed). (Wave-2/3/4; ledgered here.)

### INV-F — Security-sensitive signal ⇒ private lane, excluded from public + synth
**Statement.** A signal classified **security-sensitive** — a secret shape found in
the raw event, an `error_class ∈ {auth, crypto, secret, injection, deanon,
isolation, incident}`, or an explicit incident marker — is routed to the **private
`.planning/security-signals/` lane** (git-committed, human-triaged locally). It is
**NEVER** written to the send outbox, **NEVER** enters the public aggregate, and
**NEVER** becomes a synth candidate — **regardless of k / team count**. The private
record is itself zero-content (coded/hashed projection; the raw secret is never
persisted — only its normalized `signature_hash`).
**Enforced by.** `issue_corpus.classify_security_sensitive` at emit time routes to
`security_signals_dir(...)` and returns before the outbox write; the ingest boundary
drops any `security_sensitive:true` record fail-closed; the aggregate + synth
exclude `security_sensitive` buckets entirely.
**Falsifier — `security-routing`.** A `security_sensitive` signal that reaches the
send outbox, the public aggregate, or a synth candidate → **RED**.

### INV-G — Store-namespace isolation (issue keyspace disjoint from control-plane)
**Statement.** The issue store lands under `issues/<team_hash>/issues.ndjson`
**inside `pmr_corpus.corpus_namespace()`** — a keyspace **disjoint** from the
control-plane presence/ops/team store, and per-team-partitioned so team B cannot
read team A's issues. The `rr-multitenant-isolation` keystone stays **1.0**.
**Enforced by.** `cp_state.get_backend(namespace=corpus_namespace())` +
per-`team_hash` partition; no cross-namespace read path.
**Falsifier — `isolation`.** A cross-team or cross-namespace read of another team's
`/issues` partition → **RED** (rr keystone drops below 1.0). (Wave-2/3/4; ledgered
here.)

---

## Wave-1 falsifiers (this build — RED-without-fix, then GREEN)

The local emit lib (`bin/lib/issue_corpus.py`) ships these four falsifiers as
RED-before-impl checks (`test/heimdall-issue-corpus-emit.test.sh`), each mapped to
an invariant above:

| Falsifier | Invariant | RED-without-fix condition |
|---|---|---|
| `consent-off` | INV-D | telemetry OFF yet emit writes a byte / returns `emitted:true` |
| `leaked-content` | INV-A | a planted path/source line lands in the outbox instead of BLOCK |
| `security-routing` | INV-F | a security signal reaches the outbox instead of the private lane |
| `rare-signature` | INV-B | a signature bucket seen by < 10 distinct teams is not suppressed |

The remaining invariants (INV-C server-attribution, INV-E signed-ingest, INV-G
namespace isolation) are ledgered here and exercised by the full differential gate +
belt in Wave 4 (`bin/falsify issue-collection --assert-score 1.0`) — out of scope
for this build, encoded now so they render as *expected-red* until their wave lands.
