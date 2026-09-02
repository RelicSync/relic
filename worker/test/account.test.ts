import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { deleteAccount } from "../src/account";
import type { Auth } from "../src/auth";
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
    E.DB.prepare(
      `INSERT INTO mpu_state (account_id, blob_id, upload_id, declared_size, created_at)
       VALUES (?1,'b-inflight','up1',1000,1)`,
    ).bind(acct),
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
  // In-flight multipart parts are invisible to purgeR2Prefix (R2's list() does
  // not return them), so the teardown has to drop these rows explicitly.
  "mpu_state",
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

  it("drops the account_links row that binds a Supabase sub to the account", async () => {
    await seed("A");
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('sub-A','A')",
    ).run();
    await deleteAccount(E, { account: "A", tier: "pro" });
    const r = await E.DB.prepare("SELECT COUNT(*) AS n FROM account_links").first();
    expect(r.n).toBe(0);
  });
});

// The Supabase identity teardown (App Store Guideline 5.1.1(v)): deleting the
// account must delete the auth row + its email, not only Relic's own data.
describe("deleteAccount Supabase identity", () => {
  // deno-lint-ignore no-explicit-any
  let fetchMock: any;
  const realFetch = globalThis.fetch;

  // A service-role key shape, deliberately fake.
  const SVC = "svc_role_test_key"; // scan-ok
  const supabaseEnv = () => ({
    ...E,
    SUPABASE_URL: "https://auth.example.test",
    SUPABASE_SERVICE_ROLE_KEY: SVC,
  });
  const supabaseAuth = (account: string, sub: string): Auth => ({
    account, tier: "pro", supabase: true, supabaseSub: sub,
  });

  beforeEach(() => {
    fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  it("calls the admin delete endpoint with the sub and service-role headers", async () => {
    await seed("A");
    const res = await deleteAccount(supabaseEnv(), supabaseAuth("A", "A"));
    expect(await res.json()).toMatchObject({ deleted: true });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://auth.example.test/auth/v1/admin/users/A");
    expect(init.method).toBe("DELETE");
    expect(init.headers.Authorization).toBe(`Bearer ${SVC}`);
    expect(init.headers.apikey).toBe(SVC);
  });

  it("deletes the JWT sub, not the account id, when account_links redirects it", async () => {
    // Legacy vault "legacyAcct" that a Supabase identity "sub-9" signs in to.
    await seed("legacyAcct");
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('sub-9','legacyAcct')",
    ).run();
    await deleteAccount(supabaseEnv(), supabaseAuth("legacyAcct", "sub-9"));

    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe("https://auth.example.test/auth/v1/admin/users/sub-9");
  });

  it("skips the admin call when SUPABASE_SERVICE_ROLE_KEY is not bound", async () => {
    await seed("A");
    // E has no service-role key: a self-host / not-yet-configured deploy.
    const res = await deleteAccount({ ...E, SUPABASE_URL: "https://auth.example.test" }, supabaseAuth("A", "A"));
    expect(await res.json()).toMatchObject({ deleted: true });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await rowCount("accounts", "A")).toBe(0); // data teardown unaffected
  });

  it("skips the admin call for legacy device-token identities", async () => {
    await seed("A");
    // No supabase flag / sub: nothing to delete in the identity provider.
    await deleteAccount(supabaseEnv(), { account: "A", tier: "pro" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("still succeeds, and logs loudly, when the admin call fails", async () => {
    await seed("A");
    fetchMock.mockImplementation(async () => new Response("boom", { status: 500 }));
    const errs = vi.spyOn(console, "error").mockImplementation(() => {});

    const res = await deleteAccount(supabaseEnv(), supabaseAuth("A", "A"));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ deleted: true });
    // The data is genuinely gone even though the identity call failed.
    for (const t of PER_ACCOUNT_TABLES) expect(await rowCount(t, "A")).toBe(0);
    expect(await r2Count("users/A/")).toBe(0);

    const logged = errs.mock.calls.map(([m]) => String(m)).join("\n");
    expect(logged).toContain("supabase_user_delete_failed");
    expect(logged).toContain('"sub":"A"'); // the handle for manual cleanup
    errs.mockRestore();
  });

  it("treats a 404 from the admin API as already deleted", async () => {
    await seed("A");
    fetchMock.mockImplementation(async () => new Response("", { status: 404 }));
    const errs = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await deleteAccount(supabaseEnv(), supabaseAuth("A", "A"));
    expect(await res.json()).toMatchObject({ deleted: true });
    expect(errs).not.toHaveBeenCalled();
    errs.mockRestore();
  });

  it("still succeeds when the admin call throws (network error)", async () => {
    await seed("A");
    fetchMock.mockImplementation(async () => {
      throw new Error("network down");
    });
    const errs = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await deleteAccount(supabaseEnv(), supabaseAuth("A", "A"));
    expect(await res.json()).toMatchObject({ deleted: true });
    expect(errs.mock.calls.map(([m]) => String(m)).join("\n"))
      .toContain("supabase_user_delete_error");
    errs.mockRestore();
  });
});
