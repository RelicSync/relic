// E2EE share links from the web vault — mirror of the desktop's createShare
// (local_desk_repo.dart) and ShareCrypto (crypto.dart / worker/src/share.ts).
// Deliberately AES-GCM, not XChaCha: recipients decrypt in a browser and
// WebCrypto speaks AES-GCM natively — which is also why the CREATE side works
// here. Wire = iv(12) ‖ ct ‖ tag(16); AAD binds the share id; the key rides
// the URL fragment and never reaches the server.

import { WORKER_BASE } from "./relic-account";

const AAD_PREFIX = "relic.share.v1:";
const te = new TextEncoder();

const b64url = (b: Uint8Array) =>
  btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export class ShareError extends Error {}

export interface ShareLink {
  url: string; // includes the #key fragment
  expiresAt: number;
  oneTime: boolean;
}

export type SharePayload =
  | { v: 1; kind: "text"; text: string }
  | { v: 1; kind: "image" | "file"; mime?: string; name?: string; data: string };

async function seal(id: string, payload: SharePayload): Promise<{ keyFragment: string; wire: Uint8Array }> {
  const keyBytes = crypto.getRandomValues(new Uint8Array(32));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey("raw", keyBytes.slice().buffer, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: te.encode(`${AAD_PREFIX}${id}`) },
      key,
      te.encode(JSON.stringify(payload)),
    ),
  ); // WebCrypto returns ciphertext‖tag(16) — exactly the wire layout after the iv
  const wire = new Uint8Array(iv.length + ct.length);
  wire.set(iv);
  wire.set(ct, iv.length);
  return { keyFragment: b64url(keyBytes), wire };
}

/** Create a share link. ttlSeconds must be 3600, 86400, or 604800 (the
 * Worker's allow-list). One 409 retry — the id is client-minted so the AAD
 * can bind it before upload; a collision just means mint again. */
export async function createShareLink(
  accessToken: string,
  payload: SharePayload,
  opts: { ttlSeconds: number; oneTime: boolean },
): Promise<ShareLink> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const id = b64url(crypto.getRandomValues(new Uint8Array(16)));
    const sealed = await seal(id, payload);
    const u = new URL(`${WORKER_BASE}/share`);
    u.searchParams.set("id", id);
    u.searchParams.set("ttl", String(opts.ttlSeconds));
    if (opts.oneTime) u.searchParams.set("views", "1");
    const r = await fetch(u, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}` },
      body: sealed.wire.slice().buffer as ArrayBuffer,
    });
    if (r.ok) {
      const j = (await r.json()) as { url: string; expires_at: number };
      return { url: `${j.url}#${sealed.keyFragment}`, expiresAt: j.expires_at, oneTime: opts.oneTime };
    }
    if (r.status === 409) continue;
    throw new ShareError(
      r.status === 413
        ? "Too large to share on your plan."
        : r.status === 402
          ? "Active share limit reached. Old links expire on their own."
          : r.status === 429
            ? "Slow down a little. Try again in a minute."
            : "Couldn't create the link. Check your connection and try again.",
    );
  }
  throw new ShareError("Couldn't create the link. Try again.");
}
