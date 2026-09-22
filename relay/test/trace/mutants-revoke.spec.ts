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
} from "./helpers";

describe("MUT-INV-29-partial-revoke", () => {
  it("revoke blocks device_token reconnect, the original pairing_code, AND frame delivery — not just new frames", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const { device_token: deviceToken } = bound.payload as { device_token: string };

    const revokeRes = await revoke(init.session_id, init.relay_session_token);
    expect(revokeRes.status).toBe(200);

    // 1. New device_token reconnect attempts are blocked.
    const byToken = await wsUpgrade(init.session_id, `device_token=${deviceToken}`);
    expect(byToken.status).toBe(410);

    // 2. The ORIGINAL pairing_code is also blocked — revoke is not scoped to
    //    "reconnect" alone, it kills every entry point into the session.
    const byOriginalCode = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
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
    const preRevoke = await wsUpgrade(init.session_id, `device_token=${oldDeviceToken}`);
    expect(preRevoke.status).toBe(101);
    preRevoke.webSocket?.accept();
    preRevoke.webSocket?.close();

    await revoke(init.session_id, init.relay_session_token);

    // Retry the old token twice — proving permanence, not a transient blip.
    const attempt1 = await wsUpgrade(init.session_id, `device_token=${oldDeviceToken}`);
    expect(attempt1.status).toBe(410);
    const attempt2 = await wsUpgrade(init.session_id, `device_token=${oldDeviceToken}`);
    expect(attempt2.status).toBe(410);

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
