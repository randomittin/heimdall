// The relay's side of the shared wire contract (relay/contract/wire.json). The same file is
// replayed against the real hmd client by heimdall's test/relay-contract-fixtures.test.sh, and its
// sealed frames are opened with the JS crypto by scripts/__tests__/contract-fixtures.test.mjs.
//
// Here the real Worker + Durable Object (the workerd pool, no mocks) is driven exactly as the
// fixture says clients drive it, and what it answers must match the fixture: relay-minted values
// by pattern, everything a client or the phone sends passed through byte for byte. If the relay
// changes a shape, a status, a header or a close code this file fails, and so the change has to be
// made in the fixture -- which the hmd client's replay then checks from the other side.
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import wireJson from "../contract/wire.json";
import vectors from "../contract/vectors.json";
import { base64UrlEncode } from "../src/pairing";
import { BASE, nextCloseCode, wsUpgrade } from "./trace/helpers";

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Obj = { [key: string]: Json };

interface Binding {
  match?: string;
  type?: string;
  example?: Json;
  computed?: string;
}
interface RequestTemplate {
  method?: string;
  path: string;
  headers?: Record<string, string>;
  query?: Record<string, string>;
  body?: string;
}
interface Frame {
  direction: string;
  plaintext: Json;
  wire: Obj;
}
interface Wire {
  bindings: Record<string, Binding>;
  pair_init: { request: RequestTemplate; response: { status: number; content_type: string; body: Json } };
  stream: { request: RequestTemplate; response: { status: number; content_type: string }; lines: Record<string, Json> };
  phone: {
    claim: RequestTemplate & { status: number };
    device_bound: Json;
    revoked: { session_ended: Json; close_code: number };
  };
  frames_post: {
    request: RequestTemplate;
    response_delivered: { status: number; body: Json };
    response_undelivered: { status: number; body: Json };
  };
  revoke: { request: RequestTemplate; response: { status: number; body: Json } };
  frames: Record<string, Frame>;
}

const wire = wireJson as unknown as Wire;

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** A `computed` binding: derived from vectors.json, never stored in the fixture. The device's
 *  public key as the phone sends it in its claim and the relay forwards it, base64url. */
const COMPUTED: Record<string, string> = {
  device_pubkey_b64url: base64UrlEncode(hexToBytes(vectors.phnPublicKeyHex)),
};

type Live = Record<string, Json>;

function bound(name: string, live: Live): Json {
  if (name in live) return live[name] as Json;
  const binding = wire.bindings[name];
  if (!binding) throw new Error(`fixture names an unbound $${name}`);
  if (binding.computed !== undefined) return COMPUTED[binding.computed] as string;
  return binding.example as Json;
}

/** Fills `$name` placeholders. A string that is exactly one placeholder keeps the value's type. */
function fill<T extends Json | RequestTemplate>(node: T, live: Live): T {
  const walk = (n: Json | undefined): Json => {
    if (typeof n === "string") {
      const whole = /^\$([a-z_]+)$/.exec(n);
      if (whole) return bound(whole[1] as string, live);
      return n.replace(/\$([a-z_]+)/g, (_m, name: string) => String(bound(name, live)));
    }
    if (Array.isArray(n)) return n.map(walk);
    if (n !== null && typeof n === "object") {
      return Object.fromEntries(Object.entries(n).map(([k, v]) => [k, walk(v)]));
    }
    return n as Json;
  };
  return walk(node as unknown as Json) as unknown as T;
}

/** The relay is the producer: a placeholder is checked against its binding (the live value when
 *  one is known, else the pattern); every other leaf must be equal, and objects must have exactly
 *  the template's keys -- an extra or a missing field is a contract change. */
function expectMatch(actual: unknown, template: Json, live: Live, path = "$"): void {
  if (typeof template === "string") {
    const whole = /^\$([a-z_]+)$/.exec(template);
    if (!whole) {
      expect(actual, path).toBe(template);
      return;
    }
    const name = whole[1] as string;
    if (name in live || wire.bindings[name]?.computed !== undefined) {
      expect(actual, `${path} ($${name})`).toBe(bound(name, live));
      return;
    }
    const binding = wire.bindings[name] as Binding;
    if (binding.type === "integer") expect(Number.isInteger(actual), `${path} ($${name}) is an integer`).toBe(true);
    expect(String(actual), `${path} ($${name})`).toMatch(new RegExp(binding.match as string));
    return;
  }
  if (Array.isArray(template)) {
    expect(Array.isArray(actual), path).toBe(true);
    expect((actual as unknown[]).length, `${path} length`).toBe(template.length);
    template.forEach((item, i) => expectMatch((actual as unknown[])[i], item, live, `${path}[${i}]`));
    return;
  }
  if (template !== null && typeof template === "object") {
    expect(typeof actual === "object" && actual !== null && !Array.isArray(actual), `${path} is an object`).toBe(true);
    const got = actual as Record<string, unknown>;
    expect(Object.keys(got).sort(), `${path} keys`).toEqual(Object.keys(template).sort());
    for (const [key, item] of Object.entries(template)) expectMatch(got[key], item, live, `${path}.${key}`);
    return;
  }
  expect(actual, path).toBe(template);
}

/** fetch() forbids setting Content-Length itself; the runtime derives it from the body. */
const SKIPPED_HEADERS = new Set(["content-length"]);

function send(template: RequestTemplate, live: Live, body?: Json): Promise<Response> {
  const req = fill(template, live);
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(req.headers ?? {})) {
    if (!SKIPPED_HEADERS.has(name.toLowerCase())) headers[name] = value;
  }
  // /pair/init is throttled per source IP and the pool sends none: give each logical client its own.
  if (req.path === "/pair/init") headers["CF-Connecting-IP"] = crypto.randomUUID();
  return SELF.fetch(`${BASE}${req.path}`, {
    method: req.method ?? "GET",
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

interface Session {
  live: Live;
}

async function pairInit(): Promise<Session> {
  const res = await send(wire.pair_init.request, {});
  expect(res.status).toBe(wire.pair_init.response.status);
  const body = (await res.json()) as Record<string, Json>;
  return {
    live: {
      session_id: body.session_id as Json,
      pairing_code: body.pairing_code as Json,
      relay_session_token: body.relay_session_token as Json,
    },
  };
}

/** NDJSON off hmd's stream, one parsed frame at a time, tolerant of the runtime coalescing writes. */
class Lines {
  private buffer = "";
  constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  async next(): Promise<Record<string, unknown>> {
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        if (line.trim().length > 0) return JSON.parse(line) as Record<string, unknown>;
        continue;
      }
      const { value, done } = await this.reader.read();
      if (done || !value) throw new Error("hmd stream ended while a frame was expected");
      this.buffer += new TextDecoder().decode(value);
    }
  }

  /** The next frame that is not a keepalive: keepalives are wall-clock and may land anywhere. */
  async nextData(): Promise<Record<string, unknown>> {
    for (;;) {
      const frame = await this.next();
      if (frame.type !== "keepalive") return frame;
    }
  }
}

async function openStream(session: Session) {
  const res = await send(wire.stream.request, session.live);
  expect(res.status).toBe(wire.stream.response.status);
  expect(res.headers.get("content-type")).toContain(wire.stream.response.content_type);
  const reader = res.body?.getReader();
  if (!reader) throw new Error("the stream has no body");
  return { reader, lines: new Lines(reader) };
}

/** Every message the phone socket receives, in order, from the moment it is accepted. */
function inbox(socket: WebSocket): () => Promise<Record<string, unknown>> {
  const queue: Record<string, unknown>[] = [];
  let wake: (() => void) | null = null;
  socket.addEventListener("message", (event) => {
    queue.push(JSON.parse((event as unknown as { data: string }).data) as Record<string, unknown>);
    wake?.();
  });
  return async () => {
    while (queue.length === 0) await new Promise<void>((resolve) => (wake = resolve));
    return queue.shift() as Record<string, unknown>;
  };
}

describe("relay wire contract (relay/contract/wire.json)", () => {
  it("POST /pair/init answers the fixture's shape", async () => {
    const res = await send(wire.pair_init.request, {});
    expect(res.status).toBe(wire.pair_init.response.status);
    expect(res.headers.get("content-type")).toContain(wire.pair_init.response.content_type);
    expectMatch(await res.json(), wire.pair_init.response.body, {});
  });

  it("idle hmd streams carry the fixture's keepalive", async () => {
    const session = await pairInit();
    const { reader, lines } = await openStream(session);
    try {
      expectMatch(await lines.next(), wire.stream.lines.keepalive as Json, session.live);
    } finally {
      await reader.cancel();
    }
  });

  it("a whole session: claim, state/ack down, commands up, revoke -- the fixture's frames, byte for byte", async () => {
    const session = await pairInit();
    const live: Live = { ...session.live, device_pubkey: COMPUTED.device_pubkey_b64url as string };
    const postFrame = (name: string) => send(wire.frames_post.request, live, wire.frames[name]?.wire);

    // hmd posts before any phone is bound: the relay says so, and stores nothing it may not replay.
    const early = await postFrame("state");
    expect(early.status).toBe(wire.frames_post.response_undelivered.status);
    expectMatch(await early.json(), wire.frames_post.response_undelivered.body, live);

    const { reader, lines } = await openStream(session);
    let socket: WebSocket | undefined;
    try {
      // the phone claims with the fixture's query
      const claim = fill(wire.phone.claim, live);
      const query = new URLSearchParams(claim.query).toString();
      const upgrade = await wsUpgrade(session.live.session_id as string, query, claim.headers);
      expect(upgrade.status).toBe(wire.phone.claim.status);
      socket = upgrade.webSocket ?? undefined;
      if (!socket) throw new Error("expected a websocket in the 101 response");
      socket.accept();
      const phone = inbox(socket);

      expectMatch(await phone(), wire.phone.device_bound, live);
      expectMatch(await lines.nextData(), wire.stream.lines.device_bound as Json, live);

      // hmd -> phone: state and the three acks arrive exactly as posted
      for (const name of ["state", "ack_send_message", "ack_decide_allow", "ack_decide_deny"]) {
        const res = await postFrame(name);
        expect(res.status, name).toBe(wire.frames_post.response_delivered.status);
        expectMatch(await res.json(), wire.frames_post.response_delivered.body, live);
        expect(await phone(), `${name} as the phone receives it`).toEqual(wire.frames[name]?.wire);
      }

      // phone -> hmd: the three commands reach hmd's stream exactly as sent
      for (const name of ["command_send_message", "command_decide_allow", "command_decide_deny"]) {
        socket.send(JSON.stringify(wire.frames[name]?.wire));
        expect(await lines.nextData(), `${name} as hmd receives it`).toEqual(wire.frames[name]?.wire);
      }

      // revoke: the phone is told why, then closed
      const ended = phone();
      const closed = nextCloseCode(socket);
      const revoked = await send(wire.revoke.request, live, undefined);
      expect(revoked.status).toBe(wire.revoke.response.status);
      expectMatch(await revoked.json(), wire.revoke.response.body, live);
      expectMatch(await ended, wire.phone.revoked.session_ended, live);
      expect(await closed).toBe(wire.phone.revoked.close_code);
    } finally {
      await reader.cancel().catch(() => undefined);
    }
  });
});
