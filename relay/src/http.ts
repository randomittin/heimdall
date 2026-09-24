// Tiny shared HTTP helpers used by both the top-level Worker router
// (src/worker.ts) and the per-session Durable Object (src/session.ts).

/**
 * Sent on every response this relay builds.
 *
 * HSTS is cheap defence-in-depth for the one thing TLS interception actually
 * costs here (2026-09-24 audit, finding 18): end-to-end confidentiality
 * survives a user-installed CA or an MDM profile, but the phone-leg upgrade
 * URL carries `pairing_code` / `device_token` in its query string, which is
 * enough to claim a session or evict the bound phone. A year's max-age with
 * `includeSubDomains`, no `preload` — preloading is a one-way door owned by
 * whoever operates the domain, not by this Worker.
 */
export const SECURITY_HEADERS: Record<string, string> = {
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
};

export function jsonResponse(
  status: number,
  body: unknown,
  extraHeaders?: Record<string, string>
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...SECURITY_HEADERS, ...extraHeaders },
  });
}

export const MAX_ENVELOPE_BYTES = 1048576; // 1 MiB — INV-16 (raised 2026-09-24: real hmd state ~136 KB exceeded the old 128 KiB cap)

/** True when a phone-leg upgrade request is provably plaintext (never TLS).
 * Absence of both headers is treated as the local-dev fallback (delta brief:
 * "http in dev is fine") — only an EXPLICIT http-scheme signal rejects.
 * Checks the `Upgrade` header separately; this only inspects scheme hints. */
export function isPlaintextUpgrade(request: Request): boolean {
  const forwardedProto = request.headers.get("X-Forwarded-Proto");
  if (forwardedProto && forwardedProto.toLowerCase() === "http") return true;

  const cfVisitor = request.headers.get("cf-visitor");
  if (cfVisitor) {
    try {
      const parsed = JSON.parse(cfVisitor) as { scheme?: unknown };
      if (parsed && parsed.scheme === "http") return true;
    } catch {
      // Malformed header — not a confirmed http signal, fail open to dev-friendly default.
    }
  }
  return false;
}

export function isWebSocketUpgrade(request: Request): boolean {
  return (request.headers.get("Upgrade") ?? "").toLowerCase() === "websocket";
}
