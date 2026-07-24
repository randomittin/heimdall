# God Mode — GCP IAP setup (the exact steps RJ runs)

The **god-serving surface** is a THIRD Cloud Run service (alongside the gated
`heimdall-control-plane` and the public `heimdall-cp-public`) that serves ONLY the
owner-only cross-tenant routes `GET /god/roster` + `GET /god/logs`, gated by **Google
IAP**. IAP authenticates RJ's Google identity at the edge and forwards a signed
`X-Goog-IAP-JWT-Assertion`; the control plane (`bin/lib/cp_iap.py`) independently
**verifies** that JWT (ES256 signature + issuer + audience + expiry) and accepts it as an
owner-equivalent identity **iff** the verified `email` == the configured owner email.

This is the browser auth bridge: a browser can neither PKI-sign (the Ed25519 owner path)
nor do GCP IAM, so IAP is the only web path to `/god/*`. It does **not** weaken the
multi-tenant isolation (INV-GOD G1–G4): `/god/*` is never on the public surface (404
there), the IAP owner path is honored **only** on this surface and **only** for `/god/*`,
and the app-layer verify is fail-closed (missing / invalid / wrong-email / unconfigured →
401).

> Substitute your own values for `PROJECT_ID`, `PROJECT_NUMBER`, `REGION`, `DOMAIN`, and
> `OWNER_EMAIL` throughout. `OWNER_EMAIL` is the exact Google account you sign in to IAP
> with (RJ's).

---

## 0. Prereqs / variables

```bash
export PROJECT_ID="your-heimdall-project"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="us-central1"
export OWNER_EMAIL="rj@yourdomain.com"        # THE only identity that may reach god mode
export DOMAIN="god.runheimdall.dev"           # the IAP-gated hostname you will point at the LB
export IMAGE="us-central1-docker.pkg.dev/${PROJECT_ID}/heimdall/control-plane:latest"  # the SAME CP image
gcloud config set project "$PROJECT_ID"
```

---

## 1. Deploy the god-serving Cloud Run service

Same image as the control plane, **`--no-allow-unauthenticated`** (only the IAP load
balancer may invoke it), with the god-surface env. It is durable (Firestore) so it reads
the same presence / registry / audit state the fleet writes.

```bash
gcloud run deploy heimdall-cp-god \
  --image="$IMAGE" \
  --region="$REGION" \
  --no-allow-unauthenticated \
  --set-env-vars="HEIMDALL_GOD_SURFACE=1,HEIMDALL_GOD_OWNER_EMAIL=${OWNER_EMAIL},HEIMDALL_STATE_BACKEND=firestore,HEIMDALL_CP_SERVER_HAID=haid:cp-server" \
  --set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest" \
  --service-account="heimdall-cp-god-run@${PROJECT_ID}.iam.gserviceaccount.com"
```

- `HEIMDALL_GOD_SURFACE=1` — flips the app to the **god surface**: it serves ONLY `/god/*`
  + the health probes (every other route is a flat 404), and honors the IAP owner path.
- `HEIMDALL_GOD_OWNER_EMAIL` — the ONE Google identity accepted as owner.
- `HEIMDALL_GOD_IAP_AUDIENCE` — set in **step 5** (you need the backend-service id first).
- Runtime SA `heimdall-cp-god-run` needs **datastore read** + the PKI-key secret; it does
  **not** need `run.jobs.run` (god mode dispatches nothing — it is read-only).

---

## 2. Reserve an IP + managed cert, put a serverless NEG in front

```bash
# a) global static IP for the LB
gcloud compute addresses create heimdall-god-ip --global
export GOD_IP="$(gcloud compute addresses describe heimdall-god-ip --global --format='value(address)')"

# b) serverless NEG -> the Cloud Run god service
gcloud compute network-endpoint-groups create heimdall-god-neg \
  --region="$REGION" --network-endpoint-type=serverless \
  --cloud-run-service=heimdall-cp-god

# c) backend service (IAP attaches HERE) + attach the NEG
gcloud compute backend-services create heimdall-god-backend \
  --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services add-backend heimdall-god-backend \
  --global --network-endpoint-group=heimdall-god-neg \
  --network-endpoint-group-region="$REGION"

# d) URL map + HTTPS proxy + managed cert + forwarding rule
gcloud compute url-maps create heimdall-god-urlmap \
  --default-service=heimdall-god-backend
gcloud compute ssl-certificates create heimdall-god-cert \
  --global --domains="$DOMAIN"
gcloud compute target-https-proxies create heimdall-god-proxy \
  --url-map=heimdall-god-urlmap --ssl-certificates=heimdall-god-cert
gcloud compute forwarding-rules create heimdall-god-fr \
  --global --target-https-proxy=heimdall-god-proxy \
  --ports=443 --address=heimdall-god-ip
```

Then create a DNS **A record** `god.runheimdall.dev → $GOD_IP` and wait for the managed
cert to go `ACTIVE` (`gcloud compute ssl-certificates describe heimdall-god-cert
--global`).

---

## 3. Configure the OAuth consent screen (once per project)

IAP needs an OAuth brand. In the console: **APIs & Services → OAuth consent screen** →
Internal (if a Workspace org) or External, app name "Heimdall God", support email =
`OWNER_EMAIL`. (CLI: `gcloud iap oauth-brands create --application_title="Heimdall God"
--support_email="$OWNER_EMAIL"` — one brand per project.)

---

## 4. Enable IAP on the backend and RESTRICT it to your Google account

```bash
# enable IAP on the god backend service
gcloud iap web enable --resource-type=backend-services --service=heimdall-god-backend

# grant ONLY your Google account access (the sole god-mode principal)
gcloud iap web add-iam-policy-binding \
  --resource-type=backend-services --service=heimdall-god-backend \
  --member="user:${OWNER_EMAIL}" \
  --role="roles/iap.httpsResourceAccessor"
```

Also let the **IAP service agent** invoke the Cloud Run service (so IAP-authorized requests
reach the container while it stays `--no-allow-unauthenticated`):

```bash
gcloud run services add-iam-policy-binding heimdall-cp-god \
  --region="$REGION" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

---

## 5. Wire the JWT AUDIENCE into the god service (the app-layer check)

The IAP JWT `aud` is the backend-service **resource path**. Read the numeric id, then set
the env so `cp_iap` enforces it (a JWT with any other `aud` → 401 `bad_audience`):

```bash
export BSID="$(gcloud compute backend-services describe heimdall-god-backend --global --format='value(id)')"
export IAP_AUD="/projects/${PROJECT_NUMBER}/global/backendServices/${BSID}"
echo "IAP audience = $IAP_AUD"

gcloud run services update heimdall-cp-god \
  --region="$REGION" \
  --update-env-vars="HEIMDALL_GOD_IAP_AUDIENCE=${IAP_AUD}"
```

> Fail-closed by design: until BOTH `HEIMDALL_GOD_IAP_AUDIENCE` and
> `HEIMDALL_GOD_OWNER_EMAIL` are set, every `/god/*` request returns 401
> `iap_not_configured` — the surface grants nothing before it is fully configured.

---

## 6. Serve the static god page from the SAME IAP origin (recommended)

Host `heimdall-site/god/` (index.html + god.js + god.css) behind the **same** IAP load
balancer so the page and the endpoint share an origin — then the browser sends the IAP
cookie automatically on same-origin `fetch('/god/roster')` and `god.js`'s default
`GOD_URL = ''` Just Works (no CORS, no token in the page).

Two common ways:

- **GCS static backend on the same URL map.** Upload `god/` to a bucket, add a bucket
  backend to `heimdall-god-urlmap` as the default, and route `/god/*` (and `/healthz`) to
  `heimdall-god-backend` via a path matcher. IAP protects the whole map.
- **A tiny static Cloud Run/site behind a second serverless NEG** on the same URL map.

If you instead host the page on a **different** origin (e.g. a separate IAP-gated Netlify/
site), set `GOD_URL` in `god/god.js` to the IAP endpoint origin (`https://god.runheimdall.dev`)
and note the cross-origin IAP-cookie caveat documented in `god/README.md` — the same-origin
topology above is strongly preferred.

---

## 7. Verify

```bash
# In a browser signed in as OWNER_EMAIL: open https://god.runheimdall.dev/  -> the wall loads.
# From the CLI, prove the app-layer gate is real (no IAP assertion -> 401, never a 200):
curl -si "https://god.runheimdall.dev/god/roster" | head -1     # 302 to IAP login OR 401
```

- A request **without** a valid IAP session → IAP 302s to Google sign-in (or, past IAP, the
  app returns 401 `missing_iap_jwt`).
- A signed-in **non-owner** Google account that IAP somehow admitted → app 401 `wrong_email`.
- A tampered assertion → app 401 `bad_signature`. The app layer is the floor; IAP is defense
  in depth, not the only wall.

---

## What each env var does (summary)

| Env | Where | Purpose |
|---|---|---|
| `HEIMDALL_GOD_SURFACE=1` | god Cloud Run | Serve ONLY `/god/*` + health; honor the IAP owner path. |
| `HEIMDALL_GOD_OWNER_EMAIL` | god Cloud Run | The single Google identity accepted as owner. |
| `HEIMDALL_GOD_IAP_AUDIENCE` | god Cloud Run | The exact JWT `aud` (backend-service path) the app enforces. |
| `HEIMDALL_GOD_IAP_JWKS_URL` | god Cloud Run (optional) | Override Google's gstatic JWK URL (air-gapped/pinned mirror). Default is Google's. |
| `HEIMDALL_STATE_BACKEND=firestore` | god Cloud Run | Read the durable fleet state. |
| `HEIMDALL_CP_PKI_KEY` (secret) | god Cloud Run | Stable server identity at boot (fail-closed in cloud). |

The public surface (`heimdall-cp-public`) and the gated control plane
(`heimdall-control-plane`) are **unchanged** — `HEIMDALL_GOD_SURFACE` is unset on both, so
the god branch is inert there and `/god/*` behaves exactly as before (404 on public; Ed25519
owner + IAM on the gated service).
