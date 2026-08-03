import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { deleteAccount } from "../src/account";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

// Seed one account's rows across every per-account table + its R2 objects + KV
// keys. Returns nothing; assertions read back per account.
async function seed(acct: string) {
  await E.DB.batch([
    E.DB.prepare("INSERT INTO accounts (account_id, tier) VALUES (?1,'pro')").bind(acct),
    E.DB.prepare(
      "INSERT INTO subscriptions (account_id, stripe_customer_id, stripe_subscription_id) VALUES (?1,'cus','sub')",
    ).bind(acct),
    E.DB.prepare("INSERT INTO tokens (token_hash, account_id) VALUES (?1,?2)").bind(`h_${acct}`, acct),
    E.DB.prepare(
      "INSERT INTO devices (account_id, device_id) VALUES (?1,'dev1')",
    ).bind(acct),
    E.DB.prepare(
      "INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted) VALUES (?1,'u1',1,1,10,0)",
    ).bind(acct),
    E.DB.prepare("INSERT INTO tombstones (account_id, uid, deleted_at) VALUES (?1,'u0',1)").bind(acct),
  ]);
  await E.STORE.put(`users/${acct}/keyparams.json`, "{}");
  await E.STORE.put(`users/${acct}/relics/u1`, "envelope");
  await E.STORE.put(`users/${acct}/blob/b1`, "blob");
  await E.PAIR.put(`pair:${acct}:p1:mk`, "x");
  await E.PAIR.put(`rev:${acct}:dev9`, "1");
}

async function rowCount(table: string, acct: string): Promise<number> {
  const r = await E.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id=?1`)
    .bind(acct).first();
  return r?.n ?? 0;
}

async function r2Count(prefix: string): Promise<number> {
  const listed = await E.STORE.list({ prefix });
  return listed.objects.length;
}

async function kvCount(prefix: string): Promise<number> {
  const listed = await E.PAIR.list({ prefix });
  return listed.keys.length;
}

const PER_ACCOUNT_TABLES = [
  "accounts", "subscriptions", "tokens", "devices", "relic_meta", "tombstones",
];

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("deleteAccount", () => {
  it("wipes all state for the account and reports objects removed", async () => {
    await seed("A");
    const res = await deleteAccount(E, { account: "A", tier: "pro" });
    const body = await res.json();
    expect(body).toMatchObject({ deleted: true });
    expect(body.objects).toBe(3); // keyparams + relic + blob

    for (const t of PER_ACCOUNT_TABLES) expect(await rowCount(t, "A")).toBe(0);
    expect(await r2Count("users/A/")).toBe(0);
    expect(await kvCount("pair:A:")).toBe(0);
    expect(await kvCount("rev:A:")).toBe(0);
  });

  it("leaves other accounts untouched (scoping)", async () => {
    await seed("A");
    await seed("B");
    await deleteAccount(E, { account: "A", tier: "pro" });

    for (const t of PER_ACCOUNT_TABLES) expect(await rowCount(t, "B")).toBe(1);
    expect(await r2Count("users/B/")).toBe(3);
    expect(await kvCount("pair:B:")).toBe(1);
    expect(await kvCount("rev:B:")).toBe(1);
  });

  it("keeps the global billing_events ledger intact", async () => {
    await seed("A");
    await E.DB.prepare(
      "INSERT INTO billing_events (event_id, type, created_at) VALUES ('evt_1','x',1)",
    ).run();
    await deleteAccount(E, { account: "A", tier: "pro" });
    const r = await E.DB.prepare("SELECT COUNT(*) AS n FROM billing_events").first();
    expect(r.n).toBe(1);
  });
});
