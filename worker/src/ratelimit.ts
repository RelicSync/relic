// Native Cloudflare rate limiting (the [[unsafe.bindings]] type="ratelimit"
// blocks in wrangler.toml). Each limiter is its own namespace with a fixed
// limit/period; the caller supplies the bucket key — the account id for authed
// routes, the client IP for pre-auth. We gate the expensive/abusable routes so
// one account (or IP) can't hammer Stripe, the pairing relay, the device
// registry, or the destructive account-delete path.
//
// Fail-open by design: if a binding isn't provisioned (local dev, tests, or a
// deploy before the namespaces exist) rateLimit() returns null and the request
// proceeds. Keeping the sync data plane available matters more than perfect
// throttling, and every gated route still enforces its own auth + validation.

import { err } from "./http";

// The shape of a Cloudflare ratelimit binding. workers-types doesn't export a
// stable name for it across versions, so we pin just the one method we call.
export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

// Returns a 429 Response when the limiter rejects, or null to proceed. `key`
// buckets the count — pass the account id (per-account) or the client IP
// (per-IP, pre-auth).
export async function rateLimit(
  limiter: RateLimiter | undefined,
  key: string,
): Promise<Response | null> {
  if (!limiter) return null; // unconfigured -> fail open
  try {
    const { success } = await limiter.limit({ key });
    return success ? null : err(429, "rate_limited", "too many requests; slow down");
  } catch {
    return null; // limiter error -> fail open rather than drop legitimate traffic
  }
}

// Best-effort client IP for pre-auth (per-IP) limiting. CF-Connecting-IP is set
// by Cloudflare's edge on our zone and can't be spoofed by the client.
export const clientIp = (req: Request): string =>
  req.headers.get("CF-Connecting-IP") ?? "unknown";
