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
 * Validates an envelope arriving *from* a client — hmd's `POST /frames` body
 * or a phone WebSocket message. `keepalive` is deliberately absent from the
 * accepted `type` set below: it is relay-originated only, on the one leg
 * (hmd's `GET /stream`) the relay itself writes, so accepting one inbound
 * would only widen the surface with a frame that has no meaning in that
 * direction.
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
