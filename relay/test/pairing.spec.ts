import { describe, expect, it } from "vitest";
import {
  base64UrlDecode,
  base64UrlEncode,
  CLAIM_WINDOW_MS,
  generatePairingCode,
  generateSessionToken,
  MAX_CLAIM_ATTEMPTS,
  mintDeviceToken,
  recordClaimAttempt,
  timingSafeEqual,
  verifyDeviceToken,
} from "../src/pairing";

describe("generatePairingCode", () => {
  it("returns a 26-char base32 string from the expected alphabet", () => {
    const code = generatePairingCode();
    expect(code).toHaveLength(26);
    expect(code).toMatch(/^[A-Z2-7]{26}$/);
  });

  it("is not trivially predictable across calls", () => {
    const codes = new Set(Array.from({ length: 20 }, () => generatePairingCode()));
    expect(codes.size).toBe(20);
  });
});

describe("generateSessionToken", () => {
  it("returns a base64url string decodable back to 32 bytes", () => {
    const token = generateSessionToken();
    expect(base64UrlDecode(token)).toHaveLength(32);
  });
});

describe("base64UrlEncode / base64UrlDecode", () => {
  it("round-trips arbitrary bytes without padding or unsafe characters", () => {
    const original = new Uint8Array([0, 1, 2, 253, 254, 255, 127, 128]);
    const encoded = base64UrlEncode(original);
    expect(encoded).not.toMatch(/[+/=]/);
    expect(Array.from(base64UrlDecode(encoded))).toEqual(Array.from(original));
  });
});

describe("timingSafeEqual", () => {
  it("returns true only for identical strings", () => {
    expect(timingSafeEqual("abc", "abc")).toBe(true);
    expect(timingSafeEqual("abc", "abd")).toBe(false);
    expect(timingSafeEqual("abc", "ab")).toBe(false);
  });
});

describe("recordClaimAttempt", () => {
  it("does not throttle for the first MAX_CLAIM_ATTEMPTS attempts", () => {
    let attempts: number[] = [];
    const now = 1_000_000;
    for (let i = 0; i < MAX_CLAIM_ATTEMPTS; i++) {
      const result = recordClaimAttempt(attempts, now + i);
      attempts = result.attempts;
      expect(result.throttled).toBe(false);
    }
  });

  it("throttles on the attempt after MAX_CLAIM_ATTEMPTS within the window", () => {
    let attempts: number[] = [];
    const now = 2_000_000;
    for (let i = 0; i < MAX_CLAIM_ATTEMPTS; i++) {
      attempts = recordClaimAttempt(attempts, now + i).attempts;
    }
    const eleventh = recordClaimAttempt(attempts, now + MAX_CLAIM_ATTEMPTS);
    expect(eleventh.throttled).toBe(true);
  });

  it("prunes attempts outside the sliding window", () => {
    const now = 3_000_000;
    const staleAttempts = [now - CLAIM_WINDOW_MS - 1];
    const result = recordClaimAttempt(staleAttempts, now);
    expect(result.attempts).toEqual([now]);
    expect(result.throttled).toBe(false);
  });
});

describe("mintDeviceToken / verifyDeviceToken", () => {
  const secret = "unit-test-signing-secret";

  it("verifies a token minted for the same session and secret", async () => {
    const token = await mintDeviceToken(secret, {
      session_id: "s1",
      role: "device",
      exp: 9_999_999_999,
    });
    await expect(verifyDeviceToken(secret, token, "s1", 0)).resolves.toBe(true);
  });

  it("rejects a token checked against a different session_id", async () => {
    const token = await mintDeviceToken(secret, {
      session_id: "s1",
      role: "device",
      exp: 9_999_999_999,
    });
    await expect(verifyDeviceToken(secret, token, "s2", 0)).resolves.toBe(false);
  });

  it("rejects a token verified with a different secret", async () => {
    const token = await mintDeviceToken(secret, {
      session_id: "s1",
      role: "device",
      exp: 9_999_999_999,
    });
    await expect(verifyDeviceToken("wrong-secret", token, "s1", 0)).resolves.toBe(false);
  });

  it("rejects an expired token", async () => {
    const token = await mintDeviceToken(secret, { session_id: "s1", role: "device", exp: 1000 });
    await expect(verifyDeviceToken(secret, token, "s1", 1_000_001 * 1000)).resolves.toBe(false);
  });

  it("rejects a malformed token", async () => {
    await expect(verifyDeviceToken(secret, "not-a-real-token", "s1", 0)).resolves.toBe(false);
  });

  it("rejects a token with a tampered payload", async () => {
    const token = await mintDeviceToken(secret, {
      session_id: "s1",
      role: "device",
      exp: 9_999_999_999,
    });
    const [payload] = token.split(".");
    const tampered = `${payload}.not-the-real-signature`;
    await expect(verifyDeviceToken(secret, tampered, "s1", 0)).resolves.toBe(false);
  });
});
