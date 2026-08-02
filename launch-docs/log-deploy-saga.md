---
title: Local green is not evidence
date: 2026-07-16
updated: 2026-08-03
slug: log-deploy-saga
description: The cloud maintainer's first autonomous PR landed on real Cloud Run and Firestore after a 29-bug bring-up. All 29, named — what broke, and what catches it now.
tags: [deployed-shape, cloud run, firestore, silent failure, postmortem]
author: Heimdall Engineering
read_time: 10 min read
canonical: https://runheimdall.dev/log-deploy-saga.html
crosspost:
  - dev.to      (canonical_url: https://runheimdall.dev/log-deploy-saga.html)
  - Hashnode    (Original article URL: https://runheimdall.dev/log-deploy-saga.html)
---

The first pull request the cloud maintainer opened without a human in the loop was a one-line
off-by-one. `sum_range` dropped its final element. The maintainer read the issue, cloned the
repo, wrote the fix, ran the named gating test, pushed a branch under a bot identity, and opened
PR #5 on `randomittin/heimdall-maintainer-test`. Real Cloud Run. Real Firestore. Clean diff scope.

Getting to that one-line diff took 29 bugs.

None of the 29 were in the fix. All of them were in the machinery between an issue and a pull
request, and the dominant late class had one shape: green on a laptop, broken in the container.
This is the whole ladder, named, with the commit that closed each one.

## The container is a different machine

A Cloud Run container has a fresh `$HOME` with no history in it. Its working directory is the
read-only application image root. Its IAM is least-privilege, not "whatever your gcloud is logged
into." Its environment carries platform-reserved names you are not allowed to set. Its CPU is
throttled the moment it stops serving a request. It contains exactly what the Dockerfile
installed and nothing else.

Every one of those is a property your workstation quietly provides the opposite of. So a test run
on the workstation cannot see any of them. The laptop is not a weak environment for testing. It
is a false one.

Of the 29, ten were straight workstation assumptions. The rest were the second family, which
turned out to be worse: silent failure. Something broke, nothing said so, and the system reported
success.

## Act one — getting the container to run at all

**1 · missing-sm-dep.** `/team/cred` returned 503. `google-cloud-secret-manager` was installed in
the local venv and absent from the control-plane image. Fixed by adding the dependency and a
build-time import guard, so a missing client fails the image build instead of the first request.
`96cfc19`, `1460ec0`

**2 · cred-forward-least-priv.** Under production least-privilege, the public service could not
write Secret Manager. Nothing on a workstation enforces that boundary, so it never appeared until
the real IAM did. Public now forwards to the gated `/team/cred` over authenticated
service-to-service with a `run.invoker` grant; read and dispatch stay forbidden on the public
surface. `cca7381`, `fa23a7d`

**3 · rr-mode-routing-tab-collapse.** A tab collapse ate the `mode=control-plane` branch, so bare
`rr` went back to SSH instead of `POST /rr-task`. An ordinary logic bug, recorded because the
ladder is the ladder. `00b0b3f`

**4 · job-name-mismatch-env.** The dispatcher defaulted to `heimdall-long-job`. The deployed job
was `heimdall-maintainer-job`. A default only diverges once a real named job exists, which happens
exactly once, in production. `ef83e77`

**5 · per-team-env-dropped-jobrunner.** `CloudRunJobRunner.build_request` dropped `base_env`, so
the dispatched job ran without the per-team credential it was supposed to carry. A pass-through
that works in a local runner can be silently dropped by a different runner. The per-team
credential and minted token are now threaded into the per-execution env override. The standing
guard is the isolation oracle: `bin/falsify rr-multitenant-isolation --assert-score 1.0`, where
every mutant is a real attack and the run fails unless every one is killed. `9c5aca5`

**6 · silent-task-consumption.** A task subprocess failed. Its stderr was captured. Nobody
surfaced it. No error, no retry, no trail — the task was simply consumed. This is the shape that
produced most of the later mysteries, and it is now a rule: on a nonzero exit, write the scrubbed
stderr tail, retry where retrying is correct, and never consume a failure quietly.

**7 · drain-enumeration-scope.** The drain enumeration missed queued tasks, so the warm tick
drained nothing and looked healthy doing it.

**8 · cpu-throttle-starved-tick.** Cloud Run throttles CPU off the request path. The background
tick ran on that path and starved. There is no local equivalent to test against. Fixed with
`--no-cpu-throttling` and `min-instances=1`. `2629489`, `beba40c`

**9 · reserved-env-names-in-overrides.** The per-execution env override carried `PORT`,
`K_SERVICE`, `K_REVISION` and `K_CONFIGURATION`. Cloud Run injects those itself and rejects a
RunJob request that sets them. They are stripped now.

**10 · local-maintainer-enabled-gate.** The maintainer armed itself by reading a
`.maintainer.enabled` file. A cold container has no such file and never will. The gate is an env
override with a defined fresh-home behaviour instead.

**11 · stale-job-image-allowlist.** The control plane ships as two images: the service that ticks
and the job that executes. A `bin/lib` change rebuilt into one of them produced a job image
carrying an old allowlist while the service moved on. Any change to shared code is a change to
both images.

**12 · budget-meter-fail-closed-fresh-home.** The budget meter fail-closed when it found no usage
history. A cold container always has no usage history, so the meter refused to run the thing it
was metering. Fresh home is now a defined state, not an error.

**13 · planning-dir-slug-readonly-cwd.** The archetype. The planning directory was built by
joining a repo slug — `owner/name` — onto the current working directory, because on a laptop the
CWD is always a writable checkout, so the join always landed somewhere real. In the container the
CWD is `/app`, the read-only image root, and there is no checkout at all. `os.makedirs()` raised
`PermissionError` at startup. A slug is not a path. `resolve_workspace()` now reuses an existing
local directory unchanged, shallow-clones a bare slug into a writable workspace, and refuses a
traversing or malformed slug loudly before anything is joined. `19113ab`,
`test/heimdall-maintain-loop.test.sh` (41/41)

**14 · issue-queue-never-ingested.** `issue_queue.ingest` had zero callers. The queue was never
populated. The function was correct, tested, and unreachable — wiring that "obviously" runs, with
nothing in the deployed path actually running it. `gh issue list` now feeds `ingest_many`.
`66c3ee0`

**15 · resume_orphans-in-process-steal.** This one cost the most time. Jobs failed with an
876-line traceback pointing at code the job image did not contain. The job image was byte-verified
correct. `cp_worker.run_job` ignored `HEIMDALL_JOB_RUNNER`, so any service instance booting up
would claim queued jobs and execute them in-process, using the gated service's own stale code
instead of dispatching them to the job. The traceback was real. It was just from the wrong
machine. Resume now re-dispatches through the configured runner and never runs in-process when the
runner is remote, with a five-minute grace for young queued jobs, a two-hour running-orphan lease
with one reclaim, and a loud `resumed-via=` line so the answer to "who actually ran this" is in
the log. `a0edb19`, `test/cp-jobs.test.sh` (38/0)

## Act two — getting a fix to actually happen

The container ran. It still could not fix anything, and it did not say so.

**16 · F2-condition-ripple.** Unconditional project IAM bindings need `--condition=None`. Without
it, a binding-narrowing pass broke them without complaining. `052d5a6`, `15f3f2c`

**17 · tick-blocked-unbounded-scan.** An unbounded `list_names` scan over Firestore blocked the
tick thread. Reads are bounded now, with prefix pushdown, a page cap, and a 55-second watchdog per
step. `9305e35`, `484fba9`, `test/cp-tick-watchdog.test.sh`

**18 · W4-env-dropped-on-redeploy.** A destructive `set-env-vars` during a direct go-live run
dropped `RR_TENANT_AUTHZ` and `TEAM_CRED_STORE`, which disabled the drain. The deploy reported
success. `181d9b2`

**19 · rev-none-cas-exhaustion.** Legacy revision-less Firestore records were unclaimable, and
compare-and-swap exhaustion was conflated with an empty queue. A backed-up queue looked idle.
Exhaustion is loud now. `e063b05`, `361a15e`

**20 · fix-cycle-never-invoked-claude.** The fix cycle emitted every log line you would expect
from a fix cycle and never called `claude`. It looked like it was working because it was narrating
work it never did. Headless invocation, a loud `fix_attempt` telemetry node, and an explicit
`HEIMDALL_FIX_WITH_CLAUDE` gate landed together. `19a99f9`, `bf455fe`,
`test/issue-loop-claude-fix.test.sh`

**21 · pr-no-diff.** `gh pr create` ran before `git commit` and `git push`, so the pull request it
opened contained nothing. The fix commits onto `heimdall/issue/<id>` under bot identity, pushes
with the token in the environment (`--force-with-lease`, never to main), and only then creates the
PR. The test asserts the branch reached origin, and that a push failure does not produce a
dangling PR. `848ef19`, `96f1b8e`, `test/issue-pr.test.sh` §6

**22 · claude-config-dir-lost-in-chain.** `CLAUDE_CONFIG_DIR` was dropped across the
handler-to-fix-child environment chain, so headless `claude` could not find its provisioned
credential and fell back to an interactive OAuth login prompt, inside a container with no human in
front of it. `f8dfb2e`, `c0e2dc7`, `test/heimdall-cp-maintainer.test.sh` (G3)

**23 · corrupt-credential-ingestion.** The setup token was stored as the entire decorated
invocation string rather than the key inside it. Ingestion never stripped the decoration, so every
fix attempt authenticated with garbage. A shared `claude_cred` shape oracle now runs at both ends,
client and server, and a malformed credential is refused rather than stored. `4416623`, `5554034`,
`test/heimdall-tenant-onboard.test.sh` §10, `test/heimdall-rr-cp.test.sh` §12

**24 · pytest-not-in-image-and-dirty-scope.** The container had neither `pytest` nor the target
repo's own dependencies, so a correct fix could not be proven. The same run pushed a branch
carrying `__pycache__` and virtualenv files. Dependencies are bootstrapped before the evidence run;
non-source paths are stripped from the pushed tree, and the test asserts every junk path is absent.
`5facaa6`, `0fb43dc`, `test/issue-pr.test.sh` §7, `test/issue-bootstrap.test.sh`

**25 · whole-suite-as-gate.** Evidence ran the target repo's entire test suite, so an unrelated
co-resident failure blocked a correct fix. The gate is now the issue's named gating-test node,
extracted injection-safely from the issue body. The whole suite is advisory. `9cc8c4d`, `17fa2a2`,
`test/issue-loop-claude-fix.test.sh` §8

**26 · app-jwt-fallback-in-gh.** With `GH_CONFIG_DIR` unset, `gh` fell back to the App JWT instead
of the installation token, and PRs were authored under the App identity rather than the bot. One
cleaned installation token, an isolated `GH_CONFIG_DIR`, no fallback. `51d16d2`, `34ef3e0`,
`test/issue-pr.test.sh` §8

**27 · test-not-reconciled-to-bug21.** The PR-bot test still encoded the pre-#21 contract, so it
went red on correct behaviour. A test that describes the old world is a liability with a green
checkmark. Rewritten against a hermetic bare origin with a bot-identity branch assertion.
`da36a70`, `6cef006`

## Act three — getting the truth out

**28 · phantom-PR_OPEN.** The keystone, and the reason the other twenty-eight took as long as they
did.

`open_pr()` returned a result. Its caller discarded it and hard-coded `PR_OPEN`. There was no
branch for failure anywhere in the loop, so every run since bug #21 had reported opening a pull
request, including the runs where `gh pr create` failed outright. Three separate real causes were
hiding under that green — an expired token, a wrong `--repo`, a git identity mismatch — and each
one was individually invisible, because the loop's answer to "what happened" was a constant.

No test caught it because no test asserted the loop's returned state. The fix is a `PR_FAILED`
state that is honest about what exists: the branch is pushed, the PR is not created, the run is
flagged and re-runnable, and the failure propagates to the job row instead of being overwritten by
optimism. The falsifier makes `gh pr create` fail while the push succeeds and asserts the run is
not recorded as `PR_OPEN`. `3672b8a`, `1b10c2f`, `test/issue-loop.test.sh` §6

**29 · gh-pr-create-no-git-repo.** With #28 fixed, the next run failed loudly for the first time:
`not a git repository`. `gh pr create` had been running with the agent's working directory, which
has no `.git`, rather than the clone. It had probably been failing that way for a while. Passing
`--repo <slug>` makes `gh` independent of the working directory, and the call runs with `cwd` set
to the clone. The falsifier reproduces the exact run-15 failure and proves the same non-git
directory succeeds once `--repo` is passed. `a28b12e`, `28dc8dd`, `test/issue-pr.test.sh` §9

With #29 closed, the loop ran end to end and opened PR #5.

## What we changed about how we test

Two things came out of this and are load-bearing today.

A static preflight. `bin/heimdall-deployed-shape-check` is a stdlib-`ast` checker that flags the
recurring shapes as `file:line` warnings before a deploy runs, with no credentials needed: a repo
slug joined onto the working directory, an unguarded local-state read, a Cloud Run reserved name in
an override dict, a captured-but-ignored subprocess `stderr`. It is falsifiable, which is the only
reason to trust it — it flags the reconstructed pre-fix snippets of bugs 6, 9, 10 and 13 and passes
their fixed forms, proven by `test/heimdall-deployed-shape-check.test.sh`. It is wired warn-only
into the deploy scripts. Promotion to blocking is `--strict`, once it has earned it. Intentional
sites use `# deployed-shape-ok: <reason>`.

Loud failure as a contract. Bugs 6, 19, 20, 28 and 29 are the same bug at five different layers:
something failed and the system reported success. Every subprocess and backend read in the
maintainer loop now surfaces a scrubbed failure reason on the way out. A stuck task gets a name
instead of a shrug. Bug #29 was findable at all because bug #28 made the machine capable of saying
"no."

The general rule we now apply: any code path that stores state or dispatches work needs a test that
runs in the deployed shape, and a failure mode that is loud enough to be diagnosed from a log.
Local green is a laptop's opinion about a machine it has never seen.

None of this claims the bugs stop. It claims the next one gets caught by a test that can actually
go red, on the shape that actually ships, instead of by someone noticing production has gone quiet.

*Nothing ships unproven.*

---

*Crossposted to dev.to and Hashnode. The canonical URL for both is
`https://runheimdall.dev/log-deploy-saga.html` — set `canonical_url` in the dev.to front matter and
paste the same URL into Hashnode's "Original article URL" field before publishing, so the canonical
version stays on the site.*
