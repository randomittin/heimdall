# Split coverage matrix

Wave-0 artifact of `docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md`, section 5 (table copied verbatim). Invariants: `.planning/split/INVARIANTS.md`.

| Subsystem | In scope? | Oracle row | Expected |
|---|---|---|---|
| mirror equals baseline (skills 21 files, statusline 18+4+26 files) | yes | `test/vendor-parity.test.sh` | green |
| statusline render parity | yes | `test/split-falsify.test.sh` + goldens | green |
| runtime fetch of skills pack into `$HEIMDALL_HOME/packs` | descoped (next cycle) | none | n/a |
| removal of bundled copies | descoped (spec Stage 4) | none | n/a |
| `skills/heimdall`, designmatch/stack bins | descoped (stay core) | none | n/a |
| publishing (skills.sh, npm), signing | descoped | none | n/a |
| standalone statusline on a machine with no hmd | descoped, unmeasured fail-open | none | expected-red if tried |
