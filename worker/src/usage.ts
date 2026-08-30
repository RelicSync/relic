// Cached per-account totals (stored bytes + promoted count).
//
// Both numbers are aggregates over relic_meta, and both are read on the write
// path: the storage cap is enforced on EVERY relic push and every blob upload,
// the vault cap on every promote. Computing them by scanning meant D1 rows-read
// grew as `writes x vault size` — for an account with 4k relics that is ~12k
// rows read per write, and it was comfortably the largest D1 cost we had.
//
// So `account_usage` caches them. A missing row means "not computed yet", never
// "zero": readUsage() falls back to the scan, and the seed is written inside the
// same batch as the mutation that needed it (see usageDelta). That ordering is
// what makes it safe under concurrency — see the note on the INSERT arm below.

import type { Env } from "./env";

export interface Usage {
  /** Total stored bytes across the account's relics. */
  bytes: number;
  /** Number of promoted (kept) relics — the `vault` cap denominator. */
  vault: number;
}

/// Read an account's totals, computing them if they have never been cached.
export async function readUsage(env: Env, acct: string): Promise<Usage> {
  const row = await env.DB.prepare(
    "SELECT bytes_used, vault_count FROM account_usage WHERE account_id = ?1",
  ).bind(acct).first<{ bytes_used: number; vault_count: number }>();
  if (row) return { bytes: row.bytes_used, vault: row.vault_count };
  return computeUsage(env, acct);
}

/// The authoritative scan. Covered end to end by idx_meta_usage
/// (account_id, byte_size, promoted), so it reads index entries and never hits
/// the table. Deliberately does NOT persist what it computes: seeding is the
/// job of usageDelta, transactionally with the write that triggered it.
export async function computeUsage(env: Env, acct: string): Promise<Usage> {
  const row = await env.DB.prepare(
    `SELECT COALESCE(SUM(byte_size), 0) AS bytes,
            COALESCE(SUM(promoted), 0)  AS vault
       FROM relic_meta WHERE account_id = ?1`,
  ).bind(acct).first<{ bytes: number; vault: number }>();
  return { bytes: row?.bytes ?? 0, vault: row?.vault ?? 0 };
}

/// Build the statement that folds one relic mutation into the cached totals.
/// Batch it WITH the relic_meta write so the two can never disagree.
///
/// `base` is the totals as of this request's scan, or null when the caller never
/// scanned (deletes don't need to). It only ever feeds the INSERT arm, i.e. the
/// case where no cached row exists yet.
///
/// Concurrency: the UPDATE arm is a relative `+ delta` evaluated by SQLite, not
/// a read-modify-write in JS, so two devices writing to one account cannot lose
/// each other's change. The stale-base race is closed too — if another request
/// seeds the row first, our INSERT conflicts and we fall through to the relative
/// arm, discarding our own (now outdated) absolute. Without a base a missing row
/// simply stays missing and the next read recomputes it.
///
/// MAX(0, ...) is belt and braces: a counter should never be able to strand an
/// account below zero and lock it out of its own quota.
export function usageDelta(
  env: Env,
  acct: string,
  dBytes: number,
  dVault: number,
  base: Usage | null,
) {
  if (base) {
    return env.DB.prepare(
      `INSERT INTO account_usage (account_id, bytes_used, vault_count)
       VALUES (?1, MAX(0, ?2), MAX(0, ?3))
       ON CONFLICT(account_id) DO UPDATE SET
         bytes_used  = MAX(0, bytes_used  + ?4),
         vault_count = MAX(0, vault_count + ?5)`,
    ).bind(acct, base.bytes + dBytes, base.vault + dVault, dBytes, dVault);
  }
  return env.DB.prepare(
    `UPDATE account_usage
        SET bytes_used  = MAX(0, bytes_used  + ?2),
            vault_count = MAX(0, vault_count + ?3)
      WHERE account_id = ?1`,
  ).bind(acct, dBytes, dVault);
}
