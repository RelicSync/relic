// Janitorial sweeps, run from scheduled() every 6 hours (docs/cloudflare/06).
//
// Orphan blobs: clients upload the blob FIRST, then PUT the envelope that
// references it. A crash or lost client in that gap leaves a blob no
// relic_meta row points at — invisible to the user, billed as storage
// forever. Contract (docs/api.md): blobs unreferenced after 24 h are swept.
// The scan is bounded per run (PAGES_PER_RUN R2 list pages) and resumes from
// a cursor persisted in sweep_state, so a large bucket is swept
// incrementally across ticks rather than in one unbounded pass.
//
// Tombstone GC: tombstones exist so deletion wins over late pushes from
// offline devices (putRelic checks them). They only need to outlive any
// plausible offline device, not live forever. Rows older than
// TOMBSTONE_TTL_DAYS are dropped; a device offline longer than that can
// resurrect a deleted relic on reconnect — accepted trade, stated in
// docs/api.md.

import type { Env } from "./env";

export const ORPHAN_MIN_AGE_S = 24 * 3600;
export const TOMBSTONE_TTL_DAYS = 90;

const PAGES_PER_RUN = 3; // <= 3000 objects listed per tick
const CURSOR_KEY = "orphan_blob_cursor";
const IN_CHUNK = 40; // stay well under D1's bound-parameter limit

// Only objects at users/<acct>/blob/<id> are candidates; envelopes
// (users/<acct>/relics/<uid>), keyparams.json, and shares/<id> never match.
const BLOB_KEY_RE = /^users\/([^/]+)\/blob\/(.+)$/;

const nowS = () => Math.floor(Date.now() / 1000);

async function getCursor(env: Env): Promise<string | undefined> {
  const row = await env.DB.prepare("SELECT v FROM sweep_state WHERE k = ?1")
    .bind(CURSOR_KEY).first<{ v: string }>();
  return row?.v ?? undefined;
}

async function setCursor(env: Env, v: string | undefined): Promise<void> {
  if (v === undefined) {
    await env.DB.prepare("DELETE FROM sweep_state WHERE k = ?1").bind(CURSOR_KEY).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO sweep_state (k, v, updated_at) VALUES (?1, ?2, unixepoch())
       ON CONFLICT(k) DO UPDATE SET v = excluded.v, updated_at = excluded.updated_at`,
    ).bind(CURSOR_KEY, v).run();
  }
}

/** One bounded pass of the orphan-blob sweep. `now` is injectable for tests. */
export async function sweepOrphanBlobs(
  env: Env,
  now = nowS(),
): Promise<{ scanned: number; deleted: number; done: boolean }> {
  let cursor = await getCursor(env);
  let scanned = 0;
  let done = false;

  // Phase 1: list. Collect age-eligible blob objects, grouped by account so
  // the reference checks batch. Deletes wait until pagination is finished.
  const byAcct = new Map<string, { key: string; blobId: string }[]>();
  for (let page = 0; page < PAGES_PER_RUN; page++) {
    const listed = await env.STORE.list({ prefix: "users/", cursor, limit: 1000 });
    scanned += listed.objects.length;
    for (const obj of listed.objects) {
      const m = obj.key.match(BLOB_KEY_RE);
      if (!m) continue;
      if (obj.uploaded.getTime() / 1000 > now - ORPHAN_MIN_AGE_S) continue;
      const list = byAcct.get(m[1]) ?? [];
      list.push({ key: obj.key, blobId: m[2] });
      byAcct.set(m[1], list);
    }
    if (!listed.truncated) {
      cursor = undefined; // full wrap: next tick starts from the top
      done = true;
      break;
    }
    cursor = listed.cursor;
  }

  // Phase 2: check references in D1, delete the unreferenced.
  let deleted = 0;
  for (const [acct, blobs] of byAcct) {
    for (let i = 0; i < blobs.length; i += IN_CHUNK) {
      const chunk = blobs.slice(i, i + IN_CHUNK);
      const placeholders = chunk.map((_, j) => `?${j + 2}`).join(",");
      const rows = await env.DB.prepare(
        `SELECT blob_key FROM relic_meta
         WHERE account_id = ?1 AND blob_key IN (${placeholders})`,
      ).bind(acct, ...chunk.map((c) => c.blobId)).all<{ blob_key: string }>();
      const referenced = new Set(rows.results.map((r) => r.blob_key));
      for (const c of chunk) {
        if (referenced.has(c.blobId)) continue;
        await env.STORE.delete(c.key);
        deleted++;
      }
    }
  }

  await setCursor(env, cursor);
  return { scanned, deleted, done };
}

/** Drop tombstones past their retention window. Returns rows deleted. */
export async function sweepTombstones(env: Env, now = nowS()): Promise<number> {
  const cutoff = now - TOMBSTONE_TTL_DAYS * 86400;
  const res = await env.DB.prepare("DELETE FROM tombstones WHERE deleted_at < ?1")
    .bind(cutoff).run();
  return res.meta.changes ?? 0;
}
