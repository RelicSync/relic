# relic-crypto

**The encryption behind [Relic](https://relic.space), published so you can check
our work.** This is the *exact* code that seals your clipboard on your device
before anything is sent, extracted unchanged from the Relic apps. It is not a demo
or a simplified sketch; it is what ships.

Relic is a clipboard manager with end-to-end-encrypted sync. The claim is that a
Relic server, whether we host it or you [self-host it](https://github.com/RelicSync/server),
only ever sees ciphertext and can never read your data. For an end-to-end-encrypted
product, the client is where that claim lives or dies, so this is the part worth
reading.

## What it guarantees

- Your data is encrypted on your device with **XChaCha20-Poly1305** under a random
  master key, before it leaves.
- That master key is wrapped with a key derived from your passphrase using
  **Argon2id** (64 MiB, pinned parameters). Your passphrase and the master key
  never leave your devices, and the server stores neither.
- Every ciphertext is **bound to its context** with AAD, so a sealed item can't be
  replayed as a different item, a blob, a backup, or a share.
- The server holds only ciphertext plus content-free metadata (ids, timestamps,
  sizes) and cannot decrypt any of it.

Full details: [`wire-format.md`](./wire-format.md).

## Verify it yourself

The pinned test vectors run in seconds, with no Flutter and no app checkout:

```sh
dart pub get
dart test
```

This checks the Argon2id key-derivation vector against the reference value,
round-trips real item / blob / share ciphertext, and proves the AAD binding by
showing that a ciphertext moved to a different context fails to decrypt.

## What's here

- [`lib/relic_crypto.dart`](./lib/relic_crypto.dart) — the whole thing. `RelicCrypto`
  (vault sync), `BackupCrypto` (sealed `.relicvault` files), and `ShareCrypto`
  (E2EE share links). Its only dependencies are `cryptography` and `hashlib`.
- [`test/`](./test) — the pinned vectors.
- [`wire-format.md`](./wire-format.md) — the key hierarchy, envelope shapes, and the
  full list of AAD domains.

## How this fits together

- **The app** (the desktop and mobile clients from [relic.space](https://relic.space))
  is where this code runs.
- **The server** ([RelicSync/server](https://github.com/RelicSync/server)) is the
  open sync backend you can self-host. It only ever receives what this code produces:
  ciphertext.

## License

[Apache-2.0](./LICENSE). Read it, run it, reuse it. It carries no warranty; it is
published for transparency, not as a general-purpose crypto library.
