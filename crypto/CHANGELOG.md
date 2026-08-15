# Changelog

## 1.0.0

First pub.dev release, published from the `crypto/` directory of the
[Relic monorepo](https://github.com/RelicSync/relic).

This is the exact sealing code the Relic apps ship: Argon2id (64 MiB,
pinned parameters) wrapping a master key, XChaCha20-Poly1305 for vault
content and backups, AES-GCM for share links. The wire format is
documented in `wire-format.md`, and the `js/` directory carries the
TypeScript mirror served to browsers, byte-verified against this Dart
implementation by the test suite.
