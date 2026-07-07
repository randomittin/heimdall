# Heimdall — Operators Guide

Operator-only knobs that are deliberately invisible to users. If you run the
public control plane, deploy your own, or need to change enrollment posture, this
is your home. Users never need anything here — the happy path is zero-config.

> Users: you do not need this file. First run auto-enrolls; `rr connect` captures
> your credential. There is no token to paste. Close this and go.

---

## The enroll token — operator-only, not a user concept

The **enroll token** is a shared bootstrap secret that gates `POST /enroll` (the
PKI self-enrollment route a device hits on first run, before it has a registered
signing key). It is a **server-side capability**, mechanism-intact but erased from
every user surface. Users never see it, type it, or ask for it.

The mechanism is fully implemented and stays that way:

| Piece | Where | Role |
|---|---|---|
| `HEIMDALL_ENROLL_OPEN` | server env | The gate. Truthy (`1`/`true`/`yes`/`on`) → `/enroll` runs **tokenless** (open-bounded). Unset/`0`/`false` → **token-gated** (fail-closed). Read fresh each request — flip it with no code change. |
| `HEIMDALL_ENROLL_TOKEN` | server env / Secret Manager `cp-enroll-token` | The server-side verifier secret. Presented token must match it (constant-time). **Server-only** — never returned, logged, echoed, or shipped in a client. |
| `--enroll-token <t>` | `rr setup --mode control-plane` (client) | Hidden operator flag. Persists a bootstrap token `0600` into `~/.heimdall/cp-endpoint.json`; never argv'd back. Still fully functional — just demoted out of the primary help/onboarding. |
| `X-Heimdall-Enroll-Token` header / `enroll_token` body field | wire | How a client presents the token to a token-gated server. |
| `bin/lib/cp_enroll.py` | server | The gated enroll core (`enroll()` / `enroll_route()` / `register()`). Token gate, caps, team binding. Unchanged. |

**Current launch posture:** `HEIMDALL_ENROLL_OPEN=1` on the public service
(`heimdall-cp-public`). Enrollment is tokenless and bounded by the caps below. This
is why users need no token: the public CP accepts a tokenless, `owner=false`,
capped enrollment.

**Fail-safe:** unset the flag and enrollment reverts to the exact fail-closed token
gate — no allow-all fallback ever. An unset **server** `HEIMDALL_ENROLL_TOKEN` in
token mode refuses **every** enroll (`enroll_disabled`), never accepts all.

---

## Re-gating enrollment (open → token) in one env change

To close open enrollment and require a bootstrap token again:

1. **Mint / confirm the token secret** (Secret Manager `cp-enroll-token`):

   ```bash
   printf '%s' "$(openssl rand -base64 32)" \
     | gcloud secrets create cp-enroll-token --data-file=- --project=heimdall-cp-prod
   # (or: … versions add cp-enroll-token --data-file=-  to rotate an existing one)
   ```

2. **Flip the live service to token mode** — remove the open flag and mount the
   secret as `HEIMDALL_ENROLL_TOKEN`:

   ```bash
   gcloud run services update heimdall-cp-public \
     --region=us-central1 --project=heimdall-cp-prod \
     --remove-env-vars=HEIMDALL_ENROLL_OPEN \
     --update-secrets=HEIMDALL_ENROLL_TOKEN=cp-enroll-token:latest
   ```

   The gate reads the env fresh per request, so the new posture takes effect on the
   next revision with no code change.

3. **Distribute the token** to each device out-of-band. A device persists it 0600
   into `~/.heimdall/cp-endpoint.json` via the hidden operator flag:

   ```bash
   rr setup --mode control-plane --endpoint <cp-url> --enroll-token <token>
   ```

   Or via the install env (equivalent, no flag on argv):

   ```bash
   HEIMDALL_CP_URL=<cp-url> HEIMDALL_ENROLL_TOKEN=<token> bash install.sh
   ```

**To flip BACK to open-bounded** (the launch posture — one command):

```bash
gcloud run services update heimdall-cp-public \
  --region=us-central1 --project=heimdall-cp-prod \
  --update-env-vars=HEIMDALL_ENROLL_OPEN=1
```

The `cp-enroll-token` secret may stay mounted in open mode (a configured+presented
token is still accepted — token mode is never broken); it is simply not required.

---

## Bounded-enroll cap knobs (apply in BOTH modes)

Open enrollment is safe because it is bounded. Every knob is env-overridable on the
service; the defaults are launch-tuned. All defined in `bin/lib/cp_enroll.py` and
`bin/lib/cp_publicsurface.py`.

| Env var | Default | Bounds |
|---|---|---|
| `HEIMDALL_ENROLL_MAX_KEYS` | `1000` | HARD global registry-size ceiling — a net-new haid is refused past this (`enroll_registry_full`, 429). Total growth is capped regardless of rate / IP / token rotation. |
| `HEIMDALL_TEAM_MAX_MEMBERS` | `100` | Per-team member cap — a net-new haid is refused once a team holds this many bindings (`team_full`, 429). Bounds how much one (leaked) team secret can bloat. |
| `HEIMDALL_ENROLL_IP_LIMIT` | `5` open / `10` token | Per-IP enroll requests per window (tighter default in open mode). |
| `HEIMDALL_ENROLL_IP_WINDOW` | `60`s | Window for the per-IP enroll limit. |
| `HEIMDALL_ENROLL_TOKEN_LIMIT` | `30` | Per-token enroll requests per window. |
| `HEIMDALL_ENROLL_TOKEN_WINDOW` | `60`s | Window for the per-token limit. |
| `HEIMDALL_ENROLL_BUDGET_MAX` | `50` | Deployment-wide enroll budget per window (global backstop). |
| `HEIMDALL_ENROLL_BUDGET_WINDOW` | `3600`s | Window for the deployment-wide budget. |
| `HEIMDALL_ENROLL_TEAM_LIMIT` | `30` | Per-team enroll requests per window (rate, distinct from the member cap). |
| `HEIMDALL_ENROLL_TEAM_WINDOW` | `60`s | Window for the per-team enroll rate. |

Structural guarantees that hold in open mode regardless of caps: an open enroll can
only register `owner=false` keys (no privilege escalation), cannot hijack an
already-enrolled haid (the `haid_pubkey_conflict` 409 holds — a stolen/absent token
can never move someone else's identity), and cannot grow the registry past
`HEIMDALL_ENROLL_MAX_KEYS`.

---

## Deploy references

- `deploy/cloud-run/deploy-public-surface.sh` — deploys `heimdall-cp-public`;
  `--enroll-open` / `HEIMDALL_ENROLL_OPEN` forwarding, secret mount logic.
- `deploy/cloud-run/deploy-public-rr.sh` — public RR wiring; `--enroll-open` flag.
- `deploy/cloud-run/go-live.sh` — full go-live; Secret Manager existence checks.
- `deploy/cloud-run/PUBLIC-RR-RUNBOOK.md` / `GO-LIVE-RUNBOOK.md` — step-by-step.
- `bin/lib/cp_enroll.py` — the gated enroll core + caps.
- `bin/lib/cp_publicsurface.py` — the per-IP / budget / team rate limits.

Defaults referenced above: project `heimdall-cp-prod`, region `us-central1`,
service `heimdall-cp-public`, enroll secret `cp-enroll-token`. Override via the
`PROJECT_ID` / `REGION` / `PUBLIC_SERVICE` / `ENROLL_SECRET` env vars the deploy
scripts read.

---

## Release signing — the auto-update trust root (operator-only)

Clients auto-update by re-running a Release's `install.sh`. That is code-execution to the whole
fleet, so releases are **signed** (minisign) and `bin/heimdall-autoupdate` **verifies the
signature against the in-repo public key `release/heimdall-signing.pub` before applying** — an
unsigned/tampered/wrong-key release is refused and the client stays put. Full trust model, key
generation, and rotation live in **`SIGNING.md`**; this is the operator quick-reference.

- **Trust anchor (in repo):** `release/heimdall-signing.pub`. It must be committed and must ship
  in the **same release that first carries the verifying updater**, or auto-update fails closed
  (refuses everything — code `3`, "no trust root"). See the *Launch ordering* section of `SIGNING.md`.
- **Secret key (never in repo):** RJ holds it at `~/.heimdall/signing/heimdall-signing.key`
  (`chmod 600`). One-time generation command is in `SIGNING.md`.
- **`ship.sh` posture:** after publishing a Release it signs `install.sh` and uploads
  `install.sh.minisig`. Missing minisign **or** key ⇒ **WARN + release UNSIGNED** (never a hard
  block); it prints the exact re-sign command.

| Env var | Default | Meaning |
|---|---|---|
| `HEIMDALL_SIGNING_KEY` | `~/.heimdall/signing/heimdall-signing.key` | Secret key `ship.sh` signs with. |
| `HEIMDALL_SIGNING_PUBKEY` | in-repo `release/heimdall-signing.pub` | Trust-root override the updater verifies against (rotation / test seam). |

Incident lever: a bad-but-signed release is handled exactly like the posture memo
(`docs/analysis/launch-autoupdate-posture.md`) — un-publish the Release + delete the tag, or
fix-forward. A **leaked signing key** additionally requires key rotation (`SIGNING.md`).
