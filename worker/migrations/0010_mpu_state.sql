-- In-flight multipart uploads, so abandoned ones stop being invisible.
--
-- Two holes this closes, both specific to R2 multipart:
--
-- 1. ABANDONED UPLOADS ARE UNSWEEPABLE. A client that dies mid-upload leaves
--    parts in R2 that STORE.list() never returns, so sweepOrphanBlobs cannot
--    see them and no sweep touches them. They are billed forever. The bucket
--    lifecycle rule (docs/setup/02-cloudflare.md) is cited as the backstop but
--    has never been verified, so src/sweep.ts now aborts them itself.
--
-- 2. CONCURRENT MPUs BYPASS THE QUOTA. mpuCreate checked declared_size against
--    account_usage, which only counts COMPLETED bytes. Ten parallel creates
--    each saw the same empty account and each passed, so the effective cap was
--    the cap times the concurrency. declared_size is now reserved here and
--    summed into that check.
--
-- Keyed on all three ids because one blob key can legitimately have more than
-- one upload in flight (a retry after a stalled attempt).
CREATE TABLE IF NOT EXISTS mpu_state (
    account_id    TEXT NOT NULL,
    blob_id       TEXT NOT NULL,
    upload_id     TEXT NOT NULL,
    declared_size INTEGER NOT NULL,
    created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (account_id, blob_id, upload_id)
);

-- Drives the age-ordered sweep scan; the quota SUM rides the primary key.
CREATE INDEX IF NOT EXISTS idx_mpu_created ON mpu_state(created_at);
