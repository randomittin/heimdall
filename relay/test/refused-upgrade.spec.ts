// A refused phone upgrade that says why. React Native hands an app no HTTP status for a refused
// WebSocket handshake: a 404, a 401, a 410 and a dead network all reach it as an error with no
// relay close code, so the app retried a pairing that was over, for ever (the 2026-10-09 field
// report, hmdapp's docs/HANDOFF-TO-HEIMDALL-session-restart-repair.md, item 1). On `/ws` the relay
// therefore answers 101 and closes at once, with a code and a reason the app can read:
//
// - the session record is missing (purged, or never issued)  -> 4001 `gone`
// - the device token does not verify                          -> 4003 `invalid-token`
// - the token verifies and the session has ended              -> 4001 `ended`
//
// The order is the contract and the leak check. `gone` and `invalid-token` need no credential: they
// say what the old 404 and 401 said, to the same callers. `ended` is only ever said to a caller
// whose token verifies for THAT session, exactly as the old 410 was, so a stranger who merely holds
// a session id still cannot tell a live session from an ended one. The wire is fixed in
// relay/contract/wire.json (`phone.refused_upgrade`); this file replays it.

import { runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import wireJson from "../contract/wire.json";
import { base64UrlEncode } from "../src/pairing";
import { HmdSocket } from "./hmd-socket";
import {
  TEST_DEVICE_PUBKEY,
  claimDevice,
  nextMessage,
  pairInit,
  reconnectQuery,
  revoke,
  typedEnv,
  wsUpgrade,
} from "./trace/helpers";
import type { PairInitBody } from "./trace/helpers";

const refused = wireJson.phone.refused_upgrade;
const GONE = { code: refused.gone.close_code, reason: refused.gone.reason };
const ENDED = { code: refused.ended.close_code, reason: refused.ended.reason };
const INVALID_TOKEN = { code: refused.invalid_token.close_code, reason: refused.invalid_token.reason };

/** A phone upgrade the relay answered 101: its accepted socket, read from the first message on. */
function acceptedPhone(response: Response): HmdSocket {
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return new HmdSocket(socket);
}

/** The close an upgrade was refused with. A refusal says nothing before it closes. */
async function refusedWith(sessionId: string, query: string): Promise<{ code: number; reason: string } | null> {
  const phone = acceptedPhone(await wsUpgrade(sessionId, query));
  const close = await phone.closed();
  expect(phone.received, "a refusal sends no message before its close").toEqual([]);
  return close;
}

/** The phone claims the pairing code: the device token it reconnects with. */
async function bindPhone(init: PairInitBody): Promise<string> {
  const { socket } = await claimDevice(init.session_id, init.pairing_code);
  const bound = await nextMessage(socket);
  return (bound.payload as { device_token: string }).device_token;
}

describe("a refused phone upgrade says why", () => {
  it("answers `gone` for a session that was never issued, whatever the caller presents", async () => {
    const sessionId = crypto.randomUUID();
    const presented = [
      `device_token=not-a-token&device_pubkey=${TEST_DEVICE_PUBKEY}`,
      `pairing_code=ABCDEFGHIJKLMNOPQRSTUVWXYZ&device_pubkey=${TEST_DEVICE_PUBKEY}`,
      "",
    ];
    for (const query of presented) {
      expect(await refusedWith(sessionId, query), `presenting "${query}"`).toEqual(GONE);
    }
  });

  it("answers `gone` to a phone with a real token once the relay has purged its session", async () => {
    const init = await pairInit();
    const token = await bindPhone(init);
    await revoke(init.session_id, init.relay_session_token);
    const stub = typedEnv.SESSION.get(typedEnv.SESSION.idFromName(init.session_id));
    expect(await runDurableObjectAlarm(stub), "the purge alarm ran").toBe(true);

    expect(await refusedWith(init.session_id, reconnectQuery(token))).toEqual(GONE);
  });

  it("answers `ended` to a phone whose token verifies on a session that has ended", async () => {
    const init = await pairInit();
    const token = await bindPhone(init);
    await revoke(init.session_id, init.relay_session_token);

    expect(await refusedWith(init.session_id, reconnectQuery(token))).toEqual(ENDED);
  });

  it("answers `invalid-token` to a token that does not verify for this session and key", async () => {
    const init = await pairInit();
    const token = await bindPhone(init);
    const other = await pairInit();
    const otherToken = await bindPhone(other);
    const anotherKey = base64UrlEncode(new Uint8Array(32).fill(9));

    const cases: [string, string][] = [
      ["garbage", reconnectQuery("not-a-token")],
      ["another session's token", reconnectQuery(otherToken)],
      ["the right token without the key it is bound to", `device_token=${encodeURIComponent(token)}`],
      ["the right token with another key", `device_token=${encodeURIComponent(token)}&device_pubkey=${anotherKey}`],
    ];
    for (const [label, query] of cases) {
      expect(await refusedWith(init.session_id, query), label).toEqual(INVALID_TOKEN);
    }
  });

  it("never tells a caller without a verifying token that a session has ended: `invalid-token`, live or ended alike", async () => {
    const live = await pairInit();
    await bindPhone(live);
    const ended = await pairInit();
    await bindPhone(ended);
    await revoke(ended.session_id, ended.relay_session_token);

    expect(await refusedWith(live.session_id, reconnectQuery("not-a-token"))).toEqual(INVALID_TOKEN);
    expect(await refusedWith(ended.session_id, reconnectQuery("not-a-token"))).toEqual(INVALID_TOKEN);
  });

  it("does not refuse a phone whose token verifies on a live session", async () => {
    const init = await pairInit();
    const token = await bindPhone(init);

    const phone = acceptedPhone(await wsUpgrade(init.session_id, reconnectQuery(token)));
    expect(await phone.closed(300), "the socket stays open").toBeNull();
  });
});
