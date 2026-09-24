// Shared wire types for the hmd relay Worker + Durable Object.
//
// Shapes mirror docs/superpowers/specs/2026-09-21-hmd-relay-design.md §2.3
// (envelope + inner payload table) and docs/superpowers/specs/relay/INVARIANTS.md.
// The relay never decrypts `ciphertext` — it only ever sees the opaque
// envelope shape below (INV-18, INV-31).

export interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SIGNING_SECRET: string;
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
  | "keepalive";

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
      v.type === "session_ended") &&
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
  return value.sender === "hmd" && (value.type === "state" || value.type === "ack");
}
