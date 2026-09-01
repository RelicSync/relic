import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { authenticate } from "../src/auth";
import { TIERS, isTier } from "../src/tiers";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;
// Force the legacy device-token path (skip the Supabase JWKS path / network).
const legacyEnv = () => ({ ...E, SUPABASE_URL: undefined, SUPABASE_JWT_SECRET: undefined });
// Force the Supabase HS256 path with a known secret (no network, no JWKS).
const HS_SECRET = "test-secret";
const supabaseEnv = () => ({ ...E, SUPABASE_URL: undefined, SUPABASE_JWT_SECRET: HS_SECRET });

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/// Mint an HS256 JWT the way Supabase's legacy signing does — enough for
/// verifySupabaseJwt (audience "authenticated"; issuer unchecked without URL).
/// `iat` is optional because that is exactly the shape the min_valid_iat guard
/// has to cope with: a token minted without one must be treated as stale.
async function mintJwt(sub: string, email?: string, iat?: number): Promise<string> {
  const enc = new TextEncoder();
  const head = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify({
    sub, email, aud: "authenticated", iat,
    exp: Math.floor(Date.now() / 1000) + 3600,
  })));
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(HS_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(mac))}`;
}

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
    const auth = await authenticate(bearer(await mintJwt("sub-1", "a@x.com")), supabaseEnv());
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
    const auth = await authenticate(bearer(await mintJwt("sub-2", "b@x.com")), supabaseEnv());
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

describe("session revocation (min_valid_iat)", () => {
  const stamp = async (account: string, at: number) => {
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, min_valid_iat) VALUES (?1, ?2) " +
        "ON CONFLICT(account_id) DO UPDATE SET min_valid_iat = excluded.min_valid_iat",
    ).bind(account, at).run();
  };

  it("rejects a token minted before the watermark", async () => {
    await stamp("sub-r1", 5000);
    const r = await authenticate(bearer(await mintJwt("sub-r1", "r@x.com", 4999)), supabaseEnv());
    expect(r instanceof Response).toBe(true);
    expect((r as Response).status).toBe(401);
    expect((await (r as Response).json()).error).toBe("session_revoked");
  });

  it("accepts a token refreshed in the same second (the guard is strict <)", async () => {
    await stamp("sub-r2", 5000);
    const auth = await authenticate(bearer(await mintJwt("sub-r2", "r@x.com", 5000)), supabaseEnv());
    expect(auth).toMatchObject({ account: "sub-r2" });
  });

  it("accepts a token minted after the watermark", async () => {
    await stamp("sub-r3", 5000);
    const auth = await authenticate(bearer(await mintJwt("sub-r3", "r@x.com", 6000)), supabaseEnv());
    expect(auth).toMatchObject({ account: "sub-r3" });
  });

  it("rejects a token with no iat at all once the account is stamped", async () => {
    await stamp("sub-r4", 5000);
    const r = await authenticate(bearer(await mintJwt("sub-r4", "r@x.com")), supabaseEnv());
    expect((r as Response).status).toBe(401);
    expect((await (r as Response).json()).error).toBe("session_revoked");
  });

  it("an unstamped account (0) accepts an iat-less token unchanged", async () => {
    const auth = await authenticate(bearer(await mintJwt("sub-r5", "r@x.com")), supabaseEnv());
    expect(auth).toMatchObject({ account: "sub-r5", tier: "free" });
  });

  it("the LINKED account's watermark governs, not the sub's own", async () => {
    await E.DB.prepare(
      "INSERT INTO accounts (account_id, tier, min_valid_iat) VALUES ('legacy-v','pro',5000)",
    ).run();
    await E.DB.prepare(
      "INSERT INTO account_links (supabase_sub, account_id) VALUES ('sub-r6','legacy-v')",
    ).run();
    // The sub has no account row of its own, so only the link's stamp can bite.
    const r = await authenticate(bearer(await mintJwt("sub-r6", "r@x.com", 4000)), supabaseEnv());
    expect((r as Response).status).toBe(401);
    expect((await (r as Response).json()).error).toBe("session_revoked");
  });

  it("a stamped account does not lock out legacy device tokens", async () => {
    // Legacy tokens carry no iat and are grandfathered. They stay covered by
    // the `rev:` KV check instead.
    const hash = await sha256Hex("legacy-tok");
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,'acctL','pro')",
    ).bind(hash).run();
    await stamp("acctL", Math.floor(Date.now() / 1000) + 9999);
    const auth = await authenticate(
      new Request("https://x/account", { headers: { Authorization: "Bearer legacy-tok" } }),
      legacyEnv(),
    );
    expect(auth).toMatchObject({ account: "acctL" });
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
