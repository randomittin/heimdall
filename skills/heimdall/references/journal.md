# Journal — durable, write-during narrative log

`bin/heimdall-journal` is a durable, git-committed, human-readable log of
findings, decisions, corrections, and communications, written the MOMENT
something is learned — not summarized once at session end. It exists because
a prior ~15-agent integration session lost enormous hard-won reasoning that
existed only in conversation and died at truncation. Every other persistence
piece in this repo saves *state* (what to resume). This saves *why* — the
reasoning a truncation would otherwise erase for good.

## Gap analysis — what already exists, what this actually adds

Read this before assuming a new store is needed; three of these look similar
enough to overlap and don't:

| Existing piece | What it covers | Why it isn't this |
|---|---|---|
| `bin/heimdall-checkpoint` + `.planning/CHECKPOINT.md` | Forward "what to resume" STATE | Rewritten in place each save — a snapshot, not a log. The reasoning behind *why* the state is what it is gets overwritten, not kept. |
| `bin/heimdall-resume-probe` + `.planning/RESUME-KEY.json`, `bin/heimdall-resume-brief`, `bin/heimdall-quota-resume` | Resuming a dropped session cheaply | Same category as checkpoint — forward state, not a narrative history. |
| `bin/lib/resume-contract.sh` (`.heimdall/resume-notes.ndjson`) | Short flat resume-grading notes (`in_progress`/`gated_decisions`/`held_branches`/`unpushed`/`open_warnings`/`refuted_claims`) | Its own header says the store "lives here, not in git" — gitignored by design. Closest existing analog to a `correction` entry (`refuted_claims`), but not git-committed, no evidence field, no free-text body. |
| `.planning/ledger/decisions.md` | Hand-curated, single-file ADR-lite log | Single-file, single-type, not sharded — concurrent writers collide on one file. No corrections/communications type, no evidence field. |
| `.planning/skills/` | Which skills are active/detected | Configuration state, not narrative. |
| `edit-tracker` hook + `verify-edits` | What files were touched, stub detection | Mechanical file-diff audit, not reasoning about *why*. |
| `bin/heimdall-metric` → `.planning/metrics.jsonl` | Numeric telemetry | Gitignored, numeric, not narrative — answers "how much", not "why". |
| claude-mem | Cross-session searchable observation index | Read-optimized, its own store, not git-committed to the repo, not append-only markdown a human can `cat`. |

**The genuine remaining gap, and it turned out narrower than it first
looked**: an append-only, git-committed, per-(day × writer) plain-markdown
file, so the *reasoning* behind a finding, decision, or correction survives a
truncation that conversation memory does not — with `correction`/`refuted`
as a first-class type (the most perishable, most valuable kind of entry: a
claim already acted on, later proven wrong), and a `communication` type for
auditing what was told to the user against what later held up.

heimdall-journal extends this stack. It does not compete with or replace
`heimdall-checkpoint`, `resume-contract.sh`, or `decisions.md` — each of
those keeps doing its own job.

## Schema

One file per day per writer: `.planning/journal/{YYYY-MM-DD}-{haid-slug}.md`
— the same one-writer-per-file pattern as `.planning/ledger/{activity,
verdicts,checkpoints}/{slug}.json` (TEAM MODE P1/P2/P4), so many concurrent
worktree agents append without merge conflicts. `haid-slug` is
`haid_slug()`'s `tr '/:' '__'` form of the writer's HAID (or a
`local.$(whoami)` fallback when no HAID resolves).

Each file:

```markdown
# Journal — 2026-08-18 — haid:rj.laptop-a1b2/coder

## 2026-08-18T18:42:07Z — [CORRECTION] headroom link to token-spend-forensics

hmd told the user the cost delta was caused by headroom. A sibling agent
measured token-spend-forensics.md is entirely innocent of any headroom
link (its data is 100% context-lifecycle). The refutation is more valuable
than the original claim: the user's directive to "remove it immediately or
fix its implementation" was issued on a misattribution.

**Evidence:** sibling agent measurement, token-spend-forensics.md content audit
**By:** haid:rj.laptop-a1b2/coder
```

Fields: timestamp (UTC, `date -u +%Y-%m-%dT%H:%M:%SZ`), type (one of the four
below, upper-cased in the file), subject (single line, ≤200 chars), body
(required, ≤4000 chars — rejected outright if oversized, never silently
truncated), evidence (optional, ≤2000 chars), by (HAID). Stable and
greppable by construction: every entry header matches
`^## [0-9T:Z-]+ — \[TYPE\] subject$`.

## The four types

- **finding** — something learned about the code/system that wasn't known before.
- **decision** — a choice made and why (the "why" a commit message alone often drops).
- **correction** — a prior claim, plan, or belief that turned out wrong.
  `refuted` is accepted as an alias and normalizes to `CORRECTION` in the
  file; use whichever word reads naturally when writing it, both land the
  same. This is the type most worth writing — perishable, and the one every
  other store in the gap-analysis table above handles worst or not at all.
- **communication** — a non-trivial claim made TO THE USER, logged so it can
  be audited later against whether it held up. See
  [communication-templates.md](communication-templates.md) for when to log one.

## CLI

```bash
# Add a finding — body via flag:
bin/heimdall-journal add finding "pyenv shim adds ~400ms" \
  --body "bare python3 goes through the pyenv shim; statusline 2.35-4.09s before, 0.53-0.96s after pointing at the real interpreter." \
  --evidence "measured via hyperfine, n=20"

# Add a correction — body piped, useful for multi-line reasoning:
bin/heimdall-journal add correction "headroom link to token-spend-forensics" --evidence "sibling agent measurement" <<'EOF'
hmd told the user the cost delta was caused by headroom. A sibling agent
measured token-spend-forensics.md is entirely innocent of any headroom
link (its data is 100% context-lifecycle).
EOF
# 'refuted' also works and normalizes to the same [CORRECTION] tag:
bin/heimdall-journal add refuted "same subject" --body "..."

# Read back — always explicit, never automatic (see below):
bin/heimdall-journal today                     # today's file for the resolved writer
bin/heimdall-journal today --haid haid:x.y-1234  # today's file for a specific writer
bin/heimdall-journal tail 20                   # last 20 entries across ALL writers, oldest-to-newest
bin/heimdall-journal grep "headroom"           # file:line hits across every journal file
bin/heimdall-journal path --date 2026-08-18 --haid haid:x.y-1234  # compute a path without requiring it to exist
```

Exit codes: `add` returns 2 on any validation failure (bad type, missing/
empty/oversized subject or body) with nothing written; `grep` passes through
real grep semantics (0 = found, 1 = not found); everything else returns 0
unless the repo can't be located.

`HEIMDALL_HAID` overrides the resolved writer identity — the same override
convention `bin/heimdall-activity` already uses, not a new variable.

## Mechanical vs. advisory — be honest about which is which

**Mechanical (reliable, hook-driven):** the append-then-commit itself.
Durability is never optional — the entry lands on disk even when
`.heimdall-no-autocommit`/`.superx-no-autocommit` skips the follow-on commit.
The commit is scoped (`git add` of the journal file only, not `-A`) and
best-effort (a warning on stderr, never a hard failure — a journal tool must
never be the reason a coding task fails), carrying the same
`Co-Authored-By: hmd <hmd@runheimdall.dev>` trailer every hmd commit does.

**Advisory (needs judgement, can't be mechanized):** deciding *what* is
worth a journal entry, and writing the subject/body/evidence well. Prompt-
only instructions to "remember to journal things" demonstrably fail on their
own — that's exactly why `bin/heimdall-wip-commit` + the
`heimdall-precheck-edit` PreToolUse hook exist for commit cadence. This tool
takes the same lesson for narrative: the write path is a single mechanical
command an agent can be told to run at a specific moment (right after a
correction lands, right after a non-trivial claim is made to the user), but
*recognizing* that moment stays a judgement call no hook can make for you.
Treat "I'll journal it later" the same as "I'll test it later" — write the
entry the moment the finding/decision/correction/communication happens, not
at a summary pass.

## When to read back — deliberately almost never automatic

Nothing this tool writes is loaded into a prompt by default, and that is a
deliberate design choice, not an oversight. This repo's own
`docs/analysis/token-spend-forensics.md` measured a 6.17x cost difference
between a 731K-mean-context day and a 118K one — auto-loading a growing
narrative log into every turn would reproduce exactly the cost problem that
finding documents, not help it. `today` / `tail` / `grep` are explicit,
on-demand reads only, for a human or an agent that has decided it specifically
needs journal context right now (e.g., resuming a task and wanting the prior
agent's reasoning, or auditing whether an old claim held up). Nothing in this
repo's session-start or resume hooks reads the journal automatically; if a
future change wants to wire `heimdall-journal tail` into
`.planning/CHECKPOINT.md`'s resume section or a `Stop` hook, that is a
deliberate, separate decision to make with the same cost tradeoff in mind —
not a default this tool assumes for you.

## Grep recipes

```bash
bin/heimdall-journal grep "correction"          # every correction/refuted-type entry, matched on the tag text
bin/heimdall-journal grep "\[CORRECTION\]"      # exact tag match
grep -l "headroom" .planning/journal/*.md       # which writer/day files mention a topic
bin/heimdall-journal tail 50 | grep -B1 Evidence  # recent entries that carry evidence
```
