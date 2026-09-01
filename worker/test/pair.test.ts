import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker from "../src/index";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;
// No Supabase configured in the test env, so authenticate() uses the legacy
// device-token path. Seed a token per account.
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
  opts: { body?: unknown; device?: string } = {},
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
    E,
  );
}

// The per-account session-revocation stamp (migrations/0009). Reads 0, never
// null, for an account that has never had a device removed.
async function watermark(account: string): Promise<number> {
  const r = await E.DB.prepare(
    "SELECT min_valid_iat FROM accounts WHERE account_id = ?1",
  ).bind(account).first<{ min_valid_iat: number }>();
  return r?.min_valid_iat ?? 0;
}

beforeEach(async () => {
  await setupSchema(E.DB);
  await seedToken("tokA", "acctA");
  await seedToken("tokB", "acctB");
  // Legacy device tokens never create an accounts row, and the DELETE handler
  // only UPDATEs one, so seed both accounts explicitly.
  await E.DB.prepare(
    "INSERT OR IGNORE INTO accounts (account_id) VALUES ('acctA'), ('acctB')",
  ).run();
});

describe("pairing relay", () => {
  it("start mints a pairing id; offer/poll round-trips; claim is single-use", async () => {
    const start = await call("tokA", "POST", "/pair/start");
    expect(start.status).toBe(200);
    const { pairing_id } = await start.json<{ pairing_id: string }>();
    expect(pairing_id).toMatch(/^[0-9a-fA-F-]{8,40}$/);

    const offer = await call("tokA", "POST", "/pair/offer", {
      body: { pairing_id, slot: "np", blob: "QUJD" },
    });
    expect(offer.status).toBe(204);

    const poll = await call("tokA", "GET", `/pair/poll?pairing_id=${pairing_id}&slot=np`);
    expect(poll.status).toBe(200);
    expect((await poll.json<{ blob: string }>()).blob).toBe("QUJD");

    // Non-consuming poll leaves it; claim consumes it.
    const claim1 = await call("tokA", "GET", `/pair/claim?pairing_id=${pairing_id}&slot=np`);
    expect((await claim1.json<{ blob: string }>()).blob).toBe("QUJD");
    const claim2 = await call("tokA", "GET", `/pair/claim?pairing_id=${pairing_id}&slot=np`);
    expect(claim2.status).toBe(204); // single-use: gone
  });

  it("is account-scoped: another account cannot read the slot", async () => {
    const start = await call("tokA", "POST", "/pair/start");
    const { pairing_id } = await start.json<{ pairing_id: string }>();
    await call("tokA", "POST", "/pair/offer", {
      body: { pairing_id, slot: "mk", blob: "U0VDUkVU" },
    });
    // acctB guesses the pairing_id but the KV key embeds the account → 204.
    const other = await call("tokB", "GET", `/pair/poll?pairing_id=${pairing_id}&slot=mk`);
    expect(other.status).toBe(204);
  });

  it("rejects bad slots and oversized blobs", async () => {
    const start = await call("tokA", "POST", "/pair/start");
    const { pairing_id } = await start.json<{ pairing_id: string }>();
    const badSlot = await call("tokA", "POST", "/pair/offer", {
      body: { pairing_id, slot: "xx", blob: "QQ" },
    });
    expect(badSlot.status).toBe(400);
    const big = await call("tokA", "POST", "/pair/offer", {
      body: { pairing_id, slot: "np", blob: "Q".repeat(9000) },
    });
    expect(big.status).toBe(400);
  });
});

describe("device registry", () => {
  it("registers, lists, and marks this_device", async () => {
    const reg = await call("tokA", "POST", "/account/devices", {
      body: { device_id: "dev-1", label: "Pixel", platform: "android" },
    });
    expect(reg.status).toBe(200);
    const list = await call("tokA", "GET", "/account/devices", { device: "dev-1" });
    const { devices } = await list.json<{ devices: Array<{ device_id: string; this_device: boolean }> }>();
    expect(devices).toHaveLength(1);
    expect(devices[0]).toMatchObject({ device_id: "dev-1", this_device: true });
  });

  it("enforces the free-tier device cap with an actionable 409", async () => {
    for (const id of ["d1", "d2", "d3"]) {
      const r = await call("tokA", "POST", "/account/devices", { body: { device_id: id } });
      expect(r.status).toBe(200);
    }
    const over = await call("tokA", "POST", "/account/devices", { body: { device_id: "d4" } });
    expect(over.status).toBe(409);
    const j = await over.json<{ error: string; devices: unknown[] }>();
    expect(j.error).toBe("device_cap");
    expect(j.devices).toHaveLength(3); // handed back so the UI can offer remove/upgrade
  });

  it("removing a device hard-rejects it only when the header is present", async () => {
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone" } });
    const del = await call("tokA", "DELETE", "/account/devices/gone");
    expect(del.status).toBe(200);

    // A request labeled as the removed device is rejected (guard runs in
    // authenticate(), before any route — so any authed path 401s).
    const blocked = await call("tokA", "GET", "/account/devices", { device: "gone" });
    expect(blocked.status).toBe(401);
    // The same LEGACY credential without the header still works. That is the
    // hole min_valid_iat closes for Supabase sessions (migrations/0009);
    // legacy device tokens carry no iat and stay grandfathered here.
    const ok = await call("tokA", "GET", "/account/devices");
    expect(ok.status).toBe(200);

    // Re-registering heals the revoke.
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone" } });
    const healed = await call("tokA", "GET", "/account/devices", { device: "gone" });
    expect(healed.status).toBe(200);
  });

  it("removing a device stamps the account's session watermark", async () => {
    const before = Math.floor(Date.now() / 1000);
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone2" } });
    expect(await watermark("acctA")).toBe(0);

    expect((await call("tokA", "DELETE", "/account/devices/gone2")).status).toBe(200);
    const stamped = await watermark("acctA");
    expect(stamped).toBeGreaterThanOrEqual(before);

    // Only this account. A sibling account must not be signed out.
    expect(await watermark("acctB")).toBe(0);
  });

  it("the watermark is monotone and survives re-registration", async () => {
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone3" } });
    await call("tokA", "DELETE", "/account/devices/gone3");
    const first = await watermark("acctA");
    expect(first).toBeGreaterThan(0);

    // A clock that jumped backwards must not be able to lower the watermark.
    await E.DB.prepare("UPDATE accounts SET min_valid_iat = ?2 WHERE account_id = ?1")
      .bind("acctA", first + 10_000).run();
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone3" } });
    await call("tokA", "DELETE", "/account/devices/gone3");
    expect(await watermark("acctA")).toBe(first + 10_000);

    // Re-registering heals the KV `rev:` marker but never clears the stamp.
    await call("tokA", "POST", "/account/devices", { body: { device_id: "gone3" } });
    expect(await watermark("acctA")).toBe(first + 10_000);
  });
});
