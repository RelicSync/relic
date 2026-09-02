# Relic — Backend API Contract v1

Cloudflare Worker, JSON over HTTPS. Implements SPEC §8 against R2 (objects) +
D1 (accounts, tokens, counters).

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
| 429 | `rate_limited` | per-account rate limit |

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
"vault_count": n, "vault_cap": n|null }` — for client-side quota display.
Never includes key material.

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
Short-lived KV relay for the QR join flow: `POST /pair/start`,
`POST /pair/offer` (sealed opaque blobs, both directions), `GET /pair/poll`,
`GET /pair/claim` (single-use, deletes the record). The server never sees
plaintext secrets.

### Share links — `/share`, `/s/:id`
E2EE one-way shares (`worker/src/share.ts`): 
- `POST /share?id=<b64url>&ttl=<3600|86400|604800>&views=<n>` — body is the
  AES-GCM sealed payload; client mints the id (409 on collision → re-mint).
  → `200 { "url": "https://relic.space/s/<id>" }`; the key travels only in the
  URL fragment.
- `GET /s/:id` — recipient page (HTML, no account needed); 
  `GET /share/:id` / `GET /share/:id/blob` — the sealed payload/blob it fetches;
  `DELETE /share/:id` — revoke. Expired/over-viewed shares are swept by cron.

### Billing — `/stripe/*`
`GET /stripe/plans` (public price/tier table), `POST /stripe/checkout`,
`POST /stripe/portal`, `POST /stripe/webhook` (signature-verified; events
applied idempotently via `billing_events`, queue-buffered when bound).
The grace-sweep cron emails each account it downgrades ("plan lapsed, your
data is safe", via Resend, best-effort) so a lapse is never discovered via a
402.

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
