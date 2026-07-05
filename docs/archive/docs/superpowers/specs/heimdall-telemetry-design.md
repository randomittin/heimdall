# Heimdall — Telemetry & Reporting Layer — Design Dossier

Status: DESIGN (contract for parallel build-coders). READ-ONLY authored — no code shipped here.
Spec: `/Users/rj/Downloads/heimdall-telemetry-reporting-spec.md` (authoritative).
Builder commit identity: `rj@runheimdall.dev`. Agents NEVER push; `ship.sh` is RJ's.

This dossier pins: the ONE event schema, the ONE store interface, the EXACT write-points,
and a DISJOINT per-piece file layout so parallel coders never collide and never build
mismatched seams. The headline thesis: **Heimdall measures everything except itself; this
closes that loop — and holds Heimdall's OWN numbers to measured-not-asserted MOST of all.**

---

## 0. Seam-location result (bounded look, ≤6 calls — done)

| Seam the spec references | Located at | Reuse contract |
|---|---|---|
| Token meter (emit-at-source usage) | `bin/heimdall-tokens` | Emits `{input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, total_tokens, total_cost_usd, session_id, model, turns, [note], [error]}`. Parses `message.usage{...}` from `claude --output-format stream-json` AND `.usage + .total_cost_usd` single-shot. **NEVER invents a cost** — absent cost ⇒ `total_cost_usd: null` + `note`. Fail-open. REUSE verbatim; telemetry calls it, never re-parses claude JSON. |
| Issue-loop recording (generalize) | `bin/lib/issue_queue.py` (atomic JSON store, `.tmp`→`os.replace`, sorted keys, bucketed) + `bin/lib/issue_loop.py` (`run_once` state transitions, `_gate_and_finish`) | The atomic-store discipline + the per-transition state writes ARE the recording. Telemetry generalizes the store-write primitive; issue-loop becomes **consumer #1** by calling the general event API at each `set_state`/`flag`/`mark_resolved`. |
| Summary card (empty fields) | `bin/heimdall-demo` L501 (`# ── The run summary card`), L660-689 (renderer; `tokens — spent`, `Atomic commits`) | Renderer already degrades to `—` on missing data (L482, "honestly degrades"). Telemetry FILLS the empty fields from real events; renderer logic reused, data source swapped from the unfilled default to a telemetry query. |
| Install steps | `bin/heimdall` → `first_run_setup()` L419-451 (caveman L425-430, superpowers L432-437, claude-mem `npx claude-mem install` L440-445, marketplace L447-451) + PATH export L252-312 + `install.sh` | Each step wrapped with a telemetry emit. claude-mem step (L440-445) is the **swap-evidence target** — instrument at npm-exec granularity. |
| Holdout pattern (headroom) | Not located in ≤2 tries — **propose fresh** (§6) following the spec's "borrow headroom's holdout" intent: control-group flag + measured-vs-estimated + confidence band. |

---

## 1. General event surface + schema (PIECE a — the substrate)

### Storage decision: structured append-only NDJSON log, NOT SQLite. Justification:

- **Safe-by-construction for the secret gate.** NDJSON is line-oriented plaintext — `gitleaks detect` scans it natively with zero special handling, and a reviewer can `grep` it. A SQLite binary blob is OPAQUE to gitleaks (it would need a path-allowlist, which the fixture-secret convention explicitly calls a "code smell"). Plaintext keeps the gate fully armed on the telemetry store. **This is the decisive factor** given the security-critical constraint.
- **Append-only matches the issue-loop store discipline** (atomic write, no in-place mutation) and the fire-and-forget hot-path constraint: one `open(…, 'a')` + single `write()` of one line + `flush()` is the cheapest possible non-blocking write. No schema migration, no lock contention, no DB dependency on a clean install (MarkItDown stranger-test: absent SQLite driver must never break a run; stdlib `json` always exists).
- **Aggregation (piece d) is a streaming line-scan** — adequate at Heimdall's run volume (hundreds/thousands of events, not millions). If volume ever forces it, a compaction step to SQLite is a *separate* later spec; do NOT pre-optimize.

### Location & rotation

- Store dir: `${HEIMDALL_HOME:-<repo>/.heimdall}/telemetry/` (same home resolver as `issue_queue.heimdall_home()` — REUSE that function, do not re-derive).
- Event log: `events.ndjson` (one JSON object per line).
- Rotation: when `events.ndjson` exceeds 5 MB, rename to `events-<epoch>.ndjson` (atomic rename, cheap). Aggregation globs `events*.ndjson`.
- **Gitignore: `.heimdall/` is already gitignored** (issue_queue store lives there). Telemetry inherits this. Builder MUST assert `.heimdall/telemetry/` is covered by an existing `.gitignore` rule and add one if not — the store NEVER enters git history.

### The ONE event schema (pinned field types)

Every run + install + issue-loop transition writes events of this exact shape. Unknown-to-a-consumer fields are ignored, never rejected (forward-compatible).

```jsonc
{
  "schema_version": "1.0.0",          // string, semver
  "ts": "2026-06-23T08:00:00+00:00",  // string, ISO-8601 UTC, second precision
  "run_id": "run-<uuid4hex>",         // string; stable per hmd invocation / per install invocation
  "event_type": "install_step"        // string ENUM (see below) — REQUIRED
              | "phase" | "gate" | "token" | "outcome" | "commit" | "issue_state",
  "phase": "planning|waves|gates|install|null", // string|null — coarse lifecycle bucket
  "step": "setup|auth|companion:caveman|companion:claude-mem|skills|path|launch-readiness|null",
                                       // string|null — install step id (event_type=install_step only)
  "outcome": "started|succeeded|failed|passed|blocked|null", // string|null ENUM
  "gate": "secret-scan|oracle|lint|test|bloat|reuse|null",   // string|null — which gate fired
  "tokens": {                          // object|null — ONLY on event_type=token; copied VERBATIM
    "input_tokens": 0, "output_tokens": 0,                   // from bin/heimdall-tokens output.
    "cache_creation_tokens": 0, "cache_read_tokens": 0,      // ints
    "total_tokens": 0,
    "total_cost_usd": null,            // float|null — NEVER invented; null when source carries none
    "cost_source": "measured|null"     // string|null — provenance tag (see §6 honesty rule)
  },
  "duration_ms": 0,                    // int|null — wall-clock of the step/phase
  "commit": "abc1234|null",            // string|null — short SHA (event_type=commit only)
  "error": {                           // object|null — SHAPE only, NEVER a payload
    "class": "CalledProcessError",     // string — exception/error class name
    "step": "companion:claude-mem",    // string — where it occurred
    "detail": "npm exec exit 1"        // string — a SHAPE summary, NEVER stdout/stderr/secret/PII
  },
  "loc": "config.py:5|null",           // string|null — file:line a gate fired at (deny→fix→pass arc)
  "extra": {}                          // object — small bounded scalar tags ONLY; NEVER free payload
}
```

**Hard schema rule (security-critical):** the writer accepts ONLY the keys above. `tokens` is copied verbatim from `bin/heimdall-tokens` JSON (already secret-free metrics). `error.detail` and `extra` are bounded to short SHAPE strings/scalars — the API REJECTS (drops the field, logs nothing) any value over N chars or matching a secret-shaped pattern (§7). No field ever carries command stdout, env values, tokens, credentials, or PII. Secrets cannot enter **by construction**, not by scrubbing.

### The write API (the ONE interface every consumer calls)

`bin/lib/telemetry.py` — a pure-ish library (mirrors `issue_queue.py` shape). The single surface:

```python
# telemetry.py — the general event store. Fire-and-forget, never raises into the caller.
def emit(event_type, *, run_id=None, phase=None, step=None, outcome=None,
         gate=None, tokens=None, duration_ms=None, commit=None,
         error=None, loc=None, extra=None, home=None) -> bool
    """Append ONE schema-validated, secret-scrubbed event line to events.ndjson.
    Returns True on write, False on any drop (disabled / write-fail / validation-reject).
    NEVER raises — a telemetry failure must never fail a run or install (§8)."""

def new_run_id() -> str            # "run-<uuid4hex>"; one per hmd/install invocation
def enabled() -> bool              # False if HEIMDALL_TELEMETRY=off or opt-out marker present
def _scrub(value) -> str|None      # SHAPE-enforce + secret-pattern reject (§7); used internally
```

- `emit()` is the ONLY way to write. Consumers (b)(c) + issue-loop NEVER touch the file directly.
- `emit()` swallows ALL exceptions internally (disk full, perms, bad dir) → returns False, run continues.
- A bash wrapper `bin/heimdall-telemetry emit --type … --step … --outcome …` fronts the lib for `install.sh` (which is bash). House style = `bin/heimdall-redum`/`bin/heimdall-issue-loop` (thin bash CLI over a `bin/lib/*.py` engine). The wrapper ALSO never fails: `|| true` at every call site.

---

## 2. Generalize-issue-loop seam (issue-loop = consumer #1, ONE surface not two)

The issue-loop already records what it does via `issue_queue` state transitions. It becomes the
FIRST consumer of the general surface — it does NOT keep a parallel recording.

EXACT seam (piece a owns the edit so it stays file-disjoint from runtime instrumentation):

- `bin/lib/issue_loop.py::run_once` already calls `q.set_state(issue_id, ORIENTED|FIXED|ATTESTED|…)`
  and `q.flag(...)`. Add ONE call after each transition:
  `telemetry.emit("issue_state", run_id=loop_run_id, phase="waves", outcome=<state>, gate=<gate>, extra={"issue_id": issue_id})`.
- The gate verdict (`_gate_and_finish`, `read_verdict`) emits a `gate` event:
  `emit("gate", outcome="passed"|"blocked", gate="oracle"|…)` — reading the SAME recorded real exit
  the cardinal rule already reads (`record.evidence.all_passed`). No new verdict source.
- `issue_queue.py` is NOT modified for telemetry (keeps piece-a file scope to `issue_loop.py` + the new lib). The transition POINTS already exist; we only add emits at them.

Result: one event store. issue-loop, installs, and runs all write the same `events.ndjson` via
the same `telemetry.emit`. The loop's recording is now a special case of the general surface.

---

## 3. Install instrumentation (PIECE b)

Wrap each `first_run_setup()` step + `install.sh` step with `started`/`succeeded`/`failed` +
`error` + `duration_ms`. Steps and their EXACT fire-points:

| Step id | Fire-point | Emits |
|---|---|---|
| `setup` | `bin/heimdall:first_run_setup` entry (L419-423) | started → (succeeded at end ~L451) |
| `auth` | `bin/heimdall` auth/OAuth check (keychain check L352 region) | started/succeeded/failed |
| `companion:caveman` | L425-430 (`claude plugins install caveman`) | started→succeeded/failed + duration |
| `companion:claude-mem` | **L440-445** (`npx claude-mem install`) — instrument at npm-exec granularity | started→succeeded/failed + `error.detail="npm exec exit <code>"` |
| `skills` | superpowers + marketplace install (L432-437, L447-451) | started/succeeded/failed |
| `path` | PATH export write (`install.sh` append + `bin/heimdall` L252-312 region) | started/succeeded/failed |
| `launch-readiness` | end-of-setup readiness probe (post-marker write) | succeeded/failed |

**The claude-mem question (swap-evidence granularity):** the data must show WHERE installs fail —
`companion:claude-mem` (npm exec) vs `path` vs `auth`. The step ids above are deliberately
distinct so aggregate (piece d) can answer "is claude-mem's npm-exec the dominant failure point?"
with no ambiguity. **Do NOT swap claude-mem in this build** — instrument only; the swap is a later
evidence-based spec once the data exists.

Wiring: each step calls the bash wrapper `bin/heimdall-telemetry emit … || true`. Duration via a
`SECONDS`-delta or `date +%s%3N` bracket around the step. A telemetry failure NEVER aborts setup
(every call `|| true`; the wrapper itself is non-raising).

---

## 4. Per-run instrumentation (PIECE c — fills the summary card from REAL data)

Wire phase/gate/token/outcome/commit events into the orchestrator/launcher. Fire-points:

- **Phase events** — at planning→waves→gates boundaries in the orchestrator: `emit("phase", phase=…, outcome="started"/"succeeded", duration_ms=…)`.
- **Gate events** — each gate (secret-scan, oracle, lint, test, bloat, reuse) emits `emit("gate", gate=…, outcome="passed"|"failed"|"blocked", loc=<file:line>)`. The deny→fix→pass demo arc MUST produce: a `gate` event `{gate:"secret-scan", outcome:"blocked", loc:"config.py:5"}`, then a `phase` fix wave, then `{gate:"secret-scan", outcome:"passed"}` — a recorded blocked→fixed→passed sequence keyed by `run_id`.
- **Token event** — ONE per run: call `bin/heimdall-tokens` (REUSE), copy its JSON verbatim into `emit("token", tokens=<that object>, tokens.cost_source="measured")`. This fills `tokens — spent` on the card.
- **Outcome event** — task end: `emit("outcome", outcome="passed"|"failed", error=<shape|null>)`.
- **Commit events** — one per atomic commit the run produced (R7: one commit/task): `emit("commit", commit=<short SHA>)`. Count of these fills the card's `Atomic commits` field.

**Summary-card fill (the metering/launcher lesson — must be REAL, end-to-end, not unit-only):**
the renderer in `bin/heimdall-demo` (L660-689) currently degrades to `—`. Piece (c) adds a tiny
read path: query `events.ndjson` for this `run_id`, sum the `token` event's `total_tokens` →
`tokens — spent`; count `commit` events → `Atomic commits`. Renderer logic untouched; data source
swapped from the unfilled default to a telemetry query. The `vs raw-CC est.` slot is sourced ONLY
per §6 (measured/labeled/blank — NEVER invented).

---

## 5. `hmd report` aggregate surface (PIECE d)

`bin/heimdall-report` (bash CLI) over `bin/lib/report.py` (streaming line-scan of `events*.ndjson`).
House style = `bin/heimdall-redum`. Read-only; never writes events.

Views (query/view shapes):

- `hmd report run <run_id>` — **per-run detail**: timeline of that run's events (phases, gates fired/passed/blocked, tokens, commits, outcome). JSON + human table.
- `hmd report` (aggregate, default) — **trends across runs+installs**:
  - **gate-firing frequency** — count by `gate` × `outcome` (which gates earn their keep / never fire).
  - **failure patterns** — count by `error.class` × `step`/`gate`; top failing task types.
  - **token trends** — `total_tokens` + `cache_read_tokens` ratio over time (per run, rolling).
  - **install drop-off** — per `step`: `failed`/`started` ratio. The claude-mem evidence row.
- `hmd report --json` — structured output for downstream / CI.

Aggregation is pure: read lines → parse → group → reduce. Missing/partial events tolerated
(an absent `token` event ⇒ that run shows tokens `—`, never a fabricated number).

---

## 6. A/B-holdout + measured-vs-estimated (PIECE e) — HONESTY-CRITICAL

Borrow headroom's holdout pattern (proposed fresh; seam not located). Components:

- **Control-group flag** — `HEIMDALL_HOLDOUT=control` (or a config fraction `holdout.fraction`) marks a run as UNSHAPED control (companion/output-shaping OFF). Default runs are treated (shaped).
- `bin/heimdall-holdout` (CLI) over `bin/lib/holdout.py`: assigns a run to treated/control, tags the run's events `extra={"arm":"treated"|"control"}`, and computes the measured delta.
- **Measured delta** — over runs of the same workload, compare `total_tokens`/`total_cost_usd` of treated vs control arms; report the delta WITH a confidence band (n per arm, mean ± band). This is the ONLY way a "saved vs raw-CC" number becomes real.

**HARD RULE — NEVER fabricate a savings number.** The card's `vs raw-CC est.` is sourced by exactly one of:
1. **measured** — a holdout delta exists (≥ min n per arm) → render the measured value + band, tag `cost_source:"measured"`.
2. **estimated** — labeled explicitly `~est.` with the basis stated, tag `cost_source:"estimated"` → rendered with the `est.` label, never as a bare number.
3. **blank** — no baseline → render `—`. Honest absence.

The writer + renderer REFUSE a raw-CC number lacking a `cost_source` provenance tag. An untagged
savings number is a build defect, not a display choice. Measured-not-asserted applies to Heimdall's
OWN metrics MOST of all (the spec's core demand).

---

## 7. Privacy + no-secret-leak (security-critical — flag for security-auditor pass)

- Telemetry records event SHAPES + metrics ONLY. NEVER payloads, secret values, tokens, credentials, or PII.
- **Secrets cannot enter by construction:**
  - `emit()` accepts ONLY the pinned schema keys (§1). No free-form payload field exists to carry stdout/env.
  - `tokens` is copied verbatim from `bin/heimdall-tokens` — already pure numeric metrics, no values.
  - `error.detail` + `extra` pass through `_scrub()`: bounded length (≤120 chars), and REJECTED (field dropped) if it matches any gitleaks high-signal pattern (`ghp_[A-Za-z0-9]{36}`, `AKIA[0-9A-Z]{16}`, `sk_live_…`, PEM headers) or looks like a token/key=value with a long opaque RHS.
- **The gitleaks gate applies to the telemetry store.** `.heimdall/telemetry/events*.ndjson` is gitignored (never committed) AND must be gitleaks-clean if ever scanned. The store path is NEVER added to `.gitleaks.toml`'s `paths` allowlist (per `heimdall-fixture-secret-convention.md` — an allowlist entry for telemetry would be a code smell; the store must be clean, not exempted).
- **Test fixtures for piece (e)/(b)/(c) follow the runtime-assembly convention:** any test that proves the scrubber catches a secret-shaped value assembles the token at RUNTIME from non-matching fragments (the `test/selfscan.test.sh` pattern), so no static secret literal enters source/history and no fixture-path allowlist is needed.
- **Local-first; remote opt-in/off-by-default/disclosed.** Default: data stays on the user's machine. Any remote/anonymous telemetry is OFF by default, explicit opt-in, clearly disclosed. This build ships LOCAL-ONLY; remote is out of scope (§ Out of scope).
- **Security-auditor handoff:** the telemetry store + `_scrub()` get a dedicated `hmd:reviewer`/security pass asserting: no schema field can carry a payload; scrubber rejects every gitleaks pattern; store is gitleaks-clean; no allowlist entry added.

---

## 8. Graceful-degrade + clean-install (MarkItDown stranger-test)

- **Telemetry NEVER gates or blocks.** It observes. No run, no install, no gate decision ever depends on a telemetry read or write.
- **Write-failure degrades:** `emit()` swallows every exception → returns False → event dropped → run/install continues. The bash wrapper is `|| true` at every call site. A full disk, a bad perm, a missing dir: all silently drop the event, zero impact on the build.
- **Absent/disabled ⇒ identical:** `HEIMDALL_TELEMETRY=off` (or no telemetry lib present) ⇒ `enabled()` False ⇒ every `emit()` is a no-op returning False. Runs + installs behave IDENTICALLY to a no-telemetry world. Stranger-test green.
- **Negligible overhead / hot path:** each emit is one validate + one scrub + one `open('a')`+`write`+`flush` of one line. No DB, no lock, no network, no fork. Fire-and-forget. The token/aggregate reads happen at card-render / `hmd report` time — never in the build hot path.
- **Clean-install:** stdlib-only (`json`, `os`, `uuid`, `datetime`, `re`). No third-party dependency. Absent telemetry dir ⇒ created lazily on first emit (or skipped if creation fails).

---

## 9. EXACT FILE LAYOUT — DISJOINT per piece (parallel coders never share a file)

Sequence: **(a) FIRST** (genuine substrate dependency) → then **(b)(c) in parallel** → then **(d)(e) consume**.

### PIECE (a) — substrate (Wave 1, BLOCKING)
- CREATE `bin/lib/telemetry.py` — the event store engine + `emit()`/`new_run_id()`/`enabled()`/`_scrub()`.
- CREATE `bin/heimdall-telemetry` — bash wrapper CLI (`emit`/`status`) over the lib (house style: `bin/heimdall-redum`).
- CREATE `test/telemetry-store.test.sh` — schema validation, atomic append, scrubber, disabled-noop, write-fail-degrades.
- MODIFY `bin/lib/issue_loop.py` — add `telemetry.emit` at existing `set_state`/`flag`/`_gate_and_finish` points (consumer #1; §2). **Only file (a) touches issue_loop.py.**
- MODIFY `.gitignore` — assert `.heimdall/telemetry/` covered (add rule if absent).

### PIECE (b) — install instrumentation (Wave 2, parallel with c)
- MODIFY `bin/heimdall` — `first_run_setup()` L419-451 + auth + path regions: wrap each step with wrapper emits. **Only file (b) touches bin/heimdall.**
- MODIFY `install.sh` — wrap install.sh's own steps (PATH append, etc.) with wrapper emits. **Only file (b) touches install.sh.**
- CREATE `test/telemetry-install.test.sh` — sim-failure at a step recorded with step+error; disabled⇒identical install.

### PIECE (c) — per-run instrumentation + card fill (Wave 2, parallel with b)
- CREATE `bin/lib/run_telemetry.py` — orchestrator emit helpers (phase/gate/token/outcome/commit) + the card-fill query (`run_id` → tokens sum, commit count). Wraps `bin/heimdall-tokens` (REUSE).
- MODIFY `bin/heimdall-demo` — swap the card's `tokens`/`commits` data source from the unfilled default to a `run_telemetry` query (renderer logic at L660-689 untouched). **Only file (c) touches bin/heimdall-demo.**
- CREATE `test/telemetry-run.test.sh` — a run fills card tokens+commits from real telemetry; deny→fix→pass produces blocked→fixed→passed record.

### PIECE (d) — aggregate report (Wave 3, consumes a/b/c events)
- CREATE `bin/lib/report.py` — streaming aggregation (gate-freq, failure patterns, token trends, install drop-off, per-run detail).
- CREATE `bin/heimdall-report` — bash CLI (`run <id>` / aggregate / `--json`). **Only file (d) for the report surface.**
- CREATE `test/telemetry-report.test.sh` — per-run + aggregate views over multi-run fixture events.

### PIECE (e) — A/B holdout (Wave 3, consumes a/b/c events)
- CREATE `bin/lib/holdout.py` — arm assignment + measured-vs-estimated delta + confidence band + provenance tag.
- CREATE `bin/heimdall-holdout` — bash CLI (assign / report-delta). **Only file (e) for holdout.**
- CREATE `test/telemetry-holdout.test.sh` — measured delta with band; NO fabricated savings; untagged-number rejected; blank when no baseline.

No file appears under two pieces. `bin/heimdall` (b), `bin/heimdall-demo` (c), `issue_loop.py` (a) each have exactly one owner.

---

## 10. Reuse ledger + integration-gate plan

### Reuse ledger (REUSE vs NEW)

| Concern | REUSE (call, never rebuild) | NEW |
|---|---|---|
| Token metering | `bin/heimdall-tokens` (verbatim JSON, never-invent-cost contract) | — |
| Issue-loop recording | `bin/lib/issue_queue.py` atomic-store discipline + `issue_loop.py` transition points | `telemetry.emit` general surface |
| Home resolver | `issue_queue.heimdall_home()` | — |
| Summary-card renderer | `bin/heimdall-demo` L660-689 (degrade-to-`—` logic) | card-fill query |
| Holdout pattern | headroom's holdout (intent; seam not located → proposed fresh §6) | `bin/lib/holdout.py` |
| Secret discipline | `.gitleaks.toml` + `heimdall-fixture-secret-convention.md` (runtime-assembly fixtures) | `_scrub()` |
| CLI house style | `bin/heimdall-redum`/`bin/heimdall-issue-loop` (bash wrapper over `bin/lib/*.py`) | the 5 new CLIs |

### Spec Acceptance/Harness bullet → concrete test assertion

| Spec bullet | Assertion (runnable) | Owner test |
|---|---|---|
| Install steps emit events; sim-failure captured with step+error | force `npx claude-mem install` to exit 1; assert an `install_step` event `{step:"companion:claude-mem", outcome:"failed", error.detail~="npm exec exit 1"}` in `events.ndjson` | `test/telemetry-install.test.sh` |
| A run fills card tokens+commits from REAL telemetry | run produces `token`+`commit` events; assert card renders summed `total_tokens` + commit count, NOT `—`, NOT the unfilled default | `test/telemetry-run.test.sh` |
| deny→fix→pass produces blocked→fixed→passed record | assert ordered events for one `run_id`: `gate{secret-scan,blocked,loc}` → fix `phase` → `gate{secret-scan,passed}` | `test/telemetry-run.test.sh` |
| `hmd report` per-run + aggregate | over a ≥3-run fixture, assert per-run detail AND aggregate (gate-freq, failure patterns, token trend, install drop-off) all render | `test/telemetry-report.test.sh` |
| A/B holdout measured-vs-estimated, NO fabricated savings | assert measured delta has a confidence band; assert an untagged raw-CC number is REJECTED; assert blank when no baseline | `test/telemetry-holdout.test.sh` |
| Telemetry store gitleaks-clean | `gitleaks detect` over `.heimdall/telemetry/` (with a scrubber-rejected planted attempt) finds ZERO; assert store path NOT in `.gitleaks.toml` allowlist | `test/telemetry-store.test.sh` |
| Disabled ⇒ runs+installs identical + stranger-test green | `HEIMDALL_TELEMETRY=off`: assert run + install output byte-identical to baseline; no `events.ndjson` written | `test/telemetry-store.test.sh` + `test/telemetry-install.test.sh` |
| Write-failure degrades gracefully | make telemetry dir unwritable; assert run+install exit 0 and continue, event dropped | `test/telemetry-store.test.sh` |

### Integration gate (drives a REAL end-to-end run — the metering/launcher lesson)

The completion gate is NOT unit-only. It runs a REAL `hmd` task (the demo's deny→fix→pass arc)
end-to-end and asserts:
1. The run-summary card renders **real** `tokens — spent` (from a `token` event) and **real** `Atomic commits` count (from `commit` events) — NOT `—`, NOT the unfilled default.
2. `events.ndjson` contains the blocked→fixed→passed `secret-scan` sequence keyed to that run's `run_id`.
3. `hmd report run <run_id>` renders that run's timeline; `hmd report` aggregate includes it.
4. `gitleaks detect` over the produced `.heimdall/telemetry/` is clean.
5. Re-running with `HEIMDALL_TELEMETRY=off` produces a byte-identical build with NO telemetry store.

Commit-early in worktrees; report merges before further waves. Builders commit as
`rj@runheimdall.dev`; agents NEVER push; no tags (ship.sh is RJ's).

---

## OUT OF SCOPE

- **The claude-mem/caveman → headroom swap.** This build INSTRUMENTS where installs fail; the swap is a separate, later, evidence-based spec once the data exists. Do NOT swap any companion here.
- **Remote/anonymous telemetry transport.** This build ships LOCAL-ONLY. Off-by-default opt-in remote is a separate spec; the schema is forward-compatible for it but no transport is built.
- **SQLite/compaction backend.** NDJSON is the store. A compaction-to-SQLite step is a future spec only if event volume forces it.
- **Headroom companion itself / output-shaping engine.** Piece (e) measures a holdout delta; it does NOT build or modify any shaping/companion engine.
- **The "75% saved" marketing headline.** This build makes such a number *measurable* (holdout); it does not assert one.
- **Performance tuning beyond the negligible-overhead constraint** (single append per emit). No batching/buffering layer.
- **Backfilling telemetry for historical runs.** Telemetry starts recording at install/run time forward; no retroactive event generation.
- **Modifying `bin/heimdall-tokens`, `issue_queue.py`, or `.gitleaks.toml` rules.** Reused as-is (issue_loop.py gets emit calls; gitleaks gets NO new allowlist entry).

---

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| A secret value enters the store despite scrubbing (the headline risk) | med | high | Schema has NO free payload field (secrets can't enter by construction); `_scrub()` rejects every gitleaks high-signal pattern + bounds length; gitleaks gate on the store; dedicated security-auditor pass; fixtures use runtime-assembly | piece (a) + security pass |
| A fabricated "vs raw-CC" savings number ships | med | high | Provenance tag (`cost_source`) REQUIRED; writer+renderer refuse an untagged raw-CC number; only measured(holdout)/labeled-est./blank permitted | piece (e) |
| Telemetry write blocks/fails a run or install | low | high | `emit()` swallows all exceptions → False; bash wrapper `\|\| true` every call; disabled⇒no-op; write-fail test asserts run/install continues | piece (a)+(b)+(c) |
| Two coders collide on `bin/heimdall` / `bin/heimdall-demo` / `issue_loop.py` | low | med | Strict single-owner file map (§9): (b) owns bin/heimdall+install.sh, (c) owns heimdall-demo, (a) owns issue_loop.py; no overlap | architecture (this dossier) |
| Card "filled" in a unit test but `—` in a real run (the metering lesson) | med | high | Integration gate drives a REAL end-to-end deny→fix→pass run asserting real tokens+commits on the card, not unit-only | integration gate |
| claude-mem failure granularity too coarse to answer the swap question | med | med | Distinct `step` ids (`companion:claude-mem` at npm-exec granularity, separate from `auth`/`path`); aggregate drop-off keyed per step | piece (b)+(d) |
| `.heimdall/telemetry/` accidentally committed | low | med | Assert `.heimdall/` gitignore coverage in piece (a); store-path NEVER added to gitleaks allowlist | piece (a) |
