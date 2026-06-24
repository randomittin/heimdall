# Verified Memory — Design Dossier (git-as-ground-truth code memory)

**Status:** HYPOTHESIS until measured. The deliverable is a NUMBER, not a feature. A null
result (git-verification does not beat the drift-detector baseline) is a valid, publishable
finding and MUST be reported, not buried. Honesty discipline is carried verbatim from
`bin/lib/holdout.py`: **measured-or-labeled-estimated-or-blank, never a fabricated delta.**

**Source of truth (read fully before building):** `/Users/rj/Downloads/verified-memory-research-context.md`.
This dossier is the contract; the spec is authoritative where they ever diverge.

**One-sentence claim (the only part worth a paper):** code memory is the special case of agent
memory where ground truth exists (the repository), so staleness and conflict become *decidable
by verification against git* rather than *estimated by decay / voting / LLM-judge* — an
asymmetry the general agent-memory field cannot exploit. That asymmetry is the contribution.
Everything else (tiering, weighting, routing, human-in-the-loop) is known prior art and is NOT
claimed.

---

## §1 THE HONEST ARCHITECTURE — three layers, and why the naive version is killed first

The originating design routed staleness + conflict + team-divergence through a **weighted-memory
mechanism** (entries carry weights; high-relevance loaded, low-relevance floats in at low value;
weights adjusted on change; human intervenes on drastic shifts — Postgres 8→0.5 when MySQL
enters at 9.5, then MySQL→0.5 when NoSQL enters at 9.25). **We do NOT build that.** We build its
correction, and we state openly why the naive version fails — reviewers reward a paper that kills
the naive form of its own idea.

**Why weighted-memory-alone fails (state this in the paper, do not bury it):** *a weight is
downstream of truth, not a source of it.* The weight only moves correctly because a human (or a
gate) *decided* MySQL was displaced. The weight itself has no knowledge of whether MySQL is still
in the codebase — it is a stored opinion that decays on a schedule unrelated to ground truth. In
the 8-dev team case where 3 devs still run MySQL, the decayed weight confidently records a
falsehood = the exact staleness failure it was meant to fix. **Weighting solves retrieval-ranking
(legitimate, useful); it does NOT solve staleness or conflict — those require the weight to be
*derived from a git check*, not assigned-and-decayed.**

The three honest layers:

| Layer | Role | Mechanism | What it is NOT |
|---|---|---|---|
| **git = TRUTH** | decide live/gone | a mechanical check: does `commit_ref` exist, do the `file/symbol` refs still match the claim? (`git cat-file -e`, `git rev-parse --verify`, symbol presence at the named path) | not a vote, not an LLM opinion, not a decay timer |
| **weight = READOUT** | rank the *true* survivors for bounded context | a **function of the git-check result**, recomputed at read, never a stored number that rots. A `stale` entry's weight is 0 *because git says so*, not because time passed | not a stored opinion; not a confidence the human typed |
| **human = ESCALATION** | resolve genuine judgment git cannot answer | the *only* case humans enter: "are we *intentionally* deprecating MySQL, or did someone just not migrate yet?" — a decision, not a fact. Status `conflicted` routes here | not a fact-supplier; humans never set a weight directly |

The research question, stated exactly: **does grounding memory weight/validity in git
verification measurably reduce stale-retrieval and conflict errors versus (a) decay-based,
(b) LLM-judge contradiction-detection, (c) Codified-Context-style drift-detection — and is the
gain large enough to matter?**

---

## §2 STALENESS-BY-VERIFICATION — entry schema + the mechanical check

A memory entry about code is a **checkable claim** (exactly the shape of an SI-2 attestation in
`bin/lib/attestation.py` — a claim with contracts + evidence). Verification runs **at write AND
at read time. Read-time re-verification is the load-bearing novelty** — staleness bites at
*retrieval*, months after write, so the check must run when the entry is fetched, not only when
it is stored.

### Entry schema (`MemoryEntry`)

```jsonc
{
  "id": "vm-<uuid4hex>",
  "claim": "capability F4 (mandatory-option machinery) shipped, touches bin/lib/redum.py",
  "commit_ref": "6b32662",                    // the commit the claim asserts shipped at
  "refs": [                                    // the file/symbol refs the claim depends on
    {"path": "bin/lib/redum.py", "symbol": "factor_for_task", "kind": "function"},
    {"path": "bin/lib/redum.py", "symbol": "gate_attestation", "kind": "function"}
  ],
  "weight": 0.0,                               // READOUT of the git check, recomputed each read
  "verified_at": "2026-06-24T05:10:00+00:00",  // ISO, when status was last computed (UTC, sec-precision — telemetry._now_iso)
  "status": "live",                            // live | stale | conflicted   (see check below)
  "provenance": "measured",                    // measured | estimated | null  (holdout.py discipline — never fabricate)
  "schema_version": "vm-1.0"
}
```

The store is **append-only NDJSON** at `${HEIMDALL_HOME:-<repo>/.heimdall}/memory/entries.ndjson`
(reuse `issue_queue.heimdall_home()` — never re-derive the home). NDJSON (not SQLite) so
`gitleaks detect` scans it natively as plaintext and the secret gate stays armed without a
path-allowlist — the exact rationale telemetry.py pins. The `claim` string passes the same
`_scrub`-style shape gate (bounded length, reject gitleaks high-signal patterns / `key=opaque`)
so a credential cannot enter the memory store by construction.

### The mechanical check — `verify(entry, repo) -> status`

Pure function of `(entry, git state)`, deterministic, cheap enough to run at read time:

1. **commit exists?** `git -C <repo> cat-file -e <commit_ref>^{commit}` → exit 0. (Reuse the
   `subprocess.run(["git","-C",repo,...])` extraction shape already in `bin/heimdall-attest`
   line 252.) Missing/orphaned commit → `stale`.
2. **refs still match?** for each `{path, symbol}`: the path exists at HEAD AND the symbol is
   still declared there (reuse `reuse_analyzer.extract_units` / `treesitter_ast` — the SAME
   AST substrate SI-2 uses, never a re-parse). Path gone OR symbol absent → the claim no longer
   matches git → `stale`.
3. **all refs present + commit live** → `live`; compute `weight` = relevance-readout (see §1)
   over the surviving entries.
4. **two live entries assert contradictory claims about the same ref** (e.g. "MySQL is the
   datastore" vs "NoSQL is the datastore", both pointing at a live `db/config` symbol whose
   current content matches neither, or matches one) → `conflicted` → §3.

`verify` NEVER raises (graceful-degrade, telemetry/attestation discipline): a git failure or an
unparseable file degrades the entry to an honest `stale` (re-derive/escalate), never a crash and
never a silent `live`. **Default-to-stale on uncertainty** — a falsely-live entry is the failure
mode we are eliminating.

---

## §3 CONFLICT RESOLUTION BY GROUND TRUTH — reconcile to git

When entries disagree (or, in a team, multiple humans disagree), **git wins. Entries are claims;
git is truth.** General memory cannot do this (no referent); code can. The reconcile procedure:

1. **Collect** all entries whose `refs` intersect on a shared `{path, symbol}`.
2. **Verify each against git** (§2). Partition into `live` / `stale`.
3. **All-but-one stale → auto-resolve:** the single `live` entry wins; the stale ones are marked
   `stale` and demoted (weight→0). No human needed — git decided. This is the common case (the
   Postgres→MySQL→NoSQL chain: at the NoSQL commit, the Postgres and MySQL entries are both
   provably stale against the live `db/` symbols).
4. **Multiple live + mutually contradictory claims** (git matches none cleanly, or the diff is a
   genuine partial migration where 3 devs still run MySQL) → `conflicted` → **escalate to human**
   with the git evidence attached (the refs, the commits, what HEAD actually shows). The human
   answers the *judgment* question ("intentional deprecation vs not-yet-migrated"), NOT a fact.
   Their decision is recorded as a new entry with its own `commit_ref` so it too is later
   re-verifiable. **Humans never override git on a fact — only on intent.**

---

## §4 THE BENCHMARK + METRICS — the paper IS the number

### Metrics (the deliverables)

- **stale-retrieval error rate** — fraction of retrievals where the agent acts on an entry that
  no longer matches git (a `stale` entry served as `live`). Lower is better. THE headline number.
- **conflict-resolution accuracy** — fraction of conflict cases resolved to the git-true outcome
  (vs the wrong survivor, or an unnecessary/missed escalation).

### Baselines (compare verified-memory against all three)

- **(a) decay-based** — weight decays on age/access; no git check. The naive version §1 kills.
- **(b) LLM-judge contradiction-detection** — an LLM decides if a new entry contradicts an old
  one (positions against mem0-style + the "LLM-judge" family). Confabulates; unverifiable.
- **(c) Codified-Context-style drift-detector** (arXiv 2602.20478) — the **closest prior art**
  and the one to beat/extend *measurably*. Their drift detector flags spec-vs-code divergence;
  we must show git-grounded verification does it **better, with numbers**, or honestly report it
  does not.

### Fixtures (STALE-style Type-I / Type-II harness + the clean code fixture)

Use the STALE benchmark framing (arXiv 2605.06527): **Type-I = direct contradiction**, **Type-II
= indirect dependency-chain** staleness. The clean code fixture is the **Postgres → MySQL → NoSQL
migration**, defined concretely as a 3-commit synthetic repo under `test/fixtures/verified-memory/`:

- `commit P` — a `db/store.py` implementing a Postgres adapter (symbol `PostgresStore`). Write
  entry E1: *"datastore is Postgres, touches db/store.py:PostgresStore @ P"*. At P, E1 is `live`.
- `commit M` — replaces it with `MySQLStore`. **Type-I:** E1's ref symbol `PostgresStore` is gone
  → git proves E1 `stale`. Write E2 (*MySQL @ M*) → `live`.
- `commit N` — replaces it with `NoSQLStore`; a downstream `services/orders.py` still imports the
  old store name in one path. **Type-II:** E2 is directly stale; an entry about `orders.py` that
  *depends on* the datastore is indirectly stale via the chain. NoSQL entry E3 → `live`.
- **Team-divergence variant:** a branch where 3 of 8 devs still run MySQL → the MySQL entry is
  not cleanly stale → `conflicted` → human-escalation path exercised (§3 step 4).

Each fixture case is labeled with its git-true status so every baseline is scored against the
same ground truth.

### Honesty rule (carried from holdout.py — non-negotiable)

The reported delta is sourced by EXACTLY one provenance: **measured** (a real benchmark run with
≥ min-n cases per arm) → bare number + confidence band; **estimated** → labeled `est.` with the
basis stated, never bare; **blank** → `—`. `require_measured()`-style structural refusal: an
untagged comparison number is a build defect, not a display choice. **No fabricated X/Y deltas.**

---

## §5 DIFFERENTIATION — one paragraph each (so it is not "known")

- **Codified Context (arXiv 2602.20478, closest prior art):** they ship a *drift detector* over
  283 sessions / 108K-line C#; they already proposed "extend with semantic diff to detect when
  spec contradicts changed code." We make that hard and measured: their drift detector *estimates*
  divergence; ours *decides* it by re-checking each claim's refs against the live AST at retrieval
  time. We beat/extend it on the same axis — the benchmark must show a measurable win or honestly
  report parity/loss.
- **SSGM (arXiv 2603.11768):** formalizes the stability-plasticity conflict (reject-too-much =
  ossification, accept-too-much = drift; "distinguishing drift from update is an open algorithmic
  challenge"). We adopt their framing but resolve the conflict *for code* by ground truth: git
  decides drift-vs-update, removing the open algorithmic guess they leave open.
- **mem0 (State-of-2026):** names "staleness in high-relevance entries" as a harder, open problem
  (decay handles low-relevance only). We attack exactly that gap: high-relevance entries are where
  a false-live hurts most, and git verification re-checks them at read regardless of relevance —
  relevance never shields a stale entry.
- **Claude Code's own memory (leaked v2.1.88 prompt: "treat memory as a hint, not a fact — verify
  against real code before acting"; docs: CLAUDE.md is "context, not enforced configuration"):**
  this is the closest *statement* of the thesis. We extend it from an informal soft prompt into a
  hard, mechanical, *measured* verification system and quantify the gain. They say verify; we make
  verify a gate and put a number on it.

---

## §6 EXACT DISJOINT FILE LAYOUT — parallel coders never share a file

Mirrors house style: thin `bin/heimdall-*` bash CLI over a `bin/lib/*.py` engine; `.bash` test
under `test/*.test.sh`; fixtures under `test/fixtures/`. **Every build piece below owns disjoint
files** — no two same-wave pieces write the same path.

| Piece | Owns (CREATE) | Reuses (READ-ONLY import) | Wave |
|---|---|---|---|
| **A — git-check engine** | `bin/lib/vm_gitcheck.py` | `reuse_analyzer`, `treesitter_ast`, subprocess-git shape from `bin/heimdall-attest:252` | 1 |
| **B — verified-memory lib + CLI** | `bin/lib/verified_memory.py`, `bin/heimdall-memory` | `issue_queue.heimdall_home`, `telemetry._scrub`-style gate, `vm_gitcheck` (A) | 2 (after A) |
| **C — benchmark harness + baselines + fixtures** | `bin/lib/vm_bench.py`, `test/fixtures/verified-memory/` (the 3-commit Postgres→MySQL→NoSQL repo + labels), `bin/heimdall-vm-bench` | `holdout` (measured/estimated/blank), `verified_memory` (B) | 3 (after B) |
| **D — SI-1 read-path integration** | `bin/lib/vm_readpath.py` (the seam wiring verify-on-read into orientation) + a new `verify`/`recall` subcommand block ADDED to `bin/heimdall-comprehend` | `comprehension.load_status`, `verified_memory` (B) | 3 (after B) |
| **E — integration gate test** | `test/verified-memory-integration.test.sh` | all of the above via their CLIs | 4 (after C+D) |
| **F — unit tests (one per engine, disjoint files)** | `test/vm-gitcheck.test.sh`, `test/vm-memory.test.sh`, `test/vm-bench.test.sh` | respective engines | 2–3 (alongside) |

**Dependency / sequence:** A → B → {C, D in parallel, disjoint} → E. C and D both depend on B but
touch disjoint files (`vm_bench.py` + fixtures vs `vm_readpath.py` + the comprehend CLI block), so
they run in the same wave. **The one shared-file caution:** D appends a subcommand block to the
existing `bin/heimdall-comprehend`; no other piece may touch that file — D owns it exclusively in
its wave.

---

## §7 REUSE LEDGER + INTEGRATION-GATE PLAN

### Reuse ledger (reuse, do not rebuild)

| Need | Reuse (existing) | Why not rebuild |
|---|---|---|
| git extraction / verify-from-git (R7) | `bin/heimdall-attest:252` `subprocess.run(["git","-C",repo,...])` shape | proven git-shell pattern; SI-2 already verifies-from-git not agent-reports |
| claim-as-checkable-record shape | `bin/lib/attestation.py` `build_record` ({claims, contracts, evidence}) | a MemoryEntry IS an attestation-shaped claim; mirror SI-2, don't invent |
| AST symbol presence check | `bin/lib/reuse_analyzer.py` + `treesitter_ast.py` | the symbol-resolution substrate SI-2/redum already use; one engine |
| runtime home + NDJSON store | `issue_queue.heimdall_home()`, telemetry NDJSON+rotation pattern | gitleaks-native plaintext store, gitignored, no path-allowlist |
| no-secret-by-construction | `telemetry._scrub` / `_SECRET_PATTERNS` / `_ASSIGNED_OPAQUE` | claim strings pass the same shape gate → store stays gitleaks-clean |
| measured/estimated/blank honesty | `bin/lib/holdout.py` `savings_figure` / `require_measured` / `render_figure` | the benchmark delta obeys the SAME structural refusal — never fabricate |
| SI-1 orientation read path | `comprehension.load_status` + `bin/heimdall-comprehend` | memory is a *consumer* of orientation; wire verify-on-read into the existing capsule load, no parallel store |

### Integration gate (drives a REAL end-to-end flow)

`test/verified-memory-integration.test.sh` exercises the full arc against the live fixture repo:

1. **write** an entry E (`heimdall-memory write` → claim about `db/store.py:PostgresStore @ P`),
   verified `live` at write.
2. **mutate git** so the claim goes stale — advance the fixture to `commit M` (`PostgresStore` →
   `MySQLStore`), a real git operation, not a flag flip.
3. **read** E back through the SI-1 read path (`heimdall-comprehend recall` / `heimdall-memory
   read`).
4. **assert** E is detected `stale` (NOT retrieved as `live`) — the git ref `PostgresStore` is
   gone, so verify-on-read returns `stale`, weight 0.
5. **reconcile** to git (§3): the live MySQL entry wins; assert `stale-retrieval error = 0` on
   this case. For the team-divergence variant, assert the case routes to `conflicted` →
   escalation, not a silent wrong-survivor.

### Spec-acceptance → concrete test assertion map

| Spec acceptance (from research context) | Concrete assertion |
|---|---|
| memory verified at write AND read | integration test step 1 (write→live) AND step 3–4 (read→stale after mutation) both assert via CLI exit + JSON `status` field |
| read-time re-verification catches staleness | `grep -q '"status":"stale"'` on `heimdall-memory read` output AFTER the git mutation, with NO re-write between |
| conflicts reconcile to git | `vm-memory.test.sh`: 2 entries on a shared ref, one stale → assert live one wins, `vm reconcile` JSON shows git-decided verdict |
| team-divergence → human escalation | integration team-variant: `grep -q '"status":"conflicted"'` AND assert an escalation record emitted, no auto-resolve |
| benchmark reports measured-or-blank, never fabricated | `vm-bench.test.sh`: with <min-n cases, `grep -q '"provenance":null'` / rendered `—`; never a bare number (mirror `require_measured`) |
| stale-retrieval error rate computed over fixtures | `heimdall-vm-bench` over `test/fixtures/verified-memory/` prints the rate per arm (verified vs a/b/c baselines) as labeled JSON |
| no-secret on the store | `bin/secret-scan` / `gitleaks detect` over `.heimdall/memory/entries.ndjson` exits clean; a planted `ghp_…`-shaped claim is `_scrub`-rejected at write |

**No-secret discipline:** the memory store is gitignored runtime NDJSON; every `claim` string
passes the telemetry `_scrub` shape gate at write (reject >120 chars, gitleaks high-signal
patterns, `key=opaque-RHS`); the integration test asserts a planted secret-shaped claim is dropped
and `gitleaks detect` over the store exits clean.

---

## OUT OF SCOPE

- General (non-code) agent memory — user preferences, facts, identity. The asymmetry is *code has
  ground truth*; we do not claim anything about memory without a git referent.
- Tiering / hot-cold swapping / domain-routing — known prior art (MemGPT/Letta, MemoryOS,
  Codified Context). Not claimed, not built.
- The weighting/decay mechanism as a *staleness or conflict* solver — explicitly killed (§1).
  Weight is built ONLY as a relevance readout of the git check.
- Cross-session identity, temporal abstraction at scale (mem0 open problems beyond high-relevance
  staleness).
- Performance tuning of the git-check beyond "cheap enough to run at read time" (a risk, §Risks,
  not a perf-optimization deliverable).
- Production rollout / multi-repo deployment of verified memory — separate plan.
- LLM-based semantic claim extraction — claims are AST/git-checkable refs, deterministic, not
  LLM-derived (mirrors comprehension.py's "honest deterministic derivation, NOT an LLM call").
- Writing the paper. This dossier builds the mechanism + benchmark and produces the number; the
  paper is downstream and only exists if the delta is real.

---

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation | Owner-piece |
|---|---|---|---|---|
| read-time git-check too slow to run on every retrieval | med | high | cache the verify result keyed by `commit_ref + HEAD sha` (invalidate when HEAD moves, like comprehension's fingerprint); fall back to `stale` on timeout, never block | A (`vm_gitcheck`) |
| no measurable delta vs the Codified-Context drift-detector (null result) | med | high | report it honestly (holdout discipline) — a null is a valid finding; ensure baselines (a)(b)(c) are implemented fairly so the comparison is real, not a strawman | C (`vm_bench`) |
| symbol-presence check is brittle (rename ≠ deletion) → false `stale` | med | med | use the AST unit extractor + dedup `near()` matching (reuse redum/dedup), so a renamed-but-present capability is not flagged gone; default-to-stale only when genuinely absent | A (`vm_gitcheck`) |
| team-divergence path can't be decided by git alone | med | med | that is BY DESIGN the `conflicted`→human-escalation case (§3 step 4); assert it escalates, never auto-resolves wrong | B / E |
| secret leaks into the claim store | low | high | `_scrub` shape gate at write (reuse telemetry patterns) + `gitleaks detect` in the integration test | B / E |
| fixture not representative → inflated delta | med | med | fixtures are git-true-labeled Type-I/II per STALE; score every arm against the same labels; keep the migration fixture synthetic-but-realistic | C |
