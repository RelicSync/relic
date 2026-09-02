import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { deleteRelic, putRelic } from "../src/index";
import { computeUsage, readUsage, usageDelta } from "../src/usage";
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

describe("account_usage: the cache tracks the table", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  it("seeds on first write and matches a full recount", async () => {
    await put("u1", 100, true);
    expect(await cached()).toEqual({ bytes_used: 100, vault_count: 1 });
    expect(await computeUsage(E, "A")).toEqual({ bytes: 100, vault: 1 });
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
    expect(await computeUsage(E, "A")).toEqual({ bytes: 20, vault: 0 });
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
    expect(await readUsage(E, "A")).toEqual({ bytes: 140, vault: 2 });
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
    expect(await readUsage(E, "A")).toEqual({ bytes: 0, vault: 0 }); // recount agrees
  });

  it("never lets a counter go negative", async () => {
    await put("u1", 100, false);
    // an over-large decrement (only reachable if the cache were ever wrong)
    await E.DB.batch([usageDelta(E, "A", -100000, -50, null)]);
    expect(await cached()).toEqual({ bytes_used: 0, vault_count: 0 });
  });

  it("an unseeded account reads as empty", async () => {
    expect(await readUsage(E, "NOBODY")).toEqual({ bytes: 0, vault: 0 });
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
