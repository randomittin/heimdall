---
title: 8 bugs that only existed in production
published: false
description: The cloud maintainer's first autonomous PR landed on real Cloud Run + Firestore after a 29-bug bring-up. Eight of those bugs, with the commit and the test that now catches each one.
tags: cloudrun, firestore, testing, postmortem
canonical_url: https://runheimdall.dev/log-deploy-saga.html
---

_DRAFT — awaiting RJ editorial pass, not published. `published: false` above must stay `false` until RJ clears it._

The cloud maintainer's first autonomous PR landed on real Cloud Run + Firestore — a real issue, a real fix, a real PR a human merged. It took a **29-bug bring-up** to get there. The dominant late class of those bugs had one shape, every time: **green on a laptop, broken in the deployed container.**

This is eight of them — what we saw, why the laptop lied, the actual root cause, the fix, and the test that now stops it from coming back. No invented bugs, no rounded numbers — every claim below traces to a commit. The full 29-bug ladder (not just these eight) lives on [the proof page](https://runheimdall.dev/proof.html#bringup).

## Why local was green

"Local green" is not evidence. It's the whole thesis Heimdall is built around, and it's also, honestly, how we found out the hard way. Standing up the control plane — the service that dispatches work and the Cloud Run Job that executes it, backed by Firestore instead of a laptop's filesystem — surfaced 29 real bugs before the maintainer ever opened a PR on its own.

The pattern that kept recurring: a Cloud Run container is not a developer laptop. Its filesystem is read-only outside a scratch dir. It has no `gcloud` SDK unless the Dockerfile put one there. Its storage backend is Firestore, not a real directory tree, so anything that assumes a filesystem `path()` exists is one deploy away from breaking. And a Google Front End load balancer sits in front of every request, with its own opinions about HTTP that a local dev server never enforces. None of that is visible to a unit test run on the machine that wrote the code — the laptop *is* the false environment.

## 1 · The container had no `gcloud`

**What we saw:** Jobs queued cleanly but never ran. No crash, no error in the service logs — the task simply stayed queued forever.

**Why local was green:** The dispatcher shelled out to `gcloud run jobs execute`. On every developer machine, the Google Cloud SDK is already installed and on `PATH` — the subprocess call just worked, every time, in every local run.

**Root cause:** The Cloud Run image never installed the `gcloud` SDK. Dispatch shelled a binary that didn't exist in the container.

**The fix:** Dispatch moved off the shell entirely: `JobsClient().run_job(RunJobRequest(...))` over the Cloud Run Jobs `run_v2` API, authenticated with Application Default Credentials — no subprocess, no external binary. The import is lazy so a local run without the extra dependency installed stays green.

- commit: `cd88ad0`
- test: `test/cp-job-execution.test.sh`
- date: 2026-06-26

## 2 · The container had no writable filesystem — and no checkout

**What we saw:** The maintainer's cloud job crashed at startup: `PermissionError` trying to create its own planning directory.

**Why local was green:** Locally, `--repo owner/name` resolves against a real working checkout already sitting in the current directory. The code joined that repo slug onto the CWD as though it were always a checkout path — and on a laptop, the CWD is always a writable git repo, so the join always landed somewhere real.

**Root cause:** The cloud job has no checkout at all. Its CWD is `/app`, the read-only application image root. A bare slug like `owner/name` joined onto `/app` produced a path that was neither writable nor a real repo, and `os.makedirs()` raised.

**The fix:** A new `resolve_workspace()` step: an existing local dir is reused unchanged (so a workstation run stays byte-identical), a bare slug is shallow-cloned into a writable `$HEIMDALL_HOME/work/<owner>__<repo>`, and a traversing or ill-formed slug is refused fail-loud before any path is ever joined.

- commit: `19113ab`
- test: `test/heimdall-maintain-loop.test.sh` (41/41)
- date: 2026-07-06

## 3 · `path()` is refused by design under Firestore

**What we saw:** The background tick errored every 60 seconds in the live Cloud Run logs — `BackendUnavailable` — on a code path that was clean in every local and hermetic test.

**Why local was green:** The local storage backend is a real filesystem, so calling `.path()` on it legitimately returns a filesystem path — every `open(backend.path())` or `os.path.isdir(backend.path())` call worked, every time, locally. The Firestore-backed production storage refuses `path()` by design — a Firestore document has no filesystem path to give you — but nothing in the calling code accounted for that.

**Root cause:** This wasn't one bug, it was one bad assumption baked into six independent call sites over time: the tick's owner-registry read, the dashboard's `stored_instances` scan, `cp_ingest`/`cp_notify`'s result payload, and the CLI `status` command all called `backend.path()` and treated the local-only behavior as universal.

**The fix:** Each call site was swept, one at a time across several commits, off `path()` onto backend-safe primitives — `get_record()`, `exists()`, `append_line()` — that both backends implement without leaking filesystem semantics. The tick incident specifically moved to reading the owner registry through `cp_auth.owner_haids()` instead of opening a file at a path.

- flagship commit: `7e83432` (tick); class also `f0bd1a2`, `3f6f8ff`, `fd9e267`, `bf1d47e`, `9ed4280`, `a75d97f`, `b601e76`
- test: `test/cp-tick-firestore.test.sh`
- date: 2026-06-25

## 4 · A doc-id collision quietly dropped a team's presence

**What we saw:** A team's presence would intermittently vanish from the live roster: visible on write, invisible on read, no error either side.

**Why local was green:** The hermetic presence test ran on the local filesystem-backed storage, where a doc-id containing a literal `__` is just two underscores in a filename — it round-trips fine. Nothing about that test could see what Firestore does with the same string.

**Root cause:** The production Firestore backend uses `__` internally as its own separator, encoding a nested path into a flat document-id namespace. The presence slug generator could itself emit `__`, so a slug like `team__x` collided with the backend's own encoding and got read back as a different node than the one written to.

**The fix:** Any run of underscores in a generated slug now collapses to a single `_` before it's used as a doc-id, so the write path and the read path can never disagree about what the flat key actually is.

- commit: `9806bb9`
- test: `test/cp-presence-firestore.test.sh`
- date: 2026-07-07

## 5 · The job finished — into a document the service never read

**What we saw:** A dispatched job's own logs reported `done`. The service that had dispatched it kept polling, never saw completion, and looked hung indefinitely.

**Why local was green:** Locally, the "job" and the "service" are the same process sharing one storage identity by construction. There was no way for them to disagree about which document they meant, because there was only ever one.

**Root cause:** The Cloud Run Job runs as a genuinely separate container from the service. Nothing propagated the service's exact Firestore identity — backend, project, root prefix, and the one that actually bit, the **database coordinate**, which had silently stayed pinned to `(default)` — into the job's environment. Job and service could each resolve a valid-looking but different Firestore document for the same job id.

**The fix:** Dispatch now threads the service's complete storage identity into the Job's environment overrides, so the Job writes the literal document the service is polling, by construction rather than by convention.

- commit: `0855535`
- test: `test/cp-job-writeread.test.sh` (8/8, incl. a drift falsifier)
- date: 2026-06-26

## 6 · A swallowed error degraded every roster read to a full scan

**What we saw:** The live team roster came back empty on Firestore, even though presence writes were landing cleanly. This one is unusual: it worked in production too, for a while.

**Why local was green:** The bounded read tried to build a server-side document-id range query, but two things were wrong with it and both failed silently: `firestore.FieldPath.document_id()` isn't actually exported at the top level of the pinned client (`google-cloud-firestore==2.16.1` exposes only `FieldFilter`), so it raised `AttributeError` — and that was caught and swallowed, silently degrading the "bounded" read into a full-collection scan. On a small collection, a full scan is still fast enough to return everything inside the timeout, so it looked correct everywhere — local, staging, and early production.

**Root cause:** As the production `heimdall_cp` collection grew past what a full scan could finish inside a 20-second timeout, the degraded scan started timing out and returning `[]` — a real backend read failure silently reported as "nobody's online." A second, independent bug compounded it: even when the range filter did build, it compared the document-id against a plain string instead of a `DocumentReference`, which Firestore never matches.

**The fix:** The document-id sentinel is now the literal `"__name__"` string (no version-fragile import), bounds are built from real `col.document(id)` references so the range filter actually pushes down server-side, and a read that fails now writes one loud `stderr` line so an empty roster caused by a backend error is never indistinguishable from an idle team again.

- commit: `173f7d8` / `d6d0bec`
- test: `test/cp-presence-firestore-pushdown.test.sh`
- date: 2026-07-10

## 7 · Google's load balancer rejects a GET with a body

**What we saw:** A signed read-back of a job's state worked fine hitting the handler directly, but over real HTTP against the deployed Cloud Run service, the client got a bare `400` before any application code ran.

**Why local was green:** Local testing drove the handler function directly (or through a plain local HTTP server), which doesn't sit behind Google's Front End (GFE) load balancer — the thing that fronts every Cloud Run service in production. Our authorization code was never wrong; it never got the chance to be, because the request never arrived.

**Root cause:** The client sent the signed `job_id` as a JSON body on a `GET` request. HTTP technically allows a body on `GET`, but GFE rejects it outright at the edge — a platform-level behavior with zero local equivalent.

**The fix:** `job_id` moved to a signed query parameter. The signing scheme now covers the full path-with-query, so a `GET` carries an empty body and existing query-less `POST` routes verify byte-identically.

- commit: `2c5d24a`
- test: `test/cp-getjobs-query-param.test.sh` (10/10)
- date: 2026-06-26

## 8 · A discarded return value faked 15 straight successes (KEYSTONE)

**What we saw:** For 15 straight maintainer runs, the loop reported opening a pull request — `PR_OPEN` — even on runs where `gh pr create` had actually failed.

**Why local was green:** This one isn't a deployed-shape bug — it's the silent-failure class, and arguably the more dangerous one: `open_pr()`'s return value was discarded by its caller. There was no branch for "it failed," locally or in prod, because nothing ever checked. Early in development `gh pr create` happened to succeed every time it was exercised, so the missing check never got a chance to matter until a real failure (an expired token, a wrong `--repo`, a git-identity mismatch — three separate causes fixed individually in bugs #21, #26, and #29) hit it.

**Root cause:** A classic discarded-result bug, just in a place where the result was "did we actually tell the truth about what happened." The loop kept reporting the same optimistic state regardless of what `gh pr create` actually did.

**The fix:** The caller now honors `open_pr`'s return value. A failed create produces an honest `PR_FAILED` state — branch pushed, PR not created — flagged and re-runnable, with the failure propagated loudly to the job row instead of a fabricated `PR_OPEN`.

- commit: `3672b8a`
- test: `test/issue-loop.test.sh`
- date: 2026-07-06 — the same day the first autonomous PR landed

This is the bug that mattered most. Every deployed-shape fix above closes a gap between the laptop and the container — but this one closes the gap between what the system *did* and what it *said* it did. Fixing it is what let the next real run report the truth instead of a phantom green, and the truth was: a PR actually opened.

## The lesson wired in

Every one of these bugs is a variation on the same failure: a test that can only pass locally isn't proof, it's a laptop's opinion. The fix wasn't "write more tests" in the abstract — it was making **firestore-mode** and **deployed-shape** coverage a structural requirement for any code that stores state or dispatches work, and making every failure surface loudly instead of degrading silently. Two concrete things came out of this saga and are load-bearing in the codebase today:

**A static deployed-shape preflight.** `bin/heimdall-deployed-shape-check` is a stdlib-`ast` static checker that flags the recurring shapes above — slug-onto-CWD paths, unguarded local-state reads, Cloud Run reserved env names in an override dict, captured-but-ignored subprocess `stderr` — as `file:line` warnings before a deploy ever runs. It's proven against the reconstructed pre-fix snippets of several of these bugs and their fixed forms, wired warn-only into the deploy scripts today.

**The error_tail discipline.** Bug 6's silent `AttributeError` and bug 8's discarded return value are the same shape at different layers: something failed, and the system reported success anyway. Every subprocess and backend read in the maintainer loop now surfaces a scrubbed failure reason on the way out — a stuck task gets a name, not a shrug.

None of this is a claim that the bugs stop coming. It's a claim that the next one gets caught by a test that can actually go red, on the shape that actually ships — not by whoever notices production is quiet.

---

*Full post + the complete 29-bug ladder: [runheimdall.dev/log-deploy-saga.html](https://runheimdall.dev/log-deploy-saga.html) · [runheimdall.dev/proof.html](https://runheimdall.dev/proof.html)*
