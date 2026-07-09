# COVERAGE — Anonymized Issue Collection (`issue-collection` oracle domain)

**Authored:** 2026-07-09 (Wave 0) · **Companion of** [`INVARIANTS.md`](./INVARIANTS.md).

This matrix declares scope **UPFRONT** so descoped subsystems render as
*expected-red*, not surprise-red. A row marked **expected-red** is a deliberate
scope boundary for this build (Wave 0 + Wave 1), not a defect. See the plan
`docs/superpowers/plans/2026-07-09-anonymized-issue-collection.md` §3.

---

## Subsystem coverage

| Subsystem | In scope? | Wave | Oracle row affected | Expected result |
|---|---|---|---|---|
| Local emit + zero-content + secret-scan | yes | 1 | `anonymization` falsifier | green |
| Consent-off no-op | yes | 1 | `consent-off` falsifier | green |
| Security-sensitive routing (private lane) | yes | 1 | `security-routing` falsifier | green |
| Rare-signature k-anon suppression primitive | yes | 1 | `k-anon` falsifier (primitive) | green |
| Closed-schema `rebuild_issue` | yes | 1 | `anonymization` falsifier | green |
| Signed ingest + INV-1 server-derived attribution | yes (later wave) | 2/3 | `isolation` + `signed-ingest` falsifiers | expected-red **until Wave 2/3** |
| k-anon aggregate (published buckets) | yes (later wave) | 2 | `k-anon` falsifier (aggregate) | expected-red **until Wave 2** |
| Differential aggregate correctness | yes (later wave) | 2/4 | differential gate (independent reference) | expected-red **until Wave 2/4** |
| Seeker/fixer feed (`source=corpus`) | yes (later wave) | 3 | queue-normalize property | expected-red **until Wave 3** |
| Auto-file GitHub issues (vs shadow) | **descoped — SHADOW-only (RJ decision 2)** | — | synth-candidate row | expected-red (shadow-only, never auto-file this build) |
| Free-text / worded reports | descoped | — | — | n/a (stays on `heimdall-feedback`) |
| T1 hunk-style deny-context for issues | descoped | — | — | n/a (metadata-only) |

---

## This build (Wave 0 + Wave 1) — what is GREEN now

| Deliverable | File | Result |
|---|---|---|
| Invariant ledger | `evals/oracles/issue-collection/INVARIANTS.md` | green |
| Coverage matrix (this file) | `evals/oracles/issue-collection/COVERAGE.md` | green |
| Local emit lib | `bin/lib/issue_corpus.py` | green |
| Emit CLI | `bin/heimdall-issue-corpus` | green |
| Wave-1 falsifier belt | `test/heimdall-issue-corpus-emit.test.sh` | green |

The Wave-1 belt proves four falsifiers GREEN (each RED-without-fix before impl):
`consent-off` (INV-D), `leaked-content` (INV-A), `security-routing` (INV-F),
`rare-signature` (INV-B).

## Expected-red rows — why they are not defects

- **Signed ingest / server-derived attribution / namespace isolation** (INV-C,
  INV-E, INV-G): the ingest route, `cp_auth` chokepoint, and per-team partition
  land in Waves 2–3. The invariants are ledgered now; their falsifiers are
  *expected-red* until those files exist.
- **k-anon aggregate / differential gate**: the *primitive* (`suppress_if_rare`)
  ships and is green in Wave 1; the *aggregate* that folds a real store and the
  differential gate that diffs it against an independent reference land in
  Waves 2/4.
- **Auto-file GitHub issues**: intentionally never in scope — RJ decision 2 fixes
  disposition to SHADOW `pending_review`. This row stays *expected-red* by design.
