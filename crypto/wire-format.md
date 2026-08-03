# Relic crypto & wire format

This is the exact on-device encryption Relic uses. The reference implementation is
[`lib/relic_crypto.dart`](./lib/relic_crypto.dart); the pinned test vectors are in
[`test/`](./test). Nothing here is a simplification of what ships — it *is* what
ships.

Everything is sealed on your device. A Relic server (managed or self-hosted) only
ever receives ciphertext plus content-free metadata (ids, timestamps, sizes). It
never receives your passphrase or any key.

## Primitives

| Purpose | Algorithm | Notes |
| --- | --- | --- |
| Key derivation | **Argon2id** | v0x13, m = 64 MiB (65536 KiB), t = 3, p = 4, 32-byte output, 16-byte salt. Pinned; matches the Rust reference vector. |
| Vault + backup encryption | **XChaCha20-Poly1305** | 24-byte nonce, 16-byte tag. Ciphertext on the wire is `ciphertext ‖ tag`. |
| Share-link encryption | **AES-256-GCM** | 12-byte IV, 16-byte tag. A deliberately different primitive because share recipients decrypt in a browser, and WebCrypto speaks AES-GCM natively, not XChaCha20. |
| Hashing / fingerprints | **SHA-256** | |

Every ciphertext is bound to its context with **AAD** (additional authenticated
data). A ciphertext sealed in one context cannot be decrypted in another, even
under the same key, because the AAD string differs. The AAD domains are listed
below.

## Key hierarchy

A vault has one random 32-byte **master key (MK)**, generated once. Everything in
the vault is encrypted under the MK. The MK is never stored in the clear and never
leaves your devices.

The MK is wrapped by your passphrase:

```
KEK        = Argon2id(passphrase, salt)                      # 32 bytes
wrapped_mk = XChaCha20-Poly1305(KEK, mk_nonce, MK,           # seal
                                aad = "relic.mkwrap.v1")
```

The wrap record (`keyparams`) is what a server stores so a new device can fetch it
and unwrap the MK with the passphrase. It contains **no** secret the server can use:

```json
{
  "v": 1,
  "salt": "<base64, 16 bytes>",
  "argon2": { "m_kib": 65536, "t": 3, "p": 4 },
  "mk_nonce": "<base64, 24 bytes>",
  "wrapped_mk": "<base64, ciphertext ‖ tag>",
  "mk_fp": "<base64, 8 bytes>"
}
```

`mk_fp` is a non-secret fingerprint, the first 8 bytes of
`SHA-256("relic.mkfp.v1" ‖ MK)`. It lets a device that received an MK by other
means confirm it opens *this* vault before binding, without revealing the key.

Changing your passphrase re-wraps the **same** MK under a new KEK (fresh salt +
nonce); no content is re-encrypted, so a previously exported recovery kit stays
valid.

## Item (relic) payload

Each item's private fields (text, tags, title, note, filenames, …) are serialized
to JSON and sealed under the MK, bound to the item's uid:

```
n, ct = XChaCha20-Poly1305(MK, random_nonce, json,
                           aad = "relic.relic.v1:<uid>")
```

The envelope the server stores exposes only ciphertext plus content-free metadata:

```json
{ "v": 1, "uid": "...", "created_at": 0, "updated_at": 0,
  "byte_size": 0, "promoted": false, "blob_key": "...",
  "n": "<base64 nonce>", "ct": "<base64 ciphertext ‖ tag>" }
```

## Blob (image / file) payload

Binary payloads are sealed under the MK, bound to the blob's id, as a single wire
buffer:

```
wire = nonce(24) ‖ XChaCha20-Poly1305(MK, nonce, bytes,
                                      aad = "relic.blob.v1:<blobId>")
```

## Self-host enrollment token

Self-hosted servers are account-less. From the passphrase alone the client derives
a **bearer token**, domain-separated from the vault KEK:

```
FIXED_SALT = SHA-256("relic.selfhost.authsalt.v1")[0:16]
token      = base64url( SHA-256( "relic.selfhost.authtoken.v1"
                                 ‖ Argon2id(passphrase, FIXED_SALT) ) )
```

The server stores only `SHA-256(token)` (trust-on-first-use). This token only gates
*access* to ciphertext; it is not, and cannot derive, the vault key. Two people who
happen to pick the same passphrase on two different servers get the same token but
different random MKs, so neither can read the other's vault.

## Sealed backup files (`.relicvault`)

Local backup files use the same primitives but a fully independent key hierarchy: a
random **backup key (BK)** wrapped under a **dedicated backup passphrase**. The wrap
record travels inside the file, so any Relic install plus the passphrase can open
it. Segment AAD is backup-only (`relic.backup.v1:<domain>`), so a backup segment can
never be replayed as sync wire bytes or vice versa.

## Share links

Share links seal a payload under a fresh random AES-256-GCM key whose 43-char
base64url fragment rides in the URL after `#` and is never sent to the server. Wire
is `iv(12) ‖ ciphertext ‖ tag(16)`, AAD `relic.share.v1:<id>`, so a ciphertext can't
be replayed under a different share id.

## AAD domains (the full list)

| Domain | Used for |
| --- | --- |
| `relic.mkwrap.v1` | wrapping the master key under the passphrase KEK |
| `relic.mkfp.v1` | master-key fingerprint (hash input, not AEAD) |
| `relic.relic.v1:<uid>` | an item's private payload |
| `relic.blob.v1:<blobId>` | an image/file blob |
| `relic.selfhost.authtoken.v1` / `relic.selfhost.authsalt.v1` | self-host bearer derivation |
| `relic.backup.v1:<domain>` | sealed backup segments |
| `relic.share.v1:<id>` | E2EE share links (AES-GCM) |
