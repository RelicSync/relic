# Building Relic

Every component builds from a clean checkout of this repository. **No build step
requires a secret**: no API key, no token, no `--dart-define`, no `.env`. If a
build asks you for a credential, something is wrong.

```sh
git clone https://github.com/RelicSync/relic
cd relic
```

The Rust crates (`relic-core`, `relic-sift`, `relic-cli`) build through the root
`Cargo.toml` workspace, so run `cargo` from the repository root.

---

## Toolchain

| Tool | Version | Needed for |
|---|---|---|
| Flutter | stable channel (3.44.x at time of writing) | `app/` |
| Dart | 3.12.2 or newer within 3.x (the app pins `sdk: ^3.12.2`; the Flutter SDK bundles a matching Dart) | `app/`, `crypto/` |
| Rust | stable (1.95 or newer) | `relic-core`, `relic-sift`, `relic-cli` |
| Node | 22 or newer | `worker/`, `selfhost/` |
| JDK | 17 | Android builds |
| Visual Studio 2022 Build Tools, Desktop development with C++ | latest | Windows desktop builds |

Android is pinned on purpose and should not be bumped casually:

| | Version | Why |
|---|---|---|
| Android Gradle Plugin | 8.9.1 | `super_clipboard`'s native build (irondash cargokit) calls Gradle's `Project.exec()`, which Gradle 9 removed. AGP 9 forces Gradle 9, so the APK build breaks on it. |
| Gradle | 8.12 | Same reason. AGP 8.9.1 runs fine on it. |
| Kotlin | 2.1.20 | Matches the pinned AGP. |

Both pins live in `app/android/settings.gradle.kts` and
`app/android/gradle/wrapper/gradle-wrapper.properties`. Stay on the 8.x line
until `super_clipboard` ships a Gradle-9-compatible cargokit.

---

## `app/` — the Flutter client

### Windows

```sh
cd app
flutter pub get
flutter build windows --release
```

Output lands under `app/build/windows/`. The build produces an unsigned binary;
official releases are signed separately by the maintainer.

### Android

```sh
cd app
flutter pub get
flutter build apk --release      # or: flutter build appbundle --release
```

Release signing reads `app/android/key.properties`, which is not in the
repository. **When that file is absent the release build falls back to the debug
key**, so a fresh clone builds an installable APK without any keystore. It is
just not the signed artifact that ships to Google Play.

Android also needs the Android SDK (platform + build-tools + NDK) and JDK 17.
`flutter doctor` will tell you what is missing.

Expect the **first** Android build to take 10–20+ minutes: cargokit
cross-compiles Rust (for `super_native_extensions`) once per ABI before Gradle
even starts, and a cold Gradle cache adds more. It is not hung. Later builds
are much faster.

### Analyze and test

```sh
cd app
flutter analyze --no-fatal-infos
flutter test
```

Neither needs a secret or a network account. The `--no-fatal-infos` flag
matches CI: errors and warnings fail the check, info-level style lints do not
(a clean checkout currently carries a few dozen of those, tracked as cleanup).

---

## `relic-sift/` — the on-device AI sidecar

```sh
cargo build --release -p relic-sift
```

The binary is `sift`. It speaks NDJSON over stdin/stdout with no port and no
token; the app spawns it as a child process.

**Models are downloaded at runtime, not bundled and not in this repository.**
The first classification run fetches the ~750 MB core model set (12 files) from
a public mirror, into `%LOCALAPPDATA%\relic-sift\models` (override with
`RELIC_SIFT_HOME`). The optional labeling model is a further ~666 MB and is
fetched only when you first use `--label`. Everything downloaded is permissively
licensed.

To build and run with no network at all:

```sh
sift classify --text "hello" --offline    # or --no-ml
```

Without models the pipeline degrades gracefully to its deterministic stage
(regex, entropy, magic-byte routing) and still works.

Useful checks:

```sh
sift doctor              # verify the install
sift models status       # what is downloaded
sift models download     # fetch the core set explicitly
```

---

## `relic-cli/` — the agent-facing CLI

```sh
cargo build --release -p relic-cli
# or install it on PATH:
cargo install --path relic-cli --locked
```

Then:

```sh
relic status     # detects the desktop app's local vault
relic where      # prints the data paths
```

The CLI has no network code. It reads and writes the desktop app's local vault
directly, so it needs the app installed to be useful, but it builds and runs
without it.

By default it attaches to the **real** desktop app's data directory
(`%APPDATA%\relic` on Windows). To point it at a different vault — a sandbox,
a test fixture — set `RELIC_APP_DIR` to that directory. (Not to be confused
with `RELIC_DATA_DIR`, which is a self-host *server* variable; the CLI ignores
it.)

---

## `worker/` — the Cloudflare Worker sync server

```sh
cd worker
npm ci
npm test          # vitest; needs Node 22
cp wrangler.example.toml wrangler.toml   # wrangler needs a config to run
npx wrangler dev  # local dev server (simulated D1/R2/KV, no account needed)
```

`wrangler.example.toml` documents every binding the worker expects (D1, R2,
KV). For `wrangler dev` you can copy it **unmodified** — wrangler simulates the
bindings locally. Only when deploying to your own Cloudflare account do you
fill in your own resource ids. The live sync doorbell (a Durable Object named `SYNC`)
is **optional**: with the binding absent, `/sync/socket` returns 501 and clients
fall back to polling. It requires a Workers Paid plan.

If you would rather not run Cloudflare at all, use `selfhost/` instead. It is
the same server code.

---

## `selfhost/` — the same worker on plain Node

Docker, from the repository root (the image needs both `worker/` and
`selfhost/`):

```sh
docker build -f selfhost/Dockerfile -t relic-selfhost .
docker run -d --name relic -p 8787:8787 -v relic-data:/data relic-selfhost
```

Without Docker:

```sh
cd selfhost
npm install
npm run smoke     # in-process round-trip of the full sync data plane
npm start         # serves on :8787, data in ./data
```

Verify a running server with `curl http://localhost:8787/health` — it answers
`{"ok":true}` without auth. (Everything else returns 401 until a device
enrolls.)

**CI-runner note (skip on a normal machine):** the commands above work as-is
from a fresh clone. Some CI runners hoist `node_modules` differently; if the
smoke test cannot resolve the worker's dependencies there, copy
`selfhost/package.json` to the repository root and `npm install` at the root
instead.

Configuration is all optional: `PORT` (default `8787`), `RELIC_DATA_DIR`
(default `/data`), `RELIC_ENROLL_SECRET`, `RELIC_APP_BASE_URL`. There is no
account system and no Supabase project involved; enrollment is
trust-on-first-use against the passphrase you type in the app.

---

## `crypto/` — the verifiable client crypto

```sh
cd crypto
dart pub get
dart test
```

This runs the pinned vectors: the Argon2id derivation against its published
reference value, round-trips of real item, blob, backup, and share ciphertext,
and the AAD binding check (a ciphertext moved to a different context must fail
to decrypt). It needs Dart only, not Flutter, and it takes seconds.

The JavaScript implementation in `crypto/js/` is the same wire format,
independently written, and is what the hosted web vault ships to browsers.

---

## `relic-core/`

```sh
cargo build --release -p relic-core
cargo test -p relic-core
```

The Rust reference for the formats and the deterministic classification rules.

---

## macOS and iOS

`codemagic.yaml` at the repository root defines two cloud build lanes on
Codemagic's Mac hardware: an iOS TestFlight lane and a macOS DMG lane. Its
header comments double as the setup guide. Signing material is supplied through
Codemagic environment variable groups and never lives in this repository. Both
platforms are still in progress.
