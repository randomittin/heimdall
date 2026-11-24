# Analysis Index

> **Note:** `docs/analysis/` is **gitignored** except for this index and any explicitly force-added files. Audit and readiness reports written here are working artifacts kept **local-only** (not committed) so they never leak into the published plugin. This index is the one tracked file in the directory — it is `git add -f`'d deliberately so the directory's purpose is discoverable from the master index.

## Tracked

| Doc | Purpose | Status |
| --- | --- | --- |
| [autoresearch-distilled.md](autoresearch-distilled.md) | Distilled, transferable mechanics from the autoresearch investigation. | Current (tracked) |
| [token-spend-forensics.md](token-spend-forensics.md) | Where the token spend actually goes, measured from session transcripts; causes ranked by cost. Re-runnable via [`token-spend-forensics.py`](token-spend-forensics.py). | Current (tracked) — **row 3 refuted 2026-08-08** |
| [2026-08-08-security-review-tier-decision.md](2026-08-08-security-review-tier-decision.md) | Why the `security-guidance` reviewer stays on opus: the $57.73 was mis-attributed to the Stop hook and the prescribed fix saved $0. Pins the tier so it is not re-litigated. Guarded by `test/security-review-tier.test.sh`. | Current (tracked) |
| [2026-09-07-cost-forensics-tool.md](2026-09-07-cost-forensics-tool.md) | Productionizes this repo's n=1 token/cost analyses into a zero-config, read-only tool (`bin/heimdall-cost-forensics`) any Claude Code user can run against their own transcripts. Sanity-checked against this repo's own known figures. Guarded by `test/heimdall-cost-forensics.test.sh`. | Current (tracked) |
| [2026-11-24-lever-baseline.md](2026-11-24-lever-baseline.md) | Baseline, before 2026-11-24, of the token-lever metrics that `heimdall-cost-forensics --levers` verifies in one command (every number DERIVED with its query), and a correction of the 44.2% identical-re-read figure (a double count of transcript blob copies; the real share is 0.2-0.3%). Guarded by `test/heimdall-cost-forensics.test.sh`. | Current (tracked, force-added) |
| [2026-11-23-effort-ab.md](2026-11-23-effort-ab.md) | Pre-registered A/B of coding-agent thinking effort (medium vs high): frozen design, runner and fixtures in `evals/effort-ab/`, paired results and the GO/NO-GO verdict for lever 3 of the token-utilization audit. Guarded by `test/effort-ab.test.sh`. | Current (tracked, force-added) |

## Local-only (gitignored — generated, not committed)

These are produced by audits and readiness sweeps and live only in a working checkout. Filenames follow a dated convention; regenerate as needed:

- `prod-readiness-audit-<date>.md` — production readiness audit.
- `security-audit-<date>.md` — security audit sweep.
- `viral-readiness-audit-<date>.md` — launch/viral readiness audit.
- `<date>-public-rr-control-plane.md` — public `rr` control-plane analysis.

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
