# Relic web-vault crypto (JavaScript)

These are the exact TypeScript sources that run in your browser when you use the
hosted web vault at <https://relic.space/vault>. They are published here so the
crypto claim is verifiable rather than asserted: open your browser's devtools on
that page and the code you are executing is this code.

Relic has three independent implementations of the same wire format:

| Implementation | Where it runs | Source |
|---|---|---|
| Dart | the desktop + mobile app | `crypto/` (Apache-2.0 package) |
| Rust | `relic-core` / `relic-sift` / `relic-cli` | `relic-core/` |
| JavaScript | the hosted web vault, in your browser | this directory |

All three are byte-verified against the same pinned test vectors. See
[`docs/crypto.md`](../../docs/crypto.md) for the format itself (Argon2id key
derivation, XChaCha20-Poly1305 segment sealing) and
[`docs/wire-format.md`](../../docs/wire-format.md) for the envelope.

## Files

  - vault-api.ts
  - vault-crypto.ts
  - vault-kek.worker.ts
  - vault-recovery.ts
  - vault-search.ts
  - vault-share.ts
  - vault-tag-intents.ts
  - vault-write.ts

## Scope and status

This directory is a **published copy for verification**, not a packaged library:
it is not built, imported, or tested from this repository, and it carries the
web app's import assumptions (Web Crypto, `fetch`, a bundler). The rest of the
Relic marketing site is not open source; only these files are, because only
these files are the crypto.

If you find a discrepancy between this code and the Dart or Rust
implementations, that is a security bug — please report it per
[`SECURITY.md`](../../SECURITY.md).
