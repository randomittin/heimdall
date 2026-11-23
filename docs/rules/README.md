# Rules: long form

`CLAUDE.md` is loaded into every session and every subagent's first request, so it carries only a digest of each rule: what must and must not happen, the overrides, the one-line why. The long form (history, measurements, mechanics, proofs) was moved here verbatim on 2026-11-23 (operator directive: shrink `CLAUDE.md` and remove redundancy; target at most 13 KB).

| `CLAUDE.md` section | Long form |
| --- | --- |
| Commit attribution | [commit-attribution.md](commit-attribution.md) |
| When the full gate runs | [full-gate.md](full-gate.md) |
| Release convergence (includes the sweep guard) | [release-convergence.md](release-convergence.md) |
| Pre-commit vs pre-push; Push gate | [push-gates.md](push-gates.md) |
| CI waste guard; Wait guard; Sweep advice | [hook-guards.md](hook-guards.md) |
| Parallelism; Model routing; Edit Verification; Token Efficiency (original wording) | [conventions.md](conventions.md) |

Editing rules:
- Other files cite `CLAUDE.md` sections by heading (`"When the full gate runs"`, `"Release convergence"`, `"Commit attribution"`, `"Push gate"`, `"CI waste guard"`, `"Model routing"`, `"Token Efficiency"`, the anchor `#code-quality--zero-tolerance`): keep the headings.
- Tests read `CLAUDE.md`. Each guard section must name its override variable, its lib and its proof test (`test/disk-floor.test.sh`, `test/sweep-guard.test.sh`, `test/ci-waste-guard.test.sh`, `test/wait-guard.test.sh`, `test/sweep-advice.test.sh`). `test/no-auto-merge.test.sh` keeps one allowlist row per merge, push or release phrase in `CLAUDE.md`, matched by a fragment on the same physical line (its `A("CLAUDE.md", ...)` rows list them; `merge them ALL` and `merging agent fixes one at a time` must stay on different lines): reword one and change its row with it.
- Change a rule in both places, the digest in `CLAUDE.md` and the long form here. Cross-references in the moved text ("above", "below") refer to the original single file.
