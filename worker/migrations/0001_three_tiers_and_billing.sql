-- Migration 0001: 2-tier (free/paid) -> 3-tier (free/pro/max) + auth/billing
-- tables. Apply to the EXISTING production D1 once, BEFORE deploying the 3-tier
-- Worker (the new code has no 'paid' entry in TIERS and would fault on a 'paid'
-- token). Idempotent enough to re-run: the CREATEs use IF NOT EXISTS and the
-- token rebuild is a no-op if already on the new shape.
--
--   wrangler d1 execute relic --remote --file=migrations/0001_three_tiers_and_billing.sql
--
-- (drop --remote to apply to the local dev DB first.)

-- 1. Rebuild `tokens` to swap the CHECK constraint (SQLite can't ALTER a CHECK
--    in place) AND map legacy 'paid' -> 'pro' in the same copy. Doing the rename
--    during the copy avoids violating the OLD check (which forbade 'pro'). Old
--    paid caps (item 50MB, blob 25GB) map cleanly onto pro (item 100MB, 25GB);
--    bump specific accounts to 'max' by hand afterwards if needed.
PRAGMA foreign_keys=OFF;
CREATE TABLE IF NOT EXISTS tokens_new (
    token_hash   TEXT PRIMARY KEY,
    account_id   TEXT NOT NULL,
    device_label TEXT,
    tier         TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    revoked      INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL DEFAULT (unixepoch())
);
INSERT INTO tokens_new (token_hash, account_id, device_label, tier, revoked, created_at)
    SELECT token_hash, account_id, device_label,
           CASE WHEN tier = 'paid' THEN 'pro' ELSE tier END,
           revoked, created_at
    FROM tokens;
DROP TABLE tokens;
ALTER TABLE tokens_new RENAME TO tokens;
CREATE INDEX IF NOT EXISTS idx_tokens_account ON tokens(account_id);
PRAGMA foreign_keys=ON;

-- 3. New identity + billing tables.
CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY,
    email      TEXT,
    tier       TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS subscriptions (
    account_id             TEXT PRIMARY KEY,
    stripe_customer_id     TEXT,
    stripe_subscription_id TEXT,
    tier                   TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    status                 TEXT NOT NULL DEFAULT 'none',
    current_period_end     INTEGER,
    cancel_at_period_end   INTEGER NOT NULL DEFAULT 0,
    grace_until            INTEGER,
    updated_stripe_ts      INTEGER NOT NULL DEFAULT 0,
    updated_at             INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_sub_customer ON subscriptions(stripe_customer_id);

CREATE TABLE IF NOT EXISTS billing_events (
    event_id     TEXT PRIMARY KEY,
    type         TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    processed_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- 4. Seed accounts rows for existing legacy-token accounts so authenticate()'s
--    JWT path (once users link Supabase) and /account reads have a home. Tier
--    carried over from their token.
INSERT OR IGNORE INTO accounts (account_id, tier)
    SELECT account_id, tier FROM tokens;
