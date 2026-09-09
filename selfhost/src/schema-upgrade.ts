// Additive column upgrades for an EXISTING self-host database.
//
// A self-host instance bootstraps its database from worker/schema.sql, which is
// written so every statement is CREATE ... IF NOT EXISTS. That makes a fresh
// install correct and a re-run harmless, but it can never change a table that
// already exists: `CREATE TABLE IF NOT EXISTS` on a live table does nothing, so
// a column added to schema.sql simply never appears. The Cloudflare deploy gets
// those columns from worker/migrations/*.sql, which self-host never runs.
//
// So this is self-host's migration ledger, in the only form that suits it: for
// each column the worker code now reads, check PRAGMA table_info and ALTER it in
// if it is missing. Idempotent, cheap (a pragma per table on boot), and safe to
// run against a database of any age.
//
// It must run BEFORE schema.sql is executed. schema.sql now indexes
// relic_meta.evicted, and CREATE INDEX on a column an old database lacks throws
// and takes the whole exec with it.
//
// Adding the next migration: append to UPGRADES. Do not reorder or remove
// entries, and do not make one depend on another having run in the same pass.

import type Database from "better-sqlite3";

export interface ColumnUpgrade {
  table: string;
  column: string;
  /** Run only when `column` is missing from `table`. */
  add: string;
  /** Run straight after `add`, in the same pass. Backfills, index rebuilds. */
  then?: string[];
}

export const UPGRADES: ColumnUpgrade[] = [
  // worker/migrations/0012_history_ring.sql
  {
    table: "relic_meta",
    column: "evicted",
    add: "ALTER TABLE relic_meta ADD COLUMN evicted INTEGER NOT NULL DEFAULT 0",
    then: [
      // The account_usage seed scan counts evicted rows now, so the index that
      // covered it end to end has to carry the column. It already exists under
      // this name, which makes schema.sql's CREATE ... IF NOT EXISTS a no-op,
      // so it has to be rebuilt here.
      "DROP INDEX IF EXISTS idx_meta_usage",
      "CREATE INDEX IF NOT EXISTS idx_meta_usage ON relic_meta(account_id, byte_size, promoted, evicted)",
    ],
  },
  {
    table: "account_usage",
    column: "history_count",
    add: "ALTER TABLE account_usage ADD COLUMN history_count INTEGER NOT NULL DEFAULT 0",
    then: [
      // One-time backfill, same as the Cloudflare migration does.
      `UPDATE account_usage SET history_count = (
         SELECT COUNT(*) FROM relic_meta m
          WHERE m.account_id = account_usage.account_id AND m.promoted = 0)`,
    ],
  },
  {
    table: "account_usage",
    column: "evicted_count",
    add: "ALTER TABLE account_usage ADD COLUMN evicted_count INTEGER NOT NULL DEFAULT 0",
  },
  {
    table: "account_usage",
    column: "ring_evicted",
    add: "ALTER TABLE account_usage ADD COLUMN ring_evicted INTEGER NOT NULL DEFAULT 0",
  },
  {
    table: "account_usage",
    column: "ring_email_at",
    add: "ALTER TABLE account_usage ADD COLUMN ring_email_at INTEGER",
  },
];

/// Apply every upgrade this database is missing. Returns the columns it added,
/// so the caller can say so in the log. A table that does not exist yet is
/// skipped: this is a fresh install and schema.sql is about to create it with
/// the columns already in place.
export function applyColumnUpgrades(db: Database.Database): string[] {
  const added: string[] = [];
  for (const u of UPGRADES) {
    const cols = db.prepare(`PRAGMA table_info(${u.table})`).all() as { name: string }[];
    if (cols.length === 0) continue; // table not created yet
    if (cols.some((c) => c.name === u.column)) continue; // already upgraded
    db.exec(u.add);
    for (const stmt of u.then ?? []) db.exec(stmt);
    added.push(`${u.table}.${u.column}`);
  }
  return added;
}
