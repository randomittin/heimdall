# Headroom — companion-listing ask (draft)

> ## ⛔ NOT SUBMITTED. Nothing here has been posted anywhere.
> No issue opened on `headroomlabs-ai/headroom`, no pull request opened, no comment posted, no
> Discord message sent. RJ submits from his own identity, after the ⛔ table in §6 is cleared.
>
> **Hard rule, same as [`log-runner-and-gate.md`](log-runner-and-gate.md):** every sentence in the
> submitted text that describes Headroom must be confirmed against Headroom's own live
> documentation first. The drafting environment had no network access; the §6 rows were resolved
> later against live sources and the evidence is logged in §8. A claim that cannot be confirmed at
> the cited page gets cut, not softened — rows 4 and 5 are still open and constrain what may be
> said.

---

## 1. The line

```
Heimdall — verification gates for the output side: Headroom compresses what the agent reads, Heimdall proves what it ships.
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
Heimdall — verification gates for the output side: Headroom compresses what the agent reads, Heimdall proves what it ships.

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
Nothing to wire — the gate ships with the plugin as a Claude Code PreToolUse hook on the Bash
tool, matching `git push`. Before the push leaves the tool call it runs a secret scan, a
full-history self-scan, `bin/falsify <domain> --assert-score 1.0` over every oracle domain, and
`bin/corpus run`. Non-zero exit from any of them is a hard block with the real reason attached.
A separate native git pre-push hook covers what that one structurally cannot see — a push a human
types in a terminal — and it checks commit identity and re-runs the full-history secret scan.
Gates run 100% locally. Your code never leaves your machine.
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

Resolved from their README on 2026-08-04 (§8). Re-read it before opening the issue anyway — the
answers below are a snapshot, and the point of §4 is that this structure moves.

1. **There is no general companion-tooling section.** Their README curates adjacent tools in two
   places, and neither is an open list: (a) the **Stack & integrations** blockquote at the end of
   `## Compared to`, which is maintainer-authored prose naming *their* recommended companion
   (Serena, installed by default on `headroom wrap`, plus Ponytail); (b) `### Community projects`
   under `## Community`, which held exactly one entry — a Claude Code plugin that surfaces
   Headroom's own token savings in a status line.
2. Bullet format in `### Community projects` is `- **[Name](url)** — lowercase description.` with
   an em dash and a trailing period. Match it byte for byte if they ask for a PR.
3. `CONTRIBUTING.md` has **no listing policy** — no row covers "add my project to the README". Its
   routing table sends bugs to a PR, anything architectural to "an issue or ask in Discord first",
   and questions to Discord `#help`. It also caps open PRs at 10 per author. Opening an issue, as
   §2 says, is the route their own table endorses for a non-bug ask.

**The consequence for §2:** the only entry currently in `### Community projects` is a project built
*on* Headroom. Heimdall is not. Do not assert that section — or any section — is the right home.
Let "put it wherever it fits" carry it, which is what the submitted body already does.

---

## 5. Guard list — what must never appear on this surface

- Never characterise Headroom as missing, lacking, or not solving anything. The entry describes
  what each tool does. "Headroom compresses what the agent reads" is a description of its
  function, and it matches their own wording for it — README, `## What it does` preamble:
  "Headroom compresses everything your AI agent reads". Verified 2026-08-04 (§8, row 1). If they
  reword their headline, this clause follows theirs.
- Never "alternative to". Heimdall is not a substitute for a compression proxy, and there is no
  in-repo benchmark against any named product (`SUBMISSIONS.md` §6).
- Never a bare privacy absolute. The scoped S1–S6 set in `README.md` §"Your code stays yours" is
  the only correct framing; `test/truth-pass-claims.test.sh` goes red if a bare one reappears on a
  read-surface.
- Never quote "8/10 working output" without the word **adjudicated**. The raw machine count is
  6/10, recorded in the full-10 run JSON (`.planning/s6-sweep/20260620T050833Z-88787.json`,
  `"working_output_pass": 6`); the adjudication that lifts it to 8/10 is in the findings file at
  commit `ae88a55`. The reuse figure that stands unqualified is 0.50 median across 8 cold repos.
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
| 1 | "Headroom compresses what the agent reads" — the core comparative clause in the entry line | `https://github.com/headroomlabs-ai/headroom` — README, the project's own one-line self-description. Replace our verb with theirs if they differ. | **CONFIRMED 2026-08-04 — verb corrected** (§8) |
| 2 | Headroom is a local-first context-compression proxy | Same README, opening section. If "local-first" is not their word, drop it — it is doing work in the §3 reply about both tools running on your machine. | **CONFIRMED 2026-08-04 — "local-first" is their word, verbatim** (§8) |
| 3 | The repo slug is `headroomlabs-ai/headroom` and the licence is Apache-2.0 | The repo page and its `LICENSE` file. The slug is pasted into the submission target; a wrong slug files the issue on a stranger's repo. | **CONFIRMED 2026-08-04 — both** (§8) |
| 4 | Headroom curates companion tools in a README section, and that section is the right home for this entry | Their README. See §4 — resolve the section name and bullet format there, and keep the claim out of the submitted body regardless. | **RESOLVED BY CUTTING THE SECOND HALF — re-read live 2026-08-08.** First half confirmed: a curated surface exists (`### Community projects`, still exactly one entry; plus the Stack & integrations blockquote). The second half is claimed nowhere and stays that way — the section is not a general companion list, its one entry is a project built *on* Headroom, and "right home" is the maintainers' call. The submitted body names no section; "put it wherever it fits" carries it. (§4, §8) |
| 5 | Community channel exists and is the right place for the follow-up in §3 | The community/Discord link **in their README**. Do not guess or reconstruct an invite URL; resolve it from the README and use that. Confirm the channel's rules on tool links before posting anything. | **LINK RE-RESOLVED LIVE 2026-08-08 — `https://discord.gg/yRmaUNpsPJ`, read from their README (nav row and `## Community`), not reconstructed; invite still resolves, server "Headroom". Rules on tool links remain UNVERIFIED** — they sit behind the join, are published nowhere fetchable, and have not been read. Do not post the §3 A/B reply to Discord until someone has joined and read them. (§8) |
| 6 | Star count, if it is ever cited anywhere | The repo page. It moves daily. Preference: never cite it. It is not an argument. | **DO NOT CITE** |

---

## 7. Heimdall-side sourcing — all in-repo, no external check needed

`bin/falsify --assert-score 1.0` semantics, exchange-lob 6/6 and emulator-gb 3/3, both at
falsifiability 1.0 → `evals/flagship/STATUS.md` ·
13 cases, 13 caught, 100% at v0.1 → `evals/corpus/CORPUS-STATUS.md` ·
the `PreToolUse` gate on `Bash` matching `git push`, and the chain it runs — secret-scan →
`bin/heimdall-selfscan` → `bin/falsify <domain> --assert-score 1.0` per oracle domain →
`bin/corpus run`, each a hard block on non-zero → `hooks/hooks.json` (the `PreToolUse` `Bash`
matcher) ·
the native git pre-push hook, its two layers (identity over the push range, then full-history
selfscan) and the fact that it does **not** run the oracles → `hooks/git/pre-push` header;
`hmd guard install` installs it → `bin/heimdall:1733` ·
gates are Claude-Code-only today, cross-tool marked COMING → `heimdall-site/faq.html`
§`#cross-tool` ·
the coordination ledger over MCP, six tools, stdio JSON-RPC → `PROTOCOL.md` §"MCP Interop
Contract" ·
S1 verbatim, "Gates run 100% locally. Your code never leaves your machine." → `README.md`
§"Your code stays yours", gated by `test/truth-pass-claims.test.sh` ·
0.50 median reuse across 8 cold repos, with the full sorted per-repo table → commit `ae88a55`,
`docs/archive/docs/superpowers/specs/heimdall-S6-C3-findings.md` (sorted: 0.2581, 0.375, 0.40,
0.50, 0.50, 0.56, 0.6552, 0.9524 → median 0.50), and the four adjudication layers behind the 8/10
in that file §THE FINDING ·
the raw machine count 6/10 → the full-10 run JSON `.planning/s6-sweep/20260620T050833Z-88787.json`
(`"working_output_pass": 6`, `"working_output_rate": 0.6`, `"reuse_median": 0.5`). The findings
file carries the adjudication, not the raw count — cite the run JSON for 6/10 ·
MIT licence → `LICENSE`.

---

## 8. Headroom-side sourcing — external, fetched 2026-08-04

Primary sources only: their repo, their `LICENSE`, their `CONTRIBUTING.md`, the PyPI JSON index for
`headroom-ai`, and the Discord invite in their README. No blog, no summary, no recollection.

| # | Resolved value | Source URL | Fetched |
|---|---|---|---|
| 1 | Their headline is **"The context compression layer for AI agents"**; the preamble is **"Headroom compresses everything your AI agent reads — tool outputs, logs, RAG chunks, files, and conversation history — before it reaches the LLM."** Verb is *compresses*. Ours was *shrinks* → changed. (Their README does use "shrinks" once — "Everything above shrinks the prompt you **send**" — so the original was not false, but the headline verb is theirs to set.) | `https://raw.githubusercontent.com/headroomlabs-ai/headroom/main/README.md` | 2026-08-04 |
| 2 | **"local-first" is theirs, verbatim**, in the README subtitle: "library · proxy · MCP · content-aware compressors · local-first · reversible", and again under `## Headroom for teams`: "free, local-first, your data never leaves your machine". **"proxy" is theirs too**: "Headroom is the **proxy** — that's what we build and offer." Note it is one of several modes (library · proxy · agent wrap · MCP), so "a proxy" under-describes it; the phrase stands, the §3 reply must not imply proxy is the only mode. | Same README (subtitle; `## What it does`; `## Compared to` → Stack & integrations) | 2026-08-04 |
| 3 | **Slug `headroomlabs-ai/headroom` is canonical.** The older `chopratejas/headroom` 301-redirects to it (verified by following redirects; both raw READMEs are byte-identical). **Licence Apache-2.0**, confirmed three ways: the repo `LICENSE` file is the Apache License 2.0 text; the README badge; and PyPI `license_expression: "Apache-2.0"`. | `https://github.com/headroomlabs-ai/headroom` · `https://raw.githubusercontent.com/headroomlabs-ai/headroom/main/LICENSE` · `https://pypi.org/pypi/headroom-ai/json` | 2026-08-04 |
| 4 | `### Community projects` exists under `## Community` — one entry, format `- **[Name](url)** — description.` The other companion surface is the **Stack & integrations** blockquote closing `## Compared to`. `CONTRIBUTING.md` states no listing policy; its routing table sends non-bug asks to an issue or Discord. See §4. **"Right home" was not confirmed and is not claimable.** | Same README (`## Community`, `## Compared to`) · `https://raw.githubusercontent.com/headroomlabs-ai/headroom/main/CONTRIBUTING.md` | 2026-08-04 |
| 5 | Discord invite **`https://discord.gg/yRmaUNpsPJ`**, read from the README (nav row and `## Community`), not reconstructed. Invite resolves live to the server named **"Headroom"**. `CONTRIBUTING.md` names `#help` for questions. **Rules on tool links were not read** — see §6 row 5. | Same README · invite resolved at `https://discord.com/api/v10/invites/yRmaUNpsPJ` | 2026-08-04 |
| 6 | Star count — **not fetched, not resolved, not cited.** Deliberately excluded: it decays. | — | — |

**Re-read live 2026-08-08.** Every row above was re-fetched from the same primary sources and
still holds: headline and preamble verbs unchanged; "local-first" and "proxy" still their words;
`headroomlabs-ai/headroom` still canonical (HTTP 200, no redirect); `### Community projects` still
one entry, still a project built *on* Headroom; the Discord invite still resolves to server
"Headroom". One thing did not move and still cannot be resolved from a terminal: the channel's
rules on tool links sit behind the join. §6 row 5 stays UNVERIFIED for that reason.

**Pin cross-check (reported, not edited — `modules/**` is another agent's surface).** The pin in
`modules/headroom/manifest.json`, `headroom-ai[all]==0.33.0` with sdist digest
`97d817e5…deeb5a`, is **correct**. PyPI records `0.33.0` as the current version, `yanked: false`,
and the sdist `headroom_ai-0.33.0.tar.gz` digest is
`97d817e5923903d72bed24f75e0424e9cb7f86b3ddde0fc1acec4f3f85deeb5a` — an exact match. The `all`
extra exists in the package's `provides_extra`. The manifest's `upstream_note` about PyPI still
recording the pre-rename `chopratejas/headroom` path is also accurate, and the redirect is
confirmed above. No manifest change is needed or was made.
