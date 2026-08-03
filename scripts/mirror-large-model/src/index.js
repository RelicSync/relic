// Temporary upload shim: streams a large model file into the relic-models R2
// bucket via the binding's multipart API, because `wrangler r2 object put`
// refuses anything over 300 MiB. Deployed, used once, then deleted.
//
// Every route requires the bearer token and writes only to the key it is given.
// There is no read route and no listing route.

const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } })

export default {
  async fetch(req, env) {
    if (req.headers.get('authorization') !== `Bearer ${env.UPLOAD_TOKEN}`) {
      return new Response('unauthorized\n', { status: 401 })
    }
    const url = new URL(req.url)
    const key = url.searchParams.get('key')
    if (!key) return json({ error: 'key required' }, 400)

    try {
      switch (url.pathname) {
        case '/create': {
          const mpu = await env.MODELS.createMultipartUpload(key)
          return json({ uploadId: mpu.uploadId })
        }
        case '/part': {
          const mpu = env.MODELS.resumeMultipartUpload(key, url.searchParams.get('uploadId'))
          const part = await mpu.uploadPart(
            Number(url.searchParams.get('part')),
            await req.arrayBuffer(),
          )
          return json({ partNumber: part.partNumber, etag: part.etag })
        }
        case '/complete': {
          const mpu = env.MODELS.resumeMultipartUpload(key, url.searchParams.get('uploadId'))
          const obj = await mpu.complete(await req.json())
          return json({ size: obj.size, etag: obj.httpEtag })
        }
        case '/abort': {
          const mpu = env.MODELS.resumeMultipartUpload(key, url.searchParams.get('uploadId'))
          await mpu.abort()
          return json({ aborted: true })
        }
        default:
          return json({ error: 'no such route' }, 404)
      }
    } catch (e) {
      return json({ error: String(e && e.message ? e.message : e) }, 500)
    }
  },
}
