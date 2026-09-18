// Who our mail comes from.
//
// This has to be an address on a domain Resend has verified, and the verified
// domain is mail.relic.space: it carries the DKIM key and the SPF record. The
// bare relic.space has neither. Sending from it makes Resend answer 403 and
// nothing reaches anybody.
//
// That is not hypothetical. Every email the Worker could send used
// "no-reply@relic.space" until 2026-09-18, so the download link, the
// post-checkout setup mail, the history-ring nudge and the vault-cap nudge had
// all been silently refused since the day each shipped. One constant, imported
// everywhere, is what stops the next one drifting back.
//
// Replies still work. mail.relic.space accepts inbound, and the copy points
// people at support@relic.space anyway.
export const MAIL_FROM = "Relic <no-reply@mail.relic.space>";
