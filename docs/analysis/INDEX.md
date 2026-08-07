# Analysis Index

> **Note:** `docs/analysis/` is **gitignored** except for this index and any explicitly force-added files. Audit and readiness reports written here are working artifacts kept **local-only** (not committed) so they never leak into the published plugin. This index is the one tracked file in the directory — it is `git add -f`'d deliberately so the directory's purpose is discoverable from the master index.

## Tracked

| Doc | Purpose | Status |
| --- | --- | --- |
| [autoresearch-distilled.md](autoresearch-distilled.md) | Distilled, transferable mechanics from the autoresearch investigation. | Current (tracked) |
| [token-spend-forensics.md](token-spend-forensics.md) | Where the token spend actually goes, measured from session transcripts; causes ranked by cost. Re-runnable via [`token-spend-forensics.py`](token-spend-forensics.py). | Current (tracked) |

## Local-only (gitignored — generated, not committed)

These are produced by audits and readiness sweeps and live only in a working checkout. Filenames follow a dated convention; regenerate as needed:

- `prod-readiness-audit-<date>.md` — production readiness audit.
- `security-audit-<date>.md` — security audit sweep.
- `viral-readiness-audit-<date>.md` — launch/viral readiness audit.
- `<date>-public-rr-control-plane.md` — public `rr` control-plane analysis.

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
