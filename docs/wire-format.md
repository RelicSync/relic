# Relic — Wire Format v1

The persisted contract between clients and the sync store. Encrypted objects
live forever, so this format is versioned from day one: `v` bumps on any
breaking change; clients ignore unknown fields within a version.

Independent implementations that must stay in lockstep: the Dart app
(`app/lib/data/worker_repo.dart` envelopes, `blob_upload.dart` blob/MPU wire),
the **web vault** (`crypto/js/vault-write.ts` + `vault-api.ts` — byte-verified
against the app), and the worker's validation/tests (`worker/src/index.ts`
`validEnvelope`).

## EncryptedRelic envelope

One JSON object per relic — the body of `PUT /relic/:uid` and of each R2 object
`users/<account>/relics/<uid>`.

```json
{
  "v": 1,
  "uid": "0190a8e2-7c4d-7000-8000-1a2b3c4d5e6f",
  "created_at": 1765400000,
  "updated_at": 1765400000,
  "byte_size": 1234,
  "promoted": false,
  "blob_key": "<bare client-generated blob id>",   // omitted for text relics
  "n": "<b64 24B nonce>",
  "ct": "<b64 AEAD ciphertext>"
}
```

**Plaintext fields are exactly what the Worker needs to do its job, and nothing
more** (the "minimal metadata" of SPEC §13):

| field | why the server sees it |
|---|---|
| `uid` | object identity, AAD binding |
| `created_at` / `updated_at` | ordering, sync cursors, ring pruning |
| `byte_size` | size caps + storage quota enforcement |
| `promoted` | free vault cap; ring prune must skip vault items |
| `blob_key` | DELETE/prune must remove the relic's blob; it's a random server-side object key the server already sees on every blob request — no content leak |

`promoted` being visible is a deliberate, documented metadata leak (the
operator can see *which* items you marked, not what they are).

`byte_size` is the whole stored payload, not just the body: for a text relic
it is the plain content plus the `rich` flavors, and for a blob relic it is
the bundle length. Declaring less is what the Worker's plausibility floor
catches (it refuses a push whose body exceeds `byte_size * 4 + 16 KiB`),
because a client that under-declares is getting storage it is not charged
for.

## Private payload (inside `ct`)

AEAD-decrypts (key = MK, AAD = `relic.relic.v1:<uid>`) to:

```json
{
  "kind": "string | photo | file | other",
  "source": "clipboard | upload | hotkey | share | api",
  "device": "desktop-1",
  "mime": "image/png",
  "filename": "screenshot.png",
  "tags": ["url", "code"],
  "user_tags": ["work"],
  "title": null,
  "collection": null,
  "note": null,
  "content": "the text itself (string relics; null for blob relics)",
  "preview": "short list title",
  "attachments": [{"id": "…", "name": "notes.pdf", "mime": "…", "size": 1234}],
  "rich": {"h": 123456789, "html": "<b>styled</b>", "rtf": "<base64>"}
}
```

`attachments` is the manifest for the single bundle blob: filenames never reach
the server, so they ride inside `ct` while only `blob_key` is plaintext.

`rich` holds the formatting flavors of a text relic, so pasting into Slack or
Word keeps its styling. Both flavors are optional and the whole object is
capped at **256 KiB** by the writing client, which keeps a maximal item well
inside the Worker's `caps.item * 1.5` body gate. `h` is a fingerprint of the
`content` the flavors were derived from: a reader that finds a mismatch (a
writer edited the text without knowing this field exists) must ignore the
formatting rather than paste it. A relic tagged `secret` never carries this
field, and it is stripped from a redacted export.

JSON arrays here; the comma-joined form exists only in the local SQLite FTS
columns. Optional fields are `null`/omitted.

**"Ignore unknown fields" is read-only, not round-trip.** The web vault re-seals
the decrypted payload map verbatim, so it preserves keys it does not model. The
Dart and Rust clients rebuild the payload from their typed structs, so a build
that predates a field DROPS it on the next push of that relic. New payload
fields are therefore additive and safe, but an old client touching a relic will
strip them. `uid`, timestamps, `byte_size`,
`promoted`, and `blob_key` are NOT duplicated inside `ct` — the envelope is
authoritative and `uid` is tamper-bound via AAD. (`updated_at`/`promoted` are
Worker-readable by design; a malicious server rewriting them is within the
threat model's accepted metadata surface.)

## Blob objects

`POST /blob?id=<id>` body and R2 object `users/<account>/blob/<id>`: raw bytes,
`nonce (24B) ‖ AEAD ciphertext`, key = MK, AAD = `relic.blob.v1:<id>` where
`id` is client-generated (the AAD must be fixed before the server assigns the
full key). No JSON wrapper. Upload order: blob first → receive `blob_key` →
push the relic envelope referencing it. Unreferenced blobs are swept after 24 h.

## Tombstones

`users/<account>/tombstones/<uid>`:

```json
{ "v": 1, "uid": "…", "deleted_at": 1765400000 }
```

Retained 30 days; clients reconcile deletions via `GET /tombstones?since=`.
A device offline longer than 30 days must full-resync (compare local uids
against a complete listing) instead of trusting the tombstone feed.

## Conflict rule

Per-relic last-writer-wins on `updated_at` (server enforces: a `PUT` with an
older `updated_at` than stored is a no-op). Benign for this data model —
concurrent edits to the *same relic* on two devices are rare and low-stakes;
concurrent *captures* are different uids and never conflict.
