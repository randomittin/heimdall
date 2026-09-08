# Context Window Discipline — A Mechanical Gate at the Hard Ceiling (2026-09-08)

Operator's ask, verbatim: *"prepare a better version of execution for context
discipline and standardize it to not impact the work quality while ensuring token
saving as much as possible."*

This doc covers what was built (`bin/heimdall-ctx-meter gate`, tiered, tested — 110
passed, 0 failed), what it reuses (zero new thresholds), what it cannot do (a real,
named limit), and an honest verdict on binding vs. advisory. No savings figure in
this doc is new; every number below already exists in `token-spend-forensics.md`,
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
treats as ground truth and what the tiering in §4 derives from directly. The
restart cost both docs independently agree on: **~35K tokens of re-paid preamble,
about $0.02** — the number the gate below is sized around not disturbing.

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
This design never blocks a turn, is not keyed to a token count alone (it is keyed to
token count **and** a proof of idleness), and — after the tiering in §4 — reserves
even the *possibility* of refusing for one tier out of three, not the first one an
operator crosses.

## 4. The design: three tiers, the same thresholds, zero new numbers

`bin/heimdall-ctx-meter`'s own `ENVIRONMENT` block already carries every threshold
this gate uses, each with its derivation inline — unchanged by this task:

```
HMD_CTX_CEILING     150000  target ceiling — the cap that recovers $369.50
HMD_CTX_CLIFF_NEAR  700000  ~7 requests of headroom at the measured 13,320 tok/req
HMD_CTX_CLIFF       800000  measured quintile-5 boundary (804,141): cache-write 3.2x
```

**Why the numbers didn't change even though 150,000 was already being ignored at
422,199 (2.8×over):** that overshoot is a failure of enforcement, not calibration.
150K is the figure that independently reproduces the $369.50 recoverable number in
§1-§2; 700K/800K bracket the measured cache-write cliff (804,141, a 3.2× surcharge)
— also already measured, not guessed. Moving either number without new measurement
would be exactly the invented-figure move this task was told never to make.
Re-deriving them from the two ratios in §2 instead of inheriting them unquestioned:
at 5.19–6.17× the cost multiple between low and high context, the marginal cost of
*not* enforcing anything below 700K is small (a soft floor is proportionate), while
the marginal cost of staying past 800K compounds two ways at once — the per-request
multiple AND the cache-write cliff — which is exactly why 800K, and only 800K, is
where this design allows a refusal at all. What was missing was never the number;
it was giving each of the three existing thresholds a distinct, honest behavior
instead of collapsing them into one binary "notice vs. don't":

| Tier | Threshold | Behavior | Can it refuse new work? |
|---|---|---|---|
| 1. Soft floor | `CEILING` (150,000) | Advisory only (`render_ceiling`) | No — `gate` always returns `ok` |
| 2. Strong notice | `CLIFF_NEAR` (700,000) | Firm checkpoint instruction | **Never** — `gate` always returns `checkpoint`, exit 0, and never even calls the boundary check below |
| 3. Hard ceiling | `CLIFF` (800,000) | Boundary-gated refusal | **Only here** — `gate` calls `_boundary_decision`; refuses only on a confirmed-clean boundary, else `defer` |

`notice` (existing, unchanged) stays exactly what it was: a per-prompt, stderr-only,
always-exit-0 advisory covering tiers 1 and 2's *display*. Its one hard invariant —
*"exits 0 on garbage, always"* — runs on every prompt and must never be able to
break a turn, and that invariant is incompatible with also being the verb that
refuses new work. `gate` (new) is the verb built for the different contract that
refusing requires — see the header comment, `bin/heimdall-ctx-meter:47–79`:

```
WHY `gate` IS A SEPARATE VERB FROM notice
------------------------------------------
notice's one hard invariant is "exits 0 on garbage, always" — it runs on
EVERY prompt and must never be able to break a turn. That invariant cannot
also be the verb that refuses new work, because refusing needs a REAL exit
code, a different contract. `gate` carries that contract instead...
```

Below `CLIFF_NEAR`, `gate` always exits 0 without touching the boundary check at
all — the low-context hot path never pays for it. At `CLIFF_NEAR` itself, `gate`
still never touches the boundary check (tier 2 is display-only escalation, proven
by tests R3/R3b below). Only at `CLIFF` does the boundary check run at all.

## 5. The boundary: mechanical, ungameable, cheap, and only invoked at CLIFF

**Chosen definition**: `heimdall-agents count == 0` AND `git status --porcelain`
empty. Both are process/filesystem facts, not self-reported prose, and both are
cheap enough (two subprocess calls) to matter only at the rarest tier (`CLIFF`) —
never on the per-prompt path `notice` still owns, and never even at `CLIFF_NEAR`.

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

**Why `git status --porcelain` empty, not just "no uncommitted TRACKED files"**:
porcelain output also reports untracked files (`??` lines). An agent's
freshly-written-but-not-yet-`git add`ed file is exactly as mid-flight as a modified
tracked one, and a check that ignored it would let `gate` refuse while real,
unrecorded work sat in the tree — precisely the "strand the operator" failure mode
§3 exists to rule out. The chosen check is deliberately the superset, not the
narrower tracked-only diff.

**Two other candidate signals were considered and rejected:**

- **A green full-sweep receipt present.** Rejected: the full sweep
  (`test/run-all.sh`, ~1600s per this repo's own `CLAUDE.md`) is far too expensive
  to gate a check that fires at every `CLIFF` reading across every session — using
  it would force either paying half an hour per gate call (violating "millisecond-
  cheap") or trusting a stale receipt from hours or days earlier that says nothing
  about whether the *current* tree is safe to abandon. It also conflates two
  different questions this repo's own `CLAUDE.md` deliberately keeps separate: "is
  it safe to stop here" (this gate's job) vs. "is the code correct" (the pre-push
  quality gate's job, already covered independently). If the tree is clean, there
  is nothing new to lose regardless of what the last sweep said; a sweep receipt
  adds cost without adding safety to *this* question.
- **`.planning/CHECKPOINT.md` fresher than the last commit.** Rejected: mtime
  freshness is a weak, accidentally-gameable proxy, not a positive proof. A
  CHECKPOINT.md can be touched (bumping mtime) without its content changing
  meaningfully, and can go stale the instant an agent resumes work AFTER writing an
  accurate one — the mtime comparison has no way to detect that new work started
  since. It also answers a different question than "is anything mid-flight right
  now" — it answers "was a checkpoint written at some point after the last
  commit," which is neither necessary (a clean tree with no checkpoint can still be
  a perfectly safe boundary) nor sufficient (a checkpoint can predate live,
  unrelated agent activity). `heimdall-agents count` answers the liveness question
  directly instead of inferring it from a timestamp.

## 6. The `gate` verb's contract

```
exit 0  -> proceed  (soft-floor "ok", strong-notice "checkpoint", OR a
           hard-ceiling reading that "defer"s because in-flight work
           exists or the boundary was unresolvable — an unverifiable
           reading always resolves here too)
exit 1  -> refuse   (ONLY at the hard ceiling (CLIFF) AND a clean,
           provable boundary — CLIFF_NEAR can never reach this)
```

Four decision strings, one for each reachable state: `ok` (tiers below
`CLIFF_NEAR`, and `NON_VERIFIED`), `checkpoint` (tier 2, `CLIFF_NEAR`, always —
proven never to vary with boundary state by test R3b, which forces two live agents
and a dirty tree simultaneously and still gets `checkpoint`), `defer` (tier 3,
boundary unclean or unresolvable), `refuse` (tier 3, boundary confirmed clean —
the only exit-1 case). `NON_VERIFIED` readings always resolve to `ok` — *"the
meter never blocks new work on its own blind spot"* — the same fail-open posture
`notice` already holds for its own primary reading.

`render_cliff` (the existing severe-escalation renderer `notice` calls at
`CLIFF`/`CLIFF_NEAR`) now names the live decision inline, and the framing is
tier-specific — only `CLIFF` ever shows refuse-capable language:

```
⛔ REFUSE NEW WORK — <reason>. Do not start anything new here; restart first.
```
or (also `CLIFF`, boundary not clean)
```
DEFERRING new-work refusal — <reason>.
```
or (`CLIFF_NEAR`, unconditionally — proven by test R8b to never show the above two)
```
STRONG NOTICE — checkpoint recommended now. This tier never refuses new
work; only the hard ceiling (800,000 tokens) can.
```

(`bin/heimdall-ctx-meter`, `render_cliff`, tail.) This is the one place `gate`'s
logic runs inside the per-prompt path — but it only *renders* a decision already
computed for display; it changes nothing about `notice`'s own exit-0-always
contract, and it only executes at all once a session is already at
`CLIFF_NEAR`/`CLIFF`, the same rare tier `gate` itself is scoped to.

**Test evidence**: `test/ctx-meter.test.sh`, Section R, 32 assertions (up from 26
pre-tiering) covering below-ceiling always-proceed, `NON_VERIFIED` fail-open, the
`CLIFF_NEAR` checkpoint tier proven immune to boundary state (R3, R3b — the direct
test for "never interrupt in-flight work," since it forces live agents AND a dirty
tree simultaneously at `CLIFF_NEAR` and still gets `checkpoint`, never `defer` or
`refuse`), confirmed-clean-boundary refuse only at `CLIFF` (R4), live-agent defer
at `CLIFF` (R5 — the direct proof for the hard-ceiling tier itself: two live
agents force `defer`, never `refuse`, regardless of tree state), dirty-tree defer
at `CLIFF` (R6), all three unresolvable-boundary defer sub-cases (R6b), `--json`
shape (R7), `render_cliff`'s tier-specific inline text including the new
`CLIFF_NEAR` strong-notice framing (R8, R8b), timing, `--help` discoverability,
and garbage-input robustness:

```
$ bash -n bin/heimdall-ctx-meter && echo "SYNTAX OK"
SYNTAX OK
$ bash test/ctx-meter.test.sh 2>&1 | tail -1
ctx-meter.test.sh: 110 passed, 0 failed.
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
against `refs/heads/hmd/context`, never checked out.

**Is resume provably lossless? Two real, first-hand, DIRECTLY CONFLICTING readings
exist, and both are reported here rather than picking the convenient one.** The
orchestrator running this task reported, having run `bin/heimdall-resume-probe run`
themselves: *"GREEN — 6/6 never-lose categories recovered from the stack (checkpoint
ok · index n/a · context-branch ok)"*, rc=0. Independently, run again here, fresh,
in the course of writing this doc, in **this worktree specifically**:

```
$ bin/heimdall-resume-probe run
[heimdall] resume probe RED — 0 of 0 never-lose categories did NOT survive the
restart. This is a bug in the MEMORY STACK, not a probe failure:
  - checkpoint — layer=checkpoint: .../agent-aed7a05870e308e45/.planning/
    CHECKPOINT.md does not exist — there is no forward state to resume from
```

Both runs are real; they are not measuring the same root. This worktree's own
`.heimdall/` (confirmed directly: `ls .heimdall/` lists `.activity-stamp`,
`.agents-count-cache`, roster caches, `team.json`, a `hooks` symlink to the MAIN
checkout's hooks — no `probe.ndjson`, no `resume-notes.ndjson`) has never had a
`.planning/CHECKPOINT.md` written into it at all. The most likely, and most
mundane, reconciliation: `heimdall-checkpoint write` is an *orchestrator*-level
action — it is the main session's job to checkpoint its own overall state — and
this worktree is a narrow-scope coder sandbox spawned for one delta-brief, never
expected to carry an independent checkpoint of its own. The orchestrator's GREEN
almost certainly reflects the main checkout, where a real orchestrator session has
in fact been checkpointing; this worktree's RED reflects a probe run against a
root that was never supposed to have its own checkpoint in the first place, not a
broken memory stack.

That reconciliation is plausible and probably right — but it is still an inference,
not a proof, and it points at a real, sharp design requirement for anything built
on top of `gate` going forward: **a boundary/resume check has to resolve against
one consistent root, chosen deliberately, not whichever root happens to be the
caller's cwd.** `gate` itself sidesteps this cleanly — `_repo_root()` always
resolves relative to the script's own installed location (or `HMD_CTX_REPO` for
tests), which for a coder worktree correctly means "this worktree," not "the main
checkout" — so `gate`'s own refuse/defer decision is unaffected by this ambiguity.
But if `gate`'s refusal is ever meant to imply "and resuming afterward is lossless,"
that implication is only as strong as whichever `HEIMDALL_HOME`/repo root the
resume-probe was actually run against, and the two are not automatically the same
thing. This should be closed before any hard-binding wiring (§8) goes live
unattended: run and check `heimdall-resume-probe` against the *same* root `gate`
itself resolved, at the point `gate` would refuse, rather than trusting a cached
streak from a different session or a different root.

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
allowing a spawn through, and when `.decision` reads `"refuse"` (i.e. the CLIFF
tier, confirmed-clean boundary — never `"checkpoint"`, which must keep proceeding),
deny in the same way fence 3/4 already deny — `exit 2`, `{"error": "<the gate's own
reason string>"}` on stdout, the identical text on stderr. This is **reported, not
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
prose mandates in this repo have failed to bind repeatedly — caveman compression
(3.25% filler survived full injection), `heimdall-metric --type` (~895/900 rows
missing it despite a CLAUDE.md mandate), and this very meter (ignored for a full
day at 2.8× its own ceiling) — and that this rule is different only insofar as
`bin/heimdall-ctx-meter gate` exists to be *run and checked*, not read. It commits
to checking `gate` before spawning new delegated work once a session is already
past `CLIFF_NEAR`, treating a `checkpoint` decision as a strong recommendation and
an `exit 1` (`refuse`) as a hard stop for *new* work — never a suggestion — while
being explicit that nothing today enforces the orchestrator running that check any
more than it enforced the prior three mandates, short of §8's proposed fence
actually being built. §10 closes the loop honestly rather than overclaiming.

## 10. Honest verdict — does this bind, or is it still advisory?

**A well-argued mixed answer, not a single word**, because the honest picture has
two different layers that move independently:

- **Detection was never the gap.** `notice` already existed and already fired
  correctly, every time, including on the exact session that ignored it.
- **The primitive is now genuinely binding-capable, and that is new.** `gate`
  gives anything that calls it a real exit code — 0 or 1 — computed from
  ungameable process/filesystem facts, not self-report. That is a real
  qualitative change from pure advisory: an exit code can fail a script,
  block a `&&` chain, or (per §8) deny a hook — an advisory string cannot do
  any of those things no matter how loudly it is worded.
- **Whether the SYSTEM binds today depends on who calls it, and today the
  answer is: only a human or an agent that chooses to.** Nothing currently
  invokes `gate` automatically before every Agent spawn — §8's fence is
  reported, not applied. `render_cliff`'s inline display surfaces the
  decision to a reader, but reading is exactly the advisory failure mode
  this whole doc is about; a displayed decision that nothing enforces is
  not meaningfully different from `notice` on its own. **So: still advisory
  at the system level, and this doc says so plainly rather than overclaiming
  a win.** What has changed is the SIZE of the remaining gap — from "invent
  and wire an entire enforcement mechanism" to "add one sixth fence, in one
  named file, following a pattern that already exists five times over."
- **The tiering makes the eventual bind safer, not just narrower.** Only the
  `CLIFF` tier (800K, the true hard ceiling) can ever produce a `refuse` —
  `CLIFF_NEAR` (700K) is a `checkpoint` decision that is, by test R3b,
  provably immune to boundary state. A future caller that wires §8's fence
  cannot accidentally block work at the softer tier; the blast radius of
  "wire this in and something goes wrong" is already fenced down to the one
  tier where a clean-boundary refusal is, by construction, a moment nothing
  was mid-flight.
- **One real gap, disclosed, not hidden**: whether "resuming after a refusal
  is lossless" is provable depends on which root the resume-probe is run
  against, and §7 shows two real, correct, DIFFERENT answers for the main
  checkout (GREEN) vs. this worktree (RED) at the same moment. A gate wired
  to refuse unattended should resolve its resume-check against the same
  root it resolved its boundary check against, and nothing today guarantees
  that alignment.
- **No new savings figure is claimed anywhere in this document.** Every
  dollar and every ratio above already existed in `token-spend-forensics.md`,
  `2026-09-02-input-context-cost.md`, or `2026-09-07-cost-forensics-tool.md`
  before this task started.

Related: [`2026-09-02-input-context-cost.md`](2026-09-02-input-context-cost.md),
[`2026-09-07-cost-forensics-tool.md`](2026-09-07-cost-forensics-tool.md).

Back to the master index: [`docs/INDEX.md`](../INDEX.md).
