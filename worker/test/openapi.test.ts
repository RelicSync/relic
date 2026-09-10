// docs/openapi.json must describe the router in src/index.ts, in both
// directions: every operation in the spec reaches a real handler, and every
// route the router knows is in the spec. The spec is what relic.space serves
// at /openapi.json, so a route added here without a spec entry, or a spec
// entry for a route that no longer exists, fails this file.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import worker from "../src/index";
import spec from "../../docs/openapi.json";
import source from "../src/index.ts?raw";
import { setupSchema, sha256Hex } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const TOKEN = "openapi-token";
const ACCOUNT = "acct-openapi";
const DEVICE = "dev-openapi";

const METHODS = ["get", "put", "post", "patch", "delete"] as const;

/** A concrete URL path for a spec path template, with sample ids that satisfy
 *  each route's character rules. */
function concrete(template: string): string {
  return template.replace(/\{(\w+)\}/g, (_m, name: string) => {
    if (name === "uid") return "0190a8e2-7c4d-7000-8000-1a2b3c4d5e6f";
    if (template.startsWith("/blob/")) return "blob-0123abcd";
    if (template.startsWith("/share/") || template.startsWith("/s/")) return "AAAAAAAAAAAAAAAAAAAAAA";
    if (template.startsWith("/account/devices/")) return "dev-other";
    throw new Error(`no sample for {${name}} in ${template}`);
  });
}

/** Required query parameters, so the handler gets past its own validation and
 *  we can tell "reached the handler" from "no such route". */
type Param = { $ref?: string; name?: string; in?: string; required?: boolean };
function query(template: string, params: Param[]): string {
  const q = new URLSearchParams();
  for (const p of params) {
    const param = p.$ref
      ? (spec.components.parameters as Record<string, Param>)[p.$ref.split("/").pop()!]
      : p;
    if (param.in !== "query" || !param.required) continue;
    // The query id is the blob id on /blob* and the share id on /share.
    if (param.name === "id") q.set("id", template.startsWith("/share") ? "AAAAAAAAAAAAAAAAAAAAAA" : "blob-0123abcd");
    else if (param.name === "upload_id") q.set("upload_id", "u1");
    else if (param.name === "part") q.set("part", "1");
    else if (param.name === "ttl") q.set("ttl", "3600");
    else if (param.name === "pairing_id") q.set("pairing_id", "0190a8e2-7c4d-7000-8000-1a2b3c4d5e6f");
    else if (param.name === "slot") q.set("slot", "np");
    else q.set(param.name!, "1");
  }
  const s = q.toString();
  return s ? `?${s}` : "";
}

const paths = spec.paths as Record<string, Record<string, unknown>>;

beforeEach(async () => {
  await setupSchema(E.DB);
  await E.DB.prepare(
    "INSERT INTO tokens (token_hash, account_id, tier) VALUES (?1,?2,?3)",
  ).bind(await sha256Hex(TOKEN), ACCOUNT, "free").run();
});

describe("docs/openapi.json matches the router", () => {
  it("every operation in the spec reaches a handler (never the router's 'no route' 404)", async () => {
    const misses: string[] = [];
    for (const [template, item] of Object.entries(paths)) {
      for (const method of METHODS) {
        const op = item[method] as
          | { requestBody?: { content: Record<string, unknown> }; parameters?: Param[] }
          | undefined;
        if (!op) continue;
        const params = [...((item.parameters as Param[]) ?? []), ...(op.parameters ?? [])];
        const url = `https://x${concrete(template)}${query(template, params)}`;
        const headers: Record<string, string> = {
          Authorization: `Bearer ${TOKEN}`,
          "X-Relic-Device": DEVICE,
        };
        let body: BodyInit | undefined;
        if (op.requestBody) {
          if ("application/json" in op.requestBody.content) {
            headers["Content-Type"] = "application/json";
            body = "{}";
          } else {
            headers["Content-Type"] = "application/octet-stream";
            body = new Uint8Array(40);
          }
        }
        if (template === "/sync/socket") headers.Upgrade = "websocket";
        const res = await worker.fetch(
          new Request(url, { method: method.toUpperCase(), headers, body }),
          E,
        );
        const text = await res.text();
        if (res.status === 404 && text.includes("no route")) misses.push(`${method.toUpperCase()} ${template} -> ${text}`);
      }
    }
    expect(misses).toEqual([]);
  });

  it("every route the router matches by literal path is in the spec", () => {
    const literals = new Set<string>();
    for (const m of source.matchAll(/path === "(\/[^"]*)"/g)) literals.add(m[1]);
    expect(literals.size).toBeGreaterThan(10);
    const missing = [...literals].filter((p) => !(p in paths));
    expect(missing).toEqual([]);
  });

  it("every route the router matches by pattern is in the spec", () => {
    const patterns: string[] = [];
    for (const m of source.matchAll(/path\.match\(\/(\^.*?)\/\)/g)) patterns.push(m[1]);
    for (const m of source.matchAll(/\/(\^.*?)\/\.exec\(path\)/g)) patterns.push(m[1]);
    expect(patterns.length).toBeGreaterThan(5);
    const samples = Object.keys(paths).map(concrete);
    const uncovered = patterns.filter((src) => {
      const re = new RegExp(src);
      return !samples.some((s) => re.test(s));
    });
    expect(uncovered).toEqual([]);
  });

  it("is a 3.1 document whose every $ref resolves", () => {
    expect(spec.openapi).toMatch(/^3\.1\./);
    const refs: string[] = [];
    const walk = (node: unknown) => {
      if (Array.isArray(node)) return node.forEach(walk);
      if (node && typeof node === "object") {
        for (const [k, v] of Object.entries(node as Record<string, unknown>)) {
          if (k === "$ref" && typeof v === "string") refs.push(v);
          else walk(v);
        }
      }
    };
    walk(spec);
    expect(refs.length).toBeGreaterThan(50);
    const broken = refs.filter((r) => {
      if (!r.startsWith("#/")) return true;
      let cur: unknown = spec;
      for (const seg of r.slice(2).split("/")) {
        if (!cur || typeof cur !== "object" || !(seg in (cur as object))) return true;
        cur = (cur as Record<string, unknown>)[seg];
      }
      return false;
    });
    expect(broken).toEqual([]);
  });
});
