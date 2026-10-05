// The pure pieces of pair-by-session-code, tested without a Worker: the gh_assertion
// (same HMAC construction as device_token, a different secret), the Ed25519
// proof-of-possession check, the strict base64url decoder and the field validators.
// The HTTP behaviour that composes them is relay/test/code-pair.spec.ts; the wire they
// share is relay/contract/code-pair.json.
import { describe, expect, it } from "vitest";
import { sha256 } from "@noble/hashes/sha2.js";
import contractJson from "../contract/code-pair.json";
import {
  base64UrlDecode,
  base64UrlEncode,
  decodeFixedBase64Url,
  GH_ASSERTION_TTL_S,
  mintDeviceToken,
  mintGhAssertion,
  verifyDeviceToken,
  verifyGhAssertion,
  verifyInstallSignature,
  type GhAssertionClaims,
} from "../src/pairing";
import {
  isPlausibleGithubToken,
  isValidDeviceLabel,
  isValidSessionCode,
  popMessage,
} from "../src/code-pair";

const SECRET = "unit-test-identity-secret";
const NOW_S = 1_790_000_000;

const claims = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  v: 1,
  role: "device",
  gh_id: 1234567,
  gh_login: "octocat",
  install_pubkey: base64UrlEncode(new Uint8Array(32).fill(9)),
  iat: NOW_S,
  exp: NOW_S + GH_ASSERTION_TTL_S,
  ...over,
});

/** The construction, written out independently of src/pairing.ts: base64url(claims JSON), a
 *  dot, base64url(HMAC-SHA256(secret, that base64url string)). */
async function signRaw(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return `${payload}.${base64UrlEncode(new Uint8Array(mac))}`;
}

const encodeClaims = (body: unknown): string =>
  base64UrlEncode(new TextEncoder().encode(JSON.stringify(body)));

describe("mintGhAssertion / verifyGhAssertion", () => {
  it("uses the device_token construction: base64url(claims).base64url(HMAC-SHA256(secret, payload))", async () => {
    const minted = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    expect(minted).toBe(await signRaw(SECRET, encodeClaims(claims())));
  });

  it("verifies a fresh assertion and hands back exactly its claims", async () => {
    const minted = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    await expect(verifyGhAssertion(SECRET, minted, NOW_S * 1000)).resolves.toEqual(claims());
  });

  it("honours an assertion up to its exp and not a second past it", async () => {
    const minted = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    const exp = NOW_S + GH_ASSERTION_TTL_S;
    await expect(verifyGhAssertion(SECRET, minted, exp * 1000)).resolves.not.toBeNull();
    await expect(verifyGhAssertion(SECRET, minted, (exp + 1) * 1000)).resolves.toBeNull();
  });

  it("is valid for 30 days", () => {
    expect(GH_ASSERTION_TTL_S).toBe(60 * 60 * 24 * 30);
    expect(GH_ASSERTION_TTL_S).toBe(contractJson.constants.assertion_ttl_s);
  });

  it("refuses an assertion checked against a different secret", async () => {
    const minted = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    await expect(verifyGhAssertion("another-secret", minted, NOW_S * 1000)).resolves.toBeNull();
  });

  it("refuses a payload edited after signing (the signature no longer covers it)", async () => {
    const minted = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    const signature = minted.split(".")[1] as string;
    const forged = `${encodeClaims(claims({ gh_id: 7654321 }))}.${signature}`;
    await expect(verifyGhAssertion(SECRET, forged, NOW_S * 1000)).resolves.toBeNull();
  });

  it.each([
    ["an empty string", ""],
    ["no dot", "abcdef"],
    ["three parts", "a.b.c"],
    ["a payload that is not base64", "!!!.sig"],
    ["a signature of the wrong length", `${encodeClaims(claims())}.AAAA`],
  ])("refuses %s, never throwing", async (_label, token) => {
    await expect(verifyGhAssertion(SECRET, token, NOW_S * 1000)).resolves.toBeNull();
  });

  // A correctly signed body that is not a well-formed assertion is still refused: the
  // signature proves who minted it, not that its claims mean anything (finding 13's lesson,
  // applied to the new token from its first line).
  it.each([
    ["JSON null", null],
    ["a JSON array", [1, 2]],
    ["a string", "octocat"],
    ["a missing exp", (() => { const c = claims(); delete c.exp; return c; })()],
    ["a non-numeric exp", claims({ exp: "soon" })],
    ["v 2", claims({ v: 2 })],
    ["a missing v", (() => { const c = claims(); delete c.v; return c; })()],
    ["role other than device", claims({ role: "hmd" })],
    ["gh_id as a string", claims({ gh_id: "1234567" })],
    ["gh_id 0", claims({ gh_id: 0 })],
    ["a negative gh_id", claims({ gh_id: -5 })],
    ["a fractional gh_id", claims({ gh_id: 1.5 })],
    ["a gh_id beyond the safe integers", claims({ gh_id: 2 ** 60 })],
    ["an empty gh_login", claims({ gh_login: "" })],
    ["a non-string gh_login", claims({ gh_login: 17 })],
    ["an install_pubkey that is not 32 bytes", claims({ install_pubkey: base64UrlEncode(new Uint8Array(31)) })],
    ["a padded install_pubkey", claims({ install_pubkey: `${base64UrlEncode(new Uint8Array(32))}=` })],
    ["a missing install_pubkey", (() => { const c = claims(); delete c.install_pubkey; return c; })()],
    ["a non-numeric iat", claims({ iat: "now" })],
  ])("refuses a correctly signed body with %s", async (_label, body) => {
    const token = await signRaw(SECRET, encodeClaims(body));
    await expect(verifyGhAssertion(SECRET, token, NOW_S * 1000)).resolves.toBeNull();
  });

  it("is not interchangeable with a device_token, in either direction", async () => {
    const assertion = await mintGhAssertion(SECRET, claims() as unknown as GhAssertionClaims);
    const deviceToken = await mintDeviceToken(SECRET, {
      session_id: "s1",
      role: "device",
      exp: NOW_S + 1000,
    });
    // same secret on purpose: only the claims keep the two apart
    await expect(verifyGhAssertion(SECRET, deviceToken, NOW_S * 1000)).resolves.toBeNull();
    await expect(verifyDeviceToken(SECRET, assertion, "s1", NOW_S * 1000, null)).resolves.toBeNull();
  });
});

describe("decodeFixedBase64Url", () => {
  const thirtyTwo = base64UrlEncode(new Uint8Array(32).fill(1));

  it("decodes exactly the requested length of unpadded base64url", () => {
    expect(Array.from(decodeFixedBase64Url(thirtyTwo, 32) ?? [])).toEqual(Array(32).fill(1));
    expect(decodeFixedBase64Url(base64UrlEncode(new Uint8Array(64)), 64)).toHaveLength(64);
  });

  it.each([
    ["the wrong length", base64UrlEncode(new Uint8Array(31))],
    ["too long", base64UrlEncode(new Uint8Array(33))],
    ["padding", `${thirtyTwo}=`],
    ["the standard alphabet's +", thirtyTwo.slice(0, 40).replace(/./, "+") + thirtyTwo.slice(40)],
    ["the standard alphabet's /", thirtyTwo.slice(0, 40).replace(/./, "/") + thirtyTwo.slice(40)],
    ["whitespace", ` ${thirtyTwo}`],
    ["an empty string", ""],
  ])("refuses %s", (_label, value) => {
    expect(decodeFixedBase64Url(value, 32)).toBeNull();
  });

  it("refuses a non-string without throwing", () => {
    expect(decodeFixedBase64Url(undefined, 32)).toBeNull();
    expect(decodeFixedBase64Url(42, 32)).toBeNull();
    expect(decodeFixedBase64Url(null, 32)).toBeNull();
  });
});

describe("verifyInstallSignature", () => {
  const v = contractJson.vectors.pop;
  const message = new TextEncoder().encode(v.message_utf8);

  it("accepts the contract's known-answer PoP (signed by node:crypto and noble, verified by workerd)", async () => {
    await expect(verifyInstallSignature(v.install_pub_b64url, message, v.sig_b64url)).resolves.toBe(true);
  });

  it("builds the message the vector was signed over", () => {
    expect(new TextDecoder().decode(popMessage(v.code, v.ts))).toBe(v.message_utf8);
  });

  it("refuses a tampered message", async () => {
    const other = new TextEncoder().encode(v.message_utf8.replace("4SELK", "4SELM"));
    await expect(verifyInstallSignature(v.install_pub_b64url, other, v.sig_b64url)).resolves.toBe(false);
  });

  it("refuses a tampered signature", async () => {
    const bytes = base64UrlDecode(v.sig_b64url);
    bytes[0] = (bytes[0] ?? 0) ^ 1;
    await expect(
      verifyInstallSignature(v.install_pub_b64url, message, base64UrlEncode(bytes))
    ).resolves.toBe(false);
  });

  it("refuses another key's public half", async () => {
    const other = base64UrlEncode(new Uint8Array(32).fill(3));
    await expect(verifyInstallSignature(other, message, v.sig_b64url)).resolves.toBe(false);
  });

  it.each([
    ["a short signature", base64UrlEncode(new Uint8Array(63))],
    ["a long signature", base64UrlEncode(new Uint8Array(65))],
    ["a padded signature", `${v.sig_b64url}==`],
    ["garbage", "not base64 at all"],
    ["an empty signature", ""],
  ])("refuses %s, never throwing", async (_label, sig) => {
    await expect(verifyInstallSignature(v.install_pub_b64url, message, sig)).resolves.toBe(false);
  });

  it("refuses a public key that is not 32 bytes, never throwing", async () => {
    await expect(verifyInstallSignature("AAAA", message, v.sig_b64url)).resolves.toBe(false);
  });
});

describe("contract vectors (recomputed here, from @noble/hashes, not from the relay)", () => {
  const vectors = contractJson.vectors;
  const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  const sha = (text: string): Uint8Array => sha256(new TextEncoder().encode(text));
  const concat = (...parts: Uint8Array[]): Uint8Array => {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const part of parts) {
      out.set(part, at);
      at += part.length;
    }
    return out;
  };
  const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

  const hmdPub = sha(vectors.labels.hmd_pub);
  const devicePub = sha(vectors.labels.device_pub);
  const mitmPub = sha(vectors.labels.device_pub_mitm);
  const nonceH = sha(vectors.labels.nonce_h);
  const sas = (device: Uint8Array): string => {
    const digest = sha256(concat(utf8("hmd-pair-sas-v1\0"), utf8(vectors.session_id), utf8("\0"), hmdPub, device));
    const view = new DataView(digest.buffer, digest.byteOffset, 4);
    return String(view.getUint32(0, false) % 1_000_000).padStart(6, "0");
  };

  it("stores each raw input as the SHA-256 of its label", () => {
    expect(hex(hmdPub)).toBe(vectors.raw_sha256_hex.hmd_pub);
    expect(hex(devicePub)).toBe(vectors.raw_sha256_hex.device_pub);
    expect(hex(mitmPub)).toBe(vectors.raw_sha256_hex.device_pub_mitm);
    expect(hex(nonceH)).toBe(vectors.raw_sha256_hex.nonce_h);
  });

  it("commits to hmd's key: base64url(SHA256('hmd-pair-commit-v1' 0x00 hmd_pub nonce_h))", () => {
    const commit = base64UrlEncode(sha256(concat(utf8("hmd-pair-commit-v1\0"), hmdPub, nonceH)));
    expect(commit).toBe(vectors.commit.expected_b64url);
  });

  it("derives the 6-digit SAS 817531, and 006173 when the relay swaps in its own device key", () => {
    expect(sas(devicePub)).toBe(vectors.sas.expected);
    expect(sas(mitmPub)).toBe(vectors.sas.expected_with_device_pub_mitm);
    expect(vectors.sas.expected).toBe("817531");
    expect(vectors.sas.expected_with_device_pub_mitm).toBe("006173");
  });
});

describe("field validators", () => {
  it.each(["4SELK", "ABCDE", "23456", "ZZZZZ", "HJKMN"])("accepts the code %s", (code) => {
    expect(isValidSessionCode(code)).toBe(true);
  });

  it.each([
    ["lowercase", "4selk"],
    ["four characters", "4SEL"],
    ["six characters", "4SELKX"],
    ["a 0", "40ELK"],
    ["an O", "4OELK"],
    ["a 1", "41ELK"],
    ["an I", "4IELK"],
    ["a hyphen", "4SE-K"],
    ["whitespace", "4SE K"],
    ["a trailing newline", "4SELK\n"],
    ["an empty string", ""],
  ])("refuses a code with %s", (_label, code) => {
    expect(isValidSessionCode(code)).toBe(false);
  });

  it("refuses a code that is not a string", () => {
    expect(isValidSessionCode(undefined)).toBe(false);
    expect(isValidSessionCode(45678)).toBe(false);
    expect(isValidSessionCode(["4SELK"])).toBe(false);
  });

  it.each([
    "Pixel 9a",
    "x",
    "a".repeat(32),
    "Rishabh’s iPhone",
    "\u{1F4F1}".repeat(32), // 32 code points, 64 UTF-16 units: counted in code points
    "Galaxy S24 Ültra",
  ])("accepts the device label %j", (label) => {
    expect(isValidDeviceLabel(label)).toBe(true);
  });

  it.each([
    ["empty", ""],
    ["33 characters", "a".repeat(33)],
    ["33 code points", "\u{1F4F1}".repeat(33)],
    ["a newline", "Pixel\n9a"],
    ["an ESC (terminal injection, T7)", "Pixel\u001b[2J"],
    ["a NUL", "Pixel\u00009a"],
    ["a DEL", "Pixel\u007f9a"],
    ["a C1 control", "Pixel\u00859a"],
    ["a C1 CSI", "Pixel\u009b9a"],
    ["a line separator", "Pixel 9a"],
    ["a paragraph separator", "Pixel 9a"],
    ["a right-to-left override", "Pixel‮9a"],
    ["a bidi isolate", "Pixel⁦9a"],
    ["a lone surrogate", "Pixel\ud8009a"],
  ])("refuses a device label that is %s", (_label, label) => {
    expect(isValidDeviceLabel(label)).toBe(false);
  });

  it("refuses a device label that is not a string", () => {
    expect(isValidDeviceLabel(undefined)).toBe(false);
    expect(isValidDeviceLabel(9)).toBe(false);
    expect(isValidDeviceLabel(["Pixel"])).toBe(false);
  });

  it("takes a GitHub token to be 1..255 visible ASCII characters", () => {
    expect(isPlausibleGithubToken("gho_exampleexampleexample")).toBe(true);
    expect(isPlausibleGithubToken("a".repeat(255))).toBe(true);
    expect(isPlausibleGithubToken("a".repeat(256))).toBe(false);
    expect(isPlausibleGithubToken("")).toBe(false);
    expect(isPlausibleGithubToken("has space")).toBe(false);
    expect(isPlausibleGithubToken("trailing-newline\n")).toBe(false);
    expect(isPlausibleGithubToken("tab\tinside")).toBe(false);
    expect(isPlausibleGithubToken("café")).toBe(false);
  });
});
