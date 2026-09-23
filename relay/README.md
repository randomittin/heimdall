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
  response, one NDJSON-encoded envelope per line, for frames the phone sent. `POST
  /session/:id/frames` — send one envelope to the phone. Both require
  `Authorization: Bearer <relay_session_token>`.
- **phone leg** (WebSocket): `wss://.../session/:id/ws?pairing_code=<code>` for the first claim,
  or `?device_token=<token>` to reconnect after binding.
- **pairing**: `POST /pair/init` (unauthenticated) creates a session and returns a session id, a
  single-use ~60s pairing code, and the hmd-side bearer token.

The relay stores and forwards **ciphertext only** for `state` / `command` / `ack` frames — it
never sees plaintext. `device_bound` and `session_ended` are the two relay-originated control
frames; they carry plaintext (e.g. the freshly minted `device_token`) because they never
round-trip through hmd — they exist only on the relay-to-phone leg.

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
  sent (`command` / `ack` / `state` — whatever the phone side emits).
- `401` — missing or incorrect bearer.
- `400` — malformed `:id` (not a UUID) — rejected before reaching the Durable Object.
- `404` — well-formed `:id` that was never initialized via `/pair/init`.

### `POST /session/:id/frames` — hmd leg, requires the same bearer

Body: one `Envelope` (JSON). Response `200 {"ok": true, "delivered": <bool>}` — `delivered:
false` (not an error) when no phone is currently connected; the frame is not buffered or
retried.

- `413` — envelope exceeds 128 KiB.
- `401` / `400` / `404` — same as `/stream`.

### `GET /session/:id/ws?pairing_code=<code>` or `?device_token=<token>` — phone leg

Must be a real WebSocket upgrade (`Upgrade: websocket`) over an effectively-`wss` connection —
`400` if the `Upgrade` header is missing, or if `X-Forwarded-Proto: http` /
`cf-visitor: {"scheme":"http"}` signal a plaintext hop in front of the Worker.

- `101` — upgraded; the first frame sent on the socket is always `device_bound`
  (`{"type": "device_bound", "sender": "relay", "payload": {"device_token": "...", "exp":
  1234567890}}`, plaintext, relay-originated).
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

`nonce` / `ciphertext` are forwarded byte-identical in both directions — the relay does not
decode, validate, or transform them. `payload` is a relay-side addition (never present on
`state` / `command` / `ack`) that carries the one piece of legitimately-plaintext data
(`device_bound`'s `device_token`); client tracks should only trust a relay-minted field (e.g.
`device_token`) when it arrives via `device_bound`, never inside a `state`/`command`/`ack`
frame's `payload`.

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
- The hmd-leg `GET /session/:id/stream` response now closes server-side on `POST
  /session/:id/revoke` (`src/session.ts`'s `handleRevoke` calls `hmdStreamController.close()`).
  It still has no close hook tied to Durable Object hibernation/eviction: Cloudflare's
  Hibernation API preserves accepted WebSockets (`ctx.acceptWebSocket`, used for the device leg)
  across eviction, but this stream is a plain in-memory `ReadableStreamDefaultController` on a
  chunked HTTP response, which has no equivalent user-code "about to evict" hook to run cleanup
  in. Absent revoke, a long-idle session's stream can still only be ended by the client
  disconnecting.

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
`GET /session/:id/stream`, waits for `device_bound`, derives the session key, then seals and
POSTs a `state` envelope (the `--state` file, default `docs/samples/state.json`) every 5s with
an increasing seq, decrypts incoming `command` envelopes (printing a `send-message`'s text to
stderr as `[phone] <text>`), and answers each with an `ack` envelope. Ctrl-C POSTs `/revoke`
before exiting. It never logs `relay_session_token` or `device_token`.

`node --test scripts/__tests__/fake-hmd.test.mjs` (wired into `npm test`, run via the glob
`scripts/__tests__/*.test.mjs` — a bare directory argument doesn't auto-discover test files
under this Node version) covers `lib/relay-crypto.mjs` against the same golden vector
`src/relay/__tests__/vectors.test.ts` uses (`src/relay/__tests__/fixtures/vectors.json`), plus a
full phone-seals / hmd-opens-and-acks / phone-opens-ack round trip.

Verified against the live relay above: `/pair/init`, keypair generation, the printed payload
line, and `GET /stream` all open successfully. It then blocks on `device_bound`, for the reason
in "Confirmed gaps," below.

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
- **No `device_token`-based reconnect, no backoff/retry on stream drop, and only Ctrl-C/SIGINT
  is handled** (not `SIGTERM`) — the brief's 10-step flow asks for none of these; adding them
  would be new, unrequested scope for an interop-testing tool.

### Confirmed gaps (outside this tool's scope — reported, not fixed)

Exercising steps 1-5 against the live relay surfaced two real mismatches between
`relay/src/**` and `src/transport/RelayTransport.ts`, neither of which this task's scope
(`relay/scripts/**`) covers:

1. **Query param name mismatch on the phone's claim WS.** `RelayTransport.ts`'s
   `buildConnectUrl()` (`src/transport/RelayTransport.ts:338`) sends
   `?claim=<pairing_code>&device_pubkey=<b64>&device_name=<name>`; `session.ts`'s
   `handleWsUpgrade` (`relay/src/session.ts:198-199`) reads only `pairing_code`/`device_token`
   and never `claim` at all. `RelayTransport.ts`'s own comment directly above that call
   (`:321-328`) already flags `claim` as "a documented assumption pending a live
   relay-service-core to verify against" — this confirms the assumption doesn't hold against
   the deployed relay.
2. **hmd never learns the phone's pubkey, even independent of (1).** `handleWsUpgrade` never
   reads a `device_pubkey` param under any name (`relay/src/session.ts:186-210`);
   `PairInitResponse` (`relay/src/types.ts:43-48`) and `handleInit`'s actual response body
   (`relay/src/session.ts:109-114`) carry no pubkey field either; and `acceptDeviceSocket`
   (`relay/src/session.ts:273-296`) sends the plaintext `device_bound` control frame only to the
   phone's own just-accepted WebSocket — it never touches `hmdStreamController`, which only
   `webSocketMessage` (`relay/src/session.ts:350-364`) ever writes to, and only by forwarding a
   phone-*sent* envelope verbatim. `RelayTransport.ts`'s `handleDeviceBound`
   (`src/transport/RelayTransport.ts:402-416`) doesn't send its pubkey as such an envelope
   either — it derives its session key from its own secret key plus `hmd_pubkey` (already known
   from the QR payload) and stops there. No code path, on either side of this relay as it
   stands today, ever moves a phone's pubkey to hmd.

Together: a real phone client and this real deployed relay cannot complete pairing with each
other today, with or without `fake-hmd.mjs`. `fake-hmd.mjs` still needs some way to reach step 6
to exercise steps 7-9, so it accepts `--phone-pubkey <base64>` as a disclosed manual bridge —
pass the base64 of a real or test X25519 public key and the tool proceeds exactly as if
`device_bound` had carried it. Without that flag, and without either gap above being fixed, it
prints a diagnostic naming both issues and exits `1` rather than hanging or fabricating a key.
