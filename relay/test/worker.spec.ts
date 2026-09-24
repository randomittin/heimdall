import { env, SELF, runInDurableObject } from "cloudflare:test";
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

/** Each test is logically a separate client, so each gets its own source IP.
 * `/pair/init` is throttled per `CF-Connecting-IP` (10/60s — src/pairing.ts's
 * PAIR_INIT_MAX_PER_WINDOW, added for the 2026-09-24 audit's finding 7), and
 * the pool sends no such header, so without this every suite would share the
 * one `"unknown"` bucket and start 429ing partway through the file. The
 * throttle's own coverage lives in test/hardening.spec.ts, where a fixed IP is
 * hammered deliberately. */
async function pairInit(): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, {
    method: "POST",
    headers: { "CF-Connecting-IP": crypto.randomUUID() },
  });
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

    const reconnectRes = await SELF.fetch(
      wsUrl(
        init.session_id,
        `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${TEST_DEVICE_PUBKEY}`
      ),
      { headers: { Upgrade: "websocket" } }
    );
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
  it("rejects a frame over 1 MiB with 413", async () => {
    const init = await pairInit();
    const oversized = makeEnvelope({
      session_id: init.session_id,
      ciphertext: "a".repeat(1_100_000),
    });
    const res = await postFrame(init.session_id, init.relay_session_token, oversized);
    expect(res.status).toBe(413);
  });

  it("accepts a frame over the old 128 KiB cap but under the new 1 MiB cap (INV-16 raised 2026-09-24 — real hmd state is ~136 KB)", async () => {
    const init = await pairInit();
    const envelope = makeEnvelope({
      session_id: init.session_id,
      ciphertext: "a".repeat(136_159),
    });
    const res = await postFrame(init.session_id, init.relay_session_token, envelope);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, delivered: false });
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

/**
 * A phone that loses Wi-Fi — or is force-stopped by Android — sends no close
 * frame and no TCP reset, so the relay keeps its socket for as long as
 * Cloudflare's own timeout takes: minutes. The phone reconnects with
 * `?device_token=` in seconds, so a session routinely holds more device
 * sockets than the one the app is actually on, and "which one is live" has to
 * be answered from the socket set itself.
 *
 * Two live failures shaped these tests, in order:
 *
 * 1. Delivery went to `getWebSockets(DEVICE_TAG)[0]`, the socket the dropped
 *    Wi-Fi session had left behind. Reproduced against the deployed relay on
 *    2026-09-24: the reconnected socket sat open and silent for 22s while
 *    every `state` frame went to the dead one, and `POST /frames` answered
 *    `delivered: true` for all of them, so neither end could see it.
 *
 * 2. The first fix closed *every* tagged socket on each accept, before the
 *    new one existed — so a second `/ws?device_token=` upgrade that was then
 *    discarded (an app retry, a relaunch racing two connects) closed the
 *    socket the app was actually using. Its TCP stayed up, so the app still
 *    showed `live` and still pushed `command` frames, while the relay's pool
 *    held no OPEN socket at all and answered `delivered: false` for every
 *    frame from then on — permanently, not intermittently. Reproduced against
 *    a local `wrangler dev` on 2026-09-24; the in-DO trace ended at
 *    `count=0 states=[]` while the phone leg was still connected.
 *
 * What both share: `readyState` alone cannot say which socket is the phone's.
 * The generation stamped into each socket's hibernation attachment can, and
 * unlike a field on the Durable Object it survives the instance being evicted
 * and rebuilt underneath a still-connected socket.
 */
describe("device socket supersede (reconnect after a network drop)", () => {
  async function claimAndReadToken(
    init: PairInitBody
  ): Promise<{ socket: WebSocket; deviceToken: string }> {
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const payload = bound.payload as { device_token: string };
    return { socket, deviceToken: payload.device_token };
  }

  /** Presents `device_pubkey` alongside the token, which is what the app now
   * puts on a reconnect URL: a `device_token` minted since the 2026-09-24
   * audit's finding 6 carries the claiming device's public key in its signed
   * claims, and the relay refuses the reconnect unless the same key comes
   * back. (Tokens minted before that change carry no such claim and still
   * reconnect without it — covered in test/hardening.spec.ts.) */
  async function reconnectDevice(sessionId: string, deviceToken: string): Promise<WebSocket> {
    const response = await SELF.fetch(
      wsUrl(
        sessionId,
        `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${TEST_DEVICE_PUBKEY}`
      ),
      { headers: { Upgrade: "websocket" } }
    );
    expect(response.status).toBe(101);
    const socket = response.webSocket;
    if (!socket) throw new Error("expected a websocket in the 101 response");
    socket.accept();
    return socket;
  }

  /** The generation stamped on each device socket still attached to the
   *  session, newest last — read the same way `SessionDO` reads it, straight
   *  off `getWebSockets` + `deserializeAttachment`. */
  async function deviceSocketGenerations(sessionId: string): Promise<number[]> {
    const stub = typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));
    return runInDurableObject(stub, (_instance, state: DurableObjectState) =>
      state
        .getWebSockets("device")
        .map((socket) => (socket.deserializeAttachment() as { gen: number } | null)?.gen ?? 0)
        .sort((a, b) => a - b)
    );
  }

  /**
   * Blocks until the session's device sockets are exactly `expected`.
   *
   * A client-initiated close has no client-visible completion here to await:
   * `SessionDO.webSocketClose` does not close its own half back, so the
   * closing handshake never finishes and the client's own `close` event never
   * fires. The Durable Object's socket set is the honest signal, and it is
   * what delivery reads anyway — so poll that, and fail loudly rather than
   * racing on a sleep.
   */
  async function waitForDeviceGenerations(sessionId: string, expected: number[]): Promise<void> {
    let seen: number[] = [];
    for (let attempt = 0; attempt < 200; attempt += 1) {
      seen = await deviceSocketGenerations(sessionId);
      if (seen.length === expected.length && seen.every((gen, i) => gen === expected[i])) return;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(
      `device sockets never settled to [${expected.join(",")}] — last saw [${seen.join(",")}]`
    );
  }

  it("closes a superseded device socket with 4002, not revoke's 4001", async () => {
    const init = await pairInit();
    const { socket: first, deviceToken } = await claimAndReadToken(init);

    const firstClosed = nextCloseCode(first);
    const second = await reconnectDevice(init.session_id, deviceToken);

    // The older socket is ended when a frame confirms which socket is live —
    // never on the bare accept, which is what used to close the socket the
    // app was on. 4001 would tell the app the session was revoked and to stop
    // reconnecting; this session is very much alive.
    const delivered = nextMessage(second);
    await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "picks-the-live-socket" })
    );
    await delivered;
    expect(await firstClosed).toBe(4002);
  });

  it("delivers a frame to the reconnected socket, never the superseded one", async () => {
    const init = await pairInit();
    // The older socket is still wide open when the frame is posted — exactly
    // the state a Wi-Fi drop leaves behind — so this pins that delivery ranks
    // by generation rather than settling for the first open socket it finds.
    const { socket: first, deviceToken } = await claimAndReadToken(init);
    const firstClosed = nextCloseCode(first);
    const second = await reconnectDevice(init.session_id, deviceToken);

    const delivered = nextMessage(second);
    const res = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "to-the-live-socket" })
    );
    expect(await res.json()).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("to-the-live-socket");
    expect(await firstClosed).toBe(4002);
  });

  it("delivers to the reconnect when the abandoned socket never closes", async () => {
    const init = await pairInit();
    // Never closed, never read from: an Android force-stop leaves the relay
    // holding a socket it still believes is OPEN. Nothing below waits for it
    // to go away, because in production it does not.
    const { socket: abandoned, deviceToken } = await claimAndReadToken(init);

    const reconnected = await reconnectDevice(init.session_id, deviceToken);

    const delivered = nextMessage(reconnected);
    const res = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "past-the-ghost" })
    );
    expect(await res.json()).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("past-the-ghost");
    expect(abandoned.readyState).not.toBe(WebSocket.OPEN);
  });

  it("delivers a frame posted immediately after the reconnect's 101", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimAndReadToken(init);

    // No pause, no waiting on the old socket's teardown: the very next thing
    // after the upgrade is hmd pushing a frame, which is exactly what a
    // digest change looks like when a phone reconnects mid-run.
    const reconnected = await reconnectDevice(init.session_id, deviceToken);
    const delivered = nextMessage(reconnected);
    const res = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "immediately-after-101" })
    );

    expect(await res.json()).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("immediately-after-101");
  });

  it("keeps delivering after a duplicate upgrade is opened and discarded", async () => {
    const init = await pairInit();
    // The live regression, in order: a ghost the app can no longer read, the
    // socket the app is actually on, and a duplicate upgrade the app throws
    // away. Closing every tagged socket on the duplicate's accept left the
    // session with no OPEN socket at all and `delivered: false` forever.
    const { deviceToken } = await claimAndReadToken(init);
    const kept = await reconnectDevice(init.session_id, deviceToken);

    const duplicate = await reconnectDevice(init.session_id, deviceToken);
    duplicate.close(1000, "discarded by the app");
    await waitForDeviceGenerations(init.session_id, [1, 2]);

    const delivered = nextMessage(kept);
    const res = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "still-reaches-the-phone" })
    );
    expect(await res.json()).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("still-reaches-the-phone");
  });

  it("stamps a strictly increasing generation on each accepted socket", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimAndReadToken(init);
    expect(await deviceSocketGenerations(init.session_id)).toEqual([1]);

    await reconnectDevice(init.session_id, deviceToken);
    expect(await deviceSocketGenerations(init.session_id)).toEqual([1, 2]);

    await reconnectDevice(init.session_id, deviceToken);
    // Every generation lives on the socket's own hibernation attachment, so
    // the ordering is still readable after the Durable Object has been
    // evicted and rebuilt under these sockets — which no field on the
    // instance would survive.
    expect(await deviceSocketGenerations(init.session_id)).toEqual([1, 2, 3]);
  });

  it("forwards a command from the reconnected socket to hmd's stream", async () => {
    const init = await pairInit();
    // The claimed socket is left open and never waited on: the phone leg has
    // to work from the moment the reconnect is accepted, not from whenever
    // Cloudflare gets round to reaping the one it replaced.
    const { deviceToken } = await claimAndReadToken(init);

    const streamRes = await openHmdStream(init.session_id, init.relay_session_token);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");
    await readDataFrame(reader); // the buffered device_bound control frame

    const second = await reconnectDevice(init.session_id, deviceToken);

    second.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          ciphertext: "command-from-the-reconnected-socket",
        })
      )
    );

    const forwarded = await readDataFrame(reader);
    expect(forwarded.ciphertext).toBe("command-from-the-reconnected-socket");
    expect(forwarded.sender).toBe("device");
  });

  it("survives an hmd stream reconnect interleaved with a device reconnect", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimAndReadToken(init);

    const firstStream = await openHmdStream(init.session_id, init.relay_session_token);
    const firstReader = firstStream.body?.getReader();
    if (!firstReader) throw new Error("expected a readable stream body");
    await readDataFrame(firstReader); // the buffered device_bound control frame

    // Both legs turn over, laptop first: hmd's stream is cut and reopened
    // while the phone is also swapping sockets.
    const secondStream = await openHmdStream(init.session_id, init.relay_session_token);
    const secondReader = secondStream.body?.getReader();
    if (!secondReader) throw new Error("expected a readable stream body");

    const reconnected = await reconnectDevice(init.session_id, deviceToken);

    const delivered = nextMessage(reconnected);
    const res = await postFrame(
      init.session_id,
      init.relay_session_token,
      makeEnvelope({ session_id: init.session_id, ciphertext: "both-legs-turned-over" })
    );
    expect(await res.json()).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("both-legs-turned-over");

    reconnected.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          ciphertext: "up-the-reopened-stream",
        })
      )
    );
    const forwarded = await readDataFrame(secondReader);
    expect(forwarded.ciphertext).toBe("up-the-reopened-stream");
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
  const maxLifetimeMs = Number(
    (env as unknown as { RELAY_STREAM_MAX_LIFETIME_MS?: string })
      .RELAY_STREAM_MAX_LIFETIME_MS ?? ""
  );

  it("is configured with a test-scale keepalive interval", () => {
    // Guards the two timing tests below: without the vitest.config.ts
    // binding they would silently wait on the 20s production default and
    // fail as a timeout, which reads like a broken keepalive rather than a
    // broken test setup.
    expect(Number.isFinite(keepaliveMs)).toBe(true);
    expect(keepaliveMs).toBeGreaterThan(0);
  });

  it("is configured with a test-scale stream lifetime", () => {
    // Same guard as the keepalive one above, for the same reason: without
    // the vitest.config.ts binding the two lifetime tests below would wait
    // on the 10-minute production default and fail as timeouts. The
    // lifetime must also stay well clear of the keepalive cadence, or a
    // stream would be cut before it ever carried one.
    expect(Number.isFinite(maxLifetimeMs)).toBe(true);
    expect(maxLifetimeMs).toBeGreaterThan(keepaliveMs * 2);
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

  // Observed live on 2026-09-25 against the deployed relay, and the reason a
  // stream needs a bound on its LIFE and not just on its silence.
  //
  // A deploy rolls the Durable Object to a new generation. Hibernatable
  // device sockets are re-delivered to that new generation — so `POST
  // /frames` keeps answering `delivered: true` and every operator-visible
  // signal reads healthy — but hmd's in-flight `GET /stream` response stays
  // pinned to the OLD generation, which keeps feeding it keepalives off its
  // own `setTimeout`. hmd's client watches for silence
  // (HMD_RELAY_STREAM_IDLE_S, 60s) and never sees any, so it never
  // reconnects; meanwhile the new generation — the one actually holding the
  // phone — has `hmdStreamController === null` and drops every inbound
  // `command` as `no_hmd_stream_connected`. Phone→hmd stays dead until
  // something cuts that orphaned response, and nothing outside its isolate
  // can reach it. So it has to end itself.
  it("closes an hmd stream once its bounded lifetime expires", async () => {
    const init = await pairInit();
    const streamRes = await openHmdStream(init.session_id, init.relay_session_token);
    expect(streamRes.status).toBe(200);
    const reader = streamRes.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");

    const TIMED_OUT = Symbol("timed-out");
    const deadline = Date.now() + maxLifetimeMs * 2;
    let closed = false;
    let keepalives = 0;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const result = await Promise.race([
        reader.read(),
        new Promise<typeof TIMED_OUT>((resolve) =>
          setTimeout(() => resolve(TIMED_OUT), remaining)
        ),
      ]);
      if (result === TIMED_OUT) break;
      if (result.done) {
        closed = true;
        break;
      }
      keepalives += new TextDecoder()
        .decode(result.value)
        .split("\n")
        .filter((line) => line.includes('"keepalive"')).length;
    }

    // Both halves matter. The stream was never silent — it carried
    // keepalives the entire time, which is exactly why hmd's idle guard
    // cannot be what detects this — and it ended anyway.
    expect(keepalives).toBeGreaterThan(0);
    expect(closed).toBe(true);
  }, 30_000);

  it("gives a reconnected hmd stream its own full lifetime", async () => {
    const init = await pairInit();
    const first = await openHmdStream(init.session_id, init.relay_session_token);
    const firstReader = first.body?.getReader();
    if (!firstReader) throw new Error("expected a readable stream body");

    // Hold the first stream most of the way through its life, then replace
    // it. A lifetime timer left armed by the superseded stream would fire
    // while the new one is live and cut hmd off early — trading the
    // orphaned-stream bug for a worse, self-inflicted one.
    await new Promise((resolve) => setTimeout(resolve, maxLifetimeMs * 0.6));
    await firstReader.cancel();

    const second = await openHmdStream(init.session_id, init.relay_session_token);
    expect(second.status).toBe(200);
    const secondReader = second.body?.getReader();
    if (!secondReader) throw new Error("expected a readable stream body");

    const TIMED_OUT = Symbol("timed-out");
    const result = await Promise.race([
      (async () => {
        for (;;) {
          const { done } = await secondReader.read();
          if (done) return "closed" as const;
        }
      })(),
      new Promise<typeof TIMED_OUT>((resolve) =>
        setTimeout(() => resolve(TIMED_OUT), maxLifetimeMs * 0.6)
      ),
    ]);

    // 0.6 + 0.6 lifetimes is past the FIRST stream's original deadline, so a
    // stale timer would have closed this one by now.
    expect(result).toBe(TIMED_OUT);

    await secondReader.cancel();
  }, 30_000);
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
