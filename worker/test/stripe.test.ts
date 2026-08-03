import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { applyStripeEvent, verifySig } from "../src/stripe";
import { setupSchema, hmacHex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

beforeEach(async () => {
  await setupSchema(E.DB);
});

// deno-lint-ignore no-explicit-any
function sub(overrides: Record<string, any> = {}) {
  return {
    id: "sub_1",
    customer: "cus_1",
    status: "active",
    current_period_end: 9999999999,
    cancel_at_period_end: false,
    items: { data: [{ price: { id: "price_pro" } }] },
    metadata: { account_id: "acct_1" },
    ...overrides,
  };
}

async function tierOf(account: string): Promise<string | undefined> {
  const r = await E.DB.prepare("SELECT tier FROM accounts WHERE account_id=?1")
    .bind(account).first();
  return r?.tier;
}

describe("applyStripeEvent", () => {
  it("subscription.created maps price -> pro and mirrors to accounts", async () => {
    await applyStripeEvent(E, {
      id: "evt_1", type: "customer.subscription.created", created: 1000, data: sub(),
    });
    const s = await E.DB.prepare("SELECT tier,status FROM subscriptions WHERE account_id='acct_1'").first();
    expect(s.tier).toBe("pro");
    expect(s.status).toBe("active");
    expect(await tierOf("acct_1")).toBe("pro");
  });

  it("max price maps to max", async () => {
    await applyStripeEvent(E, {
      id: "evt_m", type: "customer.subscription.created", created: 1000,
      data: sub({ items: { data: [{ price: { id: "price_max" } }] } }),
    });
    expect(await tierOf("acct_1")).toBe("max");
  });

  it("is idempotent on replay (same event id)", async () => {
    const ev = { id: "evt_dup", type: "customer.subscription.created", created: 1000, data: sub() };
    await applyStripeEvent(E, ev);
    await E.DB.prepare("UPDATE accounts SET tier='free' WHERE account_id='acct_1'").run();
    await applyStripeEvent(E, ev); // replay must be inert
    expect(await tierOf("acct_1")).toBe("free");
  });

  it("subscription.deleted downgrades to free", async () => {
    await applyStripeEvent(E, { id: "e2", type: "customer.subscription.created", created: 1000, data: sub() });
    await applyStripeEvent(E, { id: "e3", type: "customer.subscription.deleted", created: 2000, data: sub({ status: "canceled" }) });
    expect(await tierOf("acct_1")).toBe("free");
  });

  it("payment_failed sets grace; invoice.paid clears it", async () => {
    await applyStripeEvent(E, { id: "e4", type: "customer.subscription.created", created: 1000, data: sub() });
    await applyStripeEvent(E, { id: "e5", type: "invoice.payment_failed", created: 2000, data: { customer: "cus_1" } });
    let row = await E.DB.prepare("SELECT status,grace_until FROM subscriptions WHERE account_id='acct_1'").first();
    expect(row.status).toBe("past_due");
    expect(row.grace_until).toBeTruthy();
    await applyStripeEvent(E, { id: "e6", type: "invoice.paid", created: 3000, data: { customer: "cus_1" } });
    row = await E.DB.prepare("SELECT status,grace_until FROM subscriptions WHERE account_id='acct_1'").first();
    expect(row.status).toBe("active");
    expect(row.grace_until).toBeNull();
  });

  it("incomplete status does not grant a paid tier", async () => {
    await applyStripeEvent(E, {
      id: "e7", type: "customer.subscription.updated", created: 1000,
      data: sub({ status: "incomplete" }),
    });
    expect(await tierOf("acct_1")).toBe("free");
  });
});

describe("verifySig (Stripe webhook HMAC)", () => {
  const secret = "whsec_test";
  const payload = '{"id":"evt_x"}';

  it("accepts a valid signature", async () => {
    const t = Math.floor(Date.now() / 1000);
    const v1 = await hmacHex(secret, `${t}.${payload}`);
    expect(await verifySig(payload, `t=${t},v1=${v1}`, secret)).toBe(true);
  });

  it("rejects a bad signature", async () => {
    const t = Math.floor(Date.now() / 1000);
    expect(await verifySig(payload, `t=${t},v1=deadbeef`, secret)).toBe(false);
  });

  it("rejects an out-of-window timestamp (replay)", async () => {
    const t = Math.floor(Date.now() / 1000) - 1000;
    const v1 = await hmacHex(secret, `${t}.${payload}`);
    expect(await verifySig(payload, `t=${t},v1=${v1}`, secret)).toBe(false);
  });

  it("accepts when one of several v1 signatures matches (secret rotation)", async () => {
    const t = Math.floor(Date.now() / 1000);
    const good = await hmacHex(secret, `${t}.${payload}`);
    // Header lists a stale signature first (old secret) then the valid one.
    expect(await verifySig(payload, `t=${t},v1=deadbeef,v1=${good}`, secret)).toBe(true);
  });
});
