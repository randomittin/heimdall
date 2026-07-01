---
name: debloat
description: Retroactive whole-repo bloat removal (spec H-2ii). Scores an existing repo on the deterministic bloat axes, writes BLOAT-REPORT.md, and — only behind a passing test-suite safety oracle — proposes gated refactor waves as a PR. The zero-risk adoption hook.
disable-model-invocation: true
---

# Debloat — Retroactive Whole-Repo Bloat Removal

Turn the H-2 bloat engine (`bin/bloat-gate`) on an ENTIRE existing repo. This is
the adoption hook: a cold-repo, no-setup command that produces a real bloat
scorecard, and — only when it can prove safety — proposes removals as a PR.

## When to use

- Someone wants a bloat read on a repo Heimdall did not build (the reply-guy reply).
- Before adopting the per-wave bloat gate, to clear the existing debt.
- To turn "this codebase feels bloated" into a measured, prioritized PR.

## Instructions

1. **Always start read-only.** Run the one-word scorecard on any repo:

   ```
   bin/heimdall-debloat report [<path>]      # <path> defaults to cwd
   ```

   `report` is the friendly, screenshot-worthy entrypoint (a back-compatible alias
   of `--report-only`). It runs ONLY the read-only scorecard pass, writes
   `BLOAT-REPORT.md` (dead exports, duplication clusters, complexity hotspots,
   unused deps, candidate-deletion LOC estimate), makes NO changes, and prints a
   truecolor **BLOAT SCORECARD** card to the terminal. The equivalent legacy form
   still works and is unchanged:

   ```
   bin/heimdall-debloat --report-only --repo <path>
   ```

   Present the report. Skipped axes mean the analysis tool is absent — say so
   honestly; an absent tool is a gap, never a pass.

   **The BLOAT SCORECARD card.** `report` (and `--report-only` when run
   interactively on a tty) prints a one-frame scorecard: the 5 axes — dead
   exports, duplication %, cyclomatic complexity, dependency creep, LOC budget —
   each with its real value from the bloat-gate run and a `✓` / `⚠` / `✗` glyph,
   plus an overall verdict (`LEAN` / `NEEDS TRIMMING` / `BLOATED`, or
   `INCONCLUSIVE` when every axis was skipped) and the repo name. Numbers come
   straight from the same data as `BLOAT-REPORT.md`; an axis whose tool is absent
   reads `skipped: needs <tool>` — never a fabricated number. Piped / CI output is
   clean plain text (zero ANSI), so it is safe to redirect or capture.

2. **Respect the safety oracle.** A refactor run is allowed only when a test suite
   EXISTS and PASSES on a clean checkout. If `heimdall-debloat` refuses (exit 3),
   do NOT try to force it. Offer the user the two legitimate paths:
   - add/repair a real test suite, then re-run; or
   - `bin/heimdall-debloat --generate-characterization-tests --repo <path>` to
     scaffold golden-master tests pinning current hotspot behavior.

3. **Run the gated refactor only with a green oracle:**

   ```
   bin/heimdall-debloat --repo <path> [--test-cmd '<cmd>'] [--aggressive]
   ```

   Output is a branch `heimdall/debloat-<date>` with one atomic commit per applied
   wave and an auto-written PR body (`.heimdall-debloat-PR.md`): before/after
   scorecard, per-wave commit map, and the "every test that passed before passes
   now" guarantee. It NEVER commits to the working branch directly.

4. **Honor the caps.** Default cap is −20% LOC per PR (lift with `--aggressive`).
   Generated code and migrations are excluded by default. Anything static analysis
   cannot prove dead (public API, dynamic usage, no-coverage code) is listed as a
   manual-review candidate and never auto-deleted.

## Subcommands

- `report [<path>]` — one-word bloat scorecard on any repo: runs the read-only
  scorecard pass, writes `BLOAT-REPORT.md`, and prints the shareable **BLOAT
  SCORECARD** card. Zero changes; a friendly alias of `--report-only`. `<path>`
  defaults to the current directory.

## Flags

- `--report-only` — scorecard only, zero changes (default first move; `report` is the alias).
- `--generate-characterization-tests` — scaffold golden-master tests when no suite exists.
- `--test-cmd <cmd>` — the safety-oracle command (auto-detected if omitted).
- `--aggressive` — lift the −20% LOC cap.
- `--max-loc-pct <n>` — explicit LOC-reduction cap (default 20).
- `--mode strict|standard|off` — forwarded to the scorecard axes.
- `--json` — also print a machine-readable scorecard.

## Exit codes

- `0` ok (scorecard written / PR proposed / refusal handled gracefully)
- `1` a wave failed its gate and was reverted, or the PR could not be built
- `2` usage / IO error
- `3` safety-oracle refusal (no passing test suite) when a refactor was requested
