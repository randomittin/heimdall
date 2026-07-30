# Heimdall — Submission Drafts (A6)

> ## ⛔ NOTHING IN THIS FILE HAS BEEN SUBMITTED ANYWHERE.
> **Decisions locked by RJ, 2026-07-28.** Every item below now carries a final status
> (APPROVED / DEFERRED / SKIP) at its section header, and approved copy is submission-ready.
> This file is still awaiting RJ's submission from his own identity: no PR has been opened on
> any external repo, no listing has been created, no form has been submitted, and no glama.ai
> registration has been made. Written on branch `a6-submissions` (a git worktree off `main`),
> committed locally, and **not pushed**.

---

## 0. Read this first — two findings that block "no telemetry / no network calls home" language

Before drafting a single line of public copy, I read `README.md`, `IDENTITY.md`, `PROTOCOL.md`,
`PARITY.md`, `SIGNING.md`, `SECURITY.md`, `OPERATORS.md`, `TOKEN-METRIC.md`, `REUSE-METRIC.md`,
`DECISION-GATE.md`, `evals/oracles/*`, and `docs/INDEX.md`. Two things I found change what is
safe to publish, and I flagged them rather than quietly working around them:

1. **`IDENTITY.md:31`** states, as a "constitution-level hard boundary": *"No telemetry, no
   network calls home, MIT, read the source."* That line was signed off **2026-06-13**. The
   product has since grown a control plane (`rr connect`, hosted job dispatch — README.md:15-24),
   a team-presence heartbeat (`bin/heimdall-presence`, opt-out not opt-in — see `DATA.md` on
   branch `truth-pass`), and a telemetry surface (`hmd telemetry`, `bin/heimdall-telemetry-corpus`,
   the "Pre-Merge Corpus" T0 tier, **on by default**). `IDENTITY.md` is stale relative to the
   current code and should not be quoted verbatim in public copy.
2. **`README.md`** *(FIXED — no longer applies)*. This finding was written against the
   pre-merge tree, where README read *"No sudo. No telemetry."* — a bare, unscoped claim the
   code did not support as written. That line was **removed** when the install one-liner was
   SHA-pinned to `v2.2.6` (merged in `a4-security`); README now reads *"No sudo. Idempotent."*
   and carries no bare telemetry claim. **`IDENTITY.md:31` is the only surface still carrying
   it**, and it awaits RJ's decision because it is constitution-level text. The site
   (`heimdall-site`,
   commit `7618ec7`) already fixed this exact problem for `runheimdall.dev` by replacing the
   bare claim with four **scoped** claims (gates run locally / presence is opt-out-able and
   documented / telemetry is specified+killable / auto-update is checked+disableable), each
   traceable to `DATA.md`. `DATA.md` is now **on `main`**, reconciled against current code on
   branch `truthpass-reconcile` — so the site's own `DATA.md` link
   (`github.com/randomittin/heimdall/blob/main/DATA.md`) resolves. The reconciled contract
   documents **five** surfaces (the three from `da7816b` plus the auto-update version check and
   `rr`), matching the site FAQ's enumeration, and the README carries the same scoped set as
   S1–S6 under §"Your code stays yours", gated verbatim by `test/truth-pass-claims.test.sh`.

**What I did about it:** every claim below uses the site's already-fixed, scoped phrasing
(never a bare "no telemetry"), and I did not use `IDENTITY.md`'s "no telemetry, no network
calls home" line anywhere. I'm surfacing this so RJ can decide: (a) **done** — the reconciled
`truth-pass` content is on `main` via `truthpass-reconcile`, so `DATA.md` actually resolves,
and (b) correct `IDENTITY.md:31` to match current reality (`README.md`'s bare claim is already
gone). With `DATA.md` on `main`, listing copy may link to it directly at
`github.com/randomittin/heimdall/blob/main/DATA.md` — no branch ref needed.

---

## 1. Positioning line — STATUS: APPROVED (Candidate A, locked by RJ 2026-07-28)

The task brief pointed at `heimdall-seo-geo-spec.md` §4 and a canonical "positioning line"
from §3. **Neither exists in this repo** (`heimdall-seo-geo-spec.md` is not present; I did not
invent a "§3" from a document I cannot find). Below are **candidates**, each derived verbatim
or near-verbatim from repo truth, not invented. RJ reviewed all three and approved Candidate
A; every positioning-line placeholder in this file is resolved to it below.

| # | Candidate | Source | Note |
|---|---|---|---|
| A | **"Nothing ships unproven."** — APPROVED | `IDENTITY.md:18` (`tagline:` field, canonical YAML) | Shortest, already the repo's own designated tagline. Brand-voice fits the "Bifröst/watchman" slang system (`IDENTITY.md:22-25`). **RJ's approved choice, 2026-07-28 — used in every tagline/positioning field below.** |
| B | **"A cloud bot that fixes your GitHub issues and opens a proven PR. You review, you merge."** | `README.md:3` (bolded opening line) | Concrete and literal about what `rr` does; best for listing sites that want a plain-English one-liner (StackShare, LibHunt). |
| C | **"Verification gates for AI-written code — every plan wires an external, falsifiable oracle so the merge stays blocked until the work is proven correct."** | Paraphrase of `README.md:37` ("Every plan wires an external, falsifiable oracle...") | Closest to a positioning statement (differentiates on verification vs. generation, per `evals/flagship/STATUS.md:38-42`'s explicit "VERIFICATION superiority... NOT generation superiority" framing). |

**RJ's decision (2026-07-28): Candidate A — "Nothing ships unproven." — approved for every
tagline/positioning field in this file.** Candidates B and C above are kept for provenance
only and are not used anywhere below. Every positioning-line placeholder in this file has
been resolved to this text in this pass. (Product-copy split, confirmed intentional: the
viral hook/H1 used elsewhere — "Your issues, fixed while you sleep" — is a separate line that
does not appear in this submissions file; every listing here uses the verification-framed
tagline instead.)

---

## 2. Awesome-list PRs — draft text only, NO PRs opened, NO branches created in target repos

For each list I fetched the **real, current README** from GitHub (not memory) to match its
exact entry format. Repo star counts were live-checked via the GitHub search API to confirm
each is the highest-signal list under that name.

### 2.1 `awesome-claude-code` — **GOOD FIT** — STATUS: SUBMITTED 2026-07-30 → https://github.com/hesreallyhim/awesome-claude-code/issues/2364 (validation bot: **Description max 500 chars** — used the trimmed 497-char form below; Category dropdown value = `Agent Orchestration`)

**Form description (≤500 chars, validated):**

```
Your AI agents can't grade their own homework. Heimdall gates every change behind a falsifiable oracle the agent never sees — proven able to fail before it passes — so PRs open only on real proof. It runs parallel agents across a team's machines, teammates auto-join by GitHub access, and each dev's triage is shared automatically so tribal knowledge stops dying in one head. Checkpoints context across sessions; /dream fixes overnight; design-match scores UI vs canonical. Nothing ships unproven.
```


- **Repo:** https://github.com/hesreallyhim/awesome-claude-code (50.1k★, confirmed top hit for "awesome-claude-code")
- **Section:** `## Multi-Agent Orchestration` (primary — wave-based parallel agents + the `heimdall` orchestrator agent is the closest match to this section's existing entries). Alternates worth considering: `## Security` (secret-scan + oracle gates) or `## Linting` (quality gates), but Multi-Agent Orchestration is the strongest single fit.
- **Fit assessment:** Good fit. This list already has "Security"-adjacent and orchestration entries with the same badge convention; Heimdall is a plugin for exactly this tool.
- **Entry, in the list's exact current format** (bullet + description line, then a second line of `img.shields.io` badges — matches every entry I read in `Documentation, Knowledge & Learning` / `Providers, Runtime & Integration Infrastructure`):

```markdown
- [Heimdall](https://github.com/randomittin/heimdall) by [randomittin](https://github.com/randomittin) - Your AI agents can't grade their own homework anymore. Heimdall gates every change behind an external, falsifiable oracle the agent never sees — proven able to fail before it can pass — so a PR opens only when the proof lands, not when the agent says it's done. It's more than a solo gate: it orchestrates parallel agents across a whole team's machines and developers, coordinated through one shared ledger and a live presence wall, and teammates auto-join by GitHub repo access with no invite and no pasted secret. Every dev's triage — the deny and verdict cases the gates produce — is shared across the team automatically through the presence wall and a shared corpus, so tribal knowledge stops dying in one person's head and becomes something everyone learns from. It checkpoints and restores your full context across sessions; `/dream` works the codebase overnight and leaves a morning report without ever auto-pushing; a design-match loop scores your build against its Claude Design canonical; and it tunes its own routing over time, keeping a change only when a measured delta proves it better. Nothing ships unproven.  
<img src="https://img.shields.io/github/created-at/randomittin/heimdall?style=flat-square&labelColor=2b2b2b&color=6b6b6b" alt="created">&nbsp;&nbsp;<img src="https://img.shields.io/github/last-commit/randomittin/heimdall?style=flat-square&labelColor=2b2b2b&color=6b6b6b" alt="last-commit">&nbsp;&nbsp;<img src="https://img.shields.io/github/license/randomittin/heimdall?style=flat-square&labelColor=2b2b2b&color=6b6b6b" alt="license">&nbsp;&nbsp;<img src="https://img.shields.io/github/stars/randomittin/heimdall?style=flat-square&labelColor=2b2b2b&color=6b6b6b" alt="stars">
```

- **Longer description (for the PR body, not the list line itself):**

  > Heimdall is a Claude Code superskill-orchestrator plugin. Its differentiator is
  > verification, not generation: every plan is gated by an external, falsifiable oracle
  > (`evals/oracles/registry.json` — differential / trace-diff / verdict / property / example,
  > strongest-first) that the implementing agent never sees, so a change can't grade its own
  > homework. Two flagship gates are proven falsifiable at 1.0 — `exchange-lob` (6/6 injected
  > mutants caught) and `emulator-gb` (3/3) — and a 13-case regression corpus catches 100% of
  > its recorded failure cases (`evals/corpus/CORPUS-STATUS.md`). A hosted `rr` mode extends
  > this to a cloud bot that opens a scoped `heimdall/*` PR on your own GitHub repo using
  > **your own** Claude subscription and **your own** GitHub App install — BYOC, no shared
  > keys (`README.md:22-29`) — gated by a tenant-isolation test suite with a named invariant
  > per attack class (`test/heimdall-cp-authz-gate.test.sh`). Releases are minisign-signed and
  > verified before the self-updater applies them (`SIGNING.md`). MIT-licensed.

### 2.2 `awesome-mcp-servers` — **STRETCH, honest caveat** — STATUS: APPROVED (narrow scope — option (b), `heimdall-ledger-mcp` only)

- **Repo:** https://github.com/punkpeye/awesome-mcp-servers (90.8k★, confirmed top hit)
- **Section:** `### 💻 Developer Tools`
- **Fit assessment: stretch, not a strong fit — say so plainly.** Heimdall's *product* is not
  an MCP server; its MCP surface is one thin binary, `bin/heimdall-ledger-mcp`, that exposes 6
  tools (`read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`,
  `raise_conflict_pr`) over the **coordination ledger** only — not the gates, not the oracles,
  not the verification system this list's other entries in this section are more directly
  comparable to (grounding/verification MCP servers like `eleata-verify-mcp`,
  `bumpguard-mcp`, `docguard`). Submitting the whole Heimdall repo here would overstate what
  the MCP surface actually does. **Two options for RJ:** (a) skip this list entirely, or (b)
  submit `heimdall-ledger-mcp` specifically, scoped honestly as a coordination-ledger server,
  not "Heimdall" the product. **RJ's decision (2026-07-28): option (b) — approved.** Submit
  `heimdall-ledger-mcp` narrowly, under this honest scope, now; revisit with a broader
  submission once the full Layer-1 gates/verdict MCP server ships. Draft below is option (b).
- **Format requirement I could not satisfy:** every current entry in this list carries a
  `glama.ai/mcp/servers/...` score badge, which requires the server to be registered on
  glama.ai first (a step outside this repo). The draft below omits that badge. **Action before
  submitting: register on glama.ai FIRST for the badge** — do this before opening the PR, not
  after.
- **Entry draft, in the list's exact current bullet format:**

```markdown
- [randomittin/heimdall](https://github.com/randomittin/heimdall/blob/main/bin/heimdall-ledger-mcp) 🐍 🏠 - Thin MCP wrapper (stdio, JSON-RPC 2024-11-05) over Heimdall's git-native coordination ledger: 6 tools for HAID-attributed claim/read/decision/conflict operations so any MCP client (Cursor, Copilot, Claude Code) can join the same collision-prevention surface a repo's `hmd` agents already use. Delegates every mutation to `bin/heimdall-claim` / `bin/heimdall-haid` — reimplements no logic itself.
```

- **Claim check:** the tool list, delegation model, and handshake are all directly sourced
  from `PROTOCOL.md:219-306` ("MCP Interop Contract — `heimdall-ledger-mcp` — v1.0.0").

### 2.3 `awesome-ai-tools` — **STRETCH** — STATUS: DEFERRED

- **Repo:** https://github.com/mahseema/awesome-ai-tools (5.7k★, confirmed top hit)
- **Section:** `### Code` (nested under the "Code with AI" top-level section)
- **Fit assessment: stretch.** This list skews consumer/SaaS — chatbots, image/video/audio
  generators, writing assistants. Its "Code" section holds general AI coding assistants
  (Cursor-style tools), not developer verification infrastructure. Heimdall could plausibly
  sit there since it plugs into Claude Code, but the list's audience and neighboring entries
  are not really Heimdall's audience. Low priority relative to `awesome-claude-code` and
  `awesome-devtools`.
- **Entry draft, matching the list's plain-bullet format** (`- [Name](url) - description.`):

```markdown
- [Heimdall](https://github.com/randomittin/heimdall) - A verification-first plugin for Claude Code: every AI-generated change is gated by an external, falsifiable correctness oracle before a PR opens, instead of trusting the agent's own tests. Nothing ships unproven. MIT, self-hostable.
```

### 2.4 `awesome-devtools` — **GOOD FIT** — STATUS: APPROVED

- **Repo:** https://github.com/devtoolsd/awesome-devtools (669★). I checked a second,
  higher-star candidate, `moimikey/awesome-devtools` (534★ — close, and actually the
  *lower* count once re-checked live), but its list is entirely single-purpose in-browser
  bookmarklets/utilities (CSS tools, regex testers, JSON formatters) — no category Heimdall
  belongs in. `devtoolsd/awesome-devtools` already has a live `## AI Coding Tools` section
  listing Cursor, GitHub Copilot, Claude Code itself, Cline, and OpenCode — a direct
  neighbor set.
- **Section:** `## AI Coding Tools`
- **Fit assessment: good fit** — same category as Claude Code itself, Cursor, Cline.
- **Entry draft, in the list's exact current bullet format** (`* [Name](url) - description.`):

```markdown
* [Heimdall](https://github.com/randomittin/heimdall) - Verification-gate plugin for Claude Code; wires every plan to a falsifiable external oracle so a merge stays blocked until the fix is proven, not just generated. MIT.
```

### 2.5 `awesome-git-hooks` — **WEAK FIT, recommend deprioritizing** — STATUS: SKIP

- **Repo:** https://github.com/CompSciLauren/awesome-git-hooks (1.17k★, confirmed top hit)
- **Fit assessment: honestly weak.** This list catalogs **individual, atomic, copy-paste hook
  scripts** organized strictly by git hook name (`pre-commit`, `pre-push`, etc.) — grab one
  file, drop it in `.git/hooks/`, done. Heimdall's git-hook surface (`hooks/hooks.json`,
  `hooks/git/pre-push`, wired via `hmd guard install`) is not a standalone script — it's one
  small piece of a much larger orchestrator/plugin, and pointing a reader at Heimdall's
  pre-push hook without the rest of the system (`heimdall-state`, the oracle gates, the
  corpus) doesn't match what this list promises ("grab & go", "nothing to install"). The
  list's own `## Tools` section (Husky, Overcommit, `pre-commit` framework) is a *slightly*
  better fit — hook **managers**, not scripts — but Heimdall isn't primarily a hook manager
  either.
- **Recommendation:** skip this one, or submit narrowly under `## Tools` with the caveat
  spelled out. Draft below is the narrow `## Tools`-section version, for if RJ still wants it:

```markdown
- [Heimdall](https://github.com/randomittin/heimdall) - Installs a git pre-push gate (`hmd guard install`) that chains secret-scanning, falsifiable-oracle checks, and corpus regression before a push leaves the machine — one hook inside a larger Claude Code verification plugin, not a standalone script.
```

---

## 3. Listing copy — AlternativeTo, OpenAlternative, LibHunt, StackShare, Product Hunt — STATUS: APPROVED (all 5, locked by RJ 2026-07-28)

Every field below traces to a specific repo line, cited inline. Positioning line is "Nothing ships unproven." throughout (RJ's decision, §1).

### 3.1 AlternativeTo — STATUS: APPROVED

| Field | Value | Source |
|---|---|---|
| Name | Heimdall | `IDENTITY.md:7` |
| Website | https://runheimdall.dev | `IDENTITY.md:12` |
| Tagline | Nothing ships unproven. | §1 |
| Description | "A Claude Code plugin that gates every AI-generated change behind an external, falsifiable correctness oracle — the implementing agent never sees the check that grades it. Ships a hosted mode (`rr`) that opens a scoped, human-reviewed PR on your own GitHub repo using your own Claude subscription and GitHub App install (BYOC — no shared keys). Two flagship verification gates are proven able to fail (falsifiability score 1.0 on `exchange-lob` and `emulator-gb`); a 13-case regression corpus catches 100% of its recorded failure cases at v0.1. MIT-licensed, self-hostable." | `README.md:1-37`, `evals/flagship/STATUS.md:21-26`, `evals/corpus/CORPUS-STATUS.md:10`, `LICENSE:1` |
| Categories | Developer Tools, Code Review, AI Coding Assistants | inferred from feature set |
| Platforms | macOS, Linux (bash 3.2 compatible per `PROTOCOL.md:59`); Windows not documented as supported | `PROTOCOL.md:59` — no Windows mention found anywhere in the docs read |
| License | MIT | `LICENSE:1` |
| "Alternative to" | Not a clean 1:1 substitute for any single tool — see note below. Do not list as "alternative to GitHub Copilot" or similar without qualification. | — |

**Note on "alternative to" framing:** Heimdall is a plugin *for* Claude Code, not a
replacement for it — so it is not an "alternative to Claude Code." Its hosted `rr` mode
(cloud bot opens PRs on your issues) is closer, directionally, to autonomous coding-agent
products (the pitch in `README.md:3` — "fixes your GitHub issues and opens a proven PR" —
reads similarly to that category), but I found no in-repo comparison table or benchmark
against any named competitor, so I did not write a direct "alternative to X" claim. If RJ
wants that framing, it needs a real comparison, not an assumption from me.

### 3.2 OpenAlternative — STATUS: APPROVED

| Field | Value | Source |
|---|---|---|
| Name | Heimdall | `IDENTITY.md:7` |
| Tagline | Nothing ships unproven. | §1 |
| Website | https://runheimdall.dev | `IDENTITY.md:12` |
| GitHub | https://github.com/randomittin/heimdall | `IDENTITY.md:8` |
| Category | Developer Tools / AI Coding | — |
| Pricing | Free, open source (MIT). Hosted `rr` mode is BYOC (you provide your own Claude subscription + GitHub App install; no separate SaaS fee documented in this repo) | `LICENSE:1`, `README.md:22-29` — I found no pricing page/billing code in this repo for the hosted mode, so I am not claiming it is free-forever, only that no fee mechanism exists **in this repo** as of `main`@`66b7a33` |
| "Alternative to" | Same caveat as §3.1 — no in-repo comparison basis for a specific proprietary product. If OpenAlternative's form requires a specific answer, the most defensible honest one is: "an open-source, self-hostable verification layer for AI coding agents, for teams wary of unverifiable AI-authored merges." | derived from `README.md` framing, not a direct product comparison |
| Description | (same as AlternativeTo §3.1) | — |

### 3.3 LibHunt — STATUS: APPROVED

| Field | Value | Source |
|---|---|---|
| Name | Heimdall | — |
| Summary | Nothing ships unproven. | §1 |
| Description | "Claude Code plugin + optional hosted bot. Verification gates run via falsifiable external oracles (`evals/oracles/registry.json`); quality gates block `git push` until tests pass, lint is clean, and no secret-scan finding is present (`PARITY.md:99-111`). Token-frugal multi-agent orchestration protocol included (`PROTOCOL.md`)." | as cited |
| GitHub | https://github.com/randomittin/heimdall | — |
| Language(s) | Shell (bash), Python, JavaScript/TypeScript — per `REUSE-METRIC.md:92-98`'s supported-stack table, which documents Heimdall's own analyzer's language coverage as a proxy for the repo's own primary languages | `REUSE-METRIC.md:92-98` |
| Category | Developer Tools | — |

### 3.4 StackShare — STATUS: APPROVED

| Field | Value | Source |
|---|---|---|
| Tool name | Heimdall | — |
| Tagline | Nothing ships unproven. | §1 |
| Category | Code Review / Utilities (StackShare has no exact "AI verification" category as of what I could infer; "Code Review" is the closest existing StackShare taxonomy bucket for a merge-gating tool) | inferred, flag for RJ to confirm against StackShare's live category list at submission time |
| Description | "Verification layer for Claude Code: wires an independent, falsifiable oracle into every implementation plan so a PR only opens once a check *proven able to fail* actually passes. Ships `bin/falsify` (mutation-kill scoring) and `bin/corpus` (13-case regression replay, 100% catch-rate at v0.1)." | `README.md:37`, `evals/flagship/STATUS.md:21-26`, `evals/corpus/CORPUS-STATUS.md:10` |
| Why we use it (pros, for a "stack" writeup) | "Falsifiability is measured, not asserted — every gate has a mutant-kill score before it's trusted (`evals/oracles/README.md:43-49`)." / "Signed auto-updates — releases are minisign-signed and verified before the self-updater applies anything (`SIGNING.md:9-14`)." | as cited |

### 3.5 Product Hunt — STATUS: APPROVED

| Field | Value | Source |
|---|---|---|
| Product name | Heimdall | — |
| Tagline (≤60 chars) | Nothing ships unproven. (23 characters — fits PH's ≤60-char field comfortably; Candidate C would have needed trimming) | §1 |
| Description | "Heimdall is a Claude Code plugin that gates AI-generated changes behind falsifiable, external correctness oracles — so 'the tests pass' actually means something. Two flagship gates are proven able to fail (falsifiability 1.0 on an order-book matcher and a Game Boy CPU emulator — see `evals/flagship/STATUS.md`), and a growing regression corpus makes sure a bug that was ever caught can't ship silently again. An optional hosted bot (`rr`) opens scoped, human-reviewed PRs on your own repo using your own Claude subscription and GitHub App install — you review, you merge, it never touches `main` directly and never self-merges (`README.md:5,30`)." | as cited |
| Topics/tags | Developer Tools, AI, Open Source, Claude, DevOps | — |
| First comment (maker comment) draft | "Hey — maker here. The idea behind Heimdall started from a simple annoyance: an AI agent's own tests are not evidence, because the same agent that wrote the code also wrote (and can rationalize) the tests. So Heimdall's gates are external — a mutation-tested oracle the implementing agent never sees (`evals/oracles/README.md`). We publish our own failures on purpose (`evals/flagship/STATUS.md` keeps the ❌ rows visible) because a verification system that hides its own misses can't be trusted with yours. Everything here is MIT-licensed and the install script is meant to be read before it's run (`less install.sh` before `bash install.sh` — no eval, no base64, per `README.md:51-57`). Happy to answer anything about the oracle design, the falsifiability scoring, or the hosted `rr` bot's tenant-isolation tests." | `evals/oracles/README.md`, `evals/flagship/STATUS.md:154-158`, `README.md:51-57` |

---

## 4. MCP registry submission bundle — **BLOCKED / HELD**

**Status: HELD.** Per instruction, this bundle is written but not submitted, and is held
until "Layer 1 ships."

**Honesty note on the hold condition itself:** I searched this repo for a "Layer 1" milestone
definition (`grep -rn "Layer 1" .` across all tracked files, excluding `.git`) and found only
two unrelated uses of the string — a comment in `hooks/git/pre-push:28` about hook-chaining
layering, and a comment in `sentinels/bloat.sh:90` about the bloat scanner's deterministic
engine. **Neither defines an MCP-readiness milestone.** `bin/heimdall` does reference a
"Layer 0" (`heimdall-init`, "the universal git core," `bin/heimdall:1495`), which implies a
layer numbering scheme exists somewhere in RJ's roadmap, but I could not find "Layer 1"'s
definition committed anywhere in this repo. **RJ should confirm what gates the hold** before
anyone treats this as ready — I'm not asserting it's close, only that I couldn't verify the
exact bar from repo contents alone.

**The bundle, written now so it's ready to submit once unblocked:**

| Field | Value | Source |
|---|---|---|
| Server name | `heimdall-ledger-mcp` | `PROTOCOL.md:224` |
| Version | 1.0.0 (`serverInfo.version`) | `PROTOCOL.md:241` |
| Transport | stdio, JSON-RPC 2.0, protocol revision `2024-11-05` | `PROTOCOL.md:221-222` |
| Description | "Exposes Heimdall's git-native Coordination Ledger (claim/release surfaces, capsule reads, decision log, conflict PRs) over MCP so any MCP client — Cursor, GitHub Copilot, Claude Code, or a bespoke agent — can join the same collision-prevention substrate a repo's `hmd` agents already use. Thin wrapper: every mutation shells out to `bin/heimdall-claim` / `bin/heimdall-haid`, the single sources of truth; the server reimplements none of their logic." | `PROTOCOL.md:224-229` |
| Tools (6) | `read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`, `raise_conflict_pr` | `PROTOCOL.md:271-280` (full arg table) |
| Install / registration | `.mcp.json` drop-in: `{ "mcpServers": { "heimdall-ledger": { "command": "bin/heimdall-ledger-mcp" } } }` | `PROTOCOL.md:296-302` |
| Identity model | Each client declares itself at `initialize` (`clientInfo.name`) or per-call via `client_identity`; server derives a spawn HAID `{root}/{client}` | `PROTOCOL.md:243-252` |
| Repo | https://github.com/randomittin/heimdall | — |
| License | MIT | `LICENSE:1` |

**Why held, restated plainly:** the bundle above is real and traceable — `bin/heimdall-ledger-mcp`
exists on disk (`bin/heimdall-ledger-mcp`, confirmed present), the tool contract is documented
and versioned. But per the task instruction this submission is explicitly gated on a
milestone I could not locate the definition of. **Do not submit this bundle until RJ confirms
what "Layer 1" is and that it has shipped.**

---

## 5. Claims provenance table

Every factual claim used anywhere above, traced to its source. "External" means the number
lives outside this repo (a linked page) and I could not re-verify it from a committed
artifact — flagged so RJ knows which numbers to double check before they go out.

| Claim | Source | Verified in-repo? |
|---|---|---|
| "Nothing ships unproven." (tagline) | `IDENTITY.md:18` | Yes — literal quote |
| "A cloud bot that fixes your GitHub issues and opens a proven PR. You review, you merge." | `README.md:3` | Yes — literal quote |
| Bot runs as scoped GitHub App, never as you, never on `main`, never self-merges | `README.md:5` | Yes |
| Tenant isolation is a falsifiable oracle with a named invariant + red-line mutant test per attack class | `README.md:28`; test file exists at `test/heimdall-cp-authz-gate.test.sh` | Yes — file existence confirmed via `ls` |
| BYOC — credential lands in your own per-team Secret Manager secret, never logged/echoed/readable by another tenant | `README.md:29` | Yes (doc claim; not independently re-audited by me beyond reading the doc) |
| App holds exactly Contents + Issues + Pull requests, no Administration/Actions/merge capability | `README.md:30` | Yes (doc claim) |
| No sudo, idempotent install, reversible via `hmd uninstall` | `README.md:45-49` | Yes |
| "No telemetry" (README's former bare phrasing) | *(removed)* | **Resolved.** The bare claim is gone from `README.md`; the scoped claim set now lives under README §"Your code stays yours", gated by `test/truth-pass-claims.test.sh`. |
| "No telemetry, no network calls home" (constitution-level) | `IDENTITY.md:31` | **Stale, contradicted by `bin/heimdall-presence:304` (default control plane), `bin/heimdall-autoupdate:76` (GitHub Releases GET), and `bin/rr:568` (task text).** Not reused in any draft above. **Still open — reserved for RJ.** |
| Gates run 100% locally; code never leaves the machine (scoped claim, as used in drafts above) | `heimdall-site` commit `7618ec7` (index.html); `DATA.md` §"Local gates" row | Yes — `DATA.md` is the merged data contract; the claim is gated verbatim as S1 by `test/truth-pass-claims.test.sh` |
| Falsifiability score 1.0 — `exchange-lob` 6/6 mutants caught, `emulator-gb` 3/3 | `evals/flagship/STATUS.md:21-26` | Yes |
| Corpus 13/13 caught (100%) at v0.1 | `evals/corpus/CORPUS-STATUS.md:10` | Yes |
| Oracle gate types ranked differential > trace-diff > verdict > property > example | `evals/oracles/README.md:15-19` (`registry.json`) | Yes |
| Releases minisign-signed; auto-updater verifies before applying, refuses unsigned/tampered/wrong-key | `SIGNING.md:9-14` | Yes |
| Install script is function-wrapped, no eval, no base64 — readable before running | `README.md:51-57` | Yes (I read `install.sh` header structure indirectly via the README's own description; did not re-audit the full script byte-for-byte) |
| "0.50 median reuse across 8 cold repos" | `README.md:77`, linking to external `https://runheimdall.dev/proof`; methodology (8 reuse-measured repos: 5 JS + 3 Python, 2 more working-output-only probes excluded from the median) documented in `docs/archive/docs/superpowers/specs/heimdall-S6-C3-proposal.md` | **Partially external** — the number itself lives on a linked page outside this repo; I could not find a committed results JSON/table reproducing it inside `main`. Methodology is real and traceable; the headline number is not independently re-verifiable from repo contents alone. **RJ should confirm the `/proof` page is live and accurate before this claim is used publicly.** |
| `heimdall-ledger-mcp` — 6 tools, thin wrapper, delegates to `heimdall-claim`/`heimdall-haid` | `PROTOCOL.md:219-306` | Yes; binary existence confirmed (`bin/heimdall-ledger-mcp` present) |
| MIT license | `LICENSE:1` | Yes |
| Repo `github.com/randomittin/heimdall`, domain `runheimdall.dev` | `IDENTITY.md:8-12` | Yes |
| Bash 3.2 / macOS compatibility (protocol tooling) | `PROTOCOL.md:59` | Yes |

---

## 6. Claims I considered and dropped for lack of evidence

- **Any specific dollar/time/token savings percentage as a headline number** (e.g. "cuts
  costs by X%"). `TOKEN-METRIC.md:90-93` explicitly says the metric definition itself is
  **"awaiting RJ's final confirm"** and that `total_tokens` vs `total_cost_usd` savings are
  different numbers that must not be conflated. I did not quote a percentage anywhere.
- **"Caveman ultra ~75% tokens saved"** (`PARITY.md:225`, `bin/heimdall:310`) — this is a
  real banner string in the code, but `PROTOCOL.md:9-10` itself distinguishes this
  unmeasured "claimed" 75% from the protocol's own *measured* token ledger number, and warns
  the two must be reported separately. I did not use the 75% figure in any submission draft.
- **Star counts / GitHub popularity for Heimdall itself** — not applicable pre-launch; no
  fabricated numbers used.
- **Any comparison naming a specific competitor by name** (Copilot, Devin, Cursor, etc.) as
  something Heimdall "beats" or "replaces" — no in-repo benchmark against a named competitor
  exists, so no such comparison appears anywhere above (see §3.1 note).
- **DECISION-GATE.md's 90-day targets** (2,000+ stars, 50+ waitlist signups, 5 design
  partners) — these are internal pre-commitment thresholds for RJ's own decision-making, not
  public marketing claims; not used anywhere in listing copy.
- **Windows support** — not claimed anywhere; found no evidence of it (only bash 3.2/macOS
  compatibility documented).

---

## 7. What RJ needs to do before any item here can move — PARTIALLY DONE (2026-07-28)

1. Pick (or write) the canonical positioning line (§1) and swap the positioning-line
   placeholder everywhere it appears in this file. **[DONE 2026-07-28 — Candidate A
   approved, all placeholders resolved.]**
2. Decide on the `IDENTITY.md:31` / `README.md:45` "no telemetry" staleness (§0) — at minimum,
   don't let submission copy reuse the old bare phrasing (none of the drafts above do).
3. Merge (or otherwise land) `DATA.md` onto `main` so the site's existing `DATA.md` link
   resolves, before any listing that cites it goes live.
4. Confirm the `runheimdall.dev/proof` page is live and matches the "0.50 median reuse across
   8 cold repos" claim before that line is used publicly (it's the one headline number in
   this file that isn't fully re-verifiable from committed repo contents).
5. Decide whether to skip `awesome-git-hooks` (my recommendation, §2.5) and whether to pursue
   `awesome-mcp-servers` narrowly-scoped to `heimdall-ledger-mcp` only (§2.2) rather than the
   whole product. **[DONE 2026-07-28 — git-hooks: SKIP. mcp-servers: APPROVED, narrow
   scope.]**
6. Confirm what "Layer 1" means and whether it has shipped before lifting the hold on §4.
7. Approve each section individually — this file intentionally has no single "approve all"
   switch. **[Status 2026-07-28: §1 APPROVED · §2.1 APPROVED · §2.2 APPROVED (narrow scope) ·
   §2.3 DEFERRED · §2.4 APPROVED · §2.5 SKIP · §3 APPROVED (all 5). §0 and §4 remain open —
   not part of this decision round.]**
