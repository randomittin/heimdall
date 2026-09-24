// Shared black-box client helpers for the Wave-3 relay-protocol-trace-diff
// harness (relay/test/trace/**). Independently authored per the delta brief
// ("you are the independent author — INV-drift risk in the spec requires
// that"): modeled on, but not copied from, the hmd/phone-leg idiom in
// relay/test/worker.spec.ts (pairInit/wsUrl/claimDevice/nextMessage/
// nextCloseCode/makeEnvelope/postFrame), reimplemented from scratch against
// relay/README.md's documented API and relay/src's actual behavior. This
// file is test-only tooling: it imports types (read-only) from relay/src,
// the same precedent already set by test/worker.spec.ts and
// test/pairing.spec.ts — relay/src itself is never modified from here.
import { env, SELF } from "cloudflare:test";
import { expect } from "vitest";
import type { Env, Envelope } from "../../src/types";
import { base64UrlEncode } from "../../src/pairing";

export const typedEnv = env as unknown as Env;

/** Not a secret — deterministic 32-byte filler standing in for a device's
 * X25519 public key, the same fixture idiom test/worker.spec.ts uses. A
 * `pairing_code` claim has always required `&device_pubkey=` (400 without it),
 * and since the 2026-09-24 audit's finding 6 a `device_token` reconnect must
 * re-present the same key the token was minted for. */
export const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));

export const BASE = "https://relay-trace.test";

export interface PairInitBody {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

/** Own source IP per call — `/pair/init` is throttled per `CF-Connecting-IP`
 * (src/pairing.ts's PAIR_INIT_MAX_PER_WINDOW), and the pool sends no such
 * header, so every trace session would otherwise share one bucket and start
 * 429ing partway through a seeded run. */
export async function pairInit(): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, {
    method: "POST",
    headers: { "CF-Connecting-IP": crypto.randomUUID() },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

/** Test-only setup path: talks to the Durable Object directly (bypassing the
 * Worker's /pair/init route) so a test can control `pairing_ttl_s` and build
 * a deterministically-expired session without waiting or mocking a clock —
 * the same sanctioned pattern already used by the existing Wave-1/2 suite
 * (test/worker.spec.ts's "an expired pairing code returns 410" case). Used
 * only to arrange state ahead of an assertion, never to bypass the
 * invariant a given test is actually checking. */
export async function directInit(sessionId: string, pairingTtlS?: number): Promise<PairInitBody> {
  const id = typedEnv.SESSION.idFromName(sessionId);
  const stub = typedEnv.SESSION.get(id);
  const res = await stub.fetch("http://do-internal/init", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ session_id: sessionId, pairing_ttl_s: pairingTtlS }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

export function wsUrl(sessionId: string, query: string): string {
  return `${BASE}/session/${sessionId}/ws?${query}`;
}

export async function wsUpgrade(
  sessionId: string,
  query: string,
  extraHeaders?: Record<string, string>
): Promise<Response> {
  return SELF.fetch(wsUrl(sessionId, query), {
    headers: { Upgrade: "websocket", ...extraHeaders },
  });
}

export interface ClaimedSocket {
  response: Response;
  socket: WebSocket;
}

async function acceptedSocket(response: Response): Promise<ClaimedSocket> {
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return { response, socket };
}

export async function claimDevice(sessionId: string, pairingCode: string): Promise<ClaimedSocket> {
  const response = await wsUpgrade(
    sessionId,
    `pairing_code=${pairingCode}&device_pubkey=${TEST_DEVICE_PUBKEY}`
  );
  return acceptedSocket(response);
}

export async function reconnectDevice(
  sessionId: string,
  deviceToken: string
): Promise<ClaimedSocket> {
  const response = await wsUpgrade(sessionId, reconnectQuery(deviceToken));
  return acceptedSocket(response);
}

/** The query string a real reconnect carries: the token plus the public key it
 * is bound to. Shared so the inline `wsUpgrade` call sites in the mutant specs
 * cannot drift from `reconnectDevice`. */
export function reconnectQuery(deviceToken: string): string {
  return `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${TEST_DEVICE_PUBKEY}`;
}

export function nextMessage(socket: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    socket.addEventListener(
      "message",
      (event) => resolve(JSON.parse((event as unknown as { data: string }).data)),
      { once: true }
    );
  });
}

export function nextCloseCode(socket: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    socket.addEventListener(
      "close",
      (event) => resolve((event as unknown as { code: number }).code),
      { once: true }
    );
  });
}

export function makeEnvelope(overrides: Partial<Envelope> & Pick<Envelope, "session_id">): Envelope {
  return {
    v: 1,
    seq: 1,
    sender: "hmd",
    type: "state",
    nonce: null,
    ciphertext: null,
    ...overrides,
  };
}

export async function postFrame(
  sessionId: string,
  token: string,
  envelope: Envelope | Record<string, unknown>,
  extraHeaders?: Record<string, string>
): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${sessionId}/frames`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "content-type": "application/json",
      ...extraHeaders,
    },
    body: JSON.stringify(envelope),
  });
}

export interface OpenedStream {
  reader: ReadableStreamDefaultReader<Uint8Array>;
  /** Releases the stream. The relay now closes this server-side on revoke
   * (relay/src/session.ts's handleRevoke calls
   * `hmdStreamController.close()`), but a caller must still release its own
   * end explicitly rather than relying on that: revoke doesn't happen on
   * every path that opens a stream, and even when it does, this test
   * runtime still needs the client-side reader released. `reader.cancel()`
   * is the spec-correct way to do that — it runs the underlying source's
   * `cancel()` algorithm (relay/src/session.ts's handleStream sets
   * `hmdStreamController = null` there), unlike aborting the outer fetch,
   * which does not reliably propagate to an already-resolved streaming
   * Response in this test runtime. Idempotent — safe to call more than once
   * (e.g. once from the caller's own cleanup and again from a test's
   * `afterEach` backstop). */
  close: () => Promise<void>;
}

export async function openStream(sessionId: string, token: string): Promise<OpenedStream> {
  const controller = new AbortController();
  const res = await SELF.fetch(`${BASE}/session/${sessionId}/stream`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: controller.signal,
  });
  expect(res.status).toBe(200);
  const reader = res.body?.getReader();
  if (!reader) throw new Error("expected a readable stream body");
  let released = false;
  return {
    reader,
    close: async () => {
      if (released) return;
      released = true;
      try {
        await reader.cancel();
      } catch {
        // Already errored/released server-side (e.g. revoke already closed
        // it) — the abort below still runs.
      }
      controller.abort();
    },
  };
}

/** Reads exactly one NDJSON line from an hmd-leg stream reader. Each chunk
 * is one complete line at this relay's one-envelope-per-send, test-scale
 * traffic; a stray partial chunk would surface as a loud JSON.parse
 * failure rather than a silent mis-parse. */
export async function readOneLine(
  reader: ReadableStreamDefaultReader<Uint8Array>
): Promise<Record<string, unknown>> {
  const { value, done } = await reader.read();
  if (done || !value) throw new Error("expected another stream line, got stream end");
  const line = new TextDecoder().decode(value).trim();
  return JSON.parse(line) as Record<string, unknown>;
}

export async function revoke(sessionId: string, token: string): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${sessionId}/revoke`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
}

/** Non-secret, low-entropy, obviously-descriptive label for opaque
 * ciphertext/nonce test fixtures — never a real key/token, just a
 * human-legible marker so a mis-routed frame is obvious in a failing
 * assertion. Deliberately not high-entropy/base64-blob-shaped so it can
 * never be mistaken for a real secret (hmdapp CLAUDE.md's "no secret-shaped
 * literals" rule). Pure function, no shared mutable state, so caller-passed
 * parts are the only source of uniqueness across seeds/steps. */
export function fixtureText(...parts: (string | number)[]): string {
  return parts.join("-");
}
