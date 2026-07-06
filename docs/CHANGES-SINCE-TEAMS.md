# Changes Since Team Features

Comprehensive change log covering every theme of work from the introduction of
team features through the current head. Grouped by theme, not chronology.

## Header — method, anchor, honesty

- **Head at time of writing:** `b0616d5` (`refs/heads/main` = `origin/main`).
- **Pushed frontier:** `origin/main` = `b0616d5` (released v2.0.13). Everything
  is **pushed and released** — no unpushed commits. The prior draft (anchor
  `bb8d061`) had ~85 unpushed commits; this update covers `bb8d061..b0616d5`
  (the final arc, §h–§m).
- **Sourcing note (corrected):** the prior draft was written without `git` CLI
  access — SHAs were sourced from `.git/logs/HEAD` reflog and
  `.planning/experiments.jsonl`. That constraint no longer applies: `git` IS
  available. Every SHA cited in the new sections (§h–§m) was sourced directly
  from `git log --oneline bb8d061..b0616d5` and verified with `git cat-file -e`.
  Earlier-section SHAs remain as sourced and are correct. A handful of bug-fix
  SHAs (`cca7381`, `fa23a7d`, `00b0b3f`, `9c5aca5`) still live inside squashed
  worktree merges and are cited from the experiments ledger.
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

## (c) The cloud maintainer pipeline — rr, dispatch, Cloud Run Jobs, the 29-bug ladder

This is the flagship: `bin/rr` submits a repo/issue to the public surface, which
dispatches an isolated **Cloud Run Job** (`heimdall-maintainer-job`) that clones
the target, runs the maintainer, and opens a PR. Bringing it up in production
exposed a **29-bug ladder** — almost every bug was a *deployed-shape* break
invisible locally, surfacing only in the real container/GFE/IAM environment.
Bugs 1–15 are covered here; bugs 16–29 (the final arc to the first autonomous PR)
appear in §(h). All 29 are fixed and closed.

rr / dispatch / job plumbing:

- `20ee8fd` fix(rr): code-injection — single-quote the heredoc + pass gh-issue-list output via env (untrusted issue titles no longer reach the python source)
- `1c6e0fd` feat(rr): ship the session context capsule to the VM before dispatch (continuity; opt-out `RR_NO_CONTEXT`)
- `9da2f5e` fix(context-capsule): command-injection — allowlist the repo slug `[A-Za-z0-9._-]` before it reaches remote ssh
- `7357690` fix(rr): point `DEFAULT_CP_URL` at the real deployed public surface (`heimdall-cp-public-203927696193`)
- `548576b` merge feat/deploy-public-rr — public rr surface deploy
- (`cp-job-runner-cloudrun`, `cp-job-runner-runbook`, `cp-job-hardening`, `cp-dispatch-loud-log`, `cp-getjobs-readpath`/`query-param` merged through the job read-path train)

The 29-bug bring-up ladder — bugs 1–15 (cause → fix; ledger = `.planning/experiments.jsonl`, `.planning/CHECKPOINT.md`):

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
- `bb8d061` merge worktree-agent-a478d283 — CAS pick + periodic resume + running-lease (runner-honoring resume = bug 15; fix landed in `a0edb19`)
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
- **F1 (token rotation):** CLOSED — `sk-ant-oat01-…` revoked; fresh credential in SM v4, old versions disabled. See §k.

---

## (f) Growth & product — README, site, PR-footer CTA, strategy, self-improve skill

The README was rebuilt twice: an install-first front door, then a launch rewrite
that leads with the cloud-maintainer rr loop (one-liner + 3-command onboard +
receipts). A separate site repo carries the hero/proof/team/growth pages. The
viral loop's #1 starter — the **PR-footer CTA** — ships in `issue_pr.py` alongside
`rr status`, loud enroll, and a dedup notice. A teams growth strategy doc maps the
Slack playbook to `hmd` with wave-gated phases and a Cursor-for-teams revenue
model. A self-improve/autoresearch corpus plus a **deployed-shape preflight**
(warn-only in the deploy scripts) encodes the 29-bug lessons so future bring-ups
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
- Releases in-window: `81826b5` v2.0.6 · `bdd76f8` v2.0.7 · `c9b4cb3` v2.0.8 · `fba3d7f` v2.0.9 · `1835f75` v2.0.10 · `1c42efd` v2.0.11 · `6202149` v2.0.12 · `b0616d5` v2.0.13 (the aborted `v2.1.0`/`v3.0.0`/`v9.9.9` autobump-test tags were reset, never on main)

---

## (h) The final arc — bugs #16–#29 and the first autonomous PR

**The headline:** after 29 deployed-shape bugs fixed, the cloud maintainer ran
end-to-end and opened **PR #5 on `randomittin/heimdall-maintainer-test`** —
correct `sum_range` off-by-one fix, authored under bot identity, clean diff
scope. Proven on real Cloud Run + Firestore. No hand-holding.

Bugs 16–29 (cause → fix):

16. **F2-condition-ripple** — `--condition=None` missing on unconditional project
    IAM bindings; the F2 SA-narrowing broke them silently. `052d5a6`, `15f3f2c`
17. **tick-blocked-unbounded-scan** — unbounded `list_names` Firestore scan
    blocked the tick thread; bounded reads + prefix pushdown + page-cap + 55-sec
    watchdog per step. `9305e35`, `484fba9`
18. **W4-env-dropped-on-redeploy** — `RR_TENANT_AUTHZ` + `TEAM_CRED_STORE`
    silently dropped by a destructive `set-env-vars` on a direct go-live run,
    disabling the drain. `181d9b2`
19. **rev-none-cas-exhaustion** — legacy rev-less Firestore records were
    unclaimable; CAS exhaustion conflated with empty queue (silent drop). Loud
    CAS exhaustion + `_rev_of` rev-None parity. `e063b05`, `361a15e`
20. **fix-cycle-never-invoked-claude** — the fix cycle emitted log lines but
    never actually called `claude`; added headless flags, loud `fix_attempt`
    telemetry, `HEIMDALL_FIX_WITH_CLAUDE` gate. `19a99f9`, `bf455fe`
21. **pr-no-diff** — `gh pr create` ran before `git commit`+`push`, so the
    opened PR carried no diff. Fix: commit fix onto `heimdall/issue/<id>` (bot
    identity), push via token-in-env (`force-with-lease`, never main), THEN
    create PR. `848ef19`, `96f1b8e`
22. **claude-config-dir-lost-in-chain** — `CLAUDE_CONFIG_DIR` dropped through
    the handler→fix-child env chain; `claude` headless could not locate its
    credential. Path threaded through both links. `f8dfb2e`, `c0e2dc7`
23. **corrupt-credential-ingestion** — the setup-token was stored as a decorated
    blob (full `claude setup-token …` invocation string), not the raw key;
    ingestion never stripped the decoration → every fix attempt authed with
    garbage. Shared `claude_cred` oracle added at client (`rr connect`) and
    server (`/team/cred`). `4416623`, `5554034`
24. **pytest-not-in-image-and-dirty-scope** — container lacked `pytest` and the
    target repo's dependencies; pushed branch included `__pycache__`/venv.
    Bootstrap deps before evidence run; strip non-source files from the pushed
    branch. `5facaa6`, `0fb43dc`
25. **whole-suite-as-gate** — evidence ran the entire test suite, not the
    issue-specific named test; non-deterministic cross-issue failures. Gate on
    the issue's named gating-test node (injection-safe extraction); whole-suite
    demoted to advisory. `9cc8c4d`, `17fa2a2`
26. **app-jwt-fallback-in-gh** — `gh pr create` fell back to App-JWT (not
    installation token) when `GH_CONFIG_DIR` was unset; PR created under App
    identity instead of bot. Fix: single cleaned installation token + isolated
    `GH_CONFIG_DIR`, no fallback. `51d16d2`, `34ef3e0`
27. **test-not-reconciled-to-bug21** — `heimdall-issue-pr-bot` test used the
    pre-bug-21 contract; post-push semantics broke it. Updated: hermetic bare
    origin + bot-identity branch assertion. `da36a70`, `6cef006`
28. **KEYSTONE — phantom-PR_OPEN** — `open_pr`'s return value was discarded; a
    `gh pr create` failure silently faked `PR_OPEN`. Every run since bug #21 had
    been reporting success while failing. New honest `PR_FAILED` state (branch
    pushed, PR not created): flagged, loud, re-runnable; `pr` node propagated to
    the job row. See §(m) for the meta-lesson. `3672b8a`, `1b10c2f`
29. **gh-pr-create-no-git-repo** — `gh pr create` ran with the agent's CWD (no
    `.git`), not the clone root; `not a git repository` error on run 15. Fix:
    `--repo <slug>` + `cwd=<clone>`. `a28b12e`, `28dc8dd`

**Result:** `10a036d` — `heimdall: checkpoint — FIRST AUTONOMOUS PR (#5) landed;
bugs 1-29 closed, maintainer proven end-to-end`.

---

## (i) Prompt-injection hardening of the fix-step

The fix-step runs `claude` (headless) against untrusted issue content. Two
hardening commits landed before the final run arc:

- `cf3c7b5` / `63ee326` fix(security): **Bash dropped from coder tools** in the
  fix-child invocation; untrusted issue content reframed as
  `<untrusted-content>`; child env scrubbed of all credentials not needed for
  the fix cycle (only `CLAUDE_CONFIG_DIR` + a scoped `GH_TOKEN` pass through).
  A malicious issue body cannot escape the diff surface via shell execution.

---

## (j) Idle-agent auto-reaper

Stale worktrees and orphaned pollers leaked disk + poll cycles across sessions.
A new `bin/heimdall-reap-idle` script reaps them automatically:

- `a714e74` / `17ea17a` feat(reap): **merged worktrees reaped on SessionEnd**;
  **unmerged worktrees always kept** (no data loss). Orphaned pollers (background
  `hmd team` processes without a live session) swept. SessionEnd hook runs
  `--apply` immediately; SessionStart hook prints a hint if stale worktrees
  remain. Falsifier-tested: a worktree with unmerged commits survives reap.

---

## (k) Release hygiene — gitleaks unblock, token rotation, v2.0.13

Several hygiene items closed the window before v2.0.13 ship:

- **Gitleaks history unblock** — `5502677` broke the token-shaped sentinel in
  the team-queue test fixture (a benign literal mis-authored before the
  fixture-secret convention). `ea1315c` completed the unblock: broke all live
  fixture tokens per convention + added `.gitleaksignore` fingerprints for
  confirmed-benign history entries, unblocking the `ship.sh` gitleaks gate.
- **Token rotation (F1 CLOSED)** — the `sk-ant-oat01-…` key that appeared in
  history was revoked; a fresh credential stored in Secret Manager (SM v4), old
  versions disabled. F1 from the security audit (§e) is now CLOSED.
- **Stray bot-branch cleanup** — orphaned `heimdall/issue/*` branches left by
  failed pre-#28 runs cleaned from `randomittin/heimdall-maintainer-test`.
- **v2.0.13** — `b0616d5` chore(release): v2.0.13 — the final arc pushed,
  tagged, and released.

---

## (m) Meta-lesson — the deployed-shape / silent-failure class

The last ~14 bugs (#16–#29) all share a pattern: **silent success masking real
failure**, each invisible until the prior loud-guard forced the noise outward.
The progression is not coincidence — it is the shape of layered silent-failure
systems revealing themselves one guard at a time.

**Bug #28 is the architectural keystone.** By discarding `open_pr`'s return
value, the loop had been reporting `PR_OPEN` for every run since bug #21 — even
when `gh pr create` failed. No test caught it because none asserted the loop's
returned state. Fixing it turned every subsequent run's phantom success into an
honest quoted error, and bugs #29 through the first autonomous PR fell quickly
after.

The recurring pattern that exposed each new layer: **surface the real error,
named and scrubbed, never a silently caught exception**. Applied at: tick
exhaustion (#19), fix-cycle invocation (#20), PR create result (#28), `gh` CWD
(#29). The `error_tail` discipline from bug #6 is the same lesson, twelve bugs
earlier.

---

## Current live state

- **Tenant:** team `6ca551f2`, install `144263218`, repo
  `randomittin/heimdall-maintainer-test` (4 maintainer issues seeded).
- **Services/images:** both gated and public images rebuilt and released as
  v2.0.13. Background tick healthy at 1/min.
- **Proven end-to-end:** PR #5 opened autonomously on
  `randomittin/heimdall-maintainer-test` — correct `sum_range` off-by-one fix,
  bot identity, clean diff scope, real Cloud Run + Firestore. All 29 bugs
  closed.
- **Head:** `b0616d5` (main = origin/main, PUSHED, released v2.0.13).

## Outstanding items

- **F1 token rotation** — CLOSED: `sk-ant-oat01-…` revoked; SM v4 active, old
  versions disabled (see §k).
- **Gitleaks gate** — CLOSED: `ea1315c` unblocks `ship.sh` (see §k).
- **Site repo** — hero/proof/team/growth pages live in the separate site repo
  (`4c3362e`); independent of this tree.
- **Spend-cap tuning** — per-team/day caps shipped (`13f3ce6`); further parameter
  tuning deferred to post-v2.0.13.

## Test-coverage stats (as sourced; honest)

`git` is now available in this environment; a fresh `pytest` run gives exact
counts. The following are concrete, ledger-traceable figures from the bug-fix
arc:

- **Bug ladder:** 29 found; **29 verified** (all `verified-in-prod` or
  `verified-by-test` per `.planning/experiments.jsonl`). No open bugs.
- **cp-wired §10 assembly gate** (`56d2eea`): full signed-HTTP flow gate;
  falsifiable — commenting `boot()` drops it 34 → 24/10.
- **cp-getjobs read-path** (`2c5d24a` train): 10/10, with query-mismatch
  falsifiers → 401 either direction.
- **cp-public-surface boundary falsifier** (`31c92c2`): gated routes must 404 on
  the public service.
- **maintain-loop** (`19113ab`): 41/41 with cp-maintainer 27/0 + cp-job-execution 41/0.
- **idle-agent reaper falsifier** (`17ea17a`): unmerged worktree survives reap.
- **README GENERALIZES claim** (`b4b84fc`): honest 0.50/8 repos → `/proof`.
- **Audits** (`docs/analysis/`): security = CONDITIONAL GO → F1 CLOSED, F2
  applied; prod-readiness top-5 all closed; viral-readiness PR-footer CTA
  shipped.
