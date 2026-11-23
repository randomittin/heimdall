# Release convergence: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

## Release convergence: one review, one sweep, then ship (2026-10-21)
Operator directive, 2026-10-21: *fix the too-much-testing and reiterating loop; deliver well, not
over-tested.* Measured on 2026-10-20/21: one release batch went fix → automated security finding on the
fix → fix → finding on that fix → ... (five rounds in one evening), each round re-reached ~500 suites
through a hub file, and a full review then opened a sixth round. The loop, not any single test, is
what ate the day. The rules:

- **One review round per release.** Review the release diff ONCE, after the batch is merged and before
  the sweep. Fixes to its findings are proven by their own RED→GREEN test; they are NOT re-reviewed.
  No second review of the fixes, no re-review of the whole diff.
- **Only BLOCKER/HIGH block a release.** MEDIUM/LOW findings go to `.planning/BACKLOG.md` and ride the
  next release, unless the fix is already written and tested. A finding that only exists because of a
  fix made this release is triaged the same way; it does not restart the cycle unless it is HIGH.
- **Background security-review findings** on hmd's own commits follow the same triage: HIGH → fix in
  this batch, otherwise backlog with one line. Never chain an agent per finding.
- **One sweep, last, and the developer's call.** Land every fix of the round, then recommend ONE full
  sweep on the frozen tree to the developer (why, command, cost: "When the full gate runs"), run it on
  their yes, then ship. The release script's receipt requirement stays: a release still needs the
  green receipt it checks, but the run behind it happens because the developer chose it at merge or
  release time, never because an agent started it to satisfy the script.
  A red suite after it: fix, commit, `run-all.sh --failed` (never a second full sweep).
- **Scope a fix agent to its finding.** No "while you're there" exploration, no listing of new
  candidate defects unless asked: a list becomes the next round.
- **Done means delivered.** A release that is green, reviewed once and HIGH-free ships; the backlog is
  where the rest of the perfection lives.
- **Enforced by the Bash hook, not by prose (`bin/lib/hmd_sweep_guard.py`, 2026-10-21).** The sweep rules
  did not hold as text, so `bin/heimdall-precheck-bash` DENIES a FULL `test/run-all.sh` (no `--failed`,
  `--since-green`, `--filter` or `--dry-run`) in three cases, checked in this order: a sweep is running
  (`receipts/sweep.lock` names a live pid: `a sweep is already running (pid N)`); the last receipt is red or
  aborted and its `head_sha` is HEAD or an ancestor of it (`last sweep was red at <sha>; fix, commit, then:
  bash test/run-all.sh --failed`); a green full receipt already covers HEAD, the same commit or only the
  hooks' own journal and ledger commits after it, tree clean (`already proven green at HEAD; nothing to
  re-test`). `--failed`, `--since-green`, `--filter`, a single suite and `--cold` while the cache is cold
  anyway (the salt changed: no suite-cache entry carries it) always go through. It runs after the CI waste
  guard and the disk floor, finds a real run with the kill guard's lexer (text that only mentions
  `run-all.sh` is no run), takes the repo from the script's own location, costs every other command one
  `case`, and FAILS OPEN like the CI waste guard (a missing or garbled receipt, a git failure or a timeout
  is one stderr line and an allow). The operator override is `HMD_SWEEP_ALLOW=1` in the environment Claude
  Code runs in (an inline prefix reaches the sweep, not the hook). Once a run is chosen, this guard still
  applies to it exactly as above; it recommends and starts nothing, so it neither replaces nor depends on
  the merge-time advice. Best effort, not a security boundary.
  Proof: `test/sweep-guard.test.sh`.
