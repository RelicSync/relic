# Mirroring a large model file to R2

Every model `relic-sift` downloads is mirrored on our own R2 bucket rather than
fetched from HuggingFace, so a first-run download never depends on a third
party's uptime or rate limits. For anything under 300 MiB, just use wrangler:

```powershell
wrangler r2 object put relic-models/relic-sift/v1/<name> --file <path> --remote
```

Note `--remote`. Without it, wrangler v4 writes to a *local simulated* bucket and
reports success, and a later `r2 object get` will tell you the key does not exist
while the public URL happily serves the real object. That discrepancy is the tell.

Over 300 MiB, wrangler refuses outright:

```
Error: Wrangler only supports uploading files up to 300 MiB in size
```

R2's multipart API has no such limit, but reaching it over S3 needs an R2 API
token that does not otherwise exist. Rather than mint a lasting credential, this
directory deploys a throwaway Worker that has the bucket bound, pushes the file
through it, and deletes the Worker.

## Procedure

1. Copy `wrangler.toml.example` to `wrangler.toml` and put a fresh random token
   in `UPLOAD_TOKEN`:

   ```powershell
   node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
   ```

2. Deploy, and note the `workers.dev` URL it prints:

   ```powershell
   wrangler deploy
   ```

   The route takes up to a minute to propagate. Until it does you get
   `error code: 1042` with HTTP 404 — that is propagation, not a broken Worker.
   Retry before debugging anything.

3. Push the file:

   ```powershell
   $env:MIRROR_URL   = "https://relic-tmp-mirror.<subdomain>.workers.dev"
   $env:UPLOAD_TOKEN = "<the token from step 1>"
   node push.mjs "$env:LOCALAPPDATA\relic-sift\models\<name>" "relic-sift/v1/<name>"
   ```

4. **Delete the Worker.** It can write to the bucket; do not leave it up.

   ```powershell
   wrangler delete --name relic-tmp-mirror --force
   ```

## Then verify

Size alone is not proof — a multipart upload fails by dropping or misordering a
part, which can leave the length plausible. Compare bytes at each 32 MiB seam
against the local file, and confirm the URL basename matches the `ModelFile`
`name` in `relic-sift/src/models.rs`; the registry relies on those being equal.

`push.mjs` aborts the multipart upload if any part fails, so a crashed run does
not leave a dangling upload quietly accruing storage.
