import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { deleteRelic, putRelic } from "../src/index";
import { restoreEvicted } from "../src/stripe";
import { TIERS } from "../src/tiers";
import { computeUsage, readUsage, ringDelta, usageDelta } from "../src/usage";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

function envelope(uid: string, bytes: number, promoted: boolean, updated = 1000) {
  return {
    v: 1, uid, created_at: 1000, updated_at: updated, byte_size: bytes,
    promoted, n: "nonce", ct: "cipher",
  };
}

function put(uid: string, bytes: number, promoted = false, updated = 1000, tier = "free") {
  const req = new Request(`http://x/relic/${uid}`, {
    method: "PUT",
    body: JSON.stringify(envelope(uid, bytes, promoted, updated)),
  });
  return putRelic(req, E, { account: "A", tier } as never, uid);
}

const cached = () =>
  E.DB.prepare("SELECT bytes_used, vault_count FROM account_usage WHERE account_id = ?1")
    .bind("A").first();

// The two history-ring counters, read on their own so the storage/vault cases
// above stay readable.
const ringCached = () =>
  E.DB.prepare(
    `SELECT history_count, evicted_count, ring_evicted
       FROM account_usage WHERE account_id = ?1`,
  ).bind("A").first();

describe("account_usage: the cache tracks the table", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  it("seeds on first write and matches a full recount", async () => {
    await put("u1", 100, true);
    expect(await cached()).toEqual({ bytes_used: 100, vault_count: 1 });
    expect(await computeUsage(E, "A")).toEqual({
      bytes: 100, vault: 1, history: 0, evicted: 0,
    });
  });

  it("follows adds, size changes, promote/demote and deletes", async () => {
    await put("u1", 100, true);
    await put("u2", 50, false);
    expect(await cached()).toEqual({ bytes_used: 150, vault_count: 1 });

    // same uid, bigger payload, now promoted -> delta on both counters
    await put("u2", 80, true, 2000);
    expect(await cached()).toEqual({ bytes_used: 180, vault_count: 2 });

    // demote and shrink
    await put("u2", 20, false, 3000);
    expect(await cached()).toEqual({ bytes_used: 120, vault_count: 1 });

    await deleteRelic(E, "A", "u1", { blob_key: null, byte_size: 100, promoted: 1 }, 10);
    expect(await cached()).toEqual({ bytes_used: 20, vault_count: 0 });

    // the cache still agrees with the table it is standing in for
    expect(await computeUsage(E, "A")).toEqual({
      bytes: 20, vault: 0, history: 1, evicted: 0,
    });
  });

  it("a stale write that loses LWW moves neither counter", async () => {
    await put("u1", 100, true, 5000);
    const before = await cached();
    const resp = await put("u1", 999, true, 4000); // older updated_at
    expect(await resp.json()).toEqual({ stale: true });
    expect(await cached()).toEqual(before);
  });
});

describe("account_usage: recovery and edge cases", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  it("a missing row means recompute, not zero", async () => {
    await put("u1", 100, true);
    await put("u2", 40, true);
    await E.DB.prepare("DELETE FROM account_usage").run(); // simulate never-seeded
    expect(await readUsage(E, "A")).toEqual({
      bytes: 140, vault: 2, history: 0, evicted: 0,
    });
  });

  it("re-seeds itself on the next write after the row is lost", async () => {
    await put("u1", 100, true);
    await E.DB.prepare("DELETE FROM account_usage").run();
    await put("u2", 40, false);
    expect(await cached()).toEqual({ bytes_used: 140, vault_count: 1 });
  });

  it("a delete with no cached row leaves it missing rather than negative", async () => {
    await put("u1", 100, false);
    await E.DB.prepare("DELETE FROM account_usage").run();
    await deleteRelic(E, "A", "u1", { blob_key: null, byte_size: 100, promoted: 0 }, 10);
    expect(await cached()).toBeNull();
    // recount agrees
    expect(await readUsage(E, "A")).toEqual({
      bytes: 0, vault: 0, history: 0, evicted: 0,
    });
  });

  it("never lets a counter go negative", async () => {
    await put("u1", 100, false);
    // an over-large decrement (only reachable if the cache were ever wrong)
    await E.DB.batch([usageDelta(E, "A", -100000, -50, null)]);
    expect(await cached()).toEqual({ bytes_used: 0, vault_count: 0 });
  });

  it("an unseeded account reads as empty", async () => {
    expect(await readUsage(E, "NOBODY")).toEqual({
      bytes: 0, vault: 0, history: 0, evicted: 0,
    });
  });
});

// The two counters GET /account reports as history_count and evicted_count.
// Every path that can move a row in or out of "live and unpromoted" is here,
// because a counter that drifts is a client showing a number that is not true.
describe("account_usage: the history-ring counters", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  it("counts an unpromoted put and ignores a promoted one", async () => {
    await put("h1", 10, false);
    expect(await ringCached()).toMatchObject({ history_count: 1, evicted_count: 0 });
    await put("h2", 10, true);
    expect(await ringCached()).toMatchObject({ history_count: 1, evicted_count: 0 });
  });

  it("follows promote and demote of the same row", async () => {
    await put("h1", 10, false);
    expect(await ringCached()).toMatchObject({ history_count: 1 });
    await put("h1", 10, true, 2000); // promote
    expect(await ringCached()).toMatchObject({ history_count: 0 });
    await put("h1", 10, false, 3000); // demote
    expect(await ringCached()).toMatchObject({ history_count: 1 });
  });

  it("a delete takes the row back out", async () => {
    await put("h1", 10, false);
    await deleteRelic(E, "A", "h1", { blob_key: null, byte_size: 10, promoted: 0 }, 10);
    expect(await ringCached()).toMatchObject({ history_count: 0, evicted_count: 0 });
  });

  it("deleting an evicted row moves evicted_count, not history_count", async () => {
    await put("h1", 10, false);
    await E.DB.prepare(
      "UPDATE relic_meta SET evicted = 1 WHERE account_id = 'A' AND uid = 'h1'",
    ).run();
    await E.DB.prepare(
      "UPDATE account_usage SET history_count = 0, evicted_count = 1 WHERE account_id = 'A'",
    ).run();

    await deleteRelic(
      E, "A", "h1", { blob_key: null, byte_size: 10, promoted: 0, evicted: 1 }, 10,
    );
    expect(await ringCached()).toMatchObject({ history_count: 0, evicted_count: 0 });
  });

  it("an evict moves the count across and bumps the lifetime total", async () => {
    const ring = TIERS.free.ring as number;
    const stmts = [];
    for (let i = 1; i <= ring; i++) {
      stmts.push(
        E.DB.prepare(
          `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted)
           VALUES ('A', ?1, ?2, ?2, 1, 0)`,
        ).bind(`r${i}`, i),
      );
    }
    await E.DB.batch(stmts);
    await E.DB.prepare(
      `INSERT INTO account_usage (account_id, bytes_used, vault_count, history_count)
       VALUES ('A', ?1, 0, ?1)`,
    ).bind(ring).run();

    // One more capture puts the account one over the ring.
    await put("rnew", 1, false, 10_000);
    // +1 for the new row, -1 for the one pushed out.
    expect(await ringCached()).toEqual({
      history_count: ring, evicted_count: 1, ring_evicted: 1,
    });
    // The cache still agrees with a full recount of the table.
    const scan = await computeUsage(E, "A");
    expect(scan.history).toBe(ring);
    expect(scan.evicted).toBe(1);
  }, 30_000);

  it("a restore moves the count back and leaves the lifetime total alone", async () => {
    await put("h1", 10, false);
    await E.DB.prepare(
      "UPDATE relic_meta SET evicted = 1 WHERE account_id = 'A' AND uid = 'h1'",
    ).run();
    await E.DB.prepare(
      `UPDATE account_usage SET history_count = 0, evicted_count = 1, ring_evicted = 1
        WHERE account_id = 'A'`,
    ).run();

    expect(await restoreEvicted(E, "A", 9000)).toBe(1);
    expect(await ringCached()).toEqual({
      history_count: 1, evicted_count: 0, ring_evicted: 1,
    });
  });

  it("never lets the ring counters go negative", async () => {
    await put("h1", 10, false);
    await E.DB.batch([ringDelta(E, "A", -50, -50, 0)]);
    expect(await ringCached()).toMatchObject({ history_count: 0, evicted_count: 0 });
  });
});

describe("account_usage: the caps still bite", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  // The three cases below each drive 25+ sequential writes through the real
  // handler (R2 object + D1 batch apiece). Alone that is ~200ms, but test files
  // run concurrently against one miniflare instance and one D1, so under a full
  // run they contend and can pass 30x that, enough to trip the 5s default and
  // fail on timing rather than on behaviour. Bounded explicitly here rather than
  // globally, because these are the only tests in the suite shaped this way.
  const SLOW = 30_000;

  it("free tier still refuses the 26th kept relic", async () => {
    for (let i = 0; i < 25; i++) {
      const r = await put(`u${i}`, 10, true);
      expect(await r.json()).toEqual({ stale: false });
    }
    expect(await cached()).toEqual({ bytes_used: 250, vault_count: 25 });
    const over = await put("u25", 10, true);
    expect(over.status).toBe(402);
    expect(await cached()).toEqual({ bytes_used: 250, vault_count: 25 }); // unchanged
  }, SLOW);

  // free is 250 MB of storage in 10 MB items, so 25 unpromoted relics sit
  // exactly on the cap (the check is `>`), and the 26th byte is over it.
  const ITEM = 10 * 1024 * 1024;
  const CAP = 250 * 1024 * 1024;
  const fillToCap = async () => {
    for (let i = 0; i < CAP / ITEM; i++) {
      expect((await put(`f${i}`, ITEM, false)).status).toBe(200);
    }
    expect(await cached()).toEqual({ bytes_used: CAP, vault_count: 0 });
  };

  it("still refuses a write past the storage cap", async () => {
    await fillToCap();
    const over = await put("more", 1, false);
    expect(over.status).toBe(402);
    expect(await over.json()).toMatchObject({ error: "storage_quota" });
    expect(await cached()).toEqual({ bytes_used: CAP, vault_count: 0 }); // unchanged
  }, SLOW);

  it("lets an in-place edit through when it does not grow the account", async () => {
    await fillToCap();
    // Sitting exactly on the cap, a same-size rewrite must still be allowed:
    // the check credits back the row's own bytes before comparing.
    const same = await put("f0", ITEM, false, 2000);
    expect(await same.json()).toEqual({ stale: false });
    expect(await cached()).toEqual({ bytes_used: CAP, vault_count: 0 });
    // ...and the rewrite left us still exactly on the cap, so one more byte
    // in a new relic is still refused.
    expect((await put("extra", 1, false)).status).toBe(402);
  }, SLOW);
});
