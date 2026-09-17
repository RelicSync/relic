-- The second wall gets a letter too.
--
-- The free plan has two limits, and until now only one of them could speak.
-- 0012 added ring_email_at so an account whose oldest copies had started
-- dropping out of view could be told once. The vault cap (TIERS.free.vault
-- kept-forever items) had nothing: the server answered a 402 to the app and
-- that was the end of it. In practice the vault is the wall people reach
-- first, so the quieter limit was the louder one.
--
--   vault_email_at  unix seconds the one vault-full email went out, NULL =
--                   never. Same contract as ring_email_at: set once, and only
--                   after Resend either accepted the mail or refused the
--                   address itself.

ALTER TABLE account_usage ADD COLUMN vault_email_at INTEGER;
