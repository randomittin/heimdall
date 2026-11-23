# Pre-commit vs pre-push, and the push gate: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

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
  project's `test/run-all.sh` is not mistaken for it. The gate (`heimdall-state check-quality-gates`,
  fail closed, run inside that repo: a cwd in a subdirectory reads the toplevel's state) passes its sweep
  part on EITHER a green full-equivalent sweep receipt for HEAD (the old rule, unchanged) OR, since
  2026-11-22 (operator decision "B": a push stands on the use-case journeys, a release on the full sweep),
  a green use-case journey receipt: `.heimdall/receipts/use-cases.json`, written by `bash
  test/use-cases/run.sh` after a green FULL run on a clean tree. `bin/lib/hmd_use_case_receipt.py`
  re-derives it from git, never taking the file's word: the exact schema, a green run (every journey
  passed, every mutant killed), `head_sha` a commit this checkout has and `tree_sha` its tree, and that
  commit is HEAD or only the hooks' own journal and ledger commits came after it. A missing, red, forged,
  stale, garbled, linked or unverifiable receipt blocks (the failure names `bash test/use-cases/run.sh`)
  and leaves the sweep rule as it was; the state flags and the lint evidence still apply. The release script
  is untouched: a release still needs the full sweep receipt. Proof: `test/sweep-receipt-gate.test.sh` (M, N)
  and `test/pre-push-quality-gate-blocking.test.sh` (2b-2e).
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
- **(d) unplaceable (2026-11-23).** A push whose repository the resolver cannot PLACE (a variable, substitution, glob or brace in `-C`, `--git-dir` or
  `--work-tree`, option words held in a variable, or a directory the shell is in that it cannot follow: a `cd` to a variable, a conditional or looped `cd`,
  `source`, CDPATH, `env -C`) has no repository to run a gate in, and the strict gate of the cwd grades ANOTHER repository. Live, a `for r in <a> <b>; do ...
  -C <dir>/$r ...; done` loop from a cwd whose own gate was green pushed a repository whose own checks were red. The resolver now answers ONE row,
  `unplaceable`, and the hook denies it (`cannot place this push`, naming the push; no gate runs) whatever the cwd's gate says: restate the push with the
  directory written out, one command per repository, and each is graded on its own record (a literal `-C` or `cd` target is still graded exactly, inside a loop
  too). A variable in an option that does not name the repository (`-c`'s value) only makes the push uncertain (strict) with the repository still placed.
  Proof: `test/heimdall-push-gate-per-repo.test.sh` (B "unplaceable", the differential's MUST_BLOCK commands, C70-C74).
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
