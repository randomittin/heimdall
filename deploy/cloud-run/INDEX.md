# Cloud Run Deploy — Runbook Index

Operational runbooks for deploying and operating the Heimdall control plane on Cloud Run. **These runbooks are cited by deploy scripts and tests — do not move or rename them.**

| Runbook | Purpose | Status |
| --- | --- | --- |
| [README.md](README.md) | Control-plane Cloud Run deploy runbook — the top-level entry point. | Load-bearing |
| [GO-LIVE-RUNBOOK.md](GO-LIVE-RUNBOOK.md) | Go-live runbook for the two-service (server + worker) split. | Load-bearing |
| [MAINTAINER-RUNBOOK.md](MAINTAINER-RUNBOOK.md) | Unattended maintainer dispatch — Arch A + Arch B, both auth paths. | Load-bearing |
| [PUBLIC-RR-RUNBOOK.md](PUBLIC-RR-RUNBOOK.md) | Stand up the public, multi-tenant `rr` control plane (W4). | Load-bearing |

Related: GCE remote-run handoff lives at [`deploy/gce/README-rr.md`](../gce/README-rr.md). The signed enqueue client is documented at [`docs/rr-control-plane-client.md`](../../docs/rr-control-plane-client.md).

Back to the master index: [`docs/INDEX.md`](../../docs/INDEX.md).
