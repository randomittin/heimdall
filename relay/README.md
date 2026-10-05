# hmd relay

Cloudflare Workers + Durable Object relay for hmd's phone companion app (Wave 1,
`relay-service-core`). Design of record: `docs/superpowers/specs/2026-09-21-hmd-relay-design.md`
(§1 architecture, §2 protocol, §3 threat model) and
`docs/superpowers/specs/relay/INVARIANTS.md` (INV-1..30). This directory is a self-contained
package — its own `package.json`, `tsconfig.json`, `wrangler.toml`, and vitest config — and is
never imported by the rest of this repo.

## What it does

The relay is hmd's presence control plane: outbound-only from the laptop (Decision 7), a dumb
end-to-end-encrypted pipe between one laptop (`hmd`) and one or more paired phones, keyed by a
Durable Object per `session_id` (the single serialization point for that session's state).

- **hmd leg** (laptop, authenticated): `GET /session/:id/stream` — for frames the phone sent, in
  one of two transports chosen by the request alone: a hibernatable **WebSocket** when it carries
  `Upgrade: websocket` (one envelope per text message; the Durable Object can sleep while hmd is
  connected — see "The hmd leg as a WebSocket" below), otherwise the original long-lived
  chunked-HTTP response, one NDJSON-encoded envelope per line, plus a `keepalive` control frame
  every 20s of idleness (see "Stream lifetime" below). `POST /session/:id/frames` — send one
  envelope to the phone. Both require `Authorization: Bearer <relay_session_token>`.
- **phone leg** (WebSocket): `wss://.../session/:id/ws?pairing_code=<code>` for the first claim,
  or `?device_token=<token>` to reconnect after binding.
- **pairing**: `POST /pair/init` (unauthenticated) creates a session and returns a session id, a
  single-use ~60s pairing code, and the hmd-side bearer token.
- **health**: `GET /health` (unauthenticated; `HEAD` too) answers `200 {"ok":true,"version":"<build>"}`
  from the Worker alone — it never reaches a Durable Object — and is what the deploy pipeline's
  canary check polls. `version` is `BUILD_ID`, the commit sha the pipeline injects with `wrangler
  deploy --var BUILD_ID:<sha>`, or `package.json`'s version when none was injected (local dev, a
  hand-run deploy). The body carries nothing about sessions, secrets or the host.

The relay stores and forwards **ciphertext only** for `state` / `command` / `ack` frames — it
never sees plaintext. `device_bound`, `session_ended` and `keepalive` are the three
relay-originated control frames; they carry plaintext (e.g. the freshly minted `device_token`)
because they are never sealed by either peer — the relay holds no session key and could not
seal them if it wanted to.

## Deploy

A merge to `main` that touches `relay/**` deploys itself. `.github/workflows/relay-deploy.yml` runs
relay-ci, ships the commit to the `hmd-relay-canary` Worker (`[env.canary]` in `wrangler.toml`: its
own Durable Object namespace and its own signing secret) and polls that Worker's `GET /health` until
it reports the commit's sha as `version`. Only then does it deploy the same commit to `hmd-relay` and
run the same check. If either check fails, that Worker is put back with `wrangler rollback` and the
pipeline stops, so a bad canary never reaches production. `workflow_dispatch` runs it by hand; from a
branch other than `main` it stops after the canary.

What the check proves is that the Worker answers and that the new build is the one serving. It does
not pair a phone or round-trip a frame, so a canary missing its `RELAY_SIGNING_SECRET` still passes.

One-time setup, in the repo's Settings, Environments: `relay-canary` and `relay-production` each need
the secret `CLOUDFLARE_API_TOKEN` and the variable `CLOUDFLARE_ACCOUNT_ID`, and each Worker needs its
own signing secret (below). The check polls `https://hmd-relay-canary.therishabh16.workers.dev` and
`https://hmd-relay.therishabh16.workers.dev`; an environment variable `RELAY_URL` overrides the base
URL. `bash scripts/health-check.sh <base-url> [expected-version]` is that same check, runnable by hand
against any relay.

By hand:

```
cd relay
npx wrangler login
npx wrangler secret put RELAY_SIGNING_SECRET                # production
npx wrangler secret put RELAY_SIGNING_SECRET --env canary   # canary
npx wrangler deploy                                         # production; --env canary for the canary
```

`RELAY_SIGNING_SECRET` HMAC-signs the **`device_token` only** — session id, role, expiry and the
bound device public key are baked into the signed payload. `relay_session_token` is *not* signed
with it: `generateSessionToken` (`src/pairing.ts`) is 32 raw random bytes compared
constant-time against the stored value, so hmd's bearer credential does not depend on this
secret at all. Generate the secret with any high-entropy random-string tool; it is never a
literal in this repo, only a Workers secret. Durable Objects require the Workers Paid plan
(~$5/mo) — the free plan cannot bind them.

**Rotation invalidates every outstanding `device_token`** (and nothing else — hmd's bearer
tokens survive, per the paragraph above). The token format carries no key id and
`verifyDeviceToken` accepts exactly one secret, so every paired phone must re-scan a QR after a
rotation. A key-id prefix plus an overlap window (`RELAY_SIGNING_SECRET_PREVIOUS`) would remove
that cliff; it is not implemented, so plan a rotation as a re-pair event.

## Local dev

```
cd relay
npx wrangler dev
```

`wrangler dev` reads local secrets from `relay/.dev.vars` (gitignored — set
`RELAY_SIGNING_SECRET=<any local value>` there; never commit a real one).

## Test

```
cd relay
npm test        # scripts/check-no-logged-urls.mjs, then vitest run
npm run typecheck
```

`npm test` runs a plain-Node grep guard first (`scripts/check-no-logged-urls.mjs`, INV-8: the
relay must never log a full request URL, since the phone-leg URL carries `pairing_code` /
`device_token` in its query string), then the vitest suite under
`@cloudflare/vitest-pool-workers` — a real `workerd` runtime, no Cloudflare account needed.

## HTTP / WS API for client tracks

### `POST /pair/init` — unauthenticated, throttled per source IP

Rate limit: **10 per 60s sliding window, keyed on `CF-Connecting-IP`**
(`PAIR_INIT_MAX_PER_WINDOW` / `PAIR_INIT_WINDOW_MS`, `src/pairing.ts`). The attempt that
crosses the bound gets `429` + `Retry-After: 60` + `{"retry_after_s": 60}`; the window is
sliding, so the caller is serving again 60s after its tenth accepted request. This is INV-5's
"bounded by mint + TTL + **throttle**" clause — the endpoint stays identity-free (no bearer, no
prior relationship, nothing asked of the caller but the IP the edge already routes on).

The counter lives in a Durable Object instance named `pair-init-throttle:<ip>` — the same
`SessionDO` class, a disjoint storage key (`pair_init_attempts`), never a session. A second DO
class would have needed a `[[migrations]]` entry on the deploy that ships this, which is not
worth the risk to a live paired session for a per-name counter. The bucket re-arms its own
purge alarm on every call, so an IP that stops calling reclaims its row one window later.

`CF-Connecting-IP` is set by Cloudflare's edge and cannot be spoofed (an inbound header of that
name is overwritten). Its absence means the request did not come through the edge — `wrangler
dev` or the vitest pool — and those share one `"unknown"` bucket and are throttled like any
other caller. Fail-closed on purpose: treating a missing header as "unlimited" would hand the
bypass to anyone who found a path to the Worker that skipped the edge. Tests therefore pass
their own `CF-Connecting-IP` per logical client (`test/worker.spec.ts`'s `pairInit` helper).

Not covered by this: `GET /session/<random-uuid>/ws` still instantiates a Durable Object per
distinct id before answering `404`, so a spray over random UUIDs is a DO-instantiation
amplifier with no storage write to show for it. Recorded as a known, accepted cost — bounding
it needs a KV/bloom of live session ids in the Worker, which is more machinery than the
exposure justifies while session ids are UUIDv4.

Response `200`:
```json
{
  "session_id": "<uuid>",
  "pairing_code": "<26-char base32, A-Z2-7>",
  "relay_session_token": "<base64url, opaque>",
  "exp": 1234567890
}
```
(`exp` = unix-seconds pairing code expiry, ~60s out.)

### `GET /session/:id/stream` — hmd leg, requires `Authorization: Bearer <relay_session_token>`

- `200` — chunked body, one JSON `Envelope` (see below) per line (NDJSON), for frames the phone
  sent (`command` / `ack` / `state` — whatever the phone side emits), interleaved with
  `keepalive` control frames (see "Stream lifetime" below).
- `401` — missing or incorrect bearer.
- `400` — malformed `:id` (not a UUID) — rejected before reaching the Durable Object.
- `404` — well-formed `:id` that was never initialized via `/pair/init`.

#### The hmd leg as a WebSocket (hibernatable)

`GET /session/:id/stream` with `Upgrade: websocket` — the same route, the same bearer, the same
`401`/`404` (ordinary JSON, never an upgrade) — is answered `101`, and the Durable Object accepts
the socket through the Hibernation API (`ctx.acceptWebSocket(server, ["hmd"])`). A request without
the header gets the NDJSON response above, unchanged: that is what every client that predates this
gets, and what an older relay answers an `Upgrade` request with (it ignores the header), so client
and relay can be deployed in either order. The wire is pinned in `contract/wire.json` (`stream_ws`).

- **One envelope per text message** — the bytes of an NDJSON line without its newline. The first
  message is the held `device_bound` if the phone claimed before hmd connected; then the phone's
  `command` frames. `session_ended` (INV-38) arrives as a message before the close. Never a
  `keepalive`.
- **No timer, nothing in memory.** No keepalive, no lifetime bound, no response body: nothing keeps
  the object resident, so it is evicted between events, and a frame arriving later (a phone
  command, hmd's `POST /frames`) wakes it and is still delivered. Which socket is newest and which
  session it belongs to are on the socket (`getWebSockets("hmd")`, `{ gen, sid }` on its
  attachment), never on the instance. Hibernatable sockets are re-delivered to the new generation
  after a deploy, so the 2026-09-25 orphaned-stream failure cannot happen on this transport.
- **Liveness is hmd's job.** hmd sends the text message `ping` and the runtime answers `pong`
  (`setWebSocketAutoResponse`) without waking the object. Any other message from hmd is ignored and
  logged `frame_rejected` (`leg: "hmd"`, `ws_message_unsupported`); one over `MAX_ENVELOPE_BYTES`
  closes the socket with `1009`.
- **Newest wins, across both transports.** A new hmd leg — WebSocket or NDJSON — ends the previous
  one: a socket with close code `4002` (`superseded`), a stream by closing it.
- **Ends.** `POST /revoke` closes the socket `4001` (`revoked`); a relay-ended session (pairing
  expiry, claim throttle, purge) sends the `session_ended` message, then closes `4001`.
- **Logs** (never a URL or token): `hmd_stream_open` `{transport: "ws" | "ndjson"}` on every open
  — what to count in `wrangler tail` to watch a rollout — and `hmd_socket_closed` /
  `hmd_socket_error`.

#### Stream lifetime (the NDJSON transport)

**Cloudflare closes a long-lived chunked response that carries no bytes.** Observed live on
2026-09-24 against the deployed relay: a stream opened at 08:33:53 with a phone bound and state
frames flowing, then sat idle and was closed server-side at 08:38:54 — 5m01s later. A relay
session is idle by nature (hmd sends `state` only on a digest change, INV-22), so this is the
steady state, not an edge case.

Three independent mitigations, because no two of them are sufficient:

1. **`keepalive`** — while hmd's stream has written nothing for `KEEPALIVE_INTERVAL_MS`
   (`src/session.ts`, 20s), the relay writes one plaintext control frame:
   ```json
   {"v":1,"session_id":"<uuid>","seq":0,"sender":"relay","type":"keepalive","nonce":null,"ciphertext":null,"payload":{"ts":1758700000}}
   ```
   `payload.ts` is the relay's clock in unix-seconds, informational only — no client should
   trust it, compare it against its own clock, or act on it. The frame carries no session state
   and **a reader may skip it entirely**; it exists so the response is never idle long enough to
   be cut. The timer is idle-based, not periodic: any real frame written to the stream resets
   it, so a busy stream never pays for a keepalive it does not need. `keepalive` is
   relay-originated only — `isEnvelope` (`src/types.ts`) deliberately does **not** accept one
   inbound on `POST /frames` or on the phone's socket.
   The interval is overridable with an optional `RELAY_KEEPALIVE_MS` binding (milliseconds).
   Nothing declares it in `wrangler.toml`, so production and `wrangler dev` run on the 20s
   default; only `vitest.config.ts` binds it, at 1s, because the Workers runtime offers no hook
   to advance its own timers from a test.

2. **hmd reconnects.** If the stream is cut anyway — a hard platform cap, a Durable Object
   eviction, a closed laptop lid — hmd is expected to reopen `GET /stream` with the *same*
   bearer and exponential backoff. **Losing hmd's stream never ends the session.** The DO does
   not set `status: "ended"`, does not send `session_ended`, and does not touch the phone's
   WebSocket; the phone stays bound and connected throughout, and the spent `pairing_code` stays
   spent (a re-claim is still `410`). Only `POST /revoke` — or pairing expiry *before* a bind —
   ends a session. A reconnect supersedes any still-open previous stream, which the DO closes so
   it cannot leak.

   A phone frame sent while hmd is away is **dropped, not buffered** — the same fire-once
   semantics `POST /frames` reports as `delivered: false` when the phone is absent (see the
   buffering deviation below). The phone's own missing `ack` is what surfaces it (INV-28); the
   relay adds no retry path. The one exception remains the single `device_bound` control frame,
   which is parked until hmd's stream opens.

   **hmd must reconnect on silence too, not only on close** — and the keepalive above is what
   makes that decidable. `hmdStreamController` is in-memory state that no storage can hold, so a
   Durable Object restart (any deploy, any eviction) destroys it; the chunked response to hmd can
   stay open at the client regardless, carrying nothing. A client that only reacts to a *closed*
   stream then waits forever, never reopens `GET /stream`, and the restarted Durable Object never
   gets a controller back — so `webSocketMessage` drops every phone `command` from then on while
   `POST /frames` keeps delivering hmd→phone perfectly, since that direction re-derives the
   device socket from `getWebSockets` on every call. Confirmed live 2026-09-24 after redeploying
   `8a6e821e` over a 2.5h-old session: state flowed to the phone the whole time and every
   phone→hmd send timed out. The keepalive created this trap as much as it mitigates the idle
   cut — before it, Cloudflare's ~5-minute cut forced the reconnect that healed an orphaned
   stream by accident. `fake-hmd.mjs` bounds stream silence at three missed keepalives
   (`STREAM_IDLE_TIMEOUT_MS`); `docs/HANDOFF-TO-HEIMDALL-relay.md`'s "Stream lifetime" rule 5 is
   the contract hmd implements against.

3. **Every stream carries its own deadline** (`MAX_STREAM_LIFETIME_MS`, `src/session.ts`, 10
   minutes), because mitigation 2 has a blind spot that mitigation 1 opens.

   Measured live on 2026-09-25, on a session orphaned by the `e7025229` deploy: the orphaned
   stream was **not** carrying nothing. It was still being written to — the socket took 191
   bytes with zero bytes out over a 15s window, which is one `keepalive` line (163B) plus
   chunked framing and one TLS record, and its `Recv-Q` stayed at 0. hmd's client had emitted
   **zero** `stream_drop` in 80 minutes. A deploy rolls the Durable Object to a new generation,
   and hibernatable device sockets are re-delivered to that new one — so `POST /frames` keeps
   answering `delivered: true` — while hmd's in-flight response stays pinned to the OLD
   generation, whose `keepaliveTimer` is still running in its isolate. A silence bound cannot
   fire on a stream that is not silent, so `HMD_RELAY_STREAM_IDLE_S` never tripped and hmd never
   reconnected, while the generation actually holding the phone dropped every `command` as
   `no_hmd_stream_connected`.

   Nothing outside that orphaned isolate can close the response: the controller is in its
   memory, not in storage, and the live generation has no handle to it. So the stream ends
   itself. hmd already treats a closed stream as routine (mitigation 2), which lands it on the
   live generation; the cost is one reconnect (~2s, hmd's `BACKOFF_BASE_MS`) per stream per 10
   minutes, and the bound on a post-deploy phone→hmd outage becomes the lifetime rather than
   unbounded. Emits `stream_lifetime_expired`. Overridable with an optional
   `RELAY_STREAM_MAX_LIFETIME_MS` binding on the same terms as `RELAY_KEEPALIVE_MS` above
   (vitest binds it at 8s; nothing declares it in `wrangler.toml`).

   `relay/scripts/fake-hmd.mjs` implements exactly this contract and is the reference for
   `bin/heimdall-relay-client` (see `docs/HANDOFF-TO-HEIMDALL-relay.md`'s "Stream lifetime").

### `POST /session/:id/frames` — hmd leg, requires the same bearer

Body: one `Envelope` (JSON). Response `200 {"ok": true, "delivered": <bool>}` — `delivered:
false` (not an error) when no phone is currently connected; the frame is not buffered or
retried.

**Only hmd-originated frames are accepted here**: `sender: "hmd"` and `type` of `state` or
`ack` (`isHmdFrame`, `src/types.ts`). The bearer token authorises the holder to speak *as hmd*
and nothing more — a `sender:"relay"` `device_bound`/`session_ended`, or a `sender:"device"`
frame, is `400`, never forwarded to the phone. Symmetric to the phone leg's gate below.

- `413` — envelope exceeds 1 MiB.
- `400` — invalid JSON, or an envelope that is not an hmd-originated frame.
- `401` / `404` — same as `/stream`.

One residue, disclosed: the size check reads `Content-Length` first and only then measures the
decoded body, so a chunked POST with no `Content-Length` is fully buffered in the Durable Object
before it can be measured. Streaming-and-counting, or refusing a body with no `Content-Length`,
would close that — both change what a legitimate hmd client must send, so neither ships here
without a coordinated contract change.

### `GET /session/:id/ws?pairing_code=<code>` or `?device_token=<token>` — phone leg

Must be a real WebSocket upgrade (`Upgrade: websocket`) over an effectively-`wss` connection —
`400` if the `Upgrade` header is missing, or if `X-Forwarded-Proto: http` /
`cf-visitor: {"scheme":"http"}` signal a plaintext hop in front of the Worker. A `pairing_code`
claim requires `&device_pubkey=<base64url, 32 bytes>` in the query string.

#### `device_token` is bound to the device's public key

A `device_token` minted on a `pairing_code` claim carries that claim's `device_pubkey` inside
its HMAC-signed payload. **A reconnect must present the same `&device_pubkey=` value**, and the
relay compares the two constant-time; a mismatch or an omission is `401`. Before this, the
token was bound to nothing but `session_id`: a copy exfiltrated from a device backup, a rooted
handset, or the relay's own memory was a 30-day bearer credential, and presenting it opened a
higher-generation socket that *evicted the real phone* on the next `POST /frames`. It is now
useless to a holder who cannot also present the bound key.

> **DEPRECATED — pubkey-less `device_token`s.** Tokens minted *before* this change carry no
> `device_pubkey` claim. They keep working, unbound, with or without a `&device_pubkey=` param,
> **until their own `exp`** — at most `DEVICE_TOKEN_TTL_S` (30 days) after the deploy that
> shipped this. The tolerance is mandatory, not cosmetic: a phone paired beforehand has no way
> to obtain a bound token except a physical re-scan of a QR nobody is standing in front of.
> Once the last such token has expired, the `boundPubkey === undefined` branch in
> `verifyDeviceToken` (`src/pairing.ts`) can be deleted and the claim made required.

Note what this does *not* add: there is still no per-device revocation. `POST /revoke` is
session-wide (INV-29's `{device_pubkey_fp}` parameter remains unimplemented), and the token
carries no `jti`, so revoking one device means ending the session.

- `101` — upgraded; the first frame sent on the socket is always `device_bound`
  (`{"type": "device_bound", "sender": "relay", "payload": {"device_token": "...", "exp":
  1234567890}}`, plaintext, relay-originated). On a fresh `pairing_code` claim only, the relay
  also writes a second `device_bound` frame — differently shaped — into hmd's `GET /stream`:
  `{"type": "device_bound", "sender": "relay", "payload": {"device_pubkey": "<echoed back
  exactly as sent>", "bound_at": 1234567890}}`. `device_pubkey` here is still base64url,
  unpadded — the same alphabet as the `&device_pubkey=` query param above, never re-encoded to
  standard/padded base64; a consumer that decodes it as standard base64 only will fail key
  derivation on every real device (found live 2026-09-24 against a real heimdall client — see
  `docs/HANDBACK-FROM-HEIMDALL-relay-client-fixes.md` item 6). This lets hmd derive the session
  key without the phone ever sending its pubkey through an encrypted frame. Buffered (at most
  this one control frame, per session) if hmd's stream isn't open yet, and flushed as the first
  line the moment it connects. The buffer is Durable Object **storage**, not memory: nothing keeps
  the object resident while hmd is away, and a frame held only on the instance was lost when the
  object was evicted before hmd reconnected (hmd then never derived the session key).
- **A bind supersedes the previous device socket.** Every accepted upgrade (claim *or*
  `device_token` reconnect) first closes whatever device socket the session already had, with
  close code **`4002` / `"superseded"`** — deliberately distinct from `/revoke`'s `4001`, since
  the session is still very much alive and the client should go on reconnecting. One session,
  one live device socket, newest wins. This is the phone leg's counterpart to `GET /stream`'s
  long-standing "a reconnect closes the stream it replaces".

  Why it matters: a phone that loses Wi-Fi sends no close frame and no TCP reset, so this relay
  keeps its socket for as long as Cloudflare's own timeout takes (minutes), while the phone
  notices in seconds and reconnects. Without superseding, the session accumulated two device
  sockets and `POST /frames` delivered to the *older* one — the dead one — answering
  `delivered: true` for every frame. Reproduced live on 2026-09-24 against the deployed relay:
  the reconnected socket sat open and silent for 22s while `state` seq 3-7 went to the socket
  the dropped Wi-Fi session had left behind. Covered by `test/worker.spec.ts`'s "device socket
  supersede (reconnect after a network drop)" suite.
- `400` — `device_pubkey` is missing, or doesn't decode to exactly 32 bytes (`pairing_code`
  claim only).
- `401` — `pairing_code` doesn't match; or `device_token` is invalid/expired; or the token is
  pubkey-bound and `device_pubkey` is absent or does not match the bound key.
- `410` — pairing code already claimed, or expired.
- `429` + `Retry-After: 60` — more than 10 claim attempts against one session within 60s. On
  this leg the status is not observable to a React Native client (see INV-25 under
  "Deviations"); it is reported honestly for any other caller.

#### What the relay accepts *on* the socket

Every message is gated four ways before a byte reaches hmd's stream:

1. **Size (INV-16, both legs).** A message over `MAX_ENVELOPE_BYTES` (1 MiB) is never parsed;
   the socket is closed with **`1009`** ("message too big") and the frame logged as
   `frame_rejected` / `envelope_exceeds_size_cap`. Until this, the cap existed only on `POST
   /frames`, and Cloudflare's own ~1 MiB WebSocket limit was the sole thing standing between a
   phone and the relay here.
2. **Provenance.** Only `sender: "device"` with `type: "command"` is forwarded (`isDeviceFrame`,
   `src/types.ts`). Anything else — `sender:"relay"`, `device_bound`, `session_ended`,
   `keepalive`, `state`, `ack`, `sender:"hmd"` — is dropped and logged, never forwarded. This is
   the single most important gate in the file: hmd re-derives its session key from *any*
   `device_bound` it reads off its stream, so forwarding a phone-sent one rebound the session to
   the sender's own X25519 key — a full end-to-end break by a party holding no credential at all.
3. **Session state (INV-9/INV-10).** The record is re-read *per frame*, not cached as "this
   connection was trusted at upgrade". A session that is not `bound` drops the frame and closes
   the socket with **`4001`**. This is what makes revocation immediate even when `handleRevoke`'s
   `close()` throws (its `catch` swallows one) or races a hibernated socket.
4. **Token expiry.** The admitting token's `exp` is stamped onto the socket's hibernation
   attachment and checked per frame; past it, the frame is dropped and the socket closed with
   **`4003`** ("device token expired"). Without this a phone that never dropped kept a 30-day
   credential working indefinitely. A socket accepted before this field existed carries no
   `token_exp` and is served until it drops — the relay has no honest expiry to apply to it.

Close codes on this leg: `1009` oversize, `4001` session ended/revoked, `4002` superseded,
`4003` device token expired. All four mean "reconnect" to the app except `4001`; a reconnect
after `4001`/`4003` meets a truthful `410`/`401` at the upgrade, which is how the operator
learns to re-pair.

### `POST /session/:id/revoke` — hmd leg, requires the same bearer

Response `200 {"ok": true}`. Closes the bound device's WebSocket with close code `4001` and
turns any further `pairing_code` claim into `410`. Arms the purge alarm below at a 5-minute
grace.

## Storage reclamation (purge schedule)

`SessionDO` used to write its record and delete it on no path at all — not on revoke, not on
pairing expiry — so every `/pair/init` left a persistent row behind forever. A Durable Object
alarm now reclaims storage, re-deriving the deadline from the record on every pass rather than
trusting whenever the alarm happened to be set:

| Session state | Reclaimed at |
|---|---|
| `pending`, unclaimed | `pair_exp` + 60s grace (i.e. ~2 minutes after `/pair/init`) |
| `bound` | the `device_token`'s `exp` + 60s grace — 30 days, the last moment it could reconnect |
| `ended` (revoked, expired, or claim-throttled) | 5 minutes after it ended |
| `/pair/init` throttle bucket | one window + grace after the IP's last request |

The grace exists so a client that is merely late — a phone reconnecting seconds after its token
lapsed, hmd re-reading a just-revoked session — meets a truthful `410`/`401` instead of a bare
`404` that reads like "wrong session id". Purging closes any attached device socket (`4001`) and
hmd's stream — after first telling hmd why, below — then `deleteAll()`s; it logs `session_purged`
with the `session_id` and status.

An unclaimed session therefore lives ~2 minutes: nothing ends it on a timer before its pairing
window (60 s) closes, and the purge lands 60 s after that. That second minute is invisible to the
phone (a claim after the window is `410`), but it is what hmd's client sees as the end of a
`connect` nobody scanned in time.

### hmd is told why a session ended (INV-38)

Whenever the relay ends hmd's `GET /stream` because the **session** is over, it first writes one
plaintext control frame, then closes the stream:

```json
{"v":1,"session_id":"<uuid>","seq":0,"sender":"relay","type":"session_ended","nonce":null,"ciphertext":null,"payload":{"reason":"pairing-expired"}}
```

| `payload.reason` | When |
|---|---|
| `pairing-expired` | the ~60 s pairing window lapsed with no phone bound — at the purge, or when a late claim finds it so. Re-run `hmd app connect` for a fresh code |
| `claim-throttled` | more than 10 claim attempts in 60 s ended the session (INV-4) |
| `expired` | a bound session's `device_token` lapsed and storage was reclaimed |
| `ended` | an already-ended session was reclaimed with a stream still attached |

hmd's client already treats `session_ended` as terminal and logs `payload.reason`, so no client
change is needed. Not announced, because the session is not over or hmd is ending it: a superseding
`GET /stream`, the stream-lifetime bound (hmd reconnects), and `POST /revoke`. If hmd's stream is
not attached at that instant (mid-reconnect, or orphaned by a deploy) there is nothing to write to
and the reconnect meets `404`. Each announcement is logged as `session_end_announced` (`reason`,
`delivered`).

Before this, the same end was a bare EOF followed by `404`, which hmd's client logged as "stream
closed by relay with no local cause … likely the relay's own stream-lifetime bound" and
`session_ended: stream-404`. That is the 2026-10-02 field bug: two `connect`s whose QR no phone
bound, both ended by this purge, at 120.0 s and 120.1 s after `/pair/init`.

#### Verifying a deploy

```
node relay/scripts/pairing-expiry-probe.mjs --relay https://<worker>
```

Plays hmd for one throwaway session no phone claims and holds its stream ~2.5 minutes. Exit `0`:
the relay announced a reason before the stream ended. `1`: bare EOF — a relay that predates
INV-38. `3`: still open at `--hold-s`. Prints timings, statuses and frame types only, never a
token, a code or a URL.

**A `bound` record written before `device_token_exp` existed is never purged early** — it has no
honest deadline, so each pass re-arms a full TTL out. A session live across the deploy that
shipped this keeps running.

### `Envelope` (wire shape, both directions)

```json
{
  "v": 1,
  "session_id": "<uuid>",
  "seq": 1,
  "sender": "hmd",
  "type": "state",
  "nonce": "<string, opaque>",
  "ciphertext": "<string, opaque>",
  "payload": { "...": "plaintext, only on device_bound / session_ended" }
}
```

`type` is a closed set: `state` | `command` | `ack` | `device_bound` | `session_ended` |
`keepalive`. `nonce` / `ciphertext` are forwarded byte-identical in both directions — the relay
does not decode, validate, or transform them — and are `null` on the three plaintext control
types. `payload` is a relay-side addition (never present on `state` / `command` / `ack`) that
carries plaintext relay-originated data — a `device_bound` sent to the *phone* carries
`{device_token, exp}`; a `device_bound` written into *hmd's* `GET /stream` carries
`{device_pubkey, bound_at}` instead (see the `ws` endpoint above) — the two are the same frame
`type` on two different legs, never both fields at once. A `keepalive` (hmd's stream only)
carries `{ts}`. Client tracks should only trust a relay-minted field this way when it arrives
via `device_bound`, never inside a `state`/`command`/`ack` frame's `payload`.

A client that does not recognise a control `type` should skip that line, not treat it as an
error — that is how `keepalive` was added without breaking the phone leg (`decodeRelayFrame` in
`src/relay/protocol.ts` already returns `null` for an unknown type and `RelayTransport` drops
it silently).

## Security hardening pass — 2026-09-24 audit

Every response this Worker builds carries
`Strict-Transport-Security: max-age=31536000; includeSubDomains` (no `preload` — that is a
one-way door owned by whoever operates the domain, not by this Worker). TLS interception does
not break end-to-end confidentiality, but the phone-leg upgrade URL carries `pairing_code` /
`device_token` in its query string, which is enough to claim a session or evict the bound phone.

Audited findings addressed here: **1** (per-leg sender/type allowlist), **6** (pubkey-bound
`device_token`, legacy-tolerant), **7** (`/pair/init` throttle + storage reclamation), **8**
(INV-16 on the phone leg), **9** (per-frame re-validation), **13** (fail-closed token claims),
**15** (the secret-signing sentence above, corrected), **18** (HSTS).

Deliberately **not** changed here, with reasons:

- **Finding 17 — `isPlaintextUpgrade` fails open on absence of both scheme headers.** Gating the
  dev fallback on an explicit `RELAY_ALLOW_PLAINTEXT_DEV` binding is the textbook fix, and in
  front of Cloudflare both headers are always set, so INV-7 already holds in production. That
  cuts both ways: the change can only matter where it cannot occur, and getting it wrong breaks
  the reconnect of a phone that is paired right now. Left as the documented deviation it already
  was.
- **Finding 12 — INV-25's `1013` close code on the phone leg.** Still not emitted; the claim
  throttle fires strictly pre-upgrade, so there is no live WebSocket to close. Making it visible
  to React Native would mean accepting the upgrade purely to close it, changing a response shape
  documented in `docs/HANDOFF-TO-HEIMDALL-relay.md`. Recorded honestly in `INVARIANTS.md`
  instead — an invariant ledger that lists guarantees the code does not provide is worse than one
  that lists fewer.
- **Finding 12's session-kill** — 11 wrong claims against a known `session_id` end the pairing
  before the legitimate phone scans it. That is INV-4 exactly as specified, so it is a design
  consequence, not a code bug; accepted risk. The new `/pair/init` throttle bounds session
  *creation* but not this.
- **Finding 14 — signing-secret rotation.** No key id, no overlap window; see "Deploy" above for
  what a rotation costs. Adding a versioned token format is a wire change, not a ≤10-line fix.
- **Finding 16 — session-existence oracle** (`404`/`410`/`401`/`400` distinguishable to an
  unauthenticated caller). Session ids are UUIDv4, so this is not practically enumerable;
  accepted, as the audit recommends.
- **Finding 19 — `session_id` in logs** is a correlation handle. Left as-is: it is the only
  field that makes a log line actionable, and the relay already holds everything it addresses.

## Deviations / scope decisions from the delta brief (disclosed)

- Root `tsconfig.json` gained `"relay"` in `exclude` — without it, root `tsc --noEmit` fails
  because `relay/`'s Workers-runtime globals (`DurableObjectState`, `WebSocketPair`, ...) and
  the `cloudflare:test` module aren't in root's `types` allowlist. Confirmed by a real failing
  root `tsc` run before the fix.
- Root `package.json`'s jest `testPathIgnorePatterns` was **not** touched: root jest's
  `testMatch` only matches `*.test.ts?(x)`, and every relay test file is named `*.spec.ts`, so
  root `npx jest --listTests` never discovers them (confirmed empirically — zero matches).
- No persisted frame buffering: `POST /frames` with no phone connected returns `{"ok": true,
  "delivered": false}` rather than queuing — simpler, and honestly reports non-delivery instead
  of silently dropping frames or adding an untested retry path. One narrow exception, added
  2026-09-26: the single most recent hmd->device `state` envelope is kept (not a queue — always
  overwritten, never a history) and replayed to a device socket the instant it is next accepted,
  closing the "reconnect gets nothing until the next digest change" gap. See
  `docs/superpowers/specs/relay/INVARIANTS.md`'s "State replay on reconnect" section (INV-36).
- No separate `POST /session/:id/end` — `/revoke` already covers session termination (device
  closed with `4001`, further claims `410`); a distinct graceful-end endpoint would be
  unrequested, untested scope.
- `device_token` defaults to a 30-day expiry — not spec-mandated, chosen as a reasonable
  reconnect window; revisit if a client track needs a different value.
- `wrangler.toml`'s `compatibility_date` is pinned to `2026-08-22` (not "today") — the installed
  local `workerd` binary refused to boot at a newer date (`vitest run` failed with "newest date
  supported by this server binary is 2026-08-22" until this was pinned back); update it
  deliberately, in step with the installed toolchain, rather than bumping it to "today" again.
- A scoped `relay/.gitignore` (`node_modules/`, `.wrangler/`, `.dev.vars`, `dist/`,
  `*.tsbuildinfo`) was added instead of one `relay/node_modules` line in the root `.gitignore` —
  keeps this self-contained package's ignore rules with the package itself; the root
  `.gitignore` is untouched.
- INV-25's relay-side WS close-code `1013` deviation: the relay's only throttle mechanism
  (`MAX_CLAIM_ATTEMPTS` in `src/session.ts`'s `handlePairingCodeClaim`) fires strictly
  pre-upgrade — the throttled request never completes a WebSocket handshake, so there is no
  live WebSocket to emit a `1013` close frame on. The relay already reports this throttle via
  HTTP `429` + `Retry-After: 60` + a matching `retry_after_s` body field
  (`test/trace/mutants-ack-retry.spec.ts`'s `MUT-INV-25-ignore-retry-after` case covers this). A
  `1013`-carrying close frame would require throttling an already-open device WebSocket, which
  no code path in this relay does today; adding one only to exercise an otherwise-untriggered
  deviation would be new, untested scope beyond this fix.
- The hmd-leg `GET /session/:id/stream` response closes server-side on `POST
  /session/:id/revoke` (`src/session.ts`'s `handleRevoke` → `closeHmdStream()`) and when a
  reconnect supersedes it. It still has no close hook tied to Durable Object
  hibernation/eviction: Cloudflare's Hibernation API preserves accepted WebSockets
  (`ctx.acceptWebSocket`, used for the device leg) across eviction, but this stream is a plain
  in-memory `ReadableStreamDefaultController` on a chunked HTTP response, which has no
  equivalent user-code "about to evict" hook to run cleanup in. That is why every write goes
  through `writeToHmdStream`, which treats a throwing `enqueue` as "this stream is gone",
  drops the stale controller and reports non-delivery — rather than letting the throw escape
  and take the caller's frame with it.
- **What hibernates, and what does not (Durable Object duration).** The phone leg is a
  Hibernation-API socket (`ctx.acceptWebSocket`, `webSocketMessage`/`Close`/`Error`, per-socket
  state on `serializeAttachment`), and a bound session with no hmd stream open can be evicted
  right after any request. hmd's NDJSON `GET /stream` cannot hibernate: an open response holds the
  object resident, and with it the `setTimeout` keepalive and lifetime timers, so a Durable Object
  is billed wall-clock (128 MB) for as long as that stream is open — about 10.8k GB-s per day
  for one session with hmd always on. hmd's WebSocket leg (above) is a Hibernation-API socket with
  no timer, so with it connected the object sleeps between events. Measurements, the estimate for
  the WebSocket leg, and how to measure duration before/after:
  `docs/analysis/2026-10-05-relay-hibernation.md`. The eviction-based proofs are
  `test/hibernation.spec.ts` and `test/hmd-ws.spec.ts`.
- **The keepalive is a `setTimeout` chain, not a Durable Object alarm.** An alarm is the durable
  choice and survives eviction, but this DO has no other alarm use and a 20s alarm rescheduled
  forever would pin the object awake for the life of a session, billed, purely to write filler.
  The keepalive only has value while a stream is actually open — and an open chunked response
  already keeps the DO in memory — so the timer is tied to the stream's lifetime and cleared on
  every path that ends one (`cancel`, revoke, a superseding reconnect, a failed write).
  Verified empirically: `setTimeout` fires inside the DO after `fetch()` has returned, for as
  long as the response body is unfinished (`test/worker.spec.ts`'s "stream lifetime" suite runs
  against the real `workerd`, not a mock).
- **Keepalive cadence is idle-based, not a fixed tick** — the timer restarts on every write, so
  a stream carrying traffic emits no keepalives at all. A plain `setInterval` would have been
  one line shorter and would have written a keepalive every 20s regardless.

## fake-hmd.mjs

A plain-Node dev/test tool that plays the laptop (hmd) side of the relay protocol against a
real deployed relay — for interop testing without a real hmd client or a real phone. Lives
under `relay/scripts/`, alongside `check-no-logged-urls.mjs`/`trace-diff.mjs`, not under `src/`:
it needs real filesystem and outbound-network access, which `@cloudflare/vitest-pool-workers`'
`workerd` runtime doesn't provide.

```
node relay/scripts/fake-hmd.mjs --relay https://hmd-relay.therishabh16.workers.dev \
  [--state docs/samples/state.json] [--phone-pubkey <base64>]
```

It calls `POST /pair/init`, generates an X25519 keypair, prints the pairing payload (the
`RelayPayload` shape `src/store/relayPayload.ts` parses) as one JSON line on stdout, opens
`GET /session/:id/stream`, waits for `device_bound`, derives the session key from the phone's
pubkey the relay forwards in that frame's `payload.device_pubkey` (`--phone-pubkey <base64>`
overrides this), then seals and POSTs a `state` envelope (the `--state` file, default
`docs/samples/state.json`) every 5s with an increasing seq, decrypts incoming `command`
envelopes (printing a `send-message`'s text to stderr as `[phone] <text>`), and answers each
with an `ack` envelope. Ctrl-C POSTs `/revoke` before exiting. It never logs
`relay_session_token` or `device_token`.

`node --test scripts/__tests__/fake-hmd.test.mjs` (wired into `npm test`, run via the glob
`scripts/__tests__/*.test.mjs` — a bare directory argument doesn't auto-discover test files
under this Node version) covers `lib/relay-crypto.mjs` against the same golden vector
`src/relay/__tests__/vectors.test.ts` uses (`src/relay/__tests__/fixtures/vectors.json`),
`resolvePhonePubkey`'s override-vs-payload-fallback priority, a full phone-seals /
hmd-opens-and-acks / phone-opens-ack round trip, and the reconnect ladder —
`nextBackoffMs`/`runStreamWithReconnect` driven through close, open-failure, cap, reset,
session-end, stop and fatal-vs-retryable-throw paths with an injected clock, no relay and no
socket.

Verified against the live relay above: `/pair/init`, keypair generation, the printed payload
line, and `GET /stream` all open successfully, and `device_bound` now carries a usable
`device_pubkey` end-to-end — `resolvePhonePubkey` derives the session key from it without
needing `--phone-pubkey` at all (the flag remains as a manual override for testing without a
real phone client).

### Decisions (disclosed)

- **The three `@noble/*` packages are relay's own `devDependencies`** (`ciphers`/`curves`/
  `hashes`, all `^2.4.0`, matching root's pin), installed via `npm --prefix relay install` —
  not a `createRequire(import.meta.url)` reach into root's `node_modules`. Reaching into root
  would contradict this directory's own stated self-containment (top of this file: "its own
  `package.json`... never imported by the rest of this repo"); relay already declares and
  installs its own dependencies for everything else.
- **`relay-crypto.mjs` and `envelope.mjs` are reimplementations, not imports,** of
  `src/relay/crypto.ts` and `src/relay/protocol.ts`. `crypto.ts` imports `@/relay/randomBytes` →
  `react-native-get-random-values`, unavailable in plain Node; `protocol.ts`'s inner-frame shape
  is `src/relay/protocol.ts`'s own encode/decode, reimplemented.
  `relay-crypto.mjs` is verified byte-exact against the same shared fixture
  `src/relay/__tests__/vectors.test.ts` checks.

  **Both legs encode the same full `Envelope`** (`relay/src/types.ts`). `protocol.ts` used to
  emit a narrower phone-leg frame (`{type, seq, ciphertext}`, no `v`/`session_id`/`sender`/
  `nonce`, on the reasoning that the WS URL already scopes the session and direction is
  implicit on a 1:1 socket). The relay does not read the wire that way: `isEnvelope` requires
  all four, so every phone-sent `command` was dropped by `webSocketMessage` before any logging,
  and hmd's own `decodeEnvelope` would have rejected it again. Fixed 2026-09-24 — see
  `src/relay/protocol.ts`'s header for the live evidence, and
  `scripts/__tests__/phone-leg-interop.test.mjs` for the test that now runs the app's real
  encoder through the relay's real validator and hmd's real decoder. `decodeRelayFrame` stays
  deliberately lenient in the other direction; that asymmetry is what let `keepalive` ship
  relay-side with no coordinated app release.
- **QR printing is skipped, deliberately.** A correct QR encoder needs Reed-Solomon GF(256) ECC,
  correct finder/alignment/timing module placement, and BCH-encoded format/version info — none
  of that is achievable correctly in a small dependency-free encoder, and an incorrect QR (one
  that *looks* like a QR code but doesn't decode, or decodes to the wrong bytes) is worse than
  none. The tool prints the same payload as one JSON line instead and says so on stderr.
- **The wire `nonce` field is real, derived data, not a placeholder.** `crypto.ts`'s own `open()`
  already anticipates "a wire-supplied nonce, if any" and says it is never trusted on decode —
  the true nonce is always reconstructed from `(sender tag, seq)` alone (INV-13). So
  `envelope.mjs` computes the true nonce for display, and no decoder anywhere reads it back.
- **`scripts/**` was added to `vitest.config.ts`'s `exclude`.** Vitest's default include glob
  otherwise also collects `scripts/__tests__/fake-hmd.test.mjs` and fails on it (its `test` comes
  from `node:test`, not vitest) — the same "plain Node script needs real fs/network" reasoning
  that keeps `check-no-logged-urls.mjs` out of the vitest suite.
- **State is sent unconditionally every 5s** (immediately on key derivation, then every 5s
  after), per the brief, not gated on a digest-of-state change (INV-22, which governs a real hmd
  client's traffic — not this interop tool, whose `--state` file is static for the run anyway).
- **Ack `ok:false` fires only for a structurally-malformed command payload**
  (`detail: "malformed-command"`) — it does not reproduce `/api/send`'s four real rejection
  reasons (`empty`/`too-long`/`secret-shaped`/`inbox-full`, INV-23), since this tool never runs
  `/api/send`'s own validation.
- **The stream is reconnected with backoff; `device_token` reconnect is still not implemented,
  and only Ctrl-C/SIGINT is handled** (not `SIGTERM`). The backoff arrived with the 2026-09-24
  live finding above: Cloudflare cut the stream at 5m01s, undici raised a bare
  `TypeError('terminated')`, and the old `main().catch` turned that into `fatal: terminated` and
  exited — taking the phone's session down with it. `runStreamWithReconnect` (exported, unit
  tested) now reopens `GET /stream` on any drop, 1s doubling to a 30s cap, resetting the ladder
  after any stream that actually opened so a five-minute cut cycle never creeps the delay
  upward. The session key, `seq` counters and 5s state timer live outside the loop and survive a
  reconnect untouched — `device_bound` fires once per session and is never re-sent. `keepalive`
  frames are read and discarded silently (at one every 20s, logging them would bury everything
  else). Only three things still terminate the process: a `/pair/init` failure, an explicit
  `session_ended`, and a `401` on the stream (a `FatalStreamError`, the one throw the loop does
  not retry) — a rejected bearer cannot be fixed by reconnecting. `device_token` reconnect
  remains out of scope, as before.
