-- relics.sql — canonical local-index schema (SQLite + FTS5)
-- This is the per-device DECRYPTED index (SPEC §6). The server never sees it.
-- Embedded by relic-core and applied via user_version migrations.

PRAGMA user_version = 3;

CREATE TABLE IF NOT EXISTS relics (
    id          INTEGER PRIMARY KEY,              -- rowid; FTS external-content link
    uid         TEXT    NOT NULL UNIQUE,          -- UUIDv7, stable across devices
    created_at  INTEGER NOT NULL,                 -- unix seconds (UTC)
    updated_at  INTEGER NOT NULL,
    kind        TEXT    NOT NULL CHECK (kind IN ('string','photo','file','other')),
    source      TEXT    NOT NULL CHECK (source IN ('clipboard','upload','hotkey','share','api')),
    promoted    INTEGER NOT NULL DEFAULT 0,       -- 0 = stream, 1 = vault
    byte_size   INTEGER NOT NULL DEFAULT 0,       -- plaintext size of content or blob
    device      TEXT,                             -- capturing device label
    mime        TEXT,                             -- photo/file only
    filename    TEXT,                             -- photo/file only
    blob_key    TEXT,                             -- remote key for binary payloads
    tags        TEXT    NOT NULL DEFAULT '',      -- deterministic subtype tags, comma-separated
    user_tags   TEXT    NOT NULL DEFAULT '',      -- freeform user tags, comma-separated
    title       TEXT,                             -- user-assigned; preview is the fallback
    collection  TEXT,                             -- vault grouping
    note        TEXT,                             -- user annotation
    content     TEXT,                             -- decrypted searchable text (string relics)
    preview     TEXT,                             -- short list title
    attachments TEXT    NOT NULL DEFAULT ''       -- JSON manifest of bundle attachments ('' = none)
);

CREATE INDEX IF NOT EXISTS idx_relics_created  ON relics(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_relics_updated  ON relics(updated_at);
CREATE INDEX IF NOT EXISTS idx_relics_stream   ON relics(promoted, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_relics_kind     ON relics(kind, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_relics_coll     ON relics(collection) WHERE collection IS NOT NULL;

-- External-content FTS: no text duplication; rows live in `relics`.
CREATE VIRTUAL TABLE IF NOT EXISTS relics_fts USING fts5(
    content, preview, filename, tags, title, user_tags, note,
    content='relics', content_rowid='id',
    tokenize="unicode61 remove_diacritics 2 tokenchars '-_.'"
);

CREATE TRIGGER IF NOT EXISTS relics_ai AFTER INSERT ON relics BEGIN
    INSERT INTO relics_fts(rowid, content, preview, filename, tags, title, user_tags, note)
    VALUES (new.id, new.content, new.preview, new.filename, new.tags, new.title, new.user_tags, new.note);
END;

CREATE TRIGGER IF NOT EXISTS relics_ad AFTER DELETE ON relics BEGIN
    INSERT INTO relics_fts(relics_fts, rowid, content, preview, filename, tags, title, user_tags, note)
    VALUES ('delete', old.id, old.content, old.preview, old.filename, old.tags, old.title, old.user_tags, old.note);
END;

CREATE TRIGGER IF NOT EXISTS relics_au AFTER UPDATE ON relics BEGIN
    INSERT INTO relics_fts(relics_fts, rowid, content, preview, filename, tags, title, user_tags, note)
    VALUES ('delete', old.id, old.content, old.preview, old.filename, old.tags, old.title, old.user_tags, old.note);
    INSERT INTO relics_fts(rowid, content, preview, filename, tags, title, user_tags, note)
    VALUES (new.id, new.content, new.preview, new.filename, new.tags, new.title, new.user_tags, new.note);
END;

-- Sync bookkeeping (cursor = highest updated_at fully synced, etc.)
CREATE TABLE IF NOT EXISTS sync_state (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);

-- Offline-tolerant outbound queue: ops waiting to reach the sync store.
CREATE TABLE IF NOT EXISTS pending_ops (
    uid       TEXT    NOT NULL,
    op        TEXT    NOT NULL CHECK (op IN ('push','delete')),
    queued_at INTEGER NOT NULL,
    PRIMARY KEY (uid, op)
);

-- Per-relic embedding for semantic / hybrid search (SPEC §6). Only saved
-- (promoted) relics get a vector — the ephemeral stream stays cheap. `vec` is
-- dim × f32 little-endian (L2-normalized); cosine = dot product, brute-forced
-- at query time. `model` lets a future model change trigger a re-embed.
CREATE TABLE IF NOT EXISTS vectors (
    uid   TEXT    PRIMARY KEY,
    model TEXT    NOT NULL,
    vec   BLOB    NOT NULL
);

-- Reference queries (documentation, exercised by the schema test):
--   ranked search:   SELECT r.* FROM relics_fts f JOIN relics r ON r.id = f.rowid
--                    WHERE relics_fts MATCH ?1 ORDER BY bm25(relics_fts);
--   kind filter:     ... MATCH ?1 AND r.kind = 'photo' ...
--   stream view:     SELECT * FROM relics WHERE promoted = 0 ORDER BY created_at DESC LIMIT 500;
--   vault view:      SELECT * FROM relics WHERE promoted = 1 ORDER BY created_at DESC;
--   fts integrity:   INSERT INTO relics_fts(relics_fts) VALUES('integrity-check');
