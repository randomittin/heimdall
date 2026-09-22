// Wave-3 mutant scenarios for the pairing invariants (INV-1..5). Each test
// performs the violating action named in docs/superpowers/specs/relay/
// INVARIANTS.md's "Mutant (Wave-3)" column and asserts the relay REJECTS it
// with the documented observable — a passing test means the invariant
// holds against the current relay/src implementation (read, never modified,
// by this harness; see relay/README.md for the API this drives).
import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";
import { BASE, claimDevice, directInit, pairInit, wsUpgrade } from "./helpers";

describe("MUT-INV-1-double-claim", () => {
  it("relay rejects a 2nd claim against an already-consumed pairing_code", async () => {
    const init = await pairInit();
    await claimDevice(init.session_id, init.pairing_code);

    const second = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
    expect(second.status).toBe(410);
    expect(second.webSocket).toBeNull();
  });
});

describe("MUT-INV-2-no-ttl", () => {
  it("relay rejects a claim made after the pairing code's exp, even with the correct code", async () => {
    const sessionId = crypto.randomUUID();
    const init = await directInit(sessionId, -1); // already-expired by construction

    const claim = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
    expect(claim.status).toBe(410);
  });
});

describe("MUT-INV-3-precock-leak", () => {
  it("a frame posted before any device claim is never later delivered to the claiming device", async () => {
    const init = await pairInit();

    // Nobody has claimed yet. Post a frame now — nothing is connected, so
    // relay/src/session.ts's handleFrames must report delivered:false. A
    // mutant that buffered-and-flushed-on-claim would still return this
    // same response here, so the real assertion is below: the pre-claim
    // frame must never surface once a device does claim.
    const precockEnvelope = {
      v: 1 as const,
      session_id: init.session_id,
      seq: 1,
      sender: "hmd" as const,
      type: "state" as const,
      nonce: "precock-nonce",
      ciphertext: "precock-ciphertext-should-never-be-seen",
    };
    const framesRes = await SELF.fetch(`${BASE}/session/${init.session_id}/frames`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${init.relay_session_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(precockEnvelope),
    });
    expect(framesRes.status).toBe(200);
    expect(await framesRes.json()).toEqual({ ok: true, delivered: false });

    const { socket } = await claimDevice(init.session_id, init.pairing_code);
    const first = await new Promise<Record<string, unknown>>((resolve) => {
      socket.addEventListener(
        "message",
        (event) => resolve(JSON.parse((event as unknown as { data: string }).data)),
        { once: true }
      );
    });
    expect(first.type).toBe("device_bound");
    expect(first.ciphertext).toBeNull();

    // And no second message (the leaked precock frame) follows shortly after.
    let extra: unknown = "none";
    await Promise.race([
      new Promise<void>((resolve) => {
        socket.addEventListener(
          "message",
          (event) => {
            extra = JSON.parse((event as unknown as { data: string }).data);
            resolve();
          },
          { once: true }
        );
      }),
      new Promise((resolve) => setTimeout(resolve, 50)),
    ]);
    expect(extra).toBe("none");
  });
});

describe("MUT-INV-4-no-throttle", () => {
  it("the 11th claim attempt invalidates the session outright, even a later correct-code attempt fails", async () => {
    const init = await pairInit();

    for (let i = 0; i < 10; i++) {
      const wrong = await wsUpgrade(init.session_id, "pairing_code=WRONGWRONGWRONGWRONGWRONGW");
      expect(wrong.status).toBe(401);
    }

    // 11th attempt uses the CORRECT code. If the throttle only rejected
    // wrong codes, this would succeed (101); it must not.
    const eleventh = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
    expect(eleventh.status).toBe(429);
    expect(eleventh.headers.get("Retry-After")).toBe("60");

    // The session is now permanently dead — even a later correct attempt fails.
    const twelfth = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
    expect(twelfth.status).toBe(410);
  });
});

describe("MUT-INV-5-add-identity-gate", () => {
  it("relay accepts /pair/init with no bearer/identity header of any kind", async () => {
    const res = await SELF.fetch(`${BASE}/pair/init`, { method: "POST" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { session_id: string };
    expect(typeof body.session_id).toBe("string");
  });

  it("still succeeds with an unrelated header present (no implicit identity check was added)", async () => {
    const res = await SELF.fetch(`${BASE}/pair/init`, {
      method: "POST",
      headers: { "X-Not-A-Real-Identity-Header": "anything" },
    });
    expect(res.status).toBe(200);
  });
});

describe("regression: POST /session/:id/init is not reachable from a public request", () => {
  it("external POST /session/:id/init is rejected, and the existing pairing_code stays valid", async () => {
    // relay/src/session.ts's handleInit is an internal contract meant to run
    // only from worker.ts's own handlePairInit (a direct
    // stub.fetch("http://do-internal/init", ...) call) — never from a
    // public path. This used to be reachable anyway: relay/src/worker.ts's
    // old SESSION_PATH_RE accepted an arbitrary subPath and forwarded it
    // straight to the Durable Object, including "/init", so an
    // unauthenticated internet request could re-mint an existing session's
    // pairing_code and invalidate the real one. worker.ts now whitelists the
    // session's public subpaths (stream/frames/ws/revoke) and rejects
    // anything else — including "init" — before the Durable Object is ever
    // touched. This test drives that through the real public router
    // (SELF.fetch, no direct DO binding).
    const init = await pairInit();
    const resetRes = await SELF.fetch(`${BASE}/session/${init.session_id}/init`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session_id: init.session_id }),
    });
    expect(resetRes.status).toBe(404);

    // The original pairing_code was never touched — a legitimate claim
    // against it still succeeds.
    const claim = await wsUpgrade(init.session_id, `pairing_code=${init.pairing_code}`);
    expect(claim.status).toBe(101);
    claim.webSocket?.accept();
    claim.webSocket?.close();
  });
});
