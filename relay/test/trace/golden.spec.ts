// Wave-3 golden protocol transcript: a deterministic, seeded scripted client
// pair (fake "hmd" via the /stream + /frames endpoints, fake "phone" via the
// /ws WebSocket) drives a full pairing -> bound -> N-frames-each-way ->
// revoke transcript against the real Worker, for seeds 1..5 with seeded
// interleavings of which side (hmd/phone) acts next. The canonical
// (name-keyed, not execution-order-keyed) trace must be byte-identical
// across all five seeds and against the committed golden.json below —
// "identical modulo the seed-dependent order fields" is satisfied by
// recording `executionOrder` as its own separate, expected-to-vary field,
// never mixed into the per-step observables that must match.
//
// golden.json starts as a placeholder and is regenerated for real via
// `TRACE_UPDATE=1 npm --prefix relay run test:trace` (see
// relay/scripts/trace-diff.mjs) — that outer, plain-Node script spawns this
// spec file, scrapes the canonical trace this test always prints between
// the ###GOLDEN_TRACE_START###/###GOLDEN_TRACE_END### markers below, and
// writes it to disk. Printing unconditionally (rather than gating on an
// env var read inside this file) sidesteps needing `process.env` to exist
// inside the vitest-pool-workers/workerd sandbox at all — this file has
// exactly one behavior, always.
import { afterEach, describe, expect, it } from "vitest";
import {
  claimDevice,
  fixtureText,
  makeEnvelope,
  nextCloseCode,
  nextMessage,
  openStream,
  pairInit,
  postFrame,
  readOneLine,
  revoke,
} from "./helpers";
import { mulberry32, riffleMerge } from "./prng";
import golden from "./golden.json";

const SEEDS = [1, 2, 3, 4, 5];
const FRAMES_EACH_WAY = 3;

interface TranscriptResult {
  trace: Record<string, unknown>;
  executionOrder: string[];
}

// Backstop for every stream this file opens (`openStream`, below): each call
// registers its own `close` here as soon as it's opened, and `afterEach`
// drains the list unconditionally. `runTranscript`'s own try/finally already
// releases its stream in the normal case (including a thrown assertion
// mid-loop) — this only matters if some future edit adds a path that opens
// a stream without its own try/finally; `close()` is idempotent
// (helpers.ts), so redundant calls here are harmless no-ops.
const openStreamCloses: Array<() => Promise<void>> = [];

afterEach(async () => {
  const closes = openStreamCloses.splice(0);
  for (const close of closes) {
    await close();
  }
});

/** Sorts object keys recursively (arrays keep their own order — order is the
 * whole point of `executionOrder`). Plain JS objects preserve insertion
 * order under JSON.stringify, so without this, two seeds' `trace` objects —
 * whose keys are inserted in that seed's own (seed-dependent, by design)
 * execution order — would serialize to different strings even when every
 * field matches. This is what makes "identical modulo the seed-dependent
 * order field" true of the STRING comparison below, not just of the data. */
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === "object") {
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      sorted[key] = canonicalize((value as Record<string, unknown>)[key]);
    }
    return sorted;
  }
  return value;
}

async function runTranscript(seed: number): Promise<TranscriptResult> {
  const trace: Record<string, unknown> = {};

  const init = await pairInit();
  trace.pair_init = { status: 200 };

  const { socket } = await claimDevice(init.session_id, init.pairing_code);
  trace.claim = { status: 101 };

  const bound = await nextMessage(socket);
  const boundPayload = bound.payload as { device_token: string; exp: number };
  trace.device_bound = {
    type: bound.type,
    sender: bound.sender,
    nonce: bound.nonce,
    ciphertext: bound.ciphertext,
    has_device_token: typeof boundPayload.device_token === "string" && boundPayload.device_token.length > 0,
    has_exp: typeof boundPayload.exp === "number",
  };

  const { reader, close } = await openStream(init.session_id, init.relay_session_token);
  openStreamCloses.push(close);
  // The stream wraps a long-lived response body. The relay now closes it
  // server-side on revoke (relay/src/session.ts's handleRevoke), which every
  // seed below reaches — but never releasing this end too still leaks an
  // open connection per seed (5 across this one test): vitest-pool-workers
  // waits for the workerd isolate to quiesce before/after running another
  // test file in the same run, so a leaked reader hangs that transition
  // indefinitely. try/finally (not just a trailing call) so a thrown
  // assertion mid-loop still releases it; this file's `afterEach` above is a
  // second backstop.
  try {
    const hmdActions = Array.from({ length: FRAMES_EACH_WAY }, (_, idx) => `hmd_frame_${idx + 1}`);
    const phoneActions = Array.from({ length: FRAMES_EACH_WAY }, (_, idx) => `phone_frame_${idx + 1}`);
    const random = mulberry32(seed);
    const executionOrder = riffleMerge(hmdActions, phoneActions, random);

    // Actions run strictly sequentially (never raced/concurrent) — each is
    // awaited to completion before the next starts, so "varying the order
    // phone/hmd act" only ever changes WHICH action runs next, never
    // introduces a timing race. This also keeps the "arm the WS/stream
    // listener before the send that triggers it" discipline trivially true
    // (documented gotcha, relay/test/worker.spec.ts): each branch below arms
    // its listener/read immediately before its own triggering send.
    for (const action of executionOrder) {
      const [side, , indexStr] = action.split("_");
      const i = Number(indexStr);
      if (side === "hmd") {
        const envelope = makeEnvelope({
          session_id: init.session_id,
          type: "state",
          seq: i,
          nonce: fixtureText("golden-nonce", seed, i),
          ciphertext: fixtureText("golden-state-ciphertext", seed, i),
        });
        const nextFrame = nextMessage(socket);
        const res = await postFrame(init.session_id, init.relay_session_token, envelope);
        const body = await res.json();
        const received = await nextFrame;
        trace[action] = {
          post_status: res.status,
          post_body: body,
          received: { type: received.type, sender: received.sender, seq: received.seq },
        };
      } else {
        const envelope = makeEnvelope({
          session_id: init.session_id,
          sender: "device",
          type: "command",
          seq: i,
          nonce: fixtureText("golden-nonce-device", seed, i),
          ciphertext: fixtureText("golden-command-ciphertext", seed, i),
        });
        socket.send(JSON.stringify(envelope));
        const received = await readOneLine(reader);
        trace[action] = {
          received: { type: received.type, sender: received.sender, seq: received.seq },
        };
      }
    }

    const closeCodePromise = nextCloseCode(socket);
    const revokeRes = await revoke(init.session_id, init.relay_session_token);
    const revokeBody = await revokeRes.json();
    trace.revoke = { status: revokeRes.status, body: revokeBody };
    trace.revoke_close = { code: await closeCodePromise };

    return { trace, executionOrder };
  } finally {
    await close();
  }
}

describe("golden protocol transcript (seeds 1..5)", () => {
  it("is deterministic across seeds and matches the frozen golden transcript", async () => {
    // Sequential, not Promise.all: each seed's transcript is independent
    // (its own session_id), but running them one at a time keeps this test
    // trivially easy to reason about/debug — no benefit to parallelizing a
    // handful of small scripted transcripts.
    const results: Record<number, TranscriptResult> = {};
    for (const seed of SEEDS) {
      results[seed] = await runTranscript(seed);
    }

    const canonicalStrings = SEEDS.map((seed) => JSON.stringify(canonicalize(results[seed]?.trace)));
    for (const s of canonicalStrings.slice(1)) {
      expect(s).toBe(canonicalStrings[0]);
    }

    // The interleaving actually varied across seeds — otherwise "seeded
    // interleaving" would be an untested/vacuous claim.
    const distinctOrders = new Set(SEEDS.map((seed) => JSON.stringify(results[seed]?.executionOrder)));
    expect(distinctOrders.size).toBeGreaterThan(1);

    const canonicalTrace = results[SEEDS[0] as number]?.trace;
    console.log("###GOLDEN_TRACE_START###");
    console.log(JSON.stringify(canonicalize(canonicalTrace), null, 2));
    console.log("###GOLDEN_TRACE_END###");

    expect(canonicalTrace).toEqual(golden);
  });
});
