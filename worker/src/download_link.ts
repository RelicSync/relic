// "Send me the download link" — the one-tap bridge off a phone.
//
// Somebody signs in on their phone first, and the part of Relic that matters
// most (a computer saving what you copy, by itself) lives on a machine they
// are not holding. Typing a URL onto a laptop later is where that intent dies.
// So the phone asks us to mail the link to the address they just signed in
// with, and they open it at the desk.
//
// Deliberately small: no body, no parameters, nothing to get wrong. The
// recipient is the signed-in identity's own email and can never be supplied by
// the caller, so this cannot be pointed at a stranger.
//
// Guards, in order:
//   - no email on the identity (legacy device-token auth) -> 400, because
//     there is nothing to send to.
//   - one send per account per hour, stamped in the existing PAIR KV under
//     `dl:` (a third prefix beside `pair:` and `rev:`). A server without that
//     namespace simply skips the guard; the per-account rate limiter on the
//     route is still there.
//   - no Resend key (self-host, local dev) -> 503, said plainly rather than
//     pretending to have sent something.
//
// The stamp lands only after Resend accepts the mail, so a failed send leaves
// the person free to press the button again.

import type { Env } from "./env";
import type { Auth } from "./auth";
import { CORS, err } from "./http";
import { MAIL_FROM } from "./mail";

/// One send per account per hour.
export const DL_TTL = 60 * 60;
export const dlKey = (account: string) => `dl:${account}`;

/// Where the mail points. The page picks the platform for the reader.
const DOWNLOAD_URL = "https://relic.space/get";

const SUBJECT = "Your Relic download link";

// Joined with an explicit newline, so the body on the wire never depends on
// this file's own line endings (the tree is CRLF).
const TEXT = [
  "Here is the link you asked for.",
  DOWNLOAD_URL,
  "Open it on your computer and pick your platform. Sign in with this same " +
  "account and your phone and computer share one vault.",
  "On a computer, Relic saves what you copy by itself. On a phone, you share " +
  "things to it on purpose.",
  "If you didn't ask for this, you can ignore it.",
].join("\n\n");

export async function sendDownloadLink(env: Env, auth: Auth): Promise<Response> {
  const to = auth.email;
  if (!to) {
    return err(400, "no_email", "This sign-in has no email address to send to.");
  }

  const key = dlKey(auth.account);
  // No KV namespace -> no once-an-hour memory. The route's rate limiter is the
  // remaining backstop, which is the same trade every other PAIR user makes.
  if (env.PAIR && (await env.PAIR.get(key))) {
    return err(429, "already_sent", "Already sent. Check your inbox.");
  }

  if (!env.RESEND_API_KEY) {
    return err(503, "unconfigured", "This server cannot send email.");
  }

  let ok = false;
  let status = 0;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: MAIL_FROM,
        to,
        subject: SUBJECT,
        text: TEXT,
      }),
    });
    ok = r.ok;
    status = r.status;
  } catch (e) {
    console.log(JSON.stringify({ evt: "dl_link_email_error", account: auth.account, err: String(e) }));
  }
  console.log(JSON.stringify({ evt: "dl_link_email", account: auth.account, ok, status }));
  if (!ok) return err(502, "send_failed", "The email could not be sent. Try again.");

  // Stamped only on success, so a failure the person can see is also a failure
  // they can retry.
  if (env.PAIR) await env.PAIR.put(key, "1", { expirationTtl: DL_TTL });
  return new Response(null, { status: 204, headers: CORS });
}
