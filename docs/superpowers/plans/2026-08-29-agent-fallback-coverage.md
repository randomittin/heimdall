# Agent Fallback Coverage + Multiple-Agents Mode — implementation plan

**Date:** 2026-08-29
**Owner directive, verbatim:** *"you need to ensure fallback covers agents as well and also supports multiple agents mode -- if not there then build it"*
**Status:** DESIGN ONLY. No implementation in this document. No push.
**Plan verification:** the fresh-context reviewer pass (`hmd:reviewer` grading plan-vs-spec) was **NOT run** — the authoring agent had no `Agent` tool in its toolset, so it could not spawn one. **This plan has not been independently reviewed and must be before Wave 1 dispatch.** Self-check performed instead: every file path and test-suite name cited in an acceptance criterion was existence-checked; one bad citation was found and corrected (`test/hmd-statusline.test.sh` does not exist — Task 2.3 now cites `test/heimdall-statusline-{gauge,perf-budget,width}.test.sh`).

**Sibling measurement doc:** `docs/analysis/2026-08-29-agent-fallback-seams.md` — **DID NOT EXIST when this plan was written** (checked twice, at the start and at the end of authoring). Every claim below is tagged MEASURED (I ran it in this session), READ (I read the source), or UNVERIFIED. **Every UNVERIFIED claim must be re-checked against the sibling's measurements before Wave 1 starts.** UNVERIFIED claims are collected in one place in §0.4 so the re-check is a checklist, not a re-read.

---

## 0. What is actually true today

### 0.1 MEASURED in this session

I am an in-process subagent, spawned through Claude Code's `Agent` tool. I ran:

```
echo "BASE_URL=[${ANTHROPIC_BASE_URL:-unset}] MODEL=[${ANTHROPIC_MODEL:-unset}] TOK=[${ANTHROPIC_AUTH_TOKEN:+SET}]"
→ BASE_URL=[http://127.0.0.1:8787] MODEL=[unset] TOK=[]
```

`127.0.0.1:8787` is the Headroom proxy, set on the parent `claude` process by `bin/heimdall-route` at launch. **In-process subagents inherit the parent session's routing environment.** This is not incidental — an in-process subagent shares the parent's OS process and therefore the parent's HTTP client, which was configured from that env at CLI startup.

Live gate state, same session:

```
./bin/heimdall-fallback --repo "$PWD" status
  state:                 auto
  would preflight pass:  yes
  endpoint:              http://127.0.0.1:20128
  target provider:       opencode  (keyless / free no-auth tier)

./bin/heimdall-fallback --repo "$PWD" check   → VERDICT: WAIT
  [OK  ] all nine preflight checks
  [INFO] session_usage -- under the pre-exhaustion threshold
```

Live limit snapshot, `~/.heimdall/rate-limits.json`:

```json
{"five_hour": {"resets_at": 1788008400.0, "used_percentage": 94.0},
 "seven_day": {"resets_at": 1788213600.0, "used_percentage": 61.0},
 "observed_at": 1788007577.1649358}
```

**`seven_day` is already on disk. `heimdall-session-usage` never reads it.** That is the single cheapest correctness fix in this plan.

### 0.2 READ from source

| Fact | Source |
|---|---|
| `hmd route` sets `ANTHROPIC_BASE_URL` on ONE child via `exec`, fallback URL wins over headroom, drops the gateway token on any unrouted launch | `bin/heimdall-route:170-279` |
| Judgment protection is `hmd_gate_exec` — `env -u <routing vars> ANTHROPIC_BASE_URL=$HMD_PROVIDER_BASE_URL "$@"`. **It works by creating a new process.** | `bin/lib/hmd-gate-endpoint.sh:75-87` |
| `session-fork` does **not** invoke `hmd route`. It calls `bin/hmd-exec run -p …` | `bin/session-fork:72` |
| `hmd-exec`'s `claude-code` backend sources `hmd-claude-retry.sh` and calls `hmd_claude_retry` | `bin/hmd-exec:180-192` |
| `hmd_claude_retry` invokes `local bin="${HMD_CLAUDE_BIN:-claude}"` — a bare `claude` off `PATH` from a **non-interactive** bash, where the `~/.zshrc:83` shell function is not in scope | `bin/lib/hmd-claude-retry.sh:68` |
| `PreToolUse`/`Agent` is already wired and already rewrites `tool_input` via `hookSpecificOutput.updatedInput` (schema-validated, confirmed against the installed binary) | `hooks/hooks.json`, `bin/heimdall-precheck-agent:22,132` |
| There is **no** `PostToolUse` matcher for `Agent`. There **is** a `SubagentStop` hook event, matcher `''` | `hooks/hooks.json` |
| `agent-pool` is a real file-backed concurrency limiter: `acquire` exits 2 at capacity, `wait` blocks, `health-check` reaps dead PIDs and stale-idle leases (`HMD_AGENT_STALE_SECS`, default 900), `should-scale` is capped by observed 529 pressure | `bin/agent-pool:1-45` |
| `session-fork` calls `agent-pool acquire` per fork; `MAX_PARALLEL` default 10 | `bin/session-fork:56-58,15` |
| The `PreToolUse`/`Agent` hook's only concurrency behavior is `parallelism-tracker check Agent` — an advisory nudge, no cap | `hooks/hooks.json` |
| `heimdall-529-scan` keys on transcript records with `isApiErrorMessage: true` and **deliberately ignores `error == "rate_limit"`** ("neither is a capacity signal") | `bin/heimdall-529-scan:1-30` |
| `auto` routes only on an explicit `verdict == "crossed"` allow-list; `unknown` and `unconfigured` both WAIT, by separate reasoned branches | `bin/heimdall-fallback:170-208, 1331-1360` |
| Chaining `claude → headroom → omniroute` is explicitly refused: the chain pins `HMD_HEADROOM_UPSTREAM` to `api.anthropic.com` and refuses any other destination, as a measured invariant | `bin/heimdall-route:148-160` |

### 0.3 The three defects, named precisely

**D1 — In-process subagents are covered only by accident, and only at launch time.**
Coverage exists *iff* the parent session was launched through `hmd route` *and* the gate said ROUTE *at that instant*. The production failure was mid-session: the parent launched with the gate at WAIT, four agents were spawned hours later, quota was gone, and nothing re-evaluated. **A running process's environment cannot be mutated from outside it — there is no syscall for that, and Claude Code does not re-read `ANTHROPIC_BASE_URL` per request.** So mid-session re-routing of the *current* session is impossible client-side. This is the hard limit of the whole problem and no part of this plan pretends otherwise.

**D2 — The accidental coverage is indiscriminate, and that is a live safety hole today, not a hypothetical.**
`hmd_gate_exec` protects judgment by *creating a scrubbed child process*. An in-process subagent has no exec boundary, so `hmd_gate_exec` cannot reach it. If the parent is launched while the gate says ROUTE, then **every** in-process subagent inherits the OmniRoute free-tier endpoint — including `hmd:reviewer`, `hmd:verifier`, and `hmd:security-auditor`. A verifier on a degraded free-tier model emits confident false greens. **This hole is reachable today with zero new code: `heimdall-fallback set auto` + a crossed threshold + `hmd route claude` is all it takes.** It is more urgent than the coverage gap the owner asked about, and Wave 1 fixes it first.

**D3 — The trigger watches one of the two limits that exist, and cannot see the one that actually fired.**
`heimdall-session-usage` reads `rate_limits.five_hour` only. In Claude Code's own vocabulary the five-hour window **is** the "session limit", so that half is correctly wired. The *weekly* limit is `rate_limits.seven_day`, which is persisted to `~/.heimdall/rate-limits.json` by the statusline and then never read. A weekly exhaustion with a fresh five-hour window reads as `under` → WAIT → no fallback → 429. That is exactly the reported failure sequence.

Additionally, the brief's option (c) is **false as stated**: `session-fork` does *not* pass through `hmd route`, because `hmd_claude_retry` execs a bare `claude` off `PATH` from a non-interactive shell where the zshrc function does not exist. It is, however, *one line* from being true — see Task 1.2.

### 0.4 UNVERIFIED — re-check against the sibling doc before Wave 1

| # | Assumption | Why it matters | How to falsify |
|---|---|---|---|
| U1 | Claude Code's API client reads `ANTHROPIC_BASE_URL` once at process start and in-process subagents therefore share the parent's endpoint (I measured the *env var* is inherited; I did not measure that a subagent's *traffic* goes there) | If false, D1/D2 change shape entirely and Wave 1 Task 1.1 may be unnecessary | Spawn a subagent from a session routed at `:8787` and check Headroom's request log for that subagent's turns |
| U2 | `SubagentStop` fires once per in-process subagent completion and its stdin payload carries a stable identifier correlatable to the `PreToolUse`/`Agent` event | Wave 3's in-process concurrency cap needs a release seam; without correlation the cap is TTL-only | Log `SubagentStop` stdin verbatim across a batch of 3 parallel spawns |
| U3 | `PreToolUse`/`Agent` `updatedInput` accepts a rewritten `subagent_type` (it is confirmed for `prompt`) | Task 1.1's "downgrade to deny" is unaffected, but any future "reroute the spawn" option depends on it | Rewrite `subagent_type` in the hook and observe which agent definition actually loads |
| U4 | `permissionDecision: "deny"` on `PreToolUse`/`Agent` surfaces the `permissionDecisionReason` text to the orchestrating model | Task 1.1's refusal must be *legible*, not a silent failure | Deny one spawn and read the tool result the orchestrator receives |
| U5 | A `seven_day` snapshot may lack `resets_at` (the source docstring says "does not always carry one"), so freshness must fall back to `observed_at` | Determines the freshness rule in Task 2.1 | Inspect `~/.heimdall/rate-limits.json` across several days |

---

## 1. The design

### 1.1 Answer to the owner's ask, in one paragraph

Fallback does **not** cover agents, and "multiple agents mode" exists for one of the two agent paths. The fix is not one mechanism but three, in strict safety order: (1) **stop** in-process adjudication agents from silently inheriting the free tier — a real hole open today; (2) **start** routing the subprocess agent path (`session-fork` / `hmd-exec` / `issue-loop` / `drain`) through the existing gate, which makes fallback genuinely cover agents and, because that path already uses `agent-pool`, simultaneously delivers "multiple agents mode with a shared concurrency limit" from parts that already exist; (3) **fix the trigger** so it watches both limits that are observable and reacts to an observed 429 for the exhaustion it cannot predict. What cannot be done client-side — re-routing the *already-running* parent session mid-flight — is not attempted, and the operator is told the truth instead.

### 1.2 Coverage for subagents — the three options, adjudicated

**(a) Env inheritance — REAL but insufficient, and dangerous as-is.**
MEASURED true (§0.1, modulo U1). It gives coverage for free whenever the parent launched routed. It fails on the exact production case (mid-session exhaustion) and it covers adjudication agents it must not cover (D2). **Verdict: keep it, but fence it.** Wave 1 Task 1.1 adds the fence. Do not build anything on top of it beyond that fence, because it cannot be made dynamic.

**(b) `PreToolUse`/`Agent` hook consulting the gate — REAL, with one honest limit.**
`updatedInput` is confirmed real and already in production use in this repo (`heimdall-precheck-agent:132`). The hook **can** deny a spawn, rewrite its prompt, and print disclosure to stderr. The hook **cannot** change the endpoint that spawn will use, because the spawn happens inside the parent process. So its useful powers are exactly two: **refuse** and **disclose**. Both are used. Any design that claims the hook "routes the agent" is a placebo. **Verdict: build it, for refusal + disclosure only.**

**(c) Route agent work through subprocesses — REAL, and the highest-leverage single change, but the brief's premise is wrong.**
`session-fork` does not currently pass through `hmd route` (§0.2). It is one seam away: `hmd_claude_retry` honours `HMD_CLAUDE_BIN`, so `hmd-exec`'s `claude-code` backend can point that at a two-line shim that execs `hmd route claude "$@"`. That single change routes **every** headless spawner in the repo — `session-fork`, `heimdall-drain`, `issue_loop.py`, `benchmark`, `decompose`, `heimdall-tokens` — through the gate, per-spawn, evaluated fresh. Because these are new processes, the gate is re-consulted every time, which is precisely what D1 needs and what (a) can never give. And because these are new processes, `hmd_gate_exec` works on them, so adjudication stays protectable. **Verdict: build it. This is the recommendation.**

**Recommendation: (c) as the primary mechanism, (b) as the safety fence and disclosure surface, (a) retained but fenced.** Nothing else. The honest consequence, stated once and repeated in the operator-facing text: **in-process subagents of an already-running session can never be re-routed mid-session; the only remedy for mid-session exhaustion on that path is to restart the session, or to move the work to the subprocess path.**

### 1.3 Multiple-agents mode — what it means, and what already exists

Definition, made precise for this repo: *N agents executing concurrently, each of which independently consults the fallback gate before it starts, all sharing one concurrency cap, with a defined behavior when the cap is reached and when the gate says WAIT.*

Audit against existing parts:

| Component | Does it exist? | Does it respect the gate? | Shared cap? |
|---|---|---|---|
| `bin/agent-pool` | Yes — real acquire/release/wait/health-check, TTL reaping, 529-pressure-capped scale-up | N/A (it is a limiter, not a spawner) | **Yes** — `max_agents`, default 10 |
| `bin/session-fork` | Yes — dependency-ordered waves, calls `agent-pool acquire` per fork | **No** — spawns via `hmd-exec` → bare `claude` | Yes, via agent-pool |
| `bin/decompose` | Yes — emits the wave/task graph | N/A | N/A |
| `hmd:wave-executor` (`agents/wave-executor.md`) | Yes, as an agent definition | **No** — dispatches in-process `Agent` spawns | **No** — only the advisory `parallelism-tracker` nudge |

So: **the subprocess half of multiple-agents mode already exists and needs one line to respect the gate. The in-process half has no cap at all.** Task 1.2 completes the first. Task 3.1 addresses the second — and it is deliberately last, and deliberately smallest, because it depends on U2 (a release seam) and a concurrency limiter that leaks slots deadlocks every future spawn. It fails open on every error, and it is TTL-leased so a leak self-heals in ≤ `HMD_AGENT_STALE_SECS`.

Per CLAUDE.md's own warning: **work-stealing, idle nudging and majority-vote conflict resolution are asked for in prompts and implemented by no scheduler.** Nothing in this plan reads, writes, or assumes any of them. See §5.

### 1.4 The trigger signal

Three tiers, strongest first. All three are additive `crossed` conditions on the existing allow-list; **none of them weakens any preflight check**, and a failing preflight still WAITs regardless (`bin/heimdall-fallback:170-208`).

1. **`five_hour` — already wired.** This *is* Claude Code's "session limit". Keep as-is.
2. **`seven_day` — observable, on disk, unread. Wire it.** `crossed` becomes `max(five_hour_pct, seven_day_pct) ≥ threshold`, and the verdict reports *which* window crossed (`crossed:five_hour` / `crossed:seven_day` / `crossed:both`) so an operator is never told "quota exhausted" without being told which quota. Freshness: `five_hour` keeps its existing `resets_at`-only rule (an observation whose `resets_at` has passed is ABSENT, never a low reading). `seven_day` uses `resets_at` when present and falls back to `observed_at + 18000s` when absent (U5) — a bounded TTL, never unbounded trust. A `seven_day` reading that is stale by either rule contributes `unknown`, not `under`; `unknown` on one window never masks a `crossed` on the other, and never promotes itself to `crossed`.
3. **Observed 429 — reactive, not predictive. Say so out loud.** There is no client-side signal that predicts the exhaustion that killed the four agents beyond the two windows above; if both read `under` and a 429 still arrives, the gate was not lied to, it was measuring a different thing. The honest response is to react to the observed event. `heimdall-529-scan` already parses the exact transcript records — `isApiErrorMessage: true` with `error` ∈ `{"rate_limit", "server_error", …}` — and **deliberately discards `rate_limit`** because it is a *capacity-pressure* tool and 429 is not capacity pressure. That exclusion is correct for that tool and must not be relaxed. So Task 2.2 builds a **sibling** reader over the same records that counts `error == "rate_limit"` events inside a bounded recent window, and `heimdall-session-usage` exposes it as a distinct fourth verdict input. It is labelled `crossed:observed-429` — never conflated with a threshold crossing, because it means something categorically different: *we already failed*, not *we are about to*.

**What we cannot see, stated plainly:** the harness's live HTTP responses. `bin/lib/pressure_control.py` already documents this ceiling and this plan does not pretend past it. Tier 3 is transcript-derived and therefore lags the failure by however long it takes the transcript to flush. It converts "N agents die silently" into "the next spawn routes to fallback", which is a real improvement and is not the same as prediction.

### 1.5 Safety constraints — how each is preserved

| Constraint | How this design preserves it |
|---|---|
| **Tier-1 credential isolation** (no `claude`/`claude-web` provider row) | Untouched. No task in this plan reads, writes, or bypasses `run_preflight`. Every new caller reaches routing *through* `heimdall-fallback base-url`, which runs the identical preflight `check` runs. Task 1.2's shim adds no new decision point — it calls `hmd route`, which calls the gate. Acceptance criterion 1.2-c asserts the four Tier-1 checks still appear and still fail closed. |
| **Judgment never on a fallback/compressed path** | Three layers. (i) `hmd_gate_exec` keeps working unchanged for every subprocess gate — Task 1.2's shim is inside `hmd-exec`, and `hmd_gate_exec`'s `env -u` scrub runs *outside* and *after* it, so a gate subprocess is scrubbed even if it later reaches `hmd-exec`. (ii) **New:** Task 1.1 adds an adjudication deny-list to the `PreToolUse`/`Agent` hook — when `ANTHROPIC_BASE_URL` points at the fallback endpoint and `subagent_type` is in the adjudication set, the spawn is **denied**, not silently degraded. (iii) **New:** Task 1.2's shim refuses to route when `HMD_JUDGMENT=1` is set, so a headless judge spawned through `hmd-exec` gets `api.anthropic.com` even under a ROUTE verdict. |
| **Adjudication set (explicit)** | `reviewer`, `verifier`, `security-auditor`, `incident-responder`, plus any `subagent_type` matching `*-review*`, `*-audit*`, `*-verif*`. Derived from `agents/` (`reviewer.md`, `verifier.md`, `security-auditor.md`, `incident-responder.md`) and CLAUDE.md's own "opus is retained only for adjudication: reviewer, verifier, security-auditor". The list lives in ONE file so it cannot drift between the hook and the shim. |
| **Wrong-audience token drop** | Untouched and now *more* load-bearing, because Task 1.2 puts many more launches through `heimdall-route`. Every one of those goes through the existing drop path at `bin/heimdall-route:257-266`. Acceptance criterion 1.2-d asserts an unrouted `hmd-exec` launch carries no `ANTHROPIC_AUTH_TOKEN`. |
| **`off` is the default; hmd never flips state** | Untouched. No task in this plan calls `heimdall-fallback set` or `arm`. The gate's state is operator-owned, before and after. |
| **No chaining headroom → omniroute** | Untouched. `hmd route`'s fallback branch `exec`s before the headroom branch is reached; the shim inherits that ordering for free and adds no second destination. |

**How adjudication stays off the fallback path while generation goes on it — the one-line version:** generation reaches the fallback by *going through a process boundary* (`hmd route`, `hmd-exec`), and adjudication is defined as the set of things that are either scrubbed at that same boundary (`hmd_gate_exec`, `HMD_JUDGMENT=1`) or **refused outright** when no boundary exists to scrub at (the in-process `Agent` deny). There is no third state where a judge runs degraded, because "cannot scrub" resolves to "refuse", never to "proceed".

### 1.6 Disclosure

Routing to `opencode`'s keyless tier means prompts and file context go to OmniRoute's free no-auth tier — the weakest data-retention terms available, the same category the ToS-conflict deny-list exists for. Current disclosure is a stderr line on the routed `claude` launch (`bin/heimdall-route:186-188`) — one line, once, at session start, on the shell path only. Under this plan far more work routes, so disclosure widens to three surfaces:

- **Per-spawn, subprocess path (Task 1.2):** the shim inherits `hmd route`'s existing stderr disclosure; every forked agent prints it. Loud by construction.
- **Per-spawn, in-process path (Task 1.1):** the `PreToolUse`/`Agent` hook prints a one-line stderr disclosure naming the provider, the tier, and the retention posture whenever a spawn is about to inherit a fallback endpoint. Not silenceable by a `HEIMDALL_ALLOW_*` flag — the named-agent notice has one because it is advisory; a data-egress disclosure does not get one.
- **Per-session, always-on (Task 2.3):** a statusline segment showing `⇢ oc/big-pickle (free tier)` whenever `ANTHROPIC_BASE_URL` is the fallback endpoint. The statusline already renders the rate-limit gauge from the same data (`sentinels/hmd-statusline.py:1779-1784`), so this is a sibling segment, not new plumbing. This is the surface that catches the case the per-spawn lines miss: an operator who scrolled past the launch banner three hours ago.

Wording is fixed in one constant, shared by all three, so the three can never disagree about what is being disclosed.

---

## 2. Waves

Nine tasks, four waves. Same-wave tasks touch disjoint files — verified in §2.5.

### Wave 0 — measure the seams this plan assumes

#### Task 0.1 — resolve U1–U5 against the sibling doc, or measure what it did not cover
- **Wave:** 0
- **Dependencies:** none
- **Agent:** `hmd:test-runner`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `docs/analysis/2026-08-29-agent-fallback-seams.md` (if it exists), `docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md` §0.4, `hooks/hooks.json`, `bin/heimdall-precheck-agent`
- **Files:** Create: `docs/analysis/2026-08-29-agent-fallback-seams-addendum.md`. Modify: none.
- **Skills:** `superpowers:verification-before-completion`
- **Patterns:** `docs/analysis/2026-08-25-hook-delivery-spike.md` is the house format for a hook-seam measurement — one section per question, the raw captured payload inline, a verdict line.
- **Acceptance criteria:**
  - [ ] `test -f docs/analysis/2026-08-29-agent-fallback-seams-addendum.md`
  - [ ] `for u in U1 U2 U3 U4 U5; do grep -q "^## $u" docs/analysis/2026-08-29-agent-fallback-seams-addendum.md || exit 1; done`
  - [ ] `grep -cE '^\*\*VERDICT:\*\* (CONFIRMED|REFUTED|UNMEASURABLE)' docs/analysis/2026-08-29-agent-fallback-seams-addendum.md` outputs `5`
  - [ ] `grep -q 'raw SubagentStop payload' docs/analysis/2026-08-29-agent-fallback-seams-addendum.md`
- **Verify:** `bash -c 'test -f docs/analysis/2026-08-29-agent-fallback-seams-addendum.md && [ "$(grep -cE "^\*\*VERDICT:\*\* (CONFIRMED|REFUTED|UNMEASURABLE)" docs/analysis/2026-08-29-agent-fallback-seams-addendum.md)" = 5 ]'`
- **Done when:** all five UNVERIFIED assumptions carry a CONFIRMED / REFUTED / UNMEASURABLE verdict with the raw evidence inline.
- **Risks & Mitigation:** If U1 is REFUTED, Task 1.1 changes scope (the deny may be unnecessary) — 1.1 must re-read this file before starting, which its "Read first" enforces. If U2 is REFUTED or UNMEASURABLE, Task 3.1 falls back to TTL-only leasing, which its own spec already covers.

**Wall-clock: ~30 min.** If the sibling doc already answers all five, this collapses to a ~10 min confirmation.

---

### Wave 1 — safety fence, then coverage. Both must land together.

Task 1.1 must not ship without 1.2 (a deny with no alternative path is a dead end for the operator), and 1.2 must not ship without 1.1 (widening what routes without the fence widens D2). They are same-wave and disjoint.

#### Task 1.1 — adjudication deny + per-spawn disclosure in the `PreToolUse`/`Agent` hook
- **Wave:** 1
- **Dependencies:** Task 0.1
- **Agent:** `hmd:coder`
- **Model + effort:** `opus` + `max` — this is the security-critical task in the plan; getting the deny wrong reintroduces the false-green verifier.
- **Read first:** `bin/heimdall-precheck-agent` (all 149 lines), `bin/lib/hmd-gate-endpoint.sh:60-120`, `docs/analysis/2026-08-29-agent-fallback-seams-addendum.md`, `agents/reviewer.md`, `agents/verifier.md`, `agents/security-auditor.md`
- **Files:**
  - Create: `bin/lib/hmd-adjudication-set.sh` — the single source of truth for the adjudication `subagent_type` list, sourced by both the hook and Task 1.2's shim. Exports `HMD_ADJUDICATION_TYPES` and a function `hmd_is_adjudication <type>` returning 0/1.
  - Modify: `bin/heimdall-precheck-agent` — add two branches ahead of the existing brief-adoption gate, leaving the named-agent notice and brief gate byte-identical.
- **Skills:** `superpowers:test-driven-development`, `superpowers:verification-before-completion`
- **Patterns:** Follow `bin/heimdall-precheck-agent`'s own fail-open discipline verbatim — no `set -e`, every unexpected condition exits 0 unchanged. Follow its one existing deny branch (the `heimdall-brief` exit-3 case) for the exact deny shape: exit 2 with `{"error": …}` on stdout+stderr. Follow `bin/heimdall-fallback`'s fail-closed reasoning for the *safety* branch specifically.
- **Behavior, exactly:**
  1. **Disclosure branch (always, never silenceable):** if `ANTHROPIC_BASE_URL` is a loopback URL equal to `heimdall-fallback --repo "$PWD" base-url`, print one stderr line naming provider, free-tier status, and retention posture. Exit 0. Applies to every spawn.
  2. **Deny branch:** if that same condition holds **and** `hmd_is_adjudication "$subagent_type"`, deny the spawn — `permissionDecision: "deny"` with a `permissionDecisionReason` naming the agent type, the endpoint, and the two remedies (run the judge as a subprocess through `hmd_gate_exec`, or restart the session unrouted). **This is the one deliberate deny; it is not silenceable and has no bypass env var.**
  3. Everything else — no `jq`, no `heimdall-fallback` binary, malformed payload, unreadable base-url, any error — exits 0 unchanged. A broken hook must never stop all work; only the deliberate deny blocks.
  4. The deny is **fail-closed on the safety question and fail-open on the plumbing question**: it denies only when it has *positively confirmed* both the fallback endpoint and the adjudication type. It never denies on an unknown.
- **Acceptance criteria:**
  - [ ] `bash -n bin/heimdall-precheck-agent && bash -n bin/lib/hmd-adjudication-set.sh`
  - [ ] `bash -c '. bin/lib/hmd-adjudication-set.sh; for t in reviewer verifier security-auditor incident-responder code-review pr-audit; do hmd_is_adjudication "$t" || exit 1; done'`
  - [ ] `bash -c '. bin/lib/hmd-adjudication-set.sh; for t in coder docs-writer design test-runner architect; do hmd_is_adjudication "$t" && exit 1; done; exit 0'`
  - [ ] `bash test/agent-fallback-adjudication.test.sh` exits 0 (suite authored in Task 1.4, so this criterion is graded at Wave-1 close, not at task close)
  - [ ] `grep -q 'HEIMDALL_ALLOW' bin/heimdall-precheck-agent` still matches the *pre-existing* flags only: `bash -c '[ "$(grep -c "HEIMDALL_ALLOW_NAMED_AGENT\|HEIMDALL_ALLOW_LONG_BRIEF" bin/heimdall-precheck-agent)" -ge 2 ] && ! grep -qE "HEIMDALL_ALLOW_(FALLBACK|ADJUDICATION|DEGRADED)" bin/heimdall-precheck-agent'`
  - [ ] `printf '{"tool_input":{"subagent_type":"coder","prompt":"hi"}}' | bin/heimdall-precheck-agent; test $? -eq 0` — a non-adjudication spawn is never denied
- **Verify:** `bash test/agent-fallback-adjudication.test.sh`
- **Done when:** an adjudication spawn under a fallback endpoint is refused with a legible reason, every other spawn is unaffected, and no bypass flag exists.
- **Risks & Mitigation:** A deny that fires when it should not halts all review work → the deny requires *positive* confirmation of both conditions and exits 0 on any uncertainty; Task 1.4's suite includes a "gate unreachable → allow" case. U4 REFUTED (deny reason not surfaced) → the reason is *also* written to stderr, which the hook contract does surface; this is why both channels are used.

#### Task 1.2 — route the headless spawn path through the gate
- **Wave:** 1
- **Dependencies:** Task 0.1
- **Agent:** `hmd:coder`
- **Model + effort:** `opus` + `high`
- **Read first:** `bin/hmd-exec` (all 207 lines), `bin/lib/hmd-claude-retry.sh:59-128`, `bin/heimdall-route:160-279`, `bin/lib/hmd-gate-endpoint.sh:72-90`
- **Files:**
  - Create: `bin/lib/hmd-route-claude` — an executable shim, exec-only: resolves the plugin's `heimdall-route` and `exec`s `heimdall-route claude "$@"`; if `HMD_JUDGMENT` is set to anything other than empty/`0`/`false`, or if `hmd_is_adjudication "$HMD_AGENT_TYPE"` matches, it `exec`s the real `claude` with `ANTHROPIC_BASE_URL` pinned to `$HMD_PROVIDER_BASE_URL` instead — i.e. it applies `hmd_gate_exec`'s pin itself rather than trusting an outer scrub.
  - Modify: `bin/hmd-exec:180-192` — in the `claude-code` backend branch only, export `HMD_CLAUDE_BIN` to the shim **when it is not already set**, so the existing test seam is preserved untouched.
- **Skills:** `superpowers:test-driven-development`, `superpowers:verification-before-completion`
- **Patterns:** `bin/heimdall-route`'s own no-recursion note (`command -v` from a non-interactive shell cannot see the user's `claude()` function) is the reason the shim cannot loop — reproduce that reasoning as a comment. `bin/lib/hmd-gate-endpoint.sh:75-87` is the exact pin to copy for the judgment branch; source it, do not re-implement it.
- **Acceptance criteria:**
  - [ ] `test -x bin/lib/hmd-route-claude && bash -n bin/lib/hmd-route-claude`
  - [ ] `grep -q 'HMD_CLAUDE_BIN' bin/hmd-exec`
  - [ ] `bash -c 'HMD_CLAUDE_BIN=/usr/bin/true bin/hmd-exec run -p x >/dev/null 2>&1; exit 0'` — the pre-existing test seam still overrides the default
  - [ ] `bash -c 'grep -q "exec" bin/lib/hmd-route-claude && ! grep -q "hmd-exec" bin/lib/hmd-route-claude'` — the shim never calls back into the dispatcher (no recursion)
  - [ ] `bash test/hmd-exec-fallback-routing.test.sh` exits 0 (suite authored in Task 1.4)
  - [ ] `bash -c 'HMD_JUDGMENT=1 HMD_CLAUDE_BIN=bin/lib/hmd-route-claude bin/lib/hmd-route-claude --print-endpoint 2>/dev/null | grep -q api.anthropic.com'` — a judgment spawn never lands on the fallback
- **Verify:** `bash test/hmd-exec-fallback-routing.test.sh`
- **Done when:** `session-fork`, `heimdall-drain`, `issue_loop.py`, `benchmark` and `decompose` all consult the gate per-spawn without any of them being edited, and a judgment spawn is pinned to the real provider.
- **Risks & Mitigation:** Shim breaks every headless spawn in the repo → it is exec-only with no logic beyond two branches, and `hmd route` itself is documented fail-open ("every failure lands on launch the tool unproxied, never on do not launch"). Recursion into `hmd-exec` → asserted absent by acceptance criterion 4. A spawn that was previously unrouted now routes and gets a weaker model without the caller expecting it → that is the *point*, and it is disclosed per-spawn on stderr by `hmd route`'s existing banner; Task 2.3 adds the persistent surface.

#### Task 1.3 — operator documentation of the one thing that cannot be fixed
- **Wave:** 1
- **Dependencies:** Task 0.1
- **Agent:** `hmd:docs-writer`
- **Model + effort:** `sonnet` + `default`
- **Read first:** this plan's §0.3 and §1.2, `bin/heimdall-route:1-45`, `bin/heimdall-fallback:170-208`
- **Files:** Create: `docs/fallback-and-agents.md`. Modify: none.
- **Skills:** none
- **Patterns:** `bin/heimdall-route`'s header is the house voice for "here is the measured problem, here is what this does not do" — mirror its structure: measured problem, what is covered, what is structurally impossible, what to do instead.
- **Content, required sections:** (1) the two agent paths and which is covered; (2) **"Mid-session exhaustion cannot re-route a running session"** — the no-syscall reason, stated without hedging; (3) the two remedies (restart the session; move work to the subprocess path); (4) why adjudication is denied rather than degraded; (5) the free-tier retention disclosure verbatim from the shared constant.
- **Acceptance criteria:**
  - [ ] `test -f docs/fallback-and-agents.md`
  - [ ] `grep -q 'cannot be re-routed mid-session' docs/fallback-and-agents.md`
  - [ ] `grep -q 'no syscall' docs/fallback-and-agents.md`
  - [ ] `grep -qi 'free.*tier' docs/fallback-and-agents.md`
  - [ ] `bash -c 'for s in "## The two agent paths" "## What cannot be fixed" "## Why adjudication is refused, not degraded" "## What routing to the free tier means for your data"; do grep -qF "$s" docs/fallback-and-agents.md || exit 1; done'`
- **Verify:** `bash -c 'for s in "## The two agent paths" "## What cannot be fixed" "## Why adjudication is refused, not degraded" "## What routing to the free tier means for your data"; do grep -qF "$s" docs/fallback-and-agents.md || exit 1; done && grep -q "no syscall" docs/fallback-and-agents.md'`
- **Done when:** an operator reading one page knows exactly which agents are covered, which are not, and why the uncovered case is not a bug to be filed.
- **Risks & Mitigation:** Doc drifts from code → it cites the specific files and line-anchored behaviors, and Task 1.4's suite includes a check that the disclosure string in the doc matches the shared constant byte-for-byte.

#### Task 1.4 — the independent correctness gate for Wave 1
- **Wave:** 1
- **Dependencies:** Task 0.1
- **Agent:** `hmd:test-runner`
- **Model + effort:** `opus` + `high`
- **Read first:** `test/heimdall-fallback.test.sh`, `test/heimdall-route.test.sh`, `test/issue-loop-claude-fix-fallback.test.sh`, this plan's §1.5
- **Files:** Create: `test/agent-fallback-adjudication.test.sh`, `test/hmd-exec-fallback-routing.test.sh`, `evals/oracles/agent-fallback/COVERAGE.md`, `evals/oracles/agent-fallback/INVARIANTS.md`. Modify: none.
- **Skills:** `superpowers:test-driven-development`
- **Patterns:** `test/issue-loop-claude-fix-fallback.test.sh` is the exemplar for a hermetic fallback fixture — it builds a fake OmniRoute SQLite DB rather than touching a live gateway. Copy that approach; **no test in this suite may require a running gateway.**
- **INVARIANTS.md must state, as checkable sentences:** (I1) an adjudication subagent never executes against a non-`api.anthropic.com` endpoint; (I2) a non-adjudication spawn is never denied by the fallback branch; (I3) a gate that cannot be consulted results in allow-and-unrouted, never allow-and-routed; (I4) no `ANTHROPIC_AUTH_TOKEN` survives onto a launch whose endpoint is not the fallback; (I5) the disclosure line appears on every routed spawn and is not suppressible.
- **Falsifiability, required:** each of I1–I5 ships with a **mutant** — a deliberately broken variant of the code under test that the suite must reject. The suite runs green on the real code and red on every mutant. This is the falsifiability proof; a gate that has never been shown red is not trusted.
- **Acceptance criteria:**
  - [ ] `bash test/agent-fallback-adjudication.test.sh` exits 0
  - [ ] `bash test/hmd-exec-fallback-routing.test.sh` exits 0
  - [ ] `bash -c 'grep -c "^### I[1-5]" evals/oracles/agent-fallback/INVARIANTS.md' ` outputs `5`
  - [ ] `bash -c 'grep -c "mutant" test/agent-fallback-adjudication.test.sh test/hmd-exec-fallback-routing.test.sh | awk -F: "{s+=\$2} END {exit !(s>=5)}"'`
  - [ ] `bash -c '! grep -qE "curl .*20128|nc -z" test/agent-fallback-adjudication.test.sh test/hmd-exec-fallback-routing.test.sh'` — hermetic, no live gateway
  - [ ] `test -f evals/oracles/agent-fallback/COVERAGE.md`
- **Oracle gate:** **No canonical registry oracle exists for this domain.** `jq -r '.oracles | keys[]' evals/oracles/registry.json` returns `emulator-gb, exchange-lob, issue-collection, ponytail-underdelivery, rr-multitenant-isolation, symbol-reuse, team-checkpoint, team-copilot, triage-coord` — none matches agent routing or credential isolation. Flagged for a reviewer to decide whether `agent-fallback` should be added as a registry row. In its absence: `gate_type: property + mutant-falsified`, `independent: true`, reference author = `hmd:test-runner` in a task with **disjoint file scope** from Tasks 1.1 and 1.2 (this task writes only `test/` and `evals/`; those write only `bin/`). **Justification for accepting a property gate here:** this target is a *stateless policy decision* — one input environment, one allow/deny/route verdict — not a stateful or sequence-producing target, so the plan-verification rule requiring `differential`/`trace-diff` does not apply. The whole-output-equality concern that rule exists for has no analogue in a pure predicate. Mutant falsification is what replaces it, and every invariant carries one.
- **Verify:** `bash test/agent-fallback-adjudication.test.sh && bash test/hmd-exec-fallback-routing.test.sh`
- **Done when:** all five invariants are green on real code and red on their mutants, with no live gateway required.
- **Risks & Mitigation:** Suite written by an agent who also wrote the impl → prevented structurally: this task's file scope is disjoint from 1.1/1.2 and it is dispatched as a separate agent. A property-only gate misses a whole-sequence bug → n/a for a stateless predicate, argued above; if a reviewer disagrees, the escalation is to add `agent-fallback` to the registry with a differential harness over a recorded env-matrix, which is scoped in `.planning/NEXT-CYCLES.md`.

**Wave 1 wall-clock: ~90 min** (four agents in parallel; 1.1 is the critical path at ~90 min, 1.4 at ~75 min, 1.2 at ~60 min, 1.3 at ~25 min). Wave-1 close requires 1.4's suites green against 1.1 and 1.2, so budget ~20 min of integration after the parallel work: **~110 min total.**

---

### Wave 2 — fix the trigger, and make routing visible

#### Task 2.1 — read `seven_day`; report which window crossed
- **Wave:** 2
- **Dependencies:** Task 1.4
- **Agent:** `hmd:coder`
- **Model + effort:** `opus` + `high`
- **Read first:** `bin/heimdall-session-usage:330-460`, `sentinels/hmd-statusline.py:1017-1070`, `bin/heimdall-fallback:890-935, 517-525`
- **Files:** Modify: `bin/heimdall-session-usage` (`read_real_usage` and the verdict/JSON emitters), `bin/heimdall-fallback:517-525` (`SESSION_USAGE_VERDICTS` / `SESSION_USAGE_NOTE_FMT` to accept the new sub-verdicts).
- **Skills:** `superpowers:test-driven-development`
- **Patterns:** `_window_snapshot` in `sentinels/hmd-statusline.py:1029` already handles the optional-`resets_at` case for `seven_day` — reuse its null-safety shape exactly. `bin/heimdall-fallback:170-208`'s four-state discipline is the contract: the new sub-verdicts must **extend** the `crossed` allow-list, never widen `unknown` into anything.
- **Behavior:** verdict vocabulary becomes `unconfigured | unknown | under | crossed`, with `crossed` carrying a `window` field ∈ `{five_hour, seven_day, both}`. `heimdall-fallback`'s allow-list check stays an exact `verdict == "crossed"` match, so no new code path can promote `unknown` to route. Freshness per §1.4.
- **Acceptance criteria:**
  - [ ] `bash -c 'printf "{\"five_hour\":{\"used_percentage\":10.0,\"resets_at\":9999999999},\"seven_day\":{\"used_percentage\":99.0,\"resets_at\":9999999999},\"observed_at\":9999999998}" > /tmp/rl.json; bin/heimdall-session-usage check --rate-limit-file /tmp/rl.json --json | grep -q "\"window\": \"seven_day\""'`
  - [ ] `bash -c 'printf "{\"five_hour\":{\"used_percentage\":99.0,\"resets_at\":9999999999},\"seven_day\":{\"used_percentage\":10.0,\"resets_at\":9999999999},\"observed_at\":9999999998}" > /tmp/rl.json; bin/heimdall-session-usage check --rate-limit-file /tmp/rl.json --json | grep -q "\"window\": \"five_hour\""'` — the pre-existing five-hour behavior is unchanged
  - [ ] `bash -c 'printf "{\"five_hour\":{\"used_percentage\":10.0,\"resets_at\":9999999999},\"seven_day\":{\"used_percentage\":10.0,\"resets_at\":1},\"observed_at\":1}" > /tmp/rl.json; bin/heimdall-session-usage check --rate-limit-file /tmp/rl.json --json | grep -q "\"verdict\": \"under\""'` — a stale `seven_day` never fabricates a crossing
  - [ ] `bash test/heimdall-session-usage.test.sh` exits 0 (existing suite, unmodified — a regression guard)
  - [ ] `bash test/heimdall-fallback.test.sh` exits 0 (existing suite, unmodified)
  - [ ] `bash test/heimdall-statusline-rate-limit-persist.test.sh` exits 0 (existing suite, unmodified — guards the producer of the `seven_day` field this task starts consuming)
  - [ ] `bash -c 'grep -q "verdict == \"crossed\"\|== CROSSED" bin/heimdall-fallback'` — the exact-match allow-list survives
- **Verify:** `bash test/heimdall-session-usage.test.sh && bash test/heimdall-fallback.test.sh && bash test/heimdall-statusline-rate-limit-persist.test.sh && bash test/session-usage-seven-day.test.sh`
- **Done when:** a weekly exhaustion with a fresh five-hour window produces `crossed:seven_day` and the gate routes, and no stale reading ever produces `crossed`.
- **Risks & Mitigation:** A widened verdict vocabulary silently widens routing → the allow-list stays an exact `== "crossed"` string match (asserted by criterion 6); `window` is metadata for the operator message, never a routing input. `seven_day` with no `resets_at` trusted forever → bounded `observed_at + 18000s` TTL, asserted by criterion 3.

#### Task 2.2 — observed-429 reactive condition
- **Wave:** 2
- **Dependencies:** Task 1.4
- **Agent:** `hmd:coder`
- **Model + effort:** `opus` + `high`
- **Read first:** `bin/heimdall-529-scan` (all of it), `bin/lib/pressure_control.py` docstring, `docs/analysis/2026-08-25-transcript-529-detection.md`
- **Files:** Create: `bin/heimdall-429-scan`. Modify: none. **`bin/heimdall-529-scan` is explicitly NOT modified** — its `rate_limit` exclusion is correct for a capacity-pressure tool and relaxing it would corrupt `pressure_control`'s AIMD input.
- **Skills:** `superpowers:systematic-debugging`, `superpowers:test-driven-development`
- **Patterns:** `bin/heimdall-529-scan`'s structured-field keying (`isApiErrorMessage`, `apiErrorStatus`, `error`) is the whole point — copy the field discipline verbatim and **never** regex over prose; that doc measured 31/31 false positives from a raw text search.
- **Behavior:** read-only scan of session transcripts for records with `isApiErrorMessage: true` and `error == "rate_limit"` inside a bounded window (default 1800s). Emits a count and the newest timestamp. Exit 0 always; a missing transcript dir is `count: 0`, never a crash.
- **Wiring:** `heimdall-session-usage` consults it best-effort and, on a non-zero recent count, emits `verdict: crossed` with `window: observed-429`. This is a **distinct, reasoned branch**, mirroring how `heimdall-fallback` keeps `unknown` textually separate from `under` despite both reaching WAIT — it means *we already failed*, not *we are about to*, and the operator message says exactly that.
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-429-scan && python3 -c "import ast,sys; ast.parse(open('bin/heimdall-429-scan').read())"`
  - [ ] `bin/heimdall-429-scan --transcript-dir /nonexistent --json | grep -q '"count": 0'`
  - [ ] `bash -c 'grep -q "rate_limit" bin/heimdall-429-scan && ! grep -q "server_error" bin/heimdall-429-scan'` — the two scanners keep disjoint classifications
  - [ ] `bash -c 'git diff --quiet HEAD -- bin/heimdall-529-scan'` — the 529 scanner is untouched
  - [ ] `bash test/heimdall-429-scan.test.sh` exits 0 — includes a fixture transcript with one real `rate_limit` record and one `server_error` record, asserting count 1
  - [ ] `bash -c '! grep -qE "re\.search|overloaded_error" bin/heimdall-429-scan'` — structured fields only, no prose regex
- **Verify:** `bash test/heimdall-429-scan.test.sh`
- **Done when:** an observed 429 in the last 30 minutes produces `crossed:observed-429`, and `heimdall-529-scan` is byte-identical to before.
- **Risks & Mitigation:** A single stray 429 flips a whole session onto the free tier → the window is bounded and the count threshold is configurable, defaulting to ≥1 because the measured incident killed four agents on the first one; an operator who wants hysteresis sets the threshold. Transcript lag means the reaction is late → stated explicitly in §1.4 and in Task 1.3's doc; this converts silent death into a late reroute, which is honest and better, not a prediction.

#### Task 2.3 — persistent routing disclosure in the statusline
- **Wave:** 2
- **Dependencies:** Task 1.4
- **Agent:** `hmd:coder`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `sentinels/hmd-statusline.py:1770-1800` (the rate-limit gauge row), `bin/heimdall-route:186-188` (the existing disclosure wording)
- **Files:** Modify: `sentinels/hmd-statusline.py` — one new segment function beside `rate_limit_seg`.
- **Skills:** none
- **Patterns:** `rate_limit_seg` / `five_hour_pct` / `seven_day_pct` are the exact shape to follow — a pure function returning a string or `None`, with the caller omitting the segment on `None`. Never raise from a statusline function.
- **Acceptance criteria:**
  - [ ] `python3 -c "import ast; ast.parse(open('sentinels/hmd-statusline.py').read())"`
  - [ ] `bash -c 'grep -q "def fallback_route_seg" sentinels/hmd-statusline.py'`
  - [ ] `bash -c 'ANTHROPIC_BASE_URL=http://127.0.0.1:20128 python3 sentinels/hmd-statusline.py </dev/null 2>/dev/null | grep -qi "free"'`
  - [ ] `bash -c 'ANTHROPIC_BASE_URL= python3 sentinels/hmd-statusline.py </dev/null 2>/dev/null; exit 0'` — never crashes when unrouted
  - [ ] `bash test/heimdall-statusline-gauge.test.sh` exits 0 (existing suite, unmodified — guards the rate-limit gauge row this segment sits beside)
  - [ ] `bash test/heimdall-statusline-perf-budget.test.sh` exits 0 (existing suite, unmodified — guards the per-render cost risk in this task's risk row)
  - [ ] `bash test/heimdall-statusline-width.test.sh` exits 0 (existing suite, unmodified — guards the "segment crowds the line out" risk)
- **Verify:** `bash test/heimdall-statusline-gauge.test.sh && bash test/heimdall-statusline-perf-budget.test.sh && bash test/heimdall-statusline-width.test.sh && bash -c 'ANTHROPIC_BASE_URL=http://127.0.0.1:20128 python3 sentinels/hmd-statusline.py </dev/null 2>/dev/null | grep -qi free'`
- **Done when:** a routed session shows the free-tier indicator on every statusline render, and an unrouted one shows nothing new.
- **Risks & Mitigation:** Statusline renders on every turn; a slow check costs every turn → the check is a string comparison against an env var already in the process, with no subprocess and no file read. Segment crowds the line out → it renders only when routed, which is the rare state.

**Wave 2 wall-clock: ~60 min** (three agents in parallel; 2.1 and 2.2 at ~60 min each, 2.3 at ~30 min).

---

### Wave 3 — the in-process concurrency cap, deliberately last and deliberately small

#### Task 3.1 — TTL-leased shared cap on in-process `Agent` spawns
- **Wave:** 3
- **Dependencies:** Task 2.1, Task 2.2, Task 2.3
- **Agent:** `hmd:coder`
- **Model + effort:** `opus` + `high`
- **Read first:** `bin/agent-pool` (all 432 lines), `bin/heimdall-precheck-agent` (as modified by Task 1.1), `hooks/hooks.json` (`SubagentStop`), `docs/analysis/2026-08-29-agent-fallback-seams-addendum.md` §U2
- **Files:** Create: `bin/heimdall-agent-lease` — acquire/release wrapper over `agent-pool` with a TTL lease keyed on a hook-visible identifier. Modify: `bin/heimdall-precheck-agent` (acquire branch), `hooks/hooks.json` (`SubagentStop` → release).
- **Skills:** `superpowers:test-driven-development`
- **Patterns:** `bin/session-fork:56-58` is the existing acquire call shape. `agent-pool health-check`'s `HMD_AGENT_STALE_SECS` reaping is the self-healing property this design depends on — do not add a second reaper.
- **Behavior, and its honest limit:** the hook acquires a lease before an `Agent` spawn and denies at capacity with a message naming the cap. `SubagentStop` releases. **If U2 is REFUTED — no correlatable identifier in the `SubagentStop` payload — the release degrades to "release the oldest outstanding in-process lease", which is approximate.** That approximation is acceptable *only* because a leaked lease self-heals via the existing TTL reaper within `HMD_AGENT_STALE_SECS` (default 900s), and because every error path fails **open** (allow the spawn). A concurrency limiter that can deadlock all future spawns is worse than no limiter; this one cannot, by construction.
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-agent-lease && bash -n bin/heimdall-agent-lease`
  - [ ] `bash -c 'bin/agent-pool init --max 2 >/dev/null; bin/heimdall-agent-lease acquire a >/dev/null; bin/heimdall-agent-lease acquire b >/dev/null; bin/heimdall-agent-lease acquire c; test $? -eq 2'` — the third spawn is refused at a cap of 2
  - [ ] `bash -c 'bin/heimdall-agent-lease release a >/dev/null; bin/heimdall-agent-lease acquire c; test $? -eq 0'` — a release frees a slot
  - [ ] `bash -c 'HMD_AGENT_LEASE_BIN=/nonexistent printf "{\"tool_input\":{\"subagent_type\":\"coder\"}}" | bin/heimdall-precheck-agent; test $? -eq 0'` — a broken lease tool never blocks a spawn
  - [ ] `bash test/agent-lease-cap.test.sh` exits 0 — includes a leak case asserting TTL recovery
  - [ ] `bash test/agent-fallback-adjudication.test.sh` exits 0 — Wave 1's gate still green
- **Verify:** `bash test/agent-lease-cap.test.sh && bash test/agent-fallback-adjudication.test.sh`
- **Done when:** in-process spawns share `agent-pool`'s cap, a leaked lease self-heals within the TTL, and no failure mode blocks a spawn.
- **Risks & Mitigation:** Leaked leases deadlock all spawns → fail-open on every error path plus the existing TTL reaper, both asserted by criteria 4 and 5. Approximate release attributes a stop to the wrong lease → the cap is a *count*, so a mis-attributed release still frees exactly one slot and the count stays correct; only per-agent attribution is lossy, and nothing depends on it. Cap frustrates legitimate wide fan-out → default cap is `agent-pool`'s existing 10, matching `session-fork`'s `MAX_PARALLEL`, so nothing that works today starts failing.

**Wave 3 wall-clock: ~50 min** (single agent).

---

### 2.5 Same-wave file disjointness — verified

| Wave | Task | Writes |
|---|---|---|
| 0 | 0.1 | `docs/analysis/2026-08-29-agent-fallback-seams-addendum.md` |
| 1 | 1.1 | `bin/lib/hmd-adjudication-set.sh`, `bin/heimdall-precheck-agent` |
| 1 | 1.2 | `bin/lib/hmd-route-claude`, `bin/hmd-exec` |
| 1 | 1.3 | `docs/fallback-and-agents.md` |
| 1 | 1.4 | `test/agent-fallback-adjudication.test.sh`, `test/hmd-exec-fallback-routing.test.sh`, `evals/oracles/agent-fallback/*` |
| 2 | 2.1 | `bin/heimdall-session-usage`, `bin/heimdall-fallback` |
| 2 | 2.2 | `bin/heimdall-429-scan` |
| 2 | 2.3 | `sentinels/hmd-statusline.py` |
| 3 | 3.1 | `bin/heimdall-agent-lease`, `bin/heimdall-precheck-agent`, `hooks/hooks.json` |

No file appears twice in any wave. `bin/heimdall-precheck-agent` is written by 1.1 (wave 1) and 3.1 (wave 3) — sequenced across waves, which is why 3.1 is not merged into wave 1 despite being independent in spirit.

### 2.6 Total wall-clock

| Wave | Parallel agents | Wall-clock |
|---|---|---|
| 0 | 1 | ~30 min |
| 1 | 4 | ~110 min (incl. integration) |
| 2 | 3 | ~60 min |
| 3 | 1 | ~50 min |
| **Total** | | **~4.2 hours of wall-clock with parallelism** (~7.5 agent-hours serial) |

Wave 1 alone — the safety fence plus real subagent coverage — is **~2.3 hours** and is the shippable minimum. Waves 2 and 3 are improvements on a system that is already safe and already covering the subprocess path.

### 2.7 `waves.json`

Not emitted: 9 tasks total, max 4 per wave, both under the 10-task auto-emit thresholds.

---

## 3. Risks & Mitigations

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| U1 refuted — in-process subagents do *not* actually use the inherited `ANTHROPIC_BASE_URL` | low | high | Task 0.1 measures it before any code is written; if refuted, Task 1.1's deny branch is descoped and the disclosure branch is kept | 0.1 |
| An adjudication verifier silently runs on the free tier (D2, live today) | **high — reachable now with zero new code** | **critical** | Task 1.1's non-silenceable deny; Task 1.2's `HMD_JUDGMENT` pin; both proven by mutants in Task 1.4 | 1.1, 1.2, 1.4 |
| The `PreToolUse` deny fires wrongly and halts all review work | medium | high | Deny requires positive confirmation of *both* conditions; every uncertainty exits 0; "gate unreachable → allow" is an explicit test case | 1.1, 1.4 |
| Task 1.2's shim breaks every headless spawn in the repo | medium | high | Shim is exec-only, two branches; `hmd route` is documented fail-open; the pre-existing `HMD_CLAUDE_BIN` test seam is preserved and asserted | 1.2, 1.4 |
| Shim recurses into `hmd-exec` | low | high | Asserted absent by an acceptance grep; `hmd route` resolves the tool with `command -v` from a non-interactive shell, which cannot see a shell function | 1.2 |
| Widened verdict vocabulary silently widens routing | medium | high | `heimdall-fallback` keeps an exact `== "crossed"` allow-list; `window` is operator-facing metadata only, asserted by a grep | 2.1 |
| A stale `seven_day` reading fabricates a crossing | medium | medium | `resets_at` when present, bounded `observed_at + 18000s` when absent; stale contributes `unknown`, never `under` or `crossed`; asserted by a test | 2.1 |
| Relaxing `heimdall-529-scan` to count 429s corrupts `pressure_control`'s AIMD input | medium | medium | A **sibling** tool is built; `git diff --quiet` on the 529 scanner is an acceptance criterion | 2.2 |
| One stray 429 flips a healthy session onto the free tier | medium | medium | Bounded 1800s window; count threshold configurable; disclosed on every routed spawn and persistently in the statusline | 2.2, 2.3 |
| Leaked in-process leases deadlock every future spawn | medium | high | Fail-open on all error paths + existing `HMD_AGENT_STALE_SECS` TTL reaper; leak-recovery is an explicit test case | 3.1 |
| The correctness gate is written by whoever wrote the impl | low | high | Task 1.4 is a separate agent with file scope disjoint from 1.1/1.2, and every invariant ships a mutant it must reject | 1.4 |
| Docs drift from the shipped behavior | medium | low | Task 1.4 asserts the disclosure string in `docs/fallback-and-agents.md` matches the shared constant byte-for-byte | 1.3, 1.4 |
| Statusline segment slows every render | low | low | One env-var string comparison; no subprocess, no file read | 2.3 |

---

## 4. Red flags in this plan, named

- **A property-only gate on a stateless predicate.** Flagged, argued in Task 1.4, and defensible: the target is one env → one verdict, with no sequence to diff. Mutant falsification replaces whole-output equality. **A reviewer may legitimately overrule this**; the escalation path (a registry `agent-fallback` row with a differential env-matrix harness) is scoped in `.planning/NEXT-CYCLES.md` rather than pretended away.
- **No canonical registry oracle for this domain.** Stated in Task 1.4 with the `jq` output that proves it, flagged for a reviewer decision rather than silently substituted.
- **Five UNVERIFIED assumptions.** All collected in §0.4, all assigned to Task 0.1, all with a falsification method. Wave 1 does not start until they have verdicts.
- **Task 3.1's approximate release.** Named as approximate rather than described as correct, with the TTL-reaper argument for why approximate is survivable here and would not be elsewhere.
- **`bin/heimdall-precheck-agent` is touched in two waves.** Deliberate sequencing, not an oversight — noted in §2.5.
- **Not a red flag, but worth stating:** the largest single finding in this plan (D2) was not in the owner's brief. It is a live hole, it is more urgent than the gap that was asked about, and Wave 1 fixes it first.

---

## 5. WHAT WE WILL NOT BUILD, AND WHY

1. **Mid-session re-routing of a running session.** Impossible client-side. A running process's environment cannot be mutated from outside it — there is no syscall for that — and Claude Code does not re-read `ANTHROPIC_BASE_URL` per request. Any design claiming to reroute the current session's in-process subagents mid-flight is a placebo. We document the limit (Task 1.3) and give two real remedies instead: restart the session, or move the work to the subprocess path that Task 1.2 covers.

2. **Per-subagent endpoint override.** Same reason, one level down. In-process subagents share the parent's HTTP client. No amount of `PreToolUse` / `updatedInput` work changes which host that client connects to. The hook's real powers are refuse and disclose; we use exactly those and claim nothing more.

3. **Chaining `claude → headroom → omniroute`.** `bin/heimdall-route:148-160` refuses it deliberately: the chain pins its upstream to `api.anthropic.com` and that refusal is a *measured* invariant verified from the running process. Widening it to admit a second destination trades a real security property for a compression saving on the one path where compression matters least — the fallback path already drops compression on purpose, because handing a weaker model a compressed prompt is the worst possible moment to spend its comprehension on decompression.

4. **Predicting exhaustion beyond `five_hour` and `seven_day`.** Those are the two windows Anthropic's payload exposes. There is no third. `bin/lib/pressure_control.py` already documents that hmd cannot see the harness's live HTTP responses. Tier 3 is honestly labelled *reactive*, and we do not build a model that guesses at an unobservable limit.

5. **Relaxing `heimdall-529-scan` to also count 429s.** Its `rate_limit` exclusion is correct for a capacity-pressure tool feeding `pressure_control`'s AIMD loop. Widening it would corrupt an existing, working signal to avoid writing a small sibling. We write the sibling.

6. **Work-stealing, idle nudging, and majority-vote conflict resolution.** CLAUDE.md states these are asked for in prompts and enforced by no scheduler. Building the fallback gate or the concurrency cap on top of behavior no code implements would produce a system that works in the plan and not on the machine. Nothing here reads or assumes them.

7. **A new orchestrator, scheduler, or "multiple agents mode" subsystem.** `agent-pool` + `session-fork` + `decompose` already are that system for the subprocess path, and it works. The gap was one line of routing (Task 1.2) and one missing cap on the *other* path (Task 3.1). Building a parallel orchestrator to satisfy the phrase "multiple agents mode" would be a large speculative system replacing a small working one.

8. **Auto-arming or auto-flipping the fallback state.** `off` is the default and the operator owns the state. `heimdall-quota-advisor` promises hmd "never auto-switches ANY provider for the operator. Ever." No task here calls `heimdall-fallback set` or `arm`.

9. **A bypass flag for the adjudication deny.** The named-agent notice has `HEIMDALL_ALLOW_NAMED_AGENT` because it is advisory. A degraded-judge deny is not advisory — a bypass flag on it is a bypass flag on the single most dangerous failure mode in the system, and it would be used within a week of the first inconvenient deny. Asserted absent by an acceptance criterion.

10. **A test suite that requires a live OmniRoute gateway.** `test/issue-loop-claude-fix-fallback.test.sh` already proves hermetic fixtures work for this exact subsystem. A gate that only runs when a service happens to be up is a gate that quietly stops running.

---

## OUT OF SCOPE

- **Headroom compression coverage for subagents.** Related and genuinely interesting (compression currently has the same in-process inheritance story), but a separate concern with a separate risk profile. Not touched here beyond the fallback-wins precedence that already exists.
- **OmniRoute gateway lifecycle** — starting, supervising, health-checking, or restarting it. `heimdall-fallback` is a policy gate and explicitly not a transport; this plan keeps that boundary.
- **Any change to the nine Tier-1 / ToS / sidecar preflight checks.** They are read, never modified. Adding a provider, changing the ToS deny-list, or altering credential-absence verification is out of scope entirely.
- **Choosing or benchmarking a better fallback model.** `oc/big-pickle` is what is configured; model selection is an operator decision and a separate evaluation.
- **Cost or quality measurement of fallback-routed generation.** Worth doing; needs its own eval harness and its own plan.
- **`hmd wrap`, git hooks, AGENTS.md, presence.** Untouched — `hmd route` was built specifically to be the routing half without those side effects, and that separation is preserved.
- **Retrofitting the ~26 historical commits or any past session.** Forward-looking only.
- **Multi-tenant / TEAM-mode fallback policy** (whether one teammate's fallback state should affect another's). Real question, out of scope; noted for a future cycle.
- **Adding an `agent-fallback` row to `evals/oracles/registry.json`.** Flagged for a reviewer decision in Task 1.4, scoped to `.planning/NEXT-CYCLES.md` if accepted.
- **Deployment, rollout, or version-bumping.** Separate plan.
