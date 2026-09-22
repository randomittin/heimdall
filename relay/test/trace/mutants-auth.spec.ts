// Wave-3 mutant scenarios for the auth invariants (INV-6, 7, 9, 10). INV-8 is
// intentionally absent — see relay/scripts/trace-diff.mjs's UNCOVERED entry:
// no HTTP/WS-observable surface exists for relay-internal log contents, and
// that invariant is already gated at the source level by the pre-existing
// relay/scripts/check-no-logged-urls.mjs (wired into `npm test`).
//
// docs/superpowers/specs/relay/INVARIANTS.md attributes INV-9/INV-10 (and
// INV-29/INV-30, see mutants-revoke.spec.ts) to "relay" broadly; the four
// are kept as distinct scenarios rather than one shared test because each
// targets a different regression shape given the relay's actual surface —
// there is no per-message credential in this protocol, device_token is
// checked only at WS-upgrade time:
//   INV-9  — an already-OPEN device socket stops receiving once revoked
//            (a live connection, no reconnect attempt involved).
//   INV-10 — the very NEXT reconnect attempt after revoke fails, no grace window.
//   INV-29 (mutants-revoke.spec.ts) — revoke blocks EVERY request kind, not just frames.
//   INV-30 (mutants-revoke.spec.ts) — the old device_token is dead PERMANENTLY;
//            only a fresh pairing cycle works again.
import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";
import {
  BASE,
  claimDevice,
  makeEnvelope,
  nextCloseCode,
  nextMessage,
  pairInit,
  postFrame,
  revoke,
  wsUpgrade,
} from "./helpers";

describe("MUT-INV-6-token-in-query", () => {
  it("relay does not accept a ?token= query param as an alternate to the Authorization header (stream)", async () => {
    const init = await pairInit();
    const res = await SELF.fetch(
      `${BASE}/session/${init.session_id}/stream?token=${init.relay_session_token}`
    );
    expect(res.status).toBe(401);
  });

  it("relay does not accept a ?token= query param as an alternate to the Authorization header (frames)", async () => {
    const init = await pairInit();
    const envelope = makeEnvelope({ session_id: init.session_id });
    const res = await SELF.fetch(
      `${BASE}/session/${init.session_id}/frames?token=${init.relay_session_token}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(envelope),
      }
    );
    expect(res.status).toBe(401);
  });
});

describe("MUT-INV-7-allow-plaintext-ws", () => {
  it("rejects an upgrade carrying an explicit X-Forwarded-Proto: http signal", async () => {
    const init = await pairInit();
    const res = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`, {
      "X-Forwarded-Proto": "http",
    });
    expect(res.status).toBe(400);
  });

  it("rejects an upgrade carrying an explicit cf-visitor http-scheme signal", async () => {
    const init = await pairInit();
    const res = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`, {
      "cf-visitor": JSON.stringify({ scheme: "http" }),
    });
    expect(res.status).toBe(400);
  });
});

describe("MUT-INV-9-cache-trust", () => {
  it("an already-open device socket stops being served the moment the session is revoked", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume device_bound

    const closeCodePromise = nextCloseCode(socket); // arm before the trigger — see worker.spec.ts:316
    const revokeRes = await revoke(init.session_id, init.relay_session_token);
    expect(revokeRes.status).toBe(200);
    expect(await closeCodePromise).toBe(4001); // the live socket is force-closed by revoke

    // hmd posts a frame AFTER revoke — a "cached trust" bug would still find
    // the (should-be-gone) socket and deliver to it; the relay must instead
    // re-check the live connection set and report non-delivery.
    const envelope = makeEnvelope({ session_id: init.session_id, ciphertext: "post-revoke-frame" });
    const framesRes = await postFrame(init.session_id, init.relay_session_token, envelope);
    expect(framesRes.status).toBe(200);
    expect(await framesRes.json()).toEqual({ ok: true, delivered: false });
  });
});

describe("MUT-INV-10-delayed-revoke", () => {
  it("the very next reconnect attempt using the pre-revoke device_token fails, no grace window", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const bound = await nextMessage(socket);
    const { device_token: deviceToken } = bound.payload as { device_token: string };

    // Baseline: prove the token actually works for reconnect BEFORE revoke —
    // otherwise a mutant that rejects every device_token unconditionally
    // would also make the "fails after revoke" assertion below vacuously pass.
    const preRevoke = await wsUpgrade(init.session_id, `device_token=${deviceToken}`);
    expect(preRevoke.status).toBe(101);
    preRevoke.webSocket?.accept();
    preRevoke.webSocket?.close();

    const revokeRes = await revoke(init.session_id, init.relay_session_token);
    expect(revokeRes.status).toBe(200);

    // Immediately — no delay, no sleep — attempt reconnect with the old token.
    const reconnect = await wsUpgrade(init.session_id, `device_token=${deviceToken}`);
    expect(reconnect.status).toBe(410);
  });
});
