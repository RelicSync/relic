-- The free week's one email (src/syncplan.ts syncWeekSweep).
--
-- When a free account's week of sync on every device ends and it still uses
-- two or more devices, it gets one email saying sync now runs on one of them,
-- how to pick which, and what Pro costs. Sent only while SYNC_PLAN_GATE is on.
--
--   sync_email_at  unix seconds that email went out, NULL = never. Same
--                  contract as account_usage.ring_email_at: set once, and only
--                  after Resend accepted the mail or refused the address.

ALTER TABLE accounts ADD COLUMN sync_email_at INTEGER;
