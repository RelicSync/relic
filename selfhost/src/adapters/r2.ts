// An R2Bucket-compatible shim over the local filesystem.
//
// The worker stores opaque ciphertext under keys like:
//   users/<acct>/relics/<uid>        (envelope bodies)
//   users/<acct>/blob/<id>           (attachment ciphertext, single- or multi-part)
//   users/<acct>/keyparams.json      (wrapped key params)
//   shares/<id>                      (share ciphertext)
// Every key is a slash-delimited path, so it maps 1:1 onto files under a root
// directory. Object storage semantics (get/put/head/delete/list + multipart)
// all have faithful filesystem equivalents; the same code later points at
// S3/MinIO for the scale-up path without touching the worker.
//
// Only the R2 surface the worker actually calls is implemented.

import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const isWebStream = (v: unknown): v is ReadableStream =>
  !!v && typeof (v as ReadableStream).getReader === "function";

function toBuf(value: unknown): Buffer {
  if (typeof value === "string") return Buffer.from(value, "utf8");
  if (value instanceof ArrayBuffer) return Buffer.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  return Buffer.from(String(value), "utf8");
}

// A minimal R2Object: the worker reads `.body` (as a Response body), `.size`,
// `.uploaded` (sweep), and calls `.json()` (listRelics).
function r2object(filePath: string, key: string, size: number, uploaded: Date) {
  return {
    key,
    size,
    uploaded,
    get body(): ReadableStream {
      return Readable.toWeb(fs.createReadStream(filePath)) as unknown as ReadableStream;
    },
    async arrayBuffer(): Promise<ArrayBuffer> {
      const b = await fsp.readFile(filePath);
      return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
    },
    async text(): Promise<string> {
      return fsp.readFile(filePath, "utf8");
    },
    async json<T = unknown>(): Promise<T> {
      return JSON.parse(await fsp.readFile(filePath, "utf8")) as T;
    },
  };
}

export function makeR2(root: string) {
  const mpuRoot = path.join(root, ".mpu");
  // Guard against path traversal: resolve and confirm the key stays under root.
  const filePath = (key: string): string => {
    const p = path.resolve(root, key);
    if (p !== root && !p.startsWith(root + path.sep)) {
      throw new Error("invalid object key");
    }
    return p;
  };
  const mpuDir = (uploadId: string) => path.join(mpuRoot, uploadId);

  async function walk(dir: string, base: string, out: { key: string; size: number; mtime: Date }[]) {
    let entries: fs.Dirent[];
    try {
      entries = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const abs = path.join(dir, e.name);
      const rel = base ? base + "/" + e.name : e.name;
      if (e.isDirectory()) {
        if (abs === mpuRoot) continue; // never surface in-flight multipart parts
        await walk(abs, rel, out);
      } else if (e.isFile()) {
        const st = await fsp.stat(abs);
        out.push({ key: rel, size: st.size, mtime: st.mtime });
      }
    }
  }

  return {
    async get(key: string) {
      const p = filePath(key);
      try {
        const st = await fsp.stat(p);
        if (!st.isFile()) return null;
        return r2object(p, key, st.size, st.mtime);
      } catch {
        return null;
      }
    },

    async head(key: string) {
      const p = filePath(key);
      try {
        const st = await fsp.stat(p);
        if (!st.isFile()) return null;
        return { key, size: st.size, uploaded: st.mtime };
      } catch {
        return null;
      }
    },

    async put(key: string, value: unknown) {
      const p = filePath(key);
      await fsp.mkdir(path.dirname(p), { recursive: true });
      if (isWebStream(value)) {
        await pipeline(Readable.fromWeb(value as any), fs.createWriteStream(p));
      } else {
        await fsp.writeFile(p, toBuf(value));
      }
      const st = await fsp.stat(p);
      return { key, size: st.size };
    },

    async delete(key: string | string[]) {
      const keys = Array.isArray(key) ? key : [key];
      await Promise.all(
        keys.map(async (k) => {
          try {
            await fsp.rm(filePath(k));
          } catch {
            /* already gone — delete is idempotent */
          }
        }),
      );
    },

    async list(opts: { prefix?: string; cursor?: string; limit?: number } = {}) {
      const { prefix = "", cursor, limit = 1000 } = opts;
      const all: { key: string; size: number; mtime: Date }[] = [];
      await walk(root, "", all);
      let matched = all.filter((o) => o.key.startsWith(prefix));
      matched.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
      if (cursor) matched = matched.filter((o) => o.key > cursor);
      const page = matched.slice(0, limit);
      const truncated = matched.length > limit;
      return {
        objects: page.map((o) => ({ key: o.key, size: o.size, uploaded: o.mtime })),
        truncated,
        cursor: truncated ? page[page.length - 1].key : undefined,
      };
    },

    // --- multipart (blob.ts chunked uploads) --------------------------------
    async createMultipartUpload(key: string) {
      const uploadId = randomUUID();
      await fsp.mkdir(mpuDir(uploadId), { recursive: true });
      return { key, uploadId };
    },

    resumeMultipartUpload(key: string, uploadId: string) {
      const dir = mpuDir(uploadId);
      const partPath = (n: number) => path.join(dir, String(n).padStart(6, "0"));
      return {
        key,
        uploadId,
        async uploadPart(partNumber: number, data: unknown) {
          await fsp.mkdir(dir, { recursive: true });
          const pp = partPath(partNumber);
          if (isWebStream(data)) {
            await pipeline(Readable.fromWeb(data as any), fs.createWriteStream(pp));
          } else {
            await fsp.writeFile(pp, toBuf(data));
          }
          const st = await fsp.stat(pp);
          return { partNumber, etag: `"${st.size}-${partNumber}"` };
        },
        async complete(parts: { partNumber: number; etag: string }[]) {
          const fp = filePath(key);
          await fsp.mkdir(path.dirname(fp), { recursive: true });
          const ws = fs.createWriteStream(fp);
          const ordered = [...parts].sort((a, b) => a.partNumber - b.partNumber);
          for (const pt of ordered) {
            await new Promise<void>((resolve, reject) => {
              const rs = fs.createReadStream(partPath(pt.partNumber));
              rs.on("error", reject);
              rs.on("end", resolve);
              rs.pipe(ws, { end: false });
            });
          }
          await new Promise<void>((resolve) => ws.end(resolve));
          await fsp.rm(dir, { recursive: true, force: true });
          const st = await fsp.stat(fp);
          return { key, size: st.size };
        },
        async abort() {
          await fsp.rm(dir, { recursive: true, force: true });
        },
      };
    },
  };
}
