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
The full sweep (`bash test/run-all.sh`, 320 suites, ~1600s) runs at exactly one
moment: right before the commit that lands a completed unit of work. Not at session
start, not after each file edit, not at mid-work checkpoints, not "whenever it feels
done". Running it more often costs half an hour a pop and — worse — grades a tree
that is still being edited, which attributes a verdict to a state of the code that
never existed.

- **Freeze the tree first.** `run-all.sh` reads the working tree as it finds it. No
  edits, and no agents editing, while it runs. A verdict over a moving tree is not a
  verdict.
- **Per-suite runs stay cheap and stay encouraged.** `bash test/<one>.test.sh` during
  work is the normal loop — run it constantly. What is restricted is the full sweep.
- **The `git push` hook stack is unchanged and stays.** It is a fail-closed backstop,
  not a duplicate of this rule: the pre-commit sweep is the agent's discipline, the
  pre-push gate is the machine's guarantee.
- **Already machine-enforced.** `bin/heimdall-conformance` reads the session
  transcript and fails `gate-runs-once` (two full-gate runs with no edit between them)
  and `gates-at-end` (the first full-gate run must come AFTER real work). This section
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
- This ownership move is not cosmetic: the plugin has been observed, first-hand on this repo's own session (2026-08-30), silently rewriting its OWN flag file back to its default (`full`) on session restart — an operator who set `ultra` got `full` back with no notice, which would also silently invalidate a compliance measurement taken afterward. hmd's stored level is immune (a different file, never written by the plugin), but every `hmd caveman get` (and therefore `rules` with no explicit level) also re-checks the plugin's live flag on every call and prints a one-line divergence warning to stderr — never stdout — when the two disagree; hmd's stored value always wins
- This is a change of WHO SETS the level, not of WHETHER a hook can prove compliance — a SessionStart/UserPromptSubmit hook can only inject instruction text, never verify the model followed it. Measured on this repo's own session while the plugin was active at `full`: 3.25% of prose chars were still caveman-targeted filler. Read-back audit: `hmd caveman-audit <session.jsonl>` (measures, never gates)
- Drop articles, filler, hedging — code and paths stay exact
