// Relic self-host server entrypoint.
//
// Runs the EXACT same request handler as Relic Cloud (worker/src/index.ts,
// imported unchanged) on plain Node, bridging Cloudflare's Fetch-style handler
// to a node:http listener and backing its R2/D1/KV bindings with the local
// adapters. One codebase, two deploy targets, so the two can never drift.
//
// Storage lives entirely under RELIC_DATA_DIR (default /data in Docker):
//   <data>/relic.db      SQLite (worker tables + the kv table)
//   <data>/blobs/**      object storage (ciphertext only)

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";

// The unchanged production worker. Its default export is { fetch, queue,
// scheduled }. The worker package has no "type":"module", so tsx loads it as
// CJS and the handler can end up nested under one or more `default` wrappers.
// Unwrap until we find the object that actually has fetch().
import * as workerModule from "../../worker/src/index";
import { makeEnv } from "./adapters/env";

function pickHandler(m: any): any {
  let cur = m;
  for (let i = 0; i < 6 && cur; i++) {
    if (typeof cur.fetch === "function") return cur;
    cur = cur.default;
  }
  throw new Error("worker handler with fetch() not found");
}
const worker: any = pickHandler(workerModule);
import { handleEnroll } from "./enroll";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const DATA = process.env.RELIC_DATA_DIR || path.resolve("data");
const BLOBS = path.join(DATA, "blobs");
fs.mkdirSync(BLOBS, { recursive: true });

const db = new Database(path.join(DATA, "relic.db"));
db.pragma("journal_mode = WAL");
db.pragma("busy_timeout = 5000");

// Fresh-install schema (idempotent: every statement is CREATE TABLE IF NOT
// EXISTS). Shares the same file the Cloudflare deploy applies via migrations.
const schemaSql = fs.readFileSync(path.resolve(HERE, "../../worker/schema.sql"), "utf8");
db.exec(schemaSql);

const env = makeEnv(db, BLOBS);

// Hop-by-hop / fetch-managed headers we must not copy onto the synthetic Request.
const SKIP_HEADERS = new Set([
  "host",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "content-length",
  "expect",
  "upgrade",
  "proxy-connection",
]);

async function toRequest(nreq: http.IncomingMessage): Promise<Request> {
  const method = nreq.method || "GET";
  const url = "http://" + (nreq.headers.host || "localhost") + (nreq.url || "/");

  const headers = new Headers();
  for (const [k, v] of Object.entries(nreq.headers)) {
    if (v == null || SKIP_HEADERS.has(k.toLowerCase())) continue;
    if (Array.isArray(v)) v.forEach((x) => headers.append(k, x));
    else headers.set(k, v);
  }

  let body: Buffer | undefined;
  if (method !== "GET" && method !== "HEAD") {
    const chunks: Buffer[] = [];
    for await (const c of nreq) chunks.push(c as Buffer);
    if (chunks.length) body = Buffer.concat(chunks);
  }

  return new Request(url, { method, headers, body: body && body.length ? body : undefined });
}

async function writeResponse(res: Response, nres: http.ServerResponse): Promise<void> {
  nres.statusCode = res.status;
  res.headers.forEach((val, key) => nres.setHeader(key, val));
  if (res.body) {
    Readable.fromWeb(res.body as any).pipe(nres);
  } else {
    nres.end();
  }
}

const server = http.createServer(async (nreq, nres) => {
  try {
    const request = await toRequest(nreq);
    const pathname = new URL(request.url).pathname;

    // /enroll is the only route the self-host layer adds; everything else is the
    // unchanged worker.
    const response =
      pathname === "/enroll" && request.method === "POST"
        ? await handleEnroll(request, db)
        : await worker.fetch(request, env);

    await writeResponse(response, nres);
  } catch (e) {
    console.error("[relic] request error:", e);
    if (!nres.headersSent) {
      nres.statusCode = 500;
      nres.setHeader("Content-Type", "application/json");
    }
    nres.end(JSON.stringify({ error: "internal", message: String(e) }));
  }
});

const PORT = Number(process.env.PORT || 8787);
server.listen(PORT, () => {
  console.log(`relic self-host listening on :${PORT}  (data dir: ${DATA})`);
});

// Janitor: the worker's scheduled() handler (orphan-blob GC, tombstone GC, and
// billing sweeps that no-op without Stripe). Cloudflare runs it on cron; here an
// interval does. Best-effort; a failure never takes the server down.
const SIX_HOURS = 6 * 60 * 60 * 1000;
setInterval(() => {
  Promise.resolve(worker.scheduled?.({} as any, env, {} as any)).catch((e) =>
    console.error("[relic] janitor error:", e),
  );
}, SIX_HOURS).unref();
