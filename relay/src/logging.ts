// URL-redacting logger.
//
// INV-8: the relay never logs a full request URL — on the phone leg that URL
// carries `pairing_code`/`device_token` in its query string (INV-6/INV-7's
// "Token in URL" row). Callers pass individual named, primitive fields only;
// there is no parameter here that could ever hold a Request/URL object, and
// the banned keys below make it a type error to smuggle one through under a
// different name (e.g. `url`, `href`).
//
// This file must never contain the substrings "req.url" or "request.url" —
// enforced both by construction (no such field exists) and by a literal grep
// (see relay/README.md's verification section).

type LogValue = string | number | boolean | null | undefined;

export interface LogFields {
  session_id: string;
  /** Banned: forwarding a raw URL/path defeats INV-8. Use `event` + explicit
   * safe fields (e.g. route name, status code) instead. */
  url?: never;
  href?: never;
  full_url?: never;
  request_url?: never;
  req_url?: never;
  query?: never;
  search?: never;
  [key: string]: LogValue | never;
}

export function logEvent(event: string, fields: LogFields): void {
  const record: Record<string, LogValue> = { event };
  for (const [key, value] of Object.entries(fields)) {
    record[key] = value as LogValue;
  }
  console.log(JSON.stringify(record));
}
