// Wave-3 mutant scenarios for INV-24 (ack pairing) and INV-25 (Retry-After).
// docs/superpowers/specs/relay/INVARIANTS.md attributes both to "hmd client,
// app" rather than "relay" — the relay itself never originates an ack (it
// only forwards whatever the hmd/device side sends, byte-identical) and
// never emits a WS close-code 1013 anywhere in relay/src (confirmed by
// reading session.ts in full — the only relay-initiated close code anywhere
// is 4001, from revoke). Both gaps are reported as defects in the harness's
// final output, not fixed here.
//
// What IS relay-testable, and what these two scenarios drive instead:
//   INV-24 — the relay's frame-forwarding fidelity applied to `ack`-typed
//            envelopes specifically: exactly one WS message per posted ack,
//            never zero, never duplicated.
//   INV-25 — the relay's own 429 throttle response carries a correct,
//            consistent Retry-After header AND retry_after_s body field
//            (the "carries" half of INV-25, which the relay actually owns;
//            "both legs honor it" is hmd-client/app behavior, out of reach
//            from this repo).
import { describe, expect, it } from "vitest";
import { claimDevice, makeEnvelope, nextMessage, pairInit, postFrame, wsUpgrade } from "./helpers";

describe("MUT-INV-24-duplicate-or-missing-ack", () => {
  it("delivers exactly one ack frame per posted ack — never zero, never two", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume device_bound

    const ackEnvelope = makeEnvelope({
      session_id: init.session_id,
      type: "ack",
      seq: 2,
      ciphertext: "mutant-ack-ciphertext",
    });
    const nextFrame = nextMessage(socket); // arm before send
    const ackRes = await postFrame(init.session_id, init.relay_session_token, ackEnvelope);
    expect(ackRes.status).toBe(200);

    const received = await nextFrame;
    expect(received.type).toBe("ack");
    expect(received.ciphertext).toBe(ackEnvelope.ciphertext);

    let extra: unknown = "none";
    await Promise.race([
      nextMessage(socket).then((m) => {
        extra = m;
      }),
      new Promise((resolve) => setTimeout(resolve, 50)),
    ]);
    expect(extra).toBe("none");
  });

  it("delivers two sequential acks as two distinct messages, in order — not zero, not coalesced", async () => {
    const init = await pairInit();
    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    await nextMessage(socket); // consume device_bound

    const first = makeEnvelope({ session_id: init.session_id, type: "ack", seq: 2, ciphertext: "ack-1" });
    const firstFrame = nextMessage(socket);
    await postFrame(init.session_id, init.relay_session_token, first);
    expect((await firstFrame).ciphertext).toBe("ack-1");

    const second = makeEnvelope({ session_id: init.session_id, type: "ack", seq: 3, ciphertext: "ack-2" });
    const secondFrame = nextMessage(socket);
    await postFrame(init.session_id, init.relay_session_token, second);
    expect((await secondFrame).ciphertext).toBe("ack-2");
  });
});

describe("MUT-INV-25-ignore-retry-after", () => {
  it("the relay's 429 throttle response carries a correct Retry-After header and retry_after_s body field", async () => {
    const init = await pairInit();
    let last: Response | undefined;
    for (let i = 0; i < 11; i++) {
      last = await wsUpgrade(init.session_id, "pairing_code=WRONGWRONGWRONGWRONGWRONGW");
    }
    expect(last?.status).toBe(429);
    const retryAfterHeader = last?.headers.get("Retry-After");
    expect(retryAfterHeader).toBe("60");
    const body = (await last?.json()) as { retry_after_s: number };
    expect(body.retry_after_s).toBe(60);
    expect(String(body.retry_after_s)).toBe(retryAfterHeader);
  });
});
