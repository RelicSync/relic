import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  MPU_MIN_AGE_S,
  ORPHAN_MIN_AGE_S,
  sweepAbandonedMpus,
  sweepOrphanBlobs,
  sweepTombstones,
  TOMBSTONE_TTL_DAYS,
} from "../src/sweep";
import { blobR2Key } from "../src/blob";
import worker from "../src/index";
import { ringNudgeSweep, vaultCapSweep } from "../src/stripe";
import { TIERS } from "../src/tiers";
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

describe("abandoned-MPU sweep", () => {
  // R2's list() never returns in-flight multipart parts, so mpu_state is the
  // only handle this sweep has. Rows are seeded directly: what is under test is
  // the age window and the row lifecycle, not R2's own abort.
  async function seedMpu(blobId: string, uploadId: string, createdAt: number) {
    await E.DB.prepare(
      `INSERT INTO mpu_state (account_id, blob_id, upload_id, declared_size, created_at)
       VALUES ('A', ?1, ?2, 1000, ?3)`,
    ).bind(blobId, uploadId, createdAt).run();
  }

  const rowCount = async (): Promise<number> => {
    const r = await E.DB.prepare("SELECT COUNT(*) AS n FROM mpu_state").first();
    return r.n as number;
  };

  it("clears rows past the age window and keeps fresh ones", async () => {
    await seedMpu("blob-old-0001", "up-old", NOW - MPU_MIN_AGE_S - 60);
    await seedMpu("blob-new-0001", "up-new", NOW - 60);

    expect(await sweepAbandonedMpus(E, NOW)).toBe(1);
    const left = await E.DB.prepare("SELECT upload_id FROM mpu_state").all();
    expect(left.results.map((r: { upload_id: string }) => r.upload_id)).toEqual(["up-new"]);
  });

  it("drops a row even when R2 refuses the abort", async () => {
    // The upload id is fiction, so the abort throws. The row still has to go,
    // or the sweep would retry it every six hours forever.
    await seedMpu("blob-bogus-001", "not-a-real-upload", NOW - MPU_MIN_AGE_S - 60);
    expect(await sweepAbandonedMpus(E, NOW)).toBe(1);
    expect(await rowCount()).toBe(0);
  });

  it("is bounded to 100 rows per run", async () => {
    const stmts = [];
    for (let i = 0; i < 105; i++) {
      stmts.push(
        E.DB.prepare(
          `INSERT INTO mpu_state (account_id, blob_id, upload_id, declared_size, created_at)
           VALUES ('A', ?1, ?2, 10, ?3)`,
        ).bind(`blob-bulk-${i}`, `up-${i}`, NOW - MPU_MIN_AGE_S - 60),
      );
    }
    await E.DB.batch(stmts);
    expect(await sweepAbandonedMpus(E, NOW)).toBe(100);
    expect(await rowCount()).toBe(5);
  });

  it("the janitor cron runs it", async () => {
    await seedMpu("blob-cron-001", "up-cron", NOW - MPU_MIN_AGE_S - 60);
    await worker.scheduled({} as ScheduledController, E);
    expect(await rowCount()).toBe(0);
  });
});

describe("GET /health", () => {
  it("answers ok without auth", async () => {
    const res = await worker.fetch(new Request("http://x/health"), E);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });
});

// --- free-limit nudge emails --------------------------------------------------
// One email per account per wall, ever. The stamp is what guarantees that, and
// it only goes on once retrying is pointless: the mail went out, or Resend
// refused the address itself. A server-side failure leaves the row NULL so the
// next tick tries again, which is what lets a fixed key heal the backlog.
describe("ring nudge sweep", () => {
  // deno-lint-ignore no-explicit-any
  let fetchMock: any;
  const realFetch = globalThis.fetch;

  beforeEach(async () => {
    await setupSchema(E.DB);
    fetchMock = vi.fn(async () => new Response("{}", { status: 200 }));
    globalThis.fetch = fetchMock;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  const withKey = () => ({ ...E, RESEND_API_KEY: "re_test" });

  async function seedAccount(
    account: string,
    email: string | null,
    o: {
      ringEvicted?: number;
      emailedAt?: number | null;
      subscribed?: boolean;
      vaultCount?: number;
      vaultEmailedAt?: number | null;
    } = {},
  ) {
    await E.DB.prepare("INSERT INTO accounts (account_id, email) VALUES (?1, ?2)")
      .bind(account, email).run();
    await E.DB.prepare(
      `INSERT INTO account_usage
         (account_id, bytes_used, vault_count, ring_evicted, ring_email_at, vault_email_at)
       VALUES (?1, 0, ?2, ?3, ?4, ?5)`,
    ).bind(
      account,
      o.vaultCount ?? 0,
      o.ringEvicted ?? 0,
      o.emailedAt ?? null,
      o.vaultEmailedAt ?? null,
    ).run();
    if (o.subscribed) {
      await E.DB.prepare(
        "INSERT INTO subscriptions (account_id, tier, status) VALUES (?1,'pro','active')",
      ).bind(account).run();
    }
  }

  const stampOf = async (account: string): Promise<number | null> => {
    const r = await E.DB.prepare(
      "SELECT ring_email_at FROM account_usage WHERE account_id = ?1",
    ).bind(account).first();
    return r?.ring_email_at ?? null;
  };

  it("mails the one eligible account and skips the other three", async () => {
    await seedAccount("ringA", "over@x.com", { ringEvicted: 12 });          // eligible
    await seedAccount("ringB", "done@x.com", { ringEvicted: 12, emailedAt: 99 }); // already
    await seedAccount("ringC", "payer@x.com", { ringEvicted: 12, subscribed: true });
    await seedAccount("ringD", null, { ringEvicted: 12 });                  // no address
    await seedAccount("ringE", "under@x.com", { ringEvicted: 0 });          // nothing lost

    await ringNudgeSweep(withKey());

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.resend.com/emails");
    const sent = JSON.parse(init.body);
    expect(sent.to).toBe("over@x.com");
    expect(sent.subject).toBe("Your oldest copies are dropping off");
    expect(sent.text).toContain(`your last ${TIERS.free.ring} in view`);
    expect(sent.text).toContain("https://relic.space/upgrade?source=ring_email");
    expect(sent.text).not.toContain("\u2014"); // no em dash

    expect(await stampOf("ringA")).toBeGreaterThan(0);
    expect(await stampOf("ringB")).toBe(99); // untouched
    expect(await stampOf("ringC")).toBeNull();
    expect(await stampOf("ringD")).toBeNull();
  });

  it("never sends twice", async () => {
    await seedAccount("ringF", "once@x.com", { ringEvicted: 3 });
    await ringNudgeSweep(withKey());
    await ringNudgeSweep(withKey());
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("stamps the row when Resend refuses the address itself", async () => {
    fetchMock.mockImplementation(async () => new Response("bad address", { status: 422 }));
    await seedAccount("ringG", "bounce@x.com", { ringEvicted: 3 });
    await ringNudgeSweep(withKey());
    expect(await stampOf("ringG")).toBeGreaterThan(0);
  });

  // The 2026-09-10 silence: a rejected key stamped every row it touched, so the
  // accounts were dropped from the pool for good. A server-side refusal must
  // cost us nothing but the tick.
  it("leaves the row alone when the key is rejected, and retries later", async () => {
    fetchMock.mockImplementation(async () => new Response("unauthorized", { status: 401 }));
    await seedAccount("ringJ", "keybad@x.com", { ringEvicted: 3 });
    await ringNudgeSweep(withKey());
    expect(await stampOf("ringJ")).toBeNull();

    fetchMock.mockImplementation(async () => new Response("{}", { status: 200 }));
    await ringNudgeSweep(withKey());
    expect(await stampOf("ringJ")).toBeGreaterThan(0);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("leaves the row alone when the send throws", async () => {
    fetchMock.mockImplementation(async () => {
      throw new Error("socket hang up");
    });
    await seedAccount("ringK", "flaky@x.com", { ringEvicted: 3 });
    await ringNudgeSweep(withKey());
    expect(await stampOf("ringK")).toBeNull();
  });

  it("touches nothing at all without a Resend key (the self-host case)", async () => {
    await seedAccount("ringH", "over@x.com", { ringEvicted: 3 });
    await ringNudgeSweep(E);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await stampOf("ringH")).toBeNull();
  });

  it("the cron runs it", async () => {
    await seedAccount("ringI", "cron@x.com", { ringEvicted: 3 });
    await worker.scheduled({} as ScheduledController, withKey());
    expect(await stampOf("ringI")).toBeGreaterThan(0);
  });

  // --- the other wall --------------------------------------------------------
  // The vault is the limit people reach first, and until 2026-09 it was the one
  // that said nothing at all.
  describe("vault cap sweep", () => {
    const vaultStampOf = async (account: string): Promise<number | null> => {
      const r = await E.DB.prepare(
        "SELECT vault_email_at FROM account_usage WHERE account_id = ?1",
      ).bind(account).first();
      return r?.vault_email_at ?? null;
    };

    const CAP = TIERS.free.vault as number;

    it("mails the full vault and skips everyone else", async () => {
      await seedAccount("vaultA", "full@x.com", { vaultCount: CAP });
      await seedAccount("vaultB", "over@x.com", { vaultCount: CAP + 5 });
      await seedAccount("vaultC", "told@x.com", { vaultCount: CAP, vaultEmailedAt: 99 });
      await seedAccount("vaultD", "payer@x.com", { vaultCount: CAP, subscribed: true });
      await seedAccount("vaultE", null, { vaultCount: CAP });
      await seedAccount("vaultF", "room@x.com", { vaultCount: CAP - 1 });

      await vaultCapSweep(withKey());

      expect(fetchMock).toHaveBeenCalledTimes(2);
      const sent = JSON.parse(fetchMock.mock.calls[0][1].body);
      expect(sent.subject).toBe("Your Relic vault is full");
      expect(sent.text).toContain(`keeps ${CAP} things`);
      expect(sent.text).toContain("https://relic.space/upgrade?source=vault_email");
      expect(sent.text).not.toContain("\u2014"); // no em dash

      expect(await vaultStampOf("vaultA")).toBeGreaterThan(0);
      expect(await vaultStampOf("vaultB")).toBeGreaterThan(0);
      expect(await vaultStampOf("vaultC")).toBe(99); // untouched
      expect(await vaultStampOf("vaultD")).toBeNull();
      expect(await vaultStampOf("vaultE")).toBeNull();
      expect(await vaultStampOf("vaultF")).toBeNull();
    });

    it("never sends twice", async () => {
      await seedAccount("vaultG", "once@x.com", { vaultCount: CAP });
      await vaultCapSweep(withKey());
      await vaultCapSweep(withKey());
      expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it("leaves the row alone when the key is rejected", async () => {
      fetchMock.mockImplementation(async () => new Response("unauthorized", { status: 401 }));
      await seedAccount("vaultH", "keybad@x.com", { vaultCount: CAP });
      await vaultCapSweep(withKey());
      expect(await vaultStampOf("vaultH")).toBeNull();
    });

    it("touches nothing at all without a Resend key (the self-host case)", async () => {
      await seedAccount("vaultI", "full@x.com", { vaultCount: CAP });
      await vaultCapSweep(E);
      expect(fetchMock).not.toHaveBeenCalled();
      expect(await vaultStampOf("vaultI")).toBeNull();
    });

    // The two walls keep separate memory, so being told about one must never
    // spend the other's single letter.
    it("is independent of the ring stamp", async () => {
      await seedAccount("vaultJ", "both@x.com", { vaultCount: CAP, ringEvicted: 7 });
      await ringNudgeSweep(withKey());
      expect(await stampOf("vaultJ")).toBeGreaterThan(0);
      expect(await vaultStampOf("vaultJ")).toBeNull();

      await vaultCapSweep(withKey());
      expect(await vaultStampOf("vaultJ")).toBeGreaterThan(0);
      expect(fetchMock).toHaveBeenCalledTimes(2);
    });

    it("the cron runs it", async () => {
      await seedAccount("vaultK", "cron@x.com", { vaultCount: CAP });
      await worker.scheduled({} as ScheduledController, withKey());
      expect(await vaultStampOf("vaultK")).toBeGreaterThan(0);
    });
  });
});
