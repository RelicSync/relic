// Blob storage helpers + chunked (R2 multipart) uploads.
// Spec: docs/cloudflare/15-large-uploads.md. Why this exists: the Cloudflare
// edge rejects request bodies over ~100 MB (zone-plan dependent) before the
// Worker runs, so the 100 MB (pro) / 500 MB (max) per-item caps are not
// deliverable in one POST /blob. Clients upload anything over SINGLE_SHOT_MAX
// in PART_SIZE chunks through these routes; R2 reassembles the exact bytes,
// so the E2E envelope format is untouched (multipart is pure transport).
//
// Quota model: declared size is checked at create (the cheap, pre-transfer
// 413/402 — the client's upsell moment), and the TRUE size is re-checked at
// complete (closes the lying-client hole; over-cap objects are deleted).
//
// Every create also books a row in `mpu_state` (migrations/0010) and every
// terminal outcome clears it. That row does two things account_usage cannot:
// it reserves the declared bytes, so N parallel creates can no longer each see
// the same empty account and each pass the same check, and it is the only trace
// an abandoned upload leaves anywhere, because R2's list() does not return
// in-flight multipart parts, so without it nothing could ever be reclaimed. The bucket
// lifecycle rule (docs/setup/02-cloudflare.md) stays as a second backstop, but
// src/sweep.ts no longer depends on it.

import type { Env } from "./env";
import type { Auth } from "./auth";
import { TIERS } from "./tiers";
import { err, json } from "./http";
import { readUsage } from "./usage";

/// One R2 key namespace for all blobs, single- or multi-part.
export const blobR2Key = (acct: string, id: string) => `users/${acct}/blob/${id}`;

// Dots are allowed (never leading) because pre-1.0 clients minted blob keys
// like "<uuid>.png"; those rows still live in old vaults and must stay
// pushable, or one legacy photo jams the client's ordered push queue forever.
export const BLOB_ID = /^[A-Za-z0-9-][A-Za-z0-9.-]{7,63}$/;

// 64 MiB: >= R2's 5 MiB part floor, comfortably under the edge body limit,
// and streams through the Worker without buffering pressure. Clients use the
// same number as the single-shot threshold (server returns it from create).
export const PART_SIZE = 64 * 1024 * 1024;

const maxParts = (tier: Auth["tier"]) => Math.ceil(TIERS[tier].item / PART_SIZE);

/// Body + its size, without buffering when Content-Length is present (real
/// clients always send it; a near-cap body buffered would flirt with the
/// 128 MB Worker memory limit). Falls back to buffering for length-less
/// bodies (chunked encoding, synthetic test Requests). Returns an error
/// Response when the size busts [cap].
export async function sizedBody(
  req: Request,
  cap: number,
): Promise<{ data: ReadableStream | ArrayBuffer; size: number } | Response> {
  const len = Number(req.headers.get("content-length") ?? NaN);
  if (Number.isFinite(len) && len > cap) return err(413, "too_large", "body exceeds cap");
  if (Number.isFinite(len) && len > 0 && req.body) return { data: req.body, size: len };
  const buf = await req.arrayBuffer();
  if (buf.byteLength > cap) return err(413, "too_large", "body exceeds cap");
  if (buf.byteLength === 0) return err(400, "invalid_envelope", "empty body");
  return { data: buf, size: buf.byteLength };
}

async function overQuota(env: Env, auth: Auth, size: number): Promise<boolean> {
  const cap = TIERS[auth.tier].storage;
  if (cap === null) return false;
  return (await readUsage(env, auth.account)).bytes + size > cap;
}

/// Bytes already promised to uploads this account has in flight. account_usage
/// only counts bytes that have LANDED, which is what let ten simultaneous
/// creates each pass a check the first one should have used up. One indexed
/// SUM, on a route that runs once per large file.
async function reservedBytes(env: Env, acct: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COALESCE(SUM(declared_size), 0) AS reserved FROM mpu_state WHERE account_id = ?1",
  ).bind(acct).first<{ reserved: number }>();
  return row?.reserved ?? 0;
}

/// Forget an upload. Called on every terminal outcome (completed, rejected,
/// aborted, swept) so a stale reservation can never hold quota hostage.
export async function clearMpuState(
  env: Env,
  acct: string,
  blobId: string,
  uploadId: string,
): Promise<void> {
  await env.DB.prepare(
    "DELETE FROM mpu_state WHERE account_id = ?1 AND blob_id = ?2 AND upload_id = ?3",
  ).bind(acct, blobId, uploadId).run();
}

// POST /blob/mpu?id=<blobKey>  {declared_size}
export async function mpuCreate(req: Request, env: Env, auth: Auth, id: string): Promise<Response> {
  let declared: number;
  try {
    declared = ((await req.json()) as { declared_size?: number }).declared_size ?? NaN;
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  if (!Number.isInteger(declared) || declared <= 0) {
    return err(400, "invalid_envelope", "bad declared_size");
  }
  if (declared > TIERS[auth.tier].item) return err(413, "too_large", "blob exceeds tier cap");
  const cap = TIERS[auth.tier].storage;
  if (cap !== null) {
    const used = (await readUsage(env, auth.account)).bytes;
    if (used + (await reservedBytes(env, auth.account)) + declared > cap) {
      return err(402, "storage_quota", "storage quota exceeded");
    }
  }
  const mpu = await env.STORE.createMultipartUpload(blobR2Key(auth.account, id));
  // Book the reservation only after R2 hands back an upload id, so a failed
  // create never leaves a row holding quota for something that does not exist.
  // ON CONFLICT because a client retrying the same upload id must re-book, not
  // fail the create.
  await env.DB.prepare(
    `INSERT INTO mpu_state (account_id, blob_id, upload_id, declared_size, created_at)
     VALUES (?1, ?2, ?3, ?4, unixepoch())
     ON CONFLICT(account_id, blob_id, upload_id) DO UPDATE SET
       declared_size = excluded.declared_size, created_at = excluded.created_at`,
  ).bind(auth.account, id, mpu.uploadId, declared).run();
  return json({ upload_id: mpu.uploadId, part_size: PART_SIZE, max_parts: maxParts(auth.tier) });
}

// PUT /blob/mpu/<blobKey>?upload_id=…&part=N   (body = raw chunk, streamed)
export async function mpuPart(req: Request, env: Env, auth: Auth, id: string, url: URL): Promise<Response> {
  const uploadId = url.searchParams.get("upload_id") ?? "";
  const part = Number(url.searchParams.get("part"));
  if (!uploadId) return err(400, "invalid_envelope", "missing upload_id");
  if (!Number.isInteger(part) || part < 1 || part > maxParts(auth.tier)) {
    return err(400, "invalid_envelope", "bad part number");
  }
  const body = await sizedBody(req, PART_SIZE);
  if (body instanceof Response) return body;
  const mpu = env.STORE.resumeMultipartUpload(blobR2Key(auth.account, id), uploadId);
  try {
    const up = await mpu.uploadPart(part, body.data);
    return json({ part: up.partNumber, etag: up.etag });
  } catch {
    return err(404, "not_found", "unknown upload");
  }
}

// POST /blob/mpu/<blobKey>/complete  {upload_id, parts:[{part, etag}…]}
export async function mpuComplete(req: Request, env: Env, auth: Auth, id: string): Promise<Response> {
  let body: { upload_id?: string; parts?: { part?: number; etag?: string }[] };
  try {
    body = (await req.json()) as typeof body;
  } catch {
    return err(400, "invalid_envelope", "not JSON");
  }
  const parts = body.parts;
  if (
    !body.upload_id || !Array.isArray(parts) || parts.length < 1 ||
    parts.length > maxParts(auth.tier) ||
    !parts.every((p) => Number.isInteger(p.part) && typeof p.etag === "string")
  ) {
    return err(400, "invalid_envelope", "bad upload_id or parts");
  }
  const key = blobR2Key(auth.account, id);
  const mpu = env.STORE.resumeMultipartUpload(key, body.upload_id);
  let obj: R2Object;
  try {
    obj = await mpu.complete(parts.map((p) => ({ partNumber: p.part!, etag: p.etag! })));
  } catch {
    return err(404, "not_found", "unknown upload or mismatched parts");
  }
  // The upload is no longer in flight either way, so release the reservation
  // before the size verdict, since all three exits below are terminal.
  await clearMpuState(env, auth.account, id, body.upload_id);
  // True-size re-check: the declared_size at create was client-claimed. Note
  // this one deliberately does NOT add reservedBytes: the row we just cleared
  // was this upload's own, and any sibling in flight has not landed yet.
  if (obj.size > TIERS[auth.tier].item) {
    await env.STORE.delete(key);
    return err(413, "too_large", "blob exceeds tier cap");
  }
  if (await overQuota(env, auth, obj.size)) {
    await env.STORE.delete(key);
    return err(402, "storage_quota", "storage quota exceeded");
  }
  return json({ key: id });
}

// DELETE /blob/mpu/<blobKey>?upload_id=…  — idempotent abort
export async function mpuAbort(env: Env, auth: Auth, id: string, uploadId: string): Promise<Response> {
  if (!uploadId) return err(400, "invalid_envelope", "missing upload_id");
  const mpu = env.STORE.resumeMultipartUpload(blobR2Key(auth.account, id), uploadId);
  try {
    await mpu.abort();
  } catch {
    // already aborted/completed/unknown — abort is best-effort by design
  }
  // Unconditional, and outside the try: even an abort R2 rejected means this
  // upload is done as far as we are concerned, and leaving the row would hold
  // the reservation until the 24h sweep.
  await clearMpuState(env, auth.account, id, uploadId);
  return json({ aborted: true });
}
