# Unattended maintainer dispatch — runbook (Arch A + Arch B, both auth paths)

This runbook provisions the **server-hosted, unattended maintainer** on the existing
Cloud Run control plane. The maintainer drives `bin/heimdall-maintain-loop` for a
**bounded** number of cycles against one repo, on a cron, with **no operator present** —
and it does so **without weakening the §1 security spine**: the control plane can only
ever fire the allowlisted `run-maintainer-cycle` action with **typed, bounded scalar
params** (`repo`, `max`, optional `budget_tokens`). There is **no** free-form
prompt/cmd/shell param anywhere — the maintainer prompt is built **inside**
`heimdall-maintain-loop` from the queued GitHub issue, never from a control-plane input.

> **Nothing here is executed for you.** These are artifacts + steps. **RJ holds all
> credentials** and runs every command below himself.

---

## 0. The two architectures

| | **Arch A — schedule on cloud, run on RJ's machine** | **Arch B — fully-cloud Job** |
|---|---|---|
| Where the loop runs | RJ's own machine (`SubprocessRunner`) | a Cloud Run **Job** execution (`CloudRunJobRunner`) |
| Auth source | whatever auth is already on that box (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in his shell env) | **Secret Manager** injects the token into the Job container env |
| GCP spend | \$0 (only the durable state lives in the cloud) | billed for the Job's run only |
| Use when | RJ wants his subscription used at zero infra cost | RJ wants zero-touch, machine-independent runs |

**Both use the identical handler** (`cp_handlers.run_maintainer_cycle`): a fixed argv
`heimdall-maintain-loop run --repo <repo> --max <max> [--budget-tokens <n>]`, with the
LLM credential injected **by env only** (never argv, never logged). The difference is
purely *which process env carries the token* — the operator's shell (A) or the
Secret-Manager-mounted Job env (B).

> **You don't have to pick one.** [§6 **Hybrid**](#6-hybrid-runner-selection-prefer-rjs-box-auto-fall-back-to-the-cloud)
> runs Arch A **when RJ's box is up** and auto-falls-back to Arch B **when it isn't** —
> a cycle is **never dropped**. It is the default (`HEIMDALL_MAINTAINER_RUNNER=hybrid`).

---

## 1. Auth reality — prefer OAuth, fall back to the API key

The handler selects **exactly one** credential, in this order:

1. **`CLAUDE_CODE_OAUTH_TOKEN`** — a `claude setup-token` OAuth token. On a **personal
   Max ($200)** org with **no `forceLoginMethod` block**, `claude setup-token` mints a
   **~1-year** token that authorizes headless runs **against the subscription** (cheap —
   no metered spend). A *managed* org blocks subscription-login-on-a-server at inference
   (403); this operator is on a personal org, so it works.
2. **`ANTHROPIC_API_KEY`** — the metered, always-works fallback.

**Never both required. Never logged.** If neither is set, the loop fails fast on the
box's own missing auth (we do not fabricate a credential).

### 1.1 Mint the OAuth token (RJ, on his own machine)

```bash
claude setup-token
# → prints a token beginning sk-ant-oat... (a ~1-year OAuth token).
# Copy it. It authorizes headless Claude against your Max subscription.
```

---

## 2. Arch A — schedule on cloud, run on RJ's machine

The control plane (scheduler) runs on RJ's machine with the `subprocess` runner, so the
maintainer cycle runs **out-of-process on the same box**, using the box's own auth.

```bash
# 2.1 put the minted OAuth token in THIS shell (never commit it, never echo it to a log):
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat-...<paste>..."
#   — or, for the metered fallback instead:
# export ANTHROPIC_API_KEY="sk-ant-...<paste>..."

# 2.2 the PR bot token the loop OPENS PRs with (scoped to heimdall/* branches, no main,
#     no merge — a human merges). issue_pr.py reads HEIMDALL_PR_BOT_TOKEN:
export HEIMDALL_PR_BOT_TOKEN="ghs-...<bot token>..."

# 2.3 run the control plane with the out-of-process subprocess runner:
export HEIMDALL_JOB_RUNNER=subprocess

# 2.4 register the maintainer cron (drains up to 5 issues/night at 02:00, 40k-token cap):
python3 - <<'PY'
import sys; sys.path.insert(0, "bin/lib")
import cp_scheduler as Sc, cp_auth as K
me = K.Identity("haid:rj.local", owner=True)
entry = Sc.register_maintainer_schedule(
    me, "randomittin/heimdall", 5, "0 2 * * *", budget_tokens=40000)
print("registered:", entry["schedule_id"], entry["action_type"], entry["cron"])
PY
```

The scheduler's per-minute `tick()` fires the schedule at the due minute, dispatches
`run-maintainer-cycle` through the **same §1 allowlist path** every action uses, and the
`subprocess` runner runs the loop to completion on RJ's box using the ambient token.

---

## 3. Arch B — fully-cloud Cloud Run Job

Here the maintainer cycle runs as a **Cloud Run Job execution** — a container that runs
to completion independent of the request-serving service (the same out-of-process model
as `heimdall-long-job`; see README §4). The **auth token comes from Secret Manager**,
injected into the Job container env.

> **⭐ One command does ALL of Arch B — `deploy-arch-b.sh`.**
>
> ```bash
> deploy/cloud-run/deploy-arch-b.sh --repo <owner/repo> --project <gcp-project>
> #   [--region us-central1] [--tag <t>] [--dry-run]
> ```
>
> It runs the whole pipeline in order, idempotently: **(a)** preflight → **(b)** ensure the
> Artifact Registry `heimdall` repo exists → **(c)** `docker build -f Dockerfile.maintainer`
> + `docker push` the maintainer image (git + gh + claude + the heimdall bins) → **(d)**
> resolve the pushed **digest** (`gcloud artifacts docker images describe
> --format='value(image_summary.digest)'`) and **pin** it into
> [`heimdall-maintainer-job.yaml`](./heimdall-maintainer-job.yaml) (backs the manifest up to
> `*.bak`, then seds the `heimdall-maintainer@sha256:` image line in place) → **(e)** hand off
> to [`deploy-maintainer.sh --cloud`](./deploy-maintainer.sh) for the **secrets + `run jobs
> replace` + IAM** (this is where every token is minted — via `claude setup-token` + `read
> -rs`, never echoed; `deploy-arch-b.sh` handles NO token itself) → **(f)** `gcloud run jobs
> describe` to verify. `--dry-run` prints the full plan and executes nothing (needs no creds
> or Docker). Build it **from the repo ROOT** so `COPY bin/` resolves — the script does this
> for you. Proof: `bash test/heimdall-deploy-arch-b.test.sh` (hermetic, $0).
>
> The manual §3.1–§3.3 steps below are the underlying operations `deploy-arch-b.sh`
> automates — keep them as reference / for a partial re-run.
>
> **Image requirement.** The maintainer Job's container must carry the maintainer
> toolchain the loop shells out to: **git, the `gh` CLI, and the `claude` CLI** (plus
> their runtimes). The base `heimdall-long-job` image (python-slim) does **not** ship
> these, so the maintainer Job uses its **own** image — see
> [`heimdall-maintainer-job.yaml`](./heimdall-maintainer-job.yaml) and build it from a
> Dockerfile that adds git + gh + the Claude CLI on top of the control-plane image.

### 3.1 Create the auth secret(s) — support BOTH names

Mirror the existing `cp-pki-key` seed pattern. Create **whichever** credential you want
the Job to use (you need only one; the handler prefers OAuth if both are present):

```bash
export PROJECT_ID="heimdall-cp-prod"
export REGION="us-central1"
export RUNTIME_SA="heimdall-cp-runtime@${PROJECT_ID}.iam.gserviceaccount.com"

# (A) the OAuth token (preferred) -> env CLAUDE_CODE_OAUTH_TOKEN
gcloud secrets create heimdall-cc-oauth-token --replication-policy=automatic --project="${PROJECT_ID}"
printf '%s' "sk-ant-oat-...<paste>..." \
  | gcloud secrets versions add heimdall-cc-oauth-token --data-file=- --project="${PROJECT_ID}"

# (B) OR the metered API key -> env ANTHROPIC_API_KEY
gcloud secrets create heimdall-anthropic-api-key --replication-policy=automatic --project="${PROJECT_ID}"
printf '%s' "sk-ant-...<paste>..." \
  | gcloud secrets versions add heimdall-anthropic-api-key --data-file=- --project="${PROJECT_ID}"

# the PR bot token (scoped heimdall/* branches; no main, no merge) the loop opens PRs with
gcloud secrets create heimdall-pr-bot-token --replication-policy=automatic --project="${PROJECT_ID}"
printf '%s' "ghs-...<bot token>..." \
  | gcloud secrets versions add heimdall-pr-bot-token --data-file=- --project="${PROJECT_ID}"

# grant the runtime SA read on each secret it will consume (least privilege):
for S in heimdall-cc-oauth-token heimdall-pr-bot-token; do
  gcloud secrets add-iam-policy-binding "$S" --project="${PROJECT_ID}" \
    --member="serviceAccount:${RUNTIME_SA}" --role="roles/secretmanager.secretAccessor"
done
```

### 3.2 Create the maintainer Cloud Run Job (digest-pinned)

Resolve a **digest** for the maintainer image (never a mutable tag — a Job must pin a
content-addressed image so a re-tag can't silently change what runs):

```bash
# after building/pushing REGION-docker.pkg.dev/PROJECT/heimdall/heimdall-maintainer:<sha>:
export MAINT_IMAGE_DIGEST="$(gcloud artifacts docker images describe \
  ${REGION}-docker.pkg.dev/${PROJECT_ID}/heimdall/heimdall-maintainer:latest \
  --format='value(image_summary.fully_qualified_digest)')"
echo "pinning ${MAINT_IMAGE_DIGEST}"
```

Then either **(a)** apply the YAML manifest (recommended — digest-pinned, secret env
declared in-file):

```bash
# edit heimdall-maintainer-job.yaml: set image to ${MAINT_IMAGE_DIGEST}, PROJECT_ID, region.
gcloud run jobs replace deploy/cloud-run/heimdall-maintainer-job.yaml --region="${REGION}"
```

…or **(b)** create it imperatively (swap `create` → `update` if it already exists):

```bash
gcloud run jobs create heimdall-maintainer-job \
  --image="${MAINT_IMAGE_DIGEST}" \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --command="heimdall-control-plane" \
  --args="run-job" \
  --task-timeout=3600 \
  --max-retries=1 \
  --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest,CLAUDE_CODE_OAUTH_TOKEN=heimdall-cc-oauth-token:latest,HEIMDALL_PR_BOT_TOKEN=heimdall-pr-bot-token:latest" \
  --set-env-vars="HEIMDALL_STATE_BACKEND=firestore,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},HEIMDALL_CP_SERVER_HAID=cp-server"
```

> To use the **metered API key instead of OAuth**, swap the auth entry in
> `--set-secrets`: `ANTHROPIC_API_KEY=heimdall-anthropic-api-key:latest`. The handler
> prefers `CLAUDE_CODE_OAUTH_TOKEN` when both are mounted — mount only the one you want.

### 3.3 IAM — the dispatcher must be allowed to EXECUTE the Job (`run.jobs.run`)

Identical to README §4.1. The **service** (or the machine) that dispatches the Job needs
`run.jobs.run` on it — **`roles/run.invoker` is NOT enough** (that only invokes a
*service*). Grant the least-privilege custom role:

```bash
gcloud iam roles create heimdallJobRunner \
  --project="${PROJECT_ID}" --title="Heimdall Job Runner" \
  --description="Execute heimdall Cloud Run Jobs" --permissions="run.jobs.run"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="projects/${PROJECT_ID}/roles/heimdallJobRunner"
```

> Point the dispatcher at this Job with `HEIMDALL_CP_JOB_NAME=heimdall-maintainer-job`
> for maintainer dispatches (the `cloudrun-job` runner reads the Job name from env).

---

## 4. The security spine (why this is safe to run unattended)

- **No arbitrary command by construction.** `run-maintainer-cycle` accepts only
  `repo` (an `owner/name` slug with **no** shell metacharacters), `max` (bounded
  `1..100`), and optional `budget_tokens` (bounded int). `validate_params` **refuses any
  extra key** — a smuggled `cmd`/`prompt`/`shell`/`exec` is rejected (`extra_param`)
  before any handler runs. Proven by `test/heimdall-cp-maintainer.test.sh` (a smuggled
  prompt is REJECTED while a valid `{repo,max}` is ACCEPTED — refuse-arbitrary).
- **Fixed argv, no interpolation.** The handler builds one fixed argv from validated
  scalars and runs it with `shell=False`. There is no wire-supplied command string.
- **Token never logged.** The LLM credential is injected into the child env **only** —
  never an argv element, never in the returned result, the audit store, or any log line.
  The test proves this with a **positive control** (the token *does* reach the child env)
  plus a grep across every recorded surface confirming the value appears nowhere.
- **Agent never publishes.** The maintainer **opens PRs** via the scoped B1 bot token on
  `heimdall/*` branches — it **never pushes `main`, never merges**. A **human merges**.
  RJ holds every credential (in his Secret Manager, or his shell) — nothing enters an
  agent's context or a log.

---

## 5. Verify (no spend)

```bash
bash test/heimdall-cp-maintainer.test.sh       # hermetic: mocks the loop + gh, $0
# → cp-maintainer: N passed, 0 failed  (smuggle REJECTED; token-never-logged proven)

bash test/heimdall-cp-hybrid-runner.test.sh     # hermetic: mocks both runners + clock, $0
# → cp-hybrid-runner: N passed, 0 failed
#   (fresh beat→Arch A · stale/absent→Arch B · unclaimed→FAILOVER · none→PARK; never dropped;
#    each decision logs ONE reason line; token reaches the child env yet no recorded surface)
```

---

## 6. Hybrid runner selection (prefer RJ's box, auto-fall-back to the cloud)

Hybrid is the **default** (`HEIMDALL_MAINTAINER_RUNNER=hybrid`). It prefers **Arch A**
(RJ's box, \$0) **while that box is up**, and auto-falls-back to **Arch B** (the Cloud Run
Job) when it is not — **without ever dropping a cycle**. The selection is deterministic
and reads **no credential** — only a liveness beat, the policy env, and the durable job
state.

> **⭐ One command makes the maintainer autonomous — `schedule-maintainer`.**
>
> The per-minute **tick** already runs inside the deployed control-plane service; it just
> needs a **schedule** to fire. Register one and the tick dispatches `run-maintainer-cycle`
> on its own — the hybrid selector then routes each cycle to RJ's box or the Cloud Run Job.
>
> ```bash
> # register (or update-in-place) the maintainer cron — idempotent, no duplicates:
> bin/heimdall-control-plane schedule-maintainer \
>   --repo randomittin/heimdall --cron "*/30 * * * *" --max 3 [--budget-tokens 40000]
> #   → prints: created maintainer schedule sch-… : run-maintainer-cycle for … (cron=…)
> ```
>
> - **Idempotent.** Re-running with the **same `--repo` + `--cron`** updates the existing
>   schedule **in place** (same `schedule_id`) — it never stacks duplicates. Change `--max`
>   / `--budget-tokens` and re-run to adjust; the entry is rewritten, not doubled.
> - **Typed + bounded, never a command.** The verb registers **only** the allowlisted
>   `run-maintainer-cycle` action (repo slug, `1..100` max, optional token budget). A bad
>   `--repo` / `--cron` / out-of-range `--max` is **refused** and **nothing** is persisted.
>   There is no free-form prompt/cmd — the prompt is built **inside the loop** from the
>   queued issue (§4). Registered **as the server identity** (`HEIMDALL_CP_SERVER_HAID` /
>   `heimdall-haid current`) — the same identity the tick fires as.
> - **`--dry-run`** prints the registration and writes nothing.
> - **Fully-cloud (Arch B).** So an absent local runner routes the tick to the **Cloud Run
>   Job**, run the control-plane **service** with `HEIMDALL_MAINTAINER_RUNNER=cloud` (force
>   the Job) or `hybrid` (prefer the box, fall back to the Job). `deploy-maintainer.sh
>   --cloud --schedule "<cron>"` (and `deploy-arch-b.sh --schedule "<cron>"`) call this verb
>   for you after the Job is deployed, and set that env — the **last manual step** for a
>   fully-cloud, unattended maintainer is now automated. List what is registered with
>   `bin/heimdall-control-plane schedules`.

### 6.1 How the box proves it is up — the runner beat (DATA-ONLY, no token)

RJ's box advertises liveness by beating a **signed, TTL'd `maintainer-runner` presence
record** to the control plane — the **same `cp_presence` substrate** the dev roster uses,
under a distinct kind so it never mixes with the team roster. The beat is **DATA-ONLY**
(`runner_id` + `repo` + `handle` + `ts`) — **no token, no command** rides it, by
construction (secret-scrubbed on write). Run it on a **cron on RJ's box** (~every 30–60s):

```bash
# on RJ's box — advertise this runner as UP for the repo (cron every ~30-45s):
* * * * * cd /path/to/heimdall && bin/heimdall-maintain-loop runner-beat \
  --repo randomittin/heimdall --runner-id "$(hostname)" --handle rj-laptop >/dev/null 2>&1
# (crontab's finest granularity is 1 min; for a tighter cadence run a `while sleep 30` loop
#  under a supervisor, or a systemd timer. Keep the cadence < the TTL — see 6.3.)
```

Each beat upserts one record; the selector reads it back and treats the box as **UP** iff
the newest beat is **fresher than the TTL**. Stop the cron (or the box dies) → the beat
goes stale → the selector routes to the cloud on its own. No explicit "I'm down" signal.

### 6.2 The decision (deterministic, logged, credential-free)

With `HEIMDALL_MAINTAINER_RUNNER=hybrid`, each due `run-maintainer-cycle` tick:

1. **fresh beat within TTL** → **Arch A** (`SubprocessRunner`, runs on the machine hosting
   the dispatcher — RJ's box — at \$0).
2. **no fresh beat**, cloud configured (a resolvable `GOOGLE_CLOUD_PROJECT` +
   `HEIMDALL_CP_JOB_NAME`) → **Arch B** (a Cloud Run Job execution).
3. **no fresh beat AND no cloud** → **PARK**: the durable job stays `queued`, re-drivable by
   the next tick / `resume_orphans`. Flagged, **never dropped**.

**Never-drop failover.** Under hybrid, if Arch A is picked but the job is **not claimed**
(its durable state never leaves `queued`) within the **claim grace window** — the box went
down *between* the beat and the claim — the cycle **fails over to Arch B**. If Arch B is
unconfigured too, it **parks** (still never dropped). Every decision (SELECT / FAILOVER /
PARK) emits **exactly one** token-free reason line to stderr (the Cloud Run log sink), so a
run always names **which arm ran and why**.

For hybrid to *have* both arms, run the dispatching control plane with the local
`subprocess` runner available (`HEIMDALL_JOB_RUNNER=subprocess`, §2.3) **and** the Cloud Run
Job configured as the fallback (`GOOGLE_CLOUD_PROJECT` + `HEIMDALL_CP_JOB_NAME`, §3).

### 6.3 The knobs

| Env var | Default | Meaning |
|---|---|---|
| `HEIMDALL_MAINTAINER_RUNNER` | `hybrid` | `hybrid` (prefer A, fall back to B) · `local` (**force** Arch A) · `cloud` (**force** Arch B). An unknown value falls back to `hybrid` (logged). |
| `HEIMDALL_MAINTAINER_RUNNER_TTL_SECONDS` | `90` | A beat fresher than this = the box is UP. Keep the beat **cadence < TTL** — 90s gives ~2 missed beats of slack for a 30–45s cron before the box is treated as down. |
| `HEIMDALL_MAINTAINER_CLAIM_GRACE_SECONDS` | `30` | How long a dispatched Arch-A job may stay `queued` before hybrid fails over to Arch B (the box's worker should claim a fresh job well within this). |

Force a single arm when you want it: `HEIMDALL_MAINTAINER_RUNNER=local` pins Arch A (RJ's
box only — no cloud fallback), `=cloud` pins Arch B (zero-touch, ignores the beat).

---

## 7. GCE VM (interactive cloud login) — "OpenClaw-in-cloud"

An **alternative to the §1.1 `setup-token` / §3.1 Secret-Manager path**. Instead of minting a
long-lived OAuth token and mounting it as a secret, this runs **Arch A on a persistent GCE VM**
and authenticates with an **interactive `claude` login done *on* the VM** — the login **code is
relayed to your browser** and **pasted back on the VM**. No pre-minted token ever exists.

> **Why a VM, not a Cloud Run Job?** Cloud Run Jobs are **batch / non-interactive** — there is no
> TTY to paste a login code into. An interactive `claude auth login` code-relay **requires a
> persistent machine you SSH into**. So this is **Arch A relocated onto a cloud VM**: the VM holds
> the subscription creds (a portable Linux `~/.claude/.credentials.json`), runs
> `bin/heimdall-maintain-loop`, and **beats runner-liveness** (§6.1) so the hybrid selector routes
> the cycle to it. Works because RJ is a **personal Max** org with **no `forceLoginMethod` block**
> (subscription OAuth authorizes headless runs — §1).

> **⭐ One script, two phases — `deploy/gce/provision-maintainer-vm.sh`.** RJ runs it with his own
> gcloud creds. The OAuth login is **interactive + manual**: the script only **prints** the relay
> steps — it never handles the OAuth secret. `--dry-run` prints the whole plan (create VM +
> startup script + login relay + install plan) and needs **no** gcloud/ssh/creds. Proof:
> `bash test/heimdall-provision-vm.test.sh` (hermetic, `$0`).

### 7.1 Phase 1 — `provision` (create the VM + get the login relay)

```bash
deploy/gce/provision-maintainer-vm.sh provision \
  --project heimdall-cp-prod --zone us-central1-a [--vm heimdall-maintainer-vm] \
  [--machine-type e2-small] [--private] [--dry-run]
```

Creates a small **e2-small Debian 12** VM (guarded: `instances describe … || create`) with a
**startup script** that installs the full toolchain — **git + gh + Node 20 + the `claude` CLI +
python3 with the pinned `cryptography`/`firestore`/`run` deps** (identical pins to
`Dockerfile.maintainer`) — and clones the **public** heimdall repo to `/opt/heimdall`, exporting
`bin/` on PATH via `/etc/profile.d`.

> **⚠️ Egress is mandatory — this is the bug that bit a live run.** A GCE VM with **no external
> IP and no Cloud NAT has NO route to the internet**, so the startup script dies at the first
> `apt-get`/`npm`/`git clone` with *"Network is unreachable"* — **nothing installs**. Provision
> therefore gives the VM **internet egress**:
> - **default** → an **ephemeral EXTERNAL IP** (fast, works immediately);
> - `--private` → **no external IP**, egress via a **Cloud Router + NAT** (`heimdall-maintainer-router`
>   + `heimdall-maintainer-nat`, guarded/idempotent for the region) — no public IP on the VM.
>
> The startup script is **idempotent + re-runnable**: it retries `apt-get update` (and every
> network fetch), tees to **`/var/log/heimdall-toolchain.log`**, and writes the ready marker
> **`/var/log/heimdall-toolchain-ready` only on full success** — so `verify` (§7.3) can self-heal.

**IAP auto-setup** (previously a manual step — the operator hit SSH **4033 'not authorized'**):
provision idempotently ensures the **`allow-iap-ssh`** firewall (ingress **tcp:22** from
**`35.235.240.0/20`**), **enables the `compute`/`iap` APIs**, and grants (or prints, if it lacks
project-IAM-admin) the operator's **`roles/iap.tunnelResourceAccessor`**. If the active account is
a **service account** (`*.gserviceaccount.com`, e.g. a CI SA) the script **warns loudly** that
these steps will `PERMISSION_DENIED` and to `gcloud auth login` as a human owner first.

Then it **prints the interactive login relay for RJ to run himself**:

```bash
# 1. SSH in over the IAP tunnel (no public IP needed):
gcloud compute ssh heimdall-maintainer-vm --zone us-central1-a \
  --project heimdall-cp-prod --tunnel-through-iap
#    (confirm the toolchain landed:  ls -l /var/log/heimdall-toolchain-ready )

# 2. on the VM — headless Linux can't open a browser, so claude PRINTS a URL + CODE:
claude          # (or:  claude auth login )  → prints a URL and a login CODE

# 3. open that URL in YOUR OWN browser, sign in (personal Max), copy the code,
#    and PASTE it back at the prompt on the VM.

# 4. verify the subscription auth works headless:
claude -p "ok" --          # a normal reply on your subscription (not a 401)
```

The creds now **persist on the VM** at `~/.claude/.credentials.json` (a portable OAuth file).

### 7.2 Phase 2 — `install-maintainer` (after the login succeeds)

```bash
deploy/gce/provision-maintainer-vm.sh install-maintainer --repo <owner/repo> \
  --project heimdall-cp-prod --zone us-central1-a [--vm heimdall-maintainer-vm] \
  [--max 3] [--cron "*/30 * * * *"] [--clone-path <dir>] [--dry-run]
```

Over `gcloud compute ssh --command` (IAP), on the VM:

- **prompts for `HEIMDALL_PR_BOT_TOKEN`** (`read -rs`, never echoed) and streams it over **ssh
  STDIN** into a **0600 env file** `~/.heimdall/maintainer.env`
  (`HEIMDALL_JOB_RUNNER=subprocess`, `HEIMDALL_MAINTAINER_RUNNER=hybrid`, the bot token) — the
  token is **never an argv/`--command` element**, never logged;
- **clones the target repo** on the VM (the DIR the loop's `run --max` drains against);
- installs a **cron** (idempotent, dedup on the `heimdall-maintainer-` marker): **runner-beat
  every minute** (Arch-A liveness so the hybrid selector picks this VM — §6.1) **+** a bounded
  `heimdall-maintain-loop run --max N` cycle on `--cron`;
- **smoke**: one `runner-beat` + a `claude -p "ok"` liveness check.

The maintainer **OPENS PRs** via the bot token on `heimdall/*` branches — it **never pushes
`main`, never merges**. **RJ merges** (§4).

### 7.3 `verify` — confirm (and self-heal) the toolchain

```bash
deploy/gce/provision-maintainer-vm.sh verify \
  --project heimdall-cp-prod --zone us-central1-a [--vm heimdall-maintainer-vm] [--dry-run]
```

SSHes in over IAP and checks the **`/var/log/heimdall-toolchain-ready`** marker plus
**`claude --version`** and `git`/`gh`/`heimdall-maintain-loop` on PATH. **If the marker is absent**
(a transient first-boot failure, or one fixed by adding egress after the fact), it **re-runs the
startup script** via `sudo google_metadata_script_runner startup` and **re-checks** — so the
toolchain **self-heals WITHOUT recreating the VM**. Exit 0 = `VERIFY-OK`; a still-broken toolchain
prints `VERIFY-FAIL` (see `/var/log/heimdall-toolchain.log`) and exits nonzero.

> **Secret discipline.** The OAuth login is interactive + manual (the script never touches the
> OAuth secret). The bot token is `read -rs` → **ssh STDIN pipe** → 0600 file on the VM. No
> `echo $TOKEN`, no `set -x`, no token in any argv or log. Same bar as `deploy-maintainer.sh`.

> **Cron vs systemd.** The script installs a **cron** (matches `deploy-maintainer.sh` §2, 1-min
> granularity for the beat). For a tighter beat cadence, replace the beat line with a systemd
> timer / a `while sleep 30` supervised loop (keep the cadence **< the 90s TTL** — §6.3).

---

## 8. The dedicated PR-bot credential — GitHub App (recommended) vs fine-grained PAT

The maintainer opens PRs **as a bot identity**, **never** as the operator's personal
account (`issue_pr.gh_bot_runner` authenticates `gh` with `HEIMDALL_PR_BOT_TOKEN`, on
`heimdall/*` branches only — **never pushes `main`, never merges**; a human merges).
There are two ways to be that bot. **A GitHub App is recommended**; a fine-grained PAT on
a dedicated bot account is the simpler **fallback**.

### 8.1 GitHub App — recommended (no user seat, auto-scoped, revocable)

A **GitHub App** is a first-class bot identity: **no user seat consumed**, permissions
**auto-scoped** to exactly what it was granted, **revocable** in one click, and PRs are
attributed to the **App**. Its one wrinkle: an **installation token expires after 1
hour**, so a static token cannot back a long-running loop. The maintainer therefore
**mints a fresh installation token per cycle** from the App's private key
(`bin/lib/maintain_loop.py :: apply_pr_bot_token` → `bin/heimdall-gh-app-token`: App JWT
(RS256) → `POST /app/installations/<id>/access_tokens` → the token is exported as
`HEIMDALL_PR_BOT_TOKEN` for that cycle, then expires harmlessly).

**Create + wire it with one script:**

```bash
# 0. print the App-setup plan (manifest + exact permissions + install + verify), no creds:
deploy/github-app/setup-bot.sh --dry-run --repo randomittin/heimdall

# 1. create the App from the printed manifest, install it on the target repo ONLY, then
#    verify + persist the creds (mints a test token via bin/heimdall-gh-app-token):
deploy/github-app/setup-bot.sh --configure \
  --app-id <APP_ID> --installation-id <INSTALLATION_ID> \
  --private-key-file <path/to/app-private-key.pem> --repo randomittin/heimdall
#   → writes a 0600 store (~/.heimdall/gh-app.env + gh-app-private-key.pem).
#   Add --cloud --project <gcp-project> to write the key to Secret Manager instead.
```

**The EXACT App permissions to grant — and NOTHING else:**

| Permission | Level | Why |
|---|---|---|
| **Contents** | Read and write | push the `heimdall/*` fix branch (+ read repo code) |
| **Issues** | Read and write | READ the issue queue (the connector's work source) + comment "resolved by #N" + close the resolved issue |
| **Pull requests** | Read and write | open the PR + post the proof-receipt comment |
| **Metadata** | Read-only | mandatory baseline (auto-selected) |

**Deny everything else** — critically **no Administration** (so the App cannot edit
branch protection or repo settings), **no Workflows/Actions** (no CI mutation), **no
Commit statuses / Checks** (the gate runs tests locally; it never reads CI status), no
Members, no Deployments. Install the App on **the target repo(s) only** (never "All repositories").
As a server-side backstop for "never push `main`, never merge", add a **branch protection
rule on `main`** requiring a PR + review that the App cannot bypass (GitHub App
permissions are not branch-scoped, so branch protection + no-Administration is what pins
"no direct `main` push / no self-merge").

**Config the runner reads** (any of: a sourced 0600 env file, the process env, or
Secret-Manager-mounted env):

| Env var | Meaning |
|---|---|
| `HEIMDALL_GH_APP_ID` | the App's numeric App ID |
| `HEIMDALL_GH_APP_INSTALLATION_ID` | the installation id on the target repo(s) |
| `HEIMDALL_GH_APP_PRIVATE_KEY` **or** `HEIMDALL_GH_APP_PRIVATE_KEY_FILE` | the App private key (inline PEM, or a path to a 0600 `.pem`) |

When `HEIMDALL_GH_APP_ID` is set, the loop **mints per cycle**; when it is absent it uses
the static `HEIMDALL_PR_BOT_TOKEN` (below). Provisioning wires this for you:
`deploy/cloud-run/deploy-maintainer.sh --gh-app --gh-app-id <N> --gh-app-installation-id
<N> --gh-app-key-file <pem>` (Arch A → 0600 file; Arch B → Secret Manager), and
`deploy/gce/provision-maintainer-vm.sh install-maintainer … --gh-app …` (VM → the key
streamed over ssh STDIN into a 0600 file). Verify offline:
`bash test/heimdall-gh-app-token.test.sh`.

### 8.2 Fine-grained PAT on a dedicated bot account — the simple fallback

The simplest path (no App, no per-cycle minting) is a **dedicated bot GitHub account**
with a **fine-grained PAT** scoped to the repo:

1. Create a **separate GitHub account** for the bot (this **consumes a user seat** on an
   org — the trade-off vs. the App). Give it push access to the target repo.
2. Mint a **fine-grained PAT** (Settings → Developer settings → Fine-grained tokens),
   scoped to **only** `randomittin/heimdall`, with **Repository permissions: Contents:
   Read and write** + **Issues: Read and write** + **Pull requests: Read and write** —
   nothing else. (Issues is required: the same bot identity reads the issue queue and
   comments/closes resolved issues, so its token must carry Issues scope too.) Set a short
   expiry and rotate.
3. Export it as the bot token:

   ```bash
   export HEIMDALL_PR_BOT_TOKEN="github_pat_...<the fine-grained PAT>..."
   ```

This is **static** (no hourly refresh) and requires **no** `HEIMDALL_GH_APP_*` — the loop
uses it directly. The downsides vs. the App: it **consumes a user seat**, PRs come from
the **bot user** (not an App), and scope is per-token rather than centrally managed. Prefer
the **App (§8.1) for teams**; the PAT is the quickest way for a solo operator to start.
