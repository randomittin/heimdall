// Wave-3 mutant scenarios for INV-29 (revoke blocks EVERY request kind, not
// just new frames) and INV-30 (a revoked device_token can never be
// resurrected — only a fresh pairing cycle works again). See
// mutants-auth.spec.ts's header comment for how these two are kept distinct
// from INV-9/INV-10, which share the same revoke mechanism but test
// different regression shapes (liveness-of-open-socket and immediacy,
// respectively).
import { describe, expect, it } from "vitest";
import {
  claimDevice,
  makeEnvelope,
  nextMessage,
  pairInit,
  postFrame,
  revoke,
  wsUpgrade,
  reconnectQuery,
  refusal,
  TEST_DEVICE_PUBKEY,
} from "./helpers";

describe("MUT-INV-29-partial-revoke", () => {
  it("revoke blocks device_token reconnect, the original pairing_code, AND frame delivery — not just new frames", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const { device_token: deviceToken } = bound.payload as { device_token: string };

    const revokeRes = await revoke(init.session_id, init.relay_session_token);
    expect(revokeRes.status).toBe(200);

    // 1. New device_token reconnect attempts are blocked: the token still verifies, so the relay
    //    refuses it as a 101 closed at once with 4001 / "ended" (a platform that hides the HTTP
    //    status of a refused handshake can read that). A mutant that lets the reconnect through
    //    leaves the socket open, which `refusal` reports as null.
    const byToken = await wsUpgrade(init.session_id, reconnectQuery(deviceToken));
    expect(await refusal(byToken)).toEqual({ code: 4001, reason: "ended" });

    // 2. The ORIGINAL pairing_code is also blocked — revoke is not scoped to
    //    "reconnect" alone, it kills every entry point into the session.
    const byOriginalCode = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`);
    expect(byOriginalCode.status).toBe(410);

    // 3. Frame delivery is blocked too (the device socket was force-closed).
    const envelope = makeEnvelope({ session_id: init.session_id, ciphertext: "post-revoke" });
    const framesRes = await postFrame(init.session_id, init.relay_session_token, envelope);
    expect(await framesRes.json()).toEqual({ ok: true, delivered: false });
  });
});

describe("MUT-INV-30-token-resurrection", () => {
  it("the old device_token never works again, even retried, and only a fresh pairing cycle succeeds", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const { device_token: oldDeviceToken } = bound.payload as { device_token: string };

    // Baseline: prove the token actually worked for reconnect BEFORE revoke.
    const preRevoke = await wsUpgrade(init.session_id, reconnectQuery(oldDeviceToken));
    expect(preRevoke.status).toBe(101);
    // A refusal is a 101 too, so the baseline is that the socket is NOT refused.
    expect(await refusal(preRevoke, 300), "a good token is not refused").toBeNull();

    await revoke(init.session_id, init.relay_session_token);

    // Retry the old token twice — proving permanence, not a transient blip. Each is refused with
    // 4001 / "ended" (the token verifies, the session is over); a resurrected token would leave
    // the socket open, which `refusal` reports as null.
    const attempt1 = await wsUpgrade(init.session_id, reconnectQuery(oldDeviceToken));
    expect(await refusal(attempt1)).toEqual({ code: 4001, reason: "ended" });
    const attempt2 = await wsUpgrade(init.session_id, reconnectQuery(oldDeviceToken));
    expect(await refusal(attempt2)).toEqual({ code: 4001, reason: "ended" });

    // The only forward path is an entirely fresh pairing cycle.
    const fresh = await pairInit();
    expect(fresh.session_id).not.toBe(init.session_id);
    expect(fresh.pairing_code).not.toBe(init.pairing_code);
    const { socket: freshSocket } = await claimDevice(fresh.session_id, fresh.pairing_code);
    const freshBound = await nextMessage(freshSocket);
    const { device_token: freshDeviceToken } = freshBound.payload as { device_token: string };
    expect(freshDeviceToken).not.toBe(oldDeviceToken);
  });
});
