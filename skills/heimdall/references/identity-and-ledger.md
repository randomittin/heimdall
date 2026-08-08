# Agent Identity (HAID) & Coordination Ledger

**Read this when more than one Heimdall instance may touch this repo concurrently** —
before claiming surfaces, on a claim collision (`heimdall-claim check` exit 3), when
overriding or revoking, or when wiring another client onto the ledger over MCP. The
two every-run behaviors are kept inline in `agents/heimdall.md` §5.5: register the
HAID at session start, and carry the `Heimdall-Agent:` trailer on commits. Everything
below is the protocol you consult when a collision or a governance decision actually
arises.

## Agent Identity (HAID)

Every Heimdall instance and every agent it spawns carries a **HAID** — the Heimdall Agent Identifier — the attribution backbone the token ledger (T-2) hangs off. Format:

```
haid:{human}.{machine}-{hash4}[/{spawn-role}]
e.g.  haid:rj.mbp-7f3a              (a root orchestrator)
      haid:rj.mbp-7f3a/sentinel-2   (a sentinel it spawned)
```

`human` is the local-part of `git config user.email` (else `$USER`); `machine` is the short hostname; `hash4` is a stable hash of human+machine+repo, so the same checkout always derives the same identity. Spawns **inherit** the parent HAID and append `/{role}` — accountability rolls up the spawn tree to the root human.

Rules:
- **Derive + register on first interaction.** Run `heimdall-haid register` at session start; each spawned agent runs `heimdall-haid spawn <role>` to derive its child HAID, then `heimdall-haid register --haid <child>`. The registry lives at `.planning/ledger/agents.json`.
- **Commits carry the trailer** `Heimdall-Agent: <haid>` (get it from `heimdall-haid trailer`) so every atomic commit is attributable to the instance that made it.
- **Claims, protocol messages, and reports carry the HAID** of the agent that produced them (forward ref: the ledger T-2 consumes this for per-agent cost/claim attribution).
- **Revocation is the enforcement primitive.** `heimdall-haid revoke <haid>` marks an instance untrusted; `heimdall-haid check <haid>` exits nonzero for a revoked or absent HAID — instances refuse a revoked HAID's writes/claims.
- **`heimdall-who`** gives the read-only roster: each HAID, its human, role, status, and last heartbeat (with derived staleness).

## Coordination Ledger (claims protocol)

The ledger (`.planning/ledger/`) is git-native, zero-infra surface coordination for concurrent instances. `heimdall-claim` is the collision-prevention primitive: claim the surfaces you will touch (file globs + `file#symbol` refs) so a second agent is told who holds them BEFORE editing — the R1 failure class (parallel agents stomping the same surface) made enforceable. One file per HAID (`claims/{haid}.json`) → conflict-free merges. Claims carry `ttl_minutes:90` + a `heartbeat`; expired/heartbeat-dead claims auto-release (`heimdall-claim reap`, noted in `decisions.md`).

**HONEST SCOPE:** the ledger governs cooperating AGENTS — it is **not** a security boundary. Humans (and hostile/buggy processes) are governed by GitHub branch protection + CODEOWNERS. Never represent a claim as a lock that stops a determined writer.

Protocol:
- **Pre-plan:** pull; read active claims (`heimdall-claim list`), recent `completed/` capsules, and `decisions.md`. Exclude or sequence work that overlaps a held surface.
- **Pre-wave:** each agent runs `heimdall-claim check <surfaces…>` (exit 3 = collision naming the holder) then `heimdall-claim claim <surfaces…> --task <ref>`. A real collision → **block + AWAITING INPUT**, never force.
- **Completion:** write `completed/{date}-{task}.md` (summary + ≤10-line context capsule), then `heimdall-claim release`.
- **Governance (`roles.json`):** owner/maintainer may override-after-callout (structured `override_notice` → 15-min grace → overriding agent authors `conflicts/{id}.md` with both intents, kept vs displaced, recovery path; displaced work preserved on a `displaced/` branch, never destroyed → `decisions.md` entry citing both HAIDs). Contributors are PR-only, never force, never displace a held claim.
- **MCP interop (T-4):** `bin/heimdall-ledger-mcp` exposes the ledger over MCP stdio (6 tools: read_claims, make_claim, release_claim, read_capsules, append_decision, raise_conflict_pr) so Cursor/Copilot/any client joins the same ledger with full HAID attribution — a thin wrapper over `heimdall-claim`/`heimdall-haid`, contract in `PROTOCOL.md`, register via `.mcp.json`.
