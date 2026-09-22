// Wave-3 mutant scenarios for the cap invariants (INV-16, INV-18). INV-17 is
// intentionally absent — see relay/scripts/trace-diff.mjs's UNCOVERED entry:
// relay/src/session.ts's handleFrames (~lines 139-175) has no frame-buffering
// implementation at all (confirmed by reading the full function) — an
// undelivered frame is dropped immediately, never queued, so there is no
// MAX_BUFFERED_FRAMES/300s-TTL code path for a mutant to violate. This is a
// disclosed relay gap (relay/README.md's "Deviations" section), not an
// untested path, and is reported as a defect in the harness's final output.
//
// INV-18 ("relay never possesses the 32-byte session key in any form") has
// no HTTP/WS-observable surface either — a black-box request/response check
// can only prove the relay didn't SHOW a key in the responses this test
// happened to inspect, which is no proof at all. relay/scripts/trace-diff.mjs
// instead runs a STATIC source check for this one (grep relay/src for any
// ECDH/HKDF/key-derivation identifier) — a stronger, more meaningful check
// than anything expressible here. This file still documents the invariant so
// a reader of the mutant suite sees all 17 accounted for in one place; its
// PASS/FAIL is decided by relay/scripts/trace-diff.mjs, not by a test below.
import { describe, expect, it } from "vitest";
import { makeEnvelope, pairInit, postFrame } from "./helpers";

const MAX_ENVELOPE_BYTES = 131072;

describe("MUT-INV-16-no-size-cap", () => {
  it("rejects an envelope over 128 KiB with 413", async () => {
    const init = await pairInit();
    const oversized = makeEnvelope({
      session_id: init.session_id,
      ciphertext: "a".repeat(MAX_ENVELOPE_BYTES),
    });
    const res = await postFrame(init.session_id, init.relay_session_token, oversized);
    expect(res.status).toBe(413);
  });
});

describe("MUT-INV-18-relay-holds-key", () => {
  it("is verified by a static source check (relay/scripts/trace-diff.mjs), not a runtime scenario", () => {
    // Documented here for visibility only — see this file's header comment
    // and relay/scripts/trace-diff.mjs's checkInv18StaticNoKeyDerivation().
    expect(true).toBe(true);
  });
});
