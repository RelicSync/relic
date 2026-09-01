import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { authenticate } from "../src/auth";
import { TIERS, isTier } from "../src/tiers";
import { HS_SECRET, mintJwt, setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;
// Force the legacy device-token path (skip the Supabase JWKS path / network).
const legacyEnv = () => ({ ...E, SUPABASE_URL: undefined, SUPABASE_JWT_SECRET: undefined });
// Force the Supabase HS256 path with a known secret (no network, no JWKS).
const supabaseEnv = () => ({ ...E, SUPABASE_URL: undefined, SUPABASE_JWT_SECRET: HS_SECRET });

const bearer = (token: string) =>
  new Request("https://x/account", { headers: { Authorization: `Bearer ${token}` } });

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("authenticate", () => {
  it("401s a missing bearer", async () => {
    const r = await authenticate(new Request("https://x/account"), legacyEnv());
    expect(r instanceof Response).toBe(true);
    expect((r as Response).status).toBe(401);
  });

  it("401s an unknown token", async () => {
    const r = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer nope" } }),
      legacyEnv(),
    );
    expect((r as Response).status).toBe(401);
  });

  it("resolves a valid legacy device token", async () => {
    const hash = await sha256Hex("mytoken");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'acctX','pro')",
    ).bind(hash).run();
    const auth = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer mytoken" } }),
      legacyEnv(),
    );
    expect(auth).toMatchObject({ account: "acctX", tier: "pro" });
  });

  it("a billing downgrade beats a stale paid tier on the token row", async () => {
    // tokens.tier is frozen at mint time. The account was downgraded to free
    // (webhook or grace sweep), so the legacy device must come back free.
    const hash = await sha256Hex("stale-pro");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'acctD','pro')",
    ).bind(hash).run();
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, tier) VALUES ('acctD','free')",
    ).run();
    const auth = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer stale-pro" } }),
      legacyEnv(),
    );
    expect(auth).toMatchObject({ account: "acctD", tier: "free" });
  });

  it("an upgrade on the account row reaches a legacy token too", async () => {
    const hash = await sha256Hex("stale-free");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'acctE','free')",
    ).bind(hash).run();
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, tier) VALUES ('acctE','max')",
    ).run();
    const auth = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer stale-free" } }),
      legacyEnv(),
    );
    expect(auth).toMatchObject({ account: "acctE", tier: "max" });
  });

  it("falls back to tokens.tier when the account row does not exist", async () => {
    // Legacy deploys minted tokens without ever writing an accounts row.
    const hash = await sha256Hex("no-account");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'acctF','pro')",
    ).bind(hash).run();
    const auth = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer no-account" } }),
      legacyEnv(),
    );
    expect(auth).toMatchObject({ account: "acctF", tier: "pro" });
  });

  it("ignores a revoked token", async () => {
    const hash = await sha256Hex("revoked");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier, revoked) VALUES (?1,'acctY','pro',1)",
    ).bind(hash).run();
    const r = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer revoked" } }),
      legacyEnv(),
    );
    expect((r as Response).status).toBe(401);
  });
});

describe("supabase path + account links", () => {
  it("an unlinked sub is its own account (lazy free row)", async () => {
    const auth = await authenticate(bearer(await mintJwt({ sub: "sub-1", email: "a@x.com" })), supabaseEnv());
    expect(auth).toMatchObject({ account: "sub-1", tier: "free", email: "a@x.com" });
    const row = await E.DB.prepare(
      "SELECT account_id FROM accounts WHERE account_id='sub-1'",
    ).first();
    expect(row).not.toBeNull();
  });

  it("a linked sub resolves to the linked account, including its tier", async () => {
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, tier) VALUES ('legacy-vault','pro')",
    ).run();
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('sub-2','legacy-vault')",
    ).run();
    const auth = await authenticate(bearer(await mintJwt({ sub: "sub-2", email: "b@x.com" })), supabaseEnv());
    expect(auth).toMatchObject({ account: "legacy-vault", tier: "pro", email: "b@x.com" });
    // The sub's own account row must NOT be lazily created — the identity
    // acts wholly as the linked account.
    const own = await E.DB.prepare(
      "SELECT account_id FROM accounts WHERE account_id='sub-2'",
    ).first();
    expect(own).toBeNull();
  });

  it("a garbage JWT still falls through to the legacy token path", async () => {
    const hash = await sha256Hex("dev-token");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id) VALUES (?1,'acctZ')",
    ).bind(hash).run();
    const auth = await authenticate(bearer("dev-token"), supabaseEnv());
    expect(auth).toMatchObject({ account: "acctZ", tier: "free" });
  });
});

describe("tiers", () => {
  it("validates tier strings", () => {
    expect(isTier("free")).toBe(true);
    expect(isTier("pro")).toBe(true);
    expect(isTier("max")).toBe(true);
    expect(isTier("paid")).toBe(false);
    expect(isTier(undefined)).toBe(false);
  });

  it("has the expected caps", () => {
    expect(TIERS.free.vault).toBe(25);
    expect(TIERS.pro.vault).toBeNull();
    expect(TIERS.max.ring).toBeNull();
    expect(TIERS.free.storage).toBe(250 * 1024 * 1024);
  });
});

// --- session-revocation watermark (accounts.min_valid_iat) ------------------
// Removing a device revokes every refresh token at the IdP and stamps the
// removal time here. authenticate() then refuses any access token minted before
// the stamp, which is what closes the up-to-an-hour window in which an
// already-issued token would otherwise still be honoured.
describe("session revocation watermark", () => {
  const NOW = Math.floor(Date.now() / 1000);
  const stamp = (account: string, iat: number) =>
    E.DB.prepare("INSERT INTO accounts (account_id, min_valid_iat) VALUES (?1, ?2)")
      .bind(account, iat).run();

  it("rejects a token issued before the stamp", async () => {
    await stamp("rev-old", NOW);
    const r = await authenticate(
      bearer(await mintJwt({ sub: "rev-old", iat: NOW - 60 })), supabaseEnv(),
    ) as Response;
    expect(r instanceof Response).toBe(true);
    expect(r.status).toBe(401);
    expect(await r.json()).toMatchObject({ error: "session_revoked" });
  });

  // Strict `<`: a client that refreshed in the same second as the removal is
  // holding a post-revocation token and must not be locked out by rounding.
  it("accepts a token issued in the same second as the stamp", async () => {
    await stamp("rev-edge", NOW);
    const auth = await authenticate(bearer(await mintJwt({ sub: "rev-edge", iat: NOW })), supabaseEnv());
    expect(auth instanceof Response).toBe(false);
    expect((auth as { account: string }).account).toBe("rev-edge");
  });

  it("accepts a token issued after the stamp", async () => {
    await stamp("rev-new", NOW);
    const auth = await authenticate(bearer(await mintJwt({ sub: "rev-new", iat: NOW + 30 })), supabaseEnv());
    expect(auth instanceof Response).toBe(false);
  });

  // A token we cannot place relative to the stamp fails closed.
  it("rejects a stamped account's token that carries no iat", async () => {
    await stamp("rev-noiat", NOW);
    const r = await authenticate(bearer(await mintJwt({ sub: "rev-noiat" })), supabaseEnv()) as Response;
    expect(r.status).toBe(401);
    expect(await r.json()).toMatchObject({ error: "session_revoked" });
  });

  it("ignores the default 0 stamp every existing account has", async () => {
    const auth = await authenticate(bearer(await mintJwt({ sub: "rev-zero", iat: NOW - 9999 })), supabaseEnv());
    expect(auth instanceof Response).toBe(false);
  });

  // The check sits AFTER account_links resolution on purpose: a linked identity
  // acts as the account it is bound to, so that account's stamp governs.
  it("honours the LINKED account's stamp, not the sub's own", async () => {
    await stamp("linked-acct", NOW);
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('link-sub','linked-acct')",
    ).run();
    const r = await authenticate(
      bearer(await mintJwt({ sub: "link-sub", iat: NOW - 60 })), supabaseEnv(),
    ) as Response;
    expect(r.status).toBe(401);
    expect(await r.json()).toMatchObject({ error: "session_revoked" });
  });

  it("does not let a stamp on the sub block a link to an unstamped account", async () => {
    await stamp("link-sub-2", NOW); // stamp on the SUB, which is not the account
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('link-sub-2','clean-acct')",
    ).run();
    const auth = await authenticate(
      bearer(await mintJwt({ sub: "link-sub-2", iat: NOW - 60 })), supabaseEnv(),
    );
    expect(auth instanceof Response).toBe(false);
    expect((auth as { account: string }).account).toBe("clean-acct");
  });

  // Legacy device tokens have no iat to compare and are governed by
  // tokens.revoked instead. A stamp must not strand a headless relic-cli.
  it("leaves legacy device tokens alone", async () => {
    await stamp("legacy-acct", NOW);
    const hash = await sha256Hex("legacytok");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'legacy-acct','pro')",
    ).bind(hash).run();
    const auth = await authenticate(bearer("legacytok"), legacyEnv());
    expect(auth instanceof Response).toBe(false);
    expect((auth as { account: string }).account).toBe("legacy-acct");
  });
});
