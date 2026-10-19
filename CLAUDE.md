# Project Conventions (managed by heimdall)

## Parallelism (MANDATORY)
- 2+ independent tool calls → send ALL in ONE message (batch Read, Write, Edit, Bash)
- 2+ independent tasks → spawn ALL agents in ONE message with `run_in_background: true`
- Task touches 2+ independent files → one agent per file, ALL spawned together
- NEVER: spawn agent → wait → spawn another agent for independent work
- NEVER: read file → read next file → read next file (batch all reads in one message)
- NEVER: pass `name:` to Agent unless you will `SendMessage` it — `name:` → mailbox-resident agent, never self-terminates, never returns a result (measured 0/43 named completed vs 59/66 unnamed)
- Identify a spawn's work via `description:`, never `name:` (R13)
- The `PreToolUse` `Agent` hook WARNS on `name:` (stderr, exit 0) — it does not block. Name one → you own its lifecycle: collect via `SendMessage`, close with `TaskStop`, sweep leaks with `bin/heimdall-agents orphans`

## Rules
- All code, configs, docs go in this project directory
- Planning state lives in `.planning/` (human-readable, git-committed)
- Each completed task = one atomic git commit
- Acceptance criteria must be runnable (grep, curl, test commands)

## Commit attribution
Every commit produced through hmd carries:

    Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>

hmd is the constant identity — the model underneath varies (Claude today,
something else tomorrow, a different tool on a teammate's machine) and none of
that changes who gated the work. The trailer records the layer that held the
line, not the one that typed. Rendered through the real `runhmd` GitHub machine
account (id `318965969`) rather than a plain-text address, so it links: see
"GitHub account, not a plain-text address" below. The display name is `runhmd`,
not `hmd` — only the email drives GitHub's account match, so the name is purely
cosmetic, but matching it to the account's actual login means nobody reading
history has to wonder why the visible name and the linked handle disagree.

**The model's own `Co-Authored-By` is stripped, not kept alongside it** (owner
directive, 2026-08-20). This reverses what used to be written here: "keep the
model's own trailer alongside it… dropping the model would be the same overclaim
this repo exists to prevent." The repo owner — the one human accountable for
every push (see the identity gate below) — asked for commits to show their own
identity and hmd's, and nothing else. hmd is what gated the work, so hmd is the
trailer that stays; a doc asserting the old behavior while the hook does the new
one is exactly the drift this repo keeps getting bitten by, so the paragraph is
rewritten here rather than left stale beside the new code.

The trailer is a TRAILER, deliberately. Author and committer stay human, because
`heimdall-selfscan`'s identity gate allowlists `%ae`/`%ce` and a human is the one
accountable for a push — "a human always gates the merge" has to remain literally
true. Trailers sit outside that gate, so this adds no allowlist surface. The gate
reads only the author/committer EMAIL, never the display name — changing
`user.name` (e.g. to a GitHub username) has zero effect on it.

**Mechanically enforced, not just documented.** A generated `prepare-commit-msg`
git hook (`.heimdall/hooks/prepare-commit-msg`, emitted by `hmd init` from
`bin/heimdall-init`) appends the hmd trailer to every commit message that doesn't
already carry it, and strips two things first, unconditionally, before deciding
whether to add: any Anthropic/model `Co-Authored-By` line, and any trailer still
using the OLD `hmd@runheimdall.dev` address retired on 2026-08-20. The Anthropic
strip matches by email DOMAIN (`@anthropic.com`), never the model's display name
— that name changes every release ("Claude Opus 5 (1M context)", "Claude
Sonnet 5", …) but the address stays `noreply@anthropic.com` regardless, so
domain-matching never lags a new model name and never risks catching a real
human co-author. The old-address strip matches the exact retired email, bounded
to the `<...>` field rather than the whole domain — unlike anthropic.com,
`@runheimdall.dev` is also the human owner's own author/committer address and
could plausibly host a real teammate's address too, so only the one retired
local part (`hmd@`) is matched, never the domain. Together the two strips mean a
message can never end up with an old-address trailer, a stray model trailer, and
the current trailer all at once — every rename and every model swap normalizes
to exactly one hmd line, it never stacks. This is the one client-side hook `git
commit --no-verify` does NOT skip — verified empirically, not assumed — which is
why prose alone (agents were told to add this trailer in their spawn prompts and
still routinely didn't: 55/81 commits since 2026-08-18 had it, 26 did not) isn't
enough on its own and this now lives in a hook too. Append-and-strip, all
idempotent: never duplicates the hmd trailer, never leaves a stray model or
old-address trailer behind, and fails OPEN on anything malformed or unwritable —
an attribution trailer is bookkeeping, not a correctness gate, and must never be
the reason a commit is lost. History before this hook existed was NOT rewritten
(~195 unpushed commits at the time — that would have changed every SHA); this
is enforced going forward only, and the same applies to the address rename
itself — commits already made with the old address keep it. See
`test/prepare-commit-msg-trailer.test.sh` (the proof).

**GitHub account, not a plain-text address** (owner directive, 2026-08-20 —
supersedes the "GitHub rendering limitation" this section used to document under
the retired `hmd@runheimdall.dev` address). GitHub only links a `Co-Authored-By`
to an account when the email is verified as belonging to that account; no
GitHub account ever had `hmd@runheimdall.dev` (verified: `gh api
"search/users?q=hmd@runheimdall.dev+in:email"` → `total_count: 0`), so it always
rendered as plain text, with no avatar — and that would have stayed true
regardless of whether the domain itself could receive mail, since GitHub's
account-email verification is the only thing that matters here, not general
deliverability. The owner created a real GitHub account for this instead
(`runhmd`, id `318965969`, type `User`) and the trailer now uses that account's
own GitHub-minted `<id>+<login>@users.noreply.github.com` form — an address
GitHub itself issues and already recognizes for that account, so it needs no
mail delivery or separate verification step and is guaranteed to render as a
linked co-author with an avatar.

## Quality Gates (enforced before git push)
- All tests passing
- Lint clean (zero warnings)
- Code review completed
- No untested changes
- Canonical checklist agents cross-check: `skills/heimdall/references/definition-of-done.md`

## When the full gate runs — ONCE, immediately before the landing commit
Test once, at the end — operator directive 2026-10-08: avoid over-testing the same
stuff; save testing for the end. The full sweep (`bash test/run-all.sh`, ~524 suites,
~45-60 min cold) runs at exactly one moment: on the final frozen tree, immediately before
whichever of these comes first — the commit that lands a completed unit of work, the
push, a demo, a `/hmd:save` checkpoint of finished work. One sweep serves all of them
while the tree stays unedited. Not at session start, not after each file edit, not
after each merge, not at mid-work checkpoints (`wip:` auto-commits, a save of
unfinished work), not "whenever it feels done". Running it more often costs half an
hour a pop and — worse — grades a tree that is still being edited, which attributes a
verdict to a state of the code that never existed.

- **Freeze the tree first.** `run-all.sh` reads the working tree as it finds it. No
  edits, and no agents editing, while it runs. A verdict over a moving tree is not a
  verdict.
- **Quiet gate (`--wait-quiet`, opt-in).** Use it on a shared, busy machine to start
  the sweep on a settled box. It is relative and bounded: it waits until the 15-min load
  average is below `HMD_QUIET_FACTOR` (default 1.5) × CPU count on 3 consecutive 30 s
  checks, and gives up after `HMD_QUIET_MAX_WAIT_S` (default 1200 s). Do not use an
  absolute load threshold to block a sweep; it can stay high for hours and defer the run
  forever. On a shared busy machine, lower `--jobs` instead of waiting. When the bound
  passes, the sweep runs anyway with half the jobs and `HMD_TEST_REDUCED_PARALLELISM=1`.
- **Disk floor — 10% free, enforced by hooks (operator directive 2026-10-14).**
  Agent spawns, test runs and single test files all stop below a floor of free disk: a
  full disk fails in ways that look like bugs, and the dev machine was at 7.1% free
  (16.4 GB of 228 GB) while agents ran suites that write fixtures, clones and temp data.
  One definition, `bin/lib/hmd_disk_floor.sh`: the free percent of the volume holding
  TMPDIR and of the one holding the repo (`df -Pk`, Available ÷ size — not df's own
  Capacity column, which on APFS leaves out every other volume of the container),
  against `HMD_MIN_FREE_PCT` (default 10; the operator runs 7 for now; 0 turns it off; a
  typo such as `7%` is the default, said on stderr, never a silent off). Three
  enforcement points: **(1)** the Agent hook (`bin/heimdall-precheck-agent`) DENIES a
  spawn, ahead of the in-process cap so a refused spawn stakes no lease; **(2)** the Bash
  hook (`bin/heimdall-precheck-bash`) DENIES a command that RUNS a `*.test.sh` or
  `test/run-all.sh` (`bash test/x.test.sh`, `./test/x.test.sh`, `cd d && bash x.test.sh`,
  an env prefix, `time`/`timeout`, `sh -c` — never `bash -n`, `cat`, `grep`, `git add` or a
  commit message that only mentions one): one central check, no test file edited;
  **(3)** `test/run-all.sh` REFUSES to start (exit 5, nothing left behind) beside its
  absolute floor `HMD_TEST_MIN_FREE_GB` (default 5; whichever is stricter refuses), and
  asks again before every suite and every solo re-run: once a floor is crossed mid-sweep
  it launches nothing more, the unstarted suites are `REFUSED` (a table row,
  `suites_refused` and `disk_floor` in the receipt, and in `non_green_suites` so the next
  incremental sweep carries them forward) and the run is red (exit 1) — a sweep cut short
  never reads as a sweep that passed. Set the override in the environment Claude Code
  runs in: a hook reads its own environment, so an inline `HMD_MIN_FREE_PCT=5 bash
  test/x.test.sh` reaches the test but not the hook that has already said no. A df that
  cannot answer warns and allows — this is a resource guard, not a security gate. A suite
  that drives the REAL spawn hook pins `HMD_MIN_FREE_PCT=0` (as `agent-name-gate` pins
  `HMD_CTX_GATE_OFF=1`) so it never depends on the disk it runs on. `bin/heimdall-disk-floor
  check` shows where you stand. Proof: `test/disk-floor.test.sh`.
- **Start it only when no follow-up fix is still possible.** A sweep begun while a
  reviewer, verifier or agent can still hand back a change is spent the moment that
  change lands: its receipt is stale and every suite that change reaches runs again.
- **Batch before you sweep (operator directive 2026-10-11).** Collect every pending
  agent result and merge them ALL, then run ONE sweep. Never merge anything between a
  green sweep and its push. If new work arrives after a sweep started, queue it for
  the next batch instead of merging. A failing suite gets fixed, and the fix rides the
  next batch (`--failed`, below); a small follow-up batch costs what it reaches, since the
  sweep is cached (below). Never start a second sweep while one runs. Measured 2026-10-11:
  ~9 full sweeps (~70 min each) in one day — merging agent fixes one at a time staled the
  last green receipt every time, two sweeps overlapped, one wait sat for hours on an
  absolute load threshold, and whole sweeps were re-run to tell load flakes from real
  failures (re-run the one failing suite solo instead).
- **The sweep is cached: it re-runs what a change can reach (2026-10-20).** `bash
  test/run-all.sh` serves a suite from `.heimdall/receipts/suite-cache/` (a `CACHED` row,
  counted green) while its closure hash (every tracked file it can read, found statically
  by `bin/heimdall-suite-closure`) and the runner salt (`run-all.sh` minus comments, its
  guard libs, the engine, tool versions) are unchanged and the entry is under 7 days old.
  max(20, 10%) of the hits re-run anyway (seeded by HEAD and the salt); an audited suite
  that fails with an unchanged closure is `CLOSURE UNSOUND`: red run, cache purged. Each
  green is stored the moment it finishes, so a red, stopped or cancelled run keeps what it
  proved. The receipt stays `kind:"full"` plus a `cache` block and `full_equivalent`; the
  push gate and the release script re-derive it (`bin/heimdall-suite-closure
  verify-receipt`), never on the flag's word. `--cold` (or `HMD_COLD=1`) ignores the cache
  and runs every suite: an x.y.0 release needs that cold receipt, a patch release takes a
  cache-composed one, and the first sweep after a runner change is cold by itself.
  `--no-cache` skips it (legacy receipt). It is also off, said on the `cache:` line, for a
  dirty tree, `--filter` and an incremental `--since-green` (the older textual selection,
  still there; the cache is what follow-up batches use).
- **After a red: `--failed`, never a second full sweep.** Fix, commit (a dirty tree turns
  the cache off and `--failed` refuses, exit 2), then `bash test/run-all.sh --failed`: it
  re-runs the last receipt's non-green suites, every suite whose closure the fix moved and
  the audit sample, serves the rest from the cache, and composes a gate-grade receipt
  (`amended_from`, `amended`). A test-only fix re-runs that suite and the sample, not the
  sweep. Not combinable with `--cold`, `--no-cache`, `--since-green` or `--filter`.
- **Order, `--fail-fast`, keep-awake.** Suites start failed-last-time first, then
  changed-closure, then new, then slowest-first. `--fail-fast` stops starting suites once
  a red is confirmed by its solo re-run, so a red shows in minutes, not at the end; a run
  it stops early writes `kind:"aborted"`, which the push gate and the release script refuse
  by name, so after one: fix, commit, `--failed`. On macOS the runner holds `caffeinate -i
  -w <its pid>` for the whole sweep, so the machine cannot idle to sleep mid-run
  (`HMD_NO_CAFFEINATE=1` opts out).
- **Per-suite runs: your own suite only, once.** An agent runs
  `bash test/<one>.test.sh` for ONLY the test file(s) it adds or edits, ONCE, after
  ALL its changes are written — no neighbouring or "regression" suites, no baseline
  sweep. Once means once per state of the tree: a re-run needs an edit that targets
  the failure (the TDD RED run and a break-it-and-watch-it-go-RED check each run a
  different tree), while a second run of an unchanged tree is the waste. A failure
  plausibly caused by machine load (timeout, port clash, agents running alongside)
  gets ONE solo re-run, then it is real: fix it or report it. Regressions elsewhere
  are the sweep's job.
- **The orchestrator does not re-run suites per merge.** It takes each agent's
  reported run as given, integrates, and runs the one sweep at the end.
- **Measured, 2026-10-08 chat-replies wave:** three coder agents hit their 50-turn
  limit mid-regression after running 10–25 neighbouring suites each, one suite was
  re-run three times under load, and the orchestrator re-ran the same suites after
  merging, then cancelled a full sweep when fixes landed.
- **The `git push` hook stack is unchanged and stays.** It is a fail-closed backstop,
  not a duplicate of this rule: the pre-commit sweep is the agent's discipline, the
  pre-push gate is the machine's guarantee.
- **Already machine-enforced.** `bin/heimdall-conformance` reads the session
  transcript and fails `gate-runs-once` (two full-gate runs with no edit between them)
  and `gates-at-end` (the first full-gate run must come AFTER real work). It also fails
  `sweep-staled-by-merge` (a green sweep, then a merge or commit of real work before
  the push, then another sweep) and `sweeps-overlap` (two full-gate runs whose
  start/end intervals overlap). This section
  is the human-readable statement of a rule the enforcer already checks — if the two
  ever disagree, the enforcer is authoritative and this text is the bug.

## Pre-commit vs pre-push: what stays at commit, what dedups at push
Two things are easy to conflate and must not be: the ~1600s full sweep above (never
auto-run, gated by the enforcer) and the small, real per-gate checks below (auto-run by
design, on every commit/push). "Checks run too often" is only a defect in the second
group, and only where the SAME check fires twice for one action.

- **The stub-scan and the oracle-falsifiability + corpus-regression gates stay at
  pre-commit, on purpose — this is a deliberate divergence from "only run just before
  push".** Agents commit with `--no-verify`, so the native pre-commit hook never fires
  for agent-driven commits; it exists for a human or a non-Claude-Code tool committing
  directly, who never goes through the PreToolUse layer at all and may never even
  `git push` this branch. Deferring these checks to push would mean a broken commit
  sits in history with the author having already lost the context they had at commit
  time — for the stub-scan that cost is especially stark, since it is diff-scoped and
  near-free precisely because it runs at the moment the bad line is introduced. This is
  tested, documented behavior (`test/heimdall-init.test.sh`'s staged-bad-domain case,
  `test/gate-receipt-truth.test.sh` Section A) — not an oversight to "fix" by moving it.
- **The oracle + corpus gates WERE genuinely duplicated at push, and that is fixed.**
  Both the native `.heimdall/hooks/pre-push` hook (`bin/heimdall-gate-run --phase
  pre-push`) and the Claude-Code PreToolUse `git push` chain ran the identical
  falsify-per-domain loop and `bin/corpus run` — back to back, on every agent-issued
  push, for the same result. Measured against this repo's own oracle corpus: one pass
  costs on the order of a minute; paying it twice per push was pure waste, and the real
  substance behind "checks running all the time". The PreToolUse chain now checks
  whether the native hook is actually wired (`core.hooksPath` = `.heimdall/hooks` and
  `.heimdall/hooks/pre-push` is executable) and, if so, defers to it — loudly, on
  stderr, never silently — instead of re-running the same work. If the native hook is
  NOT wired (a fresh `git worktree add`, before `hmd init` has materialized
  `.heimdall/hooks` there, runs with none), coverage is unchanged: the inline check
  still runs. `HMD_SKIP=1` cannot be used to make the PreToolUse layer defer on the
  assumption the native hook will cover it, since `HMD_SKIP` is that native hook's OWN
  bypass and has never reached the PreToolUse layer — widening its reach silently would
  be a real gate weakening, so the dedup guard explicitly excludes it.
  See `hooks/hooks.json` (the guard) and `test/pre-push-gate-dedup.test.sh` (the proof).

## Push gate: each repo's own checks, not heimdall's (2026-10-13)
The PreToolUse push chain (`bin/heimdall-precheck-bash`) used to run heimdall's sweep gate
(`heimdall-state check-quality-gates`: the state booleans, the lint receipt and
`.heimdall/receipts/last-sweep.json`) in the session's cwd for ANY push, so a push of another repo
(the site, with six gates of its own) was blocked for lacking a receipt only heimdall's
`test/run-all.sh` can write. Operator rule, verbatim: *run each repo's own checks, not heimdall's; a
repo with its own record of passing checks passes on that record; a repo hmd doesn't manage gets a
warning but isn't blocked; don't drop the gate altogether.* The gate is now chosen per repo pushed:

- **Which repo.** `bin/lib/hmd_push_target.py` reads the command the way a shell does (the cwd,
  `git -C <dir>` chains, `cd <dir> && ...`, subshells, wrappers, `sh -c`, `export GIT_DIR=...`) and
  asks **git itself** which git directory each push operates on: the same options and `GIT_*`
  environment go to `git rev-parse`, and the work tree root it finds is checked from the other end.
  `--work-tree` / `GIT_WORK_TREE` cannot point a push at a decoy, and a subdirectory or linked
  worktree of heimdall is heimdall. That (git directory, work tree) pair is resolved ONCE (2026-10-14)
  and is the one every stage reads: the class and the refspec sources are read with `GIT_DIR` and
  `GIT_WORK_TREE` pinned to it, each resolver row carries it (`class<TAB>work tree<TAB>extra<TAB>git dir`),
  the hook hands it to `heimdall-repo-checks status --git-dir` (which verifies it from both ends, reads git
  with the pair pinned and the receipt inside that work tree) and runs `heimdall-state` in that work tree
  with the same two variables exported. Nothing re-derives "the repository" from a path, so the stages
  cannot end up looking at different ones. A `GIT_*` variable the resolver does not reproduce
  (`GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`, `GIT_NAMESPACE`, `GIT_INDEX_FILE`, ...) would give the push
  another view of the refs than the gate reads, so it makes the command uncertain; the transport and
  identity ones (`GIT_SSH_COMMAND`, `GIT_TERMINAL_PROMPT`, `GIT_TRACE*`, ...) keep the class.
- **The class is read from the COMMITS, not the work tree.** The commits inspected are HEAD, its
  upstream (`@{upstream}`, `@{push}`), `origin/HEAD`, `origin/<branch>` and whatever the push names
  (refspecs, `--all`, `--mirror`, `--tags`), read with `git ls-tree` / `git cat-file`; the STRICTEST
  class over them wins. An uncommitted marker edit, deletion or new file on disk changes nothing, and a
  pushed commit that drops a marker cannot downgrade a repo whose upstream still has it.
- **(a) sweep.** Marker: a commit has `test/run-all.sh` as a regular file that names `last-sweep.json`
  (heimdall's own sweep regime; that script writes the receipt `check-quality-gates` reads). The marker
  is tracked code, never the receipt, so deleting a receipt cannot downgrade a repo, and another
  project's `test/run-all.sh` is not mistaken for it. The old gate, unchanged and fail closed, now run
  inside that repo (a cwd in a subdirectory reads the toplevel's state).
- **(b) repo-checks.** A commit has `.heimdall/repo-checks.json` = `{"schema":1,"checks":[{"name","cmd"}]}`.
  `bin/heimdall-repo-checks run [--repo PATH]` runs each check from the repo root, in order, and writes
  `<repo>/.heimdall/receipts/repo-checks.json` atomically. The gate passes ONLY on a receipt that is
  green, recorded on a tree with no uncommitted tracked changes, bound to the commit (`head_sha`), its
  tree (`tree_sha`) and the declaration's committed bytes (`decl_sha256`) (all three recomputed by the
  gate from git objects), listing exactly the declared checks, **and for the commit the push sends**: the
  resolver resolves each refspec's source with git (`origin other`, `HEAD~1:main`, `<sha>:main`, a tag;
  HEAD for a bare push) and hands the ids to `status --pushes`, and EVERY one must be the receipt's
  `head_sha`. `--all`, `--mirror`, `--tags`, a wildcard refspec, an option it cannot read (`--repo`) and
  push configuration that picks the refs (`push.default=matching`, any `remote.<name>.push`) cannot be
  tied to one receipt and block; a ref that names no commit makes the whole push the strict class. A
  push that sends no commit (`:branch`, `--delete`) needs only the current receipt. Stale, red, dirty,
  missing, mismatched, malformed, invalid, or an absent runner blocks, and the block names the runner
  command (`status [--repo PATH] [--pushes IDS]` prints the verdict). The hook reads the receipt and
  never re-runs a repo's commands. Track `repo-checks.json`, gitignore `.heimdall/receipts/`. The
  receipt's fields, types and formats are defined ONCE, in `bin/lib/hmd_repo_receipt.py`, which `run`
  builds the receipt with and `status` verifies it against (the test walks that definition: a receipt
  `run` writes passes, every field mutated alone fails).
- **(c) unmanaged.** One `WARNING` line on stderr, exit 0, and only when the command was understood
  EXACTLY, git resolved the repo, and no commit inspected has either marker.
- **A resolver that cannot answer is graded against EVERY candidate (2026-10-14).** A timeout
  (`HMD_PUSH_TARGET_TIMEOUT_S`), a crash or a missing file never falls back to ONE repository: the strict
  gate runs against the session's cwd, the payload's cwd and each `-C` / `cd` / `--git-dir` / `--work-tree`
  directory the parser had reached (the resolver prints them itself when it fails, without asking git; the
  hook adds the two cwds when it gets nothing at all), and the push is blocked unless all of them pass. A
  push git names but whose repository cannot be placed (a dotfiles layout: `--git-dir=X --work-tree=Y` with
  no link back from Y) is graded on those directories too, not only on the cwd's. A gate directory the
  hook cannot enter blocks (a candidate that does not exist is skipped: nothing can be pushed from it). The
  receipt is read as one regular file inside the repository (no link in `.heimdall` or `receipts` is
  followed, at most 1 MiB, one commit named once and used throughout), never as whatever a path leads to.
- **Fail closed.** Any construct not modelled exactly makes the whole command uncertain, and then EVERY
  repo involved (the resolved ones and the cwd one) gets class (a), never a warning. Followed exactly:
  quotes, `~`, `;` `&&` `||` `|` `&`, subshells, `$( )` and backticks, `cd`/`pushd`/`popd` as a SET of
  possible states (an `&&`/`||` runs its right side only on success/failure; a `cd` into an existing
  directory cannot fail; both outcomes of `test -d X && cd X` are gated; the last element of a pipeline
  may run in the current shell, as in zsh, so both outcomes are gated), `eval` (runs in the current
  shell), `sh -c`, here-strings, heredocs and pipes fed to a shell, `env`/`sudo`/`command`/`exec`/
  `time`/`nohup`/`xargs`, `export GIT_DIR=...`. Flagged: a dynamic `cd`, `cd -`, CDPATH, a `cd` inside
  if/while/for/case or `{ }`, a builtin (`cd`, `export`, `eval`, ...) behind a wrapper that starts a
  process (`env cd X`, `xargs cd X`, `sudo cd X`: it does not run in this shell), `env` with any option
  (`-u`, `-i`, `-C`, `-S`), an assignment to `HOME`, `CDPATH`, `PWD`, `OLDPWD`, `BASH_ENV` or `ENV`, a
  function, `source`, `alias`, a script piped to a shell, an expansion that hides a substitution, a
  heredoc body the shell expands, `find -exec` and other commands whose arguments name git and push,
  `xargs` handing over the subcommand, `sudo -D`/`-i`, a git option or subcommand it does not know (an
  alias may be a push), an unmodelled `GIT_*` variable, a cwd that is not a repo, a marker that cannot be
  inspected (a link, a submodule, a directory, a failing git). Proof: every command of a corpus is RUN
  by real bash (and zsh) with a git that records where it was started, and the repositories the pushes
  really went to are compared with the resolver's answer.
- **Every error path is strict.** git that exits non-zero, times out, answers with something it does
  not print, or cannot place a ref; a marker that is a link, a submodule or a directory; a resolver that
  crashes, times out or names a class nobody knows; a receipt or declaration that is unreadable, the
  wrong type or nested past the parser's limit: each is the strict class or a block, never the
  unmanaged warning and never a pass. The test forces each (a `git` on PATH that fails, prints
  nonsense or hangs at each call the resolver makes; corrupt receipts and declarations). A resolver
  that is missing or crashes means the old sweep gate on the cwd. Best effort, said plainly: shell
  cannot be read completely (a script can push), so the native hook (`core.hooksPath`) stays the hard
  backstop.
- **A cooperating-agent control, not a security boundary.** Like `last-sweep.json`, the repo-checks
  receipt is a plain local file: the binding catches stale, copied, mismatched and
  hand-edited-by-accident receipts, not someone who can write the file and its hashes.
- **Not relaxed.** The push-range secret scan, the full-history self-scan, the oracle and corpus
  stages, the commit secret gate, git-guard and the kill guard are not part of this rule: they run as
  before and still read the session's cwd repo. Proof: `test/heimdall-push-gate-per-repo.test.sh`
  (classes, forged receipts, fail-closed, a differential against git itself) and
  `test/heimdall-push-gate-target-repo.test.sh` (the operator's case: the session is in heimdall and
  the push goes to X by `cd X && ...`, by `-C X`, or from X itself, each graded on X's own record).

## CI waste guard: never pay to re-roll a flaky result (2026-10-19)
In a client repo an hmd agent worked around a flaky test by pushing an EMPTY commit to retrigger CI and by
re-running the workflow twice: every attempt spent GitHub Actions minutes and the flake was still there.
Operator rule: *a flaky failure is a defect: fix it or report it, never re-roll CI.* The Bash hook
(`bin/heimdall-precheck-bash`, FIRST in its chain, so a refused command never reaches git-guard or the
secret scan) now denies, through `bin/lib/hmd_ci_guard.py`:

- **Empty commits.** `git commit --allow-empty`, wherever the flag sits among the commit's options and
  behind any of git's global options (`-C d`, `-c k=v`, `--git-dir`, ...). `--allow-empty-message`,
  `--no-allow-empty`, and a `-m` value or a path that merely spells the flag are not it.
- **CI re-runs and re-dispatches.** `gh run rerun` (any flags: `--failed`, `--job`, `-R`),
  `gh workflow run`, and a `gh api` POST (`-X POST`, `--method POST`, the POST gh makes by itself once
  `-f`, `-F`, `--field`, `--raw-field` or `--input` gives it a body, or a method that cannot be told) to an
  endpoint ending `/rerun`, `/rerun-failed-jobs`, `/dispatches` or `/rerequest`.
  `gh run list|view|watch|download|cancel`, `gh workflow list|view|enable|disable` and a GET of those
  endpoints stay allowed.
- **Read like a shell, never by grepping text.** The helper reuses the kill guard's lexer
  (`bin/lib/hmd_kill_guard.py`: quotes, `env`/`nice`/`timeout`/`sudo`/`xargs`, chains, pipes, subshells,
  loops, `sh -c`, `eval`, heredocs fed to a shell) and the git option table of
  `bin/lib/hmd_push_target.py`, so text that only MENTIONS a form (echo, grep, a commit message or its
  heredoc, a gh field value) is not a form. A pre-filter starts python only for a command that mentions
  `allow-empty`, `rerun`, `rerequest`, `dispatches` or `workflow ... run`; every other command pays one
  `tr` and one `case`.
- **Operator override: `HMD_CI_RERUN_ALLOW=1`**, set in the environment Claude Code runs in. The hook reads
  ITS OWN environment, so an inline `HMD_CI_RERUN_ALLOW=1 git commit --allow-empty ...` reaches git but not
  the hook that has already said no (the same as `HMD_MIN_FREE_PCT`); only exactly `1` lifts it, and nothing
  of the guard runs then.
- **Fails OPEN, on purpose.** A cost guard, not a security gate: the disk floor's convention, not the kill
  guard's. A helper that is missing, crashes or times out (`HMD_CI_GUARD_TIMEOUT_S`, default 5), or a
  command it cannot read (an unbalanced quote, an expanded heredoc, nesting past 8), is one line on stderr
  and an allow; a form it DID read wins over what it could not. Best effort, said plainly: git and gh are the
  two tools it reads (curl against the API, a git or gh alias, a script on disk are not), and like the push gate's
  receipt it is a cooperating-agent control, not a security boundary.
- **What to do instead** (also in `skills/heimdall/references/definition-of-done.md`, `agents/coder.md` and
  `agents/fixer.md`): fix the flake (a test must not depend on the wall-clock speed of a shared runner:
  count steps, not seconds, or mark it local-only) or report it. Proof: `test/ci-waste-guard.test.sh`.

## Model routing (2026-08-11 directive)
- **Main Claude Code agent: never pinned.** It runs on the user's own default. hmd
  does not hardcode opus — or anything else — for the main agent.
- **Default coding tier: `sonnet`.** The bare alias, so Claude Code resolves the
  current generation (Sonnet 5 today, its successor tomorrow, with nothing to edit).
- **opus is retained only for adjudication**: `reviewer`, `verifier`,
  `security-auditor`. Judging work is where the extra capability pays for itself.
- **Fable 5 is escalation-only** — for a task *looping on bad output*, after sonnet
  and opus have both failed at the same step. It is not a routing default. It is also
  NOT ZDR (30-day retention), so client repos need `repo-policy allow_non_zdr_models`.
- Never write a full pinned model id into an operational spawn. The tier alias is the
  contract; `HEIMDALL_MODEL_<TIER>=<full-id>` exists solely for bench reproducibility.

## Code Quality — Zero Tolerance
- NEVER write stub, dummy, placeholder, shim, mock, TODO, or skeleton code
- Every line must be real, working, production-ready
- No `// TODO: implement`, no `pass`, no empty function bodies, no fake data
- If you cannot implement something fully, say so — do not fake it

## Style
- Follow existing patterns in the codebase
- Prefer small, focused files over large monoliths
- Name things clearly — a reader should understand without context

## Edit Verification
- All Write/Edit ops auto-logged by `edit-tracker` (PostToolUse hook)
- Run `verify-edits` to check all session edits: file existence, stub detection, git diff
- Run `verify-edits --quick` for fast check, `--diff` for full diffs, `--json` for structured output
- `edit-tracker summary` shows files edited + operation counts
- `edit-tracker paths` lists unique edited file paths
- SessionEnd auto-runs `verify-edits --quick`

## Token Efficiency
- Caveman compression active: terse output, abbreviations, arrows for causality
- The LEVEL is owned by hmd directly as of 2026-08-30 (`bin/heimdall-caveman`, wired as `hmd caveman get|set|rules`) — ownership moved in-house from the external caveman plugin (github.com/juliusbrussee/caveman, MIT) so compression no longer hard-depends on that plugin being installed. A one-time migration reads the plugin's old `.caveman-active` flag if hmd has no state of its own yet; after that hmd's own `$HEIMDALL_HOME/caveman-level` is authoritative and is never overwritten by a later plugin-flag change
- Collapsed to a SINGLE settable level, `ultra`, on 2026-09-01: hmd's audience is assumed technical — a fixed assumption baked into the level, not a setup question; no code asks one, so the gentler `lite`/`full` tiers had no separate audience of their own. `get`/`set`/the stored state file are ultra-only now; a stored or requested legacy `lite`/`full` value is accepted and mapped forward to `ultra` with a stderr notice — never a hard error, since a legacy value must never wedge the tool or emit nothing. `rules lite`/`rules full` still render by explicit name only, kept solely for `heimdall-caveman-eval`'s existing committed comparison — neither is an operator-facing level any more. The `diff` subcommand was retired alongside this: its only non-degenerate use (comparing two different real levels) no longer exists with one level
- This ownership move is not cosmetic: the plugin has been observed, first-hand on this repo's own session (2026-08-30), silently rewriting its OWN flag file back to its default (`full`) on session restart — an operator who set `ultra` got `full` back with no notice, which would also silently invalidate a compliance measurement taken afterward. hmd's stored level is immune (a different file, never written by the plugin), but every `hmd caveman get` (and therefore `rules` with no explicit level) also re-checks the plugin's live flag on every call and prints a one-line divergence warning to stderr — never stdout — when the two disagree; hmd's stored value always wins
- This is a change of WHO SETS the level, not of WHETHER a hook can prove compliance — a SessionStart/UserPromptSubmit hook can only inject instruction text, never verify the model followed it. Measured on this repo's own session while the plugin was active at `full`: 3.25% of prose chars were still caveman-targeted filler. Read-back audit: `hmd caveman-audit <session.jsonl>` (measures, never gates)
- Drop articles, filler, hedging — code and paths stay exact
