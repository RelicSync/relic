// POST /account/send-download-link — the phone mails itself the desktop link.
//
// Four things have to hold or the button is worse than no button: the mail
// actually carries the link, a second press inside the hour says so instead of
// sending twice, a server with no mail provider admits it, and a provider
// failure is retryable rather than silently swallowed.
import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../src/index";
import { dlKey } from "../src/download_link";
import { HS_SECRET, mintJwt, setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

// SUPABASE_URL stays unset so verifySupabaseJwt checks no issuer and the local
// HS256 secret is enough: that path is the only one that carries an email.
const mailEnv = (extra: Record<string, unknown> = {}) => ({
  ...E,
  SUPABASE_JWT_SECRET: HS_SECRET,
  RESEND_API_KEY: "re_test_key", // scan-ok: fake key in a test
  ...extra,
});

function send(token: string, envOverride: Record<string, unknown>) {
  return worker.fetch(
    new Request("https://x/account/send-download-link", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    }),
    envOverride,
  );
}

/// Capture what goes to Resend and control what it says back.
// deno-lint-ignore no-explicit-any
function stubResend(status: number): any {
  const mock = vi.fn(async () =>
    new Response(JSON.stringify({ id: "msg_1" }), {
      status,
      headers: { "Content-Type": "application/json" },
    })
  );
  vi.spyOn(globalThis, "fetch").mockImplementation(mock as unknown as typeof fetch);
  return mock;
}

// Storage is shared across the run (no per-test isolation in
// vitest-pool-workers 0.18+), so every test uses its own account id and the
// hourly stamp is cleared up front.
async function clearStamp(account: string) {
  await E.PAIR.delete(dlKey(account));
}

beforeEach(async () => {
  await setupSchema(E.DB);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("send download link", () => {
  it("mails the link to the signed-in address and answers 204", async () => {
    await clearStamp("dl-ok");
    const jwt = await mintJwt({ sub: "dl-ok", email: "someone@example.test" });
    const mock = stubResend(200);

    const res = await send(jwt, mailEnv());
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");

    expect(mock).toHaveBeenCalledTimes(1);
    const [url, init] = mock.mock.calls[0];
    expect(String(url)).toBe("https://api.resend.com/emails");
    const sent = JSON.parse(String(init.body));
    expect(sent.to).toBe("someone@example.test");
    expect(sent.from).toBe("Relic <no-reply@relic.space>");
    expect(sent.subject).toBe("Your Relic download link");
    expect(sent.text).toContain("relic.space/get");
    expect(sent.text).toContain("Here is the link you asked for.");
    expect(sent.text).not.toContain("—"); // house style: no em dashes
  });

  it("refuses a sign-in with no email address", async () => {
    await E.DB.prepare(
      "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)",
    ).bind(await sha256Hex("dl-legacy-token"), "dl-legacy", "free").run();
    const mock = stubResend(200);

    const res = await send("dl-legacy-token", mailEnv());
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "no_email" });
    expect(mock).not.toHaveBeenCalled();
  });

  it("sends once an hour and says so on the second press", async () => {
    await clearStamp("dl-twice");
    const jwt = await mintJwt({ sub: "dl-twice", email: "twice@example.test" });
    const mock = stubResend(200);

    expect((await send(jwt, mailEnv())).status).toBe(204);
    expect(await E.PAIR.get(dlKey("dl-twice"))).toBe("1");

    const again = await send(jwt, mailEnv());
    expect(again.status).toBe(429);
    expect(await again.json()).toMatchObject({
      error: "already_sent",
      message: "Already sent. Check your inbox.",
    });
    expect(mock).toHaveBeenCalledTimes(1); // no second mail
  });

  it("admits it when the server has no mail provider", async () => {
    await clearStamp("dl-nokey");
    const jwt = await mintJwt({ sub: "dl-nokey", email: "nokey@example.test" });
    const mock = stubResend(200);

    const res = await send(jwt, mailEnv({ RESEND_API_KEY: undefined }));
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "unconfigured" });
    expect(mock).not.toHaveBeenCalled();
  });

  it("reports a provider failure and leaves the hour open for a retry", async () => {
    await clearStamp("dl-fail");
    const jwt = await mintJwt({ sub: "dl-fail", email: "fail@example.test" });
    stubResend(422);

    const res = await send(jwt, mailEnv());
    expect(res.status).toBe(502);
    expect(await res.json()).toMatchObject({ error: "send_failed" });
    // Nothing stamped, so the person can press it again rather than waiting an
    // hour for a mail that never arrived.
    expect(await E.PAIR.get(dlKey("dl-fail"))).toBeNull();
  });
});
