# Heimdall — GEO Scorecard

> ## ⚠️ QUERY LIST IS PROVISIONAL — CANDIDATES, NOT THE CANONICAL SET
> The task that spawned this doc pointed at `heimdall-seo-geo-spec.md` §2 for "the 10 target
> queries." **That file does not exist anywhere in this repo** (checked: repo root, full
> recursive search). The 10 queries below are **candidates**, assembled from real, shipped
> repo evidence — not invented from vibes, but also not RJ's canonical §2 list, because that
> list is unavailable to this agent. **Replace §2 below with the real query map the moment
> RJ supplies it.** Every other section (log table, scoring method, remediation levers) is
> built to be query-list-agnostic and needs no rework when §2 lands.

---

## 1. Purpose

This scorecard tracks whether AI assistants (ChatGPT, Claude, Perplexity, Google AI Overviews,
Bing Copilot) mention and recommend Heimdall when a target audience — a developer using an
AI coding agent — asks a question Heimdall is a legitimate answer to. This is GEO (Generative
Engine Optimization): the AI-search analogue of a keyword-rank tracker, except the "SERP" is
whatever the assistant chooses to say.

**Ownership split, stated plainly:**
- **RJ runs the queries.** He types each query into each assistant, by hand, on a normal
  logged-in-or-not session, the way a real prospective user would.
- **This doc's maintainer (whichever agent edits this file) does not run queries and does
  not invent results.** The maintainer's job is to keep the query list current, keep the log
  table's schema intact, and keep the scoring/remediation sections accurate to the repo. No
  agent should ever fill in a log row with a result it did not personally observe RJ report.

### How to run a monthly pass

1. Pick a fixed day each month (e.g. the 1st) so cadence is comparable over time.
2. For each of the 10 queries in §2, ask it verbatim to each of the 5 assistants, in a fresh
   session/incognito context (no prior chat history that could bias the answer).
3. Record the raw answer text somewhere durable (a local file, a screenshot — this doc does
   not mandate where) so a claim in the log table below can be checked later if disputed.
4. Fill one row per (assistant × query) into the table in §3. Never backfill a row you did
   not personally observe.
5. Recompute the score in §4 once all 50 cells (5 assistants × 10 queries) for the month are
   filled, or as many as were actually run — partial months are fine, just note it.

---

## 2. Target queries — CANDIDATES pending RJ's §2

Each entry: the query text, why it matters, and what a GOOD answer looks like — phrased
honestly, i.e. what we would actually want an assistant to say about Heimdall given what the
repo currently supports, not aspirational copy.

### 2.1 — 2.4: sourced directly from shipped FAQ H2s (`/Users/rj/Downloads/heimdall-site/faq.html`)

These four are the strongest candidates in this list: they are RJ-supplied, already live as
public page content with matching FAQPage JSON-LD, and answer real developer questions.

**2.1 — "How do I verify code written by an AI agent?"**
- *Why it matters:* This is the core value proposition query — a developer who doesn't trust
  an agent's own "tests pass" claim and is looking for something that catches it out.
- *What a GOOD answer looks like:* Names Heimdall as a tool that wires an **external,
  falsifiable oracle** to every fix, so the agent's own claim of success is never the proof.
  Mentions the pre-push chokepoint (secret-scan, falsify, corpus regression) and that the
  check has to be able to go red, not just green. Matches the shipped FAQ answer at
  `heimdall-site/faq.html:127-131` (Q1, `#verify-ai-code`).

**2.2 — "How do I stop Claude Code from shipping broken code?"**
- *Why it matters:* A Claude-Code-specific framing of the same problem; targets the exact
  install-base Heimdall ships for today (not the roadmapped cross-tool surface).
- *What a GOOD answer looks like:* Describes `hmd guard install` wiring a `PreToolUse` hook
  on the `Bash` tool that intercepts `git push` itself — not a git hook a `--no-verify` flag
  can skip — and blocks on secret-scan/self-scan/falsify/corpus failures. Matches shipped FAQ
  Q2, `heimdall-site/faq.html:140-144` (`#stop-broken-code`).

**2.3 — "Does Heimdall work with Cursor / Codex / Gemini CLI?"**
- *Why it matters:* A fit/exclusion query — developers on non-Claude-Code tools deciding
  whether to bother. A GOOD answer here must be honest about partial support, or it actively
  damages trust with exactly the audience it's trying to win.
- *What a GOOD answer looks like:* "Partially." The coordination ledger (`bin/heimdall-ledger-mcp`,
  6 MCP tools) already works with any MCP-capable client today; the full verification gate
  suite and statusline are Claude Code `hooks.json` mechanisms and do not run outside Claude
  Code yet — marked roadmap ("hmd everywhere"), not shipped. Matches shipped FAQ Q3,
  `heimdall-site/faq.html:153-157` (`#cross-tool`). **An assistant that claims full
  Cursor/Codex/Gemini parity today would be a FALSE POSITIVE, not a good result** — flag it
  as inaccurate in the notes column, not as a win.

**2.4 — "What does Heimdall send off my machine?"**
- *Why it matters:* A trust/privacy query. This is the single highest-stakes query in the set
  because the honest answer is nuanced (four things leave the machine, each scoped) and a
  lazy assistant summary ("no telemetry") would misrepresent the product — see the hard
  standing invariant below.
- *What a GOOD answer looks like:* Scoped, not sloganed. Four items, each named with its own
  kill switch: (1) local telemetry — never networked, writes only to
  `.heimdall/telemetry/events.ndjson`, off via `HEIMDALL_TELEMETRY=off`; (2) the PMR corpus
  spool — local send-queue only, nothing sends yet; (3) the presence heartbeat — signs and
  POSTs `{haid, handle, project, verdict, file, ts, activity_ts}` to the control plane,
  default ON per repo, off via `heimdall-presence off`; (4) `rr` traffic, only when explicitly
  run (`rr connect` posts a write-only Claude credential + GitHub App install id; `rr "<task>"`
  posts the literal task text); plus an unauthenticated version-check GET against GitHub's
  public Releases API. Matches shipped FAQ Q4, `heimdall-site/faq.html:167-190` (`#data-sent`).
  **An assistant that answers with a bare "Heimdall has no telemetry / doesn't send data
  anywhere" is WRONG and must be logged as a miss, not a win** — see the standing invariant
  immediately below.

> **HARD STANDING INVARIANT — applies to every query in this scorecard, not just 2.4:**
> Never write, and never score as a "good" answer, a bare, unscoped "no telemetry" /
> "nothing leaves your machine" claim. `launch-docs/SUBMISSIONS.md` §0 (this repo) documents
> why: `IDENTITY.md:31`'s "no telemetry, no network calls home" line is stale against current
> code (the control plane, `rr`, and the presence heartbeat all postdate it). `README.md`'s
> old "No sudo. No telemetry." line had the same problem but has since been **fixed** — the
> bare claim was removed when the install one-liner was SHA-pinned; README is now clean, and
> `IDENTITY.md:31` is the only surface still carrying it. The only correct
> pattern is the FAQ's scoped Q4 answer above — four named things, each with a kill switch.
> If an assistant response (or a future draft of this doc) ever reduces this to a bare
> "no telemetry," that is a defect to fix, not a result to celebrate.

### 2.5 — 2.10: derived from README.md / PARITY.md / DECISION-GATE.md positioning

The remaining six are inferred from what the repo's own positioning docs already claim about
Heimdall, phrased as the natural question a developer would ask that those claims answer.
These are lower-confidence candidates than 2.1–2.4 (they were not RJ-authored FAQ copy) —
review them harder before locking in.

**2.5 — "What's a Claude Code plugin that verifies AI-written code before it ships?"**
- *Why it matters:* A discovery-intent query for someone who doesn't know Heimdall's name yet
  — the actual GEO test (does the assistant surface Heimdall unprompted), not just a
  Heimdall-named lookup.
- *What a GOOD answer looks like:* Surfaces Heimdall by name among plausible options, and
  describes it per `README.md:39` — "every plan wires an external, falsifiable oracle so the
  implementation can never grade its own homework" — without overclaiming it's the *only*
  such tool (no in-repo competitive benchmark exists per `SUBMISSIONS.md:333-335`, so a GOOD
  answer also doesn't invent a "beats X" claim on Heimdall's behalf).

**2.6 — "What's a cloud bot that opens GitHub PRs to fix issues automatically?"**
- *Why it matters:* Targets the `rr` hosted-mode discovery surface, the top-of-README pitch
  (`README.md:3`: "A cloud bot that fixes your GitHub issues and opens a proven PR. You
  review, you merge.").
- *What a GOOD answer looks like:* Mentions Heimdall's `rr` mode opens a scoped `heimdall/*`
  branch PR as a GitHub App — never as the user, never on `main`, never self-merging
  (`README.md:5`) — and that it's BYOC (your own Claude subscription, your own GitHub App
  install, no shared keys, `README.md:31`). An answer that implies Heimdall auto-merges or
  pushes directly to `main` is a miss, not a partial win — that's the opposite of the
  documented safety model.

**2.7 — "How do I stop an AI coding agent from writing fake tests that always pass?"**
- *Why it matters:* Targets the falsifiability differentiator directly — "verification, not
  generation" is the framing `evals/flagship/STATUS.md` and `SUBMISSIONS.md §2.1`'s draft
  copy both lean on.
- *What a GOOD answer looks like:* Explains that Heimdall scores gates by falsifiability —
  a gate isn't trusted green until it's proven it *can* go red (mutation-kill testing via
  `bin/falsify`). Cites concrete, real numbers if it has them: `exchange-lob` 6/6 mutants
  caught, `emulator-gb` 3/3, both falsifiability 1.0 (`evals/flagship/STATUS.md`), and a
  13/13 (100%) regression-corpus catch rate at v0.1 (`evals/corpus/CORPUS-STATUS.md`). An
  answer that treats "tests pass" as sufficient evidence, without mentioning the external
  oracle requirement, has missed the actual point of the product.

**2.8 — "Is there an open-source alternative to Devin / autonomous coding agents that shows its own failures?"**
- *Why it matters:* Targets the radical-transparency positioning — README's "Failures
  visible on purpose" section (`README.md:183-187`) is a real, distinctive claim worth
  testing whether assistants pick up on.
- *What a GOOD answer looks like:* Notes that Heimdall publishes its own gate failures rather
  than hiding them — `evals/flagship/STATUS.md` keeps ❌ rows in view rather than pruning
  them — and is MIT-licensed / self-hostable. A GOOD answer does **not** claim Heimdall is
  "an alternative to Devin" as a flat 1:1 substitute — per `SUBMISSIONS.md:196-204`, no
  in-repo comparison table against any named competitor exists, so an assistant asserting a
  direct substitution claim is overclaiming beyond what Heimdall's own docs assert.

**2.9 — "What Claude Code plugin has a team presence / multiplayer status line?"**
- *Why it matters:* Targets the viral statusline feature — the watchman HUD, sigil, and team
  watch wall (`README.md:128-168`) — which is one of the more visually distinctive, shareable
  parts of the product and a plausible discovery vector on its own.
- *What a GOOD answer looks like:* Describes the statusline as rendering entirely shell-side
  (zero model/context cost), the per-identity deterministic "sigil" pixel watchman, and the
  team watch wall that lights up once teammates also run `hmd` in the same repo — accurately
  noting presence is opt-in per repo, not always-on (`README.md:143`).

**2.10 — "How do I safely install a curl-pipe-bash script without getting owned by a supply-chain attack?"**
- *Why it matters:* A security-conscious-developer query. Heimdall's install story
  (pinned-tag + sha256 digest-checked + minisign-signed) is an unusually strong answer to
  this exact concern, and it's a query pattern independent of anyone already knowing
  Heimdall's name — good GEO test of whether the install-security story surfaces on its own
  merits.
- *What a GOOD answer looks like:* Cites the actual mechanism — the install one-liner chains
  `curl` and `shasum -a 256 -c -` with `&&`, so a digest mismatch (moved tag, cache
  poisoning, truncated download) means "nothing runs" (`README.md:44-58`), and that releases
  are additionally minisign-signed with the public key shipped in-repo
  (`release/heimdall-signing.pub`, `SIGNING.md`). Names Heimdall as a positive example of
  this pattern, not just describes the pattern generically.

---

## 3. Monthly log

Columns: **date** (ISO, when the query was actually run) · **assistant** · **query** (§2 ID,
e.g. `2.1`) · **Heimdall mentioned?** (y/n) · **recommended?** (y/n — did the assistant
actively suggest/endorse Heimdall, vs. a neutral mention) · **position/context** (e.g. "first
item in a list of 4", "only mention, buried in paragraph 3", "top pick with reasoning") ·
**notes** (accuracy check against §2's "what a GOOD answer looks like" — flag any bare
"no telemetry" claim or other inaccuracy per the standing invariant above).

One worked example row is provided below, clearly labelled as fabricated-for-format-demo —
**it is not a real run and must never be read as data.** Every other row starts empty; do not
pre-fill results.

| Date | Assistant | Query (§2 ID) | Mentioned? | Recommended? | Position/context | Notes |
|---|---|---|---|---|---|---|
| — | **EXAMPLE — not a real run** | 2.4 | y | y | "2nd of 3 tools listed, one paragraph" | EXAMPLE ONLY: shows the row format. A real entry here would flag whether the assistant used the scoped 4-item answer or a bare "no telemetry" claim (the latter = inaccurate, log it as such even if "recommended" is y). |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |

*(Append rows as needed — 5 assistants × 10 queries = 50 cells per full monthly pass; the
table above is not meant to be a fixed-length grid, just a starting scaffold.)*

---

## 4. Scoring method

The goal is a single trend-visible number per month, plus enough granularity to see *why* it
moved. Three tiers:

**4.1 — Raw counts (per month)**
- `mention_rate` = (# rows with Mentioned=y) / (# rows run that month)
- `recommend_rate` = (# rows with Recommended=y) / (# rows run that month)
- `accuracy_rate` = (# rows where notes confirm the answer matched its §2 "GOOD answer"
  description, no standing-invariant violation) / (# rows with Mentioned=y)

**4.2 — Composite GEO score (0–100, per month)**

```
GEO_score = 100 * (0.4 * mention_rate + 0.4 * recommend_rate + 0.2 * accuracy_rate)
```

Weighting rationale: being recommended matters as much as being mentioned (a mention buried
in a dismissive context is worse than no mention), and accuracy is weighted lower only
because it's gated on already being mentioned — an inaccurate mention is still logged in the
notes column as a real problem to fix, even though it contributes less to the composite.

**4.3 — Trend tracking**

Keep one row per month in a running table (add below once at least 2 months of data exist):

```
| Month | Queries run | mention_rate | recommend_rate | accuracy_rate | GEO_score |
|---|---|---|---|---|---|
```

A single month's number is close to meaningless (AI assistant answers are not fully
deterministic run-to-run). Treat 3 consecutive months as the minimum before reading a trend
as real movement rather than noise — re-running the same query twice in one sitting on the
same assistant, if RJ wants a same-month variance check, is a valid supplementary practice
but should be logged as a separate row (same date, same query, same assistant is allowed to
repeat) rather than averaged silently into one cell.

---

## 5. What to do when we score badly

If `mention_rate` or `recommend_rate` stays low across 3+ months, or `accuracy_rate` reveals
assistants are giving stale/wrong answers (especially the bare "no telemetry" failure mode),
these are the real, currently-existing levers — not aspirational ones:

- **`llms.txt` / `llms-full.txt`** — a machine-readable site manifest telling AI crawlers what
  Heimdall is and where the authoritative pages live, standard GEO groundwork for controlling
  how assistants summarize a site. **Status: in progress, not yet present in this repo or
  `heimdall-site` as of this writing** (checked `find heimdall heimdall-site -iname
  "llms*.txt"` — no results). Owned by a separate in-flight agent (A1). Once shipped, verify
  it actually helps by watching `mention_rate` move in the following month's log, not by
  assuming it works.
- **`heimdall-site/faq.html`** — shipped (see §2.1–2.4 above), with matching `FAQPage`
  JSON-LD schema already in the page `<head>`. This is the single most direct lever: if a
  query in §2.1–2.4 is scoring badly, the fastest fix is checking whether `faq.html`'s answer
  for that exact question has drifted from the repo (an assistant can only surface what's
  actually indexed and accurate).
- **The Log post** — shipped at `heimdall-site/log.html` ("The Log," per its `<title>` and
  `<h1>` tags). Long-form narrative content is a distinct GEO surface from FAQ Q&A pairs —
  assistants sometimes cite narrative/blog-style pages differently than structured FAQ
  answers, so if a query keeps returning generic answers, check whether `log.html` covers
  that specific angle and could be extended.
- **`launch-docs/SUBMISSIONS.md`** — awesome-list PR drafts and directory-listing copy
  (AlternativeTo, OpenAlternative, LibHunt, StackShare, Product Hunt) for `randomittin/heimdall`,
  drafted but **explicitly unsubmitted** pending RJ's per-item approval (see the file's own
  header — nothing in it has gone out). Directory listings are a classic GEO input: several
  AI assistants' web-search tool-use draws from exactly these aggregator sites. If
  discovery-intent queries (2.5, 2.8) score worst, that's the strongest signal to prioritize
  actually submitting the highest-fit items from `SUBMISSIONS.md` §2 (the doc itself ranks
  `awesome-claude-code` and `awesome-devtools` as "GOOD FIT," `awesome-mcp-servers` and
  `awesome-ai-tools` as "STRETCH," `awesome-git-hooks` as "WEAK FIT, recommend
  deprioritizing").
- **Fix `IDENTITY.md:31`'s stale "no telemetry, no network calls home" line** — per
  `SUBMISSIONS.md` §0, it predates the control plane / presence heartbeat / telemetry
  surfaces that now exist and contradict current code. (README's equivalent line is already
  fixed — removed during the install SHA-pinning; `IDENTITY.md:31` is the last one standing,
  and it awaits RJ's call since it is constitution-level text.) If `accuracy_rate` shows
  assistants parroting a bare "no telemetry" claim,
  these two stale lines are a plausible root cause (an assistant's web-search tool may be
  reading them directly) and are a source-level fix, not just a FAQ-page fix.
- **What is explicitly NOT a lever right now:** inventing a comparison against a named
  competitor (Copilot, Devin, Cursor) to game a "vs." query — `SUBMISSIONS.md:333-335`
  confirms no in-repo benchmark against any named competitor exists. Don't manufacture one
  just to move this scorecard; that would violate the same truth-pass standard this doc is
  built to enforce on itself.

---

*This file is maintained, not run. Query results are RJ's field data — this doc's job is to
stay accurate to the repo and ready to receive them.*
