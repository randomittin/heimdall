// Bearer-token authentication for the routes that write (upload, rate) and for reading a PRIVATE
// receipt. The service never holds a token: API_TOKEN_SHA256S is a list of SHA-256 digests, and a
// presented token is accepted only when its digest is in the list. Mint one with
// `openssl rand -hex 32`, store `printf %s "$token" | shasum -a 256`, hand the token out.
//
// Fail closed: an unset or malformed list is "disabled" (the write routes answer 503), never "open".

import { sha256Hex } from "./receipt";
import type { Env } from "./types";

export type Auth = "ok" | "missing" | "invalid" | "disabled";

const DIGEST_RE = /^[0-9a-f]{64}$/;
const BEARER_RE = /^Bearer ([\x21-\x7e]{16,512})$/;

function configuredDigests(env: Env): string[] | null {
  const entries = (env.API_TOKEN_SHA256S ?? "").split(/[\s,]+/).filter(Boolean).map((entry) => entry.toLowerCase());
  // One malformed entry disables the whole list: a half-parsed list would quietly drop a token.
  return entries.length > 0 && entries.every((entry) => DIGEST_RE.test(entry)) ? entries : null;
}

function sameHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function authenticate(request: Request, env: Env): Promise<Auth> {
  const digests = configuredDigests(env);
  if (!digests) return "disabled";
  const match = BEARER_RE.exec(request.headers.get("Authorization") ?? "");
  if (!match) return "missing";
  const presented = await sha256Hex(new TextEncoder().encode(match[1]));
  let accepted = false;
  for (const digest of digests) accepted = sameHex(presented, digest) || accepted; // visit every entry
  return accepted ? "ok" : "invalid";
}
