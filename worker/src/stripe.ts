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
import { isTier, type Tier, TIERS } from "./tiers";
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

// Which upgrade button opened this checkout. It rides through to Stripe as
// metadata on both the Checkout Session and the Subscription, and it is the
// ONLY conversion measurement we have: no client sends telemetry, so the tag on
// the button someone actually pressed is the whole funnel.
//
// Closed list on purpose. Anything else is dropped silently rather than
// rejected, because a client sending an unknown tag is a client we should still
// take money from.
const CHECKOUT_SOURCES = new Set([
  "ring_strip",
  "ring_search",
  "ring_footer",
  "ring_chip",
  "ring_notification",
  "ring_settings",
  "ring_email",
  "ring_web",
]);

// ---- POST /stripe/checkout -------------------------------------------------
export async function createCheckout(req: Request, env: Env, auth: Auth): Promise<Response> {
  if (!env.STRIPE_SECRET_KEY) return err(503, "billing_unconfigured", "billing not enabled");
  let price_id = "";
  let source = "";
  try {
    const body = await req.json<{ price_id: string; source?: string }>();
    price_id = body.price_id;
    if (typeof body.source === "string") source = body.source;
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
  // On the session for "which button started this checkout", and on the
  // subscription so the tag survives into the customer record we can still
  // query months later.
  if (CHECKOUT_SOURCES.has(source)) {
    form.set("metadata[source]", source);
    form.set("subscription_data[metadata][source]", source);
  }
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
// is part of this update AND the subscriptions write actually landed.
//
// ORDERING GUARD: webhook delivery is not ordered, and the queue consumer plus
// the reconcile cron are two more producers on the same row. Without the guard
// an old customer.subscription.updated redelivered after a newer one silently
// reinstated the stale status and tier. When the caller supplies
// updated_stripe_ts, an event older than what the row already holds is dropped;
// `>=` (not `>`) so two events inside the same second both apply. Callers with
// no ts field (checkout.session.completed, which only fills in the Stripe ids)
// keep the old unconditional behaviour.
//
// Returns whether the row was written, so a caller can tell a real apply from a
// skipped one.
async function writeSub(
  env: Env,
  accountId: string,
  fields: Record<string, string | number | null>,
): Promise<boolean> {
  const cols = ["account_id", ...Object.keys(fields)];
  const placeholders = cols.map((_, i) => `?${i + 1}`).join(",");
  const updates = Object.keys(fields).map((k) => `${k} = excluded.${k}`).join(", ");
  const guard = "updated_stripe_ts" in fields
    ? " WHERE excluded.updated_stripe_ts >= subscriptions.updated_stripe_ts"
    : "";
  // RETURNING rather than meta.changes: a DO UPDATE the guard filtered out
  // yields no row at all, which is an unambiguous "did not apply".
  const wrote = await env.DB.prepare(
    `INSERT INTO subscriptions (${cols.join(",")}) VALUES (${placeholders})
     ON CONFLICT(account_id) DO UPDATE SET ${updates}, updated_at = unixepoch()${guard}
     RETURNING account_id`,
  ).bind(accountId, ...Object.values(fields)).first<{ account_id: string }>();
  if (!wrote) return false;
  if ("tier" in fields) {
    await env.DB.prepare(
      `INSERT INTO accounts (account_id, tier) VALUES (?1, ?2)
       ON CONFLICT(account_id) DO UPDATE SET tier = excluded.tier`,
    ).bind(accountId, fields.tier).run();
  }
  return true;
}

// The ONE place a Stripe subscription object turns into our billing state.
// customer.subscription.created/updated and the reconcile cron both go through
// it, because as two copies they drifted: reconcile re-stamped grace_until on
// every 6-hourly tick, so graceSweep's `grace_until < now` never matched and a
// failed card kept its paid tier until Stripe's own dunning gave up.
//
// GRACE IS MONOTONE. The first past_due sets the deadline; every later past_due
// reads the existing stamp back and leaves it alone, so the window really does
// close GRACE_DAYS after the first failure.
async function applySubscriptionState(
  env: Env,
  accountId: string,
  // deno-lint-ignore no-explicit-any
  sub: any,
  map: Record<string, Tier>,
  now: number,
  stripeTs: number,
): Promise<boolean> {
  const status = String(sub.status);
  // Paid outright, as opposed to a past_due account still inside its grace
  // window. Only this restores evicted rows: grace is a reprieve on an account
  // that already had everything, not a new purchase.
  const paidNow = status === "active" || status === "trialing";
  let graceUntil: number | null = null;
  // active/trialing grant outright. past_due grants only inside the window.
  // Anything else (incomplete, unpaid, canceled, paused) grants nothing.
  let grant = status === "active" || status === "trialing";
  if (status === "past_due") {
    const row = await env.DB.prepare(
      "SELECT grace_until FROM subscriptions WHERE account_id = ?1",
    ).bind(accountId).first<{ grace_until: number | null }>();
    graceUntil = row?.grace_until ?? now + GRACE_DAYS * 86400;
    grant = now < graceUntil;
  }

  const fields: Record<string, string | number | null> = {
    stripe_customer_id: sub.customer ?? null,
    stripe_subscription_id: sub.id ?? null,
    status,
    current_period_end: sub.current_period_end ?? null,
    cancel_at_period_end: sub.cancel_at_period_end ? 1 : 0,
    grace_until: graceUntil,
    updated_stripe_ts: stripeTs,
  };
  if (grant) fields.tier = tierFromSub(sub, map);
  else if (status !== "past_due") fields.tier = "free";
  // A past_due whose grace has already run out deliberately writes NO tier:
  // graceSweep has already moved accounts.tier to free, and subscriptions.tier
  // has to keep holding the ENTITLED tier because that is what invoice.paid
  // restores from. Writing "free" here would erase the entitlement and strand a
  // customer on free after their card finally went through.
  const wrote = await writeSub(env, accountId, fields);
  if (wrote && paidNow && (fields.tier === "pro" || fields.tier === "max")) {
    await restoreEvicted(env, accountId, now);
  }
  return wrote;
}

/// Hand back every copy the free history ring pushed out of view.
///
/// Three statements, in this order, so no uid list has to be carried:
///   1. drop the tombstones for the rows that are STILL marked evicted,
///   2. move the count from evicted_count into history_count,
///   3. clear the flags and bump updated_at.
/// Step 3 last is what lets steps 1 and 2 identify the same set. Bumping
/// updated_at is what puts the rows back in the next pull, and dropping the
/// tombstones is what stops the same pull deleting them again (the client
/// applies /relics first and /tombstones second, and a fresh device would
/// otherwise see both).
///
/// Idempotent: Stripe replays events, and a second run finds nothing evicted and
/// changes nothing. Returns how many rows came back, for the log line.
export async function restoreEvicted(env: Env, acct: string, now: number): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT evicted_count FROM account_usage WHERE account_id = ?1",
  ).bind(acct).first<{ evicted_count: number }>();
  const n = row?.evicted_count ?? 0;
  // Nothing to hand back, and we KNOW it (the cached row exists and says zero).
  // Worth the early return: Stripe sends a subscription.updated for every
  // renewal of every paying account, and this is what stops each one walking
  // that account's relic index for rows that are not there.
  if (row && n === 0) return 0;

  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM tombstones WHERE account_id = ?1 AND uid IN (
         SELECT uid FROM relic_meta WHERE account_id = ?1 AND evicted = 1)`,
    ).bind(acct),
    env.DB.prepare(
      `UPDATE account_usage
          SET history_count = history_count + evicted_count, evicted_count = 0
        WHERE account_id = ?1`,
    ).bind(acct),
    env.DB.prepare(
      "UPDATE relic_meta SET evicted = 0, updated_at = ?2 WHERE account_id = ?1 AND evicted = 1",
    ).bind(acct, now),
  ]);

  if (n > 0) console.log(JSON.stringify({ evt: "ring_restore", account: acct, n }));
  return n;
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
      if (accountId) await applySubscriptionState(env, accountId, obj, map, now, ev.created);
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
        const row = await env.DB.prepare(
          "SELECT grace_until FROM subscriptions WHERE account_id = ?1",
        ).bind(accountId).first<{ grace_until: number | null }>();
        await writeSub(env, accountId, {
          status: "past_due",
          // Only the FIRST failure starts the clock. Stripe retries a failed
          // invoice several times across the dunning window and every retry is
          // another payment_failed; re-stamping on each one pushed the deadline
          // out again, so the grace period could never expire.
          grace_until: row?.grace_until ?? now + GRACE_DAYS * 86400,
          updated_stripe_ts: ev.created,
        });
      }
      break;
    }
    case "invoice.paid":
    case "invoice.payment_succeeded": {
      const accountId = await accountByCustomer(env, obj.customer);
      if (accountId) {
        // Clearing status and grace was never enough to undo a sweep
        // downgrade: graceSweep moves accounts.tier to free and leaves
        // subscriptions.tier holding the entitlement, so paying again has to
        // copy that entitlement back across. Passing `tier` is also what makes
        // writeSub mirror into accounts at all, which is what graceSweep's own
        // comment already promised this event would do.
        const row = await env.DB.prepare(
          "SELECT tier FROM subscriptions WHERE account_id = ?1",
        ).bind(accountId).first<{ tier: string }>();
        await writeSub(env, accountId, {
          status: "active",
          grace_until: null,
          tier: isTier(row?.tier) ? row.tier : "free",
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

// ---- scheduled free-limit nudges (cron) ------------------------------------
// One email, once, to a free account that has reached a wall. The free plan has
// two of them and each gets its own letter and its own stamp column:
//
//   ring_evicted > 0          -> the oldest copies have started dropping out of
//                                view (TIERS.free.ring)   -> ring_email_at
//   vault_count >= free cap   -> the kept-forever shelf is full
//                                (TIERS.free.vault)       -> vault_email_at
//
// These are the only surfaces that reach somebody running an old build, which
// is exactly who is over a limit today.
//
// A stamp means "never try this account again", so it is only written once we
// know retrying is pointless: see stampable(). Before 2026-09-17 it went down
// after every attempt, and a single bad Resend key on 2026-09-10 permanently
// silenced every account it touched. A server problem must not cost us the
// person.
const NUDGE_EMAIL_BATCH = 50;

/// Should this account be stamped, and so never tried again?
///
/// Yes when the mail went out, and yes on a 422, which is Resend telling us the
/// address itself is the problem. No amount of waiting fixes a dead mailbox.
///
/// Everything else is ours, not theirs: a rejected key (401/403), a rate limit
/// (429), a 5xx, a network blip. Those leave the row NULL so the next tick tries
/// again, which is what lets a fixed key heal the backlog by itself.
const stampable = (ok: boolean, status: number): boolean => ok || status === 422;

interface NudgeMail {
  subject: string;
  text: string;
  html: string;
}

/// Posts one mail to Resend and reports whether the row may be stamped.
/// Never throws: a nudge must not be able to fail the sweeps around it.
async function sendNudgeMail(
  env: Env,
  evt: string,
  accountId: string,
  to: string,
  mail: NudgeMail,
): Promise<boolean> {
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
        from: "Relic <no-reply@relic.space>",
        to,
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
      }),
    });
    ok = r.ok;
    status = r.status;
  } catch (e) {
    console.log(JSON.stringify({ evt, account: accountId, ok: false, err: String(e) }));
    return false; // a thrown fetch is always ours to retry
  }
  console.log(JSON.stringify({ evt, account: accountId, ok, status }));
  return stampable(ok, status);
}

/// Free accounts with an address that have reached `predicate` and have not been
/// told yet. `stampColumn` and the NULL check are the same column, so the two
/// sweeps can never read each other's memory.
async function dueForNudge(
  env: Env,
  stampColumn: "ring_email_at" | "vault_email_at",
  predicate: string,
  bind: unknown[],
): Promise<{ account_id: string; email: string }[]> {
  const r = await env.DB.prepare(
    `SELECT u.account_id, a.email
       FROM account_usage u
       JOIN accounts a ON a.account_id = u.account_id
      WHERE ${predicate}
        AND u.${stampColumn} IS NULL
        AND a.email IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.account_id = u.account_id)
      LIMIT ?${bind.length + 1}`,
  ).bind(...bind, NUDGE_EMAIL_BATCH).all<{ account_id: string; email: string }>();
  return r.results ?? [];
}

async function stampNudge(
  env: Env,
  stampColumn: "ring_email_at" | "vault_email_at",
  accountId: string,
  now: number,
): Promise<void> {
  await env.DB.prepare(
    `UPDATE account_usage SET ${stampColumn} = ?2 WHERE account_id = ?1`,
  ).bind(accountId, now).run();
}

export async function ringNudgeSweep(env: Env): Promise<void> {
  // Checked BEFORE any query: a self-host instance has no Resend key and this
  // must not cost it a database read on every janitor tick.
  if (!env.RESEND_API_KEY) return;

  const now = Math.floor(Date.now() / 1000);
  const due = await dueForNudge(env, "ring_email_at", "u.ring_evicted > 0", []);

  for (const row of due) {
    if (await sendNudgeMail(env, "ring_email", row.account_id, row.email, ringNudgeMail())) {
      await stampNudge(env, "ring_email_at", row.account_id, now);
    }
  }
}

export async function vaultCapSweep(env: Env): Promise<void> {
  if (!env.RESEND_API_KEY) return;
  // Unlimited vault on this tier table means there is no wall to write about.
  const cap = TIERS.free.vault;
  if (cap === null) return;

  const now = Math.floor(Date.now() / 1000);
  const due = await dueForNudge(env, "vault_email_at", "u.vault_count >= ?1", [cap]);

  for (const row of due) {
    if (await sendNudgeMail(env, "vault_email", row.account_id, row.email, vaultCapMail())) {
      await stampNudge(env, "vault_email_at", row.account_id, now);
    }
  }
}

function ringNudgeMail(): NudgeMail {
  const cap = TIERS.free.ring; // the number in the copy is the live cap
  const upgrade = "https://relic.space/upgrade?source=ring_email";
  return {
    subject: "Your oldest copies are dropping off",
    text:
      `You've copied more than ${cap} things into Relic. Nice.\n\n` +
      `The free plan keeps your last ${cap} in view, so your oldest copies have ` +
      `started to drop out of search. Relic still has them.\n\n` +
      `Pro keeps every copy, forever, for $7 a month or $60 a year. Upgrade and ` +
      `the ones that dropped off come straight back.\n\n` +
      `${upgrade}\n\n` +
      `Reply to this email if anything is off.\n\n` +
      `The Relic team`,
    html:
      `<p>You've copied more than ${cap} things into Relic. Nice.</p>` +
      `<p>The free plan keeps your last ${cap} in view, so your oldest copies ` +
      `have started to drop out of search. Relic still has them.</p>` +
      `<p>Pro keeps every copy, forever, for $7 a month or $60 a year. Upgrade ` +
      `and the ones that dropped off come straight back.</p>` +
      `<p><a href="${upgrade}">Upgrade</a></p>` +
      `<p>Reply to this email if anything is off.</p>` +
      `<p>The Relic team</p>`,
  };
}

function vaultCapMail(): NudgeMail {
  const cap = TIERS.free.vault; // the number in the copy is the live cap
  const upgrade = "https://relic.space/upgrade?source=vault_email";
  return {
    subject: "Your Relic vault is full",
    text:
      `You've filled your Relic vault. The free plan keeps ${cap} things ` +
      `forever, and you are at all ${cap}.\n\n` +
      `Relic will stop keeping new ones until you make room, so anything you ` +
      `copy from here lands in your history and ages out of it in time.\n\n` +
      `Pro lifts the limit for $7 a month or $60 a year. Everything you have ` +
      `already kept stays exactly where it is.\n\n` +
      `${upgrade}\n\n` +
      `Reply to this email if anything is off.\n\n` +
      `The Relic team`,
    html:
      `<p>You've filled your Relic vault. The free plan keeps ${cap} things ` +
      `forever, and you are at all ${cap}.</p>` +
      `<p>Relic will stop keeping new ones until you make room, so anything ` +
      `you copy from here lands in your history and ages out of it in time.</p>` +
      `<p>Pro lifts the limit for $7 a month or $60 a year. Everything you ` +
      `have already kept stays exactly where it is.</p>` +
      `<p><a href="${upgrade}">Upgrade</a></p>` +
      `<p>Reply to this email if anything is off.</p>` +
      `<p>The Relic team</p>`,
  };
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
      // `now`, NOT sub.created. sub.created is the subscription's birth date,
      // so against writeSub's ordering guard it would lose every comparison
      // with a real webhook timestamp and silently mute reconcile forever,
      // which is exactly the drift repair this cron exists to be.
      await applySubscriptionState(env, accountId, sub, map, now, now);
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
