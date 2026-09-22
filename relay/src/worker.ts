// Top-level Worker entry point: routes `/pair/init` (unauthenticated per
// spec §2 — nobody has a credential yet) and forwards a session's PUBLIC
// surface (`stream`, `frames`, `ws`, `revoke`) to that session's Durable
// Object, which is the sole owner of the session's state (spec §1). Any
// other `/session/<uuid>/*` subpath — including the Durable Object's own
// internal `/init` handler — is rejected here and never reaches the
// Durable Object; see PUBLIC_SESSION_SUBPATHS below.

import type { Env } from "./types";
import { jsonResponse } from "./http";

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
const PUBLIC_SESSION_SUBPATHS = new Set(["stream", "frames", "ws", "revoke"]);

const SESSION_PATH_RE = /^\/session\/([^/]+)\/([^/]+)$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/pair/init") {
      return handlePairInit(env);
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
      const id = env.SESSION.idFromName(sessionId);
      const stub = env.SESSION.get(id);
      const forwardUrl = new URL(request.url);
      forwardUrl.pathname = `/${subPath}`;
      return stub.fetch(new Request(forwardUrl.toString(), request));
    }

    return jsonResponse(404, { error: "not found" });
  },
};

async function handlePairInit(env: Env): Promise<Response> {
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
