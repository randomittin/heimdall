# hmd's viral launch — design spec

**Status:** design complete, ready for build sequencing. No implementation in this doc.
**Author:** hmd-architect · **Date:** 2026-08-22
**Rebase proof:** `git rev-parse HEAD` == `git merge-base HEAD main` == `git rev-parse main`
== `ab94effa842a38dbd422599e175b269e2262e4b8` (verified this session — branch is main tip,
nothing to rebase).
**Scope:** design the launch surface, demo, benchmark, and receipt/badge loop; rank what to
add; every claim below is either a command I ran this session (quoted) or explicitly marked
as a build task with an effort estimate. Nothing here is proposed as launch copy until its
command has been run and its output matches the claim.

---

## 0. Thesis (not reinvented — confirmed still true, and under-exploited)

> The product is not the agent. It is a system that refuses to believe an AI agent's claim
> that it succeeded.

hmd's own repo just spent two days finding and removing five overclaims from its own surface
(`docs/analysis/2026-08-20-launch-readiness-audit.md`) — a fabricated 65-75% token-saving
figure, a headroom number that was one event in 177 read as an aggregate, a `/hmd:verify`
command that never existed, a `sha256` mismatch on the install path, root-level `index.js`
returning `42` with a tautologically-green test script. **That audit is itself the best launch
asset in the repo and is not currently used as one.** A security/reliability tool that can be
shown publicly auditing and fixing its own overclaims is a stronger trust signal than any
benchmark number, because it demonstrates the mechanism working on the one target it can never
soften a verdict on: itself.

The launch does two things and nothing else:
1. **Show the mechanism catching a real bug a stranger cannot dismiss as cherry-picked**
   (§1, the demo).
2. **Publish the one metric nobody else publishes** — false-green rate — with a rerun command
   (§2, the benchmark).

Every other asset (badge, receipts, agent roster, team wall) is in service of those two, not a
peer to them.

---

## 1. Capability truth table (my own probes, this session — supersedes nothing the sibling
census produces, but nothing below ships to a launch surface until it or the census confirms
it)

Every command was run in `/Users/rj/Downloads/heimdall` on 2026-08-22. Quoted output is
verbatim, trimmed only for length.

| Capability | Command | Status | Evidence |
|---|---|---|---|
| Oracle falsifiability demo | `bin/falsify --demo` | **LIVE** | `SCORE: 3/3 = 1.0000`, kill-card rendered, zero setup, zero network |
| exchange-lob differential gate | `evals/oracles/exchange-lob/gate.sh --differential --seeds 200` | **LIVE** | exit 0, resolved via `bin/oracle-select exchange-lob` |
| Mutation corpus catch-rate | `bin/corpus run` | **LIVE** | `corpus-catch-rate: 13/13` (100%), wrote `evals/corpus/CORPUS-STATUS.md` |
| S-6 cold-repo sweep harness | `bin/heimdall-s6-sweep` | **LIVE (harness)** | `test/s6-sweep.test.sh` passes |
| S-6 real 10-repo run | — | **REACHABLE, unpublished** | Real dated run exists at `.planning/s6-sweep/20260620T050833Z-88787.json` (2026-06-20): `working_output_rate: 0.6`, 10 real popular repos, real token spend `10,546,175`. **But** the canonical manifest `docs/superpowers/specs/heimdall-S6-C3-repos.json` is still stamped `"status": "PROPOSAL v3 ... requires RJ sign-off on repos+tasks+bands before any run"` — the data exists, the sign-off gate that would make it citable does not. 2 of the 4 non-passing repos failed only because `go`/`cargo` are absent on this machine (`bash: go: command not found`, `bash: cargo: command not found`), not code defects |
| `hmd badge` (markdown/json/count) | `bin/heimdall-badge --json` | **LIVE (local number)** | `{"count":28,"message":"28 proven merges", ...}` — a real `beats.log`-derived count, not a placeholder |
| `hmd badge --svg` | `bin/heimdall-badge --svg` | **LIVE, offline-safe** | Produces a real 22-line SVG locally, no network |
| Hosted badge image (`runheimdall.dev/badge/heimdall.svg`) | `curl -sS -o /dev/null -w '%{http_code}' https://runheimdall.dev/badge/heimdall.svg` | **CLAIMED-ONLY — 404** | Also probed `/badge`, `/badge.svg`, `/badge/heimdall` — all 404. **`hmd badge`'s own default markdown output right now embeds a dead `<img>` src.** This is the exact B3-class defect (advertised-but-missing) the Aug 20 audit exists to catch, and it is live in the one command whose entire job is to be pasted into a stranger's README. |
| `runheimdall.dev/proof` | `curl -w '%{http_code}' -L https://runheimdall.dev/proof` | **LIVE** | 200 |
| `runheimdall.dev` root | same | **LIVE** | 200 |
| `/hmd:verify` (the B3 phantom command) | `ls commands/verify.md`; `git grep '/hmd:verify' README.md` | **FIXED — removed** | File never existed; the README row citing it is gone (confirmed absent from current README, was present only in the Aug 20 audit's *quote* of the old state) |
| `hmd report` / `hmd designmatch` dispatcher cases | `grep -n 'report)\|designmatch)' bin/heimdall` | **FIXED — now LIVE** | Dispatcher cases exist at `bin/heimdall:2376,2394`; both binaries (`bin/heimdall-report`, `bin/designmatch`) were already executable |
| Root `index.js` / `package.json` stub (B4) | `ls index.js package.json` | **FIXED — removed** | `No such file or directory`, both |
| claude-mem auto-install | `grep HEIMDALL_INSTALL_CLAUDE_MEM install.sh` | **FIXED — opt-in** | `opt in to installing the claude-mem plugin (default: <off>)` — matches the reviewer's flagged risk, already closed by `abff402 fix(install): stop preinstalling claude-mem by default` |
| Plugin/skill marketplace auto-registration | `install.sh:1155-1180` | **LIVE, still on by default** | `hmd`'s own installer registers itself as a Claude plugin marketplace and installs itself as a plugin, unprompted, as part of `install.sh`'s core path (not the claude-mem opt-in path). Security-sensitive surface the reviewer flagged; not closed, see §4 |
| Agent roster size | `ls agents/*.md \| wc -l` | **LIVE, count is 16** | Not "14" anywhere I found in current README — the reviewer's "14 agents" was a framing risk to avoid (any count as a headline), not a specific live overclaim |
| `--team N` coordination | `grep 'Shipped (no coordination' README.md` | **LIVE, already honestly disclosed** | Row 205: `Shipped (no coordination layer)` — this is correctly hedged already; the recommendation in §4 is about *emphasis*, not accuracy |

**Action item for whoever owns this launch:** fix the badge 404 before publishing anything
that recommends pasting `hmd badge`'s default output into a README (§3, T-1).

---

## 2. The demo (design item 1)

### 2.1 What ships

Two demos, ranked, because they serve different skeptics.

**Demo A — "run this in 30 seconds, no repo, no model calls" (the top-of-funnel demo).**

```
git clone https://github.com/randomittin/heimdall && cd heimdall
bash bin/falsify --demo
```

This is `bin/falsify --demo` exactly as it exists today (verified live, §1). It:
- runs the bundled `ponytail-underdelivery` oracle's golden fixture and confirms it's GREEN
  (a gate that rejects its own golden is broken — checked first, on purpose),
- runs three real mutants (`hard-part-skipped`, `criterion-dropped`, `terse-but-broken`)
  against the same gate and shows each is KILLED with the exact counterexample
  (e.g. `roman(4): expected IV actual IIII`),
- renders a kill-card: `SCORE: 3/3 = 1.0000`.

**Why this is the right first demo, not a toy:** it needs no `claude` CLI, no API key, no
network, and no cherry-picking — anyone who clones the repo gets the identical three mutants
and the identical score, because they're committed fixtures
(`evals/oracles/ponytail-underdelivery/fixtures/{golden,mutants}/`), not generated per-run.
**A skeptic verifies it by reading the mutant source** (`fixtures/mutants/hard-part-skipped.mjs`
etc.) and confirming the gate's stated counterexample matches the actual planted bug — the
repro is the fixture, not a claim about a fixture.

**Demo B — "watch it deny, then prove" (the reviewer's suggested arc, now scoped to an
existing real bug so it isn't staged).**

Target: `evals/oracles/exchange-lob`. This is chosen over inventing a new demo repo because
the bug it demonstrates **already happened for real**, is fully traced
(`evals/flagship/SPIKE-FINDINGS.md`), and is exactly the class of bug the reviewer described
("agents generating tests that faithfully test the wrong implementation") — a naive
implementation that passes every local check while a whole-sequence race is live.

Script (to be recorded, not narrated live — see effort estimate in §5):
1. A fresh Claude Code session is given the LOB matching spec
   (`evals/oracles/exchange-lob/INVARIANTS.md` minus the C2 section, to avoid leaking the
   answer) and asked to implement a `submit(order)` matching engine plus its own concurrency
   test, with no mention of hmd's oracle.
2. The agent says "done" — its own test suite (per-trade invariants + a `Promise.all`-style
   concurrency check) is green. This is the **exact false-green pattern already measured**
   in Arm 1 of the spike (`SPIKE-FINDINGS.md` lines 39-49): the naive concurrency check
   resolves in arrival order by construction and cannot fail.
3. `bin/oracle-select exchange-lob` resolves the canonical gate; `evals/oracles/exchange-lob/gate.sh
   --differential --seeds 200` is run against the agent's implementation. **DENIED** — the
   real finding was `C2 concurrent == serial replay .... FAIL @ seed 1, index 0`, with the
   exact minimal 7-order reproducing sequence and the exact wrong trade
   (`takerId=7 makerId=2 price=99 qty=5` where the reference says `takerId=3 makerId=2
   price=99 qty=3`) — already captured verbatim in `SPIKE-FINDINGS.md`.
4. Agent is handed the counterexample (not the fix) and told to serialize the read-match-mutate
   critical section. Re-run: `evals/oracles/exchange-lob/gate.sh --differential --seeds 200`
   exits 0. **PROVEN.**

**Reproducibility for a skeptic:** the DENIED step does not depend on the agent being lucky or
unlucky — the spike already proves this bug is not a fluke (Arm 1's naive concurrency check
provably cannot fail, by construction, regardless of which model wrote it: `Promise.all` over
a synchronous `submit` resolves in call order on a single JS thread). A skeptic who doubts the
recording can rerun step 3 against *the specific buggy commit* if it is preserved
(`evals/flagship/` should keep the Arm 1 source alongside the trace — currently `SPIKE-FINDINGS.md`
holds only the finding, not the buggy code; see T-2 in §5) and get the identical
`FAIL @ seed 1, index 0`, because the harness is a fixed 200-seed sweep over a deterministic
generator, not a live model call.

### 2.2 What this demo must NOT claim

- It must not claim every agent produces this exact bug on every run — the spike ran Opus
  once per arm. The honest claim is "this specific, previously-measured false-green class
  exists and hmd's canonical oracle catches it where a self-authored test does not" — not
  "AI always gets concurrency wrong."
- It must not present the recorded Demo B as live/interactive unless it is re-run for the
  recording (no narration over old text).

---

## 3. The reliability benchmark (design item 2)

### 3.1 What is measured, and by what artifact

Three numbers, from three artifacts that already exist, that must be published together
because none of them alone rules out the false-green failure mode:

| Metric | Source artifact | Current real number (this session) | What it would mean alone (and why that's not enough) |
|---|---|---|---|
| **Task-resolution rate** | `bin/heimdall-s6-sweep` against `docs/superpowers/specs/heimdall-S6-C3-repos.json` | `0.6` (6/10, real run 2026-06-20) — 2 of the 4 failures were missing `go`/`cargo` toolchains, not code bugs | Alone: "the agent solves the task." Says nothing about whether the *check* it passed could ever have failed. |
| **False-green rate** | `bin/corpus run` (mutation catch-rate) + `bin/falsify <domain> --assert-score 1.0` (per-oracle falsifiability) | `bin/corpus run`: `13/13 caught = 100%` (0% false-green, current corpus). `bin/falsify --demo`: `3/3 = 1.0000`. `evals/oracles/exchange-lob/gate.sh --differential --seeds 200`: exit 0 | **This is the metric nobody else publishes.** It answers "if the implementation were wrong, would the gate have noticed?" — the question a resolution rate cannot answer, and the exact question the exchange-lob spike (§2.1, Arm 1) proves a self-authored test answers wrong. |
| **Cost** | S-6 sweep's `total_non_cache_tokens` (via `bin/heimdall-tokens`, the general model-token meter) | `907,013` non-cache tokens across the 10-repo real run | Alone: a leaderboard vanity number. Paired with the other two, it's "at what cost does this resolution rate and this false-green rate hold." |

### 3.2 Published table format

```
| Agent config       | Task set | Task-resolution | False-green rate | Non-cache tokens |
|--------------------|----------|------------------|-------------------|-------------------|
| hmd (opus, gated)  | S-6 pop-10 + exchange-lob + emulator-gb corpus | X/10 | Y/13 mutants survived | Z |
| <baseline, ungated> | same tasks, same model, no oracle gate | ... | ... | ... |
```

The second row (ungated baseline) is the one that does not exist yet and is the single most
valuable thing to build for this benchmark (see §5, rank #1) — it is the row that turns
"hmd's own gate is falsifiable" into "an ungated agent's own self-report would have missed
this," which is the actual product claim.

### 3.3 Task-set size and composition

- **13 corpus cases** (`evals/corpus/INDEX.json`): 8 `exchange-lob`, 5 `emulator-gb`. Sourced
  `mutation | field | user` per case (`evals/corpus/SCHEMA.md`). This is small — a real
  limitation to disclose, not round up. 13 is enough to report a catch-rate with a stated
  denominator; it is not enough to claim statistical generality across domains beyond the two
  represented (a stateful matching engine, a cycle-accurate CPU trace).
- **10 real popular repos** for task-resolution (`heimdall-S6-C3-repos.json`, popular-10 set:
  `slugify`, `p-map`, `wrap-ansi`, `records`, `cachecontrol`, `jmespath.py`, `commander.js`,
  `yocto-queue`, `cobra`, `anyhow`) — cross-language (JS/TS, Python, Go, Rust), SHA-pinned,
  each with a real `baseline_cmd` (the repo's own test suite) and a real `assertion_cmd`
  (task-specific, not eval'd prose — the v3 manifest fix). 2 of 10 could not run on this
  machine for lack of `go`/`cargo`, not for lack of the harness.

### 3.4 How a stranger reruns it

```
# false-green rate (network-free, ~10s)
bash bin/corpus run
bash bin/falsify --demo

# any single oracle's differential gate directly
bin/oracle-select exchange-lob        # prints the exact command
evals/oracles/exchange-lob/gate.sh --differential --seeds 200

# task-resolution + cost (requires `claude` CLI + a Claude subscription; real spend)
bin/heimdall-s6-sweep --limit 2                    # cheap validation run first
bin/heimdall-s6-sweep --confirm-full --budget 3000000   # the full popular-10, real spend
```

### 3.5 Before this ships as launch copy

1. **Get RJ sign-off on the manifest** — `heimdall-S6-C3-repos.json` still says `"status":
   "PROPOSAL v3 ... requires RJ sign-off ... before any run"`. A real run exists without that
   sign-off having been recorded; either the sign-off happened out-of-band and the status
   field is stale, or the run should not yet be cited. Resolve the status field before
   publishing the number (effort: 5 min — it's a status-field edit plus a decision, not code).
2. **Re-run with `go` and `cargo` installed** so the 10/10 (not 8/10 attempted) real result is
   the published one. (Effort: ~15 min setup + one `--confirm-full` run.)
3. **Do not average away the 2026-06-20 dating.** Publish the run date next to the number. A
   benchmark with no date is itself an unfalsifiable claim.

---

## 4. The proof receipt + badge (design item 3)

### 4.1 The viral loop, as designed

```
hmd gates a real commit
  -> receipt written (per-commit attestation, bin/heimdall-attest)
  -> `hmd badge` reads the LOCAL beats.log count, embeds it in a README
  -> a stranger reading that repo's README sees "🛡 heimdall: N proven merges"
  -> clicks through (tagged `?ref=badge`, distinguishable from cold traffic)
  -> lands on runheimdall.dev/proof (confirmed LIVE, 200)
  -> installs
```

### 4.2 What the receipt/badge MUST assert

- **The count is a count of local, gated, passing commits** — never a productivity or
  time-saved figure. `hmd badge --json`'s own `message` field already says exactly this
  ("28 proven merges"), and it's true by construction: it reads `.heimdall/receipts/beats.log`,
  a `pass`-verdict log the gate itself writes, not a self-report.
- **A repo with zero proven merges says so honestly** ("watchman active"), never a fabricated
  "0 issues found" or similar green-by-default state.
- **The backlink is disclosed as a growth mechanic in the badge's own source comment** — it
  already is (`bin/heimdall-badge:16-18`) — so nothing about the tracking tag needs new
  disclosure copy; carry that same honesty into any launch-doc description of the badge.

### 4.3 What it must NOT assert

- Must not claim the count reflects code quality, bug-free-ness, or test coverage — only that
  N commits passed hmd's own configured gates in this repo. A stranger who greps
  `bin/heimdall-badge`'s own header comment gets this caveat already; the launch copy must
  preserve it rather than round it up to "N proven-correct commits."
- Must not embed a live remote image until the endpoint is fixed (§4.4) — an `<img>` pointing
  at a 404 is a worse first impression than no badge at all, and is exactly the class of
  overclaim the Aug 20 audit exists to catch, now found live in this exact command (§1).

### 4.4 Blocking fix before this ships (T-1, ranked #1 in §5's cut list — it is a bug, not a
feature request)

`hmd badge`'s **default** output (no flags) is the markdown form, and its `<img>` src is
`https://runheimdall.dev/badge/heimdall.svg?ref=badge` — confirmed 404 this session, along with
every sibling path probed (`/badge`, `/badge.svg`, `/badge/heimdall`). Two options, either
closes the gap:

- **(a) Ship the hosted endpoint** (real work: a small server route that reads the same
  `beats.log`-derived count — but per-repo, which means the server needs *some* way to know
  which repo's count to render; this is nontrivial state the local CLI doesn't need to carry,
  and is not "cheap" — estimate in §5).
- **(b) Change `hmd badge`'s default to emit the `--svg` form** (already fully live and
  offline-safe, confirmed this session) with the backlink preserved as the `<a href>` wrapper,
  and mark the hosted-image path `--remote` / experimental until (a) ships. This is the
  correct launch-week fix: it is a one-flag-default change in an already-working code path,
  not new infrastructure, and it means every badge pasted before the hosted endpoint exists is
  still honest.

**Recommendation: ship (b) before any launch doc recommends pasting `hmd badge`'s output
anywhere.** (a) can follow later as a real feature, not a launch blocker.

---

## 5. What to cut or hide for launch (design item 4)

A launch surface graspable in 10 seconds:

> **hmd: give it one goal. It won't tell you "done" until an oracle it didn't write agrees.**
> `bash bin/falsify --demo` — 30 seconds, no setup, see it catch a real bug.

Everything else is secondary. Concretely:

| Cut / hide | Why | Confirmed status |
|---|---|---|
| **"14 agents" / any agent-count framing** | Multi-agent-count is a crowded, undifferentiated claim; the reviewer's sharpest positioning point is explicitly *not* competing here | Repo has 16 agents currently — don't lead with a number at all, in either direction |
| **Token-saving as a headline metric** | Two of the five overclaims the Aug 20 audit found were fabricated/misattributed token-saving numbers (65-75% vs measured 0.49%; 31% vs measured 0.3009% aggregate from one event in 177) | Confirmed via `docs/analysis/` — do not resurrect this framing even with corrected numbers; false-green rate is the differentiated metric, use that instead |
| **`--team N` / team wall as a primary value prop** | README's own capability table already discloses `Shipped (no coordination layer)` — accurate, but leading with a feature the repo itself flags as incomplete undercuts the credibility pitch | Confirmed accurate disclosure already in place; recommendation is about ordering/emphasis in launch copy, not a code fix |
| **Skill/plugin marketplace auto-registration** | `install.sh` registers a Claude plugin marketplace and installs the hmd plugin from it, unprompted, as part of the base install path — a security-sensitive default a skeptical reader will flag first | **Not yet closed** (unlike claude-mem, which is already opt-in). Recommend documenting this step explicitly in the installer's own pre-install disclosure (the README already has a "what the installer writes outside the repo" table per the Aug 20 audit — this belongs in it) rather than hiding the mechanism; hiding a real security-relevant default is worse than disclosing it |
| **`hmd badge`'s default remote-image markdown** | Confirmed 404 this session (§4.4) | Must be fixed (T-1) or default-switched to `--svg` before any launch doc references it |
| **Any S-6 number citation before the manifest's own status field is resolved** | The manifest JSON that grounds the number literally says it requires sign-off it apparently hasn't recorded (§3.5) | Fix is a status-field decision, not code — ~5 minutes, but it is a hard blocker on citing the number publicly |

---

## 6. What to ADD, ranked by value/effort (design item 5)

Effort is **wall-clock for an AI-assisted build**, not calendar time — i.e., how long a
focused coder-agent session against this codebase's existing patterns takes, not how long a
human team would need to schedule it.

### #1 — Ungated baseline arm for the benchmark (§3.2's missing row)
**Value: highest.** Turns "hmd's gate is falsifiable" into "an ungated agent's self-report
would have shipped this." Concretely: run the same S-6 popular-10 tasks and the same
exchange-lob concurrency task through a plain `claude -p "<task>"` session with no oracle gate,
record its own self-reported pass/fail, then run the *real* oracle against its output
independently. The delta between "agent said pass" and "oracle says pass" **is the entire
product pitch, made numeric.**
**Effort: ~3-4 hours.** The S-6 harness already supports a `--hmd-cmd` test seam
(`bin/heimdall-s6-sweep`'s documented override) that can be pointed at a bare `claude -p`
invocation instead of the full gated `hmd` entrypoint — this is reuse, not new infrastructure.
The exchange-lob half reuses the Arm-1 spike setup already documented in `SPIKE-FINDINGS.md`.

### #2 — "Break it" mode: verifier's explicit mission is falsification, not confirmation
**Value: high, and it is mostly already built.** The reviewer's proposal — a verifier whose
job is to actively try to falsify the implementation rather than confirm it — is structurally
what `bin/falsify` + the mutation corpus already do at the **oracle** level (does the gate
itself go red on a known-bad input). The gap is at the **implementation** level: nothing today
spawns a `hmd:reviewer`-class agent with the explicit charter "find an input that breaks this,
using the existing invariant ledger as your hypothesis list" against a *freshly finished*
feature, before the oracle gate runs. This is a genuinely new agent role, not a repackaging.
**Effort: ~1 day.** Requires: (a) an `agents/breaker.md` definition (a `hmd:reviewer` variant
scoped to adversarial-input generation against the task's own `INVARIANTS.md`, not general code
review), (b) a wave-executor hook to run it between "impl agent reports done" and "final oracle
gate," (c) a fixture proving it catches at least one class of bug the corpus doesn't already
(otherwise it's redundant with existing falsify/corpus coverage — needs its own falsifiability
proof, per this repo's own zero-tolerance-for-non-falsifiable-gates rule).

### #3 — Proof levels (deterministic -> behavioral -> adversarial -> independent-agent ->
production evidence), reported as "Proof level N/5"
**Value: high, cheap relative to value — this is mostly labeling existing machinery, not
building new machinery.** Assessment against what already exists:
- Level 1 (deterministic / unit) — covered by existing per-invariant assertions
  (`INVARIANTS.md` per domain).
- Level 2 (behavioral / differential) — covered by `bin/oracle-select` + the differential gates
  (exchange-lob, team-copilot, etc.) — **already the strongest tier this repo ships.**
- Level 3 (adversarial) — **the gap** — this is exactly #2 above (Break-it mode) plus the
  existing mutation corpus (`bin/corpus run`), which already IS an adversarial layer at the
  oracle-fixture level but isn't currently reported as a distinct "level."
- Level 4 (independent-agent cross-check) — partially exists: `evals/oracles/BLIND-VERIFICATION.md`
  is exactly this (three-model blind derivation of the two golden fixtures) but is a
  **one-time manual protocol**, not a repeatable gate.
- Level 5 (production evidence) — `bin/heimdall-live-verify` already exists for one domain
  (multi-tenant isolation) and is the right template: read-only probes against a live deployed
  system, writing a committed, timestamped receipt, honestly degrading to `UNREACHABLE` rather
  than fabricating a pass with no network.
**Effort: ~1 day** to (a) formalize the level taxonomy as a schema field every `gate.json`
already has room for (`registry.json`'s `gate_type` maps directly: `example`→L1, `property`→L1,
`differential`/`trace-diff`→L2, mutation-corpus-scored→L3, `BLIND-VERIFICATION.md`-class→L4,
`heimdall-live-verify`-class→L5), and (b) surface it in `hmd report`'s existing telemetry
output as "Proof level: N/5 (<gate_type>)." No new verification machinery required for levels
1-3 and 5; level 4 needs the manual protocol converted into something `hmd report` can read
(a `VERIFICATION.md` result file already has a schema in `BLIND-VERIFICATION.md` §"Record
results" — reading it is a small parser, not a new protocol).

### #4 — Fix the badge hosted-endpoint gap (§4.4)
**Value: medium — this is a credibility bug fix, not a growth feature, but it blocks §4
entirely until closed.**
**Effort: ~15 minutes for option (b)** (default-switch to `--svg`, one conditional in
`bin/heimdall-badge`'s output-selection logic plus updating the printed usage text). **Option
(a)** (real hosted per-repo endpoint) is a separate, larger effort (~1 day, new server route +
some way to identify which repo's count a given request is asking for) and should not block
launch.

### #5 — Convert the Aug 20 self-audit into a public "we audit ourselves" launch artifact
**Value: medium-high for the credibility angle in §0, low engineering effort because the
artifact already exists.**
**Effort: ~1-2 hours.** The audit doc itself (`docs/analysis/2026-08-20-launch-readiness-audit.md`)
is already public-repo-shaped (quoted commands, dated, signed verdicts) but sits in
`docs/analysis/`, which is **gitignored** (confirmed: `.gitignore:35` covers `docs/analysis/`,
and this exact file is one of the ones that would need `git add -f` to ship, per the audit's
own T10 finding about its sibling docs). Decide deliberately whether to `git add -f` this one
document as a launch artifact (it is the single strongest proof-of-mechanism the repo has,
precisely because it is unflattering in places) rather than let `.gitignore` silently keep it
invisible.

---

## 7. Risks & mitigations

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Launch copy cites the S-6 10-repo number before the manifest's sign-off status is resolved, and a skeptic quotes the manifest's own "requires RJ sign-off" line back | med | high | Resolve/clear the manifest status field before any public citation (§3.5 item 1) | §3.5 task |
| `hmd badge`'s default markdown ships in a launch doc before the 404 is fixed | med | high (repeats the exact overclaim class the Aug 20 audit exists to catch) | Default-switch to `--svg` (§6 #4) before §4 copy is published anywhere | §6 #4 |
| Demo B (exchange-lob DENIED->PROVEN) is presented as a live re-run but is actually narrated over old text, and a skeptic asks to see it happen fresh | low-med | high (directly contradicts §0's thesis) | Record Demo B fresh at publish time, and preserve the buggy Arm-1 source in `evals/flagship/` so a skeptic can independently reproduce DENIED without trusting the recording (§2.1, §5 T-2 equivalent) | §2 build task |
| "Break it" mode (§6 #2) ships without its own falsifiability proof, becoming exactly the kind of impl-authored, unfalsifiable check this repo's own architecture rules reject | low | high (self-contradicting for a project whose brand is falsifiability) | Require a fixture proving Break-it catches at least one bug class the existing corpus/falsify stack does not, before shipping it as a claimed capability | §6 #2 |
| Marketplace auto-registration (undisclosed security-sensitive default) is discovered by a hostile reader post-launch | med | med | Add it to the README's existing installer-disclosure table now, independent of launch timing (§5) | §5 marketplace row |
| Proof-level taxonomy (§6 #3) over-promises level 4/5 coverage that is actually manual/one-domain-only | med | med | Report level per-domain, never as a single repo-wide number, and state level 4's manual cadence and level 5's single-domain scope explicitly in `hmd report` output | §6 #3 |

---

## 8. Coverage matrix (declared scope gaps upfront)

| Subsystem | In scope for this launch design | Oracle/artifact affected | Expected result |
|---|---|---|---|
| Falsifiability demo (`bin/falsify --demo`) | yes | ponytail-underdelivery kill-card | green, as measured |
| exchange-lob differential demo | yes | `gate.sh --differential --seeds 200` | green after fix, red before (staged intentionally) |
| S-6 task-resolution benchmark | yes, pending sign-off (§3.5) | `heimdall-s6-sweep` | expected-red on 2/10 repos on any machine lacking `go`/`cargo` — documented, not hidden |
| Mutation corpus false-green rate | yes | `bin/corpus run` | green (13/13) as measured |
| Hosted badge image endpoint | **descoped from this launch** (fix is default-switch, not hosting) | `runheimdall.dev/badge/*.svg` | expected-red (404) until a separate hosting task ships |
| Marketplace-endpoint independent census (LIVE/REACHABLE/ORPHANED/CLAIMED-ONLY, full repo) | **descoped — owned by the sibling four-state census task** | (sibling's own output) | this spec's §1 table is a partial, launch-scoped probe, not a substitute |
| Break-it mode / proof levels | **descoped from initial launch, ranked for fast-follow** | none yet — no gate exists | not applicable until §6 #2/#3 build |

---

## OUT OF SCOPE

- Building the hosted badge server endpoint (§6 #4 option (a)) — recommended as a fast-follow,
  not a launch blocker.
- The full four-state (LIVE/REACHABLE/ORPHANED/CLAIMED-ONLY) capability census across the
  entire repo — owned by the sibling task explicitly named in this task's brief; this spec's
  §1 table is a narrow, launch-surface-scoped probe using the same vocabulary, not a
  replacement.
- Implementing "Break it" mode (§6 #2) or the proof-level taxonomy (§6 #3) — designed and
  ranked here, not built.
- Rewriting or relabeling the `--team N` feature to add real coordination — out of scope; the
  recommendation is about launch-copy emphasis, not new engineering.
- Any change to the control-plane / `rr` cloud-bot product surface — this spec is about the
  local-engine launch surface (`hmd`), not the hosted bot.
- Marketing copywriting, ad spend, or channel selection (Show HN timing, dev.to drafts, etc.)
  — `launch-docs/` already has drafts in flight; this spec feeds their factual content, not
  their prose or scheduling.
- Re-running the full `test/run-all.sh` sweep — not needed for a design-only deliverable; no
  code changed in this session.
