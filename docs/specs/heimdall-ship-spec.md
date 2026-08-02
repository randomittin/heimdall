# Heimdall — Ship Spec & Launch Planner (S-1…S-9 + L0/L1 playbook)

**Status:** Active — the post-signature arc · **Owner:** RJ · **Gate:** everything below is unblocked; sequence is the law.
**Standing rules carried forward:** gate code changes re-trigger corpus + falsify; goldens edits re-trigger BLIND-VERIFICATION; launches never batched; the delta is measured on Fable 5 or not published.

---

## PART 1 — Repo work to public-ready

### S-1. Rename wave: superx → Heimdall (1 day)
- Touches: bins, plugin manifest, hooks, agents, docs, statusline, install banner, repo name.
- **GitHub repo rename, not a fresh repo** — auto-redirects preserve stars/history/timestamps (the "building before X" receipt).
- Identity ships with it: README ¶1 = moving-bar thesis verbatim; tagline "Nothing ships unproven."; denial-stamp copy strings; slang (Bifröst closed / Gjallarhorn / passed the watchman) in product messages only — never explained, let users discover it.
- Domain per tonight's screen: GitHub org + npm scope are canonical; .sh/.run/getX acceptable web home; **no typo domains, ever**.
- Acceptance: clean install via `claude plugins install heimdall`; zero `superx` strings outside CHANGELOG/history (`grep -ri superx` ≈ historical refs only).

### S-2. Public-repo hygiene (0.5 day, same wave)
- `.planning/` gitignored except graduated files (conventions.md, GATE-REVIEW.md — each future graduation is a deliberate force-add).
- Scrub history check: no tokens/paths/personal data in tracked files (gitleaks one-shot over full history; it's already a gate going forward).
- LICENSE (MIT), CONTRIBUTING.md (stack-pack + oracle-pack templates as the contribution doors, good-first-issue labels pre-created), SECURITY.md, CODE_OF_CONDUCT.md.
- "What Heimdall will never do" README section: retired 2026-07-28 — the absolute "no telemetry, no network calls home" claim went FALSE when team presence/cloud features flipped default-ON (`IDENTITY.md:5`, scoped paragraph `IDENTITY.md:32-38`). Ship the scoped S1–S6 claim set instead (enforced by `test/truth-pass-claims.test.sh`), with `DATA.md` as the receipt; MIT, read the source.
- Install path: marketplace primary; `--auto` default; skip-permissions behind warned flag.
- Acceptance: a stranger's 5-minute path works — clone → install → `heimdall demo` (S-5) without reading more than the README's first screen.

### S-3. H-2 bloat gate + H-2ii debloat (4–5 days)
Per core spec. Launch-critical acceptance: **one real `heimdall debloat` PR on an actual RJ repo** (superx's own tree is a legitimate and poetic first target), suite green, before/after scorecard captured — that artifact is L2's hero image. `--report-only` is the zero-risk reply-guy command; verify it runs on a cold clone of a popular OSS repo without setup.

### S-4. H-5 visible layer (2–3 day timebox, hard)
City renderer (state→city mapping per spec), reel pipeline (asciinema→agg→MP4 auto per run), denial stamp (terminal + PR check), summary card. Timebox rule stands: charming by day 2 or ship the plain HUD and move on. Acceptance: one full run produces a shareable MP4 unattended.

### S-5. `heimdall demo` + `heimdall bench` (1 day)
- `demo`: 15-min canned run ending in summary card + reel + next-prompt suggestion.
- `bench`: reproduces the public table on the user's machine (the table that exists post-S-7).
- Acceptance: both run on a fresh machine with only the documented prerequisites.

### S-6. 4b generalization proofs (2–3 days) — BEFORE flagship hardening
1. **Mini-git oracle cold:** record harness reuse fraction (reused vs new LOC across gate contract / falsify / corpus machinery). Publish the number whatever it is. <30% reuse = stop and fix the harness before adding anything.
2. **Popular-surface 10, cold:** raw-CC vs Heimdall, tasks with zero fixtures in either arm. success@3, tokens, interventions, gate-self-recoveries.
3. Corpus intake from both → starts the v0.3 diversification clock (≥1/3 non-founding by v0.3).

### S-7. Fable-5 re-spike (1–2 days, wall-clock token burn)
Both arms (raw CC / Heimdall) × both flagships, on pinned `claude-fable-5`, success@3. **This produces every number L0/L1 may cite.** Outcome branches (pre-decided): delta persists → "even on the best model" headline; delta = gates-only → verification/proof headline; delta gone → corpus + generalization story leads. No old-model numbers survive into public copy.

### S-8. Flagship hardening (wall-clock)
Exchange to 9/10 cold-run pass on the live gate; golden-run snapshot; the kill-the-engine-live recovery beat rehearsed and recorded. The reel from the best run is L1's hero video.

### S-9. Launch assets freeze (0.5 day, the day before L0)
All in `evals/flagship/` or `/assets`: dip log (CORPUS-STATUS with 9/9→7/9→9/9), R-1 confession commit link, VERIFICATION.md + BLIND-VERIFICATION.md links, STATUS table current, bench table (S-7 numbers), debloat before/after, reel MP4, 3 screenshots (denial stamp / summary card / city). Nothing published that isn't reproducible by `heimdall bench` or linked to a commit.

---

## PART 2 — Launch planner (L0 + L1; L2/L3 cadence per master spec)

### Doctrine (one paragraph, re-read before posting)
Announce results, never machinery. Every claim links to a commit or a reproducible command. Publish the losses in the same table as the wins. The dip is the story, not the blemish. Respond to every substantive comment within hours for the full launch week — block the calendar like a fundraise.

### L0 — "The bar" (soft launch, Day 0 = repo-public day)

**Purpose:** plant the storyline + the receipts before any claim. Low-key by design.

**X thread (RJ's account), 6 tweets:**
1. Hook: "My AI agent's verification stack was green at every layer — 11/11 self-verified, 9/9 mutation-proofed, 100% corpus catch-rate. The reference data itself was wrong. A thread on how we caught it, and what we built so it can't happen again:"
2. The bug: F:10 vs F:20, the inverted H/C bits, screenshot of the golden diff. "Every layer inherited the same wrong byte from the same author."
3. The catch: adversarial review anchored to the Pan Docs — external source, not more self-checks. Link: R-1 confession commit.
4. The proof: 3-model blind consensus (GPT-5.5 / Gemini 3.5 / fresh Fable 5), unanimous, "the old value would have failed 3-0." Screenshot of VERIFICATION.md.
5. The dip: CORPUS-STATUS screenshot, 9/9 → 7/9 → 9/9. "A verification system that can't show you its own failures can't be trusted with yours."
6. The repo + the bar: link, status table with the ❌s visible, "here's where it still fails — watch us close it. Nothing ships unproven."

**Reddit (r/ClaudeAI, r/ClaudeCode), same day, longer-form:** the full incident write-up, framed as "I built a verification layer for Claude Code and it caught its own author — tear it apart." Invitation-to-criticize framing, not pitch.

**HN: do NOT Show HN at L0.** The repo isn't demo-ready for a cold stranger until S-3/S-5 land; HN gets one shot. L0 on HN at most as a comment in relevant agent threads if organic.

**Success metric for L0:** not stars — replies from 5+ credible devtools/agents people, and zero claims challenged without a receipt to answer with.

### L1 — Exchange flagship (Show HN, Day ~10–14, after S-7/S-8)

**Pre-flight checklist (all true or postpone):**
☐ flagship 9/10 cold ☐ bench table on Fable 5 only ☐ `heimdall bench` reproduces it ☐ demo works on fresh machine ☐ reel MP4 <90s ☐ first-comment drafted ☐ calendar blocked 5 days ☐ 5 pre-briefed reviewers have had the repo 72h (adjacent-tool authors; ask for brutal feedback, fix what they hit — they amplify on the day)

**Timing:** Tue/Wed/Thu, post 7:00–8:00pm IST (≈9:30–10:30am ET — HN's prime window). Avoid US holidays and major-model-release *days* (ride the week, not the hour).

**Title (pick per S-7 outcome):**
- Delta persists: "Show HN: One prompt → a working exchange. Raw Claude Code crossed the spread N times; the gate layer caught every one"
- Gates-only delta: "Show HN: Heimdall – verification gates for coding agents that caught their own author's bug"
- Fallback always available: "Show HN: I gave my coding agent a falsifiable verification layer. It immediately caught me."
Rules: no superlatives, no "revolutionary," lowercase honesty; the number in the title must be in the bench table.

**First comment (post immediately, it's the real README):** 1-para what it is (moving-bar thesis, compressed) · the bench table inline (wins AND losses, pinned model IDs) · the R-1 story in 3 sentences with commit links · "run it yourself: `heimdall bench` / `heimdall debloat --report-only` on your own repo" · known limitations list (timer hole, two-domain depth, generalization numbers from S-6 whatever they are) · what feedback you want.

**X thread, same hour:** reel MP4 first tweet (the city building the exchange overnight, the kill-and-recover beat) → bench table → install one-liner → QT chain to the L0 thread ("two weeks ago our golden was wrong; today the system it certified shipped this"). DM the reel to the 10 highest-signal Claude-Code posters with a one-line personal note, no ask.

**Engagement rules for the week:** answer everything substantive <2h daytime IST; concede valid criticism in-thread and open an issue live (link it in the reply — nothing disarms HN like a filed issue mid-thread); never argue tone; the tautology/false-green skeptics are your best commenters — they're the audience that becomes contributors; ship at least one fix from comments within 48h and reply "fixed in <sha>".

**The numbers you'll be asked for — have them ready:** token cost per flagship run; wall time; what happens without Anthropic access (answer: gates/corpus/bench are agent-agnostic, harness needs any CLI agent); why not just better prompts (answer: the R-1 incident — the prompt was fine, the reference was wrong, only external anchoring caught it); license/monetization (MIT, protocol open, maybe hosted team server later — NOT "no telemetry ever": that absolute claim was retired 2026-07-28 when presence flipped default-ON; the accurate answer is the scoped S1–S6 claim set / `DATA.md`).

**L2 (bloat, fast-follow ~Day 17) and L3 (teams, ~Day 30):** per master spec — L2 is X/Reddit-led with the before/after scorecard and the reply-guy command; L3 carries the R1-collision + R7-budget-death first-party incident write-ups as evidence. Cadence rule: a launch only fires when the previous one's issue queue is at zero-or-answered.

### Post-mortem rule
72h after each launch: one `.planning/` note — what was claimed, what was challenged, what was conceded, what shipped from feedback. Feeds the next launch's first comment. The corpus gets cases; the launch process gets the same flywheel.
