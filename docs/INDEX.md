# Heimdall — Master Documentation Index (Brain Index)

The single map of Heimdall's knowledge tree. Every committed Markdown doc earns its place here or in a linked sub-index. Paths are relative to this file (`docs/`).

**Sub-indexes:** [Specs](specs/INDEX.md) · [Cloud Run runbooks](../deploy/cloud-run/INDEX.md) · [Analysis](analysis/INDEX.md) · [Archive](archive/INDEX.md) · [Oracle registry](../evals/oracles/README.md)

**Session-memory layer (not a doc):** live cross-session agent memory lives at `.claude/agent-memory/hmd-heimdall/MEMORY.md` (path reference only — untracked working state, not part of this tree).

---

## Product & Strategy

| Doc | Purpose | Status |
| --- | --- | --- |
| [../README.md](../README.md) | Project front door — what Heimdall is and how to install/use it. | Load-bearing |
| [../IDENTITY.md](../IDENTITY.md) | Canonical identity — single source of truth for naming/positioning. | Load-bearing |
| [superpowers/specs/2026-07-06-teams-growth-strategy.md](superpowers/specs/2026-07-06-teams-growth-strategy.md) | Heimdall Teams growth strategy (Slack-playbook → Cursor-for-teams revenue). | Current (draft) |
| [../DECISION-GATE.md](../DECISION-GATE.md) | Pre-launch decision gate — written before launch, frozen. | Reference |
| [../PARITY.md](../PARITY.md) | superx → heimdall feature-surface parity matrix. | Reference |

## Architecture & Specs

| Doc | Purpose | Status |
| --- | --- | --- |
| [specs/INDEX.md](specs/INDEX.md) | **Sub-index** — canonical, current design specs (teams, tenancy, isolation). | Load-bearing |
| [specs/README.md](specs/README.md) | **Sub-index** — chat-originated design specs (chatops, viral-launch plan, S-6 generalization, ship plan, website v2) + the Layer 0/Layer 1 resolution table. | Load-bearing |
| [../PROTOCOL.md](../PROTOCOL.md) | Heimdall token-frugal protocol (v2.0.0). | Load-bearing |
| [rr-control-plane-client.md](rr-control-plane-client.md) | `rr --mode control-plane` — the signed enqueue client. | Current |
| [superpowers/specs/2026-04-06-superx-design.md](superpowers/specs/2026-04-06-superx-design.md) | superx superskill-manager design — referenced by the heimdall skill + agent. | Load-bearing |
| [superpowers/specs/heimdall-fixture-secret-convention.md](superpowers/specs/heimdall-fixture-secret-convention.md) | Test-fixture secret convention — cited by 6 integration tests. | Load-bearing |
| [../STACK_PACK_TEMPLATE.md](../STACK_PACK_TEMPLATE.md) | Template for authoring stack skill packs. | Load-bearing |
| [../SI-1.md](../SI-1.md) | SI-1 — project-context comprehension capsule (orientation cache). | Reference |
| [../SI-2.md](../SI-2.md) | SI-2 — commit-time attestation record. | Reference |
| [../REUSE-METRIC.md](../REUSE-METRIC.md) | Reuse metric (S-6 Component 1) — measurement substrate. | Reference |
| [../TOKEN-METRIC.md](../TOKEN-METRIC.md) | Token metric — model-token accounting substrate (`bin/heimdall-tokens`). | Reference |
| [../BLOAT-REPORT.md](../BLOAT-REPORT.md) | Bloat report — cited by the debloat command + tests. | Load-bearing |
| [debloat.md](debloat.md) | `heimdall debloat` — retroactive whole-repo bloat removal (H-2ii). | Current |

## Security & Audits

| Doc | Purpose | Status |
| --- | --- | --- |
| [../SECURITY.md](../SECURITY.md) | Security policy — disclosure + supported versions. | Load-bearing |
| [specs/2026-06-27-multi-tenant-teams-threatmodel.md](specs/2026-06-27-multi-tenant-teams-threatmodel.md) | Threat model for private multi-tenant team presence. | Current |
| [specs/2026-07-03-rr-isolation-invariants.md](specs/2026-07-03-rr-isolation-invariants.md) | `rr` isolation invariant ledger + cross-tenant coverage matrix. | Current |
| [analysis/INDEX.md](analysis/INDEX.md) | **Sub-index** — audit/readiness reports (mostly gitignored, local-only). | Reference |

## Operations & Runbooks

| Doc | Purpose | Status |
| --- | --- | --- |
| [../deploy/cloud-run/INDEX.md](../deploy/cloud-run/INDEX.md) | **Sub-index** — Cloud Run deploy + maintainer + public-rr runbooks. | Load-bearing |
| [../deploy/gce/README-rr.md](../deploy/gce/README-rr.md) | `rr` remote-run — local → cloud maintainer handoff (GCE). | Load-bearing |
| [team-validation-runbook.md](team-validation-runbook.md) | Team-presence validation runbook. | Current |
| [../release/publish-checklist.md](../release/publish-checklist.md) | Release publish checklist (RJ-executed). | Load-bearing |
| [../release/HOSTING.md](../release/HOSTING.md) | `runheimdall.dev/install` — which redirect artifact to apply. | Reference |
| [../packages/runheimdall/README.md](../packages/runheimdall/README.md) | `runheimdall` installer package. | Load-bearing |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Contribution guide. | Reference |
| [../CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Code of conduct. | Reference |

## Skills & Agents

| Surface | Purpose | Status |
| --- | --- | --- |
| [../skills/heimdall/SKILL.md](../skills/heimdall/SKILL.md) | The orchestrator superskill (+ [references/](../skills/heimdall/references)). | Load-bearing (runtime) |
| [../skills/designmatch/SKILL.md](../skills/designmatch/SKILL.md) | Visual-parity design-match skill (+ [references/](../skills/designmatch/references)). | Load-bearing (runtime) |
| [../skills/self-improve/SKILL.md](../skills/self-improve/SKILL.md) | Self-improvement skill. | Load-bearing (runtime) |
| [../skills/stacks/README.md](../skills/stacks/README.md) | Stack skill packs (fastapi, nextjs, react-native, spring-boot). | Load-bearing (runtime) |
| [../agents/](../agents) | 16 agent definitions (architect, coder, reviewer, seeker, fixer, …) loaded by path. | Load-bearing (runtime) |
| [../commands/](../commands) | 15 slash-command definitions (maintain, team, demo, save, …) loaded by path. | Load-bearing (runtime) |
| [../conformance/README.md](../conformance/README.md) | Parity-conformance fixtures. | Load-bearing |

## Test & Verification

| Doc | Purpose | Status |
| --- | --- | --- |
| [../evals/oracles/README.md](../evals/oracles/README.md) | **Oracle registry** — external falsifiable graders (the sub-index for oracles). | Load-bearing |
| [../evals/oracles/REPORT-CONTRACT.md](../evals/oracles/REPORT-CONTRACT.md) | Oracle report contract. | Load-bearing |
| [../evals/oracles/BLIND-VERIFICATION.md](../evals/oracles/BLIND-VERIFICATION.md) | Blind-verification protocol. | Load-bearing |
| [../evals/flagship/README.md](../evals/flagship/README.md) | Flagship eval suite (emulator-gb + exchange-lob) + STATUS/PROOF docs. | Load-bearing |
| [../evals/benchmark/README.md](../evals/benchmark/README.md) | Benchmark harness + tasks. | Load-bearing |
| [../evals/corpus/CORPUS-STATUS.md](../evals/corpus/CORPUS-STATUS.md) | Corpus catch-rate time series (+ [SCHEMA.md](../evals/corpus/SCHEMA.md)). | Load-bearing |
| [../test/fixtures/redum/README.md](../test/fixtures/redum/README.md) | Redum test fixtures. | Load-bearing |
| [../test/fixtures/verified-memory/README.md](../test/fixtures/verified-memory/README.md) | Verified-memory test fixtures. | Load-bearing |

## History & Changelogs

| Doc | Purpose | Status |
| --- | --- | --- |
| [../CHANGELOG.md](../CHANGELOG.md) | Release changelog. | Load-bearing |
| [CHANGES-SINCE-TEAMS.md](CHANGES-SINCE-TEAMS.md) | Comprehensive change log since the team-features anchor. | Current |

## Archive

| Doc | Purpose | Status |
| --- | --- | --- |
| [archive/INDEX.md](archive/INDEX.md) | **Sub-index** — superseded design dossiers + completed-run records (history preserved via `git mv`). | Archive |

---

_Maintenance: when adding a committed `.md`, add it (or its sub-index) here. Protected runtime surfaces — `skills/*/SKILL.md`, `skills/**/references/*`, `agents/*.md`, `commands/*.md`, `.claude-plugin/**`, `deploy/**` runbooks, `docs/specs/**`, `evals/**` — are loaded by path and must never be moved or renamed._
