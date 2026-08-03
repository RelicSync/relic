-- E2EE share links (src/share.ts): D1 holds the metadata row, R2 holds the
-- ciphertext at shares/<id>. max_views NULL = unlimited until expiry; the
-- cron sweep reaps expired-or-consumed rows (R2 object first).
--
-- Apply:
--   wrangler d1 execute relic --remote --file=migrations/0003_shares.sql

CREATE TABLE IF NOT EXISTS shares (
    id         TEXT PRIMARY KEY,          -- client-minted, ^[A-Za-z0-9_-]{22}$
    account_id TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    max_views  INTEGER,                   -- NULL = unlimited until expiry
    views      INTEGER NOT NULL DEFAULT 0,
    byte_size  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_shares_account ON shares(account_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_shares_expiry  ON shares(expires_at);
