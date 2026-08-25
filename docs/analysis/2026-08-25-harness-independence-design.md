# Harness independence: what it would actually take

**Date:** 2026-08-25 · **Type:** design only, no implementation · **Scope:** can hmd deliver
its capabilities without Claude Code (or Cursor) as the runtime?

Every claim below is labelled **READ** (I opened the file and quote/cite it) or **INFERRED**
(reasoned from what I read, not directly observed). Nothing is graded "trivial" without
having read the code that consumes it.

---

## VERDICT

**Full harness independence: NOT YET. Do not start it.** It is technically achievable —
nothing here is impossible — but three of the dependencies are genuinely hard in the
(c) sense, and one of them (real subscription quota) is *unreplaceable*, not merely
expensive. Against that, the measured coupling is far smaller than the framing suggests:
**24 of 191 files in `bin/` reference any Claude-Code-specific env var or path**
(`CLAUDE_PLUGIN_ROOT`, `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_EXECPATH`, `~/.claude/projects`)
— **READ**, `grep -rl ... bin/ | wc -l` → 24, `ls bin | wc -l` → 191. hmd is already
~87% a plain CLI toolkit that happens to be *driven* by Claude Code.

**Do this instead — and it captures most of the value for roughly one wave of work:**
make the **autonomous / non-interactive paths** harness-independent, and leave interactive
use on Claude Code indefinitely. Today those paths already run through a single narrow
seam — a `claude -p` subprocess — in a handful of call sites. Abstract that seam behind
`hmd-exec` (dispatch to `claude -p` *or* a direct Anthropic-shaped agent loop) and the
maintainer loop, seeker/fixer, decompose, and the fallback path all become
harness-independent, while the enforcement layer (hooks) and the quota telemetry
(statusline) keep working exactly as they do now, because they only exist in the
interactive session anyway.

The 90%-of-the-benefit framing is not a hedge. The stated risk is "hmd dies if Claude Code
changes or goes away." Interactive convenience surviving that is worth little; *autonomous
work surviving it* is worth almost everything, and autonomous work is the cheap half.

---

## Dependency inventory — summary

Grades: **(a)** trivially reimplementable · **(b)** substantial but tractable ·
**(c)** genuinely hard / redesign / unreplaceable.

| # | Surface | Grade | One-line honest assessment |
|---|---|---|---|
| 1 | Read/Write/Edit/Grep/Glob/Bash tools | **(a)** | Filesystem + subprocess. A runner implements these in an afternoon. |
| 2 | `SendMessage` / `TaskStop` / named agents | **(a)** | Already *measured broken* under CC (19/20 `SendMessage` calls hard-failed). Owning the loop **removes** a pathology rather than porting one. |
| 3 | `Skill` tool + plugin/marketplace loading | **(b)** | Skills are markdown with frontmatter; loading them is prompt assembly. Marketplace distribution is the real loss, not the mechanism. |
| 4 | Hook *events* as an enforcement mechanism | **(b)** | In a runner you own, hooks get **easier** — you control the tool-call boundary. The work is porting 23 wired hook commands and their CC payload shapes, not inventing a mechanism. |
| 5 | `Agent` tool: spawning, worktrees, background, result collection | **(b)** | An API client with tool-use plus a process supervisor. hmd already owns worktree isolation and its own agent registry. The 600s-stall problem gets *better*, not worse. |
| 6 | Session/transcript JSONL format | **(b)** | 8 tools + the conformance grader parse `~/.claude/projects/<slug>/<id>.jsonl`. Needs a dual reader; the historical corpus stays CC-shaped forever. |
| 7 | Model tier-alias resolution | **(b/c)** | The whole `opus`/`sonnet`/`haiku` contract exists *because Claude Code resolves aliases to current-gen*. A direct API caller must send concrete ids — reintroducing exactly the staleness the contract was written to prevent. |
| 8 | **Hook `additionalContext` reaching the model mid-session** | **(c)** | This is hmd's PERFORM layer. Replaceable in a runner you own — but only there; there is no way to have it *and* stay on CC-shaped delivery semantics, and the semantics are already sharply constrained (see §4). |
| 9 | **`rate_limits` via statusline stdin** | **(c) — UNREPLACEABLE** | Anthropic's real 5h/7d subscription quota arrives **only** on the statusline hook's live stdin. There is no API for it. Leave CC → this number is gone, permanently. |
| 10 | **Subscription auth + prompt-cache economics** | **(c) — the sleeper** | CC runs on the Max/Pro OAuth subscription. A direct API runner bills per token. This repo's own forensics: **95.56% of tokens served from prompt cache**. Cost model changes materially and unfavorably. |

The three genuine **(c)**s are **#9, #10, and the `additionalContext` half of #8**. Everything
else is work, not a wall.

---

## Phase 1 — the dependency surface, in detail

### 1. Agent spawning — **(b)**

**READ.** `agents/*.md` are markdown-with-frontmatter specs: `tools:`, `model:`, `tier:`,
`effort:`, `memory:`, `maxTurns:`, `isolation:`, `disallowedTools:`
(`agents/coder.md:1-14`, `agents/architect.md:1-12`). Sixteen agent files. Claude Code reads
them and materializes a subagent addressed by `subagent_type: hmd:<role>`.

**READ.** `isolation: worktree` appears in `agents/coder.md:10`, `agents/wave-executor.md:8`,
`agents/test-runner.md:7`. **INFERRED:** Claude Code performs the worktree creation, but hmd
already owns the *policy* and the reaping — `bin/heimdall-reap-idle`, `bin/heimdall-agents`,
`superpowers:using-git-worktrees` — so the mechanism is git, not the harness.

**READ — and this is the important part.** `bin/heimdall-agents:2-32` documents, from
measurement on this machine, that CC-spawned subagents "NEVER enter heimdall's agent-pool or
HAID ledger, so when one dies, hangs, or parks, heimdall has ZERO visibility"; that a parked
`name:`-carrying teammate has **no signalable PID** ("in_process" is literal — a coroutine
inside the session event loop), **no control surface** (a session dir holds only
`scratchpad/` and `tasks/`), and that **`SendMessage` failed 19 of 20 times** across 566
transcripts with "No such tool available." `agents/heimdall.md:427` records **0/43 named
spawns completed vs 59/66 unnamed**.

This inverts the usual migration argument. hmd does not get agent lifecycle *from* Claude
Code; it works *around* Claude Code's agent lifecycle, with a dedicated 191-line tracker
whose header is an autopsy. A runner that owns its own subprocesses gets PIDs, exit codes,
signals, and timeouts for free — which is also the direct answer to the 600s stall problem
seen repeatedly today. **Grade (b), and a net capability gain.**

### 2. Hooks — **(b)** for the mechanism, **(c)** for `additionalContext`

**READ.** `hooks/hooks.json` — 211 lines, **23 wired command hooks** across:

| Event | Count | What hmd actually gets from it |
|---|---|---|
| `UserPromptSubmit` | 2 | `bin/parallel-gate`, `bin/heimdall-ctx-meter notice` |
| `PreToolUse` | 5 | Bash (git-guard, `secret-scan`, pre-push quality gate, `heimdall-selfscan`, oracle falsifiability, corpus regression, parallelism tracking); `Read\|Grep\|Glob` (parallelism); `Agent` (`heimdall-precheck-agent` — the `name:` warning); `Write\|Edit` (**the stub scanner**, fail-closed); `Edit\|MultiEdit\|Write` (`heimdall-precheck-edit`) |
| `PostToolUse` | 4 | `corpus-capture`, `edit-tracker log` + `mark-dirty` + autocommit-at-5-files, `heimdall-context-sync`, `heimdall-journal-hook commit` |
| `SessionStart` | 7 | autoupdate, statusline self-registration, `cc-selfheal`, tracker compilation, `stack-pack detect`, team/presence beat, reap advisory, checkpoint notice, resume probe, maintain/quota resume hints, dream notice, presence keeper, `heimdall-ai-select` |
| `SubagentStop` | 1 | `heimdall-metric-hook stop` |
| `Stop` | 1 | `hooks/heimdall-metric-reminder.sh` — the metric nudge |
| `SessionEnd` | 2 | presence keeper-stop; checkpoint write, `parallelism-tracker grade`, `verify-edits --quick`, cleanup, reel record, summary card, context sync, farewell |
| statusline | 2 (in `settings.json`) | `hooks/statusline.sh`, `sentinels/hmd-subagent-statusline.sh` |

**Payload dependencies (READ).** Most hooks parse the CC hook stdin JSON with `jq`:
`.tool_input.command`, `.tool_input.content // .tool_input.new_string`,
`.tool_input.file_path // .tool_input.notebook_path`, `.tool_name`, `.session_id`. These are
a stable, small, obvious schema — a runner emits the same shapes at its own tool boundary.
`CLAUDE_PLUGIN_ROOT` and `CLAUDE_PROJECT_DIR` are read everywhere but always with a
`git rev-parse --show-toplevel` fallback already inline — **READ**, that fallback is present
in essentially every hook command in the file.

**The exit-code contract matters and is cheap to reproduce.** `exit 2` + a JSON `{"error": ...}`
on stdout = *block the tool call*. That is the entire enforcement primitive behind the stub
gate ("🛑 BIFRÖST"), the secret gate, and the pre-push quality gate. A runner that checks a
subprocess exit code before executing a tool call reproduces it exactly.

**The genuinely hard part — `additionalContext` (c).** **READ**,
`.planning/skills/subagent-stop-delivery-scope.md` and `hooks/heimdall-metric-reminder.sh:26-45`:
the CLI binary's own doc-comment strings (verified against pinned 2.1.241 *and* 2.1.243,
identical wording) say `Stop`'s `additionalContext` is "delivered to the model; the
conversation continues," while `SubagentStop`'s is "delivered to the subagent; the subagent
continues" — and `HOOK_EVENT_REGISTRY` maps both names to the **same handler**. `SubagentStop`
is `Stop` parameterized. **READ**, `docs/analysis/2026-08-25-hook-delivery-spike.md`: a
follow-up empirical spike (SIGKILL on a real foreground subagent process) was run to settle
whether `SubagentStop` fires on non-clean death and whether `TaskCompleted`/`TaskCreated`
reach the parent.

Why this is (c) and not (b): the *ability to inject text into a running model's context* is
the mechanism behind the repo's own headline enforcement number — **130 hook-wired
parallelism-tracker records vs 5 prose-instructed heimdall-metric records over 83 days, a
26x gap** (**READ**, `hooks/heimdall-metric-reminder.sh:10-16`). A runner you own can inject
context trivially (it *is* the loop). What is hard is that today's design is shaped around
CC's specific, sharply-limited delivery scoping — the metric reminder had to be a `Stop`
hook, not `SubagentStop`, and there is *no* hook that notifies a live orchestrator at a
subagent's instant of death. Porting means re-deriving which nudge belongs where under
entirely different (better) semantics. That is redesign, not translation.

### 3. Tools — **(a)** with one **(b)**

**READ**, the `tools:` lines across all 16 agents: `Read, Write, Edit, Bash, Grep, Glob` in
essentially every agent; `Agent, TaskStop` in 5 (`heimdall`, `coder`, `design`,
`wave-executor`, `fixer`); `SendMessage` in exactly **one** (`agents/heimdall.md:4`);
`Skill` in 5; `TodoWrite` in 1.

- `Read/Write/Edit/Grep/Glob/Bash` — **(a)**. Filesystem, `ripgrep`, `glob`, `subprocess`.
  The only non-obvious behaviours are Edit's exact-match-or-fail semantics and Read's
  line-numbered output, both of which are ~50 lines each.
- `Agent`/`TaskStop` — **(a)** in a runner (spawn/kill a child process), see §1.
- `SendMessage` — **(a)**, and see §1: it barely works today.
- `Skill` — **(b)**, see §4.
- `TodoWrite` — **(a)**, and arguably not load-bearing at all.

### 4. Skills — **(b)**

**READ.** `skills/` holds 5 hmd-owned skills (`designmatch`, `heimdall`, `self-improve`,
`stacks`, `system-health`), each a `SKILL.md` with `name:`/`description:` frontmatter plus a
`references/` directory. `skills-registry.json` and `heimdall-skills.json` exist at repo
root; `bin/detect-skills` and `bin/discover-skills` are hmd's own.

**The mechanism is prompt assembly** — a skill is markdown injected into context on demand —
so a runner reimplements `Skill` as "read this file, append to the system prompt." **INFERRED**
but on solid ground: nothing in `SKILL.md` requires harness cooperation beyond that.

**What is actually lost is distribution, not execution.** `.claude-plugin/plugin.json`
(**READ**, `"name": "hmd"`, `"version": "2.4.0"`) makes hmd installable via
`claude plugins install` / `/plugin install` and discoverable in the marketplace. Also lost:
the ~15 *third-party* skills this session has available (`superpowers:*`, `caveman:*`,
`claude-mem:*`, `ui-ux-pro-max`, …) — hmd's own agent specs reference `superpowers:*` by name
in six places (**READ**, e.g. `agents/coder.md:20-24`, `agents/architect.md` skill list). A
runner would have to vendor or re-source those.

### 5. Statusline and `rate_limits` — **(c), unreplaceable**

**READ.** `settings.json:5-13` wires both `statusLine` → `hooks/statusline.sh` and
`subagentStatusLine` → `sentinels/hmd-subagent-statusline.sh`.

**READ.** `bin/heimdall-statusline-register:1-25` documents that Claude Code reads `statusLine`
**only** from user/project/enterprise settings, never from a plugin's own `settings.json`, and
that a user-level statusLine command is evaluated with **no `CLAUDE_PLUGIN_ROOT` set** — hence
the bake-an-absolute-path self-bootstrap. That is CC-specific plumbing that simply evaporates
in a runner (a runner draws its own status line).

**The real dependency is the payload, not the rendering.** **READ**,
`sentinels/hmd-statusline.py:925-1010`: `rate_limits.five_hour.{used_percentage,resets_at}`
and `rate_limits.seven_day.used_percentage`, with an explicit comment at line 1005 —
"Claude Code's own harness-computed `rate_limits`… arrive **ONLY** on THIS hook's live stdin."
**READ**, `bin/heimdall-session-usage:10-50`: the same fact stated from the other side —
delivered "EXCLUSIVELY via the statusline hook's own stdin," `/status` is interactive-only and
unparseable, and a Phase-2 bridge (landed today, commit `87b5812`) persists the allowlisted
snapshot to `~/.heimdall/rate-limits.json` so a *non*-statusline tool can read a recent real
figure at all.

**This is the sharpest (c) in the document.** Anthropic's real subscription quota is a
harness-computed value with no API surface. Leave Claude Code and hmd's honest quota reporting
degrades permanently to the fallback `bin/heimdall-session-usage` already ships: consumption
measured from the session's own transcript against an **operator-configured budget** —
explicitly labelled in that file as "nothing more" (**READ**, lines 139-146, which distinguish
`percent_real` from the estimate in the tool's own output vocabulary). A direct-API runner
gets `anthropic-ratelimit-*` response headers instead, which describe *API* limits, not the
Pro/Max subscription window. Different number, different meaning. **Not portable. Name it and
accept the loss.**

### 6. Session / transcript format — **(b)**

**READ.** Eight files parse `~/.claude/projects/`: `bin/heimdall-529-scan`, `bin/heimdall-tokens`,
`bin/heimdall-agent-resume`, `bin/heimdall-agents`, `bin/heimdall-session-usage`,
`bin/heimdall-ctx-meter`, `bin/heimdall-conformance`, `bin/lib/session-liveness.sh`. A wider
`jsonl` grep hits ~20 files including `bin/summary-card`, `bin/heimdall-dream`,
`bin/heimdall-metric`, `bin/parallelism-tracker.c`, `bin/benchmark`.

**READ**, `bin/heimdall-529-scan:100-110`: the project-directory slug rule (every char outside
`[A-Za-z0-9]` → `-`) is explicitly flagged as "a guess at an undocumented, internal Claude Code
naming convention, not a stable public contract." **READ**, `bin/heimdall-conformance:196`:
"transcript: `~/.claude/projects/<slug>/<session>.jsonl`, one JSON object per…" — the
conformance grader, which enforces `gate-runs-once` and `gates-at-end` (**READ**, `CLAUDE.md`),
grades by replaying the CC transcript.

**Grade (b), with a permanent asterisk.** A runner emits its own JSONL and these tools take a
dual reader — real work but mechanical. The asterisk: the **existing corpus is CC-shaped
forever**. Every measured claim this repo rests on (130-vs-5, 0/43-vs-59/66, 19/20
`SendMessage`, 86%/14% model split) was mined from CC transcripts. Those numbers do not
re-derive on a new format; they become history, not a live signal.

### 7. Model resolution — **(b/c)**

**READ.** `bin/heimdall-model-resolve:1-15` states the contract outright: "Claude Code maps the
bare tier ALIASES (opus/sonnet/haiku) to the newest model of that tier, so passing the alias to
`--model` always resolves to current-gen — no stale pinned id … to rot when a new gen ships."
`HEIMDALL_MODEL_<TIER>` exists **solely** for bench reproducibility, and the `fable` tier is
deny-by-default behind a fail-closed non-ZDR policy gate (lines 44-80).

**This is a real dependency on Claude Code as a resolver, not just as a runtime.** The
Anthropic Messages API takes a concrete model id. A runner must resolve `sonnet` → an id
itself — plausibly by querying `/v1/models` and picking the newest of the tier — which is
tractable **(b)** but reintroduces exactly the staleness class the alias contract was written
to eliminate, and adds a new failure mode (resolver picks wrong on a naming change). The ZDR
gate ports unchanged; it is pure local policy.

### 8. Subscription auth and prompt-cache economics — **(c), and easy to miss**

**READ**, `docs/analysis/2026-08-25-omniroute-fallback-transport.md:26-40`: this repo's own cost
forensics record a **95.56% cache-read ratio** and identify 0.1×-cache-read pricing as "the
mechanism holding spend down today." **READ**,
`docs/analysis/2026-08-23-omniroute-assessment.md:12-18`: one 15-day session accounted for
**82.8% of all measured spend**, and spend is driven by "turns × context carried per turn."

**INFERRED, but strongly:** Claude Code today runs against the Pro/Max OAuth subscription
(§5's `rate_limits.five_hour` is a subscription-window concept; `bin/lib/issue_loop.py:310`
notes `claude -p` needs the credential located for the child to work — **READ**). A
direct-API runner runs on API keys and per-token billing. Prompt caching *is* available on the
raw API, so the 0.1× read price is preservable — but the subscription flat-rate is not, and
this repo has already measured that its own workload profile (long sessions, huge carried
context) is precisely the one that benefits most from the flat rate.

**Harness independence has a bill attached, and it is not small.** Any plan that does not
price it is incomplete.

---

## Phase 2 — architecture for a harness-independent runner

### 2.1 The agent loop (`hmd-run`)

Underneath, the `Agent` tool is an LLM API client with tool-use. The runner is that, plus the
things hmd actually needs on top:

```
hmd-run
├─ transport/        Anthropic-shaped /v1/messages client (works against api.anthropic.com
│                    OR any Anthropic-shaped local gateway — the OmniRoute work already
│                    proved ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN is the supported seam
│                    on both sides; READ, omniroute-fallback-transport.md verdict §1)
├─ loop/             message loop: send → tool_use blocks → execute → tool_result → repeat
│                    until stop_reason == end_turn or maxTurns
├─ tools/            read, write, edit, bash, grep, glob, skill, agent, task_stop
├─ hooks/            dispatcher: fire command hooks at the loop's own boundaries
├─ agentspec/        parse agents/*.md frontmatter → loop config (model, tools, maxTurns,
│                    effort, isolation, disallowedTools)
├─ supervise/        one OS process per subagent: PID, exit code, signals, timeout, worktree
└─ transcript/       append-only JSONL, CC-compatible superset schema
```

**What hmd needs beyond a basic loop, specifically:**

1. **Parallel spawning.** CLAUDE.md mandates batching independent work into one message. In a
   runner this is `n` child processes started together — genuinely parallel, not
   harness-scheduled. Strictly better than today.
2. **Background execution + result collection.** Today `run_in_background: true` returns
   through an opaque task-notification channel and, per `bin/heimdall-agents`, hmd cannot see
   inside it. A runner writes each child's result to
   `.heimdall/agents/<id>/{result.json,status,pid}` and the parent polls or `wait()`s.
   Result collection stops being a channel hmd doesn't own.
3. **The 600s-stall problem — this is where the runner pays for itself.** Today a stalled
   subagent is an in-process coroutine with no PID and no control surface (**READ**,
   `bin/heimdall-agents:20-32`), so hmd can only *observe* the corpse afterwards. A supervised
   child process gets: a hard wall-clock timeout, a no-output-progress watchdog (last
   transcript append > N seconds → SIGTERM → SIGKILL), a recorded termination cause, and an
   automatic bounded retry. `bin/heimdall-agent-resume` already classifies termination cause
   and bounds retry (**READ**, commit `2348636` on main) but its own header records that it
   "cannot itself retry anything" — a runner removes that ceiling.
4. **Named-agent mailboxes: do not port them.** 0/43 completion is a design that failed
   measurement. A runner should have exactly one spawn shape (request → result) plus an
   explicit long-lived session object if ever needed.

### 2.2 Hook equivalents

The good news is structural: **hooks are easier in a runner than in a harness**, because the
runner *is* the tool-call boundary. `hooks/hooks.json` ports nearly verbatim — same events,
same `jq`-parsable stdin payloads, same `exit 2` + `{"error": ...}` block contract. The
translation table:

| CC event | Runner equivalent | Notes |
|---|---|---|
| `UserPromptSubmit` | before appending a user turn | verbatim |
| `PreToolUse` (matcher) | before dispatching a tool_use block | verbatim; `exit 2` → return a synthetic `is_error` tool_result and skip execution |
| `PostToolUse` | after tool execution, before appending tool_result | verbatim |
| `SessionStart` / `SessionEnd` | loop init / teardown | verbatim |
| `Stop` | end of an assistant turn | `additionalContext` → append a synthetic user-role system note. **Strictly more capable than CC**: the runner can also deliver to a *parent* at a child's instant of death, which CC provably cannot (§2). |
| `SubagentStop` | child loop teardown | same; the CC delivery-scope constraint disappears |
| statusline | runner draws its own | rendering ports; the `rate_limits` payload does not (§5) |

**The 26x hook-vs-prose enforcement gap is preserved** — that gap is about *mechanism vs
instruction*, and the runner keeps the mechanism. This is the single most reassuring finding
in the document: hmd's PERFORM layer is not what is at risk.

**Also unchanged:** the native git hooks (`.heimdall/hooks/pre-commit`, `pre-push`, wired via
`core.hooksPath`, emitted by `hmd init` — **READ**, `CLAUDE.md`). Those are git's, not Claude
Code's, and they are already the fail-closed backstop for exactly this reason. Under a runner
they become *more* load-bearing, not less.

### 2.3 What is LOST — named plainly

1. **Real subscription `rate_limits`.** (§5) Gone, permanently, no substitute. Degrade to the
   already-shipped budget estimate and *label it honestly*, which
   `bin/heimdall-session-usage` already does.
2. **Flat-rate subscription economics.** (§8) Replaced by per-token API billing against a
   workload this repo has measured as the worst case for it.
3. **The measured corpus.** (§6) 566 transcripts of CC-shaped evidence stop accruing. Every
   forward-looking claim needs re-measurement on the new format.
4. **Marketplace distribution + third-party skills.** (§4) `claude plugins install` and the
   `superpowers:*` / `caveman:*` ecosystem. Vendorable, but it is a real loss of leverage.
5. **Interactive UX.** Terminal UI, permission prompts, `/commands`, plan mode, the
   Escape-to-interrupt affordance. Rebuilding a good interactive TUI is a product, not a
   feature — **not worth replacing**, which is exactly why the recommendation keeps
   interactive on Claude Code.
6. **Free platform improvements.** Every CC release currently benefits hmd at zero cost.
   Independence converts that into a maintenance obligation across 191 bins and 373 test
   suites (**READ**, `ls test/*.test.sh | wc -l` → 373).

### 2.4 Incremental path — no flag day

This stages cleanly, which is the main reason it is worth designing at all:

**Stage 0 — the seam (nothing new is built).** Every autonomous path already funnels through
one shape: a `claude -p` subprocess. **READ**, the call sites are
`bin/lib/hmd-claude-retry.sh` (the retry/backoff wrapper, with real overload-vs-error
discrimination already implemented), `bin/decompose:12-14`, `bin/lib/issue_loop.py:236-246`
and `:652-760`, `bin/heimdall-fallback`, `bin/benchmark`, `bin/heimdall-drain`,
`bin/session-fork`, `bin/heimdall-tokens`. Introduce `bin/hmd-exec` as the single dispatcher
these call. Behaviour identical on day one — it shells to `claude -p`.

**Stage 1 — a second backend behind the same seam.** `hmd-exec --backend=api` runs the
runner's own loop. `--backend=claude-code` stays the default. Both harnesses live side by
side; every call site is one env var away from either. **This is the point at which hmd's
autonomous work is harness-independent**, and it is reached without touching hooks, statusline,
skills, or the interactive session at all.

**Stage 2 — dual-format transcripts.** Runner emits a CC-compatible JSONL *superset*; the 8
transcript readers get a format discriminator. Both corpora remain readable.

**Stage 3 — parity oracle (the gate, in this repo's own idiom).** A **differential** gate:
the same fixed task, run through both backends, artifacts compared. Reference half authored
independently of the runner. Falsifiability proven with injected-defect mutants
(`bin/falsify --assert-score 1.0`). Without this, "the runner works" is an assertion. With it,
Stage 4 is a data-driven decision instead of a leap.

**Stage 4 — interactive, only if Stage 3 says so.** Port hooks + build a TUI. This is the
expensive stage and the one the recommendation says to *not* do.

Nothing above requires a flag day. Every stage is independently valuable and independently
revertible.

### 2.5 Effort — in dependency waves

Per repo policy, waves and parallelism, never calendar.

**Narrow scope (Stages 0-1 only — the recommendation):**

- **Wave 1: ~3 parallel agents** — (i) `bin/hmd-exec` dispatcher + call-site migration;
  (ii) the API agent loop (transport + message loop + the 6 filesystem/shell tools);
  (iii) tests for both, including the retry/overload discrimination `hmd-claude-retry.sh`
  already encodes.
- **Wave 2: ~2 parallel** — (i) model-tier resolver against `/v1/models` preserving the alias
  contract and the ZDR gate; (ii) a differential parity gate over `bin/decompose` (a small,
  deterministic, already-headless task — the ideal first differential subject).
- **Wave 3: 1 agent** — docs, `OPERATORS.md`, backend-selection policy.

**≈6 agents across 3 waves.** Small, because the seam already exists.

**Full scope (Stages 2-4 as well):**

- **Wave 4: ~4 parallel** — subagent supervisor (worktrees, PIDs, watchdog, result collection);
  hook dispatcher porting all 23 wired hooks; skill loader + vendoring of the referenced
  `superpowers:*` skills; agent-spec frontmatter parser.
- **Wave 5: ~4 parallel** — dual-format readers across the 8 transcript tools;
  `heimdall-conformance` re-grounded on the new format; quota accounting from API response
  headers (with the honest-labelling degradation); a runner-native status renderer.
- **Wave 6: ~3 parallel** — full parity oracle across the agent roster; corpus/falsify
  re-verification; a survey of the 373 test suites for CC assumptions.
- **Wave 7: ~2** — interactive TUI spike, then a go/no-go.

**≈19 more agents across 4 further waves, plus permanent maintenance drag.** The waves are
also *less* parallel than they look: Waves 4-6 all bottleneck on the transcript schema decided
in Stage 2, so a schema mistake serializes the rest.

---

## Phase 3 — recommendation

### Is it worth doing? **The narrow version yes, the full version no — not yet.**

**Do now (≈6 agents, 3 waves):** Stages 0-1. `bin/hmd-exec` as the single dispatcher for every
`claude -p` call site, plus a direct-API backend behind it.

**What it buys.**
- The maintainer loop, seeker/fixer, `decompose`, and the exhaustion-fallback path stop
  depending on Claude Code being installed, logged in, or even existing. That is the actual
  survival property being asked for.
- It composes with work already on main: `bin/heimdall-fallback` already routes exhausted
  `claude -p` attempts to an Anthropic-shaped endpoint (**READ**, commit `b82939b`), so the
  transport question is settled — `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` is the
  supported path on both sides (**READ**, `omniroute-fallback-transport.md` §1).
- It makes hmd runnable in CI, in a container, and on a machine with no Claude Code — which is
  worth more for a tool whose pitch is autonomous verified delivery than any interactive
  improvement.
- Every one of the three genuine (c) dependencies is **out of scope by construction**:
  headless work never had a statusline, so #9 never applied; hooks stay wherever the
  interactive session is; the transcript corpus keeps accruing from interactive use.

**What it costs.** API-key billing on the autonomous paths (they are the *short-context*
paths, so this is the cheap half of the workload — **INFERRED** from the forensics in §8, which
attribute spend to long carried context). A second code path to keep honest, mitigated by the
parity gate in Wave 2. One new abstraction that must not become a leaky pass-through.

### Do NOT do now: Stages 2-4 (≈19 agents, permanent drag)

Three reasons, in order of weight:

1. **You would pay the (c) costs to buy interactive parity you already have.** Real
   `rate_limits` (§5) and subscription economics (§8) are lost the moment interactive leaves
   CC — and interactive is precisely the surface where losing them hurts most.
2. **The coupling is 24/191 files and shrinking.** hmd is already mostly harness-independent.
   The honest framing is not "hmd is trapped in Claude Code"; it is "hmd is *driven by* Claude
   Code and *implemented as* a CLI toolkit." That is a good position, and Stage 1 converts
   the only genuinely captive part.
3. **Nothing forces the decision yet.** Stage 3's parity oracle is the correct trigger. Build
   the seam, gather differential evidence on the cheap paths, and let a measurement — not a
   fear — decide Stage 4. That is the same discipline this repo already applied to
   OmniRoute, headroom, and claude-mem: decline after measurement, revisit only on new facts.

### Red flags in this document

- **Stated, not hidden:** the parity-oracle design (Stage 3 / Wave 2) is described, not
  specified. It is the correct gate but this is a design doc, not a plan; a `PLAN-*.md` for
  Stage 0-1 must wire it concretely with golden + mutant fixtures before any runner code is
  graded green.
- **One load-bearing INFERENCE:** that CC currently runs on subscription OAuth rather than an
  API key (§8). It is well-supported (subscription-window `rate_limits`, the credential note
  at `issue_loop.py:310`) but I did not read an auth-flow implementation. If it is false, §8
  weakens and the full-scope case gets modestly stronger.
- **Not investigated:** Cursor specifically. The brief named it; I found no Cursor-specific
  code in this repo and treated "harness" as Claude Code throughout. If hmd is meant to *run
  on* Cursor, that is a different (and likely easier) question than running on nothing.

## OUT OF SCOPE

- Any implementation. This document is design only; no `bin/`, `hooks/`, or `test/` file was
  modified, and `bin/heimdall-fallback` / `bin/lib/issue_loop.py` were read but not touched
  (other agents hold them).
- A `PLAN-*.md` for Stage 0-1. Recommended as the next artifact; deliberately not written here.
- Cursor, Zed, or any specific alternative harness as a *target*.
- Re-litigating OmniRoute as a cost-routing layer (settled NO, `2026-08-23-omniroute-assessment.md`).
- Pricing the API-billing delta in dollars — the forensics needed live in
  `token-spend-forensics.md` and were not re-derived.
- The interactive TUI design (Stage 4), which the recommendation declines.
