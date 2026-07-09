# PLAN — Anonymized Issue Collection (corpus/telemetry extension)

**Authored:** 2026-07-09 · **Architect:** hmd:architect · **Status:** DRAFT (pending plan-verification + RJ decisions on the open questions)

> RJ: "the capability to collect anonymised issues is a must — can be paired with Cloud Run and other scheduled features."

Teammates' Heimdall sessions surface bugs/errors/friction as **anonymized, opt-in issues** that flow to a Cloud Run collection point, get k-anon-gated + aggregated on a schedule, and feed the existing seeker/fixer → GitHub-issue → PR pipeline. Security-sensitive signals split off to a **private `.planning/` lane that never goes public**.

This is **NOT new surface**. It is an *additive sibling* of the pre-merge corpus (#10): every privacy primitive (zero-content guard, secret-scan, k-anon≥20, INV-1 server-derived attribution, isolated namespace, signed ingest, consent-off no-op) is **reused, not rebuilt**. The #4 telemetry gate and the #10 corpus gate must stay **byte-for-byte green** — we add files, we do not edit `pmr_corpus.py` / `cp_corpus.py` / `cp_corpus_aggregate.py` / `cp_corpus_synth.py`.

---

## 1. Architecture

### Data flow

```mermaid
flowchart TD
  subgraph SESSION["Teammate hmd session (local, client-side)"]
    EV[bug / error / friction event<br/>gate-fail, exception, retry-storm] --> PROJ[issue_corpus.project → issue_v1<br/>error_class + sig-HASH + hmd_ver + os_class + command/phase + coded severity]
    PROJ --> CLASS{security-sensitive?<br/>secret-finding / auth·crypto·isolation class / incident marker}
    CLASS -- yes --> PRIV[PRIVATE lane<br/>.planning/security-signals/ (git, NEVER public)<br/>excluded from public aggregate + synth]
    CLASS -- no --> ZC[assert_zero_content<br/>REUSE pmr_corpus guard]
    ZC --> SS[secret_scan_payload<br/>REUSE telemetry patterns + gitleaks]
    SS --> CONSENT{consent enabled?<br/>REUSE pmr_corpus.enabled}
    CONSENT -- off --> NOOP[pure no-op · ZERO write]
    CONSENT -- on --> SPOOL[local issue outbox spool]
  end

  SPOOL --> FLUSH[flusher: secret-scan belt →<br/>SIGNED POST /issues]
  FLUSH -->|Ed25519-signed, fail-closed| CP

  subgraph CP["Cloud Run control plane (heimdall-cp-public + gated)"]
    CP --> AUTH[cp_auth chokepoint<br/>unsigned/forged/revoked → 401]
    AUTH --> INV1[INV-1 server-derived team_id_hash<br/>NEVER a body field]
    INV1 --> REBUILD[issue_corpus.rebuild_issue<br/>closed-schema · drop unknown keys · re-scan secret]
    REBUILD --> STORE[(ISOLATED namespace<br/>heimdall_corpus/issues/&lt;team&gt;/issues.ndjson<br/>disjoint keyspace)]
    STORE --> AGG[[cron: cp_issue_aggregate<br/>allowlisted action-type]]
    AGG --> KANON{per-bucket<br/>k-anon ≥ 20 distinct teams?}
    KANON -- no --> SUPPRESS[suppression marker<br/>metrics NEVER emitted]
    KANON -- yes --> PUB[(published aggregate<br/>isolated namespace)]
    PUB --> SYNTH[[cron: cp_issue_synth<br/>cluster → candidate issues<br/>distinct-team support floor]]
  end

  SYNTH --> QUEUE[issue_queue source=corpus<br/>normalize → ONE internal schema]
  QUEUE --> LOOP[heimdall-issue-loop<br/>SI-1 orient → fix → GATE → SI-2 attest]
  LOOP --> GH[(GitHub issue / PR<br/>existing connector, bot token)]
  PRIV -. maintainer reads locally .-> LOCAL[human triage in .planning/<br/>NEVER auto-filed public]
```

### The seam: what REUSES vs what is NEW

| Concern | REUSED (byte-unchanged) | NEW (additive sibling) |
|---|---|---|
| Consent / opt-in / off-honored | `pmr_corpus.enabled` / `set_enabled` / `corpus_send_enabled` / `CONSENT_VERSION` | — (same master switch governs issues; no separate opt-out) |
| Zero-content guard | `pmr_corpus.assert_zero_content` / `_leaf_strings` / `_violates_zero_content` | applied to the new `issue_v1` schema |
| Secret-scan belt | `pmr_corpus.secret_scan_payload` / `scan_for_secrets` / gitleaks | client before-send + server boundary re-scan |
| Non-reversible attribution | `pmr_corpus.team_id_hash` / `repo_class_hash` / `_h` domain-sep | issue carries only these hashes + coded fields |
| Signed ingest + INV-1 | `cp_auth.registered_team` / `cp_server.register_route` / `cp_audit.write` | `cp_issue_ingest` route `POST /issues` (sibling of `cp_corpus`) |
| Isolated store namespace | `cp_state.get_backend(namespace=corpus_namespace())` | new `issues/` partition inside the SAME corpus namespace |
| k-anon aggregate | `cp_corpus_aggregate` bucket-fold + `K_ANONYMITY_MIN=20` suppression pattern | `cp_issue_aggregate` (mirror) keyed by error-class buckets |
| Shadow synth w/ support floor | `cp_corpus_synth.synthesize_proposals` pattern | `cp_issue_synth` → candidate GitHub issues |
| Cron / allowlisted dispatch | `cp_scheduler` + `cp_allowlist.validate` | 2 new allowlisted action-types |
| Seeker → fixer → PR | `issue_queue` + `heimdall-issue-loop` + `heimdall-maintain-loop` + `cp_maintainer_runner` | new `corpus` issue **source** in `normalize` |
| Free-text human path | `heimdall-feedback` / `report-issue` (untouched) | this path is METADATA-ONLY; free text stays human-gated |
| Falsifier convention | `bin/falsify` + `test/heimdall-corpus-ingest.test.sh` shape | mirrored belt `test/heimdall-issue-collection.test.sh` |

**New files (10) + 4 wiring edits.** No edit to the #4/#10 gated modules.

---

## 2. Privacy / security threat model

| # | Vector — how it could deanonymize or leak | Mitigation | Owner-task |
|---|---|---|---|
| T1 | Content leak: stack frame with a path, code snippet, or raw error message text rides in the signal | `assert_zero_content` on every leaf (path-sep / file-ext / code-punct / multi-word / over-length → BLOCK+ALARM) + closed-schema `rebuild_issue` drops unknown keys + `_TAG_MAX` truncation | issue-emit-lib, issue-ingest |
| T2 | Secret in error text (token in a stack trace) | `secret_scan_payload` before spool (client) **and** re-scan at ingest boundary (server) + gitleaks defense-in-depth; a finding → DROPPED + alarmed | issue-emit-lib, issue-ingest |
| T3 | Small-cohort re-identification: a bucket unique to one team/rare error reveals who hit it | per-bucket **k-anon ≥ 20 distinct teams** suppression at aggregate; sub-threshold bucket emits a `{suppressed:true}` marker, never metrics | issue-aggregate |
| T4 | Cross-tenant read: team B reads team A's issues | INV-1 **server-derived** `team_id_hash` (never a body field) + isolated `heimdall_corpus/issues/` keyspace disjoint from control-plane; the `rr-multitenant-isolation` keystone stays **1.0** | issue-ingest, wire-public-surface |
| T5 | Forged/unsigned ingest attributing to another team or smuggling content | signed ingest **fail-closed** (401 at `cp_auth` chokepoint before the route) + server `rebuild_issue` (client is never trusted) | issue-ingest |
| T6 | HAID attribution deanonymizes the reporter | issue carries only the re-projected non-reversible `team_id_hash` (domain-separated sha256) + coded class/version/os/command-phase — **no per-user id, no HAID, no repo name/URL in clear** | issue-emit-lib |
| T7 | Security-incident detail leaks to a public GitHub issue | emit-time **security-sensitivity classifier** routes matching signals to `.planning/security-signals/` PRIVATE lane, excluded from the public aggregate AND the synth candidate set — hard constraint honored | issue-emit-lib, issue-aggregate, issue-synth |
| T8 | Consent bypass: a cron/hook leaks around an OFF switch | consent is the SAME master switch (`enabled()`); OFF → emit is a pure no-op (zero spool) AND `corpus_send_enabled()` is False → the aggregate reads an empty store, so a cron **cannot** leak around it | issue-emit-lib |
| T9 | Timing / locale deanonymization | coarse `tz_bucket` (offset token only, e.g. `utc+0530`), no precise timestamps leave the client | issue-emit-lib |
| T10 | Free-text friction re-identifies a person | the anonymized path is **metadata-only** (no free text); worded reports stay on the existing `heimdall-feedback` human-gated path, out of this aggregate | (scope boundary — see §6) |

---

## 3. Coverage matrix

`evals/oracles/issue-collection/COVERAGE.md` (emitted wave-0). Declares scope UPFRONT so descoped subsystems render as *expected-red*, not surprise-red.

| Subsystem | In scope? | Oracle row affected | Expected result |
|---|---|---|---|
| Local emit + zero-content + secret-scan | yes | anonymization falsifier | green |
| Consent-off no-op | yes | consent-off falsifier | green |
| Signed ingest + INV-1 isolation | yes | isolation + signed-ingest falsifiers | green |
| k-anon aggregate | yes | k-anon falsifier | green |
| Security-sensitive routing | yes | security-routing falsifier | green |
| Differential aggregate correctness | yes | differential gate (independent reference) | green |
| Seeker/fixer feed (source=corpus) | yes | queue-normalize property | green |
| Auto-file GitHub issues (vs shadow) | **descoped — pending RJ decision Q2** | synth-candidate row | expected-red (shadow-only until decided) |
| Free-text / worded reports | descoped | — | n/a (stays on heimdall-feedback) |
| T1 hunk-style deny-context for issues | descoped | — | n/a (metadata-only) |

---

## 4. Oracle gate

No `evals/oracles/registry.json` domain matches "anonymized issue collection" (registry has `emulator-gb`, `exchange-lob`, `raytracer-calib`). Per Oracle-Gate Protocol rule 3, we wire a **falsifiable correctness gate authored independently of the impl** and register a NEW domain so it is canonical.

- **Registry domain (new):** `issue-collection`
- **gate_type:** `differential` — the published k-anon aggregate is asserted **byte-equal** to an **independently-authored reference aggregator** (separate agent, separate wave 2d, disjoint file scope) recomputing the aggregate over an identical seeded synthetic issue stream. This catches whole-output bucketing/suppression bugs a per-bucket property check passes.
- **Resolved gate command:** `evals/oracles/issue-collection/gate.sh --differential --seeds 200` (add via registry entry in wave 4; `bin/oracle-select issue-collection` must then print it).
- **independent:** `true` — reference author = wave-2d agent / seeded synthetic dataset; impl authors = waves 1–3. impl-author ≠ reference-author, separated by wave.
- **Falsifiability:** the gate ships `evals/oracles/issue-collection/fixtures/{golden,mutants}/`; `bin/falsify issue-collection --assert-score 1.0` must show golden GREEN + every injected-defect mutant KILLED (score 1.0) before the gate is trusted. Mutants MUST include: a k-anon-off mutant (sub-20 bucket surfaced), a cross-tenant-read mutant, a leaked-content mutant, and a security-signal-in-public-aggregate mutant.

The differential gate is accompanied by the property/verdict falsifier belt (`test/heimdall-issue-collection.test.sh`, mirroring `test/heimdall-corpus-ingest.test.sh`) — but the **differential gate is the load-bearing correctness signal**, the belt is defense-in-depth. Every feature ships a RED-without-fix falsifier (§ per-task acceptance).

---

## 5. Waves

Estimate is **AI wall-clock with parallel fan-out**, not calendar time. Critical path ≈ **5 sequential waves ≈ ~1.5 h**. Wave-2 and wave-3 each fan out to 4 parallel agents.

---

### Wave 0 — Invariant ledger + coverage (BEFORE any code)

#### Task: issue-ledger
- **Wave:** 0 · **Dependencies:** none
- **Agent:** `hmd:docs-writer` · **Model + effort:** `sonnet` + `default`
- **Read first:** `bin/lib/pmr_corpus.py`, `bin/lib/cp_corpus.py`, `evals/oracles/rr-multitenant-isolation/README.md`, `test/heimdall-corpus-ingest.test.sh`
- **Files:** Create: `evals/oracles/issue-collection/INVARIANTS.md`, `evals/oracles/issue-collection/COVERAGE.md`
- **Skills:** —
- **Patterns:** invariant style from `bin/lib/cp_corpus.py:1-40` header contract; coverage matrix from §3 above
- **Content (transcribe, do not invent):** INVARIANTS.md states as checkable statements: (INV-A) `issue_v1` leaves are coded/hashed/bounded only — no path, no source, no free text; (INV-B) k-anon ≥ 20 distinct teams per published bucket; (INV-C) `team_id_hash` is server-derived at ingest, never a body field; (INV-D) consent OFF → emit no-op + send gate False; (INV-E) unsigned ingest → 401 fail-closed; (INV-F) security-sensitive signal → private `.planning/` lane, excluded from public aggregate + synth; (INV-G) issue store namespace disjoint from control-plane keyspace. COVERAGE.md = the §3 matrix verbatim.
- **Acceptance criteria:**
  - [ ] `test -f evals/oracles/issue-collection/INVARIANTS.md`
  - [ ] `test -f evals/oracles/issue-collection/COVERAGE.md`
  - [ ] `grep -q "k-anon" evals/oracles/issue-collection/INVARIANTS.md && grep -q "20" evals/oracles/issue-collection/INVARIANTS.md`
  - [ ] `grep -qi "server-derived" evals/oracles/issue-collection/INVARIANTS.md`
  - [ ] `grep -qi "expected-red" evals/oracles/issue-collection/COVERAGE.md`
- **Verify:** `test -f evals/oracles/issue-collection/INVARIANTS.md && test -f evals/oracles/issue-collection/COVERAGE.md && grep -qi "server-derived" evals/oracles/issue-collection/INVARIANTS.md`
- **Done when:** the ledger + coverage matrix exist and every downstream task lists INVARIANTS.md under "Read first".
- **Risks & Mitigation:** ledger drifts from impl → re-inject INVARIANTS.md into every wave-1/2/3 task prompt (owner: this task lists it as a mandatory read).

---

### Wave 1 — Local emit engine (new sibling lib + CLI)

#### Task: issue-emit-lib
- **Wave:** 1 · **Dependencies:** issue-ledger
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md`, `bin/lib/pmr_corpus.py` (reuse target — import, never edit), `bin/lib/telemetry.py:81` (`_SECRET_PATTERNS`), `bin/heimdall-telemetry-corpus`
- **Files:** Create: `bin/lib/issue_corpus.py`, `bin/heimdall-issue-corpus`
- **Skills:** —
- **Patterns:** mirror `bin/lib/pmr_corpus.py` `project()` → `assert_zero_content` → `secret_scan_payload` → spool pipeline (`pmr_corpus.py:462-627`); import `pmr_corpus` for `enabled`/`assert_zero_content`/`secret_scan_payload`/`team_id_hash`/`repo_class_hash`/`corpus_home`/`_alarm` — **do not re-derive**. CLI shape from `bin/heimdall-telemetry-corpus` + the `hmd telemetry` router.
- **Spec (concrete, zero TBD):**
  - `SCHEMA_ISSUE = "issue_v1"`. `project(event)` builds a record with ONLY: `{schema, consent_version, ids:{issue_id, team_id_hash, repo_class_hash}, when:{ts, tz_bucket}, signal:{error_class(coded), signature_hash(sha256 of normalized error, domain-sep via pmr_corpus._h), gate(coded), phase(coded), command(coded), severity(coded enum)}, env:{os_class, ci, hmd_version}, security_sensitive:bool}`.
  - `classify_security_sensitive(event) -> bool`: True iff `secret_scan_payload` finds anything in the RAW event, OR `error_class` ∈ `{auth, crypto, secret, injection, deanon, isolation, incident}`, OR an explicit `incident` marker. (Exact taxonomy is RJ Q-open; ship the enumerated default set as a module constant `_SECURITY_CLASSES`.)
  - `emit_issue(event, home=None)`: (1) `if not pmr_corpus.enabled(home): return no-op`; (2) `project`; (3) if `security_sensitive` → write to `.planning/security-signals/<issue_id>.json` (git-committed private lane) + set a `private:true` flag, DO NOT spool to the send outbox; (4) else `assert_zero_content` (BLOCK+ALARM on violation via `pmr_corpus._alarm`); (5) `secret_scan_payload` (BLOCK+ALARM); (6) spool to `issue_outbox_dir`. Never raises into the caller.
  - `rebuild_issue(line)`: closed-schema server-side rebuild mirroring `pmr_corpus.rebuild_pmr` — bound every free field via `_tag`, coerce ints, DROP unknown keys, re-run `assert_zero_content`, return clean record or None.
  - CLI subcommands: `emit [--event @file|JSON]`, `status`, `purge` (delegates to a new issue-scoped purge + queues deletion keyed by `team_id_hash`), `flush --dry-run` (build+scan+print the signed batch, send nothing).
- **Acceptance criteria:**
  - [ ] `grep -q "SCHEMA_ISSUE" bin/lib/issue_corpus.py`
  - [ ] `grep -q "import pmr_corpus" bin/lib/issue_corpus.py` (reuse, not re-derive)
  - [ ] `grep -q "classify_security_sensitive" bin/lib/issue_corpus.py`
  - [ ] `HEIMDALL_TELEMETRY=off python3 bin/lib/issue_corpus.py emit --event '{"error_class":"lint"}' | grep -q '"emitted": false'` (consent-off no-op)
  - [ ] `python3 bin/lib/issue_corpus.py emit --event '{"error_class":"lint","message":"/etc/passwd:42 boom"}' | grep -qi "blocked"` (zero-content falsifier: planted path → BLOCK)
  - [ ] `python3 bin/lib/issue_corpus.py emit --event '{"error_class":"auth","message":"login failed"}' --home "$PWD/.tmp-ic" >/dev/null; test -d "$PWD/.tmp-ic" || grep -rq . .planning/security-signals/ 2>/dev/null` (security routing writes private lane, not outbox) — adapt to `--home` sandbox in the real test
  - [ ] `test -x bin/heimdall-issue-corpus`
- **Verify:** `HEIMDALL_TELEMETRY=off python3 bin/lib/issue_corpus.py emit --event '{"error_class":"lint"}' | grep -q '"emitted": false' && python3 bin/lib/issue_corpus.py emit --event '{"error_class":"x","message":"a/b.py:1 x()"}' | grep -qi blocked`
- **Done when:** local emit projects/guards/scans/spools an `issue_v1`, honors consent-off, and routes security-sensitive signals to the private lane.
- **Risks & Mitigation:** editing `pmr_corpus.py` breaks the #4/#10 gate → this task CREATES a sibling and imports; acceptance greps assert `import pmr_corpus` (owner: this task). · security classifier taxonomy under-covers → ship enumerated `_SECURITY_CLASSES` constant + flag Q-open (owner: this task + RJ Q1/Q-sec).

---

### Wave 2 — Server ingest + jobs + independent reference (4 parallel, disjoint NEW files)

All four import wave-1 / existing `cp_*`; none register themselves (wiring is wave 3); none edit each other.

#### Task: issue-ingest
- **Wave:** 2 · **Dependencies:** issue-emit-lib
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md`, `bin/lib/cp_corpus.py` (the sibling to mirror), `bin/lib/cp_auth.py` (`registered_team`), `bin/lib/cp_state.py` (namespace backend), `bin/lib/cp_audit.py`
- **Files:** Create: `bin/lib/cp_issue_ingest.py`
- **Patterns:** mirror `cp_corpus.py:111-259` (`ingest_*` boundary + `*_route` + `register`). Store rel: `issues/<team_hash>/issues.ndjson` inside `pmr_corpus.corpus_namespace()`. INV-1: `team_id_hash = cp_auth.registered_team(haid)`; no team → 403. Re-run `issue_corpus.rebuild_issue` per record; re-scan secret; drop security-sensitive records at the boundary (they should never have been sent, but fail-closed). Data-only — no action_type, no handler, no model call. One `cp_audit.write("issue_ingest", …)` counts-only row.
- **Acceptance criteria:**
  - [ ] `grep -q "def register" bin/lib/cp_issue_ingest.py && grep -q "/issues" bin/lib/cp_issue_ingest.py`
  - [ ] `grep -q "cp_auth.registered_team" bin/lib/cp_issue_ingest.py` (INV-1)
  - [ ] `grep -q "rebuild_issue" bin/lib/cp_issue_ingest.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_ingest"` exits 0
  - [ ] `grep -q "403" bin/lib/cp_issue_ingest.py` (no-team fail-closed)
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_ingest as m;assert hasattr(m,'register') and hasattr(m,'ingest_issues')"`
- **Done when:** a signed `POST /issues` batch lands issues in the isolated per-team partition, server-stamped, re-scrubbed, audited; unsigned/no-team fail-closed.
- **Risks & Mitigation:** cross-tenant write path → INV-1 server-derived key (owner: this task; falsifier in wave 4). · secret smuggled past client → server re-scan boundary (owner: this task).

#### Task: issue-aggregate
- **Wave:** 2 · **Dependencies:** issue-emit-lib
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md`, `bin/lib/cp_corpus_aggregate.py` (the mirror), `bin/lib/pmr_corpus.py` (`K_ANONYMITY_MIN`)
- **Files:** Create: `bin/lib/cp_issue_aggregate.py`
- **Patterns:** mirror `cp_corpus_aggregate.py` `_new_bucket`/`_fold`/`_publish_bucket`/`run_daily`. Bucket key = `(error_class, signature_hash, hmd_version, os_class, command|phase)`. Per-bucket **k-anon ≥ `pmr_corpus.K_ANONYMITY_MIN`** distinct `team_id_hash` → else `{suppressed:true, reason:"k_anonymity", teams:n}`. EXCLUDE any `security_sensitive:true` record from the public aggregate entirely. Write to the isolated corpus namespace under `issue-aggregates/`. No model call. CLI: `run [--home]`.
- **Acceptance criteria:**
  - [ ] `grep -q "K_ANONYMITY_MIN" bin/lib/cp_issue_aggregate.py`
  - [ ] `grep -q "suppressed" bin/lib/cp_issue_aggregate.py`
  - [ ] `grep -qi "security_sensitive" bin/lib/cp_issue_aggregate.py` (private-lane exclusion)
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_aggregate"` exits 0
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_aggregate as m;assert hasattr(m,'run_daily_aggregate') or hasattr(m,'run')"`
- **Done when:** a daily fold produces k-anon-gated published issue buckets with sub-20 buckets suppressed and security-sensitive records excluded.
- **Risks & Mitigation:** sparse issue buckets (rarer than PMRs) suppress everything → surface a `suppressed_bucket_count` metric + flag RJ Q3 on threshold (owner: this task).

#### Task: issue-synth
- **Wave:** 2 · **Dependencies:** issue-emit-lib
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md`, `bin/lib/cp_corpus_synth.py` (the mirror)
- **Files:** Create: `bin/lib/cp_issue_synth.py`
- **Patterns:** mirror `cp_corpus_synth.synthesize_proposals` — cluster k-anon-cleared buckets into candidate GitHub-issue records; only emit a candidate whose distinct-team support ≥ floor (default `K_ANONYMITY_MIN`). EVERY candidate is `status:"pending_review", enforced:false` (SHADOW — human promotes) **unless** RJ Q2 flips to auto-file. Candidate carries only coded pattern + support counts + sample issue_ids — no message text. NEVER include a `security_sensitive` bucket.
- **Acceptance criteria:**
  - [ ] `grep -q "pending_review" bin/lib/cp_issue_synth.py`
  - [ ] `grep -qi "support" bin/lib/cp_issue_synth.py`
  - [ ] `grep -qi "security_sensitive" bin/lib/cp_issue_synth.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_synth"` exits 0
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_issue_synth as m;assert hasattr(m,'synthesize_candidates') or hasattr(m,'synthesize_proposals')"`
- **Done when:** candidate issues are shadow proposals gated by distinct-team support, carrying zero content, excluding security buckets.
- **Risks & Mitigation:** auto-filing spam GitHub → default SHADOW/pending_review; auto-file only on explicit RJ Q2 decision (owner: this task + RJ Q2).

#### Task: issue-reference (INDEPENDENT — separate agent for differential independence)
- **Wave:** 2 · **Dependencies:** issue-ledger
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md` ONLY (must NOT read `cp_issue_aggregate.py` — shares no code path with the impl)
- **Files:** Create: `evals/oracles/issue-collection/reference/aggregate_ref.py`, `evals/oracles/issue-collection/reference/README.md`
- **Patterns:** independence from `evals/oracles/exchange-lob/reference` (deliberately naive). A from-scratch, spec-only recomputation of the k-anon aggregate over a seeded synthetic issue stream — no import of `bin/lib/*`. Correctness over speed.
- **Acceptance criteria:**
  - [ ] `test -f evals/oracles/issue-collection/reference/aggregate_ref.py`
  - [ ] `! grep -q "import cp_issue_aggregate" evals/oracles/issue-collection/reference/aggregate_ref.py` (independence — must NOT import the impl)
  - [ ] `python3 evals/oracles/issue-collection/reference/aggregate_ref.py --help` exits 0
- **Verify:** `test -f evals/oracles/issue-collection/reference/aggregate_ref.py && ! grep -q "cp_issue_aggregate" evals/oracles/issue-collection/reference/aggregate_ref.py`
- **Done when:** an independent reference aggregator exists that the wave-4 differential gate diffs against — sharing no code with the impl.
- **Risks & Mitigation:** reference shares impl misconception → authored by a DIFFERENT agent, spec-only, forbidden from importing impl (owner: this task; enforced by the `! grep` acceptance).

---

### Wave 3 — Wiring (4 parallel, disjoint shared-file owners)

Each task owns exactly one shared file; the four files are disjoint → parallel-safe.

#### Task: wire-boot
- **Wave:** 3 · **Dependencies:** issue-ingest
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `bin/lib/cp_boot.py:44-56` (imports) + `:400-429` (route registrations)
- **Files:** Modify: `bin/lib/cp_boot.py` (add `import cp_issue_ingest` + `routes["issues"] = [cp_issue_ingest.register(home=home)]`)
- **Acceptance criteria:**
  - [ ] `grep -q "import cp_issue_ingest" bin/lib/cp_boot.py`
  - [ ] `grep -q 'routes\["issues"\]' bin/lib/cp_boot.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_boot"` exits 0
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_boot"`
- **Done when:** `/issues` registers at boot alongside `/corpus`.
- **Risks & Mitigation:** boot import cycle → follow the exact lazy/eager pattern of `cp_corpus` import (owner: this task).

#### Task: wire-allowlist
- **Wave:** 3 · **Dependencies:** issue-aggregate, issue-synth
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `bin/lib/cp_allowlist.py:254-312` (ActionSpec registry), `bin/lib/cp_scheduler.py` (fire path)
- **Files:** Modify: `bin/lib/cp_allowlist.py` (add `aggregate-issues` + `synth-issues` ActionSpecs, `requires_gate=False`, `isolated=True`, typed bounded params, no free string); `bin/lib/cp_handlers.py` (add the two handlers dispatching to `cp_issue_aggregate.run_daily` / `cp_issue_synth`)
- **Acceptance criteria:**
  - [ ] `grep -q '"aggregate-issues"' bin/lib/cp_allowlist.py && grep -q '"synth-issues"' bin/lib/cp_allowlist.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_allowlist as a;assert a.is_allowed('aggregate-issues') and a.is_allowed('synth-issues')"` exits 0
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_allowlist as a;print(a.is_allowed('rm -rf'))" | grep -q False` (no free-form cmd)
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_allowlist as a;assert a.is_allowed('aggregate-issues') and not a.is_allowed('arbitrary-cmd')"`
- **Done when:** the two cron action-types are allowlisted, gated, dispatch through `cp_scheduler` → `cp_allowlist.validate`, and no arbitrary command is dispatchable.
- **Risks & Mitigation:** widening the allowlist opens a smuggle channel → typed bounded scalars only + extra-key wall (mirror `run-maintainer-cycle` spec `cp_allowlist.py:286-306`) (owner: this task).

#### Task: wire-queue-source
- **Wave:** 3 · **Dependencies:** issue-synth
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `bin/lib/issue_queue.py:103-128` (`normalize` + `_identity` + `_KIND_BY_SOURCE`), `bin/heimdall-issue-loop`
- **Files:** Modify: `bin/lib/issue_queue.py` (add `corpus` source to `_KIND_BY_SOURCE` + a `normalize` adapter mapping a synth candidate → the one internal issue schema); Create: `bin/lib/connectors/corpus.py` (read synth candidates as native items)
- **Acceptance criteria:**
  - [ ] `grep -q "corpus" bin/lib/issue_queue.py`
  - [ ] `test -f bin/lib/connectors/corpus.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import issue_queue"` exits 0
  - [ ] `python3 bin/heimdall-issue-queue status >/dev/null 2>&1; echo $?` prints `0`
- **Verify:** `python3 -c "import sys;sys.path.insert(0,'bin/lib');import issue_queue as q;assert 'corpus' in q._KIND_BY_SOURCE"`
- **Done when:** synth candidates normalize into the existing queue as `source=corpus`, drained by the unchanged `heimdall-issue-loop` seeker/fixer path.
- **Risks & Mitigation:** breaking the existing 3 launch sources → additive map entry + a connectors adapter, existing sources untouched (owner: this task).

#### Task: wire-public-surface
- **Wave:** 3 · **Dependencies:** issue-ingest
- **Agent:** `hmd:coder` · **Model + effort:** `opus` + `high`
- **Read first:** `bin/lib/cp_publicsurface.py` (`PUBLIC_ROUTES`), `deploy/cloud-run/check-public-surface.sh`
- **Files:** Modify: `bin/lib/cp_publicsurface.py` (add `POST /issues` to `PUBLIC_ROUTES` so it is served signed+gated on the public surface)
- **Acceptance criteria:**
  - [ ] `grep -q "/issues" bin/lib/cp_publicsurface.py`
  - [ ] `python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_publicsurface"` exits 0
  - [ ] `bash deploy/cloud-run/check-public-surface.sh >/dev/null 2>&1; echo $?` prints `0` (public surface still coherent)
- **Verify:** `grep -q "/issues" bin/lib/cp_publicsurface.py && python3 -c "import sys;sys.path.insert(0,'bin/lib');import cp_publicsurface"`
- **Done when:** `/issues` is on the signed, gated public surface exactly like `/corpus`.
- **Risks & Mitigation:** exposing an unsigned route → `/issues` inherits the signed+gated auth chokepoint; public-surface check asserts coherence (owner: this task).

---

### Wave 4 — Correctness gate + falsifier belt (INDEPENDENT of impl)

#### Task: issue-oracle-gate
- **Wave:** 4 · **Dependencies:** ALL wave-1/2/3 tasks + issue-reference
- **Agent:** `hmd:verifier` · **Model + effort:** `opus` + `max`
- **Read first:** `evals/oracles/issue-collection/INVARIANTS.md`, `test/heimdall-corpus-ingest.test.sh` (the belt to mirror), `bin/falsify`, `evals/oracles/registry.json`, `evals/oracles/REPORT-CONTRACT.md`, `evals/oracles/issue-collection/reference/aggregate_ref.py`
- **Files:** Create: `evals/oracles/issue-collection/gate.sh`, `evals/oracles/issue-collection/run.sh`, `evals/oracles/issue-collection/manifest.json`, `evals/oracles/issue-collection/fixtures/golden/`, `evals/oracles/issue-collection/fixtures/mutants/`, `test/heimdall-issue-collection.test.sh`; Modify: `evals/oracles/registry.json` (add the `issue-collection` domain per §4)
- **Patterns:** `run.sh` writes a typed `report.json` (status + first_divergence) per `REPORT-CONTRACT.md`; `gate.sh --differential --seeds 200` diffs the impl aggregate vs `reference/aggregate_ref.py` over seeded streams. Belt mirrors `test/heimdall-corpus-ingest.test.sh` sections.
- **Falsifier belt (each RED-without-fix):**
  - anonymization: plant a path/source-line/PII into an issue → `assert_zero_content` BLOCKS; if it lands → RED
  - secret-scan: plant `AKIAIOSFODNN7EXAMPLE` → dropped client+server; byte-string in store → RED
  - consent-off: `HEIMDALL_TELEMETRY=off` → zero spool + `corpus_send_enabled` False; any byte sent → RED
  - k-anon: a <20-team bucket surfaced with real rates in the published aggregate → RED
  - isolation: read team B's `/issues` partition from team A / cross-namespace read → RED (rr keystone 1.0)
  - signed-ingest: unsigned/forged push that stores a record → RED (fail-closed)
  - security-routing: a `security_sensitive` signal reaching the public aggregate or a synth candidate → RED
  - differential: published aggregate ≠ independent reference recomputation over the seeded stream → RED
- **Oracle gate (REQUIRED):** registry domain `issue-collection`, `gate_type: differential`, resolved command `evals/oracles/issue-collection/gate.sh --differential --seeds 200`, `independent: true`, reference author = wave-2d `issue-reference` agent (separate agent, separate wave, disjoint files). No canonical registry oracle pre-existed for this domain — this task ADDS it and flags reviewers.
- **Acceptance criteria:**
  - [ ] `bin/oracle-select issue-collection | grep -q "gate.sh"` (registry entry resolves)
  - [ ] `jq -e '.oracles["issue-collection"].gate_type=="differential"' evals/oracles/registry.json` exits 0
  - [ ] `jq -e '.oracles["issue-collection"].reference.independent==true' evals/oracles/registry.json` exits 0
  - [ ] `bin/falsify issue-collection --assert-score 1.0` exits 0 (golden GREEN + all mutants KILLED)
  - [ ] `bash test/heimdall-issue-collection.test.sh` exits 0 (full belt green)
  - [ ] `test -d evals/oracles/issue-collection/fixtures/mutants` && `ls evals/oracles/issue-collection/fixtures/mutants | grep -qi kanon`
- **Verify:** `bin/falsify issue-collection --assert-score 1.0 && bash test/heimdall-issue-collection.test.sh`
- **Done when:** the differential gate + full falsifier belt are green, `bin/falsify` shows score 1.0, and every privacy invariant has a RED-without-fix mutant.
- **Risks & Mitigation:** a tautological/non-falsifiable gate → `bin/falsify --assert-score 1.0` is itself an acceptance criterion; a mutant that survives fails the task (owner: this task). · authored by `hmd:verifier` (not a wave-1/2/3 impl agent) → gate independence (owner: this task).

---

## 6. OUT OF SCOPE

- **Free-text / worded issue reports** — the existing `heimdall-feedback` / `hmd:report-bug` human-gated path is unchanged. This capability is metadata-only.
- **Auto-filing GitHub issues without human review** — default is SHADOW `pending_review` candidates; auto-file is gated on RJ decision Q2 and would be a follow-up cycle.
- **Editing the #4 telemetry / #10 corpus gated modules** (`pmr_corpus.py`, `cp_corpus.py`, `cp_corpus_aggregate.py`, `cp_corpus_synth.py`) — additive siblings only; those gates stay byte-green.
- **T1-style deny-context hunks for issues** — issues are metadata-only; no per-hunk capture.
- **New crypto / new signing scheme** — reuses the existing signed-ingest + `cp_auth` PKI-over-HAID.
- **Per-org multi-tenant beyond the existing team isolation seam** — the `rr-multitenant-isolation` keystone governs; no new isolation model.
- **Retention-policy tuning of the issue partition** — inherits the corpus namespace retention; a separate ops decision.
- **Dashboard / UI for browsing aggregated issues** — a later cycle.
- **Deploy / rollout of the new routes to prod Cloud Run** — separate go-live runbook step.

## 7. Risks (rollup)

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Editing gated corpus modules regresses #4/#10 | med | high | additive siblings; `import pmr_corpus`, never edit; acceptance greps enforce | issue-emit-lib |
| Cross-tenant read of another team's issues | low | high | INV-1 server-derived key + isolated namespace; isolation mutant in belt | issue-ingest, wire-public-surface, issue-oracle-gate |
| Security signal leaks to public GitHub | low | high | emit-time classifier → private `.planning/` lane; excluded from aggregate+synth; security-routing mutant | issue-emit-lib, issue-aggregate, issue-synth |
| Content/secret leak in a signal | med | high | zero-content guard + secret-scan (client+server) + closed-schema rebuild | issue-emit-lib, issue-ingest |
| k-anon suppresses nearly all issue buckets (issues rarer than PMRs) | med | med | surface `suppressed_bucket_count`; RJ Q3 to tune threshold | issue-aggregate |
| Tautological / non-falsifiable gate | low | high | `bin/falsify --assert-score 1.0` is an acceptance gate; independent reference author | issue-oracle-gate |
| Auto-file spams the tracker | med | med | SHADOW `pending_review` default; auto-file only on RJ Q2 | issue-synth |
| Allowlist widening opens a smuggle channel | low | high | typed bounded scalars + extra-key wall (mirror `run-maintainer-cycle`) | wire-allowlist |

## 8. Open design questions (RJ decides)

1. **Issue signal fields + signature granularity (Q1).** Proposed minimal set: `error_class` (coded enum) · `signature_hash` (sha256 of the normalized error, domain-separated) · `gate` (which gate failed) · `phase` · `command` · coded `severity` · `hmd_version` · `os_class`. Is a *hashed* error signature acceptable, or does even a hash risk re-identifying a rare error before k-anon? Do we want the failing gate name, or is that too revealing of a team's stack?
2. **Auto-file vs human-gate (Q2).** Should the scheduled synth **auto-open** GitHub issues via the seeker/fixer loop, or emit SHADOW `pending_review` candidates a maintainer promotes (the `cp_corpus_synth` precedent)? Recommendation: **shadow first**, flip to auto-file after a confidence window.
3. **k-anon threshold for issues (Q3).** Keep `k ≥ 20` (corpus parity) or lower? Issues are likely rarer than PMRs, so `k ≥ 20` may suppress most buckets and starve the seeker feed. Also: what distinct-team **support floor** for a synth candidate?

Secondary: the exact **security-sensitivity taxonomy** (`_SECURITY_CLASSES` default = `{auth, crypto, secret, injection, deanon, isolation, incident}` — confirm/extend); the **issue partition retention** policy; whether `/issues` rides its **own route** (chosen here) or extends the existing `/corpus` batch.

---

*Note: per architect protocol this plan should be run through `hmd:reviewer` plan-verification (plan-vs-spec, unrunnable criteria, unowned risks, oracle-gate rejection rules) before hand-off to wave-executor. The architect could not self-spawn the reviewer in this environment — flagging as the required next gate.*
