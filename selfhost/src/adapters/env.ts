// Builds the `Env` object the worker's fetch() handler expects, wired to the
// local adapters instead of Cloudflare bindings.
//
// Everything billing/auth-related is deliberately left undefined:
//   - No SUPABASE_URL / SUPABASE_JWT_SECRET  -> authenticate() skips the JWT path
//     entirely and uses the legacy device-token path (sha256 lookup in `tokens`).
//   - No STRIPE_*                            -> every /stripe/* route 503s and
//     billing is inert (the worker already early-returns without the keys).
//   - No RL_* limiters                       -> rateLimit() fails open (proceeds).
//   - VERIFY_GATE unset                      -> the verify-to-sync gate is off.
// The result: a pure, account-less, zero-knowledge sync data plane. Enrolled
// tokens carry tier "max", whose caps (250 GB storage, 500 MB/item) are
// effectively unlimited for a personal vault; lifting them further is a one-line
// change to worker/src/tiers.ts if ever needed.

import type Database from "better-sqlite3";
import { makeD1 } from "./d1";
import { makeR2 } from "./r2";
import { makeKV } from "./kv";

export function makeEnv(db: Database.Database, blobRoot: string): any {
  return {
    STORE: makeR2(blobRoot),
    DB: makeD1(db),
    PAIR: makeKV(db),
    APP_BASE_URL: process.env.RELIC_APP_BASE_URL ?? "http://localhost",
    // Stripe / Supabase / rate-limit / verify-gate intentionally absent.
  };
}
