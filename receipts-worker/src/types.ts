import type { ReceiptDO, ThrottleDO } from "./do";

export interface Env {
  RECEIPT: DurableObjectNamespace<ReceiptDO>;
  THROTTLE: DurableObjectNamespace<ThrottleDO>;
  /** The receipt PUBLIC key(s): one base64 32-byte key per line, `#` comments allowed. */
  RECEIPT_PUBKEYS?: string;
  /** SHA-256 hex digests (whitespace or comma separated) of the accepted bearer tokens. */
  API_TOKEN_SHA256S?: string;
  /** https base URL pages, OG tags and upload answers link to. */
  PUBLIC_BASE_URL?: string;
  /** https URL the "Request cloud access" link points at. */
  CTA_URL?: string;
  /** Commit sha injected by the deploy (`wrangler deploy --var BUILD_ID:<sha>`). */
  BUILD_ID?: string;
}

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };
