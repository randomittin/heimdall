// Shared tooling for relay/test/github-oauth.spec.ts: the part of GitHub the browser flow adds
// (the token endpoint, reached through the GITHUB_WEB_BASE seam), the parties' requests as small
// functions (the app's PKCE pair, the browser landing on `start` and on the callback, the app's
// redeem), direct looks at Durable Object storage, and github-oauth.json's rows as assertions.
//
// Not a spec: vitest only collects *.spec.ts / *.test.ts, so this file is imported, never run.
//
// code-pair-helpers.ts's FakeGitHub keeps answering the API calls (check-token, delete-token).
// FakeGitHubWeb sits in front of it on `globalThis.fetch` and answers only the web origin, so the two
// share one table of live tokens and a test reads one record of calls per origin. Every request that
// can answer with a redirect is made with `redirect: "manual"`: following one would leave the test.

import { SELF, listDurableObjectIds, runInDurableObject } from "cloudflare:test";
import { sha256 } from "@noble/hashes/sha2.js";
import { expect } from "vitest";
import oauthContractJson from "../contract/github-oauth.json";
import { base64UrlEncode } from "../src/pairing";
import {
  dumpStorage,
  expectMatch,
  freshIp,
  newPhone,
  newUser,
  typedEnv,
  type FakeGitHub,
  type FakeUser,
  type Json,
  type Live,
  type Phone,
} from "./code-pair-helpers";

export const OAUTH_BASE = "https://relay-oauth.test";
export const CALLBACK_URL = `${OAUTH_BASE}/identity/github/oauth/callback`;

// --------------------------------------------------------------------------------------------
// The contract file, as assertions
// --------------------------------------------------------------------------------------------

interface OauthRow {
  status: number;
  headers?: Record<string, string>;
  body?: Json;
  /** A fixed HTML page: constants.pages.template with this message in it. */
  message?: string;
  /** A redirect: the Location is `base` plus a query with exactly these parameters. */
  location?: { base: string; query: Record<string, string> };
}
interface OauthRoute {
  responses: Record<string, OauthRow>;
}
interface OauthRecord {
  instance: string;
  storage_key: string;
  fields: Record<string, Json>;
}
interface OauthContract {
  constants: { app_redirect: string; pages: { content_type: string; template: string; headers: Record<string, string> } };
  bindings: Record<string, { match?: string; type?: string; example?: Json }>;
  probe: OauthRoute;
  start: OauthRoute;
  callback: OauthRoute;
  redeem: OauthRoute;
  records: { oauth_state: OauthRecord; oauth_handoff: OauthRecord };
}

export const oauth = oauthContractJson as unknown as OauthContract;

export const APP_REDIRECT = oauth.constants.app_redirect;

const ROUTES = ["probe", "start", "callback", "redeem"] as const;

/** Every row key the contract defines, e.g. `callback.expired`. */
export function allOauthRowKeys(): string[] {
  return ROUTES.flatMap((route) => Object.keys(oauth[route].responses).map((id) => `${route}.${id}`));
}

/** The rows a test has asserted against: the spec's last test fails if one was never reached. */
export const oauthCovered = new Set<string>();

export interface Answer {
  /** The parsed JSON body of a JSON row. */
  body: Record<string, unknown> | null;
  /** The page text of a `message` row. */
  text: string | null;
  /** The Location of a redirect row. */
  location: URL | null;
}

/** Asserts `res` is exactly the contract row `rowKey`: its status, the headers the row lists, and
 *  its body, page or redirect target. `live` supplies the `$bindings` a test knows the value of. */
export async function expectOauthRow(res: Response, rowKey: string, live: Live = {}): Promise<Answer> {
  const [route, id] = rowKey.split(".");
  const row = oauth[route as (typeof ROUTES)[number]]?.responses[id ?? ""];
  if (!row) throw new Error(`the contract has no row ${rowKey}`);
  oauthCovered.add(rowKey);

  expect(res.status, `${rowKey}: status`).toBe(row.status);
  for (const [name, value] of Object.entries(row.headers ?? {})) {
    expect(res.headers.get(name), `${rowKey}: header ${name}`).toBe(value);
  }

  if (row.location) {
    const raw = res.headers.get("location");
    expect(raw, `${rowKey}: has a Location`).not.toBeNull();
    const location = new URL(raw as string);
    expectMatch(`${location.protocol}//${location.host}${location.pathname}`, row.location.base, live, `${rowKey}: location`, oauth.bindings);
    const names = [...location.searchParams.keys()];
    expect(new Set(names).size, `${rowKey}: no query parameter is repeated`).toBe(names.length);
    expectMatch(Object.fromEntries(location.searchParams), row.location.query, live, `${rowKey}: location query`, oauth.bindings);
    return { body: null, text: null, location };
  }

  if (row.message !== undefined) {
    const { pages } = oauth.constants;
    expect(res.headers.get("content-type"), `${rowKey}: content-type`).toBe(pages.content_type);
    for (const [name, value] of Object.entries(pages.headers)) {
      expect(res.headers.get(name), `${rowKey}: header ${name}`).toBe(value);
    }
    const text = await res.text();
    expect(text, `${rowKey}: the fixed page`).toBe(pages.template.replace("{message}", row.message));
    return { body: null, text, location: null };
  }

  const body = (await res.json()) as Record<string, unknown>;
  expectMatch(body, row.body as Json, live, rowKey, oauth.bindings);
  return { body, text: null, location: null };
}

/** A stored record's fields against the contract's `records` entry. */
export function expectRecord(actual: unknown, kind: "oauth_state" | "oauth_handoff", live: Live): void {
  expectMatch(actual, oauth.records[kind].fields, live, `${kind} record`, oauth.bindings);
}

// --------------------------------------------------------------------------------------------
// The app's PKCE pair, and the requests of the three parties
// --------------------------------------------------------------------------------------------

export interface Pkce {
  /** The app's state: echoed back untouched in every redirect to the app. */
  state: string;
  verifier: string;
  /** base64url(SHA-256(verifier)) -- computed here with @noble, not with the relay's WebCrypto. */
  challenge: string;
}

const random32 = (): string => base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));

/** What the app makes before it opens the browser: a state and a verifier of 32 random bytes each
 *  (43 characters), and the verifier's S256 challenge. Built at run time, never a literal. */
export function newPkce(): Pkce {
  const verifier = random32();
  return { state: random32(), verifier, challenge: base64UrlEncode(sha256(new TextEncoder().encode(verifier))) };
}

export type Pairs = [string, string][];

export const toQuery = (pairs: Pairs): string => new URLSearchParams(pairs).toString();

/** The four parameters of a valid `start`, as pairs a table can mutate. */
export const startPairs = (pkce: Pkce, phone: Phone): Pairs => [
  ["state", pkce.state],
  ["code_challenge", pkce.challenge],
  ["code_challenge_method", "S256"],
  ["install_pubkey", phone.pub],
];

export const callbackQuery = (code: string, state: string): string =>
  toQuery([
    ["code", code],
    ["state", state],
  ]);

const browser = (ip: string): RequestInit => ({ redirect: "manual", headers: { "CF-Connecting-IP": ip } });

export const probeRequest = (): Promise<Response> => SELF.fetch(`${OAUTH_BASE}/identity/github/oauth`, { redirect: "manual" });

export const startRequest = (query: string, ip: string = freshIp()): Promise<Response> =>
  SELF.fetch(`${OAUTH_BASE}/identity/github/oauth/start?${query}`, browser(ip));

export const callbackRequest = (query: string, ip: string = freshIp()): Promise<Response> =>
  SELF.fetch(`${OAUTH_BASE}/identity/github/oauth/callback?${query}`, browser(ip));

/** A string body is sent as it is, so a test can send what is not JSON. */
export function redeemRequest(body: unknown, ip: string = freshIp()): Promise<Response> {
  return SELF.fetch(`${OAUTH_BASE}/identity/github/oauth/redeem`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export interface Started {
  phone: Phone;
  pkce: Pkce;
  /** The `state` the relay put in GitHub's authorize URL: the key of the pending record. */
  relayState: string;
  authorize: URL;
}

/** The app opens the browser: a real `start`, which has to answer with the redirect to GitHub. */
export async function startFlow(phone: Phone = newPhone(), pkce: Pkce = newPkce(), ip?: string): Promise<Started> {
  const res = await startRequest(toQuery(startPairs(pkce, phone)), ip);
  expect(res.status, "start").toBe(302);
  const authorize = new URL(res.headers.get("location") as string);
  return { phone, pkce, relayState: authorize.searchParams.get("state") as string, authorize };
}

export interface Reached {
  started: Started;
  user: FakeUser;
  /** The authorization code the fake issued for `user`. */
  code: string;
  hc: string;
}

/** The browser half, done: `start`, the person signing in at GitHub (the fake issues a code), the
 *  callback -- ending with the handoff the app is redirected with. */
export async function reachHandoff(
  web: FakeGitHubWeb,
  user: FakeUser = newUser(),
  phone: Phone = newPhone(),
  pkce: Pkce = newPkce()
): Promise<Reached> {
  const started = await startFlow(phone, pkce);
  const code = web.authorizationCode(user);
  const res = await callbackRequest(callbackQuery(code, started.relayState));
  const { location } = await expectOauthRow(res, "callback.handoff", { app_state: pkce.state });
  return { started, user, code, hc: location?.searchParams.get("hc") as string };
}

// --------------------------------------------------------------------------------------------
// A fake GitHub web origin: the token endpoint
// --------------------------------------------------------------------------------------------

export interface RecordedExchange {
  method: string;
  path: string;
  contentType: string | null;
  accept: string | null;
  userAgent: string | null;
  body: Record<string, unknown> | null;
  /** The relay attached an abort signal to the call, i.e. it bounds how long it will wait. */
  hasSignal: boolean;
}

type WebReply = (request: Request, signal: AbortSignal | null) => Response | Promise<Response>;

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8" } });

/** Answers `POST <GITHUB_WEB_BASE>/login/oauth/access_token` the way GitHub does for a GitHub App
 *  with expiring user tokens -- HTTP 200 with an `error` field for a code it will not take, and a
 *  refresh token beside the access token -- from a table of codes a test has issued. Every call is
 *  recorded; the next one can be told to fail in the ways GitHub does. The token it hands out is
 *  registered with the API fake, so the relay's check-and-delete finds it. */
export class FakeGitHubWeb {
  readonly calls: RecordedExchange[] = [];
  /** Every access and refresh token handed out: what no log line, Location, response or stored value may hold. */
  readonly issued: string[] = [];
  private readonly codes = new Map<string, FakeUser>();
  private readonly queued: WebReply[] = [];
  private original: typeof fetch | null = null;

  constructor(private readonly api: FakeGitHub) {}

  private get origin(): string {
    return typedEnv.GITHUB_WEB_BASE as string;
  }

  /** Starts answering. Install after the API fake: this one delegates what is not its origin to it. */
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

  /** Puts back what was there before and forgets everything. */
  uninstall(): void {
    if (this.original) globalThis.fetch = this.original;
    this.original = null;
    this.calls.length = 0;
    this.issued.length = 0;
    this.codes.clear();
    this.queued.length = 0;
  }

  /** The code GitHub would put in the callback's query once `user` has signed in and approved. */
  authorizationCode(user: FakeUser): string {
    const code = `gh-code-${crypto.randomUUID()}`;
    this.codes.set(code, user);
    return code;
  }

  /** The next exchange is answered with `status` and `body` (JSON) instead. */
  respondOnce(status: number, body: unknown): void {
    this.queued.push(() => json(status, body));
  }

  /** The next exchange is answered with `status` and `text` as they are, not JSON. */
  respondRawOnce(status: number, text: string | null, headers: Record<string, string> = {}): void {
    this.queued.push(() => new Response(text, { status, headers }));
  }

  /** The next exchange fails the way a dropped connection does. */
  networkErrorOnce(): void {
    this.queued.push(() => {
      throw new TypeError("fetch failed");
    });
  }

  /** The next exchange is never answered; it ends only when the relay's own timeout aborts it. */
  hangOnce(): void {
    this.queued.push(
      (_request, signal) =>
        new Promise<Response>((_resolve, reject) => {
          if (!signal) return;
          signal.addEventListener("abort", () => reject(signal.reason));
        })
    );
  }

  private async answer(request: Request, signal: AbortSignal | null): Promise<Response> {
    const url = new URL(request.url);
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
      method: request.method,
      path: url.pathname,
      contentType: request.headers.get("content-type"),
      accept: request.headers.get("accept"),
      userAgent: request.headers.get("user-agent"),
      body,
      hasSignal: signal !== null,
    });

    const reply = this.queued.shift();
    if (reply) return reply(request, signal);

    if (request.method !== "POST" || url.pathname !== "/login/oauth/access_token") return json(404, { message: "Not Found" });
    const fields: Record<string, unknown> = body ?? {};
    if (fields.client_id !== typedEnv.GITHUB_CLIENT_ID || fields.client_secret !== typedEnv.GITHUB_CLIENT_SECRET) {
      return json(200, { error: "incorrect_client_credentials", error_description: "The client_id and/or client_secret passed are incorrect." });
    }
    const code = typeof fields.code === "string" ? fields.code : "";
    const user = this.codes.get(code);
    if (!user) {
      return json(200, { error: "bad_verification_code", error_description: "The code passed is incorrect or expired." });
    }
    this.codes.delete(code); // a code is single use
    if (fields.redirect_uri !== CALLBACK_URL) {
      return json(200, { error: "redirect_uri_mismatch", error_description: "The redirect_uri is not associated with this application." });
    }
    const accessToken = this.api.phoneToken(user);
    const refreshToken = `ghr_test_${crypto.randomUUID()}`;
    this.issued.push(accessToken, refreshToken);
    return json(200, {
      access_token: accessToken,
      expires_in: 28800,
      refresh_token: refreshToken,
      refresh_token_expires_in: 15811200,
      token_type: "bearer",
      scope: "",
    });
  }
}

// --------------------------------------------------------------------------------------------
// Looking at Durable Object storage
// --------------------------------------------------------------------------------------------

export type OauthKind = "oauth-state" | "oauth-handoff";

export const recordStub = (kind: OauthKind, key: string): DurableObjectStub =>
  typedEnv.SESSION.get(typedEnv.SESSION.idFromName(`${kind}:${key}`));

export type StoredOauth = Record<string, unknown> & { exp: number };

export function storedOauthRecord(kind: OauthKind, key: string): Promise<StoredOauth | undefined> {
  return runInDurableObject(recordStub(kind, key), (_instance, state) => state.storage.get<StoredOauth>("oauth_record"));
}

export function oauthAlarm(kind: OauthKind, key: string): Promise<number | null> {
  return runInDurableObject(recordStub(kind, key), (_instance, state) => state.storage.getAlarm());
}

/** Rewrites the stored record in place, the way a test ages one (`exp`) or corrupts one. */
export function editOauthRecord(kind: OauthKind, key: string, change: (record: Record<string, unknown>) => void): Promise<void> {
  return runInDurableObject(recordStub(kind, key), async (_instance, state) => {
    const record = await state.storage.get<Record<string, unknown>>("oauth_record");
    if (!record) throw new Error(`no ${kind} record to edit`);
    change(record);
    await state.storage.put("oauth_record", record);
  });
}

/** Writes a record straight into its instance through the internal handler, bypassing the routes:
 *  for the one test that needs a handoff whose challenge it chose (the RFC 7636 vector). */
export function putOauthRecord(kind: OauthKind, key: string, record: Record<string, unknown>): Promise<Response> {
  return recordStub(kind, key).fetch("http://do-internal/oauth-put", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(record),
  });
}

const objectIds = async (): Promise<Set<string>> =>
  new Set((await listDurableObjectIds(typedEnv.SESSION)).map((id) => id.toString()));

/** Every Durable Object that did not exist before `since` was taken, each as the serialized text of
 *  what it holds: the sweep for a value that must not be in storage. Only the objects a flow creates
 *  are read -- the namespace is shared by the whole file, and waking every object it ever made is
 *  what once made code-pair.spec.ts take minutes. */
export async function snapshotNewObjects(since: Set<string>): Promise<string[]> {
  const dumps: string[] = [];
  for (const id of await listDurableObjectIds(typedEnv.SESSION)) {
    if (!since.has(id.toString())) dumps.push(await dumpStorage(typedEnv.SESSION.get(id)));
  }
  return dumps;
}

export const takeObjectIds = objectIds;

/** What `run` leaves behind in Durable Objects that did not exist before it. */
export async function dumpsOfNewObjects(run: () => Promise<void>): Promise<string[]> {
  const before = await objectIds();
  await run();
  return snapshotNewObjects(before);
}
