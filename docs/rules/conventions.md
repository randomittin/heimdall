# Parallelism, model routing, edit verification and token efficiency: long form

Moved verbatim from `CLAUDE.md` on 2026-11-23 (operator directive: shrink `CLAUDE.md`, which every session and subagent loads, and remove redundancy). `CLAUDE.md` keeps a digest of each rule under the same heading; this file is the long form. "above", "below" and "the Wait guard" in the text refer to the original single file: [README.md](README.md) says where each section lives now. Change a rule here and in the `CLAUDE.md` digest together.

## Parallelism (MANDATORY)
- 2+ independent tool calls → send ALL in ONE message (batch Read, Write, Edit, Bash)
- 2+ independent tasks → spawn ALL agents in ONE message with `run_in_background: true`
- Task touches 2+ independent files → one agent per file, ALL spawned together
- NEVER: spawn agent → wait → spawn another agent for independent work
- NEVER: read file → read next file → read next file (batch all reads in one message)
- NEVER: pass `name:` to Agent unless you will `SendMessage` it — `name:` → mailbox-resident agent, never self-terminates, never returns a result (measured 0/43 named completed vs 59/66 unnamed)
- Identify a spawn's work via `description:`, never `name:` (R13)
- The `PreToolUse` `Agent` hook WARNS on `name:` (stderr, exit 0) — it does not block. Name one → you own its lifecycle: collect via `SendMessage`, close with `TaskStop`, sweep leaks with `bin/heimdall-agents orphans`

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
