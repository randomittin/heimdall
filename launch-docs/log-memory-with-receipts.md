---
title: Unverified agent memory is faster-rotting documentation
date: 2026-08-03
slug: log-memory-with-receipts
description: A memory nobody checks decays exactly like a stale README, except it is invisible and the agent believes it. The alternative is a claim that carries the command that proves it.
tags: [agent memory, verification, git, staleness, benchmarks]
author: Heimdall Engineering
read_time: 8 min read
canonical: https://runheimdall.dev/log-memory-with-receipts.html
crosspost:
  - dev.to      (canonical_url: https://runheimdall.dev/log-memory-with-receipts.html)
  - Hashnode    (Original article URL: https://runheimdall.dev/log-memory-with-receipts.html)
---

Everyone who has worked on a five-year-old codebase knows what a stale README does. It tells you
the service runs on port 8080. You spend forty minutes finding out it moved two years ago. The
damage is bounded because a human read it, a human doubted it, and a human went and looked.

Agent memory has the same failure mode with two of those three safeguards removed. Nobody reads
it. Nobody doubts it. The agent retrieves the entry, treats it as background fact, and acts.

That is the argument: an agent memory that nothing re-verifies is documentation that rots faster
and is harder to notice rotting.

## The case for the almanac, stated properly

The opposing position is strong and I want it on the table honestly, because the weak version is
easy to knock over and knocking it over proves nothing.

An agent that starts every session from zero is expensive and dumb. It re-derives the same
architecture, rediscovers the same constraints, re-learns that the payments module is load-bearing
and that the flaky integration test is flaky for a known reason. Accumulating that into a durable
store is obviously correct. The literature backs it up. Tiering and hot-cold swapping work.
Relevance weighting works — an entry that nobody has touched in six months genuinely should rank
below one from last week. Drift detectors over long session histories do flag real spec-versus-code
divergence, at scale, with published numbers. Contradiction detection catches contradictions.

Claude Code's own documentation lands near the same instinct from the other direction: `CLAUDE.md`
is described as context, not enforced configuration. The tools that popularised project memory
already tell you not to treat it as binding.

None of that is wrong. Our position is narrower and it is about what those mechanisms can and
cannot decide.

## A weight is downstream of truth

Take the standard example. The datastore is Postgres, and the memory says so, weighted high
because it comes up constantly. MySQL replaces it. The Postgres entry's weight drops. Later NoSQL
replaces MySQL, and the MySQL entry's weight drops too.

Watch what actually moved that number. The weight fell because someone — a human, or a gate —
decided the old entry was displaced. The weight itself knows nothing about whether Postgres is
still in the tree. It is a stored opinion on a decay schedule that has no connection to the
repository. It happens to be right when someone keeps it right.

Now make it a real team. Eight developers, three still on MySQL, a migration half-finished. The
decayed weight confidently records a falsehood, and it records it with the same shape and the same
confidence as every true entry beside it. That is the exact staleness failure the weighting was
introduced to fix.

Weighting solves retrieval ranking. It is good at that and we use it for that. It does not solve
staleness, and it cannot, because ranking is a readout and staleness is a fact about the
repository.

There is a second, worse problem. Decay only reaches entries nobody touches. High-relevance
entries are retrieved constantly, so their weight stays high — and those are precisely the entries
where a false "live" does the most damage. Relevance shields the dangerous ones. The mem0 write-up
names this as an open problem rather than a solved one, which is the honest framing.

## Code memory is the special case where truth is checkable

General agent memory has a genuine problem: there is often no referent. If the memory says the user
prefers concise answers, there is nothing to check that against. You are stuck estimating —
decaying, voting, or asking a model to judge.

Code memory is not that. The repository is right there and it is authoritative. Which means
staleness stops being an estimation problem and becomes a decision problem.

So a memory entry about code is stored as a checkable claim, not a sentence:

```jsonc
{
  "claim": "capability F4 (mandatory-option machinery) shipped, touches bin/lib/redum.py",
  "commit_ref": "6b32662",
  "refs": [
    {"path": "bin/lib/redum.py", "symbol": "factor_for_task", "kind": "function"},
    {"path": "bin/lib/redum.py", "symbol": "gate_attestation", "kind": "function"}
  ],
  "weight": 0.0,
  "status": "live",
  "provenance": "measured"
}
```

The check is mechanical and deterministic. Does the commit still exist —
`git cat-file -e <commit_ref>^{commit}`. Does each referenced path still exist at HEAD, and is the
named symbol still declared there, resolved through the same AST substrate the rest of the
verification stack uses. Commit gone or symbol gone means the claim no longer matches the
repository, and the entry is `stale`. Not "probably outdated." Stale, because git said so.

`weight` in that record is 0.0 on purpose. It is not a stored number. It is recomputed from the
check result every time the entry is read, so it cannot rot independently of the thing it
describes.

Two design choices do the real work.

**Verification runs at read, not only at write.** Staleness bites at retrieval, months after the
entry was written, on a commit that did not exist when it was stored. Checking at write time proves
the entry was true once. That is a fact about the past.

**Uncertainty defaults to stale.** A git failure or an unparseable file degrades the entry to
`stale`, never to `live`, and never to a crash. A falsely-live entry is the failure mode being
eliminated, so every ambiguous case resolves away from it. A memory that cannot be re-verified is
dropped rather than trusted, which is the whole thesis in one sentence.

## Where git cannot answer, a human does — and only about intent

Three developers still on MySQL is not a fact question. Git can show two live, mutually
contradictory claims over the same symbol, and it cannot tell you whether that is a deliberate
deprecation in progress or somebody who has not migrated yet. That case is marked `conflicted` and
escalated with the evidence attached: the refs, the commits, what HEAD actually contains.

The human answers the judgment question. Humans never override git on a fact, only on intent. Their
decision is written back as a new entry with its own `commit_ref`, so the resolution is itself
re-verifiable later and does not become the next unfalsifiable heirloom.

## The same rule, applied everywhere else

This is not one subsystem's idea. It is the house rule, and it is easier to trust because you can
watch it cost us things.

The falsifiability harness scores a gate by whether injected defects actually kill it.
`bin/falsify rr-multitenant-isolation --assert-score 1.0` exits non-zero unless the golden fixture
passes and every mutant is caught, and it prints the literal line `REJECTED: mutant survived` when
one gets through. The 2026-07-12 run recorded 1.0 with 6 of 6 mutants killed. A gate that cannot be
shown to fail is not evidence that anything works.

The regression corpus is a published time series rather than an adjective: 13 cases, 13 caught,
100% at version 0.1. The interesting row is in the dip log. On 2026-06-12 a golden reference was
corrected — a Game Boy flag byte where `F:10` should have been `F:20`, because the half-carry bit
is `0x20` and the carry bit is `0x10` and the reference had them inverted. The corpus immediately
dropped from 9/9 to 7/9 and exited non-zero. That dip is the point. If a genuine reference fix
leaves the corpus green, the expectations were regenerated in the same breath as the reference,
which is a tautology wearing a checkmark. Recovery to 9/9 came from replaying the inputs and
capturing the emitted divergence, because pinpoints are captured, never hand-written.

The self-improvement loop keeps a change only on a measured delta over a baseline across enough
samples, and rolls the override back to its previous value otherwise. An experiment that merely
ties its baseline is discarded. The burden of proof sits on the change.

And the overnight pass is allowed to come back with nothing. The 2026-07-12 journal reads
"honest-empty — nothing to suggest," because the metrics file carried no task-outcome records and
the keep-gate had no signal to form a hypothesis from. It did not fabricate one to look useful. It
also does not push: triage is surfaced for review, and promoting anything into a standing rule is a
manual, human-reviewed weekly decision. We do not auto-synthesize rules, and we go out of our way
not to say that we do.

## The number we do not have yet

The mechanism is built and gate-tested. The benchmark fixture is built: a three-commit synthetic
migration repo where staleness is induced by a real git operation rather than a flag flip, with
direct contradiction cases and indirect dependency-chain cases, each labeled with its git-true
status, plus the team-divergence variant that must route to human escalation instead of quietly
picking a winner.

What is not published is the comparative delta against the three baselines — decay, model-judge
contradiction detection, and a drift detector of the Codified Context family, which is the closest
prior art and the one worth beating on its own axis. That number does not exist yet, so it is not
in this post, and the harness will not print it. With fewer than the minimum sample count, it
emits null provenance and renders a dash. An untagged comparison number is treated as a build
defect rather than a formatting choice.

If the measured result comes back at parity, that ships as a finding. A null result about your own
idea is worth more than a rounded one.

## The limits, since they are real

Read-time verification costs latency on every retrieval, which is why the check result is cached
against `commit_ref + HEAD` and invalidated when HEAD moves, and why a timeout falls back to stale
rather than blocking.

A rename is not a deletion, and a naive symbol-presence check will call a renamed-but-present
capability gone. Unit extraction plus near-matching exists to stop that, and it is a known source
of false stales.

And the asymmetry only holds where a git referent exists. Preferences, identity, anything without
a repository to check against — none of that is claimed here. If your memory has no referent, this
argument gives you nothing, and you should be suspicious of anyone who says otherwise.

## What to take from it

If you are running agents against a codebase, the question worth asking about your memory layer is
narrow: what happens to an entry when the code it describes changes and nobody notices?

If the answer is that a weight slowly declines, you have documentation with worse ergonomics. If
the answer is that a check re-runs at retrieval and the entry is dropped when it stops matching,
you have something closer to a claim with a receipt attached.

A memory should carry the command that proves it. If it cannot be re-verified, delete it.

*Nothing ships unproven.*

---

*Crossposted to dev.to and Hashnode. The canonical URL for both is
`https://runheimdall.dev/log-memory-with-receipts.html` — set `canonical_url` in the dev.to front
matter and paste the same URL into Hashnode's "Original article URL" field before publishing, so
the canonical version stays on the site.*
