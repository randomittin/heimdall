# Heimdall — Chat-Ops: hmd cloud via Slack/Telegram — build spec for hmd

**The ask:** from a chat message — "see what's breaking this", "investigate", "fix" — hmd cloud picks up the team's repo WITH the local context already synced via git, does the bounded work on the existing Cloud Run Jobs infra, and replies in-thread. No context rebuild, no laptop required. This is the flight-fix's payoff surface: durable server jobs + signed dispatch + owner gates already exist; chat-ops is an adapter + a context contract on top.

## 0. Channel priority (decide once)
1. **Slack first** — teams are the wedge and they live in Slack; slash command + @mention. App manifest, socket-mode (no public webhook needed initially).
2. **Telegram second** — trivial bot API, no review process, perfect for solo devs; same verb set.
3. **WhatsApp: DEFER** — Business API is gated/heavy; revisit on demand.
One adapter interface (`chat_adapter`) so channels are thin skins over the same core.

## 1. The verb set (bounded — the CP allowlist principle applies; NEVER arbitrary commands)
| Verb | What it does | Mutation | Gate |
|---|---|---|---|
| `status` | wall + last verdicts + open denies for the bound repo | none | any bound member |
| `investigate <hint?>` ("see what's breaking this") | cloud job: clone + read context ref + run gates + read CI status (gh) + produce a triage report | none (read-only job) | any bound member |
| `fix <hint?>` | investigate → then attempt the fix **on a branch** → run gates on the result → open a PR with receipts | branch + PR ONLY. **Never pushes main, never merges.** | owner-gated by default (team setting can widen to members) |
| `approve <id>` / `deny <id>` | act on a pending owner-gate item from the notify queue | as gated | owner only |
| `report` | last sleep/audit report rendered to the thread | none | any bound member |
Free-text maps to a verb via a tiny classifier ("what's failing" → investigate); anything unmappable → help text listing the five verbs. No verb = no action — the message is never handed raw to an agent as an instruction.

## 2. Identity binding (the crux — a chat handle must never be trusted bare)
- `hmd link slack` (local, on an enrolled machine) → prints a one-time 6-digit code (5-min TTL, single-use) → user DMs the bot `/hmd link <code>` → CP binds {slack_user_id ↔ HAID ↔ team_id} in the registry (signed write, audited).
- Every chat command resolves through the binding: no binding → the link instruction, nothing else. Team scope comes from the HAID's registry binding (the isolation model unchanged — a bound member can only touch their own team's repos).
- Workspace-level: the Slack app install is bound to ONE team_id at install time (the installer must be an owner). Telegram: per-user binding only.
- Unlink: `hmd unlink slack` + owner can revoke any binding. All bindings auditable (`hmd team bindings`).

## 3. Context sync via git (RJ's design — the context IS the repo + hmd's own state)
- **Where:** a dedicated branch `hmd/context` (orphan; never merged into main; main stays clean). Contents, size-capped + rotated: `context.md` (rolling session summary, last N sessions), `cases/` (open case files), `verdicts.ndjson` (recent gate history), `worklog.json` (what was being attempted, by whom, last state). NO secrets ever (the existing secret-scan runs on every context commit — falsifier: a planted sk-ant string blocks the push).
- **Local side:** a session-end hook (and a 15-min idle checkpoint) auto-commits + pushes the context branch. `hmd context off` per repo for teams who don't want it; on by default for PRIVATE repos, **off by default for public repos** (a work narrative on a public branch is a leak class — same fail-safe direction as auto-join).
- **Cloud side:** the job clones the repo, fetches `hmd/context`, reads `worklog.json` + `context.md` FIRST — it resumes, it doesn't rediscover. The triage report's first line cites what it resumed from ("continuing from RJ's session ending 14:02: auth refactor, gate red on oracle/contract").
- Trust note: the context branch lives in the team's own repo — same trust boundary as the code; nothing new is exposed to Heimdall's infra beyond what jobs already touch.

## 4. Execution (all existing plumbing)
Chat verb → CP route (signed on behalf of the bound HAID by the chat-gateway service identity, with the binding recorded in the audit line) → existing job dispatch (run_v2, digest-pinned image) → job runs the verb's playbook → result posts to the thread (+ notify inbox as today). **BYO-inference invariant holds:** jobs run on the TEAM's registered credential (rr connect); no team credential registered → `fix`/`investigate` reply with the one-line connect instruction instead of running. Repo access for clone: the GitHub App installation the team already registered (rr flow) — chat-ops adds no new credential class.

## 5. Abuse & cost bounds
Per-binding rate limit (e.g. 10 jobs/day free tier), per-team concurrent-job cap (1 free / 3 later-paid), job timeout from the existing runner, `fix` requires the owner-gate ack in-thread (a button/reply) before dispatch when invoked by non-owners. All jobs land in the audit trail. The orchestration quota from cost-gov applies.

## 6. Build phases + gates
- **P1:** context-sync (hook + branch + secret-scan falsifier + `hmd context off`) — valuable alone (any fresh machine/cloud job resumes instantly). Gate: a cloud `investigate` on a test repo cites the local session's worklog without any local involvement.
- **P2:** Telegram bot (fastest end-to-end proof) + link flow + `status`/`investigate`/`report`. Gate: phone-only triage of a real red gate, report in-thread, zero laptop.
- **P3:** Slack app + `fix` (branch+PR+receipts) + `approve`/`deny`. Gate: a real deny fixed to a green-gated PR entirely from Slack; falsifier: `fix` attempting to push main → refused + audited.
- **P4:** the same gateway exposed to the TUI/website later (one command surface, many skins).

## 7. Tests (falsifiable, per the house style)
Unbound chat id → refused with link instruction (falsifier: forged slack_user_id → refused). Cross-team command → refused (isolation suite extended). Context branch: secret plant → push blocked. `fix` → branch+PR only (falsifier: direct-push attempt → refused). Rate limit → 11th job refused. The verb classifier: unmappable text → help, never dispatch.
