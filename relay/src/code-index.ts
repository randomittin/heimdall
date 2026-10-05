// One GitHub id's index of open code windows (pair-by-session-code, spec 5.3 / 5.4).
//
// The state below lives in a Durable Object named `code-index:<gh_id>` -- the same SessionDO
// class every throttle bucket uses, for the same reason (a new class needs a migration, and a
// migration is a risk to live sessions for no behavioural gain). The class's handlers read and
// write it; every decision is a pure function of it in this file, so the rules are one place
// and a test can drive them without a Worker.
//
// What the namespacing buys: a code is only ever looked up inside the verified caller's own
// index. A stranger's GitHub id can reach nothing of anyone else's, so there is no existence
// oracle (INV-42) and a 5-character code needs no secrecy of its own. What the index does NOT
// decide is whether a window may be released -- the window's own session does that (INV-40) --
// so an entry here is a hint that is always re-checked behind it.
//
// Retention (INV-41): an entry lives exactly as long as its window, counters live a minute or
// ten, and once they have lapsed the only thing left for a GitHub id is `not_before`, and that
// only until every assertion it kills has expired anyway.

import { GH_ASSERTION_TTL_S, recordAttempt } from "./pairing";

export interface IndexEntry {
  session_id: string;
  /** The window's session's `pair_exp`, epoch ms: after it the entry means nothing. */
  exp: number;
}

export interface CodeIndexState {
  codes: Record<string, IndexEntry>;
  /** Epoch seconds. An assertion minted before it is revoked (`iat < not_before`). */
  not_before?: number;
  /** Epoch ms of consecutive misses (404s), oldest first, at most `MISS_LOCKOUT_COUNT`. */
  miss_streak: number[];
  /** Epoch ms of recent attempts: the sliding window behind the per-id throttle. */
  attempts: number[];
}

/** 10 attempts a minute per GitHub id. */
export const INDEX_ATTEMPTS_MAX = 10;
export const INDEX_ATTEMPTS_WINDOW_MS = 60_000;
export const INDEX_THROTTLE_RETRY_AFTER_S = 60;

/** 10 consecutive misses lock the id out until 600 s after the last of them. */
export const MISS_LOCKOUT_COUNT = 10;
export const MISS_LOCKOUT_MS = 600_000;

export function emptyIndex(): CodeIndexState {
  return { codes: {}, miss_streak: [], attempts: [] };
}

/** Drops what has lapsed. A full streak is a lockout and is judged by its newest miss; a
 *  shorter one is a run of misses that stops counting once it is older than the lockout. */
export function pruneIndex(state: CodeIndexState, nowMs: number): void {
  for (const [code, entry] of Object.entries(state.codes)) {
    if (entry.exp <= nowMs) delete state.codes[code];
  }
  state.attempts = state.attempts.filter((at) => nowMs - at < INDEX_ATTEMPTS_WINDOW_MS);
  if (state.miss_streak.length < MISS_LOCKOUT_COUNT) {
    state.miss_streak = state.miss_streak.filter((at) => nowMs - at < MISS_LOCKOUT_MS);
  } else if (nowMs - (state.miss_streak[state.miss_streak.length - 1] as number) >= MISS_LOCKOUT_MS) {
    state.miss_streak = [];
  }
  // A revoke matters only until every assertion it kills has expired by itself: one minted before
  // `not_before` lapses by `not_before + GH_ASSERTION_TTL_S`. After that the marker protects
  // nothing and goes. Kept, `lastDeadline` would go on answering a moment that has passed, and the
  // storage alarm re-armed from it would be due at once and fire again, for ever.
  if (state.not_before !== undefined && nowMs >= (state.not_before + GH_ASSERTION_TTL_S) * 1000) {
    delete state.not_before;
  }
}

/** Opens `code` for `sessionId`. Refused only when ANOTHER session of this GitHub id holds it
 *  and its window has not lapsed; the same session registering again just renews its entry. */
export function registerEntry(
  state: CodeIndexState,
  code: string,
  sessionId: string,
  expMs: number,
  nowMs: number
): boolean {
  const held = state.codes[code];
  if (held && held.session_id !== sessionId && held.exp > nowMs) return false;
  state.codes[code] = { session_id: sessionId, exp: expMs };
  return true;
}

/** Removes `code`'s entry, but only if it still points at `sessionId`: a renewal may have
 *  handed the code to a newer session in the meantime, and that entry is not this caller's. */
export function clearEntry(state: CodeIndexState, code: string, sessionId: string): void {
  if (state.codes[code]?.session_id === sessionId) delete state.codes[code];
}

export type Admission = { admitted: true } | { admitted: false; retryAfterS: number };

/** Whether this GitHub id may make an attempt now, and the attempt recorded if so. The
 *  lockout is answered first: a locked-out id's further attempts are not counted, so they
 *  neither extend the lockout nor wear out the minute's budget behind it. */
export function admitAttempt(state: CodeIndexState, nowMs: number): Admission {
  if (state.miss_streak.length >= MISS_LOCKOUT_COUNT) {
    const lockedUntil = (state.miss_streak[state.miss_streak.length - 1] as number) + MISS_LOCKOUT_MS;
    if (nowMs < lockedUntil) return { admitted: false, retryAfterS: Math.ceil((lockedUntil - nowMs) / 1000) };
    state.miss_streak = [];
  }
  const { attempts, throttled } = recordAttempt(state.attempts, nowMs, INDEX_ATTEMPTS_WINDOW_MS, INDEX_ATTEMPTS_MAX);
  state.attempts = attempts;
  if (throttled) return { admitted: false, retryAfterS: INDEX_THROTTLE_RETRY_AFTER_S };
  return { admitted: true };
}

export function recordMiss(state: CodeIndexState, nowMs: number): void {
  state.miss_streak = [...state.miss_streak, nowMs].slice(-MISS_LOCKOUT_COUNT);
}

export function recordHit(state: CodeIndexState): void {
  state.miss_streak = [];
}

/** `not_before` becomes the current second, never earlier than it already was. */
export function revokeBefore(state: CodeIndexState, nowMs: number): number {
  state.not_before = Math.max(state.not_before ?? 0, Math.floor(nowMs / 1000));
  return state.not_before;
}

/** An assertion minted before the last revoke is dead; one minted at or after it is not. */
export function isRevoked(state: CodeIndexState, iat: number): boolean {
  return state.not_before !== undefined && iat < state.not_before;
}

/**
 * The last moment anything in `state` still matters, epoch ms, or `null` when nothing does and
 * the whole object can be reclaimed. The storage alarm is set to this plus a grace.
 */
export function lastDeadline(state: CodeIndexState): number | null {
  const deadlines: number[] = [];
  for (const entry of Object.values(state.codes)) deadlines.push(entry.exp);
  const lastMiss = state.miss_streak[state.miss_streak.length - 1];
  if (lastMiss !== undefined) deadlines.push(lastMiss + MISS_LOCKOUT_MS);
  const lastAttempt = state.attempts[state.attempts.length - 1];
  if (lastAttempt !== undefined) deadlines.push(lastAttempt + INDEX_ATTEMPTS_WINDOW_MS);
  if (state.not_before !== undefined) deadlines.push((state.not_before + GH_ASSERTION_TTL_S) * 1000);
  return deadlines.length === 0 ? null : Math.max(...deadlines);
}
