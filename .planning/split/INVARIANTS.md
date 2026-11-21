# Split invariants ledger

Wave-0 artifact of `docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md`, section 5 (INV lines copied verbatim). "The differential gate above" refers to that plan's section 4, Oracle gate. Listed under Read first for every task after W0.

- INV-S1: every moved path exists in heimdall at the same path with the same bytes as the pinned tag; `heimdall-vendor verify` is exit 0.
- INV-S2: `hooks/statusline.sh` path and the substring `hooks/statusline.sh`, and `bin/heimdall-statusline` path, are unchanged (users' `settings.json` / Cursor config stay valid).
- INV-S3: rendered bytes for the recorded fixtures are identical before and after.
- INV-S4: no network at install or render time in phase 1.
- INV-S5: no file outside the moved set is edited by the split (`git diff --stat` names only `vendor/`, `bin/heimdall-vendor`, `bin/lib/vendor_lock.py`, tests, docs, deleted moved suites).
- INV-S6: history of each moved path is present in the new repo (`git log --oneline -- <path> | wc -l` equals the source count, except renamed-away history, open question O-D).

The ledger has no teeth without the differential gate above.
