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
