-- Migration 0006: device transparency. Each device row learns the app version
-- it last reported (X-Relic-App-Version header / app_version on register), so
-- the Devices screen can flag outdated installs. last_seen_at already exists
-- (0002) but was only bumped on registration; it now also gets a throttled
-- per-request touch in the Worker (see touchDevice in src/index.ts).
--
-- Apply BEFORE deploying the touchDevice/route changes:
--   wrangler d1 execute relic --file=migrations/0006_device_app_version.sql          (local dev)
--   wrangler d1 execute relic --remote --file=migrations/0006_device_app_version.sql (production)
ALTER TABLE devices ADD COLUMN app_version TEXT;
