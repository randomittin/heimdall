# Comparison — short forms (paste-ready)

> ## ⛔ DRAFT. Nothing here has been submitted or published.
> Companion to the long form, [`log-runner-and-gate.md`](log-runner-and-gate.md). Everything below
> is written so a form can be filled without rereading the essay. Copy the block, paste it, done.
>
> **One hard rule before anything here goes out:** every sentence that describes another product
> must be confirmed against that product's own live documentation first — see the sourcing table
> at the bottom of `log-runner-and-gate.md`. The blocks below are written to survive that check:
> they describe the *category* ("agent platforms", "runners") and name products only as examples,
> so a wording change on their side does not turn a paste into a false claim.

Thesis, one line, unchanged across every surface: **they run your agents, Heimdall proves the
output — more unattended agents means more need for a gate that can fail, so use both.**

---

## 1. FAQ row — for `heimdall-site/faq.html`

Placement: a fifth Q, after `#data-sent` and before `#when-not`. Anchor `#vs-agent-platforms`,
nav label "Agent platforms". Same section markup as Q1–Q4 (eyebrow → `h2.h-title` → bold lead
`<p>` → supporting `<p>`s), and the same Q/A pair must be added to the page's `FAQPage` JSON-LD
or the row will not be machine-readable.

**Eyebrow:** `FAQ · agent platforms`

**Question (H2):**

```
Is Heimdall an alternative to OpenHands or GitHub Copilot's coding agent?
```

The question keeps "coding agent" on purpose: that is the phrase people still search, and GitHub
used it until recently. It is a legacy name, so it may only ship alongside supporting paragraph 3
below, which names the live product and links the current page. Question without that paragraph =
a stale product name asserted with nothing correcting it.

**Answer — bold lead paragraph:**

```
No. They run agents; Heimdall proves what the agent produced. An agent platform's job finishes when a pull request exists — GitHub's own documentation for its Copilot cloud agent describes it working in "its own ephemeral development environment, powered by GitHub Actions," and states that draft pull requests it creates "must be reviewed and merged by a human" — and Heimdall's job starts at that pull request, with an external check the implementing agent never saw. Run both.
```

**Answer — supporting paragraph 1:**

```
The reason to run both is arithmetic. A reviewer reading an agent's diff has one piece of evidence: the test suite that shipped with it, written by the thing under test. That holds until the number of diffs per week is set by how many agents you leave running instead of how fast people type. Heimdall's gates are external and falsifiable — bin/falsify <domain> --assert-score 1.0 reports PASS only when every injected mutant is killed (exchange-lob 6/6, emulator-gb 3/3, evals/flagship/STATUS.md), and a 13-case regression corpus replays every failure the gates have ever caught, 13/13 at v0.1.
```

**Answer — supporting paragraph 2 (the honest boundary — do not cut it):**

```
What composes today: Heimdall gates the tree on a machine you control, and its coordination ledger already speaks MCP, so an OpenHands or Copilot agent can join the same claim surface as Claude Code via bin/heimdall-ledger-mcp. What does not compose yet: the gate suite itself is a Claude Code hooks.json mechanism and does not run inside another platform's runtime — that is roadmap, marked COMING, not shipped.
```

**Answer — supporting paragraph 3 (the rename disclosure — ships with the question, see above):**

```
GitHub documented this feature as "Copilot coding agent" until recently; that URL now redirects to Copilot cloud agent: https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent
```

---

## 2. "Alternative to" — the sanctioned answer for listing forms

AlternativeTo, LibHunt and StackShare all ask some version of this. Use these. They supersede the
older "leave blank / skip" instruction in [`LISTING-PASTE-SHEET.md`](LISTING-PASTE-SHEET.md) §3.1
— skipping the field was right while there was no honest answer written down. There is one now.

**FULL (≈460 chars — AlternativeTo's free-text field, StackShare's "why we use it" context):**

```
Not an alternative to an agent platform — a verification layer you run alongside one. Heimdall gates whatever agent you already use (OpenHands, GitHub Copilot's cloud agent, Claude Code) behind an external, falsifiable oracle the implementing agent never sees: proven able to fail before it is allowed to pass. Agent platforms end at "a pull request exists"; Heimdall decides whether that pull request is trustworthy. Use both. MIT, self-hostable.
```

**ONE-LINE (for a short or single-line field):**

```
Not a replacement for an agent platform — the falsifiable gate you point at its output. Use both.
```

**CATEGORY ANSWER (when the form demands a taxonomy bucket, not a product):**

```
AI code review / merge gating — not "AI coding agents". Heimdall is complementary to that category, not a substitute for anything in it.
```

**If a form forces a named product into an "alternative to" slot:** leave it empty. There is no
1:1 substitute, and naming one to satisfy a required field is the one move that turns this whole
piece into a false claim. If the field cannot be left empty, use the CATEGORY ANSWER above.

---

## 3. Guard list — what must never be written on any of these surfaces

- Never "alternative to GitHub Copilot" / "alternative to Claude Code" / "alternative to
  OpenHands". Heimdall is a plugin for Claude Code and a layer over the others. There is no in-repo
  benchmark against any named competitor (`SUBMISSIONS.md` §6), so there is no basis for a
  substitution claim.
- Never characterise another product's weaknesses. Describe what each category does. Every factual
  line about another product traces to their own README or docs, or it gets cut.
- Never "auto-synthesizes rules". `/dream` never auto-pushes; triage is captured and shared;
  promoting a case into a standing rule is manual and human-reviewed.
- Never a bare privacy absolute. The scoped S1–S6 set in `README.md` §"Your code stays yours" is
  the only correct framing, and `test/truth-pass-claims.test.sh` goes red if a bare one reappears
  on a read-surface.
- Never quote "8/10 working output" without the word **adjudicated** — the raw machine count is
  6/10 (commit `ae88a55`). The reuse figure that stands unqualified is 0.50 median across 8 cold
  repos.

---

## 4. Sourcing

Heimdall-side numbers: `evals/flagship/STATUS.md` (6/6, 3/3, both 1.0) ·
`evals/corpus/CORPUS-STATUS.md` (13 cases, 13 caught, v0.1) · `PROTOCOL.md` §"MCP Interop
Contract" (six MCP tools) · `heimdall-site/faq.html` §`#cross-tool` (gates are Claude-Code-only
today) · commit `ae88a55` (0.50 median reuse; adjudicated 8/10 vs raw 6/10).

Competitor-side lines: one claim only, the Copilot cloud-agent workflow description in the FAQ
lead. Confirmed at [About GitHub Copilot cloud
agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent) and
[Risks and
mitigations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations),
both retrieved 2026-08-04. Two corrections came out of that check and are already applied above:
the product is documented as **Copilot cloud agent**, not "coding agent" — the old
`.../coding-agent` URL redirects to `.../cloud-agent` — and "requesting your review" is not the
live wording, so the lead now quotes the ephemeral-environment and human-review lines verbatim
instead. Full per-claim checklist in `log-runner-and-gate.md` §DRAFT NOTE.

Re-check both pages before this row ships. GitHub has renamed this product once already, and the
sourcing note is only worth what its retrieval date is worth.
