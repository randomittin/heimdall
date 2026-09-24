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

- **hmd leg** (laptop, authenticated): `GET /session/:id/stream` — a long-lived chunked-HTTP
  response, one NDJSON-encoded envelope per line, for frames the phone sent, plus a
  `keepalive` control frame every 20s of idleness (see "Stream lifetime" below). `POST
  /session/:id/frames` — send one envelope to the phone. Both require
  `Authorization: Bearer <relay_session_token>`.
- **phone leg** (WebSocket): `wss://.../session/:id/ws?pairing_code=<code>` for the first claim,
  or `?device_token=<token>` to reconnect after binding.
- **pairing**: `POST /pair/init` (unauthenticated) creates a session and returns a session id, a
  single-use ~60s pairing code, and the hmd-side bearer token.

The relay stores and forwards **ciphertext only** for `state` / `command` / `ack` frames — it
never sees plaintext. `device_bound`, `session_ended` and `keepalive` are the three
relay-originated control frames; they carry plaintext (e.g. the freshly minted `device_token`)
because they are never sealed by either peer — the relay holds no session key and could not
seal them if it wanted to.

## Deploy

```
cd relay
npx wrangler login
npx wrangler secret put RELAY_SIGNING_SECRET
npx wrangler deploy
```

`RELAY_SIGNING_SECRET` HMAC-signs every `relay_session_token` / `device_token` (session id, role,
and expiry are baked into the signed payload) — generate it with any high-entropy random-string
tool; it is never a literal in this repo, only a Workers secret. Durable Objects require the
Workers Paid plan (~$5/mo) — the free plan cannot bind them.

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

### `POST /pair/init` — unauthenticated

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

#### Stream lifetime

**Cloudflare closes a long-lived chunked response that carries no bytes.** Observed live on
2026-09-24 against the deployed relay: a stream opened at 08:33:53 with a phone bound and state
frames flowing, then sat idle and was closed server-side at 08:38:54 — 5m01s later. A relay
session is idle by nature (hmd sends `state` only on a digest change, INV-22), so this is the
steady state, not an edge case.

Two independent mitigations, because either alone is insufficient:

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

   `relay/scripts/fake-hmd.mjs` implements exactly this contract and is the reference for
   `bin/heimdall-relay-client` (see `docs/HANDOFF-TO-HEIMDALL-relay.md`'s "Stream lifetime").

### `POST /session/:id/frames` — hmd leg, requires the same bearer

Body: one `Envelope` (JSON). Response `200 {"ok": true, "delivered": <bool>}` — `delivered:
false` (not an error) when no phone is currently connected; the frame is not buffered or
retried.

- `413` — envelope exceeds 128 KiB.
- `401` / `400` / `404` — same as `/stream`.

### `GET /session/:id/ws?pairing_code=<code>` or `?device_token=<token>` — phone leg

Must be a real WebSocket upgrade (`Upgrade: websocket`) over an effectively-`wss` connection —
`400` if the `Upgrade` header is missing, or if `X-Forwarded-Proto: http` /
`cf-visitor: {"scheme":"http"}` signal a plaintext hop in front of the Worker. A `pairing_code`
claim also requires `&device_pubkey=<base64url, 32 bytes>` in the query string — not required
(and not re-validated) on a `device_token` reconnect.

- `101` — upgraded; the first frame sent on the socket is always `device_bound`
  (`{"type": "device_bound", "sender": "relay", "payload": {"device_token": "...", "exp":
  1234567890}}`, plaintext, relay-originated). On a fresh `pairing_code` claim only, the relay
  also writes a second `device_bound` frame — differently shaped — into hmd's `GET /stream`:
  `{"type": "device_bound", "sender": "relay", "payload": {"device_pubkey": "<echoed back
  exactly as sent>", "bound_at": 1234567890}}`, so hmd can derive the session key without the
  phone ever sending its pubkey through an encrypted frame. Buffered (at most this one control
  frame, per session) if hmd's stream isn't open yet, and flushed as the first line the moment
  it connects.
- `400` — `device_pubkey` is missing, or doesn't decode to exactly 32 bytes (`pairing_code`
  claim only).
- `401` — `pairing_code` doesn't match, or `device_token` is invalid/expired.
- `410` — pairing code already claimed, or expired.
- `429` + `Retry-After: 60` — more than 10 claim attempts against one session within 60s.

### `POST /session/:id/revoke` — hmd leg, requires the same bearer

Response `200 {"ok": true}`. Closes the bound device's WebSocket with close code `4001` and
turns any further `pairing_code` claim into `410`.

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
  of silently dropping frames or adding an untested retry path.
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
  (`{type, seq, ciphertext}`, no `nonce`/`session_id`/`sender` — direction is implicit on a
  single persistent WebSocket) is the *phone* leg's, one level narrower than hmd's leg
  (`Envelope`, `relay/src/types.ts:32-41` — richer because `POST /frames` and `GET /stream` are
  separate HTTP exchanges with no persistent connection to make direction implicit).
  `relay-crypto.mjs` is verified byte-exact against the same shared fixture
  `src/relay/__tests__/vectors.test.ts` checks.
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
