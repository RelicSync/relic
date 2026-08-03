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

function call(
  token: string,
  method: string,
  path: string,
  opts: { body?: unknown; device?: string; appVersion?: string } = {},
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
    E,
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
