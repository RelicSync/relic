// DELETE /account — irreversible account teardown. Cancels the Stripe
// subscription, wipes every R2 object under the account prefix (keyparams, relic
// envelopes, blobs), drops all per-account D1 rows, and clears the account's KV
// pairing/revocation keys. Because content is E2E-encrypted and the Worker never
// held the key, deleting the R2 objects + keyparams makes it unrecoverable — a
// true delete, not a soft one.
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
    env.DB.prepare("DELETE FROM tombstones WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM devices WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM tokens WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM subscriptions WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM shares WHERE account_id = ?1").bind(acct),
    env.DB.prepare("DELETE FROM accounts WHERE account_id = ?1").bind(acct),
  ]);

  // 4) KV: pairing slots + revocation markers for this account.
  if (env.PAIR) {
    await purgeKvPrefix(env.PAIR, `pair:${acct}:`);
    await purgeKvPrefix(env.PAIR, `rev:${acct}:`);
  }

  return json({ deleted: true, objects });
}
