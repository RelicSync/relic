import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { applyStripeEvent, graceSweep, verifySig } from "../src/stripe";
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

// deno-lint-ignore no-explicit-any
async function subRow(account = "acct_1"): Promise<any> {
  return await E.DB.prepare(
    `SELECT tier, status, grace_until, current_period_end, cancel_at_period_end,
            updated_stripe_ts FROM subscriptions WHERE account_id=?1`,
  ).bind(account).first();
}

const DAY = 86400;

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

describe("writeSub ordering guard", () => {
  it("an out-of-order redelivery cannot reinstate the older state", async () => {
    // The newer event lands first (webhook delivery is not ordered).
    await applyStripeEvent(E, {
      id: "evt_new", type: "customer.subscription.updated", created: 5000,
      data: sub({ status: "canceled" }),
    });
    expect(await tierOf("acct_1")).toBe("free");

    // ...then a stale one arrives. It must be dropped, not applied.
    await applyStripeEvent(E, {
      id: "evt_old", type: "customer.subscription.updated", created: 1000,
      data: sub({ status: "active" }),
    });
    const row = await subRow();
    expect(row.status).toBe("canceled");
    expect(row.updated_stripe_ts).toBe(5000);
    expect(await tierOf("acct_1")).toBe("free");
  });

  it("two events in the same second both apply (the guard is >=)", async () => {
    await applyStripeEvent(E, {
      id: "evt_a", type: "customer.subscription.updated", created: 3000,
      data: sub({ items: { data: [{ price: { id: "price_pro" } }] } }),
    });
    await applyStripeEvent(E, {
      id: "evt_b", type: "customer.subscription.updated", created: 3000,
      data: sub({ items: { data: [{ price: { id: "price_max" } }] } }),
    });
    expect(await tierOf("acct_1")).toBe("max");
  });

  it("a caller with no timestamp still writes unconditionally", async () => {
    // checkout.session.completed carries only the Stripe ids and no ordering
    // field; it must keep working after a much newer subscription event.
    await applyStripeEvent(E, {
      id: "evt_sub", type: "customer.subscription.updated", created: 9000, data: sub(),
    });
    await applyStripeEvent(E, {
      id: "evt_ck", type: "checkout.session.completed", created: 1,
      data: { client_reference_id: "acct_1", customer: "cus_9", subscription: "sub_9" },
    });
    const row = await E.DB.prepare(
      "SELECT stripe_customer_id FROM subscriptions WHERE account_id='acct_1'",
    ).first();
    expect(row.stripe_customer_id).toBe("cus_9");
  });
});

describe("grace is monotone", () => {
  it("a second payment_failed does not push the deadline out", async () => {
    await applyStripeEvent(E, { id: "g1", type: "customer.subscription.created", created: 1000, data: sub() });
    await applyStripeEvent(E, { id: "g2", type: "invoice.payment_failed", created: 2000, data: { customer: "cus_1" } });
    const first = (await subRow()).grace_until;
    expect(first).toBeTruthy();

    // Stripe retries the invoice; each retry is another payment_failed.
    await applyStripeEvent(E, { id: "g3", type: "invoice.payment_failed", created: 3000, data: { customer: "cus_1" } });
    await applyStripeEvent(E, { id: "g4", type: "invoice.payment_failed", created: 4000, data: { customer: "cus_1" } });
    expect((await subRow()).grace_until).toBe(first);
  });

  it("a repeated past_due subscription.updated does not push it out either", async () => {
    await applyStripeEvent(E, {
      id: "g5", type: "customer.subscription.updated", created: 1000, data: sub({ status: "past_due" }),
    });
    const first = (await subRow()).grace_until;
    expect(first).toBeTruthy();
    expect(await tierOf("acct_1")).toBe("pro"); // still inside the window

    await applyStripeEvent(E, {
      id: "g6", type: "customer.subscription.updated", created: 2000, data: sub({ status: "past_due" }),
    });
    expect((await subRow()).grace_until).toBe(first);
  });

  it("past_due past its deadline grants nothing and keeps the entitlement", async () => {
    await applyStripeEvent(E, {
      id: "g7", type: "customer.subscription.updated", created: 1000, data: sub({ status: "past_due" }),
    });
    // Age the stamp out, the way seven real days would.
    await E.DB.prepare(
      "UPDATE subscriptions SET grace_until = ?1 WHERE account_id='acct_1'",
    ).bind(Math.floor(Date.now() / 1000) - 10).run();
    await graceSweep(E);
    expect(await tierOf("acct_1")).toBe("free");

    // A later past_due event must NOT re-grant, and must NOT erase the tier
    // subscriptions holds for invoice.paid to restore from.
    await applyStripeEvent(E, {
      id: "g8", type: "customer.subscription.updated", created: 2000, data: sub({ status: "past_due" }),
    });
    expect(await tierOf("acct_1")).toBe("free");
    expect((await subRow()).tier).toBe("pro");
  });

  it("invoice.paid restores the tier a sweep downgrade took away", async () => {
    await applyStripeEvent(E, { id: "g9", type: "customer.subscription.created", created: 1000, data: sub() });
    await applyStripeEvent(E, { id: "g10", type: "invoice.payment_failed", created: 2000, data: { customer: "cus_1" } });
    await E.DB.prepare(
      "UPDATE subscriptions SET grace_until = ?1 WHERE account_id='acct_1'",
    ).bind(Math.floor(Date.now() / 1000) - 10).run();
    await graceSweep(E);
    expect(await tierOf("acct_1")).toBe("free");

    await applyStripeEvent(E, { id: "g11", type: "invoice.paid", created: 3000, data: { customer: "cus_1" } });
    const row = await subRow();
    expect(row.status).toBe("active");
    expect(row.grace_until).toBeNull();
    expect(await tierOf("acct_1")).toBe("pro"); // actually restored, not just unblocked
  });

  it("graceSweep leaves subscriptions.tier alone", async () => {
    await applyStripeEvent(E, {
      id: "g12", type: "customer.subscription.updated", created: 1000, data: sub({ status: "past_due" }),
    });
    await E.DB.prepare(
      "UPDATE subscriptions SET grace_until = ?1 WHERE account_id='acct_1'",
    ).bind(Math.floor(Date.now() / 1000) - 10).run();
    await graceSweep(E);
    expect((await subRow()).tier).toBe("pro");
    expect(await tierOf("acct_1")).toBe("free");
  });

  it("a grace window still in the future keeps the paid tier", async () => {
    await applyStripeEvent(E, {
      id: "g13", type: "customer.subscription.updated", created: 1000, data: sub({ status: "past_due" }),
    });
    const row = await subRow();
    expect(row.grace_until).toBeGreaterThan(Math.floor(Date.now() / 1000) + 6 * DAY);
    await graceSweep(E); // not lapsed yet
    expect(await tierOf("acct_1")).toBe("pro");
  });

  it("recovering to active clears the grace stamp so the next failure restarts it", async () => {
    await applyStripeEvent(E, {
      id: "g14", type: "customer.subscription.updated", created: 1000, data: sub({ status: "past_due" }),
    });
    await applyStripeEvent(E, {
      id: "g15", type: "customer.subscription.updated", created: 2000, data: sub({ status: "active" }),
    });
    expect((await subRow()).grace_until).toBeNull();

    await applyStripeEvent(E, { id: "g16", type: "invoice.payment_failed", created: 3000, data: { customer: "cus_1" } });
    expect((await subRow()).grace_until).toBeGreaterThan(Math.floor(Date.now() / 1000));
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
