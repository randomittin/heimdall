// Top-level Worker entry point: routes `/pair/init` (unauthenticated per
// spec §2 — nobody has a credential yet) and forwards a session's PUBLIC
// surface (`stream`, `frames`, `ws`, `revoke`, `code`) to that session's Durable
// Object, which is the sole owner of the session's state (spec §1). Any
// other `/session/<uuid>/*` subpath — including the Durable Object's own
// internal `/init` handler — is rejected here and never reaches the
// Durable Object; see PUBLIC_SESSION_SUBPATHS below. `GET /health` is the one
// other unauthenticated route: the Worker answers it itself, first, and it
// never reaches a Durable Object (src/health.ts).
//
// Pair-by-session-code adds three routes the Worker answers itself —
// `POST /identity/github`, `POST /identity/github/revoke`, `POST /pair/code`
// (src/code-pair.ts) — and the session subpath `code`, where hmd registers a
// window. All four answer 503 `code pairing disabled` unless the GitHub App's
// config is set; the QR flow never depends on it.

import type { Env } from "./types";
import {
  codePairConfig,
  disabledResponse,
  handleIdentityGithub,
  handleIdentityRevoke,
  handlePairCode,
} from "./code-pair";
import { handleHealth } from "./health";
import { jsonResponse } from "./http";
import { PAIR_INIT_RETRY_AFTER_S } from "./pairing";

export { SessionDO } from "./session";

const SESSION_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The session's only public entry points (spec §1/§2). `/init` is
// deliberately absent: relay/src/session.ts's handleInit is an internal
// contract meant to run only from this file's own handlePairInit below (a
// direct `stub.fetch("http://do-internal/init", ...)` call, never a public
// path). Before this whitelist existed, the permissive `(\/.*)?` subpath
// match forwarded ANY subpath — including a public `POST
// /session/:id/init` — straight to the Durable Object, letting an
// unauthenticated caller who merely knew/guessed a session_id re-mint its
// pairing_code and invalidate the real one (see
// test/trace/mutants-pairing.spec.ts's regression test for this).
//
// `code` is hmd registering a code window (pair-by-session-code, spec 6.2); it is
// authenticated by the session's own bearer inside the Durable Object, like `frames` and
// `revoke`. The index and release handlers it feeds (`code-release`, `index-*`, `bucket`)
// are internal in exactly the way `init` is, and stay out of this set for the same reason.
const PUBLIC_SESSION_SUBPATHS = new Set(["stream", "frames", "ws", "revoke", "code"]);

const SESSION_PATH_RE = /^\/session\/([^/]+)\/([^/]+)$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Liveness probe: answered ahead of everything below, every other branch of
    // which builds a Durable Object stub.
    if (url.pathname === "/health" && (request.method === "GET" || request.method === "HEAD")) {
      return handleHealth(request, env);
    }

    if (request.method === "POST" && url.pathname === "/pair/init") {
      return handlePairInit(request, env);
    }
    if (request.method === "POST" && url.pathname === "/identity/github") {
      return handleIdentityGithub(request, env);
    }
    if (request.method === "POST" && url.pathname === "/identity/github/revoke") {
      return handleIdentityRevoke(request, env);
    }
    if (request.method === "POST" && url.pathname === "/pair/code") {
      return handlePairCode(request, env);
    }

    const match = SESSION_PATH_RE.exec(url.pathname);
    if (match) {
      const sessionId = match[1] ?? "";
      const subPath = match[2] ?? "";
      if (!SESSION_ID_RE.test(sessionId)) {
        return jsonResponse(400, { error: "invalid session id" });
      }
      if (!PUBLIC_SESSION_SUBPATHS.has(subPath)) {
        return jsonResponse(404, { error: "not found" });
      }
      // Before the session is touched: with code pairing off, `code` is not a route here.
      if (subPath === "code" && codePairConfig(env) === null) return disabledResponse();
      const id = env.SESSION.idFromName(sessionId);
      const stub = env.SESSION.get(id);
      const forwardUrl = new URL(request.url);
      forwardUrl.pathname = `/${subPath}`;
      return stub.fetch(new Request(forwardUrl.toString(), request));
    }

    return jsonResponse(404, { error: "not found" });
  },
};

/**
 * The throttle bucket for one source IP.
 *
 * `CF-Connecting-IP` is set by Cloudflare's own edge on every request that
 * reaches a Worker and cannot be spoofed by the client — an inbound header of
 * that name is overwritten, not forwarded. Its absence therefore means "not
 * behind the edge", i.e. `wrangler dev` or the vitest pool, which share the
 * `"unknown"` bucket and are throttled like any other caller. Fail closed:
 * treating an absent header as "unlimited" would hand the bypass to anyone who
 * ever found a path to the Worker that skipped the edge.
 */
function throttleBucket(request: Request, env: Env): DurableObjectStub {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return env.SESSION.get(env.SESSION.idFromName(`pair-init-throttle:${ip}`));
}

async function handlePairInit(request: Request, env: Env): Promise<Response> {
  // INV-5 keeps this endpoint identity-free on purpose, and the throttle does
  // not change that: no credential is asked for, no caller is identified
  // beyond the edge-supplied IP that Cloudflare already routes on. It supplies
  // the "bounded by ... throttle" half of INV-5 that the 2026-09-24 audit
  // (finding 7) found missing — an unauthenticated loop here minted one
  // Durable Object with a persistent row per request, with no reaping path.
  const throttleRes = await throttleBucket(request, env).fetch("http://do-internal/throttle", {
    method: "POST",
  });
  const { throttled } = (await throttleRes.json()) as { throttled: boolean };
  if (throttled) {
    return jsonResponse(
      429,
      { error: "too many pairing requests", retry_after_s: PAIR_INIT_RETRY_AFTER_S },
      { "Retry-After": String(PAIR_INIT_RETRY_AFTER_S) }
    );
  }

  const sessionId = crypto.randomUUID();
  const id = env.SESSION.idFromName(sessionId);
  const stub = env.SESSION.get(id);
  const initResponse = await stub.fetch("http://do-internal/init", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ session_id: sessionId }),
  });
  if (!initResponse.ok) return initResponse;
  const body = await initResponse.json();
  return jsonResponse(200, body);
}
