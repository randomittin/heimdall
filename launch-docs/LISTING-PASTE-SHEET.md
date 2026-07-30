# §3 Web Listings — Paste Sheet (expanded /ghost pitch)

One field-by-field sheet for the 5 web listings. Copy straight from here. Descriptions
refreshed 2026-07-30 from the 2026-07-28 verification-only lock → the expanded pitch
(cross-machine team orchestration · shared triage · checkpointing · /dream · design-match),
written in /ghost voice. Every factual number still traces to the repo:

- mutation-kill 1.0 on `exchange-lob` + `emulator-gb` → `evals/flagship/STATUS.md`
- 13-case regression corpus, 100% catch → `evals/corpus/CORPUS-STATUS.md`
- BYOC / scoped PR / never-self-merge → `README.md:5,22-30`
- `/dream` never auto-pushes · triage = captured/shared (rule-promotion is human-reviewed)

Tagline everywhere = **Nothing ships unproven.** (RJ-locked). Website `https://runheimdall.dev` ·
GitHub `https://github.com/randomittin/heimdall` · License `MIT`.

---

## Reusable description blocks

**LONG** (AlternativeTo, OpenAlternative, Product Hunt maker-desc):
```
Your AI agents can't grade their own homework. Heimdall gates every change behind an external, falsifiable oracle the agent never sees — proven able to fail before it can pass — so a PR opens only when the proof lands, not when the agent says it's done. Two flagship gates score a perfect 1.0 on mutation-kill (an order-book matcher and a Game Boy CPU emulator), and a regression corpus keeps a bug that was ever caught from shipping again. It's a team tool too: parallel agents run across everyone's machines behind one live presence wall, teammates auto-join by GitHub repo access with no invite or pasted secret, and each dev's triage is shared automatically so tribal knowledge stops dying in one head. Context checkpoints across sessions; /dream fixes overnight and leaves a morning report without ever auto-pushing; a design-match loop scores your UI against its Claude Design canonical. The hosted mode opens scoped, human-reviewed PRs on your own repo with your own Claude subscription and GitHub App — BYOC, no shared keys, never touches main, never self-merges. MIT, self-hostable. Nothing ships unproven.
```

**MEDIUM** (LibHunt, StackShare — ~430 chars):
```
Heimdall gates every AI change behind an external, falsifiable oracle the agent never sees — proven able to fail before it passes — so "the tests pass" finally means something. Flagship gates hit 1.0 mutation-kill; a regression corpus stops caught bugs from shipping twice. It runs parallel agents across a team's machines behind a live presence wall, auto-joins teammates by GitHub access, and shares each dev's triage automatically. Checkpoints context; /dream fixes overnight; design-match scores UI vs canonical. MIT, self-hostable.
```

**SHORT** (≤500, any length-capped field):
```
Your AI agents can't grade their own homework. Heimdall gates every change behind a falsifiable oracle the agent never sees — proven able to fail before it passes — so PRs open only on real proof. It runs parallel agents across a team's machines, teammates auto-join by GitHub access, and each dev's triage is shared automatically so tribal knowledge stops dying in one head. Checkpoints context across sessions; /dream fixes overnight; design-match scores UI vs canonical. Nothing ships unproven.
```

---

## 3.1 AlternativeTo

| Field | Value |
|---|---|
| Name | `Heimdall` |
| Website | `https://runheimdall.dev` |
| Tagline | `Nothing ships unproven.` |
| Description | LONG block above |
| Categories | Developer Tools · Code Review · AI Coding Assistants |
| Platforms | macOS, Linux (bash 3.2+). Windows not documented. |
| License | Open Source · MIT |
| "Alternative to" | Leave blank / skip — no honest 1:1 substitute. If forced: "an open-source verification layer for AI coding agents." Do NOT claim "alternative to Copilot/Claude Code." |

## 3.2 OpenAlternative — ⛔ DEFERRED (2026-07-30)
> Hard-gated: requires **≥10 stars** (repo has 5) AND "Real Application, not CLIs/scripts/AI wrappers"
> (Heimdall's core is a plugin/CLI). Revisit after crossing 10 stars; frame the hosted `rr` product,
> not the CLI. "Alternative to": CodeRabbit / Devin.


| Field | Value |
|---|---|
| Name | `Heimdall` |
| Tagline | `Nothing ships unproven.` |
| Website | `https://runheimdall.dev` |
| GitHub | `https://github.com/randomittin/heimdall` |
| Category | Developer Tools / AI Coding |
| Pricing | Free, open source (MIT). Hosted `rr` mode = BYOC (your own Claude sub + GitHub App; no separate SaaS fee). |
| Description | LONG block above (or MEDIUM if length-capped) |

## 3.3 LibHunt

| Field | Value |
|---|---|
| Name | `Heimdall` |
| Summary | `Nothing ships unproven.` |
| Description | MEDIUM block above |
| GitHub | `https://github.com/randomittin/heimdall` |
| Language(s) | Shell (bash), Python, JavaScript/TypeScript |
| Category | Developer Tools |

## 3.4 StackShare

| Field | Value |
|---|---|
| Tool name | `Heimdall` |
| Tagline | `Nothing ships unproven.` |
| Category | Code Review / Utilities (confirm against live taxonomy; no exact "AI verification" bucket) |
| Description | MEDIUM block above |
| Why we use it (pros) | • Falsifiability is measured, not asserted — every gate has a mutant-kill score before it's trusted. • Runs the whole team off one presence wall; triage is shared, not siloed. • Signed auto-updates — releases are minisign-signed and verified before the updater applies them. |

## 3.5 Product Hunt

| Field | Value |
|---|---|
| Product name | `Heimdall` |
| Tagline (≤60 chars) | `Nothing ships unproven.` (23 chars ✓) |
| Description | LONG block above |
| Topics/tags | Developer Tools · Artificial Intelligence · Open Source · Claude · DevOps |
| First comment (maker) | see block below |

**PH maker comment:**
```
Maker here. Heimdall started from one annoyance: an AI agent's own tests aren't evidence — the same agent that wrote the code wrote (and can rationalize) the tests. So the gates are external: a mutation-tested oracle the implementing agent never sees. We publish our own failures on purpose — a verification system that hides its own misses can't be trusted with yours. It grew into a team tool: parallel agents across everyone's machines on one presence wall, teammates auto-join by GitHub access, and each dev's triage is shared so it stops dying in one head. /dream works the codebase overnight and leaves a morning report — it never auto-pushes. Everything's MIT, and the install script is meant to be read before it's run. Happy to dig into the oracle design, the falsifiability scoring, or the hosted bot's tenant-isolation tests.
```

---

## Order to knock them out (fastest first)
1. **OpenAlternative** — simple form, GitHub URL does most of the work.
2. **AlternativeTo** — skip the "alternative to" field, everything else is clean.
3. **LibHunt** — MEDIUM desc, done.
4. **StackShare** — confirm category live, paste pros.
5. **Product Hunt** — biggest lever; save for a day you can be around to reply to comments. Tagline ≤60 already fits.

If any field rejects for length → drop to the SHORT block.
