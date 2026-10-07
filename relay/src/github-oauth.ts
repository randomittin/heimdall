// GitHub sign-in through the browser: the OAuth web flow (authorization code + PKCE) in the phone's
// system browser, brokered by the relay. Design of record: hmdapp
// docs/HANDOFF-TO-HEIMDALL-github-oauth.md; wire: relay/contract/github-oauth.json.
//
// GitHub needs the client secret for the code exchange and only this relay holds it, so the relay
// is the confidential client and the phone never sees a GitHub token. What the phone ends with is
// the same `gh_assertion` POST /identity/github mints (code-pair.ts's `mintSignIn`), bound to the
// same install key, so everything after sign-in -- the phone's store, the login gate, /pair/code --
// is unchanged. The device flow stays as the fallback and is not touched.
//
// Four routes, answered by the Worker itself (worker.ts):
//   GET  /identity/github/oauth            capability probe: 200 {"v":1}
//   GET  /identity/github/oauth/start      the phone's browser lands here: the pending sign-in is
//                                          stored, the browser is sent to GitHub
//   GET  /identity/github/oauth/callback   GitHub sends the browser back here with a code: it is
//                                          exchanged, the token checked and deleted, a handoff
//                                          stored, the browser sent to the app
//   POST /identity/github/oauth/redeem     the app trades the handoff and its PKCE verifier for the pass
//
// They exist only when `oauthWebConfig(env)` is not null: code pairing's three values are set AND
// the `[vars]` entry GITHUB_OAUTH_WEB is exactly "1". Off, `routeGithubOauth` answers nothing and the
// Worker's own fallthrough answers them as it answers any path it never had.
//
// Two single-use records, each in the SessionDO instance named by its key (the class every throttle
// bucket and `code-index:<gh_id>` already use: no new class, no migration; session.ts's `/oauth-put`
// and `/oauth-take`):
//   oauth-state:<relay_state>   600 s  the app's state, challenge and install key; taken by the callback
//   oauth-handoff:<hc>           60 s  the user's id and login, install key and challenge; taken by redeem
// Taking is read-and-delete in one Durable Object request, so two racing takes cannot both win, and
// the record is spent by its first use whatever that use ends in. A handoff holds identity facts and
// nothing signed: the pass is minted at redeem, so no credential sits in storage.
//
// What is never logged, stored or put in an error: a GitHub token (access or refresh), the code, the
// client secret, either state, hc, the verifier, the challenge, the install key and the pass. The
// access token lives in local variables of the one callback request and is deleted at GitHub before
// anything is stored; a refresh token is never read. The three log lines added here carry an outcome
// word and nothing from the request (scripts/check-no-logged-urls.mjs keeps the logging honest).

import {
  BUCKET_RETRY_AFTER_S,
  codePairConfig,
  mintSignIn,
  overIpBucket,
  readJsonObject,
  throttledResponse,
  type CodePairConfig,
} from "./code-pair";
import { consumePhoneToken, exchangeAuthorizationCode, githubWebOrigin, type GithubUser } from "./github";
import { SECURITY_HEADERS, jsonResponse } from "./http";
import { logEvent } from "./logging";
import {
  MAX_GH_LOGIN_LENGTH,
  base64UrlEncode,
  decodeFixedBase64Url,
  generateSessionToken,
  timingSafeEqual,
} from "./pairing";
import type { Env } from "./types";

/** Where every redirect toward the app goes: the `scheme` of the app's app.json plus its route. A
 *  constant, never read from a request, which is what rules out an open redirect and a header
 *  injection here -- every Location below is this plus values the relay generated or validated. */
const APP_REDIRECT = "hmdapp://auth/github";

/** Appended to the request's own origin to make the `redirect_uri` GitHub is given at the authorize
 *  leg and again at the exchange. It has to equal, byte for byte, a Callback URL registered on the
 *  GitHub App; the same string in both legs is what GitHub's check compares. */
const CALLBACK_PATH = "/identity/github/oauth/callback";

const STATE_TTL_S = 600;
const HANDOFF_TTL_S = 60;

const START_MAX_PER_WINDOW = 10;
const CALLBACK_MAX_PER_WINDOW = 10;
const REDEEM_MAX_PER_WINDOW = 20;

/** 43 characters of unpadded base64url: what `generateSessionToken` makes, which is what a relay
 *  state and an `hc` are. */
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
/** Visible ASCII, bounded: the shape of the `code` GitHub puts in the callback's query. */
const AUTHORIZATION_CODE_RE = /^[\x21-\x7e]{1,256}$/;
/** RFC 7636 section 4.1: 43 to 128 characters of the unreserved set. */
const CODE_VERIFIER_RE = /^[A-Za-z0-9._~-]{43,128}$/;

/** The config the routes need, or `null` when they are off: code pairing's three values set and
 *  the flag exactly "1". A TOML number, "true" or " 1" is not the flag. */
function oauthWebConfig(env: Env): CodePairConfig | null {
  return env.GITHUB_OAUTH_WEB === "1" ? codePairConfig(env) : null;
}

/**
 * The Worker's door to the four routes: the answer, or `null` when this is not one of them or they
 * are off -- worker.ts then goes on to its fallthrough, which is what "a relay that does not have
 * them" answers, for any method. Every answer carries `Cache-Control: no-store` and `Referrer-Policy:
 * no-referrer`, set here once so no branch below can forget it: the URLs these routes see carry
 * the state, the hc and the code.
 */
export async function routeGithubOauth(request: Request, url: URL, env: Env): Promise<Response | null> {
  const config = oauthWebConfig(env);
  if (config === null) return null;

  let response: Response;
  switch (`${request.method} ${url.pathname}`) {
    case "GET /identity/github/oauth":
      response = jsonResponse(200, { v: 1 });
      break;
    case "GET /identity/github/oauth/start":
      response = await handleStart(request, url, env, config);
      break;
    case "GET /identity/github/oauth/callback":
      response = await handleCallback(request, url, env, config);
      break;
    case "POST /identity/github/oauth/redeem":
      response = await handleRedeem(request, env, config);
      break;
    default:
      return null;
  }
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("Referrer-Policy", "no-referrer");
  return response;
}

// --------------------------------------------------------------------------------------------
// Answers
// --------------------------------------------------------------------------------------------

type Outcome = "ok" | "denied" | "exchange_failed" | "throttled" | "expired" | "rejected";

/** One word about how a request ended, and nothing from the request. A sign-in belongs to no
 *  session, so the session slot says `none`, as github.ts's `github_error` does. */
function logOutcome(event: "oauth_start" | "oauth_callback" | "oauth_redeem", outcome: Outcome): void {
  logEvent(event, { session_id: "none", outcome });
}

const PAGE_INVALID = "This sign-in link is not valid. Return to the app and start again.";
const PAGE_EXPIRED = "This sign-in expired or was already used. Return to the app and start again.";
const PAGE_THROTTLED = "Too many sign-in attempts. Close this window and try again in a minute.";

/** A fixed page, for the person looking at the browser: `message` is one of the constants above,
 *  never a value from the request, so there is nothing in it to inject into. */
function page(status: number, message: string, extra: Record<string, string> = {}): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>hmd sign-in</title></head><body><p>${message}</p></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
        "X-Content-Type-Options": "nosniff",
        ...SECURITY_HEADERS,
        ...extra,
      },
    }
  );
}

/** A 302 to the app. Every value in `fields` is one the relay generated or validated against a
 *  fixed shape, and the query is encoded besides. */
function appRedirect(fields: Record<string, string>): Response {
  return new Response(null, {
    status: 302,
    headers: { Location: `${APP_REDIRECT}?${new URLSearchParams(fields).toString()}`, ...SECURITY_HEADERS },
  });
}

// --------------------------------------------------------------------------------------------
// The two records
// --------------------------------------------------------------------------------------------

type RecordKind = "oauth-state" | "oauth-handoff";

const recordStub = (env: Env, kind: RecordKind, key: string): DurableObjectStub =>
  env.SESSION.get(env.SESSION.idFromName(`${kind}:${key}`));

const nowS = (): number => Math.floor(Date.now() / 1000);

/** Stores a record in the instance named by its key. One that did not land cannot be taken later,
 *  so carrying on would send the person on with nothing behind the link: it throws instead, and the
 *  platform's 500 is the honest answer. The message holds nothing from the request. */
async function putRecord(env: Env, kind: RecordKind, key: string, record: Record<string, unknown>): Promise<void> {
  const stored = await recordStub(env, kind, key).fetch("http://do-internal/oauth-put", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(record),
  });
  if (!stored.ok) throw new Error("oauth record not stored");
}

/** The record, once, or `null` when there is none, it has aged out or it was already taken. The
 *  instance reads and deletes in one request; a miss writes nothing. */
async function takeRecord(env: Env, kind: RecordKind, key: string): Promise<Record<string, unknown> | null> {
  const taken = await recordStub(env, kind, key).fetch("http://do-internal/oauth-take", { method: "POST" });
  return taken.status === 200 ? ((await taken.json()) as Record<string, unknown>) : null;
}

/** 43 characters of base64url decoding to 32 bytes: the shape of a state, a challenge, an install key. */
const isKey32 = (value: unknown): value is string => decodeFixedBase64Url(value, 32) !== null;

interface Pending {
  appState: string;
  challenge: string;
  installPubkey: string;
}

/** What `start` stored, if the record is what it wrote. A record that is anything else -- it cannot
 *  be, short of tampering with storage -- is treated as missing, not trusted. */
function parsePending(record: Record<string, unknown> | null): Pending | null {
  if (record === null) return null;
  const { app_state: appState, challenge, install_pubkey: installPubkey } = record;
  if (!isKey32(appState) || !isKey32(challenge) || !isKey32(installPubkey)) return null;
  return { appState, challenge, installPubkey };
}

interface Handoff {
  user: GithubUser;
  challenge: string;
  installPubkey: string;
}

/** What the callback stored, if the record is what it wrote; the user is held to the same bounds
 *  `verifyGhAssertion` holds an assertion's claims to. */
function parseHandoff(record: Record<string, unknown> | null): Handoff | null {
  if (record === null) return null;
  const { gh_id: id, gh_login: login, install_pubkey: installPubkey, challenge } = record;
  if (typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0) return null;
  if (typeof login !== "string" || login.length === 0 || login.length > MAX_GH_LOGIN_LENGTH) return null;
  if (!isKey32(challenge) || !isKey32(installPubkey)) return null;
  return { user: { id, login }, challenge, installPubkey };
}

/** The value of a query parameter that has to be there exactly once, or `null`: a repeated name
 *  is refused rather than resolved by picking one. */
function once(params: URLSearchParams, name: string): string | null {
  const values = params.getAll(name);
  return values.length === 1 ? (values[0] ?? null) : null;
}

// --------------------------------------------------------------------------------------------
// GET /identity/github/oauth/start
// --------------------------------------------------------------------------------------------

interface StartParams {
  state: string;
  challenge: string;
  installPubkey: string;
}

/** The four parameters, each present exactly once and in its shape, or `null`. `plain` and any
 *  other method are refused: S256 is the only one the app speaks and the only one worth having. */
function readStartParams(params: URLSearchParams): StartParams | null {
  const state = once(params, "state");
  const challenge = once(params, "code_challenge");
  const method = once(params, "code_challenge_method");
  const installPubkey = once(params, "install_pubkey");
  if (!isKey32(state) || !isKey32(challenge) || !isKey32(installPubkey) || method !== "S256") return null;
  return { state, challenge, installPubkey };
}

/** The `redirect_uri` of both legs: this request's own origin and the callback's path. */
const callbackUri = (url: URL): string => `${url.origin}${CALLBACK_PATH}`;

/**
 * Order: shapes, then the per-IP bucket, then the store, then the redirect. A bad shape never costs
 * a bucket slot or a Durable Object; a request over the bucket is sent back to the app (its state is
 * valid by now, so safe to hand back) rather than shown a page, because the app is the one that
 * can say "try again in a minute".
 */
async function handleStart(request: Request, url: URL, env: Env, config: CodePairConfig): Promise<Response> {
  const params = readStartParams(url.searchParams);
  if (params === null) {
    logOutcome("oauth_start", "rejected");
    return page(400, PAGE_INVALID);
  }
  if (await overIpBucket(env, request, "oauth-start-throttle", START_MAX_PER_WINDOW)) {
    logOutcome("oauth_start", "throttled");
    return appRedirect({ error: "temporarily_unavailable", retry_after_s: String(BUCKET_RETRY_AFTER_S), state: params.state });
  }

  // 32 random bytes, drawn here: not derived from the app's state, so GitHub and the browser's
  // history see nothing the phone chose, and the callback can only be matched to this record.
  const relayState = generateSessionToken();
  await putRecord(env, "oauth-state", relayState, {
    app_state: params.state,
    challenge: params.challenge,
    install_pubkey: params.installPubkey,
    exp: nowS() + STATE_TTL_S,
  });

  // No `scope` (a GitHub App's user token takes its permissions from the App, and identity needs
  // none), no `login`, `allow_signup` left at GitHub's default; `select_account` so a phone that
  // is signed in to one GitHub account is still asked which.
  const authorize = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: callbackUri(url),
    state: relayState,
    prompt: "select_account",
  });
  logOutcome("oauth_start", "ok");
  return new Response(null, {
    status: 302,
    headers: { Location: `${githubWebOrigin(env)}/login/oauth/authorize?${authorize.toString()}`, ...SECURITY_HEADERS },
  });
}

// --------------------------------------------------------------------------------------------
// GET /identity/github/oauth/callback
// --------------------------------------------------------------------------------------------

/**
 * GitHub's redirect of the person's browser: `code` and `state` (the relay state), or `error` and
 * `state` when they said no. Cheapest first, and the state is consumed before anything is read from
 * GitHub or from the rest of the query, so a replay finds nothing and costs nothing.
 *
 * Before the record is read the only answers are pages: there is no app state yet to redirect to.
 * After it, every ending is a redirect to the app carrying that state, so the app is never left
 * waiting on a browser that went nowhere.
 */
async function handleCallback(request: Request, url: URL, env: Env, config: CodePairConfig): Promise<Response> {
  if (await overIpBucket(env, request, "oauth-callback-throttle", CALLBACK_MAX_PER_WINDOW)) {
    logOutcome("oauth_callback", "throttled");
    return page(429, PAGE_THROTTLED, { "Retry-After": String(BUCKET_RETRY_AFTER_S) });
  }
  const state = once(url.searchParams, "state");
  if (state === null || !TOKEN_RE.test(state)) {
    logOutcome("oauth_callback", "rejected");
    return page(400, PAGE_INVALID);
  }
  const pending = parsePending(await takeRecord(env, "oauth-state", state));
  if (pending === null) {
    logOutcome("oauth_callback", "expired");
    return page(400, PAGE_EXPIRED);
  }
  const toApp = (fields: Record<string, string>): Response => appRedirect({ ...fields, state: pending.appState });

  if (url.searchParams.has("error")) {
    const errors = url.searchParams.getAll("error");
    const denied = errors.length === 1 && errors[0] === "access_denied";
    logOutcome("oauth_callback", denied ? "denied" : "exchange_failed");
    return toApp({ error: denied ? "access_denied" : "server_error" });
  }

  const code = once(url.searchParams, "code");
  if (code === null || !AUTHORIZATION_CODE_RE.test(code)) {
    logOutcome("oauth_callback", "rejected");
    return toApp({ error: "invalid_request" });
  }

  const exchanged = await exchangeAuthorizationCode(env, config.clientId, config.clientSecret, code, callbackUri(url));
  if (!exchanged.ok) {
    if (exchanged.reason === "invalid_grant") {
      logOutcome("oauth_callback", "rejected");
      return toApp({ error: "invalid_request" });
    }
    logOutcome("oauth_callback", "exchange_failed");
    return toApp({ error: "server_error" });
  }
  // The token goes to the same check-and-delete the device flow uses, and on from there to nobody:
  // not stored, not returned, not logged. Anything short of "named the user AND deleted at GitHub"
  // stores nothing, the rule POST /identity/github has.
  const verdict = await consumePhoneToken(env, config.clientId, config.clientSecret, exchanged.accessToken);
  if (!verdict.ok) {
    logOutcome("oauth_callback", "exchange_failed");
    return toApp({ error: "server_error" });
  }

  const hc = generateSessionToken();
  await putRecord(env, "oauth-handoff", hc, {
    gh_id: verdict.user.id,
    gh_login: verdict.user.login,
    install_pubkey: pending.installPubkey,
    challenge: pending.challenge,
    exp: nowS() + HANDOFF_TTL_S,
  });
  logOutcome("oauth_callback", "ok");
  return toApp({ hc });
}

// --------------------------------------------------------------------------------------------
// POST /identity/github/oauth/redeem
// --------------------------------------------------------------------------------------------

/** base64url(SHA-256(ASCII(verifier))): RFC 7636's S256, the one transform the relay checks. */
async function s256(verifier: string): Promise<string> {
  return base64UrlEncode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

/**
 * The app's half: the hc it was redirected with and the verifier that never left the phone. Cheapest
 * first, and nothing is looked up until both are in their shapes, so a malformed request burns
 * nothing. Then the handoff is TAKEN -- and spent whatever follows -- before the verifier is
 * compared: an `hc` that a browser or another app on the phone intercepted can be tried once, and a
 * wrong guess cannot be followed by a right one.
 */
async function handleRedeem(request: Request, env: Env, config: CodePairConfig): Promise<Response> {
  if (await overIpBucket(env, request, "oauth-redeem-throttle", REDEEM_MAX_PER_WINDOW)) {
    logOutcome("oauth_redeem", "throttled");
    return throttledResponse("too many identity requests", BUCKET_RETRY_AFTER_S);
  }
  const read = await readJsonObject(request);
  if (!read.ok) {
    logOutcome("oauth_redeem", "rejected");
    return read.response;
  }
  const { hc, code_verifier: verifier } = read.body;
  if (typeof hc !== "string" || !TOKEN_RE.test(hc) || typeof verifier !== "string" || !CODE_VERIFIER_RE.test(verifier)) {
    logOutcome("oauth_redeem", "rejected");
    return jsonResponse(400, { error: "invalid redeem request" });
  }

  const handoff = parseHandoff(await takeRecord(env, "oauth-handoff", hc));
  if (handoff === null) {
    logOutcome("oauth_redeem", "expired");
    return jsonResponse(410, { error: "handoff expired or used" });
  }
  if (!timingSafeEqual(await s256(verifier), handoff.challenge)) {
    logOutcome("oauth_redeem", "rejected");
    return jsonResponse(400, { error: "handoff rejected" });
  }

  logOutcome("oauth_redeem", "ok");
  return jsonResponse(200, await mintSignIn(config, handoff.user, handoff.installPubkey));
}
