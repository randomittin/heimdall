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
export PROJECT_ID="heimdall-control-plane"
export REGION="us-central1"
export RUNTIME_SA="heimdall-cp-run@${PROJECT_ID}.iam.gserviceaccount.com"

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
bash test/heimdall-cp-maintainer.test.sh   # hermetic: mocks the loop + gh, $0
# → cp-maintainer: N passed, 0 failed  (smuggle REJECTED; token-never-logged proven)
```
