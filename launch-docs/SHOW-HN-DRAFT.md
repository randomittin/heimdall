# Show HN — draft

> ## READY TO POST — gates-only form (§4 fallback, executed)
> The founding cohort (`docs/specs/heimdall-viral-now-plan.md` §Step 2 — 3–5 teams, two weeks)
> **did not run**, so every cohort claim has been CUT rather than estimated. What remains is
> only what is already true and traces to a committed artifact.
>
> This is the outcome §4 sanctions in its own words: *"Shipping the gates-only version is a
> normal outcome, not a downgrade. Shipping the cohort version with invented numbers is not an
> outcome, it is a fraud."*
>
> **Zero `[RECEIPT:]` markers remain.** If one reappears, the post does not go out.

---

## 1. Title

HN rules that apply (`docs/specs/heimdall-ship-spec.md` §L1): no superlatives, no "revolutionary,"
lowercase honesty, and **any number in the title must also appear in the body.**

The gates-only title sanctioned in §4 and in `docs/specs/heimdall-ship-spec.md:84`:

```
Show HN: Heimdall – verification gates for coding agents that caught their own author's bug
```

It carries no number, so it needs no cohort receipt. The claim it makes is the R-1
golden-reference incident, which is committed and reproducible today.

---

## 2. Body (the Show HN text field)

URL field: `https://github.com/randomittin/heimdall`

```
Heimdall is a verification layer for AI coding agents. It wires an external, falsifiable oracle to
every change — a check the implementing agent never sees, proven able to go red before it is
trusted green — and blocks the push until that check passes. The agent's own test suite is a
claim, not evidence, because the thing under test wrote it.

Three gates hold a mutation-kill score of 1.0: exchange-lob at 6 of 6 injected mutants caught,
emulator-gb at 3 of 3 (evals/flagship/STATUS.md), and the cross-tenant isolation oracle at 23 of
23 — every mutant a real breach attempt. Reproduce any of them with
`bin/falsify <domain> --assert-score 1.0`. The regression corpus is 13 cases, 13 caught, 100% at v0.1
(evals/corpus/CORPUS-STATUS.md), published as a time series with its dips visible rather than as
an adjective.

MIT, self-hostable, install script is meant to be read before it is run.
```

---

## 3. First maker comment (post it immediately — it is the real README)

Voice matches the Product Hunt maker comment in `LISTING-PASTE-SHEET.md`. Same person, same
register, more detail.

```
Maker here. Heimdall started from one annoyance: an AI agent's own tests aren't evidence — the
same agent that wrote the code wrote (and can rationalize) the tests. So the gates are external:
a mutation-tested oracle the implementing agent never sees. A gate isn't trusted green until it
has been proven able to go red, which is one command — `bin/falsify <domain> --assert-score 1.0`
passes only when every injected mutant is killed, not most of them.

The receipts, wins and losses together:

- exchange-lob: 6/6 mutants caught, falsifiability 1.0. The interesting part is why that gate
  exists — the raw arm shipped a concurrency test that could not fail, and the gated arm caught a
  race at seed 1, trade index 0, that every per-trade invariant passed.
- emulator-gb (Game Boy CPU): 3/3, 1.0. Also 10/11 blargg tests byte-exact, and the 11th is a
  descoped timer subsystem (DIV/TIMA/TMA/TAC) that is still marked ❌ in evals/flagship/STATUS.md
  because pruning a red row is how status tables start lying.
- Regression corpus: 13 cases, 13 caught, 100% at v0.1.

The failure I'd point at first is our own. On 2026-06-12 we found a golden reference in our own
emulator fixtures was wrong — a flag byte read F:10 where the truth is F:20, because the
half-carry bit is 0x20 and the carry bit is 0x10 and we had them inverted. Correcting it dropped
the corpus from 9/9 to 7/9 and exited non-zero. That dip is the point: if a genuine reference fix
leaves the corpus green, the expectations were regenerated in the same breath as the reference,
which is a tautology with a checkmark. It recovered to 9/9 only after every expectation was
re-pinned by replaying the input and capturing the divergence the oracle actually emitted.

Run it on your own repo, it takes one command each:

  bin/falsify <domain> --assert-score 1.0     # prove a gate can fail
  bin/corpus run                              # replay every failure we've ever caught
  hmd guard install                           # gate git push behind both

Known limitations, stated up front:

- The gate suite is a Claude Code hooks mechanism. It does not run inside other agent platforms
  yet. What is cross-tool today is the coordination ledger — bin/heimdall-ledger-mcp, six MCP
  tools — so a Cursor or Copilot agent can join the same claim surface, but not the same gates.
  Cross-tool gating is roadmap, marked COMING, not shipped.
- Generalization is modest and published as-is: 0.50 median reuse across 8 cold repos, full sorted
  per-repo table committed at ae88a55. The companion "8/10 working output" number is adjudicated,
  not raw — the raw machine count is 6/10, and all four adjudication layers are written down. I'd
  rather hand you that sentence than have you find it.
- 13 corpus cases is small. It is published as a time series precisely so you can watch whether it
  grows and whether it dips.
- Two flagship domains is two domains. Depth, not breadth.
- /dream works the codebase overnight and leaves a morning report. It never auto-pushes. Triage is
  captured and shared across a team; promoting a case into a standing rule is a manual,
  human-reviewed weekly decision. Nothing synthesizes rules on its own.
- What leaves your machine is enumerated field by field, with a kill switch per item, in DATA.md.
  Gates run locally; `rr` is the one thing that sends on purpose, and only when you run it.

The hosted side (`rr`) opens a scoped PR on your own repo with your own Claude subscription and
your own GitHub App install — BYOC, no shared keys, never on main, never self-merged. Getting it
running on real Cloud Run took a 29-bug bring-up; all 29 are named and published, including the
keystone where our loop hard-coded PR_OPEN and had been reporting success for every failed run.

What I want from this thread: tear at the falsifiability scoring. If you can construct a defect
class our mutant suites structurally cannot catch, that's a real finding and I'll open the issue
in-thread. Happy to go deep on the oracle design, the corpus dip log, or the tenant-isolation
tests.
```

---

## 4. Fallback — if the cohort produces nothing quotable

Cut §2's cohort paragraphs and the cohort paragraph in §3, retitle to the gates-only option
already sanctioned in `docs/specs/heimdall-ship-spec.md:84`:

```
Show HN: Heimdall – verification gates for coding agents that caught their own author's bug
```

That title needs no cohort receipt. The R-1 golden-reference incident (F:10 → F:20, corpus 9/9 →
7/9 → 9/9) is the whole claim, and it is already committed. Shipping the gates-only version is a
normal outcome, not a downgrade. Shipping the cohort version with invented numbers is not an
outcome, it is a fraud.

---

## 5. Pre-flight — all true, or postpone

Adapted from `docs/specs/heimdall-ship-spec.md` §L1.

- [ ] Zero `[RECEIPT:]` markers remain in the posted text.
- [ ] Every number in the title also appears in the body.
- [ ] Every cohort number is traceable to a named case or an aggregate someone can recount.
- [ ] Anonymization cleared: cohort is under 20 teams, so aggregate carefully or hold explicit
      named consent per team.
- [ ] `bin/falsify` and `bin/corpus` reproduce the quoted scores on a clean checkout.
- [ ] The install one-liner works on a fresh machine at the currently pinned tag and sha256.
- [ ] Known-limitations list re-checked against the repo the morning of the post.
- [ ] Tue/Wed/Thu, 7:00–8:00pm IST. Five days blocked to answer everything.
- [ ] `evals/flagship/STATUS.md` still shows its ❌ rows. If someone pruned them, put them back
      before posting, not after someone notices.
