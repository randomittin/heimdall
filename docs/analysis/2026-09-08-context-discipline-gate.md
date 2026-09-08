# Context Window Discipline — A Mechanical Gate at the Hard Ceiling (2026-09-08)

Operator's ask, verbatim: *"prepare a better version of execution for context
discipline and standardize it to not impact the work quality while ensuring token
saving as much as possible."*

This doc covers what was built (`bin/heimdall-ctx-meter gate`, tested — 104 passed, 0
failed), what it reuses (zero new thresholds), what it cannot do (a real, named
limit), and an honest verdict on binding vs. advisory. No savings figure in this doc
is new; every number below already exists in `token-spend-forensics.md`,
`2026-09-02-input-context-cost.md`, or `2026-09-07-cost-forensics-tool.md`.

## 1. The problem was never detection

`bin/heimdall-ctx-meter notice` is wired at `UserPromptSubmit` and already fires
correctly. `2026-09-02-input-context-cost.md` §7 ran it against its own session and
recorded the output verbatim:

```
[heimdall] CONTEXT 422,199 tokens — past the 150,000 ceiling. Checkpoint and
           restart: run /hmd:save, then start a fresh session.
[heimdall]     $0.366/req at 731K context vs $0.0593/req at 118K — 6.17x.
               A restart re-pays ~35K of preamble (~$0.02); staying here cost
               $369.50 over one session.
```

"It fired on every prompt of this session. Context still reached 422,199 tokens —
2.8x the ceiling — and the session continued for a full day past it." (§7, lines
424–425). That doc's own verdict: *"the gap is not detection. It is that the
orchestrator kept working... An instruction with no read-back does not bind, and an
advisory warning is an instruction with no read-back."* (§7, lines 427–434).

That §7 is explicit that this is not a one-off failure mode. Three other
prose-only mandates in this same repo degraded the identical way:

| Mandate | Where stated | Measured compliance |
|---|---|---|
| Caveman ultra compression | Injected every turn via `SessionStart`/`UserPromptSubmit` hook | 3.25% of prose chars were still caveman-targeted filler, measured on this repo's own session (`CLAUDE.md`, Token Efficiency section) |
| `heimdall-metric --type` | Mandated in `CLAUDE.md` | ~895 of 900 rows missing it (§7, line 430–431) |
| "Report once when all agents finish" | Sitting in the orchestrator's own persistent memory | Narrated after nearly every completion anyway (§7, line 431–433) |
| Context ceiling notice | `heimdall-ctx-meter notice`, fired every prompt | Session ran a full day past 2.8x its own ceiling (§7, lines 424–425) |

Four for four. The pattern is consistent enough to stop treating it as
case-specific bad luck: **a warning that is only ever read, never checked, does not
bind.** Anything this doc proposes has to either be a mechanical check with a real
exit code, or admit plainly that it is more of the same.

## 2. Two independent measurements agree on the shape, not just the anecdote

| Source | Scope | High-context group | Low-context group | Ratio |
|---|---|---|---|---|
| `token-spend-forensics.md` | Owner's own two days, same repo, same working style | 2026-08-05: 476 reqs, mean ctx 731,707 → $0.366/req | 2026-08-07: 153 reqs, mean ctx 118,678 → $0.0593/req | **6.17×** |
| `bin/heimdall-cost-forensics` sanity run | 835 sessions, 35,963 deduped requests, 2026-07-16→2026-09-06, whole-corpus quartiles | top quartile: mean ctx 365,562 → $0.2965/req, n=8,990 | bottom quartile: mean ctx 49,792 → $0.0572/req, n=8,745 | **5.19×** |

Different methodology (two hand-picked days vs. whole-corpus quartiles), different
window, different sample size — and both land in the same several-fold band.
Per `2026-09-07-cost-forensics-tool.md`'s own framing: *"neither is 'the' definitive
ratio, both say the same thing: operating at high context costs several times more
per request."* That convergence, not either single number, is what this design
treats as ground truth. The restart cost both docs independently agree on: **~35K
tokens of re-paid preamble, about $0.02** — the number the gate below is sized
around not disturbing.

## 3. Why a hard block was declined once already, and what changes now

`2026-09-02-input-context-cost.md` §7 already asked "what would actually bind" and
deliberately stopped short of proposing one:

> A `UserPromptSubmit` hook CAN return a blocking decision, not merely text. Whether
> it SHOULD hard-block a turn at the ceiling is a judgement call with a real failure
> mode — a wrongly-tuned block would strand an operator mid-task with no override.
> The honest interim: the ceiling is the OPERATOR's to enforce, and the meter's job
> is to make ignoring it a conscious act rather than an oversight.

That concern is correct and this design does not argue with it — it answers it. The
named failure mode is "strand an operator mid-task with no override." The mechanism
below (§5) is built so that it **structurally cannot** do that: it only ever refuses
at a moment it has mechanically confirmed there is no mid-task state to strand. If
there is live agent work or an uncommitted change, it defers — always, no exception.
The 2026-09-02 doc's objection was to blocking *a turn*, keyed to a token count.
This design never blocks a turn, and is not keyed to a token count alone — it is
keyed to token count **and** a proof of idleness.

## 4. The design: reuse the existing thresholds, add one verb

Zero new numbers. `bin/heimdall-ctx-meter`'s own `ENVIRONMENT` block (lines 81–95)
already carries every threshold this gate uses, each with its derivation inline:

```
HMD_CTX_CEILING     150000  target ceiling — the cap that recovers $369.50
HMD_CTX_CLIFF_NEAR  700000  ~7 requests of headroom at the measured 13,320 tok/req
HMD_CTX_CLIFF       800000  measured quintile-5 boundary (804,141): cache-write 3.2x
```

`notice` (existing, unchanged) stays exactly what it was: a per-prompt, stderr-only,
always-exit-0 advisory. Its one hard invariant — *"exits 0 on garbage, always"* —
runs on every prompt and must never be able to break a turn, and that invariant is
incompatible with also being the verb that refuses new work. `gate` (new) is the
verb built for the different contract that refusing requires:

```
WHY `gate` IS A SEPARATE VERB FROM notice
------------------------------------------
notice's one hard invariant is "exits 0 on garbage, always" — it runs on
EVERY prompt and must never be able to break a turn. That invariant cannot
also be the verb that refuses new work, because refusing needs a REAL exit
code, a different contract. `gate` carries that contract instead: it is not
on the per-prompt hot path, it exists to be invoked deliberately (by the
orchestrator, before spawning new work) and CHECKED — exit 0 vs 1 — not
merely read.
```
(`bin/heimdall-ctx-meter`, header comment, lines 47–55.)

`gate` only ever escalates past "proceed" at `CLIFF_NEAR`/`CLIFF` — the identical
existing thresholds `notice` already renders against. Below them, `gate` always
exits 0 without touching the boundary check at all, so the low-context hot path
never pays for it.

## 5. The boundary: mechanical, ungameable, cheap, and only invoked when it matters

**Definition**: `heimdall-agents count == 0` AND `git status --porcelain` empty.
Both are process/filesystem facts, not self-reported prose, and both are cheap
enough (two subprocess calls) to matter only at the rare hard-ceiling tier — never
on the per-prompt path `notice` still owns.

`_boundary_decision()` (`bin/heimdall-ctx-meter:326–366`) resolves to exactly one of
four outcomes, and every branch that cannot **positively** confirm "no live agent,
clean tree" resolves to `defer`, never falls through toward `refuse`:

1. **Unresolvable — no `heimdall-agents` binary.** `defer`: *"boundary unresolvable
   (no heimdall-agents binary) — deferring, never refusing on an unverifiable
   fact."*
2. **Unresolvable — `heimdall-agents count` gave no integer, or no repo, or not a
   git dir.** `defer`, same reasoning, one line per cause.
3. **A live agent (`count` > 0).** `defer`: *"N agent(s) live — in-flight work is
   never interrupted."*
4. **An uncommitted change (`git status --porcelain` non-empty).** `defer`:
   *"uncommitted changes present — work is mid-flight even without a live agent."*
5. **None of the above.** `refuse`: *"no live agents, clean tree — a clean boundary
   to stop new work at."*

This ordering was a deliberate correction during implementation, not an
afterthought: an early draft let a missing/non-executable `heimdall-agents` binary
fall through silently toward the git-based checks, meaning an unresolvable
agent-liveness check could still land on `refuse` if the git checks happened to
look clean. The shipped version returns immediately on every unconfirmable path,
before any git check runs, so "I could not verify" and "I verified it's safe" can
never be confused with each other.

## 6. The `gate` verb's contract

```
exit 0  -> proceed  (below the hard ceiling, an unverifiable reading, OR a
           hard-ceiling reading that DEFERS because in-flight work exists)
exit 1  -> refuse   (at/past the hard ceiling AND a clean, provable boundary)
```

`NON_VERIFIED` readings always resolve to `proceed` — *"the meter never blocks new
work on its own blind spot"* (`do_gate`, `bin/heimdall-ctx-meter:403–406`) — the
same fail-open posture `notice` already holds for its own primary reading, applied
consistently to the new verb.

`render_cliff` (the existing severe-escalation renderer `notice` calls at
`CLIFF`/`CLIFF_NEAR`) now names the live decision inline, so an operator watching
the existing notice sees the gate's verdict without invoking a second command:

```
⛔ REFUSE NEW WORK — <reason>. Do not start anything new here; restart first.
```
or
```
DEFERRING new-work refusal — <reason>.
```

(`bin/heimdall-ctx-meter:480–485`.) This is the one place `gate`'s logic runs
inside the per-prompt path — but it only *renders* the decision already computed
for display; it changes nothing about `notice`'s own exit-0-always contract, and it
only executes at all once a session is already at `CLIFF_NEAR`/`CLIFF`, the same
rare tier `gate` itself is gated to.

**Test evidence**: `test/ctx-meter.test.sh`, Section R, 26 new assertions covering
below-ceiling always-proceed, `NON_VERIFIED` fail-open, confirmed-clean-boundary
refuse (at both `CLIFF_NEAR`-adjacent and `CLIFF` readings), live-agent defer,
dirty-tree defer, all three unresolvable-boundary defer sub-cases, `--json` shape,
`render_cliff`'s inline decision text, timing, `--help` discoverability, and
garbage-input robustness:

```
RESULT: 104 passed, 0 failed
```

## 7. What must carry across a restart — the resume contract

A gate that refuses new work is only as good as what the restart it forces
actually preserves. `bin/lib/resume-contract.sh` is the single shared answer key
both the checkpoint writer (`heimdall-checkpoint`) and the probe (`heimdall-resume-
probe`) read — a design chosen specifically because *"two implementations cannot be
held in agreement by intention. They can only share the decision"* (file header,
lines 5–14), after `heimdall-brief` was burned once by exactly that drift.

Six categories must never be lost, each with a named layer that sourced it:

| id | Must preserve | Layer |
|---|---|---|
| `in_progress` | what was in progress and the next step | checkpoint |
| `gated_decisions` | decisions parked awaiting a human call | checkpoint |
| `held_branches` | branches holding unmerged work, and why | checkpoint |
| `unpushed` | commits that exist only on this machine | checkpoint |
| `open_warnings` | open ⚠ items — known-broken, not yet fixed | index |
| `refuted_claims` | what this session proved FALSE | checkpoint |

`refuted_claims` is on this list on purpose: git records what a session decided,
never what it learned was wrong, so a restart that drops corrections re-walks every
dead end at full price. Grading is a normalize-then-digest comparison
(`rc_normalize` collapses whitespace so formatting never registers as loss;
`rc_digest` sha256's the result, with a hard failure — never a silent skip — when
no hasher is available anywhere on the machine). Three physical artifacts carry the
six categories across a restart: `.planning/RESUME-KEY.json`, `$HEIMDALL_HOME/
resume-notes.ndjson`, `.planning/CHECKPOINT.md` — plus a third, architecturally
distinct layer: the orphan `hmd/context` git branch, read only via `git show`
against `refs/heads/hmd/context`, never checked out, carrying a `worklog.json` with
its own `generated_ts`. Three of the six categories (`in_progress`,
`gated_decisions`, `refuted_claims`) exist only in a session's own head — no git
command can derive "what's the next step" or "we're waiting on a human" — which is
why `rc_note_category()` exists as a recording seam at all: without it those three
fields could only ever read "none," and a probe that grades three permanent blanks
proves nothing.

**Is resume provably lossless? Honest answer: not provable for this worktree, right
now, and that gap is real, not hypothetical.** The SessionStart hook this session
has been reporting *"resume probe GREEN — 6/6 never-lose categories recovered...
Streak: 100 green"* on every compaction. Checked directly, in this worktree, as
part of writing this doc:

```
$ test -f .heimdall/probe.ndjson && echo PRESENT || echo ABSENT
ABSENT
$ ls .heimdall/
.activity-stamp  .agents-count-cache  .repo-roster-*.json  .wall-cache.json
cp-endpoint.json.example  hooks -> /Users/rj/Downloads/heimdall/.heimdall/hooks
issue-loop.config.json.example  receipts/  team.json
```

No `probe.ndjson`, no `resume-notes.ndjson`, in **this** worktree's own
`.heimdall/`. `HEIMDALL_HOME` is unset in this shell, so `rc_home()` resolves to
`<repo>/.heimdall` — this worktree's own directory, confirmed empty of both files.
The "100 green" streak being reported is near-certainly accumulated against the
**main checkout's** transcript/session history, not this isolated worktree's — the
two are different repos on disk (a `git worktree`, not a clone, but with its own
independent `.heimdall/` state directory apart from the symlinked `hooks/`). A
gate that gains teeth makes this gap matter more than it did when everything was
advisory: the whole argument for "a restart here is cheap and safe" rests on the
resume contract actually being checked in the environment the restart happens in,
and right now the green streak an operator sees is not proof of that for every
worktree they might be sitting in when `gate` refuses. This should be closed
before `gate` is wired into anything that fires unattended — the honest fix is
making sure `heimdall-resume-probe` runs (and is checked, not just displayed)
against the same `HEIMDALL_HOME`/repo root the gate itself resolved, every time,
rather than relying on a cached streak from whatever session happened to run it
last.

## 8. Where true hard-binding would live — corrected finding, reported not applied

The original assumption going into this task was that hard-binding would need a
**new** `hooks.json` entry. Direct research this task corrected that: `hooks/
hooks.json` already wires every `Agent`-tool spawn through a `PreToolUse` matcher:

```
57:        "matcher": "Agent",
```

(`hooks/hooks.json`, confirmed present, command routes to `bin/heimdall-precheck-
agent`). That script already implements five fences, all following one consistent
pattern — deny by printing `{"error": "<reason>"}` (via `jq -cn --arg r "$REASON"
'{error: $r}'`) to stdout, the same text to stderr, and `exit 2`:

1. Named-agent notice (advisory: warns when `name:` is passed without a follow-up
   plan to `SendMessage` it).
2. In-process concurrency cap (opt-in, fails open if the plumbing to count
   concurrent spawns isn't available).
3. Adjudication fallback fence (denies `reviewer`/`verifier`/`security-auditor`
   spawns when the session is fallback-routed to a loopback endpoint).
4. Coop native-spawn refusal fence (denies coop-listed roles spawned via the
   native `Agent` tool, since it can't honor per-role env routing).
5. Brief-adoption gate (auto-substitutes a `heimdall-brief` header into long
   briefless prompts; denies only on `heimdall-brief`'s own `NON_VERIFIED`/exit-3).

No new `hooks.json` entry is needed for a real bind on new Agent spawns. The
natural home is a **sixth fence inside `bin/heimdall-precheck-agent`**, following
the same shape as the five above: call `heimdall-ctx-meter gate --json` before
allowing a spawn through, and when `.decision` reads `"refuse"`, deny in the same
way fence 3/4 already deny — `exit 2`, `{"error": "<the gate's own reason
string>"}` on stdout, the identical text on stderr. This is **reported, not
applied** — the brief for this task scoped `bin/heimdall-precheck-agent` and
`hooks/hooks.json` as report-only, and a change to either is a decision for
whoever owns that file, not something to land silently as a side effect of a
ctx-meter change.

**A real, named scope limit, stated plainly**: this fence — if built — would bind
exactly one surface: *new Agent-tool spawns*, at the moment a `PreToolUse` hook can
intercept them. It would not and could not bind the orchestrator's own continued
turns on an *already-open* conversation that never spawns anything — Claude Code
has no hook point that intercepts an orchestrator's own next reply mid-conversation
the way it intercepts a tool call. An orchestrator that reaches the hard ceiling
and simply keeps replying, without ever calling `Agent`, would never trip this
fence, exactly as it never trips any `PreToolUse` hook today. That is the honest
edge of what a `PreToolUse`-based mechanism can reach.

## 9. Standardizing this in `agents/heimdall.md`

Written as its own subsection (`### 8d. Context Window Discipline`, see that file)
stating the operating rule and pointing at the mechanical check by name, rather
than repeating a fourth instance of prose-only enforcement: it says outright that
prose mandates in this repo have failed to bind three times over (caveman, `metric
--type`, the report-once rule) and that this rule is different only insofar as
`bin/heimdall-ctx-meter gate` exists to be *run and checked*, not read. It commits
to checking `gate` before spawning new delegated work once a session is already
past `CLIFF_NEAR`, and to treating `exit 1` as a hard stop for *new* work — not a
suggestion — while being explicit that nothing today enforces the orchestrator
running that check any more than it enforced the prior three mandates. §8 closes
the loop honestly rather than overclaiming: standardizing the text is necessary but
not, by itself, sufficient; §8 of this doc is what would make it sufficient.

## 10. Honest verdict

- **Detection was never the gap.** `notice` already existed and already fired
  correctly, every time, including on the exact session that ignored it.
- **Binding is new, but narrow and named.** `gate` gives the orchestrator (and,
  if §8's proposed fence is built, `heimdall-precheck-agent`) a real exit code to
  check before starting new delegated work at the hard ceiling. That is a
  genuine, mechanical improvement over pure advisory — it is ungameable
  (process/filesystem facts, not self-report) and cheap (two subprocess calls,
  paid only at the rare hard-ceiling tier).
- **It is not, today, a hard block on anything.** Until a fence like the one in
  §8 is actually built and wired, `gate` is a tool that must still be *invoked*
  by something — currently `render_cliff`'s inline display, and whatever the
  orchestrator's own discipline (§9) chooses to run. That is strictly better than
  an advisory that only prints, because the exit code exists to fail a build or
  a script the moment anything actually checks it — but "something must still
  call it" is a real, stated limit, not a solved problem.
- **Quality protection holds up under its own acceptance bar.** The boundary
  check defers on any live agent and on any uncommitted change, unconditionally.
  A restart this gate ever actually forces happens only at a moment already
  confirmed to hold no in-flight reasoning state and no uncommitted work — so
  the "restart destroys the plan/acceptance-criteria/task-list" regression the
  brief named as worse than the $369.50 it's trying to save cannot occur through
  this mechanism, by construction of §5, not by hope.
- **One real gap, disclosed, not hidden**: resume being "provably lossless" is
  not true for this worktree today (§7) — the green streak an operator sees is
  most likely scoped to the main checkout, not every worktree. A gate with real
  teeth should not go live anywhere unattended until that is fixed.
- **No new savings figure is claimed anywhere in this document.** Every dollar
  and every ratio above already existed in `token-spend-forensics.md`,
  `2026-09-02-input-context-cost.md`, or `2026-09-07-cost-forensics-tool.md`
  before this task started.

Related: [`2026-09-02-input-context-cost.md`](2026-09-02-input-context-cost.md),
[`2026-09-07-cost-forensics-tool.md`](2026-09-07-cost-forensics-tool.md).

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
