# Relic — Specification

Relic is a lightweight, cross-platform tool for capturing and keeping the things you copy and collect. Each captured item is a **relic** — a string, a photo, a file, or something else. Everything is captured and stored locally first; sync to a backend (Relic Cloud or your own server) is optional and opt-in. Paste is never touched; an on-demand, encrypted, fully-searchable history is reachable by hotkey (desktop) or a lens app (mobile). End-to-end encrypted, so the operator cannot read your content.

**Relic is open source.** The app, the on-device AI, the sync server, the self-host build, and the CLI are all published here; the *hosted service* (Relic Cloud) is the paid convenience, and self-hosting is free. The pitch: *never lose anything you've ever copied.*

Status: design spec. Version 0.5 (+ 2026-07-05 reality notes).

> **Where the built product diverged from this spec (2026-07-05):** the product
> shipped and most decisions held, with these deltas. Clients are **Flutter**
> across desktop and mobile (`app/`), not egui or SwiftUI/Compose-over-UniFFI;
> `relic-core` (Rust) remains the format/crypto reference but the app carries
> its own Dart implementations. Auth shipped as a **Supabase JWT bridge** (not
> email+password rows in D1); Stripe billing is built with **three tiers**
> (free / Pro $7 / Max $12 — `worker/src/tiers.ts`). A third client class
> exists: the **web vault** at relic.space/vault (a full browser client).
> Windows 1.0.x is released; mobile lenses and the macOS port are
> underway; the Worker deploys via push-to-main CI. Sections below are edited
> where they'd otherwise mislead; the roadmap (§17) is kept as the historical
> plan.

> **v0.5 changelog (from v0.4):** contract artifacts written and the spec aligned to them — key architecture upgraded to a **wrapped master key** (passphrase change no longer re-encrypts data; recovery kit = raw MK; see `docs/crypto.md`); `promoted` moved into the plaintext envelope (the Worker needs it for ring/vault enforcement — documented metadata leak); canonical schema (`relic-core/relics.sql`) validated; API contract (`docs/api.md`) and wire format (`docs/wire-format.md`) added.
>
> **v0.4 changelog (from v0.3):** storage model settled — a per-tier storage quota, with the free tier's total quota closing the chunked-file abuse hole.
>
> **v0.3 changelog (from v0.2):** hosted-product direction with freemium tiers; stream/vault lifecycle with promotion (replaces the 500-ring-as-philosophy); email accounts + device tokens (replaces anonymous-token-only); per-relic R2 objects (replaces single `index.json`); passphrase + recovery kit; capture-side privacy controls (OS exclusion hints, pause); size-gated file-content capture; MVP defined as Windows desktop + Worker.

---

## 1. Product model

Two layers, one mental model:

- **The stream** — every clipboard change is captured automatically. On the **free tier** the stream is a rolling ring of the last **500** items. On the **paid tiers** the stream never expires: everything you ever copy is kept until you delete it.
- **The vault** — relics you've **promoted**: marked as deliberately kept. Promoted relics never expire on any tier, can be titled, tagged, grouped, and annotated, and are the heart of the product.

**Promotion** turns an ephemeral capture into a keepsake:
- *Promote-last hotkey* — instantly promote the most recent capture ("keep that").
- *Promote after the fact* — any item in the history popup / mobile lens can be promoted (or demoted).
- *Deliberate captures are born promoted* — anything added explicitly (upload widget, capture hotkey, share sheet) skips the ephemeral stage; only passive clipboard captures start unpromoted.

Deletion is always available — *never lose anything* means nothing ages out from under you, not that you can't tidy up.

### Tiers

The live grid. `worker/src/tiers.ts` is the source of truth and `docs/api.md`
restates the enforced limits.

| | Free | Pro ($7/mo or $60/yr) | Max ($12/mo or $96/yr) |
|---|---|---|---|
| Stream | rolling 500 items | unlimited, never expires | unlimited, never expires |
| Vault (promoted) | 25 | unlimited | unlimited |
| Storage quota | 250 MB | 25 GB | 250 GB |
| Max relic size | 10 MB | 100 MB | 500 MB |
| Devices | 3 | 10 | unlimited |
| Share links | 10 active, 5 MB each | 100 active, 50 MB each | unlimited, 50 MB each |

Self-hosting has no tiers and no caps beyond your own disk.

Storage is counted uniformly on every tier: every stored byte draws from the quota. In practice blobs are the only thing that moves the number — a heavy user copying ~50 text items a day accrues roughly 36 MB a **year**, so a decade of text is about 360 MB against a 25 GB Pro quota. That is what makes the headline promise *every string you ever copy, forever* honest. Photos and files are the cost driver and are what the quota actually bounds. **Over quota:** nothing is ever deleted — new blob captures are refused (text keeps flowing) until the user frees space or upgrades. The free 250 MB total quota exists to close the file-host abuse hole (500 ring × 10 MB ≈ 5 GB otherwise); normal free users never notice it.

The Worker enforces all caps server-side from tier claims in the device token (§10), with per-user byte counters in D1.

---

## 2. Goals & behavior model

- **Copy → capture.** Every clipboard change (any copy method, not just Ctrl+C) becomes a relic and is pushed to the backend.
- **Manual capture too.** Drag-and-drop **upload widget** and a **configurable capture hotkey** (separate from the history hotkey) — for grabbing files, images, or selections without going through copy/paste. These are born promoted (§1).
- **Paste → untouched.** Relic never writes to the clipboard on paste and never auto-syncs onto it, so it can't clobber what you have. Picking a relic from history is the *only* time Relic touches the clipboard, and only ever on an explicit pick.
- **Browse → on demand.** A hotkey (desktop) or app (mobile) opens the searchable history; picking one places it on the local clipboard for a normal paste.
- **Keep → forever.** Promoted relics (and, on paid, the whole stream) persist until explicitly deleted.
- **End-to-end encrypted.** Content is encrypted on the client with a key only the user holds; the operator stores ciphertext only.
- **Self-hostable.** The Worker and clients are open source; pointing the clients at your own deployment is supported. The hosted service is the convenience.

### Non-goals
- No background auto-capture on mobile (the OS forbids it — see §8).
- No bidirectional auto-paste / clipboard clobbering. Pick → clipboard only; the user pastes.
- No server-side content processing of any kind (conflicts with E2E).

---

## 3. Architecture

```
relic-core   (Rust)  — reference types · deterministic classification · crypto/format reference
   │
   ├── app (Flutter) — the shipping client: desktop (watcher · tray · hotkeys · popup)
   │                   and the mobile lens (same codebase, lens mode)
   ├── web vault (TS) — relic.space/vault: full browser client, in-tab crypto
   │                   wire-identical to the app (docs/crypto.md)
   └── relic-cli (Rust) — agent-facing CLI over the desktop app's local vault

backend: Cloudflare Worker + R2 (relic & blob store) + D1 (accounts, tokens, counters)
         self-host: the same Worker on plain Node + SQLite + local disk (selfhost/),
         or your own Cloudflare account
```

Two storage layers, deliberately separate:
- **Local index** — a per-device SQLite database holding *decrypted* relics for instant, offline search (§6).
- **Sync store** — the remote backend holding *encrypted* objects only (§7–8).

Each device syncs encrypted relics down, decrypts them, and upserts into its local index. Search and display happen locally; the server never sees plaintext.

---

## 4. The relic: types & auto-assigned metadata

Every relic has a `kind`, assigned automatically and deterministically (no AI):

| kind | assigned when |
|---|---|
| `string` | content is plain UTF-8 text |
| `photo`  | MIME sniffs to `image/*` (PNG/JPEG/WebP/HEIC… magic bytes) |
| `file`   | a binary payload with a non-image MIME (pdf, zip, docx…) |
| `other`  | anything that doesn't cleanly classify |

Auto-assigned metadata on every relic:

- `uid` — stable id, synced across devices
- `created_at` / `updated_at` — unix seconds; date and time derive from these (`datetime(created_at,'unixepoch','localtime')`)
- `byte_size`
- `source` — `clipboard` · `upload` · `hotkey` · `share` · `api`
- `mime`, `filename` — where relevant (photo/file)
- `blob_key` — R2 object key for binary payloads
- `device` — capturing device label
- `tags` — deterministic subtype tags (§5)
- `content` / `preview` — searchable text + a short title for the list

User-assigned metadata (vault organization; editable after capture, syncs as part of the encrypted payload):

- `promoted` — bool; set by promotion surfaces (§1)
- `title` — human name; auto `preview` is the fallback
- `user_tags` — freeform tags alongside the deterministic ones; same FTS index
- `collection` — named group ("API keys", "Receipts 2026")
- `note` — freeform annotation, indexed for search

Canonical schema and the FTS index live in `relics.sql`.

---

## 5. Deterministic classification (non-AI)

Classification is rule-based and runs client-side, so it works for everyone, costs nothing, and is consistent with E2E.

- **Kind** — from MIME / magic-byte sniffing (§4 table).
- **Subtype tags** — lightweight regex/heuristic detection on string content: `url`, `email`, `phone`, `ip`, `color` (hex), `json`, `code`, `jwt`/secret-ish, `path`, `markdown`. Stored in `tags`, comma-separated, and indexed for search/faceting.

That's the full client-shipping classification scope for now. An **auto-classification pipeline** (smart titling, semantic grouping) is future work and must run client-side to preserve E2E (§17).

---

## 6. Local search (SQLite + FTS5)

A per-device SQLite database is the search index. It runs over decrypted content, so search is local, instant, and offline while the server still holds only ciphertext.

- **FTS5** virtual table, external-content linked to `relics` (no data duplication), kept in sync by insert/update/delete triggers.
- Indexes `content`, `preview`, `filename`, `tags`, `title`, `user_tags`, `note`.
- Supports prefix (`token*`), boolean (`foo AND bar`), and phrase (`"exact match"`) queries; ranked by `bm25`.
- Filter by `kind`, `promoted`, `collection`, and date range in the same statement.
- Desktop keeps the **full archive** locally (SQLite + FTS5 is comfortably fast at 100k+ rows). Mobile keeps a recent window plus all promoted relics, fetching older stream items on demand.
- Deletes (local prune or remote tombstone) flow through triggers so the FTS index stays consistent.

Verified on the reference schema: ranked prefix search across kinds, kind filtering, boolean/phrase queries, filename search, and prune-with-index-consistency all pass.

---

## 7. Storage & sync backends (`RelicStore`)

```rust
trait RelicStore {
    async fn push(&self, relic: EncryptedRelic) -> Result<()>;          // create or update (upsert by uid)
    async fn list(&self, cursor: Option<Cursor>, limit: usize) -> Result<Page<EncryptedRelic>>; // newest first, paginated
    async fn delete(&self, uid: Uid) -> Result<()>;
    async fn push_blob(&self, blob: EncryptedBlob) -> Result<BlobKey>;
    async fn get_blob(&self, key: &BlobKey) -> Result<EncryptedBlob>;
}
```

| Backend | Use | Notes |
|---|---|---|
| `http` | The hosted service or a self-hosted Worker | Reference REST API (§8) |
| `s3`   | Any S3-compatible cloud (R2/B2/MinIO/Wasabi/AWS) | Per-relic objects + blob objects |
| `local`| Single machine / testing | Directory of JSON files |

Feature-gated at build time so only the chosen backend compiles in. Because every backend is just a byte store, **E2E works across all of them unchanged**.

### Sync semantics
- **Per-relic objects** — each relic is an independent object keyed by `uid`. Pushes are independent PUTs: no read-modify-write, no lost updates between devices. An update (promotion, title edit) is a PUT of the same `uid` with a bumped `updated_at`; conflicts resolve last-writer-wins *per relic*, which is benign.
- **Tombstones** — a delete writes a small tombstone marker retained for 30 days, so offline devices learn about deletions on next sync instead of resurrecting the relic. Blobs are deleted with their relic.
- **Incremental sync** — clients sync down by `updated_at` cursor; a fresh device pages through the full archive once, then stays incremental.

---

## 8. Backend API (Cloudflare Worker + R2 + D1)

A small Worker is the front door; clients use the `http` backend pointed at it. The Worker binds natively to R2 (no S3 credentials shipped to clients), checks auth, and enforces tier caps. **Clients never talk to R2 directly.**

- Auth: `Authorization: Bearer <device-token>`; tokens carry account id + tier claims (§10). Data namespaced per account id.
- `PUT /relic/:uid` — store or update an encrypted relic. Enforces: per-relic size cap, vault cap (free), and the free-tier 500 ring (prune oldest unpromoted; counter kept in D1, pruned lazily).
- `GET /relics?cursor=&limit=` — newest-first encrypted relics, paginated by `updated_at`.
- `DELETE /relic/:uid` — delete relic + blob, write tombstone.
- `GET /tombstones?since=` — deletions for incremental sync.
- `POST /blob` — store an encrypted binary blob (photo/file), returns `key`.
- `GET /blob/:key` — return an encrypted blob (edge-cached; free egress).
- Layout in R2: `users/<account>/relics/<uid>` (encrypted relic envelopes) + `users/<account>/blob/<uuid>` (encrypted payloads) + `users/<account>/tombstones/<uid>`.
- Each relic object is a small envelope: plaintext `{uid, created_at, updated_at, byte_size, promoted}` + opaque ciphertext for everything else (`docs/wire-format.md`). The Worker needs exactly these fields to order, page, enforce caps, and prune the ring *without touching vault items*; this is the "minimal metadata" of the trust claim (§13). `promoted` being server-visible is a deliberate, documented leak — the operator sees *which* items you keep, never what they are.

Consistency: per-relic objects make concurrent multi-device writes safe without coordination. A Durable Object for strict global ordering remains future work (§17) — not needed for correctness, only for features like live push.

---

## 9. Clients

### Desktop (`app/`) — **MVP target: Windows**
- **Clipboard watcher** (dedicated thread): on change, classify → encrypt → push. Never writes to the clipboard. Dedupes against the last-captured value before sending.
- **Capture-side privacy:**
  - **Honor OS exclusion hints** — items flagged `ExcludeClipboardContentFromMonitorProcessing` (Windows), `org.nspasteboard.ConcealedType` (macOS) must not be captured. Catches well-behaved password managers for free. The active Flutter Windows path honors the Windows private formats used by the Rust reference client.
  - **Pause toggle** — tray toggle (and optional hotkey) suspends capture; visibly indicated.
- **File copies:** copying files in a file manager puts *paths* on the clipboard; Relic reads the file and captures **contents, size-gated** by the tier cap. Over the cap → captured as a path-only string relic (marked with the `path` tag).
- **Upload widget:** drag-and-drop target for files/images; born promoted.
- **Hotkeys (configurable):**
  - *History* — open the searchable popup. Default `Ctrl+Shift+V` (`Cmd+Shift+V` on macOS).
  - *Capture* — grab the current selection/clipboard/file into a promoted relic without the popup.
  - *Promote-last* — promote the most recent capture in place.
  - Optional Windows-only `Win+V` interception via a `WH_KEYBOARD_LL` hook (not portable; the only feature needing per-OS native code).
- **Popup (Flutter):** searchable list backed by the local SQLite index; stream/vault views; promote/demote, edit title/tags/note, delete. Pick → decrypt → place on clipboard (clipboard only — the user pastes; see §12 for sensitive-clipboard handling).

### Mobile lens (iOS / Android)
The desktop model (background poll + global hotkey) is **not portable** — Android bans background clipboard access (since Android 10; only the foreground app or active keyboard can read it) and iOS has no background loop, no global hotkey, and prompts on pasteboard reads. The mobile app is therefore a **lens**: view history, and add relics in.

- **Browse:** sync down, decrypt on device, search via the local index (recent window + all promoted), tap to copy locally.
- **Capture (manual):** Share Sheet / Share intent, a photo/file picker, and a foreground "capture current clipboard" button (iOS shows the system paste banner on read). All born promoted.
- Built as the same Flutter codebase as desktop (`app/`, lens mode), so classification, crypto, and search are identical by construction.

### Web vault (relic.space/vault) — shipped 2026-07-05
A full browser client: sign in with the same account, unlock with the vault
passphrase (Argon2id in a web worker), and read/decrypt, add text/files, edit,
delete, create share links, and search — all client-side in the tab. Crypto and
wire format are byte-verified against the app (`docs/crypto.md`,
`docs/wire-format.md`); the implementation it runs is published in `crypto/js/`.
Semantic search is the one deliberate gap (needs the desktop ML sidecar); the UI
points users at the apps for it.

---

## 10. Accounts, auth & billing

- **Account:** Supabase-managed identity (email+password or Google/GitHub OAuth); the Worker verifies the Supabase JWT at the edge and uses its `sub` as the account id (`worker/src/auth.ts`). Email exists for billing, abuse contact, and *account* recovery — never for data recovery (§11). Account recovery resets credentials and tokens, not the E2E passphrase.
- **Device tokens:** signing in on a device issues a revocable bearer token carrying account id + tier claims. Tokens are listed and revocable from any signed-in device ("sign out my old laptop").
- **Billing:** Stripe; tier changes update token claims on next refresh. Downgrade behavior: nothing is deleted — over-cap content becomes read-only until back under cap or re-upgraded.
- **Strict separation:** the auth credential and the E2E passphrase are unrelated secrets. The key is never derived from, transmitted with, or recoverable through the account.
- **Self-host has none of this.** A self-hosted instance is account-less: the client derives an auth token and a vault key from the passphrase alone, the server stores only a hash of the first, and the first device to connect claims the instance (`selfhost/README.md`).

---

## 11. Encryption (E2E)

Full pinned parameters live in `docs/crypto.md`; summary:

- **Wrapped master key:** a random 256-bit **master key (MK)**, generated on the first device, encrypts all content. The user's **encryption passphrase** (chosen at setup, distinct from the account password) derives a KEK via **Argon2id** that *wraps* MK. The wrapped MK + KDF salt are stored server-side (safe: useless without the passphrase), so any new device unwraps with just the passphrase. Changing the passphrase re-wraps MK — no data re-encryption. Unwrap failure doubles as wrong-passphrase detection.
- **Recovery kit:** generated at setup — a printable/downloadable document carrying the raw MK (1Password-style), stored by the user, never by the operator. The kit survives passphrase rotation and allows re-wrapping under a new passphrase. Lost passphrase + lost kit = lost data, by design. A service that can reset your data can read it.
- **Cipher:** **XChaCha20-Poly1305** (AEAD); random nonce per encryption; AAD domain separation binds each ciphertext to its `uid`/blob key (prevents server-side mix-and-match).
- **Server holds:** ciphertext, the wrapped MK, and the minimal plaintext envelope fields (§8). Never the passphrase, any unwrapped key, or any escrow.
- **Classification, dedupe, and search happen client-side.**
- Algorithm/KDF parameters are fixed in `relic-core` and versioned in the wire format so every platform interoperates.

---

## 12. Safe display (post-decryption, client-side)

Encryption protects data to the device; display is a separate, device-local threat model. Treat the app like a password manager.

- **Ephemeral plaintext:** decrypt on demand; hold in `zeroize`-d buffers; never cache to disk, logs, analytics, or crash reports.
- **Masked by default:** show `••••` / truncated previews; reveal full content on explicit tap.
- **Unlock gate:** biometric / passphrase to open history; key stored in OS secure storage (iOS Keychain w/ biometric ACL, Android Keystore, desktop keychain); auto-lock on inactivity.
- **Screen capture:** Android `FLAG_SECURE` (blocks screenshots, recording, recents thumbnail); iOS blur/cover the window when backgrounded (screenshots can't be blocked on iOS).
- **On select:** placing a relic on the system clipboard re-exposes it — mark it sensitive (Android `EXTRA_IS_SENSITIVE`, Windows exclude-from-history, macOS concealed-type), auto-clear after ~30–60s, and on iOS set pasteboard `expirationDate` + `localOnly`. Only ever copy on an explicit pick.
- **Honest limit:** once on screen / on the system clipboard, exposure is reduced and time-boxed, not eliminated — same as any password manager.

---

## 13. Trust model

The point of E2E here is that the operator **cannot** read content, so users don't have to take it on faith.

- Client-side keys → the operator cannot decrypt R2 objects, even under breach or subpoena.
- The residual trust sits in the **client**, which holds the key and the plaintext. Make its behavior verifiable:
  - **Open-source the clients and the Worker** (biggest lever; also the self-host story). Done: this repository.
  - **Reproducible builds + signed releases** so the shipped binary provably matches the source (straightforward for Android APK / desktop; harder on the iOS App Store).
  - **No analytics/crash SDKs** that could carry plaintext.
  - **No key escrow, no server-side decryption, no data recovery path.** The key is never derived from any credential the server sees.
- **Accurate public claim:** "Content is encrypted with a key only you hold; we store ciphertext and minimal metadata and cannot decrypt it." Be explicit about what the operator *can* see: account email, timestamps, approximate sizes, item counts, which items are promoted, device count, tier.
- **Irreducible trust:** while clients ship through app stores, users trust the published binary matches the audited source. Full removal requires an open protocol + build-from-source / third-party clients (§17).

---

## 14. Shortcuts / quick entry points

Define two deep-link targets — `relic://capture` (capture current clipboard/selection, near-headless, born promoted) and `relic://history` (open the lens) — and point every surface at them.

- **iOS (via App Intents):** Action Button (15 Pro+), Back Tap, Control Center / Lock Screen control (iOS 18+), home-screen long-press actions, Siri, Spotlight.
- **Android:** Quick Settings tile, app & pinned shortcuts, home-screen widget (incl. a list widget showing recent relics), Google Assistant.

The desktop capture and promote-last hotkeys (§9) are the same idea applied locally.

---

## 15. Storage guardrails

Five mechanisms bound what a hosted account can consume, all enforced
server-side (`worker/src/tiers.ts`): the per-relic size cap, the storage quota,
the free-tier 500-item ring, the free-tier vault cap, and a per-account rate
limit. None of them delete anything: at a limit, new blob captures are refused
and existing data stays put.

Text and blobs sit at wildly different scales, which is why the quotas are sized
the way they are. A heavy user's text accrues roughly 36 MB a year, so a decade
of everything they copy is around 360 MB. Photos and files reach that in an
afternoon. The quota is a blob budget in everything but name.

---

## 16. Tech stack

- **App (Flutter/Dart, all platforms):** own SQLite index (`app/lib/data/relic_db.dart`), crypto from the `crypto/` package (the de-facto reference implementation), `window_manager`/`tray_manager`/`hotkey_manager`/`super_clipboard` on desktop. ML enrichment via the `sift` Rust sidecar (`relic-sift/`).
- **Web vault (TypeScript):** `hash-wasm` (Argon2id) + `@noble/ciphers` (XChaCha20-Poly1305) in the browser (`crypto/js/`); Next.js static export.
- **Rust:** `relic-core` (format/crypto reference, historical), `relic-cli`, `relic-sift`.
- **Backend:** Cloudflare Worker (TypeScript) + R2 + D1; Stripe for billing; deployed by push-to-main CI (`wrangler` under the hood). The same worker code runs on plain Node + SQLite + local disk for self-hosting (`selfhost/`).

---

## 17. MVP & roadmap

**Phase 1 — core loop (Windows desktop + hosted Worker, end-to-end):**
1. `relic-core`: types, classification, crypto, local SQLite/FTS index, `http` store.
2. Worker + R2 + D1: relic/blob/tombstone endpoints, token auth, tier enforcement. Tokens manually issued, tiers hand-flipped in D1 — enforcement is real from day one even though signup isn't.
3. `app/` (Windows): watcher, pause, history popup, capture/promote-last hotkeys, upload/file handling, Windows secure sync-secret storage, native clipboard exclusion hints, and durable outbound sync queue. Dogfood daily.

**Phase 2 — real auth, invite-only alpha:** email+password signup, device-token issuance/revocation, and the passphrase + recovery-kit onboarding — the flows with genuine UX risk, derisked on alpha users early.

**Phase 3 — Stripe, then public launch:** billing is deliberately last because by then it's pure plumbing — tier claims, quotas, and downgrade behavior already exist and are exercised. Wire checkout/webhooks, launch.

**Then:** macOS/Linux desktop → mobile lens (iOS first or Android first, TBD) → shortcuts surfaces.

### Out of scope / future
- **AI auto-classification / semantic search** — deferred. Must run **client-side** over decrypted content to preserve E2E; server-side classification is permanently off the table. (Eventual goal: an auto-classification pipeline for titling/grouping the vault.) *Since shipped as `relic-sift/`, on-device.*
- Client-side OCR / text extraction to make photos and files searchable by their contents.
- Durable Object (live push, strict ordering); needed for real-time features, not correctness.
- Completion of the Windows `Win+V` hook.
- Open protocol publication for third-party clients (max-trust path).

### Open questions (parked, not blocking)
- Whether the free vault cap (25) is the right number.
- Whether free-tier stream expiry is count-based (500) or also time-based.
- Mobile platform order for the lens.
- Collections model details (flat vs nested; relic in multiple collections?).
