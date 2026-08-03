import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../src/index";
import { applyStripeEvent, graceSweep } from "../src/stripe";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

// --- shared helpers ---------------------------------------------------------
async function seedToken(token: string, account: string, tier = "free") {
  const hash = await sha256Hex(token);
  await E.DB.prepare(
    "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)",
  ).bind(hash, account, tier).run();
}

function call(
  token: string,
  method: string,
  path: string,
  opts: { body?: unknown; device?: string; env?: unknown } = {},
) {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  if (opts.device) headers["X-Relic-Device"] = opts.device;
  return worker.fetch(
    new Request(`https://x${path}`, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    }),
    (opts.env ?? E) as never,
  );
}

// HS256 JWT minting (mirrors auth.test) so worker.fetch exercises the Supabase
// path with a known secret — no JWKS / network.
const HS_SECRET = "test-secret";
const supaEnv = (extra: Record<string, unknown> = {}) =>
  ({ ...E, SUPABASE_URL: undefined, SUPABASE_JWT_SECRET: HS_SECRET, ...extra });

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// deno-lint-ignore no-explicit-any
async function mintJwt(claims: Record<string, any>): Promise<string> {
  const enc = new TextEncoder();
  const head = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify({
    aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600, ...claims,
  })));
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(HS_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(mac))}`;
}

function envelope(uid: string, updated = 1000) {
  return { v: 1, uid, created_at: 1000, updated_at: updated, byte_size: 10, promoted: false, n: "n", ct: "c" };
}

beforeEach(async () => {
  await setupSchema(E.DB);
});

// --- (1) device rename ------------------------------------------------------
describe("PATCH /account/devices/:id (rename)", () => {
  beforeEach(async () => {
    await seedToken("tokA", "acctA");
    await call("tokA", "POST", "/account/devices", { body: { device_id: "dev-1", label: "Old" } });
  });

  it("renames the device (happy path)", async () => {
    const r = await call("tokA", "PATCH", "/account/devices/dev-1", { body: { label: "  New Name  " } });
    expect(r.status).toBe(200);
    const row = await E.DB.prepare(
      "SELECT label FROM devices WHERE account_id='acctA' AND device_id='dev-1'",
    ).first<{ label: string }>();
    expect(row.label).toBe("New Name"); // trimmed
  });

  it("404s an unknown device", async () => {
    const r = await call("tokA", "PATCH", "/account/devices/ghost", { body: { label: "x" } });
    expect(r.status).toBe(404);
    expect((await r.json()).error).toBe("not_found");
  });

  it("404s a revoked device (owner cannot rename a removed one)", async () => {
    await call("tokA", "DELETE", "/account/devices/dev-1");
    const r = await call("tokA", "PATCH", "/account/devices/dev-1", { body: { label: "x" } });
    expect(r.status).toBe(404);
  });

  it("is owner-scoped: another account cannot rename it", async () => {
    await seedToken("tokB", "acctB");
    const r = await call("tokB", "PATCH", "/account/devices/dev-1", { body: { label: "hax" } });
    expect(r.status).toBe(404);
    const row = await E.DB.prepare(
      "SELECT label FROM devices WHERE account_id='acctA' AND device_id='dev-1'",
    ).first<{ label: string }>();
    expect(row.label).toBe("Old"); // unchanged
  });

  it("400s an empty / whitespace label", async () => {
    const r = await call("tokA", "PATCH", "/account/devices/dev-1", { body: { label: "   " } });
    expect(r.status).toBe(400);
  });

  it("caps the label at 64 chars", async () => {
    const long = "L".repeat(200);
    const r = await call("tokA", "PATCH", "/account/devices/dev-1", { body: { label: long } });
    expect(r.status).toBe(200);
    const row = await E.DB.prepare(
      "SELECT label FROM devices WHERE account_id='acctA' AND device_id='dev-1'",
    ).first<{ label: string }>();
    expect(row.label.length).toBe(64);
  });
});

// --- (2) verify-to-sync gate ------------------------------------------------
describe("VERIFY_GATE", () => {
  const unverified = () => mintJwt({ sub: "u1", email: "u@x.com", app_metadata: { provider: "email" }, user_metadata: { email_verified: false } });
  const verified = () => mintJwt({ sub: "u1", email: "u@x.com", app_metadata: { provider: "email" }, user_metadata: { email_verified: true } });
  const oauth = () => mintJwt({ sub: "u1", email: "u@x.com", app_metadata: { provider: "google", providers: ["google"] } });

  it("is off by default: an unverified write is allowed", async () => {
    const r = await worker.fetch(
      new Request("https://x/relic/aaa", {
        method: "PUT",
        headers: { Authorization: `Bearer ${await unverified()}`, "Content-Type": "application/json" },
        body: JSON.stringify(envelope("aaa")),
      }),
      supaEnv(), // VERIFY_GATE unset
    );
    expect(r.status).toBe(200);
  });

  it("on: rejects an unverified email on sync writes", async () => {
    const g = supaEnv({ VERIFY_GATE: "on" });
    const tok = await unverified();
    for (const [method, path, hasBody] of [
      ["PUT", "/relic/aaa", true],
      ["POST", "/blob?id=blob0001", false],
      ["POST", "/blob/mpu?id=blob0001", false],
      ["PUT", "/keyparams", true],
    ] as const) {
      const r = await worker.fetch(
        new Request(`https://x${path}`, {
          method,
          headers: { Authorization: `Bearer ${tok}`, ...(hasBody ? { "Content-Type": "application/json" } : {}) },
          body: hasBody ? JSON.stringify(envelope("aaa")) : "hello",
        }),
        g,
      );
      expect(r.status, `${method} ${path}`).toBe(403);
      expect((await r.json()).error).toBe("email_unverified");
    }
  });

  it("on: allows a verified email to write", async () => {
    const r = await worker.fetch(
      new Request("https://x/relic/bbb", {
        method: "PUT",
        headers: { Authorization: `Bearer ${await verified()}`, "Content-Type": "application/json" },
        body: JSON.stringify(envelope("bbb")),
      }),
      supaEnv({ VERIFY_GATE: "on" }),
    );
    expect(r.status).toBe(200);
  });

  it("on: allows an OAuth identity (provider vouches for the address)", async () => {
    const r = await worker.fetch(
      new Request("https://x/relic/ccc", {
        method: "PUT",
        headers: { Authorization: `Bearer ${await oauth()}`, "Content-Type": "application/json" },
        body: JSON.stringify(envelope("ccc")),
      }),
      supaEnv({ VERIFY_GATE: "on" }),
    );
    expect(r.status).toBe(200);
  });

  it("on: reads stay open for an unverified email", async () => {
    const r = await worker.fetch(
      new Request("https://x/relics", { headers: { Authorization: `Bearer ${await unverified()}` } }),
      supaEnv({ VERIFY_GATE: "on" }),
    );
    expect(r.status).toBe(200);
  });

  it("on: a delete stays open for an unverified email", async () => {
    const r = await worker.fetch(
      new Request("https://x/relic/aaa", { method: "DELETE", headers: { Authorization: `Bearer ${await unverified()}` } }),
      supaEnv({ VERIFY_GATE: "on" }),
    );
    expect(r.status).toBe(200);
  });

  it("on: legacy device-token auth is grandfathered", async () => {
    await seedToken("tokLegacy", "acctL");
    const r = await call("tokLegacy", "PUT", "/relic/ddd", { body: envelope("ddd"), env: { ...E, VERIFY_GATE: "on" } });
    expect(r.status).toBe(200);
  });
});

// --- (3) post-checkout zero-devices email -----------------------------------
describe("checkout.session.completed setup email", () => {
  // deno-lint-ignore no-explicit-any
  let fetchMock: any;
  const realFetch = globalThis.fetch;

  beforeEach(() => {
    fetchMock = vi.fn(async () => new Response("{}", { status: 200 }));
    globalThis.fetch = fetchMock;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  function checkout(id: string, account: string, email = "buyer@x.com") {
    return {
      id, type: "checkout.session.completed", created: 1000,
      data: { id, client_reference_id: account, customer: "cus_1", subscription: "sub_1", customer_details: { email } },
    };
  }
  const withKey = () => ({ ...E, RESEND_API_KEY: "re_test" });

  it("sends one email via Resend when the account has zero devices", async () => {
    await applyStripeEvent(withKey(), checkout("cs_send", "acctE") as never);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.resend.com/emails");
    expect(init.headers.Authorization).toBe("Bearer re_test");
    const sent = JSON.parse(init.body);
    expect(sent.from).toBe("Relic <no-reply@relic.space>");
    expect(sent.to).toBe("buyer@x.com");
    expect(sent.subject).toBe("Your Relic plan is active. 2-minute setup");
    expect(sent.text).toContain("https://relic.space/download/windows");
    expect(sent.text).not.toContain("—"); // no em dash
  });

  it("skips silently when RESEND_API_KEY is absent", async () => {
    await applyStripeEvent(E, checkout("cs_nokey", "acctE") as never); // no key on E
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("skips when the account already has an active device", async () => {
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, label) VALUES ('acctE','d1','x')",
    ).run();
    await applyStripeEvent(withKey(), checkout("cs_hasdev", "acctE") as never);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("is idempotent per session id (KV marker) across sibling events", async () => {
    await applyStripeEvent(withKey(), { ...checkout("cs_idem", "acctE"), id: "evt_a" } as never);
    // A different event id for the SAME checkout session must not re-send.
    await applyStripeEvent(withKey(), { ...checkout("cs_idem", "acctE"), id: "evt_b" } as never);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    // The KV marker exists.
    expect(await E.PAIR.get("ckem:cs_idem")).toBe("1");
  });
});

// --- graceSweep: downgrade + one "plan lapsed" email --------------------------
describe("graceSweep plan-lapsed email", () => {
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

  async function seedLapsed(account: string, email: string | null, tier = "pro") {
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, email, tier) VALUES (?1, ?2, ?3)",
    ).bind(account, email, tier).run();
    await E.DB.prepare(
      `INSERT INTO subscriptions (account_id, status, tier, grace_until)
       VALUES (?1, 'past_due', ?2, 1)`, // grace_until=1: long expired
    ).bind(account, tier).run();
  }

  it("downgrades to free and sends one email", async () => {
    await seedLapsed("acctG", "payer@x.com");
    await graceSweep(withKey());

    const acct = await E.DB.prepare(
      "SELECT tier FROM accounts WHERE account_id = 'acctG'",
    ).first();
    expect(acct.tier).toBe("free");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.resend.com/emails");
    const sent = JSON.parse(init.body);
    expect(sent.to).toBe("payer@x.com");
    expect(sent.subject).toBe("Your Relic plan has lapsed. Your data is safe");
    expect(sent.text).toContain("Nothing was deleted");
    expect(sent.text).toContain("https://relic.space/account");
    expect(sent.text).not.toContain("—"); // no em dash
  });

  it("does not re-send on the next sweep (already free)", async () => {
    await seedLapsed("acctG2", "payer2@x.com");
    await graceSweep(withKey());
    await graceSweep(withKey());
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("still downgrades when RESEND_API_KEY is absent (no email attempt)", async () => {
    await seedLapsed("acctG3", "payer3@x.com");
    await graceSweep(E);
    const acct = await E.DB.prepare(
      "SELECT tier FROM accounts WHERE account_id = 'acctG3'",
    ).first();
    expect(acct.tier).toBe("free");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("still downgrades when the account has no email on file", async () => {
    await seedLapsed("acctG4", null);
    await graceSweep(withKey());
    const acct = await E.DB.prepare(
      "SELECT tier FROM accounts WHERE account_id = 'acctG4'",
    ).first();
    expect(acct.tier).toBe("free");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("leaves in-grace accounts alone", async () => {
    const future = Math.floor(Date.now() / 1000) + 86400;
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, email, tier) VALUES ('acctG5','p5@x.com','pro')",
    ).run();
    await E.DB.prepare(
      `INSERT INTO subscriptions (account_id, status, tier, grace_until)
       VALUES ('acctG5', 'past_due', 'pro', ?1)`,
    ).bind(future).run();
    await graceSweep(withKey());
    const acct = await E.DB.prepare(
      "SELECT tier FROM accounts WHERE account_id = 'acctG5'",
    ).first();
    expect(acct.tier).toBe("pro");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// --- DELETE /account fresh-token gate -----------------------------------------
// A Supabase JWT older than 10 minutes must not be able to destroy the account;
// clients force a token refresh right before calling, so real deletes always
// carry a fresh iat. Legacy device tokens carry no iat and are grandfathered.
describe("DELETE /account stale-token gate", () => {
  const del = async (jwt: string) =>
    worker.fetch(
      new Request("https://x/account", {
        method: "DELETE",
        headers: { Authorization: `Bearer ${jwt}` },
      }),
      supaEnv() as never,
    );

  it("403s a token issued more than 10 minutes ago", async () => {
    const now = Math.floor(Date.now() / 1000);
    const jwt = await mintJwt({ sub: "acct-stale", iat: now - 20 * 60 });
    const r = await del(jwt);
    expect(r.status).toBe(403);
    expect((await r.json()).error).toBe("stale_token");
  });

  it("allows a freshly-issued token through", async () => {
    const now = Math.floor(Date.now() / 1000);
    const jwt = await mintJwt({ sub: "acct-fresh", iat: now - 30 });
    const r = await del(jwt);
    expect(r.status).toBe(200);
    expect((await r.json()).deleted).toBe(true);
  });

  it("grandfathers legacy device tokens (no iat)", async () => {
    await seedToken("tokDel", "acct-legacy");
    const r = await call("tokDel", "DELETE", "/account");
    expect(r.status).toBe(200);
  });
});
