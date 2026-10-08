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

/**
 * How long a pairing code stays claimable after `/pair/init` — and with it any session code
 * registered against that session, which lives exactly as long as the session's window
 * (relay/contract/code-pair.json `pair_window_s`). hmd keeps a session code offered by running
 * `/pair/init` again and re-registering it, about every 5 minutes; each registration sends the
 * laptop's GitHub token, so the interval is kept long and the window made to outlast it (360 s),
 * rather than the other way round: a window shorter than the interval leaves the code unclaimable
 * between renewals. The purge lands `PURGE_GRACE_MS` after the window closes (src/session.ts), so
 * an unclaimed session lives 7 minutes.
 *
 * Not a client's to set. `/pair/init` builds the Durable Object's init body itself (src/worker.ts)
 * and `init` is outside the Worker's public sub-paths, so no request can lengthen this.
 */
export const PAIRING_CODE_TTL_S = 360;
export const MAX_CLAIM_ATTEMPTS = 10;
export const CLAIM_WINDOW_MS = 60_000;
export const CLAIM_THROTTLE_RETRY_AFTER_S = 60;

/**
 * `/pair/init` throttle bounds (2026-09-24 audit, finding 7). INV-5 keeps the
 * endpoint identity-free on purpose — nobody has a credential yet — but INV-5
 * also says it is "bounded by mint + TTL + **throttle**", and the throttle
 * half did not exist: an unauthenticated loop minted one Durable Object with a
 * persistent row per request, forever. 10 per minute per source IP is far
 * above any honest client (a human scans one QR at a time) and far below a
 * useful cost-amplification rate.
 */
export const PAIR_INIT_MAX_PER_WINDOW = 10;
export const PAIR_INIT_WINDOW_MS = 60_000;
export const PAIR_INIT_RETRY_AFTER_S = 60;

/**
 * The optional `RELAY_PURGE_MIN_DELAY_MS` binding (src/types.ts) as a number of milliseconds: how
 * far from now a storage-reclamation alarm is armed at the soonest. 0 -- no floor, every alarm
 * exactly where the code puts it -- for an absent, empty, non-numeric, zero or negative value, so a
 * bad binding can never move a purge earlier or switch reclamation off. Only the vitest suite
 * binds it.
 */
export function purgeMinDelayMs(raw: string | undefined): number {
  if (raw === undefined) return 0;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

/**
 * Generic sliding-window counter. `attempts` is a persisted list of prior
 * timestamps (ms); returns the pruned+appended list plus whether THIS attempt
 * is the one that crosses `maxInWindow`.
 */
export function recordAttempt(
  attempts: number[],
  nowMs: number,
  windowMs: number,
  maxInWindow: number
): { attempts: number[]; throttled: boolean } {
  const withinWindow = attempts.filter((t) => nowMs - t < windowMs);
  withinWindow.push(nowMs);
  return {
    attempts: withinWindow,
    throttled: withinWindow.length > maxInWindow,
  };
}

/**
 * Sliding-window claim-attempt throttle (INV-4). The caller marks the session
 * permanently invalid when this returns `throttled` and never re-evaluates the
 * code again, matching "the 11th invalidates the `session_id` outright."
 */
export function recordClaimAttempt(
  attempts: number[],
  nowMs: number
): { attempts: number[]; throttled: boolean } {
  return recordAttempt(attempts, nowMs, CLAIM_WINDOW_MS, MAX_CLAIM_ATTEMPTS);
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
  /**
   * The base64url X25519 public key the device presented when it claimed the
   * pairing code, verbatim. Binds the token to *that* device: a reconnect must
   * re-present the same value or the token is refused (2026-09-24 audit,
   * finding 6 — before this, an exfiltrated `device_token` was a 30-day bearer
   * credential for anyone, and presenting it evicted the real phone).
   *
   * **Optional for legacy tolerance, and only for that.** Tokens minted before
   * this claim existed carry no `device_pubkey`; refusing them would strand
   * already-paired phones with no route back but a physical re-scan, so they
   * stay valid — unbound — until their own `exp`. Every token minted from now
   * on carries the claim. DEPRECATED: pubkey-less tokens are accepted only
   * until the last one minted before this change expires (`DEVICE_TOKEN_TTL_S`
   * after deploy); the `undefined` branch in `verifyDeviceToken` can be
   * deleted after that, and the tolerance is documented in relay/README.md.
   */
  device_pubkey?: string;
}

/** device_token = HMAC-SHA256 over the claims JSON (§2.2 step 6, INV-9/10/29/30). */
export async function mintDeviceToken(
  secret: string,
  claims: DeviceTokenClaims
): Promise<string> {
  const payload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await hmacSha256(secret, payload);
  return `${payload}.${signature}`;
}

/**
 * Verifies signature, `session_id` binding, role, expiry, and — for a token
 * that carries the claim — that `presentedPubkey` is the key the token was
 * minted for. Returns the verified claims, or `null` on any failure. Never
 * trusts the decoded claims before the signature check passes (constant-time
 * compare).
 *
 * Fails closed on a malformed claims body: `JSON.parse("null")` used to escape
 * the `try` and throw a `TypeError` on the next property read (a 500 where a
 * 401 belongs), and an absent `exp` made `nowMs / 1000 > claims.exp` a NaN
 * comparison — always false, i.e. a token that never expired (finding 13).
 * Neither is reachable without the signing secret; both are one refactor away
 * from mattering.
 */
export async function verifyDeviceToken(
  secret: string,
  token: string,
  sessionId: string,
  nowMs: number,
  presentedPubkey: string | null
): Promise<DeviceTokenClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payload, signature] = parts as [string, string];
  const expectedSignature = await hmacSha256(secret, payload);
  if (!timingSafeEqual(signature, expectedSignature)) return null;

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload)));
  } catch {
    return null;
  }
  if (typeof decoded !== "object" || decoded === null) return null;
  const claims = decoded as Record<string, unknown>;

  if (claims.session_id !== sessionId || claims.role !== "device") return null;
  if (typeof claims.exp !== "number" || !Number.isFinite(claims.exp)) return null;
  if (nowMs / 1000 > claims.exp) return null;

  const boundPubkey = claims.device_pubkey;
  if (boundPubkey !== undefined) {
    if (typeof boundPubkey !== "string") return null;
    if (presentedPubkey === null) return null;
    if (!timingSafeEqual(presentedPubkey, boundPubkey)) return null;
  }

  const verified: DeviceTokenClaims = { session_id: sessionId, role: "device", exp: claims.exp };
  if (typeof boundPubkey === "string") verified.device_pubkey = boundPubkey;
  return verified;
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Strict unpadded base64url of exactly `byteLength` bytes, or `null`. The relay's own
 * `base64UrlDecode` throws on bad input and happily takes padding and either alphabet;
 * everything pair-by-code accepts off the wire (install_pubkey, hmd_commit, sig) goes
 * through this instead, so there is one spelling of each value and a malformed one is a
 * `null` the caller maps to its own 4xx, never an exception out of a handler.
 */
export function decodeFixedBase64Url(value: unknown, byteLength: number): Uint8Array | null {
  if (typeof value !== "string") return null;
  if (value.length !== Math.ceil((byteLength * 4) / 3)) return null;
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const bytes = base64UrlDecode(value);
    return bytes.length === byteLength ? bytes : null;
  } catch {
    return null;
  }
}

/** gh_assertion validity: 30 days, the same horizon as a device_token. Revocation is
 *  `not_before` at the index (src/code-index.ts), not this expiry, which only bounds how
 *  long a NEVER-revoked sign-in survives on a phone that is never signed out. */
export const GH_ASSERTION_TTL_S = 60 * 60 * 24 * 30;

/** Longest GitHub login the relay will carry. GitHub's own bound is 39 characters; the
 *  slack is for `[bot]`-style and enterprise-managed suffixes. */
export const MAX_GH_LOGIN_LENGTH = 64;

export interface GhAssertionClaims {
  v: 1;
  /** Same word as a device_token's role, kept on purpose: the two are kept apart by their
   *  secrets (RELAY_IDENTITY_SECRET vs RELAY_SIGNING_SECRET) and their claim sets, not by
   *  a differently-spelled role. */
  role: "device";
  gh_id: number;
  gh_login: string;
  /** Unpadded base64url Ed25519 public key (32 bytes) of the phone's install key: every
   *  use of the assertion must be signed by it (INV-43). */
  install_pubkey: string;
  iat: number; // epoch seconds
  exp: number; // epoch seconds
}

/** gh_assertion = base64url(claims JSON) "." base64url(HMAC-SHA256(secret, that payload)) —
 *  `mintDeviceToken`'s construction, keyed with RELAY_IDENTITY_SECRET. */
export async function mintGhAssertion(
  secret: string,
  claims: GhAssertionClaims
): Promise<string> {
  const payload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await hmacSha256(secret, payload);
  return `${payload}.${signature}`;
}

/**
 * The verified claims of a gh_assertion, or `null` on any failure — bad shape, a signature
 * from another secret, an expired `exp`, or claims that are not a well-formed assertion.
 * Fails closed the way `verifyDeviceToken` does (finding 13): the signature is checked
 * constant-time before the payload is trusted, and every claim is type-checked after it,
 * because a correct signature proves who minted the body, not that the body means anything.
 */
export async function verifyGhAssertion(
  secret: string,
  token: string,
  nowMs: number
): Promise<GhAssertionClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payload, signature] = parts as [string, string];
  const expectedSignature = await hmacSha256(secret, payload);
  if (!timingSafeEqual(signature, expectedSignature)) return null;

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload)));
  } catch {
    return null;
  }
  if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) return null;
  const claims = decoded as Record<string, unknown>;

  if (claims.v !== 1 || claims.role !== "device") return null;
  const { gh_id, gh_login, install_pubkey, iat, exp } = claims;
  if (typeof gh_id !== "number" || !Number.isSafeInteger(gh_id) || gh_id <= 0) return null;
  if (typeof gh_login !== "string" || gh_login.length === 0 || gh_login.length > MAX_GH_LOGIN_LENGTH) {
    return null;
  }
  if (decodeFixedBase64Url(install_pubkey, 32) === null) return null;
  if (typeof iat !== "number" || !Number.isFinite(iat)) return null;
  if (typeof exp !== "number" || !Number.isFinite(exp)) return null;
  if (nowMs / 1000 > exp) return null;

  return {
    v: 1,
    role: "device",
    gh_id,
    gh_login,
    install_pubkey: install_pubkey as string,
    iat,
    exp,
  };
}

/**
 * Whether `signature` is `installPubkey`'s Ed25519 signature over `message` (RFC 8032,
 * pure). WebCrypto, so nothing is bundled; both inputs are strict fixed-length base64url
 * and any failure — a malformed key or signature, a point the runtime refuses — is `false`,
 * never a throw: this runs on attacker-chosen bytes.
 */
export async function verifyInstallSignature(
  installPubkey: string,
  message: Uint8Array,
  signature: string
): Promise<boolean> {
  const publicKey = decodeFixedBase64Url(installPubkey, 32);
  const signatureBytes = decodeFixedBase64Url(signature, 64);
  if (publicKey === null || signatureBytes === null) return false;
  try {
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signatureBytes, message);
  } catch {
    return false;
  }
}
