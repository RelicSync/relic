import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker from "../src/index";
import { aiResultWins } from "../src/ai";
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

const claim = (tok: string, dev: string, items: Array<{ uid: string; level: number }>) =>
  call(tok, "POST", "/ai/claim", { device: dev, body: { items } });

const publish = (
  tok: string,
  dev: string,
  uid: string,
  o: { ai_at: number; level: number; ct?: string },
) =>
  call(tok, "PUT", `/ai/${uid}`, {
    device: dev,
    body: { v: 1, uid, ai_at: o.ai_at, level: o.level, n: "bm9uY2U=", ct: o.ct ?? "Y2lwaGVy" },
  });

const aiRow = (acct: string, uid: string) =>
  E.DB.prepare(
    "SELECT ai_at, ai_level, device_id, ct, claimed_by, claim_expires_at FROM ai_meta WHERE account_id = ?1 AND uid = ?2",
  ).bind(acct, uid).first();

beforeEach(async () => {
  await setupSchema(E.DB);
});

describe("AI work claim", () => {
  it("grants a uid to exactly one device", async () => {
    await seedToken("tk", "acct");
    const a = await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    const b = await claim("tk", "desktop-b", [{ uid: "u1", level: 3 }]);

    expect((await a.json<{ granted: string[] }>()).granted).toEqual(["u1"]);
    // The whole point: the second desktop gets nothing and must not run models.
    expect((await b.json<{ granted: string[] }>()).granted).toEqual([]);
  });

  it("splits a batch rather than giving one device everything", async () => {
    await seedToken("tk", "acct");
    // A holds u1 only; B should still win u2 and u3 from the same request.
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    const b = await claim("tk", "desktop-b", [
      { uid: "u1", level: 3 },
      { uid: "u2", level: 3 },
      { uid: "u3", level: 3 },
    ]);
    expect((await b.json<{ granted: string[] }>()).granted.sort()).toEqual(["u2", "u3"]);
  });

  it("re-granting to the same device is idempotent, so a restart resumes", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    const again = await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    expect((await again.json<{ granted: string[] }>()).granted).toEqual(["u1"]);
  });

  it("a peer picks up work whose lease expired", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    // Desktop A went to sleep mid-item. Age its lease past the deadline.
    await E.DB.prepare(
      "UPDATE ai_meta SET claim_expires_at = 1 WHERE account_id = 'acct' AND uid = 'u1'",
    ).run();

    const b = await claim("tk", "desktop-b", [{ uid: "u1", level: 3 }]);
    expect((await b.json<{ granted: string[] }>()).granted).toEqual(["u1"]);
  });

  it("release hands work back early, and cannot steal a peer's lease", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);

    // B trying to release A's lease must be a no-op.
    const steal = await call("tk", "POST", "/ai/release", {
      device: "desktop-b",
      body: { uids: ["u1"] },
    });
    expect((await steal.json<{ released: number }>()).released).toBe(0);
    expect((await claim("tk", "desktop-b", [{ uid: "u1", level: 3 }])
      .then((r) => r.json<{ granted: string[] }>())).granted).toEqual([]);

    // A releasing its own frees it immediately.
    const own = await call("tk", "POST", "/ai/release", {
      device: "desktop-a",
      body: { uids: ["u1"] },
    });
    expect((await own.json<{ released: number }>()).released).toBe(1);
    expect((await claim("tk", "desktop-b", [{ uid: "u1", level: 3 }])
      .then((r) => r.json<{ granted: string[] }>())).granted).toEqual(["u1"]);
  });

  it("reports finished work as done so a peer stops asking forever", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    await publish("tk", "desktop-a", "u1", { ai_at: 1000, level: 3 });

    const b = await claim("tk", "desktop-b", [{ uid: "u1", level: 3 }]);
    const body = await b.json<{ granted: string[]; done: Array<{ uid: string; level: number }> }>();
    expect(body.granted).toEqual([]);
    expect(body.done).toEqual([{ uid: "u1", level: 3 }]);
  });

  it("a newer model generation may redo work an older one finished", async () => {
    await seedToken("tk", "acct");
    await publish("tk", "desktop-a", "u1", { ai_at: 1000, level: 3 });
    // Desktop B has newer models: level 4 > the stored 3, so it gets the job.
    const b = await claim("tk", "desktop-b", [{ uid: "u1", level: 4 }]);
    expect((await b.json<{ granted: string[] }>()).granted).toEqual(["u1"]);
  });

  it("refuses to lease work to a device that will not identify itself", async () => {
    await seedToken("tk", "acct");
    const r = await claim("tk", "", [{ uid: "u1", level: 3 }]);
    expect(r.status).toBe(400);
  });

  it("one account cannot see or claim another's items", async () => {
    await seedToken("tkA", "acctA");
    await seedToken("tkB", "acctB");
    await claim("tkA", "dev-a", [{ uid: "u1", level: 3 }]);
    // Same uid, different account: a separate row entirely, so B still wins it.
    const b = await claim("tkB", "dev-b", [{ uid: "u1", level: 3 }]);
    expect((await b.json<{ granted: string[] }>()).granted).toEqual(["u1"]);
  });
});

describe("AI record publish + pull", () => {
  it("publishes, clears the lease, and pulls back", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    const put = await publish("tk", "desktop-a", "u1", { ai_at: 1000, level: 3, ct: "dGl0bGU=" });
    expect(await put.json()).toEqual({ stale: false });

    const row = await aiRow("acct", "u1");
    expect(row.claimed_by).toBeNull();
    expect(row.claim_expires_at).toBeNull();

    const list = await call("tk", "GET", "/ai?since=0", { device: "phone" });
    const { items } = await list.json<{ items: Array<Record<string, unknown>> }>();
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ v: 1, uid: "u1", ai_at: 1000, level: 3, ct: "dGl0bGU=" });
  });

  it("the pull cursor only returns records newer than since", async () => {
    await seedToken("tk", "acct");
    await publish("tk", "d", "u1", { ai_at: 1000, level: 3 });
    await publish("tk", "d", "u2", { ai_at: 2000, level: 3 });

    const list = await call("tk", "GET", "/ai?since=1000");
    const { items } = await list.json<{ items: Array<{ uid: string }> }>();
    expect(items.map((i) => i.uid)).toEqual(["u2"]);
  });

  it("clamps a junk or out-of-range limit on the AI cursor too", async () => {
    await seedToken("tk", "acct");
    await publish("tk", "d", "u1", { ai_at: 1000, level: 3 });
    await publish("tk", "d", "u2", { ai_at: 2000, level: 3 });
    // listAi interpolated `limit` into its SQL exactly like listRelics did.
    // Junk and over-large both fall back to the full page of 500...
    for (const q of ["limit=abc", "limit=99999"]) {
      const list = await call("tk", "GET", `/ai?since=0&${q}`);
      expect(list.status).toBe(200);
      const { items } = await list.json<{ items: Array<{ uid: string }> }>();
      expect(items.map((i) => i.uid)).toEqual(["u1", "u2"]);
    }
    // ...while zero and negative clamp UP to 1 rather than reaching SQL.
    for (const q of ["limit=0", "limit=-5"]) {
      const list = await call("tk", "GET", `/ai?since=0&${q}`);
      expect(list.status).toBe(200);
      const { items } = await list.json<{ items: Array<{ uid: string }> }>();
      expect(items.map((i) => i.uid)).toEqual(["u1"]);
    }
  });

  it("honours a limit of 1 and hands back the matching cursor", async () => {
    await seedToken("tk", "acct");
    await publish("tk", "d", "u1", { ai_at: 1000, level: 3 });
    await publish("tk", "d", "u2", { ai_at: 2000, level: 3 });
    const list = await call("tk", "GET", "/ai?since=0&limit=1");
    const page = await list.json<{ items: Array<{ uid: string }>; next_cursor: string }>();
    expect(page.items.map((i) => i.uid)).toEqual(["u1"]);
    expect(page.next_cursor).toBe("1000:u1");
  });

  it("a bare lease is never served as a record", async () => {
    await seedToken("tk", "acct");
    await claim("tk", "desktop-a", [{ uid: "u1", level: 3 }]);
    const list = await call("tk", "GET", "/ai?since=0");
    expect((await list.json<{ items: unknown[] }>()).items).toEqual([]);
  });

  it("a late result from an expired lease does not overwrite the one that landed", async () => {
    await seedToken("tk", "acct");
    // B finished first at t=1000. A was slow and publishes at t=2000.
    await publish("tk", "desktop-b", "u1", { ai_at: 1000, level: 3, ct: "Yg==" });
    const late = await publish("tk", "desktop-a", "u1", { ai_at: 2000, level: 3, ct: "YQ==" });

    expect(await late.json()).toEqual({ stale: true });
    // The title the user is already looking at stays put.
    expect((await aiRow("acct", "u1")).ct).toBe("Yg==");
  });

  it("a genuine model upgrade does overwrite", async () => {
    await seedToken("tk", "acct");
    await publish("tk", "desktop-b", "u1", { ai_at: 1000, level: 3, ct: "b2xk" });
    const up = await publish("tk", "desktop-a", "u1", { ai_at: 2000, level: 4, ct: "bmV3" });
    expect(await up.json()).toEqual({ stale: false });
    expect((await aiRow("acct", "u1")).ct).toBe("bmV3");
  });

  it("rejects a malformed record and a uid mismatch", async () => {
    await seedToken("tk", "acct");
    const bad = await call("tk", "PUT", "/ai/u1", {
      device: "d",
      body: { v: 1, uid: "u2", ai_at: 1, level: 3, n: "x", ct: "y" },
    });
    expect(bad.status).toBe(400);

    const missing = await call("tk", "PUT", "/ai/u1", {
      device: "d",
      body: { v: 1, uid: "u1", ai_at: 1, level: 3 },
    });
    expect(missing.status).toBe(400);
  });

  it("caps record size so ai_meta cannot be used as free storage", async () => {
    await seedToken("tk", "acct");
    const r = await publish("tk", "d", "u1", { ai_at: 1, level: 3, ct: "A".repeat(50_000) });
    expect(r.status).toBe(413);
  });

  it("accepts a record carrying a full document's extracted text", async () => {
    // The cap has to clear what the client actually sends: 24 KiB of text,
    // plus JSON, plus the seal, plus base64. A record refused here is dropped
    // rather than retried, so a document whose text is within the client's own
    // budget must never bounce.
    await seedToken("tk", "acct");
    const r = await publish("tk", "d", "u1", {
      ai_at: 1,
      level: 3,
      ct: "A".repeat(Math.ceil((24 * 1024 + 512) * 1.34)),
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ stale: false });
  });

  it("a device may republish its own record with more in it", async () => {
    // The attachment-text pass finishes after the models do, so the owner comes
    // back to the same record with the other half of the answer. A peer's late
    // publish is still refused (that is the test above); this is not that.
    await seedToken("tk", "acct");
    await publish("tk", "desk-a", "u1", { ai_at: 1000, level: 3, ct: "Zmlyc3Q=" });
    const again = await publish("tk", "desk-a", "u1", {
      ai_at: 1000,
      level: 3,
      ct: "ZnVsbGVy",
    });

    expect(await again.json()).toEqual({ stale: false });
    expect(await aiRow("acct", "u1")).toMatchObject({ ct: "ZnVsbGVy" });
  });

  it("a deleted relic does not sprout an AI record", async () => {
    await seedToken("tk", "acct");
    await E.DB.prepare(
      "INSERT INTO tombstones (account_id, uid, deleted_at) VALUES ('acct','u1',5)",
    ).run();
    const r = await publish("tk", "d", "u1", { ai_at: 1000, level: 3 });
    expect(await r.json()).toEqual({ stale: true });
    expect(await aiRow("acct", "u1")).toBeNull();
  });

  it("deleting a relic drops its AI record", async () => {
    await seedToken("tk", "acct");
    await E.DB.prepare(
      `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted)
       VALUES ('acct','u1',1,1,10,1)`,
    ).run();
    await publish("tk", "d", "u1", { ai_at: 1000, level: 3 });
    expect(await aiRow("acct", "u1")).not.toBeNull();

    await call("tk", "DELETE", "/relic/u1?deleted_at=9");
    expect(await aiRow("acct", "u1")).toBeNull();
  });
});

// The rule is subtle enough to be worth testing directly, apart from the HTTP
// surface: it is what decides whether a title the user is looking at is allowed
// to change.
describe("aiResultWins", () => {
  const at = (ai_at: number, ai_level: number, device_id = "d") => ({ ai_at, ai_level, device_id });

  it("accepts anything when nothing is stored", () => {
    expect(aiResultWins(at(1, 0), null)).toBe(true);
    expect(aiResultWins(at(1, 0), { ai_at: null, ai_level: null, device_id: "x" })).toBe(true);
  });

  it("prefers a higher level even when it is older", () => {
    expect(aiResultWins(at(500, 4), { ai_at: 1000, ai_level: 3, device_id: "x" })).toBe(true);
  });

  it("never downgrades to an older level", () => {
    expect(aiResultWins(at(9999, 2), { ai_at: 1000, ai_level: 3, device_id: "x" })).toBe(false);
  });

  it("at equal level the earliest result stands", () => {
    expect(aiResultWins(at(900, 3), { ai_at: 1000, ai_level: 3, device_id: "x" })).toBe(true);
    expect(aiResultWins(at(1100, 3), { ai_at: 1000, ai_level: 3, device_id: "x" })).toBe(false);
  });

  it("breaks an exact tie deterministically, so devices converge", () => {
    // Same instant, same level: both devices must reach the SAME answer about
    // which wins, or they trade writes forever.
    const a = at(1000, 3, "aaa");
    const b = at(1000, 3, "bbb");
    expect(aiResultWins(a, { ai_at: 1000, ai_level: 3, device_id: "bbb" })).toBe(true);
    expect(aiResultWins(b, { ai_at: 1000, ai_level: 3, device_id: "aaa" })).toBe(false);
  });

  it("lets a device amend its own record with its latest word", () => {
    // The halves of a record are produced by passes that finish at different
    // times: the models caption an item, and a separate model-free pass reads
    // its attachments once their bytes are local. Without this the second half
    // could never be published — at equal level the earlier record wins, and
    // the record is its own predecessor.
    const stored = { ai_at: 1000, ai_level: 3, device_id: "d" };
    expect(aiResultWins(at(1000, 3, "d"), stored)).toBe(true);
    expect(aiResultWins(at(1200, 3, "d"), stored)).toBe(true);
  });

  it("does not let even the owner walk its record backwards", () => {
    const stored = { ai_at: 1000, ai_level: 3, device_id: "d" };
    expect(aiResultWins(at(800, 3, "d"), stored)).toBe(false);
  });

  it("an unidentified client cannot pass itself off as the owner", () => {
    // Otherwise anything without a device header would inherit the amend right
    // over every record that also lacks one.
    const stored = { ai_at: 1000, ai_level: 3, device_id: "" };
    expect(aiResultWins(at(1200, 3, ""), stored)).toBe(false);
  });
});
