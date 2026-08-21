# reasoning-bank-claude-mem-wiring — don't wire a per-task query on a self-reported ratio

A reasoning-bank entry from the 2026-08-22 Token-Frugal Protocol audit
([full measurement](../../docs/analysis/2026-08-22-reasoning-bank-wiring-decision.md),
local-only). Trigger pattern: any future proposal to wire claude-mem, `mem-search`, or another
"session memory" system into a per-task or per-spawn hook path on the strength of a
self-reported savings/compression percentage.

## The pattern

A subsystem reports an internal ratio ("98% savings") that sounds like a session-cost saving
but is actually a **compression ratio measured on a different pair of quantities** — here,
(historical cost of the sessions that produced a memory) vs. (cost of reading that memory back
now). Both numbers are real and the arithmetic is correct; the mistake is upstream, in treating
the ratio as an answer to "how much of my session's real cost did this save," which it never
measured.

## Why it failed the bar here

- Recomputed independently against the live DB: 96.65% lifetime / 95.21% recent-window —
  matches the tool's own self-report, so the number itself isn't wrong or fabricated.
- Against a real, independently-measured total-session-token baseline
  (`docs/analysis/token-spend-forensics.md`: 1,147,306,644 tokens / 234 sessions on this
  machine), the injected context is ~0.35% of an average session; a hypothetical *active*
  per-task query (the thing actually being proposed for wiring) adds ~0.22% more — both inside
  the rounding-error band this repo already used to reject the Headroom compression fork
  (0.5583%/0.271% aggregate,
  [headroom-fork-assessment](../../docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md)).
- Worse than Headroom's case: adoption of the pre-existing prompt instruction to run this query
  was **zero across ~40 spawns** measured in one session. Headroom at least had a measured, if
  tiny, realized benefit. This had none — cost was small, but benefit was never observed at all.

## Apply this pattern when

- Something reports a "savings" or "compression" percentage and the next move on the table is
  wiring it into a hot path (a hook, a per-task step, a per-spawn check).
- Ask: what are the two numbers, literally? Are they the same economic quantity, for the same
  unit of work, before and after? If not, get the real total (session tokens, wall-clock,
  dollars) from an independent source before trusting the percentage.
- "Cheap to try" is not "proven to help." A near-zero-cost check (grep, string match, no
  network) clears a much lower bar than an active query against an external store — see the
  `.planning/skills/*.md` half of this same instruction, deliberately left unresolved rather
  than folded into this verdict, because it is a different cost class and deserves its own pass.

## Outcome

`agents/heimdall.md`'s "Reasoning Bank" section no longer mandates the claude-mem query.
`hooks/hooks.json` was not changed — `grep -c 'mem-search\|claude-mem' hooks/hooks.json` → 0,
unchanged before and after. Success count: N/A — this is a wiring decision, not a pattern meant
to be retried.
