import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../src/index";
import { HS_SECRET, mintJwt, setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

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
  opts: {
    body?: unknown;
    device?: string;
    appVersion?: string;
    env?: Record<string, unknown>; // override bindings (e.g. the Supabase path)
  } = {},
) {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  if (opts.device) headers["X-Relic-Device"] = opts.device;
  if (opts.appVersion) headers["X-Relic-App-Version"] = opts.appVersion;
  return worker.fetch(
    new Request(`https://x${path}`, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    }),
    opts.env ?? E,
  );
}

async function deviceRow(account: string, device: string) {
  return await E.DB.prepare(
    "SELECT last_seen_at, app_version, revoked_at FROM devices WHERE account_id = ?1 AND device_id = ?2",
  ).bind(account, device).first();
}

// touchDevice fires without ctx.waitUntil in the test harness (no ctx passed);
// give the floating UPDATE a beat to land before asserting.
const settle = () => new Promise((r) => setTimeout(r, 50));

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("device app_version", () => {
  it("register stores app_version and GET returns it", async () => {
    await seedToken("tokV1", "acctV1");
    const reg = await call("tokV1", "POST", "/account/devices", {
      body: { device_id: "dv1", label: "Desk", platform: "windows", app_version: "1.0.13" },
    });
    expect(reg.status).toBe(200);
    const list = await call("tokV1", "GET", "/account/devices");
    const { devices } = await list.json<{ devices: Array<{ device_id: string; app_version: string | null }> }>();
    expect(devices[0]).toMatchObject({ device_id: "dv1", app_version: "1.0.13" });
  });

  it("register without app_version leaves it NULL and never clobbers a known one", async () => {
    await seedToken("tokV2", "acctV2");
    await call("tokV2", "POST", "/account/devices", { body: { device_id: "dv2" } });
    expect((await deviceRow("acctV2", "dv2")).app_version).toBeNull();

    await call("tokV2", "POST", "/account/devices", {
      body: { device_id: "dv2", app_version: "1.0.12" },
    });
    expect((await deviceRow("acctV2", "dv2")).app_version).toBe("1.0.12");

    // A legacy re-register (no version field) must not null it out (COALESCE).
    await call("tokV2", "POST", "/account/devices", { body: { device_id: "dv2" } });
    expect((await deviceRow("acctV2", "dv2")).app_version).toBe("1.0.12");
  });

  it("caps a hostile app_version at 32 chars", async () => {
    await seedToken("tokV3", "acctV3");
    await call("tokV3", "POST", "/account/devices", {
      body: { device_id: "dv3", app_version: "9".repeat(200) },
    });
    expect((await deviceRow("acctV3", "dv3")).app_version).toHaveLength(32);
  });
});

describe("device last-seen touch", () => {
  it("an authed request with a stale row bumps last_seen_at and app_version", async () => {
    await seedToken("tokT1", "acctT1");
    const stale = Math.floor(Date.now() / 1000) - 7200;
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, last_seen_at) VALUES (?1,?2,?3)",
    ).bind("acctT1", "dt1", stale).run();

    const r = await call("tokT1", "GET", "/account", { device: "dt1", appVersion: "1.0.13" });
    expect(r.status).toBe(200);
    await settle();

    const row = await deviceRow("acctT1", "dt1");
    expect(row.last_seen_at).toBeGreaterThan(stale);
    expect(row.app_version).toBe("1.0.13");
  });

  it("a fresh row is not re-written within the hour (SQL predicate)", async () => {
    await seedToken("tokT2", "acctT2");
    const recent = Math.floor(Date.now() / 1000) - 60;
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, last_seen_at, app_version) VALUES (?1,?2,?3,?4)",
    ).bind("acctT2", "dt2", recent, "1.0.10").run();

    const r = await call("tokT2", "GET", "/account", { device: "dt2", appVersion: "1.0.13" });
    expect(r.status).toBe(200);
    await settle();

    const row = await deviceRow("acctT2", "dt2");
    expect(row.last_seen_at).toBe(recent);       // untouched
    expect(row.app_version).toBe("1.0.10");      // version rides with the touch
  });

  it("a legacy request without a version header still bumps last_seen_at", async () => {
    await seedToken("tokT3", "acctT3");
    const stale = Math.floor(Date.now() / 1000) - 7200;
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, last_seen_at, app_version) VALUES (?1,?2,?3,?4)",
    ).bind("acctT3", "dt3", stale, "1.0.9").run();

    const r = await call("tokT3", "GET", "/account", { device: "dt3" });
    expect(r.status).toBe(200);
    await settle();

    const row = await deviceRow("acctT3", "dt3");
    expect(row.last_seen_at).toBeGreaterThan(stale);
    expect(row.app_version).toBe("1.0.9");       // COALESCE keeps the known version
  });

  it("never thaws a revoked row", async () => {
    await seedToken("tokT4", "acctT4");
    const stale = Math.floor(Date.now() / 1000) - 7200;
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, last_seen_at, revoked_at) VALUES (?1,?2,?3,?3)",
    ).bind("acctT4", "dt4", stale).run();

    // No KV rev: entry seeded, so auth lets the request through; the touch
    // must still leave the revoked row frozen.
    const r = await call("tokT4", "GET", "/account", { device: "dt4", appVersion: "1.0.13" });
    expect(r.status).toBe(200);
    await settle();

    const row = await deviceRow("acctT4", "dt4");
    expect(row.last_seen_at).toBe(stale);
    expect(row.app_version).toBeNull();
  });
});

// --- removing a device is a real revocation --------------------------------
// The old behaviour only parked the device id in KV, and that guard runs solely
// when the client volunteers X-Relic-Device — drop the header and keep full
// access. Removal now goes to the IdP instead, because the refresh token on the
// removed device is the thing that would mint it a new access token an hour
// later. GoTrue exposes no per-session revocation (POST /logout authenticates as
// the user; the /admin surface has no session route at all), so this is
// necessarily account-wide.
describe("device removal revokes IdP sessions", () => {
  const ISS = "https://auth.test/auth/v1";
  const supaEnv = (extra: Record<string, unknown> = {}) => ({
    ...E,
    SUPABASE_URL: "https://auth.test",
    SUPABASE_JWT_SECRET: HS_SECRET, // verify locally; no JWKS fetch
    SUPABASE_ANON_KEY: "sb_publishable_test", // scan-ok: fake key in a test
    ...extra,
  });

  // Capture what the worker sends to GoTrue, and control what it hears back.
  function stubGoTrue(status: number) {
    const seen: { url: string; method?: string; headers: Record<string, string> }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation((async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push({
        url: String(input),
        method: init?.method,
        headers: Object.fromEntries(new Headers(init?.headers).entries()),
      });
      return new Response(null, { status });
    }) as typeof fetch);
    return seen;
  }

  const watermark = async (account: string) =>
    (await E.DB.prepare("SELECT min_valid_iat AS m FROM accounts WHERE account_id = ?1")
      .bind(account).first<{ m: number }>())?.m;

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("calls GoTrue's global logout and stamps the watermark", async () => {
    const now = Math.floor(Date.now() / 1000);
    const jwt = await mintJwt({ sub: "rv-ok", iat: now - 10, iss: ISS });
    await call(jwt, "POST", "/account/devices", { body: { device_id: "d1" }, env: supaEnv() });
    const seen = stubGoTrue(204); // GoTrue's documented success

    const r = await call(jwt, "DELETE", "/account/devices/d1", { env: supaEnv() });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ ok: true, sessions_revoked: true });

    expect(seen).toHaveLength(1);
    expect(seen[0].url).toBe("https://auth.test/auth/v1/logout?scope=global");
    expect(seen[0].method).toBe("POST");
    // The CALLER's token, not the service-role key: /logout authenticates as
    // the user, so the admin key cannot reach it.
    expect(seen[0].headers.authorization).toBe(`Bearer ${jwt}`);
    expect(seen[0].headers.apikey).toBe("sb_publishable_test"); // scan-ok: fake key in a test
    expect(await watermark("rv-ok")).toBeGreaterThanOrEqual(now);
    expect((await deviceRow("rv-ok", "d1"))?.revoked_at).not.toBeNull();
  });

  // The two halves are coupled deliberately. A watermark whose refresh tokens
  // are still alive is worse than none: it 401s every honest device for an hour
  // while the removed one quietly refreshes back in.
  it("does NOT stamp the watermark when GoTrue refuses", async () => {
    const jwt = await mintJwt({ sub: "rv-fail", iat: Math.floor(Date.now() / 1000) - 10, iss: ISS });
    await call(jwt, "POST", "/account/devices", { body: { device_id: "d1" }, env: supaEnv() });
    stubGoTrue(500);

    const r = await call(jwt, "DELETE", "/account/devices/d1", { env: supaEnv() });
    expect(r.status).toBe(200); // removal still succeeds
    expect(await r.json()).toMatchObject({ ok: true, sessions_revoked: false });
    expect(await watermark("rv-fail")).toBe(0);
    // Falls back to exactly what shipped before: the device row is revoked.
    expect((await deviceRow("rv-fail", "d1"))?.revoked_at).not.toBeNull();
  });

  // Legacy device-token auth and self-host have no IdP session to revoke.
  it("skips the IdP entirely for a legacy device token", async () => {
    await seedToken("legacy", "rv-legacy");
    await call("legacy", "POST", "/account/devices", { body: { device_id: "d1" } });
    const seen = stubGoTrue(204);

    const r = await call("legacy", "DELETE", "/account/devices/d1");
    expect(await r.json()).toMatchObject({ ok: true, sessions_revoked: false });
    expect(seen).toHaveLength(0);
    // No accounts row is conjured either. The stamp is a plain UPDATE for
    // exactly this reason: an upsert would create one defaulting to tier
    // 'free' and, through COALESCE(a.tier, t.tier), downgrade this token.
    expect(await watermark("rv-legacy")).toBeUndefined();
    expect((await deviceRow("rv-legacy", "d1"))?.revoked_at).not.toBeNull();
  });

  // The point of the whole change: after a removal the old bearer is dead
  // immediately, WITHOUT the client having to send X-Relic-Device.
  it("kills the pre-removal bearer at once, and only that one", async () => {
    const now = Math.floor(Date.now() / 1000);
    const old = await mintJwt({ sub: "rv-e2e", iat: now - 10, iss: ISS });
    await call(old, "POST", "/account/devices", { body: { device_id: "d1" }, env: supaEnv() });
    stubGoTrue(204);
    await call(old, "DELETE", "/account/devices/d1", { env: supaEnv() });
    vi.restoreAllMocks();

    // No X-Relic-Device header anywhere here — that header is exactly what the
    // old KV guard depended on and an attacker would simply omit.
    const stale = await call(old, "GET", "/account/devices", { env: supaEnv() });
    expect(stale.status).toBe(401);
    expect(await stale.json()).toMatchObject({ error: "session_revoked" });

    // A token minted after the removal (a fresh sign-in) works again.
    const fresh = await mintJwt({ sub: "rv-e2e", iat: now + 60, iss: ISS });
    expect((await call(fresh, "GET", "/account/devices", { env: supaEnv() })).status).toBe(200);
  });
});
