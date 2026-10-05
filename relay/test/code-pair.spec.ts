// Pair by session code (design of record: hmdapp docs/superpowers/specs/2026-10-05-pair-by-session-code.md),
// the relay's side, driven end to end through the real Worker and Durable Objects in workerd.
// The wire is relay/contract/code-pair.json: every response asserted here is a row of that
// file, and the last test fails if a row was never asserted, so a status added to the contract
// cannot go untested. The pure pieces (assertion, PoP check, validators, vectors) are
// code-pair-units.spec.ts.
//
// GitHub is faked in-process (code-pair-helpers.ts's FakeGitHub, reached through the
// GITHUB_API_BASE seam) and never touched. Real clocks throughout: workerd's timers cannot be
// advanced from a test, so a lapsed window is arranged by editing the stored record or index
// entry rather than waited for.
//
// The invariants INV-39..INV-44 each have their own block. The blocks that guard a single
// check -- the gh_id equality, the `released` flag, the one 404 -- assert it at BOTH layers
// that carry it (the index in front, the session behind) because a test that only reaches the
// check through the other layer would let a mutant that deletes it survive.

import { SELF, listDurableObjectIds, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/worker";
import {
  GH_ASSERTION_TTL_S,
  base64UrlDecode,
  base64UrlEncode,
  mintGhAssertion,
  verifyGhAssertion,
  type GhAssertionClaims,
} from "../src/pairing";
import type { Env } from "../src/types";
import { openHmdSocket, withRelayLog } from "./hmd-socket";
import {
  BASE,
  FakeGitHub,
  HmdLines,
  TEST_DEVICE_PUBKEY,
  allRowKeys,
  claimSocket,
  contract,
  covered,
  directRelease,
  dumpStorage,
  expectMatch,
  expectRow,
  freshIp,
  indexStub,
  keyRevealEnvelope,
  lapseIndexEntry,
  lapseSession,
  newCommitment,
  newPhone,
  newUser,
  nowS,
  openWindow,
  pairCode,
  pairInit,
  popSig,
  postHmdFrame,
  randomCode,
  reconnectSocket,
  registerWindow,
  revokeSession,
  sessionStub,
  signIn,
  sleep,
  snapshot,
  storedIndex,
  storedRecord,
  typedEnv,
  type Identity,
} from "./code-pair-helpers";

// Many tests here drive a whole pairing -- sign-in, a window, a release, a bind -- or fill a
// throttle (10 and 20 requests), each request a few Durable Object hops in a real workerd:
// seconds, not milliseconds, so the 5 s default would fail them for being thorough.
vi.setConfig({ testTimeout: 60_000 });

const fake = new FakeGitHub();
beforeEach(() => fake.install());
afterEach(() => fake.uninstall());

const clientId = (): string => typedEnv.GITHUB_CLIENT_ID as string;

function post(path: string, body: unknown, ip: string = freshIp()): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "CF-Connecting-IP": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
const signInRequest = (body: unknown, ip?: string): Promise<Response> => post("/identity/github", body, ip);
const revokeRequest = (body: unknown, ip?: string): Promise<Response> => post("/identity/github/revoke", body, ip);

/** A user with a phone signed in and a laptop window open, for the many tests that need both. */
async function ready() {
  const user = newUser();
  const identity = await signIn(fake, user);
  const window = await openWindow(fake, user);
  return { user, identity, window };
}

/** A correctly signed assertion for `identity`, with any claim overridden: the way a test
 *  makes an expired or otherwise unusual one without waiting a month. */
function assertionFor(
  identity: Identity,
  over: Partial<GhAssertionClaims> = {},
  secret: string = typedEnv.RELAY_IDENTITY_SECRET as string
): Promise<string> {
  const iat = nowS();
  return mintGhAssertion(secret, {
    v: 1,
    role: "device",
    gh_id: identity.user.id,
    gh_login: identity.user.login,
    install_pubkey: identity.phone.pub,
    iat,
    exp: iat + GH_ASSERTION_TTL_S,
    ...over,
  });
}

// ============================================================================================
// The config gate
// ============================================================================================

describe("config gate: any of GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET / RELAY_IDENTITY_SECRET unset -> 503", () => {
  const VARS = ["GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "RELAY_IDENTITY_SECRET"] as const;

  const envWith = (name: (typeof VARS)[number], value: string | undefined): Env =>
    ({
      SESSION: typedEnv.SESSION,
      RELAY_SIGNING_SECRET: typedEnv.RELAY_SIGNING_SECRET,
      GITHUB_CLIENT_ID: typedEnv.GITHUB_CLIENT_ID,
      GITHUB_CLIENT_SECRET: typedEnv.GITHUB_CLIENT_SECRET,
      RELAY_IDENTITY_SECRET: typedEnv.RELAY_IDENTITY_SECRET,
      GITHUB_API_BASE: typedEnv.GITHUB_API_BASE,
      [name]: value,
    }) as Env;

  const requests: [string, () => Request][] = [
    [
      "identity_github",
      () => new Request(`${BASE}/identity/github`, { method: "POST", body: JSON.stringify({ gh_token: "gho_x", install_pubkey: newPhone().pub }) }),
    ],
    [
      "identity_revoke",
      () => new Request(`${BASE}/identity/github/revoke`, { method: "POST", body: JSON.stringify({ gh_token: "gho_x" }) }),
    ],
    [
      "pair_code",
      () => new Request(`${BASE}/pair/code`, { method: "POST", body: JSON.stringify({ code: "4SELK" }) }),
    ],
    [
      "session_code",
      () =>
        new Request(`${BASE}/session/${crypto.randomUUID()}/code`, {
          method: "POST",
          headers: { Authorization: "Bearer x" },
          body: JSON.stringify({ code: "4SELK", gh_token: "gho_x", hmd_commit: base64UrlEncode(new Uint8Array(32)) }),
        }),
    ],
  ];

  for (const [route, make] of requests) {
    for (const name of VARS) {
      for (const value of [undefined, ""]) {
        it(`${route} answers 503 before touching GitHub when ${name} is ${value === undefined ? "unset" : "empty"}`, async () => {
          const res = await worker.fetch(make(), envWith(name, value));
          await expectRow(res, `${route}.disabled`);
          expect(fake.calls).toHaveLength(0);
        });
      }
    }
  }

  it("is not a gate on the QR flow: /pair/init still works with code pairing off", async () => {
    const res = await worker.fetch(
      new Request(`${BASE}/pair/init`, { method: "POST", headers: { "CF-Connecting-IP": freshIp() } }),
      envWith("RELAY_IDENTITY_SECRET", undefined)
    );
    expect(res.status).toBe(200);
  });
});

// ============================================================================================
// POST /identity/github  (spec 6.1)
// ============================================================================================

describe("POST /identity/github (spec 6.1)", () => {
  it("signs a phone in: verifies the token with the App, deletes it at GitHub, mints an assertion bound to the install key", async () => {
    const user = newUser();
    const phone = newPhone();
    const token = fake.phoneToken(user);

    const res = await signInRequest({ gh_token: token, install_pubkey: phone.pub });
    const body = await expectRow(res, "identity_github.ok", { gh_id: user.id, gh_login: user.login });

    const claims = await verifyGhAssertion(typedEnv.RELAY_IDENTITY_SECRET as string, body.gh_assertion as string, Date.now());
    expect(claims).toMatchObject({ v: 1, role: "device", gh_id: user.id, gh_login: user.login, install_pubkey: phone.pub });
    expect((claims?.exp ?? 0) - (claims?.iat ?? 0)).toBe(GH_ASSERTION_TTL_S);
    expect(Math.abs((claims?.iat ?? 0) - nowS())).toBeLessThanOrEqual(5);
    expect(body.exp).toBe(claims?.exp);

    // exactly the two App calls, in order, authenticated as the App, the token only in the body
    const basic = `Basic ${btoa(`${typedEnv.GITHUB_CLIENT_ID}:${typedEnv.GITHUB_CLIENT_SECRET}`)}`;
    expect(fake.calls.map((c) => `${c.method} ${c.path}`)).toEqual([
      `POST /applications/${clientId()}/token`,
      `DELETE /applications/${clientId()}/token`,
    ]);
    for (const call of fake.calls) {
      expect(call.authorization).toBe(basic);
      expect(call.body).toEqual({ access_token: token });
      expect(call.userAgent).toBe("hmd-relay");
      expect(call.hasSignal).toBe(true);
    }
  });

  it("is single use by construction: the token is gone at GitHub afterwards, so replaying it is rejected", async () => {
    const user = newUser();
    const phone = newPhone();
    const token = fake.phoneToken(user);
    await expectRow(await signInRequest({ gh_token: token, install_pubkey: phone.pub }), "identity_github.ok");
    expect(fake.isPhoneTokenLive(token)).toBe(false);

    const replay = await signInRequest({ gh_token: token, install_pubkey: phone.pub });
    await expectRow(replay, "identity_github.github_rejected");
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["a number", 42],
    ["31 bytes", base64UrlEncode(new Uint8Array(31))],
    ["33 bytes", base64UrlEncode(new Uint8Array(33))],
    ["padded", `${base64UrlEncode(new Uint8Array(32))}=`],
    ["not base64", "not base64!!"],
  ])("refuses an install_pubkey that is %s with 400 and calls nobody", async (_label, installPubkey) => {
    const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: installPubkey });
    await expectRow(res, "identity_github.bad_install_pubkey");
    expect(fake.calls).toHaveLength(0);
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["a number", 42],
    ["null", null],
  ])("refuses a gh_token that is %s with 400 and calls nobody", async (_label, ghToken) => {
    const res = await signInRequest({ gh_token: ghToken, install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.missing_gh_token");
    expect(fake.calls).toHaveLength(0);
  });

  it.each([
    ["with a space", "has space"],
    ["with a newline", "ghu_abc\nX-Injected: 1"],
    ["longer than 255", "a".repeat(256)],
    ["not ASCII", "café-token"],
  ])("rejects a gh_token %s as a token without sending it upstream", async (_label, ghToken) => {
    const res = await signInRequest({ gh_token: ghToken, install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.github_rejected");
    expect(fake.calls).toHaveLength(0);
  });

  it("rejects a token GitHub does not know, and deletes nothing", async () => {
    const res = await signInRequest({ gh_token: "ghu_nobody_issued_this", install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.github_rejected");
    expect(fake.callsOf("delete")).toHaveLength(0);
  });

  it("rejects a token issued to another App (GitHub answers 404 for it), and deletes nothing", async () => {
    const token = fake.phoneToken(newUser(), "Iv-some-other-app");
    const res = await signInRequest({ gh_token: token, install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.github_rejected");
    expect(fake.callsOf("delete")).toHaveLength(0);
    expect(fake.isPhoneTokenLive(token)).toBe(true);
  });

  it("rejects an answer that names another App even if GitHub said 200, and deletes nothing", async () => {
    const user = newUser();
    fake.respondOnce("check", 200, { app: { client_id: "Iv-some-other-app" }, user: { id: user.id, login: user.login } });
    const res = await signInRequest({ gh_token: fake.phoneToken(user), install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.github_rejected");
    expect(fake.callsOf("delete")).toHaveLength(0);
  });

  it("rejects a token GitHub calls invalid (422)", async () => {
    fake.respondOnce("check", 422, { message: "Validation Failed" });
    const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.github_rejected");
  });

  it("throttles per source IP at 10 a minute, before any GitHub call (429, Retry-After 60)", async () => {
    const ip = freshIp();
    const body = { gh_token: "ghu_nobody_issued_this", install_pubkey: newPhone().pub };
    for (let i = 0; i < 10; i++) {
      await expectRow(await signInRequest(body, ip), "identity_github.github_rejected");
    }
    const callsBefore = fake.calls.length;

    const eleventh = await signInRequest(body, ip);
    await expectRow(eleventh, "identity_github.throttled");
    expect(fake.calls).toHaveLength(callsBefore);

    // another source is untouched
    const user = newUser();
    const other = await signInRequest({ gh_token: fake.phoneToken(user), install_pubkey: newPhone().pub });
    expect(other.status).toBe(200);
  });

  it("answers 502 when GitHub fails: 5xx, a dropped connection, an unreadable answer, no user in it", async () => {
    const phone = newPhone();
    const attempts: [string, () => void][] = [
      ["a 500", () => fake.respondOnce("check", 500, { message: "boom" })],
      ["a dropped connection", () => fake.networkErrorOnce("check")],
      ["a body that is not an object", () => fake.respondOnce("check", 200, "<html>an error page</html>")],
      ["a 200 without a user", () => fake.respondOnce("check", 200, { app: { client_id: clientId() } })],
      ["a user without an id", () => fake.respondOnce("check", 200, { app: { client_id: clientId() }, user: { login: "x" } })],
      ["a status it does not understand", () => fake.respondOnce("check", 403, { message: "forbidden" })],
    ];
    for (const [label, arrange] of attempts) {
      arrange();
      const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: phone.pub });
      await expectRow(res, "identity_github.github_unavailable");
      expect(fake.callsOf("delete"), label).toHaveLength(0);
    }
  });

  it("answers 502, not 401, when GitHub refuses the relay's own client credentials", async () => {
    fake.respondOnce("check", 401, { message: "Bad credentials" });
    const log = await withRelayLog(async () => {
      const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: newPhone().pub });
      await expectRow(res, "identity_github.github_unavailable");
    });
    // the operator sees a misconfiguration in the tail, with no token in it
    expect(log.events("github_error")).toHaveLength(1);
  });

  it("gives up on GitHub after 5 s and says so with 502 (the wait is bounded)", async () => {
    fake.hangOnce("check");
    const started = Date.now();
    const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: newPhone().pub });
    const waited = Date.now() - started;

    await expectRow(res, "identity_github.github_unavailable");
    expect(waited).toBeGreaterThanOrEqual(4500);
    expect(waited).toBeLessThan(9000);
    expect(fake.callsOf("delete")).toHaveLength(0);
  }, 20_000);

  it("INV-39: mints no assertion for a token whose deletion did not confirm", async () => {
    const attempts: [string, () => void][] = [
      ["a 500", () => fake.respondOnce("delete", 500, {})],
      ["a dropped connection", () => fake.networkErrorOnce("delete")],
      ["a 403", () => fake.respondOnce("delete", 403, {})],
    ];
    for (const [, arrange] of attempts) {
      arrange();
      const token = fake.phoneToken(newUser());
      const res = await signInRequest({ gh_token: token, install_pubkey: newPhone().pub });
      const body = await expectRow(res, "identity_github.github_unavailable");
      expect(body).not.toHaveProperty("gh_assertion");
      expect(fake.isPhoneTokenLive(token)).toBe(true); // GitHub never saw the delete
    }
  });

  it("treats a token already gone at delete time (404) as deleted: the check just passed, nothing is left to revoke", async () => {
    fake.respondOnce("delete", 404, { message: "Not Found" });
    const res = await signInRequest({ gh_token: fake.phoneToken(newUser()), install_pubkey: newPhone().pub });
    await expectRow(res, "identity_github.ok");
  });
});

// ============================================================================================
// POST /session/:id/code  (spec 6.2)
// ============================================================================================

describe("POST /session/:id/code (spec 6.2)", () => {
  it("registers a window: verifies the laptop's token with GET /user, answers the code, the login and the pairing exp", async () => {
    const user = newUser();
    const init = await pairInit();
    const code = randomCode();
    const commitment = newCommitment();
    const ghToken = fake.laptopToken(user);

    const res = await registerWindow(init, { code, gh_token: ghToken, hmd_commit: commitment.commit });
    await expectRow(res, "session_code.ok", { code, gh_login: user.login, exp: init.exp });

    // exactly one GitHub call, GET /user, the laptop's token as the bearer
    expect(fake.calls.map((c) => `${c.method} ${c.path}`)).toEqual(["GET /user"]);
    expect(fake.calls[0]?.authorization).toBe(`Bearer ${ghToken}`);
    expect(fake.calls[0]?.hasSignal).toBe(true);

    // the window is on the session, and the owner's index points at it for as long as the session's own window
    const record = await storedRecord(init.session_id);
    expect(record?.code_window).toEqual({ code, owner_gh_id: user.id, hmd_commit: commitment.commit, released: false });
    const entry = (await storedIndex(user.id))?.codes[code];
    expect(entry?.session_id).toBe(init.session_id);
    expect(Math.floor((entry?.exp ?? 0) / 1000)).toBe(init.exp);
  });

  it.each([
    ["missing", undefined],
    ["lowercase", "4selk"],
    ["four characters", "4SEL"],
    ["six characters", "4SELKX"],
    ["a zero", "40ELK"],
    ["an O", "4OELK"],
    ["a one", "41ELK"],
    ["an I", "4IELK"],
    ["a number", 45678],
    ["an array", ["4SELK"]],
  ])("refuses a code that is %s with 400, and calls nobody", async (_label, code) => {
    const init = await pairInit();
    const res = await registerWindow(init, { code, gh_token: fake.laptopToken(newUser()), hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.invalid_code");
    expect(fake.calls).toHaveLength(0);
  });

  it.each([
    ["missing", undefined],
    ["31 bytes", base64UrlEncode(new Uint8Array(31))],
    ["33 bytes", base64UrlEncode(new Uint8Array(33))],
    ["padded", `${base64UrlEncode(new Uint8Array(32))}=`],
    ["standard base64", btoa(String.fromCharCode(...new Uint8Array(32).fill(250)))],
    ["a number", 7],
  ])("refuses an hmd_commit that is %s with 400, and calls nobody", async (_label, commit) => {
    const init = await pairInit();
    const res = await registerWindow(init, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: commit });
    await expectRow(res, "session_code.invalid_hmd_commit");
    expect(fake.calls).toHaveLength(0);
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["a number", 42],
  ])("refuses a gh_token that is %s with 400", async (_label, ghToken) => {
    const init = await pairInit();
    const res = await registerWindow(init, { code: randomCode(), gh_token: ghToken, hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.missing_gh_token");
    expect(fake.calls).toHaveLength(0);
  });

  it("refuses a bearer that is not the session's with 401 `unauthorized`, and calls nobody", async () => {
    const init = await pairInit();
    const other = await pairInit();
    const body = { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: base64UrlEncode(new Uint8Array(32)) };

    await expectRow(await registerWindow(init, { ...body, bearer: other.relay_session_token }), "session_code.unauthorized");
    await expectRow(await registerWindow(init, { ...body, bearer: "" }), "session_code.unauthorized");
    const bare = await SELF.fetch(`${BASE}/session/${init.session_id}/code`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    await expectRow(bare, "session_code.unauthorized");
    expect(fake.calls).toHaveLength(0);
    expect((await storedRecord(init.session_id))?.code_window).toBeUndefined();
  });

  it("rejects a laptop token GitHub does not know with 401 `github token rejected`, and writes no window", async () => {
    const init = await pairInit();
    const res = await registerWindow(init, { code: randomCode(), gh_token: "gho_nobody_issued_this", hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.github_rejected");
    expect((await storedRecord(init.session_id))?.code_window).toBeUndefined();
  });

  it("rejects a laptop token that cannot be a token without sending it upstream", async () => {
    const init = await pairInit();
    const res = await registerWindow(init, { code: randomCode(), gh_token: "gho_abc\r\nX: 1", hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.github_rejected");
    expect(fake.calls).toHaveLength(0);
  });

  it("answers 502 when GitHub fails, and writes no window", async () => {
    for (const arrange of [() => fake.respondOnce("user", 500, {}), () => fake.networkErrorOnce("user"), () => fake.respondOnce("user", 200, { login: "x" })]) {
      arrange();
      const init = await pairInit();
      const res = await registerWindow(init, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: base64UrlEncode(new Uint8Array(32)) });
      await expectRow(res, "session_code.github_unavailable");
      expect((await storedRecord(init.session_id))?.code_window).toBeUndefined();
    }
  });

  it("answers 404 `session not found` for a session id that was never initialised", async () => {
    const res = await SELF.fetch(`${BASE}/session/${crypto.randomUUID()}/code`, {
      method: "POST",
      headers: { Authorization: "Bearer anything", "content-type": "application/json" },
      body: JSON.stringify({ code: randomCode(), gh_token: "gho_x", hmd_commit: base64UrlEncode(new Uint8Array(32)) }),
    });
    await expectRow(res, "session_code.session_not_found");
  });

  it("answers 409 when another live session of the same GitHub user holds the code, and leaves the first window intact", async () => {
    const user = newUser();
    const identity = await signIn(fake, user);
    const first = await openWindow(fake, user);

    const second = await pairInit();
    const res = await registerWindow(second, { code: first.code, gh_token: fake.laptopToken(user), hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.code_in_use");
    expect((await storedRecord(second.session_id))?.code_window).toBeUndefined();

    // the first window still releases, to the first session
    const released = await (await pairCode(identity, first.code)).json();
    expect(released).toMatchObject({ session_id: first.init.session_id });
  });

  it("is per GitHub user: another user may open a window under the same code", async () => {
    const code = randomCode();
    const a = newUser();
    const b = newUser();
    await openWindow(fake, a, code);
    const second = await openWindow(fake, b, code);
    const identityB = await signIn(fake, b);
    const released = (await (await pairCode(identityB, code)).json()) as { session_id: string };
    expect(released.session_id).toBe(second.init.session_id);
  });

  it("lets a renewal take the code over once the first window has lapsed", async () => {
    const user = newUser();
    const identity = await signIn(fake, user);
    const first = await openWindow(fake, user);
    await lapseSession(first.init.session_id);
    await lapseIndexEntry(user.id, first.code);

    const renewal = await pairInit();
    const res = await registerWindow(renewal, { code: first.code, gh_token: fake.laptopToken(user), hmd_commit: base64UrlEncode(new Uint8Array(32)) });
    await expectRow(res, "session_code.ok");

    const released = (await (await pairCode(identity, first.code)).json()) as { session_id: string };
    expect(released.session_id).toBe(renewal.session_id);
  });

  it("answers 410 for a session that is not pending: revoked, bound, or past its pairing window", async () => {
    const hmdCommit = base64UrlEncode(new Uint8Array(32));

    const revoked = await pairInit();
    await revokeSession(revoked);
    await expectRow(
      await registerWindow(revoked, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: hmdCommit }),
      "session_code.not_claimable"
    );

    const bound = await pairInit();
    await claimSocket(bound.session_id, bound.pairing_code);
    await expectRow(
      await registerWindow(bound, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: hmdCommit }),
      "session_code.not_claimable"
    );

    const lapsed = await pairInit();
    await lapseSession(lapsed.session_id);
    await expectRow(
      await registerWindow(lapsed, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: hmdCommit }),
      "session_code.not_claimable"
    );
    expect(fake.calls).toHaveLength(0);
  });

  it("INV-40: a window that was released cannot be registered again (410), so it cannot be released twice", async () => {
    const { identity, window } = await ready();
    expect((await pairCode(identity, window.code)).status).toBe(200);

    const again = await registerWindow(window.init, {
      code: window.code,
      gh_token: fake.laptopToken(identity.user),
      hmd_commit: window.commitment.commit,
    });
    await expectRow(again, "session_code.not_claimable");
    expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(true);
    expect((await pairCode(identity, window.code)).status).toBe(404);
  });

  it("registering the same window again is harmless: one index entry, still releasable once", async () => {
    const user = newUser();
    const identity = await signIn(fake, user);
    const window = await openWindow(fake, user);
    const again = await registerWindow(window.init, { code: window.code, gh_token: fake.laptopToken(user), hmd_commit: window.commitment.commit });
    await expectRow(again, "session_code.ok");
    expect(Object.keys((await storedIndex(user.id))?.codes ?? {})).toEqual([window.code]);
    expect((await pairCode(identity, window.code)).status).toBe(200);
  });

  it("registering a different code for the same session retires the old one", async () => {
    const user = newUser();
    const identity = await signIn(fake, user);
    const window = await openWindow(fake, user);
    const newCode = randomCode();
    const res = await registerWindow(window.init, { code: newCode, gh_token: fake.laptopToken(user), hmd_commit: window.commitment.commit });
    expect(res.status).toBe(200);

    expect(Object.keys((await storedIndex(user.id))?.codes ?? {})).toEqual([newCode]);
    expect((await pairCode(identity, window.code)).status).toBe(404);
    expect((await pairCode(identity, newCode)).status).toBe(200);
  });

  it("throttles to 6 registrations a minute per session (429, Retry-After 60), before any GitHub call", async () => {
    const init = await pairInit();
    const body = { code: "nope", gh_token: fake.laptopToken(newUser()), hmd_commit: base64UrlEncode(new Uint8Array(32)) };
    for (let i = 0; i < 6; i++) await expectRow(await registerWindow(init, body), "session_code.invalid_code");

    await expectRow(
      await registerWindow(init, { code: randomCode(), gh_token: fake.laptopToken(newUser()), hmd_commit: body.hmd_commit }),
      "session_code.throttled"
    );
    expect(fake.calls).toHaveLength(0);

    // the budget is the session's own
    const other = await openWindow(fake, newUser());
    expect(other.init.session_id).not.toBe(init.session_id);
  });
});

// ============================================================================================
// POST /pair/code  (spec 6.3)
// ============================================================================================

describe("POST /pair/code (spec 6.3)", () => {
  it("releases the window to the phone signed in as the laptop's GitHub user: session, pairing code, commitment, exp", async () => {
    const { user, identity, window } = await ready();
    const res = await pairCode(identity, window.code, { device_label: "Pixel 9a" });
    await expectRow(res, "pair_code.ok", {
      session_id: window.init.session_id,
      pairing_code: window.init.pairing_code,
      hmd_commit: window.commitment.commit,
      exp: window.init.exp,
    });

    const record = await storedRecord(window.init.session_id);
    expect(record?.code_window).toMatchObject({ released: true, device_label: "Pixel 9a", gh_login: user.login });
    expect((await storedIndex(user.id))?.codes[window.code]).toBeUndefined();
  });

  it("what it releases is the pairing code the existing claim socket takes, as after a QR scan", async () => {
    const { identity, window } = await ready();
    const released = (await (await pairCode(identity, window.code)).json()) as { session_id: string; pairing_code: string };
    const phone = await claimSocket(released.session_id, released.pairing_code);
    const first = await phone.next();
    expect(first).toMatchObject({ type: "device_bound", sender: "relay" });
    expect((first?.payload as { device_token?: string }).device_token).toEqual(expect.any(String));
  });

  it.each([
    ["lowercase", "4selk"],
    ["four characters", "4SEL"],
    ["a zero", "40ELK"],
    ["a number", 45678],
    ["missing", undefined],
  ])("refuses a code that is %s with 400", async (_label, code) => {
    const identity = await signIn(fake);
    const body = JSON.stringify({ code, gh_assertion: identity.assertion, ts: nowS(), sig: "x", device_label: "Pixel 9a" });
    await expectRow(await pairCode(identity, "unused", { rawBody: body }), "pair_code.invalid_code");
  });

  it.each([
    ["empty", ""],
    ["33 characters", "a".repeat(33)],
    ["a newline", "Pixel\n9a"],
    ["an ESC", `Pixel${String.fromCharCode(27)}[2J`],
    ["a NUL", `Pixel${String.fromCharCode(0)}9a`],
    ["a DEL", `Pixel${String.fromCharCode(0x7f)}9a`],
    ["a C1 control", `Pixel${String.fromCharCode(0x85)}9a`],
    ["a right-to-left override", `Pixel${String.fromCodePoint(0x202e)}9a`],
    ["a line separator", `Pixel${String.fromCodePoint(0x2028)}9a`],
    ["a number", 9],
    ["missing", undefined],
  ])("refuses a device_label that is %s with 400", async (_label, label) => {
    const { identity, window } = await ready();
    await expectRow(await pairCode(identity, window.code, { device_label: label }), "pair_code.invalid_device_label");
    expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
  });

  it("accepts labels at the edges: one character, 32 characters, 32 emoji", async () => {
    for (const label of ["x", "a".repeat(32), String.fromCodePoint(0x1f4f1).repeat(32)]) {
      const { identity, window } = await ready();
      expect((await pairCode(identity, window.code, { device_label: label })).status, label).toBe(200);
    }
  });

  describe("identity", () => {
    it("refuses an assertion past its exp with 401 `identity expired`", async () => {
      const { identity, window } = await ready();
      const expired = { ...identity, assertion: await assertionFor(identity, { iat: nowS() - 100, exp: nowS() - 10 }) };
      await expectRow(await pairCode(expired, window.code), "pair_code.identity_expired");
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
    });

    it("refuses an assertion that is forged, signed with the relay's OTHER secret, tampered, malformed or missing", async () => {
      const { identity, window } = await ready();
      const forged = await assertionFor(identity, {}, "some-other-secret");
      const withDeviceTokenSecret = await assertionFor(identity, {}, typedEnv.RELAY_SIGNING_SECRET as string);
      // a payload naming someone else, under the signature of the genuine one
      const signature = identity.assertion.split(".")[1] as string;
      const claims = { v: 1, role: "device", gh_id: 1, gh_login: "x", install_pubkey: identity.phone.pub, iat: nowS(), exp: nowS() + 99999 };
      const tampered = `${base64UrlEncode(new TextEncoder().encode(JSON.stringify(claims)))}.${signature}`;

      for (const assertion of [forged, withDeviceTokenSecret, tampered, "not-an-assertion", "", "a.b.c"]) {
        await expectRow(await pairCode({ ...identity, assertion }, window.code), "pair_code.identity_expired");
      }
      const missing = JSON.stringify({ code: window.code, ts: nowS(), sig: popSig(identity.phone, window.code, nowS()), device_label: "Pixel 9a" });
      await expectRow(await pairCode(identity, window.code, { rawBody: missing }), "pair_code.identity_expired");
    });

    it("refuses an assertion minted before the user's last revoke with 401 `identity revoked`, and honours one minted after", async () => {
      const { user, identity, window } = await ready();
      // Assertions and `not_before` are whole seconds and the spec honours `iat >= not_before`, so
      // a sign-in in the same second as the revoke survives it. The phone this models was lost
      // earlier than that.
      await sleep(1100);
      const revoke = await revokeRequest({ gh_token: fake.laptopToken(user) });
      const { not_before: notBefore } = (await revoke.json()) as { not_before: number };

      await expectRow(await pairCode(identity, window.code), "pair_code.identity_revoked");
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);

      // `iat >= not_before` is honoured, one second earlier is not
      const atBoundary = { ...identity, assertion: await assertionFor(identity, { iat: notBefore }) };
      const justBefore = { ...identity, assertion: await assertionFor(identity, { iat: notBefore - 1 }) };
      await expectRow(await pairCode(justBefore, window.code), "pair_code.identity_revoked");
      expect((await pairCode(atBoundary, window.code)).status).toBe(200);
    });
  });

  describe("proof of possession (INV-43)", () => {
    it("refuses a timestamp more than 60 s from the relay's clock with 401 `stale timestamp`, either way", async () => {
      for (const skew of [-65, 65]) {
        const { identity, window } = await ready();
        const ts = nowS() + skew;
        await expectRow(await pairCode(identity, window.code, { ts, sig: popSig(identity.phone, window.code, ts) }), "pair_code.stale_timestamp");
        expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
      }
    });

    it("refuses a timestamp that is not an integer", async () => {
      const { identity, window } = await ready();
      for (const ts of ["1790000010", 1.5, null, undefined, [nowS()]]) {
        await expectRow(await pairCode(identity, window.code, { ts, sig: popSig(identity.phone, window.code, nowS()) }), "pair_code.stale_timestamp");
      }
    });

    it("accepts a timestamp inside the skew, either way", async () => {
      for (const skew of [-55, 55]) {
        const { identity, window } = await ready();
        const ts = nowS() + skew;
        expect((await pairCode(identity, window.code, { ts, sig: popSig(identity.phone, window.code, ts) })).status, `${skew}`).toBe(200);
      }
    });

    it("refuses a signature by a different key than the assertion's install key: a stolen assertion is no use alone (T5)", async () => {
      const { identity, window } = await ready();
      const thief = newPhone();
      const ts = nowS();
      await expectRow(await pairCode(identity, window.code, { ts, sig: popSig(thief, window.code, ts) }), "pair_code.bad_signature");
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
    });

    it("refuses a signature made for another code, another timestamp, or in any way damaged", async () => {
      const { identity, window } = await ready();
      const ts = nowS();
      const good = popSig(identity.phone, window.code, ts);
      const forOtherCode = popSig(identity.phone, randomCode(), ts);
      const forOtherTs = popSig(identity.phone, window.code, ts - 1);
      const damaged = base64UrlDecode(good);
      damaged[0] = (damaged[0] ?? 0) ^ 1;
      const flipped = base64UrlEncode(damaged);
      for (const sig of [forOtherCode, forOtherTs, flipped, good.slice(0, -1), `${good}==`, "", 7, undefined]) {
        await expectRow(await pairCode(identity, window.code, { ts, sig }), "pair_code.bad_signature");
      }
      expect((await pairCode(identity, window.code, { ts, sig: good })).status).toBe(200);
    });
  });

  describe("no window (INV-42: one 404 for every way there is nothing to release)", () => {
    const NO_WINDOW = "pair_code.no_window";

    it("answers 404 for a code nobody opened, and says nothing else", async () => {
      const identity = await signIn(fake);
      await expectRow(await pairCode(identity, randomCode()), NO_WINDOW);
    });

    it("answers byte for byte the same 404 for unknown, another user's, lapsed, revoked, already released and QR-bound", async () => {
      const unknown = await (async () => {
        const identity = await signIn(fake);
        return snapshot(await pairCode(identity, randomCode()));
      })();
      expect(unknown.status).toBe(404);

      const cases: Record<string, () => Promise<Response>> = {
        "another user's code": async () => {
          const owner = await openWindow(fake, newUser());
          const intruder = await signIn(fake);
          return pairCode(intruder, owner.code);
        },
        "a session past its pairing window (index still has the entry)": async () => {
          const { identity, window } = await ready();
          await lapseSession(window.init.session_id);
          return pairCode(identity, window.code);
        },
        "an index entry past its exp": async () => {
          const { user, identity, window } = await ready();
          await lapseIndexEntry(user.id, window.code);
          return pairCode(identity, window.code);
        },
        "a revoked session": async () => {
          const { identity, window } = await ready();
          await revokeSession(window.init);
          return pairCode(identity, window.code);
        },
        "a window already released": async () => {
          const { identity, window } = await ready();
          expect((await pairCode(identity, window.code)).status).toBe(200);
          return pairCode(identity, window.code);
        },
        "a session a QR scan bound first": async () => {
          const { identity, window } = await ready();
          await claimSocket(window.init.session_id, window.init.pairing_code);
          return pairCode(identity, window.code);
        },
      };
      for (const [label, run] of Object.entries(cases)) {
        const res = await run();
        await expectRow(res.clone(), NO_WINDOW);
        expect(await snapshot(res), label).toEqual(unknown);
      }
    });

    it("never releases another user's window, however well the intruder signs", async () => {
      const owner = newUser();
      const window = await openWindow(fake, owner);
      const intruder = await signIn(fake);
      for (let i = 0; i < 3; i++) await pairCode(intruder, window.code);
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
      const real = await signIn(fake, owner);
      expect((await pairCode(real, window.code)).status).toBe(200);
    });
  });

  describe("throttles", () => {
    it("allows 20 requests a minute per IP and refuses the 21st with 429, even a perfect one, which then releases nothing", async () => {
      const { identity, window } = await ready();
      const ip = freshIp();
      for (let i = 0; i < 20; i++) {
        expect((await pairCode(identity, "nope", { ip })).status).toBe(400);
      }
      await expectRow(await pairCode(identity, window.code, { ip }), "pair_code.throttled");
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);

      // the same request from another address goes through
      expect((await pairCode(identity, window.code)).status).toBe(200);
    });

    it("allows 10 attempts a minute per GitHub id and refuses the 11th with 429 `retry_after_s: 60`, which then releases nothing", async () => {
      const user = newUser();
      const identity = await signIn(fake, user);
      for (let i = 0; i < 10; i++) {
        const window = await openWindow(fake, user);
        expect((await pairCode(identity, window.code)).status, `attempt ${i + 1}`).toBe(200);
      }
      const eleventh = await openWindow(fake, user);
      await expectRow(await pairCode(identity, eleventh.code), "pair_code.throttled");
      expect((await storedRecord(eleventh.init.session_id))?.code_window?.released).toBe(false);

      // another user is untouched
      const { identity: other, window: otherWindow } = await ready();
      expect((await pairCode(other, otherWindow.code)).status).toBe(200);
    });

    it("locks a GitHub id out for 600 s after 10 consecutive 404s: the 11th request, even for a real window, is 429 and releases nothing", async () => {
      const { user, identity, window } = await ready();
      for (let i = 0; i < 10; i++) {
        await expectRow(await pairCode(identity, randomCode()), "pair_code.no_window");
      }
      const locked = await pairCode(identity, window.code);
      const body = await expectRow(locked, "pair_code.locked_out");
      expect(locked.headers.get("Retry-After")).toBe(String(body.retry_after_s));
      expect(body.retry_after_s as number).toBeGreaterThanOrEqual(590);
      expect(body.retry_after_s as number).toBeLessThanOrEqual(600);
      expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);

      // it is that GitHub id only
      const { identity: other, window: otherWindow } = await ready();
      expect((await pairCode(other, otherWindow.code)).status).toBe(200);

      // once the 600 s have gone (and the minute's throttle with them) the id is served and the streak is gone
      await runInDurableObject(indexStub(user.id), async (_instance, state) => {
        const index = (await state.storage.get<{ miss_streak: number[]; attempts: number[] }>("code_index")) as {
          miss_streak: number[];
          attempts: number[];
        };
        index.miss_streak = index.miss_streak.map((at) => at - 601_000);
        index.attempts = [];
        await state.storage.put("code_index", index);
      });
      expect((await pairCode(identity, window.code)).status).toBe(200);
      expect((await storedIndex(user.id))?.miss_streak).toEqual([]);
    });

    it("counts only CONSECUTIVE misses: a release in between starts the streak over", async () => {
      const user = newUser();
      const identity = await signIn(fake, user);
      const clearMinute = () =>
        runInDurableObject(indexStub(user.id), async (_instance, state) => {
          const index = (await state.storage.get<{ attempts: number[] }>("code_index")) as { attempts: number[] };
          index.attempts = [];
          await state.storage.put("code_index", index);
        });

      for (let i = 0; i < 9; i++) await pairCode(identity, randomCode());
      const first = await openWindow(fake, user);
      expect((await pairCode(identity, first.code)).status).toBe(200);
      await clearMinute();

      // nine more misses: eighteen in all, but never ten in a row
      for (let i = 0; i < 9; i++) await expectRow(await pairCode(identity, randomCode()), "pair_code.no_window");
      const second = await openWindow(fake, user);
      expect((await pairCode(identity, second.code)).status).toBe(200);
    });
  });

  it("releases exactly once under a race: of several simultaneous requests for one window, one wins and the rest are 404", async () => {
    const { identity, window } = await ready();
    const results = await Promise.all(Array.from({ length: 5 }, () => pairCode(identity, window.code)));
    const statuses = results.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 404, 404, 404, 404]);
  });
});

// ============================================================================================
// POST /identity/github/revoke  (spec 6.4)
// ============================================================================================

describe("POST /identity/github/revoke (spec 6.4)", () => {
  it("kills every earlier sign-in for the laptop's GitHub user and nobody else's", async () => {
    const user = newUser();
    const stale = await signIn(fake, user);
    const bystander = await signIn(fake, newUser());
    const window = await openWindow(fake, user);
    const bystanderWindow = await openWindow(fake, bystander.user);

    const token = fake.laptopToken(user);
    const res = await revokeRequest({ gh_token: token });
    const body = await expectRow(res, "identity_revoke.ok", { gh_login: user.login });
    expect(Math.abs((body.not_before as number) - nowS())).toBeLessThanOrEqual(5);
    expect(fake.calls.map((c) => `${c.method} ${c.path}`)).toEqual(["GET /user"]);
    expect(fake.calls[0]?.authorization).toBe(`Bearer ${token}`);

    await expectRow(await pairCode(stale, window.code), "pair_code.identity_revoked");
    expect((await pairCode(bystander, bystanderWindow.code)).status).toBe(200);

    // signing in again is what the app does next, and it works
    const fresh = await signIn(fake, user, stale.phone);
    expect((await pairCode(fresh, window.code)).status).toBe(200);
  });

  it("never moves not_before backwards", async () => {
    const user = newUser();
    const first = (await (await revokeRequest({ gh_token: fake.laptopToken(user) })).json()) as { not_before: number };
    await sleep(1100);
    const second = (await (await revokeRequest({ gh_token: fake.laptopToken(user) })).json()) as { not_before: number };
    expect(second.not_before).toBeGreaterThanOrEqual(first.not_before + 1);
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["a number", 5],
  ])("refuses a gh_token that is %s with 400", async (_label, ghToken) => {
    await expectRow(await revokeRequest({ gh_token: ghToken }), "identity_revoke.missing_gh_token");
    expect(fake.calls).toHaveLength(0);
  });

  it("rejects a laptop token GitHub does not know with 401, and a token that cannot be one without asking GitHub", async () => {
    await expectRow(await revokeRequest({ gh_token: "gho_nobody_issued_this" }), "identity_revoke.github_rejected");
    const before = fake.calls.length;
    await expectRow(await revokeRequest({ gh_token: "has space" }), "identity_revoke.github_rejected");
    expect(fake.calls).toHaveLength(before);
  });

  it("answers 502 when GitHub fails, and revokes nothing", async () => {
    const user = newUser();
    const identity = await signIn(fake, user);
    const window = await openWindow(fake, user);
    fake.respondOnce("user", 500, {});
    await expectRow(await revokeRequest({ gh_token: fake.laptopToken(user) }), "identity_revoke.github_unavailable");
    fake.networkErrorOnce("user");
    await expectRow(await revokeRequest({ gh_token: fake.laptopToken(user) }), "identity_revoke.github_unavailable");
    expect((await pairCode(identity, window.code)).status).toBe(200);
  });

  it("shares the sign-in route's per-IP bucket: 10 a minute across both, the 11th is 429 before any GitHub call", async () => {
    const ip = freshIp();
    for (let i = 0; i < 5; i++) {
      await signInRequest({ gh_token: "ghu_nobody_issued_this", install_pubkey: newPhone().pub }, ip);
      await revokeRequest({ gh_token: "gho_nobody_issued_this" }, ip);
    }
    const callsBefore = fake.calls.length;
    await expectRow(await revokeRequest({ gh_token: "gho_nobody_issued_this" }, ip), "identity_revoke.throttled");
    expect((await signInRequest({ gh_token: "ghu_nobody_issued_this", install_pubkey: newPhone().pub }, ip)).status).toBe(429);
    expect(fake.calls).toHaveLength(callsBefore);
  });
});

// ============================================================================================
// Rows every route shares
// ============================================================================================

describe("rows all four routes share: unreadable and oversized bodies", () => {
  const routes: [string, (body: string) => Promise<Response>][] = [
    ["POST /identity/github", (body) => post("/identity/github", body)],
    ["POST /identity/github/revoke", (body) => post("/identity/github/revoke", body)],
    ["POST /pair/code", (body) => post("/pair/code", body)],
    [
      "POST /session/:id/code",
      async (body) => {
        const init = await pairInit();
        return SELF.fetch(`${BASE}/session/${init.session_id}/code`, {
          method: "POST",
          headers: { Authorization: `Bearer ${init.relay_session_token}`, "content-type": "application/json" },
          body,
        });
      },
    ],
  ];

  for (const [name, send] of routes) {
    it.each([["not JSON", "this is not json"], ["a JSON array", "[1,2]"], ["JSON null", "null"], ["a JSON string", '"gho_x"'], ["empty", ""]])(
      `${name} answers 400 \`invalid json\` for a body that is %s`,
      async (_label, body) => {
        await expectRow(await send(body), "shared.invalid_json");
        expect(fake.calls).toHaveLength(0);
      }
    );

    it(`${name} answers 413 for a body over the contract's ${contract.constants.max_body_bytes} bytes, unread`, async () => {
      const big = JSON.stringify({ gh_token: "gho_x", padding: "x".repeat(contract.constants.max_body_bytes) });
      await expectRow(await send(big), "shared.body_too_large");
      expect(fake.calls).toHaveLength(0);
    });

    it(`${name} still reads a body of exactly the contract's ${contract.constants.max_body_bytes} bytes`, async () => {
      const filler = contract.constants.max_body_bytes - JSON.stringify({ gh_token: "gho_x", padding: "" }).length;
      const exact = JSON.stringify({ gh_token: "gho_x", padding: "x".repeat(filler) });
      expect(new TextEncoder().encode(exact).byteLength).toBe(contract.constants.max_body_bytes);
      const res = await send(exact);
      expect(res.status).not.toBe(413);
      expect(res.status).not.toBe(503);
    });
  }
});

// ============================================================================================
// Frames: device_bound's `via`, and key_reveal (spec 6.5, INV-44)
// ============================================================================================

describe("frames (spec 6.5)", () => {
  /** A session bound through the code flow, with hmd's stream open to see what it is told. */
  async function bindViaCode(label = "Pixel 9a") {
    const { user, identity, window } = await ready();
    const hmd = await HmdLines.open(window.init);
    const released = (await (await pairCode(identity, window.code, { device_label: label })).json()) as { pairing_code: string };
    const phone = await claimSocket(window.init.session_id, released.pairing_code);
    const phoneBound = (await phone.next()) as { payload: { device_token: string } };
    const hmdBound = await hmd.next();
    return { user, identity, window, hmd, phone, phoneBound, hmdBound };
  }

  it("tells hmd the bind came via the code, with the label the phone claimed and the login its assertion proved", async () => {
    const { user, window, hmd, hmdBound } = await bindViaCode("Pixel 9a");
    expect(hmdBound).not.toBeNull();
    expectMatch(
      hmdBound,
      contract.frames.device_bound_to_hmd_code.envelope,
      { session_id: window.init.session_id, device_pubkey: TEST_DEVICE_PUBKEY, device_label: "Pixel 9a", gh_login: user.login },
      "frames.device_bound_to_hmd_code"
    );
    covered.add("frames.device_bound_to_hmd_code");
    await hmd.close();
  });

  it("tells hmd the bind came via the QR when nobody released a window, with nothing about a person in it", async () => {
    const init = await pairInit();
    const hmd = await HmdLines.open(init);
    await claimSocket(init.session_id, init.pairing_code);
    expectMatch(await hmd.next(), contract.frames.device_bound_to_hmd_qr.envelope, { session_id: init.session_id, device_pubkey: TEST_DEVICE_PUBKEY }, "frames.device_bound_to_hmd_qr");
    covered.add("frames.device_bound_to_hmd_qr");
    await hmd.close();
  });

  it("still says `qr` when a window was registered but the QR was scanned first, and the window is gone", async () => {
    const { user, window } = await ready();
    const hmd = await HmdLines.open(window.init);
    await claimSocket(window.init.session_id, window.init.pairing_code);
    const frame = (await hmd.next()) as { payload: Record<string, unknown> };
    expect(frame.payload.via).toBe("qr");
    expect(Object.keys(frame.payload).sort()).toEqual(["bound_at", "device_pubkey", "via"]);
    expect((await storedRecord(window.init.session_id))?.code_window).toBeUndefined();
    expect((await storedIndex(user.id))?.codes[window.code]).toBeUndefined();
    await hmd.close();
  });

  it("carries `via` and the label on hmd's WebSocket transport too", async () => {
    const { user, identity, window } = await ready();
    const hmd = await openHmdSocket(BASE, window.init);
    const released = (await (await pairCode(identity, window.code, { device_label: "Galaxy" })).json()) as { pairing_code: string };
    await claimSocket(window.init.session_id, released.pairing_code);
    const frame = await hmd.nextJson();
    expect(frame?.payload).toEqual({
      device_pubkey: TEST_DEVICE_PUBKEY,
      bound_at: expect.any(Number),
      via: "code",
      device_label: "Galaxy",
      gh_login: user.login,
    });
  });

  describe("key_reveal (INV-44)", () => {
    it("is forwarded to the phone byte for byte, once", async () => {
      const { window, hmd, phone } = await bindViaCode();
      const envelope = keyRevealEnvelope(window.init, window.commitment);

      const res = await postHmdFrame(window.init, envelope);
      await expectRow(res, "frames.key_reveal.delivered");
      expect(await phone.next()).toEqual(envelope);
      await hmd.close();
    });

    it("what the phone receives opens the commitment /pair/code gave it", async () => {
      const { window, hmd, phone } = await bindViaCode();
      await postHmdFrame(window.init, keyRevealEnvelope(window.init, window.commitment));
      const received = (await phone.next()) as { payload: { hmd_pubkey: string; nonce: string } };
      expect(received.payload).toEqual({ hmd_pubkey: window.commitment.hmdPub, nonce: window.commitment.nonce });
      await hmd.close();
    });

    it("refuses a second one with 409 `duplicate key_reveal`, and the phone sees only the first", async () => {
      const { window, hmd, phone } = await bindViaCode();
      const first = keyRevealEnvelope(window.init, window.commitment);
      await postHmdFrame(window.init, first);
      expect(await phone.next()).toEqual(first);

      const other = newCommitment();
      await expectRow(await postHmdFrame(window.init, keyRevealEnvelope(window.init, other)), "frames.key_reveal.duplicate");
      expect(await phone.next(400)).toBeNull();
      await hmd.close();
    });

    it("refuses one before the session is bound: 409 `session not bound`", async () => {
      const { window } = await ready();
      await expectRow(await postHmdFrame(window.init, keyRevealEnvelope(window.init, window.commitment)), "frames.key_reveal.not_bound");
    });

    it.each([
      ["sealed (ciphertext set)", { ciphertext: "c2VhbGVk" }],
      ["carrying a nonce", { nonce: "bm9uY2U" }],
      ["with no payload", { payload: undefined }],
      ["with an array payload", { payload: ["x"] }],
      ["with a string payload", { payload: "x" }],
      ["with a null payload", { payload: null }],
    ])("refuses one that is %s with 400 `invalid envelope`", async (_label, over) => {
      const { window, hmd } = await bindViaCode();
      const envelope = { ...keyRevealEnvelope(window.init, window.commitment), ...over };
      await expectRow(await postHmdFrame(window.init, envelope), "frames.key_reveal.not_plaintext");
      await hmd.close();
    });

    it("is not a frame anyone else can post: a device- or relay-sender key_reveal is 400, a wrong bearer 401", async () => {
      const { window, hmd } = await bindViaCode();
      const envelope = keyRevealEnvelope(window.init, window.commitment);
      expect((await postHmdFrame(window.init, { ...envelope, sender: "device" })).status).toBe(400);
      expect((await postHmdFrame(window.init, { ...envelope, sender: "relay" })).status).toBe(400);
      expect((await postHmdFrame(window.init, envelope, "wrong-bearer")).status).toBe(401);
      // none of that used up the one reveal
      await expectRow(await postHmdFrame(window.init, envelope), "frames.key_reveal.delivered");
      await hmd.close();
    });

    it("cannot be originated by the phone: a key_reveal on its socket never reaches hmd", async () => {
      const { window, hmd, phone } = await bindViaCode();
      const envelope = keyRevealEnvelope(window.init, window.commitment);
      phone.socket.send(JSON.stringify({ ...envelope, sender: "device" }));
      phone.socket.send(JSON.stringify(envelope));
      expect(await hmd.next(600)).toBeNull();
      // and it does not count as hmd's reveal
      await expectRow(await postHmdFrame(window.init, envelope), "frames.key_reveal.delivered");
      await hmd.close();
    });

    it("is held for a phone that was away: not delivered live, replayed first on its reconnect, ahead of any state", async () => {
      const { window, hmd, phone, phoneBound } = await bindViaCode();
      phone.socket.close(1000, "going away");
      await sleep(300);

      const envelope = keyRevealEnvelope(window.init, window.commitment);
      await expectRow(await postHmdFrame(window.init, envelope), "frames.key_reveal.undelivered");
      const state = { v: 1, session_id: window.init.session_id, seq: 1, sender: "hmd", type: "state", nonce: "n", ciphertext: "c" };
      await postHmdFrame(window.init, state);

      const back = await reconnectSocket(window.init.session_id, phoneBound.payload.device_token);
      expect(await back.next()).toEqual(envelope);
      expect(await back.next()).toEqual(state);
      await hmd.close();
    });

    it("is replayed to a later reconnect even after it was delivered live (the phone dedups: one reveal per session)", async () => {
      const { window, hmd, phone, phoneBound } = await bindViaCode();
      const envelope = keyRevealEnvelope(window.init, window.commitment);
      await postHmdFrame(window.init, envelope);
      expect(await phone.next()).toEqual(envelope);
      phone.socket.close(1000, "going away");
      await sleep(300);

      const back = await reconnectSocket(window.init.session_id, phoneBound.payload.device_token);
      expect(await back.next()).toEqual(envelope);
      await hmd.close();
    });

    it("does not change what a QR session does: state and ack are still hmd's, device_bound from hmd is still refused", async () => {
      const init = await pairInit();
      const phone = await claimSocket(init.session_id, init.pairing_code);
      await phone.next();
      const state = { v: 1, session_id: init.session_id, seq: 1, sender: "hmd", type: "state", nonce: "n", ciphertext: "c" };
      expect(await (await postHmdFrame(init, state)).json()).toEqual({ ok: true, delivered: true });
      expect(await phone.next()).toEqual(state);
      expect((await postHmdFrame(init, { ...state, type: "device_bound" })).status).toBe(400);
    });
  });
});

// ============================================================================================
// INV-39: nothing persisted, nothing logged
// ============================================================================================

describe("INV-39: the relay holds no GitHub token, assertion or signature, and logs none, nor a GitHub id", () => {
  it("through a whole pairing, in no log line and in no Durable Object's storage once the pairing is bound", async () => {
    const user = newUser();
    const phone = newPhone();
    const secrets: string[] = [];
    let pairingCode = "";

    const log = await withRelayLog(async () => {
      const phoneToken = fake.phoneToken(user);
      const signedIn = await signInRequest({ gh_token: phoneToken, install_pubkey: phone.pub });
      const { gh_assertion: assertion } = (await signedIn.json()) as { gh_assertion: string };
      const identity: Identity = { phone, user, assertion };

      const init = await pairInit();
      const laptopToken = fake.laptopToken(user);
      const commitment = newCommitment();
      const code = randomCode();
      await registerWindow(init, { code, gh_token: laptopToken, hmd_commit: commitment.commit });

      const ts = nowS();
      const sig = popSig(phone, code, ts);
      const released = (await (await pairCode(identity, code, { ts, sig })).json()) as { pairing_code: string };
      pairingCode = released.pairing_code;
      const bound = await claimSocket(init.session_id, released.pairing_code);
      await bound.next();
      await postHmdFrame(init, keyRevealEnvelope(init, commitment));
      await revokeRequest({ gh_token: fake.laptopToken(user) });

      secrets.push(phoneToken, laptopToken, assertion, sig);
    });

    const logged = log.lines.join("\n");
    for (const secret of secrets) expect(logged).not.toContain(secret);
    expect(logged).not.toContain(String(user.id));
    expect(logged).not.toContain(pairingCode);

    for (const id of await listDurableObjectIds(typedEnv.SESSION)) {
      const dump = await dumpStorage(typedEnv.SESSION.get(id));
      for (const secret of secrets) expect(dump).not.toContain(secret);
      expect(dump).not.toContain(String(user.id));
    }
  });
});

// ============================================================================================
// INV-40: released at most once, only to the owner, only while pending and in time
// ============================================================================================

describe("INV-40, at the session: the checks the index in front of it cannot stand in for", () => {
  async function fresh() {
    const user = newUser();
    const window = await openWindow(fake, user);
    return { user, window };
  }

  it("releases to the owner, once; the second ask is refused by the window's own `released` flag", async () => {
    const { user, window } = await fresh();
    const first = await directRelease(window.init.session_id, { gh_id: user.id, code: window.code });
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      session_id: window.init.session_id,
      pairing_code: window.init.pairing_code,
      hmd_commit: window.commitment.commit,
      exp: window.init.exp,
    });
    expect((await directRelease(window.init.session_id, { gh_id: user.id, code: window.code })).status).toBe(404);
  });

  it("refuses a GitHub id that is not the owner's, and the refusal does not spend the window", async () => {
    const { user, window } = await fresh();
    expect((await directRelease(window.init.session_id, { gh_id: user.id + 1, code: window.code })).status).toBe(404);
    expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
    expect((await directRelease(window.init.session_id, { gh_id: user.id, code: window.code })).status).toBe(200);
  });

  it("refuses a code that is not the window's", async () => {
    const { user, window } = await fresh();
    expect((await directRelease(window.init.session_id, { gh_id: user.id, code: randomCode() })).status).toBe(404);
  });

  it("refuses once the pairing window has passed", async () => {
    const { user, window } = await fresh();
    await lapseSession(window.init.session_id);
    expect((await directRelease(window.init.session_id, { gh_id: user.id, code: window.code })).status).toBe(404);
  });

  it("refuses once the session is not pending: revoked, or bound by a QR scan", async () => {
    const revoked = await fresh();
    await revokeSession(revoked.window.init);
    expect((await directRelease(revoked.window.init.session_id, { gh_id: revoked.user.id, code: revoked.window.code })).status).toBe(404);

    const bound = await fresh();
    await claimSocket(bound.window.init.session_id, bound.window.init.pairing_code);
    expect((await directRelease(bound.window.init.session_id, { gh_id: bound.user.id, code: bound.window.code })).status).toBe(404);
  });

  it("refuses a session that never had a window", async () => {
    const init = await pairInit();
    expect((await directRelease(init.session_id, { gh_id: 1, code: randomCode() })).status).toBe(404);
  });

  it("refuses a release that carries no usable fields, without spending the window", async () => {
    const { user, window } = await fresh();
    for (const body of ["not json", "[]", "null", JSON.stringify({ gh_id: "1", code: window.code }), JSON.stringify({ code: window.code })]) {
      const res = await sessionStub(window.init.session_id).fetch("http://do-internal/code-release", { method: "POST", body });
      expect(res.status, body).toBe(404);
    }
    expect((await directRelease(window.init.session_id, { gh_id: user.id, code: window.code })).status).toBe(200);
  });
});

// ============================================================================================
// INV-41: retention
// ============================================================================================

describe("INV-41: a window's identifying fields live no longer than the window", () => {
  it("are cleared from the session when the phone binds, and the index holds nothing for the window", async () => {
    const { user, identity, window } = await ready();
    const released = (await (await pairCode(identity, window.code, { device_label: "Pixel 9a" })).json()) as { pairing_code: string };
    expect((await storedRecord(window.init.session_id))?.code_window).toBeDefined();

    const phone = await claimSocket(window.init.session_id, released.pairing_code);
    await phone.next();

    const record = await storedRecord(window.init.session_id);
    expect(record?.status).toBe("bound");
    expect(record?.code_window).toBeUndefined();
    expect((await storedIndex(user.id))?.codes[window.code]).toBeUndefined();
    expect(await dumpStorage(typedEnv.SESSION.get(typedEnv.SESSION.idFromName(window.init.session_id)))).not.toContain("Pixel 9a");
  });

  it("are cleared when hmd revokes a session whose window was never released, or was released and not claimed", async () => {
    const open = await ready();
    await revokeSession(open.window.init);
    expect((await storedRecord(open.window.init.session_id))?.code_window).toBeUndefined();
    expect((await storedIndex(open.user.id))?.codes[open.window.code]).toBeUndefined();

    const released = await ready();
    await pairCode(released.identity, released.window.code);
    await revokeSession(released.window.init);
    expect((await storedRecord(released.window.init.session_id))?.code_window).toBeUndefined();
  });

  it("are cleared when a late claim finds the window lapsed (the session ends)", async () => {
    const { window } = await ready();
    await lapseSession(window.init.session_id);
    const late = await SELF.fetch(
      `${BASE}/session/${window.init.session_id}/ws?pairing_code=${window.init.pairing_code}&device_pubkey=${TEST_DEVICE_PUBKEY}`,
      { headers: { Upgrade: "websocket" } }
    );
    expect(late.status).toBe(410);
    expect((await storedRecord(window.init.session_id))?.code_window).toBeUndefined();
  });

  it("go with the record when the purge alarm reclaims a window nobody claimed", async () => {
    const { window } = await ready();
    await lapseSession(window.init.session_id);
    expect(await runDurableObjectAlarm(typedEnv.SESSION.get(typedEnv.SESSION.idFromName(window.init.session_id)))).toBe(true);
    expect(await storedRecord(window.init.session_id)).toBeUndefined();
  });

  it("leave the owner's index empty once every window has lapsed: its alarm reclaims the storage", async () => {
    const user = newUser();
    const window = await openWindow(fake, user);
    expect(await runInDurableObject(indexStub(user.id), (_i, state) => state.storage.getAlarm())).not.toBeNull();

    await lapseIndexEntry(user.id, window.code);
    await runDurableObjectAlarm(indexStub(user.id));
    expect(await storedIndex(user.id)).toBeUndefined();
  });

  it("keep, after a revoke, nothing for the GitHub id but its not_before", async () => {
    const user = newUser();
    const window = await openWindow(fake, user);
    await pairCode(await signIn(fake, user), randomCode()); // a miss, so a streak and an attempt are on file
    const { not_before: notBefore } = (await (await revokeRequest({ gh_token: fake.laptopToken(user) })).json()) as { not_before: number };

    await lapseIndexEntry(user.id, window.code);
    await runInDurableObject(indexStub(user.id), async (_instance, state) => {
      const index = (await state.storage.get<{ miss_streak: number[]; attempts: number[] }>("code_index")) as {
        miss_streak: number[];
        attempts: number[];
      };
      index.miss_streak = index.miss_streak.map((at) => at - 700_000);
      index.attempts = index.attempts.map((at) => at - 70_000);
      await state.storage.put("code_index", index);
    });
    await runDurableObjectAlarm(indexStub(user.id));

    expect(await storedIndex(user.id)).toEqual({ codes: {}, miss_streak: [], attempts: [], not_before: notBefore });
    expect(await runInDurableObject(indexStub(user.id), (_i, state) => state.storage.getAlarm())).not.toBeNull();
  });
});

// ============================================================================================
// What is reachable from outside
// ============================================================================================

describe("router: only the four routes and the `code` subpath are public", () => {
  it("reaches `code` through /session/:id/*, and keeps every internal handler of the Durable Object out", async () => {
    const { user, identity, window } = await ready();
    for (const internal of ["code-release", "bucket", "index-register", "index-clear", "index-resolve", "index-revoke", "throttle", "init"]) {
      const res = await SELF.fetch(`${BASE}/session/${window.init.session_id}/${internal}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${window.init.relay_session_token}`, "content-type": "application/json" },
        body: JSON.stringify({ gh_id: user.id, code: window.code }),
      });
      expect(res.status, internal).toBe(404);
      expect(await res.json(), internal).toEqual({ error: "not found" });
    }
    // none of that released or disturbed anything
    expect((await storedRecord(window.init.session_id))?.code_window?.released).toBe(false);
    expect((await pairCode(identity, window.code)).status).toBe(200);
  });

  it("answers 404 to the wrong method on the new top-level routes", async () => {
    for (const path of ["/identity/github", "/identity/github/revoke", "/pair/code"]) {
      expect((await SELF.fetch(`${BASE}${path}`, { method: "GET" })).status, path).toBe(404);
    }
  });

  it("does not let an index or throttle Durable Object be addressed through the public session route", async () => {
    const res = await SELF.fetch(`${BASE}/session/code-index:1234/code`, { method: "POST", body: "{}" });
    expect(res.status).toBe(400);
  });
});

// ============================================================================================
// The contract
// ============================================================================================

describe("contract (relay/contract/code-pair.json)", () => {
  it("has every row asserted by a test above (run the whole file: a filtered run leaves rows unreached)", () => {
    expect(allRowKeys().filter((key) => !covered.has(key))).toEqual([]);
  });

  it("keeps the QR-form device_bound of wire.json in step with the `via: qr` form here", async () => {
    const wire = (await import("../contract/wire.json")).default as unknown as {
      stream: { lines: { device_bound: { payload: Record<string, unknown> } } };
      stream_ws: { messages: { device_bound: { payload: Record<string, unknown> } } };
    };
    const expected = (contract.frames.device_bound_to_hmd_qr.envelope as { payload: Record<string, unknown> }).payload;
    expect(Object.keys(wire.stream.lines.device_bound.payload).sort()).toEqual(Object.keys(expected).sort());
    expect(Object.keys(wire.stream_ws.messages.device_bound.payload).sort()).toEqual(Object.keys(expected).sort());
    expect(wire.stream.lines.device_bound.payload.via).toBe("qr");
  });
});
