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
// Abandoned uploads are aborted by the client best-effort and by the bucket
// lifecycle rule (docs/setup/02-cloudflare.md) as the backstop.

import type { Env } from "./env";
import type { Auth } from "./auth";
import { TIERS } from "./tiers";
import { err, json } from "./http";

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

/// Total stored bytes for an account (the `storage` cap denominator).
export async function usageBytes(env: Env, acct: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COALESCE(SUM(byte_size), 0) AS used FROM relic_meta WHERE account_id = ?1",
  ).bind(acct).first<{ used: number }>();
  return row?.used ?? 0;
}

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
  return (await usageBytes(env, auth.account)) + size > cap;
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
  if (await overQuota(env, auth, declared)) return err(402, "storage_quota", "storage quota exceeded");
  const mpu = await env.STORE.createMultipartUpload(blobR2Key(auth.account, id));
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
  // True-size re-check: the declared_size at create was client-claimed.
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
  return json({ aborted: true });
}
