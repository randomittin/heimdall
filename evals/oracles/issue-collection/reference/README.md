# Independent reference aggregator — `issue-collection` differential oracle

`aggregate_ref.py` is the **independent reference** the Wave-4 differential gate
(`gate.sh --differential --seeds 200`) diffs the implementation aggregate
against. It is authored **separately from the implementation** so that a bug
shared with the impl cannot false-green the oracle: if both computations agree
on the served / suppressed / excluded partition of an identical seeded stream,
the impl is trusted; if they diverge, the gate goes **RED**.

## Independence contract (why this can grade the impl)

- **Zero impl imports.** This module imports nothing from `bin/lib/*` — not
  `pmr_corpus`, not `cp_issue_aggregate`/`cp_issue_ingest`/`cp_issue_synth`, not
  `cp_corpus_aggregate`. Every constant (`ISSUE_K_ANONYMITY_MIN = 10`, the
  security class set) and every computation is reproduced here from the **spec**
  (`../INVARIANTS.md`) alone. Verify:

  ```sh
  ! grep -Eq 'import (pmr_corpus|cp_issue|cp_corpus)' evals/oracles/issue-collection/reference/aggregate_ref.py
  ```

- **Disjoint path.** Lives under `evals/oracles/issue-collection/reference/`,
  touching no impl file, statusline, or autoupdate.
- **Correctness over speed.** Plain sets and dict folds, no cleverness — an
  oracle, not a hot path (independence idiom borrowed from
  `evals/oracles/exchange-lob/reference`).

## What it computes (from `INVARIANTS.md`)

Given a stream of `issue_v1` records it produces the canonical partition:

- **served** — buckets with `>= ISSUE_K_ANONYMITY_MIN (=10)` **distinct**
  `team_id_hash` (INV-B). Distinct-team count, never row count. Carries the
  bucket key + `teams` + `rows`.
- **suppressed** — buckets with `0 < teams < 10`, emitted as
  `{suppressed: true, reason: "k_anonymity", teams: n}` and **never** the
  underlying metrics (INV-B). Includes the rare-signature case.
- **excluded_security** — opaque count of records dropped because they are
  security-sensitive (INV-F): the `security_sensitive` flag is truthy **or**
  `error_class ∈ {auth, crypto, secret, injection, deanon, isolation,
  incident}`. These NEVER enter served or suppressed, at any team count.
- **dropped_no_team** — records with no `team_id_hash` (INV-C: they could not
  have been ingested; the reference does not invent attribution).

Bucket key (INV-B): `(error_class, signature_hash, hmd_version, os_class,
command|phase)`.

## Usage

```sh
# hand-checked self-consistency (proves the partition matches spec by hand)
python3 evals/oracles/issue-collection/reference/aggregate_ref.py selftest

# generate a deterministic seeded stream (ndjson on stdout)
python3 .../aggregate_ref.py generate --seed 200 > stream.ndjson

# aggregate a stream (ndjson OR JSON array, stdin or --input file)
python3 .../aggregate_ref.py aggregate --input stream.ndjson

# one-shot: seed -> stream -> canonical aggregate (what the gate diffs)
python3 .../aggregate_ref.py run --seed 200
```

Output is canonical JSON (sorted keys, compact separators, trailing newline) so
the gate can byte-diff impl-vs-reference directly. Same seed ⇒ byte-identical
stream and aggregate.

## Spec ambiguities (plainest reading taken; NOT resolved by peeking at the impl)

Per the independence rules, where `INVARIANTS.md` is ambiguous this reference
implements the plainest reading and records it here rather than reading the impl.
The Wave-4 gate author should reconcile these before trusting a byte-diff.

1. **`command|phase` bucket dimension.** The fifth key component is written with
   a pipe (`command|phase`). Plainest reading of a pipe is OR, so this
   **coalesces**: `command` if present and non-empty, else `phase`, else `""`.
   *Alternative:* a two-field `(command, phase)` key. If the impl keys on both
   fields separately, the gate will diverge and this coalesce is the reason —
   change `_coalesce_command_phase` / `BUCKET_KEY_FIELDS` to match.

2. **Suppressed-marker key visibility.** `INV-B` mandates the marker carry
   `{suppressed, reason, teams:n}` but does not say whether it also carries the
   bucket key. This reference **includes the key** so the differential can verify
   the *complete* partition (which signatures were suppressed, not just how
   many). *Alternative:* a stricter privacy reading omits `signature_hash` from
   the marker. If the impl omits keys from suppressed markers, align the
   suppressed-entry shape here.

3. **Security-exclusion predicate.** `INV-F` defines "security-sensitive" as
   *flag set OR `error_class` in the class set*. The aggregate task text says
   "exclude any `security_sensitive:true` record". On a well-formed stream (emit
   lib sets the flag for security classes) both agree. This reference excludes on
   **either** condition (the full INV-F definition) so it stays correct even on a
   fixture that forgot the flag. If the impl excludes strictly on the flag and a
   fixture carries a security `error_class` without the flag, they diverge — the
   fixture, not the reference, is malformed.

4. **Aggregate output wrapper shape.** `INVARIANTS.md` pins the per-bucket
   semantics (served/suppressed/teams) but not the top-level envelope. This
   reference defines its own (`schema: issue_aggregate_ref_v1`, `served`,
   `suppressed`, `excluded_security`, `dropped_no_team`). The gate must
   **normalise both sides to a common comparable shape** before diffing — it
   should compare the served/suppressed bucket sets and the exclusion count, not
   the raw envelopes, since impl and reference legitimately use different
   wrappers.
