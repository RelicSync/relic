import { describe, expect, it } from "vitest";

import { MAIL_FROM } from "../src/mail";

// The 2026-09-18 silence: every Worker email was addressed from
// no-reply@relic.space, a domain Resend has never verified, so all four senders
// were answered 403 and nothing reached anybody. The verified domain is
// mail.relic.space. This test is the tripwire that keeps the sender there.
describe("outgoing mail sender", () => {
  it("sends from the Resend-verified domain", () => {
    expect(MAIL_FROM.endsWith("@mail.relic.space>")).toBe(true);
  });

  it("is a display-name address, so inboxes show a name and not a bare mailbox", () => {
    expect(MAIL_FROM).toMatch(/^[^<>]+ <[^<>@\s]+@[^<>@\s]+>$/);
  });
});
