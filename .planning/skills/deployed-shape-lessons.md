# deployed-shape-lessons — the reasoning-bank pattern the 14-bug saga distilled

A [self-improve](../../skills/self-improve/SKILL.md) reasoning-bank entry mined from the 14
completed experiments in [.planning/experiments.jsonl](../experiments.jsonl) (the
cloud-maintainer bring-up saga, 2026-07-04/05). Each incident is a real fix with a named
cause and a recorded outcome; this page is the *cluster analysis* — the reusable lesson, not
the individual patches (those live in the commits the log references).

## The three hypothesis clusters (mined from the corpus)

The 14 incidents cluster into three dominant classes plus a residual. The dominant class by a
wide margin is **A: deployed-shape / workstation-assumptions** — code that was correct on a
developer laptop and wrong in a cold, ephemeral, least-privilege Cloud Run container.

### A. Deployed-shape / workstation assumptions (10 of 14 — the dominant class)
Incidents **1, 2, 4, 5, 8, 9, 10, 12, 13, 14** (+ the June `path()`-class of prod-only breaks).
The container is not the laptop: its `$HOME` is fresh, its CWD is read-only, its IAM is
least-privilege, its env is Cloud-Run-reserved-name-laden, its image is only what the
Dockerfile installed, and its CPU is throttled off-request. Every one of these bugs is a local
assumption that silently held on the workstation:
- a dep in the local venv but not the image (1)
- prod least-privilege IAM the workstation never enforces (2)
- a default job name that only diverges once a *named* job is deployed (4)
- an env override that a local runner passes through but the cloud runner dropped (5)
- CPU throttling that only exists off the request path in Cloud Run (8)
- Cloud-Run-reserved env names (`PORT`, `K_*`) that only a RunJob request rejects (9)
- a local gate file / usage history / planning dir that a cold container simply does not have (10, 12, 13)
- wiring that "obviously" runs locally but had zero callers in the deployed path (14)

### B. Two-image version skew (incident 11 + the service/job split generally)
The control-plane ships as **two images** — the SERVICE (the tick) and the JOB (the maintainer
runtime). A `bin/lib` change rebuilt into one image but not the other produces a skew: incident
11 was a stale JOB image carrying an old allowlist while the service moved on. Any change to
shared `bin/lib` code is a change to BOTH images.

### C. Silent-failure observability (incident 6 + the pre-`error_tail` exits)
A subprocess failed, its stderr was captured, and nobody surfaced it — the task was consumed
silently with no retry and no diagnosable trail (incident 6). The same shape produced the
"exited before `error_tail`" mysteries: a failure with no scrubbed stderr on the way out.

### Residual (not one of the three big classes)
Incidents **3** (a tab-collapse ate a control-flow branch) and **7** (a drain enumeration
scope miss) are ordinary logic bugs — recorded for completeness, but they carry no reusable
deployed-shape lesson and are out of the static checker's scope.

---

## The reusable pattern

### Trigger
You are about to change `bin/lib/*.py` (or any code that runs inside the deployed
control-plane), OR you are about to deploy. Reach for this whenever code reads **local state**
(a file, a config, a usage history, the CWD), threads an **env override** into an outbound
request, shells out to a **subprocess**, or assumes a dependency/identity/CPU budget the
workstation happens to provide.

### Steps
1. **Any code reading local state (file, config, usage history, CWD) MUST have an env override
   AND a defined fresh-home semantic.** A cold container's `$HOME` is empty and its CWD is
   read-only. Gate on an env var first; default to a *fresh-home* behaviour (armed/disarmed,
   zero-usage, cloned-workspace), never fail-closed on absence. (1, 10, 12, 13)
2. **Never join a repo slug onto the CWD as a writable path.** A slug (`owner/name`) is not a
   checkout. Clone into an explicit writable workspace and build paths from *that*. (13)
3. **Strip Cloud Run reserved env names** (`PORT`, `K_SERVICE`, `K_REVISION`,
   `K_CONFIGURATION`, any `K_*`) from every outbound env override — the platform injects them
   and rejects a RunJob request that sets them. (9)
4. **Thread, do not drop, the per-execution env override** (per-team cred + minted token) into
   the request the cloud runner builds — a passthrough that works locally can be silently
   dropped by a different runner. (5)
5. **Every `bin/lib` change requires BOTH images rebuilt** (service AND job) and any pinned
   allowlist/digest re-resolved. Assume nothing about the other image. (11)
6. **Every subprocess failure must surface scrubbed stderr** (and retry where appropriate).
   Capture `stderr`, and on a nonzero exit write the scrubbed tail — never consume a failure
   silently. (6)
7. **Prove the deployed dep/identity/CPU shape**, not the laptop's: pin deps in the image,
   enforce least-privilege in a preflight, run background ticks `--no-cpu-throttling`, and
   verify the wiring has a real caller in the *deployed* path. (1, 2, 8, 14)

### Why
Ten of fourteen bugs in a single bring-up were workstation assumptions that held locally and
broke only in the deployed shape — they are invisible to unit tests run on a laptop because the
laptop *is* the false environment. The cost is compounding: each one shipped, failed in prod,
and cost a diagnose-from-logs round trip (several were "prod-only breaks" that work fine
locally). A cheap static preflight that flags the recurring *shapes* — before deploy, with no
creds — converts that expensive prod-only feedback loop into an instant local warning.

## The validated improvement built from this pattern
`bin/heimdall-deployed-shape-check` — a stdlib-`ast` static preflight that flags steps 1, 2, 3
and 6 as `file:line` warnings (slug-onto-CWD paths, unguarded local-state reads, reserved env
names in override dicts, captured-but-ignored subprocess stderr). It is **falsifiable**: it
flags the reconstructed pre-fix snippets of incidents 6, 9, 10 and 13, and passes their fixed
forms — proven by `test/heimdall-deployed-shape-check.test.sh`. It is wired **WARN-only** into
`deploy/cloud-run/deploy-arch-b.sh` and `go-live.sh` (a bounded experiment; promotion to
blocking is `--strict`, once it earns it). Escape hatch for an intentional site:
`# deployed-shape-ok: <reason>`.
