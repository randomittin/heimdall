// Security hardening suite — one describe block per finding in
// docs/analysis/2026-09-24-relay-security-audit.md.
//
// Every case here is a gap the audit named explicitly under "What is NOT
// covered by tests": frame provenance on either leg, the phone-leg size cap,
// post-bind token re-validation, device-token/device-key binding, and abuse
// cost bounds. The existing worker.spec.ts suite covers the happy paths these
// build on; nothing below duplicates it.

import { env, SELF, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Env, Envelope } from "../src/types";
import type { SessionDO } from "../src/session";
import { base64UrlEncode, mintDeviceToken } from "../src/pairing";

const typedEnv = env as unknown as Env;

const BASE = "https://relay-hardening.test";

/** Not a secret — deterministic 32-byte filler, the same fixture idiom
 * worker.spec.ts uses (CLAUDE.md: "no secret-shaped literals"). */
const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));
/** A second, different valid pubkey — the "attacker presents their own key"
 * case for the device_token binding. */
const OTHER_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(9));

interface PairInitBody {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

/** Each test is logically a distinct client, so each gets its own source IP —
 * otherwise the per-IP `/pair/init` throttle this suite itself adds would
 * start rejecting the eleventh test in the file. The throttle's own tests
 * below pin a fixed IP deliberately. */
async function pairInit(ip: string = crypto.randomUUID()): Promise<PairInitBody> {
  const res = await SELF.fetch(`${BASE}/pair/init`, {
    method: "POST",
    headers: { "CF-Connecting-IP": ip },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInitBody;
}

function wsUrl(sessionId: string, query: string): string {
  return `${BASE}/session/${sessionId}/ws?${query}`;
}

async function upgrade(sessionId: string, query: string): Promise<Response> {
  return SELF.fetch(wsUrl(sessionId, query), { headers: { Upgrade: "websocket" } });
}

async function claimDevice(init: PairInitBody): Promise<{ socket: WebSocket; deviceToken: string }> {
  const response = await upgrade(
    init.session_id,
    `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`
  );
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  const bound = await nextMessage(socket);
  const payload = bound.payload as { device_token: string };
  return { socket, deviceToken: payload.device_token };
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

/** Bytes read off a stream that did not yet complete a line, carried to the
 *  next `readDataFrame` on the same reader. */
const streamResidue = new WeakMap<ReadableStreamDefaultReader<Uint8Array>, string>();

/**
 * Next non-`keepalive` line off hmd's stream.
 *
 * Buffers across reads rather than assuming one chunk is one line: the runtime
 * both coalesces small frames and splits large ones (a ~900 KB `command`
 * arrives in 4 KiB pieces), and keepalives interleave on any stream held open
 * across awaits, since their cadence is wall-clock.
 */
async function readDataFrame(
  reader: ReadableStreamDefaultReader<Uint8Array>
): Promise<Record<string, unknown>> {
  let buffered = streamResidue.get(reader) ?? "";
  for (;;) {
    let newlineAt: number;
    while ((newlineAt = buffered.indexOf("\n")) !== -1) {
      const line = buffered.slice(0, newlineAt).trim();
      buffered = buffered.slice(newlineAt + 1);
      if (line.length === 0) continue;
      const frame = JSON.parse(line) as Record<string, unknown>;
      if (frame.type === "keepalive") continue;
      streamResidue.set(reader, buffered);
      return frame;
    }
    const { value } = await reader.read();
    if (!value) throw new Error("expected stream bytes");
    buffered += new TextDecoder().decode(value);
  }
}

function makeEnvelope(overrides: Partial<Envelope> & Pick<Envelope, "session_id">): Envelope {
  return {
    v: 1,
    seq: 1,
    sender: "device",
    type: "command",
    nonce: "test-nonce",
    ciphertext: "test-ciphertext",
    ...overrides,
  };
}

async function postFrame(
  init: PairInitBody,
  envelope: Envelope | Record<string, unknown>
): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${init.session_id}/frames`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${init.relay_session_token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(envelope),
  });
}

function sessionStub(sessionId: string): DurableObjectStub {
  return typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));
}

/**
 * Sends `forged` up the device socket, then a known-good `command` carrying
 * `marker`, and returns the first frame hmd's stream actually receives.
 *
 * A single WebSocket preserves order, so if the forged frame were forwarded it
 * would arrive first — the assertion is "the marker is what came through",
 * which fails loudly on a leak instead of racing a timeout.
 */
async function firstFrameAfterForgery(
  init: PairInitBody,
  socket: WebSocket,
  reader: ReadableStreamDefaultReader<Uint8Array>,
  forged: Envelope | Record<string, unknown>,
  marker: string
): Promise<Record<string, unknown>> {
  socket.send(JSON.stringify(forged));
  socket.send(
    JSON.stringify(
      makeEnvelope({ session_id: init.session_id, seq: 2, ciphertext: marker })
    )
  );
  return readDataFrame(reader);
}

describe("finding 1 — device leg forwards only device-originated frames", () => {
  /** The audit's proof-of-concept payload: a `sender:"relay"` `device_bound`
   *  pushed up the phone socket, which the relay copied verbatim into hmd's
   *  stream. hmd re-derives its session key from `payload.device_pubkey` on
   *  every `device_bound`, so forwarding this rebinds the session to the
   *  sender's own X25519 key — a full end-to-end break (INV-18/19/31). */
  it("drops a forged sender:relay device_bound pushed up the phone socket", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader); // the buffered device_bound for hmd

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      {
        v: 1,
        session_id: init.session_id,
        seq: 0,
        sender: "relay",
        type: "device_bound",
        nonce: null,
        ciphertext: null,
        payload: { device_pubkey: OTHER_DEVICE_PUBKEY, bound_at: 1 },
      },
      "legit-after-forged-device-bound"
    );

    expect(received.type).toBe("command");
    expect(received.ciphertext).toBe("legit-after-forged-device-bound");
  });

  it("drops a forged sender:relay session_ended pushed up the phone socket", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      {
        v: 1,
        session_id: init.session_id,
        seq: 0,
        sender: "relay",
        type: "session_ended",
        nonce: null,
        ciphertext: null,
        payload: { reason: "revoked" },
      },
      "legit-after-forged-session-ended"
    );

    expect(received.ciphertext).toBe("legit-after-forged-session-ended");
  });

  it("drops a relay-originated keepalive pushed up the phone socket", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      {
        v: 1,
        session_id: init.session_id,
        seq: 0,
        sender: "relay",
        type: "keepalive",
        nonce: null,
        ciphertext: null,
        payload: { ts: 1 },
      },
      "legit-after-forged-keepalive"
    );

    expect(received.ciphertext).toBe("legit-after-forged-keepalive");
  });

  it("drops a device-sent state frame (an hmd-only type on the phone leg)", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      makeEnvelope({ session_id: init.session_id, type: "state", ciphertext: "forged-state" }),
      "legit-after-forged-state"
    );

    expect(received.ciphertext).toBe("legit-after-forged-state");
  });

  it("drops a device-sent ack frame (hmd is the only party that acks)", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      makeEnvelope({ session_id: init.session_id, type: "ack", ciphertext: "forged-ack" }),
      "legit-after-forged-ack"
    );

    expect(received.ciphertext).toBe("legit-after-forged-ack");
  });

  it("drops a sender:hmd frame pushed up the phone socket", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const received = await firstFrameAfterForgery(
      init,
      socket,
      reader,
      makeEnvelope({
        session_id: init.session_id,
        sender: "hmd",
        type: "state",
        ciphertext: "forged-hmd-state",
      }),
      "legit-after-forged-hmd-sender"
    );

    expect(received.ciphertext).toBe("legit-after-forged-hmd-sender");
  });

  it("still forwards a well-formed device command byte-identically", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    socket.send(
      JSON.stringify(
        makeEnvelope({
          session_id: init.session_id,
          ciphertext: "unchanged-command-ciphertext",
          nonce: "unchanged-command-nonce",
        })
      )
    );

    const received = await readDataFrame(reader);
    expect(received.sender).toBe("device");
    expect(received.type).toBe("command");
    expect(received.ciphertext).toBe("unchanged-command-ciphertext");
    expect(received.nonce).toBe("unchanged-command-nonce");
  });
});

describe("finding 1 — hmd leg accepts only hmd-originated frames", () => {
  it("rejects a sender:relay device_bound posted to /frames with 400", async () => {
    const init = await pairInit();
    const res = await postFrame(init, {
      v: 1,
      session_id: init.session_id,
      seq: 0,
      sender: "relay",
      type: "device_bound",
      nonce: null,
      ciphertext: null,
      payload: { device_pubkey: OTHER_DEVICE_PUBKEY, bound_at: 1 },
    });
    expect(res.status).toBe(400);
  });

  it("rejects a sender:relay session_ended posted to /frames with 400", async () => {
    const init = await pairInit();
    const res = await postFrame(init, {
      v: 1,
      session_id: init.session_id,
      seq: 0,
      sender: "relay",
      type: "session_ended",
      nonce: null,
      ciphertext: null,
      payload: { reason: "revoked" },
    });
    expect(res.status).toBe(400);
  });

  it("rejects a sender:device command posted to /frames with 400", async () => {
    const init = await pairInit();
    const res = await postFrame(init, makeEnvelope({ session_id: init.session_id }));
    expect(res.status).toBe(400);
  });

  it("rejects a sender:hmd command posted to /frames with 400", async () => {
    const init = await pairInit();
    const res = await postFrame(
      init,
      makeEnvelope({ session_id: init.session_id, sender: "hmd", type: "command" })
    );
    expect(res.status).toBe(400);
  });

  it("still accepts hmd's own state and ack frames", async () => {
    const init = await pairInit();
    const state = await postFrame(
      init,
      makeEnvelope({ session_id: init.session_id, sender: "hmd", type: "state" })
    );
    expect(state.status).toBe(200);

    const ack = await postFrame(
      init,
      makeEnvelope({ session_id: init.session_id, sender: "hmd", type: "ack", seq: 2 })
    );
    expect(ack.status).toBe(200);
  });

  it("accepts hmd's envelope with an explicit null payload (the real client's shape)", async () => {
    const init = await pairInit();
    const res = await postFrame(init, {
      ...makeEnvelope({ session_id: init.session_id, sender: "hmd", type: "state" }),
      payload: null,
    });
    expect(res.status).toBe(200);
  });
});

describe("finding 6 — device_token is bound to the device's X25519 public key", () => {
  it("accepts a reconnect presenting the same device_pubkey the token was minted for", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimDevice(init);

    const res = await upgrade(
      init.session_id,
      `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${TEST_DEVICE_PUBKEY}`
    );
    expect(res.status).toBe(101);
  });

  it("rejects a reconnect presenting a different device_pubkey with 401", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimDevice(init);

    const res = await upgrade(
      init.session_id,
      `device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${OTHER_DEVICE_PUBKEY}`
    );
    expect(res.status).toBe(401);
  });

  it("rejects a reconnect omitting device_pubkey on a pubkey-bound token with 401", async () => {
    const init = await pairInit();
    const { deviceToken } = await claimDevice(init);

    const res = await upgrade(init.session_id, `device_token=${encodeURIComponent(deviceToken)}`);
    expect(res.status).toBe(401);
  });

  /**
   * LEGACY TOLERANCE — load-bearing, not a nicety. A phone paired before this
   * change holds a token minted from `{session_id, role, exp}` with no pubkey
   * claim, and its app build does not put `device_pubkey` on the reconnect
   * URL. Rejecting that would strand a live paired device with no way back
   * except a physical re-scan. Such tokens keep working until they expire.
   */
  it("accepts a legacy token (no pubkey claim) reconnecting without device_pubkey", async () => {
    const init = await pairInit();
    await claimDevice(init);

    const legacyToken = await mintDeviceToken(typedEnv.RELAY_SIGNING_SECRET, {
      session_id: init.session_id,
      role: "device",
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    const res = await upgrade(init.session_id, `device_token=${encodeURIComponent(legacyToken)}`);
    expect(res.status).toBe(101);
  });

  it("accepts a legacy token reconnecting with a device_pubkey it cannot be checked against", async () => {
    const init = await pairInit();
    await claimDevice(init);

    const legacyToken = await mintDeviceToken(typedEnv.RELAY_SIGNING_SECRET, {
      session_id: init.session_id,
      role: "device",
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    const res = await upgrade(
      init.session_id,
      `device_token=${encodeURIComponent(legacyToken)}&device_pubkey=${OTHER_DEVICE_PUBKEY}`
    );
    expect(res.status).toBe(101);
  });
});

describe("finding 13 — device_token claims are validated fail-closed", () => {
  it("rejects a token whose claims carry no exp instead of treating it as never-expiring", async () => {
    const init = await pairInit();
    await claimDevice(init);

    // NaN comparisons are always false, so `nowMs / 1000 > claims.exp` used to
    // pass for an absent `exp` — a token that never expires.
    const noExp = await mintDeviceToken(typedEnv.RELAY_SIGNING_SECRET, {
      session_id: init.session_id,
      role: "device",
    } as never);

    const res = await upgrade(init.session_id, `device_token=${encodeURIComponent(noExp)}`);
    expect(res.status).toBe(401);
  });

  it("rejects a correctly-signed token whose payload decodes to null with 401, not a crash", async () => {
    const init = await pairInit();
    await claimDevice(init);

    // `JSON.parse("null")` succeeds, escapes the try/catch, and used to throw a
    // TypeError on the next property read — a 500 where a 401 belongs.
    const nullClaims = await mintDeviceToken(typedEnv.RELAY_SIGNING_SECRET, null as never);

    const res = await upgrade(init.session_id, `device_token=${encodeURIComponent(nullClaims)}`);
    expect(res.status).toBe(401);
  });
});

describe("finding 8 — INV-16's 1 MiB cap applies to the phone leg too", () => {
  it("closes an oversize device message's socket with 1009", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const closed = nextCloseCode(socket);

    socket.send(
      JSON.stringify(
        makeEnvelope({ session_id: init.session_id, ciphertext: "a".repeat(1_100_000) })
      )
    );

    expect(await closed).toBe(1009);
  });

  it("does not forward an oversize device message to hmd's stream", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader); // the buffered device_bound

    socket.send(
      JSON.stringify(
        makeEnvelope({ session_id: init.session_id, ciphertext: "b".repeat(1_100_000) })
      )
    );

    let forwarded: unknown = "none";
    await Promise.race([
      reader.read().then((r) => {
        forwarded = r.value ? new TextDecoder().decode(r.value) : "none";
      }),
      new Promise((resolve) => setTimeout(resolve, 100)),
    ]);
    expect(forwarded).toBe("none");
  });

  it("still forwards a large device message under the cap", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    const big = "c".repeat(900_000);
    socket.send(JSON.stringify(makeEnvelope({ session_id: init.session_id, ciphertext: big })));

    const received = await readDataFrame(reader);
    expect(received.ciphertext).toBe(big);
  });
});

describe("finding 9 — INV-9/INV-10: the device token is re-checked per frame", () => {
  /** Drives `webSocketMessage` directly so the socket is still attached after
   *  the state change — `handleRevoke` normally closes it, and the audit's
   *  point is precisely that a `close()` which throws or races leaves a socket
   *  whose frames were still being forwarded. */
  async function deliverOnDeviceSocket(
    sessionId: string,
    frame: Envelope | Record<string, unknown>,
    mutate?: (socket: WebSocket) => void
  ): Promise<void> {
    await runInDurableObject(sessionStub(sessionId), async (instance, state) => {
      const socket = state.getWebSockets("device")[0];
      if (!socket) throw new Error("expected an attached device socket");
      mutate?.(socket);
      await (instance as unknown as SessionDO).webSocketMessage(socket, JSON.stringify(frame));
    });
  }

  it("drops a frame from a socket whose session is ended", async () => {
    const init = await pairInit();
    await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    // `handleRevoke` closes and detaches the socket, so calling it would leave
    // nothing to deliver on and prove nothing. The state the audit actually
    // names is a record marked "ended" while a socket is *still attached* — a
    // `close()` that threw (the catch at handleRevoke swallows it) or raced a
    // hibernated socket. Arranged directly, so the assertion is about
    // `webSocketMessage` consulting the record rather than about revoke's
    // socket teardown, which worker.spec.ts already covers.
    await runInDurableObject(sessionStub(init.session_id), async (_instance, state) => {
      const record = (await state.storage.get("state")) as { status: string };
      record.status = "ended";
      await state.storage.put("state", record);
    });

    await deliverOnDeviceSocket(
      init.session_id,
      makeEnvelope({ session_id: init.session_id, ciphertext: "after-session-ended" })
    );

    let forwarded: unknown = "none";
    await Promise.race([
      reader.read().then((r) => {
        forwarded = r.value ? new TextDecoder().decode(r.value) : "none";
      }),
      new Promise((resolve) => setTimeout(resolve, 100)),
    ]);
    expect(forwarded).toBe("none");
  });

  it("drops a frame from a socket whose device_token has passed its exp", async () => {
    const init = await pairInit();
    await claimDevice(init);
    const reader = await openHmdStream(init);
    await readDataFrame(reader);

    await deliverOnDeviceSocket(
      init.session_id,
      makeEnvelope({ session_id: init.session_id, ciphertext: "after-token-expiry" }),
      (socket) => {
        const current = socket.deserializeAttachment() as { gen: number };
        socket.serializeAttachment({ ...current, token_exp: Math.floor(Date.now() / 1000) - 1 });
      }
    );

    let forwarded: unknown = "none";
    await Promise.race([
      reader.read().then((r) => {
        forwarded = r.value ? new TextDecoder().decode(r.value) : "none";
      }),
      new Promise((resolve) => setTimeout(resolve, 100)),
    ]);
    expect(forwarded).toBe("none");
  });

  it("stamps the token's exp onto the accepted device socket", async () => {
    const init = await pairInit();
    await claimDevice(init);

    const stamped = await runInDurableObject(sessionStub(init.session_id), (_instance, state) => {
      const socket = state.getWebSockets("device")[0];
      return (socket?.deserializeAttachment() as { token_exp?: number } | null)?.token_exp;
    });

    expect(typeof stamped).toBe("number");
    expect(stamped as number).toBeGreaterThan(Math.floor(Date.now() / 1000));
  });
});

describe("finding 7 — /pair/init is throttled per source IP", () => {
  it("rejects the attempt past the per-IP window bound with 429 + Retry-After", async () => {
    const ip = "198.51.100.7"; // TEST-NET-2, reserved for documentation (RFC 5737)
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) {
      const res = await SELF.fetch(`${BASE}/pair/init`, {
        method: "POST",
        headers: { "CF-Connecting-IP": ip },
      });
      statuses.push(res.status);
      if (i === 10) {
        expect(res.headers.get("Retry-After")).toBe("60");
        expect(await res.json()).toMatchObject({ retry_after_s: 60 });
      }
    }
    expect(statuses.slice(0, 10)).toEqual(Array(10).fill(200));
    expect(statuses[10]).toBe(429);
  });

  it("leaves a different source IP unaffected", async () => {
    const hammered = "198.51.100.8";
    for (let i = 0; i < 11; i++) {
      await SELF.fetch(`${BASE}/pair/init`, {
        method: "POST",
        headers: { "CF-Connecting-IP": hammered },
      });
    }

    const other = await SELF.fetch(`${BASE}/pair/init`, {
      method: "POST",
      headers: { "CF-Connecting-IP": "198.51.100.9" },
    });
    expect(other.status).toBe(200);
  });
});

describe("finding 7 — Durable Object storage is reclaimed", () => {
  async function storedRecord(sessionId: string): Promise<unknown> {
    return runInDurableObject(sessionStub(sessionId), (_instance, state) =>
      state.storage.get("state")
    );
  }

  async function scheduledAlarm(sessionId: string): Promise<number | null> {
    return runInDurableObject(sessionStub(sessionId), (_instance, state) =>
      state.storage.getAlarm()
    );
  }

  it("arms a purge alarm when a session is created", async () => {
    const init = await pairInit();
    expect(await scheduledAlarm(init.session_id)).not.toBeNull();
  });

  it("purges an unclaimed session once its pairing window has passed", async () => {
    const sessionId = crypto.randomUUID();
    const stub = sessionStub(sessionId);
    const res = await stub.fetch("http://do-internal/init", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session_id: sessionId, pairing_ttl_s: -1 }),
    });
    expect(res.status).toBe(200);

    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await storedRecord(sessionId)).toBeUndefined();
  });

  it("keeps a still-claimable session and re-arms its alarm", async () => {
    const init = await pairInit();

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    expect(await storedRecord(init.session_id)).toBeDefined();
    expect(await scheduledAlarm(init.session_id)).not.toBeNull();
  });

  it("keeps a bound session alive until its device_token expires", async () => {
    const init = await pairInit();
    await claimDevice(init);

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);

    expect(await storedRecord(init.session_id)).toBeDefined();
    expect(await scheduledAlarm(init.session_id)).not.toBeNull();
  });

  it("purges a bound session whose device_token has expired", async () => {
    const init = await pairInit();
    await claimDevice(init);

    await runInDurableObject(sessionStub(init.session_id), async (_instance, state) => {
      const record = (await state.storage.get("state")) as { device_token_exp: number };
      record.device_token_exp = Math.floor(Date.now() / 1000) - 1;
      await state.storage.put("state", record);
    });

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);
    expect(await storedRecord(init.session_id)).toBeUndefined();
  });

  it("purges a revoked session when its grace alarm fires", async () => {
    const init = await pairInit();
    await claimDevice(init);

    const revoked = await SELF.fetch(`${BASE}/session/${init.session_id}/revoke`, {
      method: "POST",
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(revoked.status).toBe(200);

    expect(await runDurableObjectAlarm(sessionStub(init.session_id))).toBe(true);
    expect(await storedRecord(init.session_id)).toBeUndefined();
  });

  it("purges a session whose pairing code expired at claim time", async () => {
    const sessionId = crypto.randomUUID();
    const stub = sessionStub(sessionId);
    const initRes = await stub.fetch("http://do-internal/init", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session_id: sessionId, pairing_ttl_s: -1 }),
    });
    const { pairing_code: code } = (await initRes.json()) as { pairing_code: string };

    const claim = await upgrade(sessionId, `pairing_code=${code}&device_pubkey=${TEST_DEVICE_PUBKEY}`);
    expect(claim.status).toBe(410);

    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await storedRecord(sessionId)).toBeUndefined();
  });
});

describe("finding 18 — HSTS", () => {
  it("sets Strict-Transport-Security on a JSON response", async () => {
    const res = await SELF.fetch(`${BASE}/pair/init`, {
      method: "POST",
      headers: { "CF-Connecting-IP": crypto.randomUUID() },
    });
    expect(res.headers.get("Strict-Transport-Security")).toBe(
      "max-age=31536000; includeSubDomains"
    );
  });

  it("sets Strict-Transport-Security on hmd's stream response", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(res.headers.get("Strict-Transport-Security")).toBe(
      "max-age=31536000; includeSubDomains"
    );
    await res.body?.cancel();
  });
});
