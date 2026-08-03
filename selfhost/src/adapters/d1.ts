// A D1Database-compatible shim over a local better-sqlite3 handle.
//
// The worker code (worker/src/*) is written against Cloudflare's D1 API:
//   env.DB.prepare(sql).bind(...args).first()/.all()/.run()
//   env.DB.batch([stmt, stmt, ...])
// and it uses NUMBERED bind parameters (?1, ?2, ...), often re-referencing the
// same index (e.g. touchDevice's `?3` appears twice) and re-supplying a value
// under two indices (listRelics binds the cursor value under both ?3 and ?4).
//
// better-sqlite3's anonymous `?` binding can't express "?3 used twice" cleanly,
// so we rewrite `?N` -> named `@pN` and pass a params object keyed only by the
// indices the statement actually references. That is unambiguous, handles
// repeats for free, and never trips better-sqlite3's strict arity checks.
//
// This is a faithful shim, not a general D1 emulator: it implements exactly the
// surface the worker calls. Everything is synchronous under the hood (SQLite is
// synchronous) but presented as async to match the D1 contract the worker awaits.

import Database from "better-sqlite3";

// better-sqlite3 only binds numbers, strings, bigints, buffers, and null.
// The worker never binds a raw boolean, but normalize defensively so a stray
// `promoted` flag or an `undefined` can never throw at the driver.
function norm(v: unknown): unknown {
  if (v === undefined || v === null) return null;
  if (typeof v === "boolean") return v ? 1 : 0;
  return v;
}

// Rewrite ?N -> @pN and build the params object for only the referenced indices.
function compile(sql: string, args: unknown[]): { text: string; params: Record<string, unknown>; hasParams: boolean } {
  const used = new Set<number>();
  const text = sql.replace(/\?(\d+)/g, (_m, n: string) => {
    used.add(Number(n));
    return "@p" + n;
  });
  const params: Record<string, unknown> = {};
  for (const n of used) params["p" + n] = norm(args[n - 1]);
  return { text, params, hasParams: used.size > 0 };
}

export interface D1LikeResult<T = unknown> {
  results: T[];
  success: boolean;
  meta: Record<string, unknown>;
}

export function makeD1(db: Database.Database) {
  // Cache compiled better-sqlite3 statements by their (rewritten) SQL text.
  const cache = new Map<string, Database.Statement>();
  const prep = (text: string): Database.Statement => {
    let s = cache.get(text);
    if (!s) {
      s = db.prepare(text);
      cache.set(text, s);
    }
    return s;
  };

  class Stmt {
    constructor(private readonly sql: string, private readonly args: unknown[]) {}

    bind(...args: unknown[]): Stmt {
      return new Stmt(this.sql, args);
    }

    private compiled() {
      const { text, params, hasParams } = compile(this.sql, this.args);
      return { stmt: prep(text), params, hasParams };
    }

    async first<T = unknown>(): Promise<T | null> {
      const { stmt, params, hasParams } = this.compiled();
      const row = hasParams ? stmt.get(params) : stmt.get();
      return (row === undefined ? null : row) as T | null;
    }

    async all<T = unknown>(): Promise<D1LikeResult<T>> {
      const { stmt, params, hasParams } = this.compiled();
      const results = (hasParams ? stmt.all(params) : stmt.all()) as T[];
      return { results, success: true, meta: {} };
    }

    async run(): Promise<{ success: boolean; meta: { changes: number; last_row_id: number } }> {
      const { stmt, params, hasParams } = this.compiled();
      const info = hasParams ? stmt.run(params) : stmt.run();
      return { success: true, meta: { changes: info.changes, last_row_id: Number(info.lastInsertRowid) } };
    }

    // Consumed by batch() below.
    _sql(): string {
      return this.sql;
    }
    _args(): unknown[] {
      return this.args;
    }
  }

  return {
    prepare(sql: string): Stmt {
      return new Stmt(sql, []);
    },

    // D1 runs a batch atomically; mirror that with a better-sqlite3 transaction.
    // The worker only ever batches writes (INSERT/DELETE), so .run() each.
    async batch(stmts: Stmt[]): Promise<{ success: boolean; meta: { changes: number } }[]> {
      const tx = db.transaction((items: Stmt[]) =>
        items.map((s) => {
          const { text, params, hasParams } = compile(s._sql(), s._args());
          const info = hasParams ? prep(text).run(params) : prep(text).run();
          return { success: true, meta: { changes: info.changes } };
        }),
      );
      return tx(stmts);
    },
  };
}
