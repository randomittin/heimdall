// Shared wire types for the hmd relay Worker + Durable Object.
//
// Shapes mirror docs/superpowers/specs/2026-09-21-hmd-relay-design.md §2.3
// (envelope + inner payload table) and docs/superpowers/specs/relay/INVARIANTS.md.
// The relay never decrypts `ciphertext` — it only ever sees the opaque
// envelope shape below (INV-18, INV-31).

export interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SIGNING_SECRET: string;
  /** Optional build identifier `GET /health` reports as `version`
   *  (src/health.ts). The deploy pipeline injects the commit sha with
   *  `wrangler deploy --var BUILD_ID:<sha>` so its canary check can tell the
   *  NEW build from a stale one. Declared nowhere in wrangler.toml — absent
   *  (local dev, vitest, a hand-run `wrangler deploy`) or empty, `/health`
   *  reports package.json's version. Not a secret. */
  BUILD_ID?: string;
  /** Optional override, in milliseconds, for how long hmd's `GET /stream`
   *  may sit idle before the relay writes a `keepalive` control frame
   *  (src/session.ts's KEEPALIVE_INTERVAL_MS). Declared nowhere in
   *  wrangler.toml — production and `wrangler dev` run on the code default;
   *  only the vitest suite binds it (vitest.config.ts), so the interval is
   *  observable inside a test's lifetime. Not a secret. */
  RELAY_KEEPALIVE_MS?: string;
  /** Optional override, in milliseconds, for the longest a single hmd `GET
   *  /stream` may live before the relay closes it (src/session.ts's
   *  MAX_STREAM_LIFETIME_MS). Bound on the same terms as
   *  RELAY_KEEPALIVE_MS above — vitest-only, absent in wrangler.toml, not a
   *  secret. */
  RELAY_STREAM_MAX_LIFETIME_MS?: string;
  /** Pair-by-session-code (src/code-pair.ts). The public client id of the project's GitHub
   *  App: a `[vars]` entry in wrangler.toml, not a secret. Optional in the type because
   *  all three of this and the two below must be set for code pairing to run; any one
   *  unset or empty and every code-pairing route answers 503 `code pairing disabled`. */
  GITHUB_CLIENT_ID?: string;
  /** The GitHub App's client secret, a Workers secret (`wrangler secret put`). Used only
   *  as the Basic-auth half of the check-token and delete-token calls (src/github.ts). */
  GITHUB_CLIENT_SECRET?: string;
  /** HMAC key of the gh_assertion (src/pairing.ts's mintGhAssertion), a Workers secret,
   *  distinct from RELAY_SIGNING_SECRET so the two token kinds can never stand in for each
   *  other. */
  RELAY_IDENTITY_SECRET?: string;
  /** Optional origin every GitHub call is sent to, default `https://api.github.com`.
   *  Declared nowhere in wrangler.toml: only the vitest suite binds it, to point the relay
   *  at its fake GitHub. Not a secret. */
  GITHUB_API_BASE?: string;
}

/** "relay" is not in the spec's sender enum — it is used only for the two
 * control frame types the relay itself is allowed to originate (INV-33). */
export type FrameSender = "hmd" | "device" | "relay";

export type FrameType =
  | "state"
  | "command"
  | "ack"
  | "device_bound"
  | "session_ended"
  | "keepalive"
  | "key_reveal";

/**
 * The wire envelope (spec §2.3). `nonce`/`ciphertext` are null for the three
 * unencrypted control frame types (`device_bound`, `session_ended` — INV-20,
 * INV-21 — and `keepalive`). `payload` carries the plaintext body of those
 * control types only; the relay never holds a session key (INV-18) so it can
 * never populate `payload` for `state`/`command`/`ack` — those pass through
 * as opaque `ciphertext` untouched.
 */
export interface Envelope {
  v: 1;
  session_id: string;
  seq: number;
  sender: FrameSender;
  type: FrameType;
  nonce: string | null;
  ciphertext: string | null;
  payload?: Record<string, unknown>;
}

export interface PairInitResponse {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

/** Sent to the phone as device_bound's payload on a fresh pairing-code claim
 *  (never on a device_token reconnect — see acceptDeviceSocket's
 *  hmdControlPayload parameter, which the reconnect path never passes). */
export interface DeviceBoundToPhonePayload {
  device_token: string;
  exp: number; // epoch seconds
}

/** Written into hmd's GET /stream as a plaintext device_bound control frame
 *  once per session (buffered if the stream isn't open yet — see
 *  SessionDO.deliverToHmdStream) so hmd can derive the session key without
 *  the phone ever needing to send its own pubkey back through an encrypted
 *  frame. */
export interface DeviceBoundToHmdPayload {
  device_pubkey: string; // whatever encoding the phone sent verbatim, forwarded unchanged
  bound_at: number; // epoch seconds
  /** How the phone got the pairing code it claimed with: a released code window, or the QR.
   *  `code` is what tells hmd to send `key_reveal` and ask the laptop user to approve the SAS
   *  before it seals anything (spec 5.5). Absent on a relay that predates pair-by-code, which
   *  a client reads as `qr`. */
  via: "code" | "qr";
  /** `via: "code"` only. What the phone called itself when it asked for the window --
   *  validated, but the phone's own claim and never proof of anything. */
  device_label?: string;
  /** `via: "code"` only. The GitHub login the phone's assertion proved. */
  gh_login?: string;
}

/** Payload of the `keepalive` control frame the relay writes into hmd's
 *  `GET /stream` while that stream would otherwise sit idle (see
 *  src/session.ts's KEEPALIVE_INTERVAL_MS for why). `ts` is the relay's own
 *  clock at write time — informational only: no client is expected to trust
 *  it, compare it against its own clock, or act on it. A `keepalive` carries
 *  no session state and is safe for any reader to skip. */
export interface KeepalivePayload {
  ts: number; // epoch seconds
}

/**
 * Why the relay ended a session that hmd still held a `GET /stream` for — the
 * `reason` in a `session_ended` frame written down that stream (INV-38).
 * hmd's client logs it verbatim and stops, so each value names what an
 * operator should do next:
 * - `pairing-expired` — the ~60s pairing window lapsed with no phone bound;
 *   run `hmd app connect` again for a fresh code.
 * - `claim-throttled` — more than 10 claim attempts in 60s ended the session
 *   (INV-4).
 * - `expired` — a bound session's `device_token` lapsed and storage was
 *   reclaimed.
 * - `ended` — any other session already ended, reclaimed while a stream was
 *   still attached to it.
 * `POST /revoke` is absent on purpose: hmd is the one ending that session.
 */
export type SessionEndReason = "pairing-expired" | "claim-throttled" | "expired" | "ended";

export interface SessionEndedPayload {
  reason: SessionEndReason;
}

export interface ErrorResponse {
  error: string;
  retry_after_s?: number;
}

/**
 * Structural validation only — shape, not provenance. `keepalive` is
 * deliberately absent from the accepted `type` set below: it is
 * relay-originated only, on the one leg (hmd's `GET /stream`) the relay itself
 * writes, so accepting one inbound would only widen the surface with a frame
 * that has no meaning in that direction.
 *
 * **This is not a leg gate on its own, and must never be used as one.** It
 * accepts `sender: "relay"` and the two relay-originated control types, which
 * is exactly the hole finding 1 of the 2026-09-24 security audit exploited:
 * `webSocketMessage` used to forward anything that passed here straight into
 * hmd's stream, so a phone could push a `sender:"relay"` `device_bound` and
 * rebind hmd's session key to its own X25519 key. Every client-facing path
 * goes through `isDeviceFrame` / `isHmdFrame` below instead.
 */
export function isEnvelope(value: unknown): value is Envelope {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    v.v === 1 &&
    typeof v.session_id === "string" &&
    typeof v.seq === "number" &&
    (v.sender === "hmd" || v.sender === "device" || v.sender === "relay") &&
    (v.type === "state" ||
      v.type === "command" ||
      v.type === "ack" ||
      v.type === "device_bound" ||
      v.type === "session_ended" ||
      v.type === "key_reveal") &&
    (v.nonce === null || typeof v.nonce === "string") &&
    (v.ciphertext === null || typeof v.ciphertext === "string")
  );
}

/**
 * The phone leg's gate: a frame the *device* is allowed to originate.
 *
 * `command` is the whole set. The app emits nothing else — `RelayTransport`
 * has one `ws.send`, always `sender: "device"`, `type: "command"` — and
 * `state`/`ack` are hmd's to originate, while `device_bound`/`session_ended`/
 * `keepalive` are the relay's. A frame claiming any of those from the phone
 * socket is a forgery attempt by definition, never a client that drifted.
 */
export function isDeviceFrame(value: unknown): value is Envelope {
  if (!isEnvelope(value)) return false;
  return value.sender === "device" && value.type === "command";
}

/**
 * The laptop leg's gate: a frame *hmd* is allowed to originate, checked on
 * `POST /frames`.
 *
 * `state` and `ack` are the set — `send_hmd_frame` in
 * `bin/heimdall-relay-client` is the single call site on that side and passes
 * only those two. Symmetric to `isDeviceFrame`: holding hmd's bearer token
 * must not let a caller mint a control frame the relay itself owns, nor
 * impersonate the device on the leg that feeds the phone.
 */
export function isHmdFrame(value: unknown): value is Envelope {
  if (!isEnvelope(value)) return false;
  if (value.sender !== "hmd") return false;
  if (value.type === "state" || value.type === "ack") return true;
  return isKeyReveal(value);
}

/**
 * `key_reveal` (INV-44): hmd's public key and the nonce its commitment was made with, sent to
 * the phone in the clear after a bind that came through a code window (pair-by-session-code,
 * spec 5.5). It is the only hmd->phone frame type that carries a plaintext `payload`, so it is
 * held to exactly that: no `nonce`, no `ciphertext`, a `payload` that is an object. What is in
 * the payload is not the relay's to read -- the phone checks it against the commitment it was
 * given before the key was known -- and `isDeviceFrame` still refuses the type from the phone.
 */
function isKeyReveal(value: Envelope): boolean {
  if (value.type !== "key_reveal") return false;
  if (value.nonce !== null || value.ciphertext !== null) return false;
  const payload: unknown = value.payload;
  return typeof payload === "object" && payload !== null && !Array.isArray(payload);
}
