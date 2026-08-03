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

## Quality Gates (enforced before git push)
- All tests passing
- Lint clean (zero warnings)
- Code review completed
- No untested changes
- Canonical checklist agents cross-check: `skills/heimdall/references/definition-of-done.md`

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
