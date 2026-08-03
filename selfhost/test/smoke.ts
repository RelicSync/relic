// In-process smoke test: drives the unchanged worker.fetch() through the local
// adapters, round-tripping the core sync data plane. No HTTP, no network — this
// verifies the adapters faithfully stand in for D1/R2/KV. Run: npm run smoke.
//
// Exits non-zero on the first failed assertion so CI can gate on it.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import Database from "better-sqlite3";

import * as workerModule from "../../worker/src/index";
import { makeEnv } from "../src/adapters/env";
import { handleEnroll } from "../src/enroll";

function pickHandler(m: any): any {
  let cur = m;
  for (let i = 0; i < 6 && cur; i++) {
    if (typeof cur.fetch === "function") return cur;
    cur = cur.default;
  }
  throw new Error("worker handler with fetch() not found");
}
const worker: any = pickHandler(workerModule);

let failures = 0;
function check(cond: unknown, msg: string) {
  if (cond) {
    console.log("  ok  -", msg);
  } else {
    console.error("  FAIL-", msg);
    failures++;
  }
}

const TOKEN = "smoke-secret-token-value";
const DEVICE = "dev-smoke-1";
const UID = "item-0001";
const BLOB = "blob-0001";

function authed(method: string, p: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {
    authorization: "Bearer " + TOKEN,
    "x-relic-device": DEVICE,
  };
  let b: BodyInit | undefined;
  if (body !== undefined) {
    if (typeof body === "string" || body instanceof Uint8Array) {
      b = body as BodyInit;
    } else {
      b = JSON.stringify(body);
      headers["content-type"] = "application/json";
    }
  }
  return worker.fetch(new Request("http://local" + p, { method, headers, body: b }), env);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "relic-smoke-"));
const db = new Database(path.join(tmp, "relic.db"));
db.pragma("journal_mode = WAL");
const schemaSql = fs.readFileSync(path.resolve(import.meta.dirname, "../../worker/schema.sql"), "utf8");
db.exec(schemaSql);
const env = makeEnv(db, path.join(tmp, "blobs"));

const run = async () => {
  console.log("relic self-host smoke test  (data:", tmp + ")");

  // --- enroll (TOFU) ---
  const enroll = await handleEnroll(
    new Request("http://local/enroll", {
      method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE, platform: "smoke" }),
    }),
    db,
  );
  const enrollJson = (await enroll.json()) as any;
  check(enroll.status === 200 && enrollJson.ok === true, "enroll succeeds (first = TOFU claim)");
  check(enrollJson.tier === "max", "enrolled token gets max (effectively-unlimited) tier");

  // Wrong passphrase after claim must be rejected.
  const badEnroll = await handleEnroll(
    new Request("http://local/enroll", {
      method: "POST",
      headers: { authorization: "Bearer wrong-passphrase-token", "content-type": "application/json" },
      body: "{}",
    }),
    db,
  );
  check(badEnroll.status === 403, "wrong passphrase is rejected (403)");

  // Same passphrase again = idempotent ok (a second device).
  const reEnroll = await handleEnroll(
    new Request("http://local/enroll", {
      method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ device_id: "dev-smoke-2", platform: "smoke" }),
    }),
    db,
  );
  check(reEnroll.status === 200, "same passphrase re-enrolls a second device");

  // --- unauthenticated request is rejected ---
  const noAuth = await worker.fetch(new Request("http://local/relics?since=0"), env);
  check(noAuth.status === 401, "missing bearer -> 401");

  // --- PUT relic ---
  const envelope = {
    v: 1,
    uid: UID,
    created_at: 1000,
    updated_at: 2000,
    byte_size: 50,
    promoted: false,
    n: "nonce-abc",
    ct: "ciphertext-payload",
  };
  const put = await authed("PUT", "/relic/" + UID, envelope);
  const putJson = (await put.json()) as any;
  check(put.status === 200 && putJson.stale === false, "PUT /relic stores a fresh envelope");

  // Stale re-push (same/older updated_at) is a no-op.
  const putStale = await authed("PUT", "/relic/" + UID, envelope);
  check(((await putStale.json()) as any).stale === true, "re-PUT of same version reports stale");

  // --- GET relics (list) ---
  const list = await authed("GET", "/relics?since=0");
  const listJson = (await list.json()) as any;
  check(
    list.status === 200 && listJson.items.length === 1 && listJson.items[0].uid === UID,
    "GET /relics returns the stored item",
  );
  check(listJson.items[0].ct === "ciphertext-payload", "listed envelope round-trips byte-faithfully");

  // --- keyparams ---
  const kpPut = await authed("PUT", "/keyparams", '{"kdf":"argon2id","salt":"AAAA"}');
  check(kpPut.status === 200, "PUT /keyparams stores wrapped key params");
  const kpGet = await authed("GET", "/keyparams");
  const kpJson = (await kpGet.json()) as any;
  check(kpGet.status === 200 && kpJson.kdf === "argon2id", "GET /keyparams returns them");
  // Overwrite without ?replace=1 is refused.
  const kpConflict = await authed("PUT", "/keyparams", "{}");
  check(kpConflict.status === 409, "PUT /keyparams without replace=1 -> 409");

  // --- blob single-shot ---
  const blobBytes = new Uint8Array([104, 101, 108, 108, 111, 45, 98, 108, 111, 98]); // "hello-blob"
  const blobPut = await authed("POST", "/blob?id=" + BLOB, blobBytes);
  const blobPutJson = (await blobPut.json()) as any;
  check(blobPut.status === 200 && blobPutJson.key === BLOB, "POST /blob stores ciphertext");
  const blobGet = await authed("GET", "/blob/" + BLOB);
  const gotBytes = new Uint8Array(await blobGet.arrayBuffer());
  check(
    blobGet.status === 200 && Buffer.from(gotBytes).equals(Buffer.from(blobBytes)),
    "GET /blob returns identical bytes",
  );

  // --- account usage ---
  const acct = await authed("GET", "/account");
  const acctJson = (await acct.json()) as any;
  check(acct.status === 200 && acctJson.tier === "max", "GET /account reports max tier");

  // --- devices ---
  const devs = await authed("GET", "/account/devices");
  const devsJson = (await devs.json()) as any;
  check(devsJson.devices.length === 2, "both enrolled devices are registered");

  // --- delete + tombstone ---
  const del = await authed("DELETE", "/relic/" + UID + "?deleted_at=3000");
  check(del.status === 200, "DELETE /relic succeeds");
  const tombs = await authed("GET", "/tombstones?since=0");
  const tombsJson = (await tombs.json()) as any;
  check(
    tombsJson.items.some((t: any) => t.uid === UID),
    "deleted item appears in /tombstones",
  );
  const listAfter = await authed("GET", "/relics?since=0");
  check(((await listAfter.json()) as any).items.length === 0, "deleted item no longer listed");

  // --- health ---
  const health = await worker.fetch(new Request("http://local/health"), env);
  check(health.status === 200 && ((await health.json()) as any).ok === true, "GET /health is green");

  console.log("");
  if (failures) {
    console.error(`SMOKE FAILED: ${failures} assertion(s) failed`);
    process.exit(1);
  } else {
    console.log("SMOKE PASSED");
    process.exit(0);
  }
};

run().catch((e) => {
  console.error("smoke crashed:", e);
  process.exit(1);
});
