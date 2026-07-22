# Skills Scout — Newly-Released Official Anthropic Skills → Heimdall Incorporation

**Branch:** `skills-scout-report2`  ·  **Base sha:** `7ea54ea`  ·  **Author:** scout agent
**Status:** ENRICHED — skeleton committed from LOCAL evidence, then web-verified against official Anthropic sources (network was reachable).
**Truth-pass:** every capability below is cited to a LOCAL file path or an official Anthropic URL. Nothing from memory. Anything not established from evidence is marked **UNVERIFIED / cannot establish** and NOT guessed.

---

## 0. TL;DR — the honest headline

- **"focus" IS REAL and CONFIRMED.** It is **Claude Code "focus mode"**, toggled by the **`/focus`** slash command — a *transcript display mode*, not a plugin/skill. Introduced in **Claude Code 2.1.110** (official `anthropics/claude-code` CHANGELOG). It is already available in RJ's installed **2.1.212**. Focus mode collapses in-turn activity so the user sees **only Claude's final message**; subagents/background work fold into an activity summary. See §6 for exact cited lines and the Heimdall wiring in §3 (#3).
- **"ghost" — CANNOT ESTABLISH. It is not an Anthropic capability by any evidence I have.** No `ghost` skill/plugin in the installed manifest, the 37 first-party Anthropic plugins, the 400KB+ catalog cache, OR the official `anthropics/skills` repo. In the official Claude Code CHANGELOG the only `ghost` hits are **"Ghostty"** (a third-party terminal emulator) and bug fixes for **"ghost frames/characters"** (rendering artifacts) — neither is a feature. **Needs RJ confirmation** (§5).
- What ELSE is genuinely new and official and maps cleanly onto Heimdall: from the marketplace (Anthropic-authored, **uninstalled**) — **code-simplifier**, **hookify**, code-modernization; from the official **`anthropics/skills`** repo — **webapp-testing** (HIGH fit → verifier), **doc-coauthoring** (→ docs-writer). All cited (local marketplace.json/SKILL.md + GitHub). Rank-ordered in §2–§3.

---

## 1. Evidence base (LOCAL — no network)

| Source | Path | What it gave |
|---|---|---|
| Installed plugins | `~/.claude/plugins/installed_plugins.json` | 14 installed: playwright, claude-md-management, ralph-loop, code-review, security-guidance, slack, claude-code-setup, pr-review-toolkit, skill-creator, frontend-design, claude-mem@thedotmack, caveman, superpowers, design-for-ai@rtd |
| Known marketplaces | `~/.claude/plugins/known_marketplaces.json` | official = `anthropics/claude-plugins-official` (updated 2026-07-22); plus rtd, caveman, thedotmack, claude-code-workflows |
| First-party plugin list | `~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json` | 37 Anthropic-authored plugins in `plugins/` |
| Catalog cache | `~/.claude/plugins/plugin-catalog-cache.json` (406KB) | full third-party catalog; grepped for ghost/focus |
| Installed skills dir | `~/.claude/skills/` | only `ui-ux-pro-max` |
| Claude Code version | `claude --version` | **2.1.212** |

**Search results for the two named targets:**
- `grep -i ghost` over catalog cache + marketplace tree → **0 hits.**
- `grep -i focus` → only descriptive prose (`code-simplifier` "Focuses on recently modified code"; `forge-skills` "Forge-focused"; a Lovable plugin "focused commands"). **No skill/plugin named focus.**

**Claude Code 2.1.212 CLI surface (from `claude --help`):** skills resolve via `/skill-name`; `--plugin-dir`, `--plugin-url`, `--bare` flags exist. No dedicated `claude skills list` subcommand surfaced in help output that names official skills.

---

## 2. Newly-available official Anthropic plugins (established locally) → fit table

All authorship = **Anthropic** per `marketplace.json` `author.name` (verified locally), except superpowers (community, hosted in official mktplace).

| Skill/plugin | What it is (cited local source) | Installed? | Heimdall incorporation point | Fit | Confidence |
|---|---|---|---|---|---|
| **code-simplifier** | "Agent that simplifies and refines code for clarity, consistency, and maintainability while preserving functionality. Focuses on recently modified code." (`marketplace.json`) | NO | Post-coder / pre-reviewer quality gate; complements existing `bin/bloat-gate` + `/simplify`. Wire into `agents/reviewer.md` or a wave post-step. | **HIGH** | confirmed (local) |
| **code-modernization** | "Modernize legacy codebases (COBOL, legacy Java/C++, monolith web apps) with a structured preflight/assess/map/extract…" (`marketplace.json`) | NO | Niche; only when task = legacy migration. Could be an on-demand skill `hmd:architect` detects. | LOW | confirmed (local) |
| **hookify** | "Easily create custom hooks to prevent unwanted behaviors by analyzing conversation patterns or from explicit instructions." (`marketplace.json`) | NO | Directly maps to `hooks/hooks.json` authoring — could accelerate new Heimdall guard hooks (edit-tracker, git-guard pattern). | MED | confirmed (local) |
| **session-report** | "Generate an explorable HTML report of Claude Code session usage — tokens, cache, subagents, skills, expensive prompts — from `~/.claude/projects` transcripts." (`SKILL.md`) | NO | Overlaps Heimdall's own `bin/receipts`?/`heimdall-*` telemetry + `hmd:save` checkpoint. Likely **REDUNDANT** — verify against existing. | LOW/skip | confirmed (local) |
| **receipts** | "Personal Claude Code impact report… mines `~/.claude/projects` locally, cross-references git history, writes markdown+HTML." (`SKILL.md`) | NO | Overlaps Heimdall claim-ledger / attest surfaces (`bin/heimdall-attest`, `.planning/ledger`). Likely **REDUNDANT**. | skip | confirmed (local) |
| **project-artifact** | "Generate and publish a living project status page — overview & success criteria, workstream sequence, next steps." (`marketplace.json`) | NO | Maps to `.planning/` state files + STATE.md/CHECKPOINT.md. Overlaps `hmd:save`. | LOW | confirmed (local) |
| **claude-code-setup** | "Analyze codebases and recommend tailored Claude Code automations (hooks, skills, MCP, subagents)." (`marketplace.json`) | **YES** (installed) | Already available; `skills/…/claude-automation-recommender/SKILL.md`. | n/a | confirmed (local) |
| **webapp-testing** (skills repo) | "Toolkit for interacting with and testing local web applications using Playwright… verifying frontend functionality, debugging UI behavior, capturing browser screenshots, and viewing browser logs." (`anthropics/skills` SKILL.md) | NO | **Verification-first bullseye.** Wire into `agents/verifier.md` / `hmd:test-runner` to *drive the real app*, not just run unit tests — matches the built-in `/verify` and `/run` skills' intent. | **HIGH** | confirmed (web) |
| **doc-coauthoring** (skills repo) | "Structured workflow for co-authoring documentation… Context Gathering, Refinement & Structure, Reader Testing." (`anthropics/skills` SKILL.md) | NO | Maps to `agents/docs-writer.md`. | MED | confirmed (web) |
| **`/focus` — focus mode** (CC feature) | Transcript display mode; `/focus` toggles it. "Claude now writes more self-contained summaries since it knows you only see its final message." (CC CHANGELOG 2.1.101/2.1.110/2.1.198) | **Built-in** (2.1.110+; RJ on 2.1.212) | Not installable — it's a display mode. Heimdall adaptation in §3 (#3): make agent *final messages* self-contained given users may run in focus mode. | **MED-HIGH** | confirmed (web) |

> Install command (do NOT run): `claude plugins install <name>@claude-plugins-official` (marketplace plugins) or add the `anthropics/skills` repo. NOTHING installed by this scout. `/focus` is built-in — nothing to install.

---

## 3. Prioritized "incorporate next" — top 3 (SKELETON wiring; enriched below if network reachable)

### #1 — code-simplifier → post-implementation quality gate (HIGH fit)
- **Why it fits Heimdall's north star:** verification-first + truth-pass. Heimdall already runs `bin/bloat-gate` and a `/simplify` pass; an Anthropic-authored simplifier that targets *recently modified code* is a natural pre-`reviewer` step in a wave.
- **Wiring surface:** `agents/reviewer.md` (or `agents/lint-quality.md`) invokes it; or `hooks/hooks.json` PostToolUse after coder edits; cross-checked by `skills/heimdall/references/definition-of-done.md`.
- **Conflict check:** must stay truth-pass (no fabricated "simplified" claims); must not publish. Redundancy risk vs existing `bin/bloat-gate` — needs a diff of scope.

### #2 — hookify → author new Heimdall guard hooks (MED fit)
- **Why:** Heimdall's guardrails ARE hooks (`edit-tracker`, git-guard, statusline). hookify turns "prevent behavior X" into a hook automatically → faster hardening.
- **Wiring surface:** `hooks/hooks.json`, `hooks/git/`.
- **Conflict check:** generated hooks must respect R1–R9 (`.planning/conventions.md`) and never add telemetry/publish.

### #3 — focus mode (`/focus`) → make agent final messages self-contained (MED-HIGH fit)
- **Why it fits:** focus mode is CONFIRMED shipped and available to RJ (2.1.212). When a user runs Heimdall in focus mode they see **only the final message** of each turn — all the wave/agent activity is folded away. This directly rewards Heimdall's existing "lead with the outcome, self-contained summary" discipline. CHANGELOG 2.1.101: *"Claude now writes more self-contained summaries since it knows you only see its final message."*
- **Wiring surface:** the orchestrator/agent final-report convention (`agents/heimdall.md`, `agents/*.md` final-message guidance) + `hooks/statusline.sh` / `hooks/subagent-statusline.sh` (which already surface sub-agent activity that focus mode collapses). Ensure each wave's terminal message stands alone (what shipped, what's verified) without relying on the collapsed transcript.
- **Conflict check:** none — this is display-side and tightens an existing convention. No install, no telemetry, no publish. Stays truth-pass.

### Bonus #4 — webapp-testing → verifier drives the real app (HIGH fit, see §2)
- **Wiring surface:** `agents/verifier.md` + `evals/oracles/*` — replace/augment "tests pass" with "app behavior observed via Playwright". Aligns with the built-in `/verify` skill and Heimdall's falsifiable-oracle north star. Redundancy check vs existing `hmd:designmatch` (already Playwright-based) needed before adopting.

---

## 4. Redundancy / "already have it" notes
- **session-report, receipts, project-artifact** all re-derive session/usage/status reporting that Heimdall already owns via its own `bin/heimdall-*` telemetry, `.planning/ledger`, claim-ledger, and `hmd:save`. Adopting them risks duplicate surfaces. Default = **skip** unless a specific gap is shown.
- **code-review, pr-review-toolkit, security-guidance** already installed AND Heimdall has its own `agents/reviewer.md`, `agents/security-auditor.md`, `bin/authenticity-check`, `bin/falsify`. No action.

---

## 5. COULD NOT ESTABLISH — needs RJ confirmation (LOUD)

**"focus" — RESOLVED** (see §0/§6): it is Claude Code **focus mode / `/focus`**, confirmed and cited. No longer open.

**"ghost" — STILL CANNOT ESTABLISH.** No Anthropic skill/plugin/feature named "ghost" exists in ANY source I checked:
- installed plugins manifest — no match
- 37 first-party Anthropic marketplace plugins — no match
- 406KB `plugin-catalog-cache.json` (full third-party catalog) — no match
- official `anthropics/skills` repo (17 skills) — no match
- official Claude Code CHANGELOG — only **"Ghostty"** (third-party terminal emulator) and **"ghost frames"/"ghost characters"** (rendering-bug fixes). Neither is a capability.

To resolve I need ONE of, from RJ:
1. The exact surface where RJ saw "ghost" (URL, changelog line, a `/command`, plugin name, screenshot).
2. Confirmation it's a codename/paraphrase + the rough capability RJ associates with it, so I can search official docs/changelog for the real name.
3. Whether "ghost" might be **"Ghostty"** (terminal) or a non-Anthropic tool RJ conflated.

I refuse to assert any "ghost" capability without this — a confident fabrication here is exactly the failure this task guards against.

---

## 6. Web enrichment status — REACHABLE, verified against official Anthropic sources

Sources fetched (official only): `anthropics/claude-code` CHANGELOG.md, `anthropics/skills` GitHub repo (contents API + raw SKILL.md).

### focus mode / `/focus` — CONFIRMED (Claude Code CHANGELOG, official)
Exact cited lines from `raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`:
- **2.1.110:** "Changed `Ctrl+O` to toggle between normal and verbose transcript only; **focus view is now toggled separately with the new `/focus` command**." → this is when `/focus` shipped.
- **2.1.101:** "Improved focus mode: **Claude now writes more self-contained summaries since it knows you only see its final message.**"
- **2.1.198:** "Improved focus mode: **subagents launched in a turn now appear in its activity summary**, and completed background notifications fold into a single count."
- **2.1.208-era (line 530):** ongoing focus-mode refinements — still actively maintained.
- RJ's installed CC = **2.1.212** → focus mode + `/focus` are present.

**What focus mode IS (cited):** a transcript *display* mode. When on, the user sees only Claude's final message per turn; intermediate tool calls / subagent activity collapse into an activity summary. It is NOT a plugin or skill — nothing to install.

**Heimdall relevance:** rewards self-contained final messages (already a Heimdall convention) and clean sub-agent activity summaries (Heimdall's statusline hooks). Wiring in §3 (#3).

### ghost — searched, NOT FOUND (see §5). Only "Ghostty" (terminal) + "ghost frames/characters" (bug fixes) in CHANGELOG.

### official `anthropics/skills` repo (17 skills, contents API)
Full list: algorithmic-art, brand-guidelines, canvas-design, claude-api, **doc-coauthoring**, docx, frontend-design, internal-comms, mcp-builder, pdf, pptx, skill-creator, slack-gif-creator, theme-factory, **web-artifacts-builder**, **webapp-testing**, xlsx.
- Heimdall-relevant new ones pulled into §2: **webapp-testing** (verifier), **doc-coauthoring** (docs-writer). Others are design/office-doc skills (lower fit; overlap `ui-ux-pro-max`, `hmd:designmatch`).

### Network resilience note
Skeleton (commit `562f2a8`) was committed from local evidence BEFORE any fetch, per the anti-ENOTFOUND mandate. All web calls used `curl -m 12`; a failure would have left the committed skeleton intact.
