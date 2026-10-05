// Response builders shared by the router. Every answer carries nosniff and no-referrer; HSTS is the
// same year-long, no-preload header the relay sends (preloading is a one-way door owned by whoever
// operates the domain, not by this Worker).

export const SECURITY_HEADERS: Record<string, string> = {
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

const LOCKED_DOWN = "default-src 'none'; frame-ancestors 'none'";

export function jsonResponse(status: number, body: unknown, extra?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "Cache-Control": "no-store", ...SECURITY_HEADERS, ...extra },
  });
}

/** Plain text, never HTML: the receipt page is the only HTML this service returns. */
export function textResponse(status: number, text: string, extra?: Record<string, string>): Response {
  return new Response(`${text}\n`, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": LOCKED_DOWN,
      ...SECURITY_HEADERS,
      ...extra,
    },
  });
}

export function bytesResponse(body: Uint8Array | string, contentType: string, extra?: Record<string, string>): Response {
  return new Response(body, {
    status: 200,
    headers: { "content-type": contentType, "Content-Security-Policy": LOCKED_DOWN, ...SECURITY_HEADERS, ...extra },
  });
}
