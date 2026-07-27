# Heimdall — VIRAL NOW: the battle-test cohort + the launch chain (action plan, not a spec)

**The honest premise:** the virality machinery is built or specced (badge, clip, audit-on-init, demo, Layer 0, SEO/GEO, submissions). What stands between "stable" and "viral" is not another build — it is: (1) the 41 commits reaching origin, (2) the launch chain that has been open for ~9 days, (3) real teams using team mode so triage gets battle-tested and the corpus starts filling with OTHER people's runs. This doc is the execution plan for exactly that.

## Step 1 — Ship what exists (today)
`git log origin/main..HEAD` → 41 → branch=main check → `release/ship.sh`. This publishes the Release, npm, and pushes the auto-update to every install. Then the standing Session 1: deploy (`go-live.sh`) → posture flip (hmd's env line) → live isolation test (5 checks). Nothing downstream moves without this.

## Step 2 — The Founding Cohort (the battle-test; weeks 1–2)
**Goal:** 3–5 real teams (10–25 devs total) running team mode daily, feeding the corpus, breaking triage in ways synthetic tests can't.
- **Recruit:** your own team on the private work repos (Phase 2 doubles as cohort team #1) + 2–4 warm teams (friends' startups, devs from your network shipping with Claude Code/Cursor). The pitch is one sentence + the wall GIF once it exists: "install once, see your team's watchmen; tell me what breaks."
- **The deal, explicit:** they get white-glove support (you + hmd fix their issues with priority) — you get their PMR telemetry (T0 default) + the T1 hunks opt-in pitch ("opted-in repos get their failure classes turned into gates first") + brutal honesty. Write it as 5 lines they agree to; consent posture matters.
- **The feedback loop, instrumented not vibes:** `hmd feedback` (one-line + auto-attached receipt context — the Phase-4 feedback skill, build it now, it's small) · GitHub Discussions as the public triage board (indexed = SEO; answered = docs) · a weekly cohort note from you (what broke, what shipped — the learned-changelog fed by THEIR runs, which is the flywheel's first real turn).
- **What "battle-tested triage" means, concretely — the checklist to fill during the cohort:** a real semantic-conflict deny on a shared repo · a real redum consolidation across two devs · a false-positive gate report → tuned → falsifier added · a presence bug found by a non-RJ machine · one full chat-ops investigate on a cohort repo (once P2 lands) · at least 3 learned-rules shipped FROM cohort cases. Each item checked = a receipt for the launch post.

## Step 3 — Collecting other people's runs & fixes (the corpus goes live)
- PMR T0 emission must be in the shipped build (execute-now #4 — confirm it's in the 41; if not, it's the next merge). The cohort is its first real data.
- The case→rule loop runs manually at cohort scale: weekly, hmd clusters the cohort's deny cases → proposes 1–3 rules → you review → ship in the weekly release, credited ("this rule exists because team X hit Y"). Automation (shadow gates) comes later; the manual loop NOW proves the story and produces the content.
- Public artifact from week 2: the first "what the watchman learned" post with real numbers from real teams (anonymized per k-rule — cohort is <20 teams, so aggregate carefully or get explicit named consent).

## Step 4 — The launch stack (unchanged order, now with receipts)
Phase 2 GIF → the three staged branches merge (truth-pass, readme-launch, site-sync) with the teams release → versions unified → funnel live (Δ6 gate) → **HN** ("Show HN: verification gates for AI coding agents — here's what 5 teams' watchmen caught in 2 weeks" — the cohort receipts make the post) → Product Hunt + the staggered tool-community waves as L0/L1 land → submissions from SUBMISSIONS.md → badge + clip in every adopting repo's hands.

## What runs in parallel vs what blocks
- **Blocks everything:** Step 1 (push + deploy + flip + isolation). One session.
- **Parallel tracks after that:** cohort (you recruiting, ~2h) ∥ chat-ops P1–P2 (hmd) ∥ Layer 0 if not yet landed (hmd) ∥ submissions/SEO sessions (runbook 2–4).
- **The launch date is set by:** GIF + cohort week-2 receipts + the staged branches merging. Realistic: HN inside 3 weeks of Step 1 happening.

## The one-line version
Push, deploy, flip, test with humans, put 3–5 real teams on it for two weeks while the corpus fills, then launch with their receipts. Everything else is already in a spec.
