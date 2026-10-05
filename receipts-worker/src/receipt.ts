// Verification of a runhmd.receipt/1 file. A port of `verify_bytes`, `load_trust` and `key_id_of`
// in bin/lib/runhmd_receipt.py, with the same checks in the same order and the same error kinds
// (not_json, schema, not_canonical, unknown_key, bad_signature, no_trust, bad_trust), which is
// what contract/vectors.json pins from both languages.
//
// The public key is NEVER taken from the receipt: `trust` is the pinned set the operator
// configured (RECEIPT_PUBKEYS), keyed by key_id = first 16 hex digits of SHA-256(raw 32-byte key).

import { canonical, canonicalBytes, CanonicalError } from "./canonical";
import { validateReceipt } from "./schema";
import type { JsonObject } from "./types";

export const SCHEMA_ID = "runhmd.receipt/1";
export const MAX_RECEIPT_BYTES = 1024 * 1024;
/** Domain separation: this key signs nothing else, and nothing else's signature is a receipt's. */
export const SIGN_PREFIX = new TextEncoder().encode("runhmd.receipt/1\n");

export class ReceiptError extends Error {
  kind: string;
  detail: string;
  constructor(kind: string, detail: string) {
    super(`${kind}: ${detail}`);
    this.kind = kind;
    this.detail = detail;
  }
}

/** key_id -> raw 32-byte Ed25519 public key. */
export type Trust = Map<string, Uint8Array>;

const toHex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const toB64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));
const fromB64 = (text: string): Uint8Array => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

export async function keyIdOf(publicRaw: Uint8Array): Promise<string> {
  return (await sha256Hex(publicRaw)).slice(0, 16);
}

const TRUST_CACHE = new Map<string, Trust>();

/** The pinned trust set in `text`: one canonical base64 32-byte key per line, blanks and `#` comments
 *  skipped. A line that is not such a key is a hard error, never skipped. */
export async function parseTrust(text: string): Promise<Trust> {
  const cached = TRUST_CACHE.get(text);
  if (cached) return cached;
  const trust: Trust = new Map();
  for (const [index, rawLine] of text.split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    if (!/^[A-Za-z0-9+/]{43}=$/.test(line) || toB64(fromB64(line)) !== line) {
      throw new ReceiptError("bad_trust", `line ${index + 1} is not a canonical base64 32-byte Ed25519 public key`);
    }
    const raw = fromB64(line);
    trust.set(await keyIdOf(raw), raw);
  }
  TRUST_CACHE.set(text, trust);
  return trust;
}

function parse(raw: Uint8Array): unknown {
  if (raw.byteLength > MAX_RECEIPT_BYTES) throw new ReceiptError("not_json", `larger than ${MAX_RECEIPT_BYTES} bytes`);
  let text: string;
  try {
    // fatal: invalid UTF-8 is an error. ignoreBOM: keep a BOM so JSON.parse rejects it, as Python does.
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(raw);
  } catch {
    throw new ReceiptError("not_json", "not valid UTF-8");
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new ReceiptError("not_json", `not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.byteLength === b.byteLength && a.every((value, i) => value === b[i]);
}

async function ed25519Verify(publicRaw: Uint8Array, signature: Uint8Array, message: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("raw", publicRaw, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, message);
  } catch {
    return false; // a malformed key or signature is a failed verification, never a crash
  }
}

/** The receipt document in `raw`, once EVERYTHING holds: it is JSON, it is a runhmd.receipt/1
 *  document that satisfies its schema and invariants, `raw` is exactly its canonical form (plus an
 *  optional final LF), it names a key in the pinned `trust` set, and the signature over
 *  SIGN_PREFIX + canonical(document without signature) is that key's, in canonical base64.
 *  Throws ReceiptError for anything else, and for nothing but ReceiptError. */
export async function verifyReceipt(raw: Uint8Array, trust: Trust): Promise<JsonObject> {
  if (trust.size === 0) throw new ReceiptError("no_trust", "no trusted receipt public key is configured");
  const parsed = parse(raw);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed) || (parsed as JsonObject).schema !== SCHEMA_ID) {
    throw new ReceiptError("schema", `not a ${SCHEMA_ID} document`);
  }
  const doc = parsed as JsonObject;
  const problems = validateReceipt(doc);
  if (problems.length) throw new ReceiptError("schema", problems.slice(0, 5).join("; "));
  let expected: Uint8Array;
  try {
    expected = canonicalBytes(doc);
  } catch (error) {
    if (error instanceof CanonicalError) throw new ReceiptError("not_canonical", `the document has no canonical form: ${error.message}`);
    throw error;
  }
  const withLf = new Uint8Array(expected.byteLength + 1);
  withLf.set(expected);
  withLf[expected.byteLength] = 0x0a;
  if (!sameBytes(raw, expected) && !sameBytes(raw, withLf)) {
    throw new ReceiptError("not_canonical", "the bytes are not the canonical form of the document they spell; the signature covers only that form");
  }
  const publicRaw = trust.get(doc.key_id as string);
  if (!publicRaw) {
    throw new ReceiptError("unknown_key", `signed by key ${doc.key_id}, which is not in the pinned trust set (${[...trust.keys()].sort().join(", ")})`);
  }
  const signature = doc.signature as string;
  if (toB64(fromB64(signature)) !== signature) throw new ReceiptError("bad_signature", "the signature is not canonical base64");
  const body = Object.fromEntries(Object.entries(doc).filter(([key]) => key !== "signature"));
  const message = new Uint8Array([...SIGN_PREFIX, ...new TextEncoder().encode(canonical(body))]);
  if (!(await ed25519Verify(publicRaw, fromB64(signature), message))) {
    throw new ReceiptError("bad_signature", `the signature does not match the receipt for key ${doc.key_id}: it was changed after it was signed, or signed by another key`);
  }
  return doc;
}
