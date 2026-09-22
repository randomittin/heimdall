// Shared wire types for the hmd relay Worker + Durable Object.
//
// Shapes mirror docs/superpowers/specs/2026-09-21-hmd-relay-design.md §2.3
// (envelope + inner payload table) and docs/superpowers/specs/relay/INVARIANTS.md.
// The relay never decrypts `ciphertext` — it only ever sees the opaque
// envelope shape below (INV-18, INV-31).

export interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SIGNING_SECRET: string;
}

/** "relay" is not in the spec's sender enum — it is used only for the two
 * control frame types the relay itself is allowed to originate (INV-33). */
export type FrameSender = "hmd" | "device" | "relay";

export type FrameType =
  | "state"
  | "command"
  | "ack"
  | "device_bound"
  | "session_ended";

/**
 * The wire envelope (spec §2.3). `nonce`/`ciphertext` are null for the two
 * unencrypted control frame types (`device_bound`, `session_ended` — INV-20,
 * INV-21). `payload` carries the plaintext body of those two control types
 * only; the relay never holds a session key (INV-18) so it can never
 * populate `payload` for `state`/`command`/`ack` — those pass through as
 * opaque `ciphertext` untouched.
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

export interface ErrorResponse {
  error: string;
  retry_after_s?: number;
}

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
