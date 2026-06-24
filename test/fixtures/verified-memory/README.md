# Verified-Memory benchmark fixture — Postgres → MySQL → NoSQL

This is the **git-true labeled** clean-code fixture that drives the VM benchmark
(`bin/lib/vm_bench.py`, `bin/heimdall-vm-bench`). It is the concrete realisation of
the dossier §4 fixture: a **3-commit synthetic migration repo** where each migration
makes a prior memory entry stale, plus the team-divergence conflict variant.

The fixture is **data, not a live repo**: `fixture.json` declares the commit chain
(each commit's file contents) and `cases.json` declares the labeled benchmark cases
(each a memory entry + the commit it is read at + its **git-true** `live`/`stale`
label + the STALE-style `type`). The benchmark **builds a throwaway git repo from
`fixture.json` at runtime** (real `git init` + real commits — staleness is induced by
a real git operation, never a flag flip), checks each method against the SAME labels,
and scores every method against this single ground truth.

## The migration chain (`fixture.json`)

| Commit | `db/store.py` symbol | `services/orders.py` dependency | Makes stale |
|---|---|---|---|
| **P** | `PostgresStore` | imports `PostgresStore` | — (E1 live here) |
| **M** | `MySQLStore` | imports `MySQLStore` | E1 (`PostgresStore` gone) → **Type-I** |
| **N** | `NoSQLStore` | one path still imports the old store name | E2 directly; an `orders.py` entry that *depends on* the datastore → **Type-II** |

## The cases (`cases.json`)

Each case has: `id`, the `entry` (a `vm-1.0` MemoryEntry: claim + commit_ref + refs),
the `read_at_commit` (which commit HEAD sits at when the entry is retrieved), the
`git_true` label (`live` | `stale` — the ground truth every method is scored against),
and the STALE `type` (`type-I` direct contradiction, `type-II` indirect
dependency-chain, or `clean` for a still-valid entry).

- **Type-I (direct):** E1 (Postgres) read at M/N — its ref symbol `PostgresStore` is
  gone → git-true `stale`.
- **Type-II (indirect dependency-chain):** an entry about `services/orders.py` that
  *depends on* the datastore symbol — at N the chain is broken → git-true `stale`,
  even though the entry's own file still parses.
- **clean:** the current-migration entry (e.g. E3 NoSQL read at N) → git-true `live`.

## The conflict variant (`conflict.json`)

The team-divergence case: at the MySQL commit a set of entries (Postgres-stale +
MySQL-live) reconcile to a single git-true winner (auto-resolve); the genuine
multi-live divergence (3-of-8 devs still on MySQL) routes to `conflicted` →
human-escalation. Used to score **conflict-resolution accuracy** per method.

## Honesty

Every label here is the **git-true** status — computed mechanically against the real
synthetic repo, never hand-asserted as a "result". The benchmark scores each method
(verified-memory + the 3 baselines) against these labels and reports the delta with
`holdout.py` provenance: **measured-or-estimated-or-blank, never fabricated.**
