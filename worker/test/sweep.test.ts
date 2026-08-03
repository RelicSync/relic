import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { ORPHAN_MIN_AGE_S, sweepOrphanBlobs, sweepTombstones, TOMBSTONE_TTL_DAYS } from "../src/sweep";
import { blobR2Key } from "../src/blob";
import worker from "../src/index";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const NOW = Math.floor(Date.now() / 1000);
// Test objects are uploaded "now"; judging them from a vantage point past the
// age guard makes them eligible without faking R2 timestamps.
const LATER = NOW + ORPHAN_MIN_AGE_S + 60;

async function seedRelic(uid: string, blobKey: string | null) {
  await E.DB.prepare(
    `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted, blob_key)
     VALUES ('A', ?1, 1, 1, 10, 0, ?2)`,
  ).bind(uid, blobKey).run();
}

// No per-test storage isolation (pool 0.18): wipe users/ so residue from
// other tests (mpu blobs, earlier sweep fixtures) can't skew orphan counts.
beforeEach(async () => {
  await setupSchema(E.DB);
  let cursor: string | undefined;
  do {
    const listed = await E.STORE.list({ prefix: "users/", cursor, limit: 1000 });
    for (const o of listed.objects) await E.STORE.delete(o.key);
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
});

describe("orphan-blob sweep", () => {
  it("deletes an aged unreferenced blob, keeps a referenced one", async () => {
    await E.STORE.put(blobR2Key("A", "blob-orphaned1"), "body-orphan-1");
    await E.STORE.put(blobR2Key("A", "blob-referenced"), "body-referenced");
    await seedRelic("u1", "blob-referenced");

    const res = await sweepOrphanBlobs(E, LATER);
    expect(res.deleted).toBe(1);
    expect(res.done).toBe(true);
    expect(await E.STORE.get(blobR2Key("A", "blob-orphaned1"))).toBeNull();
    expect(await E.STORE.get(blobR2Key("A", "blob-referenced"))).not.toBeNull();
  });

  it("leaves a fresh unreferenced blob alone (the 24h upload-gap guard)", async () => {
    await E.STORE.put(blobR2Key("A", "blob-justnow99"), "body-justnow");
    const res = await sweepOrphanBlobs(E, NOW); // judged from now: too young
    expect(res.deleted).toBe(0);
    expect(await E.STORE.get(blobR2Key("A", "blob-justnow99"))).not.toBeNull();
  });

  it("never touches envelopes or keyparams", async () => {
    await E.STORE.put("users/A/relics/some-uid", "{}");
    await E.STORE.put("users/A/keyparams.json", "{}");
    const res = await sweepOrphanBlobs(E, LATER);
    expect(res.deleted).toBe(0);
    expect(await E.STORE.get("users/A/relics/some-uid")).not.toBeNull();
    expect(await E.STORE.get("users/A/keyparams.json")).not.toBeNull();
  });

  it("scopes references per account: same blob id elsewhere is still an orphan", async () => {
    await E.STORE.put(blobR2Key("A", "blob-sharedid1"), "body-shared-a");
    await E.STORE.put(blobR2Key("B", "blob-sharedid1"), "body-shared-b");
    await seedRelic("u1", "blob-sharedid1"); // account A references it; B does not
    const res = await sweepOrphanBlobs(E, LATER);
    expect(res.deleted).toBe(1);
    expect(await E.STORE.get(blobR2Key("A", "blob-sharedid1"))).not.toBeNull();
    expect(await E.STORE.get(blobR2Key("B", "blob-sharedid1"))).toBeNull();
  });
});

describe("tombstone GC", () => {
  it("drops rows past the retention window, keeps recent ones", async () => {
    const old = NOW - (TOMBSTONE_TTL_DAYS + 1) * 86400;
    const recent = NOW - 86400;
    await E.DB.prepare(
      "INSERT INTO tombstones (account_id, uid, deleted_at) VALUES ('A','old',?1),('A','new',?2)",
    ).bind(old, recent).run();

    expect(await sweepTombstones(E, NOW)).toBe(1);
    const left = await E.DB.prepare("SELECT uid FROM tombstones").all();
    expect(left.results.map((r: { uid: string }) => r.uid)).toEqual(["new"]);
  });
});

describe("GET /health", () => {
  it("answers ok without auth", async () => {
    const res = await worker.fetch(new Request("http://x/health"), E);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });
});
