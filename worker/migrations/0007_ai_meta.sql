-- AI records: the generated title + tags for a relic, produced on whichever
-- device is capable of running the models, and the lease that stops two
-- devices from doing that work at the same time.
--
-- Why this is not a column on relic_meta: a relic push is rejected unless it
-- strictly advances updated_at (index.ts putRelic), and the pull cursor is
-- ordered by updated_at. Folding AI output into the relic envelope would
-- therefore make every background tagging pass count as a user edit, reorder
-- "recently updated", and let an AI write race a rename. An AI record is its
-- own document on its own cursor, so the two never compete.
--
-- The payload is small (a title and a few tags), so the ciphertext lives in D1
-- rather than R2: a pull is then one indexed query instead of N object reads.
CREATE TABLE IF NOT EXISTS ai_meta (
    account_id       TEXT NOT NULL,
    uid              TEXT NOT NULL,
    -- NULL until a result actually lands. A row can exist as a bare lease.
    ai_at            INTEGER,
    -- The enrich level the result was produced at, so a device on a newer
    -- model generation knows the stored result is behind and worth redoing,
    -- and a device on the same generation knows to leave it alone.
    ai_level         INTEGER,
    device_id        TEXT,               -- which device produced it
    n                TEXT,               -- base64 nonce   (AAD relic.ai.v1:<uid>)
    ct               TEXT,               -- base64 ciphertext: {title, tags}
    claimed_by       TEXT,               -- device holding the lease
    claim_expires_at INTEGER,            -- lease deadline; past this it is free
    PRIMARY KEY (account_id, uid)
);

-- The pull cursor. Partial on ai_at so bare leases (ai_at IS NULL) stay out of
-- the index entirely — they are coordination state, never client-visible data.
CREATE INDEX IF NOT EXISTS idx_ai_at ON ai_meta(account_id, ai_at, uid)
    WHERE ai_at IS NOT NULL;
