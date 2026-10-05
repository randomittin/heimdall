// hmd's leg as a hibernatable WebSocket: `GET /session/:id/stream` WITH
// `Upgrade: websocket`, the second transport on the route whose original is the
// chunked NDJSON response (a request without the header still gets exactly
// that). The wire is fixed in relay/contract/wire.json (`stream_ws`, replayed
// by contract.spec.ts); this file pins the behaviours around it:
//
// - auth is the NDJSON path's, ahead of any upgrade;
// - every relay -> hmd message is ONE envelope, the NDJSON line without its
//   newline;
// - newest hmd leg wins across both transports (close 4002);
// - the text `ping` is answered `pong` by the runtime, never by the object;
// - no timer is ever armed for the WebSocket path (a pending timer would pin
//   the object and defeat the point -- hibernation.spec.ts proves the object
//   can then be evicted);
// - revoke and relay-ended sessions close the socket with 4001, the latter
//   after the INV-38 `session_ended` message;
// - what hmd may send on the socket, and how closes and errors are logged.
//
// Real clocks throughout, as in pairing-expiry.spec.ts: workerd's timers cannot
// be advanced from a test.

import { runDurableObjectAlarm, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Envelope } from "../src/types";
import type { SessionDO } from "../src/session";
import { HmdSocket, openHmdSocket, requestHmdSocket, sleep, waitFor, withRelayLog } from "./hmd-socket";
import {
  BASE,
  TEST_DEVICE_PUBKEY,
  claimDevice,
  makeEnvelope,
  nextMessage,
  pairInit,
  revoke,
  typedEnv,
  wsUpgrade,
} from "./trace/helpers";
import type { PairInitBody } from "./trace/helpers";

function sessionStub(sessionId: string): DurableObjectStub {
  return typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));
}

/** The phone claims the pairing code: its open socket and the token it reconnects with. */
async function bindPhone(init: PairInitBody): Promise<{ phone: WebSocket; deviceToken: string }> {
  const { socket } = await claimDevice(init.session_id, init.pairing_code);
  const bound = await nextMessage(socket);
  return { phone: socket, deviceToken: (bound.payload as { device_token: string }).device_token };
}

/** One phone `command`, as it travels on the wire. */
function phoneCommand(init: PairInitBody, ciphertext: string): Envelope {
  return makeEnvelope({
    session_id: init.session_id,
    sender: "device",
    type: "command",
    nonce: "test-nonce",
    ciphertext,
  });
}

/** A session whose pairing window is `ttlS` seconds long, minted through the
 *  Durable Object's internal init so the window is short enough to outwait
 *  (the same sanctioned route pairing-expiry.spec.ts uses). */
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

/** The one frame INV-38 promises, spelled out by hand, key order and all: what
 *  the relay writes down NDJSON as a line, and sends here as a whole message. */
function sessionEndedMessage(sessionId: string, reason: string): string {
  return JSON.stringify({
    v: 1,
    session_id: sessionId,
    seq: 0,
    sender: "relay",
    type: "session_ended",
    nonce: null,
    ciphertext: null,
    payload: { reason },
  });
}

/** hmd's legacy NDJSON stream, read frame by frame with keepalives set aside
 *  (their cadence is wall-clock). A read that outlives a timed-out call is
 *  kept for the next one: a stream allows one pending read. */
class NdjsonStream {
  private pending: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;
  private readonly queued: Record<string, unknown>[] = [];
  private finished = false;

  constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  private async fill(deadline: number): Promise<"data" | "timeout"> {
    this.pending ??= this.reader.read();
    const chunk = await Promise.race([
      this.pending,
      sleep(Math.max(0, deadline - Date.now())).then(() => null),
    ]);
    if (chunk === null) return "timeout";
    this.pending = null;
    if (chunk.done || !chunk.value) {
      this.finished = true;
      return "data";
    }
    for (const line of new TextDecoder().decode(chunk.value).split("\n")) {
      if (line.trim().length === 0) continue;
      const frame = JSON.parse(line) as Record<string, unknown>;
      if (frame.type !== "keepalive") this.queued.push(frame);
    }
    return "data";
  }

  async next(withinMs = 3000): Promise<Record<string, unknown> | null> {
    const deadline = Date.now() + withinMs;
    for (;;) {
      const queued = this.queued.shift();
      if (queued) return queued;
      if (this.finished) return null;
      if ((await this.fill(deadline)) === "timeout") return null;
    }
  }

  /** True once the relay has ended the response. */
  async ended(withinMs = 3000): Promise<boolean> {
    const deadline = Date.now() + withinMs;
    while (!this.finished) {
      if ((await this.fill(deadline)) === "timeout") return false;
    }
    return true;
  }
}

async function openNdjson(init: PairInitBody): Promise<NdjsonStream> {
  const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
    headers: { Authorization: `Bearer ${init.relay_session_token}` },
  });
  expect(res.status).toBe(200);
  const reader = res.body?.getReader();
  if (!reader) throw new Error("expected a readable stream body");
  return new NdjsonStream(reader);
}

/** Replaces the live instance's `webSocketMessage` with a counting wrapper. */
function countWebSocketMessages(sessionId: string): Promise<{ calls: () => number }> {
  let calls = 0;
  return runInDurableObject(sessionStub(sessionId), (instance) => {
    const target = instance as unknown as SessionDO;
    const original = target.webSocketMessage.bind(target);
    target.webSocketMessage = (ws, message) => {
      calls += 1;
      return original(ws, message);
    };
    return { calls: () => calls };
  });
}

/** An hmd socket accepted by hand with a generation below any real one: what a
 *  supersede `close()` that failed would leave behind -- older than the live
 *  socket, and still open. */
async function acceptStaleHmdSocket(init: PairInitBody): Promise<HmdSocket> {
  let client!: WebSocket;
  await runInDurableObject(sessionStub(init.session_id), (_instance, state: DurableObjectState) => {
    const pair = new WebSocketPair();
    state.acceptWebSocket(pair[1], ["hmd"]);
    pair[1].serializeAttachment({ gen: 0, sid: init.session_id });
    client = pair[0];
  });
  client.accept();
  return new HmdSocket(client);
}

describe("hmd's WebSocket leg: negotiation and auth", () => {
  it("answers 101 to a bearer-authenticated Upgrade request on the stream route", async () => {
    const init = await pairInit();

    const response = await requestHmdSocket(BASE, init.session_id, {
      Authorization: `Bearer ${init.relay_session_token}`,
    });

    expect(response.status).toBe(101);
    expect(response.webSocket).not.toBeNull();
    response.webSocket?.accept();
  });

  it("refuses an Upgrade request without a bearer: 401 JSON, no upgrade", async () => {
    const init = await pairInit();

    const response = await requestHmdSocket(BASE, init.session_id, {});

    expect(response.status).toBe(401);
    expect(response.webSocket).toBeNull();
    expect(await response.json()).toEqual({ error: "missing or invalid bearer token" });
  });

  it("refuses an Upgrade request with a wrong bearer: 401 JSON, no upgrade", async () => {
    const init = await pairInit();

    const response = await requestHmdSocket(BASE, init.session_id, {
      Authorization: "Bearer not-this-session's-token",
    });

    expect(response.status).toBe(401);
    expect(response.webSocket).toBeNull();
    expect(await response.json()).toEqual({ error: "missing or invalid bearer token" });
  });

  it("answers 404 JSON to an Upgrade request for a session that was never initialised", async () => {
    const response = await requestHmdSocket(BASE, crypto.randomUUID(), {
      Authorization: "Bearer whatever",
    });

    expect(response.status).toBe(404);
    expect(response.webSocket).toBeNull();
    expect(await response.json()).toEqual({ error: "session not found" });
  });

  it("makes no plaintext-scheme check on this leg: the credential is a header, as on NDJSON", async () => {
    const init = await pairInit();

    const response = await requestHmdSocket(BASE, init.session_id, {
      Authorization: `Bearer ${init.relay_session_token}`,
      "X-Forwarded-Proto": "http",
      "cf-visitor": JSON.stringify({ scheme: "http" }),
    });

    expect(response.status).toBe(101);
    response.webSocket?.accept();
  });

  it("still serves the chunked NDJSON stream to the same request without an Upgrade header", async () => {
    const init = await pairInit();

    const response = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });

    expect(response.status).toBe(200);
    expect(response.webSocket).toBeNull();
    expect(response.headers.get("content-type")).toBe("application/x-ndjson");
    await response.body?.cancel();
  });

  it("logs hmd_stream_open per transport, naming it and never a credential", async () => {
    const init = await pairInit();

    const log = await withRelayLog(async () => {
      await openHmdSocket(BASE, init);
      await openNdjson(init);
    });

    expect(log.events("hmd_stream_open")).toEqual([
      { event: "hmd_stream_open", session_id: init.session_id, transport: "ws" },
      { event: "hmd_stream_open", session_id: init.session_id, transport: "ndjson" },
    ]);
    const opened = log.lines.filter((line) => line.includes("hmd_stream_open")).join("\n");
    expect(opened).not.toContain(init.relay_session_token);
    expect(opened).not.toContain("http");
  });
});

describe("hmd's WebSocket leg: what the relay sends hmd", () => {
  it("gives hmd the phone's device_bound live, as one plaintext message with no newline", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    await bindPhone(init);

    const raw = await hmd.next();
    expect(raw).not.toBeNull();
    expect((raw as string).endsWith("\n")).toBe(false);
    expect(JSON.parse(raw as string)).toEqual({
      v: 1,
      session_id: init.session_id,
      seq: 0,
      sender: "relay",
      type: "device_bound",
      nonce: null,
      ciphertext: null,
      payload: { device_pubkey: TEST_DEVICE_PUBKEY, bound_at: expect.any(Number) },
    });
  });

  it("forwards a phone command as the NDJSON line without its newline, byte for byte", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init);
    await hmd.next(); // the device_bound

    const command = phoneCommand(init, "command-over-ws");
    phone.send(JSON.stringify(command));

    expect(await hmd.next()).toBe(JSON.stringify(command));
  });

  it("flushes the held device_bound as the first message on connect, once, and then lets it go", async () => {
    const init = await pairInit();
    await bindPhone(init); // hmd is away: the relay holds hmd's device_bound
    const held = await runInDurableObject(sessionStub(init.session_id), (_instance, state) =>
      state.storage.get<string>("pending_hmd_control_frame")
    );
    // Held exactly as the NDJSON stream writes it, line terminator included.
    expect(held?.endsWith("\n")).toBe(true);

    const first = await openHmdSocket(BASE, init);
    expect(await first.next()).toBe((held as string).slice(0, -1));

    const second = await openHmdSocket(BASE, init);
    expect(await second.next(1000)).toBeNull();
    expect(
      await runInDurableObject(sessionStub(init.session_id), (_instance, state) =>
        state.storage.get("pending_hmd_control_frame")
      )
    ).toBeUndefined();
  });

  it("sends a held frame written by the previous code, newline and all, without the newline", async () => {
    const init = await pairInit();
    const line =
      JSON.stringify({
        v: 1,
        session_id: init.session_id,
        seq: 0,
        sender: "relay",
        type: "device_bound",
        nonce: null,
        ciphertext: null,
        payload: { device_pubkey: TEST_DEVICE_PUBKEY, bound_at: 1790000000 },
      }) + "\n";
    await runInDurableObject(sessionStub(init.session_id), (_instance, state) =>
      state.storage.put("pending_hmd_control_frame", line)
    );

    const hmd = await openHmdSocket(BASE, init);

    expect(await hmd.next()).toBe(line.slice(0, -1));
  });

  it("reports a phone command as undelivered once hmd's socket has closed", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init);
    await hmd.next();

    const log = await withRelayLog(async (captured) => {
      hmd.socket.close(1000, "done");
      expect(await waitFor(() => captured.events("hmd_socket_closed").length === 1)).toBe(true);
      phone.send(JSON.stringify(phoneCommand(init, "to-nobody")));
      expect(await waitFor(() => captured.events("frame_undelivered").length === 1)).toBe(true);
    });

    expect(log.events("frame_undelivered")).toEqual([
      { event: "frame_undelivered", session_id: init.session_id, reason: "no_hmd_stream_connected" },
    ]);
  });
});

describe("newest hmd leg wins, across both transports", () => {
  it("closes the older hmd WebSocket with 4002 'superseded' and delivers to the newer", async () => {
    const init = await pairInit();
    const older = await openHmdSocket(BASE, init);
    const newer = await openHmdSocket(BASE, init);

    expect(await older.closed()).toEqual({ code: 4002, reason: "superseded" });

    await bindPhone(init);
    expect((await newer.nextJson())?.type).toBe("device_bound");
    expect(older.received).toEqual([]);
  });

  it("ends an hmd WebSocket with 4002 when an NDJSON stream opens, and delivers to the stream", async () => {
    const init = await pairInit();
    const socket = await openHmdSocket(BASE, init);
    const stream = await openNdjson(init);

    expect(await socket.closed()).toEqual({ code: 4002, reason: "superseded" });

    const { phone } = await bindPhone(init);
    expect((await stream.next())?.type).toBe("device_bound");
    const command = phoneCommand(init, "to-the-stream");
    phone.send(JSON.stringify(command));
    expect(await stream.next()).toEqual(command);
    expect(socket.received).toEqual([]);
  });

  it("ends an NDJSON stream when an hmd WebSocket opens, and delivers to the socket", async () => {
    const init = await pairInit();
    const stream = await openNdjson(init);
    const socket = await openHmdSocket(BASE, init);

    expect(await stream.ended()).toBe(true);

    const { phone } = await bindPhone(init);
    expect((await socket.nextJson())?.type).toBe("device_bound");
    const command = phoneCommand(init, "to-the-socket");
    phone.send(JSON.stringify(command));
    expect(await socket.next()).toBe(JSON.stringify(command));
  });

  it("never delivers to an older hmd socket that is still open", async () => {
    const init = await pairInit();
    const live = await openHmdSocket(BASE, init);
    const stale = await acceptStaleHmdSocket(init);

    const { phone } = await bindPhone(init);
    expect((await live.nextJson())?.type).toBe("device_bound");
    const command = phoneCommand(init, "to-the-newest");
    phone.send(JSON.stringify(command));

    expect(await live.next()).toBe(JSON.stringify(command));
    expect(stale.received).toEqual([]);
  });
});

describe("hmd's liveness probe", () => {
  it("answers the text 'ping' with 'pong' from the runtime, never from webSocketMessage", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const spy = await countWebSocketMessages(init.session_id);

    hmd.send("ping");

    expect(await hmd.next()).toBe("pong");
    expect(spy.calls()).toBe(0);
    expect(hmd.socket.readyState).toBe(WebSocket.OPEN);
    // The runtime's own record that it, not the object, answered.
    const stamps = await runInDurableObject(sessionStub(init.session_id), (_instance, state) =>
      state.getWebSockets("hmd").map((ws) => state.getWebSocketAutoResponseTimestamp(ws))
    );
    expect(stamps).toHaveLength(1);
    expect(stamps[0]).toBeInstanceOf(Date);
  });
});

describe("no timer runs for the WebSocket path", () => {
  it("sends nothing and closes nothing across the keepalive interval and the stream lifetime", async () => {
    // vitest.config.ts: keepalive 1 s, stream lifetime 8 s -- both far inside the wait below.
    expect(typedEnv.RELAY_KEEPALIVE_MS).toBe("1000");
    expect(typedEnv.RELAY_STREAM_MAX_LIFETIME_MS).toBe("8000");
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    expect(await hmd.next(9_500)).toBeNull();
    expect(hmd.received).toEqual([]);
    expect(await hmd.closed(0)).toBeNull();

    // Still a working leg after both would have fired.
    const { phone } = await bindPhone(init);
    expect((await hmd.nextJson())?.type).toBe("device_bound");
    const command = phoneCommand(init, "after-the-wait");
    phone.send(JSON.stringify(command));
    expect(await hmd.next()).toBe(JSON.stringify(command));
  }, 30_000);
});

describe("revoke and relay-ended sessions over the WebSocket", () => {
  it("revoke closes hmd's socket with 4001 'revoked' and writes it nothing first", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    const res = await revoke(init.session_id, init.relay_session_token);
    expect(res.status).toBe(200);

    expect(await hmd.closed()).toEqual({ code: 4001, reason: "revoked" });
    expect(hmd.received).toEqual([]);
  });

  it("tells hmd the pairing expired, then closes its socket with 4001", async () => {
    const init = await initShortLived(1);
    const hmd = await openHmdSocket(BASE, init);
    await sleep(1_200); // the 1 s window lapses with nobody having claimed

    const log = await withRelayLog(async () => {
      expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);
      expect(await hmd.closed()).toEqual({ code: 4001, reason: "session ended" });
    });

    expect(hmd.received).toEqual([sessionEndedMessage(init.session_id, "pairing-expired")]);
    expect(log.events("session_end_announced")).toEqual([
      {
        event: "session_end_announced",
        session_id: init.session_id,
        reason: "pairing-expired",
        delivered: true,
      },
    ]);
  }, 15_000);

  it("tells hmd the pairing expired when a late claim is what finds the window lapsed", async () => {
    const init = await initShortLived(1);
    const hmd = await openHmdSocket(BASE, init);
    await sleep(1_200);

    const late = await wsUpgrade(
      init.session_id,
      `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`
    );
    expect(late.status).toBe(410);

    expect(await hmd.closed()).toEqual({ code: 4001, reason: "session ended" });
    expect(hmd.received).toEqual([sessionEndedMessage(init.session_id, "pairing-expired")]);
  }, 15_000);

  it("tells hmd the claim throttle ended the session, then closes its socket with 4001", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt++) {
      const res = await wsUpgrade(
        init.session_id,
        `pairing_code=${"A".repeat(26)}&device_pubkey=${TEST_DEVICE_PUBKEY}`
      );
      statuses.push(res.status);
    }
    expect(statuses).toEqual([...Array(10).fill(401), 429]);

    expect(await hmd.closed()).toEqual({ code: 4001, reason: "session ended" });
    expect(hmd.received).toEqual([sessionEndedMessage(init.session_id, "claim-throttled")]);
  });

  it("tells hmd a bound session expired when its storage is purged, after the bind itself", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    await bindPhone(init);
    await runInDurableObject(sessionStub(init.session_id), async (_instance, state) => {
      const record = (await state.storage.get("state")) as { device_token_exp: number };
      record.device_token_exp = Math.floor(Date.now() / 1000) - 1;
      await state.storage.put("state", record);
    });

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    expect(await hmd.closed()).toEqual({ code: 4001, reason: "session ended" });
    expect(hmd.received.map((message) => (JSON.parse(message) as { type: string }).type)).toEqual([
      "device_bound",
      "session_ended",
    ]);
    expect(hmd.received[1]).toBe(sessionEndedMessage(init.session_id, "expired"));
  });

  it("logs nothing about announcing an end when no hmd leg is attached", async () => {
    const init = await initShortLived(1);
    await sleep(1_200);

    const log = await withRelayLog(async () => {
      expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);
    });

    expect(log.events("session_purged")).toHaveLength(1);
    expect(log.events("session_end_announced")).toEqual([]);
  }, 15_000);
});

describe("what hmd may send on its socket", () => {
  it("closes the socket with 1009 on a message over the size cap, and logs why", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    const log = await withRelayLog(async () => {
      hmd.send("x".repeat(1_100_000));
      expect(await hmd.closed()).toMatchObject({ code: 1009 });
    });

    expect(log.events("frame_rejected")).toEqual([
      {
        event: "frame_rejected",
        session_id: init.session_id,
        leg: "hmd",
        reason: "envelope_exceeds_size_cap",
      },
    ]);
  });

  it("ignores any other text message, logging it as unsupported, and stays open", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init);
    await hmd.next();
    const toPhone: unknown[] = [];
    phone.addEventListener("message", (event) => toPhone.push((event as unknown as { data: unknown }).data));

    const log = await withRelayLog(async (captured) => {
      // A well-formed hmd frame: in this phase hmd POSTs those over HTTP.
      hmd.send(JSON.stringify(makeEnvelope({ session_id: init.session_id, ciphertext: "state-over-ws" })));
      expect(await waitFor(() => captured.events("frame_rejected").length === 1)).toBe(true);
    });

    expect(log.events("frame_rejected")).toEqual([
      {
        event: "frame_rejected",
        session_id: init.session_id,
        leg: "hmd",
        reason: "ws_message_unsupported",
      },
    ]);
    expect(toPhone).toEqual([]);
    hmd.send("ping");
    expect(await hmd.next()).toBe("pong");
    expect(await hmd.closed(0)).toBeNull();
  });

  it("ignores a binary message without a word, and stays open", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    const log = await withRelayLog(async () => {
      hmd.send(new Uint8Array([1, 2, 3]).buffer);
      hmd.send("ping"); // answered by the runtime, so a pong proves the socket is alive...
      expect(await hmd.next()).toBe("pong");
      await sleep(300); // ...and this is room for the ignored message to be (not) logged.
    });

    expect(log.events("frame_rejected")).toEqual([]);
    expect(await hmd.closed(0)).toBeNull();
  });
});

describe("closes and errors are logged by the leg they happened on", () => {
  it("logs hmd_socket_closed, and not device_socket_closed, when hmd closes its socket", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);

    const log = await withRelayLog(async (captured) => {
      hmd.socket.close(1000, "done");
      expect(await waitFor(() => captured.events("hmd_socket_closed").length === 1)).toBe(true);
    });

    expect(log.events("hmd_socket_closed")).toEqual([
      { event: "hmd_socket_closed", session_id: init.session_id, code: 1000, wasClean: true },
    ]);
    expect(log.events("device_socket_closed")).toEqual([]);
  });

  it("keeps logging device_socket_closed, and not hmd_socket_closed, for the phone's socket", async () => {
    const init = await pairInit();
    const { phone } = await bindPhone(init);

    const log = await withRelayLog(async (captured) => {
      phone.close(1000, "done");
      expect(await waitFor(() => captured.events("device_socket_closed").length === 1)).toBe(true);
    });

    expect(log.events("device_socket_closed")).toEqual([
      { event: "device_socket_closed", session_id: init.session_id, code: 1000, wasClean: true },
    ]);
    expect(log.events("hmd_socket_closed")).toEqual([]);
  });

  it("names the leg in a socket error too", async () => {
    const init = await pairInit();
    await openHmdSocket(BASE, init);
    await bindPhone(init);

    const log = await withRelayLog(async () => {
      await runInDurableObject(sessionStub(init.session_id), async (instance, state) => {
        const target = instance as unknown as SessionDO;
        const hmdSocket = state.getWebSockets("hmd")[0];
        const deviceSocket = state.getWebSockets("device")[0];
        if (!hmdSocket || !deviceSocket) throw new Error("expected one socket on each leg");
        await target.webSocketError(hmdSocket, new Error("boom"));
        await target.webSocketError(deviceSocket, new Error("boom"));
      });
    });

    expect(log.events("hmd_socket_error")).toEqual([
      { event: "hmd_socket_error", session_id: init.session_id },
    ]);
    expect(log.events("device_socket_error")).toEqual([
      { event: "device_socket_error", session_id: init.session_id },
    ]);
  });
});
