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
    item: 2 * MB, storage: 250 * MB, vault: 100, ring: 500, devices: 3,
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

// The free history ring is 500 for accounts that existed before 2026-10-20 and
// 100 for every account created on or after it. Existing free users keep the
// cap they signed up under: dropping it on them would push hundreds of copies
// out of view at once and hard-delete the images among them. `TIERS.free.ring`
// stays the legacy number so a missing creation date never shrinks anyone.
export const RING_NEW_FROM = 1792454400; // 2026-10-20T00:00:00Z
export const RING_NEW = 100;

/** The history ring for one account: null when the tier has none. */
export function ringCap(tier: Tier, createdAt: number | null | undefined): number | null {
  const legacy = TIERS[tier].ring;
  if (legacy === null) return null;
  return createdAt != null && createdAt >= RING_NEW_FROM ? RING_NEW : legacy;
}

/** accounts.created_at, or null when the row is missing. */
export async function accountCreatedAt(db: D1Database, account: string): Promise<number | null> {
  const row = await db
    .prepare("SELECT created_at FROM accounts WHERE account_id = ?1")
    .bind(account)
    .first<{ created_at: number }>();
  return row?.created_at ?? null;
}

export const isTier = (s: unknown): s is Tier =>
  s === "free" || s === "pro" || s === "max";
