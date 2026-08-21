# Reasoning Bank wiring decision — claude-mem `/mem-search`

**Date:** 2026-08-22 · **Scope:** decide whether to mechanically wire `agents/heimdall.md`'s
"query claude-mem before each task" instruction, the one unwired leg of the Token-Frugal
Protocol. Nothing in `hooks/hooks.json` changed as a result of this audit — see Verdict.

## Verdict

**NO. Do not wire.** The self-reported "98% savings" is a ratio of unrelated quantities: it
divides the historical token cost of the sessions that *produced* a stored memory by the cost
of *reading* that memory back at `SessionStart` — not a measure of session-token savings.
Taken at full face value anyway, the actual token footprint (below) is a rounding error against
real session spend, in the same band this repo already used to reject Headroom's compression
fork. Unlike that case, the mechanism actually under review here — an *active* per-task query —
has never run: adoption of the existing prompt instruction measured zero across ~40 spawns in
one session. There is no evidence of realized benefit at any price, only an unmeasured one.

## 1. What "98% savings" actually computes

Source: `~/.claude/plugins/cache/thedotmack/claude-mem/13.15.3/scripts/context-generator.cjs`
(the same functions are duplicated, minified, in `worker-service.cjs`):

```js
function be(t){let e=(t.title?.length||0)+(t.subtitle?.length||0)+(t.narrative?.length||0)+JSON.stringify(t.facts||[]).length;return Math.ceil(e/4)}
function re(t){let e=t.length,r=t.reduce((u,c)=>u+be(c),0),n=t.reduce((u,c)=>u+(c.discovery_tokens||0),0),o=n-r,s=n>0?Math.round(o/n*100):0;return{totalObservations:e,totalReadTokens:r,totalDiscoveryTokens:n,savings:o,savingsPercent:s}}
```

`savingsPercent = (Σdiscovery_tokens − Σread_tokens) / Σdiscovery_tokens × 100`, where
`discovery_tokens` is set once, at generation time, to the token cost of the (other, prior)
session that produced the observation, and `read_tokens` is a `chars/4` estimate of the
injected summary text (title + subtitle + narrative + facts). This is a real, correctly
-computed **compression ratio**: how much cheaper a stored note is to re-read than the work
that produced it cost the first time. It is not, and structurally cannot be, "session savings"
— the numerator and denominator are token costs from two different sessions, not before/after
costs of the same session's work.

## 2. Measured, not assumed

| Fact | Value | How measured |
|---|---|---|
| `mem-search`/claude-mem references in `hooks/hooks.json` | **0** | `grep -c 'mem-search\|claude-mem' hooks/hooks.json` — reconfirmed fresh, post-compaction |
| claude-mem observations (lifetime) | **25,914** | `sqlite3 -readonly ~/.claude-mem/claude-mem.db "select count(*) from observations"` |
| Lifetime `Σdiscovery_tokens` / `Σread_tokens` | 315,002,257 / ~10,551,179 | same DB, live read-only query, bounded via `perl -e 'alarm N; exec @ARGV' --` |
| Lifetime savings% (recomputed) | **96.65%** | `(315002257−10551179)/315002257×100` |
| Recent-50-observation window (the actual `SessionStart` injection default) `Σdiscovery_tokens` / `Σread_tokens` | 359,674 / 17,241 | same DB |
| Recent-window savings% (recomputed) | **95.21%** | matches the live in-session banner reproduced mid-audit: `50 obs (18,113t read) \| 340,382t work \| 95% savings` — same formula, adjacent sample window, observed live rather than just derived from source |
| Real total session-token baseline, this machine | 1,147,306,644 tokens / 234 sessions / 3,830 requests / $1,103.05 | `docs/analysis/token-spend-forensics.md`, 2026-07-14→08-07 |
| Avg tokens/session | **4,903,020** | `1,147,306,644 / 234` |
| Recent-window injected context as % of avg session (passive, already automatic) | **0.3516%** | `17,241 / 4,903,020 × 100` |
| One real `GET /api/search` call (5 results), live worker | **~273 tokens, 55–100ms** | `curl -G http://127.0.0.1:37777/api/search --data-urlencode query=... -w '%{time_total}'`; response 1,091 bytes; 3 runs, all HTTP 200 |
| 40 such calls/session (the actual unwired mechanism under review) as % of avg session | **0.2225%** | `40 × 272.75 / 4,903,020 × 100` |
| Headroom precedent bar (rejected as a rounding error) | 0.5583% aggregate / 0.271% lifetime | `docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md` |
| Adoption of the existing "query claude-mem before each task" instruction | **0 / ~40 spawns**, one session | given at task assignment (orchestrator-side measurement, not re-derived here) |

## 3. Applying the decision gate

> "If it divides injected-context by total session work-tokens, it is a ratio of unrelated
> quantities, not a saving — say so and recommend NOT wiring."

It does exactly that, twice over:

- **Categorically**: the "98%"/"95%" figure is (historical production cost of *other* sessions)
  vs. (this session's read cost) — not this session's before/after. It answers "how much
  cheaper is a compressed note than the work that made it," not "how much did this save me."
- **Numerically, even granting the metric its best-case framing**: both the passive injection
  already running today (0.3516% of an average session) and the hypothetical active per-task
  query under evaluation (0.2225%) round to noise against real measured session spend — the
  same order of magnitude as the Headroom compression fork this repo already declined to build
  (0.5583%/0.271%).

The one respect in which this is a *weaker* case than Headroom's: Headroom's aggregate 0.5583%
was at least a measured, realized number, from a mechanism that actually runs on every request.
The active per-task claude-mem query has an adoption count of zero. There is no experiment,
ever, showing it changes agent behavior, reduces redundant work, or improves outcomes. Cost is
small; benefit is not small, it is absent.

## 4. What was NOT wired, and why that's a separate, cheaper question

`agents/heimdall.md`'s Reasoning Bank section bundles two different mechanisms under one
heading. This audit resolves the claude-mem half only:

1. **`.planning/skills/*.md` pattern search** — a local grep against a small, human/agent
   -authored, git-committed directory. Zero network, zero DB, no model call. This is a
   fundamentally cheaper and differently-evidenced question than claude-mem's, and is not
   answered by anything measured in this doc. This pass does not wire it either, in keeping
   with the scope of the triggering task (decide the claude-mem leg specifically). It remains a
   legitimate, cheap candidate for a *future*, separately-scoped pass — closer in cost profile
   to the already-accepted `brief-adoption-gate` hook (a pure string/word-count check, no
   network) than to claude-mem's live query.
2. **Success/failure count tracking, auto-archiving after 3+ failed uses** — described in the
   old `agents/heimdall.md` text but never implemented; nothing in this repo increments those
   counters. Left called-out as aspirational in the instruction fix rather than either built now
   or silently left mis-described as real.

## 5. Recommendation

- **Do not add a claude-mem/`mem-search` call to any per-task or per-spawn hook path.**
- **`agents/heimdall.md` corrected** so it stops asserting an unenforced, zero-adoption,
  economically-unjustified step as a required workflow.
- **`hooks/hooks.json` unchanged.** `grep -c 'mem-search\|claude-mem' hooks/hooks.json` → 0,
  before and after this audit; `jq -e .` valid before and after.
- **claude-mem stays installed; its existing `SessionStart` auto-injection is untouched.** This
  audit is scoped to the *active per-task query*, not to claude-mem's installation status —
  that question was already answered ("keep") by
  `docs/analysis/2026-08-04-headroom-vs-claude-mem.md`, on different grounds, and nothing here
  changes it.

### What would change this verdict

| Condition | Effect |
|---|---|
| claude-mem ships a benefit metric that isn't itself the ratio audited here (e.g. a measured reduction in redundant subagent work, from a real A/B) | Re-open the wiring question with that evidence. |
| A cheap, local (non-network, non-DB) form of the check is proposed — closer to `.planning/skills/*.md`'s cost profile than to a live query | Evaluate on its own, much lower, bar — see §4.1. |
| Real per-session request volume or cost structure changes by an order of magnitude (e.g. sessions get much cheaper) | The 0.2225%/0.3516% figures would need recomputing against the new baseline. |

## Sources

Read/queried directly:
- `~/.claude/plugins/cache/thedotmack/claude-mem/13.15.3/scripts/context-generator.cjs`,
  `worker-service.cjs`, `mcp-server.cjs`
- `~/.claude-mem/claude-mem.db` (`?mode=ro`, SELECT only; queries bounded with
  `perl -e 'alarm N; exec @ARGV' --`) — read-only throughout, nothing written
- Live worker HTTP API, `127.0.0.1:37777` (PID 15126, running since 2026-08-21T10:17Z),
  `GET /api/search` — read-only, no writes
- `docs/analysis/token-spend-forensics.md`, `docs/analysis/2026-08-04-headroom-vs-claude-mem.md`,
  `docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md`
- `agents/heimdall.md`, `hooks/hooks.json` (`jq -e .` valid before and after — unchanged)

Installed/modified: `agents/heimdall.md` (Reasoning Bank section only),
`.planning/skills/reasoning-bank-claude-mem-wiring.md` (new). `hooks/hooks.json`: nothing.
