# Security

Relic exists to hold the things people copy, which means it holds passwords,
tokens, recovery codes, and private messages. Security reports get priority over
everything else.

## Reporting a vulnerability

Email **security@relic.space**. Please include:

- what you found and where (component, file, or endpoint),
- the steps or proof-of-concept needed to reproduce it,
- the impact you think it has.

Do not open a public issue for a vulnerability. Give us a reasonable window to
ship a fix before disclosing publicly. We will acknowledge your report, keep you
updated while we work on it, and credit you in the release notes unless you ask
us not to. There is no bug bounty program.

## Supported versions

- **Official signed builds** (winget, Google Play, and the installers published
  on the releases page) are supported. Fixes ship in the next release.
- **Self-built and forked binaries** are best effort. If you can reproduce an
  issue on a current official build, it gets the full treatment.

## Threat model

### What the encryption protects

Content is sealed on your device before it is sent anywhere. A server, ours or
your own, stores ciphertext and a small set of plaintext envelope fields.

- **A compromised or hostile server** yields ciphertext, plus metadata: item
  ids, timestamps, byte sizes, which items you marked as kept, device count,
  tier, and (on the hosted service) your account email. It does not yield any
  content. The full plaintext field list is in
  [`docs/wire-format.md`](./docs/wire-format.md), stated field by field with the
  reason the server needs each one.
- **A stolen backup or a subpoena** produces the same thing: sealed bytes. There
  is no key escrow, no server-side decryption, and no data recovery path. A
  service that can reset your data can read it, so Relic cannot reset yours.
- **Ciphertext shuffling.** Every ciphertext is bound to its context with AAD
  (`relic.relic.v1:<uid>` for an item, `relic.blob.v1:<id>` for a blob,
  `relic.mkwrap.v1` for the wrapped master key, `relic.share.v1:<id>` for a
  share). A server cannot replay a sealed item as a different item, as a blob,
  as a backup, or as a share. The test suite proves this by moving a ciphertext
  between contexts and showing that it fails to decrypt.
- **Traffic to the server** is TLS on top of the above, so the sealing is not
  load-bearing against a passive network observer, but it is what makes the
  server itself untrusted infrastructure rather than trusted infrastructure.

### What it does not protect

- **A compromised device.** Relic decrypts on your machine and holds a plaintext
  local index so search can be instant and offline. Malware with your user
  privileges can read that index. This is the same limit every password manager
  has, and no client-side encryption scheme changes it.
- **A weak passphrase.** Argon2id makes guessing expensive, not impossible. Your
  passphrase is the whole security boundary for a new device, so it needs to be
  a real one. A weak passphrase plus a stolen server-side blob is an offline
  attack that money can win.
- **A lost passphrase with a lost recovery kit.** That is unrecoverable, by
  design. Keep the recovery kit generated at setup.
- **Content already on screen or on the system clipboard.** Once you pick an
  item and it lands on the clipboard, it is exposed to whatever else can read
  the clipboard. Relic marks it sensitive where the OS supports that and clears
  it on a timer, which reduces and time-boxes the exposure rather than
  eliminating it.
- **Shoulder surfing, screen capture on iOS, and other physical-world things.**

### Pinned cryptographic parameters

| | |
|---|---|
| Content cipher | XChaCha20-Poly1305, 24-byte random nonce per encryption |
| Key derivation | Argon2id v1.3, **64 MiB memory, 3 iterations, parallelism 4**, 16-byte per-account salt, 32-byte output |
| Key hierarchy | random 256-bit master key encrypts all content; the passphrase-derived KEK only wraps the master key, so changing a passphrase re-wraps and never re-encrypts data |
| Context binding | AAD per domain, listed above |

These are not negotiable at runtime and are not configurable in the client. The
format version gates any future change. Full specification:
[`docs/crypto.md`](./docs/crypto.md).

## Verify it yourself

The crypto is a standalone Apache-2.0 package, and it is the exact code the apps
run:

```sh
cd crypto
dart pub get
dart test
```

That checks the Argon2id derivation against its published reference vector,
round-trips real item, blob, backup, and share ciphertext, and proves the AAD
binding. A second, independently written implementation lives in `crypto/js/`
and is byte-verified against the Dart one, so you can read either and check
both against [`docs/wire-format.md`](./docs/wire-format.md).

## Transparency notes

- **Models are downloaded, not bundled.** The on-device AI fetches its models at
  first run from a public mirror. Nothing about your content is sent in the
  process, and `--offline` skips the network entirely.
- **One non-free dependency.** QR scanning for device pairing uses
  `mobile_scanner`, which wraps Google ML Kit on Android. It is a scanner, not a
  network client, and it is only reached from the pairing screen. Replacing it
  with a fully free scanner is planned.
- **No analytics or crash-reporting SDKs** are linked into the client, because
  either one could carry plaintext off the device.
