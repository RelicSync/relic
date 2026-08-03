// Push one large file through the temporary mirror Worker into R2.
// See README.md — this is step 3 of a four-step, tear-it-down-after procedure.
//
//   MIRROR_URL=https://relic-tmp-mirror.<subdomain>.workers.dev \
//   UPLOAD_TOKEN=<same value as wrangler.toml> \
//   node scripts/mirror-large-model/push.mjs <local-file> <r2-key>
import { open, stat } from 'node:fs/promises'

const BASE = process.env.MIRROR_URL
const TOKEN = process.env.UPLOAD_TOKEN
if (!BASE || !TOKEN) throw new Error('set MIRROR_URL and UPLOAD_TOKEN')
// 32 MiB keeps each part well inside the Worker's 128 MB memory ceiling while
// staying above R2's 5 MiB minimum part size.
const PART = 32 * 1024 * 1024

const [file, key] = process.argv.slice(2)
const auth = { authorization: `Bearer ${TOKEN}` }

async function call(path, params, init = {}) {
  const url = new URL(path, BASE)
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
  const res = await fetch(url, { ...init, headers: { ...auth, ...(init.headers || {}) } })
  const body = await res.json().catch(() => ({ error: `HTTP ${res.status}` }))
  if (!res.ok || body.error) throw new Error(`${path} -> ${res.status} ${JSON.stringify(body)}`)
  return body
}

const { size } = await stat(file)
const total = Math.ceil(size / PART)
console.log(`${(size / 1048576).toFixed(1)} MiB -> ${key} in ${total} parts`)

const { uploadId } = await call('/create', { key }, { method: 'POST' })
const fh = await open(file, 'r')
const parts = []
try {
  for (let i = 0; i < total; i++) {
    const buf = Buffer.alloc(Math.min(PART, size - i * PART))
    await fh.read(buf, 0, buf.length, i * PART)
    let last
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        parts.push(await call('/part', { key, uploadId, part: i + 1 }, { method: 'PUT', body: buf }))
        last = null
        break
      } catch (e) {
        last = e
        console.log(`  part ${i + 1} attempt ${attempt} failed: ${e.message}`)
      }
    }
    if (last) throw last
    console.log(`  part ${i + 1}/${total} ok`)
  }
  const done = await call('/complete', { key, uploadId }, {
    method: 'POST',
    body: JSON.stringify(parts),
    headers: { 'content-type': 'application/json' },
  })
  console.log('complete:', JSON.stringify(done))
} catch (e) {
  // Never leave a dangling multipart upload accruing storage.
  await call('/abort', { key, uploadId }, { method: 'POST' }).catch(() => {})
  console.error('FAILED:', e.message)
  process.exitCode = 1
} finally {
  await fh.close()
}
