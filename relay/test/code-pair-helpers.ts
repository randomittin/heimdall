// Shared tooling for relay/test/code-pair.spec.ts: a fake GitHub that answers the relay's
// GitHub calls inside the test isolate, the three parties of the protocol as small client
// functions (the phone's sign-in and /pair/code, hmd's window registration), direct looks
// at Durable Object storage, and the contract file's rows as assertions.
//
// Not a spec: vitest only collects *.spec.ts / *.test.ts, so this file is imported, never run.
//
// The fake GitHub needs no network and no seam beyond `GITHUB_API_BASE`: the Worker and the
// Durable Objects run in the test's own isolate (test/hmd-socket.ts's withRelayLog relies on
// the same fact), so replacing `globalThis.fetch` for the duration of a test is seen by the
// code under test, and only calls to the fake's origin are answered -- everything else goes
// on to the real fetch.

import { env, SELF, runInDurableObject } from "cloudflare:test";
import { ed25519 } from "@noble/curves/ed25519.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { expect } from "vitest";
import contractJson from "../contract/code-pair.json";
import { base64UrlEncode } from "../src/pairing";
import { popMessage, SESSION_CODE_ALPHABET } from "../src/code-pair";
import type { Env } from "../src/types";

export const typedEnv = env as unknown as Env;

export const BASE = "https://relay-code.test";

/** Not a secret: deterministic 32-byte filler for a device's X25519 public key, the idiom
 *  worker.spec.ts uses. */
export const TEST_DEVICE_PUBKEY = base64UrlEncode(new Uint8Array(32).fill(7));

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export const nowS = (): number => Math.floor(Date.now() / 1000);

/** A source IP nobody else in the run shares. The relay keys its throttles on
 *  `CF-Connecting-IP` and the pool sends none, so every logical client names its own. */
export const freshIp = (): string => crypto.randomUUID();

// --------------------------------------------------------------------------------------------
// The contract file, as assertions
// --------------------------------------------------------------------------------------------

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Live = Record<string, Json>;

interface Row {
  status: number;
  headers?: Record<string, string>;
  body: Json;
}
interface Binding {
  match?: string;
  type?: string;
  example?: Json;
}
interface Route {
  request: { method: string; path: string; headers?: Record<string, string>; body?: Json };
  responses: Record<string, Row>;
}
interface Contract {
  bindings: Record<string, Binding>;
  identity_github: Route;
  session_code: Route;
  pair_code: Route;
  identity_revoke: Route;
  shared: { responses: Record<string, Row> };
  frames: {
    device_bound_to_hmd_code: { envelope: Json };
    device_bound_to_hmd_qr: { envelope: Json };
    key_reveal: { envelope: Json; responses: Record<string, Row> };
  };
}

export const contract = contractJson as unknown as Contract;

function rowFor(key: string): Row {
  const [first, second, third] = key.split(".");
  let row: Row | undefined;
  if (first === "frames" && second === "key_reveal") row = contract.frames.key_reveal.responses[third ?? ""];
  else if (first === "shared") row = contract.shared.responses[second ?? ""];
  else row = (contract as unknown as Record<string, Route>)[first ?? ""]?.responses[second ?? ""];
  if (!row) throw new Error(`the contract has no row ${key}`);
  return row;
}

/** Every row key the contract defines for these routes and frames, e.g. `pair_code.no_window`. */
export function allRowKeys(): string[] {
  const keys: string[] = [];
  for (const route of ["identity_github", "session_code", "pair_code", "identity_revoke"] as const) {
    for (const id of Object.keys(contract[route].responses)) keys.push(`${route}.${id}`);
  }
  for (const id of Object.keys(contract.shared.responses)) keys.push(`shared.${id}`);
  for (const id of Object.keys(contract.frames.key_reveal.responses)) keys.push(`frames.key_reveal.${id}`);
  keys.push("frames.device_bound_to_hmd_code", "frames.device_bound_to_hmd_qr");
  return keys;
}

/** The rows a test has asserted against: the spec's last test fails if one was never reached. */
export const covered = new Set<string>();

/** An actual value against a contract template. A `$binding` that is live is compared to the
 *  live value, otherwise to its pattern; every other leaf is equal, and objects have exactly
 *  the template's keys -- an extra or a missing field is a contract change. */
export function expectMatch(actual: unknown, template: Json, live: Live, path: string): void {
  if (typeof template === "string") {
    const whole = /^\$([a-z_0-9]+)$/.exec(template);
    if (!whole) {
      expect(actual, path).toBe(template);
      return;
    }
    const name = whole[1] as string;
    if (name in live) {
      expect(actual, `${path} ($${name})`).toEqual(live[name]);
      return;
    }
    const binding = contract.bindings[name];
    if (!binding) throw new Error(`the contract names an unbound $${name}`);
    if (binding.type === "integer") expect(Number.isInteger(actual), `${path} ($${name}) is an integer`).toBe(true);
    if (binding.match !== undefined) {
      expect(String(actual), `${path} ($${name})`).toMatch(new RegExp(binding.match));
    } else {
      expect(typeof actual, `${path} ($${name}) is a string`).toBe("string");
    }
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

/** Asserts `res` is exactly the contract row `rowKey` (status, headers it lists, body) and
 *  returns the parsed body. */
export async function expectRow(res: Response, rowKey: string, live: Live = {}): Promise<Record<string, unknown>> {
  const row = rowFor(rowKey);
  covered.add(rowKey);
  expect(res.status, `${rowKey}: status`).toBe(row.status);
  for (const [name, value] of Object.entries(row.headers ?? {})) {
    expect(res.headers.get(name), `${rowKey}: header ${name}`).toBe(value);
  }
  const body = (await res.json()) as Record<string, unknown>;
  expectMatch(body, row.body, live, rowKey);
  return body;
}

/** A response, flattened so two can be compared whole: status, every header but the ones the
 *  platform stamps per response, and the body text. */
export async function snapshot(res: Response): Promise<{ status: number; headers: [string, string][]; body: string }> {
  const headers = [...res.headers.entries()]
    .filter(([name]) => !["date", "content-length"].includes(name.toLowerCase()))
    .sort(([a], [b]) => a.localeCompare(b));
  return { status: res.status, headers, body: await res.text() };
}

// --------------------------------------------------------------------------------------------
// A fake GitHub
// --------------------------------------------------------------------------------------------

export interface FakeUser {
  id: number;
  login: string;
}

export type FakeKind = "user" | "check" | "delete";

export interface RecordedCall {
  kind: FakeKind | null;
  method: string;
  path: string;
  authorization: string | null;
  userAgent: string | null;
  body: Record<string, unknown> | null;
  /** The relay attached an abort signal to the call, i.e. it bounds how long it will wait. */
  hasSignal: boolean;
}

type Reply = (request: Request, signal: AbortSignal | null) => Response | Promise<Response>;

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** Answers the three GitHub endpoints the relay uses -- `GET /user`, the check-token call and
 *  the delete-token call -- from tables of tokens a test mints, records every call it
 *  receives, and can be told to fail the next call of a kind in the ways GitHub does. */
export class FakeGitHub {
  readonly calls: RecordedCall[] = [];
  private readonly phoneTokens = new Map<string, { user: FakeUser; app: string }>();
  private readonly laptopTokens = new Map<string, FakeUser>();
  private readonly queued = new Map<FakeKind, Reply[]>();
  private original: typeof fetch | null = null;

  private get origin(): string {
    return typedEnv.GITHUB_API_BASE as string;
  }

  /** Starts answering. Idempotent. */
  install(): void {
    if (this.original) return;
    const original = globalThis.fetch;
    this.original = original;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      if (!request.url.startsWith(`${this.origin}/`)) return original(input, init);
      return this.answer(request, init?.signal ?? null);
    }) as typeof fetch;
  }

  /** Puts the real fetch back and forgets everything. */
  uninstall(): void {
    if (this.original) globalThis.fetch = this.original;
    this.original = null;
    this.calls.length = 0;
    this.phoneTokens.clear();
    this.laptopTokens.clear();
    this.queued.clear();
  }

  /** A token the device flow would have issued to `app` (default: the relay's own App) for `user`. */
  phoneToken(user: FakeUser, app: string = typedEnv.GITHUB_CLIENT_ID as string): string {
    const token = `ghu_test_${crypto.randomUUID()}`;
    this.phoneTokens.set(token, { user, app });
    return token;
  }

  /** A token `gh auth token` would print for `user`. */
  laptopToken(user: FakeUser): string {
    const token = `gho_test_${crypto.randomUUID()}`;
    this.laptopTokens.set(token, user);
    return token;
  }

  isPhoneTokenLive(token: string): boolean {
    return this.phoneTokens.has(token);
  }

  callsOf(kind: FakeKind): RecordedCall[] {
    return this.calls.filter((call) => call.kind === kind);
  }

  /** The next call of `kind` is answered with `status` and `body` (JSON) instead. */
  respondOnce(kind: FakeKind, status: number, body: unknown = {}): void {
    this.queue(kind, () => json(status, body));
  }

  /** The next call of `kind` fails the way a dropped connection does. */
  networkErrorOnce(kind: FakeKind): void {
    this.queue(kind, () => {
      throw new TypeError("fetch failed");
    });
  }

  /** The next call of `kind` is never answered; it ends only when the relay's own timeout
   *  aborts it, and that is what the caller observes. */
  hangOnce(kind: FakeKind): void {
    this.queue(
      kind,
      (_request, signal) =>
        new Promise<Response>((_resolve, reject) => {
          if (!signal) return;
          signal.addEventListener("abort", () => reject(signal.reason));
        })
    );
  }

  private queue(kind: FakeKind, reply: Reply): void {
    this.queued.set(kind, [...(this.queued.get(kind) ?? []), reply]);
  }

  private kindOf(method: string, path: string): FakeKind | null {
    if (method === "GET" && path === "/user") return "user";
    if (/^\/applications\/[^/]+\/token$/.test(path)) {
      if (method === "POST") return "check";
      if (method === "DELETE") return "delete";
    }
    return null;
  }

  private async answer(request: Request, signal: AbortSignal | null): Promise<Response> {
    const url = new URL(request.url);
    const kind = this.kindOf(request.method, url.pathname);
    const raw = await request.text();
    let body: Record<string, unknown> | null = null;
    if (raw) {
      try {
        body = JSON.parse(raw) as Record<string, unknown>;
      } catch {
        body = null;
      }
    }
    this.calls.push({
      kind,
      method: request.method,
      path: url.pathname,
      authorization: request.headers.get("authorization"),
      userAgent: request.headers.get("user-agent"),
      body,
      hasSignal: signal !== null,
    });

    const reply = kind === null ? undefined : this.queued.get(kind)?.shift();
    if (reply) return reply(request, signal);

    if (kind === "user") {
      const user = this.laptopTokens.get((request.headers.get("authorization") ?? "").replace(/^Bearer /, ""));
      return user ? json(200, { login: user.login, id: user.id }) : json(401, { message: "Bad credentials" });
    }
    if (kind === "check" || kind === "delete") {
      const clientId = decodeURIComponent(url.pathname.split("/")[2] ?? "");
      const basic = `Basic ${btoa(`${typedEnv.GITHUB_CLIENT_ID}:${typedEnv.GITHUB_CLIENT_SECRET}`)}`;
      if (request.headers.get("authorization") !== basic) return json(401, { message: "Bad credentials" });
      const token = typeof body?.access_token === "string" ? body.access_token : "";
      const entry = this.phoneTokens.get(token);
      if (!entry || entry.app !== clientId) return json(404, { message: "Not Found" });
      if (kind === "delete") {
        this.phoneTokens.delete(token);
        return new Response(null, { status: 204 });
      }
      return json(200, {
        id: 1,
        token,
        app: { client_id: entry.app, name: "hmd", url: "https://example.invalid" },
        user: { login: entry.user.login, id: entry.user.id },
      });
    }
    return json(404, { message: "Not Found" });
  }
}

// --------------------------------------------------------------------------------------------
// People and sessions
// --------------------------------------------------------------------------------------------

/** A GitHub user nobody else in the run is, with an id that cannot be mistaken for a clock. */
export function newUser(): FakeUser {
  return { id: 100_000_000 + Math.floor(Math.random() * 900_000_000), login: `octo-${crypto.randomUUID().slice(0, 8)}` };
}

export function randomCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(5));
  return Array.from(bytes, (b) => SESSION_CODE_ALPHABET[b % SESSION_CODE_ALPHABET.length]).join("");
}

export interface Phone {
  /** The Ed25519 seed of the install key: only the phone holds it. */
  seed: Uint8Array;
  /** Its public half, unpadded base64url: what `/identity/github` binds the assertion to. */
  pub: string;
}

export function newPhone(): Phone {
  const seed = crypto.getRandomValues(new Uint8Array(32));
  return { seed, pub: base64UrlEncode(ed25519.getPublicKey(seed)) };
}

/** The proof of possession the phone sends with a code: the install key's signature over
 *  the contract's message. */
export function popSig(phone: Phone, code: string, ts: number): string {
  return base64UrlEncode(ed25519.sign(popMessage(code, ts), phone.seed));
}

export interface Identity {
  phone: Phone;
  user: FakeUser;
  assertion: string;
}

/** The phone signs in: a real `POST /identity/github` against the fake GitHub. */
export async function signIn(fake: FakeGitHub, user: FakeUser = newUser(), phone: Phone = newPhone()): Promise<Identity> {
  const res = await SELF.fetch(`${BASE}/identity/github`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": freshIp() },
    body: JSON.stringify({ gh_token: fake.phoneToken(user), install_pubkey: phone.pub }),
  });
  expect(res.status, "sign-in").toBe(200);
  const body = (await res.json()) as { gh_assertion: string };
  return { phone, user, assertion: body.gh_assertion };
}

export interface PairInit {
  session_id: string;
  pairing_code: string;
  relay_session_token: string;
  exp: number;
}

export async function pairInit(): Promise<PairInit> {
  const res = await SELF.fetch(`${BASE}/pair/init`, { method: "POST", headers: { "CF-Connecting-IP": freshIp() } });
  expect(res.status).toBe(200);
  return (await res.json()) as PairInit;
}

export interface Commitment {
  commit: string;
  hmdPub: string;
  nonce: string;
}

/** hmd's side of the commitment, computed the way the spec says: an opaque 32-byte value to
 *  the relay, but a real one here so a test can check the phone's half end to end. */
export function newCommitment(): Commitment {
  const hmdPub = crypto.getRandomValues(new Uint8Array(32));
  const nonce = crypto.getRandomValues(new Uint8Array(32));
  const domain = new TextEncoder().encode("hmd-pair-commit-v1\0");
  const input = new Uint8Array(domain.length + 64);
  input.set(domain, 0);
  input.set(hmdPub, domain.length);
  input.set(nonce, domain.length + 32);
  return { commit: base64UrlEncode(sha256(input)), hmdPub: base64UrlEncode(hmdPub), nonce: base64UrlEncode(nonce) };
}

export interface WindowRequest {
  code?: unknown;
  gh_token?: unknown;
  hmd_commit?: unknown;
  bearer?: string;
}

/** hmd registers a window: `POST /session/:id/code` with the session's bearer. */
export function registerWindow(init: PairInit, body: WindowRequest): Promise<Response> {
  const { bearer = init.relay_session_token, ...fields } = body;
  return SELF.fetch(`${BASE}/session/${init.session_id}/code`, {
    method: "POST",
    headers: { Authorization: `Bearer ${bearer}`, "content-type": "application/json" },
    body: JSON.stringify(fields),
  });
}

export interface OpenWindow {
  init: PairInit;
  code: string;
  commitment: Commitment;
  ghToken: string;
}

/** A session with a registered window for `user`: `/pair/init`, then the laptop's registration. */
export async function openWindow(fake: FakeGitHub, user: FakeUser, code: string = randomCode()): Promise<OpenWindow> {
  const init = await pairInit();
  const commitment = newCommitment();
  const ghToken = fake.laptopToken(user);
  const res = await registerWindow(init, { code, gh_token: ghToken, hmd_commit: commitment.commit });
  expect(res.status, "window registration").toBe(200);
  return { init, code, commitment, ghToken };
}

export interface PairCodeOptions {
  ts?: unknown;
  sig?: unknown;
  device_label?: unknown;
  ip?: string;
  /** Replaces the whole body when a test needs a shape the typed fields cannot make. */
  rawBody?: string;
}

/** `POST /pair/code`, correctly signed unless the options say otherwise. */
export function pairCode(identity: Identity, code: string, options: PairCodeOptions = {}): Promise<Response> {
  const ts = "ts" in options ? options.ts : nowS();
  const body = options.rawBody ?? JSON.stringify({
    code,
    gh_assertion: identity.assertion,
    ts,
    sig: "sig" in options ? options.sig : popSig(identity.phone, code, ts as number),
    device_label: "device_label" in options ? options.device_label : "Pixel 9a",
  });
  return SELF.fetch(`${BASE}/pair/code`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": options.ip ?? freshIp() },
    body,
  });
}

export interface PhoneSocket {
  socket: WebSocket;
  /** The next message, or null when none comes within `withinMs`. */
  next(withinMs?: number): Promise<Record<string, unknown> | null>;
}

/** An accepted phone-leg upgrade as a queue of parsed messages, in arrival order. */
async function phoneSocket(upgrade: Response): Promise<PhoneSocket> {
  expect(upgrade.status).toBe(101);
  const socket = upgrade.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  const queue: Record<string, unknown>[] = [];
  let wake: (() => void) | null = null;
  socket.addEventListener("message", (event) => {
    queue.push(JSON.parse((event as unknown as { data: string }).data) as Record<string, unknown>);
    wake?.();
  });
  return {
    socket,
    next: async (withinMs = 2000) => {
      const deadline = Date.now() + withinMs;
      while (queue.length === 0) {
        const left = deadline - Date.now();
        if (left <= 0) return null;
        await new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, left);
          wake = () => {
            clearTimeout(timer);
            resolve();
          };
        });
      }
      return queue.shift() as Record<string, unknown>;
    },
  };
}

/** The phone opens the claim socket with what `/pair/code` released, as after a QR scan. */
export async function claimSocket(
  sessionId: string,
  pairingCode: string,
  devicePubkey: string = TEST_DEVICE_PUBKEY
): Promise<PhoneSocket> {
  return phoneSocket(
    await SELF.fetch(`${BASE}/session/${sessionId}/ws?pairing_code=${pairingCode}&device_pubkey=${devicePubkey}`, {
      headers: { Upgrade: "websocket" },
    })
  );
}

/** The phone comes back with its device_token, as after a dropped connection. */
export async function reconnectSocket(
  sessionId: string,
  deviceToken: string,
  devicePubkey: string = TEST_DEVICE_PUBKEY
): Promise<PhoneSocket> {
  return phoneSocket(
    await SELF.fetch(
      `${BASE}/session/${sessionId}/ws?device_token=${encodeURIComponent(deviceToken)}&device_pubkey=${devicePubkey}`,
      { headers: { Upgrade: "websocket" } }
    )
  );
}

/** hmd's NDJSON `GET /stream`: lines parsed in order, keepalives (wall-clock) set aside. */
export class HmdLines {
  private buffer = "";
  private pending: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;

  private constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  static async open(init: PairInit): Promise<HmdLines> {
    const res = await SELF.fetch(`${BASE}/session/${init.session_id}/stream`, {
      headers: { Authorization: `Bearer ${init.relay_session_token}` },
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    if (!reader) throw new Error("the stream has no body");
    return new HmdLines(reader);
  }

  /** The next frame that is not a keepalive, or null when none arrives within `withinMs`. The
   *  one outstanding read is kept across calls, so a timeout never swallows a later chunk. */
  async next(withinMs = 3000): Promise<Record<string, unknown> | null> {
    const deadline = Date.now() + withinMs;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) {
        const line = this.buffer.slice(0, newline).trim();
        this.buffer = this.buffer.slice(newline + 1);
        if (line.length === 0) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        if (frame.type === "keepalive") continue;
        return frame;
      }
      const left = deadline - Date.now();
      if (left <= 0) return null;
      this.pending ??= this.reader.read();
      const result = await Promise.race([this.pending, sleep(left).then(() => null)]);
      if (result === null) return null;
      this.pending = null;
      if (result.done || !result.value) return null;
      this.buffer += new TextDecoder().decode(result.value);
    }
  }

  async close(): Promise<void> {
    try {
      await this.reader.cancel();
    } catch {
      // already closed server-side
    }
  }
}

/** hmd posts one frame: `POST /session/:id/frames` with the session's bearer. */
export function postHmdFrame(init: PairInit, envelope: unknown, bearer: string = init.relay_session_token): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${init.session_id}/frames`, {
    method: "POST",
    headers: { Authorization: `Bearer ${bearer}`, "content-type": "application/json" },
    body: JSON.stringify(envelope),
  });
}

/** hmd's `key_reveal` envelope, shaped as the contract says. */
export function keyRevealEnvelope(init: PairInit, commitment: Commitment): Record<string, unknown> {
  return {
    v: 1,
    session_id: init.session_id,
    seq: 0,
    sender: "hmd",
    type: "key_reveal",
    nonce: null,
    ciphertext: null,
    payload: { hmd_pubkey: commitment.hmdPub, nonce: commitment.nonce },
  };
}

export async function revokeSession(init: PairInit): Promise<Response> {
  return SELF.fetch(`${BASE}/session/${init.session_id}/revoke`, {
    method: "POST",
    headers: { Authorization: `Bearer ${init.relay_session_token}` },
  });
}

// --------------------------------------------------------------------------------------------
// Looking at Durable Object storage
// --------------------------------------------------------------------------------------------

export const sessionStub = (sessionId: string): DurableObjectStub =>
  typedEnv.SESSION.get(typedEnv.SESSION.idFromName(sessionId));

export const indexStub = (ghId: number): DurableObjectStub =>
  typedEnv.SESSION.get(typedEnv.SESSION.idFromName(`code-index:${ghId}`));

export interface StoredWindow {
  code: string;
  owner_gh_id: number;
  hmd_commit: string;
  released: boolean;
  device_label?: string;
  gh_login?: string;
}

export interface StoredRecord {
  status: string;
  pair_exp: number;
  code_window?: StoredWindow;
}

export function storedRecord(sessionId: string): Promise<StoredRecord | undefined> {
  return runInDurableObject(sessionStub(sessionId), (_instance, state) => state.storage.get<StoredRecord>("state"));
}

export interface StoredIndex {
  codes: Record<string, { session_id: string; exp: number }>;
  not_before?: number;
  miss_streak: number[];
  attempts: number[];
}

export function storedIndex(ghId: number): Promise<StoredIndex | undefined> {
  return runInDurableObject(indexStub(ghId), (_instance, state) => state.storage.get<StoredIndex>("code_index"));
}

/** Everything one Durable Object holds, serialized, for a test that asserts a value is not in it. */
export function dumpStorage(stub: DurableObjectStub): Promise<string> {
  return runInDurableObject(stub, async (_instance, state) => JSON.stringify([...(await state.storage.list()).entries()]));
}

/** The session's pairing window has lapsed, though nothing has noticed yet. */
export function lapseSession(sessionId: string): Promise<void> {
  return runInDurableObject(sessionStub(sessionId), async (_instance, state) => {
    const record = (await state.storage.get<StoredRecord>("state")) as StoredRecord;
    record.pair_exp = Date.now() - 1000;
    await state.storage.put("state", record);
  });
}

/** The index entry for `code` has lapsed, though the session behind it has not. */
export function lapseIndexEntry(ghId: number, code: string): Promise<void> {
  return runInDurableObject(indexStub(ghId), async (_instance, state) => {
    const index = (await state.storage.get<StoredIndex>("code_index")) as StoredIndex;
    const entry = index.codes[code];
    if (!entry) throw new Error("no such index entry to lapse");
    entry.exp = Date.now() - 1000;
    await state.storage.put("code_index", index);
  });
}

/** The index-to-session call, made directly: the layer a mutant in the session's own
 *  checks would hide behind the index's. Internal, never public. */
export function directRelease(
  sessionId: string,
  body: { gh_id: number; gh_login?: string; code: string; device_label?: string }
): Promise<Response> {
  return sessionStub(sessionId).fetch("http://do-internal/code-release", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ gh_login: "octocat", device_label: "Pixel 9a", ...body }),
  });
}
