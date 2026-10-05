// Test helpers: every key here is generated per run (vitest.config.ts) or per test, never committed.
import { env, SELF } from "cloudflare:test";
import { canonical } from "../src/canonical";
import { parseTrust, SIGN_PREFIX } from "../src/receipt";
import type { Env, JsonObject } from "../src/types";

export const BASE = "https://receipts.test";

export interface TestEnv extends Env {
  TEST_SIGNING_SEED_B64: string;
  TEST_API_TOKEN: string;
}
export const testEnv = env as unknown as TestEnv;
export const TOKEN = testEnv.TEST_API_TOKEN;
export const bearer = { Authorization: `Bearer ${TOKEN}` };

export interface Signer {
  key: CryptoKey;
  keyId: string;
}

const PKCS8_ED25519_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);
const toB64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));

/** The signer whose public key the Worker was configured to trust. */
export async function trustedSigner(): Promise<Signer> {
  const seed = Uint8Array.from(atob(testEnv.TEST_SIGNING_SEED_B64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", new Uint8Array([...PKCS8_ED25519_PREFIX, ...seed]), { name: "Ed25519" }, false, ["sign"]);
  const [keyId] = [...(await parseTrust(testEnv.RECEIPT_PUBKEYS as string)).keys()];
  return { key, keyId: keyId as string };
}

/** A signer nobody trusts. */
export async function strangerSigner(): Promise<Signer> {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  return { key: pair.privateKey, keyId: Array.from(digest.slice(0, 8), (b) => b.toString(16).padStart(2, "0")).join("") };
}

export const uniqueId = (): string => `r${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
export const uniqueIp = (): string => crypto.randomUUID();

export function receiptBody(over: JsonObject = {}): JsonObject {
  return {
    schema: "runhmd.receipt/1", id: uniqueId(), created_at: "2026-10-05T12:00:00Z", visibility: "public", verdict: "DENIED",
    subject: { kind: "path", head_sha: null, tree_sha256: "c".repeat(64) },
    attacks: { total: 24, survived: 21, killed: 3 },
    findings: [
      { id: "f-0001", title: "duplicate settlement (webhook+retry within 50ms)", severity: "high", category: "concurrency", digest: `sha256:${"a".repeat(64)}` },
      { id: "f-0002", title: "missing auth check on /refunds", severity: "medium", category: "auth", digest: `sha256:${"b".repeat(64)}` },
    ],
    agent: { name: "none", model: null }, cost_usd: 0.41, duration_s: 1.25, tool: { name: "hmd", version: "2.4.3" },
    verdict_sha256: "d".repeat(64), ...over,
  };
}

/** The file bytes of `body` signed by `signer`: canonical JSON of the whole document plus one LF. */
export async function signBody(body: JsonObject, signer: Signer): Promise<Uint8Array> {
  const withKey = { ...body, key_id: signer.keyId };
  const message = new Uint8Array([...SIGN_PREFIX, ...new TextEncoder().encode(canonical(withKey))]);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, signer.key, message));
  return new TextEncoder().encode(`${canonical({ ...withKey, signature: toB64(signature) })}\n`);
}

export async function issue(over: JsonObject = {}, signer?: Signer): Promise<{ id: string; raw: Uint8Array }> {
  const body = receiptBody(over);
  return { id: body.id as string, raw: await signBody(body, signer ?? (await trustedSigner())) };
}

export function upload(raw: Uint8Array | string, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`${BASE}/api/receipts`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp(), ...bearer, ...headers },
    body: raw,
  });
}

export function get(path: string, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers });
}

export function rate(id: string, findingId: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`${BASE}/r/${id}/f/${findingId}/rate`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp(), ...bearer, ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export const bytesOf = async (response: Response): Promise<Uint8Array> => new Uint8Array(await response.arrayBuffer());
