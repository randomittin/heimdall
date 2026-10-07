// GitHub sign-in through the browser -- authorization code + PKCE, brokered by the relay (design of
// record: hmdapp docs/HANDOFF-TO-HEIMDALL-github-oauth.md; its section 11 is this file's acceptance list).
// Driven end to end through the real Worker and Durable Objects in workerd. The wire is
// relay/contract/github-oauth.json: every response asserted here is a row of that file, and the last
// test fails if a row was never asserted, so a status added to the contract cannot go untested.
//
// A test named `[n]` carries item n of section 11, so the list can be audited against this file by
// grep; the tests without a number go beyond it. GitHub is faked in-process (code-pair-helpers.ts's
// FakeGitHub for the API, github-oauth-helpers.ts's FakeGitHubWeb for the token endpoint, reached
// through the GITHUB_API_BASE and GITHUB_WEB_BASE seams) and never touched. Real clocks throughout:
// workerd's timers cannot be advanced from a test, so an aged-out record is arranged by editing the
// stored `exp` rather than waited for. Values a test needs (states, verifiers, tokens, codes) are
// built at run time; the one literal digest is a known answer from python's hashlib.

/// <reference types="vite/client" />

import { SELF, runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { githubWebOrigin } from "../src/github";
import { GH_ASSERTION_TTL_S, base64UrlEncode, verifyGhAssertion } from "../src/pairing";
import worker from "../src/worker";
import type { Env } from "../src/types";
import { withRelayLog, type RelayLog } from "./hmd-socket";
import {
  FakeGitHub,
  dumpStorage,
  freshIp,
  newPhone,
  newUser,
  nowS,
  openWindow,
  pairCode,
  signIn,
  snapshot,
  typedEnv,
  type Identity,
} from "./code-pair-helpers";
import {
  CALLBACK_URL,
  FakeGitHubWeb,
  OAUTH_BASE,
  allOauthRowKeys,
  callbackQuery,
  callbackRequest,
  dumpsOfNewObjects,
  editOauthRecord,
  expectOauthRow,
  expectRecord,
  newPkce,
  oauthAlarm,
  oauthCovered,
  probeRequest,
  putOauthRecord,
  reachHandoff,
  recordStub,
  redeemRequest,
  snapshotNewObjects,
  startFlow,
  startPairs,
  startRequest,
  storedOauthRecord,
  takeObjectIds,
  toQuery,
  type Pairs,
} from "./github-oauth-helpers";

// Most tests drive a flow of three to six requests, each a few Durable Object hops in a real
// workerd, and a few fill a throttle or wait out the relay's own 5 s GitHub timeout: the 5 s
// default would fail them for being thorough. code-pair.spec.ts sets the same figure.
vi.setConfig({ testTimeout: 20_000 });

const fake = new FakeGitHub();
const web = new FakeGitHubWeb(fake);
beforeEach(() => {
  fake.install();
  web.install(); // after the API fake: it delegates everything that is not the web origin
});
afterEach(() => {
  web.uninstall();
  fake.uninstall();
});

const clientId = (): string => typedEnv.GITHUB_CLIENT_ID as string;
const clientSecret = (): string => typedEnv.GITHUB_CLIENT_SECRET as string;
const identitySecret = (): string => typedEnv.RELAY_IDENTITY_SECRET as string;
const webBase = (): string => typedEnv.GITHUB_WEB_BASE as string;

/** The `$bindings` of the redirect to GitHub that only the running suite knows. */
const authorizeLive = (): { authorize_base: string; client_id: string; callback_url: string } => ({
  authorize_base: `${webBase()}/login/oauth/authorize`,
  client_id: clientId(),
  callback_url: CALLBACK_URL,
});

/** The Worker's env as the suite binds it, with `over` laid on top: how a test turns the flag or a
 *  secret off for one request (the config-gate block of code-pair.spec.ts does the same). */
const envWith = (over: Record<string, unknown>): Env =>
  ({
    SESSION: typedEnv.SESSION,
    RELAY_SIGNING_SECRET: typedEnv.RELAY_SIGNING_SECRET,
    GITHUB_CLIENT_ID: typedEnv.GITHUB_CLIENT_ID,
    GITHUB_CLIENT_SECRET: typedEnv.GITHUB_CLIENT_SECRET,
    RELAY_IDENTITY_SECRET: typedEnv.RELAY_IDENTITY_SECRET,
    GITHUB_API_BASE: typedEnv.GITHUB_API_BASE,
    GITHUB_WEB_BASE: typedEnv.GITHUB_WEB_BASE,
    GITHUB_OAUTH_WEB: typedEnv.GITHUB_OAUTH_WEB,
    ...over,
  }) as Env;

const random32 = (): string => base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));

/** The four routes, each as a request that would succeed (or at least be well formed) on a relay
 *  that has them: the methods the routes use, and the same paths under the methods they do not. */
function requestsForAllFour(method: string | null): Request[] {
  const pairs = toQuery(startPairs(newPkce(), newPhone()));
  const paths: [string, string, string][] = [
    ["GET", "/identity/github/oauth", ""],
    ["GET", "/identity/github/oauth/start", `?${pairs}`],
    ["GET", "/identity/github/oauth/callback", `?${callbackQuery("c", random32())}`],
    ["POST", "/identity/github/oauth/redeem", ""],
  ];
  return paths.map(([own, path, query]) => {
    const m = method ?? own;
    const init: RequestInit = { method: m, headers: { "CF-Connecting-IP": freshIp() } };
    if (m === "POST" || m === "PUT") init.body = JSON.stringify({ hc: random32(), code_verifier: random32() });
    return new Request(`${OAUTH_BASE}${path}${query}`, init);
  });
}

// ============================================================================================
// The probe, and the switch that every route obeys
// ============================================================================================

describe("GET /identity/github/oauth (the capability probe)", () => {
  it('[1] enabled: 200, the body exactly {"v":1}, Cache-Control: no-store', async () => {
    const res = await probeRequest();
    expect(await res.clone().text()).toBe('{"v":1}');
    expect(res.headers.get("cache-control")).toBe("no-store");
    await expectOauthRow(res, "probe.ok");
  });

  const OFF: [string, unknown][] = [
    ["unset", undefined],
    ['"0"', "0"],
    ['""', ""],
    ['"true"', "true"],
    ['"yes"', "yes"],
    ['" 1"', " 1"],
    ['"1 "', "1 "],
    ['"11"', "11"],
    ["the number 1", 1],
  ];

  it.each(OFF)("[2] GITHUB_OAUTH_WEB %s: all four routes, under any method, answer the Worker's own 404 -- byte for byte what an unknown path answers", async (_label, value) => {
    const env = envWith({ GITHUB_OAUTH_WEB: value });
    const unknown = await snapshot(await worker.fetch(new Request(`${OAUTH_BASE}/identity/github/not-a-route`), env));
    expect(unknown.status).toBe(404);
    for (const method of [null, "GET", "POST", "PUT", "DELETE", "HEAD"]) {
      for (const request of requestsForAllFour(method)) {
        const res = await worker.fetch(request, env);
        expect(await snapshot(res), `${request.method} ${new URL(request.url).pathname}`).toEqual(unknown);
      }
    }
    // and the row says the same, in the contract's words
    await expectOauthRow(await worker.fetch(new Request(`${OAUTH_BASE}/identity/github/oauth`), env), "probe.off");
  });

  it.each(["GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "RELAY_IDENTITY_SECRET"])(
    '[2] the flag "1" with %s unset or empty: still the 404, on all four routes',
    async (name) => {
      for (const value of [undefined, ""]) {
        const env = envWith({ [name]: value });
        for (const request of requestsForAllFour(null)) {
          const res = await worker.fetch(request, env);
          await expectOauthRow(res, "probe.off");
        }
      }
      expect(fake.calls).toHaveLength(0);
      expect(web.calls).toHaveLength(0);
    }
  );

  it("[3] makes no GitHub call and addresses no Durable Object: it reads the environment and nothing else", async () => {
    const trap = new Proxy(
      {},
      {
        get: (_target, property) => {
          throw new Error(`the probe reached for SESSION.${String(property)}`);
        },
      }
    ) as unknown as DurableObjectNamespace;
    const res = await worker.fetch(new Request(`${OAUTH_BASE}/identity/github/oauth`), envWith({ SESSION: trap }));
    await expectOauthRow(res, "probe.ok");
    expect(fake.calls).toHaveLength(0);
    expect(web.calls).toHaveLength(0);
  });

  it("answers 404, like any unknown path, to the wrong method and to near-miss paths on a relay that has the routes", async () => {
    const unknown = await snapshot(await worker.fetch(new Request(`${OAUTH_BASE}/identity/github/not-a-route`), envWith({})));
    const misses: [string, string][] = [
      ["POST", "/identity/github/oauth"],
      ["PUT", "/identity/github/oauth"],
      ["HEAD", "/identity/github/oauth"],
      ["POST", "/identity/github/oauth/start"],
      ["POST", "/identity/github/oauth/callback"],
      ["GET", "/identity/github/oauth/redeem"],
      ["PUT", "/identity/github/oauth/redeem"],
      ["GET", "/identity/github/oauth/"],
      ["GET", "/identity/github/OAuth"],
      ["GET", "/identity/github/oauth/redeem/"],
      ["POST", "/identity/github/oauth/start/x"],
    ];
    for (const [method, path] of misses) {
      const res = await worker.fetch(new Request(`${OAUTH_BASE}${path}`, { method }), envWith({}));
      expect(await snapshot(res), `${method} ${path}`).toEqual(unknown);
    }
  });
});

// ============================================================================================
// GET /identity/github/oauth/start
// ============================================================================================

describe("GET /identity/github/oauth/start", () => {
  it("[4] a valid request: 302 to GitHub's authorize URL with the config's client_id, the callback as redirect_uri, a state of 43 characters that is not the app's, prompt=select_account and no scope", async () => {
    const phone = newPhone();
    const pkce = newPkce();
    const res = await startRequest(toQuery(startPairs(pkce, phone)));
    const { location } = await expectOauthRow(res, "start.redirect_github", authorizeLive());

    const url = location as URL;
    expect(`${url.origin}${url.pathname}`).toBe(`${webBase()}/login/oauth/authorize`);
    expect(url.searchParams.get("client_id")).toBe(clientId());
    expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK_URL);
    const relayState = url.searchParams.get("state") as string;
    expect(relayState).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(relayState).not.toBe(pkce.state);
    expect(url.searchParams.get("prompt")).toBe("select_account");
    // exactly these four: no scope, no login, no allow_signup, no PKCE of the relay's own
    expect([...url.searchParams.keys()].sort()).toEqual(["client_id", "prompt", "redirect_uri", "state"]);
    expect(url.searchParams.has("scope")).toBe(false);
  });

  it("[4] two starts never share a relay state, and neither derives from the app's", async () => {
    const pkce = newPkce();
    const first = await startFlow(newPhone(), pkce);
    const second = await startFlow(newPhone(), pkce);
    expect(first.relayState).not.toBe(second.relayState);
    for (const started of [first, second]) {
      expect(started.relayState).not.toBe(pkce.state);
      expect(started.relayState).not.toBe(pkce.challenge);
      expect(started.relayState).not.toBe(started.phone.pub);
    }
  });

  it("[5] Cache-Control: no-store and Referrer-Policy: no-referrer", async () => {
    const res = await startRequest(toQuery(startPairs(newPkce(), newPhone())));
    expect(res.status).toBe(302);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("[6] a record exists under the returned state: the app's state, the challenge and the install key, exp about 600 s ahead, an alarm 60 s after that", async () => {
    const phone = newPhone();
    const pkce = newPkce();
    const started = await startFlow(phone, pkce);

    const record = await storedOauthRecord("oauth-state", started.relayState);
    expect(record).toBeDefined();
    expectRecord(record, "oauth_state", { app_state: pkce.state, challenge: pkce.challenge, install_pubkey: phone.pub });
    expect(Math.abs((record as { exp: number }).exp - (nowS() + 600))).toBeLessThanOrEqual(5);
    expect(await oauthAlarm("oauth-state", started.relayState)).toBe(((record as { exp: number }).exp + 60) * 1000);
  });

  describe("[7] bad requests", () => {
    const MARK = "echo-marker";
    type Edit = (pairs: Pairs) => Pairs;
    const set =
      (name: string, value: string): Edit =>
      (pairs) =>
        pairs.map(([n, v]) => [n, n === name ? value : v]);
    const drop =
      (name: string): Edit =>
      (pairs) =>
        pairs.filter(([n]) => n !== name);
    const repeat =
      (name: string, value?: string): Edit =>
      (pairs) => [...pairs, [name, value ?? (pairs.find(([n]) => n === name)?.[1] as string)]];
    /** 43 characters, so only the alphabet is wrong, and the marker is in it. */
    const marked = (bad: string): string => `${MARK}${bad}${"A".repeat(43 - MARK.length - bad.length)}`;
    const ofBytes = (count: number): string => base64UrlEncode(new Uint8Array(count).fill(9));

    const CASES: [string, Edit][] = [
      ["state missing", drop("state")],
      ["state one character short", set("state", "A".repeat(42))],
      ["state one character long", set("state", "A".repeat(44))],
      ["state with a + in it", set("state", marked("+"))],
      ["state with a / in it", set("state", marked("/"))],
      ["state padded with =", set("state", marked("="))],
      ["state with markup in it", set("state", `${MARK}"><script>alert(1)</script>`)],
      ["state empty", set("state", "")],
      ["code_challenge missing", drop("code_challenge")],
      ["code_challenge one character short", set("code_challenge", "A".repeat(42))],
      ["code_challenge one character long", set("code_challenge", "A".repeat(44))],
      ["code_challenge with a + in it", set("code_challenge", marked("+"))],
      ["code_challenge padded with =", set("code_challenge", marked("="))],
      ["code_challenge_method plain", set("code_challenge_method", "plain")],
      ["code_challenge_method missing", drop("code_challenge_method")],
      ["code_challenge_method lower-case s256", set("code_challenge_method", "s256")],
      ["code_challenge_method S256 with a trailing space", set("code_challenge_method", "S256 ")],
      ["code_challenge_method S384", set("code_challenge_method", "S384")],
      ["code_challenge_method empty", set("code_challenge_method", "")],
      [`code_challenge_method ${MARK}`, set("code_challenge_method", MARK)],
      ["install_pubkey missing", drop("install_pubkey")],
      ["install_pubkey of 31 bytes", set("install_pubkey", ofBytes(31))],
      ["install_pubkey of 33 bytes", set("install_pubkey", ofBytes(33))],
      ["install_pubkey padded with =", set("install_pubkey", `${ofBytes(32)}=`)],
      ["install_pubkey that is not base64", set("install_pubkey", marked("!"))],
      ["state given twice (the same value)", repeat("state")],
      ["state given twice (two valid values)", repeat("state", random32())],
      ["code_challenge given twice", repeat("code_challenge")],
      ["code_challenge_method given twice", repeat("code_challenge_method")],
      ["install_pubkey given twice", repeat("install_pubkey")],
    ];

    it.each(CASES)("%s -> 400, the fixed HTML page, nothing echoed, no record and no throttle bucket created", async (_label, edit) => {
      const pairs = edit(startPairs(newPkce(), newPhone()));
      const before = await takeObjectIds();
      const res = await startRequest(toQuery(pairs));

      const { text } = await expectOauthRow(res, "start.invalid_link");
      expect(res.headers.get("location")).toBeNull();
      expect(text).not.toContain(MARK);
      for (const [, value] of pairs) if (value.length >= 20) expect(text).not.toContain(value);
      // shapes are judged before the bucket is counted and before anything is stored
      expect((await takeObjectIds()).size).toBe(before.size);
    });
  });

  it("[8] the 11th start in a window from one IP is refused with a redirect to the app (temporarily_unavailable, retry_after_s=60, the state); another IP is unaffected", async () => {
    const ip = freshIp();
    for (let attempt = 1; attempt <= 10; attempt++) {
      const res = await startRequest(toQuery(startPairs(newPkce(), newPhone())), ip);
      expect(res.status, `start ${attempt}`).toBe(302);
      expect(new URL(res.headers.get("location") as string).origin, `start ${attempt}`).toBe(webBase());
    }

    const pkce = newPkce();
    const refused = await dumpsOfNewObjects(async () => {
      const res = await startRequest(toQuery(startPairs(pkce, newPhone())), ip);
      await expectOauthRow(res, "start.throttled", { app_state: pkce.state });
    });
    expect(refused, "a refused start stores nothing").toEqual([]);

    const other = await startRequest(toQuery(startPairs(newPkce(), newPhone())), freshIp());
    await expectOauthRow(other, "start.redirect_github", authorizeLive());
  });

  it("[9] disabled: 404, and nothing stored", async () => {
    const before = await takeObjectIds();
    const res = await worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/start?${toQuery(startPairs(newPkce(), newPhone()))}`, {
        headers: { "CF-Connecting-IP": freshIp() },
      }),
      envWith({ GITHUB_OAUTH_WEB: undefined })
    );
    await expectOauthRow(res, "probe.off");
    expect((await takeObjectIds()).size).toBe(before.size);
  });

  it("goes to github.com when GITHUB_WEB_BASE is unset: the seam is the suite's alone", async () => {
    const res = await worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/start?${toQuery(startPairs(newPkce(), newPhone()))}`, {
        headers: { "CF-Connecting-IP": freshIp() },
      }),
      envWith({ GITHUB_WEB_BASE: undefined })
    );
    expect(res.status).toBe(302);
    expect((res.headers.get("location") as string).startsWith("https://github.com/login/oauth/authorize?")).toBe(true);
  });

  it("githubWebOrigin: github.com by default, the seam's origin without a trailing slash otherwise", () => {
    expect(githubWebOrigin(envWith({ GITHUB_WEB_BASE: undefined }))).toBe("https://github.com");
    expect(githubWebOrigin(envWith({ GITHUB_WEB_BASE: "" }))).toBe("https://github.com");
    expect(githubWebOrigin(envWith({ GITHUB_WEB_BASE: "https://github-web.example.test/" }))).toBe("https://github-web.example.test");
  });

  it("fails loudly, and never redirects to GitHub, when the pending record cannot be stored", async () => {
    const res = worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/start?${toQuery(startPairs(newPkce(), newPhone()))}`, {
        headers: { "CF-Connecting-IP": freshIp() },
      }),
      envWith({ SESSION: sessionWhereOauthPutFails() })
    );
    await expect(res).rejects.toThrow("oauth record not stored");
  });
});

/** The real namespace, except that writing an oauth record answers 500: a Durable Object that cannot store. */
function sessionWhereOauthPutFails(): DurableObjectNamespace {
  const real = typedEnv.SESSION;
  return {
    idFromName: (name: string) => real.idFromName(name),
    get: (id: DurableObjectId) => {
      const stub = real.get(id);
      return {
        fetch: (input: RequestInfo | URL, init?: RequestInit): Promise<Response> =>
          String(input).endsWith("/oauth-put") ? Promise.resolve(new Response("{}", { status: 500 })) : stub.fetch(input, init),
      };
    },
  } as unknown as DurableObjectNamespace;
}

// ============================================================================================
// GET /identity/github/oauth/callback
// ============================================================================================

describe("GET /identity/github/oauth/callback", () => {
  const exchangeLogged = (log: RelayLog): Record<string, unknown>[] => log.events("github_error").filter((entry) => entry.call === "exchange");

  it("[10] the happy path: 302 to the app with hc and the app's state; hc is not the relay state; the state record is gone; a handoff exists, exp about 60 s ahead", async () => {
    const user = newUser();
    const phone = newPhone();
    const pkce = newPkce();
    const started = await startFlow(phone, pkce);
    const code = web.authorizationCode(user);

    const res = await callbackRequest(callbackQuery(code, started.relayState));
    const { location } = await expectOauthRow(res, "callback.handoff", { app_state: pkce.state });

    const hc = (location as URL).searchParams.get("hc") as string;
    expect(hc).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(hc).not.toBe(started.relayState);
    expect(hc).not.toBe(pkce.state);
    expect(await storedOauthRecord("oauth-state", started.relayState)).toBeUndefined();

    const handoff = await storedOauthRecord("oauth-handoff", hc);
    expect(handoff).toBeDefined();
    expectRecord(handoff, "oauth_handoff", { gh_id: user.id, gh_login: user.login, install_pubkey: phone.pub, challenge: pkce.challenge });
    expect(Math.abs((handoff as { exp: number }).exp - (nowS() + 60))).toBeLessThanOrEqual(5);
    expect(await oauthAlarm("oauth-handoff", hc)).toBe(((handoff as { exp: number }).exp + 60) * 1000);
  });

  it("[11] the exchange: POST <web base>/login/oauth/access_token, JSON, Accept: application/json, the client id and secret, the code and the authorize leg's redirect_uri; 5 s bound, User-Agent hmd-relay", async () => {
    const started = await startFlow();
    const code = web.authorizationCode(newUser());
    await expectOauthRow(await callbackRequest(callbackQuery(code, started.relayState)), "callback.handoff", { app_state: started.pkce.state });

    expect(web.calls).toHaveLength(1);
    const [call] = web.calls;
    expect(call).toMatchObject({ method: "POST", path: "/login/oauth/access_token", accept: "application/json", userAgent: "hmd-relay", hasSignal: true });
    expect(call?.contentType).toMatch(/^application\/json/);
    expect(call?.body).toEqual({
      client_id: clientId(),
      client_secret: clientSecret(),
      code,
      redirect_uri: started.authorize.searchParams.get("redirect_uri"),
    });
    expect(call?.body?.redirect_uri).toBe(CALLBACK_URL);
  });

  it("[12] disposal: check-token then DELETE for that token, in that order; the token, its refresh token and the client secret are in no Location, body, stored value or log line", async () => {
    const user = newUser();
    const started = await startFlow();
    const code = web.authorizationCode(user);
    const before = await takeObjectIds();
    let res: Response | undefined;
    const log = await withRelayLog(async () => {
      res = await callbackRequest(callbackQuery(code, started.relayState));
    });
    const { location } = await expectOauthRow(res as Response, "callback.handoff", { app_state: started.pkce.state });

    expect(fake.calls.map((call) => `${call.method} ${call.path}`)).toEqual([
      `POST /applications/${clientId()}/token`,
      `DELETE /applications/${clientId()}/token`,
    ]);
    const [accessToken, refreshToken] = web.issued as [string, string];
    for (const call of fake.calls) expect(call.body).toEqual({ access_token: accessToken });
    expect(fake.isPhoneTokenLive(accessToken), "deleted at GitHub").toBe(false);

    const dumps = [...(await snapshotNewObjects(before)), await dumpStorage(recordStub("oauth-state", started.relayState))];
    const everywhere = [(location as URL).toString(), await (res as Response).clone().text(), ...dumps, log.lines.join("\n")];
    for (const value of [accessToken, refreshToken, clientSecret(), code]) {
      for (const place of everywhere) expect(place).not.toContain(value);
    }
  });

  it("[13] error=access_denied: 302 to the app with error=access_denied and the app's state; GitHub is not called", async () => {
    const started = await startFlow();
    const query = toQuery([
      ["error", "access_denied"],
      ["error_description", "The user has denied your application access."],
      ["error_uri", "https://docs.github.com/apps/troubleshooting-authorization-request-errors"],
      ["state", started.relayState],
    ]);
    const res = await callbackRequest(query);
    await expectOauthRow(res, "callback.denied", { app_state: started.pkce.state });
    expect(fake.calls).toHaveLength(0);
    expect(web.calls).toHaveLength(0);
    expect(await storedOauthRecord("oauth-state", started.relayState), "the state is consumed whatever the callback ends in").toBeUndefined();
  });

  it.each([
    ["server_error"],
    ["redirect_uri_mismatch"],
    ["temporarily_unavailable"],
    ["ACCESS_DENIED"],
    ["access_denied "],
    [""],
  ])("[13] any other GitHub error (%j) -> error=server_error, GitHub is not called", async (error) => {
    const started = await startFlow();
    const res = await callbackRequest(
      toQuery([
        ["error", error],
        ["state", started.relayState],
      ])
    );
    await expectOauthRow(res, "callback.server_error", { app_state: started.pkce.state });
    expect(fake.calls).toHaveLength(0);
    expect(web.calls).toHaveLength(0);
  });

  it("[13] an error beside a code is still the error: the code is never exchanged; error given twice is not access_denied", async () => {
    const started = await startFlow();
    const both = await callbackRequest(
      toQuery([
        ["error", "access_denied"],
        ["code", web.authorizationCode(newUser())],
        ["state", started.relayState],
      ])
    );
    await expectOauthRow(both, "callback.denied", { app_state: started.pkce.state });

    const twice = await startFlow();
    const res = await callbackRequest(
      toQuery([
        ["error", "access_denied"],
        ["error", "access_denied"],
        ["state", twice.relayState],
      ])
    );
    await expectOauthRow(res, "callback.server_error", { app_state: twice.pkce.state });
    expect(web.calls).toHaveLength(0);
  });

  const BAD_CODES: [string, (state: string) => Pairs][] = [
    ["no code", (state) => [["state", state]]],
    ["an empty code", (state) => [["code", ""], ["state", state]]],
    ["a code with a space", (state) => [["code", "abc def"], ["state", state]]],
    ["a code with a newline", (state) => [["code", "abc\ndef"], ["state", state]]],
    ["a code with a NUL", (state) => [["code", "abc\u0000def"], ["state", state]]],
    ["a code with DEL", (state) => [["code", "abc\u007fdef"], ["state", state]]],
    ["a code with a non-ASCII character", (state) => [["code", "abcédef"], ["state", state]]],
    ["a code of 257 characters", (state) => [["code", "a".repeat(257)], ["state", state]]],
    ["two codes", (state) => [["code", "abc"], ["code", "def"], ["state", state]]],
  ];

  it.each(BAD_CODES)("[14] %s -> error=invalid_request, GitHub is not called", async (_label, pairs) => {
    const started = await startFlow();
    const res = await callbackRequest(toQuery(pairs(started.relayState)));
    await expectOauthRow(res, "callback.invalid_request", { app_state: started.pkce.state });
    expect(fake.calls).toHaveLength(0);
    expect(web.calls).toHaveLength(0);
    expect(await storedOauthRecord("oauth-state", started.relayState)).toBeUndefined();
  });

  it("[14] a code of exactly 256 visible characters is taken to GitHub (and GitHub says what it thinks of it)", async () => {
    const started = await startFlow();
    const res = await callbackRequest(callbackQuery("a".repeat(256), started.relayState));
    await expectOauthRow(res, "callback.invalid_request", { app_state: started.pkce.state }); // GitHub: bad_verification_code
    expect(web.calls).toHaveLength(1);
  });

  type Failure = { label: string; arrange: (w: FakeGitHubWeb) => void; row: "callback.invalid_request" | "callback.server_error"; kind: string | null };
  const FAILURES: Failure[] = [
    { label: "bad_verification_code (HTTP 200 with an error field)", arrange: (w) => w.respondOnce(200, { error: "bad_verification_code", error_description: "x" }), row: "callback.invalid_request", kind: null },
    { label: "an error beside a token (the error wins)", arrange: (w) => w.respondOnce(200, { error: "bad_verification_code", access_token: "tok", token_type: "bearer" }), row: "callback.invalid_request", kind: null },
    { label: "HTTP 500", arrange: (w) => w.respondOnce(500, { message: "oops" }), row: "callback.server_error", kind: "status" },
    { label: "HTTP 502", arrange: (w) => w.respondOnce(502, { message: "oops" }), row: "callback.server_error", kind: "status" },
    { label: "HTTP 404", arrange: (w) => w.respondOnce(404, { message: "Not Found" }), row: "callback.server_error", kind: "status" },
    { label: "HTTP 429", arrange: (w) => w.respondOnce(429, { message: "slow down" }), row: "callback.server_error", kind: "status" },
    { label: "a redirect", arrange: (w) => w.respondRawOnce(302, null, { location: "https://elsewhere.test/" }), row: "callback.server_error", kind: "status" },
    { label: "a dropped connection", arrange: (w) => w.networkErrorOnce(), row: "callback.server_error", kind: "network" },
    { label: "incorrect_client_credentials", arrange: (w) => w.respondOnce(200, { error: "incorrect_client_credentials" }), row: "callback.server_error", kind: "client_credentials" },
    { label: "redirect_uri_mismatch", arrange: (w) => w.respondOnce(200, { error: "redirect_uri_mismatch" }), row: "callback.server_error", kind: "redirect_uri" },
    { label: "an error code the relay has no name for", arrange: (w) => w.respondOnce(200, { error: "unverified_user_email" }), row: "callback.server_error", kind: "error" },
    { label: "an error that is not a string", arrange: (w) => w.respondOnce(200, { error: 5 }), row: "callback.server_error", kind: "error" },
    { label: "an error beside a token", arrange: (w) => w.respondOnce(200, { error: "access_denied", access_token: "tok", token_type: "bearer" }), row: "callback.server_error", kind: "error" },
    { label: "the form-encoded answer GitHub gives without Accept: application/json", arrange: (w) => w.respondRawOnce(200, "access_token=tok&token_type=bearer", { "content-type": "text/plain; charset=utf-8" }), row: "callback.server_error", kind: "bad_body" },
    { label: "text that is not JSON", arrange: (w) => w.respondRawOnce(200, "not json"), row: "callback.server_error", kind: "bad_body" },
    { label: "an empty body", arrange: (w) => w.respondRawOnce(200, ""), row: "callback.server_error", kind: "bad_body" },
    { label: "JSON null", arrange: (w) => w.respondOnce(200, null), row: "callback.server_error", kind: "bad_body" },
    { label: "a JSON array", arrange: (w) => w.respondOnce(200, []), row: "callback.server_error", kind: "bad_body" },
    { label: "an empty object", arrange: (w) => w.respondOnce(200, {}), row: "callback.server_error", kind: "bad_body" },
    { label: "no access_token", arrange: (w) => w.respondOnce(200, { token_type: "bearer" }), row: "callback.server_error", kind: "bad_body" },
    { label: "an access_token that is not a string", arrange: (w) => w.respondOnce(200, { access_token: 5, token_type: "bearer" }), row: "callback.server_error", kind: "bad_body" },
    { label: "an empty access_token", arrange: (w) => w.respondOnce(200, { access_token: "", token_type: "bearer" }), row: "callback.server_error", kind: "bad_body" },
    { label: "an access_token with a space in it", arrange: (w) => w.respondOnce(200, { access_token: "has space", token_type: "bearer" }), row: "callback.server_error", kind: "bad_body" },
    { label: "an access_token of 256 characters", arrange: (w) => w.respondOnce(200, { access_token: "a".repeat(256), token_type: "bearer" }), row: "callback.server_error", kind: "bad_body" },
    { label: "no token_type", arrange: (w) => w.respondOnce(200, { access_token: "tok" }), row: "callback.server_error", kind: "bad_body" },
    { label: "a token_type that is not bearer", arrange: (w) => w.respondOnce(200, { access_token: "tok", token_type: "mac" }), row: "callback.server_error", kind: "bad_body" },
  ];

  it.each(FAILURES)("[15] the exchange answers $label -> $row, no handoff stored", async ({ arrange, row, kind }) => {
    const started = await startFlow();
    const code = web.authorizationCode(newUser());
    arrange(web);
    let res: Response | undefined;
    let dumps: string[] = [];
    const log = await withRelayLog(async () => {
      dumps = await dumpsOfNewObjects(async () => {
        res = await callbackRequest(callbackQuery(code, started.relayState));
      });
    });

    await expectOauthRow(res as Response, row, { app_state: started.pkce.state });
    expect(web.calls).toHaveLength(1);
    expect(fake.calls, "an answer that is not a token never reaches the check").toHaveLength(0);
    for (const dump of dumps) expect(dump, "no handoff").not.toContain("oauth_record");
    const logged = exchangeLogged(log);
    expect(logged).toHaveLength(kind === null ? 0 : 1);
    if (kind !== null) expect(logged[0]).toMatchObject({ session_id: "none", call: "exchange", kind });
  });

  it("[15] the exchange never answers: given up on after 5 s -> server_error, no handoff stored", async () => {
    const started = await startFlow();
    web.hangOnce();
    const code = web.authorizationCode(newUser());
    const began = Date.now();
    let res: Response | undefined;
    let dumps: string[] = [];
    const log = await withRelayLog(async () => {
      dumps = await dumpsOfNewObjects(async () => {
        res = await callbackRequest(callbackQuery(code, started.relayState));
      });
    });
    const waited = Date.now() - began;

    await expectOauthRow(res as Response, "callback.server_error", { app_state: started.pkce.state });
    expect(waited).toBeGreaterThanOrEqual(4500);
    expect(waited).toBeLessThan(9000);
    expect(fake.calls).toHaveLength(0);
    for (const dump of dumps) expect(dump).not.toContain("oauth_record");
    expect(exchangeLogged(log)).toEqual([{ event: "github_error", session_id: "none", call: "exchange", kind: "timeout" }]);
  }, 20_000);

  const CHECK_FAILURES: [string, (g: FakeGitHub) => void][] = [
    ["check-token answers 404 (a token this App never issued)", (g) => g.respondOnce("check", 404, { message: "Not Found" })],
    ["check-token answers 422", (g) => g.respondOnce("check", 422, { message: "Unprocessable" })],
    ["check-token answers 401 (the relay's own credentials refused)", (g) => g.respondOnce("check", 401, { message: "Bad credentials" })],
    ["check-token answers 403", (g) => g.respondOnce("check", 403, { message: "Forbidden" })],
    ["check-token answers 500", (g) => g.respondOnce("check", 500, {})],
    ["check-token drops the connection", (g) => g.networkErrorOnce("check")],
    ["check-token names no user", (g) => g.respondOnce("check", 200, { app: { client_id: clientId() } })],
    ["check-token names another App", (g) => g.respondOnce("check", 200, { app: { client_id: "Iv-another-app" }, user: { login: "octo", id: 5 } })],
    ["DELETE answers 500", (g) => g.respondOnce("delete", 500, {})],
    ["DELETE answers 403", (g) => g.respondOnce("delete", 403, {})],
    ["DELETE drops the connection", (g) => g.networkErrorOnce("delete")],
  ];

  it.each(CHECK_FAILURES)("[16] %s -> error=server_error, no handoff stored", async (_label, arrange) => {
    const started = await startFlow();
    const code = web.authorizationCode(newUser());
    arrange(fake);
    let res: Response | undefined;
    let dumps: string[] = [];
    await withRelayLog(async () => {
      dumps = await dumpsOfNewObjects(async () => {
        res = await callbackRequest(callbackQuery(code, started.relayState));
      });
    });

    await expectOauthRow(res as Response, "callback.server_error", { app_state: started.pkce.state });
    for (const dump of dumps) expect(dump, "no handoff").not.toContain("oauth_record");
    expect(await storedOauthRecord("oauth-state", started.relayState)).toBeUndefined();
  });

  describe("[17] an unknown state, or a state that is not one", () => {
    it("an unknown state of the right shape -> the 400 page, no GitHub call, no redirect", async () => {
      const res = await callbackRequest(callbackQuery("c", random32()));
      await expectOauthRow(res, "callback.expired");
      expect(res.headers.get("location")).toBeNull();
      expect(fake.calls).toHaveLength(0);
      expect(web.calls).toHaveLength(0);
    });

    const SHAPES: [string, (valid: string) => Pairs][] = [
      ["no state", () => [["code", "c"]]],
      ["a state one character short", () => [["code", "c"], ["state", "A".repeat(42)]]],
      ["a state one character long", () => [["code", "c"], ["state", "A".repeat(44)]]],
      ["a state with a + in it", () => [["code", "c"], ["state", `${"A".repeat(42)}+`]]],
      ["a state padded with =", () => [["code", "c"], ["state", `${"A".repeat(42)}=`]]],
      ["a state with markup in it", () => [["code", "c"], ["state", "<script>alert(1)</script>"]]],
      ["an empty state", () => [["code", "c"], ["state", ""]]],
      ["a live state given twice", (valid) => [["code", "c"], ["state", valid], ["state", valid]]],
    ];

    it.each(SHAPES)("%s -> the 400 'not valid' page, before any record is addressed: no GitHub call, no redirect, a live record untouched", async (_label, pairs) => {
      const started = await startFlow();
      let res: Response | undefined;
      const dumps = await dumpsOfNewObjects(async () => {
        res = await callbackRequest(toQuery(pairs(started.relayState)));
      });
      const { text } = await expectOauthRow(res as Response, "callback.invalid_link");
      expect(text).not.toContain("script");
      expect((res as Response).headers.get("location")).toBeNull();
      expect(fake.calls).toHaveLength(0);
      expect(web.calls).toHaveLength(0);
      expect(await storedOauthRecord("oauth-state", started.relayState), "the live record was not touched").toBeDefined();
      // all that was created is the IP's bucket
      expect(dumps.length).toBeLessThanOrEqual(1);
      for (const dump of dumps) expect(dump).not.toContain("oauth_record");
    });
  });

  it("[18] replaying a callback whose state was consumed -> the 400 page, and GitHub is not called again", async () => {
    const started = await startFlow();
    const code = web.authorizationCode(newUser());
    await expectOauthRow(await callbackRequest(callbackQuery(code, started.relayState)), "callback.handoff", { app_state: started.pkce.state });
    expect(web.calls).toHaveLength(1);
    expect(fake.calls).toHaveLength(2);

    const replay = await callbackRequest(callbackQuery(code, started.relayState));
    await expectOauthRow(replay, "callback.expired");
    expect(replay.headers.get("location")).toBeNull();
    expect(web.calls, "no second exchange").toHaveLength(1);
    expect(fake.calls, "no second check or delete").toHaveLength(2);
  });

  it("[18] an aged-out state record (exp in the past) -> the 400 page, no GitHub call, and the record is gone", async () => {
    const started = await startFlow();
    await editOauthRecord("oauth-state", started.relayState, (record) => {
      record.exp = nowS() - 1;
    });
    const res = await callbackRequest(callbackQuery(web.authorizationCode(newUser()), started.relayState));
    await expectOauthRow(res, "callback.expired");
    expect(fake.calls).toHaveLength(0);
    expect(web.calls).toHaveLength(0);
    expect(await storedOauthRecord("oauth-state", started.relayState), "consumed on read, not left for the alarm").toBeUndefined();
  });

  it("[19] the 11th callback in a window from one IP -> 429 page with Retry-After: 60, and that state's record is untouched", async () => {
    const started = await startFlow();
    const ip = freshIp();
    for (let attempt = 1; attempt <= 10; attempt++) {
      const res = await callbackRequest(callbackQuery("c", random32()), ip);
      await expectOauthRow(res, "callback.expired"); // answered, and counted
    }
    const code = web.authorizationCode(newUser());
    const refused = await callbackRequest(callbackQuery(code, started.relayState), ip);
    await expectOauthRow(refused, "callback.throttled");
    expect(refused.headers.get("location")).toBeNull();
    expect(await storedOauthRecord("oauth-state", started.relayState), "the record was not consumed").toBeDefined();
    expect(web.calls).toHaveLength(0);

    // from another address the same state and code still work: the refusal spent neither
    const ok = await callbackRequest(callbackQuery(code, started.relayState));
    await expectOauthRow(ok, "callback.handoff", { app_state: started.pkce.state });
  });

  it("[9] disabled: 404 on the callback too, and nothing is consumed", async () => {
    const started = await startFlow();
    const res = await worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/callback?${callbackQuery(web.authorizationCode(newUser()), started.relayState)}`),
      envWith({ GITHUB_OAUTH_WEB: "0" })
    );
    await expectOauthRow(res, "probe.off");
    expect(await storedOauthRecord("oauth-state", started.relayState)).toBeDefined();
  });

  it("fails loudly, never redirecting to the app, when the handoff cannot be stored -- after the token was deleted at GitHub", async () => {
    const started = await startFlow();
    const code = web.authorizationCode(newUser());
    const res = worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/callback?${callbackQuery(code, started.relayState)}`, {
        headers: { "CF-Connecting-IP": freshIp() },
      }),
      envWith({ SESSION: sessionWhereOauthPutFails() })
    );
    await expect(res).rejects.toThrow("oauth record not stored");
    const [accessToken] = web.issued as [string];
    expect(fake.isPhoneTokenLive(accessToken)).toBe(false);
  });
});

// ============================================================================================
// POST /identity/github/oauth/redeem
// ============================================================================================

describe("POST /identity/github/oauth/redeem", () => {
  it("[20] the happy path: 200 with exactly gh_assertion, gh_id, gh_login, exp -- the pass POST /identity/github mints for the same user and key, and /pair/code takes it", async () => {
    const user = newUser();
    const phone = newPhone();
    const { started, hc } = await reachHandoff(web, user, phone);

    const res = await redeemRequest({ hc, code_verifier: started.pkce.verifier });
    const { body } = await expectOauthRow(res, "redeem.ok", { gh_id: user.id, gh_login: user.login });
    expect(Object.keys(body as object).sort()).toEqual(["exp", "gh_assertion", "gh_id", "gh_login"]);

    const claims = await verifyGhAssertion(identitySecret(), (body as { gh_assertion: string }).gh_assertion, Date.now());
    expect(claims).toMatchObject({ v: 1, role: "device", gh_id: user.id, gh_login: user.login, install_pubkey: phone.pub });
    expect((claims?.exp ?? 0) - (claims?.iat ?? 0)).toBe(GH_ASSERTION_TTL_S);
    expect(Math.abs((claims?.iat ?? 0) - nowS())).toBeLessThanOrEqual(5);
    expect((body as { exp: number }).exp).toBe(claims?.exp);

    // the same user and key through the device flow: identical claims but for iat and exp
    const direct = await signIn(fake, user, phone);
    const directClaims = (await verifyGhAssertion(identitySecret(), direct.assertion, Date.now())) as unknown as Record<string, unknown>;
    const browserClaims = claims as unknown as Record<string, unknown>;
    expect(Object.keys(browserClaims).sort()).toEqual(Object.keys(directClaims).sort());
    for (const key of Object.keys(directClaims)) {
      if (key !== "iat" && key !== "exp") expect(browserClaims[key], key).toEqual(directClaims[key]);
    }

    // and it is accepted by /pair/code, signed by the install key it is bound to
    const window = await openWindow(fake, user);
    const identity: Identity = { phone, user, assertion: (body as { gh_assertion: string }).gh_assertion };
    expect((await pairCode(identity, window.code)).status).toBe(200);
  });

  it("[20] the pass is minted at redeem, not at the callback: the stored handoff holds identity facts and nothing signed", async () => {
    const { hc } = await reachHandoff(web);
    const handoff = (await storedOauthRecord("oauth-handoff", hc)) as Record<string, unknown>;
    expect(Object.keys(handoff).sort()).toEqual(["challenge", "exp", "gh_id", "gh_login", "install_pubkey"]);
  });

  it("[20] a verifier the S256 challenge of which is known from an independent implementation (python hashlib) is accepted", async () => {
    const verifier = "hmd-test-verifier-".repeat(3);
    const knownSha256Hex = "b77d31b7df4c5d32bd102c1be96ab3ef84de928a4b0ed40a9a575034e774a617";
    const challenge = base64UrlEncode(Uint8Array.from(knownSha256Hex.match(/../g) as string[], (pair) => parseInt(pair, 16)));
    const hc = random32();
    const stored = await putOauthRecord("oauth-handoff", hc, {
      gh_id: 4242,
      gh_login: "octo-known",
      install_pubkey: newPhone().pub,
      challenge,
      exp: nowS() + 60,
    });
    expect(stored.status).toBe(200);

    const res = await redeemRequest({ hc, code_verifier: verifier });
    await expectOauthRow(res, "redeem.ok", { gh_id: 4242, gh_login: "octo-known" });
  });

  it("[21] the wrong verifier -> 400 handoff rejected, and the right one straight after -> 410: the guess burned the handoff", async () => {
    const { started, hc } = await reachHandoff(web);
    const wrong = await redeemRequest({ hc, code_verifier: random32() });
    await expectOauthRow(wrong, "redeem.rejected");
    const right = await redeemRequest({ hc, code_verifier: started.pkce.verifier });
    await expectOauthRow(right, "redeem.gone");
    expect(await storedOauthRecord("oauth-handoff", hc)).toBeUndefined();
  });

  it("[21] the challenge itself is not a verifier: the relay hashes what it is given, so a stolen challenge opens nothing (the `plain` attack)", async () => {
    const { started, hc } = await reachHandoff(web);
    const res = await redeemRequest({ hc, code_verifier: started.pkce.challenge });
    await expectOauthRow(res, "redeem.rejected");
  });

  it("[22] a second redeem with the right verifier -> 410; an aged-out handoff -> 410; an unknown hc -> 410", async () => {
    const first = await reachHandoff(web);
    await expectOauthRow(await redeemRequest({ hc: first.hc, code_verifier: first.started.pkce.verifier }), "redeem.ok", { gh_id: first.user.id, gh_login: first.user.login });
    await expectOauthRow(await redeemRequest({ hc: first.hc, code_verifier: first.started.pkce.verifier }), "redeem.gone");

    const aged = await reachHandoff(web);
    await editOauthRecord("oauth-handoff", aged.hc, (record) => {
      record.exp = nowS() - 1;
    });
    await expectOauthRow(await redeemRequest({ hc: aged.hc, code_verifier: aged.started.pkce.verifier }), "redeem.gone");
    expect(await storedOauthRecord("oauth-handoff", aged.hc), "consumed on read, not left for the alarm").toBeUndefined();

    await expectOauthRow(await redeemRequest({ hc: random32(), code_verifier: random32() }), "redeem.gone");
  });

  describe("[23] malformed hc or verifier", () => {
    const VERIFIER_OK = "A".repeat(43);
    const HC_CASES: [string, unknown][] = [
      ["hc missing", undefined],
      ["hc one character short", "A".repeat(42)],
      ["hc one character long", "A".repeat(44)],
      ["hc with a + in it", `${"A".repeat(42)}+`],
      ["hc padded with =", `${"A".repeat(42)}=`],
      ["hc empty", ""],
      ["hc a number", 42],
      ["hc null", null],
      ["hc an array", [random32()]],
    ];
    const VERIFIER_CASES: [string, unknown][] = [
      ["code_verifier missing", undefined],
      ["code_verifier one character short (42)", "A".repeat(42)],
      ["code_verifier one character long (129)", "A".repeat(129)],
      ["code_verifier with a space", `${"A".repeat(42)} `],
      ["code_verifier with a +", `${"A".repeat(42)}+`],
      ["code_verifier with a =", `${"A".repeat(42)}=`],
      ["code_verifier with a /", `${"A".repeat(42)}/`],
      ["code_verifier with a non-ASCII character", `${"A".repeat(42)}é`],
      ["code_verifier empty", ""],
      ["code_verifier a number", 42],
      ["code_verifier null", null],
    ];

    it.each(HC_CASES)("%s -> 400 invalid redeem request", async (_label, hc) => {
      const res = await redeemRequest({ hc, code_verifier: VERIFIER_OK });
      await expectOauthRow(res, "redeem.invalid");
    });

    it.each(VERIFIER_CASES)("%s -> 400 invalid redeem request, and a live handoff survives it", async (_label, verifier) => {
      const { started, hc, user } = await reachHandoff(web);
      const res = await redeemRequest({ hc, code_verifier: verifier });
      await expectOauthRow(res, "redeem.invalid");
      expect(await storedOauthRecord("oauth-handoff", hc), "not burned").toBeDefined();
      await expectOauthRow(await redeemRequest({ hc, code_verifier: started.pkce.verifier }), "redeem.ok", { gh_id: user.id, gh_login: user.login });
    });

    it("the boundary lengths of a verifier are both accepted by the shape check: 43 and 128 characters", async () => {
      for (const length of [43, 128]) {
        const { hc } = await reachHandoff(web);
        const res = await redeemRequest({ hc, code_verifier: "A".repeat(length) });
        await expectOauthRow(res, "redeem.rejected"); // well formed, and not the verifier
      }
    });
  });

  it("[24] a body that is not JSON -> 400 invalid json; JSON that is not an object -> 400 invalid json; over 4096 bytes -> 413", async () => {
    for (const body of ["not json", "", "[1,2]", "null", "42", '"text"']) {
      await expectOauthRow(await redeemRequest(body), "redeem.invalid_json");
    }
    const big = JSON.stringify({ hc: random32(), code_verifier: "A".repeat(5000) });
    expect(big.length).toBeGreaterThan(4096);
    await expectOauthRow(await redeemRequest(big), "redeem.body_too_large");
  });

  it("[25] the 21st redeem in a window from one IP -> 429 with retry_after_s and Retry-After; another IP is unaffected", async () => {
    const ip = freshIp();
    for (let attempt = 1; attempt <= 20; attempt++) {
      await expectOauthRow(await redeemRequest({}, ip), "redeem.invalid");
    }
    await expectOauthRow(await redeemRequest({}, ip), "redeem.throttled");
    await expectOauthRow(await redeemRequest({}, freshIp()), "redeem.invalid");
  });

  it("[26] two simultaneous redeems of one handoff with the right verifier: exactly one 200 and one 410, three times over", async () => {
    for (let round = 1; round <= 3; round++) {
      const { started, hc, user } = await reachHandoff(web);
      const body = { hc, code_verifier: started.pkce.verifier };
      const answers = await Promise.all([redeemRequest(body), redeemRequest(body)]);
      expect(answers.map((res) => res.status).sort(), `round ${round}`).toEqual([200, 410]);
      for (const res of answers) {
        if (res.status === 200) await expectOauthRow(res, "redeem.ok", { gh_id: user.id, gh_login: user.login });
        else await expectOauthRow(res, "redeem.gone");
      }
    }
  });

  it("[27] disabled: 404", async () => {
    const { started, hc } = await reachHandoff(web);
    const res = await worker.fetch(
      new Request(`${OAUTH_BASE}/identity/github/oauth/redeem`, {
        method: "POST",
        headers: { "content-type": "application/json", "CF-Connecting-IP": freshIp() },
        body: JSON.stringify({ hc, code_verifier: started.pkce.verifier }),
      }),
      envWith({ RELAY_IDENTITY_SECRET: undefined })
    );
    await expectOauthRow(res, "probe.off");
    expect(await storedOauthRecord("oauth-handoff", hc), "a disabled relay burns nothing").toBeDefined();
  });
});

// ============================================================================================
// Across the four routes
// ============================================================================================

describe("across the routes: what is logged, what is stored", () => {
  it("[28] no log line of any of the four routes holds the code, state, relay state, hc, verifier, challenge, install key, either GitHub token, the client secret or the pass", async () => {
    const secrets: string[] = [clientSecret()];
    const keep = (...values: string[]): void => {
      secrets.push(...values);
    };

    const log = await withRelayLog(async () => {
      // a whole sign-in, and then the pass in use
      const user = newUser();
      const phone = newPhone();
      const pkce = newPkce();
      const started = await startFlow(phone, pkce);
      const code = web.authorizationCode(user);
      const handoff = await expectOauthRow(await callbackRequest(callbackQuery(code, started.relayState)), "callback.handoff", { app_state: pkce.state });
      const hc = handoff.location?.searchParams.get("hc") as string;
      const redeemed = await expectOauthRow(await redeemRequest({ hc, code_verifier: pkce.verifier }), "redeem.ok", { gh_id: user.id, gh_login: user.login });
      keep(pkce.state, pkce.verifier, pkce.challenge, phone.pub, started.relayState, code, hc, String(redeemed.body?.gh_assertion), String(user.id), user.login, ...web.issued);

      // a person who declines, a replay, a wrong verifier, a malformed request, a throttled start
      const declined = await startFlow();
      await callbackRequest(toQuery([["error", "access_denied"], ["state", declined.relayState]]));
      await callbackRequest(callbackQuery(code, started.relayState));
      const burned = await reachHandoff(web);
      const guess = random32();
      await redeemRequest({ hc: burned.hc, code_verifier: guess }); // rejected, and burned by it
      await redeemRequest({ hc: burned.hc, code_verifier: random32() }); // expired: it is gone
      await redeemRequest({ hc: burned.hc, code_verifier: "short" }); // rejected: not even a verifier's shape
      await startRequest(toQuery(startPairs(newPkce(), newPhone()).slice(1)));
      const ip = freshIp();
      for (let attempt = 1; attempt <= 11; attempt++) await startRequest(toQuery(startPairs(newPkce(), newPhone())), ip);
      keep(declined.relayState, declined.pkce.state, burned.hc, burned.code, burned.started.relayState, burned.started.pkce.verifier, guess);

      // GitHub failing on every leg the relay calls, which is when the relay logs the most
      for (const arrange of [
        () => web.respondOnce(500, { message: "m" }),
        () => web.networkErrorOnce(),
        () => web.respondOnce(200, { error: "incorrect_client_credentials" }),
        () => fake.respondOnce("check", 500, {}),
        () => fake.respondOnce("delete", 500, {}),
      ]) {
        const failing = await startFlow();
        const failingCode = web.authorizationCode(newUser());
        arrange();
        await callbackRequest(callbackQuery(failingCode, failing.relayState));
        keep(failing.relayState, failing.pkce.state, failingCode);
      }
      keep(...web.issued);
    });

    const logged = log.lines.join("\n");
    for (const secret of secrets) expect(logged).not.toContain(secret);

    // the three new events carry an outcome word and nothing else
    const OUTCOMES = new Set(["ok", "denied", "exchange_failed", "throttled", "expired", "rejected"]);
    const seen = new Set<string>();
    for (const event of ["oauth_start", "oauth_callback", "oauth_redeem"]) {
      const entries = log.events(event);
      expect(entries.length, `${event} is logged`).toBeGreaterThan(0);
      for (const entry of entries) {
        expect(Object.keys(entry).sort(), event).toEqual(["event", "outcome", "session_id"]);
        expect(OUTCOMES.has(entry.outcome as string), `${event}: ${String(entry.outcome)}`).toBe(true);
        seen.add(`${event}:${String(entry.outcome)}`);
      }
    }
    for (const outcome of [
      "oauth_start:ok",
      "oauth_start:throttled",
      "oauth_start:rejected",
      "oauth_callback:ok",
      "oauth_callback:denied",
      "oauth_callback:expired",
      "oauth_callback:exchange_failed",
      "oauth_redeem:ok",
      "oauth_redeem:rejected",
      "oauth_redeem:expired",
    ]) {
      expect(seen, outcome).toContain(outcome);
    }
    // what GitHub's door logs on a failure is its call name, a kind and a status
    for (const entry of log.events("github_error")) {
      expect(Object.keys(entry).sort().filter((key) => !["status"].includes(key))).toEqual(["call", "event", "kind", "session_id"]);
    }
  });

  it("[29] no stored value holds the verifier, a GitHub token (access or refresh), the authorization code or the client secret -- at each step a record exists", async () => {
    const before = await takeObjectIds();
    const user = newUser();
    const phone = newPhone();
    const pkce = newPkce();
    const sweeps: string[] = [];
    const sweep = async (): Promise<void> => {
      sweeps.push(...(await snapshotNewObjects(before)));
    };

    const started = await startFlow(phone, pkce);
    await sweep(); // the pending record is there
    const code = web.authorizationCode(user);
    const handoff = await expectOauthRow(await callbackRequest(callbackQuery(code, started.relayState)), "callback.handoff", { app_state: pkce.state });
    await sweep(); // the handoff is there
    const hc = handoff.location?.searchParams.get("hc") as string;
    const redeemed = await expectOauthRow(await redeemRequest({ hc, code_verifier: pkce.verifier }), "redeem.ok", { gh_id: user.id, gh_login: user.login });
    await sweep(); // and everything the redeem touched

    const stored = sweeps.join("\n");
    // the sweeps are not vacuous: they saw both records, which hold the challenge and the identity facts
    expect(stored).toContain("oauth_record");
    expect(stored).toContain(pkce.challenge);
    expect(stored).toContain(user.login);
    for (const secret of [pkce.verifier, code, clientSecret(), String(redeemed.body?.gh_assertion), ...web.issued]) {
      expect(stored, "a secret is in storage").not.toContain(secret);
    }
    expect(web.issued).toHaveLength(2); // an access token and a refresh token were handed out and dropped
  });

  it("[30] scripts/check-no-logged-urls.mjs passes: no raw console call outside logging.ts, none that touches a URL (the script itself runs in `npm test`; this is its rule, on every source file, including the new one)", () => {
    const sources = import.meta.glob("../src/*.ts", { query: "?raw", import: "default", eager: true }) as Record<string, string>;
    const files = Object.entries(sources);
    expect(files.map(([file]) => file.split("/").pop())).toContain("github-oauth.ts");
    for (const [file, text] of files) {
      const isLoggingModule = file.endsWith("/logging.ts");
      const consoleCalls = (text.match(/console\.(log|warn|error|info)\(/g) ?? []).length;
      if (!isLoggingModule) expect(consoleCalls, `${file}: a raw console call (route logging through logEvent)`).toBe(0);
      expect(/console\.[a-z]+\([^;]*\.url/i.test(text), `${file}: a console call that appears to reference a .url value`).toBe(false);
    }
  });
});

// ============================================================================================
// The two records' storage
// ============================================================================================

describe("the records: single use, reclaimed by their own alarm, failing closed when they are not what the relay wrote", () => {
  it("a consumed record leaves neither data nor an alarm behind", async () => {
    const { started, hc } = await reachHandoff(web);
    expect(await dumpStorage(recordStub("oauth-state", started.relayState))).toBe("[]");
    expect(await oauthAlarm("oauth-state", started.relayState)).toBeNull();

    await redeemRequest({ hc, code_verifier: started.pkce.verifier });
    expect(await dumpStorage(recordStub("oauth-handoff", hc))).toBe("[]");
    expect(await oauthAlarm("oauth-handoff", hc)).toBeNull();
  });

  it("the alarm reclaims a record that has lapsed past its grace, and only re-arms one that has not", async () => {
    for (const kind of ["oauth-state", "oauth-handoff"] as const) {
      const key = kind === "oauth-state" ? (await startFlow()).relayState : (await reachHandoff(web)).hc;
      const record = (await storedOauthRecord(kind, key)) as { exp: number };

      // live: the alarm firing early costs a re-arm and nothing else
      expect(await runDurableObjectAlarm(recordStub(kind, key))).toBe(true);
      expect(await storedOauthRecord(kind, key), `${kind}: kept`).toBeDefined();
      expect(await oauthAlarm(kind, key)).toBe((record.exp + 60) * 1000);

      // lapsed but inside the 60 s grace: still not reclaimed, still not usable (see [18], [22])
      await editOauthRecord(kind, key, (r) => {
        r.exp = nowS() - 30;
      });
      await runDurableObjectAlarm(recordStub(kind, key));
      expect(await storedOauthRecord(kind, key), `${kind}: inside the grace`).toBeDefined();

      // lapsed past the grace: reclaimed, storage and all
      await editOauthRecord(kind, key, (r) => {
        r.exp = nowS() - 61;
      });
      expect(await runDurableObjectAlarm(recordStub(kind, key))).toBe(true);
      expect(await storedOauthRecord(kind, key), `${kind}: reclaimed`).toBeUndefined();
      expect(await dumpStorage(recordStub(kind, key))).toBe("[]");
    }
  });

  it("the record handlers are internal: not public subpaths of the session route, and a record's instance name is not a session id", async () => {
    for (const subpath of ["oauth-put", "oauth-take"]) {
      const res = await postPublic(`/session/${crypto.randomUUID()}/${subpath}`);
      expect(res.status, subpath).toBe(404);
      expect(await res.json(), subpath).toEqual({ error: "not found" });
    }
    const { relayState } = await startFlow();
    const res = await postPublic(`/session/oauth-state:${relayState}/oauth-take`);
    expect(res.status).toBe(400);
    expect(await storedOauthRecord("oauth-state", relayState), "nothing was taken").toBeDefined();
  });

  it("a state record that is not what the relay wrote is treated as missing: the 400 page, no GitHub call", async () => {
    const edits: [string, (record: Record<string, unknown>) => void][] = [
      ["no app_state", (r) => delete r.app_state],
      ["a challenge of the wrong length", (r) => (r.challenge = "A".repeat(42))],
      ["an install_pubkey that is a number", (r) => (r.install_pubkey = 7)],
      ["an app_state with a character outside base64url", (r) => (r.app_state = `${"A".repeat(42)}\n`)],
      ["no exp", (r) => delete r.exp],
      ["an exp that is not a number", (r) => (r.exp = "soon")],
    ];
    for (const [label, edit] of edits) {
      const started = await startFlow();
      await editOauthRecord("oauth-state", started.relayState, edit);
      const res = await callbackRequest(callbackQuery(web.authorizationCode(newUser()), started.relayState));
      await expectOauthRow(res, "callback.expired");
      expect(web.calls, label).toHaveLength(0);
      expect(fake.calls, label).toHaveLength(0);
    }
  });

  it("a handoff record that is not what the relay wrote is treated as missing: 410, nothing minted", async () => {
    const edits: [string, (record: Record<string, unknown>) => void][] = [
      ["a gh_id that is a string", (r) => (r.gh_id = "123")],
      ["a gh_id of zero", (r) => (r.gh_id = 0)],
      ["an empty gh_login", (r) => (r.gh_login = "")],
      ["a gh_login over 64 characters", (r) => (r.gh_login = "a".repeat(65))],
      ["an install_pubkey of the wrong length", (r) => (r.install_pubkey = "A".repeat(44))],
      ["no challenge", (r) => delete r.challenge],
      ["no exp", (r) => delete r.exp],
    ];
    for (const [label, edit] of edits) {
      const { started, hc } = await reachHandoff(web);
      await editOauthRecord("oauth-handoff", hc, edit);
      const res = await redeemRequest({ hc, code_verifier: started.pkce.verifier });
      await expectOauthRow(res, "redeem.gone");
      expect(await storedOauthRecord("oauth-handoff", hc), `${label}: consumed`).toBeUndefined();
    }
  });
});

/** A POST through the Worker's own router, for the tests that look at what is not a route. */
function postPublic(path: string): Promise<Response> {
  return SELF.fetch(`${OAUTH_BASE}${path}`, { method: "POST", headers: { "CF-Connecting-IP": freshIp() } });
}

// ============================================================================================
// The contract
// ============================================================================================

describe("contract (relay/contract/github-oauth.json)", () => {
  it("has every row asserted by a test above (run the whole file: a filtered run leaves rows unreached)", () => {
    expect(allOauthRowKeys().filter((key) => !oauthCovered.has(key))).toEqual([]);
  });
});
