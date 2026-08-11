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

    Co-Authored-By: hmd <hmd@runheimdall.dev>

hmd is the constant. The model underneath varies — Claude today, something else
tomorrow, a different tool on a teammate's machine — and none of that changes who
gated the work. The trailer records the layer that held the line, not the one that
typed. Keep the model's own `Co-Authored-By` alongside it when there is one: both are
true, and dropping the model would be the same overclaim this repo exists to prevent.

The trailer is a TRAILER, deliberately. Author and committer stay human, because
`heimdall-selfscan`'s identity gate allowlists `%ae`/`%ce` and a human is the one
accountable for a push — "a human always gates the merge" has to remain literally
true. Trailers sit outside that gate, so this adds no allowlist surface.

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
- Caveman ultra mode active: terse output, abbreviations, arrows for causality
- Drop articles, filler, hedging — code and paths stay exact
