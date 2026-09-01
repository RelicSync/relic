// Worker bindings + config, in one place.
//   - bindings (STORE/DB/STRIPE_QUEUE) come from wrangler.toml
//   - [vars] are non-secret config (SUPABASE_URL, STRIPE_PRICE_MAP, APP_BASE_URL)
//   - secrets (STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, SUPABASE_JWT_SECRET) are
//     set with `wrangler secret put` and never committed.
// Everything billing/auth-related is optional so the Worker still boots (and the
// sync data plane keeps working) before any of it is configured.
// Setup runbooks: docs/setup/.

import type { RateLimiter } from "./ratelimit";

export interface Env {
  // --- core data plane (already live) ---
  STORE: R2Bucket;
  DB: D1Database;

  // --- live-sync doorbell (optional -> self-host / local dev run without it) ---
  // Per-account Durable Object holding hibernatable WebSockets; a write pokes it
  // to broadcast a content-free "wake" nudge to the account's other devices
  // (src/notify.ts). Absent -> pokeSync() and /sync/socket no-op, clients poll.
  SYNC?: DurableObjectNamespace;

  // --- Stripe billing queue (optional; webhook falls back to inline apply) ---
  STRIPE_QUEUE?: Queue<StripeMessage>;

  // --- rate limiting (native [[unsafe.bindings]] ratelimit; optional -> fail
  // open). Keys: account id (per-account) or client IP (per-IP, pre-auth). ---
  RL_BILLING?: RateLimiter; // /stripe/checkout + /stripe/portal (per-account)
  RL_PAIR?: RateLimiter; // /pair/start|offer|claim (per-account)
  RL_DEVICE?: RateLimiter; // /account/devices register + revoke (per-account)
  RL_ACCOUNT?: RateLimiter; // DELETE /account — destructive (per-account)
  RL_PLANS?: RateLimiter; // GET /stripe/plans — public/pre-auth (per-IP)
  RL_SHARE?: RateLimiter; // POST/DELETE /share — create/revoke (per-account)
  RL_SHARE_VIEW?: RateLimiter; // GET /s/:id + /share/:id/blob — public (per-IP)
  RL_SYNC?: RateLimiter; // the encrypted-sync data plane (per-account): /relics,
  // /tombstones, /keyparams, /relic/*, /blob*, /ai + /ai/*. One knob across
  // reads AND writes. /sync/socket is excluded, because MAX_SOCKETS in
  // notify.ts governs that one.

  // --- pairing relay + device-revocation set (docs/cloudflare/13 §5.5, 04 §2.3) ---
  // One KV namespace, two key prefixes: `pair:` (QR transfer slots, ~120s TTL,
  // single-use) and `rev:` (removed device ids, 90d TTL). Optional so the Worker
  // still boots before it's configured; the routes + guard check for it.
  PAIR?: KVNamespace;

  // --- Supabase auth bridge (docs/setup/01-supabase.md) ---
  SUPABASE_URL?: string; // var, canonical auth origin, e.g. https://auth.relic.space
  SUPABASE_LEGACY_URL?: string; // var, the *.supabase.co project URL — tokens
  // minted before the custom-domain switch (or by old client builds) carry this
  // issuer, so both are accepted. Same JWKS either way.
  SUPABASE_JWT_SECRET?: string; // secret — ONLY if using legacy HS256 tokens
  SUPABASE_SERVICE_ROLE_KEY?: string; // secret — GoTrue admin key. Used for
  // exactly one thing: DELETE /auth/v1/admin/users/{sub} during account
  // deletion, so deleting an account also deletes the identity (and its email)
  // in Supabase — App Store Guideline 5.1.1(v). Absent (self-host, legacy
  // device-token deploys, any setup with no Supabase) -> that call is skipped
  // and the rest of the teardown is unaffected. See src/account.ts.

  // --- Stripe (docs/setup/03-stripe.md) ---
  STRIPE_SECRET_KEY?: string; // secret (restricted key)
  STRIPE_WEBHOOK_SECRET?: string; // secret (whsec_...)
  STRIPE_PRICE_MAP?: string; // var, JSON: {"price_xxx":"pro","price_yyy":"max"}
  STRIPE_TAX?: string; // var, "on" to enable Stripe automatic_tax (needs tax origin registered)
  APP_BASE_URL?: string; // var, e.g. https://relic.space

  // --- Resend transactional email (docs/setup/08-email-runbook) ---
  RESEND_API_KEY?: string; // secret — post-checkout zero-devices setup nudge;
  // absent -> the email is skipped silently (the webhook still succeeds).

  // --- verify-to-sync gate (optional) ---
  // "on" rejects sync WRITES from Supabase identities whose access token shows
  // an unverified email; unset/"off" disables it. Reads/deletes stay open and
  // legacy device-token auth is grandfathered (see syncWriteGate in index.ts).
  VERIFY_GATE?: string; // var, "on" | "off"
}

// The minimal, idempotent envelope we put on the billing queue (and also build
// inline / during reconcile). `data` is the Stripe event's `data.object`.
export interface StripeMessage {
  id: string; // evt_... — Stripe's idempotency key
  type: string; // e.g. customer.subscription.updated
  created: number; // unix seconds (event ordering)
  // deno-lint-ignore no-explicit-any
  data: any; // the subscription / session / invoice object
}
