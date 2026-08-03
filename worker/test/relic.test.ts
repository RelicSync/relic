import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { deleteRelic, listRelics, putRelic } from "../src/index";
import { blobR2Key } from "../src/blob";
import { TIERS } from "../src/tiers";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const FREE = { account: "A", tier: "free" } as const;
const PRO = { account: "A", tier: "pro" } as const;

// Mirrors the private relicKey() in src/index.ts. Kept inline so the test can
// seed/inspect envelope objects in R2 directly (see the R2/D1 consistency case).
const relicR2Key = (acct: string, uid: string) => `users/${acct}/relics/${uid}`;

type EnvOpts = {
  created_at?: number;
  updated_at?: number;
  byte_size?: number;
  promoted?: boolean;
  blob_key?: string;
  ct?: string;
};

function envelope(uid: string, o: EnvOpts = {}) {
  const e: Record<string, unknown> = {
    v: 1,
    uid,
    created_at: o.created_at ?? 1000,
    updated_at: o.updated_at ?? 1000,
    byte_size: o.byte_size ?? 10,
    promoted: o.promoted ?? false,
    n: "nonce",
    ct: o.ct ?? "cipher",
  };
  if (o.blob_key) e.blob_key = o.blob_key;
  return e;
}

// Push a relic through the real handler (writes both D1 relic_meta and the R2
// envelope, exactly like production).
function put(auth: { account: string; tier: string }, uid: string, o: EnvOpts = {}) {
  const req = new Request(`http://x/relic/${uid}`, {
    method: "PUT",
    body: JSON.stringify(envelope(uid, o)),
  });
  return putRelic(req, E, auth as never, uid);
}

// Seed a relic_meta row directly (no R2 envelope) — for cap/LWW/ring cases that
// only exercise the D1 bookkeeping and don't read the envelope back.
function seedMeta(
  uid: string,
  o: { created_at?: number; updated_at?: number; byte_size?: number; promoted?: boolean; blob_key?: string } = {},
) {
  return E.DB.prepare(
    `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted, blob_key)
     VALUES ('A', ?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      uid,
      o.created_at ?? 1,
      o.updated_at ?? 1,
      o.byte_size ?? 10,
      o.promoted ? 1 : 0,
      o.blob_key ?? null,
    )
    .run();
}

async function metaCount(where = ""): Promise<number> {
  const r = await E.DB.prepare(
    `SELECT COUNT(*) AS n FROM relic_meta WHERE account_id = 'A' ${where}`,
  ).first();
  return r.n as number;
}

async function hasMeta(uid: string): Promise<boolean> {
  const r = await E.DB.prepare(
    "SELECT 1 FROM relic_meta WHERE account_id = 'A' AND uid = ?1",
  )
    .bind(uid)
    .first();
  return !!r;
}

async function tombstoneOf(uid: string): Promise<number | null> {
  const r = await E.DB.prepare(
    "SELECT deleted_at FROM tombstones WHERE account_id = 'A' AND uid = ?1",
  )
    .bind(uid)
    .first<{ deleted_at: number }>();
  return r ? r.deleted_at : null;
}

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("putRelic — item cap", () => {
  it("rejects an envelope whose byte_size exceeds the tier item cap", async () => {
    const res = await put(FREE, "x", { byte_size: TIERS.free.item + 1 });
    expect(res.status).toBe(413);
    expect((await res.json()).error).toBe("too_large");
    expect(await hasMeta("x")).toBe(false);
  });

  it("accepts an envelope exactly at the item cap", async () => {
    const res = await put(FREE, "x", { byte_size: TIERS.free.item });
    expect(res.status).toBe(200);
    expect((await res.json()).stale).toBe(false);
  });

  it("rejects a raw body larger than caps.item * 1.5 before parsing", async () => {
    // Padded ciphertext blows the coarse pre-parse guard (line ~112) even though
    // byte_size itself is tiny.
    const big = "c".repeat(Math.floor(TIERS.free.item * 1.5) + 100);
    const res = await put(FREE, "x", { byte_size: 10, ct: big });
    expect(res.status).toBe(413);
    expect((await res.json()).error).toBe("too_large");
  });
});

describe("putRelic — vault cap", () => {
  it("rejects promoting past the free vault cap (25)", async () => {
    for (let i = 0; i < TIERS.free.vault; i++) await seedMeta(`v${i}`, { promoted: true });
    const res = await put(FREE, "new", { promoted: true, updated_at: 2000 });
    expect(res.status).toBe(402);
    expect((await res.json()).error).toBe("vault_cap");
    expect(await hasMeta("new")).toBe(false);
  });

  it("allows promoting when one slot below the cap", async () => {
    for (let i = 0; i < TIERS.free.vault - 1; i++) await seedMeta(`v${i}`, { promoted: true });
    const res = await put(FREE, "new", { promoted: true, updated_at: 2000 });
    expect(res.status).toBe(200);
  });

  it("does not double-count when re-pushing an already-promoted relic at the cap", async () => {
    for (let i = 0; i < TIERS.free.vault; i++) await seedMeta(`v${i}`, { promoted: true, updated_at: 1 });
    // Re-push v0 (already promoted) with a newer timestamp — the cap check skips
    // relics that were already promoted, so this must NOT 402.
    const res = await put(FREE, "v0", { promoted: true, updated_at: 999 });
    expect(res.status).toBe(200);
    expect((await res.json()).stale).toBe(false);
  });

  it("never blocks promotion on pro (unlimited vault)", async () => {
    for (let i = 0; i < 40; i++) await seedMeta(`v${i}`, { promoted: true });
    const res = await put(PRO, "new", { promoted: true, updated_at: 2000 });
    expect(res.status).toBe(200);
  });
});

describe("putRelic — storage cap", () => {
  it("rejects a new relic that tips total storage over the cap", async () => {
    await seedMeta("filler", { byte_size: TIERS.free.storage - 10 });
    const res = await put(FREE, "x", { byte_size: 100 });
    expect(res.status).toBe(402);
    expect((await res.json()).error).toBe("storage_quota");
  });

  it("credits the old byte_size when overwriting (net delta, not gross)", async () => {
    // Fill storage to cap-10 with a filler, plus an existing X of 40 bytes.
    await seedMeta("filler", { byte_size: TIERS.free.storage - 50 });
    await seedMeta("x", { byte_size: 40, updated_at: 1 });
    // A brand-new 45-byte relic would tip over (used cap-10 + 45 > cap)...
    const fresh = await put(FREE, "y", { byte_size: 45 });
    expect(fresh.status).toBe(402);
    // ...but overwriting X (credit its 40) with 45 nets to cap-5 and succeeds.
    const over = await put(FREE, "x", { byte_size: 45, updated_at: 2 });
    expect(over.status).toBe(200);
  });
});

describe("putRelic — last-write-wins", () => {
  it("rejects a push whose updated_at is older than or equal to stored", async () => {
    await put(PRO, "x", { updated_at: 5, ct: "first" });
    const equal = await put(PRO, "x", { updated_at: 5, ct: "second" });
    expect((await equal.json()).stale).toBe(true);
    const older = await put(PRO, "x", { updated_at: 4, ct: "third" });
    expect((await older.json()).stale).toBe(true);
    // Stored envelope unchanged.
    const obj = await E.STORE.get(relicR2Key("A", "x"));
    expect((await obj.json()).ct).toBe("first");
  });

  it("accepts and overwrites a strictly newer push", async () => {
    await put(PRO, "x", { updated_at: 5, ct: "first" });
    const res = await put(PRO, "x", { updated_at: 6, ct: "second" });
    expect((await res.json()).stale).toBe(false);
    const row = await E.DB.prepare(
      "SELECT updated_at FROM relic_meta WHERE account_id = 'A' AND uid = 'x'",
    ).first<{ updated_at: number }>();
    expect(row.updated_at).toBe(6);
    const obj = await E.STORE.get(relicR2Key("A", "x"));
    expect((await obj.json()).ct).toBe("second");
  });
});

describe("putRelic — tombstone wins", () => {
  it("refuses to resurrect a tombstoned uid", async () => {
    await put(PRO, "x", { updated_at: 5 });
    await deleteRelic(E, "A", "x", null, 10);
    const res = await put(PRO, "x", { updated_at: 999 });
    expect((await res.json()).stale).toBe(true);
    expect(await hasMeta("x")).toBe(false);
  });
});

describe("deleteRelic", () => {
  it("tombstones the uid, drops the meta row, and deletes both R2 objects", async () => {
    await E.STORE.put(blobR2Key("A", "blob1"), "blobbytes");
    await put(PRO, "x", { blob_key: "blob1" });
    expect(await E.STORE.get(relicR2Key("A", "x"))).not.toBeNull();

    await deleteRelic(E, "A", "x", "blob1", 12345);

    expect(await hasMeta("x")).toBe(false);
    expect(await tombstoneOf("x")).toBe(12345);
    expect(await E.STORE.get(relicR2Key("A", "x"))).toBeNull();
    expect(await E.STORE.get(blobR2Key("A", "blob1"))).toBeNull();
  });
});

describe("putRelic — history ring GC (free, never-billed)", () => {
  it("prunes the oldest unpromoted past the ring; keeps promoted and recent", async () => {
    const ring = TIERS.free.ring; // 500
    // Seed ring+1 unpromoted rows, created_at = 1..ring+1 (u1 = oldest).
    const stmts = [];
    for (let i = 1; i <= ring + 1; i++) {
      stmts.push(
        E.DB.prepare(
          `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted)
           VALUES ('A', ?1, ?2, ?2, 1, 0)`,
        ).bind(`u${i}`, i),
      );
    }
    await E.DB.batch(stmts);

    // Pushing one more newest relic makes it ring+2 unpromoted → prune the 2 oldest.
    const res = await put(FREE, "unew", { created_at: 10_000, updated_at: 10_000 });
    expect(res.status).toBe(200);

    expect(await hasMeta("u1")).toBe(false);
    expect(await tombstoneOf("u1")).not.toBeNull();
    expect(await hasMeta("u2")).toBe(false);
    expect(await hasMeta("u3")).toBe(true); // just inside the ring
    expect(await hasMeta("unew")).toBe(true);
  });

  it("DOWNGRADE SAFETY: an ever-billed account is exempt from ring prune", async () => {
    await E.DB.prepare(
      "INSERT INTO subscriptions (account_id, tier, status) VALUES ('A', 'free', 'canceled')",
    ).run();
    const ring = TIERS.free.ring;
    const stmts = [];
    for (let i = 1; i <= ring + 1; i++) {
      stmts.push(
        E.DB.prepare(
          `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted)
           VALUES ('A', ?1, ?2, ?2, 1, 0)`,
        ).bind(`u${i}`, i),
      );
    }
    await E.DB.batch(stmts);

    await put(FREE, "unew", { created_at: 10_000, updated_at: 10_000 });

    // Nothing pruned — the oldest survives and no tombstones were written.
    expect(await hasMeta("u1")).toBe(true);
    expect(await tombstoneOf("u1")).toBeNull();
    const tombs = await E.DB.prepare(
      "SELECT COUNT(*) AS n FROM tombstones WHERE account_id = 'A'",
    ).first();
    expect(tombs.n).toBe(0);
  });

  it("never applies the ring on pro (unlimited history)", async () => {
    const stmts = [];
    for (let i = 1; i <= TIERS.free.ring + 5; i++) {
      stmts.push(
        E.DB.prepare(
          `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted)
           VALUES ('A', ?1, ?2, ?2, 1, 0)`,
        ).bind(`u${i}`, i),
      );
    }
    await E.DB.batch(stmts);
    await put(PRO, "unew", { created_at: 10_000, updated_at: 10_000 });
    expect(await hasMeta("u1")).toBe(true);
    expect(await metaCount()).toBe(TIERS.free.ring + 6);
  });
});

describe("listRelics — cursor pagination", () => {
  // Four relics; b and c share updated_at=20 to exercise the (updated_at, uid) tiebreak.
  async function seedFour() {
    await put(PRO, "a", { updated_at: 10 });
    await put(PRO, "b", { updated_at: 20 });
    await put(PRO, "c", { updated_at: 20 });
    await put(PRO, "d", { updated_at: 30 });
  }
  const list = (q: string) => listRelics(new URL(`http://x/relics?${q}`), E, PRO as never);

  it("paginates with no duplicates or skips across a same-timestamp boundary", async () => {
    await seedFour();
    const p1 = await (await list("limit=2")).json();
    expect(p1.items.map((r: { uid: string }) => r.uid)).toEqual(["a", "b"]);
    expect(p1.next_cursor).toBe("20:b");

    const p2 = await (await list(`limit=2&cursor=${encodeURIComponent(p1.next_cursor)}`)).json();
    expect(p2.items.map((r: { uid: string }) => r.uid)).toEqual(["c", "d"]);
    expect(p2.next_cursor).toBe("30:d");

    const p3 = await (await list(`limit=2&cursor=${encodeURIComponent(p2.next_cursor)}`)).json();
    expect(p3.items).toEqual([]);
    expect(p3.next_cursor).toBeNull();
  });

  it("filters by `since` (strictly greater than)", async () => {
    await seedFour();
    const r = await (await list("since=20")).json();
    expect(r.items.map((x: { uid: string }) => x.uid)).toEqual(["d"]);
  });

  it("returns null next_cursor when the page isn't full", async () => {
    await seedFour();
    const r = await (await list("limit=1000")).json();
    expect(r.items).toHaveLength(4);
    expect(r.next_cursor).toBeNull();
  });

  it("omits rows whose R2 envelope is missing (documents current behavior)", async () => {
    await put(PRO, "x", { updated_at: 5 });
    // Drop just the envelope, leaving the relic_meta row behind.
    await E.STORE.delete(relicR2Key("A", "x"));
    const r = await (await list("")).json();
    expect(r.items).toEqual([]);
    expect(await hasMeta("x")).toBe(true); // meta row still present
  });
});
