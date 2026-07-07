# Launch Cost Model (item 8) + Custom-Domain Runbook (item 7)

Date: 2026-07-07 · Author: hmd · Sanity-check owner: RJ ($10k cap)

All resource quantities are cited to the actual deploy configs (`file:line`). Dollar
rates are **published GCP us-central1 (single-region) list prices** — labeled `[rate]`,
not read from the repo. Where a rate has a free tier it is noted; headline figures are
stated **without** free-tier credit (conservative) unless said otherwise.

---

## 0. The three services, from the configs

| Service | Shape (verbatim from config) | Billing model |
|---|---|---|
| **Gated CP** `heimdall-control-plane` | `--min-instances=1 --no-cpu-throttling --cpu=1 --memory=512Mi --max-instances=5 --concurrency=80` — `deploy/cloud-run/go-live.sh:260-261` | **Instance-based** (always-allocated CPU) → billed 24/7 |
| **Public surface** `heimdall-cp-public` | `--min-instances=0 --cpu=1 --memory=512Mi --max-instances=5 --concurrency=80` — `deploy/cloud-run/deploy-public-surface.sh:440-450` | **Request-based** (CPU-throttled) → scale-to-zero, billed per request |
| **Maintainer Job** `heimdall-maintainer-job` | `cpu:"1" memory:1Gi` (`:83-86`), `timeoutSeconds:3600 maxRetries:1` (`:48-51`) — `deploy/cloud-run/heimdall-maintainer-job.yaml` | **Per-execution** (always-allocated during run) |

Presence cadence (drives the virality model): **1 beat / 20s** (`sentinels/hmd-statusline.py:133`),
roster refresh gated by a **~8s** refresher lock over a **~4s** cache (`sentinels/hmd-statusline.py:121-123`;
checklist assumed 15s — modeled below). Scheduler fires a **per-minute tick**
(`bin/lib/cp_scheduler.py:16`; "per-minute tick driver" `bin/heimdall-control-plane:384,405`).

### GCP list rates used `[rate]`
- Cloud Run **instance-based** (always-allocated, no-throttle): vCPU **$0.000018/vCPU-s**, mem **$0.0000020/GiB-s**.
- Cloud Run **request-based** (throttled): vCPU **$0.000024/vCPU-s**, mem **$0.0000025/GiB-s**, requests **$0.40/M**.
- Firestore Native, **regional us-central1**: reads **$0.03/100k** (=$0.0000003), writes **$0.09/100k** (=$0.0000009). Free tier 50k reads / 20k writes **per day**. (Multi-region ~2×.)
- Secret Manager: **$0.06/active version/mo**, access **$0.03/10k ops**. Free tier: 6 versions + 10k access ops/mo.
- Artifact Registry storage: **$0.10/GiB/mo**.
- Claude tokens (current): **Sonnet 4.6 $3 in / $15 out per M**, **Opus 4.8 $5 in / $25 out per M** (verified via claude-api skill, 2026-07).
- Month = 730 h = **2,628,000 s**.

---

## 1. Fixed floor — the operator's always-on bill

The floor is dominated by the **gated service**, which is `min-instances=1` + `--no-cpu-throttling`
(`go-live.sh:260`) → one instance runs 24/7 with CPU always allocated → **instance-based** rate.

```
gated vCPU  = 1 vCPU × 2,628,000 s × $0.000018 = $47.30 / mo
gated mem   = 0.5 GiB × 2,628,000 s × $0.0000020 = $2.63 / mo
gated floor = $49.93 / mo
```

| Floor component | $/mo | Basis |
|---|---|---|
| Gated always-on instance | **$49.93** | above; `go-live.sh:260-261` |
| Public surface (idle) | ~$0 | `min-instances=0` → scale-to-zero (`deploy-public-surface.sh:446`) |
| Firestore tick ops | ~$0 | 1,440 ticks/day × a few reads ≈ under the 50k/day free tier |
| Secret Manager (≈5 fixed secrets) | ~$0 | within the 6-version + 10k-op free tier |
| Artifact Registry (~2 GiB images) | ~$0.20 | image storage |
| **FLOOR** | **≈ $50 / mo** | |

### Sanity vs the prior ~$65/mo estimate — CORRECTED to ~$50/mo
The prior $65 figure matches pricing the same always-on instance at the **request** vCPU
rate ($0.000024): `2,628,000 × 0.000024 = $63.07` + mem $3.29 ≈ **$66**. That is the wrong rate:
with `--no-cpu-throttling` **and** `min-instances=1`, Cloud Run bills **instance-based**
($0.000018/vCPU-s, ~25% cheaper). **The real floor is ~$50/mo, not $65.** Everything else
(Firestore, secrets, public idle) is within free tiers and rounds to zero.

---

## 2. Marginal cost per team (BYOC → infra only)

BYOC = the team supplies its own Claude credential (`heimdall-maintainer-job.yaml:17-23,78-82`:
`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` injected per-execution, never baked in), so
**Claude tokens are the TEAM's bill — not Heimdall COGS.** Heimdall's per-team marginal:

```
2 BYOC secrets beyond the free 6 = 2 × $0.06 = $0.12 / mo (standing)
+ team presence/maintainer Firestore ops                = pennies / mo
MARGINAL PER TEAM ≈ < $0.20 / mo   (infra only)
```

---

## 3. Marginal cost per fix (one maintainer dispatch)

**Heimdall infra (COGS):** one Cloud Run Job execution, ~2–4 min of 1 vCPU + 1 GiB
(`heimdall-maintainer-job.yaml:83-86`), billed always-allocated during the run:

```
3-min run: vCPU 1 × 180 s × $0.000018 = $0.00324
           mem  1 × 180 s × $0.0000020 = $0.00036
           = $0.0036 / fix     (2-min $0.0024 … 4-min $0.0048)
MARGINAL PER FIX (Heimdall infra) ≈ < $0.01
```

**Claude tokens (the TEAM's BYOC bill, NOT Heimdall COGS):** observed ~100k–600k tokens/dispatch.
Priced input-weighted (~85% in / 15% out), **before** prompt-cache discount:

| tokens | Sonnet 4.6 | Opus 4.8 |
|---|---|---|
| 100k | ~$0.48 | ~$0.80 |
| 600k | ~$2.88 | ~$4.80 |

With prompt caching (cache reads bill 0.1× input) the input portion collapses → real per-fix
often **$0.30–$3**. Range to quote: **~$0.50–$5 per fix, paid by the team.**

### Headline numbers
1. **Operator cost floor: ~$50/month** (the gated always-on instance — corrected down from the ~$65 prior estimate; it was priced at the throttled rate, not the no-throttle instance rate).
2. **Marginal cost per team: <$0.20/month** infra (BYOC — Claude is the team's bill, ~$0 Heimdall COGS).
3. **Marginal cost per fix: <$0.01** Heimdall infra; **~$0.50–$5** Claude tokens paid by the team (BYOC).

---

## 4. Cost under virality (checklist item 8 — the $10k-cap check)

Per-active-session load (`hmd-statusline.py:133` beat/20s; refresh modeled at the checklist's
15s): **180 beats/hr** (1 Firestore write each) + **240 refreshes/hr** (1 HTTP req each; each
reads a roster of **R** docs). Public surface is request-billed (throttled). Assume ~50 ms/request
and roster **R=5**.

**Per 1,000 concurrent-session-hours:**
```
requests    = 1000×180 + 1000×240 = 420,000 / hr
Cloud Run   req   420,000 × $0.0000004               = $0.168
            vCPU  420,000 × 0.05 s × $0.000024        = $0.504
            mem   420,000 × 0.05 s × 0.5 × $0.0000025 = $0.026   → ~$0.70
Firestore   write 180,000 × $0.0000009               = $0.162
            read  240,000 × 5 × $0.0000003            = $0.360   → ~$0.52
TOTAL ≈ $1.2 per 1,000 concurrent-session-hours   (R=5, 50 ms/req)
        band: $0.9 (20 ms/req) … $1.6 (100 ms/req)
```

Scaling (dominant knobs: **request duration** and **roster size R**):

| concurrent | 8 h active/day | 24 h sustained | 24 h → /month |
|---|---|---|---|
| 100 | ~$1/day | ~$2.9/day | ~$87/mo |
| 1,000 | ~$10/day | ~$29/day | ~$870/mo |
| 10,000 | ~$98/day | ~$293/day | **~$8,800/mo → AT the $10k cap** |

**PASS check (checklist):** "1,000 concurrent < a few $/day" holds only if sessions average
**≲ 3 active hours/day** (or requests run ~20 ms). At sustained 24 h it is ~$29/day — above
"a few." **Recommendation: tune intervals BEFORE launch as insurance** (a config change now vs
a fire later). Doubling **beat 20s→40s** (`hmd-statusline.py:133`) and **refresh 15s→30s**
≈ **halves** the whole table — 10k sustained drops to ~$4.4k/mo, well under the cap.

**Kill-switch threshold:** sustained **10,000 concurrent ≈ $8.8k/mo** is the danger zone. Levers
already in the runbook (checklist item 13): enroll-cap env throttle and `HEIMDALL_ENROLL_OPEN`
unset (each one `gcloud run services update`). The interval-tuning above is the cheaper, earlier
lever — do it pre-launch.

---

## 5. Custom-domain runbook (item 7) — everything but RJ's registrar step

Goal: put the **public** service behind `cp.runheimdall.dev` so a future infra move doesn't
strand baked-in `run.app` URLs. RJ's only manual part is adding the DNS record.

### 5a. Preferred: Cloud Run domain mapping (region must support it)
```bash
# 1. Create the mapping on the PUBLIC service (the one clients hit).
gcloud beta run domain-mappings create \
  --service=heimdall-cp-public \
  --domain=cp.runheimdall.dev \
  --region=us-central1 --project=heimdall-cp-prod

# 2. Print the DNS records to add (RJ's registrar step):
gcloud beta run domain-mappings describe \
  --domain=cp.runheimdall.dev \
  --region=us-central1 --project=heimdall-cp-prod \
  --format='value(status.resourceRecords[].rrdata)'
#   → RJ adds the printed CNAME/A/AAAA at the DNS host, waits for the managed cert.

# 3. Verify once the cert is ACTIVE:
curl -s -o /dev/null -w '%{http_code}\n' https://cp.runheimdall.dev/readyz   # expect 200
```

### 5b. Fallback: global external HTTPS LB (if run domain-mappings is unsupported in-region)
```bash
gcloud compute network-endpoint-groups create heimdall-cp-public-neg \
  --region=us-central1 --network-endpoint-type=serverless \
  --cloud-run-service=heimdall-cp-public --project=heimdall-cp-prod
gcloud compute backend-services create heimdall-cp-be \
  --global --load-balancing-scheme=EXTERNAL_MANAGED --project=heimdall-cp-prod
gcloud compute backend-services add-backend heimdall-cp-be \
  --global --network-endpoint-group=heimdall-cp-public-neg \
  --network-endpoint-group-region=us-central1 --project=heimdall-cp-prod
gcloud compute ssl-certificates create heimdall-cp-cert \
  --domains=cp.runheimdall.dev --global --project=heimdall-cp-prod
gcloud compute url-maps create heimdall-cp-um \
  --default-service=heimdall-cp-be --global --project=heimdall-cp-prod
gcloud compute target-https-proxies create heimdall-cp-proxy \
  --url-map=heimdall-cp-um --ssl-certificates=heimdall-cp-cert \
  --global --project=heimdall-cp-prod
gcloud compute forwarding-rules create heimdall-cp-fr \
  --global --target-https-proxy=heimdall-cp-proxy --ports=443 \
  --project=heimdall-cp-prod
# Then: RJ points cp.runheimdall.dev A/AAAA at the printed forwarding-rule IP.
gcloud compute forwarding-rules describe heimdall-cp-fr --global \
  --project=heimdall-cp-prod --format='value(IPAddress)'
curl -s -o /dev/null -w '%{http_code}\n' https://cp.runheimdall.dev/readyz   # expect 200
```

### 5c. Then hmd (post-DNS, ships via auto-update)
Change `DEFAULT_CP_URL` in `bin/heimdall-presence`, `team.html` CSP `connect-src`, and docs →
ship. **Keep the `run.app` URL live indefinitely as the legacy fallback** (baked clients only
migrate on their next auto-update).

Cost note: 5a (domain mapping) adds **$0**. 5b (LB) adds a forwarding-rule + proxy (~**$18/mo**
for the global LB) — only take 5b if 5a is unsupported in-region.
