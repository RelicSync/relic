-- Cached per-account totals, so quota checks stop scanning relic_meta.
--
-- The storage cap is enforced on every relic push and every blob upload, and it
-- was a SUM over all of an account's rows each time; the vault cap was a second
-- scan on top. That made D1 rows-read scale as `writes x vault size`, which was
-- our largest D1 line item and got worse as vaults grew.
--
-- No backfill: a missing row means "not computed yet", so src/usage.ts falls
-- back to the scan on first touch and seeds the row inside the same batch as the
-- write. Existing accounts heal themselves on their next write, in one query.

CREATE TABLE IF NOT EXISTS account_usage (
    account_id  TEXT PRIMARY KEY,
    bytes_used  INTEGER NOT NULL,
    vault_count INTEGER NOT NULL
);

-- Covers the seed scan end to end (SUM(byte_size) + SUM(promoted) filtered by
-- account_id), so the fallback reads index entries only and never the table.
CREATE INDEX IF NOT EXISTS idx_meta_usage ON relic_meta(account_id, byte_size, promoted);
