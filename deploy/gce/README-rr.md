# `rr` — remote-run: local → cloud maintainer handoff

`rr` (also `hmd rr`) hands a task off from the **local** Heimdall to the
**cloud-hosted** maintainer — the GCE VM provisioned by
[`provision-maintainer-vm.sh`](./provision-maintainer-vm.sh). The local `hmd`
stays the orchestrator/UI; `rr` dispatches **execution** to the cloud so heavy
work runs remotely, not on your box.

## The handoff flow

1. **File the task as a maintainer issue** — the durable, auditable queue entry
   (`gh issue create --repo <R> --label maintainer …`). The resulting PR links
   back to it. **Idempotent**: an identical *open* maintainer issue (matched by
   derived title) is reused, never re-filed.
2. **Hand off to the cloud executor** — SSH to the configured VM over the IAP
   tunnel and run the maintainer there, **detached** (`nohup … &`) so `rr`
   returns fast:
   ```
   gcloud compute ssh <vm> --zone <z> --project <p> --tunnel-through-iap \
     --command "export PATH=/opt/heimdall/bin:\$PATH;
                export HEIMDALL_MAINTAINER_RUNNER=hybrid HEIMDALL_JOB_RUNNER=subprocess;
                nohup heimdall-maintain-loop run --repo \$HOME/heimdall-work/<name> --max <N> \
                  >> \$HOME/.heimdall/rr.log 2>&1 &"
   ```
   The VM already holds its own `claude` + `gh` + bot creds — **`rr` never passes
   a secret over argv and never logs one.** The bot opens PRs on `heimdall/*`
   branches; a human merges (unchanged).
3. **Report** — the issue URL, `dispatched to <vm>`, and how to watch it.

## First-time setup (writes the cloud target)

```
rr setup --vm heimdall-maintainer-vm --zone us-central1-a \
         --project heimdall-control-plane --repo owner/repo [--mode vm|control-plane]
```

Writes `~/.heimdall/remote.json` (mode `0600`; **holds no secret** by
construction — only `vm`/`zone`/`project`/`repo`/`mode`):

```json
{
  "mode": "vm",
  "project": "heimdall-control-plane",
  "repo": "owner/repo",
  "vm": "heimdall-maintainer-vm",
  "zone": "us-central1-a"
}
```

## Usage

```
rr "<task>" [--repo owner/repo] [--max N] [--dry-run]   # file issue + dispatch
rr --issue <N> [--repo R] [--dry-run]                   # skip filing; drain issue #N
rr status [--repo R]                                    # dispatches + open PRs + remote rr.log tail
rr --local [...]                                        # FALLBACK: run maintain-loop on THIS box
rr --dry-run "<task>"                                   # print the gh + ssh plan; execute nothing
```

- `--dry-run` **everywhere** prints the exact `gh` + `ssh` commands and executes
  nothing — no creds needed (works before `rr setup`).
- Fail-closed: a real cloud dispatch with no `remote.json` errors with a clear
  `run rr setup` hint and files nothing first.

## Modes

- **`vm`** (default MVP) — SSH to the VM, run the maintainer there.
- **`control-plane`** (alt) — instead of SSH, register the bounded, allowlisted
  `run-maintainer-cycle` via `heimdall-control-plane schedule-maintainer`; the
  per-minute tick fires it and the hybrid runner routes it (Arch A box / Arch B
  Cloud Run Job). Reuses the existing §1 allowlist path.

## Tests

`bash test/heimdall-rr.test.sh` — hermetic (fake `gh` + `gcloud` on PATH, throwaway
`$HOME`): proves setup shape, the dry-run plan, idempotency, `--issue`, the
fail-closed no-remote path, the `--local` fallback, and that no secret is ever
echoed.
