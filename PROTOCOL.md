# Heimdall Token-Frugal Protocol — v2.0.0

**Spec:** heimdall-core-spec §H-4 · **Status:** build-ready · **Supersedes:** 2D

The protocol that cuts main↔spawn token traffic to near zero by **compression
through reference, never obscurity**. Every message is human-readable; the full
trail lives in `.planning/protocol.log`. There is no encryption and there are no
opaque codes — auditability is the trust story. The savings are a **measured,
screenshotable number** (the token ledger), reported separately from caveman's
75%.

This document is a first-class, semantically versioned artifact. The version
above (`2.0.0`) is stamped into every state file (`symbols.json`,
`blackboard.json`, `baselines.json`) and into the message schema's `$id`. Bump
**major** on a breaking message-shape change, **minor** on an additive field or
mechanism, **patch** on a fix that preserves the wire format.

---

## Why

A v1 ("verbatim") orchestrator restates the plan, the acceptance criteria, and
prior-wave context into every spawn brief. Three spawns in a wave → the plan is
paid for three times; ten waves → thirty times. That is the orchestration token
tax this protocol exists to kill. The fix is six stacked mechanisms, each of
which replaces restated bytes with an **ID reference** that resolves to the same
human-readable content on demand.

| # | Mechanism        | Bin                   | What it removes from the wire                          |
|---|------------------|-----------------------|--------------------------------------------------------|
| 1 | Typed messages   | `heimdall-validate`   | Free-form prose; every message is a validated shape referencing artifacts by ID. |
| 2 | Symbol table     | `heimdall-resolve`    | Repeated file paths / criteria / invariants → short IDs. |
| 3 | Context capsules | `heimdall-capsule`    | Re-explained prior work → a ≤10-line capsule, hydrated only when referenced. |
| 4 | Delta briefs     | `heimdall-brief`      | The whole plan + restated criteria in a spawn brief.   |
| 5 | Blackboard       | `heimdall-blackboard` | Re-discovered facts (ports, versions, env quirks).     |
| 6 | Token ledger     | `heimdall-ledger`     | The unmeasured savings claim — replaced by a real number. |

The umbrella `heimdall-protocol` dispatches to all of the above and adds
`init`, `log`, and a measured `demo`.

---

## Layout (created by `heimdall-protocol init`)

```
.planning/
├─ protocol.log              # human-readable, append-only audit trail (tab-separated)
├─ blackboard.json           # mechanism 5: shared key→value facts
└─ protocol/
   ├─ symbols.json           # mechanism 2: id→artifact table
   ├─ message-schema.json    # mechanism 1: the published message contract
   ├─ baselines.json         # mechanism 6: v1 baselines to beat
   ├─ ledger.jsonl           # mechanism 6: one JSON token-cost line per message/spawn
   └─ capsules/{id}.md       # mechanism 3: ≤10-line context capsules
```

`HEIMDALL_PLANNING_DIR` overrides the `.planning` root (used by the test suite to
run against an isolated fixture tree). Every bin requires `jq`; absence is a hard
exit 2. macOS bash 3.2 compatible.

---

## 1 — Typed messages with ID references

Six message types, discriminated by `type`. Each references artifacts by ID and
never restates their bodies. The contract is `bin/protocol/message-schema.json`
(JSON-Schema draft-07); it is enforced by `bin/protocol/validate.jq`, kept in
lockstep with the schema (jq has no built-in schema engine and we do not assume
`ajv`/`python` are installed, so the constraints are re-stated in jq).

| `type`        | required (beyond `type`,`from`,`msg_id`) | references |
|---------------|------------------------------------------|------------|
| `task_claim`  | `task`                                   | `symbols[]`, `capsules[]` |
| `task_result` | `task`, `status∈{pass,fail,partial}`     | `criteria[]` (int IDs), `commit`, `capsule` |
| `gate_report` | `gate_id`, `status∈{pass,fail}`          | `report_ref` (path, not body) |
| `escalation`  | `reason`, `severity∈{blocker,warning,info}` | `refs[]` |
| `question`    | `question`                               | `refs[]` |
| `checkpoint`  | `wave`, `state∈{started,in_progress,complete,blocked}` | `capsules[]` |

```bash
echo '{"type":"task_result","from":"coder","msg_id":"m1","task":"3.2","status":"pass","criteria":[1,2],"commit":"a2ef507"}' \
  | heimdall-validate            # → {"valid":true,"errors":[]}, exit 0
```

**Validate-on-receipt** (`heimdall-validate --on-receipt`, reads one message per
stdin line): a malformed/invalid message gets **one** retry (the next line); a
second failure **escalates** (logs to `protocol.log`, exits nonzero). This is the
spec's "malformed → one retry → escalate" rule.

## 2 — Symbol table

Plan-time `symbols.json` assigns short IDs to recurring artifacts. Written once,
referenced thousands of times — the table *is* the compression. Human-readable
both directions.

```bash
heimdall-resolve set F12 "src/matching/engine.ts"
heimdall-resolve set C3  "balances sum to zero"
heimdall-resolve F12                       # → src/matching/engine.ts
heimdall-resolve C3                        # → balances sum to zero
heimdall-resolve --reverse "src/matching/engine.ts"   # → F12
heimdall-resolve list                      # → id<TAB>value for the whole table
```

## 3 — Context capsules

Every completed task/wave compacts to a **≤10-line** capsule (`what`, `where`,
`decision`, `gotcha`, plus a `depends` line). The cap is enforced — a capsule
that would exceed 10 lines is rejected, forcing real compaction.

Hydration emits **only the transitive `depends` closure** of the referenced
capsules — the orchestrator computes the dependency set; nothing else enters
context. This is the context-decay fix and the token fix in one mechanism.

```bash
heimdall-capsule write w1 --what "added LOB engine" --where F12 --gotcha "seed must be fixed"
heimdall-capsule write w2 --what "added book diff"  --where F13 --depends w1
heimdall-capsule write w3 --what "unrelated docs"   --where README
heimdall-capsule hydrate w2     # emits w1 then w2 — NOT w3 (not a dependency)
heimdall-capsule deps w2        # → the closure ids only
```

## 4 — Delta briefs

A spawned agent's brief = task spec + the referenced symbol entries + the
hydrated capsule closure + an invariants ref. **Never** the plan, prior
conversation, or restated criteria.

```bash
heimdall-brief build --task 3.2 --spec "implement book diff" \
  --symbols F12,C3 --capsules w2 --invariants 'CLAUDE.md#code-quality--zero-tolerance'
```

The brief resolves only the few symbols the task names and hydrates only the
referenced capsules' closure — a planted `PLAN-*.md` body never appears in it.

Every ref is checked, and an unchecked ref is never emitted as if it were fine.
An unresolvable symbol, file, capsule or invariants ref marks the whole brief
`INCOMPLETE` and exits **1**; a resolver or store that could not be read at all
exits **3** (`NON_VERIFIED`), because "it is not there" and "I could not look"
need different repairs. The invariants ref takes `<path>` or `<path>#<anchor>`
and both halves are verified — a dangling one would let a spawn believe it had
inherited quality rules it never received.

`bin/heimdall-brief` and `sentinels/lib/brief.sh` (the assembler on the
`heimdall-spawn` path) share one implementation of that policy,
`bin/lib/brief-core.sh`, so the two entry points cannot drift into disagreeing
about what counts as resolved.

## 5 — Blackboard

Shared key→value facts discovered once, read by key — kills the "every agent
rediscovers the dev-server port" tax.

```bash
heimdall-blackboard set dev_port 5173
heimdall-blackboard set node_version 20.11.0
heimdall-blackboard get dev_port           # → 5173
heimdall-blackboard list                   # → key<TAB>value
```

## 6 — Token ledger

Every message/spawn logs its token cost by role to `ledger.jsonl`. `report`
gives per-role totals for the run; `baseline` records the v1 number to beat;
`delta` computes the **measured** savings — no hardcoded percentage.

```bash
heimdall-ledger log --role orchestration --kind delta_brief --tokens 3300 --msg-id b1
heimdall-ledger baseline --role orchestration --tokens 41000
heimdall-ledger delta --role orchestration
#   orchestration: 41000 -> 11250 tokens (v1 baseline -> measured; -73%)
```

### Measured demo

`heimdall-protocol demo` runs one wave (orchestrator briefs 3 delta-spawns +
collects 3 typed results) under a v1 baseline vs this protocol, and lets the
ledger compute the delta:

```
v1 orchestration (briefing 3 spawns, verbatim): 41000 tokens (baseline)
v2 orchestration (symbol table + 3 delta briefs + 3 typed results): 11250 tokens
measured delta: orchestration: 41000 -> 11250 tokens (-73%)
```

The summary-card line: **`orchestration: 41k → 11250 tokens, measured`**.

---

## The contract-consuming adapter (built last, kept thinnest)

`heimdall-gate` is the **only** protocol component that reads `report.json`
(`evals/oracles/REPORT-CONTRACT.md`). Everything else is contract-independent, so
if a review finds a flaw in the report contract the rework is contained to this
one file. It reads only the gate-agnostic H-1 fields it is allowed to depend on
(`gate_id`, `status`, `wave` — **not** the open-keyed `metrics`) and emits a
schema-valid `gate_report` message that **references the report by path**
(`report_ref`), never inlining its body.

```bash
heimdall-gate to-message --report evals/oracles/exchange-lob/report.json \
  --from sentinel-bloat --msg-id g1 | heimdall-validate   # → valid gate_report
```

---

## Auditability

Every action appends one plain-text, tab-separated line to `.planning/protocol.log`:

```
2026-06-11T12:07:27Z	validate	accept	m1
2026-06-11T12:07:27Z	ledger	log	coder/task_result=250
```

Nothing is encoded. `heimdall-protocol log [N]` tails it.

---

## Verification

`bin/protocol/test-protocol.sh` drives every mechanism end-to-end against an
isolated fixture planning tree (55 assertions): syntax, init, resolve
forward/reverse, blackboard set/get, capsule ≤10-line cap + dependency-only
hydration, validate accept/reject + on-receipt retry/escalate, delta-brief
plan-exclusion, ledger measured delta, and the gate adapter's reference-only
`gate_report`. Exit 0 iff all pass.

---

# MCP Interop Contract — `heimdall-ledger-mcp` — v1.0.0

**Spec:** heimdall-team-spec §T-4 · **Status:** build-ready · **Transport:** MCP
stdio JSON-RPC 2.0 (protocol revision `2024-11-05`)

`bin/heimdall-ledger-mcp` exposes the Coordination Ledger (T-2) and the HAID
attribution backbone (T-1) over the **Model Context Protocol**, so *any* MCP
client — Cursor, GitHub Copilot, Claude Code, or a bespoke agent — can join the
same git-native coordination surface. It is a **thin wrapper**: every claim and
identity mutation shells out to `bin/heimdall-claim` and `bin/heimdall-haid`, the
single sources of truth. The server reimplements none of their logic.

## Why this is a protocol, not a feature

A coordination ledger that competitors can *adopt* over a published, versioned
wire contract is a **standard**, not a vendor feature. This is the
platform-absorption counter: if the big editors speak this contract, then
attribution and collision-prevention live in the open — not inside one vendor's
walls, where a platform owner could absorb and close them. The tool schema below
is the first-class public artifact, **semver-versioned** independently of the
token-frugal protocol above. Bump **major** on a breaking tool-shape change,
**minor** on an additive tool or field, **patch** on a fix that preserves the
wire shape. Current: **`1.0.0`** (`serverInfo.version`).

## Identity model

Each connecting client declares itself once at `initialize`
(`clientInfo.name` → `cursor` / `copilot` / `claude-code` / …) or per call via a
`client_identity` argument. The server derives a **spawn HAID** `{root}/{client}`
through `heimdall-haid spawn <client>` and registers it active via
`heimdall-haid register`. The role suffix (`/cursor`, `/copilot`) is the durable
distinguisher between clients in both the HAID and the registry `role` field, so
the ledger names the exact agent that acted. Every tool result echoes the
attributed HAID.

## Handshake

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize",
   "params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"cursor"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",
   "capabilities":{"tools":{"listChanged":false}},
   "serverInfo":{"name":"heimdall-ledger-mcp","version":"1.0.0"}, ...}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}        # → the 6 tools below
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"...","arguments":{...}}}
```

Stdio framing: both **newline-delimited JSON** and **`Content-Length:`-framed**
(LSP-style) requests are accepted on read; responses are line-delimited. Also
implements `ping`.

## Tools (6)

| Tool | Required args | Optional args | Delegates to / writes |
|------|---------------|---------------|-----------------------|
| `read_claims` | — | `client_identity` | `heimdall-claim list --json` → active claims + count |
| `make_claim` | `surfaces[]`, `task` | `ttl_minutes`, `client_identity` | `heimdall-claim claim` — collision gate enforced; client HAID woven into `task_ref` |
| `release_claim` | — | `haid`, `client_identity` | `heimdall-claim release` |
| `read_capsules` | — | `id`, `client_identity` | reads `.planning/ledger/completed/*.md` + `.planning/protocol/capsules/*.md` (H-4) |
| `append_decision` | `title`, `body` | `client_identity` | appends a HAID-attributed entry to `decisions.md` (append-only) |
| `raise_conflict_pr` | `id`, `title`, `surfaces[]` | `displaced_haid`, `overriding_intent`, `displaced_intent`, `client_identity` | authors `conflicts/{date}-{id}.md`, cross-links from `decisions.md`, returns the PR path |

Every tool also accepts `client_identity` (a per-call override of the
initialize-time identity) for HAID attribution. Results are returned as a JSON
`text` content block plus a `structuredContent` mirror, so both text-only and
structured MCP clients work.

```bash
# Round-trip: claim via MCP, see it through the CLI single-source-of-truth.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"cursor"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"make_claim","arguments":{"surfaces":["src/a/**"],"task":"T-9"}}}' \
  | bin/heimdall-ledger-mcp
bin/heimdall-claim list      # → the claim, task_ref carries the cursor HAID
```

## Client registration (`.mcp.json`)

A drop-in `.mcp.json` at the repo root registers the server with any MCP host:

```json
{ "mcpServers": { "heimdall-ledger": { "command": "bin/heimdall-ledger-mcp" } } }
```

Point Cursor / Copilot / Claude Code at it; the host speaks `initialize` →
`tools/list` → `tools/call` and the client joins the ledger with full attribution.
