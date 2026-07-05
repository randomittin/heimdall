# Changes Since Team Features

Comprehensive change log covering every theme of work from the introduction of
team features through the current head. Grouped by theme, not chronology.

## Header — method, anchor, honesty

- **Head at time of writing:** `bb8d061` (`refs/heads/main`).
- **Pushed frontier:** `origin/main` = `6202149` (release v2.0.12). Everything
  below `6202149..bb8d061` is **unpushed** — the checkpoint counts it at **~85
  commits ahead**; RJ pushes.
- **Sourcing note (honest):** this environment has no `git` CLI and no `rg`
  (ripgrep) — `git show --stat` could not be run. Every SHA cited here is read
  directly from git's own on-disk record, `.git/logs/HEAD` (the 299-entry HEAD
  reflog spanning 2026-06-23 → 2026-07-06), cross-checked against the tracked
  planning ledger `.planning/experiments.jsonl` and `.planning/CHECKPOINT.md`.
  SHAs are quoted in their 7-char short form as they appear in the reflog. A
  handful of bug-fix SHAs (`cca7381`, `fa23a7d`, `00b0b3f`, `9c5aca5`) live
  inside squashed worktree merges and are cited from the experiments ledger's
  `refs` field rather than the top-level reflog.
- **Anchor choice:** `28d7c4f` — `docs(team): team-mode design dossier — STEP-0
  inventory (2 naming traps caught), P1 activity-record schema + P2 gate-surface
  + P3 collision`. This is the first commit that names and specifies team
  features; everything downstream (presence, enroll, roster, statusline
  identity, the multi-tenant control plane, the cloud maintainer) descends from
  its P1/P2/P3 design. Its immediate precursors `db3772f`
  (`docs(telemetry): design dossier`) and `34249d7` (`test(telemetry): e2e
  integration gate`) are shared infra the team activity-record builds on, so
  they are noted but sit just *before* the anchor.

---

## (a) Team identity & presence — HAID, enroll, roster, statusline

The team-mode dossier defined a git-backed, secret-free **activity record**, a
shared **gate surface** (PROVEN / BLOCKED / pending verdicts republished to the
git record, never fabricated), and a **collision** model. From there the work
grew a real presence runtime: HAID-attributed identity, token-gated then
tokenless self-enroll for zero-touch PKI bootstrap, an unauthenticated
`GET /roster-public` browser read, and a full-width "watchman" statusline HUD
that renders live presence and gate verdicts. Presence culminated in a
zero-command default (`hmd team` smart-dispatch + SessionStart auto-join).

- `28d7c4f` docs(team): team-mode design dossier — activity-record + gate-surface + collision (ANCHOR)
- `180d466` merge(team-p2): shared gate surface — SI-2 verdicts republished secret-free; `hmd who`/`team` GATES column (PROVEN/BLOCKED/pending), gitleaks-clean
- `6e8f47d` merge fix-server-haid-canonical — canonical HAID on the server signing path
- `d84d35e` feat(statusline): land viral watchman v2 — sigil + full-width HUD + gate animation
- `f0407f2` feat(statusline): wire full-width watchman as live statusLine + register subagentStatusLine
- `5087b7b` feat(statusline): companion subagent watchman line + wake/share banner
- `fa07a8d` feat(sentinels): gate verdicts drive watchman HUD state + inline anim
- `6efd59a` fix(statusline): subtract sigil anchor from width-math — rows pin to COLUMNS
- `6594ed9` fix(statusline): readable watchman + target-parity elements, no edge clip
- `94e0cac` fix(statusline): blink → SQUINT so no still frame is ever eyeless
- `60d63d6` fix(sigil): clean watchman face — curated grids + template gen
- `9b74d53` feat(statusline): throttled fire-and-forget auto-beat so the wall fills itself
- `7eb1ed3` merge cp-presence — presence backend onto main
- `e487a4d` feat(land): autonomous team git flow — reversible branch push, gated shared-main land
- `7039bf0` feat(cp-enroll): token-gated self-enroll for zero-touch PKI bootstrap
- `06684be` fix(presence): sever server PKI var from dev path + honest leak-test
- `2490483` docs(public-surface): document the unauthenticated `GET /roster-public` browser read
- `4930fa0` fix(cp-presence-deployed): shipped client signs with the OWNER seed (`HMD_PRESENCE_SEED`)
- `155bf32` feat(presence): token-optional enroll (open mode) + single-fork per-render presence
- `33b3b78` feat(enroll): open (tokenless) mode + hard registry-size cap, bounded
- `1348acb` feat(open-enroll): deploy/runbook for tokenless+bounded public enroll
- `10bb8f4` feat(presence): bake the public-surface URL as a shipped default (centralized)
- `6305c50` feat(team): zero-command default team — bare `hmd team` smart dispatch + SessionStart auto
- `54b327c` docs(team): team-presence validation runbook (solo, 2-dev auto-join, isolation, negative guards)
- `212cf47` feat(hooks): emit the Heimdall Run Receipt as the SessionEnd flagship card
- `60f3f2f` chore: wire maintainer resume-hint (SessionStart) + team conflict-warn (PreToolUse) hooks

---

## (b) Multi-tenant control plane — W0–W5

The control-plane dossier froze a security spine: a **frozen action allowlist**
(no free-form command-string field; arbitrary input → 422 + audit), **Ed25519
PKI per instance**, an **isolated job worker** (control plane ≠ fleet), and
server-hosted detach/resume. ADRs pinned encryption (Cloud Run TLS + Ed25519 =
authenticated *and* encrypted; never plain-HTTP-public) and isolation (in-process
for trusted internal now, OS sandbox before external). A `StateBackend`
abstraction landed in waves (approvals, notify, observe, audit, scheduler) with a
Firestore backend behind it, then a run of Firestore-path fixes hardened the
deployed shape. W0 published the **isolation-invariant ledger + cross-tenant
coverage matrix** — the multi-tenant security contract — and the multi-tenant
teams merge train delivered per-team isolation (creds/queues/installs) with
design + threat-model docs tracked in-repo.

- `7bc90eb` docs(control-plane): design dossier — frozen action-allowlist spine, Ed25519 PKI, isolated job worker
- `017f098` docs(cp-decisions): ADR-1 encryption (TLS + Ed25519) + ADR-2 isolation (in-process now, sandbox before external)
- `e3510f8` feat(cp-state): approval store onto StateBackend (Wave 1) — atomic put/get/list, basename-guarded key
- `56d2eea` test(cp-wired): §10 assembly gate — boots ONE wired CP server, drives start→disconnect-survives→complete→notify→owner-approve over real signed HTTP; falsifiable
- `7cc1a83` docs(cp-state): fix stale "firestore reserved for Wave 2" comments — Firestore IS built; unblocks triage
- (Firestore hardening train, merged sequentially): `fix-cp-firestore-dockerfile`, `fix-readyz-backend-health`, `fix-tick-firestore-path`, `firestore-mode-sweep`, `fix-dashboard-firestore-path`, `fix-selfcheck-firestore`, `verify-flight-fix-final`, plus `cp-durability-emulator` + `cp-auth-secret-durable`
- `3f7868a` docs(rr): isolation invariant ledger + cross-tenant coverage matrix (W0 — the multi-tenant security contract)
- `42599d3` merge(worktree-agent-aed91c0): multi-tenant teams — per-team isolation landed
- `bbe2c97` chore(teams): dedupe `.gitignore` team.json + track multi-tenant design + threat-model docs

Note: W0 is explicit in the tree (`3f7868a`); W1–W5 (per-team creds, queues,
installs, public surface, oracle) landed folded into the multi-tenant merge
train (`42599d3` and the deploy/cp-image fixes in §c/§g) — the tracked design
and threat-model docs added in `bbe2c97` are the canonical W1–W5 spec.

---

## (c) The cloud maintainer pipeline — rr, dispatch, Cloud Run Jobs, the 15-bug ladder

This is the flagship: `bin/rr` submits a repo/issue to the public surface, which
dispatches an isolated **Cloud Run Job** (`heimdall-maintainer-job`) that clones
the target, runs the maintainer, and opens a PR. Bringing it up in production
exposed a **15-bug ladder** — almost every bug was a *deployed-shape* break that
works locally and fails only in the real container/GFE/IAM environment. Bugs
1–14 are fixed and merged; bug 15 is the sole open blocker.

rr / dispatch / job plumbing:

- `20ee8fd` fix(rr): code-injection — single-quote the heredoc + pass gh-issue-list output via env (untrusted issue titles no longer reach the python source)
- `1c6e0fd` feat(rr): ship the session context capsule to the VM before dispatch (continuity; opt-out `RR_NO_CONTEXT`)
- `9da2f5e` fix(context-capsule): command-injection — allowlist the repo slug `[A-Za-z0-9._-]` before it reaches remote ssh
- `7357690` fix(rr): point `DEFAULT_CP_URL` at the real deployed public surface (`heimdall-cp-public-203927696193`)
- `548576b` merge feat/deploy-public-rr — public rr surface deploy
- (`cp-job-runner-cloudrun`, `cp-job-runner-runbook`, `cp-job-hardening`, `cp-dispatch-loud-log`, `cp-getjobs-readpath`/`query-param` merged through the job read-path train)

The 15-bug bring-up ladder (cause → fix; ledger = `.planning/experiments.jsonl`, `.planning/CHECKPOINT.md`):

1. **missing-sm-dep** — `/team/cred` 503: `google-cloud-secret-manager` in the local venv, absent in the CP image → add it + build-time import guard. `96cfc19`, `1460ec0`
2. **cred-forward-least-priv** — public SA can't write Secret Manager under prod least-privilege → forward public→gated `/team/cred` over authenticated s2s + `run.invoker`; keep read/dispatch forbidden. `cca7381`, `fa23a7d`
3. **rr-mode-routing-tab-collapse** — a tab-collapse ate `mode=control-plane` → bare rr SSH'd instead of `POST /rr-task` → restore the collapsed branch. `00b0b3f`
4. **job-name-mismatch-env** — dispatcher defaulted to `heimdall-long-job`, diverging from the deployed job → set `HEIMDALL_CP_JOB_NAME=heimdall-maintainer-job` on the tick service. `ef83e77`
5. **per-team-env-dropped-jobrunner** — `CloudRunJobRunner.build_request` dropped `base_env` → job ran credless / cross-tenant → thread per-team cred + minted token into the per-execution env override. `9c5aca5`
6. **silent-task-consumption** — a failing task subprocess was captured and dropped (no error, no retry, no trail) → surface scrubbed stderr on nonzero exit + retry + loud tick; never consume silently.
7. **drain-enumeration-scope** — drain enumeration missed queued tasks → the warm tick drained nothing → widen the enumeration scope.
8. **cpu-throttle-starved-tick** — Cloud Run CPU-throttling starved the background tick → run `--no-cpu-throttling` / `min-instances=1`. `2629489`, `beba40c`
9. **reserved-env-names-in-overrides** — reserved env names in the per-execution override made Cloud Run reject the RunJob → strip `PORT`/`K_SERVICE`/`K_REVISION`/`K_CONFIGURATION`.
10. **local-maintainer-enabled-gate** — the `.maintainer.enabled` gate file is absent in an ephemeral container → gate on an env override + fresh-home semantic, not a local file.
11. **stale-job-image-allowlist** — the JOB image carried an old allowlist (service/job two-image split skewed) → rebuild BOTH images on every bin/lib change; re-pin the allowlist.
12. **budget-meter-fail-closed-fresh-home** — the budget meter fail-closed on a fresh `$HOME` (no usage history in a cold container) → fresh-home default instead of fail-close.
13. **planning-dir-slug-readonly-cwd** — planning dir built from a repo slug joined onto the read-only CWD (no clone happened) → clone into a writable workspace; never join a slug onto read-only CWD.
14. **issue-queue-never-ingested** — `issue_queue.ingest` had ZERO callers → wire `gh issue list` → `ingest_many` so the queue is populated. `66c3ee0`
15. **resume_orphans-in-process-steal** — **FIXED** (`a0edb19`, merged). `cp_worker.py` `run_job` ignored `HEIMDALL_JOB_RUNNER`; any instance boot stole queued jobs and ran them IN-PROCESS with the gated service's stale code (the 876-traceback mystery — the job image was byte-verified correct). Fix: resume re-dispatches via the configured runner (cloudrun-job), never in-process for remote runners; 5-min grace for young queued jobs; 2h running-orphan lease with 1 reclaim; loud `resumed-via=` logging. Falsifier-tested (cp-jobs 38/0).

---

## (d) Reliability & ops — retry/dead-letter, loud tick, CAS claim, resume/lease, alerting/TTL/PITR

Hardening applied live against the running services. The silent-failure class
(bug 6) drove a retry + dead-letter + **loud tick** discipline. A **CAS claim**
plus periodic resume and a **running-lease** land the concurrency-safe pickup
(and must also cover bug 15's runner-honoring resume). A hybrid runner-selection
module (`cp_maintainer_runner`: heartbeat / select / failover / park) enables the
Arch A/B/hybrid dispatch. Ops hardening (alerting / TTL / PITR) ships as a script
RJ applies via gcloud after merge. A billing kill-switch and a durable in-session
maintainer autopilot round out the reliability surface.

- `99a3f24` merge cp-dispatch-loud-log — retry + dead-letter + loud tick (bug 6 discipline)
- `508f247` merge billing-kill-switch — spend circuit-breaker
- `d6254d6` merge(maintain-loop): durable in-session maintainer autopilot (`--receipt` + `--heartbeat`)
- `31f49ae` wip(cp-hybrid): `cp_maintainer_runner` — heartbeat/select/failover/park + scheduler routing + `runner-beat` verb
- `bb8d061` merge worktree-agent-a478d283 — CAS pick + periodic resume + running-lease (MUST cover bug 15's runner-honoring resume) — **current HEAD**
- `9795c37` merge worktree-agent-a7ab547f — ops-hardening script: alerting / TTL / PITR (applied via gcloud post-merge)

---

## (e) Security — audit findings F1–F6, IAM narrowing, scrub/error_tail discipline

Three audits landed under `docs/analysis/` (per the checkpoint): a security audit
(verdict **CONDITIONAL GO**), a prod-readiness audit (top-5: CAS claim, spend
caps, alerting, resume+lease, TTL/PITR), and a viral-readiness audit. F2 (SA
narrowing) is in flight and applied live; F1 (leaked token rotation) is RJ's to
execute post-PR — the token is audit-verified NOT in the repo. Two real
code-injection findings were fixed at the boundary, and a scrub/`error_tail`
discipline keeps secrets out of surfaced subprocess output.

- `befdfd0` merge worktree-agent-aca75a28 — security **F2**: SA narrowing + `sk-ant` scrub + fail-open loudness
- `20ee8fd` fix(rr): code-injection — heredoc single-quote + env-pass of untrusted issue titles (see §c)
- `9da2f5e` fix(context-capsule): command-injection — repo-slug allowlist before remote ssh (see §c)
- `06684be` fix(presence): sever server PKI var from the dev path + honest leak-test
- `da85ffc` chore(secret-scan): allowlist the confirmed-fake enroll fixture by fingerprint
- scrub/`error_tail` discipline: bug 6 fix surfaces only *scrubbed* subprocess stderr; secrets never in argv/logs/chat
- **F1 (token rotation):** OPEN — RJ rotates `sk-ant-oat01-…` once the run-8 PR lands; leaked token is NOT in the repo (audit-verified).

---

## (f) Growth & product — README, site, PR-footer CTA, strategy, self-improve skill

The README was rebuilt twice: an install-first front door, then a launch rewrite
that leads with the cloud-maintainer rr loop (one-liner + 3-command onboard +
receipts). A separate site repo carries the hero/proof/team/growth pages. The
viral loop's #1 starter — the **PR-footer CTA** — ships in `issue_pr.py` alongside
`rr status`, loud enroll, and a dedup notice. A teams growth strategy doc maps the
Slack playbook to `hmd` with wave-gated phases and a Cursor-for-teams revenue
model. A self-improve/autoresearch corpus plus a **deployed-shape preflight**
(warn-only in the deploy scripts) encodes the 15-bug lessons so future bring-ups
catch them earlier.

- `b4b84fc` docs(readme): install-first repo front door — pin v2.0.5, honest GENERALIZES (0.50/8 repos → /proof), capability table
- `7d57811` docs(readme): lead with the cloud-maintainer rr loop for launch (one-liner + 3-command onboard + receipts; pin 2.0.12)
- `753324a` docs(strategy): teams growth strategy — Slack playbook mapped to `hmd`, wave-gated phases, Cursor-for-teams revenue model
- `ff99689` merge worktree-agent-a99bc08d — viral code fixes: PR-footer CTA (`issue_pr.py`), `rr status`, loud enroll, dedup notice, runbook §C
- `bb8e7c7` self-improve corpus + deployed-shape preflight (warn-only in deploy scripts) — *cited from CHECKPOINT; landed inside a worktree merge*
- `4c3362e` site repo — hero/proof/team/growth, v2.0.12 — *lives in the separate site repo, not this tree*

---

## (g) Deploy tooling — Cloud Build migration, multitenant manifest, prompt-free deploys, preflight wiring

The go-live path became a turnkey, propagation-safe, secret-safe operator flow.
A **two-service split** separates the public presence/enroll surface (least-priv
SA, `--allow-unauthenticated`, gated routes 404) from the gated dispatch service.
A one-shot maintainer deploy script covers Arch A/B/hybrid with an interactive
setup-token read straight to gcloud (never in argv), idempotent and `--dry-run`.
Cloud-build/manifest work dropped the docker preflight in cloud/hybrid mode and
resolved the multitenant manifest + runtime-SA references. Auto-update + auto
version-bump/tag/Release close the loop so shipped bumps actually reach clients.

- `15441ba` feat(deploy): two-service split — public presence/enroll surface, least-priv SA
- `bf262d5` feat(cp): public-surface boundary — gated routes 404 on the `--allow-unauthenticated` service
- `31c92c2` test(cp-public-surface): deployed-shape boundary falsifier — gated routes 404 on public surface
- `e7504c3` feat(go-live): turnkey two-service runbook + HARD-REFUSE the dangerous public-surface deploys
- `aa6a6ad` feat(go-live): guided operator script for two-service go-live (steps 2–7)
- `02ed9f8` fix(go-live): `ensure_ar_repo` creates the AR repo before STEP 2 push (+ `a70fa3b` ALREADY_EXISTS = success)
- `325b194` fix(go-live): STEP 4 SA propagation-safe — idempotent ensure + describe-poll + retrying grants
- `e21f500` fix(go-live): STEP 7 verify via `/readyz` + app-404 body, not GFE-eaten `/healthz`
- `bc8cc9d` feat(deploy): one-shot maintainer deploy script — Arch A/B/hybrid, interactive setup-token, secret-safe, idempotent, `--dry-run`
- `02d83ba` test(deploy-maintainer): capture-then-grep to avoid pipefail+SIGPIPE false-fail
- `71fb505` fix(deploy-arch-b): default project `heimdall-control-plane` (match infra SA / active gcloud)
- `c066c09` fix(deploy-maintainer): drop spurious docker preflight in cloud/hybrid mode (+ multitenant-manifest tests)
- `943e9c9` / `7584b95` / `58c5679` fix(deploy): resolve straggler gated-SA refs → `heimdall-cp-runtime@heimdall-cp-prod`
- `7d9e020` fix(go-live): mount `HEIMDALL_GH_APP_ID` + `HEIMDALL_GH_APP_PRIVATE_KEY` on the gated service (mint_failed fix)
- `af8ec47` feat(github-app): add `Actions:read` to the App perm set (Workflows:write stays per-team opt-in)
- Auto-update / ship: `b7b9707` + `2896a45` (SessionStart auto-update), `d3d2367` (auto version-bump + tag + Release), `c1a4bee` (self-heal native auto-update)
- Releases in-window: `81826b5` v2.0.6 · `bdd76f8` v2.0.7 · `c9b4cb3` v2.0.8 · `fba3d7f` v2.0.9 · `1835f75` v2.0.10 · `1c42efd` v2.0.11 · `6202149` v2.0.12 (the aborted `v2.1.0`/`v3.0.0`/`v9.9.9` autobump-test tags were reset, never on main)

---

## Current live state

- **Tenant:** team `6ca551f2`, install `144263218`, repo
  `randomittin/heimdall-maintainer-test` (4 maintainer issues seeded).
- **Services/images:** gated dispatch service image `1498119` — **STALE vs
  main**, needs a rebuild; JOB image `b0ffc7d5` = `66c3ee0` — **correct**
  (byte-verified). Background tick healthy at 1/min.
- **Proven end-to-end:** signed HTTP surface (401/422 cardinals), presence +
  enroll + `roster-public`, per-execution isolated dispatch, Cloud Run Job
  clone→maintainer→PR path — all 14 fixed bugs verified in prod or by test.
- **Blocked:** task `abec8dac` consumed by the bug-15 in-process steal.
  **NO PR YET.**
- **Head:** `bb8d061` (main); `origin/main` at `6202149` (v2.0.12).

## Outstanding items

- **Bug 15 (resume_orphans in-process steal)** — the one open ladder bug; fix
  must land in the CAS/resume agent (runner-honoring resume + young-job grace).
- **F1 — token rotation** — RJ rotates `sk-ant-oat01-…` after the PR lands.
- **Run-8 PR — pending** — resume sequence: merge remaining agents → full gate →
  rebuild BOTH images (`deploy-public-rr.sh` + `deploy-arch-b.sh`) → apply
  ops-hardening + F2 IAM → `bin/rr` fresh submit → run 8 → PR on
  `randomittin/heimdall-maintainer-test`.
- **~85 unpushed commits** (`6202149..bb8d061`) — RJ pushes.
- **Gated service image rebuild** — `1498119` is behind main.
- **Spend-cap fix** — per-team/day cap in `cp_maintainer_runner`, next after the
  F2 agent frees the file.

## Test-coverage stats (as sourced; honest)

A full `pytest` suite count is not derivable from the git/planning record
without running the suite, and the git CLI is unavailable in this environment —
so rather than invent a number, here are the concrete, ledger-traceable gate and
oracle figures:

- **Bug ladder:** 15 found; **14 verified** (`verified-in-prod` or
  `verified-by-test` per `.planning/experiments.jsonl`), 1 open.
- **cp-wired §10 assembly gate** (`56d2eea`): full signed-HTTP flow gate;
  falsifiable — commenting `boot()` drops it 34 → 24/10.
- **cp-getjobs read-path** (`2c5d24a` train): 10/10, with query-mismatch
  falsifiers → 401 either direction.
- **cp-public-surface boundary falsifier** (`31c92c2`): gated routes must 404 on
  the public service.
- **README GENERALIZES claim** (`b4b84fc`): honest 0.50/8 repos → `/proof`.
- **Audits** (`docs/analysis/`): security = CONDITIONAL GO, prod-readiness top-5
  logged, viral-readiness names the PR-footer CTA as the #1 loop-starter.
</content>
</invoke>
