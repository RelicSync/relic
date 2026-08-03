// Per-tier capability table — the single source of truth for quota enforcement.
// `null` = unlimited / not enforced. Mirrors docs/cloudflare/05-billing.md §1.2.
//
// Storage is counted uniformly across ALL tiers (every stored byte, not just
// blobs); the old paid-only `blobQuota` accounting collapsed into `storage`.
// `devices` is enforced at token/session issuance (04-auth), not in this
// data-plane Worker.
export const MB = 1024 * 1024;
export const GB = 1024 * MB;

// `shares` = concurrently-active share links (expired/consumed don't count);
// `shareBytes` = max ciphertext size per share.
export const TIERS = {
  free: {
    item: 10 * MB, storage: 250 * MB, vault: 25, ring: 500, devices: 3,
    shares: 10, shareBytes: 5 * MB,
  },
  pro: {
    item: 100 * MB, storage: 25 * GB, vault: null, ring: null, devices: 10,
    shares: 100, shareBytes: 50 * MB,
  },
  max: {
    item: 500 * MB, storage: 250 * GB, vault: null, ring: null, devices: null,
    shares: null, shareBytes: 50 * MB,
  },
} as const;

export type Tier = keyof typeof TIERS;

export const isTier = (s: unknown): s is Tier =>
  s === "free" || s === "pro" || s === "max";
