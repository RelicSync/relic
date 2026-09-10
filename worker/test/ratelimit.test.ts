// The RateLimit headers (docs/api.md "Rate limits") and the deprecation
// headers (docs/api.md "Versioning and deprecation"). The limiter binding
// itself is Cloudflare's; here it is a stub that says yes or no.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker from "../src/index";
import { deprecated, json } from "../src/http";
import { RATE_LIMIT_POLICIES, type RateLimiter } from "../src/ratelimit";
import example from "../wrangler.example.toml?raw";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const TOKEN = "ratelimit-token";
const ACCOUNT = "acct-ratelimit";

const allow: RateLimiter = { limit: async () => ({ success: true }) };
const refuse: RateLimiter = { limit: async () => ({ success: false }) };
const broken: RateLimiter = { limit: async () => { throw new Error("binding down"); } };

const health = (bindings: Record<string, RateLimiter>) =>
  worker.fetch(new Request("https://x/health"), { ...E, ...bindings });

beforeEach(async () => {
  await setupSchema(E.DB);
  await E.DB.prepare(
    "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)",
  ).bind(await sha256Hex(TOKEN), ACCOUNT, "free").run();
});

describe("the advertised policies are the configured ones", () => {
  it("RATE_LIMIT_POLICIES matches every ratelimit binding in wrangler.example.toml", () => {
    const configured: Record<string, { limit: number; period: number }> = {};
    const re = /name = "(RL_\w+)"[\s\S]*?simple = \{ limit = (\d+), period = (\d+) \}/g;
    for (const m of example.matchAll(re)) configured[m[1]] = { limit: Number(m[2]), period: Number(m[3]) };
    expect(Object.keys(configured).sort()).toEqual(Object.keys(RATE_LIMIT_POLICIES).sort());
    for (const [name, p] of Object.entries(RATE_LIMIT_POLICIES)) {
      expect({ limit: p.limit, period: p.period }, name).toEqual(configured[name]);
    }
  });

  it("policy names are unique and wire-safe", () => {
    const names = Object.values(RATE_LIMIT_POLICIES).map((p) => p.name);
    expect(new Set(names).size).toBe(names.length);
    for (const n of names) expect(n).toMatch(/^[a-z][a-z-]*$/);
  });
});

describe("RateLimit headers on a gated route", () => {
  it("a 2xx says which policy applied, and its quota and window", async () => {
    const res = await health({ RL_PLANS: allow });
    expect(res.status).toBe(200);
    expect(res.headers.get("RateLimit-Policy")).toBe('"public";q=30;w=60');
    expect(res.headers.get("RateLimit-Limit")).toBe("30");
    expect(res.headers.get("X-RateLimit-Limit")).toBe("30");
    expect(res.headers.get("Retry-After")).toBeNull();
    expect(res.headers.get("RateLimit-Remaining")).toBeNull();
  });

  it("a 429 adds Retry-After and the zero-remaining form", async () => {
    const res = await health({ RL_PLANS: refuse });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: "rate_limited" });
    expect(res.headers.get("Retry-After")).toBe("60");
    expect(res.headers.get("RateLimit")).toBe('"public";r=0;t=60');
    expect(res.headers.get("RateLimit-Policy")).toBe('"public";q=30;w=60');
    expect(res.headers.get("RateLimit-Remaining")).toBe("0");
    expect(res.headers.get("RateLimit-Reset")).toBe("60");
    expect(res.headers.get("X-RateLimit-Remaining")).toBe("0");
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("a server with no binding for the route sends none of them (self-host, tests)", async () => {
    const res = await health({});
    expect(res.status).toBe(200);
    for (const h of ["RateLimit-Policy", "RateLimit-Limit", "RateLimit", "Retry-After"]) {
      expect(res.headers.get(h), h).toBeNull();
    }
  });

  it("a limiter that throws fails open and stays silent", async () => {
    const res = await health({ RL_PLANS: broken });
    expect(res.status).toBe(200);
    expect(res.headers.get("RateLimit-Policy")).toBeNull();
  });

  it("the sync data plane advertises the sync policy on an authed reply", async () => {
    const res = await worker.fetch(
      new Request("https://x/relics?since=0", { headers: { Authorization: `Bearer ${TOKEN}` } }),
      { ...E, RL_SYNC: allow },
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("RateLimit-Policy")).toBe('"sync";q=900;w=60');
    expect(res.headers.get("RateLimit-Limit")).toBe("900");
  });

  it("a public share view advertises the share-view policy, even on its 404", async () => {
    const res = await worker.fetch(
      new Request("https://x/s/AAAAAAAAAAAAAAAAAAAAAA"),
      { ...E, RL_SHARE_VIEW: allow },
    );
    expect(res.headers.get("RateLimit-Policy")).toBe('"share-view";q=30;w=60');
  });

  it("an ungated route says nothing", async () => {
    const res = await worker.fetch(
      new Request("https://x/account", { headers: { Authorization: `Bearer ${TOKEN}` } }),
      { ...E, RL_PLANS: allow, RL_SYNC: allow },
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("RateLimit-Policy")).toBeNull();
  });

  it("browsers may read the headers cross-origin", async () => {
    const res = await health({ RL_PLANS: allow });
    const exposed = res.headers.get("Access-Control-Expose-Headers") ?? "";
    for (const h of ["RateLimit", "RateLimit-Policy", "Retry-After", "Deprecation", "Sunset"]) {
      expect(exposed).toContain(h);
    }
  });
});

describe("deprecated(): the headers a retiring route carries", () => {
  it("sets Deprecation, Sunset and the successor link", () => {
    const since = new Date("2026-09-10T00:00:00Z");
    const sunset = new Date("2027-03-09T00:00:00Z");
    const res = deprecated(json({ ok: true }), {
      since,
      sunset,
      successor: "https://api.relic.space/relics",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("Deprecation")).toBe(`@${Math.floor(since.getTime() / 1000)}`);
    expect(res.headers.get("Sunset")).toBe("Tue, 09 Mar 2027 00:00:00 GMT");
    expect(res.headers.get("Link")).toBe('<https://api.relic.space/relics>; rel="successor-version"');
  });

  it("works without a successor and keeps an existing Link", () => {
    const base = json({});
    base.headers.set("Link", '<https://relic.space/docs/api.md>; rel="describedby"');
    const res = deprecated(base, { since: new Date(0), sunset: new Date(86400 * 1000) });
    expect(res.headers.get("Deprecation")).toBe("@0");
    expect(res.headers.get("Sunset")).toBe("Fri, 02 Jan 1970 00:00:00 GMT");
    expect(res.headers.get("Link")).toBe('<https://relic.space/docs/api.md>; rel="describedby"');
  });
});
