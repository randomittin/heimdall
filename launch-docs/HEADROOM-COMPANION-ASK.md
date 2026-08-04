# Headroom — companion-listing ask (draft)

> ## ⛔ NOT SUBMITTED. Nothing here has been posted anywhere.
> No issue opened on `headroomlabs-ai/headroom`, no pull request opened, no comment posted, no
> Discord message sent. RJ submits from his own identity, after the ⛔ table in §6 is cleared.
>
> **Hard rule, same as [`log-runner-and-gate.md`](log-runner-and-gate.md):** every sentence in the
> submitted text that describes Headroom must be confirmed against Headroom's own live
> documentation first. The drafting environment had no network access. A claim that cannot be
> confirmed at the cited page gets cut, not softened.

---

## 1. The line

```
Heimdall — verification gates for the output side: Headroom shrinks what the agent reads, Heimdall proves what it ships.
```

That is the entry. Everything below exists so the line can be pasted without rereading anything.

---

## 2. The submission — paste this whole block as the issue body

Open it as an issue, not a PR. A PR against someone else's README asks them to review a diff; an
issue asks them a yes/no question and costs them thirty seconds. If a maintainer replies "send a
PR," send the one-line diff then.

**Title:**

```
Companion listing: Heimdall (verification gates for agent output)
```

**Body:**

```
Heimdall — verification gates for the output side: Headroom shrinks what the agent reads, Heimdall proves what it ships.

That is the proposed line. Context, so the decision takes a minute:

Heimdall (MIT, https://github.com/randomittin/heimdall) is a verification layer for AI coding
agents. Every change is gated by an external oracle the implementing agent never sees, and a gate
is not trusted green until it has been proven able to go red: `bin/falsify <domain>
--assert-score 1.0` reports PASS only when every injected mutant is killed, not most of them. Two
flagship gates hold at 1.0 — exchange-lob at 6 of 6 mutants caught, emulator-gb at 3 of 3
(`evals/flagship/STATUS.md`). A regression corpus replays every failure the gates have ever
caught: 13 cases, 13 caught, 100% at v0.1 (`evals/corpus/CORPUS-STATUS.md`).

The two tools sit on opposite halves of the same run. One decides what reaches the model. The
other decides whether the diff that comes back is allowed to be pushed. Neither needs the other
to function, and nothing in Heimdall substitutes for anything in Headroom.

One boundary, stated before you list it rather than after someone finds it: Heimdall's gate suite
is a Claude Code hooks mechanism today. It gates the tree on the machine you control. It does not
run inside another agent runtime, and cross-tool gating is roadmap, not shipped. What is
cross-tool today is the coordination ledger, an MCP server over stdio.

Put it wherever it fits, reword it however you like, or close this — no follow-up either way.
```

**Length check:** 197 words of prose plus the one-line entry. If the repo's issue template caps the
body, cut paragraph 2 down to its first sentence and the two flagship numbers. Do not cut the
boundary paragraph.

---

## 3. Follow-up replies — only if a maintainer asks

Write nothing else unprompted. These are answers, not a campaign.

**If asked "what does it actually do to my workflow":**

```
One command wires it: `hmd guard install` puts a PreToolUse hook on Claude Code's Bash tool,
matching `git push`, and runs secret-scan, a full-history self-scan, `bin/falsify` and
`bin/corpus` before the push leaves the tool call. Non-zero exit from any of them is a hard block
with the real reason attached. Gates run 100% locally. Your code never leaves your machine.
```

**If asked "why should we care, specifically":**

```
Because a compression layer changes what the model reads, and the obvious question — does the
code that comes out the other side still hold up — is not answerable from token counts. We are
running a one-week paired A/B of the same agent with and without a compression proxy in front of
it, scored on gate outcomes: oracle pass-rate, falsify survival, gate retry-count, time-to-green.
The decision rule is written down before the run, and the negative result publishes on the same
terms as a favourable one. You get the receipt either way, and we will bring it to the community
channel rather than dropping a link.
```

That reply is only accurate once the A/B is actually scheduled. If it is not, cut the second half
and say only the first sentence.

**If asked "is this a competitor":**

```
No. There is no benchmark in our repo against Headroom or anything else, so there is no basis for
a comparison claim and we do not make one. Different halves of the same run.
```

---

## 4. Placement notes — for RJ, not for the submitted text

The submitted body deliberately contains **no claim about how Headroom's README is organised**.
It says "put it wherever it fits" for exactly that reason: a sentence naming their section
structure is a factual claim that goes stale the next time they reorganise, and a wrong one turns
a courteous ask into a correction they have to make.

Before opening the issue, read their README top to bottom and confirm:

1. Which section actually collects companion or adjacent tooling, and what it is called today.
2. The exact bullet format used by the entries already in it — leading link, bolded name, trailing
   period, badge row or none. Match it byte for byte if they ask for a PR.
3. Whether they have a contributing or listing policy that governs additions to that section. If
   there is a stated policy, follow it instead of this file.

---

## 5. Guard list — what must never appear on this surface

- Never characterise Headroom as missing, lacking, or not solving anything. The entry describes
  what each tool does. "Headroom shrinks what the agent reads" is a description of its function,
  and it must match their own wording for that function or be replaced with their wording.
- Never "alternative to". Heimdall is not a substitute for a compression proxy, and there is no
  in-repo benchmark against any named product (`SUBMISSIONS.md` §6).
- Never a bare privacy absolute. The scoped S1–S6 set in `README.md` §"Your code stays yours" is
  the only correct framing; `test/truth-pass-claims.test.sh` goes red if a bare one reappears on a
  read-surface.
- Never quote "8/10 working output" without the word **adjudicated**. The raw machine count is
  6/10 at commit `ae88a55`. The reuse figure that stands unqualified is 0.50 median across 8 cold
  repos.
- Never "auto-synthesizes rules". `/dream` works the codebase overnight and leaves a morning
  report; it never auto-pushes. Promoting a case into a standing rule is a manual, human-reviewed
  weekly decision.
- Never imply the gates run inside their runtime, or anyone else's. Claude Code hooks, on your
  machine, today.

---

## 6. ⛔ DRAFT NOTE — resolve every row, then delete this block

Each claim below came from the task brief, **not** from Headroom's live documentation. A brief is
not a source. Every row is confirmed against the cited page before anything is submitted, and a
row that cannot be confirmed is cut from the submitted text rather than reworded to survive.

| # | Claim, and where it appears | Must be confirmed at | Status |
|---|---|---|---|
| 1 | "Headroom shrinks what the agent reads" — the core comparative clause in the entry line | `https://github.com/headroomlabs-ai/headroom` — README, the project's own one-line self-description. Replace our verb with theirs if they differ. | **UNVERIFIED — confirm wording** |
| 2 | Headroom is a local-first context-compression proxy | Same README, opening section. If "local-first" is not their word, drop it — it is doing work in the §3 reply about both tools running on your machine. | **UNVERIFIED — confirm** |
| 3 | The repo slug is `headroomlabs-ai/headroom` and the licence is Apache-2.0 | The repo page and its `LICENSE` file. The slug is pasted into the submission target; a wrong slug files the issue on a stranger's repo. | **UNVERIFIED — confirm both** |
| 4 | Headroom curates companion tools in a README section, and that section is the right home for this entry | Their README. See §4 — resolve the section name and bullet format there, and keep the claim out of the submitted body regardless. | **UNVERIFIED — resolve before opening** |
| 5 | Community channel exists and is the right place for the follow-up in §3 | The community/Discord link **in their README**. Do not guess or reconstruct an invite URL; resolve it from the README and use that. Confirm the channel's rules on tool links before posting anything. | **UNVERIFIED — resolve the real link** |
| 6 | Star count, if it is ever cited anywhere | The repo page. It moves daily. Preference: never cite it. It is not an argument. | **DO NOT CITE** |

---

## 7. Heimdall-side sourcing — all in-repo, no external check needed

`bin/falsify --assert-score 1.0` semantics, exchange-lob 6/6 and emulator-gb 3/3, both at
falsifiability 1.0 → `evals/flagship/STATUS.md` ·
13 cases, 13 caught, 100% at v0.1 → `evals/corpus/CORPUS-STATUS.md` ·
`hmd guard install`, `PreToolUse` on `Bash` matching `git push` → `heimdall-site/faq.html`
§`#stop-broken-code` ·
gates are Claude-Code-only today, cross-tool marked COMING → `heimdall-site/faq.html`
§`#cross-tool` ·
the coordination ledger over MCP, six tools, stdio JSON-RPC → `PROTOCOL.md` §"MCP Interop
Contract" ·
S1 verbatim, "Gates run 100% locally. Your code never leaves your machine." → `README.md`
§"Your code stays yours", gated by `test/truth-pass-claims.test.sh` ·
0.50 median reuse across 8 cold repos; adjudicated 8/10 vs raw machine count 6/10 → commit
`ae88a55`, `docs/archive/docs/superpowers/specs/heimdall-S6-C3-findings.md` §THE FINDING ·
MIT licence → `LICENSE`.
