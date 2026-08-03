import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker from "../src/index";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

async function seedToken(token: string, account: string, tier = "free") {
  const hash = await sha256Hex(token);
  await E.DB.prepare(
    "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)",
  ).bind(hash, account, tier).run();
}

const ID_A = "AAAAAAAAAAAAAAAAAAAAAA"; // 22 chars, valid share id
const ID_B = "BBBBBBBBBBBBBBBBBBBBBB";
const CT = new Uint8Array(64).fill(7); // >= 29-byte wire minimum

function create(
  token: string,
  id: string,
  opts: { ttl?: number; views?: number; body?: Uint8Array } = {},
) {
  const qs = new URLSearchParams({ id, ttl: String(opts.ttl ?? 86400) });
  if (opts.views !== undefined) qs.set("views", String(opts.views));
  return worker.fetch(
    new Request(`https://x/share?${qs}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
      body: opts.body ?? CT,
    }),
    E,
  );
}

const getPage = (id: string) => worker.fetch(new Request(`https://x/s/${id}`), E);
const getBlob = (id: string) =>
  worker.fetch(new Request(`https://x/share/${id}/blob`), E);
const revoke = (token: string, id: string) =>
  worker.fetch(
    new Request(`https://x/share/${id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    }),
    E,
  );

beforeEach(async () => {
  await setupSchema(E.DB);
  await seedToken("tokA", "acctA");
  await seedToken("tokB", "acctB");
});

describe("share links", () => {
  it("create → page → blob roundtrip; multi-view shares survive re-fetch", async () => {
    const res = await create("tokA", ID_A);
    expect(res.status).toBe(200);
    const j = await res.json<{ id: string; url: string; expires_at: number }>();
    expect(j.id).toBe(ID_A);
    expect(j.url).toBe(`https://x/s/${ID_A}`);

    const page = await getPage(ID_A);
    expect(page.status).toBe(200);
    expect(page.headers.get("Content-Type")).toContain("text/html");
    expect(await page.text()).toContain(ID_A);

    for (let i = 0; i < 3; i++) {
      const blob = await getBlob(ID_A);
      expect(blob.status).toBe(200);
      expect(new Uint8Array(await blob.arrayBuffer())).toEqual(CT);
    }
  });

  it("creating requires auth; viewing does not", async () => {
    const anon = await worker.fetch(
      new Request(`https://x/share?id=${ID_A}&ttl=3600`, { method: "POST", body: CT }),
      E,
    );
    expect(anon.status).toBe(401);
  });

  it("one-time: first blob fetch wins, second is 410, page shows gone", async () => {
    await create("tokA", ID_A, { views: 1 });
    // The page itself never burns the view (preview-bot safety).
    expect((await getPage(ID_A)).status).toBe(200);
    expect((await getPage(ID_A)).status).toBe(200);

    expect((await getBlob(ID_A)).status).toBe(200);
    expect((await getBlob(ID_A)).status).toBe(410); // consumed, row kept
    expect((await getPage(ID_A)).status).toBe(404); // gone page

    // R2 object dropped after the last permitted view.
    expect(await E.STORE.get(`shares/${ID_A}`)).toBeNull();
  });

  it("expiry is enforced at read time", async () => {
    await create("tokA", ID_A);
    await E.DB.prepare("UPDATE shares SET expires_at = ?1 WHERE id = ?2")
      .bind(Math.floor(Date.now() / 1000) - 10, ID_A).run();
    expect((await getBlob(ID_A)).status).toBe(410);
    expect((await getPage(ID_A)).status).toBe(404);
  });

  it("validation: bad id, bad ttl, undersized body, oversized body", async () => {
    expect((await create("tokA", "short", {})).status).toBe(400);
    expect((await create("tokA", ID_A, { ttl: 999 })).status).toBe(400);
    expect((await create("tokA", ID_A, { body: new Uint8Array(10) })).status).toBe(400);
    const big = new Uint8Array(5 * 1024 * 1024 + 1);
    expect((await create("tokA", ID_A, { body: big })).status).toBe(413); // free = 5MB
  });

  it("id collision → 409; foreign id looks like any other 404", async () => {
    expect((await create("tokA", ID_A)).status).toBe(200);
    expect((await create("tokB", ID_A)).status).toBe(409);
    expect((await getBlob(ID_B)).status).toBe(404);
  });

  it("active-share cap → 402 (consumed shares free a slot)", async () => {
    for (let i = 0; i < 10; i++) {
      const id = `${String.fromCharCode(67 + i)}`.repeat(22); // C..L ×22
      expect((await create("tokA", id)).status).toBe(200);
    }
    expect((await create("tokA", ID_A)).status).toBe(402);
    // Burn one (one-time consumed frees a slot only for views:1 shares — here
    // expire one instead).
    await E.DB.prepare("UPDATE shares SET expires_at = 1 WHERE id = ?1")
      .bind("C".repeat(22)).run();
    expect((await create("tokA", ID_A)).status).toBe(200);
  });

  it("owner revoke kills the share; non-owner revoke is a no-op", async () => {
    await create("tokA", ID_A);
    expect((await revoke("tokB", ID_A)).status).toBe(200); // idempotent no-op
    const alive = await getBlob(ID_A);
    expect(alive.status).toBe(200); // still alive
    await alive.arrayBuffer(); // consume the R2 stream (isolated-storage hygiene)
    expect((await revoke("tokA", ID_A)).status).toBe(200);
    expect((await getBlob(ID_A)).status).toBe(404);
    expect(await E.STORE.get(`shares/${ID_A}`)).toBeNull();
  });

  it("sweep GCs expired and consumed shares (R2 + D1)", async () => {
    await create("tokA", ID_A);
    await create("tokA", ID_B, { views: 1 });
    await E.DB.prepare("UPDATE shares SET expires_at = 1 WHERE id = ?1").bind(ID_A).run();
    await getBlob(ID_B); // consume
    await worker.scheduled({} as ScheduledController, E);
    const left = await E.DB.prepare("SELECT COUNT(*) AS n FROM shares").first();
    expect(left.n).toBe(0);
    expect(await E.STORE.get(`shares/${ID_A}`)).toBeNull();
    expect(await E.STORE.get(`shares/${ID_B}`)).toBeNull();
  });

  it("account delete cascades shares", async () => {
    await create("tokA", ID_A);
    const del = await worker.fetch(
      new Request("https://x/account", {
        method: "DELETE",
        headers: { Authorization: "Bearer tokA" },
      }),
      E,
    );
    expect(del.status).toBe(200);
    expect((await getBlob(ID_A)).status).toBe(404);
    expect(await E.STORE.get(`shares/${ID_A}`)).toBeNull();
  });
});
