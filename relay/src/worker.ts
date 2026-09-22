// Top-level Worker entry point: routes `/pair/init` (unauthenticated per
// spec §2 — nobody has a credential yet) and forwards every
// `/session/<uuid>/*` request to that session's Durable Object, which is
// the sole owner of the session's state (spec §1).

import type { Env } from "./types";
import { jsonResponse } from "./http";

export { SessionDO } from "./session";

const SESSION_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const SESSION_PATH_RE = /^\/session\/([^/]+)(\/.*)?$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/pair/init") {
      return handlePairInit(env);
    }

    const match = SESSION_PATH_RE.exec(url.pathname);
    if (match) {
      const sessionId = match[1] ?? "";
      if (!SESSION_ID_RE.test(sessionId)) {
        return jsonResponse(400, { error: "invalid session id" });
      }
      const subPath = match[2] || "/";
      const id = env.SESSION.idFromName(sessionId);
      const stub = env.SESSION.get(id);
      const forwardUrl = new URL(request.url);
      forwardUrl.pathname = subPath;
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
