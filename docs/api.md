# Relic — Backend API Contract v1

Cloudflare Worker, JSON over HTTPS. Implements SPEC §8 against R2 (objects) +
D1 (accounts, tokens, counters).

A machine-readable OpenAPI 3.1 description of every route below is
`docs/openapi.json`, served at https://relic.space/openapi.json. The worker
test `worker/test/openapi.test.ts` fails when the two drift.

## Auth (implemented — Supabase JWT bridge)

`Authorization: Bearer <token>` on every route. Two token kinds are accepted
(`worker/src/auth.ts`):

1. **Supabase access JWT** (the normal path): verified at the edge
   (JWKS/ES256, HS256 fallback); its `sub` is the account id. Accounts are
   auto-provisioned on first sight; tier comes from `accounts.tier`
   (Stripe-driven).
2. **Legacy device token** (opaque 32B base64url): still honored via the
   `tokens` table for old installs and the CLI.

Devices identify themselves with an `X-Relic-Device` header; a KV revocation
set (`rev:` prefix) lets a device be cut off before its JWT expires.

Self-hosted deployments do not use any of this: `selfhost/` enrolls devices
account-lessly from the vault passphrase alone (`selfhost/src/enroll.ts`).

Consumers of this API: the desktop/mobile apps (`app/`), the **web vault**
(`crypto/js/vault-api.ts` — uses these exact routes including MPU), and
`relic-cli` (device-token path).

## Error model

Non-2xx responses carry `{ "error": "<code>", "message": "<human text>" }`.

| HTTP | code | meaning |
|---|---|---|
| 400 | `invalid_envelope` | malformed JSON / missing fields / bad version |
| 401 | `unauthorized` | missing, unknown, or revoked token |
| 401 | `session_revoked` | token predates a device removal; sign in again |
| 402 | `storage_quota` | tier storage quota exceeded (250 MB / 25 GB / 250 GB) |
| 402 | `vault_cap` | free-tier promoted-relic cap reached |
| 404 | `not_found` | unknown uid / blob key / no keyparams yet |
| 409 | `keyparams_exists` | `PUT /keyparams` without `?replace=1` when one exists |
| 413 | `too_large` | relic/blob exceeds tier per-item size cap |
| 410 | `gone` | a route past its sunset date (see Versioning and deprecation) |
| 429 | `rate_limited` | per-account or per-IP rate limit (see Rate limits) |

## Routes

### `GET /health` (public)
→ `200 {"ok":true}` when the router and D1 answer; `503 unhealthy` otherwise.
For uptime monitoring; per-IP rate-limited.

### `GET /keyparams`
→ `200` key-params record (docs/crypto.md) · `404 not_found` if never set.

### `PUT /keyparams`
Body: key-params record. First write succeeds; subsequent writes require
`?replace=1` (passphrase change re-wrap). → `200 {}`.

### `PUT /relic/:uid`
Body: EncryptedRelic envelope (docs/wire-format.md). Upsert by `uid`.
- LWW: if stored `updated_at` ≥ envelope's → `200 { "stale": true }` (no-op).
- Enforces per-item size cap (413), storage quota (402), vault cap (402, only
  when this PUT newly sets `promoted` on a free account at cap).
- Free tier: after write, if unpromoted count > 500, delete oldest unpromoted
  relics + their blobs + write tombstones (lazy prune; D1 counters, verified by
  a scheduled reconcile job).
→ `200 { "stale": false }`.

### `GET /relics?since=<ts>&cursor=<c>&limit=<n≤500>`
Envelopes with `updated_at > since`, ascending, paginated.
→ `200 { "items": [...], "next_cursor": "..." | null }`.
Initial sync: `since=0`, page through. Steady state: `since = <sync_state cursor>`.

### `DELETE /relic/:uid`
Deletes relic object + referenced blob (from the envelope's plaintext
`blob_key`), writes tombstone, decrements counters.
→ `200 {}` (idempotent; deleting a missing uid is 200).
A later `PUT` for a uid with a live tombstone is ignored (`200 {"stale":true}`)
so offline devices can't resurrect deleted relics.

### AI records — `/ai/*` (generated title + tags, sealed)

The enrichment result for a relic (a title and tags the on-device models
produced) syncs as its own sealed record so every device shows the same title
and only one device does the work (`worker/src/ai.ts`). The Worker never sees
the title: `ct` is sealed under AAD `relic.ai.v1:<uid>`.

- `POST /ai/claim` `{ "items": [{ "uid", "level" }] }` (≤64, needs
  `X-Relic-Device`) — one device wins a 10-minute lease per uid.
  → `200 { "granted": [uid], "done": [{ "uid", "level" }], "lease_expires_at" }`.
  A uid in neither list is leased by a live peer.
- `POST /ai/release` `{ "uids": [...] }` — hand back leases you will not use.
  → `200 { "released": n }`.
- `PUT /ai/:uid` `{ "v": 1, "uid", "ai_at", "level", "n", "ct" }` (`ct` ≤ 48 KiB)
  — publish. Not LWW: a higher level wins, at equal level the earliest result
  stands, a device may amend its own. A losing write is `200 { "stale": true }`.
- `GET /ai?since=<ts>&cursor=<c>&limit=<n≤500>` — pull on the records' own
  `ai_at` cursor. → `200 { "items": [...], "next_cursor" }`.

### `GET /tombstones?since=<ts>`
→ `200 { "items": [ { "uid": "...", "deleted_at": ... } ] }`.
Tombstones are GC'd after **90 days** (`worker/src/sweep.ts`): a device
offline longer than that can resurrect a deleted relic on reconnect —
accepted trade for a bounded table.

### `POST /blob?id=<blob-id>`
Body: raw encrypted bytes (`nonce ‖ ct`). `id` is client-generated
(`[A-Za-z0-9-]{8,64}`) because the AEAD's AAD binds it before upload.
Enforces size cap + quota.
→ `200 { "key": "<id>" }` — blob keys are **bare client ids** in the wire
protocol; the `users/<account>/blob/` R2 prefix is a server-side detail.
Blobs unreferenced by any relic after 24 h are swept by the 6-hourly cron
(`worker/src/sweep.ts`).

### Chunked uploads — `/blob/mpu` (blobs past the ~100 MB edge body limit)

R2 multipart brokered through the Worker (`worker/src/blob.ts`). Clients use
plain `POST /blob` up to 64 MiB and these routes beyond. Multipart is pure
transport — R2 reassembles the exact sealed bytes, the envelope format is
unchanged.

- `POST /blob/mpu?id=<blob-id>` `{ "declared_size": n }` — pre-transfer
  cap/quota check (413/402 **before any bytes move** — the client's upgrade
  prompt). → `200 { "upload_id", "part_size": 67108864, "max_parts" }`.
- `PUT /blob/mpu/:id?upload_id=…&part=N` — raw chunk (streamed; all parts
  `part_size` except the last, R2's rule). → `200 { "part", "etag" }`.
- `POST /blob/mpu/:id/complete` `{ "upload_id", "parts": [{ "part", "etag" }] }`
  — re-checks the **true** size against cap+quota (a lying client's object is
  deleted here). → `200 { "key": "<id>" }`, same shape as `POST /blob`.
- `DELETE /blob/mpu/:id?upload_id=…` — abort, idempotent. → `200`.

Abandoned uploads are aborted by the bucket lifecycle rule (3 days).

### `GET /blob/:id`
→ `200` raw bytes, `Cache-Control: private, immutable` (edge-cached; free
egress). Resolved within the token's account namespace only.

### `GET /account`
→ `200 { "tier": "free|pro|max", "storage_used": n, "storage_quota": n,
"vault_count": n, "vault_cap": n|null, "history_count": n,
"history_cap": n|null, "evicted_count": n, "devices_cap": n|null }` — for
client-side quota display. Never includes key material.

The last four are the history ring. `history_count` is unpromoted relics still
in view, `history_cap` is the tier ring (`null` on pro and max, meaning no
ring), and `evicted_count` is how many older copies are held back and would
come straight back on an upgrade (always `0` when there is no ring). Clients
treat a missing field as `0` or `null`, so an older server never breaks a
newer client.

### `DELETE /account`
Full account deletion (R2 objects, D1 rows, Stripe cancel). Irreversible.
Requires a **fresh** Supabase token (`iat` within 10 minutes), else
`403 stale_token` ("refresh and retry") — a stale leaked bearer alone must not
be able to destroy an account. Clients force a token refresh right before
calling, so legitimate deletes never see the 403; legacy device tokens carry
no `iat` and are grandfathered.

### Devices — `/account/devices`
- `POST /account/devices` — register a device `{ device_id, label, platform }`.
  Enforces the per-tier device cap; at cap returns `409` **with the current
  device list** so the client can offer "remove one."
- `GET /account/devices` — list registered devices.
- `PATCH /account/devices/:id` `{ "label" }` — rename. → `200 { "ok": true }`,
  `404` if the device is unknown or revoked.
- `DELETE /account/devices/:id` — remove **and sign the account out**. Revokes
  every refresh token at the IdP (GoTrue `POST /logout?scope=global`) and stamps
  `accounts.min_valid_iat`, so access tokens issued before the removal are
  refused at once rather than lingering for their last hour. GoTrue has no
  per-session revocation, so this is necessarily account-wide: every device has
  to sign in again. Answers `{ "ok": true, "sessions_revoked": <bool> }`; when
  the IdP call does not succeed the watermark is deliberately left unstamped and
  only the KV `rev:` guard applies, which needs the client to send
  `X-Relic-Device`.

### Pairing relay — `/pair/*` (device onboarding)
Short-lived KV relay for the QR join flow. The server never sees plaintext
secrets; slots (`np`, `tp`, `mk`) hold opaque sealed blobs for 120 s.
- `POST /pair/start` → `200 { "pairing_id" }` (the channel key rides only in
  the QR).
- `POST /pair/offer` `{ "pairing_id", "slot", "blob" }` (blob ≤ 8 KiB) → `204`.
- `GET /pair/poll?pairing_id=&slot=` → `200 { "blob" }`, or `204` when absent,
  expired, or consumed (all three look the same on purpose).
- `GET /pair/claim?pairing_id=&slot=` — same, but single-use: deletes the slot.

### Share links — `/share`, `/s/:id`
E2EE one-way shares (`worker/src/share.ts`): 
- `POST /share?id=<b64url>&ttl=<3600|86400|604800>&views=<n>` — body is the
  AES-GCM sealed payload; client mints the id (409 on collision → re-mint).
  → `200 { "url": "https://relic.space/s/<id>" }`; the key travels only in the
  URL fragment.
- `GET /s/:id` — recipient page (HTML, no account needed). Never counts a view.
- `GET /share/:id/blob` — the sealed payload the page fetches on Reveal. This
  is the fetch that counts a view; `410 share_gone` once expired or used up.
- `DELETE /share/:id` — revoke. Expired/over-viewed shares are swept by cron.

### Billing — `/stripe/*`
- `GET /stripe/plans` — public price/tier table (`{ "plans": [...] }`, cached
  5 minutes; empty on a server with no billing).
- `POST /stripe/checkout` → `200 { "url" }` (see below for the body).
- `POST /stripe/portal` → `200 { "url" }`, `409 no_subscription` when there is
  nothing to manage.
- `POST /stripe/webhook` — signature-verified; events applied idempotently via
  `billing_events`, queue-buffered when bound.

Every billing route answers `503 billing_unconfigured` on a server without a
Stripe key (every self-host).
`POST /stripe/checkout` takes `{ price_id, source? }`; a `source` on the
allowed list rides through to Stripe as `metadata.source` on the Checkout
Session and the Subscription, so we can see which upgrade button converts.
Anything off the list is dropped and the checkout still goes through.
The grace-sweep cron emails each account it downgrades ("plan lapsed, your
data is safe", via Resend, best-effort) so a lapse is never discovered via a
402.

### Live-sync doorbell — `GET /sync/socket` (WebSocket)

Authed upgrade (`Upgrade: websocket`) forwarded to the account's Durable
Object. A write on one device rings the others, content-free; they answer
with a normal pull. `501 no_socket` on a server without the binding
(self-host), and the client falls back to polling.

## Rate limits

Every route except the webhook and the live-sync socket sits behind a fixed
window limiter: per account on signed-in routes, per IP on public ones. A
reply from a limited route says which policy applied, in the standard headers,
so a client can pace itself instead of guessing:

| header | on every reply | on a 429 |
|---|---|---|
| `RateLimit-Policy` | `"sync";q=900;w=60` (quota, window in seconds) | same |
| `RateLimit-Limit` | the quota | same |
| `RateLimit` | | `"sync";r=0;t=60` (remaining, seconds until the window turns) |
| `RateLimit-Remaining` | | `0` |
| `RateLimit-Reset` | | seconds until the window turns |
| `Retry-After` | | seconds to wait |

The `X-RateLimit-Limit` and `X-RateLimit-Remaining` forms ride along for
clients that only know those. The policies (`worker/src/ratelimit.ts`, which a
test keeps equal to `worker/wrangler.example.toml`):

| policy | routes | quota |
|---|---|---|
| `public` | /health, /stripe/plans | 30 per minute per IP |
| `share-view` | /s/:id, /share/:id/blob | 30 per minute per IP |
| `sync` | the data plane: /keyparams, /relics, /relic/:uid, /tombstones, /blob*, /ai* | 900 per minute per account |
| `billing` | /stripe/checkout, /stripe/portal | 12 per minute per account |
| `share` | creating and revoking shares | 10 per minute per account |
| `pair` | /pair/* | 40 per minute per account |
| `device` | registering, renaming and removing devices | 20 per minute per account |
| `account` | deleting the account | 3 per minute per account |

The limiter only reports pass or fail, so a 2xx carries the quota and window
and never a remaining count. A self-hosted server with no limiter bindings
sends none of these headers and never answers 429.

## Versioning and deprecation

- The path carries no version. `info.version` in `docs/openapi.json` follows
  semver: patch for wording, minor for additive changes, major for a breaking
  one.
- Additive changes (a new route, a new optional request field, a new field in
  a reply) can ship at any time. Clients ignore fields they do not know. The
  sealed envelope has its own `v` (`docs/wire-format.md`).
- A breaking change ships as a new route or a new envelope `v`. The old route
  keeps working for at least 180 days after the change ships and is marked
  `deprecated: true` in the spec.
- While it is deprecated, every reply on it carries `Deprecation` (RFC 9745,
  since when), `Sunset` (RFC 8594, the date it stops) and a `Link` with
  `rel="successor-version"`. The helper is `deprecated()` in
  `worker/src/http.ts`, so every retirement looks the same on the wire.
- After the sunset date the route answers `410 gone`.
- Self-hosted servers run the same code, so the same rules apply there.
- Nothing is deprecated today. The spec's `x-versioning-policy` carries this
  list in machine-readable form.

## Tier limits (enforced here — `worker/src/tiers.ts` is the source of truth)

| | free | pro | max |
|---|---|---|---|
| per-item size | 10 MB | 100 MB | 500 MB |
| storage quota | 250 MB | 25 GB | 250 GB |
| stream | prune unpromoted past 500 | unlimited | unlimited |
| vault | 25 promoted | unlimited | unlimited |
| devices | 3 | 10 | unlimited |

## R2 layout

```
users/<account>/keyparams.json
users/<account>/relics/<uid>
users/<account>/blob/<uuid>
users/<account>/tombstones/<uid>
```

`GET /relics` pagination uses R2 `list()` + envelope `updated_at` in v1
(personal-scale); if listing cost bites, mirror envelope plaintext fields into
a D1 table as the index. Either way the contract above doesn't change.
