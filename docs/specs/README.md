# docs/specs/README.md — canonical design-spec index (agent reference resolution)

**Why this file exists:** RJ's specs get written in chat, not committed — so an agent
grepping this repo for "Layer 1" or a spec by name finds nothing and either guesses or
stalls. This directory is where those chat specs land once committed. If a reference
below is marked missing, it is still chat-only — say so, don't invent a definition.

This is a second, separate index alongside the pre-existing [`INDEX.md`](INDEX.md) in
this same directory, which indexes the multi-tenant-teams / tenancy / isolation spec
subset (`2026-06-27-*`, `2026-07-03-*`) — a different topic. Check both.

## Layer 0 / Layer 1 — resolve these before citing them

| Layer | Is | Grounded in | Status |
|---|---|---|---|
| **Layer 0** | The universal git-core, `heimdall-init`. | `bin/heimdall-init` (shipped, `test/heimdall-init.test.sh`); `bin/heimdall:1522` calls it "the universal git core". | Shipped |
| **Layer 1** | The full gates/verdict `hmd mcp` server (`hmd_gate_check` etc.) per `heimdall-multihost-adapter-spec.md` — a **bigger** MCP surface than the existing `heimdall-ledger-mcp` (6 tools — `read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`, `raise_conflict_pr` — coordination-ledger only, no gate/verdict tools; see `PROTOCOL.md:219-306`). **Layer 1 ≠ `heimdall-ledger-mcp`.** | Source spec (`heimdall-multihost-adapter-spec.md`) is **not in this repo** — this row is relayed from the task brief that requested this index, not independently verified against a committed spec. `launch-docs/SUBMISSIONS.md` §4 already searched the whole repo for "Layer 1" and found no milestone definition (two unrelated string matches only: `hooks/git/pre-push:28`, `sentinels/bloat.sh:90`). | **Not built — still chat-only. Paste the spec in before treating Layer 1 as scoped or shipped.** |

## Specs in this directory (this pass)

| Spec | Purpose | Notes |
|---|---|---|
| [heimdall-chatops-spec.md](heimdall-chatops-spec.md) | `hmd` via Slack/Telegram — chat-driven status/investigate/fix/approve/report, identity binding, git-branch context sync. | Build spec, phased P1–P4. |
| [heimdall-viral-now-plan.md](heimdall-viral-now-plan.md) | Post-build execution plan: ship the pending commits → founding-cohort battle-test → launch chain (HN/PH/submissions). | Action plan, not a spec; references Layer 0 and L0/L1 landing as launch-gating. |
| [heimdall-S6-generalization-spec.md](heimdall-S6-generalization-spec.md) | Defines the reuse metric (C1), the mini-git controlled reuse test (C2), and the popular-10 cold-repo breadth run (C3) — the generalization gate required before forward feature work. | **Results are committed**: `docs/archive/docs/superpowers/specs/heimdall-S6-C3-findings.md` — verdict **GENERALIZES**, median reuse **0.50** across the 8 reuse-measured repos, 8/10 working-output. This is the source of the "0.50 median reuse across 8 cold repos" line in `README.md:122` and on `runheimdall.dev/proof`. |
| [heimdall-ship-spec.md](heimdall-ship-spec.md) | Ship Spec & Launch Planner, S-1…S-9 + the "L0/L1 playbook" — rename through launch-assets freeze. | Active per its own header ("Owner: RJ · sequence is the law"). |
| [heimdall-website-spec.md](heimdall-website-spec.md) | Website Spec v2 for `runheimdall.dev` — 3-page restructure (Landing/Capabilities/Proof). | Is the spec that put "0.50 median reuse across 8 cold repos" on the Proof page; itself warns the site has shipped stale numbers before (stale version, wrong commit count) — audit every hard number before trusting it. |

## Referenced but still chat-only — NOT in this repo, do not invent

- **`heimdall-multihost-adapter-spec.md`** — defines Layer 1 (above). Missing from `/Users/rj/Downloads/` and this repo.
- **`heimdall-seo-geo-spec.md`** — referenced by `launch-docs/GEO-SCORECARD.md` and `launch-docs/SUBMISSIONS.md` §1 as the source of the 10-target-query list and a canonical positioning line. Two prior agents already flagged it missing; still missing.

## Not copied here (naming mismatch — flag for RJ, not auto-added)

`/Users/rj/Downloads/HMD Statusline Spec v2.md` and `/Users/rj/Downloads/statusline-redesign-brief.md` exist in Downloads but don't match the `heimdall-*-spec.md` / `*-plan.md` pattern this pass copied.
