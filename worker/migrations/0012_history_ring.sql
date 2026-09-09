-- History ring: soft-evict text instead of deleting it, and count the ring.
--
-- The free plan shows the last N unpromoted copies (TIERS.free.ring). Until now
-- the oldest ones past that line were deleted outright, so the only thing we
-- could ever tell the user was "those are gone". A sealed text envelope is about
-- a kilobyte, so keeping them costs nothing worth measuring, and it turns the
-- message into "these are waiting for you".
--
-- relic_meta.evicted = 1 means "past the free ring": the row and its R2 envelope
-- stay, free pulls skip it, and paying flips it back. Rows with a blob keep the
-- old hard delete, because blob bytes are the only real storage cost.
--
-- The four account_usage columns keep the numbers off the request path, the same
-- way bytes_used and vault_count already do (see 0008).
--   history_count  live count of promoted = 0 AND evicted = 0 rows
--   evicted_count  live count of evicted = 1 rows, what the client shows
--   ring_evicted   lifetime count of rows the ring pushed out, never decremented
--   ring_email_at  unix seconds the nudge email went out, NULL = never
--
-- Numbering: 0009 is a permanent gap (see 0011). This follows 0011.

ALTER TABLE relic_meta ADD COLUMN evicted INTEGER NOT NULL DEFAULT 0;

-- The prune's own query: oldest unpromoted, not-yet-evicted rows by age.
CREATE INDEX IF NOT EXISTS idx_meta_ring
    ON relic_meta(account_id, promoted, evicted, created_at);

-- The account_usage seed scan now counts evicted rows too, so the index that
-- covered it end to end has to carry the new column or the scan starts reading
-- the table again. Rebuilt rather than duplicated (0008 has the rationale).
DROP INDEX IF EXISTS idx_meta_usage;
CREATE INDEX IF NOT EXISTS idx_meta_usage
    ON relic_meta(account_id, byte_size, promoted, evicted);

ALTER TABLE account_usage ADD COLUMN history_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account_usage ADD COLUMN evicted_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account_usage ADD COLUMN ring_evicted  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account_usage ADD COLUMN ring_email_at INTEGER;

-- One-time backfill of the live counter for accounts that already have a cached
-- row. Nothing is evicted yet, so history_count is just the unpromoted count and
-- evicted_count stays 0. This is a full scan, which is fine here: it runs once,
-- in the migration, off the request path.
UPDATE account_usage SET history_count = (
    SELECT COUNT(*) FROM relic_meta m
     WHERE m.account_id = account_usage.account_id AND m.promoted = 0
);
