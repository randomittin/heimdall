---
title: A runner is not a gate
date: 2026-08-03
slug: log-runner-and-gate
description: OpenHands and GitHub's Copilot coding agent run agents. Heimdall decides whether the output is trustworthy. Two jobs, and the second one gets harder every time the first one gets better.
tags: [openhands, github copilot, falsifiability, code review, agent platforms]
author: Heimdall Engineering
read_time: 9 min read
canonical: https://runheimdall.dev/log-runner-and-gate.html
crosspost:
  - dev.to      (canonical_url: https://runheimdall.dev/log-runner-and-gate.html)
  - Hashnode    (Original article URL: https://runheimdall.dev/log-runner-and-gate.html)
---

An agent platform's job finishes when a pull request exists. A gate's job starts there.

That is the entire distinction, and it is not a ranking. The two categories are solving different
problems, and the better the first category gets, the more load it puts on the second.

## What a runner does

A runner takes a task, gives an agent a machine, and hands back a diff.

OpenHands is that, open source. Its own README describes a platform for software development
agents that "can do anything a human developer can: modify code, run commands, browse the web,
call APIs" — [All-Hands-AI/OpenHands](https://github.com/All-Hands-AI/OpenHands), README.
Agent Canvas is its interface for working with more than one agent at a time:
`[SOURCE: one sentence describing Agent Canvas, written from docs.all-hands.dev verbatim — what the
canvas is and what it lets you do. Do not paraphrase from memory; open the page and quote it.]`

GitHub's Copilot coding agent is that, hosted inside GitHub. Per GitHub's own documentation, you
assign an issue to Copilot, it works in an ephemeral environment powered by GitHub Actions, pushes
its commits to a draft pull request, and requests your review when it is finished — GitHub Docs,
*About Copilot coding agent*.

Neither product claims to be the thing that decides whether the diff is correct, and GitHub's
documentation is unusually explicit about the boundary: Actions workflows on Copilot's pull
requests require approval from a user with write access before they run, Copilot cannot approve
its own pull request, and existing branch protection rules and required reviews still apply —
GitHub Docs, *Responsible use of GitHub Copilot coding agent*. The platform hands the decision
back to a human on purpose. That is the correct design. It also tells you exactly where the load
lands.

## The load lands on a person

A reviewer reading an agent's pull request has one piece of evidence in front of them: the test
suite that came with it. That suite was written by the thing under test. It is a claim, not a
check.

So the reviewer reads the diff. That works, and it keeps working, right up until the number of
diffs per week stops being set by how fast people write code and starts being set by how many
agents you are willing to leave running overnight. Review capacity is fixed. Agent throughput is
not. Every improvement in the runner category widens that gap.

What scales is not a diff a human reads. It is a check a machine runs, that the author of the
diff never saw, that has been proven able to fail.

## What a gate does

A gate is external, and it is falsifiable before it is trusted.

External means the implementing agent never sees it. Falsifiable means someone has already
injected real defects and watched the gate catch every one of them, before the gate was allowed
to certify anything.

Heimdall's version of that is one command: `bin/falsify <domain> --assert-score 1.0` runs the
domain's mutant suite and reports PASS only when every mutant is killed — not most of them. Two
flagship gates hold at 1.0: `exchange-lob` at 6 of 6 mutants caught, `emulator-gb` at 3 of 3
(`evals/flagship/STATUS.md`). A regression corpus replays every failure the gates have ever
caught: 13 cases, 13 caught, 100% at version 0.1 (`evals/corpus/CORPUS-STATUS.md`).

The row worth more than either of those is a failure. On 2026-06-12 a golden Game Boy trace was
corrected — a flag byte read `F:10` where the truth is `F:20`, because the half-carry bit is
`0x20` and the carry bit is `0x10` and the reference had them inverted. The corpus immediately
dropped from 9/9 to 7/9 and exited non-zero. It recovered to 9/9 only after every expectation was
re-pinned by replaying the inputs and capturing the emitted divergence. A corpus that stays green
while its own golden reference is being corrected is not a check. It is a tautology wearing a
checkmark.

That is the difference between a gate and a green build: one of them has a recorded incident where
it went red on its own author.

## Where the two compose

**The runner opens the pull request; the gate decides whether it can be pushed.** Concretely today:
`hmd guard install` wires a `PreToolUse` hook onto Claude Code's `Bash` tool, matching on `git push`
itself, and runs secret-scan, a full-history self-scan, `bin/falsify` and `bin/corpus` before the
push ever leaves the tool call. A non-zero exit from any of them is a hard block with the real
reason attached.

That is a Claude Code mechanism. It does not run inside OpenHands' runtime, and it does not run
inside GitHub's Actions sandbox. Saying so plainly is the point of this post — the composition
that exists today is "gate the tree the runner produced, on a machine you control," not "gate
inside their environment."

**The coordination ledger is already cross-tool.** `bin/heimdall-ledger-mcp` is a shipped MCP
server over stdio JSON-RPC exposing six tools — `read_claims`, `make_claim`, `release_claim`,
`read_capsules`, `append_decision`, `raise_conflict_pr` — so any MCP-capable client joins the same
claim surface with HAID attribution, declared at `initialize` via `clientInfo.name`
(`PROTOCOL.md` §"MCP Interop Contract"). Two agents from two different tools editing the same
repo can avoid each other today. The verification gates themselves are Claude Code
`hooks.json` mechanisms and do not run outside a Claude Code session yet; that work is roadmap,
marked COMING, not shipped.

**Heimdall runs agents too, and gates itself with the same oracle.** `rr` is a hosted maintainer:
it clones your repo with your own Claude subscription and your own GitHub App installation, runs
the issue-resolution loop until the fix passes the gates, and opens a `heimdall/*` pull request
that a human merges. Its multi-tenant isolation is not a promise — `bin/falsify
rr-multitenant-isolation --assert-score 1.0` treats every cross-tenant attack as a mutant and
fails the run unless all of them are killed. Bringing that loop up on real Cloud Run took a
29-bug ladder, all 29 named and published in [Local green is not
evidence](https://runheimdall.dev/log-deploy-saga.html). The category is not the enemy. The
unverified merge is.

## What Heimdall does not do

- It does not run your agents. If your agents live in OpenHands or in Copilot's Actions sandbox,
  they stay there.
- The gate suite is Claude Code hooks today. Cross-tool gating is not shipped; only the ledger is.
- The generalization number is modest and published as-is: 0.50 median reuse across 8 cold repos,
  with the full sorted per-repo table committed at `ae88a55`. The companion "8/10 working output"
  figure is **adjudicated**, not raw — the raw machine count in that run is 6/10, and the four
  adjudication layers are written down. Quote it with the word adjudicated or do not quote it.
- The corpus is 13 cases at v0.1. That is small, and it is published as a time series with a dip
  log rather than as an adjective, so you can watch it move instead of trusting it.
- `/dream` works the codebase overnight and leaves a morning report. It never auto-pushes. Triage
  is captured and shared across the team; promoting a case into a standing rule is a manual,
  human-reviewed weekly decision, not a synthesis step.
- Gates run 100% locally. Your code never leaves your machine. What does leave, and when, is
  enumerated field by field with a kill switch per item in
  [`DATA.md`](https://github.com/randomittin/heimdall/blob/main/DATA.md).

## The decision rule

One agent, one reviewer, every diff read line by line — a gate buys you very little. You are the
gate, and you are still fast enough.

Leave agents running unattended and the arithmetic inverts. The reviewer becomes the constraint,
the agent's own suite becomes the only evidence anyone actually has time to look at, and the
failure mode is not a bad diff. It is a green one nobody could check.

Run agents with whatever runs them best. Do not let the thing that wrote the code be the thing
that certifies it.

*Nothing ships unproven.*

---

*Short forms for FAQ rows and listing "alternative to" fields:
[`launch-docs/COMPARISON-SHORT-FORMS.md`](COMPARISON-SHORT-FORMS.md).*

*Crossposted to dev.to and Hashnode. The canonical URL for both is
`https://runheimdall.dev/log-runner-and-gate.html` — set `canonical_url` in the dev.to front
matter and paste the same URL into Hashnode's "Original article URL" field before publishing, so
the canonical version stays on the site.*

---

## ⛔ DRAFT NOTE — resolve this block, then delete it before publishing

Nothing in this post has been published. Every line about another product below must be re-read
against that product's own live documentation before the post ships. The drafting environment had
no network access, so each claim is recorded here with the exact source it must be checked
against. A claim that cannot be confirmed at the cited page gets cut, not softened.

| # | Claim as written | Must be confirmed at | Status |
|---|---|---|---|
| 1 | OpenHands is an open-source platform for software development agents; agents "can do anything a human developer can: modify code, run commands, browse the web, call APIs" | `https://github.com/All-Hands-AI/OpenHands` — README, opening section. Quote must match verbatim. | **CUT — sentence not in current README, replaced.** `All-Hands-AI/OpenHands` now redirects to `OpenHands/OpenHands`; the README has been rewritten around Agent Canvas and this sentence does not appear in it. Confirmed against [OpenHands/OpenHands](https://github.com/OpenHands/OpenHands), README, retrieved 2026-08-04. The body paragraph above still carries the old, now-false quote and needs to be rewritten around Agent Canvas (see row 2, still open) before this post can ship. |
| 2 | Agent Canvas — what it is | `https://docs.all-hands.dev` — the Agent Canvas page. | **PLACEHOLDER — write from the doc** |
| 3 | Copilot coding agent: assign an issue → works in an ephemeral environment powered by GitHub Actions → pushes commits to a draft PR → requests review | GitHub Docs, *About Copilot coding agent* (`docs.github.com`, Copilot → coding agent). Confirm the exact URL, it has moved before. | **CORRECTED — product renamed, one phrase not live.** The product is now documented as **Copilot cloud agent**, not "coding agent"; the old `.../coding-agent` URL redirects to `.../cloud-agent`. The ephemeral-GitHub-Actions-environment claim is confirmed verbatim. "Requests your review" is not the live wording — the doc says it can "research a repository, create a plan, make code changes on a branch, and optionally open a pull request." Confirmed against [About GitHub Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent), retrieved 2026-08-04. The body paragraph above still says "Copilot coding agent" / "requests your review" and needs updating to match before ship. |
| 4 | Actions workflows on Copilot's PRs need approval from a user with write access; Copilot cannot approve its own PR; branch protections and required reviews still apply | GitHub Docs, *Responsible use of GitHub Copilot coding agent* + the coding-agent security page. | **CONFIRMED — all three, verbatim.** The correct page title is *Risks and mitigations for Copilot cloud agent* (the "Responsible use" title guessed here does not exist under that name — the page was renamed along with the product). Confirmed against [Risks and mitigations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations), retrieved 2026-08-04: draft PRs "must be reviewed and merged by a human"; the agent "cannot mark its pull requests as 'Ready for review' and cannot approve or merge a pull request"; Actions workflows "are not triggered until Copilot cloud agent's code is reviewed and a user with write access to the repository clicks the Approve and run workflows button"; the agent "is also subject to any branch protections and required checks for the working repository." |

Heimdall-side claims, all traceable in-repo, no external check needed:
`bin/falsify --assert-score 1.0` semantics and the 6/6 + 3/3 flagship scores → `evals/flagship/STATUS.md` ·
13/13 at v0.1 and the 2026-06-12 `F:10 → F:20` dip 9/9 → 7/9 → 9/9 → `evals/corpus/CORPUS-STATUS.md` ·
`hmd guard install` / `PreToolUse` on `Bash` matching `git push` → `heimdall-site/faq.html` §`#stop-broken-code` ·
six MCP tools + `clientInfo.name` identity → `PROTOCOL.md` §"MCP Interop Contract" ·
gates are Claude-Code-only today, cross-tool marked COMING → `heimdall-site/faq.html` §`#cross-tool` ·
`rr` BYOC / scoped App / never `main` / never self-merge → `README.md:5,34,40-42` ·
the 29-bug ladder → `docs/CHANGES-SINCE-TEAMS.md` §(c) 1–15 and §(h) 16–29, `launch-docs/log-deploy-saga.md` ·
0.50 median reuse over 8 cold repos, adjudicated 8/10 vs raw 6/10 → commit `ae88a55`,
`docs/archive/docs/superpowers/specs/heimdall-S6-C3-findings.md` §THE FINDING ·
scoped data claims → `DATA.md`, `README.md` §"Your code stays yours" (S1–S6).
