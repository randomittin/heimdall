import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Env, Envelope } from "../src/types";
import { base64UrlEncode } from "../src/pairing";

// `cloudflare:test`'s `env` is typed against the ambient (unaugmented)
// `Cloudflare.Env`; this project's own `Env` (src/types.ts) is the real
// binding shape declared in wrangler.toml, so the cast below is a one-time,
// well-understood re-assertion rather than an `any`-shaped escape hatch.
const typedEnv = env as unknown as Env;

const BASE = "https://relay.test";

/** Not a secret — a deterministic 32-byte fixture (CLAUDE.md: "no
 * secret-shaped literals"; this is filler bytes, not a credential, same
 * pattern as RelayTransport.test.ts's generated test keypairs). */
const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));

interface PairInitBody {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

async function pairInit(): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, { method: "POST" });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

function wsUrl(sessionId: string, query: string): string {
  return `${BASE}/session/${sessionId}/ws?${query}`;
}

async function claimDevice(
  sessionId: string,
  pairingCode: string,
  devicePubkey: string = TEST_DEVICE_PUBKEY
): Promise<{ response: Response; socket: WebSocket }> {
  const response = await SELF.fetch(
    wsUrl(sessionId, `pairing_code=${pairingCode}&device_pubkey=${devicePubkey}`),
    { headers: { Upgrade: "websocket" } }
  );
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return { response, socket };
}

function nextMessage(socket: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    socket.addEventListener(
      "message",
      (event) => resolve(JSON.parse((event as unknown as { data: string }).data)),
      { once: true }
    );
  });
}

function nextCloseCode(socket: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    socket.addEventListener(
      "close",
      (event) => resolve((event as unknown as { code: number }).code),
      { once: true }
    );
  });
}

/** One NDJSON chunk off hmd's stream, parsed. Every write the Durable
 *  Object makes is a single enqueue of exactly one line, so a chunk is a
 *  frame — except when the runtime coalesces two, which `readDataFrame`
 *  below handles by splitting. */
async function readLine(
  reader: ReadableStreamDefaultReader<Uint8Array>
): Promise<Record<string, unknown>> {
  const { value } = await reader.read();
  if (!value) throw new Error("expected stream bytes");
  return JSON.parse(new TextDecoder().decode(value).trim());
}

/** Reads past any `keepalive` control frames to the next real frame — the
 *  keepalive cadence is wall-clock, so any test that holds a stream open
 *  across several awaits could otherwise see one interleaved. */
async function readDataFrame(
  reader: ReadableStreamDefaultReader<Uint8Array>
): Promise<Record<string, unknown>> {
  for (;;) {
    const { value } = await reader.read();
    if (!value) throw new Error("expected stream bytes");
    const lines = new TextDecoder()
      .decode(value)
      .split("\n")
      .filter((line) => line.trim().length > 0);
    for (const line of lines) {
      const frame = JSON.parse(line) as Record<string, unknown>;
      if (frame.type !== "keepalive") return frame;
    }
  }
}

function openHmdStream(sessionId: string, token: string): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${sessionId}/stream`, {
    headers: { Authorization: `Bearer ${token}` },
  });
}

function makeEnvelope(overrides: Partial<Envelope> & Pick<Envelope, "session_id">): Envelope {
  return {
    v: 1,
    seq: 1,
    sender: "hmd",
    type: "state",
    nonce: "test-nonce",
    ciphertext: "test-ciphertext",
    ...overrides,
  };
}

async function postFrame(
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

describe("pair/init -> claim -> bound", () => {
  it("mints a device_token as the first frame on the claimed websocket", async () => {
    const init = await pairInit();
    expect(init.session_id).toMatch(/^[0-9a-f-]{36}$/i);

    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const first = await nextMessage(socket);

    expect(first.type).toBe("device_bound");
    expect(first.sender).toBe("relay");
    const payload = first.payload as { device_token: string; exp: number };
    expect(typeof payload.device_token).toBe("string");
    expect(payload.device_token.length).toBeGreaterThan(0);
    expect(typeof payload.exp).toBe("number");
  });
});

describe("claim lifecycle errors", () => {
  it("a second claim after binding returns 410", async () => {
    const init = await pairInit();
    await claimDevice(init.session_id, init.pairing_code);

    const second = await SELF.fetch(wsUrl(init.session_id, `pairing_code=${init.pairing_code}`), {
      headers: { Upgrade: "websocket" },
    });
    expect(second.status).toBe(410);
  });

  it("an expired pairing code returns 410", async () => {
    const sessionId = crypto.randomUUID();
    const id = typedEnv.SESSION.idFromName(sessionId);
    const stub = typedEnv.SESSION.get(id);
    const initRes = await stub.fetch("http://do-internal/init", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session_id: sessionId, pairing_ttl_s: -1 }),
    });
    expect(initRes.status).toBe(200);
    const { pairing_code: pairingCode } = (await initRes.json()) as { pairing_code: string };

    const claimRes = await SELF.fetch(wsUrl(sessionId, `pairing_code=${pairingCode}`), {
      headers: { Upgrade: "websocket" },
    });
    expect(claimRes.status).toBe(410);
  });

  it("throttles after MAX_CLAIM_ATTEMPTS wrong attempts with 429 + Retry-After", async () => {
    const init = await pairInit();
    const responses: Response[] = [];
    for (let i = 0; i < 11; i++) {
      responses.push(
        await SELF.fetch(wsUrl(init.session_id, "pairing_code=WRONGCODEWRONGCODEWRONGCODE"), {
          headers: { Upgrade: "websocket" },
        })
      );
    }
    expect(responses.slice(0, 10).map((r) => r.status)).toEqual(Array(10).fill(401));
    const eleventh = responses[10];
    expect(eleventh?.status).toBe(429);
    expect(eleventh?.headers.get("Retry-After")).toBe("60");
  });
});

describe("device_pubkey reaches hmd's stream (relay/README.md 'Confirmed gaps' #2)", () => {
  it("delivers device_bound with the phone's pubkey to the hmd stream immediately when the stream is already open", async () => {
    const init = await pairInit();
    const streamRes = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(streamRes.status).toBe(200);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");

    await claimDevice(init.session_id, init.pairing_code);

    const { value } = await reader.read();
    if (!value) throw new Error("expected stream bytes");
    const received = JSON.parse(new TextDecoder().decode(value).trim());
    expect(received.type).toBe("device_bound");
    expect(received.sender).toBe("relay");
    expect(received.payload.device_pubkey).toBe(TEST_DEVICE_PUBKEY);
    expect(typeof received.payload.bound_at).toBe("number");
  });

  it("buffers device_bound for the hmd stream when the claim happens before the stream opens, and delivers it on connect", async () => {
    const init = await pairInit();
    await claimDevice(init.session_id, init.pairing_code);

    const streamRes = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(streamRes.status).toBe(200);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");

    const { value } = await reader.read();
    if (!value) throw new Error("expected stream bytes");
    const received = JSON.parse(new TextDecoder().decode(value).trim());
    expect(received.type).toBe("device_bound");
    expect(received.payload.device_pubkey).toBe(TEST_DEVICE_PUBKEY);
  });

  it("does not re-emit device_bound to the hmd stream on a device_token reconnect", async () => {
    const init = await pairInit();
    const streamRes = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");

    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const deviceToken = (bound.payload as { device_token: string }).device_token;

    await reader.read(); // consume the one device_bound the claim just delivered

    const reconnectRes = await SELF.fetch(wsUrl(init.session_id, `device_token=${deviceToken}`), {
      headers: { Upgrade: "websocket" },
    });
    expect(reconnectRes.status).toBe(101);

    let extra: unknown = "none";
    await Promise.race([
      reader.read().then((r) => {
        extra = r.value ? new TextDecoder().decode(r.value) : "none";
      }),
      new Promise((resolve) => setTimeout(resolve, 50)),
    ]);
    expect(extra).toBe("none");
  });

  it("rejects a pairing_code claim missing device_pubkey with 400", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(wsUrl(init.session_id, `pairing_code=${init.pairing_code}`), {
      headers: { Upgrade: "websocket" },
    });
    expect(res.status).toBe(400);
  });

  it("rejects a pairing_code claim with a wrong-length device_pubkey with 400", async () => {
    const init = await pairInit();
    const shortPubkey = base64UrlEncode(new Uint8Array(16).fill(1));
    const res = await SELF.fetch(
      wsUrl(init.session_id, `pairing_code=${init.pairing_code}&device_pubkey=${shortPubkey}`),
      { headers: { Upgrade: "websocket" } }
    );
    expect(res.status).toBe(400);
  });

  it("rejects a pairing_code claim with a non-base64 device_pubkey with 400 (not a crash)", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(
      wsUrl(init.session_id, `pairing_code=${init.pairing_code}&device_pubkey=not-valid-base64!!`),
      { headers: { Upgrade: "websocket" } }
    );
    expect(res.status).toBe(400);
  });
});

describe("stream (hmd leg) auth", () => {
  it("requires a bearer token", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`);
    expect(res.status).toBe(401);
  });

  it("rejects an incorrect bearer token", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: "Bearer not-the-real-token" },
    });
    expect(res.status).toBe(401);
  });
});

describe("websocket upgrade guards", () => {
  it("rejects a request missing the Upgrade header with 400", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(wsUrl(init.session_id, `pairing_code=${init.pairing_code}`));
    expect(res.status).toBe(400);
  });

  it("rejects an explicit non-wss scheme signal (X-Forwarded-Proto) with 400", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(wsUrl(init.session_id, `pairing_code=${init.pairing_code}`), {
      headers: { Upgrade: "websocket", "X-Forwarded-Proto": "http" },
    });
    expect(res.status).toBe(400);
  });

  it("rejects an explicit non-wss scheme signal (cf-visitor) with 400", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(wsUrl(init.session_id, `pairing_code=${init.pairing_code}`), {
      headers: { Upgrade: "websocket", "cf-visitor": JSON.stringify({ scheme: "http" }) },
    });
    expect(res.status).toBe(400);
  });
});

describe("frames", () => {
  it("rejects a frame over 128 KiB with 413", async () => {
    const init = await pairInit();
    const oversized = makeEnvelope({
      session_id: init.session_id,
      ciphertext: "a".repeat(140_000),
    });
    const res = await postFrame(init.session_id, init.relay_session_token, oversized);
    expect(res.status).toBe(413);
  });

  it("forwards ciphertext byte-identical hmd -> phone", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame

    const stateEnvelope = makeEnvelope({
      session_id: init.session_id,
      type: "state",
      ciphertext: "state-ciphertext-abc123",
      nonce: "state-nonce-abc123",
    });
    // Arm the listener before the action that triggers the frame: this local
    // (Miniflare) test runtime's mock WebSocket does not deliver a message
    // to a listener attached after the message was already sent.
    const nextFrame = nextMessage(socket);
    const framesRes = await postFrame(init.session_id, init.relay_session_token, stateEnvelope);
    expect(framesRes.status).toBe(200);
    expect(await framesRes.json()).toEqual({ ok: true, delivered: true });

    const received = await nextFrame;
    expect(received.ciphertext).toBe(stateEnvelope.ciphertext);
    expect(received.nonce).toBe(stateEnvelope.nonce);
    expect(received.type).toBe("state");
  });

  it("delivers an ack exactly once (1:1)", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame

    const ackEnvelope = makeEnvelope({
      session_id: init.session_id,
      type: "ack",
      seq: 2,
      ciphertext: "ack-ciphertext-xyz",
    });
    // Arm the listener before triggering the send — see the identical note
    // in the "byte-identical hmd -> phone" test above.
    const nextFrame = nextMessage(socket);
    const ackRes = await postFrame(init.session_id, init.relay_session_token, ackEnvelope);
    expect(ackRes.status).toBe(200);

    const received = await nextFrame;
    expect(received.type).toBe("ack");
    expect(received.ciphertext).toBe(ackEnvelope.ciphertext);

    // A second, immediate read must not resolve with a duplicate — assert
    // by racing against a short timer instead of a fixed message count.
    let extraMessage: unknown = "none";
    const race = await Promise.race([
      nextMessage(socket).then((m) => {
        extraMessage = m;
      }),
      new Promise((resolve) => setTimeout(resolve, 50)),
    ]);
    void race;
    expect(extraMessage).toBe("none");
  });

  it("reports delivered: false when no device is connected", async () => {
    const init = await pairInit();
    const envelope = makeEnvelope({ session_id: init.session_id });
    const res = await postFrame(init.session_id, init.relay_session_token, envelope);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, delivered: false });
  });

  it("forwards ciphertext byte-identical phone -> hmd stream", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame

    const streamRes = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(streamRes.status).toBe(200);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");
    // The claim above happened before this stream existed, so the
    // device_bound control frame it wrote for hmd (device_pubkey/bound_at)
    // was buffered and is flushed as this stream's first line — consume it
    // before looking for the phone's own forwarded command frame.
    await reader.read();

    const commandEnvelope = makeEnvelope({
      session_id: init.session_id,
      sender: "device",
      type: "command",
      ciphertext: "command-ciphertext-def456",
      nonce: "command-nonce-def456",
    });
    socket.send(JSON.stringify(commandEnvelope));

    const { value } = await reader.read();
    if (!value) throw new Error("expected stream bytes");
    const line = new TextDecoder().decode(value).trim();
    const received = JSON.parse(line);
    expect(received.ciphertext).toBe(commandEnvelope.ciphertext);
    expect(received.nonce).toBe(commandEnvelope.nonce);
    expect(received.sender).toBe("device");
  });
});

describe("revoke", () => {
  it("requires a bearer token", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/revoke`, { method: "POST" });
    expect(res.status).toBe(401);
  });

  it("closes the device websocket with 4001 and further claims return 410", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame
    const closeCodePromise = nextCloseCode(socket);

    const revokeRes = await SELF.fetch(`${BASE}/session/${init.session_id}/revoke`, {
      method: "POST",
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(revokeRes.status).toBe(200);
    expect(await revokeRes.json()).toEqual({ ok: true });

    expect(await closeCodePromise).toBe(4001);

    const claimAfterRevoke = await SELF.fetch(
      wsUrl(init.session_id, `pairing_code=${init.pairing_code}`),
      { headers: { Upgrade: "websocket" } }
    );
    expect(claimAfterRevoke.status).toBe(410);
  });
});

// Observed live on 2026-09-24 against https://hmd-relay.therishabh16.workers.dev:
// hmd's GET /stream opened at 08:33:53, the phone bound, state frames flowed,
// and at 08:38:54 — 5m01s later, with the stream idle in between — Cloudflare
// closed the response body. The three tests below pin the two halves of the
// fix: bytes keep flowing so an idle stream is never cut, and if it is cut
// anyway the session (and the phone's socket) outlive it.
describe("stream lifetime", () => {
  const keepaliveMs = Number(
    (env as unknown as { RELAY_KEEPALIVE_MS?: string }).RELAY_KEEPALIVE_MS ?? ""
  );

  it("is configured with a test-scale keepalive interval", () => {
    // Guards the two timing tests below: without the vitest.config.ts
    // binding they would silently wait on the 20s production default and
    // fail as a timeout, which reads like a broken keepalive rather than a
    // broken test setup.
    expect(Number.isFinite(keepaliveMs)).toBe(true);
    expect(keepaliveMs).toBeGreaterThan(0);
  });

  it("emits a keepalive control frame on an otherwise-idle hmd stream", async () => {
    const init = await pairInit();
    const streamRes = await openHmdStream(init.session_id, init.relay_session_token);
    expect(streamRes.status).toBe(200);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");

    // Nothing else is ever written to this stream: no device claimed, no
    // frame posted. The only line that can arrive is the keepalive.
    const frame = await readLine(reader);
    expect(frame.type).toBe("keepalive");
    expect(frame.sender).toBe("relay");
    expect(frame.session_id).toBe(init.session_id);
    expect(frame.nonce).toBeNull();
    expect(frame.ciphertext).toBeNull();
    expect(typeof (frame.payload as { ts: unknown }).ts).toBe("number");

    await reader.cancel();
  }, 15_000);

  it("keeps exactly one keepalive timer alive when hmd reconnects its stream", async () => {
    const init = await pairInit();
    const first = await openHmdStream(init.session_id, init.relay_session_token);
    const firstReader = first.body?.getReader();
    if (!firstReader) throw new Error("expected a readable stream body");
    await firstReader.cancel();

    const second = await openHmdStream(init.session_id, init.relay_session_token);
    const secondReader = second.body?.getReader();
    if (!secondReader) throw new Error("expected a readable stream body");

    // Over 2.6 intervals a single live timer writes 2 keepalives. A timer
    // left running by the first stream (the failure mode of a setInterval
    // captured in the stream's own start() closure) would double that.
    const deadline = Date.now() + keepaliveMs * 2.6;
    let keepalives = 0;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const chunk = await Promise.race([
        secondReader.read().then(({ value }) => (value ? new TextDecoder().decode(value) : null)),
        new Promise<null>((resolve) => setTimeout(() => resolve(null), remaining)),
      ]);
      if (chunk === null) break;
      keepalives += chunk.split("\n").filter((line) => line.trim().length > 0).length;
    }
    expect(keepalives).toBeGreaterThanOrEqual(2);
    expect(keepalives).toBeLessThanOrEqual(3);

    await secondReader.cancel();
  }, 20_000);

  it("keeps the session and the phone's websocket alive when hmd's stream drops", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame

    const first = await openHmdStream(init.session_id, init.relay_session_token);
    expect(first.status).toBe(200);
    const firstReader = first.body?.getReader();
    if (!firstReader) throw new Error("expected a readable stream body");
    await readDataFrame(firstReader); // the buffered device_bound

    let phoneCloseCode: number | null = null;
    socket.addEventListener("close", (event) => {
      phoneCloseCode = (event as unknown as { code: number }).code;
    });

    // hmd's leg goes away — the Cloudflare idle-close, or a laptop lid.
    await firstReader.cancel();

    // The session is still bound: hmd reopens its stream (same bearer, no
    // re-pair) and traffic resumes in both directions.
    const second = await openHmdStream(init.session_id, init.relay_session_token);
    expect(second.status).toBe(200);
    const secondReader = second.body?.getReader();
    if (!secondReader) throw new Error("expected a readable stream body");

    const nextFrame = nextMessage(socket);
    const framesRes = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "state-after-hmd-stream-drop" })
    );
    expect(framesRes.status).toBe(200);
    expect(await framesRes.json()).toEqual({ ok: true, delivered: true });
    expect((await nextFrame).ciphertext).toBe("state-after-hmd-stream-drop");

    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          seq: 2,
          ciphertext: "command-after-hmd-stream-drop",
        })
      )
    );
    const forwarded = await readDataFrame(secondReader);
    expect(forwarded.ciphertext).toBe("command-after-hmd-stream-drop");

    // No session_ended was pushed and the socket was never closed: only
    // POST /revoke ends a bound session.
    expect(phoneCloseCode).toBeNull();

    // And the pairing code stays spent rather than the session reverting
    // to claimable — status is still "bound", not "pending" or "ended".
    const reclaim = await SELF.fetch(
      wsUrl(init.session_id, `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`),
      { headers: { Upgrade: "websocket" } }
    );
    expect(reclaim.status).toBe(410);

    await secondReader.cancel();
  }, 15_000);

  it("still delivers a phone frame after a stale hmd stream, once hmd reconnects", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume the device_bound control frame

    const first = await openHmdStream(init.session_id, init.relay_session_token);
    const firstReader = first.body?.getReader();
    if (!firstReader) throw new Error("expected a readable stream body");
    await readDataFrame(firstReader); // the buffered device_bound
    await firstReader.cancel();

    // A phone frame sent while hmd is away is not delivered and not
    // buffered (relay/README.md's "no persisted frame buffering"), and
    // must not poison the next stream.
    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          seq: 3,
          ciphertext: "command-while-hmd-away",
        })
      )
    );

    const second = await openHmdStream(init.session_id, init.relay_session_token);
    const secondReader = second.body?.getReader();
    if (!secondReader) throw new Error("expected a readable stream body");

    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          seq: 4,
          ciphertext: "command-after-reconnect",
        })
      )
    );
    const forwarded = await readDataFrame(secondReader);
    expect(forwarded.ciphertext).toBe("command-after-reconnect");

    await secondReader.cancel();
  }, 15_000);
});

describe("session id validation", () => {
  it("rejects a non-UUID session id with 400 before reaching any Durable Object", async () => {
    const res = await SELF.fetch(`${BASE}/session/not-a-uuid/stream`);
    expect(res.status).toBe(400);
  });

  it("returns 404 for a well-formed but never-initialized session id", async () => {
    const res = await SELF.fetch(`${BASE}/session/${crypto.randomUUID()}/stream`, {
      headers: { Authorization: "Bearer whatever" },
    });
    expect(res.status).toBe(404);
  });

  it("rejects a subpath outside the public surface (e.g. the DO-internal /init) with 404", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/init`, { method: "POST" });
    expect(res.status).toBe(404);
    const res2 = await SELF.fetch(`${BASE}/session/${init.session_id}/not-a-real-subpath`);
    expect(res2.status).toBe(404);
  });
});
