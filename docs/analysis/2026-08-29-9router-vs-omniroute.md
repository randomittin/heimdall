# 9router vs OmniRoute — is 9router better, for hmd's fallback gateway use case?

**Date:** 2026-08-29
**Task:** delta brief brief-1788014460-56074
**Scope:** research-only, no installs/clones/runs. Repo's live OmniRoute fallback gateway untouched.
**Verdict up front:** **NO — do not switch.** 9router is worse on every axis where the two differ, and a wash on the one axis the brief flagged as "close to decisive." OmniRoute's only real negatives (residual Host-header gap, CHANGEME default) are OmniRoute's own bugs that hmd already found and fixed — switching to 9router doesn't fix them, it inherits worse versions of them plus a materially worse CVE/advisory history, while forfeiting hmd's entire OmniRoute-specific operational investment. See §8 (verdict) for what would change this.

---

## Step 1 — identifying "9router"

Name is ambiguous on its face (candidates considered: networking/router hardware tool, JS routing library, generic "9" branding). Resolved via WebSearch/WebFetch:

- **`9router` = `github.com/decolua/9router`** — an open-source, self-hostable local LLM API gateway/proxy. Distributed as an npm package (`9router`) and as Docker images (Docker Hub / GHCR). MIT licensed.
- It is a genuine, comparable candidate: same problem space as OmniRoute — a local reverse proxy that normalizes multiple LLM provider backends behind OpenAI- and Anthropic-shaped endpoints for coding-agent consumption (Claude Code, Cursor, Codex, Cline, Copilot).
- **Load-bearing fact discovered mid-research, not in the brief: OmniRoute is a fork of 9router.** OmniRoute's own README "Acknowledgements" section states it is "a fork of `9router`" plus a TypeScript port of `CLIProxyAPI` (43.6k★ Go project). This reframes the whole comparison: this is not two independent competitors, it's **parent (9router) vs. a divergent, already-hardened fork (OmniRoute) that this repo has spent multiple audit cycles on.**

Given it's a genuine comparable candidate, proceeding to Step 2 rather than stopping.

---

## Step 2 — 8-axis comparison

Labels used throughout: **MEASURED** (I or a prior hmd audit directly observed/ran/read source), **READ-FROM-SOURCE** (confirmed by reading the project's own code/docs, not run), **MARKETING CLAIM** (project's own README/marketing assertion, unverified), **SECONDARY** (third-party summary, not primary-sourced).

### Axis 1 — self-hostable, loopback-bindable (127.0.0.1-only)

- **OmniRoute:** MEASURED loopback-only in this repo's live deployment (`127.0.0.1:20128`, confirmed via `lsof`/`netstat` across two independent audit passes — `docs/analysis/2026-08-25-omniroute-install.md`, `docs/analysis/2026-08-26-omniroute-gateway-start.md`). READ-FROM-SOURCE: `run-next.mjs` defaults `hostname` to `0.0.0.0` when `HOST` is unset — the loopback binding is an **operator-supplied config choice, not a code default**. hmd's launchd unit explicitly sets `HOST=127.0.0.1`.
- **9router:** self-hostable, same category. Its docs/Docker examples more prominently surface `0.0.0.0`-style bind paths for Docker/VPS deployment (READ-FROM-SOURCE, prior-turn finding) — i.e. the "safe by default" posture is *weaker*, not stronger, than OmniRoute's (which is also not safe-by-default, just operator-hardened here).
- **Verdict:** wash-to-slight-OmniRoute-edge. Neither is loopback-safe by default; this repo has already done the hardening work for OmniRoute specifically.

### Axis 2 — credential isolation (Claude/claude-web subscription repurposing risk)

- **OmniRoute:** READ-FROM-SOURCE + MEASURED (`docs/analysis/2026-08-25-omniroute-install.md` §2, `docs/analysis/2026-08-25-omniroute-credential-isolation.md`). Mitigation structurally holds — no automatic/silent import of Claude Code credentials — but is **defeatable by anyone who authenticates to the management plane**: `POST /api/providers/claude-auth/import` lets an authenticated operator create a `claude`/`claude-web` `provider_connections` row and flip Tier-1 fallback live, no restart required. The single point of failure is the management password.
- **9router:** equivalent-shape risk (OAuth provider-connection pattern for Claude Code), but the surface defending it is **objectively weaker**: default management password is `123456` (vs OmniRoute's `CHANGEME` — both bad defaults, but 9router's dashboard additionally lacks CSRF protection on general routes and uses non-revocable 24-hour sessions (SECONDARY, StationX-style third-party security summary; not independently re-verified by reading 9router source this session, flagged accordingly).
- **Verdict:** 9router's version of this exact risk is worse-defended, not better. No structural advantage for 9router here.

### Axis 3 — auth posture (default creds, Host-header allowlist / DNS-rebinding)

- **OmniRoute:** MEASURED. Shipped default management password `CHANGEME` (found and rotated by hmd's own installer/audit — `docs/analysis/2026-08-25-omniroute-install.md`; residual stale `INITIAL_PASSWORD=CHANGEME` left in `.env`, unactioned/cosmetic since the live password is rotated separately). READ-FROM-SOURCE: **no Host-header allowlist / anti-DNS-rebinding check** found in `routeGuard.ts`, `internalServiceAuth.ts`, or CORS code — a present-but-uncatalogued gap. Classic CSRF *is* mitigated (httpOnly + `sameSite=lax` cookie, fail-closed CORS).
- **9router:** default password `123456` (unrotated in any hmd process, since 9router isn't deployed here) AND a **confirmed history of exploited** DNS-rebinding / Host-header-spoofing vulnerabilities, tracked as real GitHub Security Advisories: GHSA-86m2-fcxq-5q7c, GHSA-cmhj-wh2f-9cgx, GHSA-5mj8-gf6m-fhw8, GHSA-32gc-64m7-hj7v (READ-FROM-SOURCE / GHSA database — the class of bug OmniRoute merely *has an unexploited gap for*, 9router has *shipped, disclosed, and (per advisory records) patched multiple times*, meaning it recurred).
- **Verdict:** materially worse for 9router — same bug class, but demonstrated-exploited-and-recurring vs. present-but-dormant.

### Axis 4 — data handling (prompts/context under free/no-auth upstream retention terms)

- **OmniRoute:** MEASURED, not hypothetical. `.planning/decisions/2026-08-28-omniroute-arming.md` documents a real routed request that carried **~41,000 tokens** of local session context to a keyless, free-tier, non-Anthropic provider, which the model demonstrably **retained** (echoed unrelated local details back in a later reply). The repo owner reviewed this exact evidence and made an **explicit, informed decision to keep fallback armed** — because arming is opt-in by construction (default off, per-repo `heimdall-route`/`heimdall-fallback --repo` config) and exposure scales with whatever's in context at routing time. This is a real negative, paired with a mature, documented governance process around it.
- **9router:** no formal privacy policy found; no equivalent measurement exists because this repo has never run it. Untested is not the same as safe — but it also means there's no evidence 9router is *better* here, only that OmniRoute's exact risk has actually been quantified and OmniRoute's has actually been governed.
- **Verdict:** no advantage to 9router; OmniRoute's downside here is known and managed, 9router's is simply unknown.

### Axis 5 — build/runtime footprint

- **OmniRoute:** READ-FROM-SOURCE: `package.json` `engines` requires `>=22.22.2 <23 || >=24.0.0 <27` — i.e., Node 24 in practice. MEASURED real friction: this machine's ambient default `node` resolves to v20.20.0 (nvm's cwd-based auto-switch doesn't fire for non-interactive harness `Bash` calls), requiring an explicit `PATH` prepend / pinned launchd `PATH` (`docs/analysis/2026-08-26-omniroute-gateway-start.md`). Cold boot ~10 minutes via Next.js dev server under a webpack production-equivalent build. The brief's cited "~4.6-9.5 GB installed" figure was searched for in this repo and **does not exist in any local doc** (`grep -rl` across `docs/` and `.planning/`, run twice, zero matches) — flagging it as **UNVERIFIED, brief-supplied, not independently confirmed this session**.
- **9router:** Node 20+ (lighter floor than OmniRoute's Node 24 requirement — a real, verifiable advantage). But README/CHANGELOG evidence in prior-turn research indicates **no committed lockfile**, which is a reproducibility negative (rolling `npm install -g`-style installs can silently pull a different dependency graph release to release).
- **Verdict:** genuinely mixed. 9router has a lighter Node floor; OmniRoute has a reproducible, pinned-commit install with a known (if annoying) Node-version friction that's already solved operationally in this repo. Disk-footprint claim for either project is not independently confirmed and should not be weighted.

### Axis 6 — API compatibility (Anthropic-shaped `/v1/messages`)

- **OmniRoute:** READ-FROM-SOURCE, confirmed at the pinned commit (`d82b68274c75c14d258b4898a34edc25d9712b87`, branch `release/v3.8.51`): real, wired `/v1/messages` endpoint (`src/app/api/v1/messages/route.ts`). This is what makes hmd's `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` swap mechanism work at all (mechanism itself confirmed against Anthropic's own official docs: `code.claude.com/docs/en/llm-gateway`, `.../llm-gateway-connect`).
- **9router:** also serves `/v1/messages` (Anthropic-compatible) alongside `/v1/chat/completions` — confirmed via SKILL.md/CHANGELOG.md in prior-turn research, correcting an initial (wrong) finding that it was OpenAI-shaped only.
- **Verdict:** **this axis is a wash.** The brief called this "close to decisive" — it is not, because both projects clear the bar. No differentiator here.

### Axis 7 — maintenance signals

- **OmniRoute:** 53,721 stars / 7,347 forks / 41 open issues / 312 subscribers (as of 2026-08-24, `docs/analysis/2026-08-23-omniroute-assessment.md`), MIT, 4,288 commits, actively pushed.
- **9router:** ~26.5-26.6k stars, ~4.8k forks, 148 watchers, MIT, 997-1,810 open issues (figure inconsistent across sources — flagged, not resolved), very high release cadence (~one release every 2 days, per prior-turn research — SECONDARY/aggregated, not independently re-verified this session).
- **Verdict:** OmniRoute has roughly double the community traction and a far healthier open-issue ratio relative to size. 9router's high release cadence could read as "actively maintained" or as "shipping fast without stabilizing" — the advisory count in Axis 3 supports the latter reading.

### Axis 8 — known defects

- **OmniRoute:**
  1. Build-from-source defect (per brief): pinned commit doesn't build clean without hmd's own local patch (`patches/omniroute/0001-wsPath-*.patch`) — upstream ships a broken import. Known, patched, not blocking.
  2. **Newly confirmed this session, a genuine runtime defect** (`docs/analysis/2026-08-27-omniroute-keyless-route-verified.md`): a single per-model `402` (payment-required) response misclassifies at the *connection* level as `credits_exhausted`, blocking every other model on that connection — including previously-working ones — until manually cleared via `PATCH /api/providers/<id>`. Reproduced, not hypothetical. No credits actually involved.
- **9router:**
  - **CVE-2026-55638**, CVSS 8.6 (HIGH) — authentication bypass via `/codex` path rewrite. Patched, but shipped.
  - At least **9 additional named GHSA advisories** beyond the DNS-rebinding cluster in Axis 3, several rated HIGH: SSRF, RCE via unvalidated MCP plugin arguments, authorization downgrade via mass assignment. (READ-FROM-SOURCE / GHSA database, cross-checked this session against parallel research in memory — corroborated independently by a second research pass this session: "10+ Advisories in 2 Months Including DNS Rebinding, Host-Header SSRF, Authenticated RCE," and a StationX-style structured security audit citing five distinct findings on credential risk, auth posture, and data-in-transit.)
- **Verdict:** OmniRoute's defects are a build-time annoyance (patched) and a runtime health-state bug (annoying, non-security). 9router's defect history includes a HIGH-severity **authentication bypass CVE** and RCE-class advisories — a materially more severe and more frequent security-defect record.

---

## Step 3 — verdict

**Answering the owner's question directly: is 9router better than OmniRoute, for this specific use (hmd's local fallback gateway)? No.**

- The one axis the brief flagged as potentially decisive (Axis 6, API compatibility) is a **wash** — both serve Anthropic-shaped `/v1/messages`.
- Every axis where the two differ favors OmniRoute or is a toss-up with no clear 9router win: worse default credential-isolation posture (Axis 2), a **confirmed, exploited, recurring** Host-header/DNS-rebinding advisory history vs. OmniRoute's dormant unexploited gap (Axis 3), a heavier and more severe vulnerability/CVE record overall (Axis 8), and roughly half the community-health signal (Axis 7).
- The only place 9router has a clean, real advantage is a lighter Node-version floor (Axis 5) — not remotely enough to offset a HIGH-severity auth-bypass CVE and 9+ additional advisories.
- **Switching cost is real and one-directional.** hmd already has, for OmniRoute specifically: a pinned, patched, buildable commit; a hardened installer (password rotation via `reset-password.mjs`, 256-bit random password, 0600-permissioned secrets); a proven-necessary durable launchd start mechanism (`nohup` demonstrated insufficient — killed by session teardown); a credential-isolation audit with a "MITIGATION HOLDS" verdict and named, tracked residual risks; a working, execution-verified keyless fallback route with real native tool-calling; a 9-point `heimdall-fallback` safety-check gate; and an owner-level informed governance decision covering the one real measured data-handling risk. None of that transfers to 9router. A marginal or wash-level improvement does not justify throwing all of it away — and 9router isn't even marginally better, it's the **unaudited, unvetted, more-vulnerable ancestor** OmniRoute was forked from and hardened against.

**What would actually justify a switch (stated plainly, per brief's instruction):**
1. 9router ships a verified fix eliminating the Host-header/DNS-rebinding bug class for good (not just a patched instance — a structural allowlist), with an independent security audit confirming it, **and**
2. 9router documents a credential-isolation architecture demonstrably stronger than OmniRoute's current one (e.g., no code path capable of importing a `claude-web` OAuth session at all, not just "requires management auth"), **and**
3. 9router ships a committed lockfile / reproducible-build story matching what hmd already has for OmniRoute, **and**
4. 9router offers some concrete capability OmniRoute structurally lacks (not just "lighter," not just "faster" per its own README — that's a MARKETING CLAIM, not evidence) that materially matters for this repo's fallback use case.

Absent all four, this is not close. **Keep OmniRoute.**

---

### Sources
- OmniRoute README (Acknowledgements: fork of 9router) — read via prior audit corpus, `docs/analysis/2026-08-23-omniroute-assessment.md`
- `docs/analysis/2026-08-23-omniroute-assessment.md` — maintenance signals, fork lineage, Tier-1 ToS concern
- `docs/analysis/2026-08-25-omniroute-credential-isolation.md` — credential-isolation residual-risk framing
- `docs/analysis/2026-08-25-omniroute-install.md` — CHANGEME finding + fix, Host-header gap, Tier-1-defeat mechanism
- `docs/analysis/2026-08-25-omniroute-fallback-transport.md` — `/v1/messages` source confirmation, `ANTHROPIC_BASE_URL` mechanism, Tier-1 disable-flag NOT FOUND
- `docs/analysis/2026-08-26-omniroute-gateway-start.md` — launchd durability fix, Node-version friction, no-auth provider inventory
- `docs/analysis/2026-08-27-omniroute-keyless-route-verified.md` — keyless native tool-calling verification, 402-connection-poisoning defect
- `.planning/decisions/2026-08-28-omniroute-arming.md` — measured 41k-token data-leak event and owner governance decision
- Anthropic official docs: `code.claude.com/docs/en/llm-gateway`, `code.claude.com/docs/en/llm-gateway-connect`
- GitHub Security Advisories (9router): GHSA-86m2-fcxq-5q7c, GHSA-cmhj-wh2f-9cgx, GHSA-5mj8-gf6m-fhw8, GHSA-32gc-64m7-hj7v, CVE-2026-55638 (CVSS 8.6)
- `github.com/decolua/9router` — project identity, licensing, npm/Docker distribution
- npm registry secondary figures (v0.5.55, ~35,836 weekly downloads) — SECONDARY, npmjs.com direct fetch returned HTTP 403, not independently re-verified
