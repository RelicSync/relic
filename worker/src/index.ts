// Relic backend Worker — implements docs/api.md against R2 (bodies) + D1
// (auth, plaintext-meta index). The Worker never sees plaintext content.
//
// Layout: this file is the router + the encrypted-sync data plane. Auth lives in
// auth.ts (Supabase JWT bridge + legacy device token), billing in stripe.ts,
// tier caps in tiers.ts, bindings/config in env.ts, HTTP helpers in http.ts.

import type { Env, StripeMessage } from "./env";
import { TIERS } from "./tiers";
import {
  BLOB_ID,
  blobR2Key,
  mpuAbort,
  mpuComplete,
  mpuCreate,
  mpuPart,
  sizedBody,
} from "./blob";
import { readUsage, usageDelta } from "./usage";
import { type Auth, authenticate, REV_TTL, revKey } from "./auth";
import { clampLimit, CORS, err, json } from "./http";
import { clientIp, rateLimit } from "./ratelimit";
import { deleteAccount } from "./account";
import {
  createShare,
  fetchShareBlob,
  isShareId,
  revokeShare,
  sharePageResponse,
  sweepShares,
} from "./share";
import {
  consumeStripeBatch,
  createCheckout,
  createPortal,
  graceSweep,
  listPlans,
  reconcile,
  stripeWebhook,
} from "./stripe";
import { sweepAbandonedMpus, sweepOrphanBlobs, sweepTombstones } from "./sweep";
import { claimAi, listAi, putAi, releaseAi } from "./ai";
import { pokeSync, SyncSocket } from "./notify";

// Re-exported so Wrangler can bind the Durable Object class (it must be exported
// from the Worker's main module).
export { SyncSocket };

interface Envelope {
  v: number;
  uid: string;
  created_at: number;
  updated_at: number;
  byte_size: number;
  promoted: boolean;
  blob_key?: string;
  n: string;
  ct: string;
}

const relicKey = (acct: string, uid: string) => `users/${acct}/relics/${uid}`;
const keyparamsKey = (acct: string) => `users/${acct}/keyparams.json`;

// --- QR pairing relay (docs/cloudflare/13-device-onboarding.md §5). The relay is
// zero-knowledge: it stores only opaque base64 blobs under an account-scoped key
// with a short TTL, single-use on claim. Slots: np / tp (sealed ephemeral
// pubkeys) and mk (the sealed master key). ---
const PAIR_TTL = 120; // KV min expirationTtl is 60s; 120 covers the 90s client window
const PAIR_SLOTS = new Set(["np", "tp", "mk"]);
const pairKey = (acct: string, id: string, slot: string) =>
  `pair:${acct}:${id}:${slot}`;
const isPairId = (s: string) => /^[0-9a-fA-F-]{8,40}$/.test(s);

// Non-revoked devices for an account (the settings "your devices" list).
async function listDevices(env: Env, acct: string, thisDev?: string) {
  const rows = await env.DB.prepare(
    `SELECT device_id, label, platform, last_seen_at, app_version FROM devices
     WHERE account_id = ?1 AND revoked_at IS NULL ORDER BY last_seen_at DESC`,
  ).bind(acct).all<{
    device_id: string;
    label: string | null;
    platform: string | null;
    last_seen_at: number;
    app_version: string | null;
  }>();
  return rows.results.map((d) => ({
    ...d,
    this_device: !!thisDev && d.device_id === thisDev,
  }));
}

// Throttled "device is alive" touch on the authed hot path. Without this,
// last_seen_at only moves on registration (= once per connect), which made the
// Devices screen useless for spotting stale/outdated installs. The in-memory
// map absorbs warm-isolate repeats; the SQL predicate makes cold-isolate
// repeats a rows_written=0 UPDATE, so D1 sees at most ~24 real writes per
// device per day. UPDATE-only: never creates rows, never thaws revoked ones.
const TOUCH_INTERVAL = 3600;
const lastTouch = new Map<string, number>();
function touchDevice(env: Env, ctx: ExecutionContext | undefined, auth: Auth, req: Request) {
  if (!auth.device) return;
  const now = Math.floor(Date.now() / 1000);
  const k = `${auth.account}:${auth.device}`;
  if ((lastTouch.get(k) ?? 0) > now - TOUCH_INTERVAL) return;
  lastTouch.set(k, now);
  const ver = req.headers.get("X-Relic-App-Version")?.slice(0, 32) ?? null;
  const p = env.DB.prepare(
    `UPDATE devices SET last_seen_at = ?3, app_version = COALESCE(?4, app_version)
     WHERE account_id = ?1 AND device_id = ?2 AND revoked_at IS NULL
       AND last_seen_at < ?3 - ${TOUCH_INTERVAL}`,
  ).bind(auth.account, auth.device, now, ver).run();
  if (ctx) ctx.waitUntil(p);
  else void p.catch(() => {});
}

// VERIFY-TO-SYNC gate (env.VERIFY_GATE === "on"). Blocks the sync WRITE surface
// for Supabase identities whose access token shows an unverified email. Reads,
// deletes, billing, device, and pairing routes stay open; legacy device-token
// auth is grandfathered (auth.supabase is unset there). Cheap: pure string
// match on the request we already authenticated, no extra network calls.
const isSyncWrite = (method: string, path: string): boolean =>
  (method === "PUT" && /^\/relic\/[A-Za-z0-9-]+$/.test(path)) ||
  (method === "PUT" && path === "/keyparams") ||
  // Publishing a generated title is a sync write like any other. Claiming and
  // releasing are not: they move no data, and letting an unverified account
  // hold leases it can never publish against would park work indefinitely.
  (method === "PUT" && /^\/ai\/[^/]+$/.test(path)) ||
  (method === "POST" && path === "/blob") ||
  (method === "POST" && /^\/blob\/mpu(\/.*)?$/.test(path)); // create + complete

// The encrypted-sync data plane, for the RL_SYNC gate below. /sync/socket is
// deliberately absent: the DO's own MAX_SOCKETS cap governs that, and a
// long-lived upgrade is not a request-rate problem.
const isDataPlane = (path: string): boolean =>
  path === "/relics" || path === "/tombstones" || path === "/keyparams" ||
  path === "/ai" || path.startsWith("/relic/") || path.startsWith("/blob") ||
  path.startsWith("/ai/");

function syncWriteGate(env: Env, auth: Auth, method: string, path: string): Response | null {
  if (env.VERIFY_GATE !== "on") return null;
  if (!auth.supabase) return null; // legacy device token — grandfathered
  if (auth.emailVerified !== false) return null; // verified or unknown -> allow
  if (!isSyncWrite(method, path)) return null; // reads/deletes stay open
  return err(403, "email_unverified", "Confirm your email to start syncing.");
}

function validEnvelope(e: unknown, uid: string): e is Envelope {
  const env = e as Envelope;
  return (
    !!env && env.v === 1 && env.uid === uid &&
    Number.isFinite(env.created_at) && Number.isFinite(env.updated_at) &&
    // byte_size is client-declared and feeds the account_usage counters, so it
    // has to be a whole non-negative number. Number.isFinite let a negative
    // through, and one negative push permanently zeroed an account's cached
    // storage total (usage.ts floors it at 0), which removed the only
    // backpressure the data plane has.
    Number.isInteger(env.byte_size) && env.byte_size >= 0 &&
    typeof env.promoted === "boolean" &&
    typeof env.n === "string" && typeof env.ct === "string" &&
    (env.blob_key === undefined || typeof env.blob_key === "string")
  );
}

// blobR2Key + the chunked-upload routes live in blob.ts; the cached account
// totals the quota checks read live in usage.ts.

/// The bits of a relic_meta row a delete needs: the blob to evict from R2, and
/// the two numbers to subtract from the cached totals. Callers already look the
/// row up to find blob_key, so this costs them nothing extra.
export interface DeletedMeta {
  blob_key: string | null;
  byte_size: number;
  promoted: number;
}

export async function deleteRelic(env: Env, acct: string, uid: string, meta: DeletedMeta | null, deletedAt: number) {
  await env.STORE.delete(relicKey(acct, uid));
  if (meta?.blob_key) await env.STORE.delete(blobR2Key(acct, meta.blob_key));
  const stmts = [
    env.DB.prepare("DELETE FROM relic_meta WHERE account_id = ?1 AND uid = ?2").bind(acct, uid),
    // The AI record dies with its relic. Leaving it would strand a row no relic
    // can ever claim, and would resurrect a title if the uid were ever reused.
    env.DB.prepare("DELETE FROM ai_meta WHERE account_id = ?1 AND uid = ?2").bind(acct, uid),
    env.DB.prepare(
      "INSERT OR REPLACE INTO tombstones (account_id, uid, deleted_at) VALUES (?1, ?2, ?3)",
    ).bind(acct, uid, deletedAt),
  ];
  // Same batch as the row it accounts for, so the cache cannot drift from the
  // table. No base: a delete never needs to seed a missing row (the next read
  // recomputes it), it only adjusts one that already exists.
  if (meta) stmts.push(usageDelta(env, acct, -meta.byte_size, -meta.promoted, null));
  await env.DB.batch(stmts);
}

export async function putRelic(req: Request, env: Env, auth: Auth, uid: string, ctx?: ExecutionContext): Promise<Response> {
  const caps = TIERS[auth.tier];
  const body = await req.text();
  if (body.length > caps.item * 1.5) return err(413, "too_large", "envelope exceeds tier cap");
  let envelope: unknown;
  try {
    envelope = JSON.parse(body);
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  if (!validEnvelope(envelope, uid)) return err(400, "invalid_envelope", "bad shape or uid mismatch");
  if (envelope.byte_size > caps.item) return err(413, "too_large", "byte_size exceeds tier cap");
  // Plausibility floor on the other direction: byte_size is what the quota is
  // charged against, so UNDER-declaring it buys free storage. We cannot demand
  // exact agreement, because shipped clients compute byte_size from plaintext
  // utf8 length or from bundle length and both legitimately diverge from the
  // base64 body (real bodies run ~1.34x byte_size plus a few hundred bytes).
  // 4x plus 16 KiB leaves roughly 3x headroom over the worst real client, so
  // nothing in the wild trips it while under-declaration stays bounded.
  if (body.length > envelope.byte_size * 4 + 16384) {
    return err(400, "invalid_envelope", "byte_size is implausible for this body");
  }

  // deletion wins over late pushes from offline devices
  const tomb = await env.DB.prepare(
    "SELECT 1 FROM tombstones WHERE account_id = ?1 AND uid = ?2",
  ).bind(auth.account, uid).first();
  if (tomb) return json({ stale: true });

  const stored = await env.DB.prepare(
    "SELECT updated_at, promoted, byte_size FROM relic_meta WHERE account_id = ?1 AND uid = ?2",
  ).bind(auth.account, uid).first<{ updated_at: number; promoted: number; byte_size: number }>();
  if (stored && stored.updated_at >= envelope.updated_at) return json({ stale: true });

  // Both caps come off one cached row. These were two separate full scans of
  // relic_meta on every single write, which is what made D1 rows-read grow as
  // writes x vault size (src/usage.ts has the accounting).
  const usage = await readUsage(env, auth.account);
  // vault cap (promoted-item count) — enforced only on tiers that set it.
  if (
    caps.vault !== null && envelope.promoted && !stored?.promoted &&
    usage.vault >= caps.vault
  ) {
    return err(402, "vault_cap", "vault is full — upgrade to keep more");
  }
  // storage cap — all stored bytes, every tier.
  if (
    caps.storage !== null &&
    usage.bytes - (stored?.byte_size ?? 0) + envelope.byte_size > caps.storage
  ) {
    return err(402, "storage_quota", "storage quota exceeded");
  }

  await env.STORE.put(relicKey(auth.account, uid), body);
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO relic_meta (account_id, uid, created_at, updated_at, byte_size, promoted, blob_key)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(account_id, uid) DO UPDATE SET
         created_at = excluded.created_at, updated_at = excluded.updated_at,
         byte_size = excluded.byte_size, promoted = excluded.promoted, blob_key = excluded.blob_key`,
    ).bind(
      auth.account, uid, envelope.created_at, envelope.updated_at,
      envelope.byte_size, envelope.promoted ? 1 : 0, envelope.blob_key ?? null,
    ),
    // Atomic with the row above, so the cache cannot drift from the table.
    // `usage` is this request's scan, which lets the INSERT arm seed a
    // first-touch account; if the row already exists (or another request seeds
    // it first) SQLite applies the relative delta instead.
    usageDelta(
      env, auth.account,
      envelope.byte_size - (stored?.byte_size ?? 0),
      (envelope.promoted ? 1 : 0) - (stored?.promoted ?? 0),
      usage,
    ),
  ]);

  // history ring: lazily prune the oldest unpromoted past the tier's ring (with
  // tombstones, so other devices drop them too). Free = 500; pro/max = null
  // (no ring, keep everything).
  //
  // DOWNGRADE SAFETY (docs/cloudflare/05-billing.md §4): a paid->free account is
  // read-only, NEVER deleted. The ring only bounds accounts that have ALWAYS
  // been free — i.e. have no billing history. An account with any subscriptions
  // row earned its data on a paid plan, so we skip the prune entirely (the
  // 250MB storage cap still blocks *new* writes via the 402 above).
  const ring = caps.ring;
  if (ring !== null) {
    const everBilled = await env.DB.prepare(
      "SELECT 1 FROM subscriptions WHERE account_id = ?1",
    ).bind(auth.account).first();
    if (!everBilled) {
      const over = await env.DB.prepare(
        `SELECT uid, blob_key, byte_size, promoted FROM relic_meta
         WHERE account_id = ?1 AND promoted = 0
         ORDER BY created_at DESC LIMIT -1 OFFSET ?2`,
      ).bind(auth.account, ring).all<{ uid: string } & DeletedMeta>();
      const now = Math.floor(Date.now() / 1000);
      for (const row of over.results) {
        await deleteRelic(env, auth.account, row.uid, row, now);
      }
    }
  }

  // Committed a real write — ring the account's other devices to pull now.
  // (The stale/tombstone early-returns above skip this: nothing changed.)
  pokeSync(env, ctx, auth.account, auth.device);
  return json({ stale: false });
}

export async function listRelics(url: URL, env: Env, auth: Auth): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? 0);
  const limit = clampLimit(url.searchParams.get("limit"));
  const cursor = url.searchParams.get("cursor");

  let sql =
    "SELECT uid, updated_at FROM relic_meta WHERE account_id = ?1 AND updated_at > ?2";
  const binds: (string | number)[] = [auth.account, since];
  if (cursor) {
    const sep = cursor.lastIndexOf(":");
    if (sep < 0) return err(400, "invalid_envelope", "bad cursor");
    binds.push(Number(cursor.slice(0, sep)), Number(cursor.slice(0, sep)), cursor.slice(sep + 1));
    sql += " AND (updated_at > ?3 OR (updated_at = ?4 AND uid > ?5))";
  }
  binds.push(limit);
  sql += ` ORDER BY updated_at, uid LIMIT ?${binds.length}`;

  const rows = await env.DB.prepare(sql).bind(...binds).all<{ uid: string; updated_at: number }>();
  const items = (
    await Promise.all(
      rows.results.map((r) =>
        env.STORE.get(relicKey(auth.account, r.uid)).then((o) => o?.json<Envelope>()),
      ),
    )
  ).filter(Boolean);
  const last = rows.results.at(-1);
  const next = rows.results.length === limit && last ? `${last.updated_at}:${last.uid}` : null;
  return json({ items, next_cursor: next });
}

export default {
  async fetch(req: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    // Liveness probe (public, cheap). 200 = router up + D1 answering; used by
    // uptime monitoring. Reuses the public per-IP limiter.
    if (path === "/health" && req.method === "GET") {
      const limited = await rateLimit(env.RL_PLANS, clientIp(req));
      if (limited) return limited;
      try {
        await env.DB.prepare("SELECT 1").first();
        return json({ ok: true });
      } catch {
        return err(503, "unhealthy", "d1 unreachable");
      }
    }

    // Unauthenticated routes: the webhook self-authenticates via its signature;
    // plan listing is public pricing info.
    if (path === "/stripe/webhook" && req.method === "POST") return stripeWebhook(req, env);
    if (path === "/stripe/plans" && req.method === "GET") {
      const limited = await rateLimit(env.RL_PLANS, clientIp(req)); // per-IP (pre-auth)
      return limited ?? listPlans(env);
    }

    // Public share views (recipients have no account). The page never touches
    // the view count; only the ciphertext fetch does (see src/share.ts).
    const sharePageMatch = path.match(/^\/s\/([A-Za-z0-9_-]{1,64})$/);
    if (sharePageMatch && req.method === "GET") {
      const limited = await rateLimit(env.RL_SHARE_VIEW, clientIp(req));
      return limited ?? sharePageResponse(env, sharePageMatch[1]);
    }
    const shareBlobMatch = path.match(/^\/share\/([A-Za-z0-9_-]{1,64})\/blob$/);
    if (shareBlobMatch && req.method === "GET") {
      const limited = await rateLimit(env.RL_SHARE_VIEW, clientIp(req));
      return limited ?? fetchShareBlob(env, ctx, shareBlobMatch[1]);
    }

    const auth = await authenticate(req, env);
    if (auth instanceof Response) return auth;

    touchDevice(env, ctx, auth, req);

    // Verify-to-sync gate (optional; off unless VERIFY_GATE=on). Guards only the
    // sync write surface; everything else falls through untouched.
    const gated = syncWriteGate(env, auth, req.method, path);
    if (gated) return gated;

    // Data-plane abuse ceiling, per account, one gate for the whole surface.
    // Every other route already had a limiter. The sync plane, the part that
    // actually fans out to D1 and R2, had none, so a single stolen token could
    // hammer it as fast as the edge would carry.
    //
    // 900/60s (~15 rps) is an abuse ceiling, not traffic shaping. The worst
    // legitimate bursts are a fresh-device full sync (about 20 list pages for a
    // 10k vault plus parallel blob GETs) and a bulk import through the client's
    // ordered push queue; both are bandwidth-bound well under half of it. Reads
    // and writes share the one bucket on purpose: two knobs would each have to
    // be set loose enough for the other's burst.
    //
    // rateLimit() fails open on a missing binding, so self-host and the test
    // runtime (no RL_* bindings at all) behave byte-identically to before.
    if (isDataPlane(path)) {
      const limited = await rateLimit(env.RL_SYNC, auth.account);
      if (limited) return limited;
    }

    // --- live-sync doorbell: authed WebSocket, forwarded to the account's DO ---
    // The DO reads X-Relic-Device off this same request to skip echoing a write
    // back to its originator. Absent binding (self-host) -> 501, client polls.
    if (path === "/sync/socket" && req.headers.get("Upgrade") === "websocket") {
      if (!env.SYNC) return err(501, "no_socket", "live sync not enabled");
      return env.SYNC.get(env.SYNC.idFromName(auth.account)).fetch(req);
    }

    // --- billing (authed: identity = the bearer / Supabase JWT) ---
    if (path === "/stripe/checkout" && req.method === "POST") {
      const limited = await rateLimit(env.RL_BILLING, auth.account);
      return limited ?? createCheckout(req, env, auth);
    }
    if (path === "/stripe/portal" && req.method === "POST") {
      const limited = await rateLimit(env.RL_BILLING, auth.account);
      return limited ?? createPortal(req, env, auth);
    }

    // --- share links (create/revoke; viewing is public, above) ---
    if (path === "/share" && req.method === "POST") {
      const limited = await rateLimit(env.RL_SHARE, auth.account);
      return limited ?? createShare(req, url, env, auth);
    }
    const shareMatch = path.match(/^\/share\/([A-Za-z0-9_-]{1,64})$/);
    if (shareMatch && req.method === "DELETE" && isShareId(shareMatch[1])) {
      const limited = await rateLimit(env.RL_SHARE, auth.account);
      return limited ?? revokeShare(env, auth, shareMatch[1]);
    }

    // --- keyparams ---
    if (path === "/keyparams" && req.method === "GET") {
      const obj = await env.STORE.get(keyparamsKey(auth.account));
      if (!obj) return err(404, "not_found", "no keyparams set");
      return new Response(obj.body, { headers: { ...CORS, "Content-Type": "application/json" } });
    }
    if (path === "/keyparams" && req.method === "PUT") {
      const exists = await env.STORE.head(keyparamsKey(auth.account));
      if (exists && url.searchParams.get("replace") !== "1") {
        return err(409, "keyparams_exists", "keyparams already set; use ?replace=1 to re-wrap");
      }
      await env.STORE.put(keyparamsKey(auth.account), await req.text());
      return json({});
    }

    // --- relics ---
    const relicMatch = path.match(/^\/relic\/([A-Za-z0-9-]+)$/);
    if (relicMatch && req.method === "PUT") return putRelic(req, env, auth, relicMatch[1], ctx);
    if (relicMatch && req.method === "DELETE") {
      const uid = relicMatch[1];
      const meta = await env.DB.prepare(
        "SELECT blob_key, byte_size, promoted FROM relic_meta WHERE account_id = ?1 AND uid = ?2",
      ).bind(auth.account, uid).first<DeletedMeta>();
      const deletedAt = Number(url.searchParams.get("deleted_at")) || Math.floor(Date.now() / 1000);
      await deleteRelic(env, auth.account, uid, meta, deletedAt);
      pokeSync(env, ctx, auth.account, auth.device); // wake the other devices
      return json({});
    }
    if (path === "/relics" && req.method === "GET") return listRelics(url, env, auth);

    // --- AI records (generated title + tags) + the work lease. See ai.ts. ---
    if (path === "/ai" && req.method === "GET") return listAi(url, env, auth);
    if (path === "/ai/claim" && req.method === "POST") return claimAi(req, env, auth);
    if (path === "/ai/release" && req.method === "POST") return releaseAi(req, env, auth);
    const aiMatch = /^\/ai\/([^/]+)$/.exec(path);
    if (aiMatch && req.method === "PUT") {
      return putAi(req, env, auth, aiMatch[1], ctx);
    }

    if (path === "/tombstones" && req.method === "GET") {
      const since = Number(url.searchParams.get("since") ?? 0);
      const rows = await env.DB.prepare(
        `SELECT uid, deleted_at FROM tombstones WHERE account_id = ?1 AND deleted_at > ?2
         ORDER BY deleted_at, uid LIMIT 1000`,
      ).bind(auth.account, since).all<{ uid: string; deleted_at: number }>();
      return json({ items: rows.results.map((t) => ({ v: 1, uid: t.uid, deleted_at: t.deleted_at })) });
    }

    // --- blobs ---
    if (path === "/blob" && req.method === "POST") {
      const id = url.searchParams.get("id") ?? "";
      if (!BLOB_ID.test(id)) return err(400, "invalid_envelope", "bad blob id");
      const caps = TIERS[auth.tier];
      // Streams straight into R2 when Content-Length is present (no buffering).
      const body = await sizedBody(req, caps.item);
      if (body instanceof Response) return body;
      if (caps.storage !== null) {
        const { bytes: used } = await readUsage(env, auth.account);
        if (used + body.size > caps.storage) return err(402, "storage_quota", "storage quota exceeded");
      }
      await env.STORE.put(blobR2Key(auth.account, id), body.data);
      return json({ key: id }); // blob keys are bare client ids; the account
      // namespace is a server-side detail
    }
    // Chunked uploads for blobs past the edge body limit (~100 MB) — R2
    // multipart brokered through the Worker (docs/cloudflare/15-large-uploads.md).
    if (path === "/blob/mpu" && req.method === "POST") {
      const id = url.searchParams.get("id") ?? "";
      if (!BLOB_ID.test(id)) return err(400, "invalid_envelope", "bad blob id");
      return mpuCreate(req, env, auth, id);
    }
    // Key charset must track BLOB_ID (legacy "<uuid>.png" keys included).
    const mpuMatch = path.match(/^\/blob\/mpu\/([A-Za-z0-9-][A-Za-z0-9.-]{7,63})(\/complete)?$/);
    if (mpuMatch) {
      const id = mpuMatch[1];
      if (mpuMatch[2] && req.method === "POST") return mpuComplete(req, env, auth, id);
      if (!mpuMatch[2] && req.method === "PUT") return mpuPart(req, env, auth, id, url);
      if (!mpuMatch[2] && req.method === "DELETE") {
        return mpuAbort(env, auth, id, url.searchParams.get("upload_id") ?? "");
      }
    }
    // Key charset must track BLOB_ID (legacy "<uuid>.png" keys included).
    const blobMatch = path.match(/^\/blob\/([A-Za-z0-9-][A-Za-z0-9.-]{7,63})$/);
    if (blobMatch && req.method === "GET") {
      const obj = await env.STORE.get(blobR2Key(auth.account, blobMatch[1]));
      if (!obj) return err(404, "not_found", "no such blob");
      return new Response(obj.body, {
        headers: { ...CORS, "Cache-Control": "private, immutable", "Content-Type": "application/octet-stream" },
      });
    }

    // --- pairing relay (authed + account-scoped; opaque blobs only) ---
    // Per-account gate on the writes/claims (start/offer/claim); /pair/poll is a
    // cheap KV read left ungated so the client's poll loop isn't throttled.
    if (path === "/pair/start" || path === "/pair/offer" || path === "/pair/claim") {
      const limited = await rateLimit(env.RL_PAIR, auth.account);
      if (limited) return limited;
    }
    if (path === "/pair/start" && req.method === "POST") {
      if (!env.PAIR) return err(503, "unconfigured", "pairing relay not enabled");
      // The channel key is generated client-side and rides only in the QR; the
      // server just mints the session id (the capability).
      return json({ pairing_id: crypto.randomUUID() });
    }
    if (path === "/pair/offer" && req.method === "POST") {
      if (!env.PAIR) return err(503, "unconfigured", "pairing relay not enabled");
      let b: { pairing_id?: string; slot?: string; blob?: string };
      try {
        b = await req.json();
      } catch {
        return err(400, "bad_request", "not JSON");
      }
      if (
        !b.pairing_id || !isPairId(b.pairing_id) ||
        !b.slot || !PAIR_SLOTS.has(b.slot) ||
        typeof b.blob !== "string" || b.blob.length === 0 || b.blob.length > 8192
      ) {
        return err(400, "bad_request", "bad pairing fields");
      }
      await env.PAIR.put(pairKey(auth.account, b.pairing_id, b.slot), b.blob, {
        expirationTtl: PAIR_TTL,
      });
      return new Response(null, { status: 204, headers: CORS });
    }
    if ((path === "/pair/poll" || path === "/pair/claim") && req.method === "GET") {
      if (!env.PAIR) return err(503, "unconfigured", "pairing relay not enabled");
      const id = url.searchParams.get("pairing_id") ?? "";
      const slot = url.searchParams.get("slot") ?? "";
      if (!isPairId(id) || !PAIR_SLOTS.has(slot)) {
        return err(400, "bad_request", "bad pairing query");
      }
      const k = pairKey(auth.account, id, slot);
      const blob = await env.PAIR.get(k);
      // Absent / expired / consumed all look the same (zero-knowledge): 204.
      if (blob === null) return new Response(null, { status: 204, headers: CORS });
      if (path === "/pair/claim") await env.PAIR.delete(k); // single-use
      return json({ blob });
    }

    // --- device registry (docs/cloudflare/13 §7) ---
    if (path === "/account/devices" && req.method === "POST") {
      const limited = await rateLimit(env.RL_DEVICE, auth.account);
      if (limited) return limited;
      let b: { device_id?: string; label?: string; platform?: string; app_version?: string };
      try {
        b = await req.json();
      } catch {
        return err(400, "bad_request", "not JSON");
      }
      if (!b.device_id || b.device_id.length > 64) {
        return err(400, "bad_request", "bad device_id");
      }
      const appVer = typeof b.app_version === "string" ? b.app_version.slice(0, 32) : null;
      const now = Math.floor(Date.now() / 1000);
      const existing = await env.DB.prepare(
        "SELECT 1 FROM devices WHERE account_id = ?1 AND device_id = ?2 AND revoked_at IS NULL",
      ).bind(auth.account, b.device_id).first();
      if (!existing) {
        const cap = TIERS[auth.tier].devices;
        if (cap !== null) {
          const c = await env.DB.prepare(
            "SELECT COUNT(*) AS n FROM devices WHERE account_id = ?1 AND revoked_at IS NULL",
          ).bind(auth.account).first<{ n: number }>();
          if ((c?.n ?? 0) >= cap) {
            // Reject-but-actionable (doc 13 §10.3): hand back the list so the UI
            // can offer "remove one or upgrade" inline.
            return json(
              {
                error: "device_cap",
                message: "Device limit reached. Remove a device or upgrade.",
                devices: await listDevices(env, auth.account),
              },
              409,
            );
          }
        }
      }
      await env.DB.prepare(
        `INSERT INTO devices (account_id, device_id, label, platform, created_at, last_seen_at, app_version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6)
         ON CONFLICT(account_id, device_id) DO UPDATE SET
           label = excluded.label, platform = excluded.platform,
           last_seen_at = excluded.last_seen_at, revoked_at = NULL,
           app_version = COALESCE(excluded.app_version, app_version)`,
      ).bind(auth.account, b.device_id, b.label ?? null, b.platform ?? null, now, appVer).run();
      // Re-registering heals a prior hard-revoke (a legitimate re-pair).
      if (env.PAIR) await env.PAIR.delete(revKey(auth.account, b.device_id));
      return json({ ok: true });
    }
    if (path === "/account/devices" && req.method === "GET") {
      return json({ devices: await listDevices(env, auth.account, auth.device) });
    }
    const devMatch = path.match(/^\/account\/devices\/([A-Za-z0-9_-]{1,64})$/);
    if (devMatch && req.method === "PATCH") {
      const limited = await rateLimit(env.RL_DEVICE, auth.account);
      if (limited) return limited;
      let b: { label?: string };
      try {
        b = await req.json();
      } catch {
        return err(400, "bad_request", "not JSON");
      }
      const label = (b.label ?? "").trim().slice(0, 64);
      if (!label) return err(400, "bad_request", "label required");
      const res = await env.DB.prepare(
        `UPDATE devices SET label = ?3
         WHERE account_id = ?1 AND device_id = ?2 AND revoked_at IS NULL`,
      ).bind(auth.account, devMatch[1], label).run();
      if (!res.meta.changes) return err(404, "not_found", "no such device");
      return json({ ok: true });
    }
    if (devMatch && req.method === "DELETE") {
      const limited = await rateLimit(env.RL_DEVICE, auth.account);
      if (limited) return limited;
      const revokedAt = Math.floor(Date.now() / 1000);
      await env.DB.batch([
        env.DB.prepare(
          "UPDATE devices SET revoked_at = ?3 WHERE account_id = ?1 AND device_id = ?2",
        ).bind(auth.account, devMatch[1], revokedAt),
        // Real revocation (migrations/0009). The `rev:` marker written below
        // only bites a request that volunteers X-Relic-Device, so a stolen
        // device removed here would just drop the header and carry on. The
        // account watermark kills every access token minted before this moment
        // instead. MAX() keeps it monotone under any clock skew, and nothing
        // ever clears it: re-registering a device heals the KV marker, not
        // this.
        //
        // CONSEQUENCE, stated plainly: removing one device signs all of them
        // out. Legitimate devices recover silently on their next access-token
        // refresh (~1h; the refresh flow is untouched), and the remover's own
        // current token goes stale immediately. One forced re-login is the
        // accepted cost of revocation that actually revokes.
        env.DB.prepare(
          `UPDATE accounts SET min_valid_iat = MAX(min_valid_iat, ?2)
            WHERE account_id = ?1`,
        ).bind(auth.account, revokedAt),
      ]);
      if (env.PAIR) {
        await env.PAIR.put(revKey(auth.account, devMatch[1]), "1", {
          expirationTtl: REV_TTL,
        });
      }
      return json({ ok: true });
    }

    // --- account ---
    if (path === "/account" && req.method === "GET") {
      const caps = TIERS[auth.tier];
      const usage = await readUsage(env, auth.account);
      return json({
        tier: auth.tier,
        storage_used: usage.bytes,
        storage_quota: caps.storage,
        vault_count: usage.vault,
        vault_cap: caps.vault,
      });
    }
    // Irreversible: cancels billing + wipes all R2/D1/KV state for the account.
    // Requires a FRESH Supabase token (iat within 10 min) so a stale leaked
    // bearer alone can't destroy an account: clients force a token refresh
    // right before calling, so legitimate deletes never see this. Legacy
    // device tokens carry no iat and are grandfathered.
    if (path === "/account" && req.method === "DELETE") {
      const maxAgeS = 10 * 60;
      const nowS = Math.floor(Date.now() / 1000);
      if (auth.supabase && auth.tokenIssuedAt !== undefined && nowS - auth.tokenIssuedAt > maxAgeS) {
        return err(403, "stale_token", "sign-in too old for account deletion; refresh and retry");
      }
      const limited = await rateLimit(env.RL_ACCOUNT, auth.account);
      return limited ?? deleteAccount(env, auth);
    }

    return err(404, "not_found", `no route: ${req.method} ${path}`);
  },

  // Stripe billing queue consumer (only invoked when STRIPE_QUEUE is bound and a
  // [[queues.consumers]] points here). Applies each event idempotently.
  async queue(batch: MessageBatch<StripeMessage>, env: Env): Promise<void> {
    await consumeStripeBatch(batch, env);
  },

  // Cron (wrangler.toml [triggers]). Expire grace windows, reconcile D1
  // against Stripe (source of truth) to repair any drift, then GC dead shares
  // (expiry is enforced at read time — this is only garbage collection),
  // orphaned blobs, and aged-out tombstones (src/sweep.ts). The janitor pair
  // is fenced so a sweep failure can't starve the billing sweeps.
  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    await graceSweep(env);
    await reconcile(env);
    await sweepShares(env);
    try {
      const blobs = await sweepOrphanBlobs(env);
      const tombstones = await sweepTombstones(env);
      const mpus = await sweepAbandonedMpus(env);
      console.log(JSON.stringify({ evt: "janitor", ...blobs, tombstones, mpus }));
    } catch (e) {
      console.error(JSON.stringify({ evt: "janitor_error", err: String(e) }));
    }
  },
} satisfies ExportedHandler<Env, StripeMessage>;
