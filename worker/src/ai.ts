// AI records: the generated title + tags for a relic, plus the work lease that
// keeps two devices from generating them at the same time.
//
// The problem this solves: enrichment used to be a purely local side effect, so
// an AI title never left the machine that produced it, and every device that
// received a relic re-ran the models on it independently. That is duplicated
// generative work and, because the labeler is not deterministic across machines,
// a different title on each one.
//
// Shape of the fix:
//   claim  -> one device wins a short lease on a uid, the others skip it
//   put    -> the winner publishes the encrypted result
//   list   -> every device pulls results on a cursor of its own
//
// The Worker never sees the title or the tags: they are sealed client-side under
// AAD relic.ai.v1:<uid>. What it sees is a uid, a timestamp, a level, and which
// device did the work.
import type { Env } from "./env";
import type { Auth } from "./auth";
import { err, json } from "./http";
import { pokeSync } from "./notify";

// A lease is deliberately short. It only has to outlast one item's model pass
// (seconds), and a device that sleeps mid-item should hand the work back
// quickly rather than blocking it until that machine wakes up.
const LEASE_SECS = 600;
const MAX_CLAIM_BATCH = 64;
// A title, a handful of tags, and the text the models read out of the item
// (OCR from a screenshot, the extracted body of a document) — which is the
// large part and the reason this is not a few hundred bytes.
//
// The client budgets that text at 24 KiB of UTF-8 and holds the whole sealed
// payload under 33 KiB (kAiTextBytes / kAiPayloadBytes in
// app/lib/models/relic.dart). This cap allows for the encryption overhead and
// base64's 4/3 expansion on top of that, so a client that respects its own
// budget is never refused — which matters, because a refused record is
// dropped rather than retried: there is no version of it that would fit. It is
// still a ceiling: ai_meta lives in D1 alongside the sync metadata, and the
// file itself already syncs as a blob, so this must not become bulk storage
// that sidesteps the tier caps on relics.
const MAX_CT = 48 * 1024;

const now = () => Math.floor(Date.now() / 1000);

interface AiRow {
  ai_at: number | null;
  ai_level: number | null;
  device_id: string | null;
}

/// Which of two results for the same uid should stand.
///
/// Not last-write-wins. Ordinary LWW would let a device whose lease expired
/// mid-job publish late and overwrite the result that already landed, so a
/// title the user had settled on would change under them for no visible reason.
/// Instead:
///
///   1. a higher enrich level always wins  (a real model upgrade should apply)
///   2. a device may amend its OWN record with its latest word. The halves of a
///      record are produced by different passes that finish at different times
///      — the models caption an item, and a separate model-free pass reads its
///      attachments once their bytes are local — so the owner coming back with
///      more is adding to its answer, not competing with it. A different device
///      publishing late is the case rule 3 exists for; this is not that. Its
///      own OLDER word is still refused, so a record never moves backwards.
///   3. at equal level, the EARLIEST result wins  (a title, once it exists,
///      stops moving)
///   4. exact ties break on device id, so every device converges on one answer
///      rather than flapping between two equally-valid ones
///
/// This is also what makes the one-time convergence of already-divergent vaults
/// well defined: the oldest existing title is the one everybody adopts.
export function aiResultWins(
  incoming: { ai_at: number; ai_level: number; device_id: string },
  stored: AiRow | null,
): boolean {
  if (!stored || stored.ai_at === null) return true;
  const storedLevel = stored.ai_level ?? -1;
  if (incoming.ai_level !== storedLevel) return incoming.ai_level > storedLevel;
  if (incoming.device_id && incoming.device_id === stored.device_id) {
    return incoming.ai_at >= stored.ai_at;
  }
  if (incoming.ai_at !== stored.ai_at) return incoming.ai_at < stored.ai_at;
  return incoming.device_id < (stored.device_id ?? "￿");
}

/// POST /ai/claim — ask to do the AI work for a batch of uids.
///
/// Body: { items: [{ uid, level }], lease?: seconds }
/// Returns: { granted: [uid], done: [{ uid, level }], lease_expires_at }
///
/// `done` is the other half of the answer and matters as much as `granted`: it
/// tells a device that a peer already produced a result at or above the level it
/// was going to work at, so it can mark the item finished locally instead of
/// asking again every cycle for the life of the vault.
export async function claimAi(req: Request, env: Env, auth: Auth): Promise<Response> {
  const device = auth.device;
  if (!device) {
    // A lease has to belong to someone. A client that will not identify itself
    // cannot hold one, and silently letting it work would reintroduce exactly
    // the duplicate-work problem the lease exists to prevent.
    return err(400, "device_required", "claiming AI work requires X-Relic-Device");
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  const raw = (body as { items?: unknown })?.items;
  if (!Array.isArray(raw)) return err(400, "invalid_envelope", "items must be an array");
  if (raw.length > MAX_CLAIM_BATCH) {
    return err(400, "invalid_envelope", `at most ${MAX_CLAIM_BATCH} items per claim`);
  }

  const items: Array<{ uid: string; level: number }> = [];
  for (const it of raw) {
    const uid = (it as { uid?: unknown })?.uid;
    const level = (it as { level?: unknown })?.level;
    if (typeof uid !== "string" || !uid) continue;
    items.push({ uid, level: Number.isFinite(level) ? Number(level) : 0 });
  }
  if (items.length === 0) return json({ granted: [], done: [], lease_expires_at: 0 });

  const t = now();
  const expires = t + LEASE_SECS;

  // One statement per uid, batched into a single D1 round trip. The upsert IS
  // the mutual exclusion: SQLite applies these serially, so exactly one device's
  // DO UPDATE can satisfy the WHERE. RETURNING tells us whether ours was the one
  // that landed, with no read-then-write race in between.
  const stmts = items.map((it) =>
    env.DB.prepare(
      `INSERT INTO ai_meta (account_id, uid, claimed_by, claim_expires_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(account_id, uid) DO UPDATE SET
         claimed_by = ?3, claim_expires_at = ?4
       WHERE (ai_meta.claim_expires_at IS NULL
              OR ai_meta.claim_expires_at <= ?5
              OR ai_meta.claimed_by = ?3)
         AND (ai_meta.ai_at IS NULL
              OR ai_meta.ai_level IS NULL
              OR ai_meta.ai_level < ?6)
       RETURNING uid`,
    ).bind(auth.account, it.uid, device, expires, t, it.level),
  );
  const results = await env.DB.batch<{ uid: string }>(stmts);
  const granted = results.flatMap((r) => (r.results ?? []).map((row) => row.uid));

  // Everything we did not get, report back as done-if-done so the caller stops
  // asking. A uid that was merely leased by a live peer appears in neither list:
  // it is not ours to do, but it is not finished either, so we may get it later
  // if that peer drops the lease.
  const grantedSet = new Set(granted);
  const pending = items.filter((it) => !grantedSet.has(it.uid));
  const done: Array<{ uid: string; level: number }> = [];
  if (pending.length > 0) {
    const marks = pending.map((_, i) => `?${i + 2}`).join(",");
    const rows = await env.DB.prepare(
      `SELECT uid, ai_level FROM ai_meta
       WHERE account_id = ?1 AND uid IN (${marks}) AND ai_at IS NOT NULL`,
    ).bind(auth.account, ...pending.map((p) => p.uid)).all<{ uid: string; ai_level: number | null }>();
    for (const r of rows.results) done.push({ uid: r.uid, level: r.ai_level ?? 0 });
  }

  return json({ granted, done, lease_expires_at: expires });
}

/// POST /ai/release — give back leases this device is holding but will not use
/// (models unloaded, sync turned off, app shutting down, item deleted locally).
///
/// Purely an optimisation: every lease expires on its own. Releasing just means
/// a peer can pick the work up in seconds instead of after the lease window.
export async function releaseAi(req: Request, env: Env, auth: Auth): Promise<Response> {
  const device = auth.device;
  if (!device) return err(400, "device_required", "releasing AI work requires X-Relic-Device");
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  const uids = (body as { uids?: unknown })?.uids;
  if (!Array.isArray(uids)) return err(400, "invalid_envelope", "uids must be an array");
  const list = uids.filter((u): u is string => typeof u === "string" && !!u).slice(0, MAX_CLAIM_BATCH);
  if (list.length === 0) return json({ released: 0 });

  const marks = list.map((_, i) => `?${i + 3}`).join(",");
  // Scoped to our own leases: a device must never be able to knock a peer off
  // work it is actively doing.
  const r = await env.DB.prepare(
    `UPDATE ai_meta SET claimed_by = NULL, claim_expires_at = NULL
     WHERE account_id = ?1 AND claimed_by = ?2 AND uid IN (${marks})`,
  ).bind(auth.account, device, ...list).run();
  return json({ released: r.meta?.changes ?? 0 });
}

/// PUT /ai/:uid — publish the sealed result.
///
/// Body: { v: 1, uid, ai_at, level, n, ct }
export async function putAi(
  req: Request,
  env: Env,
  auth: Auth,
  uid: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  const e = body as {
    v?: number; uid?: string; ai_at?: number; level?: number; n?: string; ct?: string;
  };
  if (
    !e || e.v !== 1 || e.uid !== uid ||
    !Number.isFinite(e.ai_at) || !Number.isFinite(e.level) ||
    typeof e.n !== "string" || typeof e.ct !== "string"
  ) {
    return err(400, "invalid_envelope", "bad shape or uid mismatch");
  }
  if (e.ct.length > MAX_CT) return err(413, "too_large", "AI record exceeds cap");

  // A deleted relic must not sprout an AI record: the enriching device may have
  // been mid-pass when the delete landed, and writing now would leave a row
  // behind that its relic can never claim.
  const tomb = await env.DB.prepare(
    "SELECT 1 FROM tombstones WHERE account_id = ?1 AND uid = ?2",
  ).bind(auth.account, uid).first();
  if (tomb) return json({ stale: true });

  const stored = await env.DB.prepare(
    "SELECT ai_at, ai_level, device_id FROM ai_meta WHERE account_id = ?1 AND uid = ?2",
  ).bind(auth.account, uid).first<AiRow>();

  const device = auth.device ?? "";
  const incoming = { ai_at: e.ai_at!, ai_level: e.level!, device_id: device };
  if (!aiResultWins(incoming, stored)) {
    // Not an error: a peer's result already stands. The caller records the item
    // as done and moves on rather than retrying.
    return json({ stale: true });
  }

  await env.DB.prepare(
    `INSERT INTO ai_meta (account_id, uid, ai_at, ai_level, device_id, n, ct,
                          claimed_by, claim_expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, NULL)
     ON CONFLICT(account_id, uid) DO UPDATE SET
       ai_at = excluded.ai_at, ai_level = excluded.ai_level,
       device_id = excluded.device_id, n = excluded.n, ct = excluded.ct,
       claimed_by = NULL, claim_expires_at = NULL`,
  ).bind(auth.account, uid, e.ai_at, e.level, device, e.n, e.ct).run();

  // Wake the other devices: a generated title should appear on the machine you
  // are looking at, not on its next scheduled poll.
  pokeSync(env, ctx, auth.account, auth.device);
  return json({ stale: false });
}

/// GET /ai?since=&limit=&cursor= — pull AI records on their own cursor.
///
/// Mirrors listRelics, but ordered by ai_at, which is exactly the point: AI
/// results move on a timeline of their own and never disturb the relic
/// updated_at ordering the vault's "recent" views depend on.
export async function listAi(url: URL, env: Env, auth: Auth): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? 0);
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 500), 500);
  const cursor = url.searchParams.get("cursor");

  let sql =
    `SELECT uid, ai_at, ai_level, device_id, n, ct FROM ai_meta
     WHERE account_id = ?1 AND ai_at > ?2`;
  const binds: (string | number)[] = [auth.account, since];
  if (cursor) {
    const sep = cursor.lastIndexOf(":");
    if (sep < 0) return err(400, "invalid_envelope", "bad cursor");
    binds.push(Number(cursor.slice(0, sep)), Number(cursor.slice(0, sep)), cursor.slice(sep + 1));
    sql += " AND (ai_at > ?3 OR (ai_at = ?4 AND uid > ?5))";
  }
  sql += ` ORDER BY ai_at, uid LIMIT ${limit}`;

  const rows = await env.DB.prepare(sql).bind(...binds).all<{
    uid: string; ai_at: number; ai_level: number | null;
    device_id: string | null; n: string | null; ct: string | null;
  }>();
  const items = rows.results
    // A bare lease has no payload. The partial index should keep these out
    // already; the filter means a hand-edited row cannot hand a client a null.
    .filter((r) => r.n !== null && r.ct !== null)
    .map((r) => ({
      v: 1, uid: r.uid, ai_at: r.ai_at, level: r.ai_level ?? 0,
      device: r.device_id, n: r.n, ct: r.ct,
    }));
  const last = rows.results.at(-1);
  const next = rows.results.length === limit && last ? `${last.ai_at}:${last.uid}` : null;
  return json({ items, next_cursor: next });
}
