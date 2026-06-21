# SI-1 — Project-Context Comprehension Capsule (orientation cache + checkpoint)

A per-repo persisted file that caches the agent's **comprehension** of a project
(architecture, key modules, conventions, entry points, build/test commands) and
doubles as the resumable **orientation cache**: orient-once, reuse-many. Today
every run re-derives project understanding from scratch (tokens). This caches the
derivation, keyed to a structural fingerprint, and re-derives only when the repo
structurally changes.

- Engine: `bin/lib/comprehension.py` (pure-stdlib, deterministic structural scan — **not** an LLM call)
- CLI: `bin/heimdall-comprehend`
- Tests: `test/comprehension.test.sh`
- Capsule file: `${HEIMDALL_HOME:-<repo>/.heimdall}/context.json` (gitignored runtime — `.heimdall/` is already in `.gitignore`; no baked paths)

## What the capsule holds (schema)

`context.json` — one JSON object, sorted keys, written atomically (`.tmp` → `os.replace`).

| Field | Type | Meaning (all values DERIVED from a real scan) |
|---|---|---|
| `schema_version` | string | Capsule schema version (`"1.0.0"`). |
| `repo` | string | Absolute, normalized repo path the capsule describes. |
| `generated_at` | string | UTC ISO-8601 timestamp (supplied by the CLI; the engine never reads the clock — deterministic output). |
| `fingerprint` | string | sha256 structural fingerprint — the **staleness key** (see below). |
| `languages` | string[] | Languages present, by source-file extension census (e.g. `["typescript"]`). |
| `architecture` | string | One-line structural summary: `<langs> project — top-level modules: <…> — manifests: <…>`. |
| `key_modules` | object[] | Top-level source dirs ranked by file count: `{ "path", "files" }`, largest first. |
| `entry_points` | string[] | Conventional entry points: `bin/`, `cmd/`, root `main.*`/`index.*`/`__main__.py`, one per top-level source dir. |
| `conventions` | string[] | Detected conventions: lockfiles, lint/format config, test dir, GitHub Actions CI. |
| `manifests` | string[] | Build/dependency manifests at the repo root (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Makefile`, …). |
| `build_commands` | string[] | Build commands inferred from the manifests (npm `scripts`/Makefile targets preferred over generic defaults). |
| `test_commands` | string[] | Test commands inferred the same way. Empty when no manifest → honest, never fabricated. |
| `derivation` | object | `{ method: "structural-scan", count, cost_units }`. **`count`** is the orient-once proof signal; **`cost_units`** = files scanned (the deterministic, module-level stand-in for the launch-path token delta F1 will measure). |

The derivation is **honest and deterministic**: every field is computed from the
files on disk. A repo with no recognized manifest yields empty `build_commands`/
`test_commands` (and `architecture` says "no build manifest") rather than a
guessed command — there is no faked field.

## When it invalidates (staleness / re-derive rules)

`load` recomputes the structural fingerprint from the **live** repo and compares
it to the stored one. The fingerprint is a sha256 over:

1. **Top-level entries** — the sorted set of dirs + files at the repo root
   (skipping `.git`, `node_modules`, build/venv/runtime dirs, `.heimdall`, …).
   → A **new top-level module** flips it.
2. **Each detected manifest's name + a content hash of it.**
   → A **changed `package.json`/`pyproject.toml`/…** (new dependency, changed
   script) flips it — not just adding/removing a manifest, but editing one.
3. **The language set.**
   → Introducing a **new language** flips it.

Outcome of `load`:

| Capsule state | Result | CLI signal | Exit |
|---|---|---|---|
| well-formed **and** fingerprint matches | **fresh** → reuse, do **not** re-derive | `loaded:cached` | 0 |
| well-formed but fingerprint differs | **stale** → re-derive needed | `re-derive needed (stale)` | 3 |
| file absent | **missing** → re-derive needed | `re-derive needed (missing)` | 3 |
| present but unreadable / not JSON / missing required fields | **corrupt** → re-derive needed | `re-derive needed (corrupt)` | 3 |

`comprehend` reuses a **fresh** capsule (the derivation counter does **not**
advance — orient-once at the write path too); it re-derives on stale/missing/
corrupt (counter advances, fingerprint updated). `--force` always re-derives.

**Graceful degrade:** a missing or corrupt capsule is reported as exit 3, never a
crash — JSON-decode and OS errors are caught and classified as `corrupt`/`missing`.

## CLI

```
heimdall-comprehend comprehend <repo-dir> [--print] [--force]   # derive (or reuse fresh) + write
heimdall-comprehend load       <repo-dir> [--print]             # return cached if fresh, else exit 3
heimdall-comprehend show       <repo-dir>                       # print the stored capsule verbatim
heimdall-comprehend status     <repo-dir>                       # print fresh|stale|missing|corrupt
heimdall-comprehend fingerprint<repo-dir>                       # print the live structural fingerprint
heimdall-comprehend path       <repo-dir>                       # print the resolved capsule path
```

Exit: `0` derived/written or fresh-loaded · `3` load needs re-derive (stale/
missing/corrupt) · `2` usage / repo-not-found / python-missing.

## Relationship to the existing checkpoint (reused, NOT duplicated)

SI-1 does **not** introduce a parallel checkpoint store. Two existing mechanisms
are left untouched and are complementary:

- **`.planning/CHECKPOINT.md`** (the `/hmd:save` checkpoint) — the **save-state**:
  *where did we leave off* — current phase, what's done/in-progress/next,
  resume instructions. Forward progress across sessions.
- **`bin/heimdall-capsule`** — per-task **<=10-line compaction** capsules
  (`what changed / where / decision / gotcha`) hydrated by dependency closure.

The comprehension capsule is the third, orthogonal layer: the **orientation
cache** — *what IS this project* (architecture/modules/commands). The checkpoint's
"where did we leave off" sits **on top of** this "what is this project" layer.
One file (`.heimdall/context.json`), one role, no overlap with the save-state or
the task-compaction store.

## Integration boundary (F1, Wave-2)

This module is **standalone** — it is **not** wired into `bin/heimdall`'s launch
path here (that is F1's single-owner Wave-2 job, to avoid a launch-path collision
with a parallel agent). F1 will call `load <repo>` at orient time: fresh →
inject the cached capsule and skip re-derivation (the real token saving); stale/
missing/corrupt → `comprehend <repo>` to (re)derive, then inject. The
module-level acceptance here (derivation `count` stays put on a cached `load`,
advances on a stale re-derive) proves the load-not-rederive + staleness behavior
deterministically without the launch path.

## Acceptance (proven by `test/comprehension.test.sh`)

- (a) first `comprehend` writes a well-formed capsule (`jq -e .`) with every field + real derived values (count=1);
- (b) `load` on the unchanged repo = `loaded:cached` (exit 0), derivation counter stays at #1 (did **not** re-derive);
- (c) a new top-level module → `load` signals stale (exit 3) → re-derive (counter #1→#2, new module captured);
- (c2) a changed manifest (content hash) also invalidates → `load` signals stale;
- (d) a corrupt capsule → `load` exit 3 (no crash) → `comprehend` recovers a well-formed capsule;
- (e) a missing capsule → status `missing` + exit 3 (re-derive), no crash;
- (f) `HEIMDALL_HOME` relocates the capsule (no baked path).
