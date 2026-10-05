// The two Durable Object classes. Neither reads configuration: verification happens in the Worker
// before anything is stored, so a DO holds only bytes and counters.
//
//   ReceiptDO   one instance per receipt id (idFromName("receipt:<id>")). SQLite holds the single
//               immutable receipt row (a receipt is a signed statement, never edited) and the
//               current rating per finding. A DO is single-threaded, so "create if absent, else
//               compare" in put() is atomic: the first receipt filed under an id wins.
//   ThrottleDO  one instance per source IP (idFromName("write-throttle:<ip>")): a sliding-window
//               attempt counter, the same shape as the relay's /pair/init throttle
//               (relay/src/pairing.ts recordAttempt). Its alarm reclaims the row once the window
//               has passed, so an IP that stops calling leaves nothing behind.
//
// Reading an id that was never stored creates no storage: get() and labels() only SELECT, and the
// tables are made by the first write.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./types";

export type Visibility = "public" | "private";
export type Label = "real" | "false";
export type PutOutcome = "created" | "exists" | "conflict";
export interface StoredReceipt {
  raw: ArrayBuffer;
  visibility: Visibility;
}

function sameBuffer(a: ArrayBuffer, b: ArrayBuffer): boolean {
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  return left.byteLength === right.byteLength && left.every((value, i) => value === right[i]);
}

export class ReceiptDO extends DurableObject<Env> {
  private ensureTables(): void {
    const sql = this.ctx.storage.sql;
    sql.exec(
      "CREATE TABLE IF NOT EXISTS receipt (slot INTEGER PRIMARY KEY CHECK (slot = 1), raw BLOB NOT NULL, visibility TEXT NOT NULL, received_at INTEGER NOT NULL)"
    );
    sql.exec(
      "CREATE TABLE IF NOT EXISTS rating (finding_id TEXT PRIMARY KEY, label TEXT NOT NULL, source TEXT NOT NULL, rated_at INTEGER NOT NULL)"
    );
  }

  private hasTables(): boolean {
    return this.ctx.storage.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'receipt'").toArray().length > 0;
  }

  put(raw: ArrayBuffer, visibility: Visibility): PutOutcome {
    this.ensureTables();
    const sql = this.ctx.storage.sql;
    const existing = sql.exec<{ raw: ArrayBuffer }>("SELECT raw FROM receipt WHERE slot = 1").toArray()[0];
    if (existing) return sameBuffer(existing.raw, raw) ? "exists" : "conflict";
    sql.exec("INSERT INTO receipt (slot, raw, visibility, received_at) VALUES (1, ?, ?, ?)", raw, visibility, Date.now());
    return "created";
  }

  get(): StoredReceipt | null {
    if (!this.hasTables()) return null;
    const row = this.ctx.storage.sql.exec<{ raw: ArrayBuffer; visibility: Visibility }>("SELECT raw, visibility FROM receipt WHERE slot = 1").toArray()[0];
    return row ? { raw: row.raw, visibility: row.visibility } : null;
  }

  /** Record the current label for a finding (last write wins). The caller has already checked that
   *  the receipt exists and carries this finding. */
  rate(findingId: string, label: Label, source: string): void {
    this.ensureTables();
    this.ctx.storage.sql.exec(
      "INSERT INTO rating (finding_id, label, source, rated_at) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT (finding_id) DO UPDATE SET label = excluded.label, source = excluded.source, rated_at = excluded.rated_at",
      findingId,
      label,
      source,
      Date.now()
    );
  }

  /** finding id -> current label, for every rated finding. */
  labels(): Record<string, Label> {
    if (!this.hasTables()) return {};
    const rows = this.ctx.storage.sql.exec<{ finding_id: string; label: Label }>("SELECT finding_id, label FROM rating").toArray();
    return Object.fromEntries(rows.map((row) => [row.finding_id, row.label]));
  }
}

/** Timestamps (ms) of the attempts inside the window, with this attempt appended, and whether it is
 *  the one that crosses `maxInWindow`. */
export function recordAttempt(
  attempts: number[],
  nowMs: number,
  windowMs: number,
  maxInWindow: number
): { attempts: number[]; throttled: boolean } {
  const withinWindow = attempts.filter((t) => nowMs - t < windowMs);
  withinWindow.push(nowMs);
  return { attempts: withinWindow, throttled: withinWindow.length > maxInWindow };
}

const PURGE_GRACE_MS = 5_000;

export class ThrottleDO extends DurableObject<Env> {
  /** Count one attempt; true when it is over the limit. Every attempt counts, throttled ones too,
   *  so a client that keeps hammering stays throttled; the row is capped at max + 1 timestamps. */
  async hit(windowMs: number, maxInWindow: number): Promise<boolean> {
    const now = Date.now();
    const previous = (await this.ctx.storage.get<number[]>("hits")) ?? [];
    const { attempts, throttled } = recordAttempt(previous, now, windowMs, maxInWindow);
    await this.ctx.storage.put("hits", attempts.slice(-(maxInWindow + 1)));
    await this.ctx.storage.setAlarm(now + windowMs + PURGE_GRACE_MS);
    return throttled;
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
