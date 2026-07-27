# Heimdall — Website Spec v2 (for the Claude Design agent)

**This revises the live site at runheimdall.dev.** The page already gets the big things right (verification thesis leads, caveman is correctly demoted to "optional companions"). This spec fixes three problems and adds one page: (1) the page is too dense — it proves everything on one scroll, with the same points repeated 3x; (2) stale/synthetic numbers contradict reality; (3) there's no page that sharply answers "why Heimdall vs the 20 other agent tools."

**Design language: Linear.** Minimal, sharp typography, generous whitespace, restrained color, fast, everything in service of clarity. No decorative illustration — typography and precise UI elements carry it. The terminal/gate-readout motif stays (it's on-brand and Linear-compatible: monospace blocks are precise, not decorative). The aesthetic should say "serious infrastructure tool" through restraint, not through ornament.

**Three pages:** Landing (the pitch) - Capabilities (what makes it unique) - Proof (the rigor). Plus fix the data errors throughout.

---

## FIRST — data corrections (do these regardless of redesign; the page's own thesis is "honesty is the brand," so wrong numbers undercut everything)
- **Version: the page says v2.0.0 everywhere; the current release is v2.0.5.** The install one-liner pins v2.0.0 — which ships users a version predating most of what's built (SI primitives, designmatch v2, onboarding, Redum, AND a critical launcher fix). Update ALL version references and the install command to the current release tag. This is a real stale-install bug, not cosmetic.
- **Commit count: the self-scan example cites "1,284 commits"; the actual repo is ~356.** Reconcile to the real number (or make it generic — "full history"). Synthetic numbers on an honesty-branded page are self-defeating.
- Audit every hard number against reality before publishing. If a number can't be verified, make it qualitative.

---

## PAGE 1 — LANDING (the pitch, skimmable in one scroll)
The job: a skeptical engineer gets "what is this, does it work, why should I care, how do I install" in one fast scroll. Move the deep proof OFF this page (to Proof). Kill the repetition (see below).

Sections, in order:
1. **Hero** — thesis ("Nothing ships unproven") + one-line subhead (verification gates for AI coding agents; the work can't grade its own homework) + the GENERALIZES receipt as a single confident line ("Tested on 8 cold repos - 0.50 median reuse - 8/10 working-output - pre-committed rubric") that **links to the Proof page** rather than expanding inline. Primary CTA: install (correct version).
2. **How it works** — the verification thesis in 3 beats, stated ONCE: external falsifiable oracle per plan - merge blocked until proven - prove-with-tools-reason-with-the-model. (Currently this idea is restated 3x across the page — say it once, here.)
3. **Why Heimdall (the comparison section — NEW, see below)** — the at-a-glance "things only Heimdall does vs typical agent tooling." Links to the full Capabilities page.
4. **The gate suite** — condensed grid (secrets / correctness / hygiene / composition), one line each. Not the current sprawl. Links to Capabilities for detail.
5. **Install** — the one-liner (correct version), repo link, MIT, "read it before you run it" (condensed to 2-3 lines, not its own large section).
6. **Footer** — watchman line, repo, license.

**Cut from landing (moves to Proof):** the full GENERALIZES narrative, the self-scan-blocks-a-key demonstration, the "watch a gate go red" demo, the "one door that can't be bypassed" deep-dive. These are the *rigor* — they belong where people who clicked "see the proof" expect density.

## The comparison section (on Landing) — "Why Heimdall"
A clean, Linear-style comparison: **what Heimdall does that typical AI agent tooling doesn't.** NOT a feature-bashing competitor table — an honest "here's what's different" framing. The axis is "most agent tools generate code and claim done; Heimdall proves it and does things no other agent tool does." Candidate rows (pick the sharpest 5-6):
- **Verification gates that can't be bypassed** — most tools have no merge gate; Heimdall blocks the push at the git layer, even on --no-verify.
- **The work can't grade its own homework** — external falsifiable oracle vs. the model self-assessing.
- **Visual-parity gating (designmatch)** — score an RN build against its design canonical. No other agent tool does this.
- **Measured generalization** — published a GENERALIZES verdict on a pre-committed rubric. Others claim; Heimdall measured.
- **Bypass-proof secret + identity scanning** — full-history, native git hook.
- **Reuse over reinvention** — measurably reuses existing code instead of regenerating it.
Keep it tight, scannable, Linear-clean. Each row links into the Capabilities page for depth. End with a CTA to the full Capabilities page.

## PAGE 2 — CAPABILITIES (NEW — what makes Heimdall unique)
**This is the strategic page.** "AI coding agent" is a crowded category; this page is what converts "another agent wrapper" into "this does things the others can't." Lay out the full capability set, grouped, each with what it is + why it's distinctive. Linear aesthetic — structured, scannable, generous whitespace, sharp section headers.

Group the capabilities (every one is a shipping binary unless marked):
- **Verification & gates** — the falsifiable oracle, the gate suite (secret-scan, oracle/falsify perfect-1.0 assertion gates, corpus regression, bloat-gate, parallel-gate, lint/test gates, conflict-reflection, code-review verdict), the bypass-proof pre-push hook. The thing that defines Heimdall.
- **designmatch** — visual-parity gating for React Native: regenerate-not-retrofit pipeline, hash-log change-detection, AST behavioral-diff (does the new screen still DO what the old one did, not just look like it), dual-gate release (visual SSIM + behavioral both pass), language-pluggable (RN now). Genuinely unique — explain it properly, it's a strong differentiator.
- **Debloat** — detects and (v2, coming) proposes-and-performs the cut, not just flags dead code.
- **The reuse engine** — reuses existing internals instead of reinventing; measured to generalize on cold repos (link to Proof).
- **Redum (redundancy solver)** — catches when the same module is being built twice under different names; fixes reinvention before it lands. (Just shipped — present it.)
- **Checker (assurance levels)** — none/basic/max verification depth, including cross-author semantic equivalence (same thing, different names, caught).
- **Team mode** — hmd --team N: spawn N parallel Claude workers on one task, wave-grouped, with parallel-safety gates and (coming) shared state + conflict awareness for multiple humans on one project. The multi-agent orchestration story.
- **14+ specialist agents** — architect, coder, reviewer, verifier, security-auditor, fixer — wave-grouped parallel execution.
- **Observability** — terminal-native HUD statusline + end-of-run summary (the watchman instrument).
- **(Coming, fenced honestly) Autonomous issue-resolution** — connects to Slack/GitHub/email, works a backlog, proposes verified fixes, human approves merge. Mark as roadmap, not shipped.

Make the **team/multi-agent features** prominent — that's a capability axis most single-agent tools don't have, and RJ wants it featured. Each capability: what it does, why it's distinctive vs. typical tooling, the CLI/command if applicable.

## PAGE 3 — PROOF (the rigor, for the self-selected)
Everything cut from the landing's proof-heavy sections lives here, with room to be as dense as it wants. The people who clicked "see the proof" came for exactly this.
- **The GENERALIZES story, in full** — 8 cold repos, JS/TS/Python, reuse-friendly-but-not-gimme tasks, the frozen pre-committed rubric (R>=0.45 / W>=7 / B<=2 thresholds locked before the run), verdict GENERALIZES (R=0.50, W=8/10, B=1). The honesty beat: the run surfaced and FIXED its own measurement bugs (missing toolchains, a buggy assertion) before reporting, rather than passing quietly — measured, not tuned.
- **The self-scan-scans-its-own-history demo** — the synthetic-key block (label it synthetic/development, no real exposure), the bypass-proof full-history scan.
- **"Watch a gate go red"** — the staged deny->fix->pass demo (hmd demo).
- **The one door that can't be bypassed** — the native pre-push hook deep-dive: agents commit --no-verify, pre-commit doesn't fire, so the real net is at the git layer on every push.
- This page is allowed to be dense and technical — that's its job.

## De-duplication (the readability fix)
The current page says the same things 3x. Consolidate:
- **Self-scan / bypass-proof / --no-verify** appears in THREE sections ("It proves itself," "The one door that can't be bypassed," gate-suite). -> Say it ONCE in full on the Proof page; a single one-line teaser on Landing linking there.
- **"Every gate can fail / a check that can't go red proves nothing"** appears 3x. -> Say it once (it's a good line — use it once, on Landing's how-it-works or as the Proof page's thesis).
- Each idea earns one home. Repetition reads as padding and is what makes the page feel heavy.

## Boundaries
- **Linear aesthetic** — minimal, typographic, whitespace-generous, restrained color, fast. No decorative illustration (the cute-character direction fights the brand; Linear carries it on type + precise UI). Keep the monospace gate-readout motif — it's precise, on-brand, Linear-compatible.
- **Fix the version + commit numbers** — non-negotiable, the install one-liner currently ships a stale pre-fix version.
- **Don't inflate** — 0.50 / 8/10 / pre-committed rubric, real commit count. The honesty IS the brand; an exaggerated claim on a "nothing ships unproven" page is self-defeating.
- **Comparison is honest, not competitor-bashing** — "here's what's different," not "tool X is bad."
- **Fenced roadmap stays fenced** — the coming features (team shared-state, debloat-v2, issue-loop) clearly marked not-shipped.
- **Keep the watchman identity** — established brand; the redesign changes structure + density + polish, not the core identity.

## The strategic point
The landing page proves Heimdall *works*; the Capabilities page proves it's *different*; the Proof page proves it's *rigorous*. Right now all three are crammed onto one dense scroll that forces everyone through the rigor whether they want it or not. Splitting them — Linear-clean — lets a skimmer get the pitch fast, a skeptic dig into the proof, and an evaluator see the unique capabilities that separate Heimdall from the crowded agent-tooling field. The Capabilities page is the one that answers "why this and not the other twenty," which is the question the current site doesn't sharply answer.
