// The free plan sync rule (src/syncplan.ts): one device keeps syncing once a
// free account's first week is over; the rest get 403 sync_paused.
import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../src/index";
import { canExplainPause, SYNC_SWITCH_COOLDOWN, SYNC_WEEK, syncWeekSweep } from "../src/syncplan";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;
const ON = { ...E, SYNC_PLAN_GATE: "on" };
const now = () => Math.floor(Date.now() / 1000);
const DAY = 86400;

// Each test uses its own account id: the plan is cached per account for a
// minute inside the isolate, and a fresh id keeps tests from seeing each
// other's cache.
let seq = 0;
async function account(opts: {
  tier?: string;
  age?: number; // seconds since sign-up
  syncUntil?: number | null;
  // App version defaults to the first release that explains a pause; null =
  // never reported (web vault, legacy clients).
  devices?: Array<[id: string, lastSeenAgo: number, appVersion?: string | null]>;
} = {}) {
  const acct = `acct-sp-${++seq}`;
  const token = `tok-sp-${seq}`;
  const tier = opts.tier ?? "free";
  await E.DB.prepare("INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)")
    .bind(await sha256Hex(token), acct, tier).run();
  await E.DB.prepare(
    "INSERT INTO accounts (account_id, tier, created_at, sync_until) VALUES (?1,?2,?3,?4)",
  ).bind(acct, tier, now() - (opts.age ?? 8 * DAY), opts.syncUntil ?? null).run();
  for (const [id, ago, ver] of opts.devices ?? []) {
    await E.DB.prepare(
      "INSERT INTO devices (account_id, device_id, platform, last_seen_at, app_version) VALUES (?1,?2,'windows',?3,?4)",
    ).bind(acct, id, now() - ago, ver === undefined ? "1.0.64" : ver).run();
  }
  return { acct, token };
}

function call(
  token: string,
  method: string,
  path: string,
  opts: { device?: string; body?: unknown; env?: Record<string, unknown>; headers?: Record<string, string> } = {},
) {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}`, ...opts.headers };
  if (opts.device) headers["X-Relic-Device"] = opts.device;
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  return worker.fetch(
    new Request(`https://x${path}`, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    }),
    opts.env ?? ON,
  );
}

const envelope = (uid: string) => ({
  v: 1, uid, created_at: 1000, updated_at: 1000, byte_size: 10, promoted: false, n: "n", ct: "c",
});

async function syncDevice(acct: string) {
  return (await E.DB.prepare("SELECT sync_device, sync_device_at FROM accounts WHERE account_id = ?1")
    .bind(acct).first()) as { sync_device: string | null; sync_device_at: number | null };
}

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("free plan sync rule", () => {
  it("is off by default: a second device still syncs after the week", async () => {
    const { token } = await account({ devices: [["pc", 10], ["phone", 600]] });
    const r = await call(token, "GET", "/relics", { device: "phone", env: E });
    expect(r.status).toBe(200);
  });

  it("lets every device sync during the free week", async () => {
    const { token } = await account({ age: 2 * DAY, devices: [["pc", 10], ["phone", 600]] });
    for (const dev of ["pc", "phone"]) {
      expect((await call(token, "GET", "/relics", { device: dev })).status, dev).toBe(200);
    }
  });

  it("keeps a lone device syncing after the week", async () => {
    const { acct, token } = await account({ devices: [["pc", 10]] });
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(200);
    // ...and settles it as the kept device, so a phone added later is the
    // one that pauses.
    expect((await syncDevice(acct)).sync_device).toBe("pc");
  });

  it("after the week, keeps the first device to sync and pauses the rest", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(200);

    const r = await call(token, "GET", "/relics", { device: "phone" });
    expect(r.status).toBe(403);
    const body = await r.json<{ error: string; sync_device: string; sync_until: number; devices: unknown[] }>();
    expect(body.error).toBe("sync_paused");
    expect(body.sync_device).toBe("pc");
    expect(body.devices).toHaveLength(2);

    // The automatic pick is written down, and not as a by-hand pick.
    expect(await syncDevice(acct)).toEqual({ sync_device: "pc", sync_device_at: null });
  });

  it("keeps the first caller even when another device was seen more recently", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(200);
    expect((await syncDevice(acct)).sync_device).toBe("phone");
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(403);
  });

  it("settles on the most recently seen device for a request with no device id, and lets it through", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    // No device id means no version to check, so it is never paused.
    expect((await call(token, "GET", "/relics")).status).toBe(200);
    expect((await syncDevice(acct)).sync_device).toBe("pc");
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(403);
  });

  it("never pauses an app too old to explain it, or one with no version", async () => {
    const { token } = await account({
      devices: [["pc", 10], ["oldmac", 60, "1.0.60"], ["web", 60, null], ["odd", 60, "dev"]],
    });
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(200); // kept
    for (const dev of ["oldmac", "web", "odd"]) {
      expect((await call(token, "GET", "/relics", { device: dev })).status, dev).toBe(200);
      const a = await (await call(token, "GET", "/account", { device: dev })).json();
      expect(a, dev).toMatchObject({ sync_paused: false });
    }
  });

  it("pauses an old device once it updates, going by the version it sends", async () => {
    const { token } = await account({ devices: [["pc", 10], ["phone", 60, "1.0.61"]] });
    await call(token, "GET", "/relics", { device: "pc" }); // settle the pick
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(200);
    const r = await call(token, "GET", "/relics", {
      device: "phone",
      headers: { "X-Relic-App-Version": "1.0.64" },
    });
    expect(r.status).toBe(403);
  });

  it("keeps an old kept device syncing and still pauses a new second device", async () => {
    const { acct, token } = await account({ devices: [["oldpc", 10, "1.0.48"], ["phone", 60]] });
    expect((await call(token, "GET", "/relics", { device: "oldpc" })).status).toBe(200);
    expect((await syncDevice(acct)).sync_device).toBe("oldpc");
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(403);
  });

  it("covers writes, blobs and the doorbell as well as reads", async () => {
    const { token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    await call(token, "GET", "/relics", { device: "pc" }); // settle the pick
    const cases: Array<[string, string, unknown?, Record<string, string>?]> = [
      ["PUT", "/relic/aaa", envelope("aaa")],
      ["POST", "/blob?id=blob0001"],
      ["GET", "/tombstones?since=0"],
      ["GET", "/sync/socket", undefined, { Upgrade: "websocket" }],
    ];
    for (const [method, path, body, headers] of cases) {
      const r = await call(token, method, path, { device: "phone", body, headers });
      expect(r.status, `${method} ${path}`).toBe(403);
      expect((await r.json<{ error: string }>()).error).toBe("sync_paused");
    }
  });

  it("leaves account routes open on a paused device", async () => {
    const { token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    await call(token, "GET", "/relics", { device: "pc" }); // settle the pick
    expect((await call(token, "GET", "/account/devices", { device: "phone" })).status).toBe(200);
    const a = await call(token, "GET", "/account", { device: "phone" });
    expect(a.status).toBe(200);
    expect(await a.json()).toMatchObject({ sync_device: "pc", sync_paused: true });
  });

  it("never applies to paid accounts", async () => {
    for (const tier of ["pro", "max"]) {
      const { token } = await account({ tier, devices: [["pc", 10], ["phone", 3 * DAY]] });
      expect((await call(token, "GET", "/relics", { device: "phone" })).status, tier).toBe(200);
      const a = await (await call(token, "GET", "/account", { device: "phone" })).json();
      expect(a, tier).toMatchObject({ sync_until: null, sync_device: null, sync_paused: false });
    }
  });

  it("honours a later sync_until (accounts given extra time at launch)", async () => {
    const { token } = await account({
      age: 60 * DAY,
      syncUntil: now() + 20 * DAY,
      devices: [["pc", 10], ["phone", 3 * DAY]],
    });
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(200);
    const a = await (await call(token, "GET", "/account", { device: "phone" })).json<{ sync_until: number }>();
    expect(a.sync_until).toBeGreaterThan(now() + 19 * DAY);
  });

  it("reports the countdown on GET /account during the week", async () => {
    const { token } = await account({ age: 2 * DAY, devices: [["pc", 10]] });
    const a = await (await call(token, "GET", "/account", { device: "pc" })).json<{
      sync_until: number; sync_device: string | null; sync_paused: boolean;
    }>();
    expect(a.sync_until).toBeGreaterThan(now() + 4 * DAY);
    expect(a.sync_until).toBeLessThanOrEqual(now() - 2 * DAY + SYNC_WEEK);
    expect(a.sync_device).toBeNull();
    expect(a.sync_paused).toBe(false);
  });

  it("re-picks when the kept device has been removed", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY], ["old", 9 * DAY]] });    await E.DB.prepare("UPDATE accounts SET sync_device = 'old' WHERE account_id = ?1").bind(acct).run();
    await E.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE account_id = ?1 AND device_id = 'old'")
      .bind(acct).run();
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(200);
    expect((await syncDevice(acct)).sync_device).toBe("pc");
  });
});

describe("canExplainPause", () => {
  it("reads release versions and refuses anything it can't parse", () => {
    for (const v of ["1.0.64", "1.0.64+82", "1.0.65", "1.0.100", "1.1.0", "2.0.0", " 1.0.64 "]) {
      expect(canExplainPause(v), v).toBe(true);
    }
    for (const v of ["1.0.63", "1.0.9", "0.9.99", "1.0", "dev", "", null, undefined]) {
      expect(canExplainPause(v), String(v)).toBe(false);
    }
  });
});

describe("POST /account/sync-device", () => {
  it("moves sync to the chosen device; the first by-hand pick is free", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    await call(token, "GET", "/relics", { device: "pc" }); // automatic pick: pc

    const r = await call(token, "POST", "/account/sync-device", { device: "phone", body: { device_id: "phone" } });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, sync_device: "phone" });
    expect((await syncDevice(acct)).sync_device_at).toBeGreaterThan(now() - 60);

    // This isolate's cached plan was dropped, so the switch is immediate here.
    expect((await call(token, "GET", "/relics", { device: "phone" })).status).toBe(200);
    expect((await call(token, "GET", "/relics", { device: "pc" })).status).toBe(403);
  });

  it("allows one by-hand switch a week on free", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    await E.DB.prepare("UPDATE accounts SET sync_device = 'pc', sync_device_at = ?2 WHERE account_id = ?1")
      .bind(acct, now() - DAY).run();

    const r = await call(token, "POST", "/account/sync-device", { device: "phone", body: { device_id: "phone" } });
    expect(r.status).toBe(429);
    const body = await r.json<{ error: string; retry_at: number }>();
    expect(body.error).toBe("sync_switch_cooldown");
    expect(body.retry_at).toBe(now() - DAY + SYNC_SWITCH_COOLDOWN);

    // Picking the device that already syncs is a no-op, not a refusal.
    expect((await call(token, "POST", "/account/sync-device", { body: { device_id: "pc" } })).status).toBe(200);

    await E.DB.prepare("UPDATE accounts SET sync_device_at = ?2 WHERE account_id = ?1")
      .bind(acct, now() - SYNC_SWITCH_COOLDOWN - 1).run();
    expect((await call(token, "POST", "/account/sync-device", { body: { device_id: "phone" } })).status).toBe(200);
  });

  it("refuses an unknown or removed device", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["gone", DAY]] });
    await E.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE account_id = ?1 AND device_id = 'gone'")
      .bind(acct).run();
    for (const id of ["nope", "gone"]) {
      expect((await call(token, "POST", "/account/sync-device", { body: { device_id: id } })).status, id).toBe(404);
    }
    expect((await call(token, "POST", "/account/sync-device", { body: {} })).status).toBe(400);
  });

  it("works with the gate off, so apps can pick ahead of launch", async () => {
    const { acct, token } = await account({ devices: [["pc", 10], ["phone", DAY]] });
    const r = await call(token, "POST", "/account/sync-device", { body: { device_id: "phone" }, env: E });
    expect(r.status).toBe(200);
    expect((await syncDevice(acct)).sync_device).toBe("phone");
  });
});

describe("end-of-week email (syncWeekSweep)", () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  beforeEach(() => {
    fetchMock = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  const KEYED = { ...ON, RESEND_API_KEY: "re_test" };
  const stamp = async (acct: string) =>
    ((await E.DB.prepare("SELECT sync_email_at FROM accounts WHERE account_id = ?1").bind(acct).first()) as {
      sync_email_at: number | null;
    }).sync_email_at;
  // Also settles the kept device, as the first sync after the week would.
  async function withEmail(acct: string, email: string | null, kept = "pc") {
    await E.DB.prepare("UPDATE accounts SET email = ?2, sync_device = ?3 WHERE account_id = ?1")
      .bind(acct, email, kept).run();
  }

  it("mails a free account past its week that uses two devices, once", async () => {
    const { acct } = await account({ devices: [["pc", 10], ["phone", 3 * DAY]] });
    await withEmail(acct, "two@x.com");
    await syncWeekSweep(KEYED);
    await syncWeekSweep(KEYED);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const sent = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(sent.to).toBe("two@x.com");
    expect(sent.subject).toBe("Relic now syncs one of your devices");
    expect(sent.text).toContain("https://relic.space/upgrade?source=sync_week_email");
    expect(sent.text).not.toContain("—"); // no em dash
    expect(await stamp(acct)).toBeGreaterThan(0);
  });

  it("skips everyone the rule does not reach", async () => {
    const one = await account({ devices: [["pc", 10]] });
    const inWeek = await account({ age: 2 * DAY, devices: [["pc", 10], ["phone", 60]] });
    const graced = await account({ syncUntil: now() + 20 * DAY, devices: [["pc", 10], ["phone", 60]] });
    const stale = await account({ devices: [["pc", 10], ["old", 30 * DAY]] });
    const paid = await account({ tier: "pro", devices: [["pc", 10], ["phone", 60]] });
    const noMail = await account({ devices: [["pc", 10], ["phone", 60]] });
    for (const a of [one, inWeek, graced, stale, paid]) await withEmail(a.acct, `${a.acct}@x.com`);
    await withEmail(noMail.acct, null);
    await syncWeekSweep(KEYED);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("skips an account whose other devices are all on old apps, until one updates", async () => {
    const { acct } = await account({ devices: [["pc", 10], ["oldmac", 60, "1.0.60"], ["web", 60, null]] });
    await withEmail(acct, "old@x.com");
    await syncWeekSweep(KEYED);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await stamp(acct)).toBeNull();

    await E.DB.prepare("UPDATE devices SET app_version = '1.0.64+82' WHERE account_id = ?1 AND device_id = 'oldmac'")
      .bind(acct).run();
    await syncWeekSweep(KEYED);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("waits until the kept device is settled", async () => {
    const { acct } = await account({ devices: [["pc", 10], ["phone", 60]] });
    await E.DB.prepare("UPDATE accounts SET email = 'wait@x.com' WHERE account_id = ?1").bind(acct).run();
    await syncWeekSweep(KEYED);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sends nothing with the rule off or no Resend key", async () => {
    const { acct } = await account({ devices: [["pc", 10], ["phone", 60]] });
    await withEmail(acct, "off@x.com");
    await syncWeekSweep({ ...E, RESEND_API_KEY: "re_test" });
    await syncWeekSweep(ON);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await stamp(acct)).toBeNull();
  });

  it("tries again next tick when Resend refuses the key", async () => {
    fetchMock.mockImplementation(async () => new Response("no", { status: 401 }));
    const { acct } = await account({ devices: [["pc", 10], ["phone", 60]] });
    await withEmail(acct, "retry@x.com");
    await syncWeekSweep(KEYED);
    expect(await stamp(acct)).toBeNull();
  });
});
