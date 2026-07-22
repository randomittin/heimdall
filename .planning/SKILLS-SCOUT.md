# Skills Scout — Newly-Released Official Anthropic Skills → Heimdall Incorporation

**Branch:** `skills-scout-report2`  ·  **Base sha:** `7ea54ea`  ·  **Author:** scout agent
**Status:** SKELETON committed from LOCAL evidence (network enrichment attempted after).
**Truth-pass:** every capability below is cited to a LOCAL file path or an official Anthropic URL. Nothing from memory. Anything not established from evidence is marked **UNVERIFIED / cannot establish** and NOT guessed.

---

## 0. TL;DR — the honest headline

- **"ghost"** and **"focus"** as *official Anthropic skill/plugin names*: **NOT FOUND in any local evidence.** Searched the installed plugins manifest, the 37 first-party Anthropic plugins in `claude-plugins-official`, and the full 400KB+ `plugin-catalog-cache.json`. Zero `ghost*` matches; every `focus` match is the plain English word ("Focuses on recently modified code", "Forge-focused", "focused commands") — not a product. **Cannot establish what RJ means by "ghost"/"focus" from local evidence — needs RJ confirmation** (see §5).
- What IS genuinely new and official (Anthropic-authored, sitting in the marketplace **uninstalled**) and maps cleanly onto Heimdall: **code-simplifier**, **code-modernization**, **hookify**, **session-report**, **receipts**, **project-artifact**, **claude-code-setup** (automation recommender). These are real (cited to local marketplace.json + SKILL.md) and rank-ordered in §2–§3.

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

> Install command (do NOT run): `claude plugins install <name>@claude-plugins-official`. NOTHING installed by this scout.

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

### #3 — TBD pending "ghost"/"focus" establishment OR code-modernization for legacy tasks.

---

## 4. Redundancy / "already have it" notes
- **session-report, receipts, project-artifact** all re-derive session/usage/status reporting that Heimdall already owns via its own `bin/heimdall-*` telemetry, `.planning/ledger`, claim-ledger, and `hmd:save`. Adopting them risks duplicate surfaces. Default = **skip** unless a specific gap is shown.
- **code-review, pr-review-toolkit, security-guidance** already installed AND Heimdall has its own `agents/reviewer.md`, `agents/security-auditor.md`, `bin/authenticity-check`, `bin/falsify`. No action.

---

## 5. COULD NOT ESTABLISH — needs RJ confirmation (LOUD)

**"ghost"** and **"focus"** — I could not find any official Anthropic skill/plugin/feature by these names in local evidence, and I must not invent them.

To resolve, I need ONE of:
1. The exact surface where RJ saw them (a URL, a changelog line, a `/command`, a plugin name, a screenshot).
2. Confirmation they are Claude Code *features* (not plugins) — e.g. a codename — so I can search official docs/changelog for the real name.
3. Permission to treat them as paraphrases and the rough capability RJ associates with each.

Candidate interpretations I refuse to assert without evidence (listed only to speed RJ's confirmation, NOT as findings):
- "ghost" → possibly "ghost text"/inline-suggestion or a background/hidden-agent feature — **UNVERIFIED.**
- "focus" → possibly a plan/focus mode or file-scoping feature — **UNVERIFIED.**

---

## 6. Web enrichment status
_Attempted after this skeleton was committed. Results appended below if network was reachable; otherwise marked UNREACHABLE._

<!-- WEB-ENRICHMENT-MARKER -->
