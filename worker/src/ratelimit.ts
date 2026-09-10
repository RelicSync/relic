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
//
// Every response from a gated route also says which policy applied, in the
// standard RateLimit headers (docs/api.md "Rate limits"), so a client can pace
// itself instead of guessing. The binding only reports pass/fail, not a
// remaining count, so a 2xx carries the quota and window and a 429 carries
// the zero-remaining form plus Retry-After. A server with no binding for a
// route sends none of these: an advertised limit that nothing enforces would
// be a lie.

import { err } from "./http";

// The shape of a Cloudflare ratelimit binding. workers-types doesn't export a
// stable name for it across versions, so we pin just the one method we call.
export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

// One row per ratelimit binding in wrangler.example.toml, with the numbers
// the API advertises. They must match the deployed wrangler.toml, which is
// why test/ratelimit.test.ts checks this table against the example file.
// `name` is the policy name on the wire (RateLimit-Policy: "sync";q=900;w=60).
export const RATE_LIMIT_POLICIES = {
  RL_BILLING: { name: "billing", limit: 12, period: 60 },
  RL_PAIR: { name: "pair", limit: 40, period: 60 },
  RL_DEVICE: { name: "device", limit: 20, period: 60 },
  RL_ACCOUNT: { name: "account", limit: 3, period: 60 },
  RL_PLANS: { name: "public", limit: 30, period: 60 },
  RL_SHARE: { name: "share", limit: 10, period: 60 },
  RL_SHARE_VIEW: { name: "share-view", limit: 30, period: 60 },
  RL_SYNC: { name: "sync", limit: 900, period: 60 },
} as const;

export type RateLimitPolicy = keyof typeof RATE_LIMIT_POLICIES;

// Which policy gated this request, so the router can stamp the headers on
// whatever response the handler ends up returning. Keyed by the Request
// object, so nothing leaks between requests.
const applied = new WeakMap<Request, RateLimitPolicy>();

// Returns a 429 Response when the limiter rejects, or null to proceed. `key`
// buckets the count — pass the account id (per-account) or the client IP
// (per-IP, pre-auth). `policy` names the binding, for the headers.
export async function rateLimit(
  req: Request,
  limiter: RateLimiter | undefined,
  policy: RateLimitPolicy,
  key: string,
): Promise<Response | null> {
  if (!limiter) return null; // unconfigured -> fail open, and stay silent
  try {
    const { success } = await limiter.limit({ key });
    applied.set(req, policy);
    return success ? null : err(429, "rate_limited", "too many requests; slow down");
  } catch {
    return null; // limiter error -> fail open rather than drop legitimate traffic
  }
}

// Stamp the RateLimit headers for the policy that gated `req` onto `res`.
// A no-op for requests no limiter saw, and for a WebSocket upgrade (a 101
// cannot be rebuilt without losing its socket).
export function withRateLimitHeaders(req: Request, res: Response): Response {
  const policy = applied.get(req);
  if (!policy || res.status === 101) return res;
  const p = RATE_LIMIT_POLICIES[policy];
  const out = mutable(res);
  const h = out.headers;
  // draft-ietf-httpapi-ratelimit-headers (structured field form) ...
  h.set("RateLimit-Policy", `"${p.name}";q=${p.limit};w=${p.period}`);
  // ... plus the older draft names most client libraries already parse.
  h.set("RateLimit-Limit", String(p.limit));
  h.set("X-RateLimit-Limit", String(p.limit));
  if (out.status === 429) {
    // The window is at most `period` seconds long, so that is the longest a
    // caller can need to wait; a smaller true value is not observable here.
    h.set("Retry-After", String(p.period));
    h.set("RateLimit", `"${p.name}";r=0;t=${p.period}`);
    h.set("RateLimit-Remaining", "0");
    h.set("RateLimit-Reset", String(p.period));
    h.set("X-RateLimit-Remaining", "0");
  }
  return out;
}

// Responses that came out of fetch() (R2 bodies, the share page) have frozen
// headers; rebuilding one keeps status, body and headers and makes them
// writable again.
function mutable(res: Response): Response {
  try {
    res.headers.set("X-Relic-Probe", "1");
    res.headers.delete("X-Relic-Probe");
    return res;
  } catch {
    return new Response(res.body, res);
  }
}

// Best-effort client IP for pre-auth (per-IP) limiting. CF-Connecting-IP is set
// by Cloudflare's edge on our zone and can't be spoofed by the client.
export const clientIp = (req: Request): string =>
  req.headers.get("CF-Connecting-IP") ?? "unknown";
