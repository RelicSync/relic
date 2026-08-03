// A KVNamespace-compatible shim over a `kv` table in the same SQLite file.
//
// The worker uses one KV namespace (env.PAIR) for two things:
//   - `pair:` QR pairing relay slots (short TTL, single-use)
//   - `rev:`  device-revocation markers (90d TTL)
// A self-host instance mostly skips QR pairing (devices just re-enter the
// passphrase), but device revocation is a real feature, so we back KV with a
// tiny expiring table. Only the surface the worker calls is implemented:
// get / put({expirationTtl}) / delete / list({prefix}).

import type Database from "better-sqlite3";

const nowS = () => Math.floor(Date.now() / 1000);

export function makeKV(db: Database.Database) {
  db.exec(
    `CREATE TABLE IF NOT EXISTS kv (
       k TEXT PRIMARY KEY,
       v TEXT NOT NULL,
       expires_at INTEGER
     )`,
  );
  const getStmt = db.prepare("SELECT v, expires_at FROM kv WHERE k = ?");
  const delStmt = db.prepare("DELETE FROM kv WHERE k = ?");
  const putStmt = db.prepare(
    `INSERT INTO kv (k, v, expires_at) VALUES (?, ?, ?)
     ON CONFLICT(k) DO UPDATE SET v = excluded.v, expires_at = excluded.expires_at`,
  );

  return {
    async get(key: string): Promise<string | null> {
      const row = getStmt.get(key) as { v: string; expires_at: number | null } | undefined;
      if (!row) return null;
      if (row.expires_at !== null && row.expires_at <= nowS()) {
        delStmt.run(key);
        return null;
      }
      return row.v;
    },

    async put(key: string, value: string, opts?: { expirationTtl?: number }) {
      const exp = opts?.expirationTtl ? nowS() + opts.expirationTtl : null;
      putStmt.run(key, value, exp);
    },

    async delete(key: string) {
      delStmt.run(key);
    },

    async list(opts?: { prefix?: string; cursor?: string }) {
      const prefix = opts?.prefix ?? "";
      // Escape LIKE metacharacters in the prefix so `pair:%` etc. match literally.
      const like = prefix.replace(/[\\%_]/g, "\\$&") + "%";
      const rows = db
        .prepare("SELECT k FROM kv WHERE k LIKE ? ESCAPE '\\' ORDER BY k")
        .all(like) as { k: string }[];
      return { keys: rows.map((r) => ({ name: r.k })), list_complete: true, cursor: undefined };
    },
  };
}
