# CLAUDE.md

Guidance for coding agents working on the Relic **source** (contributing,
fixing, building). If you are here to *use* Relic's vault for a user, read
[`AGENTS.md`](./AGENTS.md) instead.

## This repo is the canonical source

Everything Relic ships is built from this repository: the desktop/mobile app,
the sync worker, the self-host server, the crypto package, the AI sidecar, and
the CLI. The maintainers keep a separate private repo for marketing, the
website, and release signing — but **product code lands here first**. If you
are a maintainer's agent, do not commit product changes anywhere else and
mirror them here later; that creates drift.

## Layout

| Dir | What | Test command |
| --- | --- | --- |
| `app/` | Flutter app (Windows + Android; iOS in progress) | `flutter analyze && flutter test` |
| `worker/` | Cloudflare Worker sync API | `npm test` |
| `selfhost/` | Self-hostable server (same worker, local adapters) | `npm run smoke` |
| `crypto/` | Dart crypto package (Apache-2.0) | `dart test` |
| `relic-sift/` | Rust on-device AI sidecar | `cargo test -p relic-sift` |
| `relic-cli/` | Rust CLI | `cargo test -p relic-cli` |

Full build instructions and toolchain pins: [`BUILD.md`](./BUILD.md). No build
or test needs any credential or secret.

## Gates you will hit in CI

- `flutter analyze` is **fully strict**: warnings and style infos both fail
  the build. The tree is lint-zero; run analyze locally before pushing.
- A secret scan runs over the diff. Deliberately fake tokens in tests/fixtures
  need a line-level `// scan-ok: <reason>` marker.
- Windows runners use VS 2026; worker CI runs `npm ci`, so `package-lock.json`
  must be regenerated with a full `npm install` (never partially on one
  platform, or Linux optionals get dropped).

## Ground rules

- Never commit clipboard contents, personal data, or live credentials —
  including in tests and fixtures.
- `worker/wrangler.toml` is gitignored on purpose; copy
  `wrangler.example.toml` and keep real resource ids out of the tree.
- Sign off commits (`git commit -s`); the project uses DCO, not a CLA.
- Line endings: the repo mixes platforms; when diffing trees or reviewing,
  use `--strip-trailing-cr` to separate real changes from EOL noise.
