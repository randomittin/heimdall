// Pair-by-session-code, the pieces the Worker composes: field validators and the
// proof-of-possession message. The routes themselves (`/identity/github`,
// `/identity/github/revoke`, `/pair/code`) are added below as the Worker's handlers; the
// GitHub calls live in src/github.ts and a GitHub id's window index in src/code-index.ts.
// Wire: relay/contract/code-pair.json. Design: hmdapp
// docs/superpowers/specs/2026-10-05-pair-by-session-code.md.

/** hmd's session code alphabet (bin/lib/hmd_session_code.py): 32 symbols, no 0/1/I/O. */
export const SESSION_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const SESSION_CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}$/;

/** Exactly five characters of the alphabet, uppercase. The app normalises what a person
 *  types before it sends it; the relay is deliberately not lenient about the result. */
export function isValidSessionCode(value: unknown): value is string {
  return typeof value === "string" && SESSION_CODE_RE.test(value);
}

export const DEVICE_LABEL_MAX_CHARS = 32;

/**
 * Characters a device label may not contain. The label is the phone's own claim about
 * itself and hmd prints it in a prompt the laptop user answers (threat T7), so what is
 * refused is anything that can move the cursor, start an escape sequence or reorder the
 * line: C0 controls (ESC among them), DEL, C1 controls, the Unicode line and paragraph
 * separators, the bidirectional controls, and lone surrogates (not text at all).
 */
const DEVICE_LABEL_FORBIDDEN =
  /[\u0000-\u001f\u007f-\u009f؜‎‏  ‪-‮⁦-⁩]|\p{Cs}/u;

/** 1..32 printable characters, counted in code points. */
export function isValidDeviceLabel(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0) return false;
  // 32 code points are at most 64 UTF-16 units, so anything longer is over the cap and the
  // scans below never run on an attacker-sized string.
  if (value.length > DEVICE_LABEL_MAX_CHARS * 2) return false;
  if (DEVICE_LABEL_FORBIDDEN.test(value)) return false;
  return [...value].length <= DEVICE_LABEL_MAX_CHARS;
}

/** 1..255 visible ASCII characters: the shape every GitHub token has. A value outside it
 *  cannot be one, and is refused without being sent upstream — an `Authorization` header
 *  built from a newline or a control character is a request-smuggling shape, not a token. */
export function isPlausibleGithubToken(value: unknown): value is string {
  return typeof value === "string" && /^[\x21-\x7e]{1,255}$/.test(value);
}

/** What the phone's install key signs for `/pair/code` (INV-43): the code and a timestamp,
 *  under a domain label, so a signature for one purpose, code or moment is no use for
 *  another. `ts` is the request's integer, in decimal. */
export function popMessage(code: string, ts: number): Uint8Array {
  return new TextEncoder().encode(`hmd-pair-code-v1\n${code}\n${ts}`);
}
