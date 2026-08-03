// POST /enroll — the account-less, passphrase-only device enrollment endpoint.
//
// Model (see selfhost/README.md): the whole instance is a single "space" owned
// by one person/household. There are no accounts and no server-side passphrase.
// The client derives, from the user's passphrase, TWO domain-separated values:
//   - an auth token   (what it sends as the Bearer here and on every sync call)
//   - a vault key      (used only client-side to encrypt/decrypt; never sent)
// The server only ever sees the auth token, and only stores sha256(auth token)
// in the existing `tokens` table (exactly what authenticate() looks up). It
// never sees the passphrase or the vault key, so it holds only ciphertext.
//
// Trust-on-first-use: the first enroll claims the instance and stores the token
// hash. Later devices present the same passphrase -> same auth token -> same
// hash -> recognized (idempotent). A wrong passphrase yields a different hash,
// which is rejected. Set RELIC_ENROLL_SECRET to additionally gate that very
// first enroll (belt-and-suspenders against someone reaching a fresh instance
// before you do).

import crypto from "node:crypto";
import type Database from "better-sqlite3";

const ACCOUNT_ID = "selfhost"; // single-tenant: one space per instance
const TIER = "max"; // effectively-unlimited caps for a personal vault

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,PUT,POST,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type,X-Relic-Device,X-Relic-App-Version",
};
const reply = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const sha256Hex = (s: string) => crypto.createHash("sha256").update(s).digest("hex");

interface EnrollBody {
  device_id?: string;
  label?: string;
  platform?: string;
  app_version?: string;
  enroll_secret?: string;
}

export async function handleEnroll(req: Request, db: Database.Database): Promise<Response> {
  const header = req.headers.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) return reply({ error: "unauthorized", message: "missing bearer token" }, 401);
  const token = header.slice(7);
  if (!token) return reply({ error: "unauthorized", message: "empty token" }, 401);

  let body: EnrollBody = {};
  try {
    body = (await req.json()) as EnrollBody;
  } catch {
    /* body is optional */
  }

  const hash = sha256Hex(token);
  const count = (db.prepare("SELECT COUNT(*) AS n FROM tokens").get() as { n: number }).n;

  if (count === 0) {
    const secret = process.env.RELIC_ENROLL_SECRET;
    if (secret && body.enroll_secret !== secret) {
      return reply({ error: "forbidden", message: "bad enrollment secret" }, 403);
    }
    db.prepare("INSERT INTO tokens (token_hash, account_id, tier) VALUES (?, ?, ?)").run(hash, ACCOUNT_ID, TIER);
  } else {
    const row = db.prepare("SELECT 1 FROM tokens WHERE token_hash = ? AND revoked = 0").get(hash);
    if (!row) {
      return reply({ error: "forbidden", message: "wrong passphrase for this server" }, 403);
    }
  }

  // Register the device so the app's Devices screen works (best-effort).
  if (typeof body.device_id === "string" && body.device_id && body.device_id.length <= 64) {
    const now = Math.floor(Date.now() / 1000);
    const appVer = typeof body.app_version === "string" ? body.app_version.slice(0, 32) : null;
    db.prepare(
      `INSERT INTO devices (account_id, device_id, label, platform, created_at, last_seen_at, app_version)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(account_id, device_id) DO UPDATE SET
         label = excluded.label, platform = excluded.platform,
         last_seen_at = excluded.last_seen_at, revoked_at = NULL,
         app_version = COALESCE(excluded.app_version, app_version)`,
    ).run(ACCOUNT_ID, body.device_id, body.label ?? null, body.platform ?? null, now, now, appVer);
  }

  return reply({ ok: true, account_id: ACCOUNT_ID, tier: TIER });
}
