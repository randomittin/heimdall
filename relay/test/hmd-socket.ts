// A test client for hmd's WebSocket leg -- `GET /session/:id/stream` with
// `Upgrade: websocket` -- plus the relay-log capture the specs that assert on
// relay events share. Not a spec: vitest only collects *.spec.ts / *.test.ts,
// so this file is imported, never run.
//
// Every spec using it has its own BASE host (they are separate sessions on
// the same Worker), so the base URL is a parameter rather than a constant here.

import { SELF } from "cloudflare:test";
import { expect } from "vitest";

export interface HmdCredentials {
  session_id: string;
  relay_session_token: string;
}

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Polls `condition` until it holds or `withinMs` runs out; resolves whether it held. */
export async function waitFor(condition: () => boolean, withinMs = 3000): Promise<boolean> {
  const deadline = Date.now() + withinMs;
  while (!condition()) {
    if (Date.now() >= deadline) return false;
    await sleep(10);
  }
  return true;
}

/** hmd's upgrade request, answered as-is, so a test that expects a refusal can read it. */
export function requestHmdSocket(
  base: string,
  sessionId: string,
  headers: Record<string, string>
): Promise<Response> {
  return SELF.fetch(`${base}/session/${sessionId}/stream`, {
    headers: { Upgrade: "websocket", ...headers },
  });
}

/**
 * The accepted client end of an hmd WebSocket. Listeners are attached in the
 * constructor, in the same turn as `accept()`, so a message the relay sends
 * while answering the upgrade (the held `device_bound`) is never missed.
 *
 * Everything is bounded: a message or close that never comes resolves `null`
 * after `withinMs`, so a missing frame fails as a plain assertion instead of
 * hanging until the test timeout.
 */
export class HmdSocket {
  /** Every text message received so far, in arrival order, consumed or not. */
  readonly received: string[] = [];
  private readonly unread: string[] = [];
  private closeEvent: { code: number; reason: string } | null = null;
  private wake: (() => void) | null = null;

  constructor(readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const { data } = event as unknown as { data: unknown };
      const text = typeof data === "string" ? data : "<binary message>";
      this.received.push(text);
      this.unread.push(text);
      this.wake?.();
    });
    socket.addEventListener("close", (event) => {
      const { code, reason } = event as unknown as { code: number; reason: string };
      this.closeEvent = { code, reason };
      this.wake?.();
    });
  }

  private changed(withinMs: number): Promise<void> {
    return new Promise((resolve) => {
      const settle = (): void => {
        clearTimeout(timer);
        this.wake = null;
        resolve();
      };
      const timer = setTimeout(settle, withinMs);
      this.wake = settle;
    });
  }

  /** The next text message, or null when none arrives within `withinMs` or the
   *  socket closed with nothing left unread. */
  async next(withinMs = 3000): Promise<string | null> {
    const deadline = Date.now() + withinMs;
    for (;;) {
      const message = this.unread.shift();
      if (message !== undefined) return message;
      if (this.closeEvent !== null) return null;
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      await this.changed(remaining);
    }
  }

  /** `next()`, parsed as the JSON envelope every non-`pong` message is. */
  async nextJson(withinMs = 3000): Promise<Record<string, unknown> | null> {
    const message = await this.next(withinMs);
    return message === null ? null : (JSON.parse(message) as Record<string, unknown>);
  }

  /** The close the relay sent (code and reason), or null if the socket is still open after `withinMs`. */
  async closed(withinMs = 3000): Promise<{ code: number; reason: string } | null> {
    const deadline = Date.now() + withinMs;
    for (;;) {
      if (this.closeEvent !== null) return this.closeEvent;
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      await this.changed(remaining);
    }
  }

  send(data: string | ArrayBuffer): void {
    this.socket.send(data);
  }
}

/** hmd opening its WebSocket leg with the session's bearer: resolves once the relay answered 101. */
export async function openHmdSocket(base: string, session: HmdCredentials): Promise<HmdSocket> {
  const response = await requestHmdSocket(base, session.session_id, {
    Authorization: `Bearer ${session.relay_session_token}`,
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("expected a websocket in the 101 response");
  socket.accept();
  return new HmdSocket(socket);
}

export interface RelayLog {
  /** Every raw line the relay wrote through `console.log` while capturing. */
  readonly lines: string[];
  /** The parsed entries of one event name, in the order logged. */
  events(name: string): Record<string, unknown>[];
}

/**
 * Runs `run` with `console.log` captured. The Durable Object shares the test's
 * isolate, so its `logEvent` lines land here too; the lines are returned raw
 * so a test can also prove one never carries a credential (INV-8).
 */
export async function withRelayLog(run: (log: RelayLog) => Promise<void>): Promise<RelayLog> {
  const lines: string[] = [];
  const log: RelayLog = {
    lines,
    events: (name) =>
      lines
        .filter((line) => line.startsWith("{"))
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .filter((entry) => entry.event === name),
  };
  const original = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map(String).join(" "));
  };
  try {
    await run(log);
  } finally {
    console.log = original;
  }
  return log;
}
