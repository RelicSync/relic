import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Unit tests run inside the Workers runtime (miniflare) with a real D1 binding,
// so applyStripeEvent / authenticate exercise actual SQL. No Stripe/Supabase
// network is hit (the tested paths only touch D1 + WebCrypto).
export default defineConfig({
  plugins: [
    // NOTE: vitest-pool-workers 0.18 (vitest 4) dropped per-test isolated
    // storage — tests share R2/D1/KV state within a run. Suites reset what
    // they touch in beforeEach (setupSchema for D1; explicit deletes for R2).
    cloudflareTest({
      miniflare: {
        compatibilityDate: "2026-06-01",
        d1Databases: ["DB"],
        kvNamespaces: ["PAIR"],
        r2Buckets: ["STORE"],
        bindings: {
          STRIPE_PRICE_MAP: '{"price_pro":"pro","price_max":"max"}',
        },
      },
    }),
  ],
  test: {},
});
