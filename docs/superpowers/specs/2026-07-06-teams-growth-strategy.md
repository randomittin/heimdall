# Heimdall Teams — Growth Strategy (the Slack playbook → Cursor-for-teams revenue)

Date: 2026-07-06 · Status: draft for RJ review · House rule: every claim below is either **live-verified**, **audit-cited**, or explicitly marked *hypothesis*. No vapor.

---

## 1. Where we are (honest asset inventory)

**Proven live (production, heimdall-cp-prod, 2026-07-05/06):**
- Multi-tenant control plane: two-service split (gated worker + enqueue-only public surface), Ed25519-signed requests, server-derived team identity (INV-1), per-team Secret Manager credential partitions (BYOC).
- Cross-tenant isolation is **falsifiably proven**: `bin/falsify rr-multitenant-isolation` = 1.0 — every mutant is a real attack (foreign-repo dispatch, cred read-back, team spoof) and every one is killed. This is the enterprise trust artifact; competitors assert isolation, we ship the attack suite.
- The `rr` loop: signed task → per-team queue → drain → per-team GitHub App token minted per cycle → Cloud Run Job with the team's own Claude subscription. First tenant (RJ) enrolled, connected, and dispatched end-to-end.
- Self-improvement substrate: metrics.jsonl + `heimdall-self-improve` (measured keep/discard experiments) + a 14-incident knowledge log + a deployed-shape preflight that earned its keep on a falsifiable delta.

**Fragile / known-broken (audit-cited, most fixed this session, some open):**
- The maintainer's fix-cycle last mile was closed through 15 named bugs; #15 (gated instances re-running jobs in-process with stale code) has a fix in flight. The bot's first autonomous PR is imminent but **not yet demonstrated** — do not market "it opened this PR" until it has.
- Security: CONDITIONAL GO — leaked operator token must rotate (F1); runtime SA's project-wide `secretmanager.admin` needs narrowing (F2, fix in flight).
- Prod: **no real-time spend cap** (per-cycle 600k-token cap × 30 dispatch/min/team = theoretical $78k–389k/day/team; the $10k billing killswitch is a lagging backstop), zero alerting (a dead task paged nobody), no Firestore TTL/PITR/backup, $65/mo always-on floor per region. Fixes in flight (alerting/TTL scripts, CAS claim).
- Viral funnel: the bot PR — the only surface non-users see — had **no onboarding link** until today; enroll is a manual out-of-band token from RJ; enroll failures were silent. Footer CTA, `rr status`, loud enroll, runbook fix all landed today; **enroll self-serve is still off**.

**The one-sentence position:** the hard, differentiated substrate (isolated multi-tenant BYOC execution with falsifiable proofs) is built and live; the growth machinery around it is one week old and the loop has never yet completed organically.

---

## 2. The Slack playbook, mapped

Slack's bottom-up motion: one team adopts free → in-workspace visibility makes non-users feel the gap → they join → cross-org spread through shared channels → bottom-up expansion converts to top-down contracts. Heimdall's isomorphism:

| Slack element | Heimdall equivalent | State |
|---|---|---|
| The message a non-user is forwarded | **The bot PR** — appears in repos, seen by every reviewer/watcher | Live; CTA footer shipped 2026-07-06 |
| Presence ("who's online") | Statusline team wall + roster | Live in-repo; recruits co-workers only, not PR viewers (audit) |
| The daily habit | `rr "<task>"` → reviewed PR | Live; habit-forming only once latency + reliability hold |
| Frictionless signup | Enroll token — **currently a manual secret from RJ** | The structural cap on spread (audit) |
| Shared channels (cross-org bridge) | Bot PRs into shared/OSS repos; a maintainer bot on a public repo is visible to every contributor | Untested *hypothesis* — but the mechanism exists today |

**Killing the signup bottleneck (staged, each stage gated):**
1. **Now:** token-gated, RJ hands tokens to design partners (intentional during P0 — trust > reach while spend caps are absent).
2. **P1:** `ENROLL_OPEN=1` — the mode already exists with abuse caps (IP 5/60s, budget 50/3600s, registry 1000). Flip it only after per-team spend caps land, because open enrollment without spend caps is an open wallet.
3. **P2:** email-domain teams (everyone @acme.com auto-joins acme's team — Slack's exact trick) → SSO/SAML at Enterprise.

**Instrument the loop NOW (wire into metrics.jsonl / self-improve; all measurable with existing substrate):**
- **K-factor proxy:** PR-footer link clicks → enrolls (UTM on the footer URL; count enrolls by referrer). The loop's existence proof.
- **Time-to-first-PR** per new team (enroll → first merged bot PR). Slack obsessed over time-to-value; ours must be < 1 day.
- **Weekly active teams** (≥1 task dispatched) and **bot PRs merged / team / week** (merged, not opened — merged is the value event and the trust signal).
- **Task success rate** (dispatched → merged PR vs dead/refused) — the quality scalar the self-improve loop already knows how to optimize.

---

## 3. Phases (wave-gated, no calendar fluff)

**P0 — Stabilize (trust is the product).** The audit top-5: real-time per-team spend caps + budget drop to ~$1k; transactional queue claim (kill double-dispatch); dead-letter + tick alerting; Firestore TTL/PITR/backup; resume-orphans honoring the runner (bug #15). Plus F1 rotation + F2 SA narrowing. **Gate to P1:** 7 consecutive days of a design-partner team using rr with zero manual intervention and zero silent failures; spend caps demonstrated by a falsifier (a runaway synthetic team gets throttled, not billed).

**P1 — Self-serve onboarding (kill the bottleneck).** Flip ENROLL_OPEN behind the caps; `rr status`; the funnel fixes (already shipped: loud enroll, dedup notice, runbook ordering, footer CTA); a 5-minute quickstart that a stranger completes unaided (test it on 3 literal strangers — the audit's stranger test as an acceptance criterion). Instrument the four metrics above. **Gate to P2:** ≥N organic enrolls/week attributable to PR footers with N set after 2 weeks of baseline (start hypothesis: N=5). Below N → the viral-loop hypothesis is wrong; run the autoresearch loop on the funnel before building more surface.

**P2 — Team surfaces (the Slack-analog layer).** Meet teams where they live: (a) **Slack app** — bot-PR digests, task submission (`/hmd fix issue 42`), and merge notifications posted INTO the team's Slack (this is both distribution and the exclusion-visibility mechanic); (b) shared task feed / roster dashboard (the roster-public read surface already exists); (c) PR review queue view. Every surface shows attribution (HAID) — managers see who ships. **Gate to P3:** ≥1 team that did NOT come from RJ's network uses hmd weekly for 4 straight weeks.

**P3 — Monetize** (below).

---

## 4. Revenue — "Cursor for teams"

**Cost structure is the unfair advantage.** BYOC means tenants bring their own Claude subscriptions and GitHub Apps — **we never pay their inference**. COGS ≈ control plane ($65/mo/region always-on floor + Firestore + egress; audit-verified) amortized across all teams. Gross margin at even modest pricing is software-margin, not agent-margin. Every "AI agent" competitor that resells inference has COGS scaling with usage; ours doesn't.

**Pricing (hypothesis, to validate with design partners):**
- **Free:** 1 repo, 3 devs, community support. The viral unit — never paywall the loop's entry.
- **Team: ~$20–40/dev/mo** (Cursor-anchored; Cursor charges ~$20/seat — approximation) or **~$99/repo/mo** — pick per-dev vs per-repo after observing which correlates with value (PRs merged). Includes: unlimited repos/tasks within spend policy, priority queues, policy controls (labels the bot may touch, path allowlists), audit log export, Slack app.
- **Enterprise: $30–60k/yr** — **self-hosted control plane in their GCP project**. The deploy scripts literally already do this (deploy-public-rr.sh is project-parameterized); "your data and creds never leave your cloud" is a one-command truth, not a roadmap item. Add SSO/SAML, SLA, dedicated support.

**Positioning vs the field (comps approximate):** Cursor (~$20/seat) autocompletes the editor; Copilot Workspace assists a dev in-flow; Devin sells an autonomous engineer at premium prices on their keys; Sweep/Dosu do issue-bots without the isolation/verification story. **Heimdall owns the backlog: issues in → reviewed PRs out, on your own keys, with falsifiable proof of isolation and verification.** The editor is contested; the backlog is not.

**The moat (real, defensible):** (1) falsifiable-verification discipline — every gate ships its attack suite, which enterprises can audit rather than trust; (2) BYOC — procurement and security teams approve "your keys, your cloud" categorically faster; (3) HAID attribution + coordination ledger — the team layer (who/which-agent did what) that solo-dev tools structurally lack; (4) the self-improvement corpus — every incident across every tenant compounds into routing/pattern improvements (network effect on reliability).

---

## 5. Risks + kill-criteria (autoresearch discipline: every phase is an experiment with a measured gate)

| Risk | Signal to watch | Kill/pivot criterion |
|---|---|---|
| PR quality too low → merged-rate kills trust | bot PRs merged / opened | If < 40% merged after prompt iteration on 3 partner teams → pivot from autonomous-fix to draft-assist positioning before scaling |
| Viral loop doesn't exist (PR viewers don't convert) | footer clicks → enrolls | P1 gate < N for 4 weeks → stop building growth surface; sell top-down to 5 design partners instead |
| Open enrollment = abuse/spend disaster | per-team spend, anomaly alerts | Never flip ENROLL_OPEN before spend caps pass their falsifier; auto-revoke on cap breach |
| BYOC friction (App install + setup-token too heavy for casual teams) | drop-off between enroll and connect | If > 60% drop → build a hosted-key trial tier (we eat inference for 14 days) as the on-ramp |
| Anthropic ToS / subscription-sharing posture shifts | policy changes on CLAUDE_CODE_OAUTH_TOKEN server use | Enterprise tier must also support API keys (already does — ANTHROPIC_API_KEY path exists); keep both rails |
| Single-operator bus factor (RJ holds all deploys/creds) | — | P0 exit requires a second operator + documented runbook drill |

Each gate failure triggers the self-improve loop on the funnel data before any new build — the same keep/discard rule the code uses.

---

## 6. Next 10 actions (ranked)

| # | Action | Owner | Effort |
|---|---|---|---|
| 1 | Land P0 audit fixes in flight (spend caps, CAS claim, resume #15, alerting, TTL) + rebuild both images | agent (done/merging) + RJ deploys | M |
| 2 | Rotate the leaked oauth token (F1) + apply F2 SA narrowing commands | **RJ** | S |
| 3 | Demonstrate the first end-to-end bot PR; screenshot/merge it — the founding artifact | agent + RJ merge | S (imminent) |
| 4 | Add UTM to the PR-footer link + enroll-referrer counting (K-factor instrumentation) | agent | S |
| 5 | Push the ~85 unpushed commits; deploy site update; publish the rewritten README | **RJ** | S |
| 6 | Recruit 3 design-partner teams (hand-issued tokens; weekly feedback loop) | **RJ** | M |
| 7 | Stranger-test the quickstart on 3 people; fix every stall (P1 acceptance) | RJ observes, agent fixes | M |
| 8 | Per-team spend-cap falsifier: synthetic runaway team gets throttled — required before ENROLL_OPEN | agent | M |
| 9 | Slack app MVP (digest webhook of bot PRs into a channel — start with an incoming webhook, not a full app) | agent | M |
| 10 | Pricing validation: put the Team tier in front of the 3 partners; ask "would you expense $30/dev?" and watch faces | **RJ** | S |

**North star:** bot PRs **merged** per week across teams that RJ has never met.
