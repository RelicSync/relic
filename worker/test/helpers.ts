import type { D1Database } from "@cloudflare/workers-types";

/// Create the tables the tests touch. Mirrors schema.sql (kept inline so tests
/// don't depend on multi-statement exec). Run in beforeEach for a clean DB.
const DDL = [
  `CREATE TABLE IF NOT EXISTS tokens (
     token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL, device_label TEXT,
     tier TEXT NOT NULL DEFAULT 'free', revoked INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
  `CREATE TABLE IF NOT EXISTS accounts (
     account_id TEXT PRIMARY KEY, email TEXT,
     tier TEXT NOT NULL DEFAULT 'free', created_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
  `CREATE TABLE IF NOT EXISTS subscriptions (
     account_id TEXT PRIMARY KEY, stripe_customer_id TEXT, stripe_subscription_id TEXT,
     tier TEXT NOT NULL DEFAULT 'free', status TEXT NOT NULL DEFAULT 'none',
     current_period_end INTEGER, cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
     grace_until INTEGER, updated_stripe_ts INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
  `CREATE TABLE IF NOT EXISTS billing_events (
     event_id TEXT PRIMARY KEY, type TEXT NOT NULL, created_at INTEGER NOT NULL,
     processed_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
  `CREATE TABLE IF NOT EXISTS devices (
     account_id TEXT NOT NULL, device_id TEXT NOT NULL, label TEXT, platform TEXT,
     created_at INTEGER NOT NULL DEFAULT (unixepoch()),
     last_seen_at INTEGER NOT NULL DEFAULT (unixepoch()), revoked_at INTEGER,
     app_version TEXT,
     PRIMARY KEY (account_id, device_id))`,
  `CREATE TABLE IF NOT EXISTS relic_meta (
     account_id TEXT NOT NULL, uid TEXT NOT NULL, created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL, byte_size INTEGER NOT NULL, promoted INTEGER NOT NULL,
     blob_key TEXT, PRIMARY KEY (account_id, uid))`,
  `CREATE TABLE IF NOT EXISTS tombstones (
     account_id TEXT NOT NULL, uid TEXT NOT NULL, deleted_at INTEGER NOT NULL,
     PRIMARY KEY (account_id, uid))`,
  `CREATE TABLE IF NOT EXISTS shares (
     id TEXT PRIMARY KEY, account_id TEXT NOT NULL,
     created_at INTEGER NOT NULL DEFAULT (unixepoch()), expires_at INTEGER NOT NULL,
     max_views INTEGER, views INTEGER NOT NULL DEFAULT 0, byte_size INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS sweep_state (
     k TEXT PRIMARY KEY, v TEXT NOT NULL,
     updated_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
  `CREATE TABLE IF NOT EXISTS account_links (
     supabase_sub TEXT PRIMARY KEY, account_id TEXT NOT NULL,
     created_at INTEGER NOT NULL DEFAULT (unixepoch()))`,
];

const TABLES = [
  "tokens", "accounts", "subscriptions", "billing_events",
  "devices", "relic_meta", "tombstones", "shares", "sweep_state",
  "account_links",
];

export async function setupSchema(db: D1Database): Promise<void> {
  // Drop first so each test starts clean.
  for (const t of TABLES) await db.prepare(`DROP TABLE IF EXISTS ${t}`).run();
  for (const stmt of DDL) await db.prepare(stmt).run();
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
