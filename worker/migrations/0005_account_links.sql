-- Account linking: bind a Supabase identity to a pre-existing account so
-- email sign-in lands in a vault that predates email auth (legacy device-token
-- accounts). authenticate() resolves the JWT sub through this table; data,
-- tier, and billing all key off the linked account. No data moves.
CREATE TABLE IF NOT EXISTS account_links (
    supabase_sub TEXT PRIMARY KEY,
    account_id   TEXT NOT NULL,
    created_at   INTEGER NOT NULL DEFAULT (unixepoch())
);
