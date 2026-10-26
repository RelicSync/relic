-- The free plan's sync rule: one device after a free first week.
--
-- Free accounts sync on every device for their first week. After that one
-- device keeps syncing and the others get 403 sync_paused (src/syncplan.ts,
-- behind SYNC_PLAN_GATE). Nothing reads these columns while the gate is off.
--
--   sync_until      unix seconds free multi-device sync ends. NULL means
--                   created_at + 7 days. Set by hand for accounts given extra
--                   time when the rule launched.
--   sync_device     the device that keeps syncing after the week. Filled
--                   automatically (most recently seen device) the first time
--                   the rule applies, or by POST /account/sync-device.
--   sync_device_at  unix seconds the user last picked the device by hand, for
--                   the once-a-week switch limit. NULL = never picked by hand.
--
-- Plain nullable columns, so this is a metadata-only ALTER with no backfill.

ALTER TABLE accounts ADD COLUMN sync_until INTEGER;
ALTER TABLE accounts ADD COLUMN sync_device TEXT;
ALTER TABLE accounts ADD COLUMN sync_device_at INTEGER;
