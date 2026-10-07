// Pair by session code (design of record: hmdapp
// docs/superpowers/specs/2026-10-05-pair-by-session-code.md; wire: relay/contract/code-pair.json).
//
// This file is the Worker's half: the field validators, the config gate, and the handlers of
// the three top-level routes (`POST /identity/github`, `POST /identity/github/revoke`,
// `POST /pair/code`). The fourth route, `POST /session/:id/code`, is the session's own
// (src/session.ts); a GitHub id's index of open windows is src/code-index.ts, and the GitHub
// calls are src/github.ts.
//
// What makes the design work, in one place:
//  - A window is released to a phone only when the phone's GitHub id equals the id of the
//    laptop that opened it. The id comes from a gh_assertion the relay minted after GitHub
//    itself vouched for the phone's token, so the 5-character code is a selector among the
//    user's own windows, not a secret (INV-40, INV-42).
//  - An assertion is worthless alone: every use must be signed by the Ed25519 install key it
//    is bound to, over the code and a timestamp (INV-43), so a leaked one cannot be replayed
//    from another device.
//  - No GitHub token is kept or logged, and the phone's is deleted at GitHub (INV-39).

import {
  consumePhoneToken,
  isPlausibleGithubToken,
  verifyLaptopToken,
  type GithubUser,
  type GithubVerdict,
} from "./github";
import { jsonResponse } from "./http";
import {
  GH_ASSERTION_TTL_S,
  decodeFixedBase64Url,
  mintGhAssertion,
  verifyGhAssertion,
  verifyInstallSignature,
} from "./pairing";
import type { Env } from "./types";

/** hmd's session code alphabet (bin/lib/hmd_session_code.py): 32 symbols, no 0/1/I/O. */
export const SESSION_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const SESSION_CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}$/;

/** Exactly five characters of the alphabet, uppercase. The app normalises what a person
 *  types before it sends it; the relay is deliberately not lenient about the result. */
export function isValidSessionCode(value: unknown): value is string {
  return typeof value === "string" && SESSION_CODE_RE.test(value);
}

export const DEVICE_LABEL_MAX_CHARS = 32;

/**
 * Code points a device label may not contain. The label is the phone's own claim about
 * itself and hmd prints it in a prompt the laptop user answers (threat T7), so what is
 * refused is anything that can move the cursor, start an escape sequence or reorder the
 * line. Written as numeric ranges rather than a character-class literal on purpose: a
 * class holding U+2028 or U+2029 written out is itself a line terminator in source, and
 * an escaped one is easy to lose in an editor or a tool that rewrites it.
 */
const DEVICE_LABEL_FORBIDDEN_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x0000, 0x001f], // C0 controls, ESC among them
  [0x007f, 0x009f], // DEL and the C1 controls
  [0x061c, 0x061c], // Arabic letter mark
  [0x200e, 0x200f], // left-to-right and right-to-left marks
  [0x2028, 0x2029], // line and paragraph separators
  [0x202a, 0x202e], // bidirectional embeddings and overrides
  [0x2066, 0x2069], // bidirectional isolates
];

/** 1..32 printable characters, counted in code points. */
export function isValidDeviceLabel(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0) return false;
  // 32 code points are at most 64 UTF-16 units, so anything longer is over the cap and the
  // scan below never runs on an attacker-sized string.
  if (value.length > DEVICE_LABEL_MAX_CHARS * 2) return false;
  let count = 0;
  for (const char of value) {
    const codePoint = char.codePointAt(0) as number;
    // Iterating by code point yields a lone surrogate as a unit of its own: not text.
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) return false;
    if (DEVICE_LABEL_FORBIDDEN_RANGES.some(([low, high]) => codePoint >= low && codePoint <= high)) {
      return false;
    }
    count++;
  }
  return count <= DEVICE_LABEL_MAX_CHARS;
}

// Defined with the one door to GitHub (src/github.ts), which the browser sign-in's code exchange
// needs it in too; still importable from here, where it always was.
export { isPlausibleGithubToken };

/** What the phone's install key signs for `/pair/code` (INV-43): the code and a timestamp,
 *  under a domain label, so a signature for one purpose, code or moment is no use for
 *  another. `ts` is the request's integer, in decimal. */
export function popMessage(code: string, ts: number): Uint8Array {
  return new TextEncoder().encode(`hmd-pair-code-v1\n${code}\n${ts}`);
}

// --------------------------------------------------------------------------------------------
// Config, limits, shared responses
// --------------------------------------------------------------------------------------------

export interface CodePairConfig {
  clientId: string;
  clientSecret: string;
  identitySecret: string;
}

/** All three of GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET and RELAY_IDENTITY_SECRET, or `null`:
 *  one unset or empty and code pairing is off (every route answers 503), which is also what a
 *  self-hosted relay without a GitHub App does. The QR flow never asks. */
export function codePairConfig(env: Env): CodePairConfig | null {
  const { GITHUB_CLIENT_ID: clientId, GITHUB_CLIENT_SECRET: clientSecret, RELAY_IDENTITY_SECRET: identitySecret } = env;
  if (!clientId || !clientSecret || !identitySecret) return null;
  return { clientId, clientSecret, identitySecret };
}

export const disabledResponse = (): Response => jsonResponse(503, { error: "code pairing disabled" });

/** A 429 as every throttle here answers it: the body, and the same number in Retry-After. */
export const throttledResponse = (error: string, retryAfterS: number): Response =>
  jsonResponse(429, { error, retry_after_s: retryAfterS }, { "Retry-After": String(retryAfterS) });

/** What a GitHub verdict that is not `ok` becomes on the wire. */
export const githubFailureResponse = (reason: "rejected" | "unavailable"): Response =>
  reason === "rejected"
    ? jsonResponse(401, { error: "github token rejected" })
    : jsonResponse(502, { error: "github unavailable" });

/** Every request body on these routes is a few hundred bytes of JSON; 4 KiB is generous and
 *  bounds what an unauthenticated caller can make the relay read. */
export const MAX_CODE_PAIR_BODY_BYTES = 4096;

/** The body as text, or `null` if it is over `maxBytes`. Reads as a stream and stops at the
 *  cap, so a body with no Content-Length (chunked) is never buffered whole. */
async function readBodyCapped(request: Request, maxBytes: number): Promise<string | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > maxBytes) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

export type JsonBody = { ok: true; body: Record<string, unknown> } | { ok: false; response: Response };

/** The request's body as a JSON object, or the response that refuses it: 413 over the cap,
 *  400 `invalid json` for anything that is not an object (a number, an array, `null`). */
export async function readJsonObject(request: Request): Promise<JsonBody> {
  const text = await readBodyCapped(request, MAX_CODE_PAIR_BODY_BYTES);
  if (text === null) return { ok: false, response: jsonResponse(413, { error: "request too large" }) };
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, response: jsonResponse(400, { error: "invalid json" }) };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { ok: false, response: jsonResponse(400, { error: "invalid json" }) };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}

const BUCKET_WINDOW_MS = 60_000;
/** The `Retry-After` of every per-IP throttle here and in src/github-oauth.ts: one window. */
export const BUCKET_RETRY_AFTER_S = 60;

/** `/identity/github` and `/identity/github/revoke` share one bucket per source IP: both
 *  make the relay call GitHub on an anonymous caller's behalf. */
const IDENTITY_MAX_PER_WINDOW = 10;
const PAIR_CODE_MAX_PER_WINDOW = 20;

/** Counts one request against the source IP's bucket `name`; true when it is over. The
 *  address is the edge's own `CF-Connecting-IP`, and a missing one (not behind the edge: dev
 *  and the vitest pool) shares a bucket and is throttled like anyone, never unlimited. */
export async function overIpBucket(env: Env, request: Request, name: string, max: number): Promise<boolean> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const stub = env.SESSION.get(env.SESSION.idFromName(`${name}:${ip}`));
  const res = await stub.fetch("http://do-internal/bucket", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ max, window_ms: BUCKET_WINDOW_MS }),
  });
  return ((await res.json()) as { throttled: boolean }).throttled;
}

/** The Durable Object holding a GitHub id's index of open windows. */
export function indexStub(env: Env, ghId: number): DurableObjectStub {
  return env.SESSION.get(env.SESSION.idFromName(`code-index:${ghId}`));
}

// --------------------------------------------------------------------------------------------
// POST /identity/github  (spec 6.1)
// --------------------------------------------------------------------------------------------

/** The body of a successful sign-in -- this route's, and the browser sign-in's redeem
 *  (src/github-oauth.ts): an assertion naming the user, bound to the phone's install key and
 *  valid GH_ASSERTION_TTL_S from now. One function, so the two routes cannot drift apart. */
export async function mintSignIn(
  config: CodePairConfig,
  user: GithubUser,
  installPubkey: string
): Promise<{ gh_assertion: string; gh_id: number; gh_login: string; exp: number }> {
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + GH_ASSERTION_TTL_S;
  const assertion = await mintGhAssertion(config.identitySecret, {
    v: 1,
    role: "device",
    gh_id: user.id,
    gh_login: user.login,
    install_pubkey: installPubkey,
    iat,
    exp,
  });
  return { gh_assertion: assertion, gh_id: user.id, gh_login: user.login, exp };
}

/** The phone's sign-in: its device-flow token proves who it is once, is deleted at GitHub,
 *  and what the phone keeps instead is an assertion bound to its own install key. */
export async function handleIdentityGithub(request: Request, env: Env): Promise<Response> {
  const config = codePairConfig(env);
  if (!config) return disabledResponse();
  // Before any GitHub call: the throttle is what stops a loop here costing the relay GitHub's
  // quota (threat T8).
  if (await overIpBucket(env, request, "identity-throttle", IDENTITY_MAX_PER_WINDOW)) {
    return throttledResponse("too many identity requests", BUCKET_RETRY_AFTER_S);
  }

  const read = await readJsonObject(request);
  if (!read.ok) return read.response;
  const { gh_token: ghToken, install_pubkey: installPubkey } = read.body;
  if (decodeFixedBase64Url(installPubkey, 32) === null) {
    return jsonResponse(400, { error: "install_pubkey must decode to 32 bytes" });
  }
  if (typeof ghToken !== "string" || ghToken.length === 0) {
    return jsonResponse(400, { error: "gh_token required" });
  }
  if (!isPlausibleGithubToken(ghToken)) return githubFailureResponse("rejected");

  const verdict = await consumePhoneToken(env, config.clientId, config.clientSecret, ghToken);
  if (!verdict.ok) return githubFailureResponse(verdict.reason);

  return jsonResponse(200, await mintSignIn(config, verdict.user, installPubkey as string));
}

// --------------------------------------------------------------------------------------------
// POST /identity/github/revoke  (spec 6.4)
// --------------------------------------------------------------------------------------------

/** The laptop's answer to a lost phone: every assertion minted for this GitHub id before now
 *  stops working. Needs the laptop's own GitHub token, so it is the account's owner asking. */
export async function handleIdentityRevoke(request: Request, env: Env): Promise<Response> {
  if (!codePairConfig(env)) return disabledResponse();
  if (await overIpBucket(env, request, "identity-throttle", IDENTITY_MAX_PER_WINDOW)) {
    return throttledResponse("too many identity requests", BUCKET_RETRY_AFTER_S);
  }

  const read = await readJsonObject(request);
  if (!read.ok) return read.response;
  const { gh_token: ghToken } = read.body;
  if (typeof ghToken !== "string" || ghToken.length === 0) {
    return jsonResponse(400, { error: "gh_token required" });
  }
  if (!isPlausibleGithubToken(ghToken)) return githubFailureResponse("rejected");

  const verdict: GithubVerdict = await verifyLaptopToken(env, ghToken);
  if (!verdict.ok) return githubFailureResponse(verdict.reason);

  const revoked = await indexStub(env, verdict.user.id).fetch("http://do-internal/index-revoke", { method: "POST" });
  const { not_before: notBefore } = (await revoked.json()) as { not_before: number };
  return jsonResponse(200, { gh_login: verdict.user.login, not_before: notBefore });
}

// --------------------------------------------------------------------------------------------
// POST /pair/code  (spec 6.3)
// --------------------------------------------------------------------------------------------

/** How far a request's timestamp may be from the relay's clock, either way (INV-43). */
export const POP_SKEW_S = 60;

/**
 * The phone's code, released if it is the right phone. Everything that can be checked from
 * the request alone is checked here, cheapest first; what is left -- is there a window for
 * this code in this GitHub id's own index, and may its session release it -- is the index's
 * and the session's to answer, and arrives as one 200 or one 404.
 */
export async function handlePairCode(request: Request, env: Env): Promise<Response> {
  const config = codePairConfig(env);
  if (!config) return disabledResponse();
  if (await overIpBucket(env, request, "pair-code-throttle", PAIR_CODE_MAX_PER_WINDOW)) {
    return throttledResponse("too many attempts", BUCKET_RETRY_AFTER_S);
  }

  const read = await readJsonObject(request);
  if (!read.ok) return read.response;
  const { code, gh_assertion: assertion, ts, sig, device_label: deviceLabel } = read.body;
  if (!isValidSessionCode(code)) return jsonResponse(400, { error: "invalid code" });
  if (!isValidDeviceLabel(deviceLabel)) return jsonResponse(400, { error: "invalid device_label" });

  // One answer for an assertion that is forged, malformed, from another secret, or past its
  // exp: the app's reaction to each is the same (sign in again), and none of them is a reason
  // to say more to a caller who has not proven anything.
  const nowMs = Date.now();
  const claims = typeof assertion === "string" ? await verifyGhAssertion(config.identitySecret, assertion, nowMs) : null;
  if (!claims) return jsonResponse(401, { error: "identity expired" });

  if (typeof ts !== "number" || !Number.isInteger(ts) || Math.abs(Math.floor(nowMs / 1000) - ts) > POP_SKEW_S) {
    return jsonResponse(401, { error: "stale timestamp" });
  }
  if (typeof sig !== "string" || !(await verifyInstallSignature(claims.install_pubkey, popMessage(code, ts), sig))) {
    return jsonResponse(401, { error: "bad signature" });
  }

  return indexStub(env, claims.gh_id).fetch("http://do-internal/index-resolve", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      code,
      gh_id: claims.gh_id,
      gh_login: claims.gh_login,
      iat: claims.iat,
      device_label: deviceLabel,
    }),
  });
}
