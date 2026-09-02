// DELETE /account — irreversible account teardown. Cancels the Stripe
// subscription, wipes every R2 object under the account prefix (keyparams, relic
// envelopes, blobs), drops all per-account D1 rows, clears the account's KV
// pairing/revocation keys, and finally deletes the Supabase auth identity.
// Because content is E2E-encrypted and the Worker never held the key, deleting
// the R2 objects + keyparams makes it unrecoverable — a true delete, not a soft
// one.
//
// ORDER MATTERS: Relic's own data goes first, the identity last. If the identity
// call fails we still return success (the data really is gone, and the client
// has already signed itself out); the failure is logged loudly for manual
// cleanup. Deleting the identity first would risk the opposite: the auth row
// gone while the vault survives, unreachable and undeletable.
//
// NOTE: billing_events is a GLOBAL Stripe idempotency ledger keyed by event id
// (no account_id) — intentionally left intact so replays stay inert.

import type { Env } from "./env";
import type { Auth } from "./auth";
import { json } from "./http";
import { cancelSubscription } from "./stripe";

// Delete every R2 object under a key prefix, in batches (R2 delete takes up to
// 1000 keys; list is cursor-paginated).
async function purgeR2Prefix(env: Env, prefix: string): Promise<number> {
  let cursor: string | undefined;
  let n = 0;
  do {
    const listed = await env.STORE.list({ prefix, cursor, limit: 1000 });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length) {
      await env.STORE.delete(keys);
      n += keys.length;
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return n;
}

// Delete every KV key under a prefix (pairing slots + revocation markers). KV has
// no bulk delete, so deletes go one-by-one (cursor-paginated list).
async function purgeKvPrefix(kv: KVNamespace, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const listed = await kv.list({ prefix, cursor });
    await Promise.all(listed.keys.map((k) => kv.delete(k.name)));
    cursor = listed.list_complete ? undefined : listed.cursor;
  } while (cursor);
}

// Delete the user's Supabase (GoTrue) auth identity via the admin API. Without
// this, "delete my account" only deletes the account's DATA — the auth row, and
// the email address in it, survives and can still be signed in against. App
// Store Guideline 5.1.1(v) requires the account itself to go, and the privacy
// policy promises the email is removed.
//
// Best-effort, in the same spirit as the Stripe cancel above and the Resend
// sends in stripe.ts: it can never fail the deletion. Skipped silently when
// there is no Supabase identity to delete (legacy device-token auth, self-host
// deployments — see selfhost/src/adapters/env.ts) or when the service-role key
// isn't configured. A configured-but-failing call logs at error level WITH the
// sub, which is the handle a maintainer needs to finish the job by hand.
async function deleteSupabaseUser(env: Env, auth: Auth): Promise<void> {
  const sub = auth.supabaseSub;
  if (!auth.supabase || !sub) return; // no Supabase identity behind this request
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    console.log(JSON.stringify({
      evt: "supabase_user_delete_skipped",
      account: auth.account,
      reason: !env.SUPABASE_URL ? "no_supabase_url" : "no_service_role_key", // scan-ok: key name in a log reason
    }));
    return;
  }
  // NOTE: SUPABASE_URL is the canonical auth origin (custom auth domain in
  // production, the *.supabase.co project URL otherwise). Both proxy GoTrue, so
  // /auth/v1/admin/users/{id} is correct either way. The key goes in BOTH
  // Authorization and apikey — GoTrue's admin routes want both.
  const base = env.SUPABASE_URL.replace(/\/+$/, "");
  try {
    const r = await fetch(`${base}/auth/v1/admin/users/${encodeURIComponent(sub)}`, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      },
    });
    // 404 = already gone (a retried delete). Same end state, so: success.
    if (r.ok || r.status === 404) {
      console.log(JSON.stringify({
        evt: "supabase_user_deleted", account: auth.account, status: r.status,
      }));
      return;
    }
    console.error(JSON.stringify({
      evt: "supabase_user_delete_failed",
      account: auth.account,
      sub, // logged on purpose: the identity that must be deleted by hand
      status: r.status,
      body: (await r.text().catch(() => "")).slice(0, 300),
    }));
  } catch (e) {
    console.error(JSON.stringify({
      evt: "supabase_user_delete_error", account: auth.account, sub, err: String(e),
    }));
  }
}

// Whether the IdP actually dropped this account's sessions.
//   "ok"      - GoTrue accepted the global logout; every refresh token is dead.
//   "skipped" - nothing to revoke there (legacy device-token auth, self-host,
//               or no SUPABASE_URL configured). Not a failure.
//   "failed"  - configured, attempted, refused. The caller must NOT act as
//               though revocation happened.
export type SessionRevocation = "ok" | "skipped" | "failed";

// Revoke every refresh token for this identity at the IdP: GoTrue's
// POST /logout?scope=global.
//
// WHY THE CALLER'S OWN TOKEN AND NOT THE SERVICE-ROLE KEY. GoTrue's /admin
// surface has no logout or session route at all — /logout is the only one, and
// it sits behind requireAuthentication, so it authenticates AS THE USER. The
// service-role key cannot reach it. That also means there is no way to revoke a
// single session: `scope=global` is the only granularity on offer, which is why
// removing one device necessarily signs the account out everywhere.
//
// Unlike deleteSupabaseUser above this is NOT best-effort-and-forget. Its result
// decides whether the caller stamps accounts.min_valid_iat, and a watermark that
// outlives its refresh tokens is worse than no watermark at all: it 401s every
// honest device for an hour while the removed one quietly refreshes back in.
export async function revokeSupabaseSessions(
  env: Env,
  auth: Auth,
  accessToken: string,
): Promise<SessionRevocation> {
  if (!auth.supabase || !auth.supabaseSub) return "skipped"; // no IdP session behind this
  if (!env.SUPABASE_URL) {
    console.log(JSON.stringify({
      evt: "supabase_signout_skipped", account: auth.account, reason: "no_supabase_url",
    }));
    return "skipped";
  }
  const base = env.SUPABASE_URL.replace(/\/+$/, "");
  try {
    const r = await fetch(`${base}/auth/v1/logout?scope=global`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        ...(env.SUPABASE_ANON_KEY ? { apikey: env.SUPABASE_ANON_KEY } : {}),
      },
    });
    // 2xx only (GoTrue answers 204). A 401 is deliberately NOT treated as
    // success: it means this token bought us nothing, and the other sessions
    // may well be alive, so stamping off the back of it would be a lie.
    if (r.ok) {
      console.log(JSON.stringify({
        evt: "supabase_signout", account: auth.account, status: r.status,
      }));
      return "ok";
    }
    console.error(JSON.stringify({
      evt: "supabase_signout_failed",
      account: auth.account,
      status: r.status,
      body: (await r.text().catch(() => "")).slice(0, 300),
    }));
    return "failed";
  } catch (e) {
    console.error(JSON.stringify({
      evt: "supabase_signout_error", account: auth.account, err: String(e),
    }));
    return "failed";
  }
}

export async function deleteAccount(env: Env, auth: Auth): Promise<Response> {
  const acct = auth.account;

  // 1) Stop billing first so nothing re-provisions mid-teardown. Best-effort.
  const sub = await env.DB.prepare(
    "SELECT stripe_subscription_id FROM subscriptions WHERE account_id = ?1",
  ).bind(acct).first<{ stripe_subscription_id: string | null }>();
  if (sub?.stripe_subscription_id) {
    try {
      await cancelSubscription(env, sub.stripe_subscription_id);
    } catch {
      /* best-effort; the D1 teardown below removes our mirror regardless */
    }
  }

  // 2) R2: keyparams + relic envelopes + blobs all live under users/{acct}/.
  // Share ciphertexts live under shares/<id> (public namespace) — delete them
  // by the account's D1 rows before those rows are dropped below.
  const objects = await purgeR2Prefix(env, `users/${acct}/`);
  const shares = await env.DB.prepare(
    "SELECT id FROM shares WHERE account_id = ?1",
  ).bind(acct).all<{ id: string }>();
  for (const { id } of shares.results) {
    await env.STORE.delete(`shares/${id}`);
  }

  // 3) D1: every per-account row. billing_events is global (no account_id) — kept.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM relic_meta WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM account_usage WHERE account_id = ?1").bind(acct),
    // purgeR2Prefix above cannot see in-flight multipart parts (list() does not
    // return them), so the reservations have to be dropped here explicitly or
    // they would outlive the account they belong to.
    env.DB.prepare("DELETE FROM mpu_state WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM ai_meta WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM tombstones WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM devices WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM tokens WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM subscriptions WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM shares WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM account_links WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM accounts WHERE account_id = ?1").bind(acct),
  ]);

  // 4) KV: pairing slots + revocation markers for this account.
  if (env.PAIR) {
    await purgeKvPrefix(env.PAIR, `pair:${acct}:`);
    await purgeKvPrefix(env.PAIR, `rev:${acct}:`);
  }

  // 5) LAST: the Supabase auth identity itself. Best-effort — see the function.
  await deleteSupabaseUser(env, auth);

  return json({ deleted: true, objects });
}
