-- D1 schema: auth + billing + the server-side index mirroring envelope
-- plaintext fields (docs/api.md "R2 layout" note). R2 holds envelope bodies +
-- blobs. For an EXISTING deploy, apply migrations/ in order instead of this
-- file (this is the fresh-install full schema). Tiers: free | pro | max.

-- Legacy device tokens (headless relic-cli, pre-Supabase installs). Still a
-- valid auth path; sha256(token) is looked up here.
CREATE TABLE IF NOT EXISTS tokens (
    token_hash   TEXT PRIMARY KEY,              -- hex sha256 of the bearer token
    account_id   TEXT NOT NULL,
    device_label TEXT,
    tier         TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    revoked      INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_tokens_account ON tokens(account_id);

-- Identity rows. account_id = Supabase user id ('sub') on the bridge; later the
-- native-auth account id. `tier` is the hot-path cache the Stripe webhook keeps
-- current and authenticate() reads on every request.
CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY,
    email      TEXT,
    tier       TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- A Supabase identity bound to a pre-existing account (vaults that predate
-- email sign-in). authenticate() resolves the JWT sub through this table, so
-- signing in with the email lands in the original vault — data, tier, and
-- billing all key off the linked account. No data moves, no R2 rekeying.
-- One link per identity; several identities may point at one account.
CREATE TABLE IF NOT EXISTS account_links (
    supabase_sub TEXT PRIMARY KEY,
    account_id   TEXT NOT NULL,
    created_at   INTEGER NOT NULL DEFAULT (unixepoch())
);

-- Stripe subscription mirror. Source of truth is Stripe; this mirrors it via the
-- webhook (and the reconcile cron). One row per account.
CREATE TABLE IF NOT EXISTS subscriptions (
    account_id             TEXT PRIMARY KEY,
    stripe_customer_id     TEXT,
    stripe_subscription_id TEXT,
    tier                   TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','pro','max')),
    status                 TEXT NOT NULL DEFAULT 'none',  -- active|trialing|past_due|canceled|none
    current_period_end     INTEGER,
    cancel_at_period_end   INTEGER NOT NULL DEFAULT 0,
    grace_until            INTEGER,                        -- past_due access deadline
    updated_stripe_ts      INTEGER NOT NULL DEFAULT 0,     -- last event.created applied (ordering)
    updated_at             INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_sub_customer ON subscriptions(stripe_customer_id);

-- Webhook idempotency ledger: processed Stripe event ids. Replays are inert.
CREATE TABLE IF NOT EXISTS billing_events (
    event_id     TEXT PRIMARY KEY,   -- evt_...
    type         TEXT NOT NULL,
    created_at   INTEGER NOT NULL,   -- event.created
    processed_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS relic_meta (
    account_id TEXT NOT NULL,
    uid        TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    byte_size  INTEGER NOT NULL,
    promoted   INTEGER NOT NULL,
    blob_key   TEXT,
    PRIMARY KEY (account_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_meta_updated ON relic_meta(account_id, updated_at, uid);
CREATE INDEX IF NOT EXISTS idx_meta_stream  ON relic_meta(account_id, promoted, created_at);

CREATE TABLE IF NOT EXISTS tombstones (
    account_id TEXT NOT NULL,
    uid        TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    PRIMARY KEY (account_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_tomb ON tombstones(account_id, deleted_at);

-- Device registry (docs/cloudflare/13-device-onboarding.md §7). The settings
-- "your devices" list + remote-remove. device_id is client-generated (UUID),
-- stored locally on each device.
CREATE TABLE IF NOT EXISTS devices (
    account_id   TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    label        TEXT,
    platform     TEXT,
    created_at   INTEGER NOT NULL DEFAULT (unixepoch()),
    last_seen_at INTEGER NOT NULL DEFAULT (unixepoch()),
    revoked_at   INTEGER,
    app_version  TEXT,                          -- last version the device reported
    PRIMARY KEY (account_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);

-- E2EE share links (src/share.ts). D1 metadata; ciphertext in R2 at
-- shares/<id>. max_views NULL = unlimited until expiry.
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

-- Janitorial-sweep bookkeeping (src/sweep.ts): the resumable R2 list cursor
-- for the orphan-blob sweep, plus room for future sweeps.
CREATE TABLE IF NOT EXISTS sweep_state (
    k          TEXT PRIMARY KEY,
    v          TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
