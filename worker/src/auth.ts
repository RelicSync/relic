// Authentication. Two paths, tried in order:
//
//   1. Supabase JWT (the bridge identity provider, docs/cloudflare/04-auth.md).
//      The client sends Supabase's access token as the bearer. We verify it at
//      the edge (JWKS for asymmetric signing keys, or the shared secret for
//      legacy HS256) and use the `sub` claim as the stable account_id — unless
//      an `account_links` row binds that sub to a pre-existing account (vaults
//      that predate email sign-in), in which case the linked account wins for
//      everything: data, tier, billing. Tier is read from the `accounts`
//      fast-path column (kept current by the Stripe webhook consumer).
//      INVARIANT: auth identity is wholly separate from the E2E vault key —
//      logging in never unlocks anything.
//
//   2. Legacy device token. sha256(token) looked up in the `tokens` table.
//      Kept working so existing installs and the headless relic-cli don't break.
//
// Both return { account, tier }. The Supabase path additionally carries email
// (used to pre-fill Stripe Checkout).

import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";
import type { Env } from "./env";
import { isTier, type Tier } from "./tiers";
import { err } from "./http";

export interface Auth {
  account: string;
  tier: Tier;
  email?: string;
  device?: string; // the X-Relic-Device id, when the client sent one
  supabase?: boolean; // true when the identity came from a Supabase JWT (not a
  // legacy device token). Legacy tokens are grandfathered past the verify gate.
  emailVerified?: boolean; // Supabase path only: the token's email-verification
  // signal (see isEmailVerified). Undefined = unknown / not applicable.
  tokenIssuedAt?: number; // Supabase path only: the JWT's iat (unix seconds).
  // Destructive routes (DELETE /account) use it to demand a fresh token so a
  // stale leaked bearer alone can't destroy an account. Undefined = legacy.
}

// Device revocation set (KV `rev:` prefix). A removed device id is parked here so
// the stateless hot path can hard-reject it — but ONLY for requests that carry
// X-Relic-Device (our own client always does). TTL bounds how long a removed
// device stays blocked without re-registering. See docs/cloudflare/04-auth.md §2.3.
export const REV_TTL = 90 * 24 * 60 * 60; // 90 days
export const revKey = (account: string, device: string) =>
  `rev:${account}:${device}`;

// Cached across requests in a warm isolate. createRemoteJWKSet handles its own
// key caching + rotation.
let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

// OAuth providers whose sign-in already proves control of the address. GoTrue
// records the method(s) in app_metadata.provider / app_metadata.providers.
const OAUTH_PROVIDERS = new Set([
  "google", "github", "apple", "azure", "facebook", "gitlab", "bitbucket",
  "discord", "twitter", "slack", "linkedin", "linkedin_oidc", "notion",
  "spotify", "twitch", "workos", "zoom", "figma", "kakao", "keycloak", "fly",
]);

// Decide, from the (already signature-verified) Supabase access-token payload,
// whether the email is verified.
//
// WHAT SUPABASE PUTS IN THE JWT (GoTrue access token): `email`, plus
//   - app_metadata.provider (string) and app_metadata.providers (string[]) —
//     the sign-in method(s); "email"/"phone" for password/OTP signups, else an
//     OAuth provider name.
//   - user_metadata.email_verified (bool) — flipped true once the confirmation
//     link is clicked; present on the email provider.
//   - email_confirmed_at — an ISO timestamp on some GoTrue versions; not
//     guaranteed in every release, so it is only a fallback.
// Rules:
//   1. any OAuth provider  -> verified (the provider vouched for the address).
//   2. email/phone signup  -> verified iff user_metadata.email_verified === true
//      OR email_confirmed_at is present.
//   3. no signal we recognize -> return true (fail open). A validly-signed token
//      whose shape we don't understand shouldn't be locked out of syncing; the
//      gate is a best-effort nudge, not a security boundary. Documented limit.
// deno-lint-ignore no-explicit-any
function isEmailVerified(payload: any): boolean {
  const app = payload?.app_metadata ?? {};
  const providers: string[] = Array.isArray(app.providers)
    ? app.providers
    : typeof app.provider === "string"
    ? [app.provider]
    : [];
  if (providers.some((p) => OAUTH_PROVIDERS.has(p))) return true;
  const um = payload?.user_metadata ?? {};
  if (um.email_verified === true || um.phone_verified === true) return true;
  if (typeof payload?.email_confirmed_at === "string" && payload.email_confirmed_at) return true;
  // Only a plain email/phone identity with no positive signal is treated as
  // unverified; anything else (unknown provider, no metadata) fails open.
  if (providers.length && providers.every((p) => p === "email" || p === "phone")) return false;
  return true;
}

async function verifySupabaseJwt(
  token: string,
  env: Env,
): Promise<{ sub: string; email?: string; emailVerified: boolean; iat?: number } | null> {
  try {
    // Accept the custom auth domain AND the raw project URL: which one a token
    // names as `iss` depends on where the client fetched it (old builds and
    // pre-switch sessions use the *.supabase.co origin). Same signing keys.
    const issuers = [env.SUPABASE_URL, env.SUPABASE_LEGACY_URL]
      .filter((u): u is string => !!u)
      .map((u) => `${u}/auth/v1`);
    const issuer = issuers.length ? issuers : undefined;
    let payload: JWTPayload;
    if (env.SUPABASE_JWT_SECRET) {
      const key = new TextEncoder().encode(env.SUPABASE_JWT_SECRET);
      ({ payload } = await jwtVerify(token, key, { audience: "authenticated", issuer }));
    } else if (env.SUPABASE_URL) {
      if (!jwks) {
        jwks = createRemoteJWKSet(
          new URL(`${env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`),
        );
      }
      ({ payload } = await jwtVerify(token, jwks, { audience: "authenticated", issuer }));
    } else {
      return null;
    }
    if (!payload.sub) return null;
    return {
      sub: payload.sub,
      email: typeof payload.email === "string" ? payload.email : undefined,
      emailVerified: isEmailVerified(payload),
      iat: typeof payload.iat === "number" ? payload.iat : undefined,
    };
  } catch {
    return null; // expired / wrong sig / not a Supabase token → try legacy path
  }
}

// Read (and lazily provision) the cached tier for an account. The Stripe webhook
// consumer keeps `accounts.tier` current; the reconcile cron handles grace
// expiry. First contact for a new account writes a free row, once.
async function tierForAccount(env: Env, accountId: string, email?: string): Promise<Tier> {
  const row = await env.DB.prepare("SELECT tier FROM accounts WHERE account_id = ?1")
    .bind(accountId)
    .first<{ tier: string }>();
  if (row && isTier(row.tier)) return row.tier;
  await env.DB.prepare(
    "INSERT OR IGNORE INTO accounts (account_id, email) VALUES (?1, ?2)",
  ).bind(accountId, email ?? null).run();
  return "free";
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function authenticate(req: Request, env: Env): Promise<Auth | Response> {
  const header = req.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return err(401, "unauthorized", "missing bearer token");
  const token = header.slice(7);

  let base: Auth | null = null;

  // (1) Supabase JWT — only attempt when configured and the token looks like a
  // JWT (three dot-separated segments).
  if ((env.SUPABASE_URL || env.SUPABASE_JWT_SECRET) && token.split(".").length === 3) {
    const claims = await verifySupabaseJwt(token, env);
    if (claims) {
      // Resolve through account_links first: a linked identity acts AS the
      // linked account (see header). No row → the sub is the account id.
      const link = await env.DB.prepare(
        "SELECT account_id FROM account_links WHERE supabase_sub = ?1",
      ).bind(claims.sub).first<{ account_id: string }>();
      const account = link?.account_id ?? claims.sub;
      const tier = await tierForAccount(env, account, claims.email);
      base = {
        account,
        tier,
        email: claims.email,
        supabase: true,
        emailVerified: claims.emailVerified,
        tokenIssuedAt: claims.iat,
      };
    }
    // not a valid Supabase token → fall through to the legacy path
  }

  // (2) Legacy device token.
  if (!base) {
    const hash = await sha256Hex(token);
    const row = await env.DB.prepare(
      "SELECT account_id, tier FROM tokens WHERE token_hash = ?1 AND revoked = 0",
    ).bind(hash).first<{ account_id: string; tier: string }>();
    if (!row) return err(401, "unauthorized", "unknown or revoked token");
    base = { account: row.account_id, tier: isTier(row.tier) ? row.tier : "free" };
  }

  // Device-revocation guard: cheap, and only when the client labels the request
  // with X-Relic-Device. A non-revoked device is a near-free (edge-cached) KV hit.
  const dev = req.headers.get("X-Relic-Device");
  if (dev) {
    if (env.PAIR && (await env.PAIR.get(revKey(base.account, dev)))) {
      return err(401, "device_revoked", "this device has been removed");
    }
    base.device = dev;
  }
  return base;
}
