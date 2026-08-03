// Read-only Worker calls for the web vault viewer (/vault). Everything here
// returns ciphertext — decryption happens in vault-crypto.ts, in the tab.
// Same bearer as billing: the Supabase access token (relic-account.ts).

import { WORKER_BASE, webDeviceId } from "./relic-account";
import type { Envelope, KeyParams } from "./vault-crypto";

function headers(accessToken: string): HeadersInit {
  return { Authorization: `Bearer ${accessToken}`, "X-Relic-Device": webDeviceId() };
}

/** Thrown when the Worker reports this browser's device was revoked from
 * elsewhere. The caller wipes local keys and re-locks. */
export class DeviceRevokedError extends Error {
  constructor() {
    super("This browser was signed out from another device.");
    this.name = "DeviceRevokedError";
  }
}

/** The Worker 401s a removed device with `{error:"device_revoked"}`
 * (worker/src/auth.ts). That code is unambiguous — a plain expired token is
 * `{error:"unauthorized"}` — so we can act on it without a speculative token
 * refresh. Reads a clone so the caller can still consume the body. */
async function guardRevoked(r: Response): Promise<void> {
  if (r.status !== 401 && r.status !== 403) return;
  const j = await r.clone().json().catch(() => ({}));
  if ((j as { error?: string }).error === "device_revoked") throw new DeviceRevokedError();
}

/** The account's wrapped-master-key record. Null = no vault synced yet
 * (brand-new account that has never run the app). */
export async function getKeyparams(accessToken: string): Promise<KeyParams | null> {
  const r = await fetch(`${WORKER_BASE}/keyparams`, { headers: headers(accessToken) });
  if (r.status === 404) return null;
  await guardRevoked(r);
  if (!r.ok) throw new Error(`Could not load your vault key record (${r.status}).`);
  return (await r.json()) as KeyParams;
}

/** Re-wrap: replace the account's keyparams record (recovery-kit import or a
 * passphrase change). The Worker requires ?replace=1 to overwrite an existing
 * record. Does not re-encrypt any content — the master key is unchanged. */
export async function putKeyparams(accessToken: string, kp: KeyParams): Promise<void> {
  const r = await fetch(`${WORKER_BASE}/keyparams?replace=1`, {
    method: "PUT",
    headers: { ...headers(accessToken), "Content-Type": "application/json" },
    body: JSON.stringify(kp),
  });
  if (r.ok) return;
  await guardRevoked(r);
  const j = (await r.json().catch(() => ({}))) as { message?: string };
  throw new Error(j.message ?? `Could not save the new key record (${r.status}).`);
}

/** Page through every envelope on the server (500 per request). */
export async function listAllEnvelopes(
  accessToken: string,
  onProgress?: (count: number) => void,
): Promise<Envelope[]> {
  const all: Envelope[] = [];
  let cursor: string | null = null;
  do {
    const u = new URL(`${WORKER_BASE}/relics`);
    u.searchParams.set("since", "0");
    if (cursor) u.searchParams.set("cursor", cursor);
    const r = await fetch(u, { headers: headers(accessToken) });
    if (!r.ok) {
      await guardRevoked(r);
      throw new Error(`Could not load your items (${r.status}).`);
    }
    const j = (await r.json()) as { items: Envelope[]; next_cursor: string | null };
    all.push(...j.items);
    cursor = j.next_cursor;
    onProgress?.(all.length);
  } while (cursor);
  return all;
}

/** Fetch one encrypted blob's wire bytes (nonce ‖ ct). */
export async function fetchBlobWire(accessToken: string, blobId: string): Promise<Uint8Array> {
  const r = await fetch(`${WORKER_BASE}/blob/${blobId}`, { headers: headers(accessToken) });
  if (!r.ok) {
    await guardRevoked(r);
    throw new Error(`Could not load the file (${r.status}).`);
  }
  return new Uint8Array(await r.arrayBuffer());
}

// ---- writes ----------------------------------------------------------------

/** Server said no, permanently: 413 = over the tier's per-item cap (the
 * upgrade moment), 402 = storage/vault quota. Mirrors the app's BlobRejected. */
export class WriteRejected extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function checkWrite(r: Response): Promise<void> {
  if (r.ok) return;
  await guardRevoked(r);
  const j = (await r.json().catch(() => ({}))) as { code?: string; message?: string };
  if (r.status === 413 || r.status === 402) {
    throw new WriteRejected(r.status, j.message ?? "Over your plan's limit.");
  }
  throw new Error(j.message ?? `The write failed (${r.status}).`);
}

/** PUT one sealed envelope. Returns true when stored, false when the server
 * already has a newer version or a tombstone (stale — caller should re-pull). */
export async function putEnvelope(accessToken: string, env: Envelope): Promise<boolean> {
  const r = await fetch(`${WORKER_BASE}/relic/${env.uid}`, {
    method: "PUT",
    headers: { ...headers(accessToken), "Content-Type": "application/json" },
    body: JSON.stringify(env),
  });
  await checkWrite(r);
  const j = (await r.json().catch(() => ({}))) as { stale?: boolean };
  return !j.stale;
}

/** Delete a relic (server writes a tombstone every other device honors). */
export async function deleteRelic(accessToken: string, uid: string): Promise<void> {
  const deletedAt = Math.floor(Date.now() / 1000);
  const r = await fetch(`${WORKER_BASE}/relic/${uid}?deleted_at=${deletedAt}`, {
    method: "DELETE",
    headers: headers(accessToken),
  });
  await checkWrite(r);
}

// Chunked upload past the ~100 MB edge body limit — browser mirror of
// app/lib/data/blob_upload.dart (docs/cloudflare/15-large-uploads.md).
const SINGLE_SHOT_MAX = 64 * 1024 * 1024;

async function withRetry(go: () => Promise<Response>): Promise<Response> {
  let delay = 1000;
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await go();
      if (r.status < 500 || attempt >= 2) return r;
    } catch (err) {
      if (attempt >= 2) throw err;
    }
    await new Promise((res) => setTimeout(res, delay));
    delay *= 2;
  }
}

/** Upload sealed blob wire bytes under `blobKey`. Single POST up to 64 MiB,
 * R2 multipart via /blob/mpu beyond that. Throws WriteRejected on 413/402. */
export async function uploadBlobWire(
  accessToken: string,
  blobKey: string,
  wire: Uint8Array,
  onProgress?: (fraction: number) => void,
): Promise<void> {
  const H = headers(accessToken);
  const body = (v: Uint8Array) => v.slice().buffer as ArrayBuffer;
  if (wire.length <= SINGLE_SHOT_MAX) {
    const r = await fetch(`${WORKER_BASE}/blob?id=${blobKey}`, { method: "POST", headers: H, body: body(wire) });
    await checkWrite(r);
    onProgress?.(1);
    return;
  }

  // create — the pre-transfer cap/quota check (413 here = upgrade pitch
  // before any bytes move)
  const create = await fetch(`${WORKER_BASE}/blob/mpu?id=${blobKey}`, {
    method: "POST",
    headers: { ...H, "Content-Type": "application/json" },
    body: JSON.stringify({ declared_size: wire.length }),
  });
  await checkWrite(create);
  const meta = (await create.json()) as { upload_id: string; part_size: number };

  const parts: { part: number; etag: string }[] = [];
  try {
    let n = 1;
    for (let off = 0; off < wire.length; off += meta.part_size, n++) {
      const chunk = wire.subarray(off, Math.min(off + meta.part_size, wire.length));
      const r = await withRetry(() =>
        fetch(`${WORKER_BASE}/blob/mpu/${blobKey}?upload_id=${meta.upload_id}&part=${n}`, {
          method: "PUT",
          headers: H,
          body: body(chunk),
        }),
      );
      await checkWrite(r);
      const p = (await r.json()) as { part: number; etag: string };
      parts.push(p);
      onProgress?.(Math.min(off + meta.part_size, wire.length) / wire.length);
    }
    const done = await fetch(`${WORKER_BASE}/blob/mpu/${blobKey}/complete`, {
      method: "POST",
      headers: { ...H, "Content-Type": "application/json" },
      body: JSON.stringify({ upload_id: meta.upload_id, parts }),
    });
    await checkWrite(done);
  } catch (err) {
    // free the stranded parts now instead of waiting on the lifecycle sweep
    fetch(`${WORKER_BASE}/blob/mpu/${blobKey}?upload_id=${meta.upload_id}`, {
      method: "DELETE",
      headers: H,
    }).catch(() => {});
    throw err;
  }
}
