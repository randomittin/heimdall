// The relay's one door to GitHub (pair-by-session-code, INV-39).
//
// Every call goes through `githubFetch`: one origin (`api.github.com`, or `GITHUB_API_BASE`
// when a test points it at its fake), one User-Agent, one 5 s bound on how long a verdict may
// take, and no redirect followed -- a 3xx would carry the Authorization header somewhere this
// code never chose. Callers get a verdict, never a throw and never a status they must map:
//
//   rejected     GitHub said the token is not good (or not ours): the caller answers 401
//   unavailable  GitHub could not say -- timeout, 5xx, a dropped connection, an answer that is
//                not the shape documented, the relay's own credentials refused: the caller
//                answers 502, and the operator sees a `github_error` line in the tail
//
// A token is only ever in the Authorization header or the JSON body of the one request it is
// for. It is never stored, never logged, and never part of an error: `github_error` carries the
// name of the call, the kind of failure and a status, nothing else.
//
// Two token kinds, two checks (spec 5.1 / 5.2):
//  - the phone's token came out of the device flow against OUR GitHub App, so the stronger
//    check-token endpoint applies: it answers only for a token issued to this App, and names
//    the user. The token is then deleted at GitHub (single use by construction, INV-39).
//  - the laptop's is whatever `gh auth token` prints, issued to GitHub CLI, so only `GET /user`
//    applies. One read, no more.

import { MAX_GH_LOGIN_LENGTH } from "./pairing";
import { logEvent } from "./logging";
import type { Env } from "./types";

const GITHUB_API_ORIGIN = "https://api.github.com";

/** How long any one GitHub call may take before the relay stops waiting for it. */
export const GITHUB_TIMEOUT_MS = 5000;

/** More than this from GitHub is not an answer to one of these three calls. */
const MAX_GITHUB_BODY_CHARS = 256 * 1024;

export interface GithubUser {
  id: number;
  login: string;
}

export type GithubVerdict =
  | { ok: true; user: GithubUser }
  | { ok: false; reason: "rejected" | "unavailable" };

const REJECTED: GithubVerdict = { ok: false, reason: "rejected" };
const UNAVAILABLE: GithubVerdict = { ok: false, reason: "unavailable" };

type RawAnswer = { failed: false; status: number; body: unknown } | { failed: true };

/** Which of the three calls, as the log names it. */
type CallName = "user" | "check" | "delete";

/** `logEvent` wants a session id; a GitHub call belongs to no session. */
function logGithubError(call: CallName, kind: string, status?: number): void {
  logEvent("github_error", { session_id: "none", call, kind, status });
}

/**
 * The chokepoint. `body` is the parsed JSON of the answer, or `undefined` when there was none
 * (204) or it was not JSON.
 */
async function githubFetch(
  env: Env,
  call: CallName,
  path: string,
  init: { method: string; headers: Record<string, string>; body?: string }
): Promise<RawAnswer> {
  const origin = (env.GITHUB_API_BASE || GITHUB_API_ORIGIN).replace(/\/+$/, "");
  try {
    const response = await fetch(`${origin}${path}`, {
      method: init.method,
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "hmd-relay",
        ...init.headers,
      },
      body: init.body,
      redirect: "manual",
      signal: AbortSignal.timeout(GITHUB_TIMEOUT_MS),
    });
    const text = await response.text();
    if (text.length > MAX_GITHUB_BODY_CHARS) {
      logGithubError(call, "bad_body", response.status);
      return { failed: true };
    }
    let body: unknown;
    if (text.length > 0) {
      try {
        body = JSON.parse(text);
      } catch {
        body = undefined;
      }
    }
    return { failed: false, status: response.status, body };
  } catch (error) {
    logGithubError(call, error instanceof DOMException && error.name === "TimeoutError" ? "timeout" : "network");
    return { failed: true };
  }
}

/** GitHub logins are alphanumerics and hyphens; enterprise-managed ones add an underscore and
 *  apps a `[bot]` suffix. Anything else is not a login, whatever sent it. */
const GH_LOGIN_RE = new RegExp(`^[A-Za-z0-9][A-Za-z0-9_.\\[\\]-]{0,${MAX_GH_LOGIN_LENGTH - 1}}$`);

function parseUser(value: unknown): GithubUser | null {
  if (typeof value !== "object" || value === null) return null;
  const { id, login } = value as Record<string, unknown>;
  if (typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0) return null;
  if (typeof login !== "string" || !GH_LOGIN_RE.test(login)) return null;
  return { id, login };
}

/**
 * The laptop's token: `GET /user`, one read. 401 is GitHub saying the token is not good;
 * every other answer that is not a user is GitHub being unable to say (a 403 is a rate limit
 * or a blocked App, not a verdict on the token).
 */
export async function verifyLaptopToken(env: Env, token: string): Promise<GithubVerdict> {
  const answer = await githubFetch(env, "user", "/user", {
    method: "GET",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (answer.failed) return UNAVAILABLE;
  if (answer.status === 401) return REJECTED;
  if (answer.status !== 200) {
    logGithubError("user", "status", answer.status);
    return UNAVAILABLE;
  }
  const user = parseUser(answer.body);
  if (!user) {
    logGithubError("user", "bad_body", answer.status);
    return UNAVAILABLE;
  }
  return { ok: true, user };
}

/**
 * The phone's token: check it against OUR App, then delete it at GitHub, in that order and
 * only that order. A verdict of `ok` means both happened -- the token proved who the user is
 * and is no longer good for anything, so nothing that outlives this request (the assertion
 * minted next) rests on a credential that is still live. A deletion that does not confirm is
 * `unavailable`, not a shrug: the caller mints nothing, and the phone may retry the same
 * token, which is still valid for exactly that reason.
 */
export async function consumePhoneToken(
  env: Env,
  clientId: string,
  clientSecret: string,
  token: string
): Promise<GithubVerdict> {
  let basic: string;
  try {
    basic = `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
  } catch {
    // a client id or secret that is not Latin-1 can never authenticate: a misconfiguration
    logGithubError("check", "client_credentials");
    return UNAVAILABLE;
  }
  const path = `/applications/${encodeURIComponent(clientId)}/token`;
  const request = {
    headers: { Authorization: basic, "Content-Type": "application/json" },
    body: JSON.stringify({ access_token: token }),
  };

  const check = await githubFetch(env, "check", path, { method: "POST", ...request });
  if (check.failed) return UNAVAILABLE;
  // GitHub answers 404 for a token this App never issued and 422 for one it cannot parse.
  if (check.status === 404 || check.status === 422) return REJECTED;
  if (check.status === 401 || check.status === 403) {
    // The token was not looked at: it is the relay's own client id and secret GitHub refused.
    logGithubError("check", "client_credentials", check.status);
    return UNAVAILABLE;
  }
  if (check.status !== 200) {
    logGithubError("check", "status", check.status);
    return UNAVAILABLE;
  }

  const answer = typeof check.body === "object" && check.body !== null ? (check.body as Record<string, unknown>) : null;
  const user = parseUser(answer?.user);
  if (!answer || !user) {
    logGithubError("check", "bad_body", check.status);
    return UNAVAILABLE;
  }
  // The path already scopes the check to this App; an answer that names another one anyway is
  // refused rather than trusted to be a quirk. (And is not deleted: it is not ours to delete.)
  const app = answer.app;
  if (typeof app === "object" && app !== null) {
    const appClientId = (app as Record<string, unknown>).client_id;
    if (typeof appClientId === "string" && appClientId !== clientId) return REJECTED;
  }

  const deletion = await githubFetch(env, "delete", path, { method: "DELETE", ...request });
  if (deletion.failed) return UNAVAILABLE;
  // 204 is deleted. 404/422 is a token that was already gone between the two calls: the same
  // end state, and exactly the one that was wanted.
  if (deletion.status !== 204 && deletion.status !== 404 && deletion.status !== 422) {
    logGithubError("delete", "status", deletion.status);
    return UNAVAILABLE;
  }
  return { ok: true, user };
}
