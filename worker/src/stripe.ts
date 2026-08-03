// Stripe billing, all on Cloudflare. Implements docs/cloudflare/05-billing.md.
//
//   POST /stripe/checkout  {price_id}  -> hosted Checkout URL   (authed)
//   POST /stripe/portal                -> hosted Portal URL     (authed)
//   POST /stripe/webhook               -> verify sig, enqueue/apply (UNauthed)
//
// We talk to Stripe over its REST API with fetch + form-encoding (no SDK, keeps
// the bundle tiny). Webhook signatures are verified with WebCrypto HMAC-SHA256.
// Stripe is the source of truth; D1 mirrors it. Tier changes funnel through one
// idempotent function (applyStripeEvent) whether they arrive via webhook, the
// queue consumer, or the reconcile cron.

import type { Env, StripeMessage } from "./env";
import { isTier, type Tier } from "./tiers";
import type { Auth } from "./auth";
import { CORS, err, json } from "./http";

const STRIPE_API = "https://api.stripe.com/v1";
const GRACE_DAYS = 7; // keep access this long after a failed payment

function priceMap(env: Env): Record<string, Tier> {
  try {
    const m = JSON.parse(env.STRIPE_PRICE_MAP ?? "{}") as Record<string, string>;
    const out: Record<string, Tier> = {};
    for (const [k, v] of Object.entries(m)) if (isTier(v)) out[k] = v;
    return out;
  } catch {
    return {};
  }
}

async function stripe(
  env: Env,
  path: string,
  body: URLSearchParams,
  idempotencyKey?: string,
  // deno-lint-ignore no-explicit-any
): Promise<any> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  const r = await fetch(`${STRIPE_API}${path}`, { method: "POST", headers, body });
  if (!r.ok) throw new Error(`stripe ${path} ${r.status}: ${await r.text()}`);
  return r.json();
}

// Cancel a subscription immediately (used by account deletion). Best-effort:
// account teardown proceeds even if Stripe is unreachable, because we also drop
// our D1 mirror — reconcile can't resurrect a row for an account that no longer
// exists. A genuinely orphaned Stripe sub surfaces via Stripe's own dunning.
export async function cancelSubscription(env: Env, subscriptionId: string): Promise<void> {
  if (!env.STRIPE_SECRET_KEY) return;
  await fetch(`${STRIPE_API}/subscriptions/${subscriptionId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
}

// deno-lint-ignore no-explicit-any
async function stripeGet(env: Env, path: string): Promise<any> {
  const r = await fetch(`${STRIPE_API}${path}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  if (!r.ok) throw new Error(`stripe GET ${path} ${r.status}`);
  return r.json();
}

// GET /stripe/plans -> the purchasable plans (price_id, tier, interval, amount)
// derived from STRIPE_PRICE_MAP. Lets clients render an Upgrade UI without
// hardcoding price ids (which differ test vs live).
//
// This route is public and fans out to one Stripe GET per price, so it is
// cached (in-isolate + edge Cache-Control) to blunt repeat hits and avoid
// amplifying load onto the Stripe API. Prices change ~never; a deploy resets
// the isolate cache.
let plansCache: { at: number; plans: unknown[] } | null = null;
const PLANS_TTL_MS = 5 * 60 * 1000;

function plansResponse(plans: unknown[]): Response {
  return Response.json(
    { plans },
    { headers: { ...CORS, "Cache-Control": "public, max-age=300" } },
  );
}

export async function listPlans(env: Env): Promise<Response> {
  if (plansCache && Date.now() - plansCache.at < PLANS_TTL_MS) {
    return plansResponse(plansCache.plans);
  }
  const map = priceMap(env);
  const ids = Object.keys(map);
  if (!env.STRIPE_SECRET_KEY || ids.length === 0) return plansResponse([]);
  const plans = await Promise.all(ids.map(async (id) => {
    try {
      const p = await stripeGet(env, `/prices/${id}`);
      return {
        price_id: id,
        tier: map[id],
        interval: p.recurring?.interval ?? null,
        amount: p.unit_amount ?? null,
        currency: p.currency ?? "usd",
      };
    } catch {
      return { price_id: id, tier: map[id], interval: null, amount: null, currency: "usd" };
    }
  }));
  plansCache = { at: Date.now(), plans };
  return plansResponse(plans);
}

// ---- POST /stripe/checkout -------------------------------------------------
export async function createCheckout(req: Request, env: Env, auth: Auth): Promise<Response> {
  if (!env.STRIPE_SECRET_KEY) return err(503, "billing_unconfigured", "billing not enabled");
  let price_id = "";
  try {
    price_id = (await req.json<{ price_id: string }>()).price_id;
  } catch {
    /* empty body -> bad price below */
  }
  if (!(price_id in priceMap(env))) return err(400, "bad_price", "unknown price");

  const base = env.APP_BASE_URL ?? "https://relic.space";
  const existing = await env.DB.prepare(
    "SELECT stripe_customer_id FROM subscriptions WHERE account_id = ?1",
  ).bind(auth.account).first<{ stripe_customer_id: string | null }>();

  const form = new URLSearchParams({
    mode: "subscription",
    "line_items[0][price]": price_id,
    "line_items[0][quantity]": "1",
    client_reference_id: auth.account, // <- links Stripe <-> our account
    success_url: `${base}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${base}/billing/cancel`,
    "subscription_data[metadata][account_id]": auth.account,
    allow_promotion_codes: "true",
  });
  // Opt-in: Stripe Tax requires a registered origin, so enable only when asked.
  if (env.STRIPE_TAX === "on") form.set("automatic_tax[enabled]", "true");
  if (existing?.stripe_customer_id) form.set("customer", existing.stripe_customer_id);
  else if (auth.email) form.set("customer_email", auth.email);

  const session = await stripe(env, "/checkout/sessions", form);
  return json({ url: session.url });
}

// ---- POST /stripe/portal ---------------------------------------------------
export async function createPortal(_req: Request, env: Env, auth: Auth): Promise<Response> {
  if (!env.STRIPE_SECRET_KEY) return err(503, "billing_unconfigured", "billing not enabled");
  const sub = await env.DB.prepare(
    "SELECT stripe_customer_id FROM subscriptions WHERE account_id = ?1",
  ).bind(auth.account).first<{ stripe_customer_id: string | null }>();
  if (!sub?.stripe_customer_id) return err(409, "no_subscription", "nothing to manage");
  const base = env.APP_BASE_URL ?? "https://relic.space";
  const session = await stripe(
    env,
    "/billing_portal/sessions",
    new URLSearchParams({ customer: sub.stripe_customer_id, return_url: `${base}/billing` }),
  );
  return json({ url: session.url });
}

// ---- webhook signature (WebCrypto HMAC-SHA256; Workers crypto is async) -----
export async function verifySig(payload: string, header: string, secret: string): Promise<boolean> {
  // A Stripe-Signature header can carry MORE than one v1= signature — during a
  // webhook-secret rotation Stripe signs with both the old and new secret, so we
  // must accept if ANY listed v1 matches our single secret (not just the last).
  let t: string | undefined;
  const v1s: string[] = [];
  for (const kv of header.split(",")) {
    const i = kv.indexOf("=");
    if (i <= 0) continue;
    const k = kv.slice(0, i).trim();
    const v = kv.slice(i + 1).trim();
    if (k === "t") t = v;
    else if (k === "v1") v1s.push(v);
  }
  if (!t || v1s.length === 0) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false; // 5-min replay window
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${payload}`));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  // Compare against every candidate (no early return) — accept on any match.
  let ok = false;
  for (const v1 of v1s) {
    if (v1.length !== expected.length) continue;
    let diff = 0;
    for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i);
    if (diff === 0) ok = true; // constant-time compare per candidate
  }
  return ok;
}

// ---- POST /stripe/webhook (unauthenticated; the signature is the auth) ------
export async function stripeWebhook(req: Request, env: Env): Promise<Response> {
  if (!env.STRIPE_WEBHOOK_SECRET) return new Response("billing not configured", { status: 503 });
  const sig = req.headers.get("Stripe-Signature") ?? "";
  const body = await req.text(); // raw body, pre-parse, for signature
  if (!(await verifySig(body, sig, env.STRIPE_WEBHOOK_SECRET))) {
    return new Response("bad signature", { status: 400 });
  }
  // deno-lint-ignore no-explicit-any
  let event: any;
  try {
    event = JSON.parse(body);
  } catch {
    return new Response("bad json", { status: 400 });
  }
  const msg: StripeMessage = {
    id: event.id,
    type: event.type,
    created: event.created,
    data: event.data?.object,
  };

  // Prefer the durable queue (fast ack + retries + DLQ). Fall back to inline
  // apply when no queue is bound, so billing works before the queue exists.
  if (env.STRIPE_QUEUE) {
    await env.STRIPE_QUEUE.send(msg);
  } else {
    try {
      await applyStripeEvent(env, msg);
    } catch {
      return new Response("apply failed", { status: 500 }); // Stripe retries ~3 days
    }
  }
  return new Response("ok", { status: 200 });
}

// ---- the one idempotent apply path -----------------------------------------
// deno-lint-ignore no-explicit-any
function tierFromSub(sub: any, map: Record<string, Tier>): Tier {
  const priceId = sub?.items?.data?.[0]?.price?.id;
  return (priceId && map[priceId]) || "free";
}

async function accountByCustomer(env: Env, customerId?: string): Promise<string | undefined> {
  if (!customerId) return undefined;
  const row = await env.DB.prepare(
    "SELECT account_id FROM subscriptions WHERE stripe_customer_id = ?1",
  ).bind(customerId).first<{ account_id: string }>();
  return row?.account_id;
}

// Upsert a subscriptions row and mirror the resolved tier into accounts (the
// hot-path cache authenticate() reads). Only touches accounts.tier when a tier
// is part of this update.
async function writeSub(
  env: Env,
  accountId: string,
  fields: Record<string, string | number | null>,
): Promise<void> {
  const cols = ["account_id", ...Object.keys(fields)];
  const placeholders = cols.map((_, i) => `?${i + 1}`).join(",");
  const updates = Object.keys(fields).map((k) => `${k} = excluded.${k}`).join(", ");
  await env.DB.prepare(
    `INSERT INTO subscriptions (${cols.join(",")}) VALUES (${placeholders})
     ON CONFLICT(account_id) DO UPDATE SET ${updates}, updated_at = unixepoch()`,
  ).bind(accountId, ...Object.values(fields)).run();
  if ("tier" in fields) {
    await env.DB.prepare(
      `INSERT INTO accounts (account_id, tier) VALUES (?1, ?2)
       ON CONFLICT(account_id) DO UPDATE SET tier = excluded.tier`,
    ).bind(accountId, fields.tier).run();
  }
}

// Human label for the email body. Unknown/free -> generic wording (the tier may
// not have landed yet if subscription.created arrives after checkout.completed).
function tierLabel(t?: string): string {
  return t === "pro" ? "Pro" : t === "max" ? "Max" : "paid";
}

// Post-checkout nudge: a paid checkout with no device registered yet means the
// buyer paid on the website but hasn't installed the app. Send ONE plain setup
// email via Resend. Fully best-effort: absent key / missing recipient / any
// failure is swallowed so it can never fail the webhook. Idempotent per checkout
// session id via a KV marker (`ckem:` prefix, ~7-day TTL).
// deno-lint-ignore no-explicit-any
async function maybeSendZeroDeviceEmail(env: Env, accountId: string, session: any): Promise<void> {
  try {
    if (!env.RESEND_API_KEY) return; // email not configured -> skip silently
    const to = session?.customer_details?.email ?? session?.customer_email;
    if (!to || typeof to !== "string") return;
    const marker = session?.id ? `ckem:${session.id}` : "";
    if (env.PAIR && marker && (await env.PAIR.get(marker))) return; // already sent

    const dev = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM devices WHERE account_id = ?1 AND revoked_at IS NULL",
    ).bind(accountId).first<{ n: number }>();
    if ((dev?.n ?? 0) > 0) return; // has a device -> no nudge

    const row = await env.DB.prepare("SELECT tier FROM accounts WHERE account_id = ?1")
      .bind(accountId).first<{ tier: string }>();
    const label = tierLabel(row?.tier);
    const dl = "https://relic.space/download/windows";
    const text =
      `Your Relic ${label} plan is active.\n\n` +
      `Here is the 2-minute setup:\n\n` +
      `1. Install Relic for Windows: ${dl}\n` +
      `2. Open the app and sign in with this email address.\n` +
      `3. Your plan activates automatically once you sign in.\n\n` +
      `Stuck? Reply to this email or write to support@relic.space and we will help.\n\n` +
      `- The Relic team`;
    const html =
      `<p>Your Relic ${label} plan is active.</p>` +
      `<p>Here is the 2-minute setup:</p>` +
      `<ol><li>Install Relic for Windows: <a href="${dl}">relic.space/download/windows</a></li>` +
      `<li>Open the app and sign in with this email address.</li>` +
      `<li>Your plan activates automatically once you sign in.</li></ol>` +
      `<p>Stuck? Reply to this email or write to ` +
      `<a href="mailto:support@relic.space">support@relic.space</a> and we will help.</p>` +
      `<p>- The Relic team</p>`;

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Relic <no-reply@relic.space>",
        to,
        subject: "Your Relic plan is active. 2-minute setup",
        text,
        html,
      }),
    });
    // Mark after the attempt (ok or not) so retries of a sibling event don't
    // re-send. billing_events already blocks replays of the SAME event id.
    if (env.PAIR && marker) await env.PAIR.put(marker, "1", { expirationTtl: 7 * 24 * 60 * 60 });
    console.log(JSON.stringify({ evt: "ckout_setup_email", account: accountId, ok: r.ok, status: r.status }));
  } catch (e) {
    console.log(JSON.stringify({ evt: "ckout_setup_email_error", account: accountId, err: String(e) }));
  }
}

export async function applyStripeEvent(env: Env, ev: StripeMessage): Promise<void> {
  const seen = await env.DB.prepare("SELECT 1 FROM billing_events WHERE event_id = ?1")
    .bind(ev.id).first();
  if (seen) return; // inbound idempotency: replays are inert

  const obj = ev.data ?? {};
  const map = priceMap(env);
  const now = Math.floor(Date.now() / 1000);

  switch (ev.type) {
    case "checkout.session.completed": {
      const accountId = obj.client_reference_id as string | undefined;
      if (accountId) {
        await writeSub(env, accountId, {
          stripe_customer_id: obj.customer ?? null,
          stripe_subscription_id: obj.subscription ?? null,
        });
        await maybeSendZeroDeviceEmail(env, accountId, obj);
      }
      break;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated": {
      const accountId = obj?.metadata?.account_id as string | undefined;
      if (accountId) {
        const status = String(obj.status);
        const grant = status === "active" || status === "trialing" || status === "past_due";
        await writeSub(env, accountId, {
          stripe_customer_id: obj.customer ?? null,
          stripe_subscription_id: obj.id ?? null,
          tier: grant ? tierFromSub(obj, map) : "free",
          status,
          current_period_end: obj.current_period_end ?? null,
          cancel_at_period_end: obj.cancel_at_period_end ? 1 : 0,
          grace_until: status === "past_due" ? now + GRACE_DAYS * 86400 : null,
          updated_stripe_ts: ev.created,
        });
      }
      break;
    }
    case "customer.subscription.deleted": {
      const accountId = (obj?.metadata?.account_id as string | undefined) ??
        (await accountByCustomer(env, obj.customer));
      if (accountId) {
        await writeSub(env, accountId, {
          status: "canceled",
          tier: "free", // downgrade; over-cap content stays read-only, never deleted
          cancel_at_period_end: 0,
          grace_until: null,
          updated_stripe_ts: ev.created,
        });
      }
      break;
    }
    case "invoice.payment_failed": {
      const accountId = await accountByCustomer(env, obj.customer);
      if (accountId) {
        await writeSub(env, accountId, {
          status: "past_due",
          grace_until: now + GRACE_DAYS * 86400, // keep tier through grace
          updated_stripe_ts: ev.created,
        });
      }
      break;
    }
    case "invoice.paid":
    case "invoice.payment_succeeded": {
      const accountId = await accountByCustomer(env, obj.customer);
      if (accountId) {
        await writeSub(env, accountId, {
          status: "active",
          grace_until: null,
          updated_stripe_ts: ev.created,
        });
      }
      break;
    }
  }

  await env.DB.prepare(
    "INSERT OR IGNORE INTO billing_events (event_id, type, created_at) VALUES (?1, ?2, ?3)",
  ).bind(ev.id, ev.type, ev.created).run();
}

// ---- queue consumer --------------------------------------------------------
export async function consumeStripeBatch(
  batch: MessageBatch<StripeMessage>,
  env: Env,
): Promise<void> {
  for (const m of batch.messages) {
    try {
      await applyStripeEvent(env, m.body);
      m.ack();
    } catch {
      m.retry(); // -> queue backoff -> DLQ; reconcile cron is the final backstop
    }
  }
}

// ---- scheduled grace sweep (cron) ------------------------------------------
// Past-due accounts whose grace has expired drop to free until they pay again
// (invoice.paid restores them). Each downgraded account gets ONE "plan lapsed"
// email so the change is never silent: the pre-update tier filter
// (a.tier != 'free') is the idempotency guard, because re-runs of the sweep
// see the account already on free and select nothing.
export async function graceSweep(env: Env): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const lapsed = await env.DB.prepare(
    `SELECT a.account_id, a.email, a.tier FROM accounts a
       JOIN subscriptions s ON s.account_id = a.account_id
     WHERE s.status = 'past_due' AND s.grace_until IS NOT NULL
       AND s.grace_until < ?1 AND a.tier != 'free'`,
  ).bind(now).all<{ account_id: string; email: string | null; tier: string }>();

  await env.DB.prepare(
    `UPDATE accounts SET tier = 'free' WHERE account_id IN (
       SELECT account_id FROM subscriptions
       WHERE status = 'past_due' AND grace_until IS NOT NULL AND grace_until < ?1
     )`,
  ).bind(now).run();

  for (const row of lapsed.results ?? []) {
    await sendPlanLapsedEmail(env, row.account_id, row.email, row.tier);
  }
}

// "Plan lapsed" notice, sent once per downgrade by graceSweep. Best-effort like
// the checkout nudge: no key / no address / send failure never fails the cron.
// The core reassurance: nothing was deleted, the vault is read-only over the
// free caps, and paying again restores everything.
async function sendPlanLapsedEmail(
  env: Env,
  accountId: string,
  to: string | null,
  oldTier: string,
): Promise<void> {
  try {
    if (!env.RESEND_API_KEY || !to) return;
    const label = tierLabel(oldTier);
    const manage = "https://relic.space/account";
    const text =
      `Your Relic ${label} plan has lapsed after the payment grace period.\n\n` +
      `Your data is safe. Nothing was deleted, and everything you saved is ` +
      `still there. Your account is now on the free plan, so new syncs pause ` +
      `while you are over the free limits, but you can keep reading ` +
      `everything on all your devices.\n\n` +
      `To pick up where you left off, update your payment method or renew ` +
      `here: ${manage}\n\n` +
      `Questions? Reply to this email or write to support@relic.space.\n\n` +
      `- The Relic team`;
    const html =
      `<p>Your Relic ${label} plan has lapsed after the payment grace period.</p>` +
      `<p><strong>Your data is safe.</strong> Nothing was deleted, and everything ` +
      `you saved is still there. Your account is now on the free plan, so new ` +
      `syncs pause while you are over the free limits, but you can keep reading ` +
      `everything on all your devices.</p>` +
      `<p>To pick up where you left off, update your payment method or renew at ` +
      `<a href="${manage}">relic.space/account</a>.</p>` +
      `<p>Questions? Reply to this email or write to ` +
      `<a href="mailto:support@relic.space">support@relic.space</a>.</p>` +
      `<p>- The Relic team</p>`;

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Relic <no-reply@relic.space>",
        to,
        subject: "Your Relic plan has lapsed. Your data is safe",
        text,
        html,
      }),
    });
    console.log(JSON.stringify({ evt: "plan_lapsed_email", account: accountId, ok: r.ok, status: r.status }));
  } catch (e) {
    console.log(JSON.stringify({ evt: "plan_lapsed_email_error", account: accountId, err: String(e) }));
  }
}

// ---- scheduled reconcile (cron) --------------------------------------------
// Stripe is the source of truth. Pull live subscriptions and force D1 to match,
// repairing any drift from missed webhooks, DLQ exhaustion, or manual edits.
// Funnels through the same writeSub() as the webhook so there is one apply path.
export async function reconcile(env: Env): Promise<void> {
  if (!env.STRIPE_SECRET_KEY) return;
  const map = priceMap(env);
  const now = Math.floor(Date.now() / 1000);
  let startingAfter: string | undefined;
  let pages = 0;
  do {
    const qs = new URLSearchParams({ status: "all", limit: "100" });
    if (startingAfter) qs.set("starting_after", startingAfter);
    // deno-lint-ignore no-explicit-any
    let page: any;
    try {
      page = await stripeGet(env, `/subscriptions?${qs.toString()}`);
    } catch {
      return; // transient — the next cron tick retries
    }
    // deno-lint-ignore no-explicit-any
    const subs: any[] = page.data ?? [];
    for (const sub of subs) {
      const accountId = (sub?.metadata?.account_id as string | undefined) ??
        (await accountByCustomer(env, sub.customer));
      if (!accountId) continue;
      const status = String(sub.status);
      const grant = status === "active" || status === "trialing" || status === "past_due";
      await writeSub(env, accountId, {
        stripe_customer_id: sub.customer ?? null,
        stripe_subscription_id: sub.id ?? null,
        tier: grant ? tierFromSub(sub, map) : "free",
        status,
        current_period_end: sub.current_period_end ?? null,
        cancel_at_period_end: sub.cancel_at_period_end ? 1 : 0,
        grace_until: status === "past_due" ? now + GRACE_DAYS * 86400 : null,
        updated_stripe_ts: sub.created ?? now,
      });
    }
    startingAfter = page.has_more && subs.length ? subs[subs.length - 1].id : undefined;
  } while (startingAfter && ++pages < 50);
  if (startingAfter) {
    // Bounded so one cron tick can't run unbounded; surface the truncation so
    // it isn't silently incomplete (raise the cap or shard by customer at scale).
    console.warn(
      `[reconcile] capped at ${pages} pages (~${pages * 100} subs); ` +
        "remaining subscriptions not reconciled this run",
    );
  }
}
