// The presence frame on the phone's leg. A bound session whose hmd client died without revoking
// (a reboot) stays bound for 30 days, keeps accepting phone sockets and replays hmd's last `state`,
// which the phone rendered as live: nothing on the wire said "hmd is not attached"
// (hmdapp's docs/HANDOFF-TO-HEIMDALL-session-restart-repair.md, item 2). The relay now sends the
// phone a plaintext `peer` control frame, `payload: { hmd_online }`, as the last thing an accepted
// socket carries and again at every hmd attach and detach -- on either of hmd's transports, and for
// an hmd socket that closed without a revoke, through a hibernated Durable Object too. The wire is
// fixed in relay/contract/wire.json (`phone.peer`); every frame asserted here is derived from it.
//
// Real clocks throughout, as in hmd-ws.spec.ts: workerd's timers cannot be advanced from a test.

import { evictDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import wireJson from "../contract/wire.json";
import { HmdSocket, openHmdSocket, sleep } from "./hmd-socket";
import {
  BASE,
  TEST_DEVICE_PUBKEY,
  makeEnvelope,
  pairInit,
  postFrame,
  reconnectQuery,
  revoke,
  typedEnv,
  wsUpgrade,
} from "./trace/helpers";
import type { PairInitBody } from "./trace/helpers";

/** The fixture's presence frame for `sessionId`. */
function peer(sessionId: string, hmdOnline: boolean): Record<string, unknown> {
  const template = hmdOnline ? wireJson.phone.peer.online : wireJson.phone.peer.offline;
  return JSON.parse(JSON.stringify(template).replaceAll("$session_id", sessionId)) as Record<string, unknown>;
}

/** A phone upgrade, accepted, with every message queued from the first one on. */
async function openPhone(sessionId: string, query: string): Promise<HmdSocket> {
  const response = await wsUpgrade(sessionId, query);
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return new HmdSocket(socket);
}

function claimQuery(init: PairInitBody): string {
  return `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`;
}

/** The phone claims the pairing code and reads the two frames that accept carries. */
async function bindPhone(
  init: PairInitBody,
  hmdOnline: boolean
): Promise<{ phone: HmdSocket; deviceToken: string }> {
  const phone = await openPhone(init.session_id, claimQuery(init));
  const bound = await phone.nextJson();
  expect(bound?.type).toBe("device_bound");
  expect(await phone.nextJson(), "the accept ends with presence").toEqual(peer(init.session_id, hmdOnline));
  return { phone, deviceToken: (bound?.payload as { device_token: string }).device_token };
}

/** The `hmd_online` of every presence frame the phone has received, in order. */
function onlineSeen(phone: HmdSocket): boolean[] {
  return phone.received
    .map((message) => JSON.parse(message) as { type?: string; payload?: { hmd_online?: boolean } })
    .filter((frame) => frame.type === "peer")
    .map((frame) => frame.payload?.hmd_online === true);
}

describe("presence on accept", () => {
  it("tells a phone that claims the code that hmd is not attached, after device_bound", async () => {
    const init = await pairInit();
    await bindPhone(init, false);
  });

  it("tells it hmd is attached when hmd's socket was already open", async () => {
    const init = await pairInit();
    await openHmdSocket(BASE, init);
    await bindPhone(init, true);
  });

  it("ends a reconnect's accept with presence, after the replayed state", async () => {
    const init = await pairInit();
    await openHmdSocket(BASE, init);
    const { deviceToken } = await bindPhone(init, true);
    const state = makeEnvelope({
      session_id: init.session_id,
      type: "state",
      seq: 5,
      ciphertext: "state-for-the-replay",
      nonce: "nonce-for-the-replay",
    });
    expect((await postFrame(init.session_id, init.relay_session_token, state)).status).toBe(200);

    const reconnected = await openPhone(init.session_id, reconnectQuery(deviceToken));
    expect((await reconnected.nextJson())?.type).toBe("state");
    expect(await reconnected.nextJson()).toEqual(peer(init.session_id, true));
  });
});

describe("presence at hmd's attach and detach", () => {
  it("follows hmd's WebSocket: online when it attaches, offline when it closes with no revoke", async () => {
    const init = await pairInit();
    const { phone } = await bindPhone(init, false);

    const hmd = await openHmdSocket(BASE, init);
    expect(await phone.nextJson()).toEqual(peer(init.session_id, true));

    hmd.socket.close(1000, "laptop closed");
    expect(await phone.nextJson()).toEqual(peer(init.session_id, false));
  });

  it("follows hmd's NDJSON stream the same way: online when it opens, offline when the relay's lifetime bound closes it", async () => {
    const init = await pairInit();
    const { phone } = await bindPhone(init, false);

    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    if (!reader) throw new Error("expected a readable stream body");
    expect(await phone.nextJson()).toEqual(peer(init.session_id, true));

    // The relay ends every NDJSON stream at its lifetime bound (RELAY_STREAM_MAX_LIFETIME_MS, 8 s
    // under this suite) and hmd is detached until it reconnects. A client-side cancel is not used:
    // whether it reaches the Durable Object's stream is the platform's, and not what is pinned here.
    expect(await phone.nextJson(20_000)).toEqual(peer(init.session_id, false));
    await reader.cancel();
  }, 40_000);

  it("counts a superseding hmd socket as one attach and never reports the superseded one leaving", async () => {
    const init = await pairInit();
    const { phone } = await bindPhone(init, false);

    const first = await openHmdSocket(BASE, init);
    expect(await phone.nextJson()).toEqual(peer(init.session_id, true));
    const second = await openHmdSocket(BASE, init);
    expect(await phone.nextJson()).toEqual(peer(init.session_id, true));
    expect((await first.closed())?.code, "the older hmd socket is superseded").toBe(4002);
    await sleep(300);
    expect(onlineSeen(phone), "no offline frame between the two attaches").toEqual([false, true, true]);

    second.socket.close(1000, "laptop closed");
    expect(await phone.nextJson()).toEqual(peer(init.session_id, false));
  });

  it("reaches a phone when hmd's socket closes while the Durable Object is hibernated", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init, true);

    await evictDurableObject(typedEnv.SESSION.get(typedEnv.SESSION.idFromName(init.session_id)));
    hmd.socket.close(1000, "laptop closed while the object slept");
    expect(await phone.nextJson()).toEqual(peer(init.session_id, false));
  });

  it("sends the phone no presence once the session is over: a revoke is session_ended, then the close", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init, true);

    expect((await revoke(init.session_id, init.relay_session_token)).status).toBe(200);
    expect((await phone.nextJson())?.type).toBe("session_ended");
    expect((await phone.closed())?.code).toBe(4001);
    expect((await hmd.closed())?.code).toBe(4001);
    await sleep(300);
    expect(phone.received.map((message) => (JSON.parse(message) as { type: string }).type)).toEqual([
      "device_bound",
      "peer",
      "session_ended",
    ]);
  });
});

describe("presence is the relay's to say", () => {
  it("refuses a peer frame from hmd and from the phone, and forwards neither", async () => {
    const init = await pairInit();
    const hmd = await openHmdSocket(BASE, init);
    const { phone } = await bindPhone(init, true);
    expect((await hmd.nextJson())?.type, "device_bound reaches hmd").toBe("device_bound");

    const fromHmd = await postFrame(init.session_id, init.relay_session_token, peer(init.session_id, false));
    expect(fromHmd.status).toBe(400);

    phone.send(JSON.stringify(peer(init.session_id, false)));
    phone.send(JSON.stringify({ ...peer(init.session_id, false), sender: "device" }));
    expect(await hmd.next(300), "nothing a phone claims as presence reaches hmd").toBeNull();
    expect(onlineSeen(phone), "and the phone was told nothing new").toEqual([true]);
  });
});
