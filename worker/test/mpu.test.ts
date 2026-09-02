import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { BLOB_ID, blobR2Key, mpuAbort, mpuComplete, mpuCreate, mpuPart, PART_SIZE } from "../src/blob";
import { TIERS } from "../src/tiers";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const FREE = { account: "A", tier: "free" } as const;
const PRO = { account: "A", tier: "pro" } as const;

const BLOB = "blob-0000-test";
// A second blob key, so two uploads can be genuinely in flight at once.
const BLOB2 = "blob-0000-two1";
const u = (q: string) => new URL(`http://x/blob/mpu/${BLOB}?${q}`);

function createReq(declared: number, id = BLOB): Request {
  return new Request("http://x/blob/mpu?id=" + id, {
    method: "POST",
    body: JSON.stringify({ declared_size: declared }),
  });
}

function partReq(bytes: Uint8Array): Request {
  return new Request("http://x/part", { method: "PUT", body: bytes });
}

async function create(auth = PRO, declared = 100): Promise<string> {
  const res = await mpuCreate(createReq(declared), E, auth, BLOB);
  expect(res.status).toBe(200);
  const j = await res.json();
  expect(j.part_size).toBe(PART_SIZE);
  return j.upload_id;
}

async function seedUsage(bytes: number) {
  await E.DB.prepare(
    "INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted) VALUES ('A','big',1,1,?1,0)",
  ).bind(bytes).run();
}

// In-flight reservations for account A (migrations/0010).
async function mpuRows(): Promise<Array<{ upload_id: string; declared_size: number }>> {
  const r = await E.DB.prepare(
    "SELECT upload_id, declared_size FROM mpu_state WHERE account_id = 'A' ORDER BY upload_id",
  ).all();
  return r.results;
}

beforeEach(async () => {
  await setupSchema(E.DB);
  await E.STORE.delete(blobR2Key("A", BLOB));
  await E.STORE.delete(blobR2Key("A", BLOB2));
});

describe("blob id charset", () => {
  it("accepts uuid keys, legacy dotted keys, and rejects garbage", () => {
    expect(BLOB_ID.test("56e55e48-e4c7-4e04-a47e-fea34efbb721")).toBe(true);
    // Pre-1.0 clients minted "<uuid>.png" keys; old vaults still push them.
    expect(BLOB_ID.test("56e55e48-e4c7-4e04-a47e-fea34efbb721.png")).toBe(true);
    expect(BLOB_ID.test(".hidden-leading-dot")).toBe(false);
    expect(BLOB_ID.test("short")).toBe(false);
    expect(BLOB_ID.test("has space in it")).toBe(false);
    expect(BLOB_ID.test("path/../traversal")).toBe(false);
    expect(BLOB_ID.test("x".repeat(65))).toBe(false);
  });
});

describe("mpu create", () => {
  it("rejects a declared size over the tier item cap (the pre-transfer 413)", async () => {
    const res = await mpuCreate(createReq(TIERS.free.item + 1), E, FREE, BLOB);
    expect(res.status).toBe(413);
    expect((await res.json()).error).toBe("too_large");
  });

  it("rejects when declared size would blow the storage quota", async () => {
    await seedUsage(TIERS.free.storage - 10);
    const res = await mpuCreate(createReq(100), E, FREE, BLOB);
    expect(res.status).toBe(402);
    expect((await res.json()).error).toBe("storage_quota");
  });

  it("rejects garbage declared_size", async () => {
    for (const bad of [0, -5, 1.5, "x", undefined]) {
      const req = new Request("http://x/blob/mpu?id=" + BLOB, {
        method: "POST",
        body: JSON.stringify({ declared_size: bad }),
      });
      expect((await mpuCreate(req, E, PRO, BLOB)).status).toBe(400);
    }
  });
});

describe("mpu_state reservations", () => {
  it("create books a row and complete releases it", async () => {
    const uploadId = await create(PRO, 100);
    expect(await mpuRows()).toEqual([{ upload_id: uploadId, declared_size: 100 }]);

    const up = await mpuPart(
      partReq(new TextEncoder().encode("bytes")), E, PRO, BLOB, u(`upload_id=${uploadId}&part=1`),
    );
    const { part, etag } = await up.json();
    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, PRO, BLOB,
    );
    expect(done.status).toBe(200);
    expect(await mpuRows()).toEqual([]);
  });

  it("abort releases it, idempotently", async () => {
    const uploadId = await create(PRO, 100);
    expect(await mpuRows()).toHaveLength(1);
    expect((await mpuAbort(E, PRO, BLOB, uploadId)).status).toBe(200);
    expect(await mpuRows()).toEqual([]);
    expect((await mpuAbort(E, PRO, BLOB, uploadId)).status).toBe(200);
    expect(await mpuRows()).toEqual([]);
  });

  it("a rejected complete releases it too, so quota is not held hostage", async () => {
    const uploadId = await create(FREE, 100); // declares tiny...
    const big = new Uint8Array(TIERS.free.item + 1); // ...uploads over the cap
    const up = await mpuPart(partReq(big), E, FREE, BLOB, u(`upload_id=${uploadId}&part=1`));
    const { part, etag } = await up.json();
    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, FREE, BLOB,
    );
    expect(done.status).toBe(413);
    expect(await mpuRows()).toEqual([]);
  });

  it("parallel creates cannot each spend the whole quota", async () => {
    // Room for exactly one more upload of this size...
    await seedUsage(TIERS.free.storage - 1000);
    expect((await mpuCreate(createReq(900), E, FREE, BLOB)).status).toBe(200);
    // ...so the second must see the first one's reservation and be refused.
    // Before mpu_state both saw the same headroom and both passed, which made
    // the effective cap the cap times the concurrency.
    const second = await mpuCreate(createReq(900, BLOB2), E, FREE, BLOB2);
    expect(second.status).toBe(402);
    expect((await second.json()).error).toBe("storage_quota");
    expect(await mpuRows()).toHaveLength(1);
  });

  it("releasing a reservation frees the headroom again", async () => {
    await seedUsage(TIERS.free.storage - 1000);
    const first = await mpuCreate(createReq(900), E, FREE, BLOB);
    const { upload_id } = await first.json();
    expect((await mpuCreate(createReq(900, BLOB2), E, FREE, BLOB2)).status).toBe(402);
    await mpuAbort(E, FREE, BLOB, upload_id);
    expect((await mpuCreate(createReq(900, BLOB2), E, FREE, BLOB2)).status).toBe(200);
  });

  it("books one row per upload, so a retry of the same blob key is tracked separately", async () => {
    // A client that gives up on a stalled attempt and starts again has two
    // uploads in flight under one blob key; both must be reclaimable.
    const a = await create(PRO, 100);
    const b = await create(PRO, 100);
    expect(a).not.toBe(b);
    expect(await mpuRows()).toHaveLength(2);
    await mpuAbort(E, PRO, BLOB, a);
    expect((await mpuRows()).map((r) => r.upload_id)).toEqual([b]);
  });

  it("a create R2 refuses leaves no reservation behind", async () => {
    const failing = {
      ...E,
      STORE: {
        ...E.STORE,
        createMultipartUpload: () => Promise.reject(new Error("r2 down")),
      },
    };
    await expect(mpuCreate(createReq(100), failing, PRO, BLOB)).rejects.toThrow();
    expect(await mpuRows()).toEqual([]);
  });
});

describe("mpu happy path", () => {
  it("uploads, completes, and the object round-trips", async () => {
    const uploadId = await create();
    const bytes = new TextEncoder().encode("sealed-ciphertext-bytes");
    const up = await mpuPart(partReq(bytes), E, PRO, BLOB, u(`upload_id=${uploadId}&part=1`));
    expect(up.status).toBe(200);
    const { part, etag } = await up.json();

    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, PRO, BLOB,
    );
    expect(done.status).toBe(200);
    expect((await done.json()).key).toBe(BLOB);

    const obj = await E.STORE.get(blobR2Key("A", BLOB));
    expect(await obj.text()).toBe("sealed-ciphertext-bytes");
  });
});

describe("mpu enforcement", () => {
  it("caps the part number at the tier's max part count", async () => {
    const uploadId = await create(FREE); // free: 10 MB item cap -> 1 part max
    const res = await mpuPart(
      partReq(new Uint8Array(8)), E, FREE, BLOB, u(`upload_id=${uploadId}&part=2`),
    );
    expect(res.status).toBe(400);
  });

  it("deletes the object when the TRUE size exceeds the cap (lying client)", async () => {
    const uploadId = await create(FREE, 100); // declares tiny…
    const big = new Uint8Array(TIERS.free.item + 1); // …uploads 10 MB + 1
    const up = await mpuPart(partReq(big), E, FREE, BLOB, u(`upload_id=${uploadId}&part=1`));
    expect(up.status).toBe(200);
    const { part, etag } = await up.json();

    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, FREE, BLOB,
    );
    expect(done.status).toBe(413);
    expect(await E.STORE.get(blobR2Key("A", BLOB))).toBeNull();
  });

  it("deletes the object when the TRUE size blows the storage quota", async () => {
    const uploadId = await create(FREE, 100);
    await seedUsage(TIERS.free.storage - 10); // quota filled AFTER create passed
    const up = await mpuPart(
      partReq(new Uint8Array(100)), E, FREE, BLOB, u(`upload_id=${uploadId}&part=1`),
    );
    const { part, etag } = await up.json();
    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, FREE, BLOB,
    );
    expect(done.status).toBe(402);
    expect(await E.STORE.get(blobR2Key("A", BLOB))).toBeNull();
  });

  it("abort kills the upload; complete then fails and stores nothing", async () => {
    const uploadId = await create();
    const up = await mpuPart(
      partReq(new Uint8Array(16)), E, PRO, BLOB, u(`upload_id=${uploadId}&part=1`),
    );
    const { part, etag } = await up.json();

    expect((await mpuAbort(E, PRO, BLOB, uploadId)).status).toBe(200);
    // abort is idempotent
    expect((await mpuAbort(E, PRO, BLOB, uploadId)).status).toBe(200);

    const done = await mpuComplete(
      new Request("http://x/c", {
        method: "POST",
        body: JSON.stringify({ upload_id: uploadId, parts: [{ part, etag }] }),
      }),
      E, PRO, BLOB,
    );
    expect(done.status).toBe(404);
    expect(await E.STORE.get(blobR2Key("A", BLOB))).toBeNull();
  });

  it("rejects a part for an unknown upload id", async () => {
    const res = await mpuPart(
      partReq(new Uint8Array(8)), E, PRO, BLOB, u("upload_id=bogus&part=1"),
    );
    expect(res.status).toBe(404);
  });
});
