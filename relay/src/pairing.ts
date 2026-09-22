// Pure pairing-protocol helpers: pairing_code / relay_session_token
// generation, HMAC device_token mint+verify, and the claim throttle
// (INV-1..5). No Durable Object or Worker-specific state lives here —
// src/session.ts owns storage; these are deterministic functions over
// explicit inputs (including "now", so callers/tests control time instead of
// this module reaching for a clock itself).

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** 26-char base32 (>=128 bits of entropy: 26 * 5 = 130 bits) — spec §2.1 step 2. */
export function generatePairingCode(): string {
  const bytes = new Uint8Array(17); // 136 bits sampled, 130 used (26 * 5)
  crypto.getRandomValues(bytes);
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 0x1f];
      bits -= 5;
    }
  }
  return output.slice(0, 26);
}

/** 32 random bytes, base64url-encoded — hmd's own bearer credential (§2.1 step 2). */
export function generateSessionToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlDecode(value: string): Uint8Array {
  const padLength = (4 - (value.length % 4)) % 4;
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat(padLength);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export const PAIRING_CODE_TTL_S = 60;
export const MAX_CLAIM_ATTEMPTS = 10;
export const CLAIM_WINDOW_MS = 60_000;
export const CLAIM_THROTTLE_RETRY_AFTER_S = 60;

/**
 * Sliding-window claim-attempt throttle (INV-4). `attempts` is the
 * session's persisted list of prior claim-attempt timestamps (ms); this
 * returns the pruned+appended list plus whether THIS attempt is the one that
 * crosses the bound (the 11th within the window) — the caller marks the
 * session permanently invalid at that point and never re-evaluates the code
 * again, matching "the 11th invalidates the session_id outright."
 */
export function recordClaimAttempt(
  attempts: number[],
  nowMs: number
): { attempts: number[]; throttled: boolean } {
  const withinWindow = attempts.filter((t) => nowMs - t < CLAIM_WINDOW_MS);
  withinWindow.push(nowMs);
  return {
    attempts: withinWindow,
    throttled: withinWindow.length > MAX_CLAIM_ATTEMPTS,
  };
}

async function hmacSha256(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return base64UrlEncode(new Uint8Array(signature));
}

/** device_token reconnect credential validity — generous but bounded; the
 * real revocation mechanism is `POST /session/:id/revoke` (INV-29/30), not
 * this expiry, which only bounds how long a NEVER-revoked device can idle. */
export const DEVICE_TOKEN_TTL_S = 60 * 60 * 24 * 30; // 30 days

export interface DeviceTokenClaims {
  session_id: string;
  role: "device";
  exp: number; // epoch seconds
}

/** device_token = HMAC-SHA256 over {session_id, role, exp} (§2.2 step 6, INV-9/10/29/30). */
export async function mintDeviceToken(
  secret: string,
  claims: DeviceTokenClaims
): Promise<string> {
  const payload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await hmacSha256(secret, payload);
  return `${payload}.${signature}`;
}

/** Verifies signature, session_id binding, role, and expiry. Never trusts the
 * decoded claims before the signature check passes (constant-time compare). */
export async function verifyDeviceToken(
  secret: string,
  token: string,
  sessionId: string,
  nowMs: number
): Promise<boolean> {
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  const [payload, signature] = parts as [string, string];
  const expectedSignature = await hmacSha256(secret, payload);
  if (!timingSafeEqual(signature, expectedSignature)) return false;

  let claims: DeviceTokenClaims;
  try {
    claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload))) as DeviceTokenClaims;
  } catch {
    return false;
  }
  if (claims.session_id !== sessionId || claims.role !== "device") return false;
  if (nowMs / 1000 > claims.exp) return false;
  return true;
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
