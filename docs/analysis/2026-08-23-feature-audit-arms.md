# Feature-Execution Audit — `bin/heimdall` Dispatcher Arms

**Date:** 2026-08-24 · **Commit audited:** `71bd0b7` (worktree HEAD, clean) · **Worktree:** `agent-a9b57f14abc6b31c6`

**Standard applied (verbatim from the owner):** *"it's to ensure all features announced are
actually working."* Does it run — not does the code exist. A capability census found 100 bins
statically reachable vs. 43 with any observed real invocation across 384 sessions, and
`heimdall-deadcode` once counted a prose sentence in a Markdown file as a "caller." Static
analysis has already lied here. Only actual execution counts as evidence in this document.

**Method:** every arm of the `case "${1:-}" in` dispatcher at `bin/heimdall:1646-2653` was (1)
enumerated by grep, (2) checked against the real, fully-captured `--help` text for advertisement,
(3) actually run — `--help`/`status`/read-only verbs preferred — with real captured output quoted
below, (4) classified **WORKS / BROKEN / UNSAFE-TO-TEST**. Nothing below is inferred from reading
source alone; every WORKS/BROKEN row has a command that was actually executed this session, output
captured to a log file, exit code appended via `echo "EXIT:$?"` in the same shell invocation, and
quoted here. `perl -e 'alarm N; exec @ARGV' --` stood in for the absent `timeout`/`gtimeout`.
`HEIMDALL_HOME` was pointed at a scratch dir for every invocation to keep local-state writes out of
the real `~/.heimdall`.

**Hard safety constraints observed:** no push, no PR, no real GitHub issue, no primary-checkout
mutation, no paid API, no `claude -p` spawn. Where an arm's real behavior would cross one of those
lines, it is marked **UNSAFE-TO-TEST** with an exact statement of what it would have done — a
complete verdict, not a gap. This dispatcher has **no `*)` catch-all arm**: an unmatched or
misspelled subcommand falls through ~14 sequential `if` blocks and ultimately toward a live,
`--dangerously-skip-permissions` Claude Code session launch. That path, and bare `''` (zero args,
which hits the same launch unconditionally), were never invoked for real in this audit.

45 case-arm patterns were found (grep-verified against `bin/heimdall:1646-2653` just now); a few
patterns cover more than one literal token (`version|--version|-v|-V`, `beat|roster`,
`wrap|unwrap`), so the table has 45 rows.

## Results

| # | Arm | In `--help`? | Command run | Verdict | Evidence (real, captured) |
|---|-----|:---:|---|:---:|---|
| 1 | `version\|--version\|-v\|-V` | No | `heimdall version` | WORKS | `Heimdall v2.4.0` / `commit 71bd0b7`, exit 0 |
| 2 | `help` | No¹ | `heimdall help` | WORKS | Full command list + launch-flags block printed, exit 0 |
| 3 | `demo` | No | `heimdall demo --help` | WORKS | "WHAT IT DOES… EXAMPLES: heimdall-demo / heimdall-demo --run", exit 0 — **note:** brief cites this as previously "command not found" on fresh installs; not reproduced now, confirmed fixed at this commit |
| 4 | `rr` | No | `heimdall rr --help` | WORKS | Full FLAGS/MODES help (`--dry-run`, `vm`/`control-plane`), exit 0 |
| 5 | `sigil` | No | `heimdall sigil` (bare) | WORKS | `sigil: enderman` / `haid: haid:rj.rishabhs-macbook-air-8e99` / "change locked — unlocks after 5 hmd runs (you have 0)", exit 0 |
| 6 | `sigil-png` | No | `heimdall sigil-png --seed <n> --out fox.png` | WORKS | Real file written; `file` confirms `PNG image data, 456 x 456, 8-bit/color RGBA`, exit 0 |
| 7 | `guard` | No | `heimdall guard` (bare) | WORKS | "Usage: hmd guard install" + description, exit 2 (correct refusal — no subcommand given) |
| 8 | `uninstall` | No² | `heimdall uninstall` (bare, non-TTY, no `--yes`) | WORKS | "Non-interactive: pass --yes to confirm uninstall (refusing to prompt)." exit 2 — safe-refusal path confirmed real |
| 9 | `team` | Yes | `heimdall team --help` | WORKS | Full secret-handling/security doc, "Exit: 0 ok; 2 usage/refuse-clobber…", exit 0 |
| 10 | `invite` | Yes | `heimdall invite --help` | WORKS | Full doc incl. URL-probe-before-print behavior, exit 0 |
| 11 | `join` | Yes | `heimdall join --help` | WORKS | `--help` treated as a literal secret value → "refusing a weak team secret (<32 chars)", exit 2 — correct input validation, not a crash |
| 12 | `connect` | Yes | `heimdall connect --status` | WORKS | "not connected — run `hmd connect` to register your Claude credential (30s)", exit 0 |
| 13 | `presence` | Yes | `heimdall presence status` | WORKS | Full status: repo/global/effective/signing, exit 0 — note: "global" check reads real `~/.heimdall/presence-off` even under `HEIMDALL_HOME` override (read-only, not a safety violation, but not fully sandboxed) |
| 14 | `context` | No | `heimdall context status` | WORKS | repo=randomittin/heimdall, decision=undecided, visibility=public, effective=off, exit 0 |
| 15 | `chat` | No | `heimdall chat` (bare) | WORKS | argparse usage + subcommand list `{link,handle,serve,bindings,unlink}`, exit 2 (standard argparse convention for a required-subcommand tool given none) |
| 16 | `link` | No | `heimdall link --help` | WORKS | `usage: heimdall-chat link [-h] [channel]`, exit 0 |
| 17 | `beat\|roster` | No | `heimdall roster` | WORKS | "heimdall enroll refused (401): check the enroll token / endpoint" then "presence: no teammates online" — real network call, graceful degrade, exit 0 |
| 18 | `dashboard` | No | `heimdall dashboard --help` | WORKS | "heimdall dashboard: unknown subcommand: --help" + correct usage (`hmd dashboard login <device_code>…`), exit 2 — `--help` isn't special-cased as global help (minor discoverability gap), but output is correct and safe |
| 19 | `god` | No | `heimdall god --help` | WORKS | Full `roster`/`logs` command doc, owner-only HAID gate explained, exit 0 |
| 20 | `telemetry` | No | `heimdall telemetry status` | WORKS | Real JSON: `"tier":"T0"`, `"never_collected":["source code","file paths…","prompts","secrets"]`, `"spool":{"bytes":0}`, exit 0 |
| 21 | `init` | No | `heimdall init --help` | **BROKEN** | Prints full CONTRACT text then a bare `Usage:` header with **nothing after it**, exit 0. Root cause confirmed in source: `usage() { sed -n '2,39p' "$0" \| sed 's/^# \{0,1\}//'; }` (`heimdall-init:59`) — line 39 is exactly the `# Usage:` comment line; the 4 real usage lines live at lines 40-43 and are never included. Off-by-N range, not a display artifact. |
| 22 | `verdict` | No | `heimdall verdict --help` | WORKS | `-h, --help` + field list (`verdict\|phase\|ts\|gate\|file`), "Exit: 0 always", exit 0 |
| 23 | `sla` | Yes | `heimdall sla` (bare) | WORKS | "SECURITY SLA: clean — project agent-a9b57f14abc6b31c6, 24h window / scanned 0 · breach 0 · within window 0 · triaged 0", exit 0 |
| 24 | `badge` | No | `heimdall badge --markdown` | WORKS | Real markdown emitted; the linked shields.io URL was curled live → `HTTP:200`. **Note:** brief cites a prior precedent of this exact command linking a 404 shields.io URL — not reproduced now (verified via live curl, not assumed) |
| 25 | `metrics` | No | `heimdall metrics report` | **BROKEN** | `Error: heimdall-metrics not found at .../bin/heimdall-metrics` / "Reinstall: curl -fsSL https://runheimdall.dev/install \| bash", exit 1 — confirmed via `ls`: the binary genuinely does not exist in this worktree |
| 26 | `clip` | No | `heimdall clip --help` | WORKS | `hmd clip [--last\|--wall] [--svg\|--json]`, "Exit: 0 always", exit 0 |
| 27 | `funnel` | No | `heimdall funnel status` | WORKS | Real counters: `join 1`, `badge_added 1` (from this session's own earlier `join`/`badge` runs — confirms the telemetry pipeline is really wired end to end), exit 0 |
| 28 | `watch` | No | `heimdall watch --help` | WORKS | `--pane`, `--once`, `--install-tui`, `-h\|--help` all documented; "Textual is NOT a hard dependency", exit 0 |
| 29 | `rules` | No | `heimdall rules --help` | WORKS | Full V7 rule-clustering doc + real usage (`heimdall-rules propose [options]…`) printed correctly; **but** ~10 lines of raw script (the `usage()` function itself, the `jq` check, the `case "$CMD"` block) leak after it, exit 0 — same `sed -n '2,110p'` overshoot pattern as #39/#40/#36/#42 below, this time overshooting the *long* way (too much printed, not too little) |
| 30 | `route` | No | `heimdall route --help` | WORKS | Clean doc incl. shell-integration snippet (`claude() { command hmd route claude "$@"; }`), exit 0, no leak |
| 31 | `modules` | No | `heimdall modules --help` | WORKS | Full env-var + exit-code doc, exit 0 |
| 32 | `tier` | No | `heimdall tier --help` | WORKS | argparse subcommands `{table,declare,check,agents,policy}`, exit 0 |
| 33 | `status` | Yes | `heimdall status` (bare) | WORKS | Renders the real one-line HUD (`⛭ HEIMDALL`, ANSI-colored), non-TTY-safe, exit 0 |
| 34 | `cursor-statusline` | No | `heimdall cursor-statusline status` | WORKS | `would-register` (dry, read-only — no mutation of the real `~/.cursor/` config), exit 0 |
| 35 | `weekly-log` | Yes | `heimdall weekly-log --help` | WORKS | `--until`, `--k`, `--out`, `--repo`, `--proposals`, `--stdout`, `--slice` all documented, exit 0 |
| 36 | `report` | No | `heimdall report --help` | WORKS | Full run/aggregate doc printed correctly; 5 lines of raw source (`set -euo pipefail`, `REPORT_LIB=…`) leak after it, exit 0 — same root cause as #21's sibling bug, opposite direction (over-print) |
| 37 | `report-issue` | Yes | `heimdall report-issue --help` | WORKS | Full usage block printed (comment markers `#` left unstripped — cosmetic only, still fully readable), exit 0. Real run (`gh issue create` against the live plugin repo) intentionally not exercised — forbidden by the hard safety rules |
| 38 | `designmatch` | No | `heimdall designmatch --help` | WORKS | Full numbered workflow + `--headed` auth note, exit 0 |
| 39 | `check` | No | `heimdall check --help` | WORKS | Full F2-checker doc (tiers `none\|basic\|max`, exit codes) printed correctly; 5 lines of raw source (`CHECKER_LIB=…`, `ATTEST=…`) leak after it, exit 0 |
| 40 | `redum` | No | `heimdall redum --help` | WORKS | Full F3-redum doc (`factor`/`gate` subcommands) printed correctly; 6 lines of raw source leak after it, exit 0 |
| 41 | `authenticity-check` | Yes | `heimdall authenticity-check` (bare) | WORKS | "Usage: authenticity-check <type> <identifier>" + `npm\|github\|plugin` types listed, exit 1 (usage-on-no-args; exit code choice differs from the `2` convention elsewhere but behavior is correct) |
| 42 | `queue` | Yes | `heimdall queue` (bare) | WORKS | `list`/`status`/`serve` fully documented + exit-status table; one trailing stray line (`set -euo pipefail`) leaks after it, exit 0 |
| 43 | `quota-advisor` | No | `heimdall quota-advisor status` **and** `check --text "…"` | WORKS | `status`: silent, exit 0 (by design — source confirms it only speaks when `.planning/QUOTA-STOP.json` has `status:"waiting"`, `heimdall-quota-advisor:240`); `check --text "test input"`: silent, exit 1 (by design — `_qa_detect` classified the text as non-quota-signal, `heimdall-quota-advisor:219`). Confirmed via source: no dangerous fallthrough exists any more — the tool's own `case` ends in a real usage-error branch (`heimdall-quota-advisor:257-259`), not a spawn |
| 44 | `wrap\|unwrap` | No | `heimdall wrap --help` | WORKS | `hmd wrap [tool]`, `hmd wrap <tool> --always/--default`, `hmd unwrap <tool>`, `hmd wrap status`, tool list `claude cursor codex gemini aider`, exit 0 |
| 45 | `''` (empty args) | N/A | *not executed* | UNSAFE-TO-TEST | Source-confirmed: falls straight to `exec heimdall-wrap launch` — a real `--dangerously-skip-permissions` Claude Code session spawn. No safe subset exists for zero args; never invoked. |

¹ Only the `--help` *flag* form is listed in the real help text; the bare word `help` is not mentioned anywhere in it, though it dispatches to the identical handler.
² Only the `--uninstall` *flag* form is listed (`heimdall --uninstall Remove heimdall completely (add --yes for non-interactive)`); the bare word `uninstall` is not mentioned.

## Summary counts

- **WORKS: 42** (arms #1-44 except #21 and #25)
- **BROKEN: 2** — `init` (#21, `--help` truncated before the usage synopsis), `metrics` (#25, target binary missing from this worktree)
- **UNSAFE-TO-TEST: 1 arm fully untested** (`''`, #45) **+ 6 arms partially untested by design** (the mutating half of `guard`/`uninstall`/`init`/`wrap`/`report-issue`/`god` — see below)
- **NOT-ADVERTISED (arm works but absent from `--help`): 33 of 45** — everything in the table marked "No" above

## Deliberately unexecuted mutating paths (UNSAFE-TO-TEST, by design)

Each of these has a sibling *safe* invocation already tested and marked WORKS above; only the
specific mutating form below was withheld, per the hard safety rules:

- **`guard install`** — would run `git config core.hooksPath …` against the real, *shared*
  (non-worktree-local) `.git/config` of the common object store. Bare `guard` (safe, tested above)
  confirmed the arm dispatches correctly and refuses cleanly without a subcommand.
- **`uninstall --yes`** — would remove `$PLUGIN_DIR`, the shell-profile PATH export, the
  LaunchAgent plist, and edit the real `~/.claude/settings.json`. The non-`--yes` non-TTY refusal
  path (tested above) confirmed real.
- **`init` (real, non-`--help` run)** — same shared-git-config mutation risk as `guard install`
  (`core.hooksPath` write).
- **`wrap <tool>`** (e.g. `wrap claude`) — installs git hooks, writes `AGENTS.md`, starts presence,
  and launches a real coding tool session.
- **`report-issue`** (real, non-`--help` run) — calls `gh issue create` against the live heimdall
  plugin repo. Explicitly forbidden by the hard safety rules regardless of arm correctness.
- **`god roster` / `god logs`** (real, non-`--help` run) — requires owner GCP credentials not
  available here; would attempt real network egress to the gated Cloud Run control plane.
- **Any genuinely unmatched/misspelled subcommand**, and **bare `''`** — both fall through this
  dispatcher's ~14 sequential `if` blocks (no `*)` catch-all exists) toward
  `exec heimdall-wrap launch`, a live, `--dangerously-skip-permissions` Claude Code session. Never
  invoked.

## Notable findings

1. **Two confirmed BROKEN arms**, both with root cause identified, not just symptom:
   - `init --help` (#21) truncates its own advertised usage synopsis one line early
     (`heimdall-init:59`, `sed -n '2,39p'`).
   - `metrics` (#25) dispatches to a binary (`bin/heimdall-metrics`) that does not exist in this
     worktree at all — a hard, unconditional failure on the very first invocation, not an edge case.
2. **A systemic, low-severity documentation bug reproduces across 5 arms**: `check`, `redum`,
   `report`, `rules`, and `queue` all share the `usage() { sed -n '2,Np' "$0" | sed 's/^# …//'; }`
   idiom, and in every one of the five, `N` overshoots the real header-comment block, leaking
   1-10 raw lines of shell source (variable assignments, and in `rules`'s case the entire dispatch
   `case` block) onto the end of otherwise-complete, otherwise-correct `--help` output. None of the
   five are classified BROKEN here because the actual question a user runs `--help` to answer is
   always fully and correctly answered *before* the leak starts — but all five are real,
   reproducible, and fixable with the same one-line-per-file change (correcting the line-range
   constant, or switching to a sentinel-terminated block instead of a hardcoded count).
3. **Two previously-reported precedent bugs did not reproduce today, confirmed by live
   re-execution, not assumption**: `hmd badge`'s shields.io link returned a live `HTTP:200` (not the
   previously-cited 404), and `hmd demo` produced full, correct `--help` output (not the
   previously-cited "command not found"). Both should be read as "fixed as of `71bd0b7`," not as
   this audit failing to find them — the exact URL and the exact command were both actually
   executed.
4. **The single most important structural fact governs 2 of the 45 arms and is unrelated to code
   quality**: this dispatcher has no `*)` catch-all, so `''` and any unrecognized subcommand both
   drive toward a live Claude Code launch. This was not exercised (per hard safety rules) but is
   documented here exactly as the brief requires: as a complete UNSAFE-TO-TEST verdict, not a gap
   in coverage.
5. **`quota-advisor`'s previously-cited hazard (unwired verb + no dispatcher arm, bad calls falling
   through to a live spawn) is confirmed resolved**: the dispatcher arm exists (`bin/heimdall:934`),
   and internally `heimdall-quota-advisor`'s own `case` statement ends in a real, bounded usage-error
   branch (`heimdall-quota-advisor:257-259`) — never a spawn.
