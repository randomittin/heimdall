// Hibernation suite — proves `SessionDO` is a Hibernation-API Durable Object
// and pins what keeps it from hibernating. Background and measurements live in
// docs/analysis/2026-10-05-relay-hibernation.md.
//
// "Hibernation" is simulated with `evictDurableObject` (cloudflare:test): the
// instance is torn down — every field on `this` is gone — while durable
// storage and hibernatable WebSockets are kept, which is exactly what the
// platform does to an idle object. Whatever a test observes afterwards was
// therefore recovered from storage or from a socket attachment, never from
// memory.
//
// Two harness facts every test below respects:
// - eviction "waits for in-flight requests to drain", and a response body that
//   was never read counts as one — so every Response is consumed before the
//   object is evicted;
// - a client-side `reader.cancel()` does not reach the Durable Object in this
//   runtime (the DO only lets go when its own deadline fires), so a test that
//   needs hmd's stream released uses a path the DO itself controls.

import { env, SELF, runInDurableObject, evictDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Env, Envelope } from "../src/types";
import type { SessionDO } from "../src/session";
import { base64UrlEncode } from "../src/pairing";
import { openHmdSocket } from "./hmd-socket";

const typedEnv = env as unknown as Env;

const BASE = "https://relay-hibernation.test";

/** Not a secret — deterministic 32-byte filler, the idiom the other specs use. */
const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));

interface PairInitBody {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

async function pairInit(): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, {
    method: "POST",
    headers: { "CF-Connecting-IP": crypto.randomUUID() },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

function sessionStub(sessionId: string): DurableObjectStub {
  return typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));
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

async function upgrade(sessionId: string, query: string): Promise<WebSocket> {
  const response = await SELF.fetch(`${BASE}/session/${sessionId}/ws?${query}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return socket;
}

/** Claims the pairing code; resolves with the open socket and the token the
 *  relay minted for reconnecting. */
async function claimDevice(
  init: PairInitBody
): Promise<{ socket: WebSocket; deviceToken: string }> {
  const socket = await upgrade(
    init.session_id,
    `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`
  );
  const bound = await nextMessage(socket);
  return { socket, deviceToken: (bound.payload as { device_token: string }).device_token };
}

function reconnectDevice(sessionId: string, deviceToken: string): Promise<WebSocket> {
  return upgrade(
    sessionId,
    `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${TEST_DEVICE_PUBKEY}`
  );
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

/** POSTs a frame and reads the whole response — see the harness note above. */
async function postFrame(init: PairInitBody, envelope: Envelope): Promise<unknown> {
  const res = await SELF.fetch(`${BASE}/session/${init.session_id}/frames`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${init.relay_session_token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(envelope),
  });
  expect(res.status).toBe(200);
  return res.json();
}

async function revoke(init: PairInitBody): Promise<void> {
  const res = await SELF.fetch(`${BASE}/session/${init.session_id}/revoke`, {
    method: "POST",
    headers: { Authorization: `Bearer ${init.relay_session_token}` },
  });
  expect(res.status).toBe(200);
  await res.text();
}

/** hmd's `GET /stream`, read frame by frame. A stream allows one pending read
 *  at a time, so a read that outlives a timed-out `next()` is kept and reused
 *  by the following call instead of being abandoned. */
class HmdStream {
  private pending: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;
  private queued: Record<string, unknown>[] = [];

  constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  /** The next non-`keepalive` frame, or null if none arrives within `withinMs`
   *  (or the stream ends) — so a frame that never comes fails as a plain
   *  assertion instead of hanging until the test timeout. */
  async next(withinMs = 3000): Promise<Record<string, unknown> | null> {
    const deadline = Date.now() + withinMs;
    for (;;) {
      const queued = this.queued.shift();
      if (queued) return queued;
      this.pending ??= this.reader.read();
      const chunk = await Promise.race([
        this.pending,
        new Promise<null>((resolve) =>
          setTimeout(() => resolve(null), Math.max(0, deadline - Date.now()))
        ),
      ]);
      if (chunk === null) return null;
      this.pending = null;
      if (chunk.done || !chunk.value) return null;
      for (const line of new TextDecoder().decode(chunk.value).split("\n")) {
        if (line.trim().length === 0) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        if (frame.type !== "keepalive") this.queued.push(frame);
      }
    }
  }

  /** Reads to the end of the stream, which is when the response is complete
   *  from the runtime's side. */
  async drain(): Promise<void> {
    for (;;) {
      this.pending ??= this.reader.read();
      const chunk = await this.pending;
      this.pending = null;
      if (chunk.done) return;
    }
  }
}

async function openHmdStream(init: PairInitBody): Promise<HmdStream> {
  const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
    headers: { Authorization: `Bearer ${init.relay_session_token}` },
  });
  expect(res.status).toBe(200);
  const reader = res.body?.getReader();
  if (!reader) throw new Error("expected a readable stream body");
  return new HmdStream(reader);
}

/** Resolves true if `eviction` settles within `withinMs`, false if the Durable
 *  Object is still held. */
async function settlesWithin(eviction: Promise<void>, withinMs: number): Promise<boolean> {
  return Promise.race([
    eviction.then(() => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), withinMs)),
  ]);
}

/** Evicts the session's Durable Object, failing with the reason instead of a
 *  bare test timeout if it will not go. Eviction waits for in-flight work, so a
 *  refusal means something — a timer, an open stream, an unread response — is
 *  keeping the object resident, which is exactly what this suite guards. */
async function evict(sessionId: string): Promise<void> {
  const evicted = await settlesWithin(evictDurableObject(sessionStub(sessionId)), 4000);
  if (!evicted) {
    throw new Error("the Durable Object could not be evicted: something is keeping it resident");
  }
}

function deviceSocketAttachments(sessionId: string): Promise<unknown[]> {
  return runInDurableObject(sessionStub(sessionId), (_instance, state: DurableObjectState) =>
    state.getWebSockets("device").map((socket) => socket.deserializeAttachment())
  );
}

describe("phone leg is a Hibernation-API socket", () => {
  it("accepts the device socket through ctx.acceptWebSocket, tagged 'device'", async () => {
    const init = await pairInit();
    const tagsSeen: (string[] | undefined)[] = [];
    await runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) => {
      const original = state.acceptWebSocket.bind(state);
      state.acceptWebSocket = (ws: WebSocket, tags?: string[]) => {
        tagsSeen.push(tags);
        original(ws, tags);
      };
    });

    await claimDevice(init);

    expect(tagsSeen).toEqual([["device"]]);
  });

  it("keeps the phone's socket open across an eviction and still delivers hmd's frames to it", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);

    await evict(init.session_id);

    expect(socket.readyState).toBe(WebSocket.OPEN);
    expect(await deviceSocketAttachments(init.session_id)).toHaveLength(1);

    const delivered = nextMessage(socket);
    expect(
      await postFrame(init, makeEnvelope({ session_id: init.session_id, ciphertext: "after-wake" }))
    ).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("after-wake");
  });

  it("delivers a phone command to hmd through webSocketMessage on the rebuilt instance", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    await evict(init.session_id);

    // hmd comes back after the phone's socket has been hibernated: the
    // instance serving this request is a new one, holding nothing the old one
    // knew.
    const stream = await openHmdStream(init);
    await stream.next(300); // the held device_bound, if there is one — pinned further down

    let handled = 0;
    await runInDurableObject(sessionStub(init.session_id), (instance) => {
      const target = instance as unknown as SessionDO;
      const original = target.webSocketMessage.bind(target);
      target.webSocketMessage = (ws, message) => {
        handled += 1;
        return original(ws, message);
      };
    });

    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          ciphertext: "command-after-wake",
        })
      )
    );

    const forwarded = await stream.next();
    expect(forwarded?.ciphertext).toBe("command-after-wake");
    expect(handled).toBe(1);
  });

  it("ranks sockets by the generation on their attachment after an eviction", async () => {
    const init = await pairInit();
    const { socket: first, deviceToken } = await claimDevice(init);
    const firstClosed = nextCloseCode(first);

    await evict(init.session_id);
    const second = await reconnectDevice(init.session_id, deviceToken);

    // The rebuilt instance numbered the newcomer from the hibernated socket's
    // attachment: one above it, not back at 1.
    expect(
      (await deviceSocketAttachments(init.session_id)).map((a) => (a as { gen: number }).gen).sort()
    ).toEqual([1, 2]);

    const delivered = nextMessage(second);
    expect(
      await postFrame(init, makeEnvelope({ session_id: init.session_id, ciphertext: "to-newest" }))
    ).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("to-newest");
    expect(await firstClosed).toBe(4002);
  });

  it("enforces the token expiry stored on the attachment after an eviction", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);

    await runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) => {
      const attached = state.getWebSockets("device")[0];
      if (!attached) throw new Error("expected an attached device socket");
      const current = attached.deserializeAttachment() as { gen: number };
      attached.serializeAttachment({ ...current, token_exp: Math.floor(Date.now() / 1000) - 1 });
    });
    await evict(init.session_id);

    // The instance that reads this frame never saw the socket being accepted:
    // `token_exp` can only have come back from the hibernated attachment.
    const closed = nextCloseCode(socket);
    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          ciphertext: "after-token-expiry",
        })
      )
    );
    expect(await closed).toBe(4003);
  });

  it("names the session in a pre-record rejection logged by a freshly woken instance", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    await evict(init.session_id);

    const logged: string[] = [];
    const originalLog = console.log;
    console.log = (...args: unknown[]) => {
      logged.push(args.map(String).join(" "));
    };
    try {
      // Over the 1 MiB cap, so it is rejected before the record is ever read:
      // the only place the session id can come from is the socket.
      socket.send("x".repeat(1_100_000));
      await new Promise((resolve) => setTimeout(resolve, 300));
    } finally {
      console.log = originalLog;
    }

    const rejected = logged
      .filter((line) => line.startsWith("{"))
      .map((line) => JSON.parse(line) as Record<string, unknown>)
      .find((entry) => entry.event === "frame_rejected");
    expect(rejected?.reason).toBe("envelope_exceeds_size_cap");
    expect(rejected?.session_id).toBe(init.session_id);
  });
});

describe("state that must outlive the instance is in storage, not memory", () => {
  it("still delivers device_bound to hmd's stream when the object was evicted between the claim and hmd connecting", async () => {
    const init = await pairInit();
    // The phone claims while hmd's stream is down, so the relay has to hold
    // hmd's `device_bound` until hmd connects...
    await claimDevice(init);
    // ...and the object is then evicted before that happens.
    await evict(init.session_id);

    const stream = await openHmdStream(init);
    const frame = await stream.next();

    expect(frame).not.toBeNull();
    expect(frame?.type).toBe("device_bound");
    expect((frame?.payload as { device_pubkey: string }).device_pubkey).toBe(TEST_DEVICE_PUBKEY);
  });

  it("hands the held device_bound to hmd once, not on every reconnect", async () => {
    const init = await pairInit();
    await claimDevice(init);

    const first = await openHmdStream(init);
    expect((await first.next())?.type).toBe("device_bound");

    // hmd's next stream supersedes the first (which the DO closes).
    const second = await openHmdStream(init);
    expect(await second.next(1500)).toBeNull();
  });
});

describe("nothing but hmd's stream keeps the Durable Object awake", () => {
  it("can be evicted straight after each kind of phone-leg request when no stream is open", async () => {
    const init = await pairInit();
    const { socket, deviceToken } = await claimDevice(init);
    const stub = sessionStub(init.session_id);

    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after the claim

    const delivered = nextMessage(socket);
    await postFrame(init, makeEnvelope({ session_id: init.session_id, ciphertext: "wake" }));
    await delivered;
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after hmd's POST

    await reconnectDevice(init.session_id, deviceToken);
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after a reconnect

    await revoke(init);
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after revoke
  });

  it("is held while hmd's stream is open, and freed by the stream's own deadline", async () => {
    const init = await pairInit();
    await claimDevice(init);
    const stream = await openHmdStream(init);
    expect((await stream.next())?.type).toBe("device_bound");

    // RELAY_STREAM_MAX_LIFETIME_MS is 8s under vitest (vitest.config.ts).
    const eviction = evictDurableObject(sessionStub(init.session_id));
    expect(await settlesWithin(eviction, 1500)).toBe(false);

    // Once the stream's deadline closes it — and the client has read it to
    // its end — nothing else, no timer and no controller, is left to hold the
    // object.
    await stream.drain();
    expect(await settlesWithin(eviction, 5000)).toBe(true);
  }, 30_000);

  it("is freed the moment revoke closes hmd's stream", async () => {
    const init = await pairInit();
    await claimDevice(init);
    const stream = await openHmdStream(init);
    expect((await stream.next())?.type).toBe("device_bound");

    await revoke(init);
    await stream.drain();

    expect(await settlesWithin(evictDurableObject(sessionStub(init.session_id)), 3000)).toBe(true);
  });
});

// hmd's second transport on the same route: `GET /stream` with
// `Upgrade: websocket`. Unlike the NDJSON response above, it holds nothing the
// object must stay resident for -- no response body, no timer -- which is the
// whole point of it (docs/analysis/2026-10-05-relay-hibernation.md, follow-up
// A). The tests below are the proof: every one of them evicts the object while
// an hmd socket is attached and watches what the rebuilt instance does.

function hmdSocketAttachments(sessionId: string): Promise<unknown[]> {
  return runInDurableObject(sessionStub(sessionId), (_instance, state: DurableObjectState) =>
    state.getWebSockets("hmd").map((socket) => socket.deserializeAttachment())
  );
}

function phoneCommand(sessionId: string, ciphertext: string): Envelope {
  return makeEnvelope({
    session_id: sessionId,
    sender: "device",
    type: "command",
    ciphertext,
  });
}

describe("hmd's WebSocket leg is a Hibernation-API socket", () => {
  it("accepts the hmd socket through ctx.acceptWebSocket, tagged 'hmd', with its generation and session on the attachment", async () => {
    const init = await pairInit();
    const tagsSeen: (string[] | undefined)[] = [];
    await runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) => {
      const original = state.acceptWebSocket.bind(state);
      state.acceptWebSocket = (ws: WebSocket, tags?: string[]) => {
        tagsSeen.push(tags);
        original(ws, tags);
      };
    });

    await openHmdSocket(BASE, init);

    expect(tagsSeen).toEqual([["hmd"]]);
    expect(await hmdSocketAttachments(init.session_id)).toEqual([{ gen: 1, sid: init.session_id }]);
  });

  it("can be evicted at once while an hmd WebSocket is open and idle", async () => {
    const init = await pairInit();
    await claimDevice(init);
    const hmd = await openHmdSocket(BASE, init);
    expect((await hmd.nextJson())?.type).toBe("device_bound");

    // Contrast: with hmd's NDJSON stream open the same eviction is refused until
    // the stream's own deadline ("is held while hmd's stream is open").
    expect(await settlesWithin(evictDurableObject(sessionStub(init.session_id)), 3000)).toBe(true);
    expect(hmd.socket.readyState).toBe(WebSocket.OPEN);
  });

  it("keeps hmd's socket open across an eviction and delivers a phone command to it through the rebuilt instance", async () => {
    const init = await pairInit();
    const { socket: phone } = await claimDevice(init);
    const hmd = await openHmdSocket(BASE, init);
    expect((await hmd.nextJson())?.type).toBe("device_bound");

    await evict(init.session_id);

    expect(hmd.socket.readyState).toBe(WebSocket.OPEN);
    expect(await hmdSocketAttachments(init.session_id)).toHaveLength(1);

    let handled = 0;
    await runInDurableObject(sessionStub(init.session_id), (instance) => {
      const target = instance as unknown as SessionDO;
      const original = target.webSocketMessage.bind(target);
      target.webSocketMessage = (ws, message) => {
        handled += 1;
        return original(ws, message);
      };
    });

    phone.send(JSON.stringify(phoneCommand(init.session_id, "command-after-wake")));

    expect((await hmd.nextJson())?.ciphertext).toBe("command-after-wake");
    expect(handled).toBe(1);
  });

  it("still carries hmd's POST /frames state to the phone after an eviction with hmd's socket attached", async () => {
    const init = await pairInit();
    const { socket: phone } = await claimDevice(init);
    const hmd = await openHmdSocket(BASE, init);
    expect((await hmd.nextJson())?.type).toBe("device_bound");

    await evict(init.session_id);

    const delivered = nextMessage(phone);
    expect(
      await postFrame(init, makeEnvelope({ session_id: init.session_id, ciphertext: "state-after-wake" }))
    ).toEqual({ ok: true, delivered: true });
    expect((await delivered).ciphertext).toBe("state-after-wake");
    expect(hmd.socket.readyState).toBe(WebSocket.OPEN);
  });

  it("answers hmd's ping after an eviction, without waking webSocketMessage", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    await evict(init.session_id);

    let handled = 0;
    await runInDurableObject(sessionStub(init.session_id), (instance) => {
      const target = instance as unknown as SessionDO;
      const original = target.webSocketMessage.bind(target);
      target.webSocketMessage = (ws, message) => {
        handled += 1;
        return original(ws, message);
      };
    });

    hmd.send("ping");

    expect(await hmd.next()).toBe("pong");
    expect(handled).toBe(0);
  });

  it("is freed once an hmd WebSocket replaces an NDJSON stream: none of the stream's timers is left", async () => {
    const init = await pairInit();
    const stream = await openHmdStream(init);

    const hmd = await openHmdSocket(BASE, init); // supersedes the stream, which the object ends
    await stream.drain();

    expect(await settlesWithin(evictDurableObject(sessionStub(init.session_id)), 3000)).toBe(true);
    expect(hmd.socket.readyState).toBe(WebSocket.OPEN);
  });

  it("can be evicted straight after each kind of request when an hmd WebSocket is open", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const stub = sessionStub(init.session_id);
    const { socket: phone, deviceToken } = await claimDevice(init);
    expect((await hmd.nextJson())?.type).toBe("device_bound");

    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after the claim

    phone.send(JSON.stringify(phoneCommand(init.session_id, "wake-for-hmd")));
    expect((await hmd.nextJson())?.ciphertext).toBe("wake-for-hmd");
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after a phone command reached hmd

    const delivered = nextMessage(phone);
    await postFrame(init, makeEnvelope({ session_id: init.session_id, ciphertext: "wake-for-phone" }));
    await delivered;
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after hmd's POST

    await reconnectDevice(init.session_id, deviceToken);
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after a reconnect

    await revoke(init);
    expect(await hmd.closed()).toEqual({ code: 4001, reason: "revoked" });
    expect(await settlesWithin(evictDurableObject(stub), 3000)).toBe(true); // after revoke
  });
});

describe("state that must outlive the instance, over hmd's WebSocket", () => {
  it("still delivers device_bound as the first message when the object was evicted between the claim and hmd connecting", async () => {
    const init = await pairInit();
    await claimDevice(init);
    await evict(init.session_id);

    const first = await openHmdSocket(BASE, init);
    const frame = await first.nextJson();

    expect(frame?.type).toBe("device_bound");
    expect((frame?.payload as { device_pubkey: string }).device_pubkey).toBe(TEST_DEVICE_PUBKEY);

    // Delivered exactly once: the next hmd socket is given nothing.
    const second = await openHmdSocket(BASE, init);
    expect(await second.next(1500)).toBeNull();
  });

  it("keeps the held device_bound for the next connection when sending it fails", async () => {
    const init = await pairInit();
    await claimDevice(init);
    // The first hmd socket's send throws, as it does on a socket whose peer has already gone.
    await runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) => {
      const original = state.acceptWebSocket.bind(state);
      state.acceptWebSocket = (ws: WebSocket, tags?: string[]) => {
        ws.send = () => {
          throw new Error("forced send failure");
        };
        state.acceptWebSocket = original;
        original(ws, tags);
      };
    });
    const held = () =>
      runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) =>
        state.storage.get<string>("pending_hmd_control_frame")
      );

    const failed = await openHmdSocket(BASE, init);
    expect(await failed.next(500)).toBeNull();
    expect(await held()).toBeDefined();

    const next = await openHmdSocket(BASE, init);
    expect((await next.nextJson())?.type).toBe("device_bound");
    expect(await held()).toBeUndefined();
  });

  it("ranks hmd sockets by the generation on their attachment after an eviction", async () => {
    const init = await pairInit();
    const older = await openHmdSocket(BASE, init);

    await evict(init.session_id);
    const newer = await openHmdSocket(BASE, init);

    // The rebuilt instance numbered the newcomer from the hibernated socket's
    // attachment: one above it, not back at 1. (The older socket may or may not
    // have finished closing by now, so only the highest generation is pinned.)
    expect(await older.closed()).toEqual({ code: 4002, reason: "superseded" });
    const generations = (await hmdSocketAttachments(init.session_id)).map(
      (attachment) => (attachment as { gen: number }).gen
    );
    expect(Math.max(...generations)).toBe(2);

    const { socket: phone } = await claimDevice(init);
    expect((await newer.nextJson())?.type).toBe("device_bound");
    phone.send(JSON.stringify(phoneCommand(init.session_id, "to-newest-after-wake")));
    expect((await newer.nextJson())?.ciphertext).toBe("to-newest-after-wake");
    expect(older.received).toEqual([]);
  });
});
