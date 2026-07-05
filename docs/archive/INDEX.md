# Archive Index

Superseded design dossiers, one-time recipes, and completed-run records. Nothing here is load-bearing — every file was moved with `git mv` (full history preserved) because the work it described has **shipped** and now lives in code, tests, or the canonical specs under [`docs/specs/`](../specs/INDEX.md). Kept for provenance, not for guidance.

Original paths are preserved under `docs/archive/<original-relative-path>`.

| Archived doc | Original home | Why archived (where the work lives now) |
| --- | --- | --- |
| [2026-04-06-pixel-dashboard-design.md](docs/superpowers/specs/2026-04-06-pixel-dashboard-design.md) | docs/superpowers/specs/ | Early pixel-art dashboard design; superseded by the shipped terminal-native HUD statusline. |
| [2026-04-10-single-phase-flow-design.md](docs/superpowers/specs/2026-04-10-single-phase-flow-design.md) | docs/superpowers/specs/ | Single-phase flow design; the flow shipped in the orchestrator skill. |
| [2026-06-11-oracle-gate-system.md](docs/superpowers/specs/2026-06-11-oracle-gate-system.md) | docs/superpowers/specs/ | Oracle-gate design; shipped as [`evals/oracles/`](../../evals/oracles/README.md) + flagship suite. |
| [cp-state-migration-recipe.md](docs/superpowers/specs/cp-state-migration-recipe.md) | docs/superpowers/specs/ | One-time Wave-1 `cp_state` migration recipe; migration completed, control plane shipped. |
| [heimdall-control-plane-decisions.md](docs/superpowers/specs/heimdall-control-plane-decisions.md) | docs/superpowers/specs/ | Control-plane ADR; shipped — see [`deploy/cloud-run/`](../../deploy/cloud-run/INDEX.md) + [`docs/rr-control-plane-client.md`](../rr-control-plane-client.md). |
| [heimdall-control-plane-design.md](docs/superpowers/specs/heimdall-control-plane-design.md) | docs/superpowers/specs/ | Control-plane design dossier; shipped (same as above). |
| [heimdall-F3-redum-proof.md](docs/superpowers/specs/heimdall-F3-redum-proof.md) | docs/superpowers/specs/ | Redum before/after acceptance proof; redum shipped, fixtures in `test/fixtures/redum/`. |
| [heimdall-issue-loop-design.md](docs/superpowers/specs/heimdall-issue-loop-design.md) | docs/superpowers/specs/ | Autonomous issue-loop design; shipped as `/maintain`, seeker + fixer agents. |
| [heimdall-S6-C3-findings.md](docs/superpowers/specs/heimdall-S6-C3-findings.md) | docs/superpowers/specs/ | Completed generalization-run findings record (kept for provenance). |
| [heimdall-S6-C3-proposal.md](docs/superpowers/specs/heimdall-S6-C3-proposal.md) | docs/superpowers/specs/ | Pre-run proposal (NOT-YET-RUN at authoring); superseded by the findings record. |
| [heimdall-team-mode-design.md](docs/superpowers/specs/heimdall-team-mode-design.md) | docs/superpowers/specs/ | Team-mode design dossier; superseded by canonical [`docs/specs/2026-06-27-multi-tenant-teams.md`](../specs/2026-06-27-multi-tenant-teams.md). |
| [heimdall-telemetry-design.md](docs/superpowers/specs/heimdall-telemetry-design.md) | docs/superpowers/specs/ | Telemetry/reporting design; shipped as the HUD + end-of-run summary card. |
| [heimdall-verified-memory-design.md](docs/superpowers/specs/heimdall-verified-memory-design.md) | docs/superpowers/specs/ | Verified-memory design dossier; shipped, fixtures in `test/fixtures/verified-memory/`. |

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
