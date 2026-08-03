-- Migration 0002: device registry (docs/cloudflare/13-device-onboarding.md §7,
-- 04-auth.md §4.2). Backs the settings "your devices" list + remote-remove on the
-- stateless-JWT model. device_id is client-generated (UUID) and stored locally on
-- each device; remote-remove sets revoked_at and parks the id in the KV `rev:` set
-- so the hot path can hard-reject it (for requests that carry X-Relic-Device).
--
-- Apply BEFORE deploying the device routes:
--   wrangler d1 execute relic --file=migrations/0002_device_registry.sql          (local dev)
--   wrangler d1 execute relic --remote --file=migrations/0002_device_registry.sql (production)
CREATE TABLE IF NOT EXISTS devices (
    account_id   TEXT NOT NULL,
    device_id    TEXT NOT NULL,                 -- client-generated UUID
    label        TEXT,                          -- "Jordan's Pixel 8"
    platform     TEXT,                          -- windows|macos|linux|android|ios|web|cli
    created_at   INTEGER NOT NULL DEFAULT (unixepoch()),
    last_seen_at INTEGER NOT NULL DEFAULT (unixepoch()),
    revoked_at   INTEGER,                        -- NULL = active
    PRIMARY KEY (account_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
