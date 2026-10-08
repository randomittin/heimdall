// The 2026-10-02 field bug: hmd's relay client opened `GET /stream` for a
// freshly minted session, no phone ever bound it, and the stream ended with a
// bare EOF that the client could only blame on "the relay's own stream-lifetime
// bound" — then its reconnect met `404` and the client gave up with
// `session_ended: stream-404`. Seen twice (14:23 and 18:12 IST). The client's
// own event log timestamps both: the stream closed 120.0 s and 120.1 s after
// `/pair/init`, i.e. `pair_exp` (60 s then) plus `PURGE_GRACE_MS` (60 s) — the
// storage-reclamation alarm — not early, and not inside the pairing window.
// The relay did what it was built to do. It just never said why. (The window is
// 360 s now, `PAIRING_CODE_TTL_S`, so the same purge lands 420 s after init.)
//
// What these tests pin:
// - inside the pairing window nothing ends an unclaimed session or touches
//   hmd's stream (the hypothesis the report started from; it is false, and
//   this keeps it false);
// - whenever the relay itself ends a session hmd is still holding a stream
//   for, hmd is told why (`session_ended` + `payload.reason`) before the
//   stream closes — INV-38;
// - no other session, and no throttle bucket, can end a session (the
//   restarted-`hmd app connect` context of both reports).
//
// Real clocks throughout: workerd's timers cannot be advanced from a test, so
// the pairing window is scaled down through the Durable Object's internal
// `pairing_ttl_s` parameter (the only place the TTL is a parameter —
// production never sets it) and the purge alarm is run on demand with
// `runDurableObjectAlarm`, which executes the same `alarm()` handler the
// scheduled alarm would.

import { env, SELF, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/types";
import { base64UrlEncode } from "../src/pairing";

const typedEnv = env as unknown as Env;

const BASE = "https://relay-expiry.test";

/** Not a secret — deterministic 32-byte filler (CLAUDE.md: "no secret-shaped
 * literals"), the same fixture idiom worker.spec.ts uses. */
const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));

/** A pairing code that is well-formed but is not any session's. */
const WRONG_PAIRING_CODE = "A".repeat(26);

interface PairInitBody {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

function sessionStub(sessionId: string): DurableObjectStub {
  return typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));
}

/** A real `POST /pair/init`. Each logical client gets its own source IP —
 * `/pair/init` is throttled per `CF-Connecting-IP`, and the pool sends none. */
async function pairInit(ip: string = crypto.randomUUID()): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, {
    method: "POST",
    headers: { "CF-Connecting-IP": ip },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

/** A session whose pairing window is `ttlS` seconds long, minted through the
 * Durable Object's internal init so the window is short enough to outwait. */
async function initShortLived(ttlS: number): Promise<PairInitBody> {
  const sessionId = crypto.randomUUID();
  const res = await sessionStub(sessionId).fetch("http://do-internal/init", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ session_id: sessionId, pairing_ttl_s: ttlS }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

function wsUrl(sessionId: string, query: string): string {
  return `${BASE}/session/${sessionId}/ws?${query}`;
}

function upgrade(sessionId: string, query: string): Promise<Response> {
  return SELF.fetch(wsUrl(sessionId, query), { headers: { Upgrade: "websocket" } });
}

function claimQuery(init: PairInitBody): string {
  return `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`;
}

async function openHmdStream(
  init: PairInitBody
): Promise<ReadableStreamDefaultReader<Uint8Array>> {
  const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
    headers: { Authorization: `Bearer ${init.relay_session_token}` },
  });
  expect(res.status).toBe(200);
  const reader = res.body?.getReader();
  if (!reader) throw new Error("expected a readable stream body");
  return reader;
}

/**
 * Everything hmd's stream carries until `withinMs` runs out — `keepalive`s set
 * aside, their cadence being wall-clock — and whether the relay ended the
 * response in that time. The pair is the field symptom itself: a stream that
 * "closed by relay" with nothing in it reads `{ frames: [], closed: true }`.
 *
 * Drain a given reader once: a read abandoned at the deadline stays queued on
 * the reader and would swallow the next chunk.
 */
async function drainStream(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  withinMs: number
): Promise<{ frames: Record<string, unknown>[]; closed: boolean }> {
  const deadline = Date.now() + withinMs;
  const frames: Record<string, unknown>[] = [];
  let buffered = "";
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return { frames, closed: false };
    const next = await Promise.race([
      reader.read(),
      sleep(remaining).then(() => "deadline" as const),
    ]);
    if (next === "deadline") return { frames, closed: false };
    if (next.done) return { frames, closed: true };
    buffered += new TextDecoder().decode(next.value);
    let newlineAt: number;
    while ((newlineAt = buffered.indexOf("\n")) !== -1) {
      const line = buffered.slice(0, newlineAt).trim();
      buffered = buffered.slice(newlineAt + 1);
      if (line.length === 0) continue;
      const frame = JSON.parse(line) as Record<string, unknown>;
      if (frame.type !== "keepalive") frames.push(frame);
    }
  }
}

/** The one frame INV-38 promises, spelled out by hand: relay-originated,
 * plaintext, `reason` naming why the session is over. */
function sessionEndedFrame(sessionId: string, reason: string): Record<string, unknown> {
  return {
    v: 1,
    session_id: sessionId,
    seq: 0,
    sender: "relay",
    type: "session_ended",
    nonce: null,
    ciphertext: null,
    payload: { reason },
  };
}

interface StoredRecord {
  status: string;
  device_token_exp?: number;
}

function storedRecord(sessionId: string): Promise<StoredRecord | undefined> {
  return runInDurableObject(sessionStub(sessionId), (_instance, state) =>
    state.storage.get<StoredRecord>("state")
  );
}

// A session code is registered against a session, and lives exactly as long as that session's
// pairing window. A laptop that keeps its code offered re-runs /pair/init and re-registers it
// every 5 minutes, so the window a real /pair/init grants has to outlast that: at 60 s the code
// was claimable for one minute in every five.
describe("the pairing window a real /pair/init grants", () => {
  it("is 360 s, so a client that re-registers every 5 minutes never has its code lapse first", async () => {
    const beforeS = Math.floor(Date.now() / 1000);
    const init = await pairInit();
    const afterS = Math.floor(Date.now() / 1000);

    expect(init.exp).toBeGreaterThanOrEqual(beforeS + 360);
    expect(init.exp).toBeLessThanOrEqual(afterS + 360);
  });

  it("is the relay's own to set: a pairing_ttl_s in the public request body is never read", async () => {
    const res = await SELF.fetch(`${BASE}/pair/init`, {
      method: "POST",
      headers: { "CF-Connecting-IP": crypto.randomUUID(), "content-type": "application/json" },
      body: JSON.stringify({ pairing_ttl_s: 86_400 }),
    });
    const afterS = Math.floor(Date.now() / 1000);

    expect(res.status).toBe(200);
    expect(((await res.json()) as PairInitBody).exp).toBeLessThanOrEqual(afterS + 360);
  });
});

describe("an unclaimed session inside its pairing window", () => {
  it("is not ended, announced or purged by an alarm that fires before the window closes", async () => {
    const init = await initShortLived(3);
    const reader = await openHmdStream(init);

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    // hmd's stream is still open and has been told nothing.
    expect(await drainStream(reader, 400)).toEqual({ frames: [], closed: false });
    expect((await storedRecord(init.session_id))?.status).toBe("pending");
    await reader.cancel();
  });
});

describe("an unclaimed session whose pairing window lapses (2026-10-02 field bug)", () => {
  it("tells hmd the pairing expired, then closes its stream", async () => {
    const init = await initShortLived(1);
    const reader = await openHmdStream(init);
    await sleep(1_200); // the 1 s window lapses with nobody having claimed

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    expect(await drainStream(reader, 3_000)).toEqual({
      frames: [sessionEndedFrame(init.session_id, "pairing-expired")],
      closed: true,
    });
  });

  it("tells hmd the pairing expired when a late claim is what finds the window lapsed", async () => {
    const init = await initShortLived(1);
    const reader = await openHmdStream(init);
    await sleep(1_200);

    const late = await upgrade(init.session_id, claimQuery(init));
    expect(late.status).toBe(410);

    expect(await drainStream(reader, 3_000)).toEqual({
      frames: [sessionEndedFrame(init.session_id, "pairing-expired")],
      closed: true,
    });
  });
});

describe("a session the claim throttle ends (INV-4)", () => {
  it("tells hmd the claim throttle ended it, then closes its stream", async () => {
    const init = await pairInit();
    const reader = await openHmdStream(init);

    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt++) {
      const res = await upgrade(
        init.session_id,
        `pairing_code=${WRONG_PAIRING_CODE}&device_pubkey=${TEST_DEVICE_PUBKEY}`
      );
      statuses.push(res.status);
    }
    expect(statuses).toEqual([...Array(10).fill(401), 429]);

    expect(await drainStream(reader, 3_000)).toEqual({
      frames: [sessionEndedFrame(init.session_id, "claim-throttled")],
      closed: true,
    });
  });
});

describe("a bound session whose device token has lapsed", () => {
  it("tells hmd the session expired when storage is purged, then closes its stream", async () => {
    const init = await pairInit();
    const reader = await openHmdStream(init);
    const claim = await upgrade(init.session_id, claimQuery(init));
    expect(claim.status).toBe(101);
    claim.webSocket?.accept();

    await runInDurableObject(sessionStub(init.session_id), async (_instance, state) => {
      const record = (await state.storage.get("state")) as StoredRecord;
      record.device_token_exp = Math.floor(Date.now() / 1000) - 1;
      await state.storage.put("state", record);
    });
    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    const { frames, closed } = await drainStream(reader, 3_000);
    // The first frame is the bind itself (hmd's own `device_bound`); what
    // matters is that the stream does not end on it.
    expect(frames.map((frame) => frame.type)).toEqual(["device_bound", "session_ended"]);
    expect(frames[1]).toEqual(sessionEndedFrame(init.session_id, "expired"));
    expect(closed).toBe(true);
  });
});

// Both reports had a previous `hmd app connect` killed (SIGTERM, whose handler
// POSTs /revoke for the OLD session id) and restarted at once, from the same
// laptop and so the same source IP. None of that can reach the new session.
describe("restarting `hmd app connect`", () => {
  it("leaves the new session's stream, record and claim path untouched by the old one's revoke and purge", async () => {
    const ip = crypto.randomUUID();
    const oldSession = await pairInit(ip);
    const oldReader = await openHmdStream(oldSession);

    const revoked = await SELF.fetch(`${BASE}/session/${oldSession.session_id}/revoke`, {
      method: "POST",
      headers: { Authorization: `Bearer ${oldSession.relay_session_token}` },
    });
    expect(revoked.status).toBe(200);
    const freshSession = await pairInit(ip);
    const freshReader = await openHmdStream(freshSession);
    expect(await runDurableObjectAlarm(sessionStub(oldSession.session_id))).toBe(true);

    expect(await drainStream(oldReader, 1_000)).toMatchObject({ closed: true });
    expect(await drainStream(freshReader, 500)).toEqual({ frames: [], closed: false });
    expect((await storedRecord(freshSession.session_id))?.status).toBe("pending");
    expect(await storedRecord(oldSession.session_id)).toBeUndefined();
    expect((await upgrade(freshSession.session_id, claimQuery(freshSession))).status).toBe(101);
    await freshReader.cancel();
  });
});

describe("the /pair/init throttle", () => {
  it("ends nothing of the caller's already-minted session when it starts refusing", async () => {
    const ip = crypto.randomUUID();
    const kept = await pairInit(ip);
    const reader = await openHmdStream(kept);

    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt++) {
      const res = await SELF.fetch(`${BASE}/pair/init`, {
        method: "POST",
        headers: { "CF-Connecting-IP": ip },
      });
      statuses.push(res.status);
    }
    expect(statuses).toContain(429);

    expect(await drainStream(reader, 500)).toEqual({ frames: [], closed: false });
    expect((await storedRecord(kept.session_id))?.status).toBe("pending");
    expect((await upgrade(kept.session_id, claimQuery(kept))).status).toBe(101);
    await reader.cancel();
  });
});
