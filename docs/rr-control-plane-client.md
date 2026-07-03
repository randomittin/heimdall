# `rr --mode control-plane` — the signed enqueue client

`rr` (bin/rr) is the LOCAL→CLOUD task handoff. In **control-plane** mode it does
not SSH a VM: it **signs** a bounded task with the per-dev Ed25519 key and **POSTs**
it to the control plane's public **enqueue-only** route `POST /rr-task`. A human's
GitHub App turns the drained task into a PR.

This is the client half of the `rr`-over-control-plane design; the server-side
isolation contract is `docs/specs/2026-07-03-rr-isolation-invariants.md` (INV-1…INV-8).

## Setup

```
rr setup --mode control-plane [--endpoint <url>] [--enroll-token <t>] [--repo <owner/repo>]
```

- Writes `~/.heimdall/remote.json` `{ "mode": "control-plane", "repo": "<repo>" }`.
  No secret is stored here.
- With `--endpoint`, MERGES `{ url, enroll_token? }` into the **shared**
  `~/.heimdall/cp-endpoint.json` (the SAME config `heimdall-presence` reads),
  preserving other keys. The file is chmod `600`.
- `--enroll-token` is the ONLY secret. It lives 0600 in `cp-endpoint.json` and is
  **never echoed** back on any surface (passed to the writer via the environment,
  never argv-logged/printed).

The CP URL is not a secret (a public Cloud Run endpoint) and has a shipped default,
so a dev needs zero URL config — only the enroll token is distributed.

## Dispatch

```
rr "<task>" --mode control-plane [--repo <owner/repo>] [--dry-run]
```

Flow:

1. **Resolve wire** — URL (`--endpoint` > `$HEIMDALL_CP_URL`/`$BASE_URL` >
   `cp-endpoint.json .url` > shipped default), identity HAID
   (`$HMD_HAID` > `heimdall-identity current` > `heimdall-haid current`), and the
   per-(machine,haid) `0600` seed path `~/.heimdall/pki/<haid>.seed` — the exact
   layout `heimdall-presence` persists.
2. **Ensure enrolled** — if no seed exists, reuse `heimdall-presence beat`'s
   bootstrap enroll path (keygen → `POST /enroll` → persist the 0600 seed). Enroll
   is idempotent; an already-enrolled device is a no-op. If enrollment cannot
   complete (offline / no reachable CP / missing token) the dispatch **fails closed**
   with a clear "enroll first" message and touches nothing.
3. **Build the body** — a bounded dict `{"text": <task>, "context": <capsule>,
   "nonce": …, "ts": …}`. The context is the `heimdall-context-capsule build`
   output (already secret-scrubbed), trimmed to ≤ 8000 chars. `nonce`+`ts` ride
   inside the signed body so the server's replay-nonce gate can prove a live,
   first-use enqueue. **The client sends NO `team_id`.**
4. **Sign + POST** — an inline python client (single-quoted heredoc, inputs via the
   ENV only — never argv) reuses the shipped `cp_auth` signer:
   `X-Heimdall-Signature = cp_auth.sign(seed, cp_auth.canonical_message("POST","/rr-task",body))`,
   plus `X-Heimdall-HAID`. Ed25519 is never re-implemented.
5. **Report** — prints the accepted queue id + team (server-derived) and
   `watch: the PR will appear on <repo> via your GitHub App`. Clear errors on
   `401` (signature), `403` (repo not covered / no team), `422` (payload refused),
   `429` (rate limited), and connect failure / not-enrolled.

## The exact request shape

```
POST <base>/rr-task
Content-Type: application/json
X-Heimdall-HAID: <this device's haid>
X-Heimdall-Signature: <ed25519 over canonical_message(POST,/rr-task,body)>

{"text":"<task>","context":"<≤8000c, secret-scrubbed>","nonce":"<hex>","ts":<epoch>}
```

Success: `{"enqueued": true, "id": "<queue id>", "added": true, "team_id": "<server-derived>"}`.

## Security invariants upheld client-side

- **INV-1** — the client never sends `team_id`; the server derives it from the
  verified signed binding. `--dry-run` shows the literal body so this is auditable.
- **INV-5** — task + context are bounded, secret-scrubbed DATA (context capped at
  8000 chars client-side; the server also scrubs+trims before persistence).
- **Secret discipline** — the signing seed and enroll token never touch argv or a
  log; the seed lives only in its 0600 file + the signing process, read in-process.
- **Enqueue-only** — the route writes one row to the caller's own team queue and
  stops; the client holds no dispatch capability and no cred beyond its own seed.

## Verify

```
bash -n bin/rr
bash test/heimdall-rr-cp.test.sh   # cp setup · dry-run signed-POST plan · no team_id · enroll-first · secret-safe
bash test/heimdall-rr.test.sh      # vm/local path unregressed
```
